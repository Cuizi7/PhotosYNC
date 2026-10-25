# 架构

PhotosYNC 是 macOS 13+ 菜单栏应用：只读目录 → 识别/判重 → 写入系统 Photos 图库。应用名为 PhotosYNC；工程、模块、bundle identity 和数据目录仍沿用 PhotoSync。

## 责任与路径

| 层 | 入口与责任 |
| --- | --- |
| 界面 | [AppModel](../Sources/PhotoSyncApp/AppModel.swift) 持有设置窗口；[SyncStatusPresentation](../Sources/PhotoSyncApp/SyncStatusPresentation.swift) 从快照产生显示，不查图库 |
| 调度 | [SyncRuntime](../Sources/PhotoSyncApp/SyncRuntime.swift) 持有唯一运行图、定时器和 worker；统一暂停、唤醒与活动投影 |
| 来源同步 | [SyncEngine](../Sources/PhotoSyncCore/Sync/SyncEngine.swift) 枚举、判重、排队、恢复和提交 |
| 图库分析 | [PhotosIndexCoordinator](../Sources/PhotoSyncCore/Sync/PhotosIndexCoordinator.swift) 管视觉表示与发布；[LivePhotoInventoryCoordinator](../Sources/PhotoSyncCore/Sync/LivePhotoInventoryCoordinator.swift) 管配对身份识别 |
| Live Photo 补齐 | [LivePhotoCoordinator](../Sources/PhotoSyncCore/Sync/LivePhotoCoordinator.swift) 管创建、验证、定向清理 |
| 系统边界 | [PhotoKitGateway](../Sources/PhotoSyncCore/Photos/PhotoKitGateway.swift) 封装公开 PhotoKit、变化通知、资源读取与唯一写入槽位；Sources 目录封装文件读取 |
| 持久化 | [SyncStore](../Sources/PhotoSyncCore/Storage/SyncStore.swift) 串行 SQLite、事务、成功证据与恢复任务 |

## 必须保持的边界

- **先枚举，后准入。** 安全的来源枚举可与图库准备并行；判重/实际提交必须取得有效候选证据。Live Photo 还要求其目录批次就绪。不能用一个“准备完毕”开关阻塞全部工作。
- **共享资源，不共享完成含义。** 视觉与 Live Photo 共用 gateway/store，catalog 枚举串行，worker 分开推进。视觉向量、配对身份、完整目标验证是不同证据；目前失效处理也不同，见[已知问题](README.md#当前未解决)。
- **一个 Photos 写入槽位。** 普通导入、成对创建和清理共用；未知提交跨重启阻断新写入。不得重建 gateway 或释放槽位来绕过。
- **成功事实与当前可用性分开。** 失效可以撤下候选，不能抹掉成功导入或成功分析事实；失败/观察到的新版本不能冒充成功。旧任务的结果须通过身份、版本、代次和暂停守卫再落库。
- **逻辑结束不等于物理结束。** 超时/取消不释放仍被系统读取、解析或消费的文件、预算与槽位；取消只发一次，真实终止后清理。不可中断的 I/O 可能需要用户重启，禁止无限增开 worker。
- **namespace 不是图库 UUID。** token 只是变化游标；失效退回元数据核对，不随机换域或清库。恢复 Live Photo 历史还需已知资产的正向连续性证据；权限/图库不明则等待。

## 数据与诊断

- 运行库：`~/Library/Application Support/PhotoSync/sync.sqlite`；日志：同目录 `Logs/`。排查先只读，不用删库恢复进度。
- 当前 schema **v12**；支持的 v3–v11 事务迁移保留历史。同步维护 [Schema.sql](../Sources/PhotoSyncCore/Storage/Schema.sql) 与代码迁移；未知高版本拒绝打开，不支持直接降级。
- SQLite 队列不能等待网络或 PhotoKit。`BUSY/LOCKED` 经有界退避在同一 runtime/store/gateway 恢复；真实存储故障阻断。成功回调后的落库失败仍保留未知/成功证据，不允许重复提交。
- 四种文件状态、索引表示、Live Photo 操作、UI 状态各有用途，不能相互替代。源码和数据库结构是字段清单，文档只定义边界。
- 日志保留阶段、系统错误链及匿名因果计时。资源字节数不是网络流量；嵌套耗时会重叠，不能相加或统称下载时间；`no-progress` 不代表完成。

回归入口：[运行场景 R01–R16](../Tests/Support/RuntimeScenarios.json)、[启动恢复](../Tests/PhotoSyncCoreTests/StartupRecoveryTests.swift)、[验证方法](testing/README.md)。
