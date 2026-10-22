# Live Photo 变化处理与读取诊断验证

范围以 `docs/superpowers/plans/2026-10-22-live-photo-change-efficiency.md` 为准。基线 `4d1df57` 已通过上一轮完整开发验证；本轮只修改已确认的中性通知失效、增量通知遍历和读取诊断，不增加读取并发、不改写生产数据。

## 逻辑与证据

- 中性通知通过真实 observer/store 链路使识别提交失败，RED 为 1 项/3 个失败断言；修复后相关 142 项通过。仅完整对象明细、内容未变且 Live Photo 描述一致的资产保留结果；普通 journal 仍完整写入。混合批次的真实变化、未知、删除和先前失效均不被放过。
- `PHChange` 的 `objectBeforeChanges` 指传入的对象，公开契约未保证 changedObjects 是旧版本。因此适配器在现有完整加载时保存真实旧对象，增量按 ID 查询/更新。16,225 项的合成基线只分类一项变化；更新前验证完整批次，缺失/重复/冲突明细不会部分推进快照。映射 RED 为 1 项/1 个失败断言，相关 187 项 GREEN。非增量通知保留完整 membership 恢复。
- 物理读取日志 RED 为 1 项/3 个失败断言；初步 40 项资源/PhotoKit 用例通过。受控时钟与真实临时文件验证首包 2 秒、交付跨度 3 秒、完成间隔 4 秒、总计 9 秒；源字节保持为 5 字节、两个块。重复完成和迟到数据不会再发 terminal 或改变结果；日志实际经过 RunLogger 落盘，并检查不含原标识、路径和文件名。
- 首轮集成 259 项通过；随后将资源描述查询与原有容器后缀查询合并，确保诊断不会额外 fetch 一次 PhotoKit 资源。该最终版本的相关 259 项结果见 `work/live-photo-efficiency/integrated-final-tests.log`，以实际运行结果为准。

## 日志字段

`phase=live-photo-resource` 按匿名 `requestHandle` / `assetHandle` / `resourceHandle` 关联。资源信息复用既有描述读取，只有类型和有限正数视频时长进入日志；未知时长写 unknown。普通完成在每个窗口抽取两项，慢于 5 秒或失败保留明细；所有完成计数、字节和分段耗时仍汇总到 live-photo-summary。长等待每 30 秒输出一次 waiting，取消请求和真实 terminal 分开记录。

| 字段 | 含义 |
| --- | --- |
| firstDataMS | 物理请求开始至首个非空数据块 |
| deliverySpanMS | 首个至最后一个数据块到达的跨度 |
| completionGapMS | 最后一个块到 requester 完成回调的间隔，包含既有资源结束复核 |
| writeSumMS / writeMaxMS | 临时文件写入累计/最大耗时，属于交付过程的子区间 |
| finalizeMS | 完成回调后的锁等待、关闭或失败清理 |
| totalMS | 物理请求开始至终止记录 |
| receivedBytes / writtenBytes / chunks | 收到、成功写入的字节及非空块数；取消后两者可能不同 |
| state / sinceLastDataMS | 首包等待、接收或等待完成、排空状态及距末次数据时间 |

这些值是重叠的单调墙钟测量，不能相加后称为 CPU 或网络耗时。尚无首包时相应字段写 unavailable，不编造零延迟。超时/取消不释放仍在运行的物理读取；真实回调之后才发 terminal，原预算和槽位所有权保持。

`photos-fetch-details` 的 mode / examinedObjects / libraryObjects 区分增量与全量路径；`photos-change-classification.livePhotoUnchanged` 记录专用于 Live Photo 的未变分类数量，与视觉输入分类不同。已有未知/fallback 原因仍保留。

## 集成与发布

本轮使用临时 UUID 数据库、自制字节和注入的 PhotoKit 边界。没有重新导出个人媒体、运行生产应用或修改个人图库。原生 `PHFetchResultChangeDetails` 在当前个人图库上的增量访问速度尚未重新实测；合成 mapper、SDK 契约与系统适配器接线覆盖不能当作真实 iCloud 性能证明。下一次真实运行可用新增日志检验。

用户最新授权恢复 merge/release。最终深度评审后，在 main 确切归档上执行一次 `scripts/package-release.sh --scale-profile full`，同一归档完成全套验证与 Universal/ad-hoc/DMG 产物核验。最终结果以随包 validation/provenance 为准，不复用上一轮 e08b890 的成功标记。未安装/启动生产 App，不宣称 Developer ID、公证或平台实机验收。
