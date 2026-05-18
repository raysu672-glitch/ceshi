-- ============================================================
-- IELTS Training Platform — v2 完整 Schema
-- 用户名+密码登录 + 密钥绑定 + 会话管理
-- 直接复制全文到 Supabase SQL Editor 执行
-- ============================================================

-- ── 0. 清除旧数据（全新开始）──
DROP FUNCTION IF EXISTS get_admin_students_summary() CASCADE;
DROP FUNCTION IF EXISTS get_admin_students_profile() CASCADE;
DROP FUNCTION IF EXISTS get_admin_daily_stats(INT) CASCADE;
DROP FUNCTION IF EXISTS get_admin_behavior_profile() CASCADE;
DROP FUNCTION IF EXISTS get_admin_error_heatmap() CASCADE;
DROP FUNCTION IF EXISTS get_admin_memory_overview() CASCADE;
DROP FUNCTION IF EXISTS upsert_memory_state(TEXT, TEXT, TEXT, BOOLEAN) CASCADE;
DROP FUNCTION IF EXISTS register_student(TEXT, TEXT, TEXT, TEXT) CASCADE;
DROP FUNCTION IF EXISTS login_student(TEXT, TEXT) CASCADE;
DROP FUNCTION IF EXISTS bind_key_to_student(TEXT, TEXT, TEXT) CASCADE;
DROP FUNCTION IF EXISTS batch_generate_keys(INT, TEXT, TEXT, TEXT, TIMESTAMPTZ) CASCADE;
DROP FUNCTION IF EXISTS batch_generate_keys(INT, TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ) CASCADE;
DROP FUNCTION IF EXISTS check_username_exists(TEXT) CASCADE;
DROP FUNCTION IF EXISTS admin_lookup_password(TEXT) CASCADE;

DROP VIEW IF EXISTS v_student_summary CASCADE;
DROP VIEW IF EXISTS v_error_heatmap CASCADE;
DROP VIEW IF EXISTS v_behavior_profile CASCADE;
DROP VIEW IF EXISTS v_access_keys CASCADE;

DROP TABLE IF EXISTS practice_events CASCADE;
DROP TABLE IF EXISTS memory_states CASCADE;
DROP TABLE IF EXISTS access_keys CASCADE;
DROP TABLE IF EXISTS students CASCADE;
DROP TABLE IF EXISTS modules CASCADE;

-- ── 1. 模块注册表 ──
CREATE TABLE modules (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  description TEXT,
  icon        TEXT,
  version     TEXT DEFAULT '1.0.0',
  is_active   BOOLEAN DEFAULT true,
  created_at  TIMESTAMPTZ DEFAULT now()
);

INSERT INTO modules (id, name, description, icon) VALUES
  ('synonym', '同义替换大挑战', '雅思阅读同义替换词汇练习', ''),
  ('sentence', '长难句解析', '雅思长难句结构分析与翻译练习', '')
ON CONFLICT (id) DO NOTHING;

-- ── 2. 学生表（v2：用户名+密码+密钥绑定+会话+锁定） ──
CREATE TABLE students (
  id              TEXT PRIMARY KEY,            -- stu_xxx 自动生成
  username        TEXT UNIQUE NOT NULL,         -- 用户名（登录主键）
  password_hash   TEXT NOT NULL,               -- SHA-256 哈希
  password_raw    TEXT,                         -- 密码原文（管理员可查）
  real_name       TEXT,                         -- 真实姓名（密钥绑定时确认）
  class_name      TEXT,                         -- 班级/课程
  bound_key_id    UUID REFERENCES access_keys(id), -- 绑定的密钥 ID
  failed_attempts INT DEFAULT 0,               -- 登录失败计数
  locked_until    TIMESTAMPTZ,                  -- 锁定截止时间
  session_token   TEXT,                         -- 会话令牌
  session_expires TIMESTAMPTZ,                  -- 会话过期时间
  created_at      TIMESTAMPTZ DEFAULT now(),
  last_active     TIMESTAMPTZ
);

CREATE UNIQUE INDEX idx_students_username ON students(username);

