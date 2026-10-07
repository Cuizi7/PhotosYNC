# PhotosYNC 0.2.0 高级照片判重集成 Implementation Plan

> **2026-10-07 设计修订，待实施：** 用户要求图库变化时保留有效指纹。以 spec §4.1–4.4 的“清单核对／单项内容有效性／publication 分离”为新约束；本计划下方对应条款和文末后续工作约束同步更新，不表示已实施或授权直接执行新代码。P1–P14 的历史提交、勾选及验证记录保留，但不能替代新失效粒度的验收。真实 MobileBackup 只读验证已在取图时复现全量回退阻塞，不能继续用部分索引判不重。

> **后续真实验收约束修订（2026-10-06）：** 用户确认没有独立环境，授权本机正在使用的生产图库和待导入目录测试，要求先只读、最后有防御的写入并恢复原状。以[修订后的真实 Photos＋iCloud 计划](../../release/2026-10-06-real-photos-icloud-validation-plan.md) V1–V5 为执行依据，替代本计划早期“独立测试图库/账号”的环境要求：隔离 QA 数据，真实目录 dry-run，最终最多 3 个新增，耐崩溃台账与精确 ID 回退；最近删除、并发正常变化、缓存及 iCloud 传播单列核验。这里只更新计划，未执行真实测试，已完成的 P1–P14 代码验收不重做。

> **2026-10-06 P12–P14 收尾：** FP16＋ANE 优先、GPU 降级和原生状态修正已完成，最终实现冻结于 `bc27a425`。独立深度审阅通过；完整 canonical 通过 521 项 XCTest（2 项显式跳过、0 失败）、94 项 Tools、33 例实际模型回归、四档规模和两项恢复竞态。两条允许配置各通过四组数值自检及 33 例回归，正常 Universal Release 构建与资源核验通过。原生后台动作验证已做，完整 AX/键盘/VoiceOver/真实菜单弹出仍留缺口；Intel 实机跳过、macOS 13 无设备缺口保留。已另写[真实 Photos＋iCloud 验证计划](../../release/2026-10-06-real-photos-icloud-validation-plan.md)，本轮仅交付计划，未执行真实图库或发布操作。

> **2026-10-06 FP16 执行授权：** 用户选择研究方案 A（ANE 优先、GPU 降级），要求执行后端集成、原生交互收尾与最终验收，然后编制真实 Photos＋iCloud 验证计划。新增 P12–P14 承接这次授权；P1–P11 已完成部分不重做。Intel 实机验证跳过，用户确认无 macOS 13 Apple Silicon 设备、保留该实机缺口；最低 macOS 13 与 Universal 构建目标不变。本轮不执行真实图库测试或合并/推送/发布。

> **2026-10-06 指标修订历史基线：** 用户要求复核 250 ms 的依据并直接修正不合理指标。已确认其旧 FP16/all-compute 粗测依据及测量口径不适用于当时 FP32/CPU-only 后台准备；因此改为 `background-preparation-v2`，缓存命中与新来源准备统一 P95 ≤2 秒，纯查询仅独立报告。P10/P11 已完成；验收代码修订 `477284b` 已独立审阅并通过当次 canonical：495 项 XCTest（2 项显式跳过、0 失败）、92 项 Tools、33 例回归、四档规模和两项恢复竞态。此前 `1714857` 的 250 ms 失败保留；最新 FP16 结果见上方及文末，预算不变。

> **同日产品交互补充：** 用户已确认仅在点击菜单栏图标后的下拉面板展示图库分析，就绪时隐藏；首次自动分析，完成后静默进入同步；iCloud 等待提示与基础同步统计各占一行。用户明确要求实际实现继续使用原生控件。具体约束与验收见 P8，浏览器草图仅用于设计审阅。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将用户选定的 SSCD Large / 0.98 配置接入 Photos 持续索引、SQLite 恢复、串行导入及生产日志，保持来源只读和成功历史保护。

**Architecture:** SQLite 保存可恢复的表示、向量与决定证据，并在同一读事务中流式精确查询；不再建立全量常驻向量派生视图。一个 Photos gateway 负责有代次的变化集合、受影响资产读取与最终提交检查。索引协调器负责增量维护及周期完整对账，SyncEngine 保留既有单提交/unknown 恢复语义。保留 R2 指纹和 R3 精确评分规则，显式更新后端身份及相互绑定的配置/证据，不重新选择阈值。

**Tech Stack:** Swift / Foundation / PhotoKit / ImageIO / Core ML / Accelerate / SQLite / SwiftUI，macOS 13、Universal arm64/x86_64，XCTest 与现有 Python 验收入口。

**Spec:** `docs/superpowers/specs/2026-09-28-photosync-0.2.0-advanced-dedup-design.md`；并读 `docs/specs/2026-09-18-runtime-state-and-recovery.md` 和 `Design/Validation.md`。原始实施基线 `7937a9c` / schema v3；P10/P11 基线 `9186766` / schema v4（核对当前实际列与索引）。

## Global Constraints

- “只读来源；Photos 只新增，不修改、替换、删除已有资产。”导入原始 URL，`shouldMoveFile = false`。
- “保留四种文件状态 `pending`、`importing`、`imported`、`skipped`”；不加产品人工审核环节。
- “视频保持 0.1 的文件名与 metadata 策略”，不增加 RAW 来源、视频抽帧或 Live Photo 配对。
- “不加入 pHash、第二个核验模型、服务端模型或独立向量数据库服务。”P12 按用户明确授权使用 SSCD Large FP16、Float32 IO、ANE 优先与一次 GPU 降级（spec §7.1）；不允许 CPU-only 兜底。保持全画面 stretch 320×320、sRGB、1024 维 L2 Float32 和 `score >= 0.98`。查询仍为 `sqlite-exact-f32-v1`，原 Float32 点积与 Swift 同分排序不变，不引入 ANN。
- “应用运行时每 30 分钟”核对 Photos 清单；现有 `ScanSchedule.interval = 1_800`，不叠加、不补跑所有过期周期。
- “读取失败、索引未完成等属于未知，等待恢复，不能等同于‘不是重复’。”已观察到新增/变化立即挡住新提交。
- “不得持数据库锁等待 Photos、下载或模型。”任意 await 后重新核对暂停、来源状态、stamp、图库和索引代次。
- “取消与超时不能绕过仍占用的实际资源槽位”；模型物理并发 1、batch 1，其他上限使用固定 integration profile，不自填默认值。
- 每次启动只加载一份不可变配置并注入全部组件。阈值从 decision/profile 读取（本版 0.98），各组件只消费 `configuration.threshold`，不另设阈值常量。以后显式更新配置、重启生效；只改阈值会改变 policyVersion，复用同 fingerprintVersion 的向量，不加入热更新、阈值滑杆或自动调参。
- “旧已提交结果和成功历史不得因此重新导入”；未知高版本 schema 拒绝打开，不清库重置。
- 现有日志轮转“10 × 10 MiB”；不记原图、完整向量或 metadata 全量转储，不自动上传。
- 保持 macOS 13、Universal、现有 bundle identity、数据目录 `Application Support/PhotoSync` 和本地 ad-hoc 发布契约。
- 界面沿用 SwiftUI / AppKit 原生控件。浏览器原型只表达信息层级和交互，不嵌入 App、不用 WebView 重现页面，也不照搬网页的 CSS、阴影、颜色或像素尺寸。
- 当前 33 个固定回归用例不等于封存阈值集；历史 v1 的 44 例仍须保留为已见样本；用户附件的公开分发许可仍未补全，不打包这些图片进 App、不自行推送。

## Review Focus

- Photos 编辑/删除/撤权恰好发生在最后一次 await 后：P2/P4/P6 的门闩测试必须使旧决定不能提交，晚到指纹不能复活旧表示。
- iCloud 只回 degraded 或取消后迟到 final：P2 不标记 ready；逻辑超时后真实请求继续占槽，不能无界重开请求。
- 两个来源的同图 pending 与候选停用/消失交错：P5 只能建立有向较早依赖，失效可重判，不伪造成功历史。
- 原图大而编辑版小、尺寸未知或多帧容器：P2/P6 不借另一表示尺寸跳过；未获验证的图像表示不能用单帧分数自动丢弃内容。
- 中途退出迁移、来源改动、模型版本升级与成功回调交错：P1/P7 保留 success/unknown，恢复批处理不越过条件、不计成新导入。

---

## 执行门槛与文件边界

P1 起使用下面四份已提交、相互绑定的记录。用户在 2026-10-05 明确变更了“先取得 R4 独立统计 pass”这一前置条件；不再补独立校准/封存研究，也不伪造 `accepted-profile.json` 或统计通过。

| 源记录（`docs/research/advanced-dedup/`） | Bundle 文件名 | 校验责任 |
| --- | --- | --- |
| `integration-decision.json` | `decision.json` | 用户决策依据、0.98、模型/预处理/运行配置及 active suite；原始字节 SHA 为 decision ID |
| `integration-profile.json` | `profile.json` | 合法 DedupConfiguration；`acceptanceID = user-decision:<decision SHA>`；阈值、fingerprintVersion、policyVersion 和后端一致 |
| `2026-10-05-threshold-098-regression.json` | `regression.json` | 固定 33 例内容/动作全部通过，绑定决策、配置、真值及输入向量；不是独立验收 |
| `research-closeout.json` | `closeout.json` | `closed_with_user_selected_configuration`、`approvedForProductIntegration=true`，绑定前三份；`statisticalAcceptance.status=not_performed` 如实保留 |

四份文件按原字节复制，不重新序列化改变哈希。加载器按上表固定文件名解析引用，不追随研究记录里的 `work/` 路径；不能把旧 `research:` 配置误作生产配置。原协议和旧研究 `evaluate` / `accept` 保持历史拒绝逻辑。模型分发许可、产品回归、资源/系统/平台验收仍由 P9 核实；选定阈值不代表这些已通过。本次不修改生产库、不启动生产 App。

现有接点（行号是 `a855367` 的定位提示，实际按符号核对）：

- `PhotosGateway.swift:9-83`：`PhotosCandidateValidity.commitIfCurrent(_:)`、`PhotosCandidateSnapshot.generation`、带 `expectedGeneration` 的 `create`。
- `PhotoKitGateway.swift:57-105,254-304`：已有 observer 和轻量资源文件名索引；**尚无**原始/当前图像读取实现。
- `SyncStore.swift:144-199,262-301,375-425,558-575`：保存、提交/成功、keyset 队列、本地较早候选与迁移。SQL 私有 helper 留在同一文件，不为本次工作泛化一套 repository。
- `SyncEngine.swift:496-515,621-797`：已有记录 stamp 不变便跳过，新增文件准备、drain 判定与提交；因此旧 skip 需要单独批处理。
- `SyncRuntime.swift:227-260`：一个长期 engine/gateway/executor；stop 不取消已提交 Photos 写入。

| 新增/修改位置 | 单一责任 |
| --- | --- |
| R2/R3 的 `AdvancedDedupTypes.swift`、`CoreMLFingerprinter.swift`、`ImagePreprocessor.swift`、`ExactVectorIndex.swift`、`AdvancedDuplicatePolicy.swift` | 直接复用；本阶段只补集成值类型，不另造 matcher |
| `Sources/PhotoSyncCore/Storage/SyncStore.swift`、`Schema.sql` | v3→v4 事务迁移、向量事实、决定证据和成功历史 |
| `Sources/PhotoSyncCore/Photos/PhotosIndexGateway.swift`、`PhotosRepresentationReader.swift` | typed 清单/变化/表示请求与回调；实现接入现有 PhotoKitGateway 的同一有效性门 |
| `Sources/PhotoSyncCore/Fingerprinting/ImageWorkBudget.swift` | 来源/PhotoKit 共用在途图像数量与字节额度；物理完成释放 |
| `Sources/PhotoSyncCore/Sync/PhotosIndexCoordinator.swift` | 全量对账、增量失效、可恢复建设与就绪发布 |
| `Sources/PhotoSyncCore/Matching/AdvancedDedupService.swift` | 来源 fingerprint 缓存、全候选查询和带一致性令牌的决定 |
| `Sources/PhotoSyncCore/Sync/LegacySkipReevaluation.swift` | keyset 批处理符合条件的旧疑似重复项 |
| `Sources/PhotoSyncCore/Logging/DedupDecisionLog.swift` | 有界结构化决定字段，复用 RunLogger 轮转 |
| `Sources/PhotoSyncCore/Sync/SyncEngine.swift`、`ScanSchedule.swift`、`GlobalStatus.swift`；`Sources/PhotoSyncApp/SyncRuntime.swift`、`AppModel.swift`、`SyncStatusPresentation.swift`、`StatusMenu.swift`、`SourceSettings.swift` | 串行导入、调度、暂停与聚合 UI 接线，不扩来源规则 |
| `Sources/PhotoSyncCore/Resources/AdvancedDedup/`、`PhotoSync.xcodeproj/project.pbxproj` | 固定模型、配置/决策证据及实际适用许可的 framework 资源成员关系 |
| `Tests/PhotoSyncCoreTests/`、`Tests/Tools/`、`scripts/validate.py`、`scripts/package-release.sh` | fixture/fake/临时库回归与正式包校验，不自动读个人图库 |

