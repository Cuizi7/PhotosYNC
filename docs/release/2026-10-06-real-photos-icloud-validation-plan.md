# PhotosYNC 0.2.0 本机生产 Photos / iCloud 验证 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 沿用已选子代理方式及 AGENTS.md 的风险分级，不重复等价检查。

**Goal:** 在本机正在使用的生产系统图库中，先只读验证真实照片、iCloud 和待导入目录的判重，再做有严格上限、可精确回收的写入，核对恢复原状。

**Architecture:** 同一个生产 Photos 图库，另用唯一身份的 QA 宿主及独立配置、数据库、索引和日志，复用冻结产品 Core / runtime。只读阶段从装配上禁止 Photos 变更，并停在准备决定之后；最后阶段才装配受清单和次数约束的创建入口。回退是测试宿主针对本次确证新增 ID 的收尾，不进入产品，也不通过覆盖生产数据库或还原整套图库完成。

**Tech Stack:** Swift、公开 PhotoKit、Core ML、现有 SQLite / runtime、原生 AppKit / SwiftUI；本机 Apple Silicon；私有证据仅保留在 ignored `work/`。

**Spec:** [高级判重 spec](../superpowers/specs/2026-09-28-photosync-0.2.0-advanced-dedup-design.md) §7.1、§7.4；[运行时契约](../specs/2026-09-18-runtime-state-and-recovery.md)；[历史系统验收](../../Design/Validation.md)。

**状态：计划已按用户新约束修订，未执行。** 用户已授权本机生产图库用于测试，明确“先只读、最后写入、有防御、写后恢复原状”；不再要求独立账号或另一个图库，也不重复询问是否允许使用生产图库。具体路径、资产和运行基线在 V1 记录。实现基线 `bc27a425e2c7b6f1913c7f895104d35e57ddbd96` 已通过自动验收，详情见[当前验收记录](0.2.0-advanced-dedup-validation.md)。本轮仅改计划，不开始测试。

## Global Constraints

- 产品仍为 `fp16-ane-gpu-v1`、Float32 IO/1024 维向量、`score >= 0.98`、512 MiB 解码预算、单物理模型队列；不重新调阈值、改真值或加产品人工审核。
- 来源严格只读：不改内容、metadata、权限、文件名、位置或写标记。QA 素材可以复制到独立 scratch 后改副本文件名，原始字节不变，仍用原始文件 URL、`shouldMoveFile = false` 导入；真实来源不能 chmod 为“只读”。
- 现存 Photos 资产、相簿及原有最近删除项目不编辑、不删除、不移入相簿；产品只新增。测试编辑/撤销及收尾只作用于本次确证新增项，不为测试借用一张既有照片做破坏性实验。
- 不切换系统图库、创建账号、更改 iCloud/优化存储、驱逐原片、填满磁盘、全局断网或撤销生产 App 权限。QA 自身的授权请求使用正常系统流程；模拟拒绝与请求级禁网须标为注入/API 证据。
- 不以正常 App、旧 GUI_QA 或 `--demo` 替代受防护宿主；不打开生产数据库做迁移或写测试状态，不把旧备份覆盖回生产库。
- Photos 读取会影响系统缓存并可能触发下载；“只读”指不变更照片/相簿内容，不等于零网络/零缓存变化。不承诺下载配额或缓存逐字节回到原状。
- 同时最多一个真实提交；超时/取消不证明请求终止，未知结果不重试、不提前释放物理额度、不按文件名猜测成功或回收对象。
- Intel 运行验证跳过，macOS 13 实机缺口保留；0.2 发布、安装、升级生产库、合并及推送不属于本计划。

## Review Focus

1. **删错照片：** 只能回收台账确证创建、基线不存在的精确 ID；名称、时间、总数和相似度都不能授予删除权（V1/V5）。
2. **生产数据或真实来源被误写：** QA 状态目录及 DB 必须与生产分离；只读装配不得调用创建或提交前持久化入口，源路径不可由数据库副本自动启用（V1/V3）。
3. **不完整候选集误判不重：** 小样本只能证明读取/已有匹配；完整有效候选与成功/unknown 历史保护成立前不得写入（V2/V3/V4）。
4. **并发用户/iCloud 变化被当作 QA 垃圾：** 差异须分账，任何非 QA 新增均保留；提交前复核代次，清理时不按全库差集删除（V4/V5）。
5. **新增已提交但台账丢失：** 意图和额度先持久化、placeholder 检查点同步落盘、完成证据独立保存；unknown 阻断后续写入与不确定清理（V1/V4/V5）。

