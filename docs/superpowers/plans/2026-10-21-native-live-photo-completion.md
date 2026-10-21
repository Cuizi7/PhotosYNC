# Native Live Photo Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 默认导入完整原生 Live Photo，允许缺半先保存、后到补齐，并通过只完整执行一次的全库历史识别覆盖既有资产。

**Architecture:** 在现有 source reader、SyncStore、PhotoKitGateway 和 runtime 中接入身份识别、目录放行及组级恢复；用一个专用协调器处理成对创建、验证与旧项清理。首次历史任务只负责建立身份索引，持久化完成标记后转入增量处理。所有实际 Photos 写入沿用一个提交槽位，不建立第二套扫描或通用工作流框架。

**Tech Stack:** Swift、Foundation、ImageIO、AVFoundation、PhotoKit、SQLite、XCTest；现有 Xcode project，无新增第三方运行时依赖。

**Spec:** [2026-10-21-native-live-photo-completion-design.md](../specs/2026-10-21-native-live-photo-completion-design.md)，已获用户批准；计划依据提交 `64fd689`，产品代码基线 `773a493`。

## Global Constraints

- 最低 macOS 13；Universal arm64/x86_64。公开 API，新增 API 必须做 availability 检查。
- 来源目录严格只读；使用原资源、`shouldMoveFile = false`，不转码、不缓存源原片、不计算产品级内容哈希。
- Photos 临时原资源合计不超过 512 MiB（536870912 bytes），磁盘保留至少 128 MiB（134217728 bytes）；逻辑超时不释放仍占用的物理槽位。
- 文件只保留 `pending/importing/imported/skipped`；文件保存与整组完成分别记账，计数继续按源文件。
- 精确配对及资源/受保护信息保留验证通过，才允许清理被替代单项；不删除完整 Live Photo 或清空“最近删除”。
- 首次任务完成标记持久化，重启和常规升级不重跑；待核实项目单独重试，不重置完成标记。
- 一次性盘点和自动待核实重试禁止联网取原件；精确定位的补齐/验证才可受预算约束读取云端资源。
- 一个实际 PhotoKit 提交槽位；创建或删除结果未知时阻断新提交。保留成功历史及用户删除阻断。
- 不新增设置开关、独立清理脚本或全库指纹索引。现有诊断显示人话，技术详情留日志/tooltip。
- 自动测试只用自制媒体、UUID 临时库及 fake Photos；真实图库写入按具体授权执行，不启动生产 App。

## Review Focus

1. **已完成任务换进程、升级或权限间断：**不得因新 session/epoch 再执行历史全扫；Task 2/4 的重开数据库测试覆盖。
2. **元数据缺失、同 ID 多个版本与云端完整目标未知：**不能猜测配对或先建重复目标；Task 1/4/7 覆盖。
3. **旧 pending 在目录扫描中提交、共享 placeholder 被逐行恢复：**不得绕过目录门槛或形成重复提交；Task 2/5/7 覆盖。
4. **用户在异步读取期间编辑/删除、删除事件重复投递：**保留变化项并幂等恢复，不复活资产；Task 3/4/7 覆盖。
5. **无启用来源、超预算、网络未结束却逻辑超时：**历史任务仍可暂停、物理资源不超限且不拖死无关工作；Task 3/8 覆盖。

## 执行和文件边界

当前 checkout 已是独立 worktree；执行前按 using-git-worktrees 核对附件和 Git 状态，复用本目录，在当前 HEAD 建立 `codex/native-live-photo-completion` 分支。不要回退到产品基线或丢弃已批准文档。先检查当前及父目录 CLAUDE.md；当前检查未发现该文件。实施中遵守仓库 AGENTS.md，不修改生产数据库。

| 文件 | 责任 |
| --- | --- |
| 新建 `Sources/PhotoSyncCore/Domain/LivePhotoTypes.swift` | 身份、资源引用、组操作、首次任务和诊断的具体类型 |
| 新建 `Sources/PhotoSyncCore/Sources/LivePhotoMetadataReader.swift` | 照片/MOV 原始身份与 timed metadata 识别 |
| 修改 `Storage/SyncStore.swift`、`Storage/Schema.sql` | v11 迁移、观察/组/操作/首次任务事务及排他归属 |
| 新建 `Photos/LivePhotoPhotosGateway.swift`、`Photos/PhotoKitLivePhotoReader.swift` | 专用可注入读取/创建/清理接口；全库资源描述及受保护信息读取 |
| 修改 `Photos/PhotoKitGateway.swift`、`Photos/PhotosResourceReader.swift`、`Photos/PhotosIndexGateway.swift` | 共享提交生命周期、总预算、分类事件与现有索引衔接 |
| 新建 `Sync/LivePhotoInventoryCoordinator.swift` | 一次性清点、身份任务队列、进度与增量衔接 |
| 新建 `Sync/LivePhotoCoordinator.swift`、`Sync/LivePhotoRetirementPolicy.swift` | 组选择、恢复、清理准入；后者为无 I/O 规则 |
| 修改 `Sync/SyncEngine.swift`、`Sync/PhotosIndexCoordinator.swift` | 目录批次放行、普通队列排他、事件落库先于消费 |
| 修改 `Sources/PhotoSyncApp/SyncRuntime.swift`、`AppModel.swift` 及现有状态展示 | 生命周期、无来源工作、暂停、诊断 |
| 修改 `PhotoSync.xcodeproj/project.pbxproj` | 每次新增文件同步加入对应 Core/App/Test target，不留最后补 |