### 跨任务值类型（P1 定义，其他任务按此使用）

均放 `AdvancedDedupTypes.swift`，值类型 `Codable, Equatable, Sendable`（含 closure 的类型只 Sendable）；所有 ID 为不透明值，不从文件名推导。

- `LibraryContext { id: UUID, epoch: Int64 }`；`RepresentationKind = original | current`；`RepresentationKey { assetID: String, kind: RepresentationKind }`。
- `RepresentationDescriptor { key: RepresentationKey, context: LibraryContext, revision: String, size: PixelSize?, equivalentToOriginal: Bool, revisionIsReliable: Bool }`。revision 来自该资产修改线索/资源描述的规范化摘要，不是图像内容哈希；不可靠时不得声称未改变。
- `IndexToken { context: LibraryContext, photosGeneration: Int, indexGeneration: Int64, localRevision: Int64, fingerprintVersion: String }`，分别区分现有 Photos 的 Int 代次和 SQLite Int64 代次。
- `IndexState = preparing | updating | ready | waiting | paused`；`IndexProgress { state: IndexState, totalsKnown: Bool, totalAssets: Int, readyAssets: Int, totalRepresentations: Int, readyRepresentations: Int, excludedAssets: Int, issue: String? }`。未知总数用 `totalsKnown=false`，不以 0 冒充已扫描为空。
- `RepresentationTask { descriptor: RepresentationDescriptor, retryCount: Int, nextRetryAt: Date?, fingerprintVersion: String }`；`IndexPublication { token: IndexToken, entries: [VectorEntry] }`。
- `PreparedSource { fileID: UUID, file: SourceFile, fingerprint: Fingerprint, size: PixelSize? }`。
- `VectorSearchResult { matches: [ScoredCandidate], diagnostics: [ScoredCandidate] }`：matches 含全部达阈值候选；diagnostics 是有界最近候选，包含阈值以下分数，不参与跳过判定。
- `AdvancedEvidence { eventID: UUID, fileID: UUID, stamp: FileStamp, token: IndexToken, policyVersion: String, evaluation: DuplicateEvaluation, decisiveCandidates: [ScoredCandidate], diagnostics: [ScoredCandidate], timingsMS: [String: Double] }`。decisiveCandidates 只保留实际导致跳过的一个覆盖候选，或导入时最相关的一个命中；diagnostics 全部候选来源合并后最多 10 条，不把全部匹配 pair 持久化，不使用研究容量 `evidenceCandidateLimit=200000` 作为日志上限。
- `AdvancedAdmission { source: PreparedSource, evidence: AdvancedEvidence, validity: any PhotosCandidateValidity }`；`AdvancedPreparation = ready(AdvancedAdmission) | waiting(reason: String)`。

图像字节/CGImage 不进入 Codable 存储类型。`LoadedRepresentation`（P2）只在物理预算租约内存在，持有 `image: CGImage`, `orientation: CGImagePropertyOrientation`, `descriptor: RepresentationDescriptor`, `lease: ImageLease`；尺寸未知保留 nil，不用模型输入尺寸补齐。

各 Step 1 代码块给出该步骤的核心断言；变量由紧邻文字指定的 fake/临时库/门闩场景构造，不是额外未定义的生产 API。

测试命令：每 Pn 用独立 `work/Pn-derived` 执行研究计划的 `xcodebuild build-for-testing` 和无过滤 `xcrun xctest` 命令。最后运行完整 `python3 scripts/validate.py --output-dir "$PWD/work/validation-advanced-dedup" --derived-data "$PWD/work/validation-advanced-dedup-derived"`，路径必须不存在；以最终退出码、测试数>0及0失败为准。新增 Core/Test 文件同任务更新显式 PBX target membership。

### Task 1 (P1): schema v4 与可恢复的索引事实

**Files:** Modify `Storage/SyncStore.swift`, `Storage/Schema.sql`, `Matching/AdvancedDedupTypes.swift`, `PhotoSync.xcodeproj/project.pbxproj`; Create `Tests/PhotoSyncCoreTests/AdvancedDedupStoreTests.swift`。

**Interfaces:** Produces `DedupConfiguration.loadValidated(resourceDirectory: URL) throws -> DedupConfiguration`（校验上表的 decision/profile/regression/closeout 原始字节绑定、用户选择依据、0.98 与模型/策略/运行配置一致；缺失或不符即抛错，资源路径来自注入）；`SyncStore.beginIndexReconciliation(context: LibraryContext, photosGeneration: Int, fingerprintVersion: String) async throws -> Int64`、`upsertRepresentations(_ descriptors: [RepresentationDescriptor], generation: Int64) async throws`、`finishIndexReconciliation(generation: Int64) async throws`、`nextRepresentationTasks(now: Date, limit: Int) async throws -> [RepresentationTask]`、`completeRepresentation(_ task: RepresentationTask, fingerprint: Fingerprint) async throws -> Bool`、`failRepresentation(_ task: RepresentationTask, nextRetryAt: Date, detail: String) async throws`、`indexPublication() async throws -> IndexPublication?`、`markIndexPublished(token: IndexToken) async throws -> Bool`。`false` 代表修订/代次已过期，不能强制发布。

- [ ] **Step 1 — 写失败测试。** `testV3MigrationPreservesSuccessAndUnknown` 比较临时 v3 数据库迁移前后 success_id、success_metadata_json、attempt_id、placeholder_id、submitted_at、definitely_not_committed 原样；`testMigrationRollbackAndFutureSchemaRejection`：注入 DDL 失败后仍 v3，v5 拒绝打开；`testStaleTaskCannotPublish`：revision A 返回时库已是 B，complete=false；`testPartialReconciliationDoesNotDeleteUnseenAssets`：只有完整枚举结束才 tombstone 未见资产；`testUserSelectedConfigurationLoadsWithoutStatisticalPass`：当前用户决策及 33/33 回归有效，即使 statisticalAcceptance=not_performed 也可加载；`testMissingOrTamperedDecisionRejectsConfiguration`：缺任一绑定文件、旧 research profile 或哈希不符拒绝；`testThresholdMustMatchDecisionAndPolicyVersion`：单改阈值或复用旧 policyVersion 拒绝。
```swift
let published = try await store.completeRepresentation(staleTask, fingerprint: fingerprint)
XCTAssertFalse(published)
```

- [ ] **Step 2 — 跑 P1 红阶段命令。** 预期缺表/新 API 或新断言失败。
- [ ] **Step 3 — 实现 v4 事务迁移及接口。** 新表固定为 `dedup_index_state`（context/epoch/generation/published_generation/fingerprint_version/reconcile_cursor）、`photos_representation`（context+asset+kind 主键、revision、尺寸、equivalence、seen_generation、ready/pending/failed、vector BLOB）、`fingerprint_task`（表示键+revision+version 唯一、重试期限）、`file_fingerprint`（file_id+stamp+version+purpose 联合主键，purpose=current/success）、`advanced_match_evidence`（event/file/token/策略/动作/关键匹配）、`dedup_dependency`（file_id→candidate_file_id、candidate revision）、`dedup_recheck_progress`（目标策略、游标）。不新增成功历史表；success 指纹引用现有 file_record 成功记录且不级联丢失。扩 SQL Value/bind/read 支持 BLOB 并严格验证 Float32 little-endian 1024 项。在 AdvancedDedupTypes 实现配置验证加载入口，使用上表的单向绑定（decision → profile → regression → closeout，箭头表示后一项绑定前项）；生产入口不得对错误资源回退旧图片规则。
- [ ] **Step 4 — 验证重建与版本失配。** 增加断言：SQLite 已提交而派生索引未发布时 publication 可重建但 ready=false；旧向量版本不参与新查询；新 profile 不能重置 imported/unknown；只改阈值时保留相同 fingerprintVersion 的向量、失效旧策略决定；历史不可补齐不计入 Photos 必需任务。跑 P1 绿阶段，确认代码迁移和 `Schema.sql` 等价。
- [ ] **Step 5 — 提交。** `git add` 本任务列出的文件，`git commit -m "feat: persist recoverable advanced dedup index state"`。

### Task 2 (P2): PhotoKit 指定表示读取与共享物理预算

**Files:** Create `Photos/PhotosIndexGateway.swift`, `Photos/PhotosRepresentationReader.swift`, `Fingerprinting/ImageWorkBudget.swift`, `Tests/PhotoSyncCoreTests/PhotosRepresentationTests.swift`, `docs/research/advanced-dedup/photokit-contract.md`; Modify `Photos/PhotoKitGateway.swift`, `Photos/PhotosGateway.swift`, `Sources/ReadExecutor.swift`, `PhotoSync.xcodeproj/project.pbxproj`。

**Interfaces:** `protocol PhotosIndexGateway: PhotosGateway { func representationCatalog(offset: Int, limit: Int, expectedGeneration: Int) async throws -> RepresentationPage; func changes() -> AsyncStream<PhotosIndexChange>; func readRepresentation(_ descriptor: RepresentationDescriptor) async throws -> LoadedRepresentation }`；`PhotosIndexChange = assetsChanged([String]) | assetsDeleted([String]) | fullReconcileRequired | contextInvalidated`。`RepresentationPage { context: LibraryContext, generation: Int, descriptors: [RepresentationDescriptor], nextOffset: Int? }` 是历史示意接口。此次修订须显式区分稳定清单会话身份、原始通知序号与已覆盖事件终点（spec §4.1.3）；分页绑定同一枚举基线，末页 nextOffset=nil，基线失效才拒绝该枚举，不能单因中性通知序号前进就从头扫描。实际参数／字段需据此调整，不沿用一个 generation 同时承担三种语义。现有 `PhotoKitGateway` 同时实现两个协议，只有一个 observer/generation 有效性门。`actor ImageWorkBudget` 产生 `acquire(bytes: Int64) async throws -> ImageLease`；`ImageLease.finishPhysicalWork()` 幂等释放，共享于来源解码和 Photos 读取；不能在逻辑超时 defer 中释放尚未完成的任务。

- [ ] **Step 1 — 写失败测试。** `testDegradedThenFinalPublishesOnce`：degraded 不返回，最终满足版本质量才完成一次；`testCancelThenLateFinalDoesNotPublishOrFreeEarly`：取消不创建 ready，物理结束前槽仍占用；`testEditedDimensionsBelongToEditedRepresentation`：原始 4000×3000、编辑 1000×1000，两个 descriptor 的尺寸不互借；`testUnknownRevisionCannotReuseCachedImage`：nil/不可靠修改线索导致失效；`testUnsupportedAndMultiFrameAreExplicitlyClassified`：无法证明安全单帧等价的 GIF/TIFF/组合资源不从第一帧生成跳过证据。
```swift
XCTAssertEqual(publishedFingerprintCountAfterDegraded, 0)
XCTAssertEqual(occupiedSlotsBeforePhysicalCompletion, 1)
```

- [ ] **Step 2 — 跑 P2 红阶段命令。** 使用注入的 callback requester 和 fake catalog；不申请真实 Photos 权限。
- [ ] **Step 3 — 实现协议与 SDK 契约核对。** 明确使用公开 `PHImageRequestOptions.version` 区分 original/current，以最终高质量回调为唯一完成输入，处理 error/nil/degraded/cancel 与 `isNetworkAccessAllowed=true`。回调给出的已定向位图标为 orientation=up，未定向像素才携带其真实方向，禁止二次应用 EXIF 旋转。记录 macOS 13 SDK 中实际可用签名、原图/当前版尺寸的可信来源和 Live Photo 静态资源范围到 photokit-contract.md。不能可靠拿到对应原尺寸则返回 nil，不能借缩略图或别的表示尺寸。无法通过公开证据证明多帧/复合静态内容等价的格式先视为“不能自动跳过的支持输入”，成功读取后保守导入并记录原因；不得把读取错误归为已确认排除或借此扩大 RAW 支持。
- [ ] **Step 4 — 接入已有有效性和资源生命周期。** callback 先撤销可能过期的判重发布权限，再分类和合并事件；全局通知代次变化不能独自使所有图像输入失效。bounded 缓冲溢出设置不可被窄事件覆盖的“清单需重查”标记，按 spec §4.1 保留已知影响范围和向量，不将 fullReconcileRequired 等同于全库内容变化。源读取沿用 ReadExecutor 的 sourceID 公平/物理占用规则；共享图像字节预算与 PhotoKit request 上限另外约束。请求槽只在真实终止回调后释放，解码字节租约则由 LoadedRepresentation 持有到最后一次真实推理/消费完成，不能在收到 final 图像时提前释放。超尺寸结果不能继续生成无限额图像副本；记录实际返回尺寸和拒绝原因。预算统计覆盖 App 持有的图像，PhotoKit 内部缓存另实测，不声称可控制系统总内存。ImageIO 限制目标解码，不暂存图片到应用数据目录；请求目标大小不承诺 iCloud 字节上限。公开 API 若不能保证表示语义，报告并停止相关 skip 路径，不能伪称探针已验证。
- [ ] **Step 5 — 绿阶段与提交。** P2 单测绿，callback 多次/错误/晚回调及占槽门闩全部通过；仅记录本地 SDK/fake 证据，真实图库/iCloud 留待 P9。`git commit -m "feat: read versioned Photos representations with bounded resources"`。