## 顺序、授权与恢复口径

严格顺序为 **V1 防护准备 → V2 图库/云端只读 → V3 真实目录 dry-run 与其余只读检查 → V4 最后写入 → V5 精确回退与核验**。V1–V3 必须报告 `Photos mutations = 0`，不能为了取得测试样本提前导入。回退功能先用 fake 验证，再有真实写入。

`scope.json` 固定 `runID`、源码/模型身份、当前账号与系统图库确认记录、QA 数据根目录、真实来源根目录及文件清单、读取预算、写入清单/上限、生产 App 原先运行/暂停状态、允许的 QA 前台操作。图库标识只能使用公开 API 与用户可核对信息；不能遍历 Photos 私有数据库或凭一个缓存标志猜测已切库。

优先从用户指明的待导入目录中选一个；若路径尚未给出，可只读列出已有来源配置后定位，无法唯一判断时才询问路径。不扫描整个主目录/磁盘，不因配置中存在路径就自动启用全部来源。首轮 dry-run 最多 50 个冻结文件，涵盖已知副本和不同照片；其余文件保留待测。

**读取节奏：** 先本地可用表示，云端探针最多 10 个资产、每次一个请求。完整覆盖按现有配置有界推进，首轮最多 30 分钟或 500 次允许联网的表示请求；到限停止发新请求、保留检查点与实际在途任务，报告已覆盖/未覆盖及下载迹象后再安排续跑。目标尺寸不是网络字节上限。达到边界不能降格索引就绪或越级写入。

**真实新增总上限 3 个资产**，首个成功后先核对台账和回收可定位性，再允许其余项；不是必须用满。未知尝试占用预算，重启不归零，额度不能靠换 runID 绕过未完成会话。若预期只跳过，就不得为了“测写入”强制忽略实际判重结果。

“恢复原状”分层验收，不能合并成一个资产总数：

| 层面 | 完成条件 |
| --- | --- |
| 原有数据 | 来源字节/属性未变；既有照片、编辑和相簿未被测试修改；生产配置/历史未被测试覆盖。正常用户/iCloud 变更单独记录并保留。 |
| 活动图库 | 本次确证新增项全部按精确 ID 回收；没有未决提交或额外新增；基线受保护资产没有测试造成的缺失/修改。 |
| 最近删除 | 仅本次测试项完成定向收尾后，才称测试资产完全清理。公开 API 删除后的残留与系统确认按 V5 处理；未完记 `cleanup_pending`，不能清空整个“最近删除”。 |
| 运行状态 | 恢复为了写入窗口而暂停的生产同步到原状态；本来暂停则保持暂停。QA 退出，临时资源不再占用；未解决 unknown 时不能草率恢复自动提交。 |
| 系统副作用 | 明确记录 iCloud 上传/删除传播、缓存、系统历史及“最近项目/导入”展示顺序不可保证精确还原；活动照片恢复不等于零痕迹回滚。不能承诺他端同步立即完成。 |

## 文件与接口

| 位置 | 责任 |
| --- | --- |
| `work/real-photos-icloud/<runID>/scope.json`、`baseline.json` | 范围、初始资产 ID/可读修订、来源清单、运行状态及限额；原始标识只留本地 |
| 同目录 `Harness.swift`、`HarnessTests.swift`、`build-qa.sh`、`Info.plist` | 薄 QA 宿主、范围包装与 fake 拒绝/回退测试；在临时 target 中编入必要 App 源码以使用 internal `AdvancedRuntimeGraph`，不改产品访问级别或复用旧 GUIQA readonly |
| 同目录 `qa.sqlite`、`history-snapshot.sqlite` / `history-before-write.sqlite` | 生产库一致只读快照保留原样；先复制整份快照为可迁移 QA 工作库，保留所有来源历史/身份，不另造 history import API。生产库不存在须明确验证后才可新建空 QA 库 |
| 同目录 `write-manifest.json`、`write-journal.jsonl`、`cleanup.json` | 冻结的逐项写入许可、耐崩溃的创建证据及逐 ID 回收记录 |
| 同目录 `source-before.json` / `source-after.json`、`evidence/<caseID>/` | 来源完整性、真实决定/分数/候选、回调、状态、度量与恢复差异 |
| `docs/release/<实际执行日期>-real-photos-icloud-validation.md` | 脱敏的逐例结论；不提交私人图片、标识、路径、向量或数据库 |

