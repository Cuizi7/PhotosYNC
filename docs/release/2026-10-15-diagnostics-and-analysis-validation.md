# 0.2.2 来源诊断与图库分析详情验证记录

记录更新：2026-10-16（Asia/Shanghai）；文件名保留设计日期。**开发快照 `125ada6` 的完整 canonical、既有集成评审及协调代理原生 UI 验收为已完成历史；首次 exact-main 归档在 XCTest 阶段失败，未通过发布门槛。** PR #3 已 squash 至 `8531080153b00109e1a7bf462c9cd7602ffc874c`。后续 `05518b7` 仅修正测试 OCR 内存合成，聚焦 GREEN 不替代新 exact-main 的完整归档验收。最终实际 main/tag/产物由对应 provenance 和下载校验绑定，不预填未知结果；本次只更新文档，不重跑 suite。

原功能分支基线 main/v0.2.1：`1291b53ee0d263709379eb016d78b6fb8070c762`。原工作分支 `codex/source-diagnostics-022`，发行准备步骤开始 HEAD `926fbdb`。2026-10-16 当次 GitHub REST 历史复核：main 为上述提交，latest 为 v0.2.1（draft=false、prerelease=false）；v0.2.2 tag 和 release 查询均 HTTP404。查询时点无冲突不保证稍后仍空闲；发布前须再核对。

## 范围与约束

依据[批准设计](../superpowers/specs/2026-10-15-diagnostics-and-analysis-details-design.md) §§1、7、8：完整当前诊断与准确阶段、原生来源详情、与主菜单一致的图库分析详情。schema v8、媒体规则、模型/阈值、提交/恢复/调度决策和权限不变，无迁移、视频扩展、转码或新依赖。分阶段诊断/UI 测试使用合成来源、UUID 临时库、fake/injected Photos；最终 canonical 另运行既有获批固定 33 例模型语料。均不读取生产来源/数据库或真实 Photos。本步骤最初仅版本、脚本常量、合成发行 fixture 和文档，此次后续仅更新文档事实。

## 诊断与恢复实现边界

来源问题按当前未解决的诊断身份计数，同一问题重试不重复计数。详情按目录与连接、读取与解析、导入与提交分组，保留完整路径、准确人话、已知阶段和可取得的嵌套系统 domain/code/description。逐目录恢复后，首条原因来自仍未解决的成员；既有来源恢复标记仍须完整遍历证据才清除，不能将单个目录恢复当作整个来源恢复。只在完整且未延迟/中断的遍历证明旧扫描问题对应条目消失时清除该内存诊断，不清提交问题或成功历史。

视频四个既有必需元数据步骤保留实际失败阶段和系统原因；无更明确证据时不猜测损坏、缺解码器或格式不支持。失败继续报错，健康兄弟继续，不扩展视频兼容性。图库分析在 ready 时仅移除分析组，保留同一入口和浮层；representation 数不混入资产进度。

本版不改变 bundle identity 或最低系统版本；不配对 Live Photo、不自动挂载来源。本轮未新增或实测生产迁移，打包不启动应用、不备份或迁移生产数据。完整既有使用边界继续见 [0.2.1 发行说明](0.2.1.md)。

## 已有构建及自动测试证据

下表是各次实际快照的历史结果，不拼接成最终快照的完整通过。原始日志均保留于本工作树 ignored `work/`；SDD task 报告保留完整命令、失败、修正和绑定信息。

