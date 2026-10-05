# PhotosYNC 0.2.0 高级照片判重集成 Implementation Plan

> **2026-10-05 当前状态：** 用户明确选定初始阈值 **0.98**，结束进一步独立校准/封存研究，进入产品集成准备。固定配置及当前 33 例的共享 Swift scorer 重放（33/33 内容和动作通过）见[研究收尾](../../research/advanced-dedup/2026-10-05-research-closeout.md)。这是用户决策与固定回归证据，未证明原协议的统计目标。旧 44 例及 0.8 失败报告保留。P1–P8 已实施，P9 已接入资源与验收门槛，真实 33 例已通过，当前规模已实测，历史候选热路径及图库变化就绪时延仍超目标，等待明确性能范围决定；最终全量验收和分支审阅尚未完成。

> **同日产品交互补充：** 用户已确认仅在点击菜单栏图标后的下拉面板展示图库分析，就绪时隐藏；首次自动分析，完成后静默进入同步；iCloud 等待提示与基础同步统计各占一行。用户明确要求实际实现继续使用原生控件。具体约束与验收见 P8，浏览器草图仅用于设计审阅。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将用户选定的 SSCD Large / 0.98 配置接入 Photos 持续索引、SQLite 恢复、串行导入及生产日志，保持来源只读和成功历史保护。

**Architecture:** SQLite 保存可恢复的表示、向量与决定证据，精确向量索引是同代次的派生视图；一个 Photos gateway 负责变化失效与最终提交检查。索引协调器负责增量维护，判重服务负责准备来源和取得有一致性令牌的决定，SyncEngine 保留既有单提交/unknown 恢复语义。复用研究 R2/R3 实现，消费 `docs/research/advanced-dedup/integration-profile.json` 和相互绑定的用户决策、回归及收尾记录，不在集成中重新选阈值。

**Tech Stack:** Swift / Foundation / PhotoKit / ImageIO / Core ML / Accelerate / SQLite / SwiftUI，macOS 13、Universal arm64/x86_64，XCTest 与现有 Python 验收入口。

**Spec:** `docs/superpowers/specs/2026-09-28-photosync-0.2.0-advanced-dedup-design.md`；并读 `docs/specs/2026-09-18-runtime-state-and-recovery.md` 和 `Design/Validation.md`。本次修订代码基线 `7937a9c`；现有 schema v3。

## Global Constraints

- “只读来源；Photos 只新增，不修改、替换、删除已有资产。”导入原始 URL，`shouldMoveFile = false`。
- “保留四种文件状态 `pending`、`importing`、`imported`、`skipped`”；不加产品人工审核环节。
- “视频保持 0.1 的文件名与 metadata 策略”，不增加 RAW 来源、视频抽帧或 Live Photo 配对。
- “不加入 pHash、第二个核验模型、服务端模型或独立向量数据库服务。”固定 SSCD Large FP32、Core ML `.cpuOnly`、全画面 stretch 320×320、sRGB、1024 维 L2 Float32、`exact-f32-v1` 和 `score >= 0.98`；不暗换 FP16、GPU/ANE 或 ANN。
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

**Interfaces:** `protocol PhotosIndexGateway: PhotosGateway { func representationCatalog(offset: Int, limit: Int, expectedGeneration: Int) async throws -> RepresentationPage; func changes() -> AsyncStream<PhotosIndexChange>; func readRepresentation(_ descriptor: RepresentationDescriptor) async throws -> LoadedRepresentation }`；`PhotosIndexChange = assetsChanged([String]) | assetsDeleted([String]) | fullReconcileRequired | contextInvalidated`。`RepresentationPage { context: LibraryContext, generation: Int, descriptors: [RepresentationDescriptor], nextOffset: Int? }` 是按固定代次拉取的有界页，末页 nextOffset=nil；代次改变抛 libraryChanged 而非丢页。现有 `PhotoKitGateway` 同时实现两个协议，只有一个 observer/generation 有效性门。`actor ImageWorkBudget` 产生 `acquire(bytes: Int64) async throws -> ImageLease`；`ImageLease.finishPhysicalWork()` 幂等释放，共享于来源解码和 Photos 读取；不能在逻辑超时 defer 中释放尚未完成的任务。

