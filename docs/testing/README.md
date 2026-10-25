# 验证与发布

测试应可在新 clone 重现，耗时有上限。默认只用仓库登记素材、UUID 临时 SQLite 和 fake Photos，不读个人图库、生产数据库或其副本，不启动已安装 App。

## 运行入口

需要完整 Xcode（图标编译需 26+）、Python 3.10+、Git LFS、`rg`。参考机为 macOS 27.0.1 arm64 / Xcode 27.1 / Swift 6.4，不等于其他平台已测。

```sh
# 首次准备：独立 venv、固定 wheel/素材/模型校验；最多 10 分钟
python3 scripts/test-environment.py --prepare --root "$PWD/work/test-environment"

# 开发：startup / recovery / ui / tools，最多 8 分钟
work/test-environment/venv/bin/python scripts/run-focused-tests.py \
  --suite startup --output-dir "$PWD/work/focus-startup" \
  --derived-data "$PWD/work/focus-startup-derived"

# 完整验收：每次使用新的输出和 DerivedData 路径
work/test-environment/venv/bin/python scripts/validate.py \
  --scale-profile full --ui-profile none \
  --output-dir "$PWD/work/validation-full" \
  --derived-data "$PWD/work/validation-full-derived"
```

准备后用 `test-environment.py --check --output <路径>` 核查；检查/测试不会自动下载、安装或改全局环境。模型和媒体清单是硬输入，见 [test-environment.json](../../Tests/Support/test-environment.json)。

| 选择 | 范围与上限 |
| --- | --- |
| `release`（默认） | 20 万表示 + 10 万成功历史；验收 25 分钟，含包装总上限 35 分钟 |
| `full` | 10/15/20 万表示 + 最大混合历史档；验收 35 分钟，含包装总上限 40 分钟 |
| `native` UI | 真实窗口阶段最多 8 分钟，计入验收总期限；需要已获焦点授权 |

索引、候选查询、缓存、SQLite、预处理/模型、资源或规模门槛变更选 full；普通迭代可用 release。前三档分别覆盖 0%/50%/100% 编辑比例，最大混合档不能替代这三种形态。

## 什么算通过

两档均执行完整 XCTest、Tools、33 例实际模型回归、[R01–R16](../../Tests/Support/RuntimeScenarios.json)、跨进程恢复/崩溃/固定事件序列、两种续体 GREEN/预期 RED、规定规模档及真实 60 秒空闲检查。所有报告必须绑定同一源码；零测试、未知跳过、缺场景、缺/旧/错哈希报告、超时均失败，不自动重跑直到通过。

- 聚焦测试或直接 `xctest` 用于诊断，不能冒充 canonical。只读 review 不要求重跑同一未变快照。
- 取消仅收尾本轮拥有的进程，最多额外 8 秒；不降低阈值、放宽授权或读生产数据换取通过。
- 场景名不是覆盖证明。共享逻辑改动要从真实业务路径注入系统边界事件；[当前缺口](../README.md#当前未解决)不可因现有总测试通过而抹掉。

## UI 验收

UI 改动把完整命令改为 `--ui-profile native --ui-allow-focus`；没有本次焦点授权时不能使用该开关。需已登录桌面和执行器所需权限；脚本不改系统权限，缺能力报 `blocked_environment`。XCUITest 只操作独立 QA bundle、fake Photos 和真实 Settings/MenuBarExtra scene；目前 runner 支持 macOS 14+。

U01–U06 覆盖浅深色、单/双任务、已知/未知进度、错误/恢复/暂停、真实 hover、五次重开、文字选择/滚动及跨进程内存档持久化。只截 QA 自己的窗口；hover 必须由悬停打开并离开关闭，不能用点击补过；方向检查含翻转负对照，OCR 自动纠正不是证明。

出现 `NATIVE_REVIEW_PENDING` 后查看 `native/index.html`，在 180 秒内逐帧填写 `review-decisions.json` 的 reviewer、pass/fail 与观察，再记录：

```sh
work/test-environment/venv/bin/python Tests/UIReview/run-native-scenes.py \
  --record-review "$PWD/work/validation-full/native/review-decisions.json" \
  --manifest "$PWD/work/validation-full/native/native-scenes.json"
```

可在捕捉时提前看已完成的帧。缺帧、过期、像素/二进制变化或他轮记录不接受。smoke、settings-only、离屏渲染不满足完整 native 门槛；人工验收只能覆盖明确看过的场景。

## 打包与升级

```sh
# profile 按改动选择；UI 参数仅在该轮已获授权时添加
PATH="$PWD/work/test-environment/venv/bin:$PATH" \
  scripts/package-release.sh --scale-profile full --ui-profile native --ui-allow-focus
```

脚本从干净已提交源码归档，在归档内完整验收后正常构建 Universal Release，核对版本/channel/build、App/Core 双架构、模型、图标、逐层签名、DMG、provenance 和 SHA256。已有目录/锁不覆盖，失败不留成功包；不安装或启动生产 App。包内发行说明来自根 [CHANGELOG](../../CHANGELOG.md)。

当前产物是 ad-hoc 签名，不等于 Developer ID、公证或 Gatekeeper 验收。新版本升级前退出 App、备份完整 Application Support/PhotoSync（含 WAL/SHM）；不支持直接降级，不用旧库覆盖新成功历史。

## 系统证据与缺口

| 已有证据 | 能说明什么 |
| --- | --- |
| 0.2 定向真实 QA：256 资产 / 262 表示、3,017 来源；87 组盲审为 36 重复 / 50 不重 / 1 不确定 | 86 组已定结论与算法一致，仅限候选范围；无全库召回或统计误跳过率保证 |
| 自制 canary 导入、同路径/改名防重、精确删除后保留成功历史 | 该授权范围的真实 PhotoKit 路径通过，不能推广成后续写入授权 |
| 0.3 自制照片/MOV/完整 Live Photo 共 3 项创建、原资源/身份/音轨验证及精确清理；PHLivePhotoView 播放 | 验证限定原生路径；最近删除保留，未验证 Photos.app 手势或外放听感 |
| beta9 的 full/native 归档验收 | 同一源码自动回归与真实 QA UI，通过不证明现场偶发倒字已修复 |

必须联网的 iCloud-only/跨设备传播、第二台 Mac、macOS 13/14 与 Intel 当前运行时、真实 1×屏幕及完整 VoiceOver 仍未覆盖。最低部署版本/Universal 编译或同机新 clone 不等于这些实机验收。

普通 beta 可复用未变系统边界的历史证据；更改 PhotoKit 提交/授权/媒体读取或平台假设须补针对性验证。真实写入使用获准测试图库及自制素材，先记录精确新增范围，清理只限有成功证据的 QA 项；不切换图库、开关 iCloud 或清空最近删除。自动 fake 通过不能代替它。

素材入口：[照片回归与许可](../../Tests/Fixtures/AdvancedDedup/README.md)、[Live Photo 自制素材](../../Tests/Fixtures/LivePhotoPortable/README.md)、[历史 schema](../../Tests/Fixtures/SchemaHistory/README.md)。历史原始报告用 Git 或对应发布包查询，不随版本重复抄入文档。
