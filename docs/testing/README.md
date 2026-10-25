# 可复现测试

默认测试只读仓库内登记的素材，使用 UUID 临时 SQLite 和 fake Photos。它不读取生产图库、生产数据库或历史生产副本，也不启动已安装的 PhotosYNC。系统 PhotoKit/iCloud、另一台机器和最低系统版本的验收分别记录，不能用这些自动测试替代。

## 准备一次

在新 checkout 的根目录执行。需要完整 Xcode、Python 3.10+、Git LFS、`rg` 和 macOS 自带工具；参考环境是 macOS 27.0.1 / arm64、Xcode 27.1 / Swift 6.4。此版本号是已测环境，不表示其他版本已验证。

```sh
python3 scripts/test-environment.py --prepare --root "$PWD/work/test-environment"
```

准备过程最多 10 分钟：获取当前提交所需的 LFS 对象，检查固定媒体、模型及授权清单的 SHA256，建立独立 venv，以固定 wheel 哈希安装 Pillow 12.3.0。它不安装 Xcode，不改全局 Python/Git 设置，不覆盖已被修改的模型。失败后查看输出，选择新的 work 目录显式重试。

后续命令都使用刚创建的 Python。`--check` 与所有测试默认不安装依赖、不下载素材：

```sh
work/test-environment/venv/bin/python scripts/test-environment.py \
  --check --output "$PWD/work/environment-check.json"
```

提交了少量 CC0 自制 HEIC/JPEG/MOV（含 10 秒边界和损坏文件）、12 份 Git 提交固定的历史 DDL、生成方法和预期元数据。已有 33 例图片及其项目测试授权保持原样；授权不推广到用户的其他照片。模型保留 Git LFS，不提交机器编译缓存、个人数据库或截图。

## 开发时只跑相关检查

```sh
work/test-environment/venv/bin/python scripts/run-focused-tests.py \
  --suite startup --output-dir "$PWD/work/focus-startup" \
  --derived-data "$PWD/work/focus-startup-derived"
```

可选 `startup`、`recovery`、`ui`、`tools`。每次使用新的输出和 DerivedData 路径；上限 8 分钟。结果是 `focused.json`，不能冒充完整验收。直接调用底层 XCTest 可用于热构建诊断，但也不是 canonical 证据。

## 完整验收

```sh
work/test-environment/venv/bin/python scripts/validate.py \
  --scale-profile full --ui-profile none \
  --output-dir "$PWD/work/validation-full" \
  --derived-data "$PWD/work/validation-full-derived"
```

`release` 默认跑 200k 表示 + 100k 成功历史，上限 25 分钟；`full` 跑原有四档，上限 35 分钟。本轮修改启动、SQLite 和测试资源行为，必须选择 `full`。两档都保留完整 XCTest、Tools、实际模型 33 例、两种续体 RED/GREEN，以及最大混合规模档的真实 60 秒空闲检查。原性能阈值不变。

R01–R16 的对应测试记录在 `Tests/Support/RuntimeScenarios.json`。结果同时核验三进程冷启动、六处崩溃边界和 20 个种子 × 40 个合法事件的独立报告；仅有“总测试数大于零”不能替代这些场景。默认入口清除私有复放和内部子进程环境变量；外部 corpus 路径必须被素材门槛拒绝。`CI=true` 使用同一门槛。

超时、取消、未知跳过、缺场景或旧报告均失败，不自动重跑至通过。取消会通知有独立 session 的嵌套 runner，再清理本轮拥有的进程组；QA 使用可撤销启动租约及独立寿命上限，并按本轮精确可执行路径清理。强制收尾最多额外 8 秒。只读复核不要求重复跑同一快照。

## UI 改动的真实窗口验收

本轮及后续 UI 改动必须把上述命令改为 `--ui-profile native --ui-allow-focus`。这是显式允许测试应用短暂取得焦点；不应在未获许可时使用。原生阶段在 Debug 构建后、昂贵规模测试前执行，上限 8 分钟，计入总截止时间。

需要登录桌面及执行器已有的辅助功能/输入/窗口读取能力。脚本不请求或更改系统权限；缺能力就报 `blocked_environment`。前台 QA 使用独立 app/UI-test target，由 XCUITest 启动并驱动真实 `PhotoSyncApp` 的 Settings/MenuBarExtra scene，保持菜单栏应用的激活策略。Xcode 的系统认证和 Xcode Helper 权限必须由用户处理；脚本不自动启用开发者模式或修改 TCC。macOS 13 设置回退仍需另行 smoke，当前原生 runner 只支持 macOS 14+。

