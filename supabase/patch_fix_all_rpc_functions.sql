-- ============================================================
-- 补丁：补齐所有缺失的 RPC 函数
-- 直接在 Supabase SQL Editor 中执行此文件
-- ============================================================

-- 删除可能存在的旧版本（避免冲突）
DROP FUNCTION IF EXISTS register_student(TEXT, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS login_student(TEXT, TEXT);
DROP FUNCTION IF EXISTS bind_key_to_student(TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS check_username_exists(TEXT);
DROP FUNCTION IF EXISTS admin_lookup_password(TEXT);
DROP FUNCTION IF EXISTS get_admin_students_summary();
DROP FUNCTION IF EXISTS get_admin_daily_stats(INT);
DROP FUNCTION IF EXISTS get_admin_behavior_profile();
DROP FUNCTION IF EXISTS get_admin_error_heatmap();
DROP FUNCTION IF EXISTS get_admin_memory_overview();
DROP FUNCTION IF EXISTS upsert_memory_state(TEXT, TEXT, TEXT, BOOLEAN);

-- ── 1. 注册函数 ──
CREATE OR REPLACE FUNCTION register_student(
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

-- ── 2. 登录函数 ──
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
  SELECT * INTO v_student FROM students WHERE username = p_username;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_student.locked_until IS NOT NULL AND v_student.locked_until > now() THEN
    v_locked := true;
    v_remaining := EXTRACT(EPOCH FROM (v_student.locked_until - now()))::INT / 60 + 1;
    RETURN QUERY SELECT
      v_student.id, v_student.username, v_student.real_name,
      v_student.class_name, v_student.bound_key_id,
      v_locked, v_remaining;
    RETURN;
  END IF;

  IF v_student.locked_until IS NOT NULL AND v_student.locked_until <= now() THEN
    UPDATE students SET failed_attempts = 0, locked_until = NULL WHERE id = v_student.id;
    v_student.failed_attempts := 0;
  END IF;

  IF v_student.password_hash = p_password_hash THEN
    UPDATE students SET failed_attempts = 0, locked_until = NULL, last_active = now()
    WHERE id = v_student.id;
    RETURN QUERY SELECT
      v_student.id, v_student.username, v_student.real_name,
      v_student.class_name, v_student.bound_key_id,
      false, 0;
  ELSE
    UPDATE students SET failed_attempts = failed_attempts + 1 WHERE id = v_student.id;
    IF v_student.failed_attempts + 1 >= 5 THEN
      UPDATE students SET locked_until = now() + interval '15 minutes' WHERE id = v_student.id;
    END IF;
    RETURN;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 3. 密钥绑定函数 ──
CREATE OR REPLACE FUNCTION bind_key_to_student(
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

  UPDATE access_keys SET
    used_by = (SELECT username FROM students WHERE id = p_student_id),
    used_by_id = p_student_id,
    used_at = now()
  WHERE id = v_key.id;

  UPDATE students SET
    bound_key_id = v_key.id,
    real_name = p_real_name,
    class_name = COALESCE(v_key.class_name, v_key.course_name, class_name)
  WHERE id = p_student_id;

  RETURN QUERY SELECT true, '密钥绑定成功'::TEXT, v_key.student_name, v_key.class_name;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 4. 检查用户名是否存在 ──
CREATE OR REPLACE FUNCTION check_username_exists(
  p_username TEXT
)
RETURNS TABLE(username_exists BOOLEAN) AS $$
BEGIN
  RETURN QUERY SELECT EXISTS(SELECT 1 FROM students WHERE username = p_username);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 5. 管理员查询密码 ──
CREATE OR REPLACE FUNCTION admin_lookup_password(
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

-- ── 6. 遗忘曲线更新函数 ──
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

-- ── 7. 管理端：学生摘要 ──
CREATE OR REPLACE FUNCTION get_admin_students_summary()
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

-- ── 8. 管理端：每日统计 ──
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

-- ── 9. 管理端：行为画像 ──
CREATE OR REPLACE FUNCTION get_admin_behavior_profile()
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

-- ── 10. 管理端：错误热力图 ──
CREATE OR REPLACE FUNCTION get_admin_error_heatmap()
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

-- ── 11. 管理端：记忆状态概览 ──
CREATE OR REPLACE FUNCTION get_admin_memory_overview()
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

-- 验证：列出所有已创建的函数
SELECT proname AS function_name, pg_get_function_arguments(oid) AS arguments
FROM pg_proc
WHERE proname IN (
  'register_student', 'login_student', 'bind_key_to_student',
  'check_username_exists', 'admin_lookup_password', 'batch_generate_keys',
  'get_admin_students_summary', 'get_admin_daily_stats',
  'get_admin_behavior_profile', 'get_admin_error_heatmap',
  'get_admin_memory_overview', 'upsert_memory_state'
)
ORDER BY proname;
