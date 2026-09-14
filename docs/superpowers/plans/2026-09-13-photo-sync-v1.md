# macOS Photo Sync v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现可恢复的 macOS 多目录到 Photos 单向追加同步程序，使用原生菜单栏界面，保留保守跳过记录。

**Architecture:** 单应用进程；同步协调、纯判重规则、目录读取、Photos 接入、SQLite 存储及原生界面分离。系统调用用具体适配器，测试通过小型协议替换；不建设插件框架、独立后台服务或媒体缓存。

**Tech Stack:** Swift、SwiftUI/AppKit、PhotoKit、Image I/O、AVFoundation、系统 SQLite3、ServiceManagement、XCTest；最低 macOS 13。不引入第三方运行时依赖。

**Spec:** `outputs/2026-09-13-photo-sync-v1-design.md`（用户于 2026-09-13 批准并要求编写计划；执行者必须先读全文）。

## Global Constraints

- 源目录严格只读；Photos 只新增，不覆盖、不删除已有资产。
- 支持多个目录，统一目录读取逻辑，不区分本地盘或网络盘。
- 不建立应用原片缓存、不计算内容哈希；允许读取媒体元数据。
- 位图及视频，排除 RAW，不转码、不配对 Live Photo，不映射目录为相簿。
- 文件名精确相等才比较重复；时间精确到秒，不设容差；时区不确定不据此排除重复。
- 同名且拍摄时间或完整设备信息明确冲突则不同；其他情况疑似重复，跳过留记录。
- 四状态仅为 pending / importing / imported / skipped；通过字段表达原因、尝试和重试。
- 已成功导入的历史长期保留，目标后来消失不重导；源属性变化先跳过。
- 不确定导入先核对；有明确未提交/未成功证据才能重试，单次 fetch 不命中不算证据。
- 启动扫描，之后默认每 30 分钟；不重叠、不积压；登录自启动默认关闭且有开关。
- 原生控件；菜单栏图标表达全局状态；等待恢复不能被其他来源的运行掩盖。
- 无内置日志阅读界面，仅提供 Finder 打开日志目录入口。
- 未来 DMG 分发，不上 App Store；本版非 App Sandbox，但仍遵守系统 Photos 权限。
- 本计划只安排实现与验收，不授权向用户现有 Photos 图库导入测试照片。写入测试须使用用户明确确认的测试环境；不得替用户切换系统图库或改变 iCloud 配置。

---

## 执行前状态与方式

当前目录只有设计文档，没有应用或 Git 仓库。2026-09-13 已只读确认本机 Xcode 26.6、Swift 6.3.3；这不是构建或运行验收。执行时复核工具链，不以当前 SDK 的新 API 代替 macOS 13 可用 API。

在开始实现时建立代码仓库并提交设计和计划；如果用户指定已有项目，先读该项目及父目录的 CLAUDE.md/AGENTS.md 并采用其结构，不覆盖用户改动。仓库初始化属于执行阶段，本次没有建立仓库或应用工程。

工程采用一个 Xcode 项目：`PhotoSync` 应用目标、`PhotoSyncCore` framework 目标、无宿主的 `PhotoSyncCoreTests` 逻辑测试目标。应用仅组合适配器与界面。Core 不导入 SwiftUI/AppKit；系统适配器可以使用 Photos/ImageIO/AVFoundation。Core 作为嵌入 framework 不引入第二进程。XCTest 直接测试 Core，不启动菜单栏程序，也不请求真实 Photos 权限。

任务按 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 执行。每个任务按失败测试、最小实现、通过测试、提交的顺序推进；不以所有测试必须一次写完作为门槛。主要外部接口风险放在任务 4，未通过之前不启用真实自动导入。

## 文件布局和责任

```text
PhotoSync.xcodeproj/                    # 三个目标及共享 PhotoSync scheme，部署目标 13.0
Sources/PhotoSyncApp/
  PhotoSyncApp.swift                    # 唯一应用入口、MenuBarExtra、Settings
  AppModel.swift                        # MainActor 界面状态和指令桥接
  StatusMenu.swift                      # 原生菜单内容及辅助功能文字
  SourceSettings.swift                  # 来源列表、NSOpenPanel、自启动开关
  LoginItemController.swift             # SMAppService.mainApp 真实状态
  NotificationController.swift         # 去重后的系统通知
  Info.plist                           # LSUIElement、Photos 用途、版本
Sources/PhotoSyncCore/
  Domain/MediaRecord.swift              # 文件/元数据/四状态/候选/决策
  Matching/DuplicatePolicy.swift        # 无 I/O 的精确规则
  Storage/SyncStore.swift               # SQLite 连接、迁移、事务和有界查询
  Storage/Schema.sql                    # 第一版表、约束、索引
  Sources/SourceRegistry.swift          # 来源启停、路径重叠判断
  Sources/DirectoryReader.swift         # 不跟随链接的逐目录读取
  Sources/MetadataReader.swift          # ImageIO/AVFoundation 元数据
  Sources/ReadExecutor.swift            # 有界阻塞工作、截止时间、晚到回调
  Photos/PhotosGateway.swift            # 协议、查询/导入/核对的数据类型
  Photos/PhotoKitGateway.swift          # 系统照片图库，新增操作唯一出口
  Sync/SyncEngine.swift                 # 扫描到提交的协调流程
  Sync/ImportRecovery.swift             # 中断核对的纯转移决策
  Sync/ScanSchedule.swift               # 30 分钟、暂停、来源重试调度
  Presentation/GlobalStatus.swift       # 纯状态优先级与文案数据
  Logging/RunLogger.swift               # 轮转日志，打开路径由 App 负责
Tests/PhotoSyncCoreTests/
  DuplicatePolicyTests.swift
  StoreTests.swift
  SourceReaderTests.swift
  PhotoKitContractTests.swift
  RecoveryTests.swift
  EngineTests.swift
  ScheduleTests.swift
  GlobalStatusTests.swift
  TestSupport.swift                     # 合成元数据和 fake 适配器
  Fixtures/                            # 自制微型图片/视频，不使用个人照片
scripts/build-dmg.sh                    # 已构建 .app 的分发打包
README.md                              # 构建、安装、权限、日志和限制
Design/Validation.md                    # 真实 API 验收步骤及结果，不放个人照片
```

