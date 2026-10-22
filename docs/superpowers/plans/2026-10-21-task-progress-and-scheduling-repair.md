# 任务状态与推进效率修复实施计划

> **For agentic workers:** 使用 `superpowers:executing-plans` 串行实施。2026-10-22 用户已批准实施；由父代理串行修改，独立代理负责只读探索、评审和验证。

**Goal:** 修复 beta2 的整队列退避、确定性超限重复读取、瞬时活动误判及额外轮询工作，并实现已批准的进度/hover 原型。

**Architecture:** 继续使用现有 coordinator、runtime、队列和快照；为通知分类和可运行工作提供明确的 typed facts。由这些事实驱动稳定任务展示，不另建下载服务、UI 持久状态机或改变底层并发上限。

**Tech Stack:** Swift / PhotoKit / SQLite / SwiftUI / XCTest，macOS 13+。

**Spec:** [设计与修复契约](../specs/2026-10-21-task-progress-and-scheduling-repair-design.md)。[当前运行证据](../../validation/2026-10-21-beta2-runtime-task-audit.md)。基线 `58b9559`。

## Global Constraints

- 六标题、单任务一行、独立计数、固定任务顺序、同宽同高纯色轨道和任务 hover 按已批准原型。
- schema v11、成功历史、一次性识别标记、既有候选和未知写入保护不变。
- 不扩大 512 MiB 预算，不放宽来源只读、资源版本或全局单写槽位。
- 真实生产资料只用于只读诊断；自动回归使用合成数据/临时库，不运行生产来源。
- 已有代码根工作树已附着，可在实施时从 main 创建隔离分支；当前原型及诊断均在忽略的 work 目录。

## Review Focus

1. 视觉 inputUnchanged 但 Live Photo revision 真变：旧结果必须拒绝。
2. 原件在通知分类窗口完成，随后又来新事件：不丢无关变化下的有效结果、不无限循环或释放仍在使用的资源。
3. 队列里只有未来重试/未核实依赖：不能因 pending 非零永远显示正在准备。
4. 超限暂停与单项临时失败并存：健康工作继续，真实网络失败仍可自动重试，旧暂停不会被启动/唤醒重开。
5. GUI 轮询不触发 PhotoKit 工作，同时真实判重/写入守卫继续复核版本；hover 打开时状态更新不丢锚点。

### Task 1：Live Photo 变化等待与退避范围

**Files:** `PhotoKitGateway.swift`、`LivePhotoPhotosGateway.swift`、`LivePhotoInventoryCoordinator.swift`、`LivePhotoCoordinator.swift`、`SyncRuntime.swift`、现有 logging 文件；`LivePhotoKitContractTests.swift`、`AdvancedRuntimeTests.swift`。

**Interfaces:** 在现有读取错误/准入类型中增加明确的 classification-pending 原因；分类/描述失效、单项 I/O 失败、全局恢复分别传递到 runtime。在现有 producer 的 submission lock 下捕获水位并排入 FIFO 分类完成标记，禁止新增第二个分类器。标记不调用 `candidateSnapshot()`，不加载候选；单次逻辑等待最多 5 秒，使用可注入单调时钟和一次性完成机制。

- [x] 先补有界 LP 阶段诊断：read-admission、raw-read、classification、metadata、descriptor-validation、observation-commit、completion；匿名 handle、原因、事件与耗时，30 秒聚合，零工作不刷日志。
- [x] 写 RED：现有受控 raw read 在 pending details 窗口完成；无关/确切资源未变事件在分类后可接受；新读在分类前不能派发；目标修改时间/资源 key 变更、删除、unknown、权限撤回拒绝。加入“视觉 inputUnchanged 但 LP revision changed”反例。
- [x] 实现上述 FIFO 标记和 typed deferral：每个已完成 raw read 最多等待一次，保留 ticket/lease 到消费者实际结束。超时返回 pending、取消返回 cancellation，迟到标记不再恢复调用者或产生副作用；raw 尚未结束时保留原有物理释放规则。
- [x] RED/GREEN：5 秒超时、取消、迟到标记及新事件插入；新 pending 延后、已分类事件重新验证、unknown coverage 拒绝。metadata/入库前再次遇到 pending 也传递 typed 原因；有限等待不得通过绕过分类或重复派发来实现。
- [x] 写 runtime RED：模拟 25 次分类窗口竞争与多个健康资产，分类完成后可继续下一 tick；不设置 60 秒全 LP deadline、不热循环；目标真变只读新 descriptor。
- [x] 将单项失败保留在对应项/操作期限，分类竞争由现有事件/tick恢复；仅真正全局不可用才保留全局等待。保留未核实完整候选和 unknown mutation 的安全守卫。
- [x] 运行上述合约/runtime/库存/配对回归，检查有界读取、预算最终归零和无重复写入，GREEN 后提交。

