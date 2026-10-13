# PhotosYNC 原始资源路径真实验收收尾 Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development. One private-harness implementation owner at a time, task-scoped safety review, and integrated result verification. Do not repeat accepted product implementation tasks.

**Goal:** 完成用户批准的两项后续工作：补当前编辑版／必须联网资源的新路径只读验证，继续既定限定图库判重、最后单张 canary 与回收，并生成本地 0.2.0 beta 包。

**Architecture:** 沿用公开产品 Core、独立 QA 身份／状态和正常 coordinator。旧宿主、数据库、日志和人工标签封存；在新的 ignored 私有目录中适配现有宿主。先只读，真实写入只由 root 在防护检查后逐阶段开启。

**Tech Stack:** Swift、PhotoKit、ImageIO、Core ML、系统 SQLite／Accelerate、既有私有 Python 审计工具、LaunchServices、本地 ad-hoc 打包。

**Spec:** [共同解码契约](../specs/2026-10-11-original-resource-common-decoder-design.md)、[真实图库验收计划](../../release/2026-10-06-real-photos-icloud-validation-plan.md)、[高级判重设计](../specs/2026-09-28-photosync-0.2.0-advanced-dedup-design.md)。这是已批准验收的当前执行细化，不新增产品功能或放宽原就绪／写入门槛。

## Global Constraints

- SSCD Large、FP16 ANE 优先／GPU 降级、Float32 320×320 输入／1024 维向量和 `score >= 0.98` 不变。
- 当前产品行为冻结为 `cd32bd6`，只读产物源码为 `f467ed4`，canary 构建源码为 `a469324`，两者间仅文档变更；输入 `encoded-resource-imageio-v1`，SQLite schema v8。旧 Photos 预览向量须通过正常 coordinator 重建，不能改版本标签后复用。
- 只读判重仍限定原冻结的 256 Photos 资产、3,017 来源图片及原 50 独立配对。Source 目录严格只读；已有标签不修改，源工作缓存不授予旧评分有效性。
- 相同编码 Source 解码契约的旧正式版本仅可在精确版本、模型、来源身份／stamp、尺寸、向量字节及摘要等事实校验后复用；不扩展成任意跨版本缓存兼容。每行重新查询正常发布的新候选快照。
- 当前编辑版从可靠 descriptor 精确绑定唯一 `.fullSizePhoto`。使用自然已有编辑，不编辑既有 Photos 资产。编辑版检查与云端检查可以使用不同样本，不要求人为制造同时满足两条件的图片。
- 网络探针最多 10 个自然资产，每次一个请求；精确资源禁网时的公开 `PHPhotosErrorDomain / PHPhotosErrorNetworkAccessRequired (3164)` 终态才是必须联网的证据。随后直接使用产品联网取图路径，不先用额外联网探针暖缓存。无合格样本如实保留缺口，不驱逐缓存、改图库／iCloud 设置或全局断网。
- 产品读取后使用共同 ImageIO／预处理／模型；编码暂存量不是网络传输量。底层终态、lease／物理预算归零及确切临时目录清理均须核验。
- 每批最多 500 次允许联网表示请求／30 分钟；Source 轮次上限 1,800 秒；完成时来源清单和最终统一评分 token 仍须成立。明确单项错误分账，不伪造向量或判不重。
- 只读阶段 Photos mutations = 0，禁止 engine drain／创建／删除装配。真实写阶段仅一张全新自制 scratch canary，新 manifest 的 `maximumCreates = 1` 且校验必须为 1；原始 URL／`shouldMoveFile = false`，不突破既有最多 3 资产的跨会话耐崩溃总上限。未决提交阻断，不能换 runID 绕过。
- canary 使用生产历史完整一致只读快照的 QA 副本，并正常完成限定候选索引；生产 DB 不迁移、不改写，不将空库或 photos-only 研究库当完整历史。实际生产实例锁先于写能力图。
- 回收只消费同一 run 台账确证成功且基线不存在的确切 ID；不按名称、时间或全库差集删除。最近删除定向永久清理由用户正常界面完成，仅本次测试图；清理未完成不能宣称完全恢复。
- 私人图片、路径／资产 ID、数据库及向量只在 ignored `work/`；旧证据不覆盖。Root 不读取个人图片像素，内容审阅使用有界子代理。
- 仅本地包获授权；不合并、推送、公开发布、安装／启动生产 App、修改生产配置、Developer ID／公证。
- 平台范围更新（2026-10-13，用户确认）：本轮不执行 macOS 13 或 Intel 实机验证，两项均不作为本轮本地 beta 收尾条件；如实记录运行行为未验证。最低支持版本仍为 macOS 13，Universal 构建和最低部署目标核验继续执行。

