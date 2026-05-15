/**
 * IELTS Training Platform — Tracker SDK v6
 * 用户名+密码认证 + 密钥绑定 + 会话管理
 *
 * 用法：
 *   tracker.init({ module: 'synonym', supabaseUrl: '...', supabaseAnonKey: '...' })
 *   tracker.event('answer', { itemKey: 'successive/consecutive', correct: true, responseMs: 2300 })
 *
 * 认证：
 *   await tracker.registerStudent(username, passwordHash, passwordRaw)
 *   await tracker.loginStudent(username, passwordHash)
 *   await tracker.bindKeyToStudent(studentId, keyString, realName)
 */

const tracker = (() => {
  // ── 内部状态 ──
  let _config = null;
  let _studentId = null;
  let _sessionId = null;
  let _sessionStart = null;
  let _db = null;
  let _flushTimer = null;
  let _supabaseUrl = '';
  let _supabaseAnonKey = '';
  let _online = typeof navigator !== 'undefined' ? navigator.onLine : true;

  const DB_NAME = 'ielts_tracker';
  const DB_VERSION = 3;
  const EVENT_STORE = 'event_queue';
  const HISTORY_STORE = 'practice_history';
  const MEMORY_STORE = 'memory_states';
  const FLUSH_INTERVAL = 5000;
  const FLUSH_BATCH_SIZE = 50;

  // localStorage keys
  const STUDENT_ID_KEY = 'ielts_student_id';
  const STUDENT_NAME_KEY = 'ielts_student_name';
  const STUDENT_CLASS_KEY = 'ielts_student_class';
  const USERNAME_KEY = 'ielts_username';
  const SESSION_COUNTER_KEY = 'ielts_session_counter';
  const LOGGED_IN_KEY = 'ielts_logged_in';
  const SESSION_TOKEN_KEY = 'ielts_session_token';
  const SESSION_EXPIRES_KEY = 'ielts_session_expires';
  const REMEMBER_ME_KEY = 'ielts_remember_me';

  // ── 工具函数 ──

  /** SHA-256 哈希（Web Crypto API） */
  async function sha256(message) {
    const msgBuffer = new TextEncoder().encode(message);
    const hashBuffer = await crypto.subtle.digest('SHA-256', msgBuffer);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
  }

  /** 生成随机 session token */
  function _generateSessionToken() {
    const bytes = new Uint8Array(32);
    crypto.getRandomValues(bytes);
    return Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
  }

  /** 生成新 student_id */
  function _generateNewStudentId() {
    return 'stu_' + Date.now().toString(36) + '_' + Math.random().toString(36).slice(2, 8);
  }

  // ── Session ID 生成 ──
  function _createSessionId() {
    let counter = parseInt(localStorage.getItem(SESSION_COUNTER_KEY) || '0', 10) + 1;
    localStorage.setItem(SESSION_COUNTER_KEY, String(counter));
    return `sess_${_studentId}_${counter}_${Date.now().toString(36)}`;
  }

  // ── IndexedDB 初始化 ──
  function _initDB() {
    return new Promise((resolve, reject) => {
      const req = indexedDB.open(DB_NAME, DB_VERSION);
      req.onupgradeneeded = (e) => {
        const db = e.target.result;
        if (!db.objectStoreNames.contains(EVENT_STORE)) {
          const store = db.createObjectStore(EVENT_STORE, { keyPath: 'id', autoIncrement: true });
          store.createIndex('module', 'module', { unique: false });
          store.createIndex('timestamp', 'timestamp', { unique: false });
        }
        if (!db.objectStoreNames.contains(HISTORY_STORE)) {
          const store = db.createObjectStore(HISTORY_STORE, { keyPath: 'id', autoIncrement: true });
          store.createIndex('studentId', 'studentId', { unique: false });
          store.createIndex('module', 'module', { unique: false });
          store.createIndex('eventType', 'eventType', { unique: false });
          store.createIndex('timestamp', 'timestamp', { unique: false });
          store.createIndex('sessionId', 'sessionId', { unique: false });
          store.createIndex('dayKey', 'dayKey', { unique: false });
        }
        if (!db.objectStoreNames.contains(MEMORY_STORE)) {
          const store = db.createObjectStore(MEMORY_STORE, { keyPath: 'itemKey' });
          store.createIndex('module', 'module', { unique: false });
          store.createIndex('nextReview', 'nextReview', { unique: false });
          store.createIndex('stability', 'stability', { unique: false });
        }
      };
      req.onsuccess = (e) => { _db = e.target.result; resolve(_db); };
      req.onerror = (e) => reject(e.target.error);
    });
  }

  // ── 事件队列 ──
  function _enqueueEvent(evt) {
    return new Promise((resolve, reject) => {
      if (!_db) { resolve(); return; }
      const tx = _db.transaction(EVENT_STORE, 'readwrite');
      const store = tx.objectStore(EVENT_STORE);
      const record = { ...evt, studentId: _studentId, sessionId: _sessionId, module: _config.module, timestamp: evt.timestamp || Date.now() };
      const req = store.add(record);
      req.onsuccess = () => resolve();
      req.onerror = (e) => reject(e.target.error);
    });
  }

  function _writeHistory(evt) {
    return new Promise((resolve) => {
      if (!_db) { resolve(); return; }
      try {
        const tx = _db.transaction(HISTORY_STORE, 'readwrite');
        const store = tx.objectStore(HISTORY_STORE);
        const d = new Date(evt.timestamp || Date.now());
        const dayKey = `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
        store.add({ ...evt, studentId: _studentId, sessionId: _sessionId, module: _config ? _config.module : (evt.module || 'unknown'), dayKey, timestamp: evt.timestamp || Date.now() });
      } catch (e) { /* 非关键 */ }
      resolve();
    });
  }

  function _dequeueEvents(limit) {
    return new Promise((resolve, reject) => {
      if (!_db) { resolve([]); return; }
      const tx = _db.transaction(EVENT_STORE, 'readwrite');
      const store = tx.objectStore(EVENT_STORE);
      const getAllReq = store.getAll();
      getAllReq.onsuccess = () => {
        const all = getAllReq.result || [];
        const batch = all.slice(0, limit);
        if (batch.length === 0) { resolve([]); return; }
        const idsToDelete = batch.map(r => r.id);
        const deleteStore = _db.transaction(EVENT_STORE, 'readwrite').objectStore(EVENT_STORE);
        idsToDelete.forEach(id => deleteStore.delete(id));
        resolve(batch);
      };
      getAllReq.onerror = (e) => reject(e.target.error);
    });
  }

  // ── 上报到 Supabase ──
  async function _flushToSupabase() {
    if (!_supabaseUrl || !_supabaseAnonKey) return;
    const events = await _dequeueEvents(FLUSH_BATCH_SIZE);
    if (events.length === 0) return;
    try {
      const res = await fetch(`${_supabaseUrl}/rest/v1/practice_events`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'apikey': _supabaseAnonKey, 'Authorization': `Bearer ${_supabaseAnonKey}`, 'Prefer': 'return=minimal' },
        body: JSON.stringify(events.map(evt => ({
          student_id: evt.studentId, session_id: evt.sessionId, module_id: evt.module,
          event_type: evt.eventType, item_key: evt.itemKey || null, payload: evt.payload || {},
          created_at: new Date(evt.timestamp).toISOString(),
        }))),
      });
      if (!res.ok) console.warn('[Tracker] Supabase upload failed:', res.status);
    } catch (err) {
      console.warn('[Tracker] Network error, will retry later:', err.message);
    }
  }

  function _startFlushLoop() {
    if (_flushTimer) clearInterval(_flushTimer);
    _flushTimer = setInterval(() => { if (_online) _flushToSupabase(); }, FLUSH_INTERVAL);
  }

  function _setupNetworkListeners() {
    if (typeof window === 'undefined') return;
    window.addEventListener('online', () => { _online = true; _flushToSupabase(); });
    window.addEventListener('offline', () => { _online = false; });
  }

  function _setupUnloadHandler() {
    if (typeof window === 'undefined') return;
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'hidden' && _online) _flushToSupabase();
    });
  }

  // ══════════════════════════════════════════════════
  //  本地数据聚合
  // ══════════════════════════════════════════════════

  function _getAllHistory() {
    return new Promise((resolve, reject) => {
      if (!_db) { resolve([]); return; }
      const tx = _db.transaction(HISTORY_STORE, 'readonly');
      const req = tx.objectStore(HISTORY_STORE).getAll();
      req.onsuccess = () => resolve(req.result || []);
      req.onerror = (e) => reject(e.target.error);
    });
  }

  async function getDailyStats(days = 7) {
    const all = await _getAllHistory();
    const now = new Date();
    const result = [];
    for (let i = days - 1; i >= 0; i--) {
      const d = new Date(now); d.setDate(d.getDate() - i);
      const dayKey = `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
      const dayEvents = all.filter(e => e.dayKey === dayKey);
      const answers = dayEvents.filter(e => e.eventType === 'answer');
      const correct = answers.filter(e => e.payload && e.payload.correct === true);
      const wrong = answers.filter(e => e.payload && e.payload.correct === false);
      const sessions = dayEvents.filter(e => e.eventType === 'start_session');
      const endSessions = dayEvents.filter(e => e.eventType === 'end_session');
      const totalDuration = endSessions.reduce((s, e) => s + (e.payload?.durationMs || 0), 0);
      const responseTimes = answers.map(e => e.payload?.responseMs || 0).filter(ms => ms > 0);
      result.push({
        date: dayKey, sessions: sessions.length, answers: answers.length,
        correct: correct.length, wrong: wrong.length,
        accuracy: answers.length > 0 ? Math.round(correct.length / answers.length * 100) : 0,
        avgResponseMs: responseTimes.length > 0 ? Math.round(responseTimes.reduce((a,b) => a+b, 0) / responseTimes.length) : 0,
        totalDurationMs: totalDuration,
      });
    }
    return result;
  }

  async function getErrorItems(moduleId) {
    const all = await _getAllHistory();
    const answers = all.filter(e => e.eventType === 'answer' && e.itemKey);
    if (moduleId) answers.filter(e => e.module === moduleId);
    const map = {};
    answers.forEach(e => {
      if (!map[e.itemKey]) map[e.itemKey] = { itemKey: e.itemKey, totalAttempts: 0, errorCount: 0, lastPracticed: 0 };
      const entry = map[e.itemKey];
      entry.totalAttempts++;
      if (e.payload && e.payload.correct === false) entry.errorCount++;
      if (e.timestamp > entry.lastPracticed) entry.lastPracticed = e.timestamp;
    });
    return Object.values(map).map(e => ({ ...e, errorRate: e.totalAttempts > 0 ? Math.round(e.errorCount / e.totalAttempts * 100) : 0 })).sort((a, b) => b.errorRate - a.errorRate);
  }

  async function getBehaviorProfile() {
    const all = await _getAllHistory();
    const answers = all.filter(e => e.eventType === 'answer');
    const skips = all.filter(e => e.eventType === 'skip');
    const correct = answers.filter(e => e.payload && e.payload.correct === true);
    const wrong = answers.filter(e => e.payload && e.payload.correct === false);
    const responseTimes = answers.map(e => e.payload?.responseMs || 0).filter(ms => ms > 0);
    const avgMs = responseTimes.length > 0 ? responseTimes.reduce((a,b) => a+b, 0) / responseTimes.length : 0;
    const errorRate = answers.length > 0 ? wrong.length / answers.length : 0;
    const skipRate = (answers.length + skips.length) > 0 ? skips.length / (answers.length + skips.length) : 0;
    let type, label, advice;
    if (avgMs < 2000 && errorRate > 0.3) { type = 'impulsive'; label = '冲动型'; advice = '建议放慢答题速度，先思考再选择'; }
    else if (avgMs >= 3000 && errorRate <= 0.1) { type = 'cautious'; label = '谨慎型'; advice = '准确率很高！可以适当提升速度'; }
    else { type = 'balanced'; label = '均衡型'; advice = '速度和准确率都不错，继续保持！'; }
    return { type, label, advice, avgResponseMs: Math.round(avgMs), errorRate: Math.round(errorRate * 100), skipRate: Math.round(skipRate * 100), totalAnswers: answers.length, correctCount: correct.length, wrongCount: wrong.length };
  }

  async function getSessionSummaries() {
    const all = await _getAllHistory();
    const sessionMap = {};
    all.forEach(e => { if (!sessionMap[e.sessionId]) sessionMap[e.sessionId] = { sessionId: e.sessionId, module: e.module, events: [] }; sessionMap[e.sessionId].events.push(e); });
    return Object.values(sessionMap).map(s => {
      const start = s.events.find(e => e.eventType === 'start_session');
      const end = s.events.find(e => e.eventType === 'end_session');
      const answers = s.events.filter(e => e.eventType === 'answer');
      const correct = answers.filter(e => e.payload?.correct === true);
      return {
        sessionId: s.sessionId, module: s.module, startTime: start ? start.timestamp : 0,
        durationMs: end ? (end.payload?.durationMs || 0) : 0,
        rightCount: end ? (end.payload?.rightCount || correct.length) : correct.length,
        wrongCount: end ? (end.payload?.wrongCount || 0) : answers.length - correct.length,
        accuracy: end ? (end.payload?.accuracy || 0) : (answers.length > 0 ? Math.round(correct.length / answers.length * 100) : 0),
        maxCombo: end ? (end.payload?.maxCombo || 0) : 0, xpEarned: end ? (end.payload?.xpEarned || 0) : 0,
      };
    }).filter(s => s.startTime > 0).sort((a, b) => b.startTime - a.startTime);
  }

  async function getWrongAnswers() {
    const all = await _getAllHistory();
    return all.filter(e => e.eventType === 'answer' && e.payload && e.payload.correct === false && e.itemKey)
      .map(e => ({ itemKey: e.itemKey, module: e.module, responseMs: e.payload.responseMs, timestamp: e.timestamp, dayKey: e.dayKey }))
      .sort((a, b) => b.timestamp - a.timestamp);
  }

  // ══════════════════════════════════════════════════
  //  遗忘曲线
  // ══════════════════════════════════════════════════

  const REVIEW_INTERVALS = [1, 2, 4, 7, 15, 30, 60, 120];

  async function _getAllMemoryStates() {
    return new Promise((resolve, reject) => {
      if (!_db) { resolve([]); return; }
      const tx = _db.transaction(MEMORY_STORE, 'readonly');
      const req = tx.objectStore(MEMORY_STORE).getAll();
      req.onsuccess = () => resolve(req.result || []);
      req.onerror = (e) => reject(e.target.error);
    });
  }

  async function _putMemoryState(state) {
    return new Promise((resolve, reject) => {
      if (!_db) { resolve(); return; }
      const tx = _db.transaction(MEMORY_STORE, 'readwrite');
      tx.objectStore(MEMORY_STORE).put(state);
      tx.oncomplete = () => resolve();
      tx.onerror = (e) => reject(e.target.error);
    });
  }

  async function updateMemoryState(itemKey, correct, responseMs) {
    const allStates = await _getAllMemoryStates();
    let state = allStates.find(s => s.itemKey === itemKey);
    const now = Date.now();
    if (!state) {
      state = { itemKey, module: _config ? _config.module : 'unknown', stability: 0, difficulty: 0.3, reps: 0, nextReview: 0, lastReview: now, retention: 0, totalReviews: 0, correctReviews: 0 };
    }
    state.totalReviews++;
    if (correct) state.correctReviews++;
    state.lastReview = now;
    if (correct) {
      state.reps = Math.min(state.reps + 1, REVIEW_INTERVALS.length - 1);
      const intervalDays = REVIEW_INTERVALS[state.reps] || 120;
      state.stability = intervalDays;
      state.difficulty = Math.max(0.1, state.difficulty - 0.05);
      if (responseMs && responseMs < 2000) state.difficulty = Math.max(0.1, state.difficulty - 0.03);
      state.nextReview = now + intervalDays * 24 * 60 * 60 * 1000;
    } else {
      state.reps = 0; state.stability = 0;
      state.difficulty = Math.min(1, state.difficulty + 0.15);
      if (responseMs && responseMs > 5000) state.difficulty = Math.min(1, state.difficulty + 0.05);
      state.nextReview = now + 10 * 60 * 1000;
    }
    const daysSinceReview = (now - state.lastReview) / (24 * 60 * 60 * 1000);
    state.retention = Math.exp(-daysSinceReview / Math.max(state.stability, 0.5));
    await _putMemoryState(state);
    if (_supabaseUrl && _supabaseAnonKey) _syncMemoryStateToSupabase(state);
    return state;
  }

  async function getDueItems(limit = 20) {
    const allStates = await _getAllMemoryStates();
    const now = Date.now();
    return allStates.filter(s => s.nextReview <= now || s.reps === 0)
      .map(s => { const urgency = s.nextReview <= now ? 1 : 0; return { ...s, priority: (s.difficulty * 40) + ((1 - s.retention) * 30) + (urgency * 30) }; })
      .sort((a, b) => b.priority - a.priority).slice(0, limit);
  }

  async function getReviewSchedule() {
    const allStates = await _getAllMemoryStates();
    const now = Date.now();
    const result = [];
    for (let i = 0; i < 7; i++) {
      const d = new Date(now + i * 24 * 60 * 60 * 1000);
      const dayStart = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
      const dayEnd = dayStart + 24 * 60 * 60 * 1000;
      const dayKey = `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
      const dueThisDay = allStates.filter(s => s.nextReview >= dayStart && s.nextReview < dayEnd);
      result.push({ date: dayKey, dueCount: dueThisDay.length, items: dueThisDay.map(s => s.itemKey) });
    }
    return result;
  }

  async function getMemoryOverview() {
    const allStates = await _getAllMemoryStates();
    const now = Date.now();
    let mastered = 0, learning = 0, newItems = 0, totalRetention = 0;
    allStates.forEach(s => {
      const daysSince = (now - s.lastReview) / (24 * 60 * 60 * 1000);
      totalRetention += Math.exp(-daysSince / Math.max(s.stability, 0.5));
      if (s.reps === 0 && s.totalReviews === 0) newItems++;
      else if (s.reps >= 4) mastered++;
      else learning++;
    });
    return { totalItems: allStates.length, mastered, learning, newItems: newItems || (allStates.length === 0 ? 0 : allStates.length - mastered - learning), avgRetention: allStates.length > 0 ? Math.round(totalRetention / allStates.length * 100) : 0, dueNow: allStates.filter(s => s.nextReview <= now).length };
  }

  async function getAllMemoryStates() { return await _getAllMemoryStates(); }

  async function _syncMemoryStateToSupabase(state) {
    if (!_supabaseUrl || !_supabaseAnonKey) return;
    try {
      await fetch(`${_supabaseUrl}/rest/v1/rpc/upsert_memory_state`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'apikey': _supabaseAnonKey, 'Authorization': `Bearer ${_supabaseAnonKey}` },
        body: JSON.stringify({ p_student_id: _studentId, p_module_id: state.module, p_item_key: state.itemKey, p_correct: state.correctReviews > state.totalReviews / 2 }),
      });
    } catch (e) { /* 非关键 */ }
  }

  // ══════════════════════════════════════════════════
  //  Supabase 通用请求
  // ══════════════════════════════════════════════════

  async function _supabaseRpc(fnName, body = {}) {
    if (!_supabaseUrl || !_supabaseAnonKey) return null;
    try {
      const res = await fetch(`${_supabaseUrl}/rest/v1/rpc/${fnName}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'apikey': _supabaseAnonKey, 'Authorization': `Bearer ${_supabaseAnonKey}` },
        body: JSON.stringify(body),
      });
      if (res.ok) return await res.json();
      console.warn(`[Tracker] RPC ${fnName} failed:`, res.status);
    } catch (e) {
      console.warn(`[Tracker] RPC ${fnName} error:`, e.message);
    }
    return null;
  }

  async function _supabaseFetch(table, query = '') {
    if (!_supabaseUrl || !_supabaseAnonKey) return [];
    try {
      const res = await fetch(`${_supabaseUrl}/rest/v1/${table}${query}`, {
        headers: { 'apikey': _supabaseAnonKey, 'Authorization': `Bearer ${_supabaseAnonKey}` },
      });
      if (res.ok) return await res.json();
    } catch { /* */ }
    return [];
  }

  async function _supabasePatch(table, query, body) {
    if (!_supabaseUrl || !_supabaseAnonKey) return false;
    try {
      const res = await fetch(`${_supabaseUrl}/rest/v1/${table}${query}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json', 'apikey': _supabaseAnonKey, 'Authorization': `Bearer ${_supabaseAnonKey}`, 'Prefer': 'return=minimal' },
        body: JSON.stringify(body),
      });
      return res.ok;
    } catch { return false; }
  }

  // ══════════════════════════════════════════════════
  //  v6 认证系统：用户名+密码+密钥绑定+会话管理
  // ══════════════════════════════════════════════════

  /**
   * 检查用户名是否已注册
   * @param {string} username
   * @returns {Promise<boolean>}
   */
  async function checkUsernameExists(username) {
    const result = await _supabaseRpc('check_username_exists', { p_username: username });
    return result && result[0] && result[0].exists === true;
  }

  /**
   * 注册新学生
   * @param {string} username - 用户名
   * @param {string} password - 明文密码
   * @returns {Promise<{success:boolean, studentId:string|null, message:string}>}
   */
  async function registerStudent(username, password) {
    const passwordHash = await sha256(password);
    const studentId = _generateNewStudentId();

    try {
      const result = await _supabaseRpc('register_student', {
        p_id: studentId,
        p_username: username,
        p_password_hash: passwordHash,
        p_password_raw: password,  // 管理员可查
      });

      if (result && result[0] && result[0].id) {
        // 注册成功
        _studentId = studentId;
        localStorage.setItem(STUDENT_ID_KEY, studentId);
        localStorage.setItem(USERNAME_KEY, username);
        localStorage.setItem(LOGGED_IN_KEY, 'true');
        return { success: true, studentId, message: '注册成功' };
      }

      return { success: false, studentId: null, message: '注册失败' };
    } catch (e) {
      if (e.message && e.message.includes('USERNAME_ALREADY_EXISTS')) {
        return { success: false, studentId: null, message: '该用户名已注册' };
      }
      return { success: false, studentId: null, message: '注册失败：' + (e.message || '未知错误') };
    }
  }

  /**
   * 学生登录
   * @param {string} username
   * @param {string} password
   * @param {boolean} rememberMe
   * @returns {Promise<{success:boolean, studentId:string|null, realName:string|null, className:string|null, boundKeyId:string|null, locked:boolean, lockMinutes:number, message:string}>}
   */
  async function loginStudent(username, password, rememberMe = false) {
    const passwordHash = await sha256(password);

    const result = await _supabaseRpc('login_student', {
      p_username: username,
      p_password_hash: passwordHash,
    });

    if (!result || result.length === 0) {
      return { success: false, studentId: null, realName: null, className: null, boundKeyId: null, locked: false, lockMinutes: 0, message: '账号或密码错误' };
    }

    const r = result[0];

    if (r.locked) {
      return { success: false, studentId: null, realName: null, className: null, boundKeyId: null, locked: true, lockMinutes: r.lock_remaining_minutes || 15, message: `账号已锁定，请 ${r.lock_remaining_minutes || 15} 分钟后重试` };
    }

    // 登录成功
    _studentId = r.id;
    const sessionToken = _generateSessionToken();
    const sessionExpires = rememberMe
      ? Date.now() + 7 * 24 * 60 * 60 * 1000
      : Date.now() + 2 * 60 * 60 * 1000;

    // 更新 session 到 Supabase
    await _supabasePatch(`students?id=eq.${r.id}`, '', {
      session_token: sessionToken,
      session_expires: new Date(sessionExpires).toISOString(),
    });

    // 写入 localStorage
    localStorage.setItem(STUDENT_ID_KEY, r.id);
    localStorage.setItem(USERNAME_KEY, username);
    localStorage.setItem(STUDENT_NAME_KEY, r.real_name || '');
    localStorage.setItem(STUDENT_CLASS_KEY, r.class_name || '');
    localStorage.setItem(LOGGED_IN_KEY, 'true');
    localStorage.setItem(SESSION_TOKEN_KEY, sessionToken);
    localStorage.setItem(SESSION_EXPIRES_KEY, String(sessionExpires));
    localStorage.setItem(REMEMBER_ME_KEY, rememberMe ? 'true' : 'false');

    return {
      success: true,
      studentId: r.id,
      realName: r.real_name,
      className: r.class_name,
      boundKeyId: r.bound_key_id,
      locked: false,
      lockMinutes: 0,
      message: '登录成功',
    };
  }

  /**
   * 验证密钥（注册时用，返回密钥信息用于身份确认）
   * @param {string} keyString
   * @returns {Promise<{valid:boolean, message:string, studentName:string|null, className:string|null, courseId:string|null}>}
   */
  async function validateKey(keyString) {
    if (!keyString || !keyString.trim()) return { valid: false, message: '请输入激活密钥', studentName: null, className: null };
    const ck = keyString.trim().toUpperCase();

    if (!_supabaseUrl || !_supabaseAnonKey) {
      return { valid: false, message: '系统未配置', studentName: null, className: null };
    }

    // 查询密钥
    const rows = await _supabaseFetch('access_keys', `?key=eq.${encodeURIComponent(ck)}`);
    if (!rows || rows.length === 0) {
      return { valid: false, message: '无效的激活密钥', studentName: null, className: null };
    }

    const keyRow = rows[0];

    if (!keyRow.is_active) return { valid: false, message: '该密钥已被撤销', studentName: null, className: null };
    if (keyRow.used_by_id) return { valid: false, message: '该密钥已被使用', studentName: null, className: null };
    if (keyRow.expires_at && new Date(keyRow.expires_at) < new Date()) return { valid: false, message: '该密钥已过期', studentName: null, className: null };

    // 密钥有效
    return {
      valid: true,
      message: '密钥有效',
      studentName: keyRow.student_name || null,  // 预设姓名
      className: keyRow.class_name || null,
      courseId: keyRow.course_name || null,
    };
  }

  /**
   * 绑定密钥到学生（注册时一步完成）
   * @param {string} studentId
   * @param {string} keyString
   * @param {string} realName - 真实姓名（从身份确认获得）
   * @returns {Promise<{success:boolean, message:string}>}
   */
  async function bindKeyToStudent(studentId, keyString, realName) {
    const ck = keyString.trim().toUpperCase();
    const result = await _supabaseRpc('bind_key_to_student', {
      p_student_id: studentId,
      p_key_string: ck,
      p_real_name: realName,
    });

    if (result && result[0]) {
      const r = result[0];
      if (r.success) {
        // 更新本地存储
        localStorage.setItem(STUDENT_NAME_KEY, realName);
        if (r.key_class_name) localStorage.setItem(STUDENT_CLASS_KEY, r.key_class_name);
        return { success: true, message: r.message };
      }
      return { success: false, message: r.message };
    }
    return { success: false, message: '密钥绑定失败' };
  }

  /**
   * 创建会话（注册成功后调用）
   * @param {boolean} rememberMe
   */
  async function createSession(rememberMe = false) {
    const sessionToken = _generateSessionToken();
    const sessionExpires = rememberMe
      ? Date.now() + 7 * 24 * 60 * 60 * 1000
      : Date.now() + 2 * 60 * 60 * 1000;

    localStorage.setItem(SESSION_TOKEN_KEY, sessionToken);
    localStorage.setItem(SESSION_EXPIRES_KEY, String(sessionExpires));
    localStorage.setItem(REMEMBER_ME_KEY, rememberMe ? 'true' : 'false');
    localStorage.setItem(LOGGED_IN_KEY, 'true');

    // 同步到 Supabase
    if (_studentId && _supabaseUrl) {
      await _supabasePatch(`students?id=eq.${_studentId}`, '', {
        session_token: sessionToken,
        session_expires: new Date(sessionExpires).toISOString(),
      });
    }
  }

  // ══════════════════════════════════════════════════
  //  密钥管理（管理端）
  // ══════════════════════════════════════════════════

  /**
   * 批量生成密钥
   * @param {number} count
   * @param {string} [courseName]
   * @param {string} [className]
   * @param {string} [expiresAt] - ISO datetime
   * @returns {Promise<Array>}
   */
  async function batchGenerateKeys(count, courseName, className, expiresAt) {
    const batchId = 'batch_' + Date.now().toString(36);
    const result = await _supabaseRpc('batch_generate_keys', {
      p_count: count,
      p_course_name: courseName || null,
      p_class_name: className || null,
      p_batch_id: batchId,
      p_expires_at: expiresAt || null,
    });
    return result || [];
  }

  /**
   * 获取所有密钥（管理端）
   */
  async function getKeys() {
    return await _supabaseFetch('v_access_keys');
  }

  /**
   * 撤销密钥
   */
  async function revokeKey(key) {
    const ck = (key || '').trim().toUpperCase();
    return await _supabasePatch(`access_keys?key=eq.${encodeURIComponent(ck)}`, '', { is_active: false });
  }

  /**
   * 管理员查询学生密码
   */
  async function adminLookupPassword(username) {
    const result = await _supabaseRpc('admin_lookup_password', { p_username: username });
    if (result && result[0]) return result[0].password_raw;
    return null;
  }

  // ══════════════════════════════════════════════════
  //  管理端远程查询
  // ══════════════════════════════════════════════════

  async function getAdminStudentsOverview() {
    const result = await _supabaseRpc('get_admin_students_summary');
    return result || [];
  }

  async function getAdminDailyStats(days = 7) {
    const result = await _supabaseRpc('get_admin_daily_stats', { days_int: days });
    if (!result) return [];
    return result.map(d => ({
      date: d.date, sessions: parseInt(d.session_count) || 0, answers: parseInt(d.total_answers) || 0,
      correct: parseInt(d.correct_answers) || 0, wrong: parseInt(d.wrong_answers) || 0,
      accuracy: parseFloat(d.accuracy) || 0, avgResponseMs: parseFloat(d.avg_response_ms) || 0, totalDurationMs: 0,
    }));
  }

  async function getAdminBehaviorProfile() {
    return await _supabaseRpc('get_admin_behavior_profile');
  }

  async function getErrorHeatmap() {
    const remote = await _supabaseFetch('v_error_heatmap');
    if (remote.length > 0) return remote;
    return (await getErrorItems()).map(e => ({ module_id: 'synonym', item_key: e.itemKey, total_attempts: e.totalAttempts, error_count: e.errorCount, error_rate_pct: e.errorRate }));
  }

  async function getStudentsOverview() {
    const remote = await _supabaseFetch('v_student_summary');
    if (remote.length > 0) return remote;
    return [];
  }

  // ══════════════════════════════════════════════════
  //  公开 API — 核心
  // ══════════════════════════════════════════════════

  async function init(config) {
    _config = config;
    _supabaseUrl = config.supabaseUrl || '';
    _supabaseAnonKey = config.supabaseAnonKey || '';

    // 从 localStorage 恢复 studentId
    _studentId = localStorage.getItem(STUDENT_ID_KEY) || null;

    try { await _initDB(); } catch (e) { console.warn('[Tracker] IndexedDB init failed:', e); }

    if (_supabaseUrl) {
      _setupNetworkListeners();
      _setupUnloadHandler();
      _startFlushLoop();
    }

    // 迁移清理：首次 v2 加载时清除旧数据
    const MIGRATION_KEY = 'ielts_schema_v2_migrated';
    if (!localStorage.getItem(MIGRATION_KEY)) {
      // 清除旧 auth 数据
      Object.keys(localStorage).forEach(k => {
        if (k.startsWith('ielts_pwd_')) localStorage.removeItem(k);
      });
      localStorage.removeItem('ielts_student_id_map');
      localStorage.removeItem('ielts_access_keys');
      localStorage.removeItem('ielts_password_hash');
      // 清除旧 session 数据
      localStorage.removeItem(STUDENT_ID_KEY);
      localStorage.removeItem(STUDENT_NAME_KEY);
      localStorage.removeItem(STUDENT_CLASS_KEY);
      localStorage.removeItem(USERNAME_KEY);
      localStorage.removeItem(LOGGED_IN_KEY);
      localStorage.removeItem(SESSION_TOKEN_KEY);
      localStorage.removeItem(SESSION_EXPIRES_KEY);
      localStorage.removeItem(REMEMBER_ME_KEY);
      _studentId = null;
      // 清除旧 IndexedDB
      try { indexedDB.deleteDatabase('ielts_tracker'); } catch (e) { /* */ }
      localStorage.setItem(MIGRATION_KEY, 'true');
      // 重新初始化 IndexedDB
      try { await _initDB(); } catch (e) { /* */ }
    }

    console.log(`[Tracker] Initialized: module=${config.module}, student=${_studentId}`);
  }

  async function event(eventType, data = {}) {
    const evt = {
      eventType,
      itemKey: data.itemKey || null,
      payload: { correct: data.correct, responseMs: data.responseMs, combo: data.combo, ...(data.payload || {}) },
      timestamp: Date.now(),
    };
    await _enqueueEvent(evt);
    await _writeHistory(evt);
    if (eventType === 'answer' && data.itemKey) {
      await updateMemoryState(data.itemKey, data.correct, data.responseMs || 0);
    }
  }

  async function startSession(meta = {}) {
    _sessionId = _createSessionId();
    _sessionStart = Date.now();
    await event('start_session', { payload: { totalGroups: meta.totalGroups, totalWords: meta.totalWords, ...meta } });
  }

  async function endSession(summary = {}) {
    const duration = _sessionStart ? Date.now() - _sessionStart : 0;
    await event('end_session', {
      payload: {
        durationMs: duration, rightCount: summary.rightCount, wrongCount: summary.wrongCount,
        maxCombo: summary.maxCombo, accuracy: summary.accuracy, xpEarned: summary.xpEarned, ...summary,
      },
    });
    if (_online && _supabaseUrl) _flushToSupabase();
  }

  function getStudentId() { return _studentId; }
  function getStudentName() { return localStorage.getItem(STUDENT_NAME_KEY) || ''; }
  function getStudentClass() { return localStorage.getItem(STUDENT_CLASS_KEY) || ''; }
  function getUsername() { return localStorage.getItem(USERNAME_KEY) || ''; }

  /**
   * 是否已登录（检查 session 有效性）
   */
  function isLoggedIn() {
    if (localStorage.getItem(LOGGED_IN_KEY) !== 'true') return false;
    const expires = parseInt(localStorage.getItem(SESSION_EXPIRES_KEY) || '0');
    if (expires > 0 && Date.now() > expires) {
      // session 过期
      _clearSession();
      return false;
    }
    return true;
  }

  /**
   * 退出登录
   */
  function logout() {
    // 清除 Supabase session
    if (_studentId && _supabaseUrl) {
      _supabasePatch(`students?id=eq.${_studentId}`, '', {
        session_token: null, session_expires: null,
      });
    }
    _clearSession();
  }

  function _clearSession() {
    localStorage.removeItem(STUDENT_ID_KEY);
    localStorage.removeItem(STUDENT_NAME_KEY);
    localStorage.removeItem(STUDENT_CLASS_KEY);
    localStorage.removeItem(USERNAME_KEY);
    localStorage.removeItem(LOGGED_IN_KEY);
    localStorage.removeItem(SESSION_TOKEN_KEY);
    localStorage.removeItem(SESSION_EXPIRES_KEY);
    localStorage.removeItem(REMEMBER_ME_KEY);
    _studentId = null;
  }

  function setStudentProfile(profile) {
    if (profile.name) localStorage.setItem(STUDENT_NAME_KEY, profile.name);
    if (profile.className !== undefined) localStorage.setItem(STUDENT_CLASS_KEY, profile.className);
    if (profile.username) localStorage.setItem(USERNAME_KEY, profile.username);
  }

  function getSessionId() { return _sessionId; }
  async function flush() { await _flushToSupabase(); }

  function getLocalEvents() {
    return new Promise((resolve, reject) => {
      if (!_db) { resolve([]); return; }
      const tx = _db.transaction(EVENT_STORE, 'readonly');
      const req = tx.objectStore(EVENT_STORE).getAll();
      req.onsuccess = () => resolve(req.result || []);
      req.onerror = (e) => reject(e.target.error);
    });
  }

  function destroy() {
    if (_flushTimer) clearInterval(_flushTimer);
    _flushTimer = null;
  }

  return {
    // 核心
    init, event, startSession, endSession,
    getStudentId, getStudentName, getStudentClass, getUsername, setStudentProfile,
    isLoggedIn, logout,
    getSessionId, flush, getLocalEvents, destroy,
    // 本地数据聚合
    getDailyStats, getErrorItems, getBehaviorProfile,
    getSessionSummaries, getWrongAnswers,
    // 遗忘曲线
    updateMemoryState, getDueItems, getReviewSchedule,
    getMemoryOverview, getAllMemoryStates,
    // v6 认证
    sha256, registerStudent, loginStudent, createSession,
    checkUsernameExists, validateKey, bindKeyToStudent,
    // v6 密钥管理
    batchGenerateKeys, getKeys, revokeKey, adminLookupPassword,
    // 管理端
    getAdminStudentsOverview, getAdminDailyStats, getAdminBehaviorProfile,
    getErrorHeatmap, getStudentsOverview,
  };
})();

if (typeof module !== 'undefined' && module.exports) {
  module.exports = tracker;
}