宿主命令为 `preflight`、`read-library`、`dry-run`、`write-canary`、`rollback`、`verify-restored`，统一显式 `--scope <scope.json> --output <新阶段目录>`。前三者没有可用变更入口；`write-canary` 必须引用冻结 `--write-manifest`；`rollback` 必须引用同一 run 的 `--journal`，不接收临时拼接的任意资产 ID 列表。重启复用同一台账/QA DB，禁止覆写旧证据。

决定通过 `AdvancedDedupService.prepare` 和当前 SQLite/策略取得；dry-run 不运行 engine drain，也不调用 `commitAdvancedSkip` / `beginAdvancedAttempt` / `PhotoKitGateway.create`，不把拒绝写入伪装成文件错误，也不伪造成功历史。`prepare` 需要 QA 库内对应的 pending 来源行且会缓存指纹，允许这些 shadow 状态；imported/unknown 原记录不降格成 pending。现有 GUIQA readonly 仅接旧 metadata 网关，不能用于此项。产品没有公开 dry-run 功能，本计划只写测试入口。

创建台账至少含 `runID/attemptID`、源路径代号/字节摘要与 stamp、许可版本、提交前代次、已保留额度、placeholder ID、完成回调和错误、成功 asset ID、回收状态。先持久化 intent/额度，再提交；在现有同步 placeholder checkpoint 中落盘该 ID。无法落盘视为 unknown 风险，立即挡住下一项。清理绝不以反查同名或“测试后新增集合”替代身份链。

### Task V1：准备只读装配和先行回退防护

**Files:** scope、宿主/fake 测试、baseline/台账接口；只读复用现有 Core 与 runtime。任何必要产品改动须另行列明，不借验收加入通用 dry-run/删除功能。

- [ ] 记录当前生产 App 状态、版本和数据路径、图库/权限、可用空间及来源候选，只采集测试所需信息。QA 使用唯一身份、独立数据路径，关闭自启动、通知及生产配置自动加载；尚不暂停生产同步、不开写模式。
- [ ] 只要生产数据库存在，就必须用 SQLite 一致性备份接口从只读连接取得完整快照，不直接复制打开中的 sqlite/WAL 文件，不使用 `SyncStore` 打开生产路径。先复制快照为 `qa.sqlite` 再做现有迁移，逐项核验 source/file 身份、success/attempt/placeholder/unknown 字段和各来源成功指纹未丢失。不能把空 QA 历史当完整；无法读取/兼容则写阶段 blocked。QA 数据目录权限限定当前用户。
- [ ] 在 QA 副本保留所有历史，仅按 scope 显式配置本次活动来源；任何模式都不能从快照 source.path 自动扫描全目录。dry-run 手工登记/准备允许清单，真实写阶段停用所有复制的生产来源，仅启用专用 scratch 来源；历史仍保留并参与产品应保留的成功候选，未知提交另行阻断。此处候选的本地 pending 活动来源范围必须在报告中说明，不声称完整生产队列已执行。
- [ ] 先 RED/GREEN 验证 `testReadOnlyCannotBeginAttemptOrCallMutation`、`testProductionPathsAndUnlistedSourcesRejected`、`testBudgetPersistsAcrossRestartAndUnknown`、`testCleanupRejectsBaselineAndUnjournaledIDs`、`testConcurrentUnrelatedAssetIsPreserved`、`testPlaceholderFailureStopsFollowingCreates`。证明回退失败、重复运行和取消不会扩大删除/新增范围；回退清单重复执行应幂等。
- [ ] 补全 `testSnapshotPreservesAllSourceHistoryAndBlocksUnknown`、`testOtherSourceSuccessAfterDryRunInvalidatesWritePlan`、`testScratchIdentityCannotBypassOriginalSuccessOrUnknown`、`testScratchInputRequiresFreshAdmission`、`testProductionInstanceLockContentionPreventsWriteGraphLoad`：分别覆盖其他来源新增成功后 Photos 又删除、原记录 imported/importing/unknown、scratch stamp/路径变化及生产锁竞争。锁竞争须断言尚未建立写能力图，其余拒绝须断言未发创建请求，不能只断言最终报错。
- [ ] 编译并核验实际 bundle/模型身份，再通过 fake 全链路预演“新增→checkpoint→完成→回收→核验”。只读与回退安全审阅通过后才连接真实 PhotoKit；这些不产生任何真实新增。