### Task 3 (P3): 增量索引协调、清单对账与原子发布

**Files:** Create `Sync/PhotosIndexCoordinator.swift`, `Tests/PhotoSyncCoreTests/PhotosIndexCoordinatorTests.swift`; Modify `Storage/SyncStore.swift`, `Matching/ExactVectorIndex.swift`, `PhotoSync.xcodeproj/project.pbxproj`。

**Interfaces:** Consumes P1/P2 和 R2/R3；Produces `actor PhotosIndexCoordinator { init(store: SyncStore, photos: any PhotosIndexGateway, fingerprinter: any ImageFingerprinting, index: ExactVectorIndex, configuration: DedupConfiguration); func reconcile() async throws; func processDueWork(now: Date) async; func setPaused(_ paused: Bool) async; func progress() async -> IndexProgress; func readyToken() async throws -> IndexToken? }`。队列长度/分页批量必须受 R1/R4 资源配置约束，禁止一次创建十万个 Task。

- [ ] **Step 1 — 写失败测试。** `testNoChangeReconciliationDoesNoImageIO`：第二轮相同可靠清单读取/推理次数均为 0；`testSingleEditInvalidatesOnlyAffectedRepresentations`：仅有关表示变动，original 可证明未变时复用；`testRevertCoalescesEquivalentRepresentations`：撤销编辑不留重复向量；`testDeletedAssetAndLateResultNeverReturn`：删除后迟到结果被拒绝；`testOneFailedAssetDoesNotStopOtherIndexWorkButBlocksReady`：健康任务完成，readyToken 仍 nil。
```swift
XCTAssertEqual(secondUnchangedRoundReadCount, 0)
XCTAssertEqual(secondUnchangedRoundInferenceCount, 0)
```

- [ ] **Step 2 — 跑 P3 红阶段命令。** 以可控 change stream、注入时钟和模型调用计数断言，不使用 sleep 排序。
- [ ] **Step 3 — 实现对账与工作循环。** 建立上下文明确的稳定清单会话，按其身份分页；并持续保留从该基线到目标终点的完整变化集合，按 spec §4.1.3 顺序归并到 SQLite。已证实无成员／输入变化的通知仅推进覆盖终点，不使分页重启。未知缺口或基线失效仍阻断；完成后按最新覆盖终点和已提交索引版本作发布校验。启动/恢复/fullReconcile/context 事件核对轻量清单，不按拍摄时间或总数判断增量。完整枚举结束才清除消失资产；context 无法确认延续则关闭当前 publication，保留持久向量／任务／成功历史供后续核验。明确内容变化即使尺寸不变也使相关表示待重算；泛化的 fullReconcile 只触发非破坏性清单核对。复用须满足 spec §4.1.2 的上下文、指纹版本和内容连续性证据，不能仅看 revision 相等。暂停仅阻止新工作，已完成结果符合修订时可落库；失败按批准退避期限继续处理其他任务。
- [ ] **Step 4 — 发布与恢复。** SQLite 提交完成 → 构造同代次 ExactVectorIndex → 事务确认该代次仍满足必需覆盖 → markIndexPublished；任何一步 crash 后启动重建派生索引而非清事实库。完整性/向量数与 generation 不一致时 readyToken=nil，永远不把空索引伪装就绪。测试在这三步之间分别中断重启、在发布前插入变化，以及模型/预处理版本失配重算；索引格式单变只重建派生结构。
- [ ] **Step 5 — 绿阶段与提交。** 跑 P3 命令并核对最大在途值从未超出配置，`git commit -m "feat: maintain incremental Photos fingerprint generations"`。

### Task 4 (P4): 来源准备和全候选高级判定服务

**Files:** Create `Matching/AdvancedDedupService.swift`, `Tests/PhotoSyncCoreTests/AdvancedDedupServiceTests.swift`; Modify `Storage/SyncStore.swift`, `Sources/MetadataReader.swift`, `Matching/ExactVectorIndex.swift`, `PhotoSync.xcodeproj/project.pbxproj`。

**Interfaces:** `actor AdvancedDedupService { init(store: SyncStore, photos: any PhotosIndexGateway, coordinator: PhotosIndexCoordinator, fingerprinter: any ImageFingerprinting, index: ExactVectorIndex, configuration: DedupConfiguration, executor: ReadExecutor, budget: ImageWorkBudget); func prepare(fileID: UUID, file: SourceFile) async throws -> AdvancedPreparation }`。Store 提供 `fingerprint(fileID: UUID, stamp: FileStamp, version: String) async throws -> Fingerprint?`、`cacheFingerprint(_ source: PreparedSource) async throws -> Bool`、`localVectorCandidates(beforeOrder: Int64, excluding: UUID, version: String) async throws -> (revision: Int64, entries: [VectorEntry])`。beforeOrder 来自现有 `StoredFile.createdOrder`，不来自路径排序。增加 `ExactVectorIndex.searchWithDiagnostics(query: Fingerprint, minimumScore: Double, generation: Int64, diagnosticLimit: Int) throws -> VectorSearchResult`（actor）及 `static scoreWithDiagnostics(query: Fingerprint, entries: [VectorEntry], minimumScore: Double, diagnosticLimit: Int) throws -> VectorSearchResult`；同一次精确评分取得全部匹配及有界近邻，不为日志重复扫描。原 score/search 可保留兼容入口。

- [ ] **Step 1 — 写失败测试。** `testDifferentFilenameStillMatches`：改名不缩小候选域；`testSameFilenameCannotForceImageSkip`：异图同名仍由向量决定；`testReadFailureIsWaitingNotNoMatch`：未就绪/读取失败不能形成 `.importFile`；`testStampChangesDuringFingerprintDiscardsResult`：await 后 stamp 不同则拒缓存/决定；`testCurrentMatchCannotBorrowOriginalDimensions`：命中小编辑表示不得借大原图尺寸跳过；`testMissingOldHistoryFingerprintDoesNotBlockLibraryReady`：旧成功仍受身份保护但不假造向量匹配；`testBelowThresholdNearestIsDiagnosticOnly`：没有命中时仍记录最近分数且导入；`testCoveringMatchBeyondDiagnosticLimitStillSkips`：第 11 个以上的达阈值高清候选仍能决定跳过；`testThresholdChangeReusesFingerprintButNotOldDecision`：复用指纹，按新策略重新评分。
```swift
guard case .waiting = result else { return XCTFail("Unknown index must wait") }
XCTAssertEqual(createCount, 0)
```

- [ ] **Step 2 — 跑 P4 红阶段命令。** fake Photos/向量，不靠模型分数碰巧触发分支。
- [ ] **Step 3 — 实现 prepare。** 先查既有成功/unknown 保护；准备来源指纹时前后核对 stamp，方向/颜色共用 R2。读取图库 ready token 与其 validity，合并同版本 Photos、较早的有效 pending/importing、成功历史向量；用持久化规范化向量精确评分，对所有达阈值结果调用 R3 策略；不得用最多 10 条诊断候选限制决策候选。来源损坏等明确读取错误向上抛出沿用文件级重试；就绪不足返回 waiting。不可读旧历史只能沿旧身份保护，正常授权可读关联资源才补齐，绝不扫描停用来源。
- [ ] **Step 4 — 构造一致性证据。** AdvancedEvidence 记录表示 kind、原尺寸、实际 threshold、决定跳过的覆盖候选及有界最近候选。Photos 和本地候选分别取最近 10 条再合并为全局最近 10 条，含低于阈值的分数；关键决定候选另存，不受诊断上限截断。不缓存“无候选”跨代次或 policyVersion。读取到未知尺寸但有效图像/候选时保守导入；未知读取错误不能走此分支。图库 readyToken 与 candidateSnapshot.generation 必须一致；localVectorCandidates 返回的 revision 写入本次 IndexToken，局部候选用上述 static scoreWithDiagnostics 评分。localRevision 只保护该次本地候选决定，不因普通本地插入触发全库 Photos 重建。任一 await 后重新核对 token/stamp/暂停，失效返回 waiting 或重新准备，不能复用前一轮分数。
- [ ] **Step 5 — 绿阶段与提交。** 跑 P4 命令，`git commit -m "feat: prepare consistent advanced duplicate admissions"`。

### Task 5 (P5): 本地依赖、成功指纹和决定原子性

**Files:** Modify `Storage/SyncStore.swift`, `Storage/Schema.sql`, `Domain/MediaRecord.swift`; Test `AdvancedDedupStoreTests.swift`, `StoreTests.swift`。

**Interfaces:** Produces `commitAdvancedSkip(_ admission: AdvancedAdmission) async throws -> Bool`、`beginAdvancedAttempt(_ admission: AdvancedAdmission, attemptID: UUID) async throws -> Bool`、`markImported(fileID: UUID, attemptID: UUID, identifier: String, sourceFingerprint: PreparedSource?) async throws`（保留现有 3 参数 overload 转调 nil，视频不产生指纹）。false 是证据过期，不是成功 skip。Store 维护 localRevision，所有影响候选资格的操作都在同一串行写入路径递增。

- [ ] **Step 1 — 写失败测试。** `testOnlyOlderPendingCanBeDependency`：A/B 同图不能相互 skipped；`testDisabledOrMissingCandidateReopensDependents`：候选停用/确认未提交且缺失后，其 dependent 重新 pending；`testSuccessFingerprintSurvivesPhotosDeletionAndSourceRemoval`：当前 Photos 候选删除，历史指纹仍在；`testEvidenceFailureRollsBackSkip`：证据 INSERT 失败不能留下 skipped；`testLocalRevisionChangeRejectsAdmission`：准备到事务间候选变化，结果 false。
```swift
let dependentState = try await store.state(of: dependentID)
XCTAssertEqual(dependentState, .pending)
XCTAssertEqual(successIdentifierAfterCurrentAssetDeletion, originalSuccessIdentifier)
```

- [ ] **Step 2 — 跑 P5 红阶段命令。** 临时 UUID 数据库+故障注入；不使用生产库副本。
- [ ] **Step 3 — 原子写入。** 在现有 PhotosCandidateValidity.commitIfCurrent 同步边界内执行 store 事务，检查 file state/stamp、index generation、localRevision、candidate 仍有效及 created_order；同时落 skip/关键证据/依赖或 importing/attempt/准备指纹。不要把成功尚未成立的 pending 依赖写成 success_id。不持 DB 锁跨 await。按现有锁顺序保持 Photos validity → store 同步事务，事件不能反向持 store 锁等待 Photos。
- [ ] **Step 4 — 成功与依赖恢复。** 成功回调把来源指纹和相应原尺寸绑定到现有成功记录；晚到的成功不被候选失效/撤权覆盖。停用、移除、stamp 改变、确认缺失、明确不可再提交等事件使依赖失效并可恢复重判；unknown/importing 不当成未提交删除。失败时继续沿原 retry/unknown 语义，不为依赖新造文件状态。
- [ ] **Step 5 — 绿阶段与提交。** P5 全通过并回归既有 ordered-pending/history 测试，`git commit -m "feat: atomically persist dedup evidence and local dependencies"`。

### Task 6 (P6): 接入扫描与单提交恢复流程

**Files:** Modify `Sync/SyncEngine.swift`, `Sync/ImportRecovery.swift`, `Photos/PhotosGateway.swift`; Test `Tests/PhotoSyncCoreTests/AdvancedDedupEngineTests.swift`, `EngineTests.swift`, `RecoveryTests.swift`, `Tests/Regression/ContinuationRace.swift`（只有锚点确实改变才调整对应 harness）。

**Interfaces:** Extend `SyncEngine.init(..., advancedDedup: AdvancedDedupService?, indexCoordinator: PhotosIndexCoordinator?, ...)`；生产静态照片路径必须注入有效组件，nil 只服务既有 v1/video 测试和 demo，不能成为 0.2 发行静态照片 filename fallback。既有 `scanEnabledSources()`, `scan(sourceIDs:)`, pause/setPaused/drain 和 Photos `create(fileURL:kind:expectedGeneration:onPlaceholder:)` 保持职责。

