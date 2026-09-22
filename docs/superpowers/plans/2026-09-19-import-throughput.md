# 导入吞吐问题：诊断与修复计划

> **For agentic workers:** 实施时使用 superpowers:executing-plans，按仓库 AGENTS.md 安排一次集成 reviewer 和 tester；不要机械拆成多个实现代理。本文件是待审阅方案，本轮不修改产品代码、不安装或启动新版本。

**Goal:** 消除每张导入重复读取整个 pending 队列及整个 Photos 候选集的开销，保持现有判重、串行提交和恢复规则。

**Architecture:** 分两阶段验收。先用 SQLite 顺序游标每次选一条 pending；再为 Photos 建立带版本的、按文件名索引的增量候选快照。两阶段分别测量，以判断各自收益。

**Tech Stack:** Swift、SQLite、公开 PhotoKit、XCTest；最低 macOS 13。

**Spec:** `outputs/2026-09-13-photo-sync-v1-design.md`、`docs/specs/2026-09-18-runtime-state-and-recovery.md`、`Design/Validation.md`。本文不扩充产品边界，Photos 快照接口变更须在实施前确认本方案。

## 已核实的事实

- 旧 checkout `/Users/cuiziqi/Documents/Codex/2026-09-13/photos-mac-gui-metadata-photos-gui-2` 为 `8d9e6c990bdc7ede80eeeef017bc521a76ce2a8e`。其 `SyncEngine.swift:349` 每轮调用 `allFiles(.pending)`，`:374` 每条提交前调用 `photos.loadCandidates()`；`:585` 开始的 `allFiles` 用 256 条分页，但最终合并全部记录。旧目录有与本次无关的未跟踪文档，未修改。
- 当前源码为 `b237512a3991583dfe93342c71dedaf56a6b4426`。同样的路径仍在 `SyncEngine.swift:601`、`:654`、`:888`，所以单纯升级到当前 beta3 不会解决这两个热点。
- `SyncStore.swift:278–286` 的分页返回完整 `StoredFile`；`:496–498` 解码 metadata JSON、UUID 并重建 URL。`drain` 仅从全部结果选一条。未来重试、非本轮来源等记录也会先被读出。
- 假定 13,369 条全成功、没有新增或其他 pending 干扰，清空队列会解码 `N(N+1)/2 = 89,371,765` 条记录，而不是 13,369 条。此数是代码推导，不是线上采样计数；读取排序成本另计。
- `PhotoKitGateway.swift:65–77` 没有缓存捷径。系统实现 `:219–230` 每次 fetch 全部资产，再枚举每项资源构建候选。`DuplicatePolicy.swift:9` 又在线性数组中过滤同名项。
- `PhotoKitGateway.swift:199` 的变化通知只递增 generation；`:91–95`、`beforeMutation` 依赖索引版本保护提交。直接删掉刷新会破坏这条安全边界；仅按 generation 缓存，也可能在每张自身导入产生变化后重新全量读取。
- 本轮未重新读取生产数据库、日志或采样运行进程。用户提供的 14:03 数量和 60–65 秒/张是外部诊断输入；本轮确认代码路径存在，不能独立确认各阶段占用秒数、运行二进制对应提交或优化后实际速度。

## 本轮最小实验

只在 SQLite `:memory:` 中使用现有 `Schema.sql` 创建 13,369 条合成 pending，未打开生产数据库或媒体。macOS `/usr/bin/sqlite3` 3.51.0 的 `EXPLAIN QUERY PLAN` 显示：

```text
现有首页和后续页：
SEARCH file_record USING INDEX file_state_retry (state=?)
USE TEMP B-TREE FOR ORDER BY

增加 (state, created_order) 索引后的顺序单条查询：
SEARCH file_record USING INDEX diagnostic_pending_order (state=? AND created_order>?)
```

证据：`work/import-performance-diagnosis/system-query-plans.txt`。另一份 `query-plans.txt` 使用 PATH 中 SQLite 3.40.0，结果一致。此实验只验证 SQL 访问计划，不测 Swift 解码、网络读取或 PhotoKit 用时，也不替代应用链接 SQLite 的性能测试。

## 全局约束

