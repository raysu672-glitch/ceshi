# MEMORY.md - 长期记忆

## 项目信息
- **项目**: 雅思训练平台（IELTS Training Platform）
- **路径**: G:\网站\同义替换\
- **类型**: 多模块教育训练平台，模块化架构

## 目录结构（2026-05-15 v2 重构）
```
G:\网站\同义替换\
├── index.html              ← 平台入口（用户名+密码登录/注册 + 密钥绑定）
├── shared/tracker.js       ← 统一埋点 SDK v6（含认证+遗忘曲线+密钥）
├── modules/synonym/        ← 同义替换模块（随机+复习双模式）
│   └── index.html
├── modules/sentence/       ← 长难句模块（待开发）
├── admin/index.html        ← 教师管理端（5个Tab+Excel导出）
├── student/index.html      ← 学生历史页（4个Tab）
└── supabase/
    ├── schema.sql          ← 数据库 Schema（= full_schema.sql）
    └── full_schema.sql     ← 完整可执行 Schema
```

## 技术决策
- 纯前端方案，模块化目录结构
- **统一埋点 SDK** (`shared/tracker.js`)：所有模块共用
- **数据存储**：IndexedDB 离线队列 → Supabase 批量上报
- **Supabase**：PostgreSQL + RLS 行级安全 + 实时订阅
- 暗色主题 + 霓虹效果的游戏化风格
- Web Audio API 生成音效，Canvas 粒子特效
- **v2 学生身份系统**（2026-05-15 重构）：
  - 用户名+密码登录（替代姓名+密码）
  - 密码 SHA-256 哈希存 Supabase students.password_hash
  - 密码原文存 students.password_raw（管理员可查，学生忘了帮忙找）
  - 注册时一步绑定密钥+身份确认
  - 会话管理：session_token + session_expires
  - 记住我：7天 / 默认2小时
  - 登录失败5次锁定15分钟

## Tracker SDK v6（2026-05-15）
- `tracker.init({ module, supabaseUrl?, supabaseAnonKey? })`
- `tracker.startSession(meta)` / `tracker.endSession(summary)`
- `tracker.event('answer'|'skip'|..., { itemKey, correct, responseMs, combo })`
- 离线安全：先写 IndexedDB（event_queue + practice_history + memory_states），5秒批量上报
- 学生 ID 自动生成（stu_xxx 格式）
- **v6 认证系统**：
  - `sha256(message)` — SHA-256 哈希（Web Crypto API）
  - `registerStudent(username, password)` — 注册（调 register_student RPC）
  - `loginStudent(username, password, rememberMe)` — 登录（调 login_student RPC）
  - `createSession(rememberMe)` — 创建会话
  - `checkUsernameExists(username)` — 检查用户名唯一性
  - `validateKey(keyString)` — 验证密钥（返回 studentName/className/courseId）
  - `bindKeyToStudent(studentId, keyString, realName)` — 绑定密钥
  - `isLoggedIn()` — 检查 session 有效性
  - `logout()` — 清除 session（Supabase + localStorage）
  - `getUsername()` / `getStudentName()` / `getStudentClass()`
  - `setStudentProfile({ name, username, className })`
- 本地聚合：getDailyStats / getErrorItems / getBehaviorProfile / getSessionSummaries / getWrongAnswers
- 管理端：getAdminStudentsOverview / getAdminDailyStats / getAdminBehaviorProfile / getErrorHeatmap
- 遗忘曲线 API：updateMemoryState / getDueItems / getReviewSchedule / getMemoryOverview / getAllMemoryStates
- **v6 密钥管理**：
  - `batchGenerateKeys(count, courseName?, className?, expiresAt?)` — 批量生成（调 batch_generate_keys RPC）
  - `getKeys()` — 获取所有密钥（从 v_access_keys 视图）
  - `revokeKey(key)` — 撤销密钥
  - `adminLookupPassword(username)` — 管理员查询密码原文

## 数据库 Schema v2（2026-05-15）
- `modules` 表：模块注册（synonym, sentence, ...）
- `students` 表：**id, username(UNIQUE), password_hash, password_raw, real_name, class_name, bound_key_id(FK), failed_attempts, locked_until, session_token, session_expires, created_at, last_active**
- `access_keys` 表：**新增 course_name, expires_at, batch_id**
- `practice_events` 表：统一事件表（JSONB payload）
- `memory_states` 表：艾宾浩斯遗忘状态
- 视图：`v_student_summary`(含 username, real_name, bound_key, bound_course), `v_error_heatmap`, `v_behavior_profile`, `v_access_keys`(含 course_name, expires_at, batch_id, expired 状态)
- 函数：`upsert_memory_state()` 更新遗忘曲线
- RPC 函数（SECURITY DEFINER）：
  - `register_student(p_id, p_username, p_password_hash, p_password_raw)` — 注册
  - `login_student(p_username, p_password_hash)` — 登录+失败锁定
  - `bind_key_to_student(p_student_id, p_key_string, p_real_name)` — 密钥绑定
  - `batch_generate_keys(p_count, p_course_name, p_class_name, p_batch_id, p_expires_at)` — 批量生成
  - `check_username_exists(p_username)` — 用户名查重
  - `admin_lookup_password(p_username)` — 管理员查密码
  - `get_admin_students_summary()` — 学生摘要（含 username, real_name, bound_key, course）
  - `get_admin_daily_stats(days_int)` — 每日统计
  - `get_admin_behavior_profile()` — 行为画像
  - `get_admin_error_heatmap()` — 错误热力图
  - `get_admin_memory_overview()` — 记忆状态概览