| 范围/快照 | 实际结果 | 证据 |
| --- | --- | --- |
| Task 1 诊断/恢复最终聚焦 | build-for-testing exit0；134 项，0 跳过，0 失败 | `work/022-task1-final-build.log`、`022-task1-focused-tests-final.log` |
| Task 1 初次完整 hostless | 616 项、3 跳过、1 失败；UI/OCR 候选标签断言失败，不是通过 | `work/022-task1-full-tests.log`；后由 Task 2 定位字形观察并修正 |
| Task 1 日志 F1 修正 `9ba24ac` | 最终 build exit0；Engine/AdvancedDedupEngine 96 项、0 跳过、0 失败 | `work/022-task1-f1-final-build.log`、`022-task1-f1-final-tests.log` |
| Task 2 原 UI 行为快照 | 最终 build-for-testing exit0；AppView/Presentation/AppModel 聚焦 60 项、0 失败 | `work/022-task2-final-build.log`、`022-task2-final-focused.log` |
| Task 2 修正 QA fixture 之前的完整 hostless | 626 项、3 跳过、0 失败，exit0，完整结束；不是 canonical 全门槛 | `work/022-task2-full-hostless.log` |
| Task 2 最后 QA fixture/test 修正 `a0f5a6c` | 新一致性测试有效 RED：1 项、10 个预期断言失败；GREEN build exit0，5 项、0 失败、exit0 | `work/022-task2-fixture-red-tests.log`、`022-task2-fixture-green-build.log`、`022-task2-fixture-green-tests.log` |

上述历史完整 hostless 的三项跳过为 `testControlledScaleThroughActualGraph`、`testExistingVectorReplayUsesSQLiteBackend`、`testFrozenCorpusContentAndActions`，需要 canonical 子进程/显式本地输入。它们不能免除最终语料、模型、runtime、四组规模及两项 continuation 门槛。旧 626 项完整通过早于最后一次 QA fixture/test 修改；该历史记录本身不能替代后述 `125ada6` 的完整 canonical。

## 开发快照完整自动验收：冻结 125ada6（历史）

专属 tester 在干净冻结提交 `125ada636248249fe74bc87299f598a0eac77950` 执行以下 canonical 入口，最终进程 **exit0**、`validation.json.status=passed`。协调代理已独立核对完整结果及所引用哈希并认可；未重复 suite。至 PR #3 合并的功能源码/测试保持同一内容；其间文档提交未重跑 suite。后述 `05518b7` 修改测试观测输入，另有聚焦验证，不沿用此结果冒称其完整验收通过。

```sh
python3 scripts/validate.py --output-dir "$PWD/work/022-integrated-validation" --derived-data "$PWD/work/022-integrated-derived" > "$PWD/work/022-integrated-validation.log" 2>&1
```

| 门槛 | 实际结果 |
| --- | --- |
| 构建与完整 XCTest | Debug/Release build-for-testing 完成；627 项，2 跳过，0 失败 |
| Python Tools | 97 项通过 |
| 权重/模型/runtime/固定语料 | 资源、实际模型执行及 runtime 门槛通过；固定 33 例实际运行，14 个内容 duplicate、11 个策略 skip，不混同两个口径 |
| 四组独立规模子进程 | 100000、150000、200000、200000 + 100000 history 均通过，其中最大 history 场景包含 60.033 秒 idle 观察及 622.390ms resume query；前三组无独立 60 秒 idle 样本 |
| 两项受控 continuation | stamp 与 advanced-preparation 均 GREEN exit0/fixture passed、预期 RED exit1/fixture failed，无 timeout |
| 源码一致性 | 324 entries，前后 digest 相同，unchanged_after_validation=true；所有引用结果哈希匹配 |

两个 XCTest 跳过分别为 `testControlledScaleThroughActualGraph`（已由上述四组独立子进程实际覆盖）和 `testExistingVectorReplayUsesSQLiteBackend`（额外本地 saved-vector 输入未提供，未运行，不声称通过）。此前默认跳过的固定语料本次已实际执行，不能沿用历史三跳过说法。

证据目录 `work/022-integrated-validation/` 包含 validation/report、源码 manifest、模型/runtime/scale 结果、两项 continuation 结果及日志；外层日志 `work/022-integrated-validation.log`。关键绑定：

| 证据 | SHA256 / digest |
| --- | --- |
| `validation.json` 文件 | `e3e09e9db85a37032dbd006d841d0cf218aada8b320bd6a2efd4a45d213955d7` |
| `source-manifest.json` 文件 | `2439c6208ce9fff92f7697d3c41cb26bf9373099d27159f40249f804f8714d52` |
| 前后源码 manifest digest | `806b41958d833617cf5419a8f0a4451a71aa7e1c5059b47d9075f2ac8dc9fe35` |

