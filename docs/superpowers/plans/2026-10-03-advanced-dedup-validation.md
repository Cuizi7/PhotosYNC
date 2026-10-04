# PhotosYNC 0.2.0 判重研究与配置冻结 Implementation Plan

> **2026-10-04 范围修订：** 本文件记录第一轮按 v1 全部 44 例执行的研究，已按失败结果收尾。用户现已通过 `Tests/Fixtures/AdvancedDedup/active-suite.json` 停用 11 个信息看板用例，当前为 33 例。不要重跑下面整套已完成步骤，也不要把旧协议或旧 44 例结论改写为新范围验收。下一轮仅补范围绑定、独立校准/封存和真实图库性能证据，具体复用边界见 [范围修订评估](../../research/advanced-dedup/2026-10-04-scope-reassessment.md)。本次没有授权执行这些后续研究或产品集成。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付可复现的 SSCD Large 特征、精确检索和查询级评估工具，得到满足事先批准要求的发行配置，或明确报告该方案不能通过。

**Architecture:** 研究工具直接复用将来产品的 Swift 预处理、推理与纯判定代码；Python 只负责数据清单、统计和报告。先批准研究协议，再测量和校准，最后一次性评估封存集合。通过后才进入[产品集成计划](2026-10-03-advanced-dedup-integration.md)，研究工具本身不启动同步或接触生产数据库。

**Tech Stack:** Swift 5 language mode、macOS 13+、Core ML、ImageIO/CoreGraphics、Accelerate、XCTest；Python 3.10+ 离线研究工具。模型转换环境单独锁定，不增加 App 的 Python 依赖。

**Spec:** `docs/superpowers/specs/2026-09-28-photosync-0.2.0-advanced-dedup-design.md`，重点第 2、3、7、8、11 节；内容基线 `a855367`。实施前核对当前 HEAD/AGENTS.md，保留已有改动。

## Global Constraints

- “不加入 pHash、第二个核验模型、服务端模型或独立向量数据库服务。”
- “生成 SSCD Large 1024 维向量。”统一保存 L2 归一化 Float32；权重精度与向量存储精度分别记录。
- “固定输入尺寸的候选基线为 320×320、保留整幅画面”；这是研究起点，不是已经批准的最终预处理。
- “推理初始采用串行、批次 1”；运行配置必须有物理在途上限，不能按图库大小增加并发。
- “保持 macOS 13 与 Universal 交付目标”；M2 Pro 结果不能替代 Intel/macOS 13 实机证据。
- “案例有方向，不能直接互换 query/candidate 并继承导入动作。”冻集 44 例／63 图、14 判重／30 判不重、11 跳过／33 导入。
- “画面整体旋转 90°……尚未定案”；不恢复 B015/B017/B019、不更改固定真值让模型过关。
- “这些数值与阈值报告一起审阅，实施不得暗设默认值。”协议和发行配置缺字段立即失败；测试里的合成数值不是发行默认值。
- 六张用户附件限当前本地测试；不上传。研究数据不进 App；不读取个人 Photos、生产数据库或停用来源。

## Review Focus

- 同源变体跨校准/封存组，或在公共回归集上选阈值：R1 必须拒绝泄漏，报告不能把相关 pair 当作独立查询。
- EXIF 镜像方向、Display P3、极宽图：R2 在相同可见画面上走一致的颜色/方向路径，不能静默中心裁剪。
- 最近候选是低清图，而稍远候选已足够高清：R3 必须找出所有达阈值候选后决定，不能只看 top-1。
- 零观察误跳过但样本极少、或超高阈值令正例全部漏检：R4 必须仍拒绝，分别验收置信上界和召回底线。
- 串行推理超时后物理计算尚未结束：R2 保留占用，后续任务不能借逻辑取消突破物理上限。

---

## 文件结构与交付接口

本计划和产品集成是一项能力的两个门控阶段，不重复建设第二套 matcher。R2/R3 的 Core 代码之后原样复用，配置字段由 R1/R4 冻结；产品计划不得猜参数。所有新增 Swift 文件须同步加入 `PhotoSync.xcodeproj/project.pbxproj` 的 Core / XCTest target。