- RLS 策略：students/access_keys 用 `FOR ALL USING (true) WITH CHECK (true)`，其余相同

## 同义替换模块
- 词库内嵌在 JS 中，约160组同义替换词
- 游戏化：连击、XP/等级、音效、粒子特效
- 已接入 tracker：6个埋点（init/startSession/answer×2/skip/endSession）
- **v3 新增**：错题专练模式（`?mode=review`）
  - 从遗忘曲线待复习词组中抽取
  - 优先展示即将遗忘的词组
  - 无待复习时回退到错误率最高的词组
  - 答题后自动更新记忆状态

## 学生端（student/index.html）
- 4个 Tab：概览 / 复习计划 / 练习记录 / 错题本
- 复习计划 Tab：
  - 记忆状态统计（已学/已掌握/学习中/待复习）
  - 记忆状态环形图（Canvas）
  - 待复习词组列表（保持率条 + 优先级徽章）
  - 7天复习日程
  - 一键跳转错题专练

## 管理端（admin/index.html）
- 5个 Tab：总览 / 学生画像 / 错题热力图 / 遗忘曲线 / 设置
- 学生画像表格显示「姓名」+「班级」列（班级蓝色标签）
- 学生详情弹窗标题格式：姓名 · 班级
- 遗忘曲线 Tab：
  - 全班记忆状态统计
  - 记忆状态分布条形图
  - 词组保持率排序（保持率最低的优先展示）
  - 7天复习日程预览
  - 学生详情弹窗增加记忆状态数据

## 第四期：密钥系统（2026-05-13）
- `supabase/schema.sql` 新增 `access_keys` 表 + `v_access_keys` 视图
- `shared/tracker.js` v4 新增5个方法：
  - `generateKeys(count, studentName, className)` — 生成密钥，优先写 Supabase，降级 localStorage
  - `validateKey(key, studentName)` — 注册时验证：有效/已使用/已撤销/预分配姓名匹配
  - `consumeKey(key, studentName, studentId)` — 注册成功后标记已使用
  - `getKeys()` — 管理端获取所有密钥列表（含状态）
  - `revokeKey(key)` — 撤销密钥（软删除，is_active=false）
- 密钥格式：`XXXX-XXXX-XXXX`（12位，排除 O/0/1/I 等易混淆字符）
- 支持 Supabase 云端 + localStorage 本地双模式（自动降级）
- `index.html` 注册表单新增「激活密钥」字段：
  - 必填，格式提示：`XXXX-XXXX-XXXX`
  - `handleRegister()` 改为 `async`，验证通过后才注册
  - 注册成功调用 `tracker.consumeKey()` 标记已使用
  - Enter 导航：`regPassword2` → `regKey` → 提交
- `admin/index.html` 新增「🔑 密钥管理」Tab：
  - 统计卡片：总数 / 未使用（绿色）/ 已使用（灰色）/ 已撤销（红色）
  - 生成区域：数量输入 + 预分配学生（可选）+ 预分配班级（可选下拉）+ 生成按钮
  - 密钥列表表格：密钥（等宽字体）/ 预分配学生 / 预分配班级 / 状态标签 / 使用者 / 使用时间 / 操作（复制+撤销）
  - JS 函数：`loadKeys()` / `handleGenerateKeys()` / `handleRevokeKey()` / `copyToClipboard()`
  - Tab 切换时自动调用 `loadKeys()` 刷新
- 使用流程：老师生成密钥 → 分发给学生 → 学生注册时输入密钥 → 验证通过完成注册

## 四期路线
1. ✅ 第一期：SDK + 数据基础（已完成）
2. ✅ 第二期：管理端 + 画像 + 错题热力图（已完成）
3. ✅ 第三期：遗忘曲线 + 学生端增强（已完成）
4. ✅ 第四期：密钥激活系统（已完成）

## Supabase 云端部署（2026-05-14）
- **项目 URL**: `https://jhmcyiilfndpdiyutnzu.supabase.co`
- **GitHub 仓库**: `https://github.com/raysu672-glitch/ceshi`
- **部署状态**: 前端代码已配置，后端 Schema 待导入
- **已配置模块**:
  - `modules/synonym/index.html`
  - `student/index.html`
  - `admin/index.html`（默认可覆盖）

## Bug 修复记录
- **2026-05-14**: 修复注册时密钥验证失败（"无效的激活密钥"）
  - **根因**: `index.html` 未调用 `tracker.init()` 传入 Supabase 凭据，导致 `validateKey()` 无法查询 Supabase，降级到 localStorage 查不到密钥
  - **修复**: 在 `index.html` 初始化段添加 `tracker.init({ module: 'platform', supabaseUrl, supabaseAnonKey })`
  - **教训**: 所有使用 tracker 密钥功能的页面都必须初始化 tracker 并传入 Supabase 配置

## 下一步
- 在 Supabase SQL Editor 中执行 `supabase/schema.sql`

## 用户偏好
- 偏好游戏化学习体验
- 重视视觉效果和交互反馈
- 暗色主题设计偏好
- 平台需具备后续灵活性，支持多模块统一监控
