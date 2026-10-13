# PhotosYNC Native UI Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现用户确认的原生菜单/设置定稿，以已发现记录的分段进度、悬浮详情和两行目录简化展示，并交付实现后的真实 UI 截图供用户人工验收。

**Architecture:** 继续使用现有 `AppModel` 和不可变 snapshot 输入，视图仅做只读算术与局部布局/交互。增加进度/详情和来源行两个小型视图文件；不引入新 ViewModel，不改变 model/runtime/Core。现有 hostless 测试覆盖回归，测试专用原生 host 负责截图和瞬态浮层验收。

**Tech Stack:** Swift 5 language mode、SwiftUI/AppKit、macOS 13+、Xcode project、XCTest；无新增依赖。

**Spec:** [2026-10-13-native-ui-polish-design.md](../specs/2026-10-13-native-ui-polish-design.md)（必须与本计划一起阅读，包含定稿图、公式、显隐和人工验收约束）。

## Global Constraints

- 最低 macOS 13；使用原生 SwiftUI/AppKit，不增加第三方运行时依赖。
- 只改视图、只读的视图计算、视图局部交互状态和对应测试；不修改后端逻辑或接口。
- 冻结 `AppModel.swift`、`SyncStatusPresentation.swift`、`SyncRuntime.swift`、`PhotoSyncApp.swift`、整个 `Sources/PhotoSyncCore/`、数据库 schema、权限调用、扫描/调度/判重/提交/恢复逻辑。
- 保留现有 action、Binding setter、disabled 条件、快捷键、来源顺序/身份、移除确认语义、系统刷新时机和窗口高度回调；不增加重试、清库、删除文件或独立分析控制。
- 菜单宽 320pt；状态区沿用当前屏幕自适应上限（最多 440pt），操作区固定在外；设置宽 600pt、内容高不超过 680pt、短内容自然收缩。
- `MenuBarExtra(.window)` 与 macOS 13 设置窗口兼容路径不变；菜单不是新独立窗口。
- 只使用合成来源描述、UUID 临时库和现有 injected AppModel；不访问真实 Photos/生产数据库/真实来源，不启动生产 App，不修改权限、登录项或通知设置。
- ImageGen 原型、自动测试、真实 UI 截图和用户人工验收分别记录；用户确认前不得宣布前端验收完成。

## Review Focus

人工验收反馈第 1 轮：修正等宽主按钮与有分隔线的纯文字次操作；分析计数和 info 在条上、删除重复小标题；详情扫描改为对齐的名称/值行。重做受影响明暗截图与原型对照，异常系统材质图不得标为视觉通过。保留此前目录统一 caption 字号修订与全部冻结范围；最后代码再次运行完整 canonical 验证。首次送验未通过，用户确认仍为必需关卡。

1. pending/importing/retryPending、退役历史和本轮计数混合时分母仍只用活动来源互斥状态；Task 1 固定 `150/200` 及新增记录后的回退测试。
2. nil/0/过期汇总、满条但来源失效/提交未知时不得假装完成或显示最新统计；Task 1 加状态/尺寸用例，Task 4 对照实际渲染标题和警告。
3. Unicode/根路径/超长末级名称和设置按钮挤占宽度时仍只有两行，完整路径可取；Task 2 测单行边界，Task 4 用真实 tooltip 截图验收。
4. 30 来源加长授权/通知/错误提示时不裁掉固定设置或形成高度反馈循环；Task 2 测紧凑与上限，Task 4 检查列表顶/底和极端提示。
5. hover 跨入 popover、键盘关闭与原按钮使能在边界状态下不能闪烁/丢焦点/改动作；Task 3 的原生 host 实际触发，Task 4 留交互及焦点截图，reviewer 逐项对照基线绑定。

---

## 文件与职责（执行时的白名单）

