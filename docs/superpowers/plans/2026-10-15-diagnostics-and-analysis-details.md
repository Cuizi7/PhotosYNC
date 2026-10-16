# PhotosYNC Diagnostics and Analysis Details Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 来源行汇总所有当前问题并能查看完整诊断，图库分析详情与主菜单状态一致，完成0.2.2补丁发行。

**Architecture:** 扩展既有内存问题的诊断成员并投影到EngineSnapshot；保留来源恢复标记和调度消费者。UI复用原生hover交互，分析组消费既有analysis。无新存储、依赖、媒体支持或业务状态机。

**Tech Stack:** Swift/SwiftUI/AppKit、AVFoundation、XCTest；既有Python验证和zsh打包入口。

**Spec:** `docs/superpowers/specs/2026-10-15-diagnostics-and-analysis-details-design.md`（先读全文）。

**Status:** 2026-10-15协调线程已完整审阅并批准实际spec/plan，进入SDD；以下采用同消息明确的基线复用、Task3独立implementer和单次任务review收敛。

## Global Constraints

- 保持原生 SwiftUI/AppKit Button、Popover、ScrollView；最低 macOS 13，Universal arm64/x86_64，无新运行时依赖。
- 源严格只读，Photos 仅既有新增语义；不转码、不扩展视频兼容性，不吞解析错误继续导入，不变更判重/提交/恢复/调度决策或 schema v8。
- 使用合成来源、UUID 临时库与 fake/injected 状态；不读取生产视频、数据库、真实 Photos，不安装或启动生产 App，不改权限/登录项/通知设置。
- 当前工作树 `/Users/cuiziqi/.codex/worktrees/photosync-diagnostics-022/PhotosYNC`，分支 `codex/source-diagnostics-022`；禁止在主仓库main实施。
- 设计与实际计划已获协调线程明确批准；按SDD继续，不重复等待相同设计答复。不得自动变更历史UI验收事实。
- 三个开发任务顺序执行，每个fresh scoped implementer独占其范围，包括Task3的版本/打包脚本/测试fixture。控制器只负责文档台账、调度、审阅与PR/合并/打包/GitHub工具操作。任务1提供任务2的数据接口；不要并行修改共享文件。每任务一次合适深度完整review同时检查spec+quality，最后独立deep集成review。

## Review Focus

1. 目录A/B都恢复但C发生deferred/暂停：诊断叶子可为0，来源恢复标记和失败退避仍保留；任务1确定性runtime测试。
2. 同路径扫描/提交失败并存及旧续体晚回：不得错误合并、重复、复活；任务1受控门闩与原continuation测试。
3. 完整错误链/长Unicode路径在滚动尾部仍可读：任务1保真测试、任务2明暗原生布局及滚动测试。
4. 浮层打开时analysis→ready，SwiftUI条件分支不得销毁入口：任务2真实popover更新测试与截图。
5. Photos资产/表示/来源记录/本轮事件数同时不同：任务2独立数值断言；不得加总或推算剩余。

## 执行前准备（主代理/验证代理）

- [x] 协调线程已明确批准实际design/plan，消息来自 `01a0ce7b-c1db-70d3-a47d-34f56363ffe0`，并认可primary跟随剩余诊断、目录项属性阶段、0诊断待恢复三点；本次按其委托执行。
- [x] 核对worktree干净、分支及main基线；执行 `git lfs checkout` 仅恢复本checkout受控权重，缺本地对象时用已授权仓库LFS下载并校验，不复制QA数据。初始pointer已hydrate并完成资源校验；证据见台账baseline与work/022-baseline-resources.json。
- [x] 运行 `python3 scripts/advanced-dedup/release.py --resources "$PWD/Sources/PhotoSyncCore/Resources/AdvancedDedup" --output "$PWD/work/022-baseline-resources.json"`；必须验证真实权重而非pointer。先创建work目录。
- [x] 优先复用主目录 `outputs/releases/0.2.1/PhotosYNC.provenance` 及 `work/Archive/2026-10-15-worktree-cleanup-20261015T124806Z/worktrees/a60d/work/release-0.2.1.Q7OJM6/validation/` 的exact-main=1291b53完整基线。核实源码manifest（本轮仅新增设计文档）、日志/报告哈希、工具链、模型绑定等价；相同快照不再无条件全跑baseline。新worktree仍hydrate并校验资源，任务RED/GREEN仍运行。
- [ ] 仅发现真实环境/工具链差异使旧基线失效时，记录证据再用fresh路径执行完整baseline validate。最终集成完整validate与确切main归档打包的完整验证无条件保留。