- [ ] **Step 1 — 写失败测试。** `testInitialIndexBlocksCreateButAllowsScanPreparation`；`testThirdPartyChangeAfterLastAwaitPreventsCreate`（门闩在 beginAdvancedAttempt 及真实 create 前，变化后 create 次数 0）；`testOwnSuccessParticipatesBeforePhotosNotification`（连续同图第二项 skipped）；`testPauseOrSourceDisableAfterInferenceStopsNewSubmit`；`testVideoKeepsLegacyMatching`；`testLateSuccessAfterIndexInvalidationStillPersists`。
```swift
XCTAssertEqual(createCountAfterGenerationChange, 0)
XCTAssertEqual(secondIdenticalFileState, .skipped)
```

- [ ] **Step 2 — 跑 P6 红阶段命令。** 所有 Photos 使用 fake；断言具体 create 次数、DB state、success_id 和统计值。
- [ ] **Step 3 — 接入新文件与 drain。** 图像扫描只登记来源和已有历史，不用 filename 强制 skip；drain 中按稳定 created_order 准备并判定，跳过用 P5 原子 API，导入用 beginAdvancedAttempt 再以同一 Photos generation 调 create。就绪未知返回调度等待，不计成功/误报读取失败，不改变四状态。视频继续调用旧 DuplicatePolicy。每个 async 边界维持暂停/启用/stamp/context 再校验。
- [ ] **Step 4 — 保护恢复契约。** importing/unknown 先按既有 ImportRecovery 处理，不被重新指纹计算触发重提；placeholder 检查点失败仍未知。成功已确认但新索引失败时仍保存成功。保持单个 gateway 和一个实际提交；索引不可用不是重建 gateway 的理由。运行现有恢复/受控续体竞态测试，修正 harness 锚点时保留同一个“retry 已写入、旧错误尚未发布”的窗口。
- [ ] **Step 5 — 绿阶段与提交。** P6 通过并核对静态照片无旧规则旁路，`git commit -m "feat: gate photo imports on current advanced dedup evidence"`。

### Task 7 (P7): 可中断的旧策略疑似重复重判

**Files:** Create `Sync/LegacySkipReevaluation.swift`, `Tests/PhotoSyncCoreTests/LegacySkipReevaluationTests.swift`; Modify `Storage/SyncStore.swift`, `Sync/SyncEngine.swift`, `PhotoSync.xcodeproj/project.pbxproj`。

**Interfaces:** `struct LegacySkipCandidate { file: StoredFile, skipReason: SkipReason, submittedAt: Date?, definitelyNotCommitted: Bool, decisionPolicyVersion: String? }`；`SyncStore.legacySkipPage(afterOrder: Int64, limit: Int, policyVersion: String) async throws -> [LegacySkipCandidate]`、`reopenLegacySkip(fileID: UUID, expectedStamp: FileStamp, policyVersion: String) async throws -> Bool`；`actor LegacySkipReevaluation { init(store: SyncStore, stamp: @escaping @Sendable (SourceFile) async throws -> FileStamp, policyVersion: String); func processBatch(limit: Int) async throws -> Int }`。Legacy 在这里包含 0.1 及所有旧判定策略，不仅指文件名策略；nil decisionPolicyVersion 表示 0.1。progress 表保存目标 policy 和游标，批量限制沿配置，单项事务结束才推进游标。目标策略变化启动新的重判进度，同一版本重复执行幂等。

- [ ] **Step 1 — 写失败测试。** `testOnlyEligibleEnabledImageSkipsReopen`：只有启用/未移除来源、image、suspectedDuplicate、无 success_id、无 unknown/importing、stamp 未变且仍存在、决定策略为 nil 或不同于目标版本者重开；视频、sourceChanged、unsupportedFormat、停用来源逐项保持原状；`testCrashAfterReopenResumesIdempotently`：重启不重复计数；`testSourceMutationOrSuccessWinsOverReopen`：并发成功/stamp变化不得被批处理覆盖；`testNewThresholdRechecksOldAdvancedSkipsWithoutInference`：提高阈值后符合条件的旧高级 skip 重开并用已有指纹重判，既有 imported/unknown 不动；`testSamePolicyDoesNotReopenAgain`：同目标策略已完成项不反复重判。
```swift
XCTAssertEqual(reopenedIDs, Set([eligibleImageID]))
XCTAssertEqual(importedCountAfterReopen, importedCountBeforeReopen)
```

- [ ] **Step 2 — 跑 P7 红阶段命令。** 普通扫描 stamp 未变的 continue 路径不能代替此测试。
- [ ] **Step 3 — 实现筛选、stamp 检查和重开。** 不为全部 skipped 清标记；SQL 条件校验旧决定策略、保留 success_metadata 与提交恢复信息；只改阈值不清理指纹、不触发全库下载或模型推理。来源读取通过现有只读入口，离线/未知不推进该项为已完成；用 keyset cursor+单项待重试记录避免一个失败阻塞其他项或被永久越过。重开仅回 pending 交 P6，不能直接创造成功或增加 imported。
- [ ] **Step 4 — 验证来源恢复与提交。** 来源重新启用或重新添加时，将当前目标策略的重判重新排入现有进度流程，补扫已越过游标的旧项；可复用现有进度表从头扫描，以决定 policyVersion 排除已完成项，不新增服务或表。重新排入与在途批次的游标提交必须串行协调，启动时也核对是否存在当前启用来源中尚未应用目标策略的 skip，避免中断后遗漏。增加 `testReenabledSourceBeforeCompletedCursorIsReevaluated`：游标已完成后启用旧来源，旧策略 skip 用缓存指纹重判，同策略 skip、success/unknown 不重开；并覆盖来源重新添加及重新排入时退出恢复。P7 测试绿，再断言停止/恢复、批尾新加入来源与重复策略版本请求均可收敛；`git commit -m "feat: reevaluate eligible legacy duplicate skips resumably"`。

### Task 8 (P8): runtime 调度、聚合界面与诊断日志

**Files:** Create `Logging/DedupDecisionLog.swift`, `Tests/PhotoSyncCoreTests/DedupLoggingTests.swift`; Modify `Sync/ScanSchedule.swift`, `Sync/GlobalStatus.swift`, `Sync/SyncEngine.swift`, `Logging/RunLogger.swift`, `Sources/PhotoSyncApp/SyncRuntime.swift`, `Sources/PhotoSyncApp/AppModel.swift`, `Sources/PhotoSyncApp/SyncStatusPresentation.swift`, `Sources/PhotoSyncApp/StatusMenu.swift`, `Sources/PhotoSyncApp/SourceSettings.swift`; Test `ScheduleTests.swift`, `AppModelTests.swift`, `AppViewTests.swift`, `SyncStatusPresentationTests.swift`。

**Interfaces:** `DedupDecisionLog.maxDiagnosticCandidates = 10`，`DedupDecisionLog.fields(evidence: AdvancedEvidence, configuration: DedupConfiguration) -> [String: String]`；`EngineSnapshot.indexProgress: IndexProgress?`。Runtime 启动时通过 P1 loadValidated 装载一份不可变配置并注入全部组件，持有一个 gateway/coordinator/fingerprinter/index/budget/service，pause/resume/stop 转发；P9 装入正式资源之前测试使用显式注入资源目录，正常启动缺资源显示配置不可用并禁止静态照片新提交；`ScanSchedule` 增加 Photos 对账到期状态，仍 `interval=1800`，与来源扫描 tick 合并。

**已确认的产品交互与原生实现约束（2026-10-05）：**

| 项目 | 实现要求 |
| --- | --- |
| 菜单栏入口 | 保持 `PhotoSyncApp.swift` 现有 `MenuBarExtra` + `.menuBarExtraStyle(.window)`。菜单栏 label 只放状态 `Image(systemName:)`，保留辅助功能标签；不增加可见摘要、文字或进度数字。 |
| 分析区域位置 | 在点击图标后的 `StatusMenu` 下拉面板中，放于状态标题和来源同步信息之间；设置页保持既有来源/登录启动/通知职责，不另建图库分析页或独立窗口。 |
| 显示与隐藏 | 首次准备、更新、等待时显示；未完成分析被暂停时保留进度。图库就绪后整块移除，不留下“图库已就绪”一行或空白占位；就绪后仅暂停同步也不能让分析区域重新出现。后续确有分析工作/等待时重新展示。 |
| 首次使用/升级 | 已授权 Photos、至少一个来源启用且未暂停时自动开始分析，不增加“开始分析”确认步骤。首次说明“完成图库分析后开始导入”，以及部分照片可能从 iCloud 下载。就绪后在既有暂停/授权/提交条件允许时自动继续同步。 |
| 通知与暂停 | 不单独发送“图库分析完成”通知，保留既有同步通知设置及规则。沿用“暂停同步／继续同步”控制新分析与新导入；在途工作按既有规则收尾，保留已完成进度，不增加独立分析暂停开关。 |
| 分析进度 | 主进度按照片计数，原片与编辑版不算两张照片；表示级任务数仍保留在内部进度和日志。总数已知时使用原生进度条与“已分析 N / M 张”；总数未知时显示读取图库阶段，不编造总数或百分比。 |
| 两处单行文案 | iCloud 等待提示为“正在等待 iCloud 图像，连接恢复后自动继续”；基础统计为“已导入 N · 已跳过 M · 待处理 K”，各占一行、不手动插入换行。待重试、提交中/待确认及退役历史等既有附注可另行呈现，不能因压成一行丢失这些信息。 |
| 原生布局 | 用现有 SwiftUI `Text`、`Label`、`ProgressView`、`Button`、`Divider`、`ScrollView` 组织内容，保留系统字号、控件反馈、键盘和辅助功能行为。沿用现有 320pt 下拉面板与有界状态滚动区、固定操作区；通过原生布局核对单行完整性，不用缩小字号或省略关键计数换取单行。macOS 13 的既有 AppKit 设置窗口兼容路径保留。 |

以上文字是持久化的实现要求；本地网页仅辅助审阅，示例数字、桌面装饰和场景切换按钮均不进入产品。浏览器检查不能代替下面的原生布局与交互验收。

- [ ] **Step 1 — 写失败测试。** `testThirtyMinuteReconcileDoesNotOverlapOrCatchUp`：注入时钟 1800s 触发、忙时合并、休眠不补跑过期轮；`testIndexProgressCountsAssetsAndRepresentationsSeparately`：100000资产/200000表示不能显示成20万照片；`testWaitingIndexIsNotFinishedOrFileError`：索引阻断显示原因；`testLogsImportsAsWellAsSkipsAndDeduplicatesSameEvidence`：同stamp/profile/token只一条，变化后新event；`testDiagnosticCapNeverDropsDecisiveCandidate`；`testLogsBelowThresholdScoreAndSignedMarginWithoutRounding`：记录近邻原始分数及 score-threshold，不四舍五入成 0.98；`testNoCandidateIsAbsentNotZeroScore`；`testPolicyChangeCreatesNewDiagnosticEvent`；`testLogFailureIsWarningButEvidenceFailureBlocksDecision`。

  UI/runtime 另覆盖 `testLibraryAnalysisVisibility`（准备/更新/等待/未完成时暂停可见，就绪及就绪后暂停时整块隐藏）；`testAnalysisStartsAutomaticallyOnlyWhenEligible`（授权、启用来源、暂停条件）；`testAnalysisReadyDoesNotEmitExtraNotification`（单独的分析完成事件不发通知，既有同步通知不变）；`testCompactAnalysisAndCountersFitNativeMenu`（320pt 原生面板、系统字体，iCloud 提示及基础三项含六位数计数仍各占一行、信息完整，附加状态保留）。沿用现有 UI 测试核对菜单栏仅图标、暂停/继续入口及固定操作区，不为网页草图建立产品依赖。
```swift
XCTAssertEqual(ScanSchedule.interval, 1800)
XCTAssertEqual(progress.totalAssets, 100000)
XCTAssertEqual(progress.totalRepresentations, 200000)
```