### Task V2：生产图库及 iCloud 只读检查

**Interfaces:** `read-library` 使用真实 PhotoKit gateway/reader；小样本和完整覆盖结果分开，原有资产只读。

- [ ] 分页记录当前图库清单、资产数/表示数和可读修订，不能把权限不足、错误或不完整页当成空库。先验证少量本地原版/已有编辑版、尺寸和指纹；不为造编辑用例改动既有照片。
- [ ] 在指定表示、同尺寸/版本请求中设 `isNetworkAccessAllowed=false`。只有没有可用最终表示且 `PHImageResultIsInCloudKey == true` 才证明此时该请求需要云端；最多找 10 个资产，不清缓存、不用“优化存储”设置推断。
- [ ] 对合格样本逐一允许网络，记录 final/nondegraded/noncancelled/error-free 结果、耗时和实际产品读取→指纹→ready。original/current 分别证明；拿到缩略图不能证明完整原片，API 探针通过不能代替产品路径通过。
- [ ] 开始完整候选索引，只写 QA DB，按读取预算分批续建。记录所有未就绪/超限/排除表示及原因；小样本完成不授予“全图库无重复”结论。不要求把整库原片下载到应用目录。
- [ ] 无自然云端样本时 iCloud 项记 blocked、其余检查继续；不得制造缓存驱逐。可选完整数据探针使用 `requestImageDataAndOrientation`（无 targetSize）或 `PHAssetResourceManager`，只针对单个已限定样本；交付字节不等于网络字节，不加入产品整库下载。

### Task V3：真实待导入目录 dry-run、恢复和资源观察

**Interfaces:** `dry-run` 消费冻结真实来源清单及 V2 的索引。输出每项 expected/observed 决定、候选 kind/ID 代号、score、尺寸、理由和阶段时延，所有 Photos 变更计数为 0。

- [ ] 先对清单中的已知副本、压缩/缩小副本、不同照片及有意义编辑作真实读取和判定。测试真值来自明确源关系或受限内容核对，不把模型自身 score 当成真值；不调整 0.98。私人图片/结果只留本地，不加入 GitHub 用例集。
- [ ] 覆盖完整有效 Photos 候选及应保留的成功/unknown 历史后，才记录可用于写阶段的 `would_import` / `would_skip`；覆盖不足记 waiting/partial。避免小候选集遗漏导致误导“应导入”。unknown/importing 来源和版本不兼容的成功证据继续阻断，不靠清空 QA 历史解除。
- [ ] 在只读宿主上验证暂停/恢复、停用 QA 来源、索引建设/完成后重启；原有资产的自然新增/编辑/撤销事件只观察。观察一次实际 30 分钟清单核对，无变化时不重复图像推理；没有自然事件的分支留到 V4 的 QA 新增项或记缺口。
- [ ] 请求级禁网、注入授权失败验证等待路径；不全局断网、不撤销生产 App 授权。不要把这些称为真实断网/系统撤权验收。当前产品未保存取消下载 request ID，逻辑暂停不证明下载被强制取消。
- [ ] 记录一个实际 QA 运行图的分析前/后、至少 60 秒闲置、恢复请求的 footprint/RSS/CPU/IO，分离云端等待、推理、查询和提交。原 87.2 MiB 合成宿主闲置结果不代替这次测量，样本不足不报 P95。
- [ ] 在允许的本机前台时段，用只读/fake 状态完成真实菜单、键盘、AX 与 VoiceOver 检查；不抢焦点、不发全局快捷键或启动会扫描生产配置的旧入口。无合适时段就保留缺口。
- [ ] 汇总只读结果，独立 reviewer 核对写入防护/回退证据链及本阶段发现。所有影响数据正确性的疑点解决，完整候选覆盖和来源稳定后，才生成最多 3 项写入清单；尚未具备条件就停在只读，不跳过门槛。

