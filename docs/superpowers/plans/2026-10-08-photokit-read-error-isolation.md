# PhotoKit 单项读取错误隔离 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development。用户已经明确批准容错行为，沿用当前 worktree 和已选子代理执行方式，不重复询问是否实施。

**Goal:** 单张 PhotoKit 图像读取出错时持久记录并跳过当前尝试，其他照片继续建指纹，健康索引可发布且缺口可追溯。

**Architecture:** 在现有 reader 边界标记明确的图片读取错误；coordinator 仅处理这个分类，Store 以任务的 `failure_kind` 保留缺口和重试。保留原 publication、上下文及发行身份检查；不新增队列、数据库或原片读取路径。

**Tech Stack:** Swift、PhotoKit、SQLite schema v7、Core ML、XCTest；最低 macOS 13。

**Spec:** [高级判重设计](../specs/2026-09-28-photosync-0.2.0-advanced-dedup-design.md) §4.3.1、§4.4、§5–6。

## Global Constraints

- 基线产品 `b15742f`，本轮文档基线 `20d360a`。SSCD FP16、ANE/GPU、0.98、SQLite 精确评分、512 MiB 与单物理消费者不变。
- 源目录严格只读；真实验证只读 Photos，绝不访问生产同步库或启动生产 App。个人原片／ID／向量及 QA 文件只在 ignored 私有目录。
- 本次不修中性通知延迟消费导致的重复推理，不增加原片导出 fallback，不给私人失败照片创建公开 fixture，不更改来源文件失败规则或视频行为。
- 单项读取错误只表示已记录的覆盖缺口，不是假向量、损坏判定或源文件 skipped。授权、未知变化、网络等待、模型和数据库失败不能被放行。
- 迁移保持源码两份 schema 一致、拒绝未知高版本、保留成功／unknown 历史，不能删库重置。迁移与分类状态改变均需事务。
- 保留既有 UI 结构和原生控件；本轮只补进度／日志事实。无合并、推送、发布或安装。

## Review Focus

- 实际 `NSCocoaErrorDomain/-1` 必须从 PhotoKit 回调分类为可隔离错误；同域错误若来自模型或 SQLite，不能误放行。
- 有读取错误的可用索引只检索健康向量；陈旧向量、孤立／错配任务、pending 和未知故障不能靠 failure_kind 绕过完整性检查。
- 重试恢复增加候选时旧 token／prepared source 必须失效；再次同类读取失败不反复撤销健康发布。
- 中性对账保留分类／期限，未知或相关变化撤销分类，晚到成功／失败不能复活旧任务。
- 旧库 NULL 分类、失败迁移回滚和大规模查询的索引／内存行为；不能为新 readiness SQL 全量读取向量。

### Task 1: 产品单项错误分类、持久化及发布语义

**Ownership:** 一个实现者负责 `PhotosRepresentationReader.swift`、`PhotosIndexCoordinator.swift`、`SyncStore.swift`、`Schema.sql`、`AdvancedDedupTypes.swift`、`SyncRuntime.swift` 的必要接线，以及对应现有 Tests。不要拆分这些耦合修改并行编辑。

**Interfaces:** 在现有 `PhotosRepresentationError` 中提供明确的回调读取错误及可隔离判定，保留 domain/code/detail；`failRepresentation` 增加默认 NULL 的失败分类参数。`IndexProgress` 增加默认 0 的 `readErrorRepresentations`，ready 计数保持真实向量数。具体 helper 命名可沿用项目习惯，但不能通过解析错误字符串分类。

