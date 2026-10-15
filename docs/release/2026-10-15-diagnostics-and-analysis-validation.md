# 0.2.2 来源诊断与图库分析详情验证记录

记录更新：2026-10-16（Asia/Shanghai）；文件名保留设计日期。**状态：发行准备，合并与发布阻断。** 本页汇总已存在的分阶段证据及本步骤的聚焦检查，不是最终 canonical 或真实浮层验收成功记录。

基线 main/v0.2.1：`1291b53ee0d263709379eb016d78b6fb8070c762`。工作分支 `codex/source-diagnostics-022`，本步骤开始 HEAD `926fbdb`。2026-10-16 通过 GitHub REST 只读复核：main 仍为上述提交，latest 为 v0.2.1（draft=false、prerelease=false）；v0.2.2 tag 和 release 查询均 HTTP404。查询时点无冲突不保证稍后仍空闲；发布前须再核对。

## 范围与约束

依据[批准设计](../superpowers/specs/2026-10-15-diagnostics-and-analysis-details-design.md) §§1、7、8：完整当前诊断与准确阶段、原生来源详情、与主菜单一致的图库分析详情。schema v8、媒体规则、模型/阈值、提交/恢复/调度决策和权限不变，无迁移、视频扩展、转码或新依赖。测试只用合成来源、UUID 临时库、fake/injected Photos；本步骤仅版本、脚本常量、合成发行 fixture 和文档。

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

完整 hostless 的三项跳过为 `testControlledScaleThroughActualGraph`、`testExistingVectorReplayUsesSQLiteBackend`、`testFrozenCorpusContentAndActions`，需要 canonical 子进程/显式本地输入。它们不能免除最终语料、模型、runtime、四组规模及两项 continuation 门槛。旧 626 项完整通过早于最后一次 QA fixture/test 修改，最终完整验证仍待执行。

## GUI 证据和未通过项目

- 修正后静态 gallery：`work/022-ui-fixture-corrected/index.html`，clean `a0f5a6c`；`source.json`、manifest 和 SHA256SUMS 绑定 118 张明/暗 PNG 及编译输入。与保留的旧 gallery 比较，8 张 mixedIssues 图改变，其余 110 张字节一致。协调代理已审阅；这是静态原生内容，不是实际屏幕 popup/material，也不是用户本人验收。
- 测试中同一 native popup/trigger 在进度更新与 ready 转换后保留，长内容实际滚动；它们证明逻辑和内容，不证明 active material、物理 hover、独立键盘固定/关闭或可见焦点恢复。
- 保留早期 `work/022-ui-native-probe/`、`022-ui-native-check/`、`022-ui-native-check-stable/` 的失败：部分透明/不完整材质，native/CG 尺寸未收敛（CG 1×2），自己窗口截图失败。未当作视觉通过。
- 唯一授权前台会话：`work/022-ui-controlled-once/source.json` 与 `controlled-manifest.json`，clean `3df233d`。原前台 loginwindow/PID417，QA PID31722；qaActivationCalls=1、elapsed=1.1928489s、userSwitchObserved=false、captures=0、status=unverified。QA 未成为前台，恢复 guard 为 false，restore.attempted=false；会话关闭自己宿主并退出，没有再次激活、全局输入、权限更改或新截图。wrapper exit0 只表示观察报告生成。没有仅凭这些观察推断权限失败或锁屏原因。

**真实屏幕打开浮层及材质验收未通过，继续阻断合并与发布。** 协调线程等待用户解锁后的合法后续安排；本步骤不重试激活。旧 0.2.1 用户视觉接受只覆盖其历史快照及未改变边界，不能替代本轮改变部分。

## 本次发行准备检查

目标三种现有 App 配置均为 0.2.2/build10；Info.plist 继续 stable。package-release 仅更新 release_name、bundle 版本/build 断言、说明路径和 provenance build；Tests/Tools 对应 DMG/版本/锁/staging/notes fixture 同步，不改失败门槛。

本步骤要求运行：

```sh
python3 -m unittest discover -s Tests/Tools -p test_release_validation.py
zsh -n scripts/package-release.sh
git diff --check
```

