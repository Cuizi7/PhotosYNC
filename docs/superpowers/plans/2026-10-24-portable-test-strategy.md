# PhotosYNC Portable Test Strategy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. 按用户此前选择由主代理串行实施；探索、测试和独立评审按需委派。步骤使用 checkbox 跟踪。

**Goal:** 修复本轮准备阻塞、残留等待、设置文字倒置及经证实的相关数据库错误，同时交付可在其他 Mac 从 GitHub checkout 复现、时间有界的测试门槛。

**Architecture:** 扩展现有 XCTest、GUIQA、`validate.py` 和 packaging 入口。使用真实 runtime/graph/SQLite，在系统边界注入可控事件与自制媒体；另用真实 Settings scene 验证像素和交互。所有必须证据绑定本次源码、固定素材、模型及环境。

**Tech Stack:** Swift/XCTest、SwiftUI/AppKit、PhotoKit lifecycle seams、SQLite、ImageIO/AVFoundation、Python unittest/Pillow、Git LFS、Xcode。

**Spec:** [可复现测试方案](../specs/2026-10-24-portable-test-strategy-design.md)。实施前同时阅读 `Design/Validation.md` 和 `docs/specs/2026-09-18-runtime-state-and-recovery.md`。

## Global Constraints

- 仅使用仓库授权素材和生成数据；常规测试不读取生产 Photos、生产 SQLite、生产副本或来源。
- 不改变产品去重/提交/所有权规则来满足测试；B01–B04已获本轮修复授权，先保存失败证据。此授权不包括无关重构、生产数据修复、安装或release。
- 默认内存 2 GiB；普通视频严格大于 10 秒且无明确 Live Photo 身份时排除识别，仍正常导入。
- `release` 保留 200k + 100k 历史；`full` 保留四档、真实 60 秒空闲检查、2 秒/4 GiB 等已有门槛；本轮选择 full。
- focus 8 分钟、canonical release/full 25/35 分钟、native UI 8 分钟；带包装的总截止时间 35/40 分钟。超时非零退出，不重试到绿。
- 所有新增脚本默认离线；依赖准备显式执行。源码、测试素材、脚本和许可证可提交；work/、个人照片/数据库、机器缓存和凭据不提交。
- 每个阶段使用新证据目录；同一提交归档内执行 canonical，不跨提交复用通过标记。当前实施记录见文末；未满足的验收项保持未完成。

## Review Focus

1. 冷启动没有 observer 的情况下，fake 的即时 snapshot 会掩盖全量候选等待：Task 2 必须包含物理加载门闩及第一项真实目录事件。
2. 已 verified 新目标与旧 blocked attempt 共存，或未知写入遇到恢复：Task 3 同时检查无幽灵待办和不重复提交。
3. 实际 Settings scene 的文本方向与离屏 OCR 不一致：Task 4 检查真实窗口像素并证明倒置负对照会失败。
4. 只改变 `user_version` 的假历史库、GUIQA 默认新会话掩盖升级/重启：Task 2/3 使用结构匹配的历史 DDL及显式隔离会话重开。
5. CI 环境变量、缺素材、慢机超时或 GUI 缺权限导致静默降级：Task 1/5/6 必须失败并保留覆盖缺口，不能宣称全量通过。

---

## 文件与职责

| 文件 | 用途 |
| --- | --- |
| `scripts/test-environment.py`、`scripts/requirements-test.txt`、`Tests/Support/test-environment.json` | 显式依赖准备、固定工具与素材身份、环境预检 |
| `Tests/Fixtures/LivePhotoPortable/`、`Tests/Support/RuntimeScenarios.json` | 少量自制固定媒体、生成记录、种子和场景预期 |
| `Tests/PhotoSyncCoreTests/RuntimeScenarioSupport.swift` | 复用现有 fake/gate 的公共测试辅助；不复制业务状态机 |
| `Tests/PhotoSyncCoreTests/StartupRecoveryTests.swift`、`RuntimeEventSequenceTests.swift` | 持久冷启动、串联恢复及有限事件序列 |
| `Tests/RuntimeValidation/RuntimeHost.swift` | 复用产品运行时的独立进程重启/故障检查宿主 |
| `Sources/PhotoSyncApp/GUIQARuntime.swift`、`GUIQALaunchConfiguration.swift` | QA 复用 actual graph 与受约束会话，不改正常启动默认路径 |
| `Tests/UIReview/NativeSceneDriver.swift`、`native-scenarios.json`、`run-native-scenes.py` | 真实 Settings/MenuBarExtra 动作、窗口捕捉与场景报告 |
| `scripts/run-focused-tests.py` | 有限命名 suite 的开发入口；永不生成 canonical 成功证据 |
| `scripts/validate.py`、`scripts/package-release.sh` | 必须场景、截止时间、GUI profile、报告/provenance 集成 |
| `Tests/Tools/test_test_environment.py`、`test_focused_tests.py`、`test_native_scene_runner.py`、既有 runner 测试 | 上述工具的合成输入验证、失败闭合和超时回收 |
| `PhotoSync.xcodeproj/project.pbxproj` | 新 Swift 文件的正确目标归属；测试宿主不进入发行产物 |
| `docs/testing/README.md`、`Design/Validation.md`、`README.md` | 实施后的真实命令、预算、跨机器结果与边界 |

