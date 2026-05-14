-- ============================================================
-- IELTS Training Platform — Supabase Schema
-- 第一期：数据基础 + 事件采集
-- ============================================================

-- ── 1. 模块注册表 ──
CREATE TABLE IF NOT EXISTS modules (
  id          TEXT PRIMARY KEY,          -- 如 'synonym', 'sentence'
  name        TEXT NOT NULL,             -- 显示名：'同义替换大挑战'
  description TEXT,
  icon        TEXT,                      -- emoji 或图标类名
  version     TEXT DEFAULT '1.0.0',
  is_active   BOOLEAN DEFAULT true,
  created_at  TIMESTAMPTZ DEFAULT now()
);

-- 初始化种子数据
INSERT INTO modules (id, name, description, icon) VALUES
  ('synonym', '同义替换大挑战', '雅思阅读同义替换词汇练习', '🔄'),
  ('sentence', '长难句解析', '雅思长难句结构分析与翻译练习', '📖')
ON CONFLICT (id) DO NOTHING;

-- ── 2. 学生表 ──
CREATE TABLE IF NOT EXISTS students (
  id          TEXT PRIMARY KEY,          -- stu_xxx 格式，前端自动生成
  display_name TEXT,
  class_name  TEXT,                      -- 班级：如 '雅思A班'
  created_at  TIMESTAMPTZ DEFAULT now(),
  last_active TIMESTAMPTZ
);

-- ── 3. 练习事件统一表 ──
CREATE TABLE IF NOT EXISTS practice_events (
  id          BIGSERIAL PRIMARY KEY,
  student_id  TEXT NOT NULL REFERENCES students(id) ON DELETE CASCADE,
  session_id  TEXT NOT NULL,             -- 同一会话的所有事件共享 session_id
  module_id   TEXT NOT NULL REFERENCES modules(id),
  event_type  TEXT NOT NULL,             -- answer / skip / start_session / end_session / hint_used / level_up
  item_key    TEXT,                      -- 题目标识：如 'successive/consecutive'
  payload     JSONB DEFAULT '{}',        -- 灵活扩展字段：correct, responseMs, combo 等
  created_at  TIMESTAMPTZ DEFAULT now(),

  -- 性能优化索引
  CONSTRAINT valid_event_type CHECK (
    event_type IN ('answer', 'skip', 'start_session', 'end_session', 'hint_used', 'level_up')
  )
);

CREATE INDEX idx_events_student ON practice_events (student_id);
CREATE INDEX idx_events_session ON practice_events (session_id);
CREATE INDEX idx_events_module  ON practice_events (module_id);
CREATE INDEX idx_events_type    ON practice_events (event_type);
CREATE INDEX idx_events_item    ON practice_events (item_key) WHERE item_key IS NOT NULL;
CREATE INDEX idx_events_created ON practice_events (created_at DESC);

-- ── 4. 遗忘状态表（为第三期艾宾浩斯曲线预留） ──
CREATE TABLE IF NOT EXISTS memory_states (
  id          BIGSERIAL PRIMARY KEY,
  student_id  TEXT NOT NULL REFERENCES students(id) ON DELETE CASCADE,
  module_id   TEXT NOT NULL REFERENCES modules(id),
  item_key    TEXT NOT NULL,
  stability   REAL DEFAULT 1.0,          -- S 值：记忆稳定度（天）
  retrievability REAL DEFAULT 1.0,       -- R(t)：当前可提取概率
  last_practiced TIMESTAMPTZ,
  practice_count INT DEFAULT 0,
  correct_count  INT DEFAULT 0,
  created_at  TIMESTAMPTZ DEFAULT now(),
  updated_at  TIMESTAMPTZ DEFAULT now(),

  UNIQUE (student_id, module_id, item_key)
);

CREATE INDEX idx_memory_student ON memory_states (student_id);
CREATE INDEX idx_memory_due ON memory_states (retrievability) WHERE retrievability < 0.7;

-- ── 5. RLS 行级安全策略 ──

-- students 表：学生只能读写自己
ALTER TABLE students ENABLE ROW LEVEL SECURITY;
CREATE POLICY students_self ON students
  FOR ALL USING (id = current_setting('request.jwt.claims', true)::json->>'student_id');

-- practice_events 表：学生只能插入自己的事件
ALTER TABLE practice_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY events_insert ON practice_events
  FOR INSERT WITH CHECK (student_id = current_setting('request.jwt.claims', true)::json->>'student_id');
CREATE POLICY events_self ON practice_events
  FOR SELECT USING (student_id = current_setting('request.jwt.claims', true)::json->>'student_id');

-- memory_states 表：学生读写自己
ALTER TABLE memory_states ENABLE ROW LEVEL SECURITY;
CREATE POLICY memory_self ON memory_states
  FOR ALL USING (student_id = current_setting('request.jwt.claims', true)::json->>'student_id');

-- ── 6. 教师角色视图（方便管理端查询） ──

