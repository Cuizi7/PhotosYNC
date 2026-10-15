# PhotosYNC 来源诊断与图库分析详情设计

日期：2026-10-15（Asia/Shanghai）。状态：**协调线程已批准实际设计与计划，进入SDD；批准时未开始产品实现**。
基线：本地/远端 main 与 v0.2.1 均为 `1291b53ee0d263709379eb016d78b6fb8070c762`。
工作树：`/Users/cuiziqi/.codex/worktrees/photosync-diagnostics-022/PhotosYNC`；分支：`codex/source-diagnostics-022`。

## 1. 目标与授权边界

本轮只修复两个用户可见缺口：来源行以一个含数量的摘要代表全部当前未解决问题，hover 可读完整诊断；图库分析时 info 的内容与主菜单同一分析状态一致。

- 保持原生 SwiftUI/AppKit Button、Popover、ScrollView；最低 macOS 13，Universal arm64/x86_64，无新运行时依赖。
- 源严格只读，Photos 仅既有新增语义；不转码、不扩展视频兼容性，不吞解析错误继续导入，不变更判重/提交/恢复/调度决策或 schema v8。
- 使用合成来源、UUID 临时库与 fake/injected 状态；不读取生产视频、数据库、真实 Photos，不安装或启动生产 App，不改权限/登录项/通知设置。
- 这次委托授权修复、PR、push、squash merge main、下一补丁 GitHub stable release；发布仍为既有 ad-hoc 分发。macOS13 与 Intel 实机不执行，Universal 构建保留。
- 先审阅本设计和计划，再 SDD。实际 UI 截图交协调线程；代理审阅不能写成人工验收。旧包、标签、stash、QA 数据及 cleanup Archive 全部保留。

## 2. 现状、选项和最小改动

`EngineSnapshot.waitingSources` 只提供每来源首条问题，`sourceFileIssueCounts` 只计 scan:file，完整内存集合是 `SyncEngine.sourceIssues`。其中所有目录故障共用 `scan:directory`，已经在快照前丢失其他目录详情。`DirectoryEntry.failure` 又将属性错误转为字符串，丢失 domain/code。视频必需 load 的 catch 有系统代码但没有失败步骤。

`StatusMenu` 前景使用 `SyncStatusPresentation.analysis`；`SyncDetailsContent` 只读 summary/latestScan。IndexProgress 已到达菜单，不需要新查询或计数器。

| 选项 | 结果 |
| --- | --- |
| **推荐：补齐既有内存问题的诊断成员与只读快照，UI 原生浮层投影** | 能显示所有问题并保留恢复边界；增量仅为必要诊断信息与 UI |
| 只拼首条问题与现有文件数 | 无法补回其他目录、路径、提交问题，不能验收 |
| 建持久化错误中心/新错误数据库 | 超出范围，增加生命周期和迁移风险，不采用 |

推荐方案新增一个只读明细值类型、现有问题值的私有诊断容器，以及共享原生 hover 控件。它们分别直接服务“完整问题内容”和两类详情复用同一交互，不引入独立 ViewModel、错误服务或持久化系统。

## 3. 来源问题身份、数量与恢复

### 3.1 数据契约

新增 `SourceIssueDetail: Equatable, Sendable, Identifiable`，字段为 `id: String`、`kind: SourceIssueKind`、`path: String`、`summary: String`、`stage: String?`、`detail: String`。path 是失败处已有的完整路径，不通过 hover 再访问文件系统；无法确定步骤时 stage=nil，不能猜测。

新增 `EngineSnapshot.sourceIssueDetails: [UUID: [SourceIssueDetail]]`，仅从 actor 内现有问题集合投影。保持 waitingSources 和 sourceFileIssueCounts 的既有分类用途，UI 的“问题项数”只取明细身份数，不加文件失败次数/来源数/重试数。

内部 `sourceIssues` 保留原有槽位键，值改为私有 `TrackedSourceIssue`（primary: SourceIssue + diagnostics: [String: SourceIssueDetail]）：

| 问题 | 槽位/诊断身份 | 恢复证据 |
| --- | --- | --- |
| 文件扫描读取 | 既有 `scan:file:<relativePath>`，一项 | 原有可读取/记录或干净扫描边界 |
| 文件提交/提交前检查 | 既有 `file:<record UUID>`，一项 | 原有提交、属性变化、明确删除等边界 |
| 目录枚举 | 槽位仍为 `scan:directory`；成员按完整失败目录路径标识 | 某目录 entries 成功仅移除该目录诊断；完整遍历才清槽位 |