2026-10-16 实际结果：发行工具测试 **15 项，0 失败，57.217 秒，exit0（OK）**，日志 `work/022-task3-release-validation-tests.log`。覆盖当前版本产物与 provenance，以及失败/缺架构/脏源码/已有目标/锁冲突的拒绝路径。脚本语法和 diff 空白检查 exit0；另行 `plutil -lint PhotoSync.xcodeproj/project.pbxproj` exit0。只读断言核对三种现有版本配置、stable 渠道、脚本/fixture 相对基线严格只有批准的常量替换，以及四份文档全部本地链接存在，均通过。未运行生产打包入口或 broad suite；合成 fixture 内调用打包脚本不等于生成真实发行包。

## 必须后续完成的门槛

1. 完成改变部分的真实原生浮层/材质截图，由协调代理明确审阅具体证据；分别标注普通原生宿主、真正 MenuBarExtra 和物理交互覆盖。不得将失败/无截图写为通过。
2. 专属 tester 对最终快照执行 fresh `scripts/validate.py`，记录完整 XCTest/跳过/失败与 Tools、完整权重/model/runtime、固定语料、100000/150000/200000/200000-history-100000 四组规模、stamp 与 advanced-preparation continuation 的 GREEN/预期 RED、前后源码 manifest 一致。
3. 对 main 基线到最终集成 diff 完成 deep review；最后行为/测试修改后完整验证，等价只读 review 不强制重复相同快照验证。
4. 按批准计划 Step 4 独立推进 push/PR，创建后立即 attach，并如实披露当前验证及视觉缺口；核对远端 diff/checks/mergeability。真实 popup 视觉关卡不扩大为创建 PR 的前置条件。squash merge 与 release 仍须满足上述完整验证、集成深度评审和协调代理对真实浮层/材质的必要审阅结论。
5. 合并后核对 main tree 和实际提交，再从该干净提交运行 package-release，归档内重新完整验收并核验 Universal App/Core、0.2.2/stable/10、资源、图标、签名、DMG、provenance 和校验。保留 App、DMG、RELEASE-NOTES、CHANGELOG、完整 validation、构建日志及本地全目录 SHA256SUMS；已有目录、文件、符号链接或锁均不能覆盖/绕过；失败、缺报告、零测试、资源损坏及源码 manifest 变化不得跳过。
6. 真正发布前，逐项检查 README、CHANGELOG、0.2.2 发行说明、此验证记录及最终 RELEASE-NOTES 与实际证据一致。依据真实完成状态更新“尚未发布”“待完成”“未创建”等准备阶段语句；历史采集失败和分阶段数量仍保留为有日期/快照绑定的历史，不改写成成功。不预填未知 main/tag/哈希，精确源码、manifest、验证哈希和产物绑定由实际 provenance 与校验记录给出。避免将准备阶段文本原样作为已完成发行说明上传。
7. 发布前重新核对 v0.2.2，tag 绑定实际 main；GitHub stable/latest 四项资产为 `PhotosYNC-0.2.2.dmg`、`PhotosYNC.provenance`、`RELEASE-NOTES.md` 和只覆盖前三项的下载 `SHA256SUMS`，与本地全目录清单分离，上传后回读并下载校验。旧包/标签/证据保留。

## 分开报告的边界

| 类别 | 当前状态 |
| --- | --- |
| 构建 | 分阶段 build-for-testing 已通过；最终 canonical 和正式 Universal Release 未执行 |
| 自动测试 | 上述分阶段结果；最后 fixture 修正后未完整 canonical 验证 |
| GUI | 118 静态内容图已由协调代理审阅；真实屏幕 popup/material 仍未通过，物理键盘/hover/系统菜单/VoiceOver 有缺口 |
| 真实 Photos/生产来源或数据库 | 本轮未执行；历史实测不标成本轮新测 |
| 平台实机 | macOS13/14 与 Intel 本轮未运行；macOS13/Intel 按授权排除实机收尾门槛，最低版本与 Universal 构建要求保留 |
| 签名及分发 | 本轮 release 包、tag、上传、安装/启动未执行；目标 ad-hoc，未 Developer ID、公证、stapling 或 Gatekeeper 验收 |

实际发行完成后由协调线程补录本次 main/tag/PR/release、包目录、验证与 provenance/DMG 哈希及限制；本页不使用占位成功或旧包校验值。