-- 学生练习摘要
CREATE OR REPLACE VIEW v_student_summary AS
SELECT
  e.student_id,
  s.display_name,
  s.class_name,
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
  MAX(e.created_at) AS last_active
FROM practice_events e
LEFT JOIN students s ON e.student_id = s.id
GROUP BY e.student_id, s.display_name, s.class_name;

-- 错题热力图
CREATE OR REPLACE VIEW v_error_heatmap AS
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

-- 行为画像数据
CREATE OR REPLACE VIEW v_behavior_profile AS
SELECT
  e.student_id,
  s.display_name,
  COUNT(*) FILTER (WHERE e.event_type = 'answer') AS total_answers,
  ROUND(AVG((e.payload->>'responseMs')::numeric) FILTER (WHERE e.event_type = 'answer')) AS avg_response_ms,
  CASE WHEN COUNT(*) FILTER (WHERE e.event_type = 'answer') > 0
    THEN ROUND(
      COUNT(*) FILTER (WHERE e.event_type = 'answer' AND (e.payload->>'correct')::boolean = false)::numeric /
      COUNT(*) FILTER (WHERE e.event_type = 'answer') * 100, 1
    )
    ELSE 0
  END AS error_rate_pct,
  COUNT(*) FILTER (WHERE e.event_type = 'skip') AS skip_count,
  -- 冲动型判定（高错误率 + 快响应）
  CASE
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
FROM practice_events e
LEFT JOIN students s ON e.student_id = s.id
GROUP BY e.student_id, s.display_name
HAVING COUNT(*) FILTER (WHERE e.event_type = 'answer') >= 5;

