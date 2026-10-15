# 原始资源共同解码产品集成 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox syntax for tracking. 用户已选择子代理实施，并明确要求开始本次产品集成。

**Goal:** 将已验证的 Photos 编码原始资源 → 共同 ImageIO 解码路径接入 0.2.0，安全升级已有指纹数据，并在最终产品代码上完成验收。

**Architecture:** Source 与 Photos 共用原有有界 ImageIO 算法；Photos 仅将精确绑定的编码资源流式写入短期私有文件。指纹身份绑定新输入契约；旧 Photos 表示重建，精确等价的 Source 历史事务迁移。

**Tech Stack:** Swift / ImageIO / PhotoKit / Core ML / SQLite + sqlite-vec / Xcode / Python release gates。

**Spec:** `docs/superpowers/specs/2026-10-11-original-resource-common-decoder-design.md`；既有主设计、运行时与发布契约继续有效。

## Global Constraints

- HEAD 基线 `4e3a847c11b508004b5206026f4b58b9d3935fda`；当前独立工作树及已有研究/设计文档保留。只提交任务所属文件。
- SSCD Large FP16、ANE 优先 / GPU 降级、320×320 sRGB stretch、1024 Float32、阈值 0.98 不变；Source stamp 和成功/未知提交语义不变。
- 解码最长边 4096，decoded allowance 536870912 bytes；一个物理 Photos 请求；编码文件上限 536870912 bytes，同卷 free-space reserve 134217728 bytes；不得整片累积 Data。
- PhotoKit 原始版选唯一 `.photo`，编辑当前版选可靠唯一 `.fullSizePhoto`；不回退到 320 栅格，不以原始版冒充编辑版。
- 源目录和真实 Photos 只读；普通应用正常启动、写入、安装、合并、推送和发布不属本次范围。最低 macOS 13，Intel 实机与 macOS 13 实机缺口保留。
- 变更先 RED 后 GREEN；每块一个独立深评审，综合评审仅补跨块风险。受控合成测试不访问真实图库/生产库。实现者不再派代理、不撤销他人修改。

## Review Focus

- 超时后 PhotoKit 晚到回调/无回调：不提前释放请求槽、预算或删除部分文件，不启动替代读取。
- 解码像素仍可能访问临时文件：资源所有权持续到实际消费完成，lazy ImageIO 不读已删文件。
- 磁盘不足/符号链接/非本应用遗留目录：等待并保护其他文件，不将全局资源故障隔离成健康索引。
- 已导入或未知提交的旧 Source 向量：不能因新版本被查询静默遗漏或使所有导入永久阻断。
- 旧 Photos 向量/晚到工作/编辑资源变化：重新生成并通过现有 publication 和 revision 门禁，不能混入新索引。

---

### Task 1: 共同编码解码与 Photos 物理生命周期

**Files:**
- Create: `Sources/PhotoSyncCore/Fingerprinting/EncodedImageDecoder.swift`，`Sources/PhotoSyncCore/Photos/PhotosResourceReader.swift`（流与私有暂存职责，可在此职责内合理拆成小文件）。
- Modify: `Sources/PhotoSyncCore/Sources/MetadataReader.swift`、`Sources/PhotoSyncCore/Photos/PhotosRepresentationReader.swift`、`PhotosIndexGateway.swift`、必要的 `PhotoKitGateway.swift` / `ImageWorkBudget.swift` / `PhotosIndexCoordinator.swift`、`PhotoSync.xcodeproj/project.pbxproj`。
- Test: `Tests/PhotoSyncCoreTests/PhotosRepresentationTests.swift`，必要的独立 shared-decoder / temp-resource XCTest；`PhotoKitContractTests.swift`、`PhotosIndexCoordinatorTests.swift` 内两个既有 reader fake 只做必要构造参数/回调 seam 迁移，保留原行为断言；新增文件同步 Xcode membership。

**Interfaces:** Source 保留 `readForFingerprint(url:configuration:budget:)`、`SourceImage` 和 lease 行为。共享解码提供同步内部 `EncodedImageDecoder.decode(url:configuration:decodedAllowance:) throws -> SourceImage`，由受控物理执行所有者调用。Photos 保留 `PhotosIndexGateway.readRepresentation` / `LoadedRepresentation` 的对外契约；可对内部 request seam 增加编码流、取消和资源所有权，但现有调用方/测试必须同步迁移。新增内部 `PhotosResourceLimits` 默认编码上限和空间保留取 Global Constraints；Task 2 将其字段绑定产品 profile。