## 最终集成静态评审与已接受残余

独立 deep reviewer 对 `1291b53..125ada6` 全部集成差异完成代码、规格和架构评审，结论 **APPROVED，无 P0/P1/P2**。报告为 ignored `.superpowers/sdd/2026-10-15-diagnostics-and-analysis-details/integrated-review.md`。同一评审者已在 `e0b9a97` addendum 完成 canonical 证据补核 PASS 和文档差异 APPROVED，核对 111 个 artifact-sha256 条目零不匹配；复用精确 `125ada6` 执行，不重跑 suite。同一评审者随后已对 UI/ICC 与正式文案完成补核，最终 `ed58a4d` 文档/证据 follow-up APPROVED；该既有批准不替代下述测试修正及新归档的验收。

协调代理明确接受 **P3 F1**：仅自定义 `PhotosGateway` 在 `saveScannedFile` 候选查询抛出非 typed 错误时，诊断可能继承前面的“读取媒体元数据”阶段。内置 `SystemPhotoKitLifecycle` 当前路径没有已证实触发点，不宣称已运行复现。后续最小修正可在 metadata 读取完成后结束该阶段、使用准确后续阶段或 nil，并加该 gateway 边界注入测试；本轮不扩展异常分类、重试或准入策略，不改冻结代码。

## GUI 历史证据与后续验收

- 修正后静态 gallery：`work/022-ui-fixture-corrected/index.html`，clean `a0f5a6c`；`source.json`、manifest 和 SHA256SUMS 绑定 118 张明/暗 PNG 及编译输入。与保留的旧 gallery 比较，8 张 mixedIssues 图改变，其余 110 张字节一致。协调代理已审阅；这是静态原生内容，不是实际屏幕 popup/material，也不是用户本人验收。
- 测试中同一 native popup/trigger 在进度更新与 ready 转换后保留，长内容实际滚动；它们证明逻辑和内容，不证明 active material、物理 hover、独立键盘固定/关闭或可见焦点恢复。
- 保留早期 `work/022-ui-native-probe/`、`022-ui-native-check/`、`022-ui-native-check-stable/` 的失败：部分透明/不完整材质，native/CG 尺寸未收敛（CG 1×2），自己窗口截图失败。未当作视觉通过。
- 早期一次授权前台会话：`work/022-ui-controlled-once/source.json` 与 `controlled-manifest.json`，clean `3df233d`。原前台 loginwindow/PID417，QA PID31722；qaActivationCalls=1、elapsed=1.1928489s、userSwitchObserved=false、captures=0、status=unverified。QA 未成为前台，恢复 guard 为 false，restore.attempted=false；会话关闭自己宿主并退出，没有再次激活、全局输入、权限更改或新截图。wrapper exit0 只表示观察报告生成。没有仅凭这些观察推断权限失败或锁屏原因。

**上述早期证据当时未满足真实浮层验收，原失败及绑定完整保留。** 后续由新的明确授权完成下述采集和协调代理验收；不将旧失败改写为成功，不自动复用 0.2.1 的历史视觉接受。

## 新增原生 UI 与材质证据：协调代理验收通过

2026-10-16，协调代理明确审阅并通过本轮新增内容的原生 UI 验收；这是**协调代理审阅，不是用户亲自验收**。该批采集时产品、Core、Tests 和已提交 harness 不变，复用 `125ada6` canonical 与当时 deep review；后续 test-only OCR 修正不改变产品原生 UI，保留此协调验收范围。新采集绑定 clean `e0b9a97` 和原始编译/源码哈希，私有 QA 宿主与审计不进入产品。