### Task 1: 完整、准确且不改变恢复决策的来源诊断

**Files:**
- Modify: `Sources/PhotoSyncCore/Sync/SyncEngine.swift`（SourceIssue/EngineSnapshot附近、scanSource、问题设置/清理）
- Modify: `Sources/PhotoSyncCore/Sources/DirectoryReader.swift`
- Modify: `Sources/PhotoSyncCore/Sources/MetadataReader.swift`
- Modify: `Sources/PhotoSyncApp/SyncRuntime.swift`（仅移除来源的新快照成员清理）
- Test: `Tests/PhotoSyncCoreTests/EngineTests.swift`, `SourceReaderTests.swift`, `AdvancedRuntimeTests.swift`, `ScheduleTests.swift`
- Modify: `docs/specs/2026-09-18-runtime-state-and-recovery.md`（仅新增诊断明细口径）

**Interfaces:**
- Produces: `public struct SourceIssueDetail: Equatable, Sendable, Identifiable { id: String; kind: SourceIssueKind; path: String; summary: String; stage: String?; detail: String }`，公共init覆盖全部字段。
- Produces: `EngineSnapshot.sourceIssueDetails: [UUID: [SourceIssueDetail]] = [:]`；每来源确定性排序，empty时移除key。
- Preserves: `waitingSources: [UUID: SourceIssue]` 与 `sourceFileIssueCounts` 原本业务含义；公开SourceIssue init不破坏现有调用。
- Adds: `DirectoryEntry.failureCause: NSError?`，现有initializer末尾追加默认nil；`failure: String?`保留。NSError仅作诊断，不使用unchecked标记来绕过新的并发问题。
- Internal: `TrackedSourceIssue { primary: SourceIssue; diagnostics: [String: SourceIssueDetail] }`，保留既有槽位键；诊断ID按spec§3。
- Internal: `VideoMetadataStage`四个case：duration/creationDate/commonMetadata/creationDateStringValue；`MetadataReader.videoMetadataError(_:stage:) -> NSError`（stage可nil以兼容当前调用），小型stage包装函数供现有load共用和测试。