新增文件可在实现时按现有 helper 合并，职责与场景 ID 不变；禁止为了迁就这个表大规模迁移无关测试。

## Task 1：固定可分发输入和环境入口

**Files:** 上表环境文件及 `Tests/Fixtures/LivePhotoPortable/`；修改 `scripts/validate.py`、`scripts/dedup-fixtures/validate.py`、`Tests/Tools/test_release_validation.py`；关联 `Tests/Fixtures/AdvancedDedup/PUBLICATION_AUTHORIZATION.md`。

**Interfaces:**
- `test-environment.py --prepare --root <absolute-new-root>` 在同一10分钟预算内创建 `venv/`、取得并水合当前提交所需LFS、写 `environment.json`；`--check --root <root> --output <new-report>` 只检查，不隐式安装/联网。
- `test-environment.json` 记录 schemaVersion、参考工具链、所需工具、模型/素材清单及每份授权记录的相对路径和哈希；不能将可变绝对路径写入身份。
- `RuntimeScenarios.json` 使用 `schemaVersion`, `seed`, `scenarioID`, `initialState`, `events`, `expectations`；资源只能引用 manifest 内的相对 ID。

- [x] 增加环境测试：缺 LFS object、Pillow/工具缺失、素材 hash 错、未知外部 corpus、生产路径/符号链接逃逸均明确失败；`CI=true` + 精确允许素材可运行，CI 值改变不能扩大素材范围。
- [x] 运行 `python3 -m unittest discover -s Tests/Tools -p 'test_test_environment.py'`，保存预期失败。原有33例及其冻结真值不删不改；先列出全部运行依赖，区分默认验收和仅模型转换所需依赖。
- [x] 实现独立 venv 准备及 hash 校验。锁定 Pillow 12.3.0 和适用 wheel 哈希；记录 Xcode/Swift/Python/macOS/架构及 GUI 能力。LFS子进程也受同一10分钟截止约束，拒绝覆盖修改过的模型；不在说明中留无界下载命令。
- [x] 从现有 `LivePhotoTestSupport.swift` 的自制媒体辅助生成小型固定 HEIC/JPEG/MOV 语料，补 10 秒边界、损坏及缺标识样本；提交字节、生成方式、预期 metadata 和许可/来源。生成器跨 SDK 不要求产生相同码流，正式回归必须读取已冻结字节。
- [x] 运行新工具测试、已有 fixture 校验和真实 `LivePhotoMetadataReader` 的 fixture 断言。报告新素材总大小，普通 Git 新增素材预算 10 MiB；不提交大数据库或大量视频。
- [x] 提交本任务文件，保留原33例 expected/manifest hash 不变的校验结果。

## Task 2：贯通冷启动到真正同步

**Files:** `StartupRecoveryTests.swift`、`RuntimeScenarioSupport.swift`、`Tests/RuntimeValidation/RuntimeHost.swift`；扩展 `AdvancedRuntimeTests.swift`、`LivePhotoKitContractTests.swift`、`LivePhotoCoordinatorTests.swift` 中现有辅助；仅按需给 `SyncRuntime.swift` 加窄注入点；更新 Xcode 目标。

**Interfaces:**
- `RuntimeScenarioFixture.open(root: URL, scenarioID: String) async throws -> RuntimeScenarioFixture`；对象持有实际 `SyncStore`、`SyncRuntime`、受控系统边界与事件记录。
- `recordedEvents() async -> [ScenarioEvent]`，事件包含 logicalSequence、monotonicOffset、kind、匿名 fixtureHandle；按设计第5节枚举事件名。
- `RuntimeHost --scenario <id> --session <owned-root> --phase seed|resume --output <new-report>`。seed/resume 允许重开同一个带测试身份清单的 QA 会话；拒绝外部数据库/来源。程序退出后再 resume，不能靠复用对象冒充冷启动。