上表未写完整前缀的代码路径均相对 `Sources/PhotoSyncCore/`。不拆分或重写现有整个 SyncStore/SyncEngine。新类型默认 internal，需要跨 Core/App 的摘要和入口才 public。

## 验证命令约定

每个任务先写失败用例，再做最小实现并复跑受影响测试；下面用 `CLASS` 表示各任务指定的 XCTest 类名。

```bash
xcodebuild -project PhotoSync.xcodeproj -scheme PhotoSync -destination 'platform=macOS' \
  -derivedDataPath work/livephoto-dev CODE_SIGNING_ALLOWED=NO build-for-testing \
  > work/livephoto-build.log 2>&1
# 仅构建退出 0 后运行；CLASS 替换为任务列出的具体类，一次一类。
xcrun xctest -XCTest PhotoSyncCoreTests.CLASS \
  work/livephoto-dev/Build/Products/Debug/PhotoSyncCoreTests.xctest
```

先 `mkdir -p work`；保留各轮 RED/GREEN 日志到唯一文件。RED 必须是预期缺失接口/断言失败，环境故障不算重现。GREEN 必须退出 0、有完整结束摘要、实际测试数大于 0 且零失败。这些聚焦检查不替代 Task 9 的 canonical 验收。每个任务提交仅列出本任务文件，不用 `git add .`；不是每个任务都重复完整评审。

## Task 1：原始资源身份识别和自制 fixture

**Files:** 新建 `Domain/LivePhotoTypes.swift`、`Sources/LivePhotoMetadataReader.swift`；新增 `Tests/PhotoSyncCoreTests/LivePhotoIdentityTests.swift`、`LivePhotoTestSupport.swift`；按需接入 `Sources/MetadataReader.swift`；更新 Xcode target。

**Interfaces:**
- `enum LivePhotoRole: String, Codable { case photo, motion }`。
- `LivePhotoIdentity: Codable, Equatable, Sendable`：`contentIdentifier: String`、`role: LivePhotoRole`、`stillImageTime: Double?`、`hasAudio: Bool?`；未知与无音轨区分。
- `enum LivePhotoInspection: Codable, Equatable, Sendable { case identified(LivePhotoIdentity), noIdentifier, unresolved(String) }`；读取损坏仍抛出错误，不伪装 noIdentifier。
- `protocol LivePhotoMetadataReading: Sendable { func inspect(url: URL, kind: MediaKind) async throws -> LivePhotoInspection }`；具体 `LivePhotoMetadataReader` 使用现有 ReadExecutor，不嵌套占用同一读取槽位。

- [ ] 写 `testImageAndMotionShareIdentity`、`testIdentifierWithoutTimedSampleIsUnresolved`、`testMismatchedAndMissingIdentifiersDoNotPair`、`testCorruptMediaThrows`、`testTimedMetadataDoesNotDecodeVideoFrames`。断言：同 ID 两角色正确；ContentIdentifier-only MOV 不能确认为动态部分；错配不能配对；缺标记与读取失败不同。
- [ ] 用 AVAssetWriter/AVFoundation 生成带共享 ID、timed still-image-time、合成画面及音轨的短视频，ImageIO 生成配套 JPEG/HEIC。先断言生成文件经原生 reader 读取到预期标识，不能仅测 fake 字典。不复制那 12 对私人媒体进测试。用已有只读探针的代码作 API 参考，不把外部命令变成产品依赖。
关键断言（测试先取得实际读取值再断言）：
```swift
XCTAssertEqual(photoIdentity.contentIdentifier, motionIdentity.contentIdentifier)
XCTAssertEqual(motionIdentity.role, .motion)
XCTAssertNotNil(motionIdentity.stillImageTime)
```

- [ ] 运行 `LivePhotoIdentityTests` 得到预期 RED。
- [ ] 实现 ImageIO Maker Note 与 AVFoundation QuickTime/timed metadata 读取，覆盖正反例及 metadata 格式差异；源路径校验沿用 SourceRegistry。仅返回证据，不在 reader 决定组/删除。
- [ ] 重跑 `LivePhotoIdentityTests`、`SourceReaderTests`；自制配对原生 PHLivePhoto 加载另记结果，加载成功仍不等于系统图库验收。提交 `feat: identify Live Photo resource roles`。

## Task 2：身份索引、首次任务和组操作的持久化

**Files:** 修改 `Storage/SyncStore.swift`、`Storage/Schema.sql`、`Domain/LivePhotoTypes.swift`、`Domain/MediaRecord.swift`；新增 `Tests/PhotoSyncCoreTests/LivePhotoStoreTests.swift`；更新 target。