-- ── 7. 辅助函数：更新遗忘状态 ──
CREATE OR REPLACE FUNCTION upsert_memory_state(
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
  -- 获取当前状态
  SELECT stability, retrievability, last_practiced
  INTO v_stability, v_retrievability, v_last
  FROM memory_states
  WHERE student_id = p_student_id AND module_id = p_module_id AND item_key = p_item_key;

  IF NOT FOUND THEN
    -- 首次练习
    INSERT INTO memory_states (student_id, module_id, item_key, stability, retrievability, last_practiced, practice_count, correct_count)
    VALUES (p_student_id, p_module_id, p_item_key, 1.0, 1.0, now(), 1, CASE WHEN p_correct THEN 1 ELSE 0 END);
  ELSE
    -- 计算时间间隔（天）
    v_interval_days := EXTRACT(EPOCH FROM (now() - v_last)) / 86400.0;

    -- 艾宾浩斯衰减：R(t) = e^(-t/S)
    v_retrievability := EXP(-v_interval_days / v_stability);

    -- 根据回答结果更新 S
    IF p_correct THEN
      v_stability := v_stability * (1 + 0.3 * v_retrievability);  -- 正确 → 稳定度增长
    ELSE
      v_stability := GREATEST(v_stability * 0.5, 0.5);  -- 错误 → 稳定度衰减
    END IF;

    UPDATE memory_states SET
      stability = v_stability,
      retrievability = v_stability,  -- 刚练习过，R=1（用新的 S）
      last_practiced = now(),
      practice_count = practice_count + 1,
      correct_count = correct_count + CASE WHEN p_correct THEN 1 ELSE 0 END,
      updated_at = now()
    WHERE student_id = p_student_id AND module_id = p_module_id AND item_key = p_item_key;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- ── 8. 访问密钥表（第四期：密钥激活系统） ──CREATE TABLE IF NOT EXISTS access_keys (
  id           UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  key          TEXT UNIQUE NOT NULL,
  student_name TEXT,                          -- 预分配学生姓名（可选）
  class_name   TEXT,                          -- 预分配班级（可选）
  used_by      TEXT,                          -- 实际使用者姓名
  used_by_id   TEXT,                          -- 实际使用学生 ID
  used_at      TIMESTAMPTZ,                  -- 使用时间
  is_active    BOOLEAN DEFAULT true,
  created_at   TIMESTAMPTZ DEFAULT now()
);

-- 索引
CREATE INDEX IF NOT EXISTS idx_access_keys_key      ON access_keys (key);
CREATE INDEX IF NOT EXISTS idx_access_keys_active   ON access_keys (is_active) WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_access_keys_used    ON access_keys (used_by) WHERE used_by IS NOT NULL;

-- RLS：允许匿名读取未使用的激活密钥（用于注册验证）
ALTER TABLE access_keys ENABLE ROW LEVEL SECURITY;

-- 检查并创建策略（兼容 PostgreSQL 15）
-- 删除可能冲突的旧策略
DROP POLICY IF EXISTS anon_read_unused ON access_keys;

-- SELECT 策略：允许匿名查询所有密钥（注册验证/管理端列表用）
-- 注意：密钥值本身就是敏感信息，通过预分配姓名来控制使用权限
CREATE POLICY anon_select_keys ON access_keys
  FOR SELECT USING (true);

-- INSERT 策略：允许匿名插入新密钥（管理端生成用）
CREATE POLICY anon_insert_keys ON access_keys
  FOR INSERT WITH CHECK (true);

-- UPDATE 策略：允许匿名更新（消费/撤销密钥）
CREATE POLICY anon_update_keys ON access_keys
  FOR UPDATE USING (true);
-- 教师（service_role）可完整管理
-- 注意：管理端使用 localStorage 中的 service_role key 或通过 admin 面板操作

-- 方便管理端查询的视图
CREATE OR REPLACE VIEW v_access_keys AS
SELECT
  id, key, student_name, class_name,
  used_by, used_by_id, used_at,
  is_active, created_at,
  CASE
    WHEN used_by IS NOT NULL THEN 'used'
    WHEN is_active = false THEN 'revoked'
    ELSE 'unused'
  END AS status
FROM access_keys
ORDER BY created_at DESC;

-- ── 9. 管理端 RPC 函数（绕过 RLS）────────────────────
-- 获取所有学生摘要（用于管理端学生画像）
CREATE OR REPLACE FUNCTION get_admin_students_summary()
RETURNS TABLE (
  student_id TEXT,
  display_name TEXT,
  class_name TEXT,
  total_sessions BIGINT,
  total_answers BIGINT,
  correct_answers BIGINT,
  accuracy_pct NUMERIC,
  avg_response_ms NUMERIC,
  last_active TIMESTAMPTZ
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    e.student_id,
    s.display_name,
    s.class_name,
    COUNT(DISTINCT e.session_id)::BIGINT AS total_sessions,
    COUNT(*) FILTER (WHERE e.event_type = 'answer')::BIGINT AS total_answers,
    COUNT(*) FILTER (WHERE e.event_type = 'answer' AND (e.payload->>'correct')::boolean = true)::BIGINT AS correct_answers,
    CASE WHEN COUNT(*) FILTER (WHERE e.event_type = 'answer') > 0
      THEN ROUND(
        COUNT(*) FILTER (WHERE e.event_type = 'answer' AND (e.payload->>'correct')::boolean = true)::numeric /
        COUNT(*) FILTER (WHERE e.event_type = 'answer') * 100, 1
      )
      ELSE 0
    END AS accuracy_pct,
    AVG((e.payload->>'responseMs')::int) FILTER (WHERE e.event_type = 'answer') AS avg_response_ms,
    MAX(e.created_at) AS last_active
  FROM practice_events e
  LEFT JOIN students s ON e.student_id = s.id
  GROUP BY e.student_id, s.display_name, s.class_name;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 获取所有学生的每日统计（用于管理端总览）
CREATE OR REPLACE FUNCTION get_admin_daily_stats(days_int INT DEFAULT 7)
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
    COALESCE(dd.total_answers, 0)::BIGINT AS total_answers,
    COALESCE(dd.correct_answers, 0)::BIGINT AS correct_answers,
    COALESCE(dd.wrong_answers, 0)::BIGINT AS wrong_answers,
    CASE WHEN COALESCE(dd.total_answers, 0) > 0
      THEN ROUND(COALESCE(dd.correct_answers, 0)::numeric / COALESCE(dd.total_answers, 1) * 100, 1)
      ELSE 0
    END AS accuracy,
    dd.avg_response_ms,
    COALESCE(dd.session_count, 0)::BIGINT AS session_count
  FROM date_series ds
  LEFT JOIN daily_data dd ON ds.date = dd.event_date
  ORDER BY ds.date;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 获取行为画像数据（用于管理端）
CREATE OR REPLACE FUNCTION get_admin_behavior_profile()
RETURNS TABLE (
  student_id TEXT,
  display_name TEXT,
  total_answers BIGINT,
  avg_response_ms NUMERIC,
  error_rate_pct NUMERIC,
  skip_count BIGINT,
  behavior_type TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    e.student_id,
    s.display_name,
    COUNT(*) FILTER (WHERE e.event_type = 'answer')::BIGINT AS total_answers,
    ROUND(AVG((e.payload->>'responseMs')::numeric) FILTER (WHERE e.event_type = 'answer'), 1) AS avg_response_ms,
    CASE WHEN COUNT(*) FILTER (WHERE e.event_type = 'answer') > 0
      THEN ROUND(
        COUNT(*) FILTER (WHERE e.event_type = 'answer' AND (e.payload->>'correct')::boolean = false)::numeric /
        COUNT(*) FILTER (WHERE e.event_type = 'answer') * 100, 1
      )
      ELSE 0
    END AS error_rate_pct,
    COUNT(*) FILTER (WHERE e.event_type = 'skip')::BIGINT AS skip_count,
    CASE
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
  FROM practice_events e
  LEFT JOIN students s ON e.student_id = s.id
  GROUP BY e.student_id, s.display_name
  HAVING COUNT(*) FILTER (WHERE e.event_type = 'answer') >= 5;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
