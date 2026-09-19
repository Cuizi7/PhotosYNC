# PhotosYNC 0.1.0 beta3 Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 2026-09-19 审查确认的并发、恢复、调度、UI、日志及时间解析问题，通过验证后构建独立的 PhotosYNC 0.1.0 beta3（build 3）Universal app/DMG。

**Architecture:** 保留 SyncStore → SyncEngine → SyncRuntime → AppModel/SwiftUI 的现有结构。数据库原子保护未确认提交，运行时消费文件重试期限，目录与文件问题分别恢复；UI 复用已有纯展示层计算状态，不增设同步框架、持久化状态或数据库版本。按一个 beta3 交付计划组织可独立测试的修复任务，最后集中做一次深度集成评审与打包。

**Tech Stack:** Swift、SwiftUI/AppKit、PhotoKit、SQLite、XCTest、Xcode 26+、zsh；无第三方运行时依赖。

**Spec:** `outputs/2026-09-13-photo-sync-v1-design.md`、`docs/specs/2026-09-18-runtime-state-and-recovery.md`、`AGENTS.md`、`Design/Validation.md`；本计划的“验收口径”明确本次审查修复范围。审查基线为 `de594b3044086eb8b45c26468da2ab3bd53555c6`，当时 build-for-testing 成功、170 项 XCTest 通过；执行时重新核对 HEAD，不把历史结果当成改后验证。

## Global Constraints

- “最低 macOS 13”；保持 arm64/x86_64 Universal 发布。
- “源目录严格只读：不删除、移动、重命名、改内容、改 metadata、写标记或缓存。”
- “Photos 仅新增资产，不覆盖、编辑、删除已有资产，不创建目录/相簿映射。”
- “导入使用原始文件 URL，`shouldMoveFile = false`。”
- “不计算产品级内容哈希、不暂存原片、不下载整套 iCloud 原片用于判重。”
- “仅四种文件状态：`pending`、`importing`、`imported`、`skipped`。重试和跳过原因是字段，不扩充状态。”
- “成功历史不随目标消失、来源停用、源属性变化而清空。”
- “只有明确失败证据才允许重试。”
- “同一时刻只能有一个实际 Photos 提交。”
- “暂停/停用停止新提交，已经提交的结果仍必须落库。”
- schema 保持 v3；本计划不迁移、清理或修复生产数据库中的历史记录。
- 产品名 PhotosYNC；project/scheme/module/bundle ID 与 `Application Support/PhotoSync` 路径不变。
- 操作错误、系统错误原文只进入日志/tooltip；主要 UI 文案使用可行动的中文摘要。
- 测试使用 UUID 临时目录、自制媒体及 fake gateway；不得从生产数据库复制路径去扫描真实媒体。
- 不启动生产应用、不覆盖已安装应用、不操作真实 Photos、不更改登录项/通知权限、不推送或公开发布。
- GUI 验证不得抢占用户前台焦点或使用全局模拟快捷键；原生操作只能在可独立操作的测试环境进行。受限时如实记录未完成，不能用离屏图替代原生验收。
- beta3 输出为 `outputs/releases/0.1.0-beta3/`；保留 beta1/beta2，现有目录禁止覆盖。

---

## 验收口径和范围决策

| 审查发现 | 本次要求 | 任务 |
| --- | --- | --- |
| P1 扫描覆盖 importing 的身份 | 原子阻止覆盖；晚到成功仍可入库；正常并发变化不毒化整个 engine | 1 |
| P2 文件重试等到 30 分钟 | 到期后的第一个正常 tick 尝试，允许约 1 秒轮询误差；不改变 30 分钟周期 | 2 |
| P2 恢复目录受坏文件牵连 | 完整目录遍历恢复后清除目录问题，文件问题继续保留 | 3 |
| P2 deferred 虚报完成 | 未完成工作不显示完成；正常等待不成为错误 | 4 |
| P2 文件错误冒充来源恢复 | 只有 sourceAvailability 才叫“等待恢复”；其他类别分别展示 | 4 |
| P3 日志跨文件误去重 | 来源/阶段/文件分别去重，同文件同错误仍去重 | 3 |
| P3 停用没有启用入口 | 原位置启用，复用原 ID 和历史；校验失败保持停用 | 5 |
| 菜单内容可能超高 | 状态列表可滚动、操作区固定可见；先验证布局边界再保留修复 | 5 |
| 两份文档的状态优先级冲突 | 保留明确批准的“真实来源不可用优先于运行中”，统一运行时契约；文件错误不属于来源不可用 | 4 |
| 非法日期及视频小数秒 | 无效日历日期返回 nil；合法带 offset 的小数秒转换并向下取整 | 6 |
| beta3 构建 | version 0.1.0/channel beta3/build 3，Universal、ad-hoc 签名、独立 DMG、commit 与 SHA256 证据 | 7 |

本计划不包含挂载身份跟踪、自动挂载、全量内容判重、图库修复、数据库清理、任意文件结构重构、Developer ID/公证。若执行中发现必须扩大这些边界才能修复，先报告具体影响，不能通过修改本计划自我授权。

## 文件和责任地图

