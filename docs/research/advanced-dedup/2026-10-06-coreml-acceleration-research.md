# Core ML 硬件加速研究与实施方案

日期：2026-10-06。源码基线：`5e286c7`（`codex/photosync-0.2.0-design`）。状态：独立研究完成，未修改产品、标签、0.98 阈值或发布绑定，未提交或发布。

## 结论与建议

**当前证据不支持继续把 CPU-only 作为唯一执行路径。当前 FP32 模型可在 GPU 允许配置下稳定运行；同权重 FP16 模型实际使用 ANE，推理约快 9.4 倍，且适合低驻留开销的常驻应用。** 历史 CPU-only 选择有当时的稳定性原因；本次新证据支持重新评估，但不能直接把 `.cpuOnly` 改成 `.all` 就算完成：本次发现 FP16 的 CPU 路径会失败于已有转换等价门槛。

建议将 **FP16 + `.cpuAndNeuralEngine` 作为目标方案**，同一 FP16 包的 `.cpuAndGPU` 作为已通过本机数值门槛的备选；两条路径均不可用或数值自检失败时进入等待，不把该候选切到 `.cpuOnly`。`.all` 在本机选择 ANE，但没有比限制 GPU 使用的配置显示有意义的收益；常驻后台任务优先避免与前台绘图争用 GPU。这是产品策略建议，不是本次测得的能耗结论。

**若 0.2.0 要保持可用 CPU 兜底、避免增加“仅硬件加速可用”这一产品限制，建议先实施现有 FP32 包的 `.cpuAndGPU → .cpuOnly`。** 本机热推理约快 2.6 倍，模型和预处理不变，CPU/GPU 数值差异很小。FP16 可在明确接受无 CPU 兜底的规则，或修复并重新验证 FP16 CPU 精度后切入。两种选择的差别由真实转换失败决定，不是由假设的生产索引迁移成本决定。

0.2 尚未发布，已发布 v1/schema v3 没有高级判重向量；因此不存在需要先迁移的线上 FP32 高级索引。以下版本保护仍适用于开发数据和未来升级，已有成功与 unknown 导入记录始终保留。

## 官方事实与支持边界