- [x] 添加 `testColdRestartWithHistoryReachesSourceWork`：真实写入1,000表示/200历史/40待识别项后停止并重开；新 observer 无连续性但持久历史有效。新实例必须走实际 `bootstrap()` 及配置/存储打开路径，先注入隔离根和系统依赖；不能只用 `prepareInjectedRuntime()` 加tick冒充启动。断言旧指纹不重算、一次性任务不重跑、目录确实交付首项、合法提交确实完成、成功历史未变。
- [x] 添加 `testBlockedCandidateLoadDoesNotHideSourceProgressOrPermitUnsafeSubmit` 和 `testLivePhotoItemsDoNotReloadSameCandidateGeneration`：门闩控制物理加载，实际 `PhotoKitGateway` + fake lifecycle 对加载计数；分别断言来源枚举、必要核实后的提交和缓存调用次数。无关媒体等待不得阻塞健康枚举；unknown 不得提交。
- [x] 添加有效/失效历史、单项通知/未知全量、启动中暂停/撤权、无来源但有Photos待办的参数化变体，关联 R01–R04/R12。依赖释放前后的时间分开计量，不将测试自己制造的等待隐藏。
- [x] 用独立子进程两次启动 `RuntimeHost` 跑固定 cold-restart 场景，收集事件与临时库结果。把旧实现的失败断言保存为 RED；若当前所有断言都通过却不能解释用户故障，先补复现，不能凭绿色宣称修复。
- [x] 实现只为测试需要的边界注入/事件观测；保留 actual graph/coordinators。新增辅助复用 `CompletionPhotos`、`P8Gate`/`InventoryReadGate` 模式，不造第二个简化 runtime。
- [x] 修复B01：避免必要候选核对阻断安全来源枚举，提交仍等待同一有效快照；同generation的物理候选加载复用，历史分析不制造重复全量工作。运行新测试及既有 `AdvancedRuntimeTests`、`PhotosIndexCoordinatorTests`、`LivePhotoKitContractTests`，核对RED/GREEN与调用量。
- [x] 提交完整可测的冷启动回归及必要测试辅助；未修的产品缺陷必须保持可见失败，不能以 skip 合并。

## Task 3：故障、持久化与有限时序覆盖

**Files:** `RuntimeEventSequenceTests.swift`、`RuntimeScenarios.json`、现有 `LivePhoto*Tests.swift`、`StoreTests.swift`、`SourceReaderTests.swift`、`Tests/RuntimeValidation/RuntimeHost.swift`。

**Interfaces:**
- `runScenario(id: String, seed: UInt64, maximumEvents: Int) async throws -> ScenarioReport`；固定稳定的种子算法，不使用系统随机数决定测试路径。
- 子进程宿主增加 `--crash-at <named-checkpoint>`，仅测试宿主可见；系统提交 journal 是测试-owned 文件，应用 SQLite 仍走真实 API。测试进程被终止后保留 journal 与同一测试库。

- [x] 按设计 R05–R16 标出已有 XCTest 方法及缺口；已有完整场景只链接，不重复写等价测试。增加过期 blocked + 同组 verified、未知提交重启、根恢复与旧续体、内存变更与晚失败等固定三方交错。
- [x] 修复B02：在存储/协调层收敛已被已验证目标替代的旧待办，summary与scheduler使用相同有效工作口径；保留未知提交阻断。B04先只读定位错误类别，再用临时SQLite复现并修复确认的问题；证据不足时明确记录，不能凭截图猜数据库损坏。
- [x] 添加崩溃检查点：意图落库后、placeholder后、成功系统回调与本地确认之间、目标验证后、清理发出但未确认、清理已确认。每个点断言无重复实际提交、成功历史保留、未知结果不被超时伪造为失败。
- [x] 为受支持 schema 逐项绑定最小历史结构与生成记录；复用已有迁移测试，修正仅降 `user_version` 却保留新结构的不足。检查迁移中断回滚、未来版本拒绝、汇总读取失败与数据库不可写分别恢复。
- [x] 运行固定20种子×40合法事件。每步检查四个不变量；集成执行增量不超过90秒。失败报告保留 seed 和完整最短失败前缀；显式最小化最多30秒，不在正常通过路径跑无界 fuzz。
- [x] 为资源/时长边界、正常跳过与真正失败、日志阶段计数增加缺失断言。时钟推进到600/610秒只消耗虚拟时间；物理结束门闩未放行前预算/槽位仍保留。
- [x] 在相关套件通过后提交；所有产品修复须映射用户批准行为，不能在此任务顺手重构存储或调度。