| 文件 | 责任 |
| --- | --- |
| Create `Sources/PhotoSyncApp/SyncProgressView.swift` | 只读进度指标、分段条、详情 Button/popover；均为 app 内部视图类型 |
| Modify `Sources/PhotoSyncApp/StatusMenu.swift` | 消费新控件，重排摘要与操作；现有状态/动作不变 |
| Create `Sources/PhotoSyncApp/SourceRowLabel.swift` | 菜单/设置/demo 共用路径和状态两行标签 |
| Modify `Sources/PhotoSyncApp/SourceSettings.swift` | 来源区域独立滚动、权限/提示靠前、常用选项与诊断保留可达 |
| Modify `Tests/PhotoSyncCoreTests/AppViewTests.swift` | 数值、尺寸、混合状态测试；拓展当前离屏捕获 |
| Create `Tests/UIReview/ReviewFixtures.swift` | 仅测试/审阅 host 编译的确定性合成状态，既不扫描也不 bootstrap |
| Create `Tests/UIReview/ReviewHost.swift` | 独立原生审阅入口，承载实际产品视图；不进入 app 或 Core target |
| Create `Tests/UIReview/run-ui-review.sh` | 编译/启动上述独立 host，保存截图/manifest，不执行生产入口 |
| Modify `PhotoSync.xcodeproj/project.pbxproj` | 只登记上述 app 文件到 PhotoSync 与 CoreTests、fixture 到 CoreTests；不得加入 Core 或改构建/版本/权限配置 |
| Create `docs/release/2026-10-13-native-ui-acceptance.md` | 自动验证、截图、用户结论的独立记录；未取得用户结论保持待验收 |

文档/定稿已在当前 checkout；实施前使用 worktree 技能检查并复用合适的隔离工作树，建 `codex/native-ui-polish` 分支，保留本轮文档和图。当前 HEAD 是 detached `f467ed4`，不能据此认为已在实现分支；不额外复制工作树或丢失未提交文档。

## 聚焦验证命令

每次行为/测试修改后先重新构建；不能用旧 bundle 跑出 GREEN。工具缓存权限失败走正常工具审批，不改变系统配置。

```bash
mkdir -p work/ui-polish
xcodebuild -project PhotoSync.xcodeproj -scheme PhotoSync \
  -destination 'platform=macOS' -derivedDataPath work/ui-polish-derived \
  CODE_SIGNING_ALLOWED=NO build-for-testing > work/ui-polish/build.log 2>&1
```

仅构建 exit 0 后运行：

```bash
xcrun xctest -XCTest 'PhotoSyncCoreTests.AppViewTests' \
  work/ui-polish-derived/Build/Products/Debug/PhotoSyncCoreTests.xctest \
  > work/ui-polish/views.log 2>&1
xcrun xctest -XCTest 'PhotoSyncCoreTests.SyncStatusPresentationTests,PhotoSyncCoreTests.AppModelTests' \
  work/ui-polish-derived/Build/Products/Debug/PhotoSyncCoreTests.xctest \
  > work/ui-polish/contracts.log 2>&1
```

命令成功条件：退出码 0、`Selected tests` 正常结束、实际测试数大于零、0 failures；测试类前加模块名，不能接受过滤错误造成的零测试。RED 必须是新断言或缺少正在新增的类型所致，工具/资源故障不是有效 RED。

### Task 1: 菜单分段进度与详情入口

**Files:** Create `Sources/PhotoSyncApp/SyncProgressView.swift`; modify `Sources/PhotoSyncApp/StatusMenu.swift:5`、`Tests/PhotoSyncCoreTests/AppViewTests.swift:6`、`PhotoSync.xcodeproj/project.pbxproj`。

**Interfaces:**

- Consumes：现有 `EngineSnapshot`、`SyncStatusSummary`、`AppModel.statusDescription/status/analysis/counters/scanDescription/recoveryAdvice`，不修改签名或返回规则。
- Produces：`SyncProgressMetrics.init?(summary: SyncStatusSummary?)`；只读 `known: Int`、`processed: Int`、`incomplete: Int`、`importedFraction/skippedFraction/incompleteFraction: Double`；nil 输入返回 nil，known=0 的各 fraction 为 0。
- Produces：`SyncProgressView(summary: SyncStatusSummary?, stale: Bool)`、`SyncDetailsButton(snapshot: EngineSnapshot)`、`SyncDetailsContent(snapshot: EngineSnapshot)`。内含局部私有色段视图和 hover 状态，不构建业务 adapter；后三者均为 SwiftUI View。

