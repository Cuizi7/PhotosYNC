# PhotosYNC：后续开发与测试交接

本文件面向接手本仓库的代理。先核对当前工作树；历史报告不是当前代码或环境的保证。用户当前指令优先于本文件，已明确授权的操作不要重复询问。

## 先读什么

1. `git status --short`、`git log -5 --oneline`；检查当前目录及父目录的 `CLAUDE.md` / `claude.md`。
2. `outputs/2026-09-13-photo-sync-v1-design.md`：已批准的产品规则。
3. `README.md`：构建、运行和当前限制。
4. `docs/specs/2026-09-18-runtime-state-and-recovery.md`：扫描/恢复/计数/文案的权威运行时契约。
5. `Design/Validation.md`：真实 Photos 验收程序及已验证/未验证的区别。
6. 需要回溯任务时读 `docs/superpowers/plans/2026-09-13-photo-sync-v1.md`；计划含示意接口，以批准设计和实际代码为准。

v1 已实现并合并到 `main`。`4adc1e0` 是本轮修复前的 main 基线。beta3 修复、App 自动测试及发布门槛的当前源码以本 checkout 的 `git rev-parse HEAD` 为准；下方日期记录保留历史验证事实，不能代替当前发布结果。不要重新执行整套已完成实施计划；后续变更仍需在当前 HEAD 验证。

## 不可突破的第一版边界

- 源目录严格只读：不删除、移动、重命名、改内容、改 metadata、写标记或缓存。
- Photos 仅新增资产，不覆盖、编辑、删除已有资产，不创建目录/相簿映射。
- 允许合理读取 Photos；采用公开 PhotoKit，目标为系统照片图库。`PHPhotoLibrary.shared()` 不是 iCloud 共享相簿。
- 导入使用原始文件 URL，`shouldMoveFile = false`。不解码后重新编码、不转码。
- 不计算产品级内容哈希、不暂存原片、不下载整套 iCloud 原片用于判重。
- 多目录走同一读取逻辑，不区分本地和网络，不自动挂载或保存网络凭据。
- 位图和视频为媒体范围；RAW、旁车等排除，未知格式记录跳过。损坏的支持格式是读取错误，不能伪装成正常缺失元数据。
- 不跟随来源根目录、祖先或子项的符号链接。当前实现仅对核实目标的系统 `/var`、`/tmp` 别名作规范化；不承诺对抗任意并发路径替换。
- 删除双向同步、编辑覆盖、精确内容判重、Live Photo 配对、复杂调度和更多来源均属于后续版本，不能顺手加入。

## 已批准的判重和恢复语义

- 文件名（含扩展名、不含目录）精确比较，不折叠大小写；不同文件名视为不同照片。
- 同名时，可靠拍摄时间精确到秒不同，或完整设备信息明确冲突，才能排除该候选。
- 不设置时间容差。不知道时区或精度不足时不推测本机时区；任意未排除候选都导致疑似重复跳过。
- 相机厂商/型号允许规范化空白和大小写；缺失不是不同证据。尺寸、时长、大小不额外决定不同。
- Photos 现存资产、本地待导入/导入中以及成功历史参与候选查询；不能把无成功关系的跳过项当作成功导入证明。
- 仅四种文件状态：`pending`、`importing`、`imported`、`skipped`。重试和跳过原因是字段，不扩充状态。
- 成功历史不随目标消失、来源停用、源属性变化而清空；Photos 中删除过的成功导入项不能自动补回来。
- 源大小/mtime 变化先跳过；属性未变不表示内容已经校验一致。
- 提交前落库意图；placeholder 检查点不等于成功。收到 PhotoKit 成功回调后保留成功证据，即使随后的 fetch 或权限检查失败。
- PhotoKit 与 SQLite 无联合事务。单次查询不到、超时、崩溃或权限不足都不能证明未提交；只有明确失败证据才允许重试。
- 同一时刻只能有一个实际 Photos 提交。超时不能假定系统请求已终止，不能重建 gateway 绕过未知结果阻断。
- 暂停/停用停止新提交，已经提交的结果仍必须落库。actor 每次 await 后须重新核对关键提交条件。