**Interfaces / schema 决策:**
- `LivePhotoResourceRef: Codable, Hashable, Sendable` 用 `.source(fileID: UUID, stamp: FileStamp)` 或 `.photos(contextID: UUID, assetID: String, resourceKey: String, revision: String)` 表示资源。需要 Hashable 时为 FileStamp 增加同值合成遵循。
- `resourceKey` 是本 App 从资源角色、原始文件名、UTI、当前描述序号组成的标识，绑定 revision；不是臆造的 PhotoKit 公共 resource ID。revision 是观察版本，不是字节一致性证明。
- 在本任务定义后续接口共用的 `LivePhotoAssetDescriptor`（context、assetID、revision、isLivePhoto、mediaKind、资源引用及角色/原文件名描述）和 `LivePhotoPreservationSnapshot`，避免 store 依赖后续任务才存在的类型。快照字段见 Task 3，先定义可编码值类型，不在本任务做媒体读取。
- `LivePhotoObservation` 含资源引用、inspection、识别版本、检查时间；`LivePhotoGroup` 含图库域、配对 ID、选定资源引用、完整目标及删除阻断。
- `LivePhotoOperation` 含 UUID、组 ID、固定资源引用/源成员 IDs/旧资产 IDs、属性快照、阶段、placeholder、成功目标、错误与重试时间。阶段至少 `planned/creating/created/verifying/readyToRetire/retiring/complete/blocked`；提交证据独立用 `notSubmitted/submitted/confirmed/unknown/failed`，不混淆文件状态。
- 新表：`live_photo_observation`（资源键+revision+识别版本唯一）、`live_photo_group`（图库域+配对ID唯一，冲突版本另记观察）、`live_photo_operation`（操作UUID）、`live_photo_inventory`（图库域+固定任务键唯一）、`live_photo_inventory_item`（任务+资产ID唯一，含 revision/结果/重试状态）。`file_record.live_photo_operation_id` 可空；索引覆盖任务队列、配对身份、操作归属，约束一个成员只属一个活动操作。
- 固定任务键 `live-photo-initial-identification-v1`；任务状态使用 `enum LivePhotoInventoryPhase: String, Codable { case enumerating, identifying, completed }`，保存进度、图库域、coverage、变更检查点、完成时间；App 版本不入主键。复用持久 `LibraryContext.id` 域，`epoch`/运行 session 仅作有效性校验，不能让一次性标记因重启失效。
- Store 方法：`saveLivePhotoObservation(_ observation: LivePhotoObservation) async throws`；`reserveLivePhotoOperation(_ operation: LivePhotoOperation) async throws -> Bool`；`checkpointLivePhotoPlaceholder(operationID: UUID, identifier: String) throws`；`confirmLivePhotoCreation(operationID: UUID, identifier: String) async throws`；`loadLivePhotoOperationsForRecovery() async throws -> [LivePhotoOperation]`；`saveLivePhotoOperation(_ updated: LivePhotoOperation, expectedStage: LivePhotoOperation.Stage) async throws -> Bool` 为其余失败/未知/阻断转换提供带前态比较的持久入口，终态释放成员归属，未知不得释放。
- 任务方法：`ensureLivePhotoInventory(context: LibraryContext) async throws`；`enqueueLivePhotoAssets(context: LibraryContext, assets: [LivePhotoAssetDescriptor]) async throws`；`nextLivePhotoInventoryItem(context: LibraryContext, now: Date) async throws -> LivePhotoAssetDescriptor?`；`recordLivePhotoInventoryResult(context: LibraryContext, assetID: String, revision: String, observations: [LivePhotoObservation]) async throws`；`completeLivePhotoInventory(context: LibraryContext, expectedGeneration: Int) async throws -> Bool`。后者检查清点结束、全行已尝试或待核实入队、变更衔接已持久化，非单纯置布尔值。

- [ ] 写迁移/事务用例：旧 v10 数据和 success_id 不变、迁移失败回滚、未知高版本拒绝；并行预留同成员只成功一次；两成员同 placeholder 同结果；已有 imported 不回退；复用目标只记 skipped；全 imported 的活动组仍可恢复。
- [ ] 写任务重开数据库用例：完成后 `ensureLivePhotoInventory` 不重置；中断保留队列；常规 App 版本、epoch 改变不重置；单项待核实不撤销 completed；上下文无法确认时返回待核实，不凭新 session 创建另一份全扫任务。
关键断言（使用重新打开数据库后的实际查询结果）：
```swift
XCTAssertEqual(oldFileState, .imported)
XCTAssertEqual(oldSuccessIDAfter, oldSuccessIDBefore)
XCTAssertEqual(completedAtAfterRestart, completedAtBeforeRestart)
XCTAssertEqual(successfulReservations, 1)
```

- [ ] 运行 `LivePhotoStoreTests` 得到 RED。
- [ ] 实施事务 v11（先核对是否被并行工作占用），同步 Schema.sql；成员变更与组结果同事务写入，普通 pending/retry/import recovery 查询排除被预留行。数据库事务不访问媒体。保留旧成功及 old→complete 关系，不做数据库重置。
- [ ] 重跑 `LivePhotoStoreTests`、`StoreTests`、`AdvancedDedupStoreTests`、`RecoveryTests`。提交 `feat: persist Live Photo groups and one-time inventory`。