### Task V4：最后执行有上限的真实写入

**Interfaces:** 只允许 `write-canary` 按持久清单执行一次一个 asset 创建；创建仍走真实 Core/PhotoKit。新增后的编辑/撤销测试由独立 QA 操作执行，产品保持只新增。

- [ ] 进入短写入窗口：若生产 PhotosYNC 正在运行，先通过正常控制暂停新提交并确认已有提交明确完成，再正常退出该实例；不强杀、不用全局快捷键，也不能仅凭 PID 消失认定 PhotoKit 已结束。随后在任何写能力图初始化之前，使用已核实生产 bundle ID 和实际生产锁目录取得 `SingleInstanceLock.lockURL` / `acquire` 的同一把锁，持有至 V5 完成；QA 身份的另一把锁不够，不能删锁/改路径绕过竞争。无可靠控制、锁占用或有未决提交则 blocked，生产 SQLite 不被测试写入。
- [ ] 写窗口开始后取得新的**全部来源**一致快照，包含停用/移除来源成功历史及所有 unknown/importing。与 V1 原始快照逐行比较 `source`、`file_record`、`file_fingerprint`、`dedup_dependency` 的键和值（旧 schema 不存在的表按其版本处理，不能漏已有表）。保护事实完全相同才允许复用已有 QA 工作库；任何变化都丢弃旧写清单，从新快照另建 QA 副本，重走完整候选覆盖和本次来源准备，不手写合并或删减历史。Photos 已删除的其他来源成功项仍必须保留。刷新完整图库基线/代次，不能沿用长时间前的 token。
- [ ] 默认将只读验证过的原始字节复制到 QA scratch、使用唯一 run 文件名以便收尾。`write-manifest` 必须绑定原 `sourceID/relativePath/fileID/stamp`（尚无记录则明确记 absent）与最终 scratch `sourceID/relativePath/fileID/stamp` 及字节摘要。先查最新完整历史：原来源已成功/正在提交/结果未知时禁止通过改名另造记录；原来源有变化也停止。随后对**最终 scratch SourceFile** 重跑真实 `prepare`，创建走 `SyncEngine` 的准备→`beginAdvancedAttempt`→`PhotoKitGateway.create`，由最终输入生成新 evidence，不移植原 dry-run 结果。实际原路径提交未被此副本测试覆盖，报告须区分。Photos 返回 ID 才是回收依据，文件名只辅助核对。
- [ ] 写窗口上限先设 30 分钟，超时只停止新请求，实际在途任务仍须完成/恢复。若新快照需长时间重建，尚未发创建则退出本次窗口、恢复原运行状态，保留只读结果后另排；不为赶时间跳过覆盖。若生产实例原先运行但暂停，必须预先证明存在恢复该状态且不会抢先自动提交的已有入口；不能保证就不进入写窗口，不能用“先启动再赶紧暂停”恢复。
- [ ] 预先确认本次新增项的活动图库删除及“最近删除”定向收尾路径可用；系统解锁由用户完成。不能假定 API 可无提示永久删除，无法完成最终收尾时不开始写入。既有用户资产、原有最近删除项、相簿和图库设置均不在可操作清单。
- [ ] **第一项 canary：** 选只读评估为应导入且不被既有成功历史覆盖的单个输入，持久化意图/额度后提交。等待明确成功与 ID 绑定，核对实际 Photos/QA DB/来源；未知或多新增立即停止。无法可靠定位回收对象时不继续。
- [ ] **后续最多两项：** 优先真实目录中“已存在的重复应跳过”和“不同照片应导入”；有合格素材再验证高清保留，不强凑场景或绕过现有图库候选。副本跳过不消耗创建额度，但必须断言 `createCalls=0`。所有实际创建（含 QA 用来触发外部新增的动作）共同消耗同一 3 资产预算。
- [ ] 对已确证新增的 QA 资产，可做一次明显裁剪和撤销，验证 original/current 各自内容/尺寸、外部变更失效及恢复；只读导出当前版到 QA scratch 作对照。不得编辑原有照片。没有可安全完成的系统交互时记缺口，不能扩操作范围。
- [ ] 每次新提交前复核源 stamp、授权、图库/索引代次、运行资格、剩余额度及无 unknown；每次完成即核对资产集合。生产/iCloud 自然变化先失效并重新分析，不能把它们当作本次创建。不得故意在真实提交中杀进程、制造磁盘满或撤权；该故障注入仍用已通过的 fake/受控测试。