所有路径相对于执行项目根目录。任务仅创建所列文件；若需要独立服务、源媒体缓存或修改判重语义，停止该方向并说明影响，不能修改设计自授权。

## 通用验证命令

以下 scheme 和目标名称在任务 1 创建并共享。签名关闭只用于本地构建和逻辑测试，不能据此声称真实 Photos 权限或分发验收完成。

```bash
xcodebuild -project PhotoSync.xcodeproj -scheme PhotoSync \
  -destination 'platform=macOS' -derivedDataPath work/DerivedData \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project PhotoSync.xcodeproj -scheme PhotoSync \
  -destination 'platform=macOS' -derivedDataPath work/DerivedData \
  CODE_SIGNING_ALLOWED=NO -only-testing:PhotoSyncCoreTests test
```

每个任务将 `-only-testing` 收窄到对应测试类。失败必须来自断言或尚未实现的被测接口，而不是错误的 scheme、签名或依赖缺失；环境失败先修复，不能记作有效红灯。

## Task 1：可测试的领域模型与保守判重

**Files:** 创建 Xcode 项目、`Domain/MediaRecord.swift`、`Matching/DuplicatePolicy.swift`、`Tests/.../DuplicatePolicyTests.swift`、`TestSupport.swift`。应用入口先为空壳，不能自动访问 Photos；工程配置和空壳归入此任务。

**Interfaces:** 后续所有任务使用下列值类型，不另起同义类型。时间存储 Unix 秒仅在来源能可靠确定绝对时间时填写；缺少时区则为 nil，同时保存原始文本。

```swift
import Foundation

enum FileState: String, Codable { case pending, importing, imported, skipped }
enum SkipReason: String, Codable {
    case suspectedDuplicate, sourceChanged, unsupportedFormat
}
enum MediaKind: String, Codable { case image, video }
struct FileStamp: Codable, Equatable {
    let size: Int64
    let modifiedNanoseconds: Int64
}
struct MediaMetadata: Codable, Equatable {
    let filename: String
    let kind: MediaKind
    let captureSecond: Int64?
    let rawCaptureTime: String?
    let make: String?
    let model: String?
    let width: Int?
    let height: Int?
    let duration: Double?
}
struct SourceFile: Codable, Equatable {
    let sourceID: UUID
    let relativePath: String
    let url: URL
    let stamp: FileStamp
    let metadata: MediaMetadata
}
struct MatchCandidate: Codable, Equatable {
    let key: String             // photos:<id> 或 file:<recordUUID>
    let metadata: MediaMetadata
}
enum MatchDecision: Equatable {
    case importNew
    case skip(candidateKeys: [String])
}
struct DuplicatePolicy {
    static let version = 1
    func evaluate(_ source: MediaMetadata,
                  candidates: [MatchCandidate]) -> MatchDecision
}
```

- [ ] 建立三目标、共享 scheme、无宿主 XCTest，Core 链接系统 SQLite3，部署目标统一 13.0。添加域类型和下面的失败测试。

```swift
import XCTest
@testable import PhotoSyncCore

func media(_ name: String = "IMG_0001.JPG", second: Int64? = nil,
           make: String? = nil, model: String? = nil) -> MediaMetadata {
    MediaMetadata(filename: name, kind: .image, captureSecond: second,
        rawCaptureTime: nil, make: make, model: model,
        width: 100, height: 100, duration: nil)
}

final class DuplicatePolicyTests: XCTestCase {
    func testDifferentFilenameAlwaysImports() {
        let candidate = MatchCandidate(key: "photos:1", metadata: media("B.JPG"))
        XCTAssertEqual(DuplicatePolicy().evaluate(media("A.JPG"),
            candidates: [candidate]), .importNew)
    }
    func testOneSecondDifferenceExcludesCandidate() {
        let candidate = MatchCandidate(key: "photos:1", metadata: media(second: 101))
        XCTAssertEqual(DuplicatePolicy().evaluate(media(second: 100),
            candidates: [candidate]), .importNew)
    }
    func testMissingTimeIsConservative() {
        let candidate = MatchCandidate(key: "photos:1", metadata: media())
        XCTAssertEqual(DuplicatePolicy().evaluate(media(second: 100),
            candidates: [candidate]), .skip(candidateKeys: ["photos:1"]))
    }
}
```

