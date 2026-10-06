# PhotosYNC 0.2.0 真实 Photos / iCloud 验证 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 沿用已选子代理方式，按 AGENTS.md 缩放审阅，不重复等价检查。

**Goal:** 在明确授权的小范围图库中，验证实际 PhotoKit 表示读取、变化索引、自动判重和 iCloud 等待恢复，同时核对来源不变及 PhotosYNC 只新增。

**Architecture:** 独立 QA 宿主链接冻结提交的原始 PhotoSyncCore，注入 UUID 测试数据库和限定来源，调用实际 PhotoKit 适配器。宿主只增加范围、提交次数和证据记录限制；不改变判重、索引或恢复算法。先完成本地功能，再进行有云端前置证据的测试；不直接启动会加载生产配置的正常 App 或旧 GUI_QA 入口。`--demo` 仅提供演示状态，不能作为实际 PhotoKit 系统验收入口。

**Tech Stack:** Swift、公开 PhotoKit、Core ML、现有 SQLite / runtime、原生 AppKit / SwiftUI；本机 Apple Silicon。测试观察数据保留在 ignored `work/`。

**Spec:** [高级判重 spec](../superpowers/specs/2026-09-28-photosync-0.2.0-advanced-dedup-design.md) §3–5、§7.1、§8–11；[运行时契约](../specs/2026-09-18-runtime-state-and-recovery.md)；[历史系统验收](../../Design/Validation.md)。

**状态：仅计划，未执行。** 前置实现 `bc27a425e2c7b6f1913c7f895104d35e57ddbd96` 已通过独立源码审阅、完整自动验收和正常 Universal 构建；详细证据见[当前验收记录](0.2.0-advanced-dedup-validation.md)。本计划不授予尚未确认的账号、图库、资产或网络设置操作权限。

## Global Constraints

- 固定 `fp16-ane-gpu-v1`、已绑定 FP16 模型、Float32 IO/1024 维向量、`score >= 0.98`；不重新调阈值、改真值、加人工判重或第二模型。
- 来源只读；PhotosYNC 只新增，导入原始 URL、`shouldMoveFile = false`。编辑/撤销/删除场景由测试操作者在 Photos 中对明确列出的 QA 资产执行，不能由产品模拟删除或修改。
- 新请求遵守实际并发、512 MiB 解码预算和暂停/授权规则；已有物理任务返回前不释放资源。未知提交保持 unknown/importing，不能因查询不到而重试。
- 不读取或清理生产数据库，不自行切换系统图库、创建账号、登录 Apple 账号、改变 iCloud 存储设置、清除 Photos 缓存或全局断网。凭据由用户在系统界面输入，不进入日志或聊天。
- Intel 执行已排除；macOS 13 实机缺口保留。当前机器的构建/运行不能代替这些平台。
- 本地 2 秒准备预算不包含 iCloud 等待、PhotoKit 提交或整个初次索引；不把合成 100k 测试等同真实十万资产验收。

## Review Focus

1. 缩略图可用但原始表示仍需联网：V3 必须按版本、请求尺寸和最终回调判断，不能从“优化存储”选项推断云端状态。
2. 原版和编辑版内容/尺寸错配：V2 分别验证它们的向量与自身尺寸，不借原版尺寸覆盖编辑版。
3. 外部变化发生在准备和提交之间：V2/V4 核对索引失效和最终代次，过期证据不准新增。
4. 取消/暂停只结束逻辑等待：V4 核对后续请求、物理占用与恢复，不把没有回调当成物理终止。
5. 成功历史与已有高分辨率资产污染下一例：V1/V2 固定顺序和初始资产集合，不以删库重置制造预期结果。

## 环境选择与授权清单

首选一个用户确认的独立 macOS 测试账号及其系统图库，图库内只有已确认的少量测试素材；需要 iCloud 时由用户准备该账号的 iCloud 环境。无需另找 macOS 13 设备。

若没有独立 iCloud 测试环境，可把本地新增/编辑/删除验收与云端读取拆开：在独立本地图库验证写入；另行明确授权最多 10 个现有个人资产的**只读**云端探针。该模式编译/装配时禁用全部 Photos 写接口、来源扫描和导入；只能证明限定表示的读取及恢复，不能声称完整个人图库同步通过。没有合格云端样本时保留 iCloud 缺口，不能强制驱逐原片。