### Task 2：终止确定性解码超限的自动重读

**Files:** `PhotosRepresentationReader.swift`、`PhotosIndexGateway.swift`、`PhotosIndexCoordinator.swift`、`SyncStore.swift`、`SyncRuntime.swift`、`AppModel.swift`；读取、索引、store/runtime 测试。

**Interfaces:** 不扩展持久化 `RepresentationFailureKind`，保留 v11 的 `NULL/'photos_read'` CHECK。typed `decodedResourceLimit` 分支写入 `.photosRead` + `Date.distantFuture`，将该组合作为 fingerprint task 的专用自动重试暂停编码；其他临时失败写有限期限。增加仅由显式扫描触发的 `retryIndexReadLimits` 准入，不复用启动/唤醒 `force`。在进度摘要增加按 asset 去重的 `requiresAttentionAssets`，独立于 publication ready 和普通 read errors。

- [x] RED：同修订超限后时间推进多个 60 秒周期，read 次数不再增加，健康 sibling token 仍可发布；普通 imageReadFailed/iCloudUnavailable 仍可自动重试。
- [x] 将“是否可隔离以继续发布”和“是否可自动重试”分开；保持 `Self.readFailureMatch` 的 photos_read 隔离语义。任务选择明确排除专用暂停组合，显式 retry 仅更新与当前 context/修订/generation/输入契约有效匹配的该组合；不得靠解析 last_error 做选择。
- [x] RED/GREEN：资源修订/输入契约变更重开；显式扫描仅重开该类 hold；重启、唤醒、普通 tick 不重开；旧 photos_read 记录下次经 typed 结果自然归类，无生产回填。
- [x] RED/GREEN：已发布健康索引仍有保留项时，摘要可读出独立人工处理数；同资产多表示只计一张。覆盖旧 v11 数据库真实 CHECK、重启持久化、stale failure/retry 无效、普通重试不被手动入口修改，确认无需 schema 迁移。
- [x] 核对旧枚举值及持久记录兼容、暂停期限和诊断说明，运行受影响读取/store/index/runtime 测试并提交。

### Task 3：可靠的任务生命周期与低开销状态读取

**Files:** `LivePhotoTypes.swift`、`PhotosIndexCoordinator.swift`、两个 LP coordinator、`SyncRuntime.swift`、必要的 `SyncStore.swift` 只读摘要；`SyncStatusPresentation.swift`、`GlobalStatus.swift`；coordinator/runtime/presentation 测试。

**Interfaces:** 在已有 `IndexActivity` 增加 `.queued`，在 `LivePhotoActivity` 增加 `.queued(LivePhotoActivityKind)`；它们只表示有到期且通过现有必要准入的工作。队列摘要复用实际选择谓词和当前 context/generation，不按错误文案猜测，不加载全库资源 payload。

- [x] 将 `work/progress-stability-probe` 的四帧序列写为 RED：计数不变、working/queued交替时，两行及标题保持；真正 future retry/排空/未核实依赖则进入等待，未知写入仍最高安全等待。
- [x] 扩展 activity 覆盖逻辑轮次：正常批次 yield 为 queued；LP inventory 到期项与 completion 准入分别判断，planned 计数本身不能证明可补齐。运行时全局 deadline/权限/暂停要覆盖 coordinator 的局部事实。
- [x] RED/GREEN：publication ready 但有解码保留项不算全部结束；仅剩这些项目时为“需要处理”，有健康工作时保持运行标题并显示局部需处理数。暂停/未知写入沿用现有优先级，不能把所有 read errors 都归为人工处理。
- [x] 将 `progress/activity/current` 改为无 PhotoKit 工作的只读投影；保留真正 reconciliation、发布、判重和提交路径的 fresh version 验证。复用现有进度发布节奏，避免重复读取同一摘要。
- [x] 没有到期工作时跳过空消费切片，按已有下一期限和通知唤醒；不能仅延长统一轮询间隔，也不能缓存一个永久 ready 布尔值。
- [x] RED/GREEN：双 gate 同时工作、短批次交错、空队列、未来重试、通知到达、暂停/恢复/停用、一次性任务 completed+unresolved、终止保护性保留。用调用计数证明状态轮询不再触发 candidateSnapshot。
- [x] 同一份展示投影供标题、任务行和 hover 复用；用连续快照断言它们一致，不新增独立 UI 状态存储。运行受影响测试并提交。