| 文件 | 责任 |
| --- | --- |
| `scripts/advanced-dedup/research.py`、`scripts/advanced-dedup/requirements.txt` | 研究协议、清单、统计、报告 CLI；转换依赖锁定在研究环境 |
| `docs/research/advanced-dedup/protocol.json`、`protocol.md` | 未看结果前填写并审阅的指标、样本与资源预算 |
| `Sources/PhotoSyncCore/Matching/AdvancedDedupTypes.swift` | 下述配置、向量、尺寸、候选和决定值类型 |
| `Sources/PhotoSyncCore/Fingerprinting/ImagePreprocessor.swift`、`CoreMLFingerprinter.swift` | 唯一的图像预处理与串行模型执行实现 |
| `Sources/PhotoSyncCore/Matching/ExactVectorIndex.swift`、`AdvancedDuplicatePolicy.swift` | 精确候选检索及无 I/O 决定 |
| `Tools/AdvancedDedupProbe/main.swift`、`scripts/advanced-dedup/run-probe.sh` | 显式输入路径的命令行探针；不构造生产 runtime |
| `scripts/advanced-dedup/convert-model.py`、`docs/research/advanced-dedup/model-provenance.json` | 可重复转换、上游 revision/权重 SHA256、MIT 声明与转换记录 |
| `docs/research/advanced-dedup/acceptance.json`、`acceptance.md`、`accepted-profile.json` | 仅通过 R4 后生成的证据与机器配置；不得提前写 pass |
| `Tests/Tools/test_advanced_dedup_research.py`、`Tests/PhotoSyncCoreTests/{Fingerprint,AdvancedDuplicatePolicy,VectorIndex}Tests.swift` | 自制数据单测；不自动下载外部图片 |

拟新增公共类型（实现位置为 `AdvancedDedupTypes.swift`；后续任务不得重命名其字段）：

- `PixelSize: Codable, Equatable, Sendable { width: Int, height: Int }`，只允许正数；策略比较 `min(width,height)`、`max(width,height)`。
- `FingerprintConfiguration: Codable, Equatable, Sendable { version: String, modelSHA256: String, inputSide: Int, resizeMode: ResizeMode, colorSpace: String, mean: [Float], std: [Float] }`；`ResizeMode` 仅 `stretchFullFrame` / `letterbox`。归一化数组各 3 项，std 正且有限；version 由除 version 本身外的全部配置字段和转换身份规范化哈希得到。不得接受中心裁剪方案作为默认。
- `Fingerprint: Equatable, Sendable { version: String, values: [Float] }`；`init(version: String, values: [Float]) throws` 拒绝非 1024 维、NaN/Inf/零范数，然后归一化。SQL 编码固定 little-endian Float32，不保存图像。
- `CandidateOrigin: String, Codable, Sendable`：`photosOriginal`, `photosCurrent`, `localPending`, `localImporting`, `successHistory`。
- `ScoredCandidate: Equatable, Sendable { key: String, origin: CandidateOrigin, score: Double, size: PixelSize?, fingerprintVersion: String }`。
- `DuplicateEvaluation: Equatable, Sendable { content: ContentResult, action: ImportAction, reason: DecisionReason, matchedKeys: [String], coveringKeys: [String] }`；`ContentResult = duplicate | notDuplicate`，`ImportAction = importFile | skip`；`DecisionReason = noMatch | covered | resolutionUpgrade | insufficientSizeEvidence`。未知读取不进入此纯函数。
- `DedupConfiguration: Codable, Sendable { fingerprint: FingerprintConfiguration, policyVersion: String, threshold: Double, backend: String, resources: ResourceLimits, evidenceCandidateLimit: Int, acceptanceID: String }`。`ResourceLimits` 包含 `decodeConcurrency: Int`, `photoRequestConcurrency: Int`, `maxDecodedBytes: Int64`, `requestTimeoutSeconds: Double`, `retryDelaysSeconds: [Double]`, `catalogBatchSize: Int`, `maxInFlightTasks: Int`, `progressPublishIntervalSeconds: Double`，另强制 `inferenceConcurrency = 1`, `batchSize = 1`。policyVersion 绑定 fingerprint.version、threshold、backend 和尺寸判定规则版本，排除 policyVersion 自身及验收记录ID，避免循环哈希。所有数值来自批准协议/报告且为正、有限；没有发行 fallback。校准期间候选 profile 使用 `acceptanceID="research:<protocol_sha256>"`，仅显式 Tools 探针可消费；产品加载器必须拒绝没有成功 acceptance 绑定的候选配置。