- [x] **Step 1: 写失败测试。** 新增 `testSourceIssueDetailsPreserveMixedDirectoriesFilesAndSubmission`：两个失败目录、两个文件和同一路径提交问题，断言全部id/path/kind/原因与总项数，不用summary文本作id。`testDirectoryPrimaryFollowsRemainingDiagnostic`：A权限拒绝、B网络中断，两项并存后A恢复，primary必须来自B的完整summary/detail；B恢复但遍历未完则为中性原因且kind不变，通知/日志不再引用A。`testRepeatedIssuesUpdateWithoutAccumulating`：同键同错/换错均不增加，局部恢复只移除命中项，最终清空；`testDirectoryDiagnosticRecoveryKeepsSourceRecoveryUntilCompleteTraversal`：A/B错误→A成功/B错误→A/B成功而C门闩deferred/暂停→完整遍历，分别断言诊断集合、waitingSources类型、通知数、来源backoff与deferred独立。不靠随机sleep。
- [x] **Step 2: 写迟到、已删除诊断与错误保真失败测试。** `testDeletedUnrecordedScanIssueClearsWhileSiblingStillFails`：A/B新文件metadata失败均无file_record，下一完整轮A缺失B仍坏，assert仅A诊断/数量消失，B与提交未知/存储不变；覆盖目录失败、属性失败、deferred、暂停、旧续体的不清理分支。先复现原缺陷，记录明确根因。 `testLateIssueCannotReviveDisabledOrRemovedSource`、`testRecoveredIssueIsNotRepublishedByOlderContinuation`（复用已有门闩/ContinuationRegression，不另建框架）；SourceReader的 `testEntryAttributeFailurePreservesSystemCause` 注入Cocoa/POSIX underlying链并验证健康兄弟保留；未知条目类型时assert“读取目录项属性”阶段、主体“目录项”、不猜损坏/类型，目录遍历不完整且不移除未见pending后代；`testVideoMetadataFailureReportsExactRequiredStage` 对四阶段同一包装路径抛合成错误，assert stage+完整多层domain/code/description；`testFileDiagnosticClassifiesKnownCauseWithoutGuessingUnknownVideo` 覆盖权限/不存在/网络/未知-11800链。保留真实自制坏MPG读取失败测试。
- [x] **Step 3: 运行RED并保留输出。** `xcodebuild -project PhotoSync.xcodeproj -scheme PhotoSync -destination 'platform=macOS' -derivedDataPath work/022-focused CODE_SIGNING_ALLOWED=NO build-for-testing > work/022-task1-red-build.log 2>&1`，缺新接口的编译错误或新增断言失败为预期。已有bundle运行可用 `xcrun xctest -XCTest PhotoSyncCoreTests.EngineTests work/022-focused/Build/Products/Debug/PhotoSyncCoreTests.xctest`；验证命令与当前bundle真实test标识相符，零测试不是RED证据。
- [x] **Step 4: 最小实现诊断保留。** 改私有sourceIssues值，所有问题产生点填入已有路径/步骤；目录失败合并诊断成员，不覆盖其他目录；成功entries只清对应成员/日志签名并刷新明细，完整遍历才走既有清槽位路径。每次目录成员增删后按路径/身份从仍未解决成员确定primary，summary/detail保持同一成员；禁止继续引用已恢复项。成员全空但标记仍在时primary使用“等待确认来源恢复”，detail说明等待完整遍历，不生成诊断项。仅对已证明删除的旧scan:file诊断补清理：本轮仅跟踪未见的旧诊断键，已见即移除候选；已有完整遍历事实且无deferred/暂停/属性缺口才清未见项，不能新存全库路径集合/新IO/DB，也不改提交问题/未知结果/历史/存储行/来源退避。停用/移除/clean-scan/单文件恢复同步清理；不改finishedRound、ScanSchedule、store或提交路径决策。读取后遵守canScan及现有防晚回检查。
- [x] **Step 5: 实现原因与步骤保真。** DirectoryReader填failureCause，engine优先使用原cause；属性失败stage固定“读取目录项属性”，无法确定file/directory时使用“目录项”主体，保持遍历不完整安全门槛；准确分类仍保留原kind。每个必需视频load使用标注阶段包装，可选尺寸load保持try?；完整NSError链含每层描述/代码并防环，UI与日志共享可读诊断。阶段未知就nil，不从扩展名或错误代码猜根因。文案严格按spec§4。
- [x] **Step 6: GREEN和规格/质量review。** 重建同derived数据后运行完整EngineTests、SourceReaderTests及受影响Runtime测试；须验证 `testUnreadableVideoKeepsFileFailureWhileHealthySiblingImports`、`testUnreadableMetadataLeavesNoRecordAndRecoversNextScan` 和目录/文件恢复/日志去重现有测试。对新增接口+恢复边界使用一次deep任务review同时检查规格与质量；只修范围内发现，记录不可接受风险。提交 `fix: preserve complete source issue diagnostics`。

### Task 2: 来源问题hover和随状态更新的图库分析详情

**Files:**
- Modify: `Sources/PhotoSyncApp/{StatusMenu,SyncProgressView,SourceRowLabel,SourceSettings}.swift`
- Create: `Sources/PhotoSyncApp/HoverDetailsButton.swift`
- Modify if needed for pure projection: `Sources/PhotoSyncApp/{SyncStatusPresentation,AppModel}.swift`
- Modify: `PhotoSync.xcodeproj/project.pbxproj`（新App文件同时加入hostless tests，不能加入Core）
- Test: `Tests/PhotoSyncCoreTests/{AppViewTests,SyncStatusPresentationTests}.swift`
- Modify: `Tests/UIReview/{ReviewFixtures,ReviewHost}.swift`、`run-ui-review.sh`（仅新场景/真实浮层更新及捕获）
- Modify: `docs/superpowers/specs/2026-10-13-native-ui-polish-design.md`（§2/4/5仅交叉引用本轮变更）