U01–U06 在浅/深两种外观下执行：一项/两项任务、已知/未知进度、双错误与恢复、等待/暂停、任务 hover、五次重开、文字选择/滚动和内存档持久化。注入的系统调用均由 fake 拒绝。XCTest 只查询本轮唯一 QA bundle 的控件，普通点击拒绝被遮挡或未激活的窗口；状态栏只点击该 app 的唯一可命中 status item。真实遮挡负对照也必须通过。内存档在两种外观下均经过 QA 进程终止/重启，不能用同进程替换 runtime 冒充。

Xcode 的 UI runner 保持系统沙盒：读取本轮请求，通过只监听 `127.0.0.1` 的临时通道回复；协调器校验随机令牌及当前请求 ID 后只写固定回复文件。主程序和嵌入 Core 在启动前冻结哈希，运行后及复制证据后再次核对。测试不会为写入 checkout 放宽沙盒。

hover 必须实际打开浮层并在指针移出后关闭，不能用点击补过。浮层展开期间，WindowServer 可能先给出极小的动画帧；驱动有界等待原生窗口与合成像素尺寸一致（最多40次、间隔50毫秒，截图调用仍受总截止约束），再检查实际文案。单独的 `--matrix smoke --allow-focus` 只验证少量设置场景和菜单开关，报告标为 smoke，不能满足 native 完整门槛。

每张 PNG 来自 QA 自己的 WindowServer 窗口，记录尺寸、倍率及任务身份。方向检查比较文字几何，不用会自动纠正倒字的 OCR 作为方向证明。自制上下翻转/180 度负对照必须失败。

捕捉后 runner 输出 `NATIVE_REVIEW_PENDING`，生成 `native/index.html` 和 `review-decisions.json`。审阅者须在 180 秒内查看实际图片，逐帧填写 reviewer、pass/fail 和观察，再执行：

```sh
work/test-environment/venv/bin/python Tests/UIReview/run-native-scenes.py \
  --record-review "$PWD/work/validation-full/native/review-decisions.json" \
  --manifest "$PWD/work/validation-full/native/native-scenes.json"
```

缺帧、拒绝、过期、变化后的像素/二进制或另一轮记录不能通过。完整本轮审阅通过后，同一 canonical 进程继续后续检查。`--settings-only --allow-focus` 只是前台设置专项，仍使用 XCUITest，不能满足完整菜单矩阵的 native 门槛。另有既存离屏工具用于快速布局诊断，但不会被此入口接受为原生证据。

可在捕捉过程中先查看已经写完的 PNG；最终仍须对本轮清单中的每一帧核验哈希并明确审阅，避免把全部阅读挤到最后 180 秒。窗口宽度由产品固定，调整大小的尝试不等于已验证任意宽度布局。方向回归通过也不能代替尚未复现的间歇性倒置问题的直接修复证据。

## 新机器和发布边界

从新 clone、全新 venv 和 DerivedData 运行以上命令，不复制旧 work、成功标记或模型编译缓存。默认 fake 测试不需要 Photos 授权或 Apple ID。没有第二台 Mac 时记录“跨机未测”，同机新 clone 不称为跨机验证；Intel、macOS 13/14、真实 1×显示器和 PhotoKit 的缺口单独保留。

本轮开发验收不自动 merge/release。之后如获发布授权，使用 `scripts/package-release.sh --scale-profile full --ui-profile native --ui-allow-focus`，并让 PATH 优先使用准备好的 venv。打包仍从干净已提交的精确归档执行完整验收，随后正常 Universal 构建、签名、DMG及校验；包装阶段上限 6 分钟，总上限 release/full 为 35/40 分钟。既有发布目录不覆盖。

## 已测耗时

在上述参考环境、提交 `944e04a` 的全新本地 clone 上，full/native 为24分51秒（上限35分钟）；含983项XCTest、132项工具测试、四档规模、两组续体及54帧真实UI审阅。startup聚焦入口的新DerivedData构建加60项测试为70秒，复用构建后相同测试约16秒。其他机器以实际报告为准，超时仍失败。详情见[本轮验证记录](../validation/2026-10-24-portable-test-strategy.md)。
