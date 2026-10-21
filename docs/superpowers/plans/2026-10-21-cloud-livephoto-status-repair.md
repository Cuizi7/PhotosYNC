# 云端 Live Photo 与六状态修复实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking. 用户已批准并实施；沿用本线程串行实施方式，调查和最终评审可委派只读代理。

**Goal:** 让历史 Live Photo 能按需读取云端原件并续跑，统一菜单、设置与 hover 的六状态、进度和说明。

**Architecture:** 沿用现有 PhotoKit 原资源 reader、持久队列和写入槽位；补齐请求期限/物理完成所有权，并由 runtime 单独持有一个 Live Photo 工作任务。使用少量明确的实时事实生成同一份展示结果，不把后台队列、历史完成标记或原始错误文本直接当成整体状态。

**Tech Stack:** Swift / PhotoKit / SwiftUI / AppKit / SQLite / XCTest；现有 Xcode 项目，无新运行时依赖。

**Spec:** [修复设计](../specs/2026-10-21-cloud-livephoto-status-repair-design.md)。基线 `82a80e8`，隔离工作树 `c129/PhotosYNC`，分支 `codex/cloud-livephoto-status-repair`。

## Global Constraints

- 用户文案只有“正在准备／正在同步／等待恢复／已暂停／需要处理／同步完成”。
- 前两种显示可靠或不完整进度；小字只用“正在建立视觉索引”“正在配对 Live Photo”。下载、保存不独立展示。
- 最低 macOS 13；Universal arm64/x86_64；来源只读，不转码、不提高预算或全局并发、不改精确配对/清理保护与未知提交安全边界。
- Live Photo 原资源：请求期限 600 秒，外层逻辑等待上限 610 秒；512 MiB 总预算，128 MiB 磁盘保留。只有实际完成才能释放物理所有权。
- 保持 schema v11、四种来源文件状态、固定一次性任务键及成功历史；旧 unresolved 逐项恢复，已完成且未变化的项目不重做。
- 只做本轮修复；不实现此前的 UI 草图，不加设置，不启动生产 App、不读写生产库；用户后续已授权按正常流程 squash 合并 main 并本地发布 0.3.0 beta2（build 19）。

## Review Focus

1. 云端请求超过旧 60 秒、取消后晚回调或无回调：不丢成功结果、不提前释放占用、不重复请求同一资源。
2. beta1 已标记首次完成但仍有 unresolved，或重启期间有新变化：复用成功结果，只处理未完成和变化项，不能清标记重扫。
3. NAS 离线、视觉分析、Live Photo 读取和未知 Photos 提交并存：标题/进度来自真实活动和全局安全阻断，不能互相遮蔽。
4. 总量未知、两类检查重叠、只有一半的正常项目、保护性保留：不能造总百分比、把失败计成完成或永久显示“待清理”。
5. 单资源过大与共享预算暂满、权限变化、暂停后晚结果：原因分类正确，既不反复下载确定超限文件，也不放宽物理/提交守卫。

---

## 文件与接口安排

| 文件 | 责任 |
| --- | --- |
| `Sources/PhotoSyncCore/Photos/LivePhotoPhotosGateway.swift`、`PhotoKitGateway.swift` | 原资源联网、专用期限、取消和流式资源所有权及只读准入 |
| `Sources/PhotoSyncCore/Domain/LivePhotoTypes.swift` | 历史队列汇总、重试决策、Live Photo 实时活动事实 |
| `Sources/PhotoSyncCore/Sync/LivePhotoInventoryCoordinator.swift` | 一项识别、可重试/需处理分类与活动发布 |
| `Sources/PhotoSyncCore/Storage/SyncStore.swift` | 复用现有列的重试决策、汇总及主动重新尝试 |
| `Sources/PhotoSyncCore/Sync/LivePhotoCoordinator.swift` | 区分真实补齐活动、验证、恢复与终止保留结果的只读汇总 |
| `Sources/PhotoSyncCore/Sync/PhotosIndexCoordinator.swift` | 视觉 reconciliation、读取/计算的实时活动；维持单 catalog 会话准入 |
| `Sources/PhotoSyncCore/Sync/GlobalStatus.swift`、`SyncEngine.swift` | 六状态枚举和必要的真实来源工作事实 |
| `Sources/PhotoSyncApp/SyncRuntime.swift` | 独立且唯一的 LP 任务、暂停/恢复及合并快照 |
| `Sources/PhotoSyncApp/SyncStatusPresentation.swift`、`AppModel.swift` | 唯一状态投影、进度与精确文案 |
| `StatusMenu.swift`、`SourceSettings.swift`、`SyncProgressView.swift` | 复用展示结果，现有状态区域与 hover 保持一致 |
| `RibbonStatusIcon.swift`、`PhotoSync.xcodeproj/project.pbxproj` | 准备状态复用运行中标记；仅必要的枚举/目标成员调整 |

