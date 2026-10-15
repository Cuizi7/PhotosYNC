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

## 实施与最终验证结果

实现提交 `477284b3025351683a7460ca4ce4cd4fedd5c847` 只改三个验收/测试文件；产品算法和运行时未变。独立 SPEC / QUALITY 审阅通过。合成 CLI 测试先证明旧校验器会接受 52 个无效报告变体，再验证新校验器逐项拒绝；缓存/新来源、小规模/规模报告均覆盖 750 ms 与 2,000 ms 等号通过，以及错误契约、预算、缺失、非法和超限数值拒绝。

完整 `scripts/validate.py` 在该干净快照执行并退出 0，`work/validation-background-preparation-v2-20261006/validation.json` 为 `passed`。包含 495 项 XCTest（0 失败、2 项显式跳过）、92 项 Tools、33 例实际模型回归、四档 Release 规模测试及两项 continuation GREEN / 预期 RED。两项跳过分别是另由四档子进程执行的规模测试和未启用的历史向量重放；本次已执行当前模型新推理。验证前后 239 项源码清单一致，SHA256 为 `35b3e2bbaa6187939f20a214e8ed7fd7e39ae23b25bc73a0a274a35ea114e9ef`。

M2 Pro 受控产品组件测量如下；使用临时 SQLite、合成图库表示和 fake Photos，查询/准备各 20 个样本，增删改各 5 个样本。“变化至就绪”取三类操作 P95 的最大值。

| Photos 表示 / 成功历史 | 纯查询 P95 ms | 缓存准备 P95 ms | 新来源准备 P95 ms | 变化至就绪 P95 ms | 峰值 RSS GiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| 100k / 0 | 167.05 | 225.01 | 300.45 | 164.01 | 0.91 |
| 150k / 0 | 250.51 | 341.41 | 430.99 | 233.36 | 1.13 |
| 200k / 0 | 338.25 | 454.24 | 555.15 | 301.47 | 1.79 |
| 200k / 100k | 610.71 | 735.97 | 845.23 | 348.81 | 1.86 |

四档按新契约均通过；这反映验收口径修订，不是产品加速。四档纯查询均零行写入、零 VFS 写入；无变化核对仍为零表示/任务/排除行写入、3 行全局状态写入和 50,772 字节逻辑 VFS 写入。最大档实际闲置 60.0005 秒，footprint 58.17 → 23.99 MiB，RSS 1.53 → 1.49 GiB，恢复查询单次 624.08 ms；期间未观测到进程磁盘读写或 page-in 增加。该进程同时保留重开前后对象，测量在日志压力与大图阶段之前，不代表真实 App 闲置或物理 SSD 磨损。

61 MP 16-bit PNG 在 200k / 最大历史两档的单次准备为 2.22 / 2.46 秒，仍高于 2 秒；这是单独披露的边界观察，不是普通来源样本的 P95，也不能宣称所有大图均满足预算。真实 Photos/iCloud、UI 负载、macOS 13/Intel 实机和签名分发没有新增验收。详细结果与历史 FAIL 并存于[验收记录](../../release/0.2.0-advanced-dedup-validation.md)。