- [ ] 运行 `DuplicatePolicyTests`，记录尚未实现规则导致的失败。
- [ ] 实现同名候选过滤、已知秒级时间冲突、完整设备二元组冲突；其余候选全部保留。设备仅去首尾空白、合并连续空白和大小写归一；任一 make/model 缺失则不能凭设备排除。不得使用尺寸、时长或大小排除候选。

```swift
let sameName = candidates.filter { $0.metadata.filename == source.filename }
let unresolved = sameName.filter { candidate in
    let other = candidate.metadata
    if let left = source.captureSecond, let right = other.captureSecond,
       left != right { return false }
    return !deviceConflict(source, other)
}
return unresolved.isEmpty ? .importNew
    : .skip(candidateKeys: unresolved.map(\.key).sorted())
```

`deviceConflict` 放在同一判重文件内：

```swift
private func normalizedDevicePart(_ value: String?) -> String? {
    guard let value else { return nil }
    let result = value.split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ").lowercased()
    return result.isEmpty ? nil : result
}
private func deviceConflict(_ left: MediaMetadata, _ right: MediaMetadata) -> Bool {
    guard let lm = normalizedDevicePart(left.make),
          let ld = normalizedDevicePart(left.model),
          let rm = normalizedDevicePart(right.make),
          let rd = normalizedDevicePart(right.model) else { return false }
    return lm != rm || ld != rd
}
```

- [ ] 加入设备冲突/规范化/单方缺失、相同秒不同小数、时区未知、文件名大小写不同、多候选中一条未排除的断言。验证精度转换时向下取整到 Unix 秒，不四舍五入。
- [ ] 运行本类及完整 Core 测试；通过后提交 `feat: define media records and conservative matching`。

## Task 2：SQLite 持久化、来源登记与日志

**Files:** `Storage/SyncStore.swift`、`Storage/Schema.sql`、`Sources/SourceRegistry.swift`、`Logging/RunLogger.swift`、`StoreTests.swift`。

**Consumes:** 任务 1 的值类型。

**Produces:** `SyncStore` 为线程安全 final class，唯一私有 DispatchQueue 串行管理 SQLite 连接；所有常规方法为 async throws，经队列调度。只有 PhotoKit placeholder 检查点使用同步队列方法，避免在系统同步 change block 中 await。打开失败不退回空数据库。接口 `init(url: URL) throws`、`registerSource(url: URL) throws -> UUID`、`disableSource(id: UUID) throws`、`save(_ file: SourceFile, decision: MatchDecision) throws -> UUID`、`state(of id: UUID) throws -> FileState`、`beginAttempt(fileID: UUID, attemptID: UUID) throws`、`checkpointPlaceholder(fileID: UUID, attemptID: UUID, identifier: String) throws`（唯一同步写入口）、`markImported(fileID: UUID, attemptID: UUID, identifier: String) throws`、`recordSourceChange(fileID: UUID, stamp: FileStamp) throws`、`successIdentifier(of id: UUID) throws -> String?`。后续任务依赖以下查询，同步行为均通过队列完成，不建立通用 CRUD 框架：

```swift
struct StoredFile {
    let id: UUID
    let file: SourceFile
    let state: FileState
    let attemptID: UUID?
    let placeholderID: String?
    let successID: String?
    let nextRetryAt: Date?
}
struct RegisteredSource {
    let id: UUID
    let url: URL
    let enabled: Bool
}
// SyncStore 方法；均为 async throws，checkpointPlaceholder 除外。
// source(id: UUID) -> RegisteredSource
// file(sourceID: UUID, relativePath: String) -> StoredFile?
// listFiles(state: FileState, afterID: UUID?, limit: Int) -> [StoredFile]
// candidates(filename: String, excludingID: UUID?) -> [MatchCandidate]
// markSkipped(fileID: UUID, reason: SkipReason, candidates: [MatchCandidate])
// recordRetry(fileID: UUID, attemptID: UUID?, nextRetry: Date, error: String,
//             definitelyNotCommitted: Bool)
// beginScan(sourceID: UUID, now: Date) -> UUID
// finishScan(runID: UUID, now: Date, complete: Bool, checked: Int,
//            failed: Int, error: String?)
```

`candidates` 提供 pending、importing 与成功快照；skipped 仅在存在 success_id 时提供成功快照，不用变化后的 metadata 替代旧成功元数据。稳定排序使用记录创建序号；队列候选保存关系可追溯到对应 file ID。

- [ ] 写重开数据库仍保留成功历史的测试；`TestSupport.swift` 的 `temporaryDirectory()` 用 UUID 在系统临时目录创建测试目录，测试结束只清理自己创建的目录。