验证命令约定：`python3 -m unittest discover -s Tests/Tools -p test_advanced_dedup_research.py -v`。Swift 每任务使用干净独立 `work/RN-derived` 运行 `xcodebuild -project PhotoSync.xcodeproj -scheme PhotoSync -destination 'platform=macOS' -derivedDataPath work/RN-derived CODE_SIGNING_ALLOWED=NO build-for-testing`，成功后 `xcrun xctest work/RN-derived/Build/Products/Debug/PhotoSyncCoreTests.xctest`。RN 替换为任务号；红阶段可为新增接口不存在而编译失败，绿阶段要求最终退出 0、实际执行 >0、0 failures。最后必须另跑项目统一验收，局部命令不冒充发布验收。

### Task 1 (R1): 研究协议和无泄漏数据清单

**Files:** Create `scripts/advanced-dedup/research.py`, `docs/research/advanced-dedup/protocol.json`, `docs/research/advanced-dedup/protocol.md`; Test `Tests/Tools/test_advanced_dedup_research.py`。固定素材目录只读。

**Interfaces:** Produces `validate_protocol(document: dict) -> dict`, `validate_dataset(document: dict, fixture_manifest_sha256: str) -> dict`。协议字段：`approved`, `confidence_level`, `max_false_skip_upper_bound`, `min_copy_recall_by_stratum`, `min_candidate_recall`, `minimum_queries_by_stratum`, `max_hot_query_p95_ms`, `max_incremental_p95_ms`, `max_peak_rss_bytes`, `resources`, `seed`, `sampling_unit`, `alpha_allocation_by_stratum`, `conversion_max_abs_error`, `conversion_min_cosine`。清单每条必须含 `query_id`, `family_id`, `split_group`, `split`（calibration/sealed/distractor/public_regression）, `path`, `sha256`, `license_record`, `expected_candidates` 和 `expected_action`；多候选尺寸由真实表示分别记录。

- [ ] **Step 1 — 写失败测试。** `test_protocol_has_no_implicit_targets`：`validate_protocol({})` 抛 `ValueError`；`test_family_leakage_rejected`：同一 family/split_group 同时进入 calibration 和 sealed 必须失败；`test_public_fixture_is_not_a_sealed_set`：以冻集内容哈希登记为 sealed 必须失败；`test_repeat_variants_do_not_increase_independent_query_count`：同一家族 10 个变体仍只计 1 个独立抽样单位。
```python
with self.assertRaises(ValueError): validate_protocol({})
```

- [ ] **Step 2 — 运行 Python 工具测试。** 预期 FAIL，失败点为研究模块或上述保护不存在。
- [ ] **Step 3 — 实现验证和 CLI。** `research.py check-protocol --protocol PATH --dataset PATH` 校验字段/类型/范围、文件哈希与许可记录、独立家族和抽样单位；不加载模型；清单审计允许校验封存文件哈希，但不推理、不生成分数、不展示封存内容。为不同假设/分层预先分配总 alpha，禁止统计时临时改变置信口径。
- [ ] **Step 4 — 产出具体协议草案并取得审阅。** 根据实际可获得、可许可数据提出误跳过上界、最低召回、置信水平、样本规模与 M2 Pro 时延/RSS/资源预算；写出样本规模的推导。`approved=false` 的草案可以保存但测量命令拒绝启动；用户批准后记录批准文本和协议哈希，所有字段必须已有数值。这里是 spec 第 7/8 节要求的研究决定，不由本 plan 虚构默认值。数据不足则补数据或结束为“无法验收”，不能用 44 例补足封存样本。
- [ ] **Step 5 — 运行测试为绿并提交。** 上述 Python 命令全通过；提交本任务四个文件，`git commit -m "test: define advanced dedup research protocol and dataset guards"`。未批准协议时，R2 可编写自制数据代码，不能开展受协议约束的真实测量或执行 R4。