## 代码地图与容易出错的接口

| 位置 | 责任 |
| --- | --- |
| `Sources/PhotoSyncApp/AppModel.swift` | MainActor UI、原生设置、自启动/通知权限动作；`--demo` 入口 |
| `Sources/PhotoSyncApp/SyncRuntime.swift` | 一个 engine/gateway/shared executor 的生命周期、真实计时器和调度接入 |
| `Sources/PhotoSyncCore/Sync/SyncEngine.swift` | 并发来源扫描、串行提交、恢复、来源聚合错误和计数 |
| `Sources/PhotoSyncCore/Sync/ScanSchedule.swift` | 30 分钟触发、不叠加/补跑，来源 5/15/30/60 秒恢复 |
| `Sources/PhotoSyncCore/Matching/DuplicatePolicy.swift` | 无 I/O 的判重规则 |
| `Sources/PhotoSyncCore/Photos/` | 公开 PhotoKit 适配、可注入生命周期测试接口 |
| `Sources/PhotoSyncCore/Sources/` | 来源验证、逐项枚举、ImageIO/AVFoundation 元数据、有界读取 |
| `Sources/PhotoSyncCore/Storage/` | SQLite 迁移、事务、成功历史、真实候选快照 |
| `Sources/PhotoSyncCore/Logging/RunLogger.swift` | 轮转日志及失败回调 |
| `Tests/PhotoSyncCoreTests/` | 无宿主 XCTest；含引擎及 runtime 注入测试 |

Core 是 framework，应用和测试均需正确链接/嵌入；增加文件时更新 Xcode project 的目标成员关系。没有第三方运行时依赖。

当前 SQLite schema 为 v3；source.removed 用于移除来源配置并保留同步历史。重新添加同一路径恢复原来源身份；移除不删除源文件或 Photos 资产。`non_media_skip` 保存只有属性的非媒体跳过记录，不编造拍摄 metadata。迁移必须事务化，拒绝未知高版本且不能删除旧库。`Schema.sql` 和代码内迁移仍有重复定义，修改时必须同步核对两处。

SQLite 常规调用通过串行队列；placeholder 用同步检查点入口。网络目录验证不能占据数据库队列，不能持数据库锁等待 PhotoKit。实际读取占用有界，超时/取消只结束逻辑等待，底层读取结束才释放物理槽位；正常完成须先释放再返回，避免紧接着的同来源读取误报 busy。

单个子文件失败不能丢掉全部健康兄弟项。来源恢复提示依据全部未解决问题聚合，不能一张成功就清空其他失败；扫描结束不能覆盖并发提交失败的日志。

## 构建和自动测试

完整验收和发布以文末“Agent 自主验收与本地发布契约”的统一入口为准。下方原生构建/XCTest命令用于分层诊断，不单独构成发布验收。

最低 macOS 13；历史验证环境为 Xcode 26.6 / Swift 6.3.3。执行前用 `xcodebuild -version`、`xcrun swift --version` 复核。

从仓库根目录执行，产物及日志放到被忽略的 `work/`：

```bash
mkdir -p work
xcodebuild -project PhotoSync.xcodeproj -scheme PhotoSync \
  -destination 'platform=macOS' -derivedDataPath work/Validation \
  CODE_SIGNING_ALLOWED=NO build-for-testing > work/build.log 2>&1
```

仅在构建退出码为 0 后运行：

```bash
xcrun xctest work/Validation/Build/Products/Debug/PhotoSyncCoreTests.xctest \
  > work/tests.log 2>&1
```

