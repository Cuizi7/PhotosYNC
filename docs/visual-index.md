# 视觉判重与索引

照片跨文件名比较内容；视频仍用[文件名/元数据规则](sync.md)。**相似不等于可以跳过**：匹配照片还需覆盖来源分辨率。Live Photo 的精确身份和删除准入另见[配对规则](live-photo.md)。

## 比较规则与输入

- SSCD Large FP16 权重，Float32 输入/输出；1×3×320×320 输入，1,024 维归一化向量。系统 SQLite + Accelerate 精确点积，`score >= 0.98` 为匹配；至少一个匹配候选的短边、长边均不小于来源才跳过，否则保留导入。
- 0.98 是用户选定值；33 例固定回归不是独立统计校准或误跳过率保证。尺寸缺失不能推断覆盖，读取失败不能推断唯一。
- Photos 的 original 与 current 分别索引。original 只选唯一 `.photo`；current 选唯一 `.fullSizePhoto`，仅在无编辑资源时可退回 `.photo`。资源歧义不猜；不用 PhotoKit 缩略图代替。
- 来源与 Photos 共用原编码资源的 ImageIO 解码：可比较 JPEG/PNG/HEIC/HEIF 单帧图；RAW、多帧、歧义或超预算不参与指纹。已确认可读但不可比较的来源保守导入，真实读取错误仍等待/报错。
- 共同解码最长边 4096，EXIF 方向只应用一次，再以 sRGB RGBA8、高质量缩放将完整画面 stretch 到 320×320。改变解码/预处理须同步两侧并更新输入契约；归一化常数及哈希见 [profile.json](../Sources/PhotoSyncCore/Resources/AdvancedDedup/profile.json)。

## 复用与恢复

| 当前证据 | 行为 |
| --- | --- |
| 同 namespace、资产 ID、original/current、分析契约及相同有效**成功**修改日期 | 直接复用向量，零读图、零摘要、零推理；通知/descriptor 不能推翻该日期规则 |
| 日期变化、缺失或无兼容成功事实 | 只读该表示；比较实际模型输入摘要及其与成功向量的可靠绑定，相同则复用，否则推理 |
| 读取/预处理/推理失败 | 保留旧成功日期、向量、摘要及契约，非当前结果不参与决策；逐项恢复 |
| history token 过期、丢失或损坏 | 保留 namespace 与成果，退回 metadata 对账；临时历史失败退避 5/15/30/60 秒 |
| 模型/输入语义改变 | 保留旧成果但撤下不兼容候选，逐项升级，不冒充新版本 |

观察日期不是成功日期，两个 nil 不相等。成功事实须在 task/代次/身份校验后原子提交；旧回调不能复活 ready。迁移不编造成功日期或摘要绑定。**完整 metadata 枚举不等于全量重算**；中断/授权不完整不能据缺项删除，候选发布要等完整授权清单确认。

定时维护只有在同实例连续监听、上下文/代次一致、无待办变化且发布有效时才省略 catalog 遍历；启动、手动扫描或覆盖不足仍核对。单项已知读取缺口不拖住健康表示，但可能漏掉只能由该表示证明的重复。

输入 SHA-256 只覆盖预处理后的 NCHW Float32 逻辑元素，不哈希原片；运行时/输入契约不兼容不能命中。摘要相同只证明模型输入相同，不证明原文件或 Live Photo 资源相同。诊断记录比较结果/匿名计时，不输出摘要。

## 执行与预算

- Apple Silicon 优先 CPU+ANE，仅 CPU+GPU 降级；Intel 用 CPU+GPU。每个新模型实例先通过四个固定数值自检，不选 CPU-only 兜底；请求计算单元不等于证明实际硬件执行。不可用时自动重试间隔至少 60 秒，手动扫描/恢复有显式例外。
- 图片解码/预处理共享峰值预算默认 **2 GiB**，设置可调；不是进程 RSS 上限。提高上限待旧物理工作释放后重新开放此前解码超限项；降低不撤销已占用资源。模型与系统缓存额外占用。
- Photos 编码临时文件上限 **512 MiB**、磁盘保留 **128 MiB**，实际消费者结束后才释放。确定解码超限停止同版本自动重读；提高预算、手动扫描或精确输入变化可重开。
- 模型随包通过 Git LFS 固定，不在 App 运行时下载。来源、转换和许可见 [model-provenance.json](../Sources/PhotoSyncCore/Resources/AdvancedDedup/model-provenance.json) 与 [SSCD 许可证](../Sources/PhotoSyncCore/Resources/AdvancedDedup/LICENSE-SSCD.txt)。

原资源路径已做 50 对真实 Source/original 定向验证（19 正、31 负均符合预期）；这支持当前取图方式，不证明全图库召回或必须联网的 iCloud 场景。

实现：[PhotosRepresentationReader](../Sources/PhotoSyncCore/Photos/PhotosRepresentationReader.swift)、[AdvancedDuplicatePolicy](../Sources/PhotoSyncCore/Matching/AdvancedDuplicatePolicy.swift)、[PhotosIndexCoordinator](../Sources/PhotoSyncCore/Sync/PhotosIndexCoordinator.swift)。回归：[索引恢复](../Tests/PhotoSyncCoreTests/PhotosIndexCoordinatorTests.swift)、[判重](../Tests/PhotoSyncCoreTests/AdvancedDuplicatePolicyTests.swift)、[固定素材](../Tests/Fixtures/AdvancedDedup/README.md)。