### Task 2 (R2): 单一生产同源预处理与 Core ML 指纹

**Files:** Create 本节文件表的 `AdvancedDedupTypes.swift`, `ImagePreprocessor.swift`, `CoreMLFingerprinter.swift`, `Tools/AdvancedDedupProbe/main.swift`, `run-probe.sh`, `convert-model.py`, `model-provenance.json`, `requirements.txt`; Modify `PhotoSync.xcodeproj/project.pbxproj`; Test `FingerprintTests.swift` 和 R1 工具测试中的转换清单检查。

**Interfaces:** Consumes R1 协议；Produces `ImagePreprocessor.prepare(image: CGImage, orientation: CGImagePropertyOrientation, configuration: FingerprintConfiguration) throws -> MLMultiArray`、`protocol ImageFingerprinting: Sendable { func fingerprint(image: CGImage, orientation: CGImagePropertyOrientation) async throws -> Fingerprint }`、`actor CoreMLFingerprinter: ImageFingerprinting`，初始化 `init(modelURL: URL, configuration: FingerprintConfiguration) throws`；测试注入初始化为 `init(configuration: FingerprintConfiguration, predict: @escaping @Sendable (MLMultiArray) throws -> [Float])`。`CoreMLFingerprinter` 明确持有单个模型与物理串行队列，actor 可重入不代表物理串行。

- [ ] **Step 1 — 写失败测试。** 在 `FingerprintTests` 编写 `testAllEightEXIFOrientations`（用有方向角标的自制图核对 8 种方向）、`testP3AndSRGBSameVisibleColorUseSamePipeline`（颜色转换对参考张量的容差来自转换协议）、`testWideImageRetainsBothEdges`（极宽图左右标记都保留）、`testInvalidVectorsRejected`（1023 维/零向量/NaN 全抛错）、`testCancelledWaitDoesNotStartSecondPhysicalInference`（可控门闩：首个物理工作未结束时第二个开始数仍为 0）。用可注入预测闭包和自制 Core ML 测试模型，不下载权重作为单测前提。
```swift
XCTAssertThrowsError(try Fingerprint(version: "unit", values: Array(repeating: 0, count: 1024)))
XCTAssertEqual(secondPhysicalStartCountBeforeFirstCompletion, 0)
```

- [ ] **Step 2 — 运行 R2 Swift 红阶段命令。** 预期接口缺失或断言失败；保存失败名，不接受环境缺库作为功能已红的证据。
- [ ] **Step 3 — 实现接口和模型来源工具。** EXIF 定向、ICC 转统一 sRGB、完整画面 resize、RGB tensor 和均值/标准差共用一条路径；来源与 PhotoKit 都调用它。使用 ImageIO 限制解码目标和在途对象，不先把所有大图解码到数组。转换工具显式传入权重，记录上游 revision、SHA256、MIT 文本、torch/coremltools/SDK/转换参数及 `.mlpackage` 哈希；复用 `work/embedding-research-larger-20260924/sscd-large/` 作参考，不能直接信任其历史结果。模型包以规范化的排序相对路径+文件字节清单计算 modelSHA256；上游 TorchScript 权重另记 weightsSHA256。若传入 .mlpackage，先验证并用 Core ML 编译为当前平台缓存再加载，缓存身份含模型哈希/OS/SDK，编译产物只作为可重建派生物。串行预测的逻辑取消不释放物理执行位置，输出校验归一化后才返回。
- [ ] **Step 4 — 建立可执行探针。** `run-probe.sh fingerprint --profile PATH --model PATH --input-list PATH --output-dir PATH` 编译 Swift 探针并逐批读取列表，输出按输入 SHA256 绑定的向量及 decode/preprocess/inference 分段耗时；不实例化 AppModel/SyncRuntime/PhotoKitGateway，不自动遍历个人目录。张量基线与 Core ML 输出在批准容差内等价才继续；可比较 stretchFullFrame 与 letterbox，但不能在 sealed 集上选择。
- [ ] **Step 5 — 绿阶段与提交。** 跑 R2 Swift 命令和 Python 工具测试，自制图通过；批准协议存在时才运行公共冻集探针。提交本任务源码、单测、Xcode 成员关系和来源记录，`git commit -m "feat: add versioned SSCD fingerprint pipeline and offline probe"`。模型权重先存 ignored 研究目录，R4 通过前不进入发行资源。