检查退出码、测试总数及失败数，不以日志中出现一次 PASS 代替最终结果。历史的 94 不是永久固定数量。`xcodebuild test` 曾因 testmanagerd 权限/调度在本环境阻塞；直接 xctest 执行同一个构建好的无宿主测试 bundle 是已验证路径。不要无限重试/长时间挂住 runner；必要时仅终止自己启动的进程并记录环境问题。

测试均应使用临时 UUID 目录、自制媒体和 injected fake/lifecycle seam，不实例化真实图库来替代缺少的 mock。真实 metadata 提取、SQLite、判重和调度须有行为断言；并发使用可控门闩建立时序，不靠随意 sleep 碰运气。修改行为先重现失败，再做最小修复并验证；不要重复运行已通过且未变化的测试快照。

## GUI、真实图库及系统副作用

- 正常启动会读取本机应用配置，已有授权及启用来源时可以自动导入；不是无副作用的 UI 演示。
- 仅检查布局时使用 `--demo`，此分支不建立真实 runtime/store/gateway。可追加 `--status error --light`；其他状态值见 `GlobalStatus.swift`。

```bash
open -n work/Validation/Build/Products/Debug/PhotosYNC.app --args --demo --status error --light
```

在需要系统批准的环境正常请求工具执行权限。不要为演示授权 Photos、启用登录项或更改通知权限；这些系统动作的实测应明确列出。

真实 Photos 写入默认遵循 `Design/Validation.md`：用户确认的独立 macOS 测试账号、该账号系统图库、自制只读照片/视频，避免使用个人图库。不要自行切换用户系统图库、开关 iCloud 或创建系统账号。用户后续若明确授权了不同测试范围，应记录确切范围并遵守，不机械重复索要同一授权。

代码允许不代表已经获准执行：不得通过脚本调用绕过 UI 提示来扩大测试范围。测试用哈希可以核对自制 fixture 的前后字节，但不能带入产品的同步逻辑。

## 运行数据与打包

发布统一使用 `scripts/package-release.sh`，它从归档源码强制执行完整验收。下方手动 Release/签名命令仅保留为历史诊断参考，不得用来绕过发布门槛。

真实运行数据：`~/Library/Application Support/PhotoSync/sync.sqlite`，日志在同目录 `Logs/`。排查时先只读；不要删除数据库“重置测试”，这会丢失防重复导入的历史。源码/构建目录不是运行数据目录。

```bash
xcodebuild -project PhotoSync.xcodeproj -scheme PhotoSync -configuration Release \
  -destination 'platform=macOS' -derivedDataPath work/Release CODE_SIGNING_ALLOWED=NO build
```

构建成功后再执行：

```bash
ditto work/Release/Build/Products/Release/PhotosYNC.app outputs/PhotosYNC.app
codesign --force --sign - --timestamp=none outputs/PhotosYNC.app/Contents/Frameworks/PhotoSyncCore.framework
codesign --force --sign - --timestamp=none outputs/PhotosYNC.app
codesign --verify --deep --strict --all-architectures outputs/PhotosYNC.app
scripts/build-dmg.sh "$PWD/outputs/PhotosYNC.app" "$PWD/outputs/PhotosYNC.dmg"
```

这些是本地 ad-hoc 签名产物，不等于 Developer ID 签名、公证或 Gatekeeper 验收通过。正式签名/公证需真实凭据和授权，不购买、上传或公开发布来“顺便完成”。重建后更新 `outputs/PhotosYNC.provenance` 的确切源码提交、脚本版本及校验值；旧包不是修改后代码的验证证据。

`work/`、`.worktrees/`、应用/DMG/provenance 已被忽略。不要强制提交 scratch、DerivedData、个人数据库或媒体。`outputs/PhotoSync-implementation-report.md` 和 execution-ledger 是交付记录，可能未被 Git 跟踪；保留，不误作待删垃圾。

## 剩余验收和已知限制

没有尚未修复的已知高严重性评审问题，但这不代表全部真实环境验收完成：

