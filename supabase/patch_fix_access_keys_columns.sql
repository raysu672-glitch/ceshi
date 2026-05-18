-- ============================================================
-- 补丁：为 access_keys 表补全缺失的列（course_name 等）
-- 直接在 Supabase SQL Editor 中执行
-- ============================================================

-- 检查并添加缺失的列
DO $$
BEGIN
  -- course_name
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'access_keys' AND column_name = 'course_name'
  ) THEN
    ALTER TABLE access_keys ADD COLUMN course_name TEXT;
    RAISE NOTICE 'Added column course_name to access_keys';
  END IF;

  -- batch_id
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'access_keys' AND column_name = 'batch_id'
  ) THEN
    ALTER TABLE access_keys ADD COLUMN batch_id TEXT;
    RAISE NOTICE 'Added column batch_id to access_keys';
  END IF;

  -- expires_at
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'access_keys' AND column_name = 'expires_at'
  ) THEN
    ALTER TABLE access_keys ADD COLUMN expires_at TIMESTAMPTZ;
    RAISE NOTICE 'Added column expires_at to access_keys';
  END IF;

  -- used_by
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'access_keys' AND column_name = 'used_by'
  ) THEN
    ALTER TABLE access_keys ADD COLUMN used_by TEXT;
    RAISE NOTICE 'Added column used_by to access_keys';
  END IF;

  -- used_by_id
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'access_keys' AND column_name = 'used_by_id'
  ) THEN
    ALTER TABLE access_keys ADD COLUMN used_by_id TEXT;
    RAISE NOTICE 'Added column used_by_id to access_keys';
  END IF;

  -- used_at
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'access_keys' AND column_name = 'used_at'
  ) THEN
    ALTER TABLE access_keys ADD COLUMN used_at TIMESTAMPTZ;
    RAISE NOTICE 'Added column used_at to access_keys';
  END IF;

  -- student_name
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'access_keys' AND column_name = 'student_name'
  ) THEN
    ALTER TABLE access_keys ADD COLUMN student_name TEXT;
    RAISE NOTICE 'Added column student_name to access_keys';
  END IF;

  -- class_name
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'access_keys' AND column_name = 'class_name'
  ) THEN
    ALTER TABLE access_keys ADD COLUMN class_name TEXT;
    RAISE NOTICE 'Added column class_name to access_keys';
  END IF;

  -- is_active
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'access_keys' AND column_name = 'is_active'
  ) THEN
    ALTER TABLE access_keys ADD COLUMN is_active BOOLEAN DEFAULT true;
    RAISE NOTICE 'Added column is_active to access_keys';
  END IF;

  -- created_at
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'access_keys' AND column_name = 'created_at'
  ) THEN
    ALTER TABLE access_keys ADD COLUMN created_at TIMESTAMPTZ DEFAULT now();
    RAISE NOTICE 'Added column created_at to access_keys';
  END IF;
END $$;

-- 创建缺失的索引
CREATE INDEX IF NOT EXISTS idx_access_keys_key ON access_keys(key);
CREATE INDEX IF NOT EXISTS idx_access_keys_active ON access_keys(is_active) WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_access_keys_batch ON access_keys(batch_id) WHERE batch_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_access_keys_course ON access_keys(course_name) WHERE course_name IS NOT NULL;

-- 验证：查看表结构
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_name = 'access_keys'
ORDER BY ordinal_position;