## Task 3：Photos 资源读取与保留信息快照

**Files:** 新建 `Photos/LivePhotoPhotosGateway.swift`、`Photos/PhotoKitLivePhotoReader.swift`；修改 `Photos/PhotosResourceReader.swift`、`Photos/PhotoKitGateway.swift`、`Domain/LivePhotoTypes.swift`；新增 `Tests/PhotoSyncCoreTests/LivePhotoResourceTests.swift`；更新 target。

**Interfaces:**
- 消费 Task 2 的 `LivePhotoAssetDescriptor`，不能从 image-only representationCatalog 推断全媒体覆盖。在此定义 `protocol LivePhotoPhotosGateway: PhotosIndexGateway` 及本任务读取方法，PhotoKitGateway 接入 reader；Task 4/6 依次扩展 catalog/写入方法，不预先依赖后续实现。
- `enum LivePhotoReadPurpose { case inventory, completion }`；inventory 强制 `isNetworkAccessAllowed = false`，completion 也仅接受已准确选定资源引用。
- `LivePhotoResourceLease` 持有 URL 和物理资源所有权，不可仅用逻辑 timeout 释放；`LivePhotoResourceBudget` 提供合计 536870912 bytes、保留134217728 bytes 的预算，读取前预留，结束后释放。
- `func readLivePhotoResource(_ ref: LivePhotoResourceRef, purpose: LivePhotoReadPurpose, budget: LivePhotoResourceBudget) async throws -> LivePhotoResourceLease`。
- `enum PreservedField<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable { case emptyOrNotApplicable, value(Value), unknown }`；此值类型及快照在 Task 2 一并定义，本任务读取填充。`LivePhotoPreservationSnapshot` 保存 revision，以及各自被 PreservedField 包装的 creationDate(Date)、location（可编码的 latitude/longitude/altitude 数值）、favorite/hidden(Bool)、rating(Int)、title/caption(String)、keywords/albumIDs([String])、hasAdjustments/hasExtraResources/isSharedAlbum(Bool)。冲突记为 unknown，并在操作诊断记录原因。
- `func livePhotoPreservationSnapshot(assetID: String, context: LibraryContext) async throws -> LivePhotoPreservationSnapshot`；`func resourcesEqual(_ lhs: LivePhotoResourceRef, _ rhs: LivePhotoResourceRef, budget: LivePhotoResourceBudget) async throws -> Bool`。公开 SDK 不支持的字段为 unknown，绝不通过私有 KVC 获取。

- [ ] 写 `testInventoryNeverEnablesNetwork`、`testCombinedResourcesRespect512MiB`、`testFreeSpaceReserve128MiB`、`testTimeoutRetainsPhysicalLease`、`testExactComparisonRejectsSameIDWithDifferentBytes`、`testUnsupportedProtectedFieldIsUnknown`；覆盖原件请求结束前取消及两输入+验证资源总占用。
关键断言：
```swift
XCTAssertFalse(inventoryRequestOptions.isNetworkAccessAllowed)
XCTAssertLessThanOrEqual(peakReservedBytes, 536870912)
XCTAssertEqual(configuredFreeSpaceReserveBytes, 134217728)
XCTAssertFalse(equalForSameIDButDifferentBytes)
```

- [ ] 运行 `LivePhotoResourceTests` 得到 RED。
- [ ] 扩展原始资源流读，不接入图片像素解码管线；让既有存储回收逻辑管理每个临时文件，增加总预算而不是提高单文件限额。流式比较不产生哈希或全片内存副本。对资源变化、读不完整和磁盘不足失败关闭。
- [ ] 基于 SDK 核对每个受保护字段的读写及 availability：macOS 27 新字段运行时守卫；13–26 无法读的字段为 unknown。PHAssetResource 描述变化/事件间断使 observation 失效，不把描述相同当字节相同。
- [ ] 重跑 `LivePhotoResourceTests`、`PhotosRepresentationTests`。提交 `feat: read bounded Live Photo resources and metadata`。

## Task 4：首次全库识别只运行一次，接续增量与删除事件

**Files:** 新建 `Sync/LivePhotoInventoryCoordinator.swift`、`Tests/PhotoSyncCoreTests/LivePhotoInventoryTests.swift`；修改 `Photos/LivePhotoPhotosGateway.swift`、`Photos/PhotoKitGateway.swift`、`Photos/PhotosIndexGateway.swift`、`Sync/PhotosIndexCoordinator.swift`、`Storage/SyncStore.swift`；更新 target。