**Interfaces:**
- Consumes: Task1的`sourceIssueDetails`；既有`SyncStatusPresentation(snapshot:).analysis`。
- Produces: `SourceRowLabel(url: URL, status: String, issues: [SourceIssueDetail] = [], recoveryPending: Bool = false)`；问题为0时原状态，目录恢复未确认时中性状态。删除其旧fileIssueCount驱动的第二段计数；调用方/合成fixture一起更新。
- Produces: `SourceIssuesContent(sourceURL: URL, issues: [SourceIssueDetail], recoveryPending: Bool)`，纯只读分组/渲染，所有诊断来自传入值。
- Produces: `HoverDetailsButton<Label: View, Content: View>(accessibilityLabel: String, accessibilityIdentifier: String, @ViewBuilder label: () -> Label, @ViewBuilder content: () -> Content)`，持有现有hover/pin/focus状态，200ms规则不变。
- Preserves: `SyncDetailsContent(snapshot: EngineSnapshot)` 和 `SyncDetailsButton(snapshot: EngineSnapshot)`；后者使用通用原生控件且上下文名称动态变化。

- [x] **Step 1: 写RED展示与原生布局测试。** `testSourceRowShowsOneProblemSummary`断言只“发现 5 项问题”、两行、无读取失败计数重复；`testSourceDetailsGroupCompletePathsAndCauses`断言三组、五项、同文件两项与空组隐藏；`testLongSourceIssuesScrollWithoutTruncatingFinalItem`用20项长Unicode路径/原因，明暗宽360/高≤420、滚动尾可达。`testRecoveryPendingDoesNotInventIssueCount`：零明细只显示中性状态。
- [x] **Step 2: 写RED分析与更新测试。** `testAnalysisDetailsUseSameAssetProgressAsMenu` 用readyAssets=2192,totalAssets=15702，但表示数/summary/scan均不同，assert两处文本一致且没有混用；`testAnalysisDetailsCoverUnknownZeroWaitingPausedAndReady` 覆盖每种状态/原issue/三个脚注，分析脚注精确为“统计 Photos 图库中的项目，与来源目录的文件数分别计算。”；`testOpenDetailsUpdateAndRemainOpenWhenAnalysisBecomesReady`在单个原生宿主打开实际popover，向同一model发布新snapshot，验证进度更新、ready移除“图库分析”但下两组和popover保留、辅助名称回到“查看同步详情”。不以重新实例化静态详情证明动态更新。
- [x] **Step 3: 最小原生交互复用。** 将SyncDetailsButton现有状态/任务原样迁入HoverDetailsButton，两个入口用同一交互；来源第二行用button承载，路径help仍是独立目标。SourceIssuesContent按spec§5渲染并有界ScrollView，路径/诊断可选择、不截断。所有调用方和ReviewFixtures改用真实明细，不能用计数补造虚构错误。
- [x] **Step 4: 实现分析组及稳定入口。** SyncDetailsContent用既有analysis在顶部加入spec§6的状态/进度/原因/说明/脚注；三组分别标范围，300pt有界滚动。StatusMenu进度区将唯一SyncDetailsButton保持在analysis/sync条件分支之外的稳定结构中；调整LibraryAnalysisView/SyncProgressView的摘要与图形分工，避免复制交互或多个info，保留292pt内容宽、原生字号、原状态优先级和no-source可达入口。恢复ready时不重置presented。
- [x] **Step 5: GREEN及任务review。** 重建并运行AppViewTests、SyncStatusPresentationTests、现有AppModelTests；覆盖0/1/30来源、明暗、原操作/disabled/键盘映射。新原生文件必须在实际App与测试都编译。一次SDD完整任务review同时检查规格与质量，通过后提交 `fix(ui): align source and library analysis details`。
- [x] **Step 6: 产出可审阅真实UI证据。** 扩展现有ReviewHost识别新详情按钮，不沿用失效硬编码坐标。`Tests/UIReview/run-ui-review.sh --derived-data "$PWD/work/022-focused" --output-dir "$PWD/work/022-ui-static"`取得主体；`--probe`用另一fresh目录取得本进程实际浮层。合成场景包括混合问题、20项滚动首尾、analysis known/unknown/waiting/paused和opened→ready，明暗各一套。用已有权限的自己窗口捕获，记录commit/diff、PID/windowID、尺寸/场景、原生popover发现/实际内容/结果；不激活、无全局输入。静态详情拼接或透明异常材质不能充当成功。环境不足时交协调线程具体失败证据，不擅自改权限。
- [x] **Step 6a: 协调批准的一次前台取图。** 常规非激活捕获已产生CG窗口仅1×2的具体证据后，协调线程明确授权spec§8的单次合成ReviewHost受控激活（≤30秒）。保留原frontmost、自己的PID/window/尺寸和明暗/滚动/动态原图；用户切走即停、不抢回，条件恢复原App，无全局输入或权限改动。仅测试宿主入口支持此模式，默认验收路径不激活；控制器核对一次性/恢复边界后执行，不需重复询问授权。
- [x] **Step 7: 交协调线程截图审阅。** 给原始PNG/图册/已披露局限；按收到的范围内修订更新截图和相关验证。记录结论为“协调代理审阅”，不得改写旧版本人工结论或称用户本人验收。由协调线程判断其本次委托的验收条件。