原则：直接扩展已有职责，不建全局下载服务、独立 ViewModel、持久化 UI 状态机或通用错误中心。只有出现批准目标内无法解决的实际依赖才增加文件，并先说明影响。

### Task 1: 云端原资源请求与物理生命周期

**Files:** `LivePhotoPhotosGateway.swift`、`PhotoKitGateway.swift`；仅必要时 `PhotoKitLivePhotoReader.swift`；测试 `Tests/PhotoSyncCoreTests/LivePhotoResourceTests.swift`。

**Interfaces:** 保留 `read(resource:purpose:budget:) async throws -> LivePhotoResourceLease` 与 `LivePhotoResourceRequesting.request(_:allowNetwork:receive:completion:)`。为 `LivePhotoRawResourceReader.init` 增加可注入 `requestTimeout: Duration = .seconds(600)`、`logicalTimeout: Duration = .seconds(610)`；期限用于此 reader，不改 `ReadExecutor` 全局默认值。增加 `LivePhotoRawResourceReader.admission() async -> PhotosReaderAdmission`，通过 `LivePhotoPhotosGateway.livePhotoReadAdmission() async -> PhotosReaderAdmission` 转发；复用已有 available/busy/draining/stalled 值。stream 使用一个锁保护的取消入口，所有取消来源共用至多一次的 requester cancel 调用。

- [x] 写 RED：将 `testInventoryNeverEnablesNetwork` 改成 `testInventoryAndCompletionAllowCloudOriginals`，fake 必须在 `allowNetwork=true` 时才返回成功；分别覆盖两个 purpose。
- [x] 写生命周期 RED：可控 PhotoKit fake 覆盖旧 60 秒阈值之后仍能成功、请求期限到达时 cancel 一次、cancel handle 晚注册、同步成功/失败、重复完成、晚到 data 与 terminal、取消后始终无 terminal。以缩短注入期限和受控时钟/门闩驱动，不实等 60/600 秒。
- [x] 写取消穿透 RED：调用 `read` 的 Task 被取消时，取消信号能越过 `ReadExecutor.executeAsync` 的非结构化 Task 到达同一个 stream，不能只测期限 timer。补读取期间加入无关资产仍接受、目标 revision/删除/未知变更覆盖/授权撤回均拒绝的 gateway 用例（`LivePhotoKitContractTests` 与现有 gateway fake）。
- [x] 写资源 RED：取消/超时后预算和 `ReadExecutor.snapshot().physicalOccupancy` 保持，terminal 后恰好归零；同资源再次进入不能启动第二个实际请求。准入在排空期间持续为 draining/stalled，正常 terminal 后回到 available。区分单个 stream 已超过上限与其他 lease 占用导致暂满。
- [x] 用现有 Xcode `build-for-testing` 和直接 xctest 的受影响用例确认 RED；把编译失败与期望行为断言失败分开记录。
- [x] 在现有 stream 上实现联网、期限与取消；原生 UTI 文件后缀、数据块落盘、completion 后版本复核、错误和物理槽位所有权保持。取消后忽略新增数据，实际 completion 前不清临时文件/字节预算；outer timeout 不能绕过仍占用的 reader。
- [x] 在 `PhotoKitGateway` 复用现有按资产读取票据及 active-read invalidation，目标描述再次核对；只读结果不因已覆盖的无关 generation 变化丢弃。协调器侧对应收口由 Task 2 完成；实际创建、验证、删除的 generation 守卫不变。
- [x] 运行 `LivePhotoResourceTests`、现有读取所有权/存储相关用例，全部 GREEN 后提交 `fix: allow bounded cloud reads for Live Photo identification`。