- `work/022-ui-onscreen-resumed-20261016T074406/` 的 14 张真实原生浮层内容图覆盖明/暗、长问题列表滚动末项、同一浮层中的进度更新及 ready 转换。协调代理已审阅这些实际内容；它们与之前 118 张静态内容图分别保留。
- v3 材质 A/B：`work/022-material-v3-capture-20261016T082619-99842c/`。同一 popup、内容、frame/appearance，A 无背景时显示灰底低对比，B 加入仅自己 QA 的真实 opaque 背景后文字可读。原始 PNG、controlled-manifest、capture-summary、offline audit 和 CAPTURE-SHA256SUMS 保留；没有改产品样式或 PNG。
- v3 原协议因颜色门槛记录 `unverified`，这一状态不覆盖。直接 `NSBitmapImageRep.colorAt` 给出的 NSColor 被标成 Generic RGB，而 bitmap.colorSpace 实测为显示 ICC `LV273HUPR`；将原编码样本当 Generic RGB 直接转 sRGB 的最大误差约 0.054，不能据此认定真实背景不存在。
- 协调代理随后独立审计原图：先将原采样分量赋予 image.colorSpace，再转 sRGB，四个原定角点最大误差 **0.0015423131（<0.001543）**，小于未改变的 **8/255** 门槛；LittleCMS 按嵌入 ICC 转换同样通过（8-bit 比较最大误差约 0.002353）。这是只读解释原 PNG，不是重写图片或放宽容差。
- 独立审计原来源为 `/private/tmp/`，三份文件已原样归档在上述 v3 capture 目录：`photosync022-icc-audit.json`、`photosync022-color-icc-audit.swift`、`photosync022-color-icc-audit.log`。`COORDINATOR-AUDIT-SHA256SUMS` 和 `coordinator-audit-copy-verification.json` 绑定复制一致性；原 capture 清单 11 项哈希未变，原 manifest 仍为 unverified。审计脚本 SHA256 `1bdf5377ec0f189e03961011e321a95f8b7c59efa2e6bfd7fac4acdd7256d817`；日志 SHA256 `56495c499ab282380e6526db2d5bebf3f35b99ca1fdf79b2b7e53fd2fae821ba`。A/B 原 PNG SHA256 分别为 `c4b5ef0b9207487537172091f20d7865f8830f8d2d57369830f953cec3158077`、`35df0006ca3ae6775d97efa03bfbeb76d73a0672d7ac0389f90f793fb8c9763d`。

**结论边界：** 独立 ICC 审计及协调代理对具体原图的视觉审阅补充满足本轮新增内容验收；不把原 manifest 改为 passed，也不声称颜色断言之后未到达的末尾断言运行或通过。NSWorkspace frontmost=QA 与 NSApp.active=false/keyWindow=nil 是分别记录的观察，不等价为同一 active/focus 结论，不推断原因。自己的窗口组及受控 QA 背景不是全显示器截图；物理 hover/focus、完整键盘、VoiceOver、真正 MenuBarExtra 和全屏背景真实性未新增验证。

## 发行配置聚焦检查（历史）

目标三种现有 App 配置均为 0.2.2/build10；Info.plist 继续 stable。package-release 仅更新 release_name、bundle 版本/build 断言、说明路径和 provenance build；Tests/Tools 对应 DMG/版本/锁/staging/notes fixture 同步，不改失败门槛。

本步骤要求运行：

```sh
python3 -m unittest discover -s Tests/Tools -p test_release_validation.py
zsh -n scripts/package-release.sh
git diff --check
```

2026-10-16 实际结果：发行工具测试 **15 项，0 失败，57.217 秒，exit0（OK）**，日志 `work/022-task3-release-validation-tests.log`。覆盖当前版本产物与 provenance，以及失败/缺架构/脏源码/已有目标/锁冲突的拒绝路径。脚本语法和 diff 空白检查 exit0；另行 `plutil -lint PhotoSync.xcodeproj/project.pbxproj` exit0。只读断言核对三种现有版本配置、stable 渠道、脚本/fixture 相对基线严格只有批准的常量替换，以及四份文档全部本地链接存在，均通过。未运行生产打包入口或 broad suite；合成 fixture 内调用打包脚本不等于生成真实发行包。

## 首次归档失败与 test-only OCR 观测修正（2026-10-16）