目录诊断成员变化后，TrackedSourceIssue.primary 必须从仍未解决成员按完整路径、身份排序选取，summary/detail来自同一成员；A已恢复、B仍失败时不得再用A的原因用于waitingSources、通知或日志。成员空但恢复标记仍在时primary改用中性恢复原因，kind与来源退避门槛保持不变。

同一身份重复失败只更新原因与步骤，不累计；错误代码/文案变化不产生新身份。同一文件的扫描与提交是不同问题，保留两项；不按 filename、summary 或系统错误文本去重。组内按完整路径、身份稳定排序，不改变来源顺序。

### 3.2 目录恢复必须保留的边界

`SyncRuntime.finishedRound` 依赖 waitingSources.isSourceAvailability 决定来源失败曲线。不得将逐目录诊断恢复直接等价为来源恢复。

保留 `scan:directory` 作为现有来源恢复标记：有过目录故障后，只有原先的完整目录遍历条件成立才清除该标记及来源退避/恢复通知。成功目录只去掉自身诊断和对应日志签名，不重置兄弟目录去重。未访问目录的旧诊断继续保留；完整遍历可一次清除已不再存在的旧目录诊断。任何 await 后仍使用既有 canScan 校验。

若该标记的诊断已全部清空，但其他目录 deferred/暂停/中断导致恢复尚未确认，保留标记并显示中性状态“等待确认来源恢复”，不增加问题数。若还有文件/提交问题，来源行仍只显示“发现 N 项问题”，浮层另列该恢复状态。单纯 deferred 且无既有故障不能创建此标记、问题项、失败日志或通知。

完整遍历还需清理已证明不存在、但metadata失败而从未落库的旧scan:file诊断：扫描开始只跟踪本轮未见的旧诊断键，观察到对应条目即移出；遍历完整、无deferred/暂停/属性读取缺口时可清理其余旧scan:file项，即使另一文件仍metadata失败。不得清理提交问题/未知结果/历史/存储行，也不得新增IO或全库文件集合；旧续体不能据此清除新问题。

停用/移除清除明细与现有内存状态；重新启用由扫描发现。重复扫描、旧回调，以及停用/移除后的迟到错误不能增加重复项或复活已清问题；复用既有身份/时序保护并用合成reader门闩验证，不新造调度机制。部分恢复不抹掉其他问题；全部恢复后退出问题摘要并回到原有阶段/启停状态。未知提交仍保留，不能因详情关闭、刷新或重扫而解除。

## 4. 准确原因与视频阶段

- `DirectoryEntry` 保留 public `failure: String?`，加可选 `failureCause: NSError?`（默认 nil）；真实 reader 保存原错误，engine 优先使用它。旧注入 reader 只有字符串时用中性未知原因，不能从字符串猜权限或网络。
- 属性读取失败时可能尚不知道条目是文件还是目录；阶段固定为“读取目录项属性”，人话主体用“目录项”，完整路径照实保留，不能凭扩展名说成文件损坏/目录损坏。保留既有 directoryTraversalComplete=false 安全门槛及问题kind，不据此推断后代消失。
- 来源目录既有分类保持；文件读取可根据明确 Cocoa/POSIX/underlying error 区分路径不可用、访问权限不足、网络连接中断。其 kind 仍是 file，不把文件错误送入来源退避。
- 视频元数据错误且无更明确系统原因：人话“视频元数据读取失败，具体原因尚无法确定。”；其他未知文件错误：“文件暂时无法读取，具体原因尚无法确定。”。移除现有无证据的“可能已损坏或没有权限”。不能根据 -11800/-12979 或扩展名认定损坏、缺解码器或不支持格式。
- 只给现有必需的 AVFoundation load 增加步骤记录：duration（读取时长）、creationDate（读取创建日期）、commonMetadata（读取公共元数据）、creationDate.stringValue（读取拍摄时间文本）。已执行到哪一步就记录哪一步；可选 tracks/naturalSize 的 `try?` 语义不变，不产生新增失败。
- 诊断保留完整路径、已知阶段、全部可取得的嵌套系统 domain/code/description；遍历 NSError 链要防环。日志亦保留这些信息，不只在 UI 有。不得任意截断成首条系统原因；不 dump 无关 userInfo 对象。
- 必需步骤失败仍抛错，无 MediaMetadata/成功/skipped 伪结果；健康兄弟继续。