| 文件 | 本次职责 |
| --- | --- |
| `Sources/PhotoSyncCore/Storage/SyncStore.swift` | 原子源变化保护、到期重试来源查询；不改 schema |
| `Sources/PhotoSyncCore/Sync/SyncEngine.swift` | 使用原子结果、统一注入时钟、按目录恢复、文件日志身份 |
| `Sources/PhotoSyncCore/Sync/ScanSchedule.swift` | 沿用现有 requestNow/来源两条退避；仅在必要时补聚合期限接口 |
| `Sources/PhotoSyncApp/SyncRuntime.swift` | 消费文件重试期限、启用来源入口、恢复通知正确摘要 |
| `Sources/PhotoSyncApp/SyncStatusPresentation.swift` | 无副作用的全局状态和文案映射 |
| `Sources/PhotoSyncApp/AppModel.swift` | 调用纯状态映射、来源操作进行中保护、启用动作 |
| `Sources/PhotoSyncApp/SourceSettings.swift` | 启用/停用入口、动作可用性 |
| `Sources/PhotoSyncApp/StatusMenu.swift` | 有界滚动信息区及固定操作区 |
| `Sources/PhotoSyncCore/Sources/MetadataReader.swift` | 严格日期与小数秒解析 |
| `Tests/PhotoSyncCoreTests/StoreTests.swift` | 状态转换与到期查询行为 |
| `Tests/PhotoSyncCoreTests/EngineTests.swift` | 目录/文件混合恢复、日志隔离、并发成功证据 |
| `Tests/PhotoSyncCoreTests/GlobalStatusTests.swift` | runtime tick、启用、暂停/停用与时钟行为 |
| `Tests/PhotoSyncCoreTests/SyncStatusPresentationTests.swift` | 纯状态/文案矩阵，避免创建 AppModel 真实 runtime |
| `Tests/PhotoSyncCoreTests/SourceReaderTests.swift` | 真实已有媒体 fixture + parser 边界 |
| `Tests/PhotoSyncCoreTests/TestSupport.swift` | 只放多项测试共用的 fake/门闩；不搬入整个审查 harness |
| `Sources/PhotoSyncApp/Info.plist`、`PhotoSync.xcodeproj/project.pbxproj` | beta3 channel/build；必要的 target membership |
| `scripts/package-release.sh` | beta3 独立、不可覆盖的已提交快照打包 |
| `docs/release/0.1.0-beta3.md`（新建） | 发布变化与实际验证边界 |
| `README.md`、`AGENTS.md`、运行时契约、`Design/Validation.md` | 最终行为与版本交接，保留历史验证，不改写历史结果 |

上述源文件已有 Xcode membership；默认不新增产品文件或模块。若新增 XCTest 文件，必须加入 PhotoSyncCoreTests Sources build phase。不要把 work 下的生成文件加入 project。

## 执行、验证与提交约定

执行时用 `superpowers:using-git-worktrees` 创建隔离分支 `codex/photosync-beta3-fixes`；计划编写阶段不创建 worktree。先检查工作树和父目录 CLAUDE.md。计划若仍未提交，先将本计划单独提交，再创建包含该提交的工作副本；不带走或丢弃其他用户变更。

所有下面的命令在执行工作树根目录运行。给当前 shell 定义以下函数，仅存入终端或 `work/`，不额外提交构建包装脚本：

```bash
mkdir -p work
beta3_build_tests() {
  xcodebuild -project PhotoSync.xcodeproj -scheme PhotoSync \
    -destination 'platform=macOS' -derivedDataPath work/Beta3Validation \
    CODE_SIGNING_ALLOWED=NO build-for-testing > work/beta3-build.log 2>&1
}
beta3_test_case() {
  xcrun xctest -XCTest "$1" \
    work/Beta3Validation/Build/Products/Debug/PhotoSyncCoreTests.xctest
}
```

每个任务先添加行为断言，运行 `beta3_build_tests && beta3_test_case 'PhotoSyncCoreTests/具体类/具体方法'`，记录 RED 的具体断言；新增签名的编译错误不是行为 RED 的替代品，先让调用可编译并保持旧行为再观察断言。修复后重建并运行相同测试与受影响现有类。构建失败不得运行旧 bundle。正常权限构建若因沙箱/actool 受限，按工具权限流程重试并保留两份日志，不删除用户缓存。

每项先完成所有覆盖场景再提交；提交只含任务列出的文件。复用 `makeEngineFixture`、`EngineTestGate`、`RuntimeClock` 等现有 helper 时先查看定义；下面 XCTest 内的 await 均先赋局部值，再传给 XCTAssert，避免异步 autoclosure 编译错误。

---

### Task 1: 原子保护未确认导入身份

**Files:** Modify `SyncStore.swift`（recordSourceChange、beginAttempt 的调用边界），`SyncEngine.swift`（两个 recordSourceChange 调用及 beginAttempt 错误分类）；Test `StoreTests.swift`、`EngineTests.swift`。

**Interfaces:**
- Consumes: `file(sourceID:relativePath:) async throws -> StoredFile?`、`beginAttempt(fileID:attemptID:) async throws`、`checkpointPlaceholder(fileID:attemptID:identifier:) throws`、`markImported(fileID:attemptID:identifier:) async throws`。
- Produces: `@discardableResult public func recordSourceChange(fileID: UUID, stamp: FileStamp) async throws -> Bool`；true 表示实际记录变化，false 仅表示当前 importing 被保护；缺失 ID/SQL 失败继续 throws。

- [ ] **1. 添加失败测试，证明 importing 的身份不会丢失。** 在 StoreTests 类内使用已有 `makeRoot()` 与 `source(sourceID:root:relativePath:size:modified:)`：

```swift
func testSourceChangePreservesUnconfirmedAttempt() async throws {
    let root = try makeRoot()
    let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
    let sourceID = try await store.registerSource(url: root)
    let file = source(sourceID: sourceID, root: root)
    let fileID = try await store.save(file, decision: .importNew)
    let oldValue = try await store.file(sourceID: sourceID, relativePath: "a.jpg")
    let stale = try XCTUnwrap(oldValue)
    let attempt = UUID()
    try await store.beginAttempt(fileID: fileID, attemptID: attempt)
    try store.checkpointPlaceholder(fileID: fileID, attemptID: attempt, identifier: "asset")
    if stale.state != .importing {
        try await store.recordSourceChange(fileID: fileID, stamp: .init(size: 99, modifiedNanoseconds: 99))
    }
    let during = try await store.file(sourceID: sourceID, relativePath: "a.jpg")
    XCTAssertEqual(during?.state, .importing)
    XCTAssertEqual(during?.attemptID, attempt)
    XCTAssertEqual(during?.placeholderID, "asset")
    XCTAssertEqual(during?.file.stamp, file.stamp)
    try await store.markImported(fileID: fileID, attemptID: attempt, identifier: "asset")
    let success = try await store.successIdentifier(of: fileID)
    XCTAssertEqual(success, "asset")
}
```

- [ ] **2. 运行并确认 RED。** `beta3_build_tests && beta3_test_case 'PhotoSyncCoreTests/StoreTests/testSourceChangePreservesUnconfirmedAttempt'`；应失败于 state/attempt/placeholder，而不是启动真实图库。
- [ ] **3. 在已有串行数据库事务中核对实时状态并执行更新。** 保留原成功字段，不能把 false 转成 invalidTransition：

```sql
UPDATE file_record
SET size = ?, modified_ns = ?, state = 'skipped', skip_reason = ?,
    attempt_id = NULL, placeholder_id = NULL
WHERE id = ? AND state <> 'importing';
```