- 真实 PhotoKit 导入、授权/图库变化、崩溃恢复、源不变性、只增不删。
- 真实网络挂载断开/恢复、空间不足；不可中断 I/O 全占满时可能需重启。
- macOS 13/14 实机、登录启动、系统通知、真实菜单/目录选择、键盘/VoiceOver。
- 真实 Finder alias fixture、AVFoundation 从真实视频提取带 offset 的拍摄时间；parser 测试不能证明资源提取。
- Developer ID 签名、公证、正式安装启动。

低优先级限制：停用来源仍参与父子目录重叠判断；schema 双份定义。未经新的范围确认，不扩成重构项目。

## 协作及完成标准

按风险缩放流程：文档/小改动直接做聚焦验证；复杂功能、状态持久化和并发修改先明确方案，使用独立分支/worktree、评审和验证。允许按需使用 explorer、docs_researcher、reviewer、tester 分担独立任务；单个所有者负责每块修改，不并行编辑相同区域，不撤销他人变更。用户指定子代理开发流程时按该流程执行，避免重复评审同一快照。

报告必须分开列出：构建、自动测试、GUI 演示、真实 Photos、平台兼容、签名分发；未运行写清楚，不能互相替代。记录实际 commit、命令、结果和残余风险。合并/推送/发布遵守用户已授权的范围，不自行发布远端。

兼容范围变更（2026-09-14，用户批准）：最低系统版本由 macOS 14 扩展为 macOS 13。macOS 13 设置入口使用受 AppModel 持有的原生 NSWindow；14+ 保留 SettingsLink。构建成功不等于 macOS 13 实机/真实 Photos 验收通过，结果需单独记录。


2026-09-15 发布改名：用户可见名称/产品为 PhotosYNC；Xcode project、scheme、模块、bundle ID 和 Application Support/PhotoSync 数据目录保持不变。macOS默认文件系统不区分大小写，PhotoSync.app与PhotosYNC.app不能作为独立路径；更新产物应使用干净暂存目录，不能用ditto叠加旧包。网络恢复方案在docs/release/2026-09-15-network-recovery-plan.md，尚未实现。最近删除中的用户授权测试图按用户要求不再清理。


2026-09-15 beta 冻结：版本 0.1.0 beta（build 1），Release 使用 scripts/package-release.sh 从已提交 git archive 快照构建 Universal 包，输出 outputs/releases/0.1.0-beta/，不覆盖旧包也不启动应用。图标源 Design/Icons/PhotosYNC.icon 已进入 app 资源阶段；Xcode 编译 Assets.car 和旧系统 ICNS。详情 docs/release/0.1.0-beta.md。历史未跟踪报告、候选图标及 remote-macos13 原始证据已归档 work/Archive/2026-09-15-beta-freeze/；旧 DerivedData 的 Build/模块缓存/索引已清理，日志和数据库备份保留。

用户正在使用本机时，不通过全局模拟按键（尤其 ⌘W / ⌘Q）或抢占前台焦点控制工具；本次发布收尾仅用无界面命令行，不关闭用户窗口，不启动会自动扫描的生产 PhotosYNC。

2026-09-16 beta2：统计拆分为 EngineSnapshot.summary（活动来源持久化互斥状态，首次未知为 nil）与 latestScan（本次扫描）。非候选 ARW/XMP 不写跳过记录、不计检查/跳过；旧 non_media_skip 表可存在但应用不读写；离线清理工具 scripts/cleanup-non-candidate-records.py 默认 dry-run，--apply 必须指定备份，对实际生产库取得相同 instance.lock，不能在生产应用运行时清理。生产数据库副本只能用于隔离测试，不得根据副本中的 source.path 扫描实际媒体。通知警告独立于同步错误；checkpointFailed 仍是 unknown 恢复证据，不能据此允许重试。beta2 build 2，tag/产物独立于 beta1。部署或清理生产数据仍需新的明确授权。