## Task 4：真实 Settings scene 与菜单回归

**Files:** `GUIQARuntime.swift`、`GUIQALaunchConfiguration.swift`、`PhotoSyncApp.swift`/`AppModel.swift` 的 QA 分支；新增 `NativeSceneDriver.swift`、`native-scenarios.json`、`run-native-scenes.py`；扩展 `AppViewTests.swift`、`GUIQALaunchConfigurationTests.swift` 和 runner Tools 测试。

**Interfaces:**
- `run-native-scenes.py --derived-data <this-run> --output-dir <new-root> --matrix critical`：执行 U01–U06×light/dark，产出 `native-scenes.json` 与原始 PNG、关键帧审阅清单。
- 报告字段：`runID`, `sourceManifestSHA256`, `binarySHA256`, `scenarioManifestSHA256`, `scenarioID`, `appearance`, `windowKind`, `backingScale`, `steps`, `assertions`, `captureMode`, `reviewStatus`；状态为 passed/failed/blocked_environment/pending_review。
- 同一runner提供 `--record-review <decisions.json> --manifest <native-scenes.json>`：校验当前run/source/binary/场景及必需PNG集合与哈希，写 `ui-review.json`；每帧须有reviewer、verdict、comment。不自动批准模板。捕捉后等待最多180秒，计入native及全程截止；拒绝/缺项/旧记录/超时非零退出。
- 测试动作以目标窗口/应用自己的动作定位；实际 Settings 走产品 scene，禁止用 GUIQA 额外 WindowGroup 代替。

- [x] 先增加两个真实错误通道同时出现的独立文案断言；增加窗口方向检查器的正立、上下翻转、180度旋转负对照。证明倒置会失败，不能只靠 OCR 字符串或非空图片。
- [x] 将 GUIQA fake 模式接入现有 `AdvancedRuntimeGraph` 及隔离偏好；扩展会话重开参数，仅允许已登记QA session。拒绝生产根、外部源、symlink别名；create/delete/auth/通知/登录项等系统动作不得进入真实适配器。
- [x] 通过实际 Settings 入口执行 U01–U06；注入两条错误后选中文字、滚动、resize、重开5次并恢复。每次取得本进程真实窗口像素和几何数据；记录权限/桌面前置条件失败，不自动改变系统设置。
- [ ] 根据真实窗口RED证据修复B03所在渲染边界；复跑相同状态与交互，确认文字正立和恢复过程。不能只调整离屏宿主，也不能删除错误提示掩盖缺陷。
- [x] 捕捉后立即flush图集/待审清单路径和上述录入命令，写pending_review；审阅者在180秒内目视查看U02/U05每个关键帧、每种外观及所有新差异后记录结果。既有离屏矩阵继续覆盖其34场景。文字倒置原因尚未确定，不预先指定删除 `.textSelection` 作为“修复”。
- [x] runner 测试覆盖缺窗口、黑图/锁屏、错误 windowKind、漏场景、OCR自动纠正、旧截图/审阅、缺帧、时间超限、未review；正确本轮审阅应使同一进程继续而不重新构建。输出普通成功不得替代native成功。
- [x] 提交 native harness、场景及必要产品UI修复；真实窗口未成功捕捉时，本任务保持未验收。

## Task 5：时间有界的统一验收与证据

**Files:** `scripts/validate.py`、`scripts/package-release.sh`、`scripts/run-focused-tests.py`、Tools 入口测试、`Design/Validation.md`、`README.md`。

**Interfaces:**
- `run-focused-tests.py --suite startup|recovery|ui|tools --output-dir <new> --derived-data <new>`；suite→精确测试ID由受版本控制的表定义，报告 `scope=focused`。
- `validate.py` / `package-release.sh` 增加 `--ui-profile none|native`，默认 none 保持现有无UI任务；本轮和未来UI改动必须显式native并记录选择原因。`scale-profile` 仍为 release/full。
- `validation.json` 增加 `required_scenarios`, `executed_scenarios`, `environment`, `timing_budget`, `coverage_gaps`, `ui_profile`。packager在同一归档跑全部要求；provenance重复关键身份和profile。