## Review Focus

1. 旧取图版本、编辑版资源选择或提前暖缓存导致伪新路径／伪云端验收。
2. 范围包装、通知覆盖、迁移或来源 sidecar 复用使旧评分冒充统一新索引结论。
3. 取消／超时／日志失败时提前退出，丢失在途物理资源或清理证据。
4. 生产历史／unknown 未完整保护，或 QA 锁不能排斥实际生产实例。
5. 台账不完整、并发用户变更、最近删除残留被错误认定为可删除或完全恢复。

### Task 1: 新路径只读验收与限定目录判重

**Files:** 在 `work/real-photos-icloud/20261011-final-qa/readonly/` 和 `probes/` 复制并最小适配既有 `20261010-bounded-mobilebackup/host`、`analysis` 及 `20261011-original-resource-product/host` 的具名源码／配方；不修改旧冻结目录。完整报告落本计划 workspace。

**Interfaces:** 公开 `PhotoKitGateway.readRepresentation`、现有 `PhotosIndexCoordinator`／`SyncStore.vectorCandidates`，具名 Source sidecar、scope 和原样本标签；用实际 Core 创建指纹和发布 token，不复制产品算法。

- [x] 保存当前源／Core／资源／宿主构建绑定和运行限额；先 RED/GREEN 覆盖旧 Photos 输入拒绝、精确 Source 复用、编辑版选择、3164 分类、无预暖网络步骤、版本／scope／token 错配拒绝，以及实际 drain／只读不变量。
- [x] 编译新私有宿主并执行最小相关 fake／工具检查。独立安全 reviewer 对最小适配和新真实入口给出 SPEC／QUALITY 结论；root 开启真实阶段前核对实际 hash／签名。
- [x] 串行检查少量已有编辑版，核对原始版／当前版选择及尺寸，使用新产品资源读取、共同缩图与模型。最多 10 自然资产寻找明确需网络的原始资源，禁网终态后直接调用产品联网路径；记录绑定、阶段时间、终态、暂存归属／清理。
- [x] 对原 256 资产通过正常 coordinator 重建旧 Photos 向量并发布限定 ready；保留单项读取缺口及正常通知证据。停止并重新打开一次，证明合法新向量复用和重新发布，不手写 token。
- [x] 核对原来源冻结清单，先做 50 pilot，再复用已完成来源扫描的合法元数据／指纹，对 3,017 来源重新查询新候选快照；不为新配对测试重新解码全部健康 Source。Source 合法缓存复用单列；任何 typed source 错误保持 waiting／未评分。
- [x] 保留原 50 独立真值，在新完整查询结果中复核检出。旧双向选择及失败保持原样；对新判重／判不重结果按原随机及阈值附近协议另存具名新选择，不静默替换旧样本。仅需要的新预览经精确资源绑定导出，保留物理 drain／失败证据。给子代理匿名图像和关系信息、隐藏 score／算法分类；疑似误判／uncertain 做独立复核，不重调阈值。
- [x] 记录退出、来源不变性、Photos mutations = 0、scope 分母、读取缺口及实际资源情况。Tester 独立核对具名结果／清单／摘要／台账，不重新启动图库读取；真实阶段通过与未建立场景明确分开。

### Task 2: 单张真实 canary 与精确回收

**Files:** 在 `work/real-photos-icloud/20261011-final-qa/canary/` 复制最小既有 `20261010-minimal-canary/` 宿主／配方，保留旧 fake 报告；不增加产品写入／删除 API。

**Interfaces:** 当前 Core `AdvancedDedupService.prepare`、`SyncEngine`、同一限定 gateway／coordinator／store；生产一致快照、实际生产 `SingleInstanceLock`、冻结自制输入清单、耐崩溃 intent／placeholder／completion／rollback journal。

- [x] 最小适配 v8／新输入及当前 Core；重跑相关 fake，覆盖生产路径拒绝、完整历史／unknown、实际生产锁、全程限定 gateway、单项额度、日志／checkpoint 失败、确切 ID 清理与并发无关资产保留。新私有适配经独立安全 review 后才构建真实写阶段。
- [x] 只读阶段完成后，root 核对当前生产进程／未决提交及原运行状态；需要暂停／退出时使用已有正常入口。没有可靠恢复路径则不自行启动或强杀。取得实际生产锁和最新全部来源一致快照，再对隔离 QA 副本做 v8 迁移／历史保护核验和正常限定索引就绪。
- [x] 冻结唯一自制 canary 和输入身份，先判定及保存耐崩溃意图；一次真实创建，检查 Core／台账／Photos 的成功 ID 相同。任何 unknown 或额外新增保留现场并阻断后续。
- [x] 同路径复扫无新增；同字节改名 scratch 副本判重跳过且 createCalls = 0。随后关闭新创建，按同一台账确切 ID 回收；删除后只读重扫原输入，成功历史仍防补导。
- [x] 核验活动图库／原有资产／来源／生产配置和历史。用户仅对本次 canary 完成最近删除定向收尾；正常并发变化分账、缓存与他端传播限制保留。QA 真正 drain／退出、生产锁释放并恢复原运行状态。
- [x] Tester 独立核对写入／回收／历史证据链；未完成系统交互仍为 cleanup_pending，不能勾选完整恢复。