- [ ] **Step 2 — 跑 P8 红阶段命令。** 日志用临时目录和 flushForTesting；UI 仅 injected runtime/offscreen。
- [ ] **Step 3 — 实现 scheduling/UI。** 启动、恢复、撤权/图库变化、PhotoKit事件、每30分钟和导入前触发对账；无源启用时不新开昂贵任务。内部保留 preparing/updating/ready/waiting/paused 状态，按上表决定分析区域可见性，不将内部 ready 状态显示为常驻一行。`SyncStatusPresentation` 集中推导状态、可见性与文案，`StatusMenu` 只消费聚合字段并用原生控件渲染；`SourceSettings` 不增加图库分析区域。批量建设只节流发布聚合进度；照片数用于用户进度、表示数用于内部工作量和日志，两者不混算。不增加额外完成通知、人工照片审核、概率或阈值滑杆。UI summary 用中文说明，底层详情仅 tooltip/log；macOS 13 设置窗口和 --demo 继续无生产副作用。
- [ ] **Step 4 — 实现日志字段。** 包含 event/file/stamp、context/index/local revisions、model/preprocess/policy 版本、acceptanceID（用户决策 ID）与实际阈值、source/representation尺寸、动作原因、关键匹配和最近候选精确分数、每个分数与阈值的有符号差（score-threshold）、分段耗时、索引触发/新增/更改/删除/失败/等待计数。全局最多 10 个诊断候选加 1 个独立关键候选，包含未命中的最近分数；使用可往返的 Double 精度，不能用仅两三位小数掩盖边界。确实没有候选时记录空值及原因，不造 0 分。完整embedding/图片/metadata禁止序列化；保留10×10MiB轮转与失败warning。关键DB证据不随日志轮转删除；日志不能自动调阈值。
- [ ] **Step 5 — 绿阶段与提交。** P8 测试绿，用原生离屏/GUI QA 验证准备、更新、iCloud 等待、暂停及错误文案，重点核对两处单行文字、就绪后整块隐藏及底部操作不被裁切。用 demo/injected runtime 检查键盘焦点和辅助功能标签，不启动生产同步。浏览器原型或其截图不作为原生验收通过证据；`git commit -m "feat: expose advanced index progress and decision diagnostics"`。

### Task 9 (P9): 固定回归、系统边界与发行资源验收

**Files:** Create `Tests/PhotoSyncCoreTests/AdvancedDedupRegressionTests.swift`, `Tests/Tools/test_advanced_dedup_release.py`, `docs/release/0.2.0-advanced-dedup-validation.md`, `Sources/PhotoSyncCore/Resources/AdvancedDedup/{profile.json,decision.json,regression.json,closeout.json,model-provenance.json,LICENSE-SSCD.txt,SSCDLarge.mlpackage}`; Modify `scripts/validate.py`, `scripts/package-release.sh`, `PhotoSync.xcodeproj/project.pbxproj`, `Design/Validation.md`, `README.md`。

**Interfaces:** Consumes P1 的 `DedupConfiguration.loadValidated(resourceDirectory: URL) throws -> DedupConfiguration`，本任务用真实 Bundle 资源验证该入口，不再新增另一个加载器。Bundle 通过 `Bundle(for:)` 的Core资源定位模型，不能指向work研究路径。以文件夹资源原样复制已固定且获准分发的 .mlpackage，不让Xcode自动替换成另一哈希的 .mlmodelc；R2 加载器验证包后在后台编译/缓存当前平台产物。发行 provenance 绑定源模型包和转换身份，系统验收另记录当时编译缓存的哈希，不误当成跨SDK永恒相同。冷启动预算包含首次编译。

- [ ] **Step 1 — 写失败测试。** `testFrozenCorpusContentAndActions`：先验证固定素材、真值及 active suite 哈希，再用发行预处理、模型、策略断言当前33例，明确14/19及11/22；`testReleaseRejectsMissingModelProfileOrLicense`：缺一项、错误 SHA、未绑定用户决策、阈值/策略/CPU 执行配置不符均拒绝；`testNoImagesOrResearchCorpusInAppBundle`：包无测试图片/原片/完整向量/原始研究数据，也不含网页原型及预览服务；仅允许上表列出的紧凑配置与结果证据。普通自动单测只用自制图；本地完整33例回归可使用已授权六附件，未获公开许可前不得将其推到公共CI。不得用旧44例协议身份替代当前scope绑定。
```swift
XCTAssertEqual(results.count, 33)
XCTAssertEqual(results.filter { $0.content == .duplicate }.count, 14)
XCTAssertEqual(results.filter { $0.action == .skip }.count, 11)
```

- [ ] **Step 2 — 跑红阶段并装入固定资源。** 初次因无 resource/未接线失败；按上表原样复制 4 份交接记录，核对模型包、转换身份、FP32/CPU-only 配置。分别核实代码和权重的实际再分发许可；代码 MIT 不自动授权权重打包，若仍未解决则暂停分发资源装入并报告，P1–P8 可用本地研究资源和 fake 继续开发。具备分发依据后复制模型及适用许可记录入 Core 资源，绑定 profile。让 `scripts/validate.py` 执行fixture `--require-approved`、工具测试和模型回归，不能只核对文件存在或跳过模型；保留完整 XCTest、Tests/Tools、continuation race 门槛。
- [ ] **Step 3 — 做针对性系统验收。** 在用户授权的独立测试图库/账号验证原始与当前表示、编辑/撤销、第三方新增/删除、撤权、iCloud-only离线/下载/取消、重启及source不变性；iCloud有单独流量/耗时记录，不切换系统图库或设置来规避授权。若当前无此测试授权或设备，记录缺口并停止相应发行通过声明。保留测试fixture说明；不能把mock或本地JPEG实验当作真实PhotoKit证据。
- [ ] **Step 4 — 全应用与平台验收。** 复用历史 100k/150k/200k 合成向量基线，记录其旧 0.8、研究进程和本地输入的适用边界；不重启已停止的独立准确率/36,887 负例收集。集成后用受控应用负载验证分段耗时、P50/P95/P99、RSS、持久存储与资源上限，当前工程目标采用 `background-preparation-v2`：M2 Pro 缓存/新来源准备均 P95 ≤2 秒，Photos 变化就绪保留 2 秒上限，峰值 RSS ≤4 GiB；纯查询分布单独记录，以实际输入和测量范围报告。无变化轮不得下载/推理，单项改变只重算相关表示。十万真实资产（0/50/100% 编辑比例）、真实 iCloud 若没有实际执行则列为未验证，不把合成基线写成实测；不将其补做为当前进入 P1 的前置。macOS13与Intel/arm64分别验证CoreML加载和固定 CPU-only 后端；只构建Universal不算实机通过。实际产品回归或资源预算不满足须修复/报告后再判定发行，不能以本次用户阈值决策掩盖。
- [ ] **Step 5 — 完整自动门槛与分支审阅。** 执行本文件开头的 `scripts/validate.py` 全量入口并保存源码树身份；独立 reviewer 检查集成、持久化和并发风险。修复仅重验受影响部分后，再跑覆盖最终行为的全量验收；等价只读审阅不触发重复测试。`git commit -m "feat: validate and package PhotosYNC advanced dedup resources"`，精确记录最后源码提交与系统证据。
- [ ] **Step 6 — 授权范围内的交付。** 只有版本/channel/build已明确、源码已提交且上述门槛通过，才执行 `scripts/package-release.sh` 的正常本地归档路径；不覆盖旧产物，不手工绕过归档内验收。没有本轮打包/合并/安装授权时交付验证记录与待发布源码，不自行执行推送、安装、启动生产App、Developer ID、公证或公开发布。六张用户照片许可问题与系统验收缺口分别列出，不以功能完成掩盖。

### Task 10 (P10): SQLite 流式精确查询与轻量就绪发布

**Files:**
- Create: `Sources/PhotoSyncCore/Storage/SQLiteVectorQuery/SQLiteVectorQuery.h`、`SQLiteVectorQuery.c`、`module.modulemap`：窄的同步扫描桥，不建立通用数据库框架。
- Modify: `Sources/PhotoSyncCore/Storage/SyncStore.swift`、`Matching/AdvancedDedupService.swift`、`Matching/AdvancedDedupTypes.swift`、`Sync/PhotosIndexCoordinator.swift`、`Sources/PhotoSyncApp/SyncRuntime.swift`；`PhotoSync.xcodeproj/project.pbxproj` 及现有 Tools/Regression 编译入口仅作必需的 C 链接适配。
- Modify: `docs/research/advanced-dedup/` 的四份集成交接记录、Core `Resources/AdvancedDedup/` 对应副本及验收记录；保留旧记录 SHA/提交与历史事实。
- Test: `VectorIndexTests.swift`、`AdvancedDedupStoreTests.swift`、`AdvancedDedupServiceTests.swift`、`PhotosIndexCoordinatorTests.swift`、`AdvancedRuntimeTests.swift` 与必要 Tools 构建测试。

**Decision and interfaces:**
- 用户授权 SQLite 查询架构；补充原型选择系统 SQLite + Accelerate 单遍桥，而非 sqlite-vec L2 两遍筛选。证据 `work/backend-validation-20261006/production-query-probe/report.md`：100k/300k 热 P95 125/478 ms，最大档仍未达标。不得把它标为 sqlite-vec 或性能已通过。
- 生产入口：`SyncStore.vectorCandidates(for: UUID, query: Fingerprint, token: IndexToken, threshold: Double, diagnosticLimit: Int) async throws -> VectorSearchResult?`。在现有串行队列和一个读事务内，验证就绪/令牌后查询 Photos、本地较早 pending/importing、成功历史的完整有效候选集合；nil 仅表示令牌过期，损坏/读取错误必须 throw。同一事务中的 localRevision 与调用 token 一致，不能先查本地再在另一快照查 Photos。
- `IndexPublication` 改为 `{ token: IndexToken, representationCount: Int }`。`indexPublication()` / `markIndexPublished(token:)` / `indexIsReady(token:)` 保留事实完整性、进程内发布证明与 PhotoKit acknowledge 屏障；仅发布计数和令牌。移除生产 graph/service/coordinator 对 `ExactVectorIndex` 全量实例的依赖，原纯评分器留作研究和 oracle。
- 配置后端显式为 `sqlite-exact-f32-v1`，重新计算 policyVersion / acceptanceID 与四文件原字节哈希链。fingerprintVersion、模型、阈值、真值不变。新回归记录必须由新查询后端重放产生；旧报告不能仅改标签变成新证据。追加带本次用户指令、旧记录 SHA/提交、后端变化依据的 amendment，保留 `statisticalAcceptance.status=not_performed`。
- 请求 `PRAGMA mmap_size=2147483648` 并记录实际生效值，`PRAGMA cache_size=-16384` 限制普通页缓存；mmap 为 0/被系统截断仍正确。不改变已有事务/耐久化配置。查询不使用全量排序、临时表或持久写入，不为优化开启不受控 TEMP 内存。

- [x] **Step 1 — 写并运行 RED。** 对同一临时数据库和原 `ExactVectorIndex` oracle，断言全部阈值命中、全局前 10 ID/精确分数/Swift key 同分次序和动作一致，覆盖第 11 个才具有尺寸覆盖的候选、400 个同分命中、Unicode key、负分、阈值及范数容差邻接 Float。非命中行放在合法命中之后，分别写入 NULL、非法长度、NaN/Inf、零/高/低范数，查询必须整体失败；不能返回先累计的 skip。资格测试覆盖停用/移除来源、较新 pending、自身、已跳过无 success、成功历史、stamp/version/context/generation。令牌/本地修订改变应返回等待，旧 admission 不得提交。
- [x] **Step 2 — 实现并接入单遍扫描。** SQL 仍由 SyncStore 定义候选资格及 metadata；扫描按行验证必需的 key/origin/尺寸字段及 1024 个 f32，长度 4096、分量 finite、Double 平方和误差 ≤1e-5，再调用原 `vDSP_dotpr`。只把全部达阈值候选或可能进入诊断前 10 的行交给 Swift；等分也交回，排序仍用原 Swift String 规则。向量只在当前行缓冲中存在；错误/取消/SQLite step 失败不暴露部分结果。C 禁用 fast-math 并固定 `-ffp-contract=off`；跨语言对象、statement、BLOB 指针仅在同步扫描期有效，所有路径 finalize/free。不添加本地候选缓存、不改提交锁顺序。
- [x] **Step 3 — 轻量发布与配置证据。** service 改用统一 SQLite 查询，coordinator 不再解码/复制/replace 全库向量。更新 graph、fake、测试调用点及 Core/Tools/race 编译成员关系。更新后端绑定及逐字段/篡改测试；用既有固定输入重放新后端并生成四文件一致的记录，另跑实际 bundled 模型的 33 例，明确两者来源。
- [x] **Step 4 — GREEN 与独立任务审阅。** 运行受影响原生测试及编译入口检查，最后一个 P10 快照做一次完整 native XCTest；记录有效 mmap、查询写计数为零、向量内存不随总数常驻增长的受控检查。完整 100k/150k/200k Photos + 100k 历史性能/闲置测量留到 P11 集成完成，避免重复。自行审阅后提交 `feat: query dedup fingerprints directly from SQLite`，输出 RED/GREEN、命令/退出码、资源身份和剩余性能风险，控制线程做 SPEC/QUALITY 审阅。

### Task 11 (P11): Photos 连续变化集与无变化对账零行写入