### Task V5：精确回退、原状核验和交付

**Interfaces:** `rollback` 只消费同一 run 的耐崩溃台账和基线；恢复工具独立于产品的创建能力。`verify-restored` 输出每层 restored / cleanup_pending / unknown / failed，不用一个布尔值掩盖残留。

- [ ] 先禁用任何新创建，等待所有已发请求明确完成；unknown 保存现场并阻断正常收尾。只有基线不存在且有本次创建/完成证据、当前可核对的精确 ID 才进入回收集；占位符无成功确认或单次 fetch 缺失不能当成已恢复。
- [ ] 逐 ID 调用公开删除流程，仅回收本次确证新增；若系统要求确认/解锁，走正常流程，不绕过，也不把“系统一定会弹窗”当作安全防线。意图、成功/错误和复查结果入台账。测试删除后的成功历史保护：QA 已成功来源不应被重新导入，必须在仍禁止新写的状态下检查。
- [ ] 核对活动图库已无本次新增。只在 Photos 系统界面对本次项目作最近删除收尾，需要解锁时由用户完成；不调用私有 API、不“全部删除”、不接触原有最近删除项目。无法明确辨认或完成时保留 `cleanup_pending`，不宣称完全恢复。
- [ ] 对比来源完整性、基线受保护资产/修订与当前清单；以“本次新增集合为空＋原有项无测试损伤＋并发正常变更单列”核验。若有非 QA 差异只报告/追溯，绝不通过删除新照片或恢复旧快照来强行集合相等。检查 iCloud 同步状态，无法证明他端完成就记待观察。
- [ ] 核对生产持久配置/历史未被测试替换，完成收尾后关闭 QA 写能力图并释放生产身份的实例锁，再按预先验证的路径恢复原运行/暂停状态；本来未运行不自行启动。未解决 unknown 或疑似额外创建时不恢复自动提交并报告，不能隐瞒未恢复的运行状态。QA 停止后保留本地台账/证据，不把私有历史快照或图片发布到仓库。
- [ ] 更新脱敏验收及合并准备记录：分别报告只读、真实写入、活动图库恢复、最近删除/云端残留、原生交互和平台缺口。独立 reviewer 核对结论；源代码若有必要修复，再做对应审阅和当前完整自动验收。文档修订不重复重跑已通过代码。

## 停止条件与已知边界

任何越界来源/资产、只读阶段调用变更、意图/ID 落盘失败、未知提交、非预期新增、源变化、原有资产被测试修改、索引未就绪仍提交、未结束任务却释放额度，立即停止新工作并保留证据。回退失败不得重置台账、恢复整库或扩大删除范围。

PhotoKit 目标尺寸、进度或返回长度不能证明固定下载字节；只读也可能使云端内容留在系统缓存。普通删除及 iCloud 传播不是逐字节撤销，最近删除定向收尾是单独结果，不能承诺所有系统记录完全消失。若用户要求包括缓存/同步历史的绝对零痕迹，应停在只读阶段说明该目标无法由公开接口保证。

公开接口依据：[deleteAssets](https://developer.apple.com/documentation/photos/phassetchangerequest/deleteassets%28_%3A%29) 仅请求删除指定资产；[performChanges](https://developer.apple.com/documentation/photos/phphotolibrary/performchanges%28_%3Acompletionhandler%3A%29) 的完成结果不构成跨 PhotoKit/QA 数据库的回滚事务。[Mac Photos 删除说明](https://support.apple.com/en-am/guide/photos/pht3bfab2f96/mac) 将最近删除和永久删除分别处理，永久清理使用 Photos 界面；[iCloud 删除说明](https://support.apple.com/en-nz/guide/icloud/mm8b32f3ae27/icloud) 明确同账号设备间传播。已核对本机 macOS 26.5 SDK，未找到公开的最近删除永久清除接口；不借私有接口绕过。

真实十万资产、长期能耗、macOS 13 和所有媒体格式仍须按实际覆盖报告。本轮只交付修订计划；执行时沿用本次生产图库授权和既定子代理方式，缺具体路径或系统解锁时只补充必要信息，不重复询问已同意的测试范围。
