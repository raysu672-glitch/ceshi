-- ============================================================
-- 补丁 v2：修复 batch_generate_keys 函数（更简单可靠方案）
-- 彻底避免 RETURNS TABLE 的兼容性问题
-- 直接在 Supabase SQL Editor 中执行此文件
-- ============================================================

-- 第一步：补全 access_keys 表缺失的列（如果之前只建了一半表结构）
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'access_keys' AND column_name = 'course_name') THEN
    ALTER TABLE access_keys ADD COLUMN course_name TEXT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'access_keys' AND column_name = 'batch_id') THEN
    ALTER TABLE access_keys ADD COLUMN batch_id TEXT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'access_keys' AND column_name = 'expires_at') THEN
    ALTER TABLE access_keys ADD COLUMN expires_at TIMESTAMPTZ;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'access_keys' AND column_name = 'used_by') THEN
    ALTER TABLE access_keys ADD COLUMN used_by TEXT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'access_keys' AND column_name = 'used_by_id') THEN
    ALTER TABLE access_keys ADD COLUMN used_by_id TEXT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'access_keys' AND column_name = 'used_at') THEN
    ALTER TABLE access_keys ADD COLUMN used_at TIMESTAMPTZ;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'access_keys' AND column_name = 'student_name') THEN
    ALTER TABLE access_keys ADD COLUMN student_name TEXT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'access_keys' AND column_name = 'class_name') THEN
    ALTER TABLE access_keys ADD COLUMN class_name TEXT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'access_keys' AND column_name = 'is_active') THEN
    ALTER TABLE access_keys ADD COLUMN is_active BOOLEAN DEFAULT true;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'access_keys' AND column_name = 'created_at') THEN
    ALTER TABLE access_keys ADD COLUMN created_at TIMESTAMPTZ DEFAULT now();
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_access_keys_key ON access_keys(key);
CREATE INDEX IF NOT EXISTS idx_access_keys_active ON access_keys(is_active) WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_access_keys_batch ON access_keys(batch_id) WHERE batch_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_access_keys_course ON access_keys(course_name) WHERE course_name IS NOT NULL;

-- 第二步：删除旧版本函数（多种签名都删）
DROP FUNCTION IF EXISTS batch_generate_keys(INT, TEXT, TEXT, TEXT, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS batch_generate_keys(INT, TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS batch_generate_keys(INT, TEXT, TEXT, TEXT, TEXT);

-- 第三步：重建函数——用 RETURNS TEXT 简单返回密钥字符串
-- 客户端负责插入后查询获取完整信息
CREATE OR REPLACE FUNCTION batch_generate_keys(
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
    -- 生成 XXXX-XXXX-XXXX 格式密钥
    v_key_text :=
      upper(substring(md5(random()::text || clock_timestamp()::text) from 1 for 4))
      || '-' || upper(substring(md5(random()::text || clock_timestamp()::text) from 1 for 4))
      || '-' || upper(substring(md5(random()::text || clock_timestamp()::text) from 1 for 4));

    -- 插入数据库
    INSERT INTO access_keys (key, student_name, course_name, class_name, batch_id, expires_at, is_active, created_at)
    VALUES (v_key_text, p_student_name, p_course_name, p_class_name, p_batch_id, p_expires_at, true, now());
  END LOOP;

  -- 返回最后一个生成的密钥（客户端需要知道生成的是哪个）
  RETURN v_key_text;
END;
$$;

-- 验证：手动测试（请在 SQL Editor 中执行以下语句，确认返回密钥字符串）
-- SELECT batch_generate_keys(1, '测试学生', NULL, NULL, 'test_batch', NULL);