**Files:**
- Modify: `Sources/PhotoSyncCore/Photos/PhotosIndexGateway.swift`、`PhotoKitGateway.swift`、必要的 `PhotosRepresentationReader.swift`；`Sync/PhotosIndexCoordinator.swift`；`Storage/SyncStore.swift` / `Schema.sql`；`Matching/AdvancedDedupTypes.swift`；`Sources/PhotoSyncApp/SyncRuntime.swift`。
- Test: `PhotoKitContractTests.swift`、`PhotosIndexCoordinatorTests.swift`、`AdvancedDedupStoreTests.swift`、`AdvancedDedupServiceTests.swift`、`AdvancedRuntimeTests.swift` 及既有 fake 生命周期实现。
- Modify: `docs/release/0.2.0-advanced-dedup-validation.md` 和既有 scale/validate harness，仅补变化路径、真实终点与资源测量，不改门槛或跳过失败。

**Decision and interfaces:**
- 新值 `PhotosIndexDelta { context: LibraryContext, fromGeneration: Int, toGeneration: Int, changedAssetIDs: [String], deletedAssetIDs: [String] }`；`PhotosIndexChange` 传递完整 `.incremental(PhotosIndexDelta)` 或明确 full/context invalidation。同一增量含全部影响 ID；不可把部分 batch 当完整事务。内存批次上限采用既有 `catalogBatchSize`，完整影响集合可分批持久合并，不能因数量超过批次容量就变成全库内容失效；缺基线、不连续或范围无法保全时 sticky full-reconcile 只要求重新核对清单。空 ID 的合法连续代次也须推进就绪屏障。
- `PhotosIndexGateway.representationDelta(_ delta: PhotosIndexDelta) async throws -> RepresentationPage`：只 fetch changed IDs，返回同上下文/目标代次的 descriptors、exclusions、内容失效集合；删除来自该可靠 delta。分页/超量/缺失 changed ID/代次变化不是删除证据，回退完整对账。原始/当前复用必须有可靠依据，不从尺寸/文件名不变推断；不能区分时允许该资产两表示均重算。
- `SyncStore.applyIndexDelta(_ delta: PhotosIndexDelta, page: RepresentationPage, fingerprintVersion: String, checkpoint: LibraryResumeCheckpoint?) async throws -> Int64`：同一事务验证旧清单基线、上下文和 fromGeneration，只更新受影响表示/任务及有限全局状态，发行新全局索引代次。页面和 checkpoint 必须同上下文/目标代次；不完整/过期整体回滚。
- 完整扫描 coordinator 临时保存 `Set<RepresentationKey>` 作为 eligible seen keys；exclusions 单独计数并使旧不再合格表示失效，不能把 excluded key 当作可保留候选。完整 finish 增加 seen keys 参数，遍历轻量持久键，仅墓碑真正缺失/被排除的表示。未完成扫描永不做缺失删除；重启重扫清单但复用有效 ready 向量。不要 TEMP 表/持久 seen 标记，也不要持久化第二份全库快照。
- 原 `seen_generation` 可保留为表示/任务发行代次，不再要求等于当前全局发布代次；变更语义必须同步修正完整性、publication、query、progress、task polling/completion、索引和迁移。无变化表示/任务不 UPDATE。任务保留自己的发行代次，完成时验证持久 task 仍存在、发行代次和完整 descriptor/fingerprintVersion；换任务后同 revision 的迟到结果也拒绝。保留事务化 v3→当前及已有 v4 数据升级，不清成功历史/unknown。
- 为在增量时准确更新 excludedAssets，增加同一数据库的轻量 `photos_index_exclusion` 表（context_id/context_epoch/asset_id 主键，只保存完全不属于高级候选的资产），不能靠单个累计数猜某 ID 原先是否被排除。完整对账更新实际差异，delta 只处理涉及的 ID；与表示更新同事务。迁移升至 schema v5，旧 v4 初始化为空且必须重新完成清单再发布；v3 路径仍保留全部历史，未知更高版本拒绝。`Schema.sql` 与迁移同步；这不是第二套向量或成功历史表。

- [x] **Step 1 — 写并运行 RED。** 初始化后加/改/删单资产，断言 gateway 只读取给定 ID、没有完整 catalog、无关表示/任务逐字段不变、只重推理有关表示、动作和尺寸覆盖正确；metadata/编辑/撤销/排除 transitions 分别覆盖。使用 SQLite update hook 或等价实际语句变化计数断言 unchanged 完整对账对 `photos_representation` / `fingerprint_task` 零写入、零图像读取/推理，不能用现有逻辑 IndexMutationCounts 代替物理写证明。不同总库规模同一 delta 的行写数相同。
- [x] **Step 2 — 增量 producer 与落库。** gateway 在既有 observer/串行 candidate index/validity 中产生带基线的完整增量，先使旧提交失效，再处理详情；队列丢失/无订阅/overflow 继续 sticky full。runtime 传递变化原因，不把每个 granular event 都提升为全库 force。coordinator 只合并同上下文连续增量，以后发生的 changed/deleted 状态为准；有歧义保守 full，不猜遗漏。事务完成后再做所需图像任务及轻量发布，所有 await 后核对暂停/变化/上下文。
- [x] **Step 3 — 无变化完整检查及任务 fencing。** 改为本次临时 seen-key 集合，去掉未变化表示及 task 的 generation UPDATE；完整校验后才处理遗漏。保留启动/恢复/30 分钟 full。补 controlled tests：事件断档、非增量、overflow、缺 ID、暂停分页/重启、上下文/授权变化、中途失败、连续改删/删改、受影响晚结果被拒、无关在途结果仍可完成、发表前又来变化不得 ready。对方系统变化不能只靠 fake 改 enum 跳过实际接线。
- [x] **Step 4 — 聚焦 GREEN 并冻结。** 对真实 SQLite + fake Photos 运行相关状态/持久化/恢复/并发测试，检查 SQL 查询计划不因去掉 seen_generation 谓词退化到读全部 BLOB 来判 readiness；必要索引属于同任务。记录写行计数与持久文件/WAL变化，保持既有日志完整。提交 `feat: update Photos fingerprints from asset deltas` 并接受独立 SPEC/QUALITY 审阅。完整 canonical 由控制线程指派 tester 在最终快照运行，不由 implementer 重复执行同一快照全套。
- [x] **Step 5 — 回到 P9 最终验收。** 更新既有受控 scale harness，覆盖 100k/150k/200k Photos 表示，以及 200k Photos + 100k 成功历史。热查询分段与 source prepare 分开；单项变化计时直到有效 ready token/Photos generation/表示数全部吻合，多次样本给 P50/P95/P99；初建、单变更、无变更 full、重启各标明真实/合成。最大档记录查询后 60 秒闲置的 footprint/RSS、再次查询延迟及查询/增量/无变更对账的逻辑 I/O/进程 I/O/写计数；查询零写不等于整个导入零写。沿用 `scripts/validate.py` 的完整 native/Tools/两个 continuation race/实际模型/规模门槛；失败仍退出非零并报告，不重跑已见统计校准或无限增加优化路线。
- [x] **Step 6 — 最后集成审阅与交付记录。** 全分支审阅聚焦新查询与既有 commit/恢复、轻量 publication 和 delta 的组合风险；修复后补受影响验证。已知最大规模热查询风险必须以最终测量说明，达不到仍不能宣称完整性能验收或发行就绪。更新 spec/plan 实际完成状态与验证记录，交付本地源码提交；不发布、安装或启动真实应用。

> 上述 P11 勾选是 2026-10-06 历史完成事实；2026-10-07 的失效粒度修订尚未实施，新增约束不能由这些勾选宣称已验证。P11 步骤完成表示当时实现、审阅和要求的测量均已执行并记录，不表示所有性能指标通过。最终 canonical 的失败与 P9 未关闭项目见文末；不继续扩展查询架构或放宽门槛来制造通过。

## 自检覆盖与执行交接

| spec | 落点 |
| --- | --- |
| 1/2 范围、只读/只新增、四状态、编辑边界 | R3/R4、P2、P5/P6、P9 |
| 3.1 向量/检索/版本与全部候选 | R2/R3/R4、P3/P4 |
| 3.2 决策/尺寸/本地依赖 | R3、P4/P5/P6 |
| 3.3 成功历史与旧记录缺指纹 | P1/P4/P5 |
| 4 清单/双表示/一致性 | P1/P2/P3/P6/P8 |
| 5 iCloud/预算/取消 | R1/R2、P2/P3、P9 |
| 6 v3迁移/恢复/旧skip重判 | P1/P5/P7 |
| 7/7.1 用户选定配置、历史研究与固定真值 | 收尾记录、P1/P9 |
| 8 性能与十万/二十万表示 | R4、P3/P8/P9 |
| 9/10 阈值调整、近邻日志和UI | P4/P7/P8 |
| 11 自动/系统/平台/交付 | P6/P9 |

任务状态：P1–P8 已完成；P10 SQLite 和 P11 Photos delta 已实施并完成源码审阅；P9 最终自动检查与四档规模测量已执行，性能验收因热准备超标仍未通过。共享文件由单一所有者串行整合，不并发改 SyncStore；持续用最小相关检查，非最终任务不重复平台或真实图库全验收。上方 P1–P9 原实施步骤和值类型保留作历史，P10/P11 的新接口与用户批准方向优先。

用户已授权并采用 subagent-driven 实施 P1–P9。P1–P8 已完成任务级实施与评审；P9 及最后全量验收、分支审阅按当前证据收尾。以下任务框架保留为原计划，不应重新执行已完成步骤。

## 2026-10-05 已批准实施修订与证据

- 初始 0.98 是用户选择；独立统计验收仍为 `not_performed`，不再追加独立校准。历史 44 例和旧失败记录保留。
- 用户批准 decoded allowance 512 MiB；可读且仍超限的支持图像以 `decodedResourceLimit` / `notCompared` 保守导入原文件，不伪造向量或 noMatch，未知/失败/占槽仍守原有等待与错误规则。
- 用户选择 Git LFS；固定权重按 exact-commit pointer、local object SHA/size、完整模型包身份依次校验后才允许归档构建，无自动远端上传。
- P5 实际锁顺序为 store 串行队列 → Photos validity → SQLite 事务；原计划的简写不授权反向持锁或跨 await 等待 Photos。
- 实际 runtime/UI/诊断责任落在 SyncRuntime、AppModel、SyncStatusPresentation、AdvancedRuntimeTests 等已有边界；不为匹配原计划文件名进行机械迁移。
- 当前实施/回归/系统与平台缺口以 [P9 验收记录](../../release/0.2.0-advanced-dedup-validation.md) 为准。P9 已恢复冻结 R2 bounded thumbnail 解码并通过真实 33 例，失败对照仍保留；不能用历史重放替代当前产品验收；最终分支审阅已完成；控制线程验收结果及未通过项见下方 2026-10-06 收尾记录。

P9 真实回归发现并修复未发行的 P4 解码偏差：固定 R2 从引入提交 `f60bf5d` 到冻结底本 `04da1ab` 均使用有界 ImageIO thumbnail 解码。恢复其参数后 33 例从 30/33 回到全部通过，阈值与真值未动；保留 512 MiB 原始 backing 预检、超限保守导入、原始 metadata 尺寸、原 EXIF 处理和物理租约。该修复由控制线程明确确认，先前“full CreateImage 是冻结 R2”的说明不再适用。


## 2026-10-06 P10 验证检查点

SQLite 查询已在 `348e128` 实施，溯源字段修正在 `2eec0fe`；独立任务审阅及修正复核通过，未留开放问题。当前原生 480 项测试零失败（1 项规模测试按独立子进程执行），72 项受影响 Tools 与两个受控竞态通过；四文件资源绑定已重新核验。33 例分别通过既有向量 SQLite 重放和当前模型新推理。该检查点不代替 P11 后的最终规模/闲置/canonical/全分支审阅；已知最大档热查询超目标仍保留。


## 2026-10-06 SQLite / Photos delta 收尾

实现提交为 `348e128`（SQLite）、`a32fd9f`（Photos delta），后续 `75d62a6` 修正旧 v4 迁移夹具及接口文档，`1714857` 修正测试宿主的重启后服务配对。后两次修正没有改变产品判定、资源预算或迁移安全检查。独立全分支审阅及局部复核通过；原有来源恢复标题的低优先级 UI 问题记录在验收文档，未扩入本轮修改。

最终测试源树为 `d63764a7d741b50e23437462cea564691c2a4caf`。`scripts/validate.py` 在该快照的 150k 热准备门槛处退出 1；未执行的 200k、200k+100k、完整 Tools 和两项 continuation 检查随后在同一源码串行补齐。原始失败不改写为通过，不生成成功 `validation.json`。