**Interfaces:**
- 在专用 gateway 增加 `func livePhotoAssetCatalog(session: PhotosCatalogSession, offset: Int, limit: Int) async throws -> LivePhotoAssetPage`；page 含全媒体描述、generation、nextOffset；复用现有固定 catalog session/资源批量配置，不把进程内 offset 当跨重启可靠游标。
- `LivePhotoInventoryCoordinator(store: SyncStore, photos: any LivePhotoPhotosGateway, metadata: any LivePhotoMetadataReading)`；入口 `func resumeInitialInventory() async throws`、`func processNextInventoryItem(now: Date) async throws -> Bool`、`func setPaused(_ paused: Bool) async`、`func summary() async throws -> LivePhotoInventorySummary`。`LivePhotoInventorySummary` 定义 `phase: LivePhotoInventoryPhase, inventoried: Int, identified: Int, unresolved: Int, completedAt: Date?`，不与源文件 imported 计数相加。
- 用现有 `PhotosIndexDelta.changedAssetIDs/deletedAssetIDs` 保留分类事实；扩展 `PhotoKitLifecycle.replayPersistentChanges` 的投递契约，不再将明确 delete 折叠为 contentChange。`SyncStore.applyLivePhotoDelta(_ delta: PhotosIndexDelta) async throws` 在现有事件消费/ack 之前事务性落库跟踪组阻断及 observation 失效。

- [ ] 写 `testInitialInventoryIncludesUntrackedImagesAndVideos`、`testCompletedInventoryDoesNotEnumerateOnRestartOrUpgrade`、`testInterruptedInventoryResumesPendingItems`、`testUnresolvedItemsDoNotResetCompletion`、`testLibraryChangeDuringPagingDoesNotLoseAssets`、`testDeletionPersistsBeforeAcknowledgement`。使用远多于12项的合成清单，包括普通照片、普通视频、完整 LP、两类独立组成部分和无源历史；断言完成后新建 coordinator 的全量 catalog 调用次数为 0。
- [ ] 写权限间断/游标失效、隐藏资产/非主时间线可访问资产、重复事件、资产在页游标前新增、返还已完成图库的测试。图库身份无法确认时保留旧完成记录并等待核实，不以猜测的新 UUID 自动全扫。
关键断言（重建 coordinator 和重新打开数据库后）：
```swift
XCTAssertEqual(fullCatalogCallsAfterCompletedRestart, 0)
XCTAssertEqual(unresolvedItemRetryCalls, 1)
XCTAssertEqual(initialTaskCompletedAtAfterRetry, initialTaskCompletedAtBeforeRetry)
XCTAssertTrue(deletionBlockWasDurableBeforeEventAck)
```

- [ ] 运行 `LivePhotoInventoryTests` 得到 RED。
- [ ] 实现先枚举资产描述入持久队列，再分批识别原资源；按历史 success_id 关联全部本地记录，未关联资产仍照常识别，缺失历史资产遵守删除保护而非自动重建。重启时复用已持久 asset IDs/revision；若未完成枚举的 snapshot 已失效，可重新对齐轻量清单并去重，但不得重新识别已完成且未变化的资源。未完成单项进入待核实队列，禁止网络的自动重试按现有退避调度，不忙循环。
- [ ] 清点末尾衔接订阅期间事件/持久检查点，原子完成首次任务；完成后只接增量和逐项重试。权限新增范围只登记新增未覆盖资产；现有索引所需的目录核对不得重置本功能完成标记或重新批量读取原件。多消费者复用现有事件持久事实，不能竞争消费导致组漏掉删除。
- [ ] 重跑 `LivePhotoInventoryTests`、`PhotosIndexCoordinatorTests`、`PhotoKitContractTests`。提交 `feat: identify historical Live Photos once per library`。

## Task 5：目录批次先配对，再放行导入

**Files:** 修改 `Sync/SyncEngine.swift`、`Storage/SyncStore.swift`、`Domain/LivePhotoTypes.swift`；新建 `Sync/LivePhotoCoordinator.swift` 的目录观察协议及 `Tests/PhotoSyncCoreTests/LivePhotoDirectoryTests.swift`；按需扩展 `Sources/DirectoryReader.swift` 的测试 seam，不重写其递归策略；更新 target。

**Interfaces:**
- `DirectoryBatchKey: Hashable, Sendable`：`sourceID: UUID, relativeDirectory: String`；本轮 `DirectoryBatchState` 为 enumerating/identifying/ready，绑定 round ID 与来源修订。
- engine 内 `func canSubmitDirectory(_ key: DirectoryBatchKey, roundID: UUID) -> Bool`，与现有 canSubmit 共同使用；每次 await 后及实际 beforeMutation 都复核。
- 在 `Sync/LivePhotoCoordinator.swift` 定义 `protocol LivePhotoDirectoryObserving: Sendable { func observeDirectory(sourceID: UUID, relativeDirectory: String, fileIDs: [UUID]) async throws }`，engine 注入协议，Task 7 的 coordinator 实现。此任务用 fake 完成预留断言：目录身份识别结束后通知 observer，已知完整组先预留，再向普通 drain 放行。正式 runtime 接线在 Task 8，本任务不引用尚不存在的具体 actor。