- 源目录只读，Photos 仅新增；不增加并发 Photos 提交、不暂存原片、不做内容哈希。
- 保留四状态、成功历史、placeholder 检查点、unknown 阻断和已有 attempt 校验。
- 暂停、来源停用/移除及每次 await 后的提交条件仍需检查；deferred 与文件失败退避独立。
- 不重判历史 skipped、不清理生产库、不改来源配置。索引可以增加，但不修改业务行内容或 schema v3 数据含义。
- 从当前 main 开独立 `codex/` 分支实施，保留 beta3 已有修复，不回旧 checkout 改运行中的包。

### Task 1: 消除 pending 全量读取（优先）

**Files:** `Sources/PhotoSyncCore/Storage/SyncStore.swift`、`Storage/Schema.sql`、`Sync/SyncEngine.swift`；测试在 `Tests/PhotoSyncCoreTests/StoreTests.swift`、`EngineTests.swift`。

**建议接口：** `SyncStore.nextPendingFile(sourceIDs: Set<UUID>, afterID: UUID?) async throws -> StoredFile?`。空来源直接返回 nil；游标通过主键取得稳定 `created_order`，保持现有“游标对应行必须存在”的约束。

查询骨架（参数绑定，不拼接值）：

```sql
SELECT <现有 fileColumns>
FROM file_record JOIN source ON source.id = file_record.source_id
WHERE file_record.state = 'pending'
  AND file_record.created_order > ?
  AND file_record.source_id IN (<绑定的来源 ID>)
  AND source.enabled = 1 AND source.removed = 0
ORDER BY file_record.created_order
LIMIT 1;
```

- [ ] 先补 RED：10,000 条合成队列，只处理固定前缀时，读取/解码数量应与处理前缀同阶，而不是前缀乘以总队列。用隔离测试计数或临时插桩记录真实解码次数，不用几秒之内通过这类脆弱断言；不读取生产快照。
- [ ] 覆盖稳定顺序、不同来源作用域、停用/移除、空队列、游标对应行已转 imported/skipped、晚加入的新记录，以及未来重试记录不会挡住后面的正常项。
- [ ] 新增 `(state, created_order)` 索引，并同步更新两份 schema 定义。对已有 v3 库在正常打开流程事务性、幂等补建索引；不能仅改新建库 SQL，也不能删除重建数据库。保留未知高版本拒绝逻辑。
- [ ] 每个 drain 的游标从 nil 开始，选到一条后立即推进游标，再执行原有 deadline/stamp/判重/提交逻辑。删除该路径中的全量读取和 visited 集合；恢复 importing 的路径暂不改动。
- [ ] deadline 仍逐条检查，不在 SQL 中把未来记录隐式过滤掉，保持“一轮访问一次、后续由已有调度重试”的语义。新记录的 created_order 更大，当前轮可发现；低序号记录经恢复回到 pending 时，须保证后续 drain 从头处理。
- [ ] 用受控门闩覆盖：扫描并发追加、扫描改为 sourceChanged、recoverImports 让较早记录回 pending、暂停/停用发生于 await 期间。验证不会漏掉后续轮的重试、不重复提交，且晚到成功仍落库。若出现饥饿，修正 drain 唤醒衔接，不引入新调度体系。
- [ ] 用 fresh v3 / reopened v3 / 升级旧版本的自制库验证索引存在、历史内容保持、重复打开成功及索引失败不会被当成正常开启。检查实际 app SQLite 查询计划，包括多来源及大量非活动来源。
- [ ] 在 1k、10k、50k 合成记录下比较处理固定前缀的队列耗时与解码数量。目标是每选中一条只解码一条；不声称所有过滤场景下 SQL 总成本恒定，也不承诺真实导入倍率。

本阶段保持 Photos 全量刷新，用来单独量化队列优化。它可以独立验收；它不是第二个热点已经修复的证据。

### Task 2: Photos 增量候选索引及按名查询

**Files:** `Photos/PhotoKitGateway.swift`、`Photos/PhotosGateway.swift`、`Sync/SyncEngine.swift`；对应 `PhotoKitContractTests.swift`、`EngineTests.swift`、`TestSupport.swift` 及 `Sources/PhotoSyncApp/GUIQARuntime.swift`、`GUIQAReadOnlyPhotosGateway.swift` 中协议实现。协议变更时同时核对 `Tests/Regression/ContinuationRace.swift`。

**设计边界：** 这是更大的 PhotoKit 适配层变更。保留 `PHFetchResult<PHAsset>` 和按 asset ID 管理的候选，派生按原文件名精确查找的桶。对外返回带 generation 的不可变快照；提交绑定本次判重快照的 generation，不能让另一次扫描刷新索引后替旧判定“续期”。不改 DuplicatePolicy 的规则。