实现形状：`perform { transaction { 读取 id 当前 state；不存在 throw notFound；importing return false；requireChange(上述 SQL)；return true } }`。读取和 UPDATE 必须处于同一个现有事务/队列闭包；不能在两次 async 调用间检查。两个 engine 调用只在返回 true 时清除该记录对应问题；false 保留候选/恢复状态。

- [ ] **4. 验证反向交错。** 扫描先将 pending 变成 skipped、drain 后尝试 beginAttempt 时不能提交，也不应毒化数据库：仅捕获 `SyncStoreError.invalidTransition`，重新读取该文件；若已非 pending，清除本次内存 activeAttempt 并 continue；记录仍 pending 或查询失败则保留原存储错误处理。不要吞掉 checkpoint/markImported 的 invalidTransition。补行为断言：createCount=0、blockingError=nil、state=skipped。
- [ ] **5. 加入引擎成功回调回归。** 使用已有 fake gateway 的 creationGate，在已 checkpoint 的 create 等待期间调用 store.recordSourceChange，再 release；等待 scan task 完成后断言 imported、success ID 非空、blockingError=nil。补 pending 正常变化为 skipped、imported 变化后历史不丢、缺失 ID 抛错、重开库 importing 身份仍在四组断言。禁止把审查 scratch 注入 latch 的 Store 拷贝放进产品。
- [ ] **6. 运行 StoreTests、EngineTests、RecoveryTests，GREEN 后提交。**

```bash
beta3_build_tests && beta3_test_case 'PhotoSyncCoreTests/StoreTests'
beta3_test_case 'PhotoSyncCoreTests/EngineTests'
beta3_test_case 'PhotoSyncCoreTests/RecoveryTests'
git add Sources/PhotoSyncCore/Storage/SyncStore.swift Sources/PhotoSyncCore/Sync/SyncEngine.swift Tests/PhotoSyncCoreTests/StoreTests.swift Tests/PhotoSyncCoreTests/EngineTests.swift
git commit -m "fix: preserve import evidence during source changes"
```

### Task 2: 将到期文件重试接入真实 tick

**Files:** Modify `SyncStore.swift`、`SyncEngine.swift`、`SyncRuntime.swift`；Test `StoreTests.swift`、`GlobalStatusTests.swift`。

**Interfaces:**
- Produces: `public func dueRetrySourceIDs(at now: Date) async throws -> [UUID]`；仅返回启用且未移除来源中明确失败、已到期 pending 的来源 ID。
- Produces: SyncEngine initializer 尾部增加 `now: @escaping @Sendable () -> Date = { Date() }`，保存为私有 closure；SyncRuntime 创建 engine 时传同一 closure。
- Consumes: `ScanSchedule.requestNow(now:)`、`dueRecoverySources(now:)`、现有两条来源 deadline、`SyncRuntime.waitForRound()`，不引入第二个 timer/drain。

- [ ] **1. 写 runtime 集成失败用例。** 放在 GlobalStatusTests.swift 的 RuntimeIntegrationTests 内；复用该文件 RuntimeClock：

```swift
func testDueFileRetryRunsAtFiveSeconds() async throws {
    let f = try await makeEngineFixture(sourceCount: 1)
    let clock = RuntimeClock()
    let engine = SyncEngine(store: f.store, photos: f.photos, now: { clock.read() })
    let runtime = SyncRuntime(store: f.store, engine: engine,
                              now: { clock.read() }, authorized: { true })
    await f.photos.setCreationError(.definitelyNotCommitted("temporary"))
    try await runtime.prepareInjectedRuntime()
    await runtime.tick(force: true)
    await runtime.waitForRound()
    await f.photos.setCreationError(nil)
    clock.set(4)
    await runtime.tick()
    await runtime.waitForRound()
    let beforeDue = await f.photos.createCount
    XCTAssertEqual(beforeDue, 1)
    clock.set(5)
    await runtime.tick()
    await runtime.waitForRound()
    let afterDue = await f.photos.createCount
    XCTAssertEqual(afterDue, 2)
    let state = await runtime.current()
    XCTAssertEqual(state.snapshot.summary?.imported, 1)
    XCTAssertEqual(state.nextScan, Date(timeIntervalSince1970: 1800))
}
```

- [ ] **2. 提供默认不改变行为的时钟注入，再观察 RED。** 将 engine 的 retry 比较、nextRetry、明确恢复后的立即重试和扫描起止时间统一到该 closure；删掉 `nextRetry(for:now: = Date())` 的真实时钟默认参数。先不改 runtime 触发条件，运行上述测试，确认 +5 秒 createCount 仍为 1。
- [ ] **3. 增加到期查询并测试活动来源过滤。** 使用现有 `perform/rows/uuid` helper：

```sql
SELECT DISTINCT source.id
FROM file_record JOIN source ON source.id = file_record.source_id
WHERE source.enabled = 1 AND source.removed = 0
  AND file_record.state = 'pending'
  AND file_record.last_error IS NOT NULL
  AND file_record.definitely_not_committed = 1
  AND file_record.next_retry_at IS NOT NULL
  AND file_record.next_retry_at <= ?
ORDER BY source.id;
```

StoreTests 建立两条同来源已到期记录、未来记录、未失败 pending、importing、停用和移除来源记录；断言结果仅含一个正确来源 ID，deadline 前为空、恰好 deadline 时出现。

- [ ] **4. 在 tick 无在飞行 round 后消费文件 deadline。** 算法如下，保留 force 和普通周期分支优先级：

```swift
let dueSourceRecovery = Set(schedule.dueRecoverySources(now: now)).intersection(enabled)
let dueFiles = Set(try await store.dueRetrySourceIDs(at: now)).intersection(enabled)
let heldSources = registeredFailures.union(state.snapshot.deferredSources)
let eligibleFiles = dueFiles.subtracting(heldSources).union(dueFiles.intersection(dueSourceRecovery))
```

在数据库 await 返回后重新检查 stopped、paused、授权、enabled 和 round；重新过滤集合，不可使用过期许可。非空 eligibleFiles 使用 `schedule.requestNow(now:)`，本轮 ids 为 eligibleFiles ∪ dueSourceRecovery；不能使用带 60 秒 recoveryPollAt 门槛的 requestRecovery 来限制 5 秒文件重试。保留现有单个 round/drain，requestNow 不重置 nextScanAt。查询失败走人话数据库错误，不当作“没有到期文件”。

