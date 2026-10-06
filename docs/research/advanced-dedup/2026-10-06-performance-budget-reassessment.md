# 后台判重性能预算复核（2026-10-06）

用户要求分析 250 ms 是否合理、有无依据，并明确授权在不合理时修改。结论：它有早期可行性粗测作为参考，但不足以作为当前所有规模的产品硬门槛。当前集成验收改用 `background-preparation-v2`；旧协议、配置哈希链、原始测量和旧 FAIL 均不改写。

## 250 ms 的出处与适用范围

最早的明确值出现在 `d95584014541b8586c8fe8c26f9e5792d43c89fa`：`protocol.json.max_hot_query_p95_ms = 250`。此前设计仅要求先冻结数字再测量，没有给出 250。原 `protocol.md` §“Proposed conversion, performance and resource gate” 将它定义为 M2 Pro、100k/200k 表示下的本地读取、预处理、推理、检索和策略的端到端 P95；另设变更表示生成及清单更新 2 秒、峰值 RSS 4 GiB。

原文以 4.53 ms 推理中位数、49.60 ms 本地 JPEG 读取加推理中位数作为放宽初始预算的动机，并明确说这些数字不能证明所提的 P95。没有查到恰好 250 ms 的业务吞吐推导或用户可感知时延要求。

这组历史依据来自 `work/embedding-research-larger-20260924/sscd-large/`：

- `coreml-all-results.json`：60 次暖预测，p50 4.5287 ms；输入已是 320×320 tensor，不含解码和检索。
- `coreml-pipeline-results.json`：80 个合成 9–12 MP JPEG 暖读取样本，读取至推理 p50 49.601 ms、p95 51.213 ms；不含图库检索、PhotoKit、NAS 或 HEIC。
- `conversion.json` 及两份结果均对应 **FP16 转换、Core ML `compute_units=all`**，包大小 88,486,159 字节，预处理也不是当前冻结的 R2 来源路径。允许系统选择设备不证明具体由 ANE 执行。

当前产品是 FP32、CPU-only、冻结的 R2 预处理及 SQLite 全候选精确查询。这些旧中位数既不是匹配配置的基线，也不能直接推导当前 P95。后续 `d6bee1a` 又把 250 ms 用于跳过解码和推理的缓存命中 `hot_preparation_ms`，而新来源 `source_incremental_ms` 允许 2 秒；`a32fd9f` 新增的 `raw_query_ms` 则只测 SQLite 查询。三个口径不能互换。最大测量还扩至 200k Photos 表示加 100k 成功历史。

原批准记录引用的问题把风险、召回和性能数字放在一起，但用户原答复只明确选择了“≤0.01%”误跳过置信上限；不能仅凭该答复声称用户特别要求 250 ms。历史记录仍原样保留；本次修改依据是当前用户对指标复核和修订的明确授权。

## 与交互体验的关系

`AdvancedDedupService`、`SyncEngine`、`SyncRuntime` 是 actor；引擎异步等待准备完成再串行提交，SQLite 查询在 store 的串行队列执行。该计时不等于 `@MainActor` 输入到屏幕更新的停顿，但会影响后台队列推进速度。实际 UI 响应和完整导入吞吐仍需分别验证，不能只凭 async 关键字或这一指标宣称体验通过。

Apple 的 [Understanding hangs in your app](https://developer.apple.com/documentation/xcode/understanding-hangs-in-your-app) 和 [Analyzing responsiveness issues](https://developer.apple.com/documentation/xcode/analyzing-responsiveness-issues-in-your-shipping-app) 将 250 ms 用于主运行循环无响应的卡顿检测/统计。[Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness) 的约 100 ms 建议针对离散交互后的同步主线程工作。这些均不规定后台判重查询必须在 250 ms 内完成，也不提供 PhotosYNC 的吞吐或内存 SLA。

用户后来明确优先考虑常驻但闲置时的资源占用、高频查询的磁盘负担和实现简单。为追逐不匹配的 250 ms 门槛重新引入整库堆缓存，不符合这一取舍。

## 当前集成契约：background-preparation-v2

| 项目 | 当前规则 | 测量终点与边界 |
| --- | --- | --- |
| 缓存命中后的判重准备 | P95 ≤ 2,000 ms | `service.prepare` 返回有效 admission；包含就绪/资格检查、查询、策略及最终校验 |
| 新照片判重准备 | P95 ≤ 2,000 ms | 同一接口、同一终点，另含本地读取、预处理与 CPU 推理 |
| Photos 单项变化 | 保留现有 2,000 ms 上限 | 当前 harness 每次观测均须满足，并验证有效 token、Photos 代次、表示数；不是仅等到推理返回 |
| 峰值 RSS | 保留 ≤ 4 GiB | 原受控进程口径不变 |
| 纯查询 | 报告各规模 P50/P95/P99，不设独立 250 ms 阻断线 | 查询为完整后台准备的组成部分；不把它冒充 UI 响应或完整导入吞吐 |
| 闲置与写入 | 保留原测量和零写入检查 | 四档查询零写入；无变化核对零表示/任务/排除行写入；最大档实际 60 秒闲置及恢复测量 |

2 秒沿用集成阶段已有的准备预算，并把同一个后台工作单元的缓存/未缓存路径统一；没有另取一个恰好高于当前 732 ms 的新数字。它仍是项目工程保护线，不是行业标准，也不是经过真实全量图库验证的产品 SLA。验收统计限额不改变运行时超时、取消或未知结果处理。

暂不设新的硬吞吐率：实际导入还包含 PhotoKit 提交/回调，iCloud 和网络等待不可由这些本地样本推出。继续报告分段时延、不同规模和图像的分布，后续用生产证据决定是否需要新的吞吐要求。20 个合成来源样本不代表所有分辨率/格式；61 MP 16-bit PNG 的 2.24–2.56 秒单次观察仍需披露，不能因改门槛就称所有大图通过。

## 实施与验证边界

- 仅更新现有 Swift 验收测试、Python 验收门及对应合成 CLI 测试；不改产品算法、存储、运行时资源策略、0.98 阈值或四份不可变资源记录。
- 小规模 runtime 和四档 scale 报告显式记录 `performance_contract = background-preparation-v2` 和准备预算 2,000 ms。Python 门槛须拒绝缺失/错误契约、非有限/非法/超限 P95 或虚假的 `budget_pass`；不得仅相信一个布尔通过标记。
- 缓存与新来源分别验证边界（含 2,000 ms 等号）；Photos 变化终点、内存、写入、样本数和闲置证据门槛继续生效。
- `protocol.json` / 原研究评估器与历史结果保持原样。旧 250 ms FAIL 仍表示未达到旧目标；新判定必须绑定新契约和新快照，不能把旧 JSON 的 `budget_pass` 改成 true。
- 独立评审这次门槛变更并执行当前完整自动入口。修改指标不等于算法加速，也不替代真实 Photos/iCloud、平台、GUI 或分发验收。

实施与最终验收结果待追加；旧测量 `1714857` 的缓存/新来源 P95 在四档均低于 2 秒，只支持按新口径的回顾性判断，不冒充已经执行的新 canonical PASS。
