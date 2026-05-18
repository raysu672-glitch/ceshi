-- ============================================================
-- 补丁：修复 batch_generate_keys 函数（密钥生成失败修复）
-- 直接在 Supabase SQL Editor 中执行此文件
-- ============================================================

-- 第一步：删除旧版本函数（两种签名都删）
DROP FUNCTION IF EXISTS batch_generate_keys(INT, TEXT, TEXT, TEXT, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS batch_generate_keys(INT, TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ);

-- 第二步：重建函数，改用 RETURNS TABLE 明确字段，兼容 PostgREST RPC 调用
CREATE OR REPLACE FUNCTION batch_generate_keys(
  p_count        INT,
  p_student_name TEXT DEFAULT NULL,
  p_course_name  TEXT DEFAULT NULL,
  p_class_name   TEXT DEFAULT NULL,
  p_batch_id     TEXT DEFAULT NULL,
  p_expires_at   TIMESTAMPTZ DEFAULT NULL
)
RETURNS TABLE (
  id          UUID,
  key         TEXT,
  student_name TEXT,
  class_name  TEXT,
  course_name TEXT,
  expires_at  TIMESTAMPTZ,
  batch_id    TEXT,
  used_by     TEXT,
  used_by_id  TEXT,
  used_at     TIMESTAMPTZ,
  is_active   BOOLEAN,
  created_at  TIMESTAMPTZ
) AS $$
DECLARE
  i         INT;
  v_key_text TEXT;
  v_row     access_keys%ROWTYPE;
BEGIN
  FOR i IN 1..p_count LOOP
    -- 生成 XXXX-XXXX-XXXX 格式密钥
    v_key_text :=
      upper(substring(md5(random()::text || clock_timestamp()::text) from 1 for 4))
      || '-' || upper(substring(md5(random()::text || clock_timestamp()::text) from 1 for 4))
      || '-' || upper(substring(md5(random()::text || clock_timestamp()::text) from 1 for 4));

    INSERT INTO access_keys (key, student_name, course_name, class_name, batch_id, expires_at, is_active, created_at)
    VALUES (v_key_text, p_student_name, p_course_name, p_class_name, p_batch_id, p_expires_at, true, now())
    RETURNING * INTO v_row;

    -- 明确返回每个字段
    id          := v_row.id;
    key         := v_row.key;
    student_name := v_row.student_name;
    class_name  := v_row.class_name;
    course_name := v_row.course_name;
    expires_at  := v_row.expires_at;
    batch_id    := v_row.batch_id;
    used_by     := v_row.used_by;
    used_by_id  := v_row.used_by_id;
    used_at     := v_row.used_at;
    is_active   := v_row.is_active;
    created_at  := v_row.created_at;
    RETURN NEXT;
  END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