- [ ] **5. 补齐定时边界。** 连续失败分别在累计 t=5、20、50、110 发生；相同 deadline 多次 tick 不重叠；暂停期间零新提交、继续后到期项可推进；停用/移除不重试；未知 importing 不重试；来源不可用和 deferred 的未来 deadline 不被过期文件绕过；重启后到期记录可被发现；另一健康来源不受影响。用共享假时钟推进，不改数据库 deadline、不 sleep 等待 30 分钟。
- [ ] **6. GREEN 后提交。**

```bash
beta3_build_tests && beta3_test_case 'PhotoSyncCoreTests/RuntimeIntegrationTests'
beta3_test_case 'PhotoSyncCoreTests/StoreTests'
beta3_test_case 'PhotoSyncCoreTests/ScheduleTests'
git add Sources/PhotoSyncCore/Storage/SyncStore.swift Sources/PhotoSyncCore/Sync/SyncEngine.swift Sources/PhotoSyncApp/SyncRuntime.swift Tests/PhotoSyncCoreTests/StoreTests.swift Tests/PhotoSyncCoreTests/GlobalStatusTests.swift
git commit -m "fix: schedule due file retries independently"
```

### Task 3: 分离目录恢复与文件问题，修正日志身份

**Files:** Modify `SyncEngine.swift`；Test `EngineTests.swift`、`GlobalStatusTests.swift`。

**Interfaces:** 保留 SourceIssueKind 与 sourceIssues 结构；继续用目录问题键 `scan:directory`、文件问题键 `scan:file:<relativePath>`。新增局部目录遍历完整性变量，不增加持久化字段。`notifySourceIssue(UUID, Bool, SourceIssue?)` 签名不变。

- [ ] **1. 写目录恢复后仍有坏文件的 RED。** 在 EngineTests.swift 定义两个仅用于本组测试的 helper：

```swift
private actor Beta3RecoveryDirectory: DirectoryReading {
    private var calls = 0
    func entries(in directory: URL) async throws -> [DirectoryEntry] {
        calls += 1
        if calls == 1 { throw CocoaError(.fileReadNoSuchFile) }
        return [DirectoryEntry(url: directory.appendingPathComponent("broken.jpg"),
                               isDirectory: false, stamp: nil)]
    }
    func stamp(of file: URL) async throws -> FileStamp {
        FileStamp(size: 12, modifiedNanoseconds: 1)
    }
}
private struct Beta3BrokenMetadata: MetadataReading {
    func read(url: URL, filename: String) async throws -> MediaMetadata {
        throw MetadataError.unreadable
    }
}
```

在 EngineTests 类内添加：

```swift
func testRecoveredDirectoryKeepsOnlyFileIssue() async throws {
    let f = try await makeEngineFixture(sourceCount: 1)
    let reader = Beta3RecoveryDirectory()
    let engine = SyncEngine(store: f.store, photos: f.photos,
                            directory: { _ in reader }, metadata: { _ in Beta3BrokenMetadata() })
    await engine.scan(sourceIDs: f.sourceIDs)
    let offline = await engine.snapshot()
    XCTAssertEqual(offline.waitingSources[f.sourceIDs[0]]?.kind, .sourceAvailability)
    await engine.scan(sourceIDs: f.sourceIDs)
    let recovered = await engine.snapshot()
    XCTAssertEqual(recovered.waitingSources[f.sourceIDs[0]]?.kind, .file)
    XCTAssertEqual(recovered.sourceFileIssueCounts[f.sourceIDs[0]], 1)
    XCTAssertEqual(recovered.latestScan.failedFiles, 1)
}
```

- [ ] **2. 运行该测试，确认第二轮仍为 sourceAvailability 的 RED。** `beta3_build_tests && beta3_test_case 'PhotoSyncCoreTests/EngineTests/testRecoveredDirectoryKeepsOnlyFileIssue'`。
- [ ] **3. 跟踪完整目录遍历，与文件读取结果分离。** 在 scanSource 里建立 `directoryTraversalComplete = true`；目录 entries 抛错（包括 deferred）、遍历中暂停/停用或仍有未访问目录时置 false。metadata/stamp 的失败或 deferred 不改变目录遍历完整性。处理完成后：

```swift
if directoryTraversalComplete && directories.isEmpty && canScan(sourceID: sourceID) {
    resolveSourceIssue(sourceID, key: Self.directoryScanIssueKey, runID: run)
}
```

必须在完整遍历后清除，不能刚读到根目录就清除子目录故障。保留原 failedFiles、scan_run complete、文件问题与提交问题；整轮干净时仍使用 resolveScanIssues 清除已消失文件的旧问题。
- [ ] **4. 验证通知和退避。** 来源从 sourceAvailability 转为 file 时，runtime 解除 registeredFailures，不再增长目录退避；文件仍按其规则显示。保留现有“只有全部问题解决才发完整恢复”的聚合通知语义：目录恢复但文件问题仍在时不发送“全部恢复正常”，也不重发首次失败；最后一个文件问题清除后恰好一次恢复通知。覆盖子目录仍失败时不恢复、暂停截断不恢复、目录 deferred 不恢复、坏文件修复后问题清零。
- [ ] **5. 补日志跨文件 RED 并修复 key。** 用单来源两个不同文件、相同 submission-stamp 错误验证日志应包含两个不同 file ID；重复同一文件同一错误不新增；恢复后再次失败新增。现有 `logFailureOnce` 中 key 改成：

```swift
let identity = keyPath ?? path ?? fileID?.uuidString ?? ""
let key = "\(sourceID.uuidString)|\(phase)|\(identity)"
```

同时对 submission-stamp 调用显式传 `keyPath: record.file.relativePath` 和 `path: record.file.url.path`；清除单文件问题时清除该文件 submission-stamp 签名，不能清掉其他文件签名。日志读取同步通过现有 logger 串行队列的测试 drain（如确有需要，只新增 internal `flushForTesting() { queue.sync {} }` 并使用 @testable），不以固定 sleep 等待落盘。

断言使用解析后的 JSON 行，匹配 `phase == "submission-stamp" && result == "failed"`，再比较 `Set(rows.compactMap { $0["file"] })` 等于两个真实 fixture ID；不得仅断言日志文件存在。
- [ ] **6. GREEN 后提交。**