- [x] **Step 1: 写失败用例，锁定公式与未知状态。** 在 `AppViewTests` 新增以下测试（下列为核心断言，测试方法名固定）：

```swift
func testProgressCountsAllUnfinishedStatesButNotHistoryOrRoundEvents() throws {
    let summary = SyncStatusSummary(imported: 120, skipped: 30, pending: 40,
        importing: 1, retryPending: 9, retainedImported: 500)
    let p = try XCTUnwrap(SyncProgressMetrics(summary: summary))
    XCTAssertEqual(p.known, 200)
    XCTAssertEqual(p.processed, 150)
    XCTAssertEqual(p.incomplete, 50)
    XCTAssertEqual(p.importedFraction, 0.6, accuracy: 0.000001)
    XCTAssertEqual(p.skippedFraction, 0.15, accuracy: 0.000001)
    XCTAssertEqual(p.incompleteFraction, 0.25, accuracy: 0.000001)
}
func testProgressNilZeroAndDiscoveryGrowth() throws {
    XCTAssertNil(SyncProgressMetrics(summary: nil))
    let zero = try XCTUnwrap(SyncProgressMetrics(summary: SyncStatusSummary()))
    XCTAssertEqual(zero.known, 0)
    XCTAssertEqual(zero.importedFraction + zero.skippedFraction + zero.incompleteFraction, 0)
    let grown = try XCTUnwrap(SyncProgressMetrics(summary:
        SyncStatusSummary(imported: 120, skipped: 30, pending: 249, importing: 1)))
    XCTAssertEqual(grown.known, 400)
    XCTAssertEqual(grown.processed, 150)
    XCTAssertEqual(grown.importedFraction + grown.skippedFraction, 0.375)
}
```

  同步扩展 `testProgressPreservesBlockingHeadlineAndStaleSummary`：构造 imported=200、其余=0，分别添加来源不可用与 unknown blocker，断言 model 标题仍为“等待恢复”/“需要处理错误”，渲染菜单；summaryError 存在时旧计数不消失，记录对应截图用例。新增 `testProgressLargeCountsAndAnalysisStatesRemainBounded`，输入 imported/skipped/pending 各999999、importing=3、retryPending=4、retainedImported=5；断言 known=3000004、processed=1999998，明暗菜单保持320pt和高度上限，进度摘要不截断。

- [x] **Step 2: 跑构建与聚焦测试，确认 RED 原因。** 使用前述命令，记录新断言/缺失新类型失败。不能删掉旧保护性测试来取得 RED/GREEN。

- [x] **Step 3: 实现新视图并接入菜单。** 指标只使用 spec §3 的五个互斥状态；6pt 轨道，accentColor / secondaryLabelColor / quaternaryLabelColor，同一外层裁切；零段不占宽。新 Button 的 hover 200ms / 离开联合区域200ms、点击保持、Escape/外部关闭行为按 spec §4，取消过期 UI Task，关闭恢复焦点。详情保留退役历史、统计错误、扫描失败/时间等全部既有信息。

  `StatusMenu` 继续用同一 model 的标题/符号/可见问题；分析非 nil 时保留 `LibraryAnalysisView` 并统一 accent tint，同步分段条仅在其余状态且有启用来源时显示。ⓘ 在两种阶段均可达。将扫描/暂停置于一行，设置/退出置于次行；两个设置兼容分支均改“设置”。逐字保留原动作、disabled 表达式和 quit 快捷键。保留 `photosync-status`、`sync-counters`、`scan-now`、`toggle-pause`、`open-settings` 等标识，新加 `sync-progress`、`sync-details`、`sync-details-content`；`sync-counters` 标识新的同口径摘要，不保留隐藏的旧重复行。

  调整旧 `testCompactAnalysisAndCountersFitNativeMenu` 的外观断言：旧三计数不再要求主界面常驻，但数字必须在详情完整可取，iCloud 固定提示仍单行，图库分析的可见性和状态测试保留。这不是修改 `SyncStatusPresentation`。

