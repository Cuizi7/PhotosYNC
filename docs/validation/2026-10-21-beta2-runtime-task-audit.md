# beta2 运行任务只读诊断

观察日期：2026-10-21，以下时间均为 Asia/Shanghai。源码 `58b9559`；实际进程位于 `/Applications/PhotosYNC.app/Contents/MacOS/PhotosYNC`，21:54:20 启动，已安装版本 0.3.0 beta2 / build 19。没有停止应用、修改配置/数据库或主动触发 Photos 读写。

证据：应用 JSONL 日志、SQLite `mode=ro` + `query_only` 的聚合查询，以及合成状态快照复现。日志/数据库聚合保存在忽略目录 `work/runtime-audit-20261021/`；快照复现在 `work/progress-stability-probe/`。生产数据不进入自动回归 fixture。

## 实际推进情况

| 流程 | 观察结果 | 判断 |
| --- | --- | --- |
| 视觉索引 | 21:54:20–22:21:28：新增完成 0 次，解码预算超限失败 65 次。保持 15,959 个 ready 表示、3 个失败表示，15,716 张已有分析结果 | 主要在处理通知和重复尝试确定性失败，并非重新分析全部照片 |
| Live Photo | 启动至 22:21:30，当前 checked 资产中有 19 项在本次启动后完成核对。22:21:30 checked=63；22:24:21 checked=68，171 秒净增 5 项，约 1.76 项/分钟 | 推进很慢；这是观察窗口的吞吐，不是下载带宽或全库 ETA |
| 配对补齐 | 22:24:21 有 3 个 planned 操作，holds_unknown=0；后续只读检查均无 requiredTarget、无来源成员。903 个完整 Live Photo 候选仍 unresolved | 现有防重复创建规则要求先核实这些候选；慢速识别会连带推迟补齐，不能通过放宽该守卫解决 |
| 来源目录 | 两个来源缺少 `/Volumes/home`；恢复后的稳定探测间隔约 5 分钟 | 符合当前来源恢复策略，暂未发现调度缺陷 |

22:21:30 的 Live Photo 队列：checked 63、queued 10、unresolved 16,149。17,059 条 current unresolved **资源观察**均保留旧的 PHPhotosErrorDomain 3164；该资源数不等于图库资产数，也不能当作本次新失败数。已有完成标记仍在，禁止重置全库识别来解决慢速。

## 问题与证据强度

### 1. 任务间隙被错误解释为等待恢复（已复现）

AppModel 每次 `tick()` 后读取状态并等待约一秒。`SyncStatusPresentation.progressRows` 仅显示 `.working`；标题也由瞬时 `.working` 推导。视觉 activity 仅覆盖 `reconciling || performingRead`，Live Photo activity 仅覆盖单项/单操作的 `active` 窗口。

只改变两个 activity、保持所有队列和计数不变的合成探针输出：

| 瞬时活动 | 行 | 标题 |
| --- | --- | --- |
| 两者 working | 视觉 + Live Photo | 正在准备 |
| Live Photo 单项间隙 | 视觉 | 正在准备 |
| 视觉批次间隙 | Live Photo | 正在准备 |
| 两者都处于间隙 | 无 | 等待恢复 |

相关位置：`SyncRuntime.current`、`PhotosIndexCoordinator.activity`、两个 Live Photo coordinator 的 `activity`、`SyncStatusPresentation.progressRows/globalStatus`。这证明存在逻辑缺陷，但不能把用户观察到的每次切换都归因于这个缺陷：下述 60 秒退避也产生真实停顿。

### 2. Live Photo 通用错误让整条队列停 60 秒（已确认；具体拒绝点尚需补证）

21:54:20–22:21:28 有 22 次 `live-photo-work: libraryChanged`；截至 22:24:21 增至 25 次，间隔中位数 67.5 秒。23/25 次在 Photos 通知开始分类后的 2 秒内发生。

`runLivePhotoWork` 对通用错误统一设置 `nextLivePhotoWorkAt = now + 60`；该期限同时阻挡库存识别和配对补齐。它把单个项目/通知瞬时冲突放大成全队列等待。