### Task 2: 旧队列恢复、重试分类与可靠计数

**Files:** `LivePhotoTypes.swift`、`LivePhotoInventoryCoordinator.swift`、`SyncStore.swift`；必要的明确失败类型位于现有 reader；测试 `LivePhotoInventoryTests.swift`、`LivePhotoStoreTests.swift`、`LivePhotoIdentityTests.swift`。

**Interfaces:** 增加 `LivePhotoInventoryRetryPolicy`（`automatic(nextRetryAt: Date)` / `requiresAttention`）；`recordLivePhotoInventoryResult(context:assetID:revision:observations:retryPolicy:)` 显式接收该决策。增加 `retryLivePhotoInventoryAttention(context:now:) async throws -> Int`。`LivePhotoInventorySummary` 在现有字段上增加 `pending`、`retryWaiting`、`requiresAttention`、`nextRetryAt`；`identified` 保持现有内部意义，不再作为用户文案。

- [x] 写 RED：从真实 schema v11 合成库写出“首次 completed + checked + unresolved”的 beta1 状态，重开库后只读取旧 unresolved；`completedAt`、任务键、成功历史和 catalog 调用次数不变。另测尚未完成的 queued 续跑和新 revision 重新入队。
- [x] 写 RED：临时云端失败持久为 60 秒后重试，未到期不启动；明确单资源超限/确定解析问题设置 unresolved+NULL deadline，自动 tick 不再反复下载；资源 revision 变化或主动重试只重开相应未完成项。共享预算忙/正常 deferred 不作永久失败。
- [x] 写计数 RED：checked、queued/needsDescriptor、自动等待、需处理相互独立；总数未知不当作零；无标识的确定结果计入 checked，读取失败不计入 checked。
- [x] 写身份观察 RED：读取期间加入无关资产仍能保存结果；目标变化/删除/未知变更覆盖不能写成 checked。衔接 Task 1 的按资产读取票据，写观察前再核对目标描述和持久 revision，移除身份观察的全库 generation 相等要求；实际 mutation 守卫不变。
- [x] 受影响测试确认 RED，再以现有 `status`/`next_retry_at`/observation payload 实现；汇总用现有索引与聚合，不加载全库 payload、不加 schema 或重置标记。不同错误按类型和发生阶段分类：metadata reader 明确返回的 unresolved 属于当前字节的确定解析问题，读取异常属于另一分支；不匹配诊断字符串。
- [x] GREEN：上述测试及现有历史分页、变化衔接、上下文锚点/暂停用例通过；提交 `fix: resume unresolved Live Photo work without rescanning history`。

### Task 3: 长读取不阻塞其他工作，发布明确活动事实

**Files:** `SyncRuntime.swift`、`PhotosIndexCoordinator.swift`、`LivePhotoInventoryCoordinator.swift`、`LivePhotoCoordinator.swift`、`LivePhotoTypes.swift`、`SyncEngine.swift`；测试 `AdvancedRuntimeTests.swift`、`LivePhotoInventoryTests.swift`、`LivePhotoCoordinatorTests.swift` 及现有 index coordinator 用例。

**Interfaces:** runtime 增加一个 `livePhotoWorkTask: Task<Void, Never>?`，由既有 tick 准入；`runAdvancedWork` 不再 await 原资源工作批次，但保留串行 catalog 入口。`LivePhotoActivity` 为 `idle / working(LivePhotoActivityKind) / waiting(nextRetryAt: Date?) / draining / requiresAttention(SourceIssue)`，其中 kind 为 `identification / completion`；两个 LP coordinator 均提供 `activity() async -> LivePhotoActivity`。`PhotosIndexCoordinator.activity() async -> IndexActivity`（idle / working / waiting）显式报告当前工作。`EngineSnapshot` 增加 `sourceActivities: [UUID: SourceActivity]`（scanning / submitting / waiting）、`indexActivity: IndexActivity` 及 `livePhotoActivities: [LivePhotoActivity]`；runtime 合并生产者快照。现有 progress/summary 仍承载数量，不从字符串推导活动。