2026-09-17 计数口径修订（分支 fix/error-caliber-2026-09-17，用户逐项确认；未合并、未发布）：菜单不再显示“错误 N 次”这种把来源不可用与文件失败混在一起的本轮事件数。`SyncStatusSummary` 新增 `retryPending`（`pending` 且 `last_error` 非空），`pending` 只统计尚无错误的待提交记录，两者相加等于全部 pending，仍只有四种文件状态。`ScanProgress` 新增 `failedFiles`（本轮文件读取失败数，只用于“本次扫描”行），内部 `failed` 仍驱动 `finishScan(complete:)`、来源退避与“已中断”，语义未变。来源问题键由固定 `"scan"` 拆为 `scan:directory` 与 `scan:file:<relativePath>`，主消息按目录→提交→文件优先级选取，`EngineSnapshot.sourceFileIssueCounts` 提供每来源未解决文件数；干净扫描清除全部 `scan:*` 键，单文件在其可读或被记录后单独清除；停用来源会清除其等待状态。`sourceRecoveryDelay` 与文件级 `retryDelay` 分离，来源连续 5 次不可用后改为每 5 分钟探测（文件重试仍是 5/15/30/60 秒），重复的失败行只在签名变化时写日志（每轮尝试仍由 scan_run 记录）。未授权 Photos 计入“需要处理错误”（`GlobalStatus.resolve(authorized:)`），`blockingError` 首次进入时通过新的 `notifyIssue` 通道发通知，授权撤回在状态转变时通知；上述均未做真实 Photos/系统通知实测。

2026-09-17 文案口径（同一分支，用户要求“系统原文不该给用户看”）：`SourceIssue{summary, detail}` 取代来源问题里的裸字符串——菜单、设置页和系统通知只显示 `summary`（人话，按失败位置分类：卷未挂载／目录不存在／无权限／网络中断／文件不可读／导入未确认／检查点失败／库停止／图库不可用），`detail` 保留系统原文并只出现在悬停提示与日志里。`EngineSnapshot.blockingSummary` 提供阻断类首行文案，`blockingError`、`summaryError`、`RuntimeState.messageDetail` 及 AppModel 的 `errorDetail` 只进工具提示；`SourceRegistryError` 的描述改为中文（它直接面对用户）；弹窗/菜单不再直接拼接 `localizedDescription`。日志与 `scan_run.last_error` 仍保留原文，不得为好看而丢弃。

2026-09-17 与 feat/macos13-compat 对齐（分支 fix/error-caliber-reconciled；用户的 beta2 由另一份工作副本 `~/Documents/Codex/2026-09-13/photos-mac-gui-metadata-photos-gui-2` 构建，其 HEAD 为 `8d9e6c9`，父提交即本仓库 `c554f07`；两份副本此前各自提交、无 remote，已用 `git fetch <本地路径>` 取回 `8d9e6c9`）。我原先的 3 个提交（完整历史保留在 `backup/error-caliber-3commits-20260917`）因与 `8d9e6c9` 反复改写同一区域，被压成一个对齐提交：保留 `SourceIssue{summary,detail}`、`retryPending`、问题键细分、deferred、通知通道与日志去重，吸收对方的 `subject`（来源目录/部分子目录）文案、`SourceRegistryError` 分支、`NSUnderlyingErrorKey` 链遍历与其 `ControlledDirectoryReader` 测试夹，并在此基础上改文案：根目录缺失用“来源目录不可用，正在等待恢复。请检查磁盘或网络连接。”，`/Volumes/<卷>` 缺失仍用更精确的“未挂载”句。

读取竞争＝正常等待（同一提交，用户要求“用户不能看到报错，因为这其实只是正常的等待逻辑”）：`ReadExecutorError` 的三种结果不再产生任何来源或文件问题，不计 `failedFiles`、不进 `waitingSources`/`sourceFileIssueCounts`、不发通知，也不写 `scan_run` 失败；只置 `ScanProgress.deferred` 与 `EngineSnapshot.deferredSources`，本轮在菜单显示“稍后继续”，并由 `ScanSchedule.recordSourceDeferral` 以 5/5/15/15/60 秒的独立短退避取回（与失败曲线、5 分钟来源退避互不影响）。`8d9e6c9` 中把 busy/timeout 映射成等待文案的写法与相应用例已按此政策改写。构建与 160 项测试在本分支通过；未做 GUI、真实 Photos、系统通知与打包验证。