- [ ] **Step 1 — 写失败测试。** `testDegradedThenFinalPublishesOnce`：degraded 不返回，最终满足版本质量才完成一次；`testCancelThenLateFinalDoesNotPublishOrFreeEarly`：取消不创建 ready，物理结束前槽仍占用；`testEditedDimensionsBelongToEditedRepresentation`：原始 4000×3000、编辑 1000×1000，两个 descriptor 的尺寸不互借；`testUnknownRevisionCannotReuseCachedImage`：nil/不可靠修改线索导致失效；`testUnsupportedAndMultiFrameAreExplicitlyClassified`：无法证明安全单帧等价的 GIF/TIFF/组合资源不从第一帧生成跳过证据。
```swift
XCTAssertEqual(publishedFingerprintCountAfterDegraded, 0)
XCTAssertEqual(occupiedSlotsBeforePhysicalCompletion, 1)
```

- [ ] **Step 2 — 跑 P2 红阶段命令。** 使用注入的 callback requester 和 fake catalog；不申请真实 Photos 权限。
- [ ] **Step 3 — 实现协议与 SDK 契约核对。** 明确使用公开 `PHImageRequestOptions.version` 区分 original/current，以最终高质量回调为唯一完成输入，处理 error/nil/degraded/cancel 与 `isNetworkAccessAllowed=true`。回调给出的已定向位图标为 orientation=up，未定向像素才携带其真实方向，禁止二次应用 EXIF 旋转。记录 macOS 13 SDK 中实际可用签名、原图/当前版尺寸的可信来源和 Live Photo 静态资源范围到 photokit-contract.md。不能可靠拿到对应原尺寸则返回 nil，不能借缩略图或别的表示尺寸。无法通过公开证据证明多帧/复合静态内容等价的格式先视为“不能自动跳过的支持输入”，成功读取后保守导入并记录原因；不得把读取错误归为已确认排除或借此扩大 RAW 支持。
- [ ] **Step 4 — 接入已有有效性和资源生命周期。** callback 立即使旧 Photos generation 失效，再向流合并事件；bounded 缓冲溢出设置不可被后续事件覆盖的 dirty 标记并升级 fullReconcileRequired，不能丢消息。源读取沿用 ReadExecutor 的 sourceID 公平/物理占用规则；共享图像字节预算与 PhotoKit request 上限另外约束。请求槽只在真实终止回调后释放，解码字节租约则由 LoadedRepresentation 持有到最后一次真实推理/消费完成，不能在收到 final 图像时提前释放。超尺寸结果不能继续生成无限额图像副本；记录实际返回尺寸和拒绝原因。预算统计覆盖 App 持有的图像，PhotoKit 内部缓存另实测，不声称可控制系统总内存。ImageIO 限制目标解码，不暂存图片到应用数据目录；请求目标大小不承诺 iCloud 字节上限。公开 API 若不能保证表示语义，报告并停止相关 skip 路径，不能伪称探针已验证。
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
- [ ] **Step 3 — 实现对账与工作循环。** 每次从 candidateSnapshot 取得 generation，再按该 generation 拉取 catalog 页并传给 beginIndexReconciliation。启动/恢复/fullReconcile/context 事件核对轻量清单，不按拍摄时间或总数判断增量。完整枚举结束才清除消失资产；context 无法确认延续则失效当前索引，但不清成功历史。事件观察到即使尺寸不变也失效；可靠 revision 和 same-context 才可复用。暂停仅阻止新工作，已完成结果符合修订时可落库；失败按批准退避期限继续处理其他任务。
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
- [ ] **Step 4 — 全应用与平台验收。** 复用历史 100k/150k/200k 合成向量基线，记录其旧 0.8、研究进程和本地输入的适用边界；不重启已停止的独立准确率/36,887 负例收集。集成后用受控应用负载验证分段耗时、P50/P95/P99、RSS、持久存储与资源上限，工程目标仍为 M2 Pro 热查询 P95 ≤250 ms、单张本地增量 P95 ≤2 秒、峰值 RSS ≤4 GiB；以实际输入和测量范围报告。无变化轮不得下载/推理，单项改变只重算相关表示。十万真实资产（0/50/100% 编辑比例）、真实 iCloud 若没有实际执行则列为未验证，不把合成基线写成实测；不将其补做为当前进入 P1 的前置。macOS13与Intel/arm64分别验证CoreML加载和固定 CPU-only 后端；只构建Universal不算实机通过。实际产品回归或资源预算不满足须修复/报告后再判定发行，不能以本次用户阈值决策掩盖。
- [ ] **Step 5 — 完整自动门槛与分支审阅。** 执行本文件开头的 `scripts/validate.py` 全量入口并保存源码树身份；独立 reviewer 检查集成、持久化和并发风险。修复仅重验受影响部分后，再跑覆盖最终行为的全量验收；等价只读审阅不触发重复测试。`git commit -m "feat: validate and package PhotosYNC advanced dedup resources"`，精确记录最后源码提交与系统证据。
- [ ] **Step 6 — 授权范围内的交付。** 只有版本/channel/build已明确、源码已提交且上述门槛通过，才执行 `scripts/package-release.sh` 的正常本地归档路径；不覆盖旧产物，不手工绕过归档内验收。没有本轮打包/合并/安装授权时交付验证记录与待发布源码，不自行执行推送、安装、启动生产App、Developer ID、公证或公开发布。六张用户照片许可问题与系统验收缺口分别列出，不以功能完成掩盖。

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