### Task 3: 脱敏记录与本地 0.2.0 beta 包

**Files:** 更新真实验收／merge readiness、`docs/release/0.2.0-beta.md`、README 的实际状态与 v8／原始资源表述、必要 CHANGELOG；源码行为和阈值不变。当前版本 0.2.0 beta／build 7，目标 `outputs/releases/0.2.0-beta/`。

- [x] 将实际执行结果写入脱敏记录；修正旧 v7／预览描述，区别历史证据、当前验收、限定候选、真实编辑／联网、写入回收和未验证平台。每个变更映射至本次目标，私人数据不进入 Git。
- [x] 最终集成 reviewer 核对跨阶段安全／证据与发行结论，避免重审相同已通过产品快照。处理本轮新增范围内的问题；产品设计变化仍按 AGENTS.md 另行征得批准。
- [x] 提交最终文档，核对工作树干净。执行唯一入口 `scripts/package-release.sh`，由该确切提交归档完整验收和 Universal Release 构建。失败保留独立 work 证据，不覆盖已有包或锁。
- [x] 独立核对包内 provenance、validation 完整结束／数量／退出码、模型／版本／图标、Universal app/Core、签名、DMG 和 SHA256。报告本地包路径、真实闭环结果和剩余边界；不安装／启动生产 App。

## 2026-10-13 实际检查点

Task 1 已在批准的限定范围内完成：3,017 来源、51 内容重复／2,965 低于阈值／1 等待；原 19 组已知副本检出，新增 87 组盲审为 36 重复／50 不重／1 不确定，独立证据核验通过。六组编辑版／原版路径通过，十个禁网样本未建立明确必须联网场景；Task 1 勾选表示执行已完成，不能冒充这一场景通过。一个资产修改时间变化影响两处旧候选，另一候选匹配的一组可判重，另一组保留不确定；归档缺完整 revision 输入及事件分类，根因边界见收尾记录。只读宿主已退出，资源／Photos mutations 为零，标签和失败证据保持封存。

Task 2 静态准备、16 组 fake、安全评审及独立宿主构建完成，实际系统授权和完整生产历史保护均已成立。Task 3 文档同步进行，最终集成审阅和归档打包依次执行；包内 provenance 绑定实际源码与完整验收结果。

Task 2 实际追加：授权回调3，生产实例锁归属和完整历史一致快照核验通过，QA 副本迁移／unknown 检查通过。正常限定索引 ready token +256资产／262表示／0读取缺口／物理归零成立；Store 原始 progress.state 的 updating 不等于 coordinator 未就绪，不改产品门槛。实际仅一次创建且确切 ID 绑定，同路径复扫无新增、改名同字节副本 skip 及成功依赖证据通过。用户确认系统删除后 PhotoKit 回调成功，精确台账状态为 deleted；删除后复扫仍保留成功历史且累计创建数为1。用户随后确认仅永久删除该测试图；正常最终 marker、物理归零、原生进程退出及既有生产锁可获取均已核验。`open -W` 返回0只记录 launcher 状态，不当作直接原生 exit code；Host 固定 manual_confirmation_required 标志与用户真实 UI 完成凭据分开保存。前段临时资源采样固定窗口到期，后段在同一宿主删除后复扫前重启采样并在实际 drain 后停止；不声称连续或全覆盖。没有启动生产应用，原先停止状态保持。

Task 3 实际追加：脱敏记录及集成评审完成。首次归档包装因本机 `lipo` 双架构参数错误退出1，无发行目录；修复为分别强制验证 App／Core 的两种架构，真实工具回归及增量深度评审通过。随后干净提交 `d6702f9ba3d3146277d2321bf0fcb1125ff43544` 的统一入口退出0：589项 XCTest（2跳过、0失败）、97项 Tools、模型／runtime／四档规模／两项竞态和正常 Universal Release 构建通过。新本地包 `outputs/releases/0.2.0-beta/` 的源码、资源、版本、架构、签名、DMG及849项摘要通过独立核验。计划完成标记在包生成后更新，包内 provenance 仍绑定实际归档提交；未合并、推送、公开发布、安装或启动生产 App。