- [ ] 写 `testNoSubmissionBeforeDirectoryIdentificationCompletes`、`testHEICAndMOVOrderingDoesNotSplitPair`、`testOldPendingAndRetryCannotBypassDirectoryGate`、`testHealthySiblingCanSubmitWithoutWaitingForSubtree`、`testDirectoryFailureHoldsOnlyThatDirectory`、`testSingleUnreadableEntryDoesNotDiscardSiblings`。
- [ ] 写未变 imported/skipped 历史文件仍补身份的用例；确认单项成功计数不增加。跨目录两侧皆 ready 才成对提交；新文件在枚举后出现由下轮处理。
关键断言（用门闩推进同一次测试，不依赖 sleep）：
```swift
XCTAssertEqual(createCallsBeforeDirectoryReady, 0)
XCTAssertEqual(ordinaryCreateCallsForKnownPair, 0)
XCTAssertEqual(healthySiblingCreateCallsWhileOtherDirectoryBlocked, 1)
```

- [ ] 运行 `LivePhotoDirectoryTests` 得到 RED。
- [ ] 保留 DirectoryReader 一次返回直属项的模式，将身份读取和决策分成目录两阶段。用持久观察/文件行存储结果，不在内存积累全来源媒体。暂停/重启后重新建立目录准入，不恢复旧内存 ready 标记。
- [ ] 在有目录可放行后启动/唤醒现有串行 drain，不再为首次可提交目录等待所有来源完成；保持全来源 unseenPending/旧诊断清理只在原完整遍历条件下执行。已提交请求的回调与恢复不受新目录门槛拦截。
- [ ] 重跑 `LivePhotoDirectoryTests`、`EngineTests`、`AdvancedDedupEngineTests`。提交 `feat: admit imports after directory pairing`。

## Task 6：在同一 PhotoKit 提交生命周期支持成对创建和定向清理

**Files:** 修改 `Photos/PhotoKitGateway.swift`、`Photos/LivePhotoPhotosGateway.swift`；新增 `Tests/PhotoSyncCoreTests/LivePhotoKitContractTests.swift`；更新 target。

**Interfaces:**
- 扩展 Task 3 已定义的 `LivePhotoPhotosGateway`，保留 Task 4 的 catalog 接口；唯一实际实现仍为 `PhotoKitGateway`，不是第二个实例。
- `func createLivePhoto(photoURL: URL, motionURL: URL, preservation: LivePhotoPreservationSnapshot, expectedGeneration: Int, beforeMutation: @escaping @Sendable () throws -> Bool, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String`。
- `func retireLivePhotoComponents(assetIDs: [String], expectedGeneration: Int, beforeMutation: @escaping @Sendable () throws -> Bool) async throws`；正常返回仅表示系统明确成功，失败/未知使用既有错误证据规则，取消和超时不能报告未提交。
- 将内部 `PhotoKitCreateCommand` 扩展为具体 mutation 命令枚举：single / livePhoto / retireComponents，并调整 lifecycle.submit 的结果区分 created(identifier)/retired/checkpointFailed/preventedBeforeMutation。旧单文件 PhotosGateway API 保留，全部转到同一 state/admission 及真实请求结束生命周期。

- [ ] 写 fake lifecycle 用例：一次创建有且只有 `.photo`、`.pairedVideo`，两者 shouldMoveFile=false；删除仅 frozen IDs；旧普通创建与成对创建/删除不会并发；未知删除阻断普通创建；最后守卫拒绝时无 mutation；placeholder 失败保留未知；晚到成功仍记账。
关键断言：
```swift
XCTAssertEqual(addedResourceTypes, [.photo, .pairedVideo])
XCTAssertEqual(shouldMoveFileValues, [false, false])
XCTAssertEqual(maxConcurrentPhysicalMutations, 1)
XCTAssertEqual(createCallsWhileRetirementUnknown, 0)
```

- [ ] 运行 `LivePhotoKitContractTests` 得到 RED。
- [ ] 在同一 PHAssetCreationRequest 添加两资源和可写属性/相册；清理单独使用公开删除请求。不把清理与未验证新建放入同一 performChanges；不使用私有 API 或第二个 PhotosGateway 绕过 pending 请求。
- [ ] 保留 create 的旧契约和错误语义；资源 leases 持续到真实 PhotoKit 请求结束，不因调用方逻辑 timeout 提前删除临时输入。纯读取/盘点不获取写入槽位。
- [ ] 重跑 `LivePhotoKitContractTests`、`PhotoKitContractTests`、`RecoveryTests`。提交 `feat: create and retire Live Photo assets through shared gateway`。

## Task 7：统一补齐、属性保留、清理与崩溃恢复

**Files:** 在 Task 5 的 `Sync/LivePhotoCoordinator.swift` 中添加具体 actor；新建 `Sync/LivePhotoRetirementPolicy.swift`、`Tests/PhotoSyncCoreTests/LivePhotoCoordinatorTests.swift`、`LivePhotoRetirementTests.swift`；修改 `Storage/SyncStore.swift`、`Sync/SyncEngine.swift`、`Domain/LivePhotoTypes.swift`；更新 target。