`PhotoKitState.beginResourceRead` 和 `resourceReadIsCurrent` 要求全局 `pendingChangeDetails == 0`。因此任何尚未分类的通知都可能阻止新读取或拒绝已完成读取，即使随后确认与目标无关。真正的目标变化、删除、unknown coverage、权限撤回仍必须拒绝旧结果。

当前日志只记录 `libraryChanged`，没有拒绝阶段、目标匿名 handle、读取起止和事件序号，**不能证明这 25 次分别在哪个 guard 失败，也不能证明通知由下载触发或涉及同一资产**。观察窗口的通知均为视觉内容未变；视觉 `inputUnchanged` 不等于 Live Photo resource revision 未变，不能用它直接放行 Live Photo 结果。

2026-10-22 针对吞吐追问复核原日志：在前述 22:21:30.893–22:24:21.777 的 170.884 秒窗口内，错误发生于 22:21:54、22:23:01、22:24:14。按每次设置 60 秒计算，窗口内分别覆盖 60、60、7.777 秒，合计约 127.8 秒（74.8%）。这是日志触发时间与源码配置期限的交集，不是 CPU/网络采样；日志时间精度为秒，也不覆盖用户显式点击扫描解除期限的可能性。普通 tick、Photos 通知和唤醒不会解除该期限，故不能用 iCloud 下载慢解释这部分等待。

单轮先保存一个 inventory 项，再推进一次 completion；前者已增加 checked 后，后者仍可能抛错并让两者一起冷却。因此净增 5 个 checked 不是完成 5 组补齐，也不是测得 5 次下载各耗时约 34 秒。余下约 43 秒还混有读取、元数据解析、版本校验和调度；现有日志不足以将其直接归为网络耗时。修复须消除阶段间不必要的全队列退避，并补阶段计时验证，不先增加并发或放宽资源版本校验。

### 3. 确定的解码预算超限被当作临时读取失败（已确认）

三个 original 项目的 `decodedResourceLimit` 重试次数在首次观察时已超过 1,600；每次约 0.9 秒，失败后再次等待 60 秒。短暂等待不会改变同修订资源的解码预算需求。

原因：`PhotosRepresentationReader.isIsolatableReadFailure` 将所有 `unsupportedRepresentation` 一并归为读取失败，`PhotosIndexCoordinator` 按自动重试退避处理。这个逻辑早于 beta2，当前版本仍存在。现有测试覆盖健康项目继续发布，但没有跨多个 deadline 验证确定性限制不重复读取。

不能据此断言每次都重新下载 iCloud 原片。确证的是重复请求/解码尝试。修复应区分“允许健康候选继续参与判重”和“是否自动重试”，保留前者。

### 4. 状态轮询包含额外 PhotoKit 工作（已确认；次要性能问题）

`activity()` 调用 `progress()`，后者调用 `readyToken()`，进一步进入 `candidateSnapshot()`；runtime 当前状态刷新还可能重复取 progress。空切片每秒仍会进入队列/发布检查。

22:00 后的 48 个约 30 秒窗口，记录 4,944 次 candidate snapshot 调用，累计墙钟约 19.0 秒；窗口累计墙钟中位数约 2.6 毫秒，最大约 2.05 秒。窗口中也可见约 25–28 次空切片。多数调用便宜，故不把它描述为当前主要瓶颈；通知分类时出现较大等待，重复调用也增加状态交错机会。累计墙钟不是 CPU 时间。

## 修复顺序与边界

先补能区分阶段/原因的有界诊断，再修 Live Photo 通知等待与重试范围、索引确定性限制，随后从可靠的队列/准入事实生成稳定任务状态，并实现已批准原型。继续保留视觉与 Live Photo 读取的并发能力、共享预算、串行 catalog 和单一实际 Photos 写槽位。

没有证据支持重置历史、扩大解码预算、关闭安全版本检查、绕过未确认完整候选，或将两条任务强制串行。真实云端下载耗时/字节速率尚缺独立计时证据；本轮只读观察不能补充此前未做的 iCloud-only 专项验收。