```swift
final class StoreTests: XCTestCase {
    func testSourceChangeKeepsImportedHistory() async throws {
        let root = try temporaryDirectory()
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let sourceID = try await store.registerSource(url: root)
        let file = SourceFile(sourceID: sourceID, relativePath: "a.jpg",
            url: root.appendingPathComponent("a.jpg"),
            stamp: FileStamp(size: 12, modifiedNanoseconds: 10), metadata: media("a.jpg"))
        let id = try await store.save(file, decision: .importNew)
        let attempt = UUID()
        try await store.beginAttempt(fileID: id, attemptID: attempt)
        try await store.markImported(fileID: id, attemptID: attempt, identifier: "asset-1")
        try await store.recordSourceChange(fileID: id,
            stamp: FileStamp(size: 15, modifiedNanoseconds: 20))
        let state = try await store.state(of: id)
        let history = try await store.successIdentifier(of: id)
        XCTAssertEqual(state, .skipped)
        XCTAssertEqual(history, "asset-1")
    }
}
```

- [ ] 运行 `StoreTests` 验证失败；实现版本 1 迁移、绑定参数和事务。所有迁移失败回滚，不删除旧库。

```sql
CREATE TABLE source (
 id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, enabled INTEGER NOT NULL,
 last_scan_at REAL, last_error TEXT
);
CREATE TABLE file_record (
 id TEXT PRIMARY KEY, created_order INTEGER NOT NULL UNIQUE,
 source_id TEXT NOT NULL REFERENCES source(id),
 relative_path TEXT NOT NULL, filename TEXT NOT NULL,
 size INTEGER NOT NULL, modified_ns INTEGER NOT NULL, metadata_json TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('pending','importing','imported','skipped')),
 skip_reason TEXT, rule_version INTEGER NOT NULL,
 attempt_id TEXT, placeholder_id TEXT, submitted_at REAL,
 definitely_not_committed INTEGER NOT NULL DEFAULT 0,
 success_id TEXT, success_metadata_json TEXT, succeeded_at REAL,
 retry_count INTEGER NOT NULL DEFAULT 0, next_retry_at REAL, last_error TEXT,
 UNIQUE(source_id, relative_path)
);
CREATE TABLE match_evidence (
 file_id TEXT NOT NULL REFERENCES file_record(id), candidate_key TEXT NOT NULL,
 candidate_json TEXT NOT NULL, rule_version INTEGER NOT NULL, compared_at REAL NOT NULL,
 PRIMARY KEY(file_id, candidate_key)
);
CREATE TABLE scan_run (
 id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES source(id),
 started_at REAL NOT NULL, ended_at REAL, complete INTEGER NOT NULL DEFAULT 0,
 checked INTEGER NOT NULL DEFAULT 0, failed INTEGER NOT NULL DEFAULT 0,
 last_error TEXT
);
CREATE INDEX file_state_retry ON file_record(state, next_retry_at);
CREATE INDEX file_name ON file_record(filename);
```

- [ ] 状态和 evidence 同事务写入；成功快照只在确认成功时写入，来源变化不得清空。`beginAttempt` 通过条件更新仅接受 pending，旧 attempt 的迟到回调不能覆盖新记录；无法落库时抛错并停止写入链。
- [ ] 来源路径按 URL 标准化、组件级父子判断，不能使用简单字符串前缀判断（`/a` 不包含 `/abc`）；检查路径本身的别名/链接只用于配置验证，运行时不递归跟随链接。重新添加已停用的相同路径启用原 ID；父子冲突包括仍在运行的停用请求。
- [ ] 实现轮转 JSONL 日志，10 个文件、每个最多 10 MB（允许单条记录带来的极小越界）；保存 metadata/evidence 的数据库不参与轮转。写日志失败显示一次错误摘要，不递归记录自身失败。
- [ ] 加入重开库、约束冲突、事务失败、不支持未来 schema、移除再添加、父子路径、只查询 importing/pending 分页等验证。测试只写临时测试库。
- [ ] 通过后提交 `feat: persist sync state and source history`。

## Task 3：统一目录读取、元数据和有界慢读

**Files:** `DirectoryReader.swift`、`MetadataReader.swift`、`ReadExecutor.swift`、`SourceReaderTests.swift`、自制 Fixtures。

**Interfaces:**

```swift
struct DirectoryEntry {
    let url: URL
    let isDirectory: Bool
    let stamp: FileStamp?
}
protocol DirectoryReading: Sendable {
    func entries(in directory: URL) async throws -> [DirectoryEntry]
    func stamp(of file: URL) async throws -> FileStamp
}
protocol MetadataReading: Sendable {
    func read(url: URL, filename: String) async throws -> MediaMetadata
}
```

按单目录分批读取，SyncEngine 管理目录队列；不要一次把全部原片读进内存。测试 fake 实现这两个协议；`FailingReader` 在指定 URL 抛错，`BlockingReader` 用可释放锁存器控制返回时间，不用长时间 sleep。

- [ ] 写测试用目录：正常图片、缺 EXIF 图片、损坏图片、子目录、符号链接、隐藏目录、RAW、目录包。生成源 fixture 时可写入，运行被测读取器之后不再改源。