### Task 4：实现已批准原型并完成集成验证

**Files:** `SyncProgressView.swift`、`SyncStatusPresentation.swift`、`StatusMenu.swift`、`SourceSettings.swift`、必要的 `HoverDetailsButton.swift`；`AppViewTests.swift`、`SyncStatusPresentationTests.swift`、`Tests/UIReview/`；运行时契约/验证记录。

- [x] 每任务一行：名称、数量、ⓘ 同行，轨道紧贴其下；固定 visualIndex/livePhoto 顺序和稳定 ID。等待/暂停状态保留数量，动画停下；有解码保留项时同一行显示“N 张需处理”，hover 说明原因和“立即扫描”重试入口。只有结束/不再适用才撤行。
- [x] 已知/未知进度统一5pt高、占满同一内容宽度、纯色无渐变；未知仅移动短段。降低动态效果设置下保留静态活动指示，不能造百分比。
- [x] 分任务 hover 使用已审文案：视觉已有分析结果包含历史；LP 计数是图库项目核对数而非补齐数；补齐阶段不沿用识别百分比；iCloud流量、续跑及旧单项影响准确。更新时保持锚点、点击固定与 Escape。
- [x] 原生离屏/GUIQA 覆盖单/双任务、known/unknown、等待/暂停/补齐/需处理、浅深色及 hover 打开期间切换；核对与已批准 v2 原型一致，补充需处理场景。原型原文件在 `work/task-progress-prototypes/`。
- [x] 深度评审完整集成 diff，独立 tester 核对最后行为快照；先定向，再用 `python3 scripts/validate.py --scale-profile full` 执行完整验收。若用户另行授权发布，则按既有规则让 main 归档 package 执行该最终 canonical，避免只读评审引发重复全套。
- [x] 验收报告对照基线：LP 接受/拒绝原因和吞吐、通知分类等待、超限重读次数、空切片与快照调用数。先以门闩/时钟证明逻辑修复，真实运行测量单独标注版本和时间窗口，不把原片网络速度当成固定性能承诺。

## 完成标准

没有未解决 P1/P2；真实内容不确定仍保守，正常调度间隙不冒充恢复等待；确定性超限不周期性重读；健康队列不被无关通知整队列冻结；状态/数量/hover与批准原型一致。合并、版本号和发布按后续用户授权执行。

## 方案评审记录

2026-10-21：独立深度评审后修订 v11 持久化兼容编码、可发布与需处理状态的区别、分类等待的事件水位/5 秒期限/取消/迟到边界。修订复核无剩余 P1/P2 设计阻塞。该记录属于实施前的方案评审，不是修复后的测试或性能证据。


## 实施与验收记录（2026-10-22）

已在 `codex/task-progress-scheduling-repair` 串行完成，代码快照 `4fb4190`。独立深度评审发现的三处 P2 已有 RED/GREEN 并修复，无剩余 P1/P2；完整 `full` 验收通过：899 XCTest（2 条件跳过）、102 工具测试、四档规模预算、两组续体竞态。详见[验收报告](../../validation/2026-10-22-task-progress-repair.md)。

UI 已完成 198 张原生视图矩阵及 4 个任务弹层、12 次生命周期转换检查；同宽 5pt/无渐变由像素测试验证。既有 hover/点击固定/Escape 实现保留。非激活窗口无法证明物理 hover、Escape、焦点或系统菜单材质，真实 iCloud 吞吐也未复测；这些边界在报告中保留为未实测，不冒称通过。分支和工作树保留，本轮未合并或发布。