执行注：早期3df233d的受控会话因原前台为loginwindow而零截图，失败证据保留。用户明确告知已解锁后，按协调线程新授权取得14张真实原图，覆盖混合诊断、两色长列表首尾及同一浮层分析进度到ready转换；浅色材质另以获准的一次v3会话取得同popup的A/B原图。协调代理于2026-10-16直接审阅上述原图及独立ICC审计，通过本轮新增内容的原生UI验收；这是协调代理审阅，非用户亲自验收。v3原manifest因NSBitmapImageRep采样颜色空间解释保持unverified，补充审计按原PNG嵌入ICC、原四角及原8/255阈值通过，不覆盖原失败或冒称未到达的末尾断言通过。物理hover/focus/VoiceOver、真实MenuBarExtra及全显示器背景真实性未新增验证。详细边界见本轮validation记录。Task2独立代码review的SPEC/QUALITY已通过，无P0–P2发现。

### Task 3: 0.2.2发行配置与集成交付（scoped implementer + 主代理协调）

**Files:**
- Modify: `PhotoSync.xcodeproj/project.pbxproj`（所有现有配置0.2.2/build10）
- Modify: `scripts/package-release.sh`（release_name、版本/build断言、notes/provenance，仅必要替换）
- Modify: `Tests/Tools/test_release_validation.py`（对应打包fixture版本/锁/路径，不改失败门槛）
- Modify/Create: `README.md`, `CHANGELOG.md`, `docs/release/0.2.2.md`, `docs/release/2026-10-15-diagnostics-and-analysis-validation.md`

**Ownership:** scoped implementer仅承担Step1版本、打包脚本、测试fixture与发行文档；主代理在其一次完整spec+quality review通过后负责Step2–8验证调度和外部工具操作，不自行编辑产品/测试。

**Interfaces:** 使用既有 `scripts/validate.py` 与 `scripts/package-release.sh`，不得增加skip/cache-success通道；输出新目录`outputs/releases/0.2.2/`。