- [x] 先写工具失败测试：必需场景少一项、漏/多/重复规模报告、非白名单skip、focused冒充canonical、UI native缺像素/未review、model/fixture身份不符、截止超时均拒绝。
- [x] 将已有完整 XCTest/Tools/实际模型/两种续体/规模门槛与新场景接入唯一canonical；继续验证精确scale集合。清理过时CI文案时仍使用Task1的精确素材准入，不接受任意环境路径。
- [x] 用单调时钟施加阶段及总截止时间；启动前预检必要GUI环境，native在Debugbuild后、昂贵规模前捕捉并完成180秒内的审阅握手。通过后同一归档继续其余阶段，无二次canonical；无人值守无UI通过不能代替native要求。取消只清理本轮拥有的子进程/临时资源，失败报告在短收尾时间内写完。
- [x] 不重复构建同一native harness；共享本轮debug产物输入时绑定内容hash。保留独立优化宿主、正常Universal和续体RED/GREEN构建，不做跨提交成功缓存或删现有60秒检查。
- [x] 独立review在最终行为快照审查所选profile、冷启动故障覆盖与系统副作用；tester核对同一快照的计时、报告和hash。readonlyreview不触发第二遍全套。
- [x] 更新用户可复制命令和失败处理说明；提交工具与契约。仅脚本成功不算Task6的跨机器通过。

## Task 6：干净环境复现与预算校准（另机为补充）

**Files:** 新建 `docs/testing/README.md`、`docs/validation/2026-10-24-portable-test-strategy.md`；不提交原始私人环境日志。

- [x] 在参考Mac记录同一最终提交的focus热/冷耗时及一次canonical full/native；实际总时长与阶段加和分开。比较新增执行增量90秒目标；超预算先定位，不直接调高阈值。
- [x] 在本机全新clone取得最终提交和固定LFS，按README创建全新依赖和DerivedData；不复制旧work或人工补代码。最终canonical full/native只在这个干净checkout跑一次，记录环境和时长，不另在原工作树重复全量。
- [ ] 证明离线运行、不同checkout路径、空Photos授权/无Apple ID也能完成默认fake测试。检测fixture源前后hash，测试根与生产根无交集；真实PhotoKit层若未执行，明确标为未验证。
- [x] current/arm64是默认验证平台；macOS13回退、14+scene及Intel在可用机器做独立smoke并记录。第二台机器不是本轮阻断条件，未执行就标记跨机未测；本机真实GUI能力缺失仍阻断对应UI验收，不能以离屏替代。
- [ ] 完成覆盖表：每个R/U ID映射测试方法、命令、证据、预算和残余风险。既有两个用户缺陷各自绑定直接RED/GREEN；对系统实测缺口如实保留。
- [x] 提交脱敏验证摘要和复现说明。此计划不自动执行merge/release；如之后按用户授权发布，仍从最终main精确归档执行完整门槛。

## 方案自检

- [x] 覆盖设计R01–R16、U01–U06、冷启动完整路径、持久恢复、方向负对照和独立机器复现。
- [x] 默认测试不依赖生产状态；可提交素材和必须由操作系统提供的依赖已区分。
- [x] 目标耗时基于beta8阶段记录，硬超时、失败处理和未验证平台没有用“自动跳过”掩盖。
- [x] actual graph、adapter、native scene分别有对应证据；未将离屏渲染或fake测试称为真实Photos验收。
- [x] 用户随后已授权实现测试方案及B01–B04修复；按任务记录实际完成证据，不提前勾选通过。

## 实施记录（2026-10-24）