```swift
final class SourceReaderTests: XCTestCase {
    func testMissingExifIsNotReadFailure() async throws {
        let url = try fixtureURL(named: "no-exif.png")
        let value = try await MetadataReader().read(url: url, filename: "no-exif.png")
        XCTAssertNil(value.captureSecond)
        XCTAssertNil(value.make)
        XCTAssertNotNil(value.width)
    }
    func testCorruptImageThrows() async throws {
        let url = try fixtureURL(named: "corrupt.jpg")
        do {
            _ = try await MetadataReader().read(url: url, filename: "corrupt.jpg")
            XCTFail("损坏文件不能当作正常缺失元数据")
        } catch { /* expected read/parse failure */ }
    }
}
```

`fixtureURL(named:)` 在 TestSupport 中从测试 Bundle 解析固定 fixture，找不到则抛测试错误；不能悄悄跳过。

- [ ] 运行本类红灯；实现只读枚举，排除隐藏项、链接和目录包。源 ID 与相对路径由协调层附加，读取层不访问数据库或 Photos。
- [ ] ImageIO 使用 `CGImageSourceCreateWithURL` 与 `CGImageSourceCopyPropertiesAtIndex`，关闭图像缓存，不创建缩略图；分别记录 EXIF 原时间、OffsetTimeOriginal、TIFF Make/Model。未知 offset 的 `captureSecond=nil`。不借文件 mtime 补拍摄时间。

```swift
let options = [kCGImageSourceShouldCache: false] as CFDictionary
guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options)
else { throw MetadataError.unreadable }
```

在该文件定义 `enum MetadataError: Error { case unreadable, unsupported }`。视频使用 `AVURLAsset` 异步 load 元数据和时长，不解码整个视频；只有包含明确 offset 的日期才生成绝对秒。无法取得设备字段留 nil。

- [ ] `ReadExecutor` 用专用固定 2 个工作线程执行同步目录/ImageIO 操作；每来源至多 1 个未结束调用，Photos 请求独立。逻辑超时默认 60 秒，槽位必须等底层调用实际结束才释放；最多 1 个待派发操作/来源，不无限缓冲。
- [ ] 以 callback + continuation 管理一次性完成；计时器和底层回调只能有一方恢复 continuation，晚到结果不得第二次恢复。记录实际占用和批次 ID；超时不派发同来源新操作。优先给尚未运行的来源槽位。
- [ ] 用锁存器测试：一个阻塞另一个能返回；两个都阻塞时提示资源受限、线程数不增长；释放后可重试；取消、超时与返回竞态不双重完成。文件内容及 mtime 在被测读取前后相同；不要求系统 atime 不变。
- [ ] 全部通过后提交 `feat: read directory metadata with bounded IO`。

## Task 4：PhotoKit 适配与导入核对契约

**Files:** `PhotosGateway.swift`、`PhotoKitGateway.swift`、`ImportRecovery.swift`、`PhotoKitContractTests.swift`、`RecoveryTests.swift`、`Design/Validation.md`。

**Interfaces:**

```swift
enum ImportEvidence: Equatable {
    case found(identifier: String)
    case definitelyNotCommitted
    case unknown
}
enum RecoveryAction: Equatable { case markImported, retry, keepImporting }
func recoveryAction(_ evidence: ImportEvidence) -> RecoveryAction {
    switch evidence {
    case .found: return .markImported
    case .definitelyNotCommitted: return .retry
    case .unknown: return .keepImporting
    }
}
protocol PhotosGateway: Sendable {
    func loadCandidates() async throws -> [MatchCandidate]
    func create(fileURL: URL, kind: MediaKind,
        onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String
    func reconcile(placeholder: String?) async throws -> ImportEvidence
}
```

`loadCandidates` 成功才可用，失败不能返回空数组。`create` 仅返回已确认成功的目标 ID。定义明确错误类型区分未提交/确定失败、结果未知、权限或图库不可用；协调层不能对所有 throw 一律重试。

- [ ] 先写核心恢复测试，无真实 PhotoKit 写入。

```swift
final class RecoveryTests: XCTestCase {
    func testAbsenceWithoutProofDoesNotRetry() {
        XCTAssertEqual(recoveryAction(.unknown), .keepImporting)
    }
    func testDefiniteFailureCanRetry() {
        XCTAssertEqual(recoveryAction(.definitelyNotCommitted), .retry)
    }
    func testFoundCompletes() {
        XCTAssertEqual(recoveryAction(.found(identifier: "asset-1")), .markImported)
    }
}
```

- [ ] 运行失败测试，再实现转换；通过后实现系统适配。申请 `.readWrite`，只有充分查询授权和可用图库才建立索引；索引枚举应包含可查询的隐藏资产、burst 资产，按原始资源名列候选，不能只看默认可见缩略图列表。不可完整查询时停止新增并说明覆盖边界。
- [ ] 使用 `PHAssetResource.originalFilename`（macOS 13 可用）；已有资产设备字段缺失按 nil，不使用私有 KVC 或读取 Photos.sqlite，不下载所有 iCloud 原片。`PHAsset.creationDate` 的来源/时区语义无法可靠确认时不要当作 EXIF offset 证据。
- [ ] 新增唯一入口如下，强制复制语义；禁止删除、编辑资产及修改相簿请求。

```swift
let options = PHAssetResourceCreationOptions()
options.shouldMoveFile = false
let request = PHAssetCreationRequest.forAsset()
request.addResource(with: kind == .image ? .photo : .video,
                    fileURL: fileURL, options: options)
let identifier = request.placeholderForCreatedAsset?.localIdentifier
```