| 项目 | 可依赖的事实 | 对本项目的含义 |
|---|---|---|
| `computeUnits` | 配置允许使用的设备集合，系统决定分区和落点；四种配置都允许 CPU | `.all`、`.cpuAndGPU`、`.cpuAndNeuralEngine` 不构成实际加速证明。[Apple API](https://developer.apple.com/documentation/coreml/mlcomputeunits) |
| FP32 ML Program | 中间张量类型规定最低精度；FP32 可用 CPU/GPU，不能用 ANE；FP16 可因算子或设备能力以更高精度执行 | FP32 无需通过 CPU-only 保证精度，FP16 的 CPU 回退也不保证与 ANE 逐位相同。[Typed Execution](https://apple.github.io/coremltools/docs-guides/source/typed-execution.html) |
| 输入输出精度 | macOS 13 起可使用 FP16 multi-array；模型内部精度与输入输出 dtype 是独立选择 | 本候选明确维持 FP32 输入/输出，只改变内部转换精度，沿用当前 Swift 预处理与 Float32 向量存储。[Input/output types](https://apple.github.io/coremltools/docs-guides/source/model-input-and-output-types.html) |
| CPU+ANE | `.cpuAndNeuralEngine` 自 macOS 13 可用，排除 GPU | API 可用不代表设备有 ANE。Intel 路径必须单独验收；没有 ANE 时不能宣称 ANE 加速。[Apple API](https://developer.apple.com/documentation/coreml/mlcomputeunits/cpuandneuralengine) |
| 设备/计划检查 | 本地 SDK 标注 `MLComputeDevice` 为 macOS 14+、`MLComputePlan` 为 14.4+；计划返回 anticipated/preferred 设备及估算权重 | macOS 13 不能调用这些 API；计划是诊断证据，不替代执行轨迹，不把算子数当成耗时比例。[MLComputePlan](https://developer.apple.com/documentation/coreml/mlcomputeplan) |
| 并发 | 同步 prediction 需要串行使用；异步 prediction 可支持并发，代价包括更多资源占用 | 保留当前单模型、单物理 inference 队列、batch=1；本方案不需要并发推理或修改取消占槽语义。[WWDC23](https://developer.apple.com/videos/play/wwdc2023/10049/) |
| 编译与缓存 | `.mlpackage → .mlmodelc` 编译和加载时设备专用化不同；专用化缓存绑定路径/配置，系统可在升级或空间压力下清除 | 稳定复用编译路径；不每张图片编译/加载，不清理系统 Core ML 缓存；分别计编译、加载、首推理和热推理。[Model prediction](https://apple.github.io/coremltools/docs-guides/source/model-prediction.html) |
| 性能取证 | Xcode 报告/ Instruments 能检查设备使用及模型生命周期 | 日志里的 requested backend 与执行轨迹分开；不能以更短耗时或更少 CPU 时间推算瓦数/焦耳。[Performance analysis](https://developer.apple.com/documentation/coreml/analyzing-a-core-ml-model-s-performance-in-xcode) |

Apple 明确 Core ML 同时支持 Intel 和 Apple Silicon；ANE 的加速优势依赖 Apple Silicon。该平台事实不能代替这个具体模型在 macOS 13/Intel 的执行结果。[Apple Silicon architecture](https://developer.apple.com/videos/play/wwdc2020/10686/)

检索使用 agent-reach；Exa 返回 DNS `ENOTFOUND mcp.exa.ai`，按本次授权改用 web 的 Apple/coremltools 一手资料。本地 SDK 的 `MLModelConfiguration.h`、`MLComputePlan.h` 与 Swift interface 同时核对。未使用论坛普通用户说法作为 API 保证。

## 本次实验的身份与方法

- 机器：MacBook Pro / Mac14,9，M2 Pro，12 核 CPU、19 核 GPU、32 GiB 内存。macOS **27.0.1 / 26A434**；Core ML build **3600.25.2**。运行时低电量模式为 false，连续测试热状态均为 nominal。不是空载实验室环境，未关闭用户应用或抢占前台。
- 工具：Xcode 26.6 / 17F113，Swift 6.3.3；`xcrun --sdk macosx --show-sdk-version` 为 26.5。Python 3.10.8、coremltools 9.0、Torch 2.13.0，复用 `work/R2-python-deps`，未安装全局依赖。coremltools 对该 Torch 版本给出“未测试版本”的警告。
- 当前 FP32 包 SHA256：`c0cb378982abd1bd775d377d4dfd66ac3469bce894d0834ed69c3c778fb3c9b3`；176,788,972 bytes；当前 fingerprintVersion：`d7412709d47be7d1f56529adda4956f555feafd86843ca38f408a8dda87dacf6`。
- FP16 候选包 SHA256：`026e7a43660e29c307941a88dbe35b9c14468693333ff926e9b984eef3b4b8d0`；88,486,719 bytes；按当前规则得到新 fingerprintVersion：`ec805406fa61e91384e4bf29ae29a52694b80e3755afd7768da80a6db70c9a1d`。
- 两包均源于已核实 TorchScript 权重 `16a196359f91e5fc4e774d5679244c8a661c182309ad4ede0c7e83f6a9861fa0`；ML Program，minimumDeploymentTarget=macOS13，batch=1，输入 `[1,3,320,320]`，输出 1024 维。新候选 **显式**指定 `np.float32` 输入、输出。历史 9 月 FP16 包实际是 FP16 IO，不能直接充当本轮结果。
- 同一当前 R2 ImageIO 缩略图参数和 `ImagePreprocessor.prepare`：全画面拉伸、sRGB、EXIF orientation、当前 mean/std。探针直接编译产品预处理和归一化源码；所需类型从当前文件原样截取至 `LibraryContext` 之前。模型调用用独立串行探针，不启动 runtime/store/PhotoKit。
- 8 个精度/后端组合分别独立进程。每次 60–90 秒超时；进程退出码、stderr、阶段 JSONL 均保留。没有应用层自动 fallback；每条结果只代表其配置允许的集合。
- 先各做 1 次首推理、1 次预热、5 次测量的 smoke，再跑每组合 42 张图片及 5 次预热、120 次固定张量热推理。连续负载额外只选三个代表路径。所有性能负载串行执行。
- 33 例、42 图来自现有批准活动集。使用现有 `vDSP_dotpr` Float32 分数及 `AdvancedDuplicatePolicy`，只将标签的 `not_duplicate/import` 映射为产品枚举 `notDuplicate/importFile`。交叉对照仅在研究内存中赋统一版本以观察数值，**不是给产品存储重标版本的授权**。
- 所有图片/向量/原始 trace 留在本机 `work/coreml-acceleration-20261006/`；本报告不嵌入私人图片。未访问生产数据库、真实 Photos 或网络媒体来源。
- root 独立核对本轮 42 个 FP32 CPU 向量的 SHA256，与 fresh canonical `work/validation-background-preparation-v2-20261006/model-regression.json` 的输入向量身份逐个一致；研究预处理基线没有偏离刚通过验证的产品路径。

## 实测：速度、落点与稳定性

以下 P50 用中位数，P95 用 nearest-rank；均为 120 次固定准备好张量的 prediction＋输出归一化，不含图片读取、解码、SQLite、PhotoKit。JSON 驱动摘要的 P95 索引略有不同，本表以统一重算的 `numerics-summary.json` 为准。

| 模型/允许配置 | 热 P50 / P95 ms | compute plan 的可执行算子首选设备 | 33 例内容/动作 |
|---|---:|---|---:|
| FP32 CPU | 42.263 / 44.919 | 248 CPU | 33/33 |
| FP32 CPU+GPU | 17.210 / 21.375 | 219 GPU + 29 CPU | 33/33 |
| FP32 CPU+ANE | 42.584 / 43.450 | 248 CPU | 33/33 |
| FP32 all | 16.361 / 21.585 | 219 GPU + 29 CPU | 33/33 |
| FP16 CPU | 27.265 / 34.684 | 250 CPU | 33/33，但转换 golden 失败 |
| FP16 CPU+GPU | 14.898 / 16.582 | 250 GPU | 33/33 |
| FP16 CPU+ANE | 4.610 / 4.746 | 250 ANE | 33/33 |
| FP16 all | 4.580 / 4.656 | 250 ANE | 33/33 |

不具备 device usage 的常量等节点分别有 746/748 个，不算“落到 CPU”。FP32 的 `.cpuAndNeuralEngine` 计划没有 ANE，耗时与 CPU 相当，明确展示了“允许 ANE”不等于“使用 ANE”。

**ANE 已有真实执行证据**：一次独立 Instruments Core ML trace，目标进程正常退出 0；`ane-hw-intervals-internal` 导出 **1,007 条**带本探针模型名的 Apple Neural Engine 硬件事件：1 条 cached load、**1,006 条 Prediction**，对应首推理＋5 次预热＋1,000 次预测。`trace-summary.json` 记录计数。Core ML OS signpost 汇总表本轮为零行，不拿它作证明；ANE 硬件表非空且有模型标签才是该结论的依据。本轮没有另取 GPU 执行 trace，GPU 列仍是计划证据。

| 额外连续负载 | 次数 | P50 / P95 / max ms | 实际循环时长 | 重复输入最大向量差 | 进程峰值 RSS / footprint MiB |
|---|---:|---:|---:|---:|---:|
| FP32 CPU | 500 | 42.651 / 43.354 / 49.553 | 21.337 s | 0 | 391.1 / 203.7 |
| FP32 CPU+GPU | 1,000 | 16.545 / 19.665 / 30.613 | 17.069 s | 0 | 419.1 / 221.3 |
| FP16 CPU+ANE | 2,000 | 4.560 / 4.716 / 5.121 | 9.161 s | 0 | 107.8 / 98.7 |

上述进程均零崩溃、零超时，包含固定输入稳定性检查。约 47 秒独立进程运行只能证明这一有界场景，不是数小时热稳定、100k Photos 或休眠恢复验收。

首轮 smoke 的源包编译仅各测一次：FP32 76.5 ms、FP16 68.1 ms。首次使用 FP16 CPU+ANE 的 load 为 1,742.5 ms，随后 corpus 进程 load 为 49.7 ms、连续进程为 53.4 ms。首次 FP32 GPU load/首预测为 414.2/1,171.2 ms，后续连续进程为 304.9/195.5 ms；单点不能视为冷启动 P95。这里区分 fresh process、首次配置/路径使用和系统缓存冷状态；没有清缓存或重启制造系统冷启动。

注意证据字段：corpus 报告的 `firstPredictionMS` 位于 42 图循环之后，只是随后固定张量的首测，不是模型冷首推理；`loadWallSeconds/loadCPUSeconds` 是连续推理循环的 wall/CPU 时间，实际模型加载字段为 `loadMS`。不能混用。最初 FP32 smoke 的 CPU 时间字段使用了不适当的计数换算，未用于结论；后续均改用 `getrusage` 的 timeval。corpus 的 `memoryFinal` 未强制延长模型生存期，不用于空闲驻留结论；持续与生命周期测量显式保留实例。

42 图本地完整读取/解码/预处理/推理的 P50：CPU FP32 54.06 ms，GPU FP32 30.02 ms，ANE FP16 19.80 ms；它们包含不同图片，首项可含惰性初始化，只用于本地流水线对照。现有最大规模 source prepare 约 845 ms，其中 SQLite 约 616 ms；模型加速只能减少新指纹阶段，不能把 9.4 倍推理收益宣称为整个 prepare 或缓存查询的收益。

## 实测：数值与 0.98 边界

以下与本轮 FP32 CPU 的 42 个归一化输出比较；分数差是同后端 query/gallery 的现有用例比较。

| 候选 | 最大向量绝对差 | 最低向量 cosine | 最大用例分数差 | 低于阈值的最高分 / 高于阈值的最低分 |
|---|---:|---:|---:|---:|
| FP32 GPU/all | 0.000001048 | 0.9999999999465 | 0.000000507 | 0.9745907 / 0.9881904 |
| FP16 ANE/all | 0.000998409 | 0.9999591992 | 0.000502944 | 0.9744580 / 0.9881294 |
| FP16 GPU | 0.000973915 | 0.9999588805 | 0.000569105 | 0.9744939 / 0.9881475 |
| FP16 CPU | 0.004272275 | 0.9993487970 | 0.006960988 | 0.9736966 / 0.9880424 |

8×8 query/gallery 对照共 **64 组 ×33 例**，内容和动作均通过。这个数量是同一批用例的重复比较，不是 2,112 个独立样本，也不提供误跳过率置信上限。

CPU FP16 最大差在 B011：0.904353976 → 0.911314964，仍远低于 0.98。离阈值最近的 N053：FP32 CPU 0.974590540；FP16 CPU 0.973696589；FP16 ANE 0.974457979；FP16 GPU 0.974493861。该例都不重，没有翻转。**不能用本批最小边界距离为未知输入推导安全误差上限。** 未改变阈值、标签或重新启动已取消的统计校准研究。

额外沿用 R2 四个合成 TorchScript golden，现有门槛为 maxAbs≤0.02 且 cosine≥0.999：

| FP16 后端 | 通过 | 最低 cosine | 最大绝对差 |
|---|---:|---:|---:|
| CPU+ANE | 4/4 | 0.999841099 | 0.001927983 |
| CPU+GPU | 4/4 | 0.999840994 | 0.001876830 |
| CPU | **2/4，失败** | **0.985738924** | 0.017593963 |

作为同轮配对基线，当前 FP32 CPU 与 GPU 均 4/4 通过；最小 cosine 分别 0.999999999889 / 0.999999999955，最大绝对差分别 1.493e-6 / 1.259e-6。故上述 CPU FP16 失败不是只与一份未复核的历史参考作比较。

CPU 的 tensor 2/3 cosine 分别 0.995308154 / 0.985738924。这是明确的转换/执行兼容性失败，不能用 33 例恰好通过来覆盖；本报告不接受 FP16 CPU fallback，也不把其向量自动视作 ANE/GPU 的通用等价物。当前事实不足以把失败归因于某个具体算子。后续可按官方 mixed precision 能力定位/保留敏感算子 FP32，再重新过所有门槛；不得为容纳它降低门槛或移动 0.98。

转换还有一次 overflow warning。检查生成图可定位唯一非有限 immediate FP16 常量 `const_4_to_fp16` 为 clip 的上界 `+inf`，原 FP32 上界为 `3.40282347e38`。这不是非有限训练权重；对有限 FP16 输入两者均不收紧上界。此解释不能证明 CPU 数值误差根因已解决。相关常量和消费者保留在 scratch 审计文件中。

## 驻留、缓存、线程和能耗

另建更小的生命周期探针，仅载入、预测 5 次、保留 3 秒、释放、再等 3 秒。单位 MiB，RSS/phys_footprint 都是**进程**指标：

| 配置 | 保留模型空闲 3 秒 RSS / footprint | 释放后再空闲 3 秒 RSS / footprint |
|---|---:|---:|
| FP32 CPU | 206.0 / 14.9 | 26.3 / 10.5 |
| FP32 CPU+GPU | 218.8 / 56.5 | 42.9 / 27.6 |
| FP16 CPU+ANE | 28.9 / 19.4 | 27.8 / 16.9 |

这与前表峰值不同：模型文件映射、可回收页、设备服务及统一内存记账不同，不能将 RSS、footprint、GPU/ANE 分配相加。生命周期探针不含读取整包 SHA 的高水位；后端持续探针还包含身份校验和所有运行阶段。ANE 可能在系统服务持有资源，此表不是全部设备占用。

已确认 ANE 候选没有显著的进程空闲 RSS 负担；本次释放模型的额外收益很小。**第一步保留一个可复用模型实例，不为“全部卸载”增加新进程或复杂定时器。** 当前 CPU/GPU 路径若最终采用，可让同一 actor 在已有明确 quiescent 边界释放模型，后续懒加载；只有实际队列已空、底层 prediction 返回后才能释放/换后端，逻辑取消或超时不能提前腾槽。该可选生命周期变化需要单独行为测试。

编译包大小：FP32 176,821,686 bytes，FP16 88,519,315 bytes；不含系统专用化缓存。维持当前按包 hash＋OS＋Core ML build 的稳定编译路径；另外记录 backend/IO/低精度积累选项的执行身份。相同编译包可共享，不必为每张图复制；Core ML 自己按加载配置专用化。用原子 staging 和有界旧版本清理，避免每次启动重建、无界留 UUID 编译目录。首次编译可能写盘，常态不做图片/张量落盘缓存；报告本轮未量化系统缓存总占用或 idle 磁盘写入。

不增加推理并发、不使用未公开线程环境变量，不把设置 PyTorch 的线程数当作控制 Swift Core ML 线程数。保持单物理队列、batch=1、当前取消语义，CPU/GPU/ANE 内部并行交给系统。

**未量化能耗。** 本次有进程 CPU 时间、延迟、thermal state、实际 ANE 轨迹，没有瓦数、焦耳/图或整机电池消耗；少 CPU 时间不是省电证明。功耗验收可在同硬件、相同输入数/时长、记录空闲基线后，用获授权的 powermetrics/Power Profiler 对照；不需要现在索取 sudo、改变系统设置或阻塞方案。

## 历史 FP32 `.all` 崩溃复核

原文 provenance 的 macOS 27.0 崩溃不能删掉，但也不能继续当成当前所有硬件的定论。

本次找到了 2026-10-03 会话中对 `advanced-dedup-probe-2026-10-03-184732.ips` 的实际解析输出转录，栈顶为 `_platform_memmove → Espresso::dummy_blob_container::__copy_from_host → EspressoLight::espresso_plan::__copy_inputs → execute_sync → MLNeuralNetworkEngine → MLMultiFunctionProgramEngine`。原 `.ips` 在当前 DiagnosticReports/Retired 均已不可得；保留的是会话转录证据，缺完整 fault address、寄存器、线程与精确二进制绑定。旧转录同时检查了早期 FP16 IO 与当时 `work/R2-fp32` FP32 IO，随后固定 `.cpuOnly`。

因此能确认当时发生过 Core ML 输入拷贝路径崩溃；**不能据此归咎 GPU 硬件、ANE、精度本身，或断言是 Apple 已修复的 OS bug。** 当前 OS 为 27.0.1，包/探针也不等于旧故障快照。

本次对当前固定 FP32 包的四后端 smoke、42 图和热循环都成功，FP32 GPU 1,000 次额外连续运行也成功。已经将问题缩小为“历史具体环境/转换包/调用路径中的事件，不是当前包在该机所有 GPU 允许配置的必现故障”。缺旧完整现场，无法重建同条件根因；没有无限重试或用 CPU fallback 掩盖新崩溃。若再现，应由独立有超时子进程取得完整 crash/输入 dtype/shape/strides/包 hash/runtime/config，再构造最小复现；产品不得用 signal handler 继续执行受损进程。

## 可执行的接入方案

### A. 推荐性能目标：单 FP16 模型，ANE 优先

1. 维持最低 macOS 13、Universal 产品与当前公开 Core ML API。Apple Silicon 首选 `.cpuAndNeuralEngine`；明确可恢复的加载/预测错误时，同一包最多切换一次 `.cpuAndGPU`。不并行持有多个工作模型，不无限尝试 `.all`。
2. **CPU 不在该候选获准的执行兼容集合，但 API 没有“只用加速器”的选项。** 两个允许集合仍可能由系统安排部分 CPU。因此最小可执行保护是：每个新加载实例在选定 configuration 下先跑四个固定合成 golden，满足既有门槛后才输出可持久化指纹；失败则等待，不能以没有显式选择 `.cpuOnly` 作为通过。这是拟议的有界数值自检，需要批准及实现，并非当前产品已有能力；不是统计校准。macOS 14.4+ 记录计划有辅助价值，但计划不能替代该自检。
   自检只证明该实例此时对这些输入合规；它不能保证 Core ML 后续内部重新规划或任意输入的所有误差。macOS 13 缺计划 API，限制更明显。平台验证与运行时重新加载后的自检仍是方案 A 的验收缺口；若要求无此额外限制的 CPU fallback，应选择 B，而不是声称能强制 ANE-only。
3. Intel 没有 ANE，只能单独验收同 FP16 包的 `.cpuAndGPU`；其实际 GPU/CPU 分区与精度当前未知，不能将 M2 成绩推广到 Intel。若无法达到已有等价门槛，停止高级分析并显示可恢复等待/模型不兼容状态，不能把失败作“无重复候选”。若产品不能接受这个限制，选择方案 B。
4. 负载途中失败不写有效向量，不推进 ready。释放失败实例前等待物理任务结束。后端切换在同一受控队列空闲点生效，记录旧/新 requested backend、原因和结果。Swift 可捕获错误与进程崩溃区别处理；崩溃无法在进程内可靠自动降级。
5. 不自动切换到另一个 FP32 包继续共用当前索引；本轮没有提出双模型、多索引或子进程推理服务。这些属于新架构，只有单模型无法满足批准的支持范围时再立项。

### B. CPU 兜底优先：当前 FP32 模型用 GPU

当前包 `.cpuAndGPU` 为首选，明确可恢复错误后最多转 `.cpuOnly`。FP32 `.cpuAndNeuralEngine` 没有加速意义；`.all` 本机计划与 CPU+GPU 相同，不必引入额外不确定路径。保持 FP32 输入输出、同包 hash 和预处理；在设备/OS 上验收 CPU↔GPU 混合向量后可维持数学 fingerprintVersion，**执行绑定必须更新**，不能继续发布 `cpuOnly` 的旧决定。

本机 FP32 GPU/CPU 向量最大差约 1.05e-6、用例分数差约 5.07e-7，是该方案较简单的数值依据；仍非跨 OS/Intel 的无限保证。该方案同样需 macOS 13/Intel 执行验证，但不承受本轮已观察到的 FP16 CPU golden 失败。

### 版本、历史与绑定

- **FP16 新包必须新 fingerprintVersion**；内部精度变化不能只改 runtimeComputeUnits。Float32 存储格式及 SQLite dot product 不变，不需要因为“FP16 模型”就把持久向量改成 FP16。
- 同一获准精度/包的允许后端属于同一数学版本，但另设明确 execution-policy identity，绑定允许集合、优先级、fallback、`allowLowPrecisionAccumulationOnGPU=false`、IO dtype、验收证据及平台范围。运行日志记录实际选择；有计划时另记 preferred summary，有 trace 时才宣称实际设备。
- 版本改变时，Photos 表示与可重建 current 指纹失效重建；全部完成前不发布 ready。成功/attempt/unknown 历史、源身份、恢复证据和过去决定不可清空、重标或改写。v1/schema3 升级复用既有迁移边界，不因此新加一次数据库重构。
- 未来已有旧版本高级成功向量但原来源/目标已消失时，简单“只查新版本”会丢掉跨来源防重证据。保留旧事实并保持保守阻断/专门升级决策；不能因为本次 64 组通过，就把旧 blob 更新成新版本。对于未发布 0.2，先选定包再建立第一份高级索引即可避免这类首次交付迁移问题。
- 需要建立的批准绑定：**另存新的版本化 decision、profile、regression、closeout 和 model-provenance 证据**，按新批准的执行方案形成完整哈希关联，再更新 `Sources/PhotoSyncCore/Resources/AdvancedDedup/` 的当前活动 bundle。保留 `docs/research/advanced-dedup/integration-decision.json` 及当前关联 profile、regression、closeout、model-provenance 等历史研究绑定 JSON 的原始字节，不覆盖旧记录来迁就新后端；保留权重许可证确认链。不得把本报告冒充用户批准记录。
- 产品：`CoreMLFingerprinter.swift` 的加载配置、错误/生命周期、IO dtype 校验；`AdvancedDedupTypes.swift` 的 `loadValidated` 当前在约 468/503 行写死 cpuOnly/float32/当前 hash；只改 line 73 会被其余绑定拒绝。
- 工具/发布：`convert-model.py` 显式 IO dtype；`Tools/AdvancedDedupProbe`、`run-probe.sh`、actual-model 回归/验证入口要记录实际请求后端；`scripts/advanced-dedup/release.py` 当前硬编码模型 hash、weight size/hash、cpuOnly/float32，需与选择一起更新。FP16 包更换需更新 LFS/resource/provenance 身份并验证两个架构的资源一致性。
- 不修改 `ExactVectorIndex`、SQLite query、0.98、原片读取与导入语义来换取推理数字。

### 后续实施顺序与验收

1. 明确选择 A 的无 CPU 兜底契约，或 B 的 CPU 兜底契约；这是待批准的具体产品差别。本轮只交研究方案。
2. 固化选定包、FP32 IO、转换工具链/警告处理和 execution binding。若要支持 FP16 CPU，先定位上述两个 golden 失败，必要时用官方 selective FP32 conversion 产生新候选；未通过不进产品、不降低现有门槛。
3. 最小改动接入后端选择及最多一次错误降级，沿用单 actor/物理槽。没有新并发、独立服务、自动多模型迁移或对 SQLite 的改动。
4. tester 验证：允许/实际身份分离；加载/预测失败、两路径均失败、暂停取消时禁止第二物理提交；失败不缓存、不形成无重复/ready；懒加载/可选释放不丢历史或重建 gateway 绕过 unknown。注入 fake 验证这类状态，实际模型验证算数。
5. 每个正式获准后端必须通过现有四个 synthetic golden、33/33 固定阈值内容/动作、受支持后端之间 query/gallery 交叉回归和有限负载。不能把 FP16 CPU 2/4 记为通过。新增的 CPU precision fix 只重跑改变的候选，再跑最终完整门槛。
6. 在 macOS 13 Apple Silicon 和 Intel 原生系统实测加载/预测/数值/失败策略；macOS 14.4+ 的 plan API 必须有 availability guard。x86_64 构建或 Rosetta 不等于 Intel GPU 验收。当前这些系统证据仍缺，报告不能称全平台通过。
7. 以 `scripts/validate.py` 对最后产品快照完整验收；深度 reviewer 覆盖持久历史、fallback 和版本边界。若获本地发布授权，再从干净已提交归档走 `scripts/package-release.sh`，核对 app/Core Universal、精确包、资源绑定、签名、DMG/provenance。不得复用本研究探针结果替代该入口。
8. 发布性能标准先采用相对目标：同机同输入与 FP32 CPU 配对，ANE 目标至少明显降低推理延迟和进程负担且不牺牲既有数值/动作门槛；本次已观察约 9.4 倍。最终端到端预算仍沿用现有批准规则，不能把模型加速承诺为 SQLite 查询加速。功耗、长时间热状态、前台 GPU 争用可作为后续有界专项验收，未测写明未测。

## 可复查证据与命令

目录：`work/coreml-acceleration-20261006/`。`source-binding.json` 保存所读源码/固定用例绑定 SHA；所有子进程 JSON 配置保留完整参数。可重跑时使用新的 `--label`，脚本拒绝覆盖已存在的输出目录。

```sh
# 编译隔离探针；CoreTypes.swift 是当前 AdvancedDedupTypes.swift 在 LibraryContext 前的原样片段
xcrun clang -O2 -c work/coreml-acceleration-20261006/metrics.c -o work/coreml-acceleration-20261006/metrics.o
xcrun swiftc -O -target arm64-apple-macos13.0 \
  -module-cache-path work/coreml-acceleration-20261006/module-cache \
  work/coreml-acceleration-20261006/CoreTypes.swift \
  Sources/PhotoSyncCore/Fingerprinting/ImagePreprocessor.swift \
  Sources/PhotoSyncCore/Fingerprinting/CoreMLFingerprinter.swift \
  Sources/PhotoSyncCore/Matching/AdvancedDuplicatePolicy.swift \
  work/coreml-acceleration-20261006/Probe.swift work/coreml-acceleration-20261006/metrics.o \
  -o work/coreml-acceleration-20261006/probe

# 复用本地 research 依赖，转换同权重 FP16、FP32 IO（已有输出时拒绝覆盖）
PYTHONPATH=work/R2-python-deps python3 work/coreml-acceleration-20261006/convert-fp16.py

# 四后端 smoke，以及42图＋120次固定张量热推理
python3 work/coreml-acceleration-20261006/run.py --precision fp32 --label smoke --repeats 5 --warmups 1 --timeout 60
python3 work/coreml-acceleration-20261006/run.py --precision fp16 --label smoke --repeats 5 --warmups 1 --timeout 60
python3 work/coreml-acceleration-20261006/run.py --precision fp32 --label corpus --corpus --plan --repeats 120 --warmups 5 --timeout 90
python3 work/coreml-acceleration-20261006/run.py --precision fp16 --label corpus --corpus --plan --repeats 120 --warmups 5 --timeout 90

# 逐个进程串行连续负载，分别500/1000/2000次
python3 work/coreml-acceleration-20261006/run.py --precision fp32 --backends cpuOnly --label sustained --repeats 500 --warmups 5 --timeout 60
python3 work/coreml-acceleration-20261006/run.py --precision fp32 --backends cpuAndGPU --label sustained --repeats 1000 --warmups 5 --timeout 60
python3 work/coreml-acceleration-20261006/run.py --precision fp16 --backends cpuAndNeuralEngine --label sustained --repeats 2000 --warmups 5 --timeout 60

# 每个golden的确切模型、张量与后端已写入配置；同一probe直接接受该JSON
work/coreml-acceleration-20261006/probe work/coreml-acceleration-20261006/fp16-cpuOnly-golden2.json
```

关键结果：`numerics-summary.json`、`parity.json`、`synthetic-equivalence.json`（**含 CPU 失败**）、`synthetic-equivalence-gpu.json`、`synthetic-equivalence-fp32.json`、`*-sustained/report.json`、`*-lifetime.jsonl`、`trace-summary.json`、`trace-ane.xml`、`fp16-provenance.json`、`historical-crash-excerpt.txt`、`final-evidence-check.json`。所有 stderr/退出码随各运行目录保留。scratch 可含本地图片的向量、路径与设备 trace 元数据，不进入公开分发。

本次没有产品构建/完整 canonical 重验、GUI、真实 Photos/iCloud、生产库迁移、macOS 13/Intel 实机、系统能耗测量、签名打包、安装、合并或发布。已有 root 的 canonical 验证是原产品快照证据，不能提前替代未来后端变更的验收。