## 5. 来源行与问题浮层

菜单/设置共用两行 SourceRowLabel。第一行路径保留现有 caption、颜色、头部省略和独立完整路径 help；第二行有问题时仅“发现 N 项问题”，不附加第二段文件数或原始错误。没有明细问题时保持原启停/阶段文字，目录恢复尚待确认时使用第3节中性状态。

第二行是可聚焦的原生无边框 Button，hover/点击/键盘均能打开同一原生 popover；辅助功能名称“查看来源问题详情，N 项问题”。不另添 info、不增加第三行。

浮层宽360pt，内容短时自然收缩，长时上限420pt并在内部 ScrollView 滚动（小屏再按可见高度收窄）。顶部来源完整路径和“当前未解决 N 项问题”。按“目录与连接”“读取与解析”“导入与提交”分组，空组隐藏；每项显示完整路径、准确人话、已知步骤、系统诊断。完整路径和长文件名/错误换行、可选择复制，不用 lineLimit 截断。组内路径排序仅影响详情，不影响处理次序。读不到更多根因时明确保留不确定性。

两类浮层复用一个局部通用 HoverDetailsButton：保留现有200ms打开/关闭延迟，按钮与浮层联合 hover 区，点击/Space/Return固定，Escape/外部点击关闭、焦点返回、消失取消任务。不写 model/store，不引入新的业务状态机。

## 6. 图库分析与同步详情

仍以 `SyncStatusPresentation(snapshot: snapshot).analysis` 为唯一的分析显示条件；ready 或无 indexProgress 时为 nil。主菜单、按钮辅助名称和浮层同时消费同一份 snapshot，不另查 Photos/数据库。

分析非nil时详情顶部插入“图库分析”组：

| 数据 | 显示 |
| --- | --- |
| analysis.title | “状态”行，preparing/updating/waiting/paused 的既有中文 |
| analysis.progressText | “进度”行，已知总数为“已分析 X / Y 张”；未知为“正在读取图库…” |
| analysis.detail | 非空时显示等待/异常原因；包括现有 iCloud 原文 |
| analysis.explanation | 保留已有说明 |
| 组脚注 | “统计 Photos 图库中的项目，与来源目录的文件数分别计算。” |

本轮不新增表示计数表：totalRepresentations/readyRepresentations/readErrorRepresentations/excludedAssets 不混入 X/Y、不推算 remainingAssets。零/未知总数不制造完成率。snapshot.isPaused 的全局标题优先级不改；分析组按现有 IndexProgress.state 显示，并以测试覆盖暂停前后同一快照的既有结果。

后续保留“已发现的文件”和“本次扫描”两组逐行统计；各组下紧接口径说明：

- 已发现的文件：“统计当前启用来源的记录，包含此前扫描。总量随新文件发现而增加。” retainedImported 单独附注，summaryError 保留。
- 本次扫描：“仅统计本轮扫描事件；文件读取失败与来源等待分别计数，不与上方记录数相加。” 保留本轮候选、新增、阶段、失败、来源等待及原时间。

详情宽300pt，内容增加后有界滚动，短内容自然收缩。分析时按钮名称“查看图库分析与同步详情”，其他时为“查看同步详情”。同一个浮层打开期间进度、原因、ready转换必须更新；ready后只移除分析组，入口继续存在且不强制关闭浮层。需保持入口SwiftUI身份（可调整父级进度容器），不能在 analysis/sync 分支之间销毁持有 presented 的按钮。下方两组不因分析出现而清零，也不嵌套 info。

## 7. 文件边界与文档关系

Core：SyncEngine.swift、DirectoryReader.swift、MetadataReader.swift，仅诊断捕获/现有问题保留/只读快照；允许新增小型明细值类型于 SyncEngine.swift。SyncRuntime.swift 仅在移除来源的现有清理路径同步删除新快照成员；不能改调度分支。

App：StatusMenu.swift、SyncProgressView.swift、SourceRowLabel.swift、SourceSettings.swift；SyncStatusPresentation.swift/AppModel.swift 只可增加必要纯投影。新增 HoverDetailsButton.swift 只封装两种详情共用的原生交互；新App文件同时加入App与hostless tests。