- [x] **Step 4: 重建、运行 AppViewTests 和既有 contracts 测试到 GREEN。** 增加进行中/暂停/未授权/未配置等动作使能对照表到验收记录草稿，review 时核对前后绑定；不要为 UI 测试开放 AppModel 私有 setter。
- [x] **Step 5: 提交本任务。** `git add Sources/PhotoSyncApp/SyncProgressView.swift Sources/PhotoSyncApp/StatusMenu.swift Tests/PhotoSyncCoreTests/AppViewTests.swift PhotoSync.xcodeproj/project.pbxproj`，`git commit -m "feat(ui): simplify sync progress and reveal scoped details"`。

### Task 2: 两行来源显示与设置页局部滚动

**Files:** Create `Sources/PhotoSyncApp/SourceRowLabel.swift`; modify `Sources/PhotoSyncApp/StatusMenu.swift`、`Sources/PhotoSyncApp/SourceSettings.swift`、`Tests/PhotoSyncCoreTests/AppViewTests.swift`、`PhotoSync.xcodeproj/project.pbxproj`。

**Interfaces:**

- Consumes：Task 1 菜单结构；现有 `RegisteredSource.url`、来源问题/阶段、`fileIssueCount(for:)` 和全部设置绑定。
- Produces：`SourcePathLabel(url: URL)`；`SourceRowLabel(url: URL, status: String, detail: String? = nil, fileIssueCount: Int = 0)`，仅包含文件夹图标及两行信息，不拥有来源按钮/action。
- 保持 `SourceSettings(model:)`、静态600/420/680尺寸常量、`model.settingsContentHeightDidChange(_:)` 调用关系不变。

- [x] **Step 1: 添加失败的布局用例。** 在已有 `measure` 测试 helper 增加 `minimumHeight: CGFloat = 100` 参数，小组件测量时传0；仍要求多次布局收敛，不靠固定 sleep 判定。

```swift
func testSourcePathStaysOneLineAtConstrainedWidths() throws {
    let paths = ["/", "/照片/旅行", "/Volumes/非常长的父目录/2026/旅行照片",
        "/家人/旅行👨‍👩‍👧‍👦/假日e\u{301}", "/照片/" + String(repeating: "很长末级目录", count: 20)]
    for path in paths {
        for width in [CGFloat(180), 292, 360] {
            let size = try measure(SourcePathLabel(url: URL(fileURLWithPath: path))
                .frame(width: width), width: width, minimumHeight: 0)
            XCTAssertEqual(size.width, width, accuracy: 1)
            XCTAssertLessThanOrEqual(size.height, 20)
        }
    }
}
```

  新增 `testSourceRowKeepsFileFailureCountInTwoLines`：292pt 宽，长中文 status + fileIssueCount=7，明暗渲染高度≤42pt；静态测量之外，后续人工验证数量和完整 tooltip。新增 `testSettingsSourceViewportBoundsThirtyMixedSources`：0/1/30来源，30来源夹杂停用、登录待批准、长错误，600pt宽和≤680pt高；比较短列表自然收缩。为列表上下滚动位置的固定“同步选项/诊断”留下截图夹具，不能只断言总高度就称固定位置通过。

- [x] **Step 2: 执行聚焦 RED。** 按统一命令重建，核对新类型/断言失败；记录当前三行来源或整页长滚动的基线图作为前后比较。
- [x] **Step 3: 实现并接入共享行与设置结构。** 单个 rich `Text` 将 prefix `.caption/.secondary` 与 basename `.caption/.primary` 拼在同一基线，整行字号和字重一致，仅通过颜色突出末级（2026-10-13 用户实施中修订），`.lineLimit(1).truncationMode(.head)`；不把 path 拆成多个相互争宽的 HStack Text。单独对路径 `.help(url.path)` 和完整 accessibility label；第二行单行状态，fileIssueCount>0 时同一行尾部保留“读取失败 N 个”，状态先截断，完整摘要/raw detail 在 help 可取。菜单、设置、demo 三处共用，保留来源顺序和现有问题/阶段选择。

  设置改为顶部状态/权限 → 独立来源标题与受限列表 → 同步选项 → 诊断/版本。列表最高280pt，并用静态区实测高度缩小，正常30来源不推走底部；极长静态内容按 spec §6 退回外层有界滚动。同一权限说明只在顶部出现，其他错误及关闭动作不能丢。保留 onAppear 系统刷新、confirmationDialog、pendingRemoval 生命周期、各按钮 disabled 与 identifier；高度回调只在实际变化时触发，避免测量环。
