# MEMORY.md - 长期记忆

## 项目信息
- **项目**: 雅思训练平台（IELTS Training Platform）
- **路径**: G:\网站\同义替换\
- **类型**: 多模块教育训练平台，模块化架构

## 目录结构（2026-05-13 重构）
```
G:\网站\同义替换\
├── index.html              ← 平台入口（登录/注册 + 模块导航）
├── shared/tracker.js       ← 统一埋点 SDK v3（含遗忘曲线）
├── modules/synonym/        ← 同义替换模块（随机+复习双模式）
│   └── index.html
├── modules/sentence/       ← 长难句模块（待开发）
├── admin/index.html        ← 教师管理端（5个Tab）
├── student/index.html      ← 学生历史页（4个Tab）
└── supabase/schema.sql     ← 数据库 Schema
```

## 技术决策
- 纯前端方案，模块化目录结构
- **统一埋点 SDK** (`shared/tracker.js`)：所有模块共用
- **数据存储**：IndexedDB 离线队列 → Supabase 批量上报
- **Supabase**：PostgreSQL + RLS 行级安全 + 实时订阅
- 暗色主题 + 霓虹效果的游戏化风格
- Web Audio API 生成音效，Canvas 粒子特效
- 学生 ID 自动生成（localStorage 持久化）
- **学生身份系统**：注册（姓名+班级+密码）→ 登录验证 → 退出切换
  - 密码简单 hash 存 localStorage，key: `ielts_pwd_{name}_{class}`
  - 未登录时模块卡片灰掉不可点击
  - 子页面（student/synonym）检查登录状态，未登录跳转入口
  - tracker.isLoggedIn() / tracker.logout() / tracker.setStudentProfile()

## Tracker SDK v3（2026-05-13）
- `tracker.init({ module, supabaseUrl?, supabaseAnonKey? })`
- `tracker.startSession(meta)` / `tracker.endSession(summary)`
- `tracker.event('answer'|'skip'|..., { itemKey, correct, responseMs, combo })`
- 离线安全：先写 IndexedDB（event_queue + practice_history + memory_states），5秒批量上报
- 自动生成 studentId（stu_xxx 格式）
- 学生身份：isLoggedIn / logout / setStudentProfile / getStudentName / getStudentClass
- 本地聚合：getDailyStats / getErrorItems / getBehaviorProfile / getSessionSummaries / getWrongAnswers
- 远程查询（管理端）：getStudentsOverview / getErrorHeatmap
- **v3 新增**：遗忘曲线 API
  - `updateMemoryState(itemKey, correct, responseMs)` — 答题后自动调用
  - `getDueItems(limit)` — 获取待复习词组（优先级排序）
  - `getReviewSchedule()` — 获取7天复习日程
  - `getMemoryOverview()` — 获取记忆状态概览
  - `getAllMemoryStates()` — 获取所有记忆状态
- **v3 遗忘曲线算法**：
  - 间隔序列：1→2→4→7→15→30→60→120 天
  - 正确 → 递增间隔，降低难度
  - 错误 → 重置为0，10分钟后重新复习
  - 保持率 = exp(-经过天数 / 稳定度)

## 数据库 Schema（2026-05-13）
- `modules` 表：模块注册（synonym, sentence, ...）
- `students` 表：学生信息（含 class_name）
- `practice_events` 表：统一事件表（JSONB payload）
- `memory_states` 表：艾宾浩斯遗忘状态
- 视图：`v_student_summary`, `v_error_heatmap`, `v_behavior_profile`
- 函数：`upsert_memory_state()` 更新遗忘曲线

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