-- ── 3. 访问密钥表（v2：新增课程/过期/批次） ──
CREATE TABLE access_keys (
  id           UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  key          TEXT UNIQUE NOT NULL,             -- XXXX-XXXX-XXXX
  student_name TEXT,                             -- 预设学生姓名
  class_name   TEXT,                             -- 预设班级
  course_name  TEXT,                             -- 课程名称
  expires_at   TIMESTAMPTZ,                      -- 过期时间
  batch_id     TEXT,                             -- 批次 ID
  used_by      TEXT,                             -- 使用者用户名
  used_by_id   TEXT,                             -- 使用者学生 ID
  used_at      TIMESTAMPTZ,                      -- 使用时间
  is_active    BOOLEAN DEFAULT true,
  created_at   TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_access_keys_key ON access_keys(key);
CREATE INDEX idx_access_keys_active ON access_keys(is_active) WHERE is_active = true;
CREATE INDEX idx_access_keys_batch ON access_keys(batch_id) WHERE batch_id IS NOT NULL;
CREATE INDEX idx_access_keys_course ON access_keys(course_name) WHERE course_name IS NOT NULL;

-- ── 4. 练习事件统一表 ──
CREATE TABLE practice_events (
  id          BIGSERIAL PRIMARY KEY,
  student_id  TEXT NOT NULL REFERENCES students(id) ON DELETE CASCADE,
  session_id  TEXT NOT NULL,
  module_id   TEXT NOT NULL REFERENCES modules(id),
  event_type  TEXT NOT NULL,
  item_key    TEXT,
  payload     JSONB DEFAULT '{}',
  created_at  TIMESTAMPTZ DEFAULT now(),

  CONSTRAINT valid_event_type CHECK (
    event_type IN ('answer', 'skip', 'start_session', 'end_session', 'hint_used', 'level_up')
  )
);

CREATE INDEX idx_events_student ON practice_events(student_id);
CREATE INDEX idx_events_session ON practice_events(session_id);
CREATE INDEX idx_events_module  ON practice_events(module_id);
CREATE INDEX idx_events_type    ON practice_events(event_type);
CREATE INDEX idx_events_item    ON practice_events(item_key) WHERE item_key IS NOT NULL;
CREATE INDEX idx_events_created ON practice_events(created_at DESC);

-- ── 5. 遗忘状态表 ──
CREATE TABLE memory_states (
  id             BIGSERIAL PRIMARY KEY,
  student_id     TEXT NOT NULL REFERENCES students(id) ON DELETE CASCADE,
  module_id      TEXT NOT NULL REFERENCES modules(id),
  item_key       TEXT NOT NULL,
  stability      REAL DEFAULT 1.0,
  retrievability REAL DEFAULT 1.0,
  last_practiced TIMESTAMPTZ,
  practice_count INT DEFAULT 0,
  correct_count  INT DEFAULT 0,
  created_at     TIMESTAMPTZ DEFAULT now(),
  updated_at     TIMESTAMPTZ DEFAULT now(),
  UNIQUE (student_id, module_id, item_key)
);

CREATE INDEX idx_memory_student ON memory_states(student_id);
CREATE INDEX idx_memory_due ON memory_states(retrievability) WHERE retrievability < 0.7;

-- ── 6. RLS 策略（全部放开，纯前端方案） ──
ALTER TABLE students ENABLE ROW LEVEL SECURITY;
CREATE POLICY students_all ON students FOR ALL USING (true) WITH CHECK (true);

ALTER TABLE practice_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY events_select ON practice_events FOR SELECT USING (true);
CREATE POLICY events_insert ON practice_events FOR INSERT WITH CHECK (true);

ALTER TABLE memory_states ENABLE ROW LEVEL SECURITY;
CREATE POLICY memory_select ON memory_states FOR SELECT USING (true);
CREATE POLICY memory_insert ON memory_states FOR INSERT WITH CHECK (true);
CREATE POLICY memory_update ON memory_states FOR UPDATE USING (true);

ALTER TABLE access_keys ENABLE ROW LEVEL SECURITY;
CREATE POLICY keys_all ON access_keys FOR ALL USING (true) WITH CHECK (true);

-- ── 7. 视图 ──

CREATE VIEW v_student_summary AS
SELECT
  s.id AS student_id,
  s.username,
  s.real_name,
  s.class_name,
  ak.key AS bound_key,
  ak.course_name AS bound_course,
  COUNT(DISTINCT e.session_id) AS total_sessions,
  COUNT(*) FILTER (WHERE e.event_type = 'answer') AS total_answers,
  COUNT(*) FILTER (WHERE e.event_type = 'answer' AND (e.payload->>'correct')::boolean = true) AS correct_answers,
  CASE WHEN COUNT(*) FILTER (WHERE e.event_type = 'answer') > 0
    THEN ROUND(
      COUNT(*) FILTER (WHERE e.event_type = 'answer' AND (e.payload->>'correct')::boolean = true)::numeric /
      COUNT(*) FILTER (WHERE e.event_type = 'answer') * 100, 1
    )
    ELSE 0
  END AS accuracy_pct,
  AVG((e.payload->>'responseMs')::int) FILTER (WHERE e.event_type = 'answer') AS avg_response_ms,
  GREATEST(MAX(e.created_at), s.last_active) AS last_active
FROM students s
LEFT JOIN practice_events e ON e.student_id = s.id
LEFT JOIN access_keys ak ON ak.id = s.bound_key_id
GROUP BY s.id, s.username, s.real_name, s.class_name, ak.key, ak.course_name;

CREATE VIEW v_error_heatmap AS
SELECT
  e.module_id,
  e.item_key,
  COUNT(*) AS total_attempts,
  COUNT(*) FILTER (WHERE (e.payload->>'correct')::boolean = false) AS error_count,
  CASE WHEN COUNT(*) > 0
    THEN ROUND(
      COUNT(*) FILTER (WHERE (e.payload->>'correct')::boolean = false)::numeric / COUNT(*) * 100, 1
    )
    ELSE 0
  END AS error_rate_pct
FROM practice_events e
WHERE e.event_type = 'answer'
GROUP BY e.module_id, e.item_key
ORDER BY error_rate_pct DESC;

CREATE VIEW v_behavior_profile AS
SELECT
  s.id AS student_id,
  s.real_name,
  COALESCE(COUNT(*) FILTER (WHERE e.event_type = 'answer'), 0) AS total_answers,
  ROUND(AVG((e.payload->>'responseMs')::numeric) FILTER (WHERE e.event_type = 'answer')) AS avg_response_ms,
  CASE WHEN COUNT(*) FILTER (WHERE e.event_type = 'answer') > 0
    THEN ROUND(
      COUNT(*) FILTER (WHERE e.event_type = 'answer' AND (e.payload->>'correct')::boolean = false)::numeric /
      COUNT(*) FILTER (WHERE e.event_type = 'answer') * 100, 1
    )
    ELSE 0
  END AS error_rate_pct,
  COALESCE(COUNT(*) FILTER (WHERE e.event_type = 'skip'), 0) AS skip_count,
  CASE
    WHEN COUNT(*) FILTER (WHERE e.event_type = 'answer') = 0 THEN NULL
    WHEN AVG((e.payload->>'responseMs')::numeric) FILTER (WHERE e.event_type = 'answer') < 2000
     AND COUNT(*) FILTER (WHERE e.event_type = 'answer' AND (e.payload->>'correct')::boolean = false)::numeric /
         NULLIF(COUNT(*) FILTER (WHERE e.event_type = 'answer'), 0) > 0.3
    THEN 'impulsive'
    WHEN AVG((e.payload->>'responseMs')::numeric) FILTER (WHERE e.event_type = 'answer') >= 3000
     AND COUNT(*) FILTER (WHERE e.event_type = 'answer' AND (e.payload->>'correct')::boolean = false)::numeric /
         NULLIF(COUNT(*) FILTER (WHERE e.event_type = 'answer'), 0) <= 0.1
    THEN 'cautious'
    ELSE 'balanced'
  END AS behavior_type
FROM students s
LEFT JOIN practice_events e ON e.student_id = s.id
GROUP BY s.id, s.real_name
ORDER BY s.real_name;

CREATE VIEW v_access_keys AS
SELECT
  id, key, student_name, class_name, course_name, expires_at, batch_id,
  used_by, used_by_id, used_at,
  is_active, created_at,
  CASE
    WHEN used_by_id IS NOT NULL THEN 'used'
    WHEN is_active = false THEN 'revoked'
    WHEN expires_at IS NOT NULL AND expires_at < now() THEN 'expired'
    ELSE 'unused'
  END AS status
FROM access_keys
ORDER BY created_at DESC;

-- ── 8. 遗忘曲线更新函数 ──
CREATE FUNCTION upsert_memory_state(
  p_student_id TEXT,
  p_module_id  TEXT,
  p_item_key   TEXT,
  p_correct    BOOLEAN
)
RETURNS VOID AS $$
DECLARE
  v_stability REAL;
  v_retrievability REAL;
  v_last TIMESTAMP;
  v_interval_days REAL;
BEGIN
  SELECT stability, retrievability, last_practiced
  INTO v_stability, v_retrievability, v_last
  FROM memory_states
  WHERE student_id = p_student_id AND module_id = p_module_id AND item_key = p_item_key;

  IF NOT FOUND THEN
    INSERT INTO memory_states (student_id, module_id, item_key, stability, retrievability, last_practiced, practice_count, correct_count)
    VALUES (p_student_id, p_module_id, p_item_key, 1.0, 1.0, now(), 1, CASE WHEN p_correct THEN 1 ELSE 0 END);
  ELSE
    v_interval_days := EXTRACT(EPOCH FROM (now() - v_last)) / 86400.0;
    v_retrievability := EXP(-v_interval_days / v_stability);
    IF p_correct THEN
      v_stability := v_stability * (1 + 0.3 * v_retrievability);
    ELSE
      v_stability := GREATEST(v_stability * 0.5, 0.5);
    END IF;
    UPDATE memory_states SET
      stability = v_stability,
      retrievability = v_stability,
      last_practiced = now(),
      practice_count = practice_count + 1,
      correct_count = correct_count + CASE WHEN p_correct THEN 1 ELSE 0 END,
      updated_at = now()
    WHERE student_id = p_student_id AND module_id = p_module_id AND item_key = p_item_key;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- ── 9. 注册函数（原子检查+插入） ──
CREATE FUNCTION register_student(
  p_id            TEXT,
  p_username      TEXT,
  p_password_hash TEXT,
  p_password_raw  TEXT
)
RETURNS TABLE(id TEXT, username TEXT) AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM students WHERE username = p_username) THEN
    RAISE EXCEPTION 'USERNAME_ALREADY_EXISTS';
  END IF;
  INSERT INTO students (id, username, password_hash, password_raw, created_at, last_active)
  VALUES (p_id, p_username, p_password_hash, p_password_raw, now(), now());
  RETURN QUERY SELECT p_id, p_username;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 10. 登录函数（密码验证+失败锁定） ──
