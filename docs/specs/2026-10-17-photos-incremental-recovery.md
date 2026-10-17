# Photos 按 ID/date 增量分析的最终契约

日期：2026-10-17；依据用户最后确认，取代本文件较早的额外内容失效策略。

## 已确认原则

- 始终逐项增量，不提供清空重建快捷路径；任何失败均不得批量 ready→pending、truncate 成果，或重新随机换域使旧成果不可见。完整 metadata 枚举只是对账，不是全量重建。
- 在同设备持久资产 ID 域、同表示 original/current、同分析契约下：同 ID + 相同有效 modificationDate 直接复用，不读图、不计算输入摘要、不推理。不再以资源描述/尺寸变动、token/context 状态或额外内容通知推翻相同有效 date。
- date 不同，只处理该项：读对应版本、准备实际模型输入、比较与成功向量可靠绑定的摘要/契约；相同则复用向量并确认新成功 date，不同才预测该项。
- 读/预处理/预测失败保留旧成功向量及成功 date/摘要/分析契约，标记待更新并按现有退避重试；观察到的新 date 不是已分析成功的 date，不能提前记成已处理。
- date 缺失/无效或无旧成果是单项缺证据，进入该项验证，不牵连全库。没有兼容的旧摘要/向量配对不能猜测命中。
- 新资产/新表示逐项计算。删除/排除只有完整、授权且可靠的 inventory 对账才能逐项确认；权限不足、瞬时读取失败或中断清单不作删除。
- 模型/输入语义契约变更，旧向量保留但不能冒充新版本；受影响项渐进计算。没有新增媒体类型、来源哈希、生产维护或图库写入。

## 成功事实与当前观察

RepresentationDescriptor 传递精确有效的 modificationDate，保留现有 revision 作为读取时的定位/竞态证据。SQLite 分开保存当前观察的 date 与成功分析对应的 date/版本；比较使用成功事实，不能以 pending 的目标字段解释旧向量。

新成功结果或摘要命中，在同一事务内接受当前 task/代际/表示身份后提交成功 date、向量、摘要和契约。复用读取与复用接受都须检查配对仍有效。失败不推进成功 date；旧任务或过期结果不复活 ready。失败保留向量时，查询必须依赖状态/当前有效性，不能把保留的旧向量当作当前成果；既有 read-gap 分类如保留，仍必须隔离旧向量。

v9 没有原始成功 date，不能从 revision hash 反推。迁移不批量作废 ready：首次清单若现有完整 revision/版本匹配，可仅为该项补齐成功 date/向量版本的已证事实；不伪造旧摘要/向量配对。不能证明匹配的旧项逐项核查。schema v10 的新增字段均事务化，双份 schema 同步，旧版拒绝高版本。无可靠日期不能将两个 nil 当作相同日期。

## 恢复和并发

持久对象 namespace 从独立 SQLite 身份恢复，不依赖 token 解码成功；它不是 Photos 图库 UUID。checkpoint 缺失/损坏/不匹配只失去历史游标。暂时历史错误保留成果并退避；token 过期/详情不可用退化为 metadata 对账。

观察者和 catalog session/generation 屏障继续发现创建、删除及 date 变化，不能因新策略吞掉变化。必须覆盖：恢复前与恢复期间收到事件；同 date 是零读取/零推理的正例，date 不同是必须更新且不得发布旧 ready 的反例。覆盖 await 后暂停/取消、权限失败、枚举期间变化和 checkpoint 提交窗口，中断重开不归零。

## 摘要算法与契约

生产配置的实际输入为 1×3×320×320 NCHW Float32。ImageIO 选择/解码静态表示，ImagePreprocessor 应用 EXIF 方向一次，在 sRGB RGBA8 premultiplied backing 上以 high interpolation 做配置的 stretch/letterbox，按通道进行 (RGB/255-mean)/std 的 Float32 归一化。PreparedTensorDigest 对有限值的逻辑元素按通道→行→列序列化成小端 Float32，以 SHA-256 处理 1,228,800 字节，不包含 strides/padding，不哈希原片、文件名或其它 metadata。

摘要契约：model-input-sha256-v1 | nchw-f32-le | imageio-selection-v1 | cg-srgb-rgba8-premultiplied-high-exif-v1 | FingerprintConfiguration.version | OS/ImageIO/CoreGraphics/ColorSync runtime identity。配置版本绑定模型 SHA-256、输入尺寸、resize mode、色彩、mean/std 和 inputContract。相同成功 date 的直接复用以同分析语义配置版本为前提；运行时摘要契约差异仅在该项进入输入验证时阻止摘要复用，不触发全库重建。

## 验收

仅使用临时 UUID SQLite、mock、自制媒体及现有合成 fixtures。RED→GREEN、逐项复用/失败/中断、v9 迁移、启动事件顺序、规格/质量复核后，冻结快照运行 canonical full profile（718 基线数量不是固定目标），不削减任何门槛。此前 canonical full-2 因工具 fake probe 2 秒超时退出 1 的事实保留；补跑工具 102/102 和两项真实续体均通过，但不是该 canonical 的 exit 0。

真实 Photos、生产 SQLite、目标、生产应用、权限、监控、合并、推送、发布不在本任务执行范围。自动通过不代表真实图库验收。

## 官方依据

[PHObject.localIdentifier](https://developer.apple.com/documentation/photos/phobject/localidentifier) 是同设备持久对象标识；[PHAsset.modificationDate](https://developer.apple.com/documentation/photos/phasset/modificationdate) 在内容或 metadata 变动时更新。[WWDC22 change history](https://developer.apple.com/videos/play/wwdc2022/10132/) 说明 token 过旧/详情不可用后重新获取资产及修改日期 fallback。未证实应用版本升级会高概率使 token 失效。
