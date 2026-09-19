# PhotosYNC 运行时状态与恢复契约

本文是 PhotosYNC v1 在“扫描、恢复、计数和用户提示”方面的实现契约。产品范围仍以
`outputs/2026-09-13-photo-sync-v1-design.md` 为准；本文补充其没有详细规定的运行时边界。
实现、测试和后续重构发生冲突时，先遵守本文和产品设计，再修改本文并记录迁移理由。

## 1. 四层状态，不能混用

PhotosYNC 同时维护四层状态：

1. **文件状态**：数据库中只有 `pending`、`importing`、`imported`、`skipped` 四种状态。
   重试次数、`next_retry_at`、`last_error`、attempt 和跳过原因都是字段，不是第五种状态。
2. **来源问题**：说明目录、单文件或提交是否有未解决问题。来源问题使用
   `SourceIssueKind` 分类：`sourceAvailability`、`file`、`submission`。
3. **本轮扫描状态**：`ScanProgress` 的 `notStarted`、`running`、`completed`、`interrupted`，
   以及本轮的 `checkedCandidates`、`newlyImported`、`failedFiles`、`deferred`。
4. **全局阻断/警告**：Photos 授权、图库上下文、数据库、提交结果不确定等需要人处理的阻断，
   与日志写入失败、通知未授权等非阻断警告分开保存。

不能用“有一个 waitingSources 项”推断整个来源不可用，也不能用某一轮的 `failed` 推断
数据库中的文件状态。

## 2. 来源问题分类和调度

### 2.1 来源不可用

目录不存在、卷未挂载、权限拒绝、网络连接中断、来源配置失效等属于
`sourceAvailability`。这类问题：

- 来源行显示可行动的人话，系统原文只写日志、`scan_run.last_error` 和 tooltip；
- 进入来源退避：第 1/2/3/4 次为 5/15/30/60 秒，第 5 次起为 300 秒；
- 该来源从普通扫描集合暂时移出，只由到期恢复探测重新加入；
- 成功扫描后清除来源退避和来源问题，并发送一次恢复通知；
- 相同问题重复出现时不重复写相同的失败日志或通知，但每轮仍保留批次证据。

### 2.2 单文件或提交问题

支持格式文件不可读、元数据解析失败、提交前 stamp 失败、Photos 明确拒绝某次导入，
分别属于 `file` 或 `submission`。这类问题不能把健康目录送入来源退避：

- 其他文件继续扫描；
- 来源仍按正常周期扫描；
- 文件级明确未提交失败才写 `last_error`、增加 `retry_count`，并使用文件退避 5/15/30/60 秒；
- 单文件错误可在来源行展示，但不能计入“来源等待恢复”数量；
- `failedFiles` 只统计本轮真实文件读取失败，不统计目录失效或提交结果不确定。

### 2.3 读取竞争和逻辑超时

`ReadExecutorError.sourceBusy`、`timedOut`、`resourceExhausted` 表示有界读取排队或等待结束，
不是文件损坏或来源失效。它们必须：

- 不增加 `failed` 或 `failedFiles`；
- 不建立 `waitingSources` 问题、不发来源通知、不写失败日志；
- 不改变文件的 `last_error`、`retry_count`、`next_retry_at`，也不把文件变为 `retryPending`；
- 只把当前内存扫描标记为 `deferred`，菜单显示“稍后继续”；
- 使用独立延迟曲线：第 1/2/3/4 次为 5/5/15/15 秒，之后 60 秒封顶。

来源故障 deadline 和读取 deferred deadline 必须独立保存；清除其中一条曲线不能清除另一条。

## 3. `scan_run` 和日志语义

读取 deferred 不是失败。为保持 schema v3 不增加状态字段，deferred 扫描可落一条
`complete = 1, failed = 0, last_error = NULL` 的 `scan_run`，同时在内存
`ScanProgress.deferred = true`，并写扫描事件 `result = deferred`。不得写 `result = failed`。

真正的目录或文件错误才允许把扫描标为失败、增加失败计数并写 `last_error`。提交前 stamp
读取发生 deferred 时，不调用 `recordRetry`；文件行保持原样，后续由来源 deferred 调度再次尝试。

日志按“状态变化”去重：同一来源、阶段、路径和错误签名不重复写失败行；不同子目录或文件
必须使用不同的 dedupe key。每轮 `scan_run` 仍然保留，不得用日志去重代替批次审计。