- [x] **Step 1: 发行准备。** 再查远端main/tag/releases防版本冲突；若0.2.2已占用先向协调线程报告，不覆盖。按上述文件更新0.2.2 stable/build10，写两项修复/无视频扩展/无迁移/实机与签名限制。Python测试改动前读取python-development-guidelines。跑 `python3 -m unittest discover -s Tests/Tools -p test_release_validation.py`，确认新版本fixture及失败拒绝门槛；提交 `release: prepare PhotosYNC 0.2.2 stable`。
- [x] **Step 2: 最终tester验收。** 专属tester执行 `python3 scripts/validate.py --output-dir "$PWD/work/022-integrated-validation" --derived-data "$PWD/work/022-integrated-derived" > "$PWD/work/022-integrated-validation.log" 2>&1`。读取完整validation.json、报告与日志，列XCTest数/跳过/失败、Tools、权重/model、scale四组、两个continuation、源码manifest前后一致。失败不得绕过；修复后重跑必要完整验收，路径唯一。
- [x] **Step 3: 最终集成deep_reviewer。** 审base `1291b53`→当前全部diff及spec/plan/验证/UI证据，重点接口/actor恢复边界、阶段错误不改变媒体规则、浮层生命周期、发布配置。高严重性无遗留、中严重性解决或有协调线程明确接受。只读review不重跑相同快照测试；新增修复按影响复核、最后行为变更完整验证。
- [x] **Step 4: PR。** 协调线程明确允许自动验收与代码review通过后创建披露真实popup关卡未过的draft PR；该关卡继续阻断merge/tag/release。push本轮分支；用临时body文件写清两项问题、行为、验证和限制，再 `gh pr create --repo Cuizi7/PhotosYNC --base main --head codex/source-diagnostics-022 --draft --body-file <file>`。创建后立即 `attach_artifact`。检查远端diff/checks/mergeability；base有变化则先评估集成和对应验证，不盲合并。
- [ ] **Step 5: squash merge main。** 完成协调截图审阅和上述门槛后按已授权范围 `gh pr merge <PR> --squash`；fetch/pull主仓库仅fast-forward、先确认干净且无别人在改，不删除历史work/stash。记录真实main提交并比较合并tree与已审源树（文档和版本亦说明），复用同快照review不重复审批。
- [ ] **Step 6: 从确切main打包。** 主仓库clean main执行 `scripts/package-release.sh`；它在精确git archive内重新全验收再Universal Release。确认LFS完整权重、app/Core双架构、0.2.2/stable/10、图标、嵌套签名、DMG verify、local SHA256SUMS、provenance source_commit/manifest/validation hashes全部吻合。目录已存在或锁冲突就停止，不覆盖、不清他人锁。
- [ ] **Step 7: GitHub stable release。** 创建v0.2.2标签绑定main实commit，先确认远端无冲突。在独立work分发目录准备DMG/provenance/RELEASE-NOTES及只覆盖这三文件的下载SHA256SUMS；本地包完整校验表不改。用`gh release create v0.2.2 ... --verify-tag --latest --title 'PhotosYNC 0.2.2' --notes-file <notes>`上传四项既有惯例资产；无draft/prerelease。若上传结果未知先回读，避免重复。回读release/tag/assets，下载到独立临时目录验证哈希后报告。
- [ ] **Step 8: 交付。** 报PR、main/tag、release链接、DMG SHA256、provenance、自动验证计数、协调代理原生UI审阅证据；分列构建/自动测试/GUI/真实Photos未新增/平台实机未做/ad-hoc未公证。保留所有旧发布与QA证据；不安装/启动生产App。

## 自检与交接

需求映射：Task1覆盖spec§3–4，Task2覆盖§5–6与截图，Task3覆盖§8发行。Review Focus五项各有具名测试。新增文件仅共享hover责任，Core新增类型留在既有文件；不拆分/重构其他模块。

设计方向已由协调线程审阅通过；本计划将其指定的目录primary跟随剩余成员、未知目录项属性阶段两点落实为Task1测试与实现要求。Task2稳定入口也列为验收点；若实现发现必须改调度/存储或更大架构，暂停相关修改并报告具体差异，不改设计自授权。基线按协调要求优先核验复用；截至2026-10-16，Task1/2代码及各自独立审阅已完成；具体RED/GREEN和运行次数见台账。Task3发行配置与scoped review已完成；完整canonical于125ada6通过（627 XCTest含2项明确跳过/0失败、97 Tools、固定33例模型、四组规模、两项续体GREEN/预期RED，manifest前后一致）。此后的文档结果更新不冒称重新执行过测试；最终exact-main归档验收仍保留。最终deep代码review及111项验证证据补核已完成，无P0–P2；P3自定义gateway阶段边界由协调线程接受。PR #3已创建并附带本轮验证记录。新增原生UI内容已由协调代理审阅通过，保留上述明确局限；同一deep reviewer仅补核最终文档和新增证据边界。产品/tests/Core未变，不重复分支整套suite；PR ready/squash、exact-main归档全验收/Universal打包、v0.2.2 stable/latest四资产发布及下载校验按已授权顺序执行，实际结果由main/package provenance及交付记录绑定。