**Interfaces:**
- `LivePhotoCoordinator(store: SyncStore, photos: any LivePhotoPhotosGateway, metadata: any LivePhotoMetadataReading)`；遵循 Task 5 的 `LivePhotoDirectoryObserving`；`func recover() async throws`、`func advanceNext(now: Date) async throws -> Bool`、`func setPaused(_ paused: Bool) async`、`func summary() async throws -> LivePhotoWorkSummary`。
- `LivePhotoRetirementDecision` 为 eligible 或 retain(reasons: [String])；`LivePhotoRetirementPolicy.evaluate(old: LivePhotoPreservationSnapshot, target: LivePhotoPreservationSnapshot, resourcePreserved: Bool) -> LivePhotoRetirementDecision`。单项快照合并由 `mergeForCreation(photo: LivePhotoPreservationSnapshot, motion: LivePhotoPreservationSnapshot) -> LivePhotoPreservationSnapshot` 产出，不能抹掉冲突/unknown。
- gateway 增加 `func verifyLivePhoto(assetID: String, operation: LivePhotoOperation) async throws -> LivePhotoVerification`；记录 subtype、角色/身份、播放对象、方向/时长/静态帧及音轨证据。`LivePhotoVerification` 含通过/未通过项，不用一个 loaded=true 替代内容验证。
- store 增加 `func recordLivePhotoVerification(operationID: UUID, verification: LivePhotoVerification) async throws`、`func beginLivePhotoRetirement(operationID: UUID, assetIDs: [String]) async throws -> Bool`、`func confirmLivePhotoRetirement(operationID: UUID) async throws`；状态转换检查前置阶段与冻结 revision。

- [ ] 写到达顺序/来源与图库混合/两半仅在图库的用例；所有完整新建入口等待首次盘点屏障；未知且无法排除的完整候选阻止新建；已配齐组不拆开提交。完整目标复用不伪造本 App 成功记录。
- [ ] 写资源连续性与清理规则用例：source stamp 未变但内容不同不允许据此删旧；新建实际使用旧 Photos 原资源；复用目标流式相等才能清理；同 ID 多版本、编辑、额外资源、unknown 说明/关键词、冲突日期/位置、共享相簿保留旧项。可写相册并集、favorite/hidden OR；已有完整目标不被静默改属性。
- [ ] 写每阶段 crash/restart 参数化用例：planned、placeholder 后、成功回调后 DB 失败、created、verified、删除 submitted/unknown、数据库已完成但日志未收尾。断言只一个完整目标、无提前删除、旧 imported 不倒退、单文件恢复不抢组成员、用户删除旧/完整目标不复活。
关键断言：
```swift
XCTAssertEqual(fullAssetCreateCountAcrossRestarts, 1)
XCTAssertEqual(retireCallsBeforeVerification, 0)
XCTAssertEqual(retireCallsWithUnknownProtectedFields, 0)
XCTAssertEqual(recreateCallsAfterUserDeletion, 0)
```

- [ ] 运行 `LivePhotoCoordinatorTests`、`LivePhotoRetirementTests` 得到 RED。
- [ ] 按 spec 顺序实现选择→预留/意图→创建或复用→成功记账→验证→最终属性/版本/权限核对→清理意图→清理结果。每个 await 后检查关键条件；将已跟踪删除事件持久阻断纳入提交守卫。恢复先加载所有活动组和未知 mutation，再允许普通队列运行。
- [ ] 自有删除事件仅作关联线索，不凭 fetch 不到认定成功；用户拒绝删除保留待处理且不周期弹窗。真正缺半保持已保存、无 activeWork；受限组不阻塞无关单项，实际提交未知仍全局阻断。
- [ ] 重跑两新测试类以及 `EngineTests`、`RecoveryTests`、`AdvancedDedupEngineTests`。提交 `feat: complete and recover native Live Photos safely`。

## Task 8：runtime、暂停和用户可见状态接入

**Files:** 修改 `Sources/PhotoSyncApp/SyncRuntime.swift`、`AppModel.swift`、`Sources/PhotoSyncCore/Sync/SyncEngine.swift`、`Sync/GlobalStatus.swift`、`Sources/PhotoSyncApp/SyncStatusPresentation.swift`；修改 `Tests/PhotoSyncCoreTests/AdvancedRuntimeTests.swift`、`AppModelTests.swift`、`SyncStatusPresentationTests.swift`、`AppViewTests.swift`。

**Interfaces:**
- `LivePhotoInventorySummary`（Task 4 定义）与 `LivePhotoWorkSummary`（Task 7 定义）加入 EngineSnapshot/RuntimeState 的独立字段；后者定义 `activeGroups: Int, awaitingVerification: Int, awaitingRetirement: Int, unknownMutation: Bool`，不改变 SyncStatusSummary 文件计数。
- runtime 在既有初始化、tick、暂停/恢复中驱动两个协调器；先恢复写入阻断，再安排盘点与扫描。AppModel.canTogglePause 使用“有启用来源或有历史/组工作”，不再只看 hasEnabledSources。