CREATE OR REPLACE FUNCTION login_student(
  p_username      TEXT,
  p_password_hash TEXT
)
RETURNS TABLE(
  id TEXT,
  username TEXT,
  real_name TEXT,
  class_name TEXT,
  bound_key_id UUID,
  locked BOOLEAN,
  lock_remaining_minutes INT
) AS $$
DECLARE
  v_student students%ROWTYPE;
  v_locked BOOLEAN := false;
  v_remaining INT := 0;
BEGIN
  SELECT * INTO v_student FROM students WHERE students.username = p_username;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  -- 检查锁定
  IF v_student.locked_until IS NOT NULL AND v_student.locked_until > now() THEN
    v_locked := true;
    v_remaining := EXTRACT(EPOCH FROM (v_student.locked_until - now()))::INT / 60 + 1;
    RETURN QUERY SELECT
      v_student.id, v_student.username, v_student.real_name,
      v_student.class_name, v_student.bound_key_id,
      v_locked, v_remaining;
    RETURN;
  END IF;

  -- 锁定过期则解锁
  IF v_student.locked_until IS NOT NULL AND v_student.locked_until <= now() THEN
    UPDATE students SET failed_attempts = 0, locked_until = NULL WHERE students.id = v_student.id;
    v_student.failed_attempts := 0;
  END IF;

  -- 验证密码
  IF v_student.password_hash = p_password_hash THEN
    UPDATE students SET failed_attempts = 0, locked_until = NULL, last_active = now()
    WHERE students.id = v_student.id;
    RETURN QUERY SELECT
      v_student.id, v_student.username, v_student.real_name,
      v_student.class_name, v_student.bound_key_id,
      false, 0;
  ELSE
    UPDATE students SET failed_attempts = failed_attempts + 1 WHERE students.id = v_student.id;
    IF v_student.failed_attempts + 1 >= 5 THEN
      UPDATE students SET locked_until = now() + interval '15 minutes' WHERE students.id = v_student.id;
    END IF;
    RETURN;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 11. 密钥绑定函数 ──