```bash
beta3_build_tests && beta3_test_case 'PhotoSyncCoreTests/EngineTests'
beta3_test_case 'PhotoSyncCoreTests/RuntimeIntegrationTests'
git add Sources/PhotoSyncCore/Sync/SyncEngine.swift Tests/PhotoSyncCoreTests/EngineTests.swift Tests/PhotoSyncCoreTests/GlobalStatusTests.swift
git commit -m "fix: separate directory recovery and per-file diagnostics"
```

若确实增加 RunLogger 测试 drain，将该文件单独检查后同次加入，不顺手调整轮转或日志格式。

### Task 4: 统一全局状态计算与中文提示

**Files:** Modify `SyncStatusPresentation.swift`、`AppModel.swift`、`docs/specs/2026-09-18-runtime-state-and-recovery.md`；Test `SyncStatusPresentationTests.swift`、`GlobalStatusTests.swift`。保留 GlobalStatus 六个枚举值及原始 resolve API。

**Interfaces:** 在已有 SyncStatusPresentation 中新增：

```swift
func globalStatus(enabledSourceIDs: Set<UUID>, authorized: Bool,
                  hasBlockingError: Bool) -> GlobalStatus
func statusDescription(for status: GlobalStatus, enabledSourceIDs: Set<UUID>) -> String
```

`hasBlockingError` 由 AppModel 按现有 error/state.message/blockingError/summaryError 计算。所有来源集合先与 enabledSourceIDs 交集，不能让停用来源的过期 snapshot 污染状态。

- [ ] **1. 写两个核心 RED。** 不创建真实 AppModel/runtime：

```swift
func testDeferredRoundIsNotCompleted() {
    let id = UUID()
    var snapshot = EngineSnapshot()
    snapshot.summary = SyncStatusSummary()
    snapshot.latestScan = ScanProgress(state: .interrupted, deferred: true)
    snapshot.deferredSources = [id]
    let view = SyncStatusPresentation(snapshot: snapshot)
    let status = view.globalStatus(enabledSourceIDs: [id], authorized: true, hasBlockingError: false)
    XCTAssertEqual(status, .waiting)
    XCTAssertEqual(view.statusDescription(for: status, enabledSourceIDs: [id]), "稍后继续")
}
func testFileIssueDoesNotHideHealthyWork() {
    let id = UUID()
    var snapshot = EngineSnapshot()
    snapshot.activeWork = true
    snapshot.waitingSources[id] = SourceIssue(summary: "文件无法读取。", detail: "fixture", kind: .file)
    let view = SyncStatusPresentation(snapshot: snapshot)
    XCTAssertEqual(view.globalStatus(enabledSourceIDs: [id], authorized: true, hasBlockingError: false), .running)
}
```

先把当前 AppModel 的状态表达式原样移动到新方法、接入调用且不修改语义，让测试可编译并观测 RED；随后才修改规则。
- [ ] **2. 实现以下完整优先级。**

```text
没有启用来源 -> unconfigured
授权缺失或真正全局错误 -> error
用户暂停 -> paused
启用来源存在 sourceAvailability -> waiting / 等待恢复
activeWork -> running
deferredSources 非空或 latestScan.deferred -> waiting / 稍后继续
importing > 0 -> waiting / 等待核对
pending + retryPending > 0 -> waiting / 等待重试（仅 retryPending）或 等待处理
有未解决 file/submission 问题 -> error / 部分文件需要处理
latestScan.state == completed -> completed
其他尚未完成/尚未启动 -> waiting / 等待扫描
```

文案根据实际 status 与活动 snapshot 决定，暂停中的活动工作仍使用“正在暂停，等待当前操作返回”，但不能遮掉真正全局错误。file/submission 问题仍保留来源行，不冒充目录故障。deferred 无错误通知、无错误计数，idle 文件失败的 error 表示需要处理文件，不阻止引擎处理健康文件。
- [ ] **3. AppModel 单一调用。**

```swift
let ids = Set(state.sources.filter(\.enabled).map(\.id))
let presentation = SyncStatusPresentation(snapshot: state.snapshot)
return presentation.globalStatus(
    enabledSourceIDs: ids,
    authorized: !needsPhotosAuthorization,
    hasBlockingError: error != nil || state.message != nil ||
        state.snapshot.blockingError != nil || state.snapshot.summaryError != nil
)
```

保留 demo/GUIQA 的明确分支；正常 statusDescription 同样调用 presentation；不在 StatusMenu 再写第二套状态优先级。
- [ ] **4. 扩展矩阵并同步契约。** 覆盖已完成、notStarted、interrupted、日志/通知 warning、缺授权、暂停+活动、真实来源离线+其他来源活动、单文件错误+活动/idle、deferred+零文件记录、retryPending、unknown importing、停用来源问题。运行时契约 §5 明确“真实来源不可用优先于运行中”，与原批准设计一致；解释文件问题不会进入来源恢复曲线。
- [ ] **5. GREEN 后提交。**

```bash
beta3_build_tests && beta3_test_case 'PhotoSyncCoreTests/SyncStatusPresentationTests'
beta3_test_case 'PhotoSyncCoreTests/GlobalStatusTests'
git add Sources/PhotoSyncApp/SyncStatusPresentation.swift Sources/PhotoSyncApp/AppModel.swift Tests/PhotoSyncCoreTests/SyncStatusPresentationTests.swift Tests/PhotoSyncCoreTests/GlobalStatusTests.swift docs/specs/2026-09-18-runtime-state-and-recovery.md
git commit -m "fix: derive UI status from classified outstanding work"
```

### Task 5: 恢复启用入口和有界菜单布局

**Files:** Modify `SyncRuntime.swift`、`AppModel.swift`、`SourceSettings.swift`、`StatusMenu.swift`；Test `GlobalStatusTests.swift`；原生 fake GUIQA 证据存 `work/Beta3GUI/`。

**Interfaces:**
- `SyncRuntime.enable(_ id: UUID) async throws`：读取已有来源并确认未 removed，复用 add(source.url) 的校验/ID恢复路径，不创建新身份、不手写裸 enabled UPDATE。
- `AppModel.enable(_ id: UUID)` 与 `@Published private(set) var changingSources: Set<UUID> = []`：同一来源动作进行时禁用启用/停用/移除按钮；开始前检查集合，Task 的 defer 清除。
- StatusMenu 信息区保留原数据与顺序，操作区保留立即扫描、暂停/继续、设置、退出。

- [ ] **1. 写启用行为测试。**