首次正常 `package-release.sh` 从 main `8531080153b00109e1a7bf462c9cd7602ffc874c` 归档到**主 checkout** 的 `work/release-0.2.2.a9rpNf/`。完整 XCTest 执行 627 项、2 skip，在 `testOpenDetailsUpdateAndRemainOpenWhenAnalysisBecomesReady` 原 493/497 行出现 2 个 OCR 内容断言失败；入口 exit1、无 `validation.json` 成功 marker、无发行包或 tag，Tools/规模/Release 打包阶段未运行。门槛按失败关闭，旧开发快照通过不替代该归档结果。

独立同 archive 单测另在原 487 行找不到 popup，未进入上述 OCR 断言；原因未证，不能归为同一根因。临时 guard 诊断曾因原生 NSButton label/id 为空而提前停止，该次未复现原症状。后续纯观测 v2 保留原 selector/点击/窗口搜索/两秒等待/核心断言，真实复现相同两个 OCR 失败：popup 18521 确属 host 18520，输入更新且内容高度由 446 变 369，原透明 PNG 中存在黑色 primary 字形，OCR 只读到 secondary 脚注。

同一 `updating-011.png` 和 `ready-024.png` 各做一次旧 pipeline / 仅内存白底 A/B，共 4 次离线 Vision request。A 复现两个对应谓词 false，B 仅填 opaque white 即均 true，跨状态错误谓词仍 false，原 PNG SHA 前后不变。这支持这两个失败样本的透明 bitmap→OCR 合成/对比度边界，不证明 487 缺窗口原因，也不是 v3 旧 ICC 颜色解释问题；产品 material、原图和协调代理 UI 验收不变，原 v3 manifest 仍 unverified。

终版提交 `05518b7eb364a0ed6b80e67827aa89486e5c497f` 仅在 `AppViewTests.recognizedText` 既有 draw 前增加 5 行，按 view.effectiveAppearance 为 OCR 内存缓冲填匹配的白/黑 opaque 底。全部 temporary diagnostics/guards 已移除；原测试、selector、等待、policy、精确正/负谓词与 popup/trigger 身份断言恢复不变。文件 SHA256：`3bedf5fd345f5f24c3c1b510bc6fceef06e2dbb0496a4ae2cbe7e561ee0435ff`。产品/Core/UI/脚本/0.2.2 stable build 10 均不改。

| 独立原 tester 聚焦验证 | 实际结果 |
| --- | --- |
| fresh `work/022-ocr-fix-validation-20261016T091508/` build-for-testing | exit0，完整 TEST BUILD SUCCEEDED |
| 原目标 method 单跑 | 1 项、0 skip、0 fail，1.428s，exit0 |
| 完整 AppViewTests class | 27 项、0 skip、0 fail，46.478s，exit0；目标在类内 1.282s |
| 源码绑定 | 运行时为 `8531080` + 5 行 diff，前/后 SHA 均为上述值，与 `05518b7` 同字节；不能称原 `8531080` 提交通过 |

487 变体在这两轮未复现，未宣称因果解决。聚焦测试含 programmatic 原生 AppKit/OCR 明暗及语义阴性覆盖，不是新的物理/屏幕材质验收，也未执行完整 627、Tools/模型/规模/continuation 门槛。

完整命令、原件和证据路径保留在 ignored SDD 报告：`archive-validation-failure.md`、`popover-failure-diagnostic-report.md`、`popover-failure-diagnostic-v2-report.md`、`popover-offline-ocr-ab-report.md`、`ocr-observation-fix-report.md` 和 `ocr-fix-validation-report.md`。诊断 v2 目录 `work/022-popover-failure-diagnostic-v2-20261016T090132-8d8a0d/`；离线 A/B 目录 `work/022-popover-offline-ocr-20261016T091029-410a24/`。`ocr-fix-validation-report.md` SHA256：`3c0a5e45c7150ca6d225303dcc4e0c5a7d5af572d94334a50a2ea3acb955f251`。这些历史失败与 GREEN 不覆盖未来归档结果。