### Task 3 (R3): 精确检索基准、纯策略与查询级评分报告

**Files:** Create `ExactVectorIndex.swift`, `AdvancedDuplicatePolicy.swift`, `VectorIndexTests.swift`, `AdvancedDuplicatePolicyTests.swift`; Modify `AdvancedDedupTypes.swift`, `Tools/AdvancedDedupProbe/main.swift`, `research.py`, `PhotoSync.xcodeproj/project.pbxproj`; Test `test_advanced_dedup_research.py`。

**Interfaces:** Produces `struct VectorEntry: Sendable { key: String, origin: CandidateOrigin, fingerprint: Fingerprint, size: PixelSize? }`；`actor ExactVectorIndex { init(version: String); func replace(entries: [VectorEntry], generation: Int64) throws; func search(query: Fingerprint, minimumScore: Double, generation: Int64) throws -> [ScoredCandidate] }`。`ExactVectorIndex` 的 `nonisolated static func score(query: Fingerprint, entries: [VectorEntry], minimumScore: Double) throws -> [ScoredCandidate]` 供同版本本地/历史候选复用同一评分路径。`AdvancedDuplicatePolicy.evaluate(sourceSize: PixelSize?, candidates: [ScoredCandidate], configuration: DedupConfiguration) throws -> DuplicateEvaluation`。`research.py score --protocol PATH --dataset PATH --vectors PATH --output PATH`；统计输入是每 query 对指定图库的结果，不是任意 pair 展开。

- [ ] **Step 1 — 写失败测试。** `testFindsCoveringCandidateBeyondTopOne`：合成测试阈值 0.8，score 0.99 的 640×480 候选和 0.95 的 4000×3000 候选，对 2000×1500 来源应 `.skip` 命中第二项；`testHighResolutionCopyImports`：同样匹配、来源 4000×3000 对候选 2000×1500 应 `.duplicate/.importFile/.resolutionUpgrade`；`testUnknownOrCrossedSizesImport`：nil 或一边大一边小应导入；`testGenerationOrVersionMismatchThrows`：旧代次/不同向量版本不能返回空候选伪装唯一。`testZeroNegativeQueriesCannotPass`：无负例独立 query 时统计不得通过。
```swift
XCTAssertEqual(decision.action, .skip) // 较远但尺寸覆盖的候选必须胜出
XCTAssertEqual(upgrade.content, .duplicate)
XCTAssertEqual(upgrade.action, .importFile)
```

- [ ] **Step 2 — 运行 R3 Swift / Python 红阶段命令。** 预期上述行为缺失。
- [ ] **Step 3 — 实现连续 Float32 精确基准。** 校验同版本 1024 维向量，使用 Accelerate 点积，输出所有 `score >= minimumScore` 的有限候选，稳定按 score 降序和 key 排序；持久化向量重评分与研究基准共用精度路径。纯策略只将该表示本身的尺寸用于覆盖，返回 matched 与 covering 两组 key。候选读取失败不由此函数解释，传入者必须先确认完整有效视图。
- [ ] **Step 4 — 增加报告与回归命令。** `run-probe.sh evaluate --profile PATH --model PATH --dataset Tests/Fixtures/AdvancedDedup --output-dir PATH` 首先核对 `expected-results.json` 及其绑定，报告全部 44 个内容/动作断言和各失败样本。`run-probe.sh search-benchmark --profile PATH --vectors PATH --asset-count 100000 --edited-fraction 0|0.5|1 --output-dir PATH` 测 100000/150000/200000 表示；合成向量只能证明检索性能/一致性，不能证明图像判重准确率。输出热查询 P50/P95/P99、构建/增量耗时及峰值 RSS。
- [ ] **Step 5 — 绿阶段与提交。** 跑 R3 命令，通过纯策略和精确基准测试；另报告真实 44 例的实际结果，不能要求修改真值。提交本任务文件，`git commit -m "feat: add exact vector search and resolution-aware duplicate policy"`。