以上放进 `PHPhotoLibrary.shared().performChanges` change block；placeholder 由 `onPlaceholder` 在返回 change block 前持久化。调用任务 2 的 checkpointPlaceholder 同步检查点入口，所有常规异步存储调用与它复用同一 SQLite 串行队列；调用 performChanges 前必须结束数据库操作，严禁持锁或占据数据库队列等待 PhotoKit 回调。如果保存 checkpoint 失败，标记整个尝试为未知并停止新增；不能假定 PhotoKit 自动回滚。

- [ ] 明確恢复依据：未调用 performChanges 之前的本地失败可重试；已收到系统确定未提交/原子事务失败结果可记录确定失败；成功 callback 后必须记录成功。崩溃丢失 callback 或 placeholder fetch 不存在均为 unknown，不把系统应用运行正常当否定证明。
- [ ] 可取得库可用性事件时监听；所有查询/写入前复核授权，库变化或目标标识异常时停止新增。macOS 13 无法验证目标一致性的分支保持 unknown；不得伪造公开库 UUID。
- [ ] 在 `Design/Validation.md` 写可执行人工验证：使用用户确认的独立 macOS 测试账号和系统照片图库，不启用 iCloud；从临时只读目录导入自制图片/视频；记录 placeholder、callback、fetch；源仍存在且属性不变；在指定故障点结束测试进程后恢复核对。不得在默认个人图库自动运行。
- [ ] 无授权或无测试环境时完成 mock/编译验证，并将真实导入验收标记“未执行”；不能宣称接入通过。此缺口阻止正式开启用户图库自动导入，但不阻止任务 5–7 的 fake 验证。
- [ ] 通过相关检查后提交 `feat: add PhotoKit import and conservative recovery`。

## Task 5：同步协调与跨目录去重

**Files:** `SyncEngine.swift`、`EngineTests.swift`、补充 Store 必要查询与 TestSupport fake。

**Consumes:** `SyncStore`、`DirectoryReading`、`MetadataReading`、`PhotosGateway`、`DuplicatePolicy`。

**Produces:** `actor SyncEngine`，初始化注入上述五依赖；`scan(sourceIDs: [UUID]) async`、`pause() async`、`resume() async`、`recoverImports() async`、`snapshot() -> EngineSnapshot`。`EngineSnapshot` 包含 checked、pending、imported、skipped、failed、activeWork、waitingSources、blockingError。定义在本文件，所有计数说明是本轮还是累计；界面默认本轮。

- [ ] `FakePhotosGateway` 在 TestSupport 实现协议，保存创建调用次数、内存候选列表和可配置 reconcile 结果，默认不触碰系统 API。创建时调用 onPlaceholder，再返回固定 ID 并更新候选。
- [ ] `EngineTests` 建两个临时来源，写入自制同名图片，用真实目录读取+fake Photos 执行扫描。

```swift
// makeEngineFixture() 在 TestSupport 构造临时库、两个来源、fake Photos 和 engine，
// 返回命名元组 (engine, sourceIDs, photos)，所有资源仅在测试临时目录。
func testTwoSourcesSubmitOnlyOnce() async throws {
    let fixture = try await makeEngineFixture()
    await fixture.engine.scan(sourceIDs: fixture.sourceIDs)
    let count = await fixture.photos.createCount
    XCTAssertEqual(count, 1)
    await fixture.engine.scan(sourceIDs: fixture.sourceIDs)
    let afterRescan = await fixture.photos.createCount
    XCTAssertEqual(afterRescan, 1)
}
```

- [ ] 红灯后实现：恢复 importing → 完整加载 Photos 候选 → 公平轮转目录工作 → stat → 查历史 → 读取新文件 metadata → 原子保存判定/候选 → 提交队列。读取失败只日志和 scan_run 计数，不创建文件记录。
- [ ] 已有 pending 文件必须回到导入队列，已有 importing 去核对，不因 stamp 未变直接遗漏；只有终态 imported/skipped 的未变文件直接略过 metadata。
- [ ] 每次提交前重查 stamp、Photos 候选更新和本地 reservations；排除自己的 record key。待导入跨源候选以创建顺序保留一个提交者，避免两者互相跳过。其他记录匹配这个明确候选即跳过并保存依据，不当作已成功导入。
- [ ] 串行提交：先事务 beginAttempt，再调用 create；成功落库并更新索引后才提交下一项。失去系统响应且仍有未结束的实际提交时占住 Photos 提交槽位，其他来源可继续扫描；不得启动多个实际 performChanges 绕过并发 1。
- [ ] 跨启动无法确认的历史尝试保持 importing；没有存活请求且不属于同名候选的其他文件可继续。失败后重试由确切错误分类决定；SQLite 写入失败全局停止提交。
- [ ] 加入回归：目标从 fake 删除后原源不重导、源变化留成功快照、缺 metadata 的读取失败下轮恢复、Photos 索引失败不提交、多个候选未排除则跳过、source disable 不清历史、晚到 callback 仍记已提交结果、create 成功 store 失败不继续第二次。
- [ ] 运行 `EngineTests`、`StoreTests`、`RecoveryTests`；通过后提交 `feat: coordinate resumable multi-source sync`。