- [x] **Step 1: RED 行为测试。** 同一自制 EXIF 旋转 JPEG/PNG 编码 URL 经 Source 与 Photos fake encoded stream，assert 最终 tensor bytes/原始尺寸/方向/资格相等；旧 targetSide 图像路径不能满足 raw-stream case。控制 chunk、终止与取消时序，assert 逻辑超时后预算/槽仍占用；最终回调前没有删除部分文件。模拟超上限、磁盘不足、晚到 chunk、current 资源歧义，assert 无向量且错误分类正确。
- [x] **Step 2: 运行聚焦 build-for-testing / xctest，保留预期失败日志和命令。** 如新 seam 尚不存在，先引入只用于表达测试的编译型占位，再验证行为失败；不以语法错误当唯一 RED。
- [x] **Step 3: 最小生产实现。** 提取现有 ImageIO 算法，不改变 Source 数值路径；替换生产 requestImage 为精确 resource requestData。排他创建 0700/0600 私有暂存，流式计数/空间检查，真正 drain 后关闭、解码并释放所有权；必须防止取消 ID 尚未返回、重入/晚回调、重复 terminal。单项 encoded cap/照片解码错误隔离；临时存储/空间失败仍等待。清理仅自己的无活跃 owner 遗留物，未知路径保持原样。保留照片描述符前后检查及现有 eligibility，不扩大 RAW/多帧范围。
- [x] **Step 4: GREEN 覆盖测试。** 同 URL tensor 等价、预算/槽 drain、取消完成/未完成、异常与文件权限/清理、精确资源匹配、编辑等价/歧义均通过；测试自制大图保留 >64 MiB 产品额度证据，严格上界用注入小额度验证。没有实际 completion 的请求宁可保持 occupied，不能编造物理结束。
- [x] **Step 5: 自审并提交该任务文件，报告具体 tests / 退出码 / RED-GREEN / 所有权设计及未验证边界。** 不提交私有媒体、ignored evidence 或其他人的设计修改。

### Task 2: 输入版本、数据迁移与发布校验链

**Files:**
- Modify: `Sources/PhotoSyncCore/Matching/AdvancedDedupTypes.swift`、`Sources/PhotoSyncCore/Fingerprinting/ModelExecution.swift`、`Sources/PhotoSyncCore/Storage/SyncStore.swift` / `Schema.sql`、`Sources/PhotoSyncApp/SyncRuntime.swift`。
- Modify: `Sources/PhotoSyncCore/Resources/AdvancedDedup/` 新绑定 profile / decision / regression / closeout / execution-policy / provenance；`scripts/advanced-dedup/release.py`、`scripts/validate.py`、必要的现有 fingerprint helper。
- Test: `Tests/PhotoSyncCoreTests/AdvancedDedupStoreTests.swift` / `AdvancedDedupRegressionTests.swift` / 配置 tests；`StoreTests.swift` / `LegacySkipReevaluationTests.swift` 同步既有迁移 schema 预期（未知高版本 fixture 从 v8 调整为 v9，其余旧 v7 预期改为 v8），保留历史/回滚断言，`Tests/Tools/test_advanced_dedup_release.py` / `test_release_validation.py`。
- Create: `docs/research/advanced-dedup/original-resource-v1/` 本次新记录/校验链，历史研究证据不重写。

**Interfaces:** Task 1 内部 resource-limits 字段接入 `ResourceLimits`/profile，保留默认兼容测试构造器。`FingerprintConfiguration` 新输入字段 `inputContract` 为 `encoded-resource-imageio-v1`；旧缺字段 JSON 仅使用旧 hash 算法并作为 legacy 解析，新 hash 使用 namespace `sscd-preprocess-v2` 再加入 inputContract。精确新 hash 由实际代码生成并一致写入记录，不手工猜值。新增 `SyncStore.rebindEquivalentSourceFingerprints(to:) async throws`，仅接受正式新配置，旧版本 allowlist 仅 `ec805406fa61e91384e4bf29ae29a52694b80e3755afd7768da80a6db70c9a1d`；Runtime 校验配置后、factory/tick/graph 工作前调用。

- [x] **Step 1: RED 持久化与配置测试。** 旧 v7 数据中 current/attempt/success Source 精确旧版本；升级后 assert blob/stamp/尺寸/成功关系不变且查询可见、unknown attempt 后续 markImported 仍为新版本。assert 相同碰撞可安全合并、事实或向量不同回滚、未知旧成功仍阻断、Photos 旧向量不重绑定、重建期间 ready token 不可用。assert v3–v7 数据迁移保留及 v9 拒绝。assert 新契约版本与旧版本不同、被篡改契约/额度/绑定拒绝。
- [x] **Step 2: 聚焦验证预期失败并记录。** Release Python 变更前先读 `python-development-guidelines`。
- [x] **Step 3: 实现迁移与新契约。** schema v8 兼容 fence 在 store 打开时执行；source-only allowlist 重绑定在事务中做精确碰撞比较，更新 local_revision 一次（仅改变时），不删除成功/unknown；保留其他版本保护。Photos 按既有 version reconciliation 重新建指纹，绝不 relabel。模型 weights/goldens/阈值/编译 cache key 不改。新产品加载必须采用新 contract 与两项临时额度，旧式构造仅为 legacy 测试/解析。
- [x] **Step 4: 更新发布资源完整绑定链并通过 GREEN。** acceptance/provenance 明确新的取得路径；保留原 33 例标签/媒体和四 golden 数值；新记录的校验值来自实际输出。Release gate 验证新 inputContract / resource budget / fp version / records hash；旧记录改名变新记录不能代替新验收。本轮最终 canonical / targeted real 结果稍后补入验收报告，资源加载应保守地区分已有模型证据与本次路径证据。
- [x] **Step 5: 自审并提交该任务文件，报告迁移测试和所有校验链，说明旧连接不被 v8 强制撤销的限制。**