执行前填写 `scope.json`：`runID`、实际源码提交、主机/系统、测试账号和系统图库确认记录、模式（`isolated-system-library` / `asset-read-only`）、允许来源根路径、允许资产标识、最多新增数量、允许由操作者编辑/删除的 QA 标识、是否允许前台交互及实际网络中断。未确认的字段对应动作不执行；其他独立步骤可继续。设置或账号变化由用户完成并记录，不要求把凭据交给代理。

默认先一个素材家族，QA 新增预算最多 8 个资产；预算是限制，不要求用满。个人只读模式预算恒为 0。不得为追求通过清空现有图库；遇到未确认的资产干扰，应先报告前置条件不符。

## 文件与接口

| 位置 | 责任 |
| --- | --- |
| `work/real-photos-icloud/<runID>/scope.json` | 本次明确范围、授权与固定身份；仅本地保存 |
| 同目录 `Harness.swift`、`HarnessTests.swift`、`build-qa.sh`、`Info.plist` | 唯一 QA bundle ID、真实 Core、假后端范围防护测试；临时宿主不进入产品 |
| 同目录 `source/`、`source-manifest-before.json` / `after.json` | 冻结素材副本、尺寸/mtime/字节校验；准备完成后设只读 |
| 同目录 `evidence/<caseID>/` | 请求/回调、runtime/index 快照、QA DB、操作日志、度量和原生 UI 证据 |
| `docs/release/<实际执行日期>-real-photos-icloud-validation.md` | 脱敏后的逐例结果、源码身份与未测范围；执行结束才创建 |

宿主提供 `preflight`、`local-flow`、`cloud-probe`、`recovery` 四个阶段命令，每个均必须显式传入 `--scope <scope.json> --output <新目录>`，拒绝复用输出路径。`cloud-probe` 另需资产 ID、`original/current` 和 `network-off/network-on`；用与产品相同的请求尺寸、质量、resize 和 content mode。其他场景参数由已验证的 scope/清单读取，不接受任意图库路径或绕过范围的参数。

输出 `result.json` 至少包含：`caseID`、`status`（passed/failed/blocked/not_run）、源码/模型/策略身份、前置条件、预期/实际决定和动作、发生次序及时间、Photos 请求/回调/版本信息、索引和提交证据、边界检查、未证明事项。记录 requested backend 与数值自检，不从配置名推断实际硬件。私有 ID、路径、系统错误原文保留本地；共享报告用本次随机代号，不能输出完整照片向量或原图。

### Task V1：封定环境与安全宿主

**Files:** 上述 scope、宿主/测试及 source 清单；只读复用产品 `AdvancedRuntimeGraph`、`PhotoKitGateway`、`PhotosRepresentationReader`、`SyncRuntime`。不修改产品持久化或同步算法。

- [ ] 记录授权范围并检查主机、构建、有效模型/策略、可用空间、Photos 授权状态和测试库基线；权限不足时在已同意的 QA 账号正常请求系统授权，不替用户点击批准。
- [ ] 先用假网关验证宿主的三项拒绝行为：`testReadOnlyModeRejectsEveryCreate`、`testUnlistedSourceAndAssetAreRejected`、`testSubmissionBudgetStopsNextCreate`；断言 PhotoKit 调用计数为 0 或不超过 scope 上限。再装配真实适配器，保持这些外层限制。
- [ ] 构建唯一 QA bundle，独立 Application Support/UUID DB，禁用登录项、系统通知和自动读取生产配置。确认没有正常 App/旧 GUIQA 入口；只在明确允许的测试时段启用前台交互。
- [ ] 选择当前冻结用例的公共素材，按 `active-suite.json` 过滤、从 `expected-results.json` 读取真值。`manifest.json` 的 44 例及 `expected=null` 是历史内容记录，不能当作未审批的新真值。复制到 QA 来源后记录哈希/属性并设只读；不访问 Downloads 或用户 Photos 来扩充测试集。
- [ ] 宿主假后端检查、资源校验和范围报告通过后，再允许第一个真实请求。保存阶段结果，不提交个人媒体、数据库、宿主 bundle 或权限数据到 Git。

### Task V2：真实本地 PhotoKit 与自动决策

**Interfaces:** 消费 V1 的 scope/固定来源；使用实际表示读取、索引协调器、SQLite 查询和导入状态机。每个决定记录候选表示、score、尺寸、expected/actual action；测试真值不变。