```swift
func testEnableSourceReusesIdentityAndSuccessfulHistory() async throws {
    let f = try await makeEngineFixture(sourceCount: 1)
    let runtime = SyncRuntime(store: f.store, engine: f.engine,
                              now: { Date() }, authorized: { true })
    try await runtime.prepareInjectedRuntime()
    await runtime.tick(force: true)
    await runtime.waitForRound()
    let countBefore = await f.photos.createCount
    try await runtime.disable(f.sourceIDs[0])
    try await runtime.enable(f.sourceIDs[0])
    await runtime.waitForRound()
    let state = await runtime.current()
    let countAfter = await f.photos.createCount
    XCTAssertEqual(state.sources.map(\.id), f.sourceIDs)
    XCTAssertTrue(state.sources[0].enabled)
    XCTAssertEqual(state.snapshot.summary?.imported, 1)
    XCTAssertEqual(countAfter, countBefore)
}
```

- [ ] **2. 实现启用与动作互斥。** runtime.enable 通过 store.source 和 isSourceRemoved 校验，removed 时抛本文件定义的 RuntimeSourceOperationError.sourceRemoved，复用现有 add；离线/重叠/链接失败继续保持停用且显示已有 reportOperationFailure 人话。model 对同一来源的三个动作在方法入口 guard changingSources、插入 ID、Task defer 移除 ID，不能仅靠按钮 disabled；添加目录面板返回已有同路径来源时也检查该 ID 的进行中状态。这样同一来源只能发出一个 UI 命令，不允许慢启用和新的停用/移除重叠；不引入全局任务队列或新存储层。

```swift
Button(source.enabled ? "停用" : "启用") {
    if source.enabled { model.disable(source.id) }
    else { model.enable(source.id) }
}
.disabled(model.demo || !model.ready || model.changingSources.contains(source.id))
```

在 SyncRuntime.swift 内定义准确的操作错误，不把已移除伪装成“不是文件夹”：

```swift
enum RuntimeSourceOperationError: Error, LocalizedError {
    case sourceRemoved
    var errorDescription: String? { "该来源已移除，请重新添加来源目录。" }
}
```

AppModel.enable 捕获此类型时直接使用上述中文摘要；其他错误仍经 reportOperationFailure。移除按钮同样检查 changingSources；启用按钮使用 `.accessibilityIdentifier("enable-source-\(source.id.uuidString)")`，成功刷新来源和统计，失败后按钮重新可用。
- [ ] **3. 用 0/1/16/30 来源和长文案测量菜单。** 在安全 fixture UI 中确认自然内容超过 600pt 的场景；不要引用上轮截图作为本轮结果。先保留证明原布局超界的尺寸记录，再加入有界信息区：

```swift
VStack(alignment: .leading, spacing: 0) {
    ScrollView {
        statusContent
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(height: min(measuredStatusHeight, maximumStatusHeight))
    Divider().padding(.vertical, 8)
    actions
}
.padding(14)
.frame(width: 320)
```

`statusContent`/`actions` 是从本文件原 body 提取的两个 private computed View，不新建组件层。按 SourceSettings 现有 GeometryReader/PreferenceKey 模式测量自然信息高度；新增 `@State private var measuredStatusHeight: CGFloat = 1`，由单个内容高度 preference 更新。`maximumStatusHeight` 是本视图私有 CGFloat computed property，取 `min(440, max(160, visibleScreenHeight - 220))`；`visibleScreenHeight` 取 `NSScreen.screens.map { $0.visibleFrame.height }.min() ?? 660`，避免多屏时误用更大主屏导致小屏溢出。仅测量 ScrollView 内自然内容，避免高度反馈循环。操作区不放进滚动区；少来源时不留下固定 440pt 空白。
- [ ] **4. 行为和视觉验收。** 自动测试：重复启用 ID/历史不变、失败仍停用、已 removed ID 的启用请求被拒绝；进行中的启用禁用该来源停用/移除调用、暂停时启用不触发新提交。GUIQA fake：启用/停用/移除按钮状态、快速重复点击、目录校验失败后的恢复；明暗外观、0/1/16/30 来源、长路径/摘要、键盘能到达固定操作区。Settings 底部诊断可达；菜单信息可滚动但按钮持续可见。原生窗口不能在当前桌面安全操作时标注该项未验收，禁止通过启动生产应用补证。
- [ ] **5. 测试与视觉证据确认后提交。**

```bash
beta3_build_tests && beta3_test_case 'PhotoSyncCoreTests/RuntimeIntegrationTests'
git add Sources/PhotoSyncApp/SyncRuntime.swift Sources/PhotoSyncApp/AppModel.swift Sources/PhotoSyncApp/SourceSettings.swift Sources/PhotoSyncApp/StatusMenu.swift Tests/PhotoSyncCoreTests/GlobalStatusTests.swift
git commit -m "fix: restore source enable controls and bound menu content"
```

### Task 6: 修正严格日历校验与视频小数秒

**Files:** Modify `MetadataReader.swift`；Test `SourceReaderTests.swift`。不更改 DuplicatePolicy、不重判已有 skipped 记录。

**Interfaces:** 保留 `captureSecond(rawCaptureTime:offsetTimeOriginal:) -> Int64?`、`videoCaptureSecond(rawCaptureTime:) -> Int64?`；未知时区/精度不足仍返回 nil，可靠时间仍向下取整到 Unix 秒。

- [ ] **1. 添加 parser RED。**

```swift
func testInvalidCalendarDatesStayUncertain() {
    XCTAssertNil(MetadataReader.captureSecond(rawCaptureTime: "2024:02:30 03:04:05", offsetTimeOriginal: "+00:00"))
    XCTAssertNil(MetadataReader.captureSecond(rawCaptureTime: "2023:02:29 03:04:05", offsetTimeOriginal: "+00:00"))
    XCTAssertNotNil(MetadataReader.captureSecond(rawCaptureTime: "2024:02:29 03:04:05", offsetTimeOriginal: "+00:00"))
    XCTAssertNil(MetadataReader.captureSecond(rawCaptureTime: "2024:01:02 03:04", offsetTimeOriginal: "+00:00"))
}
func testVideoFractionalSecondsPreserveReliableSecond() {
    XCTAssertEqual(MetadataReader.videoCaptureSecond(rawCaptureTime: "1970-01-01T00:00:00.123Z"), 0)
    XCTAssertEqual(MetadataReader.videoCaptureSecond(rawCaptureTime: "1970-01-01T08:00:00.999+08:00"), 0)
    XCTAssertEqual(MetadataReader.videoCaptureSecond(rawCaptureTime: "1969-12-31T23:59:59.900Z"), -1)
    XCTAssertNil(MetadataReader.videoCaptureSecond(rawCaptureTime: "1970-01-01T00:00:00.123"))
}
```