### Task 4 (R4): 封存验收、性能比较与发行配置门槛

**Files:** Modify `research.py`, `test_advanced_dedup_research.py`, `Tools/AdvancedDedupProbe/main.swift`; Create `docs/research/advanced-dedup/acceptance.md`, `acceptance.json`, `accepted-profile.json`（后两项只有通过时生成）。

**Interfaces:** Produces `verify_acceptance(protocol: dict, results: dict) -> dict` 和 `research.py accept --protocol PATH --dataset PATH --results PATH --output-dir PATH`。通过记录含 `protocol_sha256`, `dataset_sha256`, `calibration_sha256`, `sealed_results_sha256`, `model_sha256`, `preprocess_sha256`, `profile_sha256`, `pass`；配置必须反序列化为 R2/R3 的 `DedupConfiguration`。acceptanceID 固定为协议哈希与封存结果哈希的组合摘要；profile 只引用此 ID，acceptance 报告再绑定 profileSHA256，避免两份文件互含对方哈希形成循环。不能以目录名或旧 pass 文件替代实际字节绑定。

- [ ] **Step 1 — 写失败测试。** `testZeroErrorsCanStillFailConfidenceBound`：合成协议 confidence=0.95、风险上限 0.001、独立 n=100 且 0 错误，`1 - 0.05 ** (1/100)` 大于目标，结果必须拒绝；`testRejectsPerfectSafetyWithZeroRecall`：全部导入不满足最低正例召回；`testGateRejectsChangedProtocolOrMissingMeasurements`：校准后换协议、缺 P95/RSS/分层数据均失败；`testAnyFalseSkipFailsSealedGate`：任意误跳过拒绝。以上值仅用于验算拒绝路径。
```python
self.assertGreater(1 - 0.05 ** (1 / 100), 0.001)
self.assertFalse(verify_acceptance(protocol, results)["pass"])
```

- [ ] **Step 2 — 运行 Python 红阶段命令。** 预期门槛尚不存在。
- [ ] **Step 3 — 实现审计门槛。** 按 R1 冻结的独立抽样单位统计；零错误上界用单侧精确二项式界，召回的分层置信口径按预注册 alpha 分配计算并用小样本解析例校验。只在 calibration 选预处理、阈值和检索参数；记录无合格阈值的情况。封存集只用于最后验收，已用于调参的集合必须退役并换独立集合。
- [ ] **Step 4 — 执行已批准数据/协议的评估。** 收集 100000 干扰资产、0/50/100% 编辑表示、冷/热推理、查询、单项更新和 RSS。先测 exact backend；如果 exact 达到预算，发行固定 `backend="exact-f32-v1"`。如不达标，停止进入产品计划，提交候选近似实现的独立比较与精确召回差异，并更新本计划/产品后端接口的具体实现任务后再执行；不临时加第三方索引或声称 top-k 足够。真实 PhotoKit/iCloud 性能仍由产品计划的系统验收补足。
- [ ] **Step 5 — 输出结果和提交。** 工具测试绿后，只有风险/召回/44例回归/时延/RSS全满足才生成 `accepted-profile.json` 和 `pass=true` 报告，提交 `git commit -m "test: freeze validated advanced dedup profile and evidence"`；否则提交失败研究报告，结束研究阶段，不启用产品高级判重。失败不是可以通过把阈值设成 1 来规避的分支。

## 自检与交接

覆盖：spec 3.1/3.2 → R2/R3；spec 7/7.1 → R1/R3/R4；spec 8 的本地模型/检索基准 → R2/R4；实际 PhotoKit、系统授权、全应用预算留给产品计划，不能借本阶段通过替代。Review Focus 五项分别落在 R1、R2、R3、R4、R2 的具名断言。

本计划没有设置发行阈值、风险/召回数值或 M2 Pro 承诺，也没有选择尚未测量的 ANN。R1 的具体协议批准和 R4 的成功证据是可以检查的前置条件，而不是实现者自行填空。两份计划由同一 spec 约束；先审阅计划并选择执行方式，再执行 R1。协议未通过时可以继续自制数据单测，但不得通过产品入口影响实际导入。