## 交付门槛与最终绑定

1. 本轮新增原生内容/受控材质的协调代理验收已通过，范围见上；保留原失败和未运行断言，不扩展为物理交互、真实 MenuBarExtra 或全屏真实性通过。
2. `125ada6` 开发快照完整通过、`8531080` 首次归档失败和 `05518b7` test-only 聚焦 GREEN 分别保留；聚焦 GREEN 不能替代正常发布入口的新完整归档验收，不豁免失败/缺工具/零测试/源码一致性门槛。
3. 既有集成 deep review、canonical 及 UI/ICC/文案补核已通过，无 P0–P2，P3 F1 为协调已接受残余；本轮 5 行测试修正及证据由同一评审者补核。只读复核本身不重复未变测试，但不能绕过新 exact-main 的完整发布验收。
4. PR #3 已 squash 至 `8531080`；test-only 后续修正通过同一评审者补核后，由主线程继续后续 PR/合并，核对远端 base/diff/checks/mergeability 和新 main 源码树。后续 PR 编号及新 main 未知时不预填。
5. 修正 squash 到新 main 后核对 tree 和实际提交，再从该干净提交使用正常 `scripts/package-release.sh` 重新归档，归档内重新完整验收并核验 Universal App/Core、0.2.2/stable/10、资源、图标、签名、DMG、provenance 和校验。保留 App、DMG、RELEASE-NOTES、CHANGELOG、完整 validation、构建日志及本地全目录 SHA256SUMS；已有目录、文件、符号链接或锁均不能覆盖/绕过；失败、缺报告、零测试、资源损坏及源码 manifest 变化不得跳过。
6. 正式文案与 README/CHANGELOG/RELEASE-NOTES 保持一致，只描述实际验收与限制；历史失败和分阶段数量保留日期/快照绑定，不改写成成功。最终 main/tag、归档 manifest、验收哈希和产物由实际 provenance/校验记录给出，不从本页推导未知结果；上传前由主线程核对。
7. 发布前重新核对 v0.2.2，tag 绑定实际 main；GitHub stable/latest 四项资产为 `PhotosYNC-0.2.2.dmg`、`PhotosYNC.provenance`、`RELEASE-NOTES.md` 和只覆盖前三项的下载 `SHA256SUMS`，与本地全目录清单分离，上传后回读并下载校验。旧包/标签/证据保留。

## 分开报告的边界

| 类别 | 当前状态 |
| --- | --- |
| 构建 | 历史开发构建与 5 行修正 fresh build 通过；首次 exact-main 归档在完整 XCTest 失败，未进入 Universal Release；最终产物以新归档日志/provenance 绑定 |
| 自动测试 | `125ada6` 历史 canonical passed；`8531080` 归档 627/2 skip/2 断言失败；5 行修正目标 1/0 fail 及 AppView 27/0 fail只为聚焦 GREEN，新完整归档结果独立记录 |
| 集成评审 | 原功能/证据 APPROVED，P3 F1 已接受；test-only 后续修正及证据以同一评审者的补核记录为准 |
| GUI | 118 静态图、14 张新增真实内容图及 v3 原图+ICC 补审已由协调代理验收；非用户亲自验收，物理键盘/hover/focus/系统菜单/VoiceOver/全屏真实性保留缺口 |
| 真实 Photos/生产来源或数据库 | 本轮未执行；历史实测不标成本轮新测 |
| 平台实机 | macOS13/14 与 Intel 本轮未运行；macOS13/Intel 按授权排除实机收尾门槛，最低版本与 Universal 构建要求保留 |
| 签名及分发 | 确切 main 归档及实际 release 产物结果由 provenance/下载校验记录绑定；ad-hoc，未 Developer ID、公证、stapling 或 Gatekeeper 验收，本步骤不安装/启动生产 App |

实际交付的 main/tag/release、包目录、归档验证与 provenance/DMG 哈希由主线程核对并记录；本页不使用占位成功或旧包校验值。本步骤只提交正式文档，不执行 push、merge、package、tag 或 release。