- [x] **Step 1 — RED。** 用 fake PhotoKit callback 注入与实测同形的 Cocoa -1，证明一个失败和健康兄弟项最终能发布可用索引，失败项无候选，日志带单项读取阶段。先观察原代码对此行为失败；保留网络／模型／数据库／取消／占槽仍阻断的对照，避免仅测试计数。
- [x] **Step 2 — 最小实现。** 在终结回调／单图解码边界分类，coordinator 不把任意 catch 当读取错误；分离取图、推理和持久化失败语义。schema v7 在 fingerprint_task 增加 nullable failure_kind（约束 NULL/photos_read），所有旧版迁移同一事务并默认 NULL；不新增表或改表示状态 CHECK。
- [x] **Step 3 — 发布与重试。** 非阻塞错误保留 task/retry deadline；完整性校验同时核对错误任务与 failed 表示的上下文、修订、版本、代次及发行事实。只有 ready 行可检索，publication/entryCount 反映实际候选；错误恢复／转为阻塞时原子推进索引代次和撤销发布，稳定重复读错只更新错误和期限。未知失效清分类、中性变化保留；不延后无关任务。
- [x] **Step 4 — 日志与回归。** 新进度字段区分 read errors 与 waiting，coordinator 转发、runtime 日志计数一致；不用错误数充 ready/excludedAssets。覆盖重开库、各旧版迁移／回滚、未知高版本、陈旧任务／损坏分类、original/current 分别失败、恢复使旧准备结果失效、稳定读错不引发无效发布。资格／物理租约测试不退化。
- [x] **Step 5 — 聚焦 GREEN 与提交。** 正常 build-for-testing、相关无宿主 XCTest；只用 fake、自制图像和 UUID SQLite。记录 RED/GREEN、实际命令和返回码，提交这一整体实现，不在该阶段重复 canonical。

### Task 2: 独立审阅和最终集成验收

**Ownership:** reviewer 只读本单元完整差异，原实现者负责范围内修复；tester 不改代码，root 更新文档和 ledger。

- [x] **Step 1 — 深度集成审阅。** 一次审阅覆盖 spec/quality、迁移、并发／publication、错误边界及调用方；满足本单元最终审阅，不重复旧大分支审阅。修复后只复核差异。
- [x] **Step 2 — 最终 canonical。** `python3 scripts/validate.py --output-dir "$PWD/work/validation-read-error-isolation-<unique>" --derived-data "$PWD/work/validation-read-error-isolation-<unique>-derived"`。完整 XCTest、Tools、实际模型、四档规模及续体探针；关注 readiness SQL 仍使用元数据索引、不加载全部向量。记录真实 skip/失败，不能放宽性能或数值门槛。必要时补正常 Universal Release 构建，Intel/macOS 13 实机仍保留既有缺口。
- [x] **Step 3 — 绑定结果。** 更新 PhotoKit contract、本计划／spec 状态、真实测试计划及脱敏验收记录；不把自动验证当成真实 Photos 通过。

### Task 3: 调整只读 QA 并恢复既定真实测试

**Ownership:** 新的 ignored `work/real-photos-icloud/20261008-read-error-isolation/`；root 负责恢复副本／scope，单个实现者改宿主，reviewer 审变化，tester 验证并独占真实运行。

- [x] **Step 1 — QA 只容忍产品明确分类的错误。** 从已审阅宿主复制，绑定最终产品提交；539 向量／1 失败原库保留，复制后走真实 v7 迁移／历史核对。读取预算区分已分类单项错误与其他失败；正常批次继续条件可以接受前者，后者仍按原 gate 停止。旧精确许可机制若保留，摘要必须包含新增分类，不能用泛化许可掩盖全局失败。对 readiness／结果导出分别记录完整 metadata、可用向量、读取缺口，不声称全照片取图成功。
- [x] **Step 2 — 离线审阅和验证。** fake-only 验证单项读错／健康兄弟项可跨批推进、阻塞错误仍停止、到期恢复、旧控制拒绝、mutation=0；完整哈希／签名及恢复库未被自测改写。只有这些通过后才建立新执行门闩。
- [ ] **Step 3 — 恢复 MB2–MB7。** 经 LaunchServices 正常授权入口启动唯一宿主，每批仍 500 请求／30 分钟，单物理消费者；检查点检查记录过的单项错误后可顺序继续。拿到新语义下的有效 token 后继续 MobileBackup 50 张试点、全量扫描和既定独立／双向盲审；报告所有缺口及分母。不重新调阈值、不写 Photos、不扩大为原片 fallback 测试。

### Task 4: 按错误事实恢复只读测试（2026-10-09 用户修订）