- [ ] **2. 运行上述用例确认 RED。** `beta3_build_tests && beta3_test_case 'PhotoSyncCoreTests/SourceReaderTests'`；不得只凭 Foundation 文档猜测 parser 行为。
- [ ] **3. 严格 EXIF 基础日期校验。** 对输入用 `^[0-9]{4}:[0-9]{2}:[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?$` 完整匹配；前 19 位用 Gregorian/en_US_POSIX、已有显式 offset、`yyyy:MM:dd HH:mm:ss`、`isLenient=false` 解析，再以相同 formatter 回写并与前 19 位完全比较。不相等返回 nil，不能让 Foundation 把 2 月 30 日改成 3 月 1 日。小数部分单独转 Double 加到基础日期，最后仍 rounded(.down)。
- [ ] **4. 视频支持两种明确格式。**

```swift
let fractional = ISO8601DateFormatter()
fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
let integral = ISO8601DateFormatter()
integral.formatOptions = [.withInternetDateTime]
let date = fractional.date(from: rawCaptureTime) ?? integral.date(from: rawCaptureTime)
```

调用前仍要求 videoOffset 非空和输入包含完整秒；对完整基础年月日时分秒做与 EXIF 等价的日历有效性检查，不能仅用格式器非 nil 判断可靠性。保留 rawCaptureTime/rawCaptureOffset，不读取原片缓存、不引入第三方 parser。
- [ ] **5. 补边界并保留资源级测试。** 验证月底、闰日、24 点、秒=60、垃圾后缀、非法 offset、无 offset、1/3/6/9 位小数、1970 前向下取整。运行既有自制 JPEG/ImageIO 元数据读取用例；有自制 AVFoundation fixture 时验证提取带 offset 的小数秒，若只能验证 parser，在发布说明明确区分，不拿 parser 测试冒充真实视频提取。
- [ ] **6. GREEN 后提交。**

```bash
beta3_build_tests && beta3_test_case 'PhotoSyncCoreTests/SourceReaderTests'
beta3_test_case 'PhotoSyncCoreTests/DuplicatePolicyTests'
git add Sources/PhotoSyncCore/Sources/MetadataReader.swift Tests/PhotoSyncCoreTests/SourceReaderTests.swift
git commit -m "fix: validate capture dates and accept fractional video timestamps"
```

### Task 7: 集成评审、版本冻结与 beta3 独立打包

**Files:** Modify `Sources/PhotoSyncApp/Info.plist`、`PhotoSync.xcodeproj/project.pbxproj`、`scripts/package-release.sh`、`README.md`、`AGENTS.md`、`Design/Validation.md`；Create `docs/release/0.1.0-beta3.md`。产物和测试日志只放被忽略的 work/outputs。

**Interfaces:** 发布常量为 `MARKETING_VERSION=0.1.0`、`CURRENT_PROJECT_VERSION=3`、`PhotoSyncReleaseChannel=beta3`；打包目录 `outputs/releases/0.1.0-beta3/`，DMG 名 `PhotosYNC-0.1.0-beta3.dmg`。沿用 scripts/package-release.sh 从 git archive 构建、逐层签名、provenance 与 SHA256SUMS 的现有接口。

- [ ] **1. 执行一次集成深度评审。** 使用 reviewer 审查执行分支相对执行起点的完整 diff，附任务 1–6 的行为证据；范围重点：SQL 原子性、暂停/停用的 await 许可、单实际提交、三类 deadline 互不覆盖、来源故障恢复、候选历史、状态/文案一致性。此轮覆盖任务级快速评审要求，不对同一快照再跑 quick_reviewer。发现只修复本计划范围；修后重跑受影响测试，不擅自扩成重构。
- [ ] **2. 更新发布常量与脚本。** 修改以下确切字段，不全局替换历史 beta2 记录：

```text
Sources/PhotoSyncApp/Info.plist:
  PhotoSyncReleaseChannel = beta3
PhotoSync.xcodeproj/project.pbxproj:
  Debug / Release / GUIQA 的 CURRENT_PROJECT_VERSION = 3
  三者 MARKETING_VERSION 保持 0.1.0
scripts/package-release.sh:
  release_name=0.1.0-beta3
  CFBundleVersion 断言从 2 改为 3
  增加 PhotoSyncReleaseChannel == beta3 断言
  cp docs/release/0.1.0-beta3.md "$release_dir/RELEASE-NOTES.md"
  provenance build_number=3
```

新增 channel 检查实际命令：

```bash
[[ "$(/usr/libexec/PlistBuddy -c 'Print :PhotoSyncReleaseChannel' "$app_path/Contents/Info.plist")" == 'beta3' ]]
```

保留脚本已有 release_dir 存在即失败、只打包已提交 git archive、Universal 架构/Assets.car/ICNS 验证、ad-hoc 签名、DMG 验证；不引入覆盖参数或自动安装动作。
- [ ] **3. 写发布说明并核对修改映射。** beta3.md 明确 5 项主要修复、日志/启用/布局/时间解析调整、版本/最低系统/架构、不做既有 skipped 重判、不修复过去可能丢失的成功历史、真实 Photos/旧系统/公证的实际验证边界。README 当前版本指向 beta3；AGENTS 当前基线记录修复 commit 和实际测试数，保留旧历史；Design/Validation 追加本轮证据，不把未执行项改成 Pass。

发布说明的固定边界文字：

```text
PhotosYNC 0.1.0 beta3 (build 3), macOS 13+, Universal arm64/x86_64.
本包为本地 ad-hoc 签名版本，未作 Developer ID 签名或公证。
保留 schema v3、源只读和 Photos 只增不删；不修改现有成功历史，不自动重判历史跳过记录。
```

- [ ] **4. tester 验证集成后的实际快照。** 构建和全套测试必须成功后再打包；日志保留最终总数，不能写死为 170：