### Task 3: 集成验证、定向真实只读验收与交付记录

**Files:** 修改本计划、主 integration plan / 主 spec 的当前路径状态、`Design/Validation.md`、新本次实施结果文档；私有 QA harness/results 放 `work/real-photos-icloud/20261011-original-resource-product/`。不变更产品行为，验证发现的范围内修复回到相应实现者。

- [x] **Step 1: 综合审阅跨块契约。** 独立 reviewer 审查 Task 1–2 的物理 lease、持久化迁移、runtime 启动、发行绑定和既有 publication/unknown 语义，优先补未被任务等价审阅覆盖的集成风险；修复后只复审差异。
- [x] **Step 2: tester 执行最终代码完整统一验收。** `python3 scripts/validate.py --output-dir "$PWD/work/validation-original-resource-product-<unique>" --derived-data "$PWD/work/validation-original-resource-product-<unique>-derived"`，assert 最终退出 0、完整 XCTest 数量 >0 / 无失败、Tools 和 continuation-race 完整。本地 active33/四 golden 可复用源数据但必须使用最终新代码；模型/来源边界的新结果不借旧报告宣称。
- [x] **Step 3: 新产品 Core 定向只读真实验收。** 正常 LaunchServices 授权的私有宿主调用生产 gateway/resource path，共同处理冻结 19 对，assert 19 complete 且 score≥0.98、descriptor/stamp 前后匹配、终止时物理槽与私有文件 drain；原真实 31 负例保留已有标签，报告分母、误跳过/漏判/未评分。精确已编辑 current 资源若现有素材具备前提，验证它确实取 fullSizePhoto；不改 Photos。可对尚未采集过原片的冻结负例资源，先顺序执行公开 requestData 的 network-disabled 只读探测；只有明确的 PHPhotosErrorDomain / networkAccessRequired (3164) terminal 错误、且同一精确资源随后经产品 network-enabled 路径成功时，才报告网络必需条件及产品允许网络获取路径已验证；该 API 不提供字节来源证明，不断言实际下载字节或必然来自 iCloud。探测无可靠 terminal 时保持占用、不启动替代请求；不改变网络/iCloud 或生产图库制造前提。没有可靠证据则记录缺口。不能正常取得的项保留未评分而非删分母。
- [x] **Step 4: 保存源码/命令/结果与边界，更新设计/计划状态并提交范围内文档。** 构建、自动测试、真实 Photos、平台和分发分别报告；不执行 merge/push/安装/生产 App 启动/发布。保留私有证据，清理本计划临时 SDD workspace 时将关键 rulings/验收写入版本控制报告。


## 执行结果 — 2026-10-11

三项任务完成，行为冻结 `cd32bd61a31ac0613e8e90ceb45095cc355b9de0`；源代码、行为测试与资源在最终 canonical 后未改变。完整门槛退出0：589 XCTest（2 明确跳过、0 失败）、96 Tools、active33、8 个请求后端 golden 检查、四档规模及两项 continuation 均通过；任务及跨块独立评审通过。

实际公共 gateway 只读冻结50配对完成并独立复核 PASS：19 判重/skip，31 判不重/importFile，零未评分；最低正例0.984066010，最高反例0.865148246。50个唯一暂存 owner 及其编码大小/哈希可追溯，实际图像/字节预算和 Source 物理占用归零，确切目录均已删除；原生/launcher/系统退出分别确认。原始请求计数不是公开接口，没有虚构该计数。

首轮取证缺口保留；修复仅私有 QA 观察逻辑后同样本补跑，分数/数值文件全部相同，独立样本分母仍50。当前编辑版/撤销及确定网络必需条件没有本次可靠真实证据，单列缺口；未执行生产库迁移、完整真实索引发布、写入、合并/推送或发行打包。

[最终实施与验收记录](../../release/2026-10-11-original-resource-integration-validation.md)包含代码/命令/结果、两项选择及代价、旧失败和平台/分发边界。当前文档路径状态同步到主 spec、主 integration plan、README 和 Design/Validation；私人数据与详细证据仅保留在 ignored work。