- Task 1：`eccc71d`，固定媒体与环境入口；小型素材约 26 KiB，未改原 33 例字节/真值。
- Task 2：`e67c7d9`、`04d1849`，实际 bootstrap 及三个独立 xctest 子进程。宿主复用同一测试方法的子进程入口，未复制一套 runtime 实现。
- Task 3：`77526c4`、`95251ea`、`472b67a`、`c264fe3`，数据库锁恢复、精确覆盖旧操作、六处崩溃和 20×40 序列；深度评审的 bootstrap 遗漏已修复并直接 RED/GREEN。历史 DDL 覆盖已发布形态；未支持未发布的早期 v11 开发结构。
- Task 4：真实菜单、hover、选择、Picker 的浅色流程已经取得证据；最终两种外观完整 native gate 仍待通过。50 张背景 Settings 图已经审阅，不能代替此门槛。B03 尚未复现，未修改文字渲染或宣称修复。
- Task 5：场景/截止/native/打包证据入口已接入；独立评审发现的私有环境继承和嵌套取消均有失败反例。输入改为定向 PID/AX 并加入真实遮挡拒绝检查，等待最终 native 与 canonical 验证。
- Task 6：将从新 clone、全新依赖和 DerivedData 执行 full/native；第二台 Mac、macOS 13/14、Intel、真实 PhotoKit 和 1×显示器均不预先声称通过。

## 用户批准的 Task 4 调整：XCUITest

用户已明确同意将 CLI 输入驱动换成 XCUITest；原生门槛与生产隔离不降低。

- [x] 新建独立 QA app、UI testing bundle 和共享 scheme，复用真实 @main / Settings / MenuBarExtra、原 advanced graph 与 fake 系统边界；不改发行 target 成员。
- [x] UI test 使用唯一 QA bundle ID，通过 XCTest 的 click/hover/doubleClick 处理带 nonce 的请求和本机回环回复握手；普通点击须命中 QA 当前窗口，保留遮挡拒绝反例。移除旧 CGEvent/AXPress 输入控制器。
- [x] 先以单场景 smoke 验证系统 runner、身份、权限和真实菜单开关。缺系统认证或 Helper 权限停在边界，不自动改 TCC/系统设置。
- [x] 父 runner 保留8分钟截止；QA启动须持有有效租约，取消后拒绝晚启动，已启动 QA 有独立寿命上限并按本轮路径/PID回收；Xcode子链取消与既有证据审阅契约保持。
- [x] 接回 full/native canonical，记录真实 UI test 完成结果、截图和逐帧审阅；最终集成审查只覆盖此新增范围，已审稳定 Core不重审。

第一次 XCUITest smoke 的构建成功，但测试 runner 初始化被 macOS LocalAuthentication 拒绝：认证已取消 / System authentication is running。QA尚未启动，已向用户询问系统认证状态；这不是产品UI失败或通过证据。

## 2026-10-25 原生门槛结果

- 首次系统认证在显示提示前被另一认证取消；用户反馈未看到提示。一次正常重试随后进入真实 XCTest，没有更改 DevToolsSecurity、TCC 或系统设置。
- UI runner 的系统沙盒不允许写 checkout，改为仅本机回环、令牌与当前请求核验的回复通道；主程序与 embedded Core 均在启动前绑定，运行及复制后复核。
- `xcui-critical-6`：真实 1 项 XCTest 通过（185.809 秒），54 张浅深色原生窗口图逐帧审阅通过（152.8 秒内），4 次真实 hover，3 个 PID / 2 次重启，文字选择和设置持久化通过。
- 浮层捕捉曾拿到展开动画的极小中间帧；改为有界轮询等待同一窗口合成像素达到原生尺寸（最多40次、间隔50毫秒，截图调用计入总截止）。没有点击回退，漏 hover 证据会失败。
- B03 仍未复现、未修复；不能勾选该直接修复项。固定宽度窗口的 resize 尝试不构成任意尺寸兼容验收。
- Task 4 的驱动和实际场景验证已完成，提交后仍需最终新 clone 的 full/native；Task 6 尚未完成，未 merge/release。

## 最终验证记录（2026-10-25）

- 行为/测试定稿 `944e04a9034142beaa27d6d72095493d56598555`；新 clone、全新 venv/LFS准备/DerivedData 的 full/native 通过，1,491.211秒 /2,100秒。
- 983 XCTest（2登记跳过/0失败）、132 Tools、R01–R16、4档规模、两组续体、54帧本轮原生截图审阅全部通过，446项源码清单前后不变。
- startup聚焦入口新DerivedData总计70.204秒（60项通过），复用构建15.608秒（同60项），没有重复跑全量。
- B03直接复现/修复仍未完成，因此相关勾选保留；其余R/U覆盖已有对应当前证据。没有通过断网或注销Apple ID做系统实验；默认fake入口不请求Photos，依赖准备后无需下载。第二台Mac及旧OS/Intel/1×仍未验证。
- 验证详情见 `docs/validation/2026-10-24-portable-test-strategy.md`；不执行merge/release，生产环境保持不变。