2026-09-17 统计口径补注（同一分支）：`activeSourceSummary` 改为一条带 CTE 的语句，除原有活动来源计数外新增 `retainedImported`（停用或移除来源的成功导入数）；活动计数显式带 `source.enabled = 1 AND source.removed = 0` 条件，退役历史不再混入 `imported`。`SyncStatusPresentation.summary` 在 `retainedImported > 0` 时附注“另有 N 条历史属已停用或移除的来源”。动机：把子目录换成其父目录、或停用来源时，历史仍在库中但会退出统计，原实现会让“已导入”看起来凭空归零。已在生产库只读副本上核对：212 活动导入 + 2 条退役历史（已移除的 PhotosYNC-QA），与原 214 条一致。构建与 161 项测试通过。

2026-09-18 当前基线：上述 2026-09-17 修复已在本地 `main` squash 为 `259d990`，远端尚未推送。运行时状态、读取 deferred、来源/文件错误隔离、退避和文案以 `docs/specs/2026-09-18-runtime-state-and-recovery.md` 为权威；核心测试基线为 167 项。历史分支名称和旧测试数量只用于追溯，不作为当前状态。


## 2026-09-19 beta3 修复与本地发布

以下记录对应 `codex/photosync-beta3-fixes` 的历史行为冻结阶段；当前分支与合并状态须以 Git 为准。行为冻结提交 `5420dce992d2fcb58a5d0a8bd57b5c55dc31af3f` 已通过干净 build-for-testing 和完整 209 项 XCTest（0 失败，2.909 秒）；集成深度评审及修复复核 SPEC/QUALITY 均通过，范围内问题均已解决。恢复后旧错误发布交错另有受控 RED/GREEN 探针与 84 项受影响测试证据。最终日志为 `work/beta3-frozen-build.log`、`work/beta3-frozen-tests.log`；打包提交由发布产物 provenance 记录。

- `recordSourceChange` 在同一事务内拒绝覆盖 `importing`；晚到的成功回调仍保留成功证据，提交前的正常并发状态变化不会停止整个 engine。
- runtime tick 独立消费明确未提交文件的重试期限；目录恢复、文件重试和读取 deferred 使用独立口径，unknown 提交不因到期进入重试。
- 完整目录遍历恢复后清除目录问题，即使另有坏文件；文件日志独立去重，目录恢复后相同故障再次出现会重新记录。恢复已经清除的问题不会被早先异步读取失败重新发布。
- UI 从问题类别和未完成工作推导状态；真实来源不可用保持优先于运行中，deferred 不再虚报完成。设置支持原位置启用来源并保留身份/历史，操作进行中防重复；菜单信息区有界滚动，操作区固定。
- 日期解析拒绝日历无效日期；带明确时区的合法视频小数秒使用基础整数秒，避免浮点舍入进位。判重仍无时间容差，不猜测时区。

版本配置为 0.1.0 / beta3 / build 3；独立打包路径 `outputs/releases/0.1.0-beta3/`。使用 `scripts/package-release.sh` 从干净已提交的 git archive 构建 Universal arm64/x86_64，并记录实际源码提交。包是否已构建、签名/DMG/校验是否通过以本轮发布证据为准，不能凭版本配置推断。

