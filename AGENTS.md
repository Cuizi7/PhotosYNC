# PhotoSync：后续开发与测试交接

本文件面向接手本仓库的代理。先核对当前工作树；历史报告不是当前代码或环境的保证。用户当前指令优先于本文件，已明确授权的操作不要重复询问。

## 先读什么

1. `git status --short`、`git log -5 --oneline`；检查当前目录及父目录的 `CLAUDE.md` / `claude.md`。
2. `outputs/2026-09-13-photo-sync-v1-design.md`：已批准的产品规则。
3. `README.md`：构建、运行和当前限制。
4. `Design/Validation.md`：真实 Photos 验收程序及已验证/未验证的区别。
5. 需要回溯任务时读 `docs/superpowers/plans/2026-09-13-photo-sync-v1.md`；计划含示意接口，以批准设计和实际代码为准。

v1 已实现并合并到 `main`，代码基线 `5666851`；2026-09-14 合并后重新构建和执行 94 项测试通过。不要重新执行整套已完成实施计划。后续变更仍需在当前 HEAD 验证。

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

当前 SQLite schema 为 v2，`non_media_skip` 保存只有属性的非媒体跳过记录，不编造拍摄 metadata。迁移必须事务化，拒绝未知高版本且不能删除旧库。`Schema.sql` 和代码内迁移仍有重复定义，修改时必须同步核对两处。

SQLite 常规调用通过串行队列；placeholder 用同步检查点入口。网络目录验证不能占据数据库队列，不能持数据库锁等待 PhotoKit。实际读取占用有界，超时/取消只结束逻辑等待，底层读取结束才释放物理槽位；正常完成须先释放再返回，避免紧接着的同来源读取误报 busy。

单个子文件失败不能丢掉全部健康兄弟项。来源恢复提示依据全部未解决问题聚合，不能一张成功就清空其他失败；扫描结束不能覆盖并发提交失败的日志。

## 构建和自动测试

最低 macOS 14；历史验证环境为 Xcode 26.6 / Swift 6.3.3。执行前用 `xcodebuild -version`、`xcrun swift --version` 复核。

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
open -n work/Validation/Build/Products/Debug/PhotoSync.app --args --demo --status error --light
```

在需要系统批准的环境正常请求工具执行权限。不要为演示授权 Photos、启用登录项或更改通知权限；这些系统动作的实测应明确列出。

真实 Photos 写入默认遵循 `Design/Validation.md`：用户确认的独立 macOS 测试账号、该账号系统图库、自制只读照片/视频，避免使用个人图库。不要自行切换用户系统图库、开关 iCloud 或创建系统账号。用户后续若明确授权了不同测试范围，应记录确切范围并遵守，不机械重复索要同一授权。

代码允许不代表已经获准执行：不得通过脚本调用绕过 UI 提示来扩大测试范围。测试用哈希可以核对自制 fixture 的前后字节，但不能带入产品的同步逻辑。

## 运行数据与打包

真实运行数据：`~/Library/Application Support/PhotoSync/sync.sqlite`，日志在同目录 `Logs/`。排查时先只读；不要删除数据库“重置测试”，这会丢失防重复导入的历史。源码/构建目录不是运行数据目录。

```bash
xcodebuild -project PhotoSync.xcodeproj -scheme PhotoSync -configuration Release \
  -destination 'platform=macOS' -derivedDataPath work/Release CODE_SIGNING_ALLOWED=NO build
```

构建成功后再执行：

```bash
ditto work/Release/Build/Products/Release/PhotoSync.app outputs/PhotoSync.app
scripts/build-dmg.sh "$PWD/outputs/PhotoSync.app" "$PWD/outputs/PhotoSync.dmg"
```

这些是本地 ad-hoc 签名产物，不等于 Developer ID 签名、公证或 Gatekeeper 验收通过。正式签名/公证需真实凭据和授权，不购买、上传或公开发布来“顺便完成”。重建后更新 `outputs/PhotoSync.provenance` 的确切源码提交、脚本版本及校验值；旧包不是修改后代码的验证证据。

`work/`、`.worktrees/`、应用/DMG/provenance 已被忽略。不要强制提交 scratch、DerivedData、个人数据库或媒体。`outputs/PhotoSync-implementation-report.md` 和 execution-ledger 是交付记录，可能未被 Git 跟踪；保留，不误作待删垃圾。

## 剩余验收和已知限制

没有尚未修复的已知高严重性评审问题，但这不代表全部真实环境验收完成：

- 真实 PhotoKit 导入、授权/图库变化、崩溃恢复、源不变性、只增不删。
- 真实网络挂载断开/恢复、空间不足；不可中断 I/O 全占满时可能需重启。
- macOS 14 实机、登录启动、系统通知、真实菜单/目录选择、键盘/VoiceOver。
- 真实 Finder alias fixture、AVFoundation 从真实视频提取带 offset 的拍摄时间；parser 测试不能证明资源提取。
- Developer ID 签名、公证、正式安装启动。

低优先级限制：停用来源仍参与父子目录重叠判断；schema 双份定义。未经新的范围确认，不扩成重构项目。

## 协作及完成标准

按风险缩放流程：文档/小改动直接做聚焦验证；复杂功能、状态持久化和并发修改先明确方案，使用独立分支/worktree、评审和验证。允许按需使用 explorer、docs_researcher、reviewer、tester 分担独立任务；单个所有者负责每块修改，不并行编辑相同区域，不撤销他人变更。用户指定子代理开发流程时按该流程执行，避免重复评审同一快照。

报告必须分开列出：构建、自动测试、GUI 演示、真实 Photos、平台兼容、签名分发；未运行写清楚，不能互相替代。记录实际 commit、命令、结果和残余风险。合并/推送/发布遵守用户已授权的范围，不自行发布远端。