| 次序 / 用例 | 操作与预期 |
| --- | --- |
| L1 高清保留（B002） | 库中先只有批准的半尺寸副本，再提供对应高清来源：内容判重但仍导入，恰好新增 1 个资产。先做这一例，防止已有高清资产或成功历史改变前提。 |
| L2 副本（P001/P003/P004/P005） | 以 L1 已有高清图为候选，分别提供改名、压缩、缩小、PNG 副本：判重并跳过，新增 0。 |
| L3 真实相似（N001） | 提供另一次拍摄的相似公共素材：判不重并导入。不能只核对标题/文件名。 |
| L4 原版/当前版 | 操作者只对已指定 QA 资产在 Photos 做明显裁剪，并导出当前呈现作新的只读来源。分别证明 original 与 current 对应各自输入/尺寸；对编辑前、后来源都能找到正确表示。不得把“另导入一张裁剪图”当作 current 版本验证。若不能形成可区分表示，记前置未满足，不改阈值。 |
| L5 外部新增、编辑、撤销 | 从 Photos 外部加入已批准 QA 图，再编辑/撤销指定 QA 资产。观察变化通知、表示失效、受影响资产重新计算及真实 ready token；未变资产不重做图像推理，索引不完整时不新增。 |
| L6 外部删除与成功历史 | 操作者删除一个明确授权、曾由 QA PhotosYNC 成功导入的资产。索引移除对应表示，但成功关系/指纹保留；重新出现的已成功来源不自动补回。删除仅限 scope 列出的测试资产，不能清理其他资产。 |
| L7 重启与周期检查 | 关闭并重启 QA 宿主，复用该 QA DB；检查离线期间变化。至少观察一次真实 30 分钟周期检查；无变化时图像读取/推理为 0，正常单资产变化走增量；不能用重启代替周期触发证据。 |

- [ ] 按表顺序记录每例初始 ID 集合与成功历史，执行一次，核对 PhotoKit 成功回调、placeholder/assetID、SQLite 最终状态与最终实际资产集合。
- [ ] 对 L4/L5，保存修改前后 representation revision、kind、尺寸和 source→original/current 分数，不要求跨 API 图像字节或向量逐位相等；明确区分策略结果与表示来源。
- [ ] 对 L5/L7，记录元数据枚举数、图像请求数、推理数、变化代次和就绪终点。全量对账仍可读取清单，不能把“未推理”写成“完全没读取 Photos”。
- [ ] 每阶段对比来源清单与 Photos 集合；PhotosYNC 的变更只能是计划中的新增。操作者的外部变更单独列账，不混入产品只增不删结论。

### Task V3：证明需要云端的请求及实际读取

**Interfaces:** `cloud-probe` 使用公开 `PHImageManager` 的同版本/同尺寸请求；产品集成仍使用 `PhotosRepresentationReader`。底层 API 探针不能代替产品读取得分/状态证据。

- [ ] 先对范围内一项资产的 `original`，必要时另对 `current`，关闭该请求的网络访问。只有拿不到可用最终表示且回调明确 `PHImageResultIsInCloudKey == true`，才记录“此时此请求需要云端”。缩略图、优化存储设置、元数据或本地文件搜索都不能代替这项证据；不扫描 Photos 私有包目录或用私有 KVC 判断。
- [ ] 若不满足前置条件，改用范围内下一项，最多 10 项；仍不满足则 V3 标 blocked。不能清理缓存、删除原片或扩大资产范围来强造条件。其他已完成结果保留。
- [ ] 对同一 ID/version/request 配置启用网络，先单个请求；要求最终非 degraded、非 cancelled、无 error 的图像，记录耗时和回调次序。再经实际产品读取/指纹/索引路径核对该表示从未完成到有效 ready；等待期间不得当作不重导入。
- [ ] 若 `current` 是独立编辑表示，单独证明并记录其前置与结果；原版请求需要云端，不代表当前版也需要云端。请求期间发生编辑时按新 revision 重试，旧结果不得发布为当前就绪。
- [ ] 核对应用自己的 QA 数据目录：仅允许指纹/必要信息、日志和编译模型缓存；没有复制的原片/预览文件。Photos 自身缓存由系统管理，不要求下载后永久常驻，也不尝试强制保留或驱逐。