保持 schema v3，不重判历史 skipped，不修补过去可能丢失的成功历史，不清理或迁移生产数据库。UI 证据来自 `005bfd7` 的离屏 NSHostingView/临时 fixture：0/1/16/30 来源菜单高 248/299/626/626pt；这不是原生菜单、点击、键盘/VoiceOver 或 macOS 13/14 实机验收。该历史阶段未启动生产应用、访问真实 Photos、更改系统权限、安装、合并或推送；后续合并与发布以 Git 和产物 provenance 为准。本地 ad-hoc 签名不等于 Developer ID、公证或 Gatekeeper 验收。完整边界见 `docs/release/0.1.0-beta3.md` 与 `Design/Validation.md`。


## Agent 自主验收与本地发布契约（2026-09-19）

普通 beta 的默认发布门槛是自动回归和产物核验，不要求每次重复真实 Photos 验收。此前的基础系统验收可复用于没有改变的系统集成边界；不得把历史记录写成当前包的新实测。

### 强制入口与失败处理

- 开发验收使用 `python3 scripts/validate.py --output-dir "$PWD/work/validation-<唯一名称>" --derived-data "$PWD/work/validation-<唯一名称>-derived"`。不要用仅 `xcodebuild build`、几项 selected tests 或旧日志宣告完整验收。
- 发布使用 `scripts/package-release.sh`。它要求干净的已提交源码（非 ignored 的未跟踪文件也须处理），先归档该提交，再在同一归档中完整验证和正常 Universal Release 构建。不允许先在旧工作树测试，再包装不同源码。
- 验收包含完整无过滤 XCTest、`Tests/Tools` 合成数据测试和受控续体竞态回归。XCTest 退出码、完整结束标志、实际数量大于零及失败数为零须同时满足；任何失败、超时、缺失工具/报告或零测试都不能绕过。
- `scripts/test-continuation-race.py` 从当前 Core 创建隔离副本并插入唯一 await 门闩，执行版本控制的 `Tests/Regression/ContinuationRace.swift`。锚点改变须失败并修复 harness，不能跳过；门闩及测试代码不得进入发行 App。它补的是 retry 写入成功之后、失败提示发布之前的竞争，不得以较早的 retry 写入前竞争测试替代。
- 发布包必须通过版本/channel/build、Universal app/Core 架构、图标资源、逐层签名、DMG 和校验值检查。provenance 必须绑定实际源码提交与本次验证证据；不得复用旧的成功标记。
- 已有发布路径（目录、文件或符号链接）不得覆盖。发布锁冲突须停止；不能删除他人锁或在旧发布目录内嵌套新 package 来规避拒绝。失败保留独立 work 证据，不留下被宣称成功的发布目录。
- 独立 review 按本文件风险等级执行；等价只读 review 不使既有测试失效，修复后仅重审新差异。最终完整验收必须覆盖最后一次行为/测试变更。用户明确授权的本地 squash merge 不重复询问；合并后核对源码树，并从 main 的确切提交执行发布入口。

### 何时需要针对性系统验证

- 普通状态机修复、调度、统计、日志、纯解析逻辑及已有契约内的来源操作，可用完整自动验证验收。UI 改动补常规离屏/GUIQA 行为测试；无需为 UI 测试导入真实照片。
- 真实 PhotoKit 提交/恢复语义、系统授权调用、entitlements/bundle identity、真实媒体读取方式、新媒体类型、最低系统版本或平台兼容假设改变时，评估并补改变边界的针对性系统验证。不是对同一旧路径反复重跑整套手工验证。
- 新的系统验收需要超出已有用户授权的图库、来源或系统设置时，先说明确切范围与缺口；不得通过测试脚本绕过授权。没有执行的边界如实标为未验证，不能伪称通过。
- 常规自动验收只用自制媒体、UUID 临时数据库和 fake Photos；不得自动读取生产数据库或历史生产快照。`Tests/Tools` 也遵循这一规则。

本契约中的“发布”默认是本地 ad-hoc app/DMG 交付。远端推送、公开发布、安装/启动生产 App、Developer ID/公证、生产数据维护均遵守用户实际授权；不能由“验收通过”自行推导授权。全局 Codex 配置及插件技能无需为本项目改写。