M2 Pro、实际模型及产品组件、临时 SQLite / 合成表示 / fake Photos 的 Release 测量如下；不是十万真实 Photos 资产的实测。查询/准备各 20 个样本，增删改各 5 个样本；“变更”列取三类操作 P95 中最高值。

| Photos 表示 / 成功历史 | 纯查询 P95 ms | 热准备 P95 ms | 新来源准备 P95 ms | 变更至就绪 P95 ms | 峰值 RSS GiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| 100k / 0 | 168.42 | 232.68 | 316.72 | 167.09 | 0.90 |
| 150k / 0 | 252.94 | 344.27 | 437.35 | 238.30 | 1.13 |
| 200k / 0 | 339.17 | 455.45 | 560.93 | 301.28 | 1.80 |
| 200k / 100k | 612.05 | 732.36 | 846.22 | 357.92 | 1.67 |

- 已证明的写入边界：四档纯查询均零行写入、零 VFS 写入；无变化核对均无模型调用，表示/任务/排除表零写入，只更新 3 行全局状态，约 50,772 字节逻辑 VFS 写入。单资产编辑/新增分别涉及 2 次表示写与 2 次任务写，删除 1 次表示写；另有各 4 次全局状态写，与总库大小无关。这是受控 fixture 的行计数，不是所有原生编辑类型的固定写次数。
- 最大档真实闲置 60.041 秒：footprint 50,710,760 → 31,967,416 字节（约 48.36 → 30.49 MiB），RSS 1,645,887,488 → 1,401,110,528 字节；恢复查询单次 615.98 ms。该间隔没有观测到进程磁盘读写或 page-in 增加。它位于查询/增量/同进程重新打开之后、日志压力与大图读取之前；旧新对象仍共存，不是 App 冷重启或真实 Photos 闲置验收。未单独量出文件映射，不能把 RSS 差额全部称为可回收缓存；逻辑 I/O 不是 SSD/NAND 磨损。
- 大图成功参与比较，但 61 MP 16-bit PNG 的两个单次观察为 2.24 / 2.56 秒，超过 2 秒；不能用普通小图的 P95 掩盖，也不能把两次观察称为 P95。
- 功能回归、写入边界、单张 Photos 增量和峰值 RSS 已取得受控证据。P9 的 250 ms 热准备目标、真实系统/平台和发行验收仍未关闭；本次交付本地源码与记录，未授权任何合并、推送、打包或部署。

完整数值、原始失败、验证命令和局限见 [0.2.0 验收记录](../../release/0.2.0-advanced-dedup-validation.md)。保留本计划的 SDD 记录及 `work/final-integrated-171485732fa1-20261006/` 证据，后续不要重做 P1–P11 或将已完成的源代码审阅误当作完整性能通过。


## 2026-10-06 当前性能契约修订

用户已授权判断指标合理性并修改。依据、原始来源及取舍见 [性能预算复核](../../research/advanced-dedup/2026-10-06-performance-budget-reassessment.md)。此节替代历史步骤中把 250 ms 当作当前产品硬门槛的要求；不更改原研究协议或将历史 FAIL 重写为 PASS。

- [x] 调整 `AdvancedDedupRegressionTests.swift` 的小规模/四档验收：缓存和新来源 `prepare` 均 P95 ≤2,000 ms；报告新契约 ID 与预算，继续保留纯查询分布。照片变化、RSS、写入、闲置和真实终点检查不弱化。
- [x] 在 `scripts/validate.py` 及 `Tests/Tools/test_release_validation.py` 同步报告契约和数值校验；以合成 CLI 用例证明 250–2,000 ms 可通过、超过 2,000 ms 或缺失/无效证据仍被拒绝，布尔 `budget_pass=true` 不能绕过数值。
- [x] 独立审阅这次门槛修订，针对修正补验证；最后运行完整 `scripts/validate.py` 于新冻结快照，保留原始失败和全部运行身份。
- [x] 更新当前验收结果，区分新契约通过、历史 250 ms 失败、61 MP 大 PNG 单次较慢及真实系统/平台未验证；不新增后端、模型、运行时配置或部署动作。

沿用现有子代理执行方式：一个实现者只改验收代码；控制线程负责文档和最后记录，审阅/测试独立执行。这是同一后台准备工作单元的预算纠偏，不扩成算法性能重构，也不新增一个贴着已观察时延选取的 1 秒门槛。

这次预算修订的历史冻结提交为 `477284b3025351683a7460ca4ce4cd4fedd5c847`，源码树为 `a6f4117f69d85255f936c916a693e2f62c23ea8b`；完整入口在 `work/validation-background-preparation-v2-20261006/` 生成通过报告，239 项源码清单前后一致。四档缓存准备 P95 为 225.01/341.41/454.24/735.97 ms，新来源为 300.45/430.99/555.15/845.23 ms；变化至就绪最高 P95 348.81 ms、峰值 RSS 最高 1.86 GiB。最大档测量 60 秒闲置及恢复；61 MP PNG 单次 2.22/2.46 秒单列披露。这些是 FP32 基线，不代替后续 P14 的 FP16 验收，也不把文档提交冒充新一次代码验收。详细表格、命令与限制见 [验收记录](../../release/0.2.0-advanced-dedup-validation.md)。

### Task 12 (P12): FP16 模型、实例自检和串行 GPU 降级

**Authority:** 本计划 Global Constraints 与 spec §7.1；用户已明确选择研究方案 A 并要求执行。模型/后端研究不再重跑，研究 golden 失败不能改成通过。实施基线 `2d90d3d`，开始前核对包含文档授权补充的 HEAD。

**Files / ownership:**
- Modify: `Sources/PhotoSyncCore/Fingerprinting/CoreMLFingerprinter.swift`、`Matching/AdvancedDedupTypes.swift`、`Matching/AdvancedDedupService.swift`、`Sync/PhotosIndexCoordinator.swift`、`Storage/SyncStore.swift`（仅必要的旧版本成功向量保护）、`Sources/PhotoSyncApp/SyncRuntime.swift`、`AppModel.swift`（仅明确手动模型重试的调用点）、`Logging/DedupDecisionLog.swift` 或现有 logger 事件接点。
- Create: `Sources/PhotoSyncCore/Fingerprinting/ModelExecution.swift`，集中小型执行策略/自检值类型、资源解析与会话状态，不建立通用推理框架。更新 Xcode target membership。
- Replace active bundle: `Sources/PhotoSyncCore/Resources/AdvancedDedup/SSCDLarge.mlpackage` 及当前配置/来源记录；Create 同目录 `execution-policy.json`、`ModelSelfTest/manifest.json` 与 `input-0.f32`…`input-3.f32`、`reference-0.f32`…`reference-3.f32`。
- Create: `docs/research/advanced-dedup/fp16-ane-gpu-v1/` 的新 decision/profile/regression/closeout/model-provenance/执行策略证据。历史目录已有 JSON 原始字节不变。
- Modify: `scripts/advanced-dedup/convert-model.py`、`release.py`、`Tools/AdvancedDedupProbe/main.swift`、必要的 `run-probe.sh` 与 `scripts/validate.py`；只修改新产品后端必需的资源/证据接口，原研究协议与旧 `research.py evaluate/accept` 语义不改。
- Tests: `FingerprintTests.swift`、`AdvancedRuntimeTests.swift`、`AdvancedDedupServiceTests.swift`、`AdvancedDedupEngineTests.swift`、`PhotosIndexCoordinatorTests.swift`、`AdvancedDedupStoreTests.swift`、`AdvancedDedupRegressionTests.swift`；`Tests/Tools/test_advanced_dedup_release.py`、`test_release_validation.py`。仅扩与本任务行为/资源相关的断言。

**Interfaces / values:**
- 继续消费 `ImageFingerprinting.fingerprint(image:orientation:) async throws -> Fingerprint`，保留现有注入预测器测试。生产构造入口仍由 `AdvancedRuntimeGraph.load` 拥有一个 fingerprinter；增加受验证执行策略和自检资源的显式输入，不能由调用端传一个未校验 backend 字符串。
- 引入 `ModelExecutionPolicy`（标识 `fp16-ane-gpu-v1`、arm64 主/备用为 `cpuAndNeuralEngine` / `cpuAndGPU`、x86_64 仅 `cpuAndGPU`、无 `.all`/`.cpuOnly`、Float32 IO、低精度 GPU accumulation 为 false）及 `ModelExecutionUnavailable` 类型错误。只将可恢复执行错误/数值自检不合格归入该等待错误；配置损坏保留 fail-closed 配置错误，来源损坏保持原读取错误。
- `CoreMLFingerprinter` 内的一个 serial physical queue 拥有可变模型会话、选择/验证/预测/降级及释放；不能让每次 enqueue 捕获旧不可变 predictor 后绕过会话状态，也不通过新建 fingerprinter 增加第二条物理队列。只在旧调用/实例结束后换 GPU；逻辑取消不能提前腾槽。
- 当前批准候选是 `work/coreml-acceleration-20261006/SSCDLargeFP16.mlpackage`，SHA `026e7a43660e29c307941a88dbe35b9c14468693333ff926e9b984eef3b4b8d0`，FP32 IO，fingerprintVersion `ec805406fa61e91384e4bf29ae29a52694b80e3755afd7768da80a6db70c9a1d`。复用确切字节，不再转换出另一个未经比较的包。权重继续 LFS。
- 四个固定输入来自 `work/R2-synthetic-tensors/{0,1,2,3}.f32`，各 1,228,800 字节；四个参考来自 `{0,1,2,3}-torch.f32`，各 4,096 字节。每个新会话在当前配置下逐一比较，全部 `maxAbs <= 0.02` 且 `cosine >= 0.999` 后才可输出持久化指纹；不改变比较/归一化口径。清单绑定每文件 SHA256，外层执行策略和 decision 绑定清单，加载与 release 都核验路径、大小、有限值和门槛。合成自检资源是 App 资源白名单的明确新增例外；私人图片、私人 embedding、任意研究文件仍禁止进入 App。
- `ModelExecutionUnavailable` 在来源准备映射为 `AdvancedPreparation.waiting`，利用 `SyncEngine.recordAdvancedWait`，不记录损坏来源、不增加提交失败/unknown。协调器的模型失败仍阻止对应任务 ready，但使用模型等待文案，不冒充 iCloud/照片读取失败。初次模型不可用由 runtime 保留可恢复 waiting；已有 `advancedLoadAttempted` 不能让其永久卡在配置 error。
- 在现有 tick 检查模型重试期限，自动重试最多每 60 秒一次，明确的手动扫描/恢复允许一次即时重试；自动唤醒/内部 follow-up 的 `force` 不等于手动重试。暂停/停用/撤权不重试，被拒绝的手动意图不能留存到以后绕过期限。每个新会话只尝试其批准候选各一次；每个新物理阶段通过现有同步授权提供者和运行资格信号核对当前条件。GPU 耗尽时即使同时失去资格也保留 retry deadline，以便首次明确恢复正确重试。所有 await 后保留既有提交和所有权复核。
- 日志记录 policy ID、requested/selected 配置、自检结果及失败/降级阶段，技术原文仅在诊断；不宣称配置名等于实际硬件，不输出完整张量或向量。不要引入模型卸载定时器、第二模型或额外推理并发。

- [x] **Step 1 — 有行为意义的 RED。** 加入具名测试：`testSelfTestFailureSelectsGPUBeforePublishingFingerprint`（主会话验证失败，释放后 GPU 验证通过，未验证结果绝不返回）；`testPredictionFailureFallsBackOnlyAfterPhysicalReturn`（受控门闩证明最大物理并发/活跃实例为 1）；`testCancelledPredictionDoesNotStartFallback`；`testBothBackendsUnavailableNeverUsesCPU`；`testModelUnavailableDefersWithoutPersistingFileError`；`testModelRetryRespectsDeadlinePauseAndAuthorization`；`testBackendResourceCorruptionIsNotRetryableHardwareFailure`；`testOldSuccessfulFingerprintVersionIsRetainedAndNotSilentlyIgnored`。工具测试拒绝错误模型/策略/自检文件或摘要、CPU-only 策略、非法 IO/门槛；保留边界等号与现有 missing-resource 案例。先运行并记录预期失败，不以编译环境失败当作 RED。
- [x] **Step 2 — 实现模型会话及等待接入。** 按上述单队列实现加载/验证/一次降级，接入 runtime、service 和 coordinator 的类型化等待。改动只覆盖该失败来源，保留非模型读错误、unknown 提交、旧成功关系和已有索引代次的原语义。版本变化重算可重建表示；旧高级成功向量无法安全使用时保留并等待，不静默过滤后判无重复。本轮不做多版本历史自动转换。
- [x] **Step 3 — 固定资源、绑定与真值回归。** 为本次用户授权另存新绑定链，并用实际 bundled FP16 管线产生 33 例结果及允许后端对照；真实 source decoder、当前 SQLite scorer/策略和 0.98 均不变。正确区分查询 backend 与模型 execution policy。由 loader/release 同时核验执行/self-test/模型身份，legacy 研究构造路径若保留必须显式为历史用途且不能被 App 生产装配采用。转换工具补显式 Float32 IO，以便未来重现，不修改已选候选字节。
- [x] **Step 4 — 聚焦 GREEN 与本地提交。** 优先跑以上新测试和受影响套件、资源 Tools；在本机实际跑批准的 ANE/GPU 各四个 golden 与 33 例内容/动作，不能只用 fake。检查实际 bundle self-test bytes、模型/LFS、记录哈希和旧不可变资源字节。报告包括 RED/GREEN、真实/注入边界、变化文件和未验证平台。产品最终全量入口留给 P14 串行执行，避免多个 worker 同时跑性能负载。提交 `feat: validate FP16 ANE inference with serial GPU fallback`。

