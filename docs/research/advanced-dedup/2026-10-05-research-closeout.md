# 研究阶段收尾与 0.98 集成交接 — 2026-10-05

研究阶段按用户最新决定收尾：**初始判重阈值固定为 0.98，进入产品集成准备，不继续开展独立校准或大规模封存研究。** 本次只更新交接材料、spec 和产品计划，没有执行 P1–P9。

用户原话已原样记录在 `integration-decision.json`。这是用户选定阈值和调整推进顺序的决策，不是独立统计研究通过。原 `protocol.json`、旧 0.8 配置及历史 44 例报告保持原样；原先的 ≤0.01% 误跳过率置信上限、分层召回置信要求没有获得证明，也没有被改成较低数字来制造通过。

## 固定配置与本次实际检查

| 项目 | 收尾记录 |
| --- | --- |
| 判重阈值 | `score >= 0.98`；明确来源为用户选择 |
| 模型 / 预处理 | SSCD Large、FP32 Core ML、CPU-only、全画面 stretch 320×320、sRGB，沿用 R2 的 mean/std 和 1024 维 L2 Float32 指纹 |
| 检索 / 尺寸策略 | `exact-f32-v1`；取得所有达阈值候选后按对应表示尺寸决定，高清升级仍导入 |
| 当前用例 | active suite `2026-10-04-no-information-panels`，33 例 / 42 图；11 个信息看板用例仍仅存于历史底本 |
| 本次验证 | **33/33 内容及动作均通过**：14 判重、19 判不重；11 跳过、22 导入，其中 3 个高清升级导入 |
| 推理工作 | 没有重新生成图片指纹；校验旧指纹字节后，用原 Swift `ExactVectorIndex.score` 和 `AdvancedDuplicatePolicy.evaluate` 在 0.98 重放当前 33 例各自定义的候选集合；本集每例仅 1 个候选，不是对整座图库的检验 |
| 配置可读取性 | 最终 integration profile 通过现有 Swift `DedupConfiguration` 反序列化、策略版本与资源约束检查 |
| 未做 | 新照片独立校准、封存统计验收、0.98 的新性能基准、十万真实资产与真实 Photos/iCloud 验收 |

这次 33/33 是固定公开回归结果，不代表生产误跳过率为零或已证明 ≤0.01%。前一天的 27/33 对应旧 0.8；两份结果分别保存，未改写原观察值。新重放的候选分数及向量哈希与原记录逐条一致，变化来自阈值和策略版本。

## 交接文件与身份

- `integration-decision.json`：用户指令、日期、阈值、模型/运行配置、active suite 和未完成验证的边界。**该文件原始字节的 SHA256 就是 decision ID**。
- `integration-profile.json`：符合现有 `DedupConfiguration` 的配置；`acceptanceID = user-decision:<decision SHA256>`。继续使用这个既有字段，不把它解释为统计通过。
- `2026-10-05-threshold-098-regression.json`：33 例共享 Swift scorer 重放结果，绑定真值、active suite、源向量清单、decision 与 profile。
- `research-closeout.json`：绑定上述文件和配置，并将 `approvedForProductIntegration=true` 与 `statisticalAcceptance.status=not_performed` 分开记录。此处批准的是采用当前配置进入集成，不是发布、安装或真实图库写入授权。

这些文件单向绑定，不互含对方哈希形成循环：decision → profile → regression → closeout（后一项绑定前项）。最终 profile SHA256 为 `10a98218d0b7b5b1ea7be01d057be26c33da0c088e68e07ccd97d5843dc52404`；新 policyVersion 为 `42a811d97844de4a0e2223060178ee1136ef74775a31d2d12a56f9007eff6570`。fingerprintVersion 仍是 `d7412709d47be7d1f56529adda4956f555feafd86843ca38f408a8dda87dacf6`，因此不需要重建已有向量。

旧研究 wrapper 的 `score-batch` 要求研究用 acceptanceID。本次在 ignored `work/research-closeout-20261005/replay-profile.json` 中使用其要求的旧 protocol ID，其他数值、模型、预处理、资源及策略字段与最终 integration profile 完全相同；旧协议仅提供 runner 的输入/资源一致性约束，不代表按原 R4 方案通过验收。最终 user-decision profile 另经 `validate-profile` 直接解析。原始 batch 和 Swift 输出留在 `work/research-closeout-20261005/raw-replay.json`，没有绕过或修改旧 `evaluate` / `accept` 的拒绝逻辑。

## 对产品集成计划的调整

1. P1 开始使用用户决策、固定配置、当前回归和 closeout 的相互绑定，替代“必须先取得 R4 统计 pass”这一已被用户变更的前置。模型/配置/哈希错误仍须拒绝，不能接受任意研究草稿。
2. 直接复用现有 FP32 CPU-only 模型、预处理、精确索引和判定代码；不重做模型选择，不引入第二模型或向量数据库服务。
3. 阈值是单一版本化配置参数。未来根据生产情况调整时，生成新 decision/profile/policyVersion 并在应用重启时加载；同一运行期保持配置不变，不增加热更新或阈值滑杆。只改变阈值不得触发同 fingerprintVersion 的全库下载/推理。
4. 旧判定缓存按 policyVersion 失效。符合条件的旧疑似重复 skip 使用已有可中断重判流程重新评估；success/unknown 不被重开或自动补导。将这些要求落实到 P4/P7 的具名测试。
5. 日志同时覆盖导入和跳过，记录实际阈值、策略版本、最接近候选的精确分数及与阈值的差；包含低于阈值的近邻，诊断候选最多 10 条，关键决定候选独立保留。研究 profile 的 `evidenceCandidateLimit=200000` 是历史评分容量上限，不能直接变成生产日志输出量。生产日志只提供分析证据，不自动改变阈值。
6. 独立统计研究不再作为本版集成前置；正常自动回归、PhotoKit/iCloud、资源有界性、平台和发行权限检查继续由产品计划承担。已有合成大图库性能只作工程基线，未做的真实大图库验收必须明确记录，不能换标签当作通过。

## 本次收尾验证

在代码基线 `a6d3750` 上完成共享 Swift scorer 的 33 例重放与最终配置解析；独立 tester 又逐例核对真值、原分数/向量、输入 batch 与四份交接文件的哈希，未发现不一致。固定素材完整性检查通过：当前 33 例 / 42 图、历史 44 例 / 63 图。首次检查因 Python 环境缺少 Pillow 未进入校验，修正环境后的实际校验退出码为 0。原协议、active suite、冻结真值与图片均未修改。

独立 reviewer 的 SPEC / QUALITY / PLAN-INTEGRATION 审阅通过；发现的旧来源重新启用后游标遗漏问题已在 P7/spec 补齐触发条件和计划测试，并经复核关闭。计划中的产品测试尚未执行。本次只改变配置记录和文档，没有重跑 App 构建或完整自动套件，也没有新增模型、性能或系统验收声明。

原始审计报告保留在 `work/research-closeout-20261005/validation.md` 和 `review.md`；Markdown 本地链接及 `git diff --check` 均通过。

## 收尾范围

模型权重再分发许可、六张用户图片的公开分发许可、真实 Photos/iCloud 与 macOS 13/Intel 等边界仍独立存在；它们没有因选定阈值而被证明或授权。后续使用已批准资源与测试环境，按修订后的产品计划继续；本次不执行产品集成、生产数据操作、合并、推送或发布。