Tests：EngineTests/SourceReaderTests/SyncStatusPresentationTests/AppViewTests、需要的runtime恢复回归及Tests/UIReview。发布：Xcode版本配置、package-release、其合成Tools测试、README/CHANGELOG/0.2.2发行说明。

原 `2026-10-13-native-ui-polish-design.md` §4 的固定两组与 §5 的“读取失败 N 个”由本设计替代；该文件§2冻结Core/展示接口是旧轮次边界，本轮仅按上列必要范围解除，其他约束保持。运行时契约补充诊断口径，不将历史 schema v3文字改写为本轮新迁移。

## 8. 验证、审阅与发布

自动覆盖：A/B不同目录错误逐项恢复后primary只来自未解决成员；未知文件/目录类型的属性失败显示正确阶段且禁止删除推断；未落库坏文件A删除而B仍坏时仅清A，遍历不完整/属性失败/deferred/暂停及旧续体不得触发清理；多文件/多种/多目录混合；同文件扫描与提交两项；重试不累加；错误文本变化身份不变；部分/全部恢复；目录叶子全恢复但其他目录deferred时来源退避仍保持、无提前恢复通知；停用/移除、晚到回调及现有续体竞态；文件权限/路径/网络分类；四个视频必需阶段及系统链、损坏自制MPG仍报错、健康兄弟继续。

UI覆盖明暗、长Unicode路径、多错误滚动至尾、0/1/30来源；分析known/unknown/零总数/iCloud等待/暂停/异常/ready；打开浮层时更新与ready转换；同一资产数不同representation数不影响进度；summary/latestScan隔离。

用最终编译代码与隔离合成宿主生成真实原生菜单内容和**实际打开**的浮层PNG（明/暗），包括滚动首尾及进度转换。优先复用Tests/UIReview，捕获仅自己PID/windowID，不激活前台、不发全局按键，不静态拼图。离屏内容、普通原生审阅窗口与真正MenuBarExtra交互须分别标注。验证不得使用未公开AX开关、私有反射、全局权限改动或字符替换来制造通过；若使用Vision多候选，原样保存候选/置信度并严格匹配期望，结合独立语义/视觉证据，不称为原生AX验收。若宿主无法在不抢焦点下打开有效浮层/材质，保留失败证据、完成其他工作并交协调线程处理；不反复强行激活、不将宿主exit0标为产品通过。

审阅安排：原UI设计§8要求“生成真实截图…交用户验收…等待用户明确通过”。本轮协调线程补充说明：用户委托其与本线程交互到release，由它审看具体原生截图后判断是否满足本轮委托验收。因此将本轮截图和限制交协调线程，结果明确标为“协调代理审阅”，不冒称用户本人验收，不改写旧版本事实或自动复用旧截图为新结果。历史0.2.1接受仅复用于未变部分。

最终tester执行完整 `scripts/validate.py`（fresh输出和DerivedData），记录XCTest实际数量、跳过/失败、Tools、模型/LFS/fixture、四组规模及两项continuation GREEN/RED。最终集成diff由deep_reviewer审阅；等价覆盖不重复。最后产品/测试修改后完整验证；只读review不使验证失效。

发布候选0.2.2 stable/build10，先PR并attach，获必要审阅结论后squash到main，核对合并源码树，使用确切干净main执行package-release（归档内再次完整验证）。检查全部权重、Universal App/Core、版本/channel/build、图标、逐层ad-hoc签名、DMG、provenance及SHA256。新路径不得覆盖。GitHub资产沿v0.2.1惯例：PhotosYNC-0.2.2.dmg、PhotosYNC.provenance、RELEASE-NOTES.md、SHA256SUMS；发布清单与本地全目录清单分开，避免下载者校验不存在的本地App文件。tag必须指向实际main发行提交，发布后回读核实latest/资产哈希。

## 9. 协调线程重点审阅

1. 是否认可目录诊断逐项恢复、来源恢复标记保持完整遍历门槛；诊断0项时显示中性状态。
2. 仅展示资产进度，representation字段不额外扩展；三个组各自脚注是否准确。
3. 共享原生hover控件与保持入口身份是本次必要局部改动，无新业务状态。
4. 原生宿主/真正系统菜单/物理交互证据分别标注，实际截图后由协调线程处理人工验收结论。