- [x] **Step 4: 重建并跑聚焦 GREEN。** 既有 AppModel/SyncStatusPresentation 测试必须保持通过。仅因用户明确变更的视图结构更新测试，不能放宽680pt上限或移除未知提交/历史保护断言。
- [x] **Step 5: 提交。** 暂存本任务列出的5个文件，`git commit -m "refactor(ui): unify source rows and bound settings scrolling"`。

### Task 3: 集成验证与真实 UI 证据产出

**Files:** Create `Tests/UIReview/ReviewFixtures.swift`、`Tests/UIReview/ReviewHost.swift`、`Tests/UIReview/run-ui-review.sh`、`docs/release/2026-10-13-native-ui-acceptance.md`; modify `Tests/PhotoSyncCoreTests/AppViewTests.swift`、`PhotoSync.xcodeproj/project.pbxproj`（仅 fixture 测试成员）。

**Interfaces:**

- Consumes：Task 1/2 的真实 `StatusMenu`、`SourceSettings`、`SyncDetailsContent`；现有 `AppModel(runtime: SyncRuntime, initialState: RuntimeState)` 注入入口。
- Produces：测试专用 `UIReviewScenario: String, CaseIterable`（syncing, analyzing, preparing, icloud, paused, pausing, completed, offline, fileIssue, unauthorized, unknown, summaryLoading, summaryStale, empty, single, many, longLeaf）；`@MainActor makeUIReviewModel(scenario: UIReviewScenario, root: URL) throws -> AppModel`。
- Produces CLI：`run-ui-review.sh --derived-data PATH --output-dir PATH [--interactive --scenario NAME --appearance light|dark]`。默认捕获全部场景两种外观、菜单与设置；interactive 只启动选定场景用于真实浮层/焦点操作。
- 输出：原始 PNG、`manifest.json`（scenario/appearance/surface/尺寸/输入计数/源码commit及diff摘要/OS/Xcode/捕获方式）、可浏览 `index.html`；源码图和测试 host 不进入产品资源。

- [x] **Step 1: 写有意义的夹具/截图失败检查。** 新增 `testReviewScenariosStayIsolatedAndHaveExpectedCounts` 与 `testRenderAllReviewScenarios` 到 AppViewTests。前者断言所有 model `allowsSystemIntegrations == false`，syncing 为120/30/49/1/0、known200，completed 为170/30/0/0/0、unknown保留importing1、many恰有30来源。后者在 `PHOTOSYNC_UI_OUTPUT` 指定时输出所有场景真实视图；缺失文件/零尺寸/空白图/不收敛均失败。无该变量仍跑场景尺寸验证，不静默跳过所有用例。RED 只接受新夹具/捕获检查未满足。
- [x] **Step 2: 实现测试专用 fixture 和原生 review host。** 固定示例日期2026-10-13，UUID临时 SQLite；仅造 source 描述，不遍历路径，不调用生产 `AppModel()`、bootstrap/tick、Photos gateway 或系统权限。保持 model 的系统集成断言；不得为造图改 AppModel 私有 setter。现有离屏 NSHostingView/未显示NSWindow/bitmap方法扩展到设置，用尺寸收敛而非固定延时确认捕获就绪，保留 `P8_NATIVE_OUTPUT` 兼容输出。

  脚本使用当前 DerivedData 的 Core，编译当前 App Swift 文件（明确排除 `PhotoSyncApp.swift`）及测试 fixture/ReviewHost，构造独立 bundle ID `local.photosync.ui-review`。读取同次构建 Info.plist 版本信息但改变该 host 的 executable/identity；不复用生产单实例入口。默认不显示窗口；interactive 只打开隔离 host 的原生内容窗，不主动 activate、不发全局键，窗口ID写入 manifest。测试/审阅 host 的系统开关禁用是隔离约束，图册标明，不当作生产禁用规则变更。