产品的目标尺寸 bitmap 请求通过，只能证明拿到了判重所需表示。若另外需要回答“完整原始文件是否能取出”，单独用 `requestImageDataAndOrientation`（无 targetSize 参数）或 `PHAssetResourceManager.requestData`，在该测试范围内有界记录成功、格式和交付数据字节；不得据此改变产品为整库原片下载。交付数据字节不等于网络传输字节。相关公开接口见 [PHImageRequestOptions](https://developer.apple.com/documentation/photokit/phimagerequestoptions)、[PHImageManager](https://developer.apple.com/documentation/photokit/phimagemanager)、[PHAssetResourceManager](https://developer.apple.com/documentation/photokit/phassetresourcemanager)。

### Task V4：等待、暂停、权限与重启恢复

**Interfaces:** 复用同一 QA DB/来源，保留各例意图、成功及未知证据；只对已批准的测试宿主进程操作，不影响生产实例。

- [ ] 在 V3 已证明需要云端的请求上验证禁网等待。实际断网/恢复只在 scope 明确允许的网络与时段进行；没有这项授权时只报告请求级禁网证据，不宣称真实网络恢复通过。
- [ ] 在请求或推理执行期间暂停、停用最后一个来源；确认停止新请求/模型阶段，既有物理占用保留至实际返回，已成功完成的结果按原有规则保存。恢复后重做未完成项，不重做完整图库。
- [ ] 在 QA 环境撤销并恢复 Photos 授权，记录观察时序和状态。撤权期间不开始新模型/提交，恢复重新核对上下文；不能把权限受限时的空 fetch 当成资产不存在。
- [ ] 分别在索引未完成、已完成及一次提交结果不明确时重启测试宿主。未知场景优先采用受控测试出口，不随机杀生产进程；检查原有 unknown/importing 证据保留，不因一次 fetch 未命中就再次新增。
- [ ] 当前产品未保留 `cancelImageRequest` 的请求 ID，暂停属于停止新任务和逻辑等待控制。单独 API 取消实验如另行运行，只记录公开 API 的表现；不能当成产品已实现强制取消下载，也不能用没有回调证明物理请求结束。
- [ ] 每种故障恢复后再次核对来源哈希、资产增删账、提交次数和资源占用。出现未知结果后先停止新提交并保存现场，不删除 QA DB“重试一次”。

### Task V5：真实资源、原生交互与交付结论

- [ ] 分别记录模型准备、图像读取/云端等待、预处理/推理、SQL 查询、提交/回调、Photos 变化至 ready 的耗时；记录样本数、冷/热缓存前提，单次值不包装成 P95。
- [ ] 在一个实际 QA App 图形/运行图中测量初始状态、分析后、至少 60 秒闲置、恢复查询的 footprint/RSS/CPU/进程 IO。当前合成宿主同时保留重启前后对象，87.2 MiB 闲置 footprint 不能直接代表真实常驻 App；需独立复核。Photos/iCloud 系统进程的流量/磁盘写入不能仅归因于 QA 进程计数。
- [ ] 在用户同意的测试账号前台时段检查真实菜单弹出、键盘遍历、焦点、AX 控件角色/标签/启用状态及 VoiceOver 听读，覆盖分析、等待、暂停、就绪隐藏和来源不可用。没有合适时段则明确保留缺口；现有后台原生暂停/恢复动作及离屏渲染不替代这些证据。
- [ ] 保存逐例 passed/failed/blocked/not_run、来源及 Photos 差异、源码/模型身份、原始日志摘要和限制。独立 reviewer 核对证据与结论；只修本范围明确缺陷，若需要产品改动则先复现、最小修复、对应审阅与当前完整自动验收。
- [ ] 更新脱敏验收文档及合并准备记录。保留 QA DB/日志用于追溯；只有获得明确清理授权才删除指定测试资产。真实十万资产、长期能耗、macOS 13、公开发布/安装均不由这组小样本自动推导为通过。

## 停止条件与结果边界

发生越界来源/资产、非预期 Photos 写入、来源字节变化、索引未就绪仍新增、未知提交重试、未终止物理任务却释放额度，立即停止新工作并保留证据。触及范围/新增预算或缺少云端前置时停止相应阶段，不放宽边界或改标签。

本计划完成小范围系统验收后，再决定是否进行真实大图库的分阶段分析和长期资源观察；那需要明确图库范围、可接受下载和运行时间。PhotoKit 的目标尺寸、进度或返回数据长度均不是严格网络字节上限，不能承诺固定下载配额或永久驻留。当前计划不执行合并、推送、发行、安装或生产数据维护。