- [ ] 写无启用来源仍会一次盘点、全局暂停不安排新读取/提交但接收已发请求回调、完成任务重启不会重新全扫、只剩待核实不忙循环、源文件计数不因 Photos-only 组增加等断言。
- [ ] 写既有菜单/设置状态展示：`正在识别历史 Live Photo`、`历史识别已完成，部分项目待核实`、`Live Photo 已补齐，旧项目待清理`；错误系统原文只入 detail，不显示内部 ID。清点/识别/待核实数量独立于导入数量。
关键断言：
```swift
XCTAssertTrue(canTogglePauseWithOnlyInventoryWork)
XCTAssertEqual(newMutationsAfterPause, 0)
XCTAssertEqual(sourceImportedCountAfterPhotosOnlyCompletion, sourceImportedCountBefore)
```

- [ ] 运行上述受影响测试类得到 RED。
- [ ] 接线并在现有诊断位置展示；读取限流继续复用调度和 ReadExecutor 物理容量，不为全库任务另起无界任务池。保持 demo 不建立真实 store/gateway/runtime。
- [ ] 重跑相关 runtime/AppModel/状态/视图测试；用 --demo 或现有离屏测试检查文案长度与暂停入口，禁止为演示启动生产 runtime。提交 `feat: expose Live Photo progress in existing runtime UI`。

## Task 9：集成验收、系统边界和交付记录

**Files:** 修改 `Tests/PhotoSyncCoreTests/AdvancedDedupRegressionTests.swift` 的相关合成规模覆盖；按新增锚点核对 `Tests/Regression/ContinuationRace.swift`、`scripts/test-continuation-race.py`；更新 `Design/Validation.md`、`README.md`、`docs/specs/2026-09-18-runtime-state-and-recovery.md` 的改变契约；新增 `docs/validation/2026-10-21-live-photo-completion.md`。仅当必须修改 Python harness 时读取 python-development-guidelines，不顺带重构脚本。

- [ ] 为现有规模 fixture 加入分散的成对/缺半/完整目标/历史成功记录，验证身份查询走索引、盘点分批、第二次启动盘点调用为零、混合资源预算和 idle/resume 不回退；不降低原有阈值或缩减四档规模。核对续体竞态 harness 仍对实际新旧提交交错有效。
- [ ] 用受控 fake 在实际 runtime 图中验证一次性扫描→目录配对→创建→清理→重启，以及各故障边界；最终测试先覆盖最后一次行为变更。
- [ ] 请 tester 运行并解释一次完整 canonical 验收：

```bash
python3 scripts/validate.py --scale-profile full \
  --output-dir "$PWD/work/validation-livephoto-final" \
  --derived-data "$PWD/work/validation-livephoto-final-derived"
```

必须输出完整无过滤 XCTest、Tools、受控续体竞态及四档 full profile 的有效成功报告。目录若已存在，换唯一名称，保留失败证据；不拿几项 selected tests 或旧日志宣告通过。

- [ ] 请 deep_reviewer 一次审阅集成 diff，覆盖迁移、并发、PhotoKit 真实 mutation、删除边界、首次任务完成语义及授权范围。修复范围内问题后只复核相关差异；最终 canonical 证据必须覆盖最后一次行为/测试变更，不因只读评审重复跑未变快照。
- [ ] 准备可审阅的系统测试清单和自制资源：单次成对导入、HEIC先到/MOV先到、图库既有单项、只有Photos两半、LIVE画面/声音/方向/时长、旧项最近删除、暂停、重启不全扫、未知/用户拒绝。优先使用用户确认的独立测试账号系统图库；执行前核对具体图库和写入授权，缺少授权时给出准备好的确切测试范围再请求，不以那12个私人样本代替测试。不得切换系统图库或开关iCloud。
- [ ] 系统验证记录实际 OS、源码 commit、输入资源及断言；0x0 的 PHLivePhoto 加载探针不能充当播放证据。macOS13实机、iCloud多设备、系统授权、删除确认未完成则单独标记未验证；不声称与iPhone原生效果等价已实测。
- [ ] 文档对齐实际实现，记录构建、自动测试、GUI、真实Photos、平台兼容各自结果和剩余限制；提交 `test: validate Live Photo completion and one-time inventory`。本计划不包含生产库维护、安装、自动启动、远端推送、合并或发布；如后续授权发布，使用现有 package-release.sh 从确切提交归档验证。

## 依赖与收尾检查

执行顺序：1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9。任务间共享 Store/Gateway/Engine，默认串行实现；探索、文档核对、最终 tester/reviewer 可按需委派，不安排多个代理同时编辑这些文件。

规格映射：§1目录行为→Task5/7；§2原生能力→Task1/6/9；§3历史盘点与资源→Task1/3/4；§4持久/判重→Task2/5/7；§5创建清理→Task3/6/7；§6恢复删除→Task2/4/6/7；§7验收→Task8/9。每一项改动都须映射到该表，不吸收邻近无关修复。

用户已批准本计划并选择串行实施；当前进度和实际验证范围见[验收记录](../../validation/2026-10-21-live-photo-completion.md)。本计划不授权安装、生产数据维护、远端发布或合并。