### Task 13 (P13): 原生状态标题与隔离交互验证

**Files / ownership:** Modify `Sources/PhotoSyncApp/SyncStatusPresentation.swift`，必要的原生 accessibility 属性限于 `StatusMenu.swift`；Test `SyncStatusPresentationTests.swift`、`AppViewTests.swift`。复用当前 injected AppModel/runtime 与既有测试 seam；如需可见原生验证宿主，仅放在 ignored `work/`，不要创建产品网页/新的正常入口或无关 build/run 系统。

**Interfaces:** 保持 `globalStatus`、`statusDescription(for:enabledSourceIDs:)` 和 `analysis` 的现有 API。`statusDescription` 在未暂停、无更高优先级错误时，来源不可用先于分析标题；单独的图库分析区域仍显示，原生控件、菜单栏仅图标、就绪后隐藏、单行基础统计/iCloud 提示继续生效。

- [x] **Step 1 — RED。** `testUnavailableSourceHeadlineWinsWhileAnalysisVisible` 覆盖 preparing/updating/waiting，断言图标 waiting、主标题“等待恢复”、分析区域保留；暂停/授权/阻断状态不被该修复覆盖，ready 后分析隐藏。实际运行该测试，确认原行 40 的覆盖错误被复现。
- [x] **Step 2 — 最小修复并 GREEN。** 修正标题优先级；运行 presentation 与 AppView 相关用例，保留 320pt 宽、两处单行、明暗主题及有界动作区域证据。无必要不改布局或其他文案。
- [x] **Step 3 — 本机原生验证。** 以明确只用 fake/临时 UUID 数据、无 Photos/生产库/系统集成的专用宿主检查五种分析状态、暂停/恢复、就绪隐藏和原生动作。观察可访问性树的角色/标签/状态及键盘/responder 路径；区分自动 AX/键盘验证与实际 VoiceOver 听读，不从离屏尺寸测试推导后者通过。不得启动当前会自动激活或复用生产实例的普通 App/旧 GUIQA 路径，不抢用户前台、不发全局快捷键、不改系统权限。受工具能力限制的项目原样报告，不能伪称完成。
- [x] **Step 4 — 报告并提交。** 保存命令、截图/结构证据、结果和限制，提交 `fix: preserve source recovery priority in native status panel`；只提交产品修复与可复用行为测试，不提交临时 QA 宿主或个人数据。

### Task 14 (P14): 最终审阅、完整验收与真实图库验证计划

**Files / ownership:** 控制线程更新本 spec/plan、`README.md`、`docs/release/0.2.0-advanced-dedup-validation.md`、`docs/release/2026-10-06-0.2.0-merge-readiness.md`；新增 `docs/release/2026-10-06-real-photos-icloud-validation-plan.md`。Reviewer 只读、tester 不改产品。不得调整版本/channel/build 或实际打包/合并/推送。

- [x] **Step 1 — 一次深度集成审阅。** 覆盖 P12/P13 新差异及执行策略、缓存/历史、失败等待/恢复、取消和原生状态的相互作用；已有 P1–P11 等价源码审阅不重做。新发现仅在当前授权边界内修复，修复后只复核新差异。此深度 review 同时满足新增任务和最终集成门槛，避免重复审阅同一快照。
- [x] **Step 2 — 冻结后完整验证。** 用全新 work 输出与 DerivedData 跑 `python3 scripts/validate.py --output-dir "$PWD/work/validation-fp16-<唯一名>" --derived-data "$PWD/work/validation-fp16-<唯一名>-derived"`。必须完整 XCTest/Tools、实际 33 例、runtime、四档规模、最大档 60s idle、两项 continuation GREEN/预期 RED、前后源码身份一致。验证包内新模型/自检资源和允许后端，不用研究探针替代。另做正常 Universal 构建但不运行 Intel、Rosetta 或旧 macOS 实机测试；这些范围由用户明确跳过/保留。
- [x] **Step 3 — 收口当前证据。** 写明新提交、全部命令/结果、有效 execution policy、允许配置与实际设备证据的区别、旧失败和被排除平台；只记录已测性能与资源，不把短时/合成证据写成真实 Photos 或功耗通过。只读 review、最后的文档更新不触发同快照重复全量测试。
- [x] **Step 4 — 之后规划真实 Photos＋iCloud。** 按最终实现写可执行分阶段计划：明确测试账号/图库/来源授权、fixture 与观察点、original/current/edit/undo、外部变化、云端-only 前置证明、离线/恢复、权限/暂停/进程重启、源不变及仅新增、缓存/下载/时延证据和停止条件。把自动假网关不能证明的内容列成明确步骤，区分公开 API 可观测与不能可靠计量的字节/缓存信息；不假设已有可用测试账号，也不自行切系统图库或 iCloud。计划交付到此，本轮不执行它。

P12/P13 按串行所有者实施，最终 tester 独占重负载。本节的授权、错误分类与 60 秒有界恢复节拍须写入 SDD ledger；不再重复询问已经批准的后端方案或执行方式。

## P12–P14 执行结果（2026-10-06）

- P12 初始实现 `da349236`，P13 原生标题修正 `edc44c47`；集成审阅发现的恢复资格/手动重试问题由 `e9db96c0`、`bc27a425` 修正。最后冻结源码为 `bc27a425e2c7b6f1913c7f895104d35e57ddbd96`，tree `133bfa3a614e4c9e9d1d447b8665cf6e42b31855`。独立 reviewer 最终 SPEC PASS / QUALITY APPROVED，无开放发现。
- 模型字节和数值管线采用已批准候选，阈值仍为 0.98；原研究协议及六份历史绑定 JSON 未改写。四份合成输入/参考是明确的 App 资源白名单例外；实际用户照片及其向量不进入 App。新配置、指纹版本、自检、许可及 LFS 权重已共同核验。
- 完整验收命令与证据在 `work/validation-fp16-20261006/`：521 XCTest、94 Tools、33 例实际模型、四档规模及两项受控恢复竞态通过；两项 XCTest 显式跳过有独立原因。前后 269 项源码清单 SHA256 均为 `875de28b2b99dba404b2ce0a0b142cf58f88768d5324b7d26878f176fa5d4fec`。`work/validation-fp16-20261006-execution/` 的 ANE/GPU 请求配置分别通过 4 golden＋33/33；配置名不等于实际硬件跟踪。
- 正常 Universal Release 的 App/Core 各含 arm64、x86_64，最低系统均为 13.0，复制资源核验通过。没有 Intel 执行；用户确认没有 macOS 13 测试机，保留实机缺口。这不是发行打包、签名分发或安装验收。
- P13 的 RED/GREEN 和 29 项聚焦测试、18 张原生明暗渲染、五种隔离后台窗口状态及本地暂停/恢复动作已记录。宿主未激活前台、Photos create 为 0；完整控件 AX、键盘遍历、VoiceOver 和真实菜单弹出未得到完整证据，P13 Step 3 的完成表示已执行允许的检查并报告限制，不代表这些项目通过。
- 四档准备 P95 都满足 2 秒预算，最大档（200k 表示＋100k 成功历史）新图准备 P95 893.00 ms、峰值 RSS 1.60 GiB。保留 200k 档单次 4.30 秒尾部、大 PNG 单次 2.23/2.48 秒及最大档闲置 footprint 87.19 MiB；不声称全部请求两秒内或闲置内存全面改善。原始报告 `scope` 残留 CPU-only 文案的局限已说明，实际构造器使用当前受验证 FP16 策略，原始证据未改写。
- [真实 Photos＋iCloud 计划](../../release/2026-10-06-real-photos-icloud-validation-plan.md) 已编制 V1–V5，并随后按用户明确授权改为本机生产图库：先只读、最后限额写入和精确回退，执行时登记具体来源/资产及运行基线；没有合格云端前置就保留缺口。真实图库、长期资源与完整原生交互均未在本轮执行。公开素材/LFS/CI、发行版本和打包等后续事项仍见[合并准备记录](../../release/2026-10-06-0.2.0-merge-readiness.md)。

控制线程最后仅更新 Markdown，未改变上述冻结实现或重跑同一源码；详细命令、数值与局限以[验收记录](../../release/0.2.0-advanced-dedup-validation.md)为准。本轮不合并、推送、发布或启动生产实例。

## 2026-10-07 失效粒度修订：后续实施与验收约束（未执行）

本节同步已修订的设计和待办范围，不是新的执行记录。详细实施任务应以修订后的书面 spec 为准继续展开；当前不改产品代码、不重启真实图库测试、不合并或发布。真实触发分支尚未定位，不能将“首次取图伴随通知”当成已证明的 iCloud 缓存事件。

**涉及原任务：** P2 的通知／读取有效性、P3 的清单与 publication、P11 的增量／存储事实；P8 仅补现有日志和进度口径，P9/P14 补新快照验收。保持 SSCD/0.98、SQLite 精确评分和成功／unknown 保护，不扩判重模型、来源类型或 UI 操作。

- [ ] **明确事件证据与数据契约。** 区分清单需重查、已知内容变化、已证明无输入变化、未知范围及上下文不可信。记录 producer 回退具体原因，而非仅 `libraryChanged`。审核公开 PhotoKit 证据能否支撑复用；当前修改日期／资源 SHA 不能冒充内容版本。对 API 无法确认的情况保持未知，不按通知名称猜 iCloud。
- [ ] **非破坏性 reconciliation。** 优先复用现有 `invalidateIndexPublication`、`beginIndexReconciliation`、upsert 和任务接口；full-reconcile/事件积压不调用 `invalidateRepresentations(nil)` 清库。保留字节与判定可用性分离，已知改变只处理相关表示，未知记录在验证前不参与当前决定。对全量重建给出明确原因与影响数。仅在必要时扩充既有 schema，并同步迁移、Schema.sql 和崩溃恢复契约，禁止无关存储重构。
- [ ] **初建与持续变化。** 对账/分类期间保留已完成向量和待办；稳定清单会话与通知覆盖终点分离，完整已分类变化可归并到终点，不要求全轮 raw generation 静止；已知变更集合分批持久处理，129 个 ID 不污染其他资产。无关在途任务可按本项证据完成；相关编辑／删除／任务替换的迟到结果必须拒绝。未知输入不发布，实际物理任务终结才释放资源；不靠重建 gateway 逃离占用。新事件到来时完整性屏障仍有效，但不把建设进度重置。
- [ ] **聚焦 RED/GREEN。** 用门闩复现 raw notification、producer 回退、page invalidation、coordinator、真实 SQLite 的完整链路；清单会话与覆盖终点测试须在每页之间送达中性通知、不给整轮静默窗口，断言分页完成、终点覆盖及短发布屏障；未覆盖新增／内容／未知事件则拒绝旧终点。另覆盖十万条库单项变化、有证据的非增量无内容变化、未知历史下相同 metadata 不可复用、129-ID 分批、重复通知期间初建收敛、相关与无关在途结果、分页/崩溃恢复、最终 ready 检查失效。断言向量字节保留、实际行写及读取/模型调用，不能只给 fake 一个“无变化”标签跳过分类接线。新增原生进度断言但不改布局。
- [ ] **独立审阅与完整验证。** 修复后按仓库规定在最终行为快照跑 canonical，并保留原有规模／数值门槛。历史 `bc27a425` 通过不代表本次通过。性能需分别报告清单核对、保留／验证／重算数量、取图与推理次数；不把 QA 每行审计落盘时长当产品耗时。
- [ ] **恢复真实只读验证。** 先补原始 PhotoKit 变更详情／回退分支诊断，使用真实只读计划的同一安全边界。证明有充分证据的非内容通知不会清向量或反复中断初建；无法分类的通知仍等候，不能屏蔽 observer 制造成功。达到完整 ready 后才续跑 MobileBackup 全量扫描和既定盲审。既有测试快照不伪装成新实现结果；换实现后复用照片指纹需依据相同 fingerprintVersion、输入语义和当前内容证据，缺口如实保留。