- [ ] 补 RED：无变化时反复查询只构建一次全索引；模拟连续 100 次自身新增时只解析新增/变更资产；按一个文件名查候选不遍历整个候选数组。计数观测放在 fake lifecycle/测试内。
- [ ] 首次建立完整索引，保留 includeHiddenAssets/includeAllBurstAssets 及同一资产的多个资源名。变化回调先使旧 generation 不可提交，再在串行上下文中应用变化；不能在任意回调队列上无锁修改共享字典。
- [ ] 使用 `PHChange` 对保留 fetch result 的变更明细：删除旧资产对应候选，插入/变更资产重新提取全部资源候选，更新为 `fetchResultAfterChanges`。无可用增量或快照失配时安全重建；重建失败保持阻断，不能把错误当空库。
- [ ] 仍检查权限和图库可用性。快照版本必须从判重一直带到 create 的 admission 和 beforeMutation。期间发生变化就拒绝这次尚未提交的请求并重新取快照、判重；已提交结果不因变化被丢弃。
- [ ] 自身导入也按同一增量路径处理；成功历史及时落库，在通知到达前参与本地候选查询。不能仅凭源文件 metadata 冒充 Photos 实际资源 metadata，也不能为了性能忽略自身事件。
- [ ] 引擎扫描和提交均按文件名取得 Photos 候选，再合并现有本地候选；保留 `olderPendingOnly` 及成功历史策略。避免“缓存了系统枚举，但每张仍复制和过滤全库数组”。
- [ ] 覆盖外部同名新增、资源名/metadata 改变、删除、非增量变更、回调延迟/重排边界、全量构建期间变化、判重后另一轮刷新、权限撤回、图库不可用。变化无法证实时保守阻断；同名任一候选不能排除仍跳过。
- [ ] 验证删除 Photos 资产仅影响当前 Photos 索引，不删除本地成功历史，不导致补导。验证 unknown/超时/检查点失败仍不允许另一个实际提交。
- [ ] 因改变 PhotoKit 读取和通知处理方式，补针对性系统验收：隔离授权环境、自制媒体，核对自身和外部变化通知、实际资源名、增量/全量回退；不默认用正在同步的个人图库。授权或环境缺口单列，不以 fake 通过代替。

本机 SDK 依据：`MacOSX26.5.sdk/.../Photos.framework/Headers/PHChange.h:51–76` 提供 after fetch result、增量可用标志及增删改对象；`PHPhotoLibrary.h:36–40` 说明回调来自任意串行队列。Apple 对非增量变更要求全量重载，见 [hasIncrementalChanges](https://developer.apple.com/documentation/photos/phfetchresultchangedetails/hasincrementalchanges)。

## 评审与验收

重点检查五类输入：大队列中的未来重试；游标之后/之前并发出现的工作；判重和提交之间的图库变化；权限丢失或非增量更新；成功历史与目标删除。这些分别由阶段一游标测试和阶段二 lifecycle 测试覆盖。

- [ ] reviewer 检查最终集成差异的判重、持久化和并发安全；修复后只复核新差异，不重复同快照评审。
- [ ] tester 在最后一次行为/测试变更后运行统一入口：

```sh
python3 scripts/validate.py \
  --output-dir "$PWD/work/validation-import-throughput-<唯一名称>" \
  --derived-data "$PWD/work/validation-import-throughput-<唯一名称>-derived"
```

- [ ] 记录阶段耗时：取下一条、stamp、Photos 快照刷新、判重、PhotoKit 提交、成功落库。以自制固定数据比较各阶段及总吞吐，不把 fake Photos 速度外推为生产速度。
- [ ] 只有后续获准交付新包时才变更版本、提交源码并使用 `scripts/package-release.sh`；产物目录必须全新。安装/替换/重启生产应用、远端推送和生产数据操作不属于本轮诊断规划。

## 本轮交付边界

已完成：两 checkout 静态调用链核对、临时 SQLite 查询计划实验、PhotoKit SDK 契约核对和本计划。

未进行：产品代码修改、完整构建/XCTest、GUI、真实 Photos 验收、性能修复后实测、签名打包、安装或重启生产应用。仍不能给出新的队列完成日期。