## 4. 计数和菜单文案

持久统计与本轮事件分两行：

- 持久统计：启用且未移除来源的 `imported`、`skipped`、无错误 `pending`、明确未提交的
  `retryPending`、`importing`；这些数字来自 SQLite 汇总；
- 本轮事件：检查候选数、新增导入数、本轮文件读取失败数、不可用来源数。

停用或移除来源的成功历史不重新计入活动统计，但通过 `retainedImported` 附注告知用户历史仍在。
不支持的 RAW/XMP 等非候选文件不进入候选数，也不写成 skipped。

首行文案必须是人话，不能直接展示 Foundation/POSIX 原文：

- 来源目录不可用、卷未挂载、无权限、网络中断、文件不可读、导入未确认、检查点失败、
  数据库停止、图库不可用和 Photos 未授权各有明确摘要；
- 原始错误仍保存在日志、`scan_run.last_error` 或 tooltip 中；
- 日志写入失败是 warning，不得改变全局错误图标或阻止同步；
- 通知使用 `SourceIssue.summary` / blocking summary，不发送原始系统错误。

## 5. 全局状态优先级

全局图标按以下顺序从同一份快照投影，所有按来源保存的集合都先与启用来源 ID 取交集：

1. 没有启用来源时显示未配置/未启用；
2. Photos 授权缺失或真正的全局阻断时显示错误；
3. 用户暂停时显示暂停；
4. 启用来源存在 `sourceAvailability` 时显示等待恢复，即使另一个来源正在工作；
5. 有实际扫描或提交工作时显示运行中；
6. 启用来源存在读取 deferred 时显示稍后继续；
7. `importing`、待处理/待重试记录分别显示等待核对、等待处理/等待重试；
8. 空闲时存在 file/submission 问题时显示“部分文件需要处理”；
9. 没有未完成工作且本轮已完成时才显示完成，其他未启动或中断状态显示等待扫描。

`latestScan.deferred` 是上一轮的事件记录，不能单独让已经停用来源的旧 deferred 把健康启用来源显示为等待。
文件级问题可以保留在来源行或摘要中，但不能伪装成来源不可用、进入来源恢复曲线，或让一个坏文件阻止健康兄弟文件继续工作。

## 6. 持久化和兼容性

- schema 当前为 v3，不为上述运行时分类增加文件状态；迁移必须事务化并保留旧库；
- `SourceIssue` 的 `summary`、`detail`、`kind` 分开保存语义；detail 不进入首行 UI；
- `EngineSnapshot.waitingSources` 已使用 `SourceIssue`。`waitingSourceSummaries` 是给已更新到
  新框架版本、但只需要人话摘要的迁移访问器；它不能让未重新编译的旧客户端继续使用已改变的
  `waitingSources` 类型。新增代码应直接读取 `SourceIssue`；
- 成功历史、来源停用/移除关系和 Photos 未确认提交不得因刷新失败而清空；
- Photos 与 SQLite 没有联合事务。查询不到、超时或进程崩溃不能单独证明没有提交。

## 7. 接手开发时的最小验证矩阵

任何修改扫描、调度、提示或存储的 agent 至少运行：

1. 目录 deferred：`scan_run` 无失败、无错误日志，`deferred = true`；
2. 元数据 deferred：同上，且不建立错误文件记录；
3. stamp deferred：文件仍为 pending，retry 字段不变，`retryPending = 0`；
4. 单文件错误：其他文件继续，来源不进入 source recovery backoff；
5. 混合来源失败/deferred：两套 deadline 互不覆盖；
6. Photos 授权失败、数据库失败、日志失败：文案和全局图标类别正确；
7. 退役来源历史、ARW/XMP 排除和通知摘要不回归。

测试必须使用临时目录、临时 SQLite 和注入的 fake gateway/reader。不得启动生产应用、访问生产
Photos 或依据生产数据库路径扫描媒体。当前 main 的基线为 commit `259d990`，核心测试数量以
当前构建实际输出为准；最近修复在 167 项核心测试上通过。

## 8. 变更规则

如果后续要增加真正的新文件状态、改变 deferred 的持久化含义、改变重复判定或允许 Photos 删除/覆盖，
必须先更新本文和产品设计，并新增迁移/验收说明。不要只在 UI 文案或测试 fixture 中改变语义。
