/**
 * IELTS Training Platform — Tracker SDK v3
 * 统一埋点 SDK，支持所有训练模块
 *
 * 用法：
 *   tracker.init({ module: 'synonym', supabaseUrl: '...', supabaseAnonKey: '...' })
 *   tracker.event('answer', { itemKey: 'successive/consecutive', correct: true, responseMs: 2300 })
 *   const stats = await tracker.getDailyStats()           // 本地聚合
 *   const errors = await tracker.getErrorItems()          // 错题统计
 *   const profile = await tracker.getBehaviorProfile()    // 行为画像
 *   const dueItems = await tracker.getDueItems()          // 待复习词组
 *   const schedule = await tracker.getReviewSchedule()    // 复习日程
 *
 * 离线安全：事件先写入 IndexedDB，批量上报到 Supabase
 * 自动生成 studentId（首次访问时创建，存储在 localStorage）
 * 遗忘曲线：基于艾宾浩斯间隔重复算法（SM-2 简化版）
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
  const DB_VERSION = 3;  // v3: 新增 memory_states store
  const EVENT_STORE = 'event_queue';
  const HISTORY_STORE = 'practice_history';
  const MEMORY_STORE = 'memory_states';  // v3: 遗忘曲线记忆状态
  const FLUSH_INTERVAL = 5000;
  const FLUSH_BATCH_SIZE = 50;
  const STUDENT_ID_KEY = 'ielts_student_id';
  const STUDENT_NAME_KEY = 'ielts_student_name';
  const STUDENT_CLASS_KEY = 'ielts_student_class';
  const SESSION_COUNTER_KEY = 'ielts_session_counter';
  const LOGGED_IN_KEY = 'ielts_logged_in';

  // ── Student ID 生成 ──
  function _getOrCreateStudentId() {
    let id = localStorage.getItem(STUDENT_ID_KEY);
    if (!id) {
      id = 'stu_' + Date.now().toString(36) + '_' + Math.random().toString(36).slice(2, 8);
      localStorage.setItem(STUDENT_ID_KEY, id);
    }
    return id;
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
        // 事件队列
        if (!db.objectStoreNames.contains(EVENT_STORE)) {
          const store = db.createObjectStore(EVENT_STORE, { keyPath: 'id', autoIncrement: true });
          store.createIndex('module', 'module', { unique: false });
          store.createIndex('timestamp', 'timestamp', { unique: false });
        }
        // 已上报的历史记录（永久保留在本地，用于离线查询）
        if (!db.objectStoreNames.contains(HISTORY_STORE)) {
          const store = db.createObjectStore(HISTORY_STORE, { keyPath: 'id', autoIncrement: true });
          store.createIndex('studentId', 'studentId', { unique: false });
          store.createIndex('module', 'module', { unique: false });
          store.createIndex('eventType', 'eventType', { unique: false });
          store.createIndex('timestamp', 'timestamp', { unique: false });
          store.createIndex('sessionId', 'sessionId', { unique: false });
          store.createIndex('dayKey', 'dayKey', { unique: false });
        }
        // v3: 遗忘曲线记忆状态
        if (!db.objectStoreNames.contains(MEMORY_STORE)) {
          const store = db.createObjectStore(MEMORY_STORE, { keyPath: 'itemKey' });
          store.createIndex('module', 'module', { unique: false });
          store.createIndex('nextReview', 'nextReview', { unique: false });
          store.createIndex('stability', 'stability', { unique: false });
        }
      };
      req.onsuccess = (e) => {
        _db = e.target.result;
        resolve(_db);
      };
      req.onerror = (e) => reject(e.target.error);
    });
  }

  // ── 写入事件到队列 ──
  function _enqueueEvent(evt) {
    return new Promise((resolve, reject) => {
      if (!_db) { resolve(); return; }
      const tx = _db.transaction(EVENT_STORE, 'readwrite');
      const store = tx.objectStore(EVENT_STORE);
      const record = {
        ...evt,
        studentId: _studentId,
        sessionId: _sessionId,
        module: _config.module,
        timestamp: evt.timestamp || Date.now(),
      };
      const req = store.add(record);
      req.onsuccess = () => resolve();
      req.onerror = (e) => reject(e.target.error);
    });
  }

  // ── 同时写入历史（永久保留） ──
  function _writeHistory(evt) {
    return new Promise((resolve) => {
      if (!_db) { resolve(); return; }
      try {
        const tx = _db.transaction(HISTORY_STORE, 'readwrite');
        const store = tx.objectStore(HISTORY_STORE);
        const d = new Date(evt.timestamp || Date.now());
        const dayKey = `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
        const record = {
          ...evt,
          studentId: _studentId,
          sessionId: _sessionId,
          module: _config ? _config.module : (evt.module || 'unknown'),
          dayKey,
          timestamp: evt.timestamp || Date.now(),
        };
        store.add(record);
      } catch (e) {
        // 历史写入失败不影响主流程
      }
      resolve();
    });
  }

  // ── 从队列取出待上报事件 ──
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
        headers: {
          'Content-Type': 'application/json',
          'apikey': _supabaseAnonKey,
          'Authorization': `Bearer ${_supabaseAnonKey}`,
          'Prefer': 'return=minimal',
        },
        body: JSON.stringify(events.map(evt => ({
          student_id: evt.studentId,
          session_id: evt.sessionId,
          module_id: evt.module,
          event_type: evt.eventType,
          item_key: evt.itemKey || null,
          payload: evt.payload || {},
          created_at: new Date(evt.timestamp).toISOString(),
        }))),
      });

      if (!res.ok) {
        console.warn('[Tracker] Supabase upload failed:', res.status);
      }
    } catch (err) {
      console.warn('[Tracker] Network error, will retry later:', err.message);
    }
  }

  // ── 定时 flush ──
  function _startFlushLoop() {
    if (_flushTimer) clearInterval(_flushTimer);
    _flushTimer = setInterval(() => {
      if (_online) _flushToSupabase();
    }, FLUSH_INTERVAL);
  }

  // ── 网络状态监听 ──
  function _setupNetworkListeners() {
    if (typeof window === 'undefined') return;
    window.addEventListener('online', () => {
      _online = true;
      _flushToSupabase();
    });
    window.addEventListener('offline', () => { _online = false; });
  }

  // ── 页面关闭前最后上报 ──
  function _setupUnloadHandler() {
    if (typeof window === 'undefined') return;
    window.addEventListener('beforeunload', () => { /* rely on interval flush */ });
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'hidden' && _online) { _flushToSupabase(); }
    });
  }

  // ══════════════════════════════════════════════════
  //  本地数据聚合（纯 IndexedDB 查询，不依赖 Supabase）
  // ══════════════════════════════════════════════════

  function _getAllHistory() {
    return new Promise((resolve, reject) => {
      if (!_db) { resolve([]); return; }
      const tx = _db.transaction(HISTORY_STORE, 'readonly');
      const store = tx.objectStore(HISTORY_STORE);
      const req = store.getAll();
      req.onsuccess = () => resolve(req.result || []);
      req.onerror = (e) => reject(e.target.error);
    });
  }

  /**
   * 获取每日学习统计
   * @param {number} [days=7] - 最近几天
   * @returns {Array<{date:string, sessions:number, answers:number, correct:number, wrong:number, accuracy:number, avgResponseMs:number, totalDurationMs:number}>}
   */
  async function getDailyStats(days = 7) {
    const all = await _getAllHistory();
    const now = new Date();
    const result = [];

    for (let i = days - 1; i >= 0; i--) {
      const d = new Date(now);
      d.setDate(d.getDate() - i);
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
        date: dayKey,
        sessions: sessions.length,
        answers: answers.length,
        correct: correct.length,
        wrong: wrong.length,
        accuracy: answers.length > 0 ? Math.round(correct.length / answers.length * 100) : 0,
        avgResponseMs: responseTimes.length > 0 ? Math.round(responseTimes.reduce((a,b) => a+b, 0) / responseTimes.length) : 0,
        totalDurationMs: totalDuration,
      });
    }
    return result;
  }

  /**
   * 获取错题统计（按 itemKey 聚合错误率）
   * @param {string} [moduleId] - 可选过滤模块
   * @returns {Array<{itemKey:string, totalAttempts:number, errorCount:number, errorRate:number, lastPracticed:number}>}
   */
  async function getErrorItems(moduleId) {
    const all = await _getAllHistory();
    const answers = all.filter(e => e.eventType === 'answer' && e.itemKey);
    if (moduleId) answers.filter(e => e.module === moduleId);

    const map = {};
    answers.forEach(e => {
      if (!map[e.itemKey]) {
        map[e.itemKey] = { itemKey: e.itemKey, totalAttempts: 0, errorCount: 0, lastPracticed: 0 };
      }
      const entry = map[e.itemKey];
      entry.totalAttempts++;
      if (e.payload && e.payload.correct === false) entry.errorCount++;
      if (e.timestamp > entry.lastPracticed) entry.lastPracticed = e.timestamp;
    });

    return Object.values(map)
      .map(e => ({ ...e, errorRate: e.totalAttempts > 0 ? Math.round(e.errorCount / e.totalAttempts * 100) : 0 }))
      .sort((a, b) => b.errorRate - a.errorRate);
  }

  /**
   * 获取行为画像
   * @returns {{type:string, avgResponseMs:number, errorRate:number, skipRate:number, totalAnswers:number, label:string, advice:string}}
   */
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
    if (avgMs < 2000 && errorRate > 0.3) {
      type = 'impulsive'; label = '冲动型';
      advice = '建议放慢答题速度，先思考再选择，减少误答';
    } else if (avgMs >= 3000 && errorRate <= 0.1) {
      type = 'cautious'; label = '谨慎型';
      advice = '准确率很高！可以适当提升速度，挑战更高连击';
    } else {
      type = 'balanced'; label = '均衡型';
      advice = '速度和准确率都不错，继续保持！';
    }

    return {
      type, label, advice,
      avgResponseMs: Math.round(avgMs),
      errorRate: Math.round(errorRate * 100),
      skipRate: Math.round(skipRate * 100),
      totalAnswers: answers.length,
      correctCount: correct.length,
      wrongCount: wrong.length,
    };
  }

  /**
   * 获取所有会话摘要
   * @returns {Array<{sessionId:string, startTime:number, durationMs:number, rightCount:number, wrongCount:number, accuracy:number, maxCombo:number, module:string}>}
   */
  async function getSessionSummaries() {
    const all = await _getAllHistory();
    const sessionMap = {};

    all.forEach(e => {
      if (!sessionMap[e.sessionId]) {
        sessionMap[e.sessionId] = { sessionId: e.sessionId, module: e.module, events: [] };
      }
      sessionMap[e.sessionId].events.push(e);
    });

    return Object.values(sessionMap).map(s => {
      const start = s.events.find(e => e.eventType === 'start_session');
      const end = s.events.find(e => e.eventType === 'end_session');
      const answers = s.events.filter(e => e.eventType === 'answer');
      const correct = answers.filter(e => e.payload?.correct === true);

      return {
        sessionId: s.sessionId,
        module: s.module,
        startTime: start ? start.timestamp : 0,
        durationMs: end ? (end.payload?.durationMs || 0) : 0,
        rightCount: end ? (end.payload?.rightCount || correct.length) : correct.length,
        wrongCount: end ? (end.payload?.wrongCount || 0) : answers.length - correct.length,
        accuracy: end ? (end.payload?.accuracy || 0) : (answers.length > 0 ? Math.round(correct.length / answers.length * 100) : 0),
        maxCombo: end ? (end.payload?.maxCombo || 0) : 0,
        xpEarned: end ? (end.payload?.xpEarned || 0) : 0,
      };
    }).filter(s => s.startTime > 0).sort((a, b) => b.startTime - a.startTime);
  }

  /**
   * 获取错题本（所有答错的条目，按时间倒序）
   */
  async function getWrongAnswers() {
    const all = await _getAllHistory();
    return all
      .filter(e => e.eventType === 'answer' && e.payload && e.payload.correct === false && e.itemKey)
      .map(e => ({
        itemKey: e.itemKey,
        module: e.module,
        responseMs: e.payload.responseMs,
        timestamp: e.timestamp,
        dayKey: e.dayKey,
      }))
      .sort((a, b) => b.timestamp - a.timestamp);
  }

  // ══════════════════════════════════════════════════
  //  遗忘曲线：艾宾浩斯间隔重复算法（SM-2 简化版）
  // ══════════════════════════════════════════════════

  // 复习间隔（天）：1→2→4→7→15→30→60→∞
  const REVIEW_INTERVALS = [1, 2, 4, 7, 15, 30, 60, 120];

  /**
   * 获取记忆状态（从 IndexedDB memory_states store）
   * @returns {Array<{itemKey:string, module:string, stability:number, difficulty:number, reps:number, nextReview:number, lastReview:number, retention:number}>}
   */
  async function _getAllMemoryStates() {
    return new Promise((resolve, reject) => {
      if (!_db) { resolve([]); return; }
      const tx = _db.transaction(MEMORY_STORE, 'readonly');
      const store = tx.objectStore(MEMORY_STORE);
      const req = store.getAll();
      req.onsuccess = () => resolve(req.result || []);
      req.onerror = (e) => reject(e.target.error);
    });
  }

  /**
   * 写入/更新单个词组的记忆状态
   */
  async function _putMemoryState(state) {
    return new Promise((resolve, reject) => {
      if (!_db) { resolve(); return; }
      const tx = _db.transaction(MEMORY_STORE, 'readwrite');
      const store = tx.objectStore(MEMORY_STORE);
      store.put(state);
      tx.oncomplete = () => resolve();
      tx.onerror = (e) => reject(e.target.error);
    });
  }

  /**
   * 答题后更新记忆状态
   * @param {string} itemKey - 词组标识
   * @param {boolean} correct - 是否正确
   * @param {number} responseMs - 响应时间
   */
  async function updateMemoryState(itemKey, correct, responseMs) {
    const allStates = await _getAllMemoryStates();
    let state = allStates.find(s => s.itemKey === itemKey);

    const now = Date.now();

    if (!state) {
      // 新词组
      state = {
        itemKey,
        module: _config ? _config.module : 'unknown',
        stability: 0,      // 记忆稳定度（天）
        difficulty: 0.3,    // 难度系数 0~1
        reps: 0,            // 连续正确次数
        nextReview: 0,      // 下次复习时间戳
        lastReview: now,
        retention: 0,       // 记忆保持率 0~1
        totalReviews: 0,
        correctReviews: 0,
      };
    }

    state.totalReviews++;
    if (correct) state.correctReviews++;
    state.lastReview = now;

    if (correct) {
      // 正确：增加间隔
      state.reps = Math.min(state.reps + 1, REVIEW_INTERVALS.length - 1);
      const intervalDays = REVIEW_INTERVALS[state.reps] || 120;
      state.stability = intervalDays;
      // 难度降低
      state.difficulty = Math.max(0.1, state.difficulty - 0.05);
      // 响应时间快 → 额外加成
      if (responseMs && responseMs < 2000) {
        state.difficulty = Math.max(0.1, state.difficulty - 0.03);
      }
      state.nextReview = now + intervalDays * 24 * 60 * 60 * 1000;
    } else {
      // 错误：重置间隔
      state.reps = 0;
      state.stability = 0;
      state.difficulty = Math.min(1, state.difficulty + 0.15);
      // 响应时间慢 → 额外加难度
      if (responseMs && responseMs > 5000) {
        state.difficulty = Math.min(1, state.difficulty + 0.05);
      }
      // 10分钟后重新复习
      state.nextReview = now + 10 * 60 * 1000;
    }

    // 计算当前保持率（指数衰减模型）
    const daysSinceReview = (now - state.lastReview) / (24 * 60 * 60 * 1000);
    state.retention = Math.exp(-daysSinceReview / Math.max(state.stability, 0.5));

    await _putMemoryState(state);

    // 同步到 Supabase（如果有配置）
    if (_supabaseUrl && _supabaseAnonKey) {
      _syncMemoryStateToSupabase(state);
    }

    return state;
  }

  /**
   * 获取待复习词组（遗忘曲线到期 + 优先级排序）
   * @param {number} [limit=20] - 最多返回多少个
   * @returns {Array} 待复习词组列表
   */
  async function getDueItems(limit = 20) {
    const allStates = await _getAllMemoryStates();
    const now = Date.now();

    // 筛选到期或即将到期的词组
    const dueItems = allStates
      .filter(s => s.nextReview <= now || s.reps === 0)
      .map(s => {
        // 优先级：难度高 > 记忆保持率低 > 即将到期
        const urgency = s.nextReview <= now ? 1 : 0;
        const priority = (s.difficulty * 40) + ((1 - s.retention) * 30) + (urgency * 30);
        return { ...s, priority };
      })
      .sort((a, b) => b.priority - a.priority)
      .slice(0, limit);

    return dueItems;
  }

  /**
   * 获取复习日程（未来7天的预期复习量）
   * @returns {Array<{date:string, dueCount:number, items:Array}>}
   */
  async function getReviewSchedule() {
    const allStates = await _getAllMemoryStates();
    const now = Date.now();
    const result = [];

    for (let i = 0; i < 7; i++) {
      const d = new Date(now + i * 24 * 60 * 60 * 1000);
      const dayStart = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
      const dayEnd = dayStart + 24 * 60 * 60 * 1000;
      const dayKey = `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;

      const dueThisDay = allStates.filter(s =>
        s.nextReview >= dayStart && s.nextReview < dayEnd
      );

      result.push({
        date: dayKey,
        dueCount: dueThisDay.length,
        items: dueThisDay.map(s => s.itemKey),
      });
    }

    return result;
  }

  /**
   * 获取记忆状态概览（全局）
   * @returns {{totalItems:number, mastered:number, learning:number, newItems:number, avgRetention:number}}
   */
  async function getMemoryOverview() {
    const allStates = await _getAllMemoryStates();
    const now = Date.now();

    let mastered = 0, learning = 0, newItems = 0;
    let totalRetention = 0;

    allStates.forEach(s => {
      // 刷新保持率
      const daysSince = (now - s.lastReview) / (24 * 60 * 60 * 1000);
      const retention = Math.exp(-daysSince / Math.max(s.stability, 0.5));
      totalRetention += retention;

      if (s.reps === 0 && s.totalReviews === 0) newItems++;
      else if (s.reps >= 4) mastered++;
      else learning++;
    });

    return {
      totalItems: allStates.length,
      mastered,
      learning,
      newItems: newItems || (allStates.length === 0 ? 0 : allStates.length - mastered - learning),
      avgRetention: allStates.length > 0 ? Math.round(totalRetention / allStates.length * 100) : 0,
      dueNow: allStates.filter(s => s.nextReview <= now).length,
    };
  }

  /**
   * 获取所有记忆状态（用于可视化）
   */
  async function getAllMemoryStates() {
    return await _getAllMemoryStates();
  }

  /**
   * 同步记忆状态到 Supabase
   */
  async function _syncMemoryStateToSupabase(state) {
    if (!_supabaseUrl || !_supabaseAnonKey) return;
    try {
      await fetch(`${_supabaseUrl}/rest/v1/rpc/upsert_memory_state`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'apikey': _supabaseAnonKey,
          'Authorization': `Bearer ${_supabaseAnonKey}`,
        },
        body: JSON.stringify({
          p_student_id: _studentId,
          p_module_id: state.module,
          p_item_key: state.itemKey,
          p_stability: state.stability,
          p_difficulty: state.difficulty,
          p_reps: state.reps,
          p_next_review: new Date(state.nextReview).toISOString(),
        }),
      });
    } catch (e) { /* 非关键 */ }
  }

  // ══════════════════════════════════════════════════
  //  Supabase 远程查询（管理端使用）
  // ══════════════════════════════════════════════════

  async function _supabaseFetch(table, query = '') {
    if (!_supabaseUrl || !_supabaseAnonKey) return [];
    try {
      const res = await fetch(`${_supabaseUrl}/rest/v1/${table}${query}`, {
        headers: {
          'apikey': _supabaseAnonKey,
          'Authorization': `Bearer ${_supabaseAnonKey}`,
        },
      });
      if (!res.ok) return [];
      return await res.json();
    } catch { return []; }
  }

  /**
   * 管理端：获取所有学生概览
   * @returns {Array} 学生列表
   */
  async function getStudentsOverview() {
    // 先尝试从 Supabase 视图获取
    const remote = await _supabaseFetch('v_student_summary');
    if (remote.length > 0) return remote;
    // 降级：只返回当前本地学生
    const profile = await getBehaviorProfile();
    return [{
      student_id: _studentId,
      display_name: localStorage.getItem(STUDENT_NAME_KEY) || '未命名',
      class_name: localStorage.getItem(STUDENT_CLASS_KEY) || '',
      total_sessions: (await getSessionSummaries()).length,
      total_answers: profile.totalAnswers,
      correct_answers: profile.correctCount,
      accuracy_pct: 100 - profile.errorRate,
      avg_response_ms: profile.avgResponseMs,
      behavior_type: profile.type,
    }];
  }

  /**
   * 管理端：获取错题热力图
   */
  async function getErrorHeatmap() {
    const remote = await _supabaseFetch('v_error_heatmap');
    if (remote.length > 0) return remote;
    // 降级到本地
    return (await getErrorItems()).map(e => ({
      module_id: 'synonym',
      item_key: e.itemKey,
      total_attempts: e.totalAttempts,
      error_count: e.errorCount,
      error_rate_pct: e.errorRate,
    }));
  }

  // ══════════════════════════════════════════════════
  //  公开 API
  // ══════════════════════════════════════════════════

  /**
   * 初始化 tracker
   */
  async function init(config) {
    _config = config;
    _studentId = config.studentId || _getOrCreateStudentId();
    _supabaseUrl = config.supabaseUrl || '';
    _supabaseAnonKey = config.supabaseAnonKey || '';

    try { await _initDB(); } catch (e) {
      console.warn('[Tracker] IndexedDB init failed:', e);
    }

    if (_supabaseUrl) {
      _setupNetworkListeners();
      _setupUnloadHandler();
      _startFlushLoop();
    }

    // 注册/更新学生到 Supabase
    if (_supabaseUrl) {
      _registerStudent();
    }

    console.log(`[Tracker] Initialized: module=${config.module}, student=${_studentId}`);
  }

  async function _registerStudent() {
    if (!_supabaseUrl || !_supabaseAnonKey) return;
    try {
      await fetch(`${_supabaseUrl}/rest/v1/students`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'apikey': _supabaseAnonKey,
          'Authorization': `Bearer ${_supabaseAnonKey}`,
          'Prefer': 'resolution=merge-duplicates',
        },
        body: JSON.stringify({
          id: _studentId,
          display_name: localStorage.getItem(STUDENT_NAME_KEY) || '',
          class_name: localStorage.getItem(STUDENT_CLASS_KEY) || '',
          last_active: new Date().toISOString(),
        }),
      });
    } catch (e) { /* 非关键 */ }
  }

  /**
   * 记录一个事件
   */
  async function event(eventType, data = {}) {
    const evt = {
      eventType,
      itemKey: data.itemKey || null,
      payload: {
        correct: data.correct,
        responseMs: data.responseMs,
        combo: data.combo,
        ...(data.payload || {}),
      },
      timestamp: Date.now(),
    };

    await _enqueueEvent(evt);
    await _writeHistory(evt);

    // v3: 答题事件自动更新遗忘曲线
    if (eventType === 'answer' && data.itemKey) {
      await updateMemoryState(data.itemKey, data.correct, data.responseMs || 0);
    }
  }

  /**
   * 开始一个会话
   */
  async function startSession(meta = {}) {
    _sessionId = _createSessionId();
    _sessionStart = Date.now();
    await event('start_session', {
      payload: { totalGroups: meta.totalGroups, totalWords: meta.totalWords, ...meta },
    });
  }

  /**
   * 结束当前会话
   */
  async function endSession(summary = {}) {
    const duration = _sessionStart ? Date.now() - _sessionStart : 0;
    await event('end_session', {
      payload: {
        durationMs: duration, rightCount: summary.rightCount,
        wrongCount: summary.wrongCount, maxCombo: summary.maxCombo,
        accuracy: summary.accuracy, xpEarned: summary.xpEarned, ...summary,
      },
    });
    if (_online && _supabaseUrl) _flushToSupabase();
  }

  function getStudentId() { return _studentId; }
  function getStudentName() { return localStorage.getItem(STUDENT_NAME_KEY) || ''; }
  function getStudentClass() { return localStorage.getItem(STUDENT_CLASS_KEY) || ''; }

  /**
   * 更新学生身份信息（姓名、班级）
   * @param {{name?:string, className?:string}} profile
   */
  function setStudentProfile(profile) {
    if (profile.name) localStorage.setItem(STUDENT_NAME_KEY, profile.name);
    if (profile.className) localStorage.setItem(STUDENT_CLASS_KEY, profile.className);
    localStorage.setItem(LOGGED_IN_KEY, 'true');
    // 同步到 Supabase
    if (_supabaseUrl && _supabaseAnonKey) {
      _registerStudent();
    }
  }

  /**
   * 是否已登录
   */
  function isLoggedIn() {
    return localStorage.getItem(LOGGED_IN_KEY) === 'true'
      && !!localStorage.getItem(STUDENT_NAME_KEY)
      && !!localStorage.getItem(STUDENT_CLASS_KEY);
  }

  /**
   * 退出登录（清除身份信息，保留 studentId 和练习数据）
   */
  function logout() {
    localStorage.removeItem(STUDENT_NAME_KEY);
    localStorage.removeItem(STUDENT_CLASS_KEY);
    localStorage.removeItem(LOGGED_IN_KEY);
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

  // ── 密钥管理（第四期）──────────────────────────
  const KEY_STORE = 'ielts_access_keys';

  // 生成单个密钥字符串（格式：XXXX-XXXX-XXXX）
  function _genKey() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    let r = '';
    for (let i = 0; i < 12; i++) {
      if (i > 0 && i % 4 === 0) r += '-';
      r += chars[Math.floor(Math.random() * chars.length)];
    }
    return r;
  }

  /**
   * 生成密钥（管理端调用）
   * @param {number} [count=1]
   * @param {string} [studentName]
   * @param {string} [className]
   * @returns {Promise<Array>}
   */
  async function generateKeys(count = 1, studentName, className) {
    const keys = [];
    for (let i = 0; i < count; i++) {
      keys.push({
        key: _genKey(),
        student_name: studentName || null,
        class_name: className || null,
        used_by: null, used_by_id: null, used_at: null,
        is_active: true, created_at: new Date().toISOString(),
      });
    }
    // 尝试写入 Supabase
    if (_supabaseUrl && _supabaseAnonKey) {
      try {
        const res = await fetch(`${_supabaseUrl}/rest/v1/access_keys`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'apikey': _supabaseAnonKey,
            'Authorization': `Bearer ${_supabaseAnonKey}`,
            'Prefer': 'return=representation',
          },
          body: JSON.stringify(keys.map(k => ({
            key: k.key,
            student_name: k.student_name,
            class_name: k.class_name,
          }))),
        });
        if (res.ok) {
          console.log('[Tracker] Keys generated in Supabase:', keys.map(k => k.key));
          return await res.json();
        } else {
          const errText = await res.text();
          console.error('[Tracker] Supabase insert failed:', res.status, errText);
        }
      } catch (e) {
        console.error('[Tracker] Supabase network error:', e.message);
      }
    }
    // localStorage 降级
    let localKeys = [];
    try { localKeys = JSON.parse(localStorage.getItem(KEY_STORE) || '[]'); } catch (e) { localKeys = []; }
    const eK = new Set(localKeys.map(k => k.key));
    const nK = [];
    for (let i = 0; i < count; i++) {
      let n = keys[i].key;
      while (eK.has(n)) n = _genKey();
      eK.add(n);
      nK.push({ ...keys[i], key: n });
    }
    localKeys.push(...nK);
    localStorage.setItem(KEY_STORE, JSON.stringify(localKeys));
    return nK;
  }

  /**
   * 验证密钥（注册时调用）
   * @param {string} key
   * @param {string} [studentName]
   * @returns {Promise<{valid:boolean, message:string}>}
   */
  async function validateKey(key, studentName) {
    if (!key || !key.trim()) return { valid: false, message: '请输入激活密钥' };
    const ck = key.trim().toUpperCase();
    if (_supabaseUrl && _supabaseAnonKey) {
      try {
        let res = await fetch(
          `${_supabaseUrl}/rest/v1/access_keys?key=eq.${encodeURIComponent(ck)}&is_active=eq.true&used_by=is.null`,
          { headers: { 'apikey': _supabaseAnonKey, 'Authorization': `Bearer ${_supabaseAnonKey}` } }
        );
        if (res.ok) {
          const rows = await res.json();
          if (rows.length === 0) {
            res = await fetch(
              `${_supabaseUrl}/rest/v1/access_keys?key=eq.${encodeURIComponent(ck)}`,
              { headers: { 'apikey': _supabaseAnonKey, 'Authorization': `Bearer ${_supabaseAnonKey}` } }
            );
            if (res.ok) {
              const r = await res.json();
              if (r.length > 0) {
                if (r[0].used_by) {
                  return r[0].used_by === studentName
                    ? { valid: true, message: '该密钥已绑定此账号' }
                    : { valid: false, message: '该密钥已被使用' };
                }
                if (!r[0].is_active) return { valid: false, message: '该密钥已被撤销' };
              }
            }
            return { valid: false, message: '无效的激活密钥' };
          }
          if (rows[0].student_name && rows[0].student_name !== studentName) {
            return { valid: false, message: `该密钥预分配给「${rows[0].student_name}」，请用本人姓名注册` };
          }
          return { valid: true, message: '密钥有效' };
        }
      } catch (e) { /* 降级 */ }
    }
    // localStorage 降级
    let localKeys = [];
    try { localKeys = JSON.parse(localStorage.getItem(KEY_STORE) || '[]'); } catch (e) {
      return { valid: false, message: '密钥系统未初始化' };
    }
    const row = localKeys.find(k => k.key === ck);
    if (!row) return { valid: false, message: '无效的激活密钥' };
    if (!row.is_active) return { valid: false, message: '该密钥已被撤销' };
    if (row.used_by) {
      return row.used_by === studentName
        ? { valid: true, message: '该密钥已绑定此账号' }
        : { valid: false, message: '该密钥已被使用' };
    }
    if (row.student_name && row.student_name !== studentName) {
      return { valid: false, message: `该密钥预分配给「${row.student_name}」，请用本人姓名注册` };
    }
    return { valid: true, message: '密钥有效' };
  }

  /**
   * 使用密钥（注册成功后调用）
   * @param {string} key
   * @param {string} studentName
   * @param {string} studentId
   * @returns {Promise<boolean>}
   */
  async function consumeKey(key, studentName, studentId) {
    const ck = (key || '').trim().toUpperCase();
    if (!ck) return false;
    if (_supabaseUrl && _supabaseAnonKey) {
      try {
        const res = await fetch(
          `${_supabaseUrl}/rest/v1/access_keys?key=eq.${encodeURIComponent(ck)}`,
          {
            method: 'PATCH',
            headers: {
              'Content-Type': 'application/json',
              'apikey': _supabaseAnonKey,
              'Authorization': `Bearer ${_supabaseAnonKey}`,
              'Prefer': 'return=minimal',
            },
            body: JSON.stringify({
              used_by: studentName,
              used_by_id: studentId,
              used_at: new Date().toISOString(),
            }),
          }
        );
        if (res.ok) return true;
      } catch (e) { /* 降级 */ }
    }
    let localKeys = [];
    try { localKeys = JSON.parse(localStorage.getItem(KEY_STORE) || '[]'); } catch (e) { return false; }
    const idx = localKeys.findIndex(k => k.key === ck);
    if (idx === -1) return false;
    localKeys[idx].used_by = studentName;
    localKeys[idx].used_by_id = studentId;
    localKeys[idx].used_at = new Date().toISOString();
    localStorage.setItem(KEY_STORE, JSON.stringify(localKeys));
    return true;
  }

  /**
   * 获取所有密钥（管理端调用）
   * @returns {Promise<Array>}
   */
  async function getKeys() {
    if (_supabaseUrl && _supabaseAnonKey) {
      try {
        const res = await fetch(`${_supabaseUrl}/rest/v1/v_access_keys`, {
          headers: { 'apikey': _supabaseAnonKey, 'Authorization': `Bearer ${_supabaseAnonKey}` },
        });
        if (res.ok) return await res.json();
      } catch (e) { /* 降级 */ }
    }
    try { return JSON.parse(localStorage.getItem(KEY_STORE) || '[]'); } catch (e) { return []; }
  }

  /**
   * 撤销密钥（管理端调用）
   * @param {string} key
   * @returns {Promise<boolean>}
   */
  async function revokeKey(key) {
    const ck = (key || '').trim().toUpperCase();
    if (!ck) return false;
    if (_supabaseUrl && _supabaseAnonKey) {
      try {
        const res = await fetch(
          `${_supabaseUrl}/rest/v1/access_keys?key=eq.${encodeURIComponent(ck)}`,
          {
            method: 'PATCH',
            headers: {
              'Content-Type': 'application/json',
              'apikey': _supabaseAnonKey,
              'Authorization': `Bearer ${_supabaseAnonKey}`,
              'Prefer': 'return=minimal',
            },
            body: JSON.stringify({ is_active: false }),
          }
        );
        if (res.ok) return true;
      } catch (e) { /* 降级 */ }
    }
    let localKeys = [];
    try { localKeys = JSON.parse(localStorage.getItem(KEY_STORE) || '[]'); } catch (e) { return false; }
    const idx = localKeys.findIndex(k => k.key === ck);
    if (idx === -1) return false;
    localKeys[idx].is_active = false;
    localStorage.setItem(KEY_STORE, JSON.stringify(localKeys));
    return true;
  }

  return {
    init, event, startSession, endSession,
    getStudentId, getStudentName, getStudentClass, setStudentProfile,
    isLoggedIn, logout,
    getSessionId, flush, getLocalEvents, destroy,
    // v2: 本地数据聚合
    getDailyStats, getErrorItems, getBehaviorProfile,
    getSessionSummaries, getWrongAnswers,
    // v2: 远程查询（管理端）
    getStudentsOverview, getErrorHeatmap,
    // v3: 遗忘曲线
    updateMemoryState, getDueItems, getReviewSchedule,
    getMemoryOverview, getAllMemoryStates,
    // v4: 密钥管理
    generateKeys, validateKey, consumeKey, getKeys, revokeKey,
  };
})();

if (typeof module !== 'undefined' && module.exports) {
  module.exports = tracker;
}