- [x] 写 RED：held LP 请求期间，已有 tick 能完成另一段视觉索引、合并 Photos change/reconcile、推进健康来源扫描并刷新状态；同一时间最多一个 LP runtime task，不出现第二次同 asset 请求。
- [x] 写 catalog RED：分别先阻住视觉 catalog、先阻住 LP catalog，再触发另一方；另一方必须等待，不调用第二次 `beginCatalogSession` 覆盖旧 session。首次枚举放在 runtime 的串行 reconciliation 工作入口，独立 LP task 仅执行原资源识别和组操作，不自行开始 catalog。
- [x] 写 RED：暂停/权限撤回时不启动下一个读取或写入；在途读取结束/取消排空保留物理所有权，实际成功提交仍结算。恢复不会绕过 busy、unknown mutation、来源枚举屏障或 context/revision 守卫。
- [x] 写 RED：不设来源仍能处理 Photos-only 历史工作；重启恢复未完成项；未到期 retry 和 draining 不被当成正在工作，更不被当完成。覆盖源扫描等待索引的情况，不能因为 `activeWork=true` 就虚报实际同步。
- [x] 实现独立 owned LP task：每次一个历史 asset、最多一个 completion 操作，然后交回 tick；保留两 actor 的工作守卫与公共写入槽位，不把 inventory/completion 各开并行 worker。使用 Task 1 的准入：排空期间不再探发请求；其他共享资源竞争沿用 5/5/15/15/60 秒 deferred 曲线，不变成每秒一次重试。`waitForRound` 覆盖新 task；`current()` 能在长 await 中读取最新进度。
- [x] 仅增加终止保留结果的只读汇总，不改清理决策：已验证且因信息保护留下原项不算持续待清理；明确失败/未知删除仍保留对应失败或安全等待，禁止按 error 文案猜测。
- [x] 补组预算 RED/GREEN：两个必需资源各未超单项上限但固定工作集超总预算（缩小 fixture 等价于 300+300 MiB 对 512 MiB），不会每 60 秒重下；其他任务占用导致暂满则恢复后可继续。用 stream 已收字节和本组持有 lease 字节证明固定工作集超限，不靠一次全局 reserve 失败猜测。`LivePhotoOperation` 增加可选 `deferralReason: LivePhotoDeferralReason?`（protectedInformation / workingSetLimit / otherFailure），旧 payload 缺字段可解码；工作集超限保持原 stage、设暂停重试期限并显示需处理，主动重试不解除 unknown。不要提高预算或引入原片缓存。
- [x] 上述及现有 runtime、目录屏障、组预留、恢复用例 GREEN 后提交 `fix: keep Live Photo reads independent from index work`。

### Task 4: 六状态、进度与三个界面的同一投影

**Files:** `GlobalStatus.swift`、`SyncStatusPresentation.swift`、`AppModel.swift`、`RibbonStatusIcon.swift`、`StatusMenu.swift`、`SourceSettings.swift`、`SyncProgressView.swift`；测试 `GlobalStatusTests.swift`、`SyncStatusPresentationTests.swift`、`AppViewTests.swift`、受影响 GUIQA/`Tests/UIReview`。

**Interfaces:** `GlobalStatus` 使用 `preparing/running/waiting/paused/error/completed` 六个内部 case；用户文案逐字按 spec。`SyncStatusPresentation` 提供唯一总体状态及 `progressRows: [PreparationProgress]`；其嵌套值类型 `PreparationProgress: Identifiable` 的字段为 `id: String`（固定 visualIndex / livePhoto）、`subtitle: String`、`progressText: String?`、`fraction: Double?`、`explanation: String`。普通来源同步仍使用现有 `SyncProgressMetrics`，不加入这两类任务的进度分母。`AppModel`、菜单、设置与详情消费同一结果，不各自拼接“已完成”。