CREATE FUNCTION bind_key_to_student(
  p_student_id TEXT,
  p_key_string TEXT,
  p_real_name  TEXT
)
RETURNS TABLE(success BOOLEAN, message TEXT, key_student_name TEXT, key_class_name TEXT) AS $$
DECLARE
  v_key access_keys%ROWTYPE;
BEGIN
  SELECT * INTO v_key FROM access_keys WHERE key = p_key_string;

  IF NOT FOUND THEN
    RETURN QUERY SELECT false, '无效的激活密钥'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF NOT v_key.is_active THEN
    RETURN QUERY SELECT false, '该密钥已被撤销'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF v_key.used_by_id IS NOT NULL THEN
    RETURN QUERY SELECT false, '该密钥已被使用'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF v_key.expires_at IS NOT NULL AND v_key.expires_at < now() THEN
    RETURN QUERY SELECT false, '该密钥已过期'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF EXISTS (SELECT 1 FROM students WHERE id = p_student_id AND bound_key_id IS NOT NULL) THEN
    RETURN QUERY SELECT false, '该账号已绑定密钥'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- 绑定密钥
  UPDATE access_keys SET
    used_by = (SELECT username FROM students WHERE id = p_student_id),
    used_by_id = p_student_id,
    used_at = now()
  WHERE id = v_key.id;

  -- 更新学生信息
  UPDATE students SET
    bound_key_id = v_key.id,
    real_name = p_real_name,
    class_name = COALESCE(v_key.class_name, v_key.course_name, class_name)
  WHERE id = p_student_id;

  RETURN QUERY SELECT true, '密钥绑定成功'::TEXT, v_key.student_name, v_key.class_name;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 12. 生成密钥（支持逐个/批量，含学生姓名） ──