## Task 6：调度、恢复与日志事件

**Files:** `ScanSchedule.swift`、`ScheduleTests.swift`、必要的 Engine 事件；使用 Task 2 RunLogger。

**Interfaces:** 纯调度 `struct ScanSchedule`、`mutating func request(now: Date) -> Bool`、`mutating func finished(now: Date)`、`mutating func pause()`、`mutating func resume(now: Date) -> Bool`；属性 `nextScanAt: Date?`。应用计时器只调用此纯逻辑，不把测试绑定真实 30 分钟。来源重试采用 `retryDelay(failureCount: Int) -> TimeInterval`。

- [ ] 写无等待的时间测试。

```swift
func testNoOverlapOrCatchupBurst() {
    var schedule = ScanSchedule()
    let start = Date(timeIntervalSince1970: 0)
    XCTAssertTrue(schedule.request(now: start))
    XCTAssertFalse(schedule.request(now: start.addingTimeInterval(1800)))
    schedule.finished(now: start.addingTimeInterval(1900))
    XCTAssertFalse(schedule.request(now: start.addingTimeInterval(1901)))
    XCTAssertTrue(schedule.request(now: start.addingTimeInterval(3600)))
}
```

保持已批准的“每 30 分钟触发”语义，不改成完成后再等待 30 分钟。计时触发时推进下一时点；正在运行就丢弃本次触发，finished 不移动计时时点。启动/继续/用户手动触发绕过时间门槛但不绕过运行互斥。为手动触发新增 `requestNow(now:) -> Bool`。

```swift
mutating func request(now: Date) -> Bool {
    guard !paused else { return false }
    if let nextScanAt, now < nextScanAt { return false }
    nextScanAt = now.addingTimeInterval(1800)
    guard !running else { return false }
    running = true
    return true
}
mutating func finished(now: Date) { running = false }
mutating func requestNow(now: Date) -> Bool {
    guard !paused, !running else { return false }
    running = true
    if nextScanAt == nil { nextScanAt = now.addingTimeInterval(1800) }
    return true
}
```

ScanSchedule 声明 private running=false、private paused=false 和 private(set) nextScanAt: Date?。resume 清除 paused，调用 requestNow；pause 设置 paused=true。定时器错过多个周期时只调用一次 request，不遍历补跑。

- [ ] 红灯后实现 running/paused/nextScanAt 内存调度信息（不是新增文件状态）；暂停拒绝新提交，当前提交仍收结果。应用重启默认自动扫描，不将上次临时暂停持久化为永久禁止启动。
- [ ] 来源 retryDelay 为 5、15、30、60、60…秒；一分钟恢复检查独立于 30 分钟周期，不生成重叠 scan。重试成功重置计数，单来源故障不标记其他来源失败。
- [ ] 为暂停期间不探测、继续立即扫描、立即扫描运行中不积压、唤醒只触发一次、系统时间变化不产生补跑风暴写断言。应用用相对计时器等待剩余间隔；检测到时钟变化或唤醒后重建一次计时，不循环补跑。测试注入 now 覆盖前跳/后跳；出现明显时钟回拨时重置 nextScanAt=now+1800，防止等到旧墙钟日期。
- [ ] 日志事件必须包含 run/source/file/attempt 标识、阶段、结果及错误；有发生/恢复转变才发通知事件，不因每分钟重试刷屏。恢复前未解决错误不会显示“已完成”。
- [ ] 通过测试后提交 `feat: schedule scans and source recovery`。

## Task 7：原生菜单栏、全局图标与配置

**Files:** App 下全部 SwiftUI/AppKit 文件、`GlobalStatus.swift`、`GlobalStatusTests.swift`、Info.plist。

**Interfaces:** `GlobalStatus` 为 enum，`static func resolve(configured: Bool, error: Bool, paused: Bool, waiting: Bool, running: Bool) -> GlobalStatus`。状态和系统符号映射为纯函数；AppModel 为 MainActor，接收 EngineSnapshot、来源配置、自启动真实状态。

- [ ] 先验证状态优先级。

```swift
func testWaitingIsVisibleWhileAnotherSourceRuns() {
    XCTAssertEqual(GlobalStatus.resolve(configured: true, error: false,
        paused: false, waiting: true, running: true), .waiting)
}
func testErrorIsNotReportedAsCompleted() {
    XCTAssertEqual(GlobalStatus.resolve(configured: true, error: true,
        paused: false, waiting: false, running: false), .error)
}
```

- [ ] 实现无来源→未配置；其他状态错误 > 暂停 > 等待恢复 > 运行 > 已完成。尚有提交返回时暂停显示“正在暂停”进度，不能伪报工作已停止。
- [ ] 界面采用 `MenuBarExtra`、原生 Button/Text/Divider/ProgressView；图标分别采用 `exclamationmark.triangle`、`pause.circle`、`clock`、`arrow.triangle.2.circlepath`、`checkmark.circle`、`photo`，必须在 macOS 13 验证符号存在；提供 accessibilityLabel 和文本摘要，不能只靠颜色。