- [x] 写表驱动 RED：启动未知、缺配置/授权、用户暂停、纯准备、纯同步、两者重叠、一个来源失联而其他工作继续、所有工作等待、queued 未尝试、completed 标记+unresolved、未知创建/删除、保护性保留、下次扫描到期前的正常空闲。
- [x] 精确断言：活动状态只有六个标题；小字只用“正在建立视觉索引”“正在配对 Live Photo”；云端读取不成为第三种任务。`2 checked / 16222 inventoried / 626 unresolved` 的分子只能是 2，不能是 628，不能出现完成标题。
- [x] 写进度 RED：两项任务分别显示独立数量、总量未知只有数量/活动指示、不合成百分比；检查完成但组验证未完成不保留检查100%作为全配对进度。局部问题和需执行的动作始终可见。
- [x] 实现投影及最小视图复用；菜单、设置具有同样标题/数量，hover 移入目的、原件获取/流量、持久结果与续跑说明。去掉常显旧三计数、禁止下载说明以及保存/下载子阶段；保留来源问题、历史统计与本轮事件的独立口径。
- [x] 准备状态复用运行中图标，不重画品牌；同步 demo/GUIQA 和 exhaustiveness 断言。核对 hover 点按固定、键盘与 Escape；不添加新控制器或下载开关。
- [x] GREEN：逻辑测试与原生离屏明/暗、多来源、长原因、进度变化/浮层打开时切换验证通过；记录证据种类，不借用旧图冒充本轮。提交 `fix: unify preparation and sync status across app surfaces`。

### Task 5: 集成验收与文档交付

**Files:** `docs/specs/2026-09-18-runtime-state-and-recovery.md`、`docs/superpowers/specs/2026-10-21-native-live-photo-completion-design.md`、`README.md`，本轮独立验证记录；既有发布/历史验证记录不覆盖。

- [ ] 核对每项改动均对应本 spec；更新当前运行时契约中禁止联网、旧状态优先级、旧完成口径和相关说明。保留成功历史、暂停和未知结果安全契约。
- [ ] 用 fake 做跨组件验收：beta1 未完成历史 → 允许云端资源 → 网络失败恢复 → 检查/配对 → 完成；中途插入暂停、重启、NAS 断开、资源变化和未知提交，验证菜单/设置同步变化且无重复写入。
- [ ] 用户已授权发布：开发阶段运行受影响回归，最终 canonical 由 main 确切提交的 `scripts/package-release.sh --scale-profile full` 在不可变归档执行一次；使用独立发布路径，不覆盖旧证据。完整 XCTest、Tools、四档规模、两组 continuation GREEN/预期 RED 和源码 manifest 均须通过，不降低阈值。
- [ ] deep_reviewer 审阅最后集成 diff 与并发/持久化/状态边界；tester 独立核对同一快照验证证据。修复后重测受影响行为，最终完整验收覆盖最后行为/测试改动，不重复只读 review 已覆盖的相同快照。
- [ ] 准备针对真实 iCloud 的**只读**验证范围：一个可确认仅在云端的受控资产、原资源字节上限、只读工具身份与清理其私有临时文件；执行前确认实际资产/流量范围，不新增/编辑/删除 Photos 资产，不提交媒体。没有批准或条件不满足时明确留为未验证，不用 fake 代替。
- [ ] 交付修复提交、六状态真值表、自动验证与原生展示证据及真实云端验证结果/缺口。随后按用户授权及既有发布契约 squash 合并 main、更新 beta2 并本地打包；不安装、启动或公开远端发布。

## 自检与实施交接

- 本计划覆盖云端开关、长请求生命周期、旧队列续跑、无忙循环、活动快照、六状态、进度/hover、原生界面一致性及验证。
- 不建立新下载服务、不新增数据库版本、不将实现细节重新放回常显文案。
- 先串行完成 Task 1–4 的 RED/GREEN 和提交，再做 Task 5 集成验收；Task 1–4 已完成，Task 5 的最终发行归档验证进行中；精确结果由发行 provenance 与验证记录绑定。