-- 注意：使用 RETURNS TEXT 简单返回密钥字符串，避免 RETURNS TABLE 在 PostgREST RPC 中的兼容性问题
-- 客户端负责用 key 字段查询 access_keys 表获取完整对象
CREATE FUNCTION batch_generate_keys(
  p_count        INT,
  p_student_name TEXT DEFAULT NULL,
  p_course_name  TEXT DEFAULT NULL,
  p_class_name   TEXT DEFAULT NULL,
  p_batch_id     TEXT DEFAULT NULL,
  p_expires_at   TIMESTAMPTZ DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  i          INT;
  v_key_text TEXT;
BEGIN
  FOR i IN 1..p_count LOOP
    v_key_text :=
      upper(substring(md5(random()::text || clock_timestamp()::text) from 1 for 4))
      || '-' || upper(substring(md5(random()::text || clock_timestamp()::text) from 1 for 4))
      || '-' || upper(substring(md5(random()::text || clock_timestamp()::text) from 1 for 4));

    INSERT INTO access_keys (key, student_name, course_name, class_name, batch_id, expires_at, is_active, created_at)
    VALUES (v_key_text, p_student_name, p_course_name, p_class_name, p_batch_id, p_expires_at, true, now());
  END LOOP;

  RETURN v_key_text;
END;
$$;

-- ── 13. 检查用户名是否已注册 ──
CREATE FUNCTION check_username_exists(
  p_username TEXT
)
RETURNS TABLE(username_exists BOOLEAN) AS $$
BEGIN
  RETURN QUERY SELECT EXISTS(SELECT 1 FROM students WHERE students.username = p_username);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 14. 管理员查询学生密码 ──
CREATE FUNCTION admin_lookup_password(
  p_username TEXT
)
RETURNS TABLE(username TEXT, password_raw TEXT, real_name TEXT) AS $$
BEGIN
  RETURN QUERY
  SELECT s.username, s.password_raw, s.real_name
  FROM students s
  WHERE s.username = p_username;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 15. 管理端 RPC 函数 ──

-- 学生摘要
CREATE FUNCTION get_admin_students_summary()
RETURNS TABLE (
  student_id TEXT,
  username TEXT,
  real_name TEXT,
  class_name TEXT,
  bound_key TEXT,
  bound_course TEXT,
  total_sessions BIGINT,
  total_answers BIGINT,
  correct_answers BIGINT,
  accuracy_pct NUMERIC,
  avg_response_ms NUMERIC,
  last_active TIMESTAMPTZ,
  behavior_type TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    s.id AS student_id,
    s.username,
    s.real_name,
    s.class_name,
    ak.key AS bound_key,
    ak.course_name AS bound_course,
    COUNT(DISTINCT e.session_id)::BIGINT AS total_sessions,
    COALESCE(COUNT(*) FILTER (WHERE e.event_type = 'answer'), 0)::BIGINT AS total_answers,
    COALESCE(COUNT(*) FILTER (WHERE e.event_type = 'answer' AND (e.payload->>'correct')::boolean = true), 0)::BIGINT AS correct_answers,
    CASE WHEN COUNT(*) FILTER (WHERE e.event_type = 'answer') > 0
      THEN ROUND(
        COUNT(*) FILTER (WHERE e.event_type = 'answer' AND (e.payload->>'correct')::boolean = true)::numeric /
        COUNT(*) FILTER (WHERE e.event_type = 'answer') * 100, 1
      )
      ELSE 0
    END AS accuracy_pct,
    AVG((e.payload->>'responseMs')::int) FILTER (WHERE e.event_type = 'answer') AS avg_response_ms,
    GREATEST(MAX(e.created_at), s.last_active) AS last_active,
    CASE
      WHEN COUNT(*) FILTER (WHERE e.event_type = 'answer') = 0 THEN NULL
      WHEN AVG((e.payload->>'responseMs')::numeric) FILTER (WHERE e.event_type = 'answer') < 2000
       AND COUNT(*) FILTER (WHERE e.event_type = 'answer' AND (e.payload->>'correct')::boolean = false)::numeric /
           NULLIF(COUNT(*) FILTER (WHERE e.event_type = 'answer'), 0) > 0.3
      THEN 'impulsive'
      WHEN AVG((e.payload->>'responseMs')::numeric) FILTER (WHERE e.event_type = 'answer') >= 3000
       AND COUNT(*) FILTER (WHERE e.event_type = 'answer' AND (e.payload->>'correct')::boolean = false)::numeric /
           NULLIF(COUNT(*) FILTER (WHERE e.event_type = 'answer'), 0) <= 0.1
      THEN 'cautious'
      ELSE 'balanced'
    END AS behavior_type
  FROM students s
  LEFT JOIN practice_events e ON e.student_id = s.id
  LEFT JOIN access_keys ak ON ak.id = s.bound_key_id
  GROUP BY s.id, s.username, s.real_name, s.class_name, ak.key, ak.course_name, s.last_active
  ORDER BY s.real_name;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 每日统计
CREATE FUNCTION get_admin_daily_stats(days_int INT DEFAULT 7)
RETURNS TABLE (
  date DATE,
  total_answers BIGINT,
  correct_answers BIGINT,
  wrong_answers BIGINT,
  accuracy NUMERIC,
  avg_response_ms NUMERIC,
  session_count BIGINT
) AS $$
DECLARE
  start_date DATE := CURRENT_DATE - (days_int - 1);
BEGIN
  RETURN QUERY
  WITH date_series AS (
    SELECT generate_series(start_date, CURRENT_DATE, '1 day')::DATE AS date
  ),
  daily_data AS (
    SELECT
      e.created_at::DATE AS event_date,
      COUNT(*) FILTER (WHERE e.event_type = 'answer')::BIGINT AS total_answers,
      COUNT(*) FILTER (WHERE e.event_type = 'answer' AND (e.payload->>'correct')::boolean = true)::BIGINT AS correct_answers,
      COUNT(*) FILTER (WHERE e.event_type = 'answer' AND (e.payload->>'correct')::boolean = false)::BIGINT AS wrong_answers,
      AVG((e.payload->>'responseMs')::int) FILTER (WHERE e.event_type = 'answer') AS avg_response_ms,
      COUNT(DISTINCT e.session_id) FILTER (WHERE e.event_type = 'start_session')::BIGINT AS session_count
    FROM practice_events e
    WHERE e.created_at::DATE >= start_date
    GROUP BY e.created_at::DATE
  )
  SELECT
    ds.date,
    COALESCE(dd.total_answers, 0)::BIGINT,
    COALESCE(dd.correct_answers, 0)::BIGINT,
    COALESCE(dd.wrong_answers, 0)::BIGINT,
    CASE WHEN COALESCE(dd.total_answers, 0) > 0
      THEN ROUND(COALESCE(dd.correct_answers, 0)::numeric / COALESCE(dd.total_answers, 1) * 100, 1)
      ELSE 0
    END,
    dd.avg_response_ms,
    COALESCE(dd.session_count, 0)::BIGINT
  FROM date_series ds
  LEFT JOIN daily_data dd ON ds.date = dd.event_date
  ORDER BY ds.date;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 行为画像
CREATE FUNCTION get_admin_behavior_profile()
RETURNS TABLE (
  student_id TEXT,
  real_name TEXT,
  total_answers BIGINT,
  avg_response_ms NUMERIC,
  error_rate_pct NUMERIC,
  skip_count BIGINT,
  behavior_type TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    s.id AS student_id,
    s.real_name,
    COALESCE(COUNT(*) FILTER (WHERE e.event_type = 'answer'), 0)::BIGINT,
    ROUND(AVG((e.payload->>'responseMs')::numeric) FILTER (WHERE e.event_type = 'answer'), 1),
    CASE WHEN COUNT(*) FILTER (WHERE e.event_type = 'answer') > 0
      THEN ROUND(
        COUNT(*) FILTER (WHERE e.event_type = 'answer' AND (e.payload->>'correct')::boolean = false)::numeric /
        COUNT(*) FILTER (WHERE e.event_type = 'answer') * 100, 1
      )
      ELSE 0
    END,
    COALESCE(COUNT(*) FILTER (WHERE e.event_type = 'skip'), 0)::BIGINT,
    CASE
      WHEN COUNT(*) FILTER (WHERE e.event_type = 'answer') = 0 THEN NULL
      WHEN AVG((e.payload->>'responseMs')::numeric) FILTER (WHERE e.event_type = 'answer') < 2000
       AND COUNT(*) FILTER (WHERE e.event_type = 'answer' AND (e.payload->>'correct')::boolean = false)::numeric /
           NULLIF(COUNT(*) FILTER (WHERE e.event_type = 'answer'), 0) > 0.3
      THEN 'impulsive'
      WHEN AVG((e.payload->>'responseMs')::numeric) FILTER (WHERE e.event_type = 'answer') >= 3000
       AND COUNT(*) FILTER (WHERE e.event_type = 'answer' AND (e.payload->>'correct')::boolean = false)::numeric /
           NULLIF(COUNT(*) FILTER (WHERE e.event_type = 'answer'), 0) <= 0.1
      THEN 'cautious'
      ELSE 'balanced'
    END
  FROM students s
  LEFT JOIN practice_events e ON e.student_id = s.id
  GROUP BY s.id, s.real_name
  ORDER BY s.real_name;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 错误热力图
CREATE FUNCTION get_admin_error_heatmap()
RETURNS TABLE (
  module_id TEXT,
  item_key TEXT,
  total_attempts BIGINT,
  error_count BIGINT,
  error_rate_pct NUMERIC
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    e.module_id,
    e.item_key,
    COUNT(*)::BIGINT,
    COUNT(*) FILTER (WHERE (e.payload->>'correct')::boolean = false)::BIGINT,
    CASE WHEN COUNT(*) > 0
      THEN ROUND(
        COUNT(*) FILTER (WHERE (e.payload->>'correct')::boolean = false)::numeric / COUNT(*) * 100, 1
      )
      ELSE 0
    END
  FROM practice_events e
  WHERE e.event_type = 'answer'
  GROUP BY e.module_id, e.item_key
  ORDER BY error_rate_pct DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 记忆状态概览
CREATE FUNCTION get_admin_memory_overview()
RETURNS TABLE (
  student_id TEXT,
  real_name TEXT,
  class_name TEXT,
  total_items BIGINT,
  mastered_items BIGINT,
  learning_items BIGINT,
  due_items BIGINT,
  avg_retrievability NUMERIC
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    s.id,
    s.real_name,
    s.class_name,
    COUNT(m.id)::BIGINT,
    COUNT(m.id) FILTER (WHERE m.retrievability >= 0.9)::BIGINT,
    COUNT(m.id) FILTER (WHERE m.retrievability >= 0.5 AND m.retrievability < 0.9)::BIGINT,
    COUNT(m.id) FILTER (WHERE m.retrievability < 0.5)::BIGINT,
    ROUND(AVG(m.retrievability), 3)
  FROM students s
  LEFT JOIN memory_states m ON m.student_id = s.id
  GROUP BY s.id, s.real_name, s.class_name
  ORDER BY s.real_name;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 18. 同义替换专项统计 ──
CREATE OR REPLACE FUNCTION get_admin_synonym_stats()
RETURNS TABLE (
  student_id        TEXT,
  username          TEXT,
  real_name         TEXT,
  class_name        TEXT,
  bound_key         TEXT,
  bound_course      TEXT,
  total_sessions    BIGINT,
  total_duration_ms BIGINT,
  total_words       BIGINT,
  right_words       BIGINT,
  wrong_words       BIGINT,
  accuracy_pct      NUMERIC,
  last_active       TIMESTAMPTZ
) AS $$
BEGIN
  RETURN QUERY
  WITH session_stats AS (
    SELECT
      e.student_id,
      COUNT(DISTINCT e.session_id) AS total_sessions,
      SUM((e.payload->>'durationMs')::BIGINT) AS total_duration_ms,
      SUM((e.payload->>'rightCount')::INT) AS total_right,
      SUM((e.payload->>'wrongCount')::INT) AS total_wrong,
      MAX(e.created_at) AS last_active
    FROM practice_events e
    WHERE e.module_id = 'synonym' AND e.event_type = 'end_session'
    GROUP BY e.student_id
  )
  SELECT
    s.id                                    AS student_id,
    s.username,
    s.real_name,
    s.class_name,
    ak.key                                  AS bound_key,
    ak.course_name                          AS bound_course,
    COALESCE(ss.total_sessions, 0)::BIGINT  AS total_sessions,
    COALESCE(ss.total_duration_ms, 0)::BIGINT AS total_duration_ms,
    (COALESCE(ss.total_right, 0) + COALESCE(ss.total_wrong, 0))::BIGINT AS total_words,
    COALESCE(ss.total_right, 0)::BIGINT    AS right_words,
    COALESCE(ss.total_wrong, 0)::BIGINT     AS wrong_words,
    CASE
      WHEN COALESCE(ss.total_right, 0) + COALESCE(ss.total_wrong, 0) > 0
      THEN ROUND(
        COALESCE(ss.total_right, 0)::NUMERIC /
        (COALESCE(ss.total_right, 0) + COALESCE(ss.total_wrong, 0))::NUMERIC * 100,
        1
      )
      ELSE 0
    END                                     AS accuracy_pct,
    COALESCE(ss.last_active, s.last_active) AS last_active
  FROM students s
  LEFT JOIN access_keys ak ON ak.id = s.bound_key_id
  LEFT JOIN session_stats ss ON ss.student_id = s.id
  WHERE s.bound_key_id IS NOT NULL
     OR COALESCE(ss.total_sessions, 0) > 0
  ORDER BY s.real_name;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 17. 学生画像（按模块细分）──
CREATE OR REPLACE FUNCTION get_admin_students_profile()
RETURNS TABLE (
  student_id          TEXT,
  username            TEXT,
  real_name           TEXT,
  class_name          TEXT,
  bound_key           TEXT,
  bound_course        TEXT,
  module_id           TEXT,
  module_name         TEXT,
  total_answers       BIGINT,
  correct_answers     BIGINT,
  accuracy_pct        NUMERIC,
  practiced_items     BIGINT,
  total_items         BIGINT,
  unpracticed_items   BIGINT,
  progress_pct        NUMERIC,
  total_duration_ms   BIGINT,
  today_duration_ms   BIGINT,
  last_active         TIMESTAMPTZ,
  behavior_type       TEXT
) AS $$
BEGIN
  RETURN QUERY
  WITH module_totals AS (
    SELECT 'synonym'::TEXT AS module_id, 157::BIGINT AS total_groups, 732::BIGINT AS total_items
    UNION ALL
    SELECT 'sentence'::TEXT, 0::BIGINT, 0::BIGINT
  ),
  student_module_stats AS (
    SELECT
      e.student_id,
      e.module_id,
      COUNT(*) FILTER (WHERE e.event_type = 'answer') AS total_answers,
      COUNT(*) FILTER (WHERE e.event_type = 'answer' AND (e.payload->>'correct')::boolean = true) AS correct_answers,
      COUNT(DISTINCT e.item_key) AS practiced_items,
      COALESCE(SUM((e.payload->>'responseMs')::BIGINT) FILTER (WHERE e.event_type = 'answer'), 0) AS total_duration_ms,
      COALESCE(SUM((e.payload->>'responseMs')::BIGINT) FILTER (WHERE e.event_type = 'answer' AND e.created_at::DATE = CURRENT_DATE), 0) AS today_duration_ms,
      MAX(e.created_at) AS last_active,
      CASE
        WHEN COUNT(*) FILTER (WHERE e.event_type = 'answer') = 0 THEN NULL
        WHEN AVG((e.payload->>'responseMs')::NUMERIC) FILTER (WHERE e.event_type = 'answer') < 2000
         AND COUNT(*) FILTER (WHERE e.event_type = 'answer' AND (e.payload->>'correct')::boolean = false)::NUMERIC /
             NULLIF(COUNT(*) FILTER (WHERE e.event_type = 'answer'), 0) > 0.3
        THEN 'impulsive'
        WHEN AVG((e.payload->>'responseMs')::NUMERIC) FILTER (WHERE e.event_type = 'answer') >= 3000
         AND COUNT(*) FILTER (WHERE e.event_type = 'answer' AND (e.payload->>'correct')::boolean = false)::NUMERIC /
             NULLIF(COUNT(*) FILTER (WHERE e.event_type = 'answer'), 0) <= 0.1
        THEN 'cautious'
        ELSE 'balanced'
      END AS behavior_type
    FROM practice_events e
    GROUP BY e.student_id, e.module_id
  )
  SELECT
    s.id                          AS student_id,
    s.username,
    s.real_name,
    s.class_name,
    ak.key                        AS bound_key,
    ak.course_name                AS bound_course,
    mt.module_id                  AS module_id,
    CASE mt.module_id
      WHEN 'synonym' THEN '同义替换大挑战'
      WHEN 'sentence' THEN '长难句解析'
      ELSE mt.module_id
    END                           AS module_name,
    COALESCE(sms.total_answers, 0)::BIGINT    AS total_answers,
    COALESCE(sms.correct_answers, 0)::BIGINT  AS correct_answers,
    CASE WHEN COALESCE(sms.total_answers, 0) > 0
      THEN ROUND(COALESCE(sms.correct_answers, 0)::NUMERIC / NULLIF(sms.total_answers, 0) * 100, 1)
      ELSE 0
    END                           AS accuracy_pct,
    COALESCE(sms.practiced_items, 0)::BIGINT  AS practiced_items,
    mt.total_items::BIGINT,
    GREATEST(mt.total_items - COALESCE(sms.practiced_items, 0), 0)::BIGINT AS unpracticed_items,
    CASE WHEN mt.total_items > 0
      THEN ROUND(LEAST(COALESCE(sms.practiced_items, 0)::NUMERIC / mt.total_items * 100, 100), 1)
      ELSE 0
    END                           AS progress_pct,
    COALESCE(sms.total_duration_ms, 0)::BIGINT  AS total_duration_ms,
    COALESCE(sms.today_duration_ms, 0)::BIGINT  AS today_duration_ms,
    COALESCE(sms.last_active, s.last_active)     AS last_active,
    sms.behavior_type
  FROM students s
  LEFT JOIN access_keys ak ON ak.id = s.bound_key_id
  CROSS JOIN module_totals mt
  LEFT JOIN student_module_stats sms ON sms.student_id = s.id AND sms.module_id = mt.module_id
  WHERE mt.total_items > 0
     OR COALESCE(sms.total_answers, 0) > 0
  ORDER BY s.real_name, mt.module_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