- [x] **Step 3: 重建并跑聚焦 GREEN，生成整套真实主体截图。**

```bash
mkdir -p work/ui-polish/screens
PHOTOSYNC_UI_OUTPUT="$PWD/work/ui-polish/screens" \
  xcrun xctest -XCTest 'PhotoSyncCoreTests.AppViewTests' \
  work/ui-polish-derived/Build/Products/Debug/PhotoSyncCoreTests.xctest \
  > work/ui-polish/screens.log 2>&1
bash Tests/UIReview/run-ui-review.sh \
  --derived-data "$PWD/work/ui-polish-derived" \
  --output-dir "$PWD/work/ui-polish/review"
```

  17场景×2外观×2主体=68张主体图；many补设置顶部/底部。检查PNG实际内容、比例与清晰度，图册按场景配对菜单/设置，并提供原始图链接。
- [ ] **Step 4: 实际触发并捕获瞬态 UI。** 运行上一脚本的 `--interactive --scenario syncing --appearance light`（并覆盖dark），通过 app 范围内的原生交互测试 hover→进入popover、click/Space/Return固定、Escape/外部关闭及焦点恢复。再以many场景触发完整路径tooltip，点击“移除”只打开确认框后取消。捕获真正打开的浮层、键盘焦点、列表顶/底；用该host窗口定向截图，不能P图或把详情组件拼成浮层，不能按确认或操作真实源。若工具不能触发/捕获，记录明确缺口，不拿离屏主体替代，不宣告该项通过。
- [x] **Step 5: 一次集成评审与最终完整验证。** 使用一个 reviewer 检查计算口径、UI绑定/使能等价、宏/目标成员/兼容范围和跨视图布局；tester 在集成结果运行最小相关检查并执行最后完整门槛，失败修复仅限授权前端范围。相同快照不重复等价 review；如采用逐任务 subagent review，最终只审新集成风险。

```bash
python3 scripts/validate.py \
  --output-dir "$PWD/work/validation-native-ui-final" \
  --derived-data "$PWD/work/validation-native-ui-final-derived"
git diff f467ed49f5c34637437aa936dbe13f8c91ef2b33 -- \
  Sources/PhotoSyncCore Sources/PhotoSyncApp/AppModel.swift \
  Sources/PhotoSyncApp/SyncRuntime.swift Sources/PhotoSyncApp/SyncStatusPresentation.swift \
  Sources/PhotoSyncApp/PhotoSyncApp.swift
```

  验证输出目录必须全新；失败保留记录，不复用成功标记。完整门槛要求 exit0、正常结束、非零用例、无失败以及工具/竞态/资源报告齐全。冻结路径 diff 必须为空；Info.plist、entitlements、版本、Core目标成员同样不变。任何修复改变行为/测试后，最终门槛覆盖最新快照并更新受影响截图。
- [x] **Step 6: 记录并提交自动验证及截图证据索引。** 验收文档列实际commit/dirty diff、构建、自动测试、GUI截图、系统/平台/发布各自结果；人工结论写“等待用户验收”。只提交测试host/fixture、测试改动、Xcode成员变更和报告，不提交 `work/`、生产数据或额外媒体。`git commit -m "test(ui): capture native review scenes for human acceptance"`。

### Task 4: 用户前端人工验收（强制关卡）

**Files:** Update `docs/release/2026-10-13-native-ui-acceptance.md`；仅有用户反馈时修改上面授权的视图/测试文件。

**Interfaces:** Consumes Task 3 的最终代码真实截图与manifest；Produces 用户明确验收结论及对应快照，不能由代理代签。