任务顺序：研究已按 2026-10-05 用户决策收尾 → P1 → P2 → P3 → P4 → P5 → P6 → P7 → P8 → P9。P2 的SDK/fake实现可与P1的存储工作分开评审，但共享类型与文件必须由单一所有者串行整合，不并发改SyncStore/SyncEngine。持续用最小相关检查；非最终任务不重复平台或真实图库全验收。

用户已授权并采用 subagent-driven 实施 P1–P9。P1–P8 已完成任务级实施与评审；P9 及最后全量验收、分支审阅按当前证据收尾。以下任务框架保留为原计划，不应重新执行已完成步骤。

## 2026-10-05 已批准实施修订与证据

- 初始 0.98 是用户选择；独立统计验收仍为 `not_performed`，不再追加独立校准。历史 44 例和旧失败记录保留。
- 用户批准 decoded allowance 512 MiB；可读且仍超限的支持图像以 `decodedResourceLimit` / `notCompared` 保守导入原文件，不伪造向量或 noMatch，未知/失败/占槽仍守原有等待与错误规则。
- 用户选择 Git LFS；固定权重按 exact-commit pointer、local object SHA/size、完整模型包身份依次校验后才允许归档构建，无自动远端上传。
- P5 实际锁顺序为 store 串行队列 → Photos validity → SQLite 事务；原计划的简写不授权反向持锁或跨 await 等待 Photos。
- 实际 runtime/UI/诊断责任落在 SyncRuntime、AppModel、SyncStatusPresentation、AdvancedRuntimeTests 等已有边界；不为匹配原计划文件名进行机械迁移。
- 当前实施/回归/系统与平台缺口以 [P9 验收记录](../../release/0.2.0-advanced-dedup-validation.md) 为准。P9 已恢复冻结 R2 bounded thumbnail 解码并通过真实 33 例，失败对照仍保留；不能用历史重放替代当前产品验收；最终分支审阅和控制线程验收尚待完成。

P9 真实回归发现并修复未发行的 P4 解码偏差：固定 R2 从引入提交 `f60bf5d` 到冻结底本 `04da1ab` 均使用有界 ImageIO thumbnail 解码。恢复其参数后 33 例从 30/33 回到全部通过，阈值与真值未动；保留 512 MiB 原始 backing 预检、超限保守导入、原始 metadata 尺寸、原 EXIF 处理和物理租约。该修复由控制线程明确确认，先前“full CreateImage 是冻结 R2”的说明不再适用。