```swift
MenuBarExtra {
    StatusMenu(model: model)
} label: {
    Image(systemName: model.statusSymbol)
        .accessibilityLabel(model.statusDescription)
}
Settings { SourceSettings(model: model) }
```

- [ ] Settings 原生 List 管理来源，NSOpenPanel 只选目录；移除等价停用且保留记录。自启动 Toggle 调用 SMAppService.mainApp register/unregister，完成后读取真实 status；失败回退并显示错误。初次不调用 register。
- [ ] “在 Finder 中打开日志目录”使用 NSWorkspace 打开应用日志目录；创建日志目录只在应用自身存储区。没有日志列表或阅读窗口。Info.plist 设置 LSUIElement 和 NSPhotoLibraryUsageDescription；设置非 App Sandbox，写权限边界靠实际 API 和验收约束。
- [ ] 初次未授权时显示原生解释和系统授权动作，不把授权弹窗放在后台静默循环。配置完成及有权限后启动扫描；真实图库未通过任务 4 验收前仅在明确测试环境运行。
- [ ] 手工检查浅色/深色、键盘、VoiceOver、所有全局图标，长目录和错误摘要不挤坏布局；关闭菜单继续、退出停止、启动恢复、启动项开关真的生效。
- [ ] 通过 Core 状态测试和 GUI 手验后提交 `feat: add native menu bar controls and status`。

## Task 8：集成验收、文档与可安装产物

**Files:** `README.md`、`Design/Validation.md`、`scripts/build-dmg.sh`、必要的现有测试补充；不新增功能模块。

- [ ] 运行全部逻辑测试与构建，保存 xcresult 到 work/，记录确切 commit、OS、Xcode、执行命令、结果。用 reviewer 做一次集成审查；tester 只运行相关已集成检查，不重复同一快照的等价审查。
- [ ] 对规格第 10 节每条验收建立结果表（pass/fail/not-run），证据分别标明模拟、真实 PhotoKit、GUI。照片写入验收沿用任务 4 的明确授权测试环境，缺权限不降级使用个人图库。
- [ ] 真实验证源无移动/删除/内容写入；应用无原片缓存；仅允许自己的 SQLite/日志持久化。可用独立测试脚本计算 fixture 测试前后摘要，此测试方法不进入产品，不构成应用哈希功能。
- [ ] 使用测试系统图库完成已导入后删除、重复启动、中断恢复场景；删除测试资产需在授权的测试范围内，不能触及个人图库。无法证明的崩溃分支预期为 importing，而不是强制成功。
- [ ] README 说明安装路径、权限、系统照片图库含义、扫描节奏、跳过语义、日志路径、不可中断 I/O 限制、应用导入完成不等于 iCloud 完成。说明第一版不迁移图库、不自动挂载、不重导删除项。
- [ ] 本地构建产物以 `PhotoSync.app` 放到 outputs；脚本参数仅接受已构建 app 路径和输出 DMG 路径，使用独立 staging 目录复制 app 和 Applications 链接，再 `hdiutil create`，不打包源文件或数据库。

```bash
xcodebuild -project PhotoSync.xcodeproj -scheme PhotoSync -configuration Release \
  -destination 'platform=macOS' -derivedDataPath work/Release CODE_SIGNING_ALLOWED=NO build
# 正式分发另用真实 Developer ID 签名；本地无签名构建不冒充已公证版本。
hdiutil create -volname PhotoSync -srcfolder work/dmg-stage \
  -ov -format UDZO outputs/PhotoSync.dmg
```

- [ ] 正式外部分发时再用实际 Developer ID archive、codesign 验证、notarytool 提交并等待、stapler、spctl 验收。没有证书或公证凭据则交付本地构建并清楚标注“未完成分发签名/公证”，不购买、不上传个人资料、不声称 DMG 即可绕过 Gatekeeper。
- [ ] 收敛评审问题、运行受影响测试并提交 `docs: record validation and package local app`。无剩余高严重性问题，中的问题解决或用户接受，才报告实现完成；真实验收缺口单独列出。

## 规格覆盖与自查

| 设计章节 | 对应任务 |
| --- | --- |
| 1 目标边界、2 架构 | 1、3、4、7、8 |
| 3 来源扫描 | 2、3、5、6 |
| 4 判重 | 1、4、5 |
| 5 四状态恢复 | 2、4、5 |
| 6 慢读异常 | 3、5、6 |
| 7 Photos 接入 | 4、7、8 |
| 8 原生 UI/图标 | 7 |
| 9 数据日志 | 2、6、7 |
| 10 验收 | 每任务测试及 8 |
| 11 扩展边界 | 1、2 的值类型/版本/历史；不实现未来功能 |
| 12 技术验证 | 3、4、8 |

## 实施阶段的关键限制

- 先用编译和 fake 验证推进，不因缺少真实 Photos 测试授权中断全部工程工作；但实际用户图库自动导入必须等真实接入验收。
- 底层不可中断 I/O 占满固定槽位时受控报错，不通过无限线程或额外服务规避已确认架构。
- 公共 API 字段不足按缺失处理，不在实现中偷偷加入私有数据库依赖或全库原片下载。
- 任何改变已确认产品语义的必要调整，要说明并让用户批准；普通局部修复和测试纠错在本计划内推进。