- [ ] **Step 1: 视觉一致性检查（必须通过）。** 将定稿原型与最终代码的真实 UI 截图按相同场景、外观和逻辑尺寸并列呈现，主体截图不得缩放变形；图册保存配对比较图。逐项检查信息顺序、主次字体/颜色、间距与对齐、蓝/深灰/浅灰色段和实际比例、150/200及200/200、无记录/过期、分析单进度、两行目录/开头省略/完整路径hover、固定操作/设置区、阻断直接可见。建立逐场景差异清单，每项附截图位置、是否满足规格、修正结果；ImageGen的示意像素不凌驾于原生控件尺寸与文字规格。发现可修正的视觉差异，先在授权前端范围修正、重测并重截图，重新检查该配对。只有差异清单中无未解决的规格偏差，才能进入Step2用户验收；有意的原生样式差异要说明理由交用户确认。
- [ ] **Step 2: 把真实 UI 图册交用户验收。** 在聊天内显示代表截图并给完整图册链接，明确它们来自最终代码；单独标出实际浮层/交互图和任何未覆盖项。不能只给测试日志或ImageGen参考图。
- [ ] **Step 3: 等待用户明确通过。** 用户未回复或只提出修改意见均不算通过。收到意见后按前端范围调整，相关回归及最新完整门槛通过，重新提交受影响真实截图；不要扩大到后端。此时状态只能是“自动验证通过，等待前端人工验收”。
- [ ] **Step 4: 记录用户结论。** 把明确通过的日期、截图manifest、代码快照和接受的残余限制写入验收文档；取得结论之后再声明前端验收完成。该通过不授权合并、推送、安装/启动生产App、打包/发布或访问生产数据。

## 计划自检记录

- 覆盖：spec §3/4→Task1；§5/6→Task2；§7→Task1–3；§8→Task3/4；全部全局约束适用于所有任务。
- 类型：进度指标只消费现有 summary；共享来源行只读URL/文本/数量；fixture 与 host 不进入产品；所有后续使用的类型和CLI在对应 Interfaces 块中定义。
- 验证：数值测试、布局测试、真实截图、瞬态原生交互、完整门槛、用户确认分别有检查点；没有把截图等同交互，也没有把自动回归等同用户验收。
- 比例：不在计划中展开产品实现体；测试片段只锁定关键用户决策，不建设额外组件框架。

## 执行交接

2026-10-13 用户已批准开始实施，并明确选择 Subagent-driven；实施完成后仍需真实截图人工验收。

执行方式：Task1–3依次交给新的implementer，每任务完成后做spec与quality评审；最终review只补新的集成风险。Task4的视觉一致性检查由主线程统筹，必要修正仍交implementer并复核；截图提交后等待用户明确验收。

## 2026-10-13 首轮候选记录（人工验收未通过）

- 最终行为/测试提交 `e3e3a3f19c9b8e89f5795287bb5f9fcd2c1e2acc`；之后仅更新计划和验收记录。菜单分段进度、详情、两行目录与设置局部滚动均已实现；目录按用户最新指令全行caption/相同字重，仅颜色区别。
- 独立task评审与完整集成评审通过；一轮修复后定向复核无遗留阻断问题。未改Core、AppModel、runtime、现有统计接口、入口/Info或Core目标成员。
- `scripts/validate.py` 在全新 `work/validation-native-ui-final-retry1` / `-derived` 完整通过：599项XCTest（2项显式门控跳过，0失败）、96项Tools、四组优化规模和两组续体竞态、模型/资源检查；源码清单前后相同。首轮LFS前置失败保留，精确本地对象恢复后才重跑，没有绕过门槛。
- 首轮真实截图：`work/ui-polish/review-e3e3a3f-final` 70张主体，`probe-e3e3a3f-final-retry1` 四张实际原生组合窗口图，manifest均绑定干净e3e3a3f。用户已指出按钮、分析区、详情扫描排版及浮层截图偏差，相关视觉通过结论撤回；`work/ui-polish/comparison`已标出正在修正。
- Task3Step4为**部分完成**：实际点击popover/确认框与取消已捕获；物理hover、完整路径tooltip、独立键盘固定、真实Escape/外部关闭/焦点恢复与active材质仍未验证，非key宿主本地popover Escape失败事实保留。
- Task4首轮人工验收未通过，不能由评审/自动回归代签；修正后重做视觉对照和最后源码的完整验证。原生交互与外观缺口没有标为通过。
- 完整证据与差异：[验收记录](../../release/2026-10-13-native-ui-acceptance.md)。本轮没有合并、推送、安装、打包/发布或启动生产App。