```bash
xcodebuild -version
xcrun swift --version
beta3_build_tests && xcrun xctest \
  work/Beta3Validation/Build/Products/Debug/PhotoSyncCoreTests.xctest \
  > work/beta3-tests.log 2>&1
zsh -n scripts/package-release.sh
```

结果包含任务 1–6 新回归、既有 unknown/checkpoint/历史/ARW/XMP/通知/日志故障测试。纯版本/文档更新后无需重复此前同一行为快照的全部场景；此处全套作为最终发布证据，之后只有代码再变才重跑。当前 Xcode XCTest 链接 macOS 14 的警告应记录为测试宿主限制，不擅自抬高产品最低系统。
- [ ] **5. 用 GUIQA fake 或 demo 做版本与界面验收。** fake 构建命令：

```bash
xcodebuild -project PhotoSync.xcodeproj -scheme PhotoSync -configuration GUIQA \
  -destination 'platform=macOS' -derivedDataPath work/Beta3GUI \
  CODE_SIGNING_ALLOWED=NO build > work/beta3-gui-build.log 2>&1
```

为 GUIQA 生成本轮独立根路径：

```bash
beta3_qa_root="$PWD/work/Beta3GUI-$(uuidgen)"
```

GUIQA 只允许参数 `--qa-mode fake --qa-root "$beta3_qa_root"`；启动前检查 GUIQA bundle ID 与 production 不同。不要对 GUIQA 使用 `--demo` 代替明确的 fake 参数。原生操作必须满足前述前台限制；若未能原生验收，则 release notes 逐项注明，仍可交付已通过自动验证的本地 beta 包，不声称完整 GUI/真实 Photos 验收完成。
- [ ] **6. 提交全部修复和发布配置，保证可追溯源码。**

```bash
git add Sources/PhotoSyncApp/Info.plist PhotoSync.xcodeproj/project.pbxproj scripts/package-release.sh README.md AGENTS.md Design/Validation.md docs/release/0.1.0-beta3.md
git commit -m "release: prepare PhotosYNC 0.1.0 beta3"
git status --short
git rev-parse HEAD
```

只能从已包含本计划全部通过修复的干净提交打包。没有用户新授权，不合并 main、不推送、不打远端 tag、不重启用户应用。
- [ ] **7. 构建独立 beta3 产物。** 确认没有现存 beta3 release 目录后执行：

```bash
scripts/package-release.sh > work/beta3-package.log 2>&1
```

成功后应具备：

```text
outputs/releases/0.1.0-beta3/PhotosYNC.app
outputs/releases/0.1.0-beta3/PhotosYNC-0.1.0-beta3.dmg
outputs/releases/0.1.0-beta3/PhotosYNC.provenance
outputs/releases/0.1.0-beta3/SHA256SUMS
outputs/releases/0.1.0-beta3/RELEASE-NOTES.md
```

失败保留 work/release-* 构建证据；不得用 beta2 旧包或把旧包改名充当 beta3。release_dir 已存在时先读取 provenance 判断内容，不能删除覆盖重试。
- [ ] **8. 独立核验最终产物。**

```bash
beta3_dir="$PWD/outputs/releases/0.1.0-beta3"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$beta3_dir/PhotosYNC.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$beta3_dir/PhotosYNC.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :PhotoSyncReleaseChannel' "$beta3_dir/PhotosYNC.app/Contents/Info.plist"
lipo "$beta3_dir/PhotosYNC.app/Contents/MacOS/PhotosYNC" -verify_arch arm64 x86_64
lipo "$beta3_dir/PhotosYNC.app/Contents/Frameworks/PhotoSyncCore.framework/Versions/A/PhotoSyncCore" -verify_arch arm64 x86_64
codesign --verify --deep --strict --all-architectures "$beta3_dir/PhotosYNC.app"
hdiutil verify "$beta3_dir/PhotosYNC-0.1.0-beta3.dmg"
(cd "$beta3_dir" && shasum -a 256 -c SHA256SUMS)
cat "$beta3_dir/PhotosYNC.provenance"
git rev-parse HEAD
```

预期 version=0.1.0/build=3/channel=beta3；两份二进制都含 arm64+x86_64；签名、DMG、checksum 检查退出 0；provenance source_commit 与打包提交完全一致。签名验证成功不等于公证/Gatekeeper 放行。
- [ ] **9. 交付自包含结果。** 给出 app/DMG/provenance 链接、确切源码 commit、构建工具链、实际测试总数、所有已修问题到任务的映射。单独列出构建、自动测试、GUI、真实 Photos、macOS 13/14、签名分发结果；未执行写清楚。代码与包完成后停止，不安装到 Applications，不清理生产数据。

## 依赖与协作

执行顺序为 1 → 2 → 3 → 4 → 5 → 6 → 7。任务 6 可独立于前面读取研究，但同一工作树的构建与 project 修改保持串行。主代理负责集成；同一时刻只有一个实现者修改 SyncEngine/SyncRuntime/AppModel。使用子代理执行时给每项明确文件所有权，并告知它不是唯一协作者，不得回滚其他人的改动。

每项包含自己的 RED/GREEN 和提交；最终一次 reviewer + tester 覆盖集成风险。若已做等价深度任务评审且最终没有集成变化，不为遵循技能模板重复评审相同快照。技能的推荐流程按 AGENTS 的风险缩放规则执行。

## 计划自检与完成标准

- [ ] 审查报告的 5 项主要问题与 5 类补充事项均有对应任务；不顺手修复报告外的问题。
- [ ] importing 身份和成功历史有数据库级断言；不得只靠 UI 截图判断数据安全。
- [ ] 重试从真实 runtime.tick 触发；未知结果永不被“到期”查询选中。
- [ ] 目录、文件、deferred 三种恢复场景分别验证；本次事件数与持久统计不混用。
- [ ] UI 显示不会出现“已完成/稍后继续”矛盾、文件错误不冒充目录离线。
- [ ] 菜单 action 区在测试尺寸下可达，停用来源能复用身份启用；原生 GUI 未验证时明确说明。
- [ ] 日期可靠性没有变宽到猜测时区/容差匹配，既有判重规则不变。
- [ ] 高严重性评审项全部解决，中严重性项解决或明确获准保留；范围外风险只报告。
- [ ] 最终源码已提交，beta3 包来自该提交，旧包未被覆盖，生产运行数据未被触及。

计划文档完成并不表示修复、测试或 beta3 构建已执行；执行后才按实际证据勾选上述项目。