**原因：** Task 3 实测隔离了两项 PhotoKit 读取错误，但后续一次取图超时连带两次资源占用拒绝。底层请求已结束、宿主正常退出，保留 839 个 ready 向量。原 QA 恢复入口写死 `failureFacts.count == 1`，是代理针对早先单个失败案例添加的实现限制，不是用户批准的产品要求；本次明确取消，不改成另一固定错误数量。

**Ownership / scope:** 新的 ignored `work/real-photos-icloud/20261009-read-error-recovery/`；一个实现者负责宿主与 fake 回归，root 负责计划／scope／恢复副本，独立 reviewer 与 tester 分别审阅和验证。产品 `a190279` 不变，复用已完成的 canonical，不重跑无关模型／规模测试。旧宿主、839 向量原库和所有证据封存保留。

- [x] **Step 1 — 最小恢复修正与 RED/GREEN。** 有效 `photos_read` 缺口数量不限制正常推进。其他失败需复核当前完整失败集合和错误来源，恢复许可绑定完整摘要、会话及检查点；不限制失败项恰好为一条，也不因上批触发错误计数暂停而永久拒绝恢复。保留单物理消费者、资源归零、诊断／数据库健康、发行身份／版本及只读不变量校验。授权／图库／模型／数据库故障未恢复不能仅靠人工摘要放行；本次已明确定位且物理请求已结束的超时／资源暂不可用允许沿产品原退避与队列重试。不更改数据库行、重置重试计数或把超时当作 `photos_read`。
- [x] **Step 2 — 聚焦独立审阅和最终宿主验证。** fake 覆盖至少三项有效失败的完整摘要恢复并处理健康兄弟项、改变失败集合或发行身份后旧许可拒绝、实际消费者未结束时拒绝、多个单项读错正常推进，以及带阻断事实不能发布 ready。500 次／30 分钟／每批错误暂停观察保留；每批错误暂停是检查点，不是整个会话可恢复错误数量上限。一次恢复只消费对应检查点许可，新批次继续按新的事实复核，无需用户重复批准同一已授权只读范围。保持普通代码签名／Photos 授权流程，尽可能沿用 QA 身份，不修改 TCC 或伪造签名来避免系统询问。
- [ ] **Step 3 — 从保留副本续测。** 新 QA 库通过只读 SQLite 备份从已停止旧 QA 库建立，核对 839 个向量和所有错误／重试事实保留；fake 不接触真实 QA 库。最终产物 hash／签名／自测通过后建立 scope 和门闩；唯一 runner 恢复 MB2，继续按错误性质和实际资源检查点复核，禁止并发新宿主或强行释放在途租约。完成索引后仍须源挂载恢复并核对冻结清单，才执行 MB3–MB7；不自动挂载。

## 执行状态

Task 1–2 已完成：产品快照 `a190279` 经独立深度评审及嵌套 NSError 修复复核通过，最终 canonical 为 571 项 XCTest（2 跳过、0 失败）、94 项工具测试、四档规模及两组恢复竞态全部通过；正常 Universal Release 构建通过。详见[验收记录](../../release/2026-10-08-photos-read-error-isolation-validation.md)。

Task 3 的新只读宿主已完成静态审阅、固定快照构建／签名，以及三个最终 fake 模式验证（Photos mutation 为 0）。恢复副本已通过最终 Core 的真实 v6→v7 迁移，539 个向量的键／字节及所有旧重试数据保留，15,369 个历史 failure_kind 均为 NULL，旧库字节未变。

10 月 9 日 Task 4 的恢复修正、独立审阅及最终宿主自测已完成，三条原超时／资源占用失败在真实重试中均自然恢复。恢复后的最新已完成检查点为 1,689 个 ready 表示、3 个单项读取缺口、0 项阻断；仍未获得完整 ready token。

10 月 9 日晚用户恢复 `/Volumes/home` 后，两次只读目录清单核对通过：4,986 个条目、3,017 个图片候选与冻结清单一致，无路径／类型／大小／mtime 差异或符号链接。原 50 组独立候选全部仍在最新 PhotoKit 清单中，保持原选择不重抽。网络等待在同一宿主的一次有界重试中已观察到原三项均正常读回，继续 MB2。源挂载门槛已解除；source-metadata 需独占宿主，扫描／预览导出仍要求完整候选就绪。没有修改产品源码、重建已通过产品验收或写入 Photos。
