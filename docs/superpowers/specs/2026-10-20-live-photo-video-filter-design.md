# PhotosYNC：来源级 Live Photo 动态视频过滤与定向清理设计

日期：2026-10-20（Asia/Shanghai）。代码基线：773a493f85a0d6a4f69a96fe19ca5cd304f9cd8e。
状态：已被用户于2026-10-20明确提出的新目标替代。后文保留为历史设计和调查记录，不再是可执行规格；旧评审结论只覆盖旧目标。

当前目标：固定且默认将配套照片与MOV作为一个完整原生Live Photo导入Photos，保留动态画面和声音，避免独立短视频；不新增来源级或全局设置选项。旧过滤开关、相应UI原型和只导入照片部分的方案均不再适用。精确12个已导入MOV的维护需求仍保留，但须结合完整Live Photo导入及已有图库资产的处理重新设计，当前不执行旧清理方案。产品、清理脚本均未实现，未删除Photos资产或回退生产数据库。

2026-10-21用户进一步明确统一流程：来源只有HEIC或只有MOV时，允许先作为独立照片/视频导入Photos，尽量保存源目录中本来就不完整的内容；发现另一半后再合成为完整Live Photo。既有不完整项目和新发现项目使用同一配对/补齐逻辑。此前“缺半时一直等待、禁止单项导入”不再适用。用户随后明确授权：成功合并后清理旧单项也包括图库原有、能够精确确认配对的照片和视频。后续以[完整Live Photo补齐设计](2026-10-21-native-live-photo-completion-design.md)为新方案，不执行后文旧过滤/回退方案。

## 1. 已确认目标与范围

用户希望 Synology 备份中的 Live Photo 只以静态照片进入 Photos，避免动态 MOV 成为独立短视频，同时保留普通视频同步。本轮用户新增并明确要求：

- 每个来源目录独立配置是否跳过 Live Photo 动态视频，默认开启、可以关闭；包含已有来源的升级默认值。
- 因涉及设置界面，增加设计评审及实现后真实原生 UI 验收。
- 制作一次性临时脚本，精确清理先前确认的 12 个已导入 MOV，并使对应同步记录恢复为未导入状态。这是对这 12 个明确目标的维护例外，不改变产品“保留成功历史、不删除 Photos 资产”的一般规则。

其他已确认规则继续成立：MOV 自身有可靠 Live Photo 证据时，HEIC 尚未到位也不得先按普通视频导入；HEIC 独立走现有照片读取、视觉判重和导入路径。其他原有照片格式继续按原规则处理；不把“只导入 HEIC”扩成禁止 JPEG 等静态照片。

范围不包含 Live Photo 重新配对导入、源文件修改、Synology 设置修改、Photos 资产自动清理、新调度器、全局视频开关或判重算法调整。

## 2. 研究依据和可行性验证

Synology 官方说明备份后的 Live Photo 由 HEIC 和 MOV 两文件保存；预览和压缩视频属于另外的处理机制。官方材料未在所查页面承诺两文件的原子到达、固定写入顺序或永远同名，因此不能依赖这些假设。

- https://kb.synology.com/en-global/DSM/tutorial/Why_is_uploaded_photo_smaller_than_one_in_iOS_Photos
- https://kb.synology.com/en-global/DSM/tutorial/How_does_Synology_Photos_process_and_display_my_photos

Apple 描述了照片/MOV 的共享标识及 MOV 中标记静态帧时刻的 timed metadata。ContentIdentifier 单字段是通用字段，不作为单独跳过依据。

- https://developer.apple.com/videos/play/wwdc2016/501/
- https://developer.apple.com/documentation/avfoundation/avmetadataidentifier/quicktimemetadatacontentidentifier

本轮只读 AVFoundation 探针读取 QuickTime ContentIdentifier，以及元数据轨中 `mdta/com.apple.quicktime.still-image-time` 的实际样本。12 个已确认真实 MOV 全部满足两项证据；普通 Canon MP4、普通短 MOV、使用原生 API 写入 ContentIdentifier 但无静态帧标记的 MOV 均未误判，共 15/15。探针不读取配套照片。

证据原位于 `/tmp/photosync-livephoto-probe/`，已将探针源码、最终结果和编译日志归档至被忽略的 `work/livephoto-native-feasibility-20261020/`。`Probe.swift` SHA-256 为 `0234dd152d048442586deec6ad4b7c736f88b85c38cff02708cc34775fdbaac6`，`result-final.jsonl` 为 `319979daa787039774e7f9fbcbd29c529af079b51b729f9abc9da2b917bf0d52`。这些是现场验证证据，不是永久测试夹；源码和自动测试不得依赖该 work 路径或个人媒体。

宿主 macOS 27.0.1 / Swift 6.4，部署目标 arm64 macOS 13.0。这是原生读取方法的可行性证据，不是产品拦截、完整自动验收、性能或 macOS 13 实机证据。使用原始 metadata identifier 字符串是格式约定；没有声称存在名为 quickTimeMetadataStillImageTime 的公开常量。产品不引入 ExifTool、ffmpeg 或私有 API。

## 3. 来源选项和持久化

字段建议名 `skipLivePhotoVideos: Bool`，属于 RegisteredSource / source 配置，不属于全局偏好。

- 新来源默认 true；现存所有来源，包括停用和 removed 记录，事务迁移为 true。
- 当前实际 schema 为 v10，设计以现有迁移代码为准，不能沿用 AGENTS 历史 v3 记录。增加 `source.skip_live_photo_videos INTEGER NOT NULL DEFAULT 1 CHECK (skip_live_photo_videos IN (0,1))`，本设计目标 schema v11；代码迁移和 Schema.sql 同步。实施前若基线出现其他迁移，须解决版本冲突并更新规格，不能覆盖其他迁移。
- 停用来源保留偏好；移除后重新添加同一路径恢复原身份及偏好，不强制重置 true。迁移后的默认 true 与后续用户选择分别对待。
- 写入通过 store 串行事务，经 runtime 和 AppModel 暴露；成功持久化后刷新 UI。写入失败保留原值，显示简明错误，系统 detail 留日志/提示。
- 关闭只使该来源、无成功关系、原因精确为本策略的 skipped 项恢复为可重新判定的 pending。不得直接提交：仍执行源属性检查、普通视频判重及现有提交条件。其他 skip 原因和有成功历史的记录不变。
- 开启后，新发现以及尚未提交的 pending / 明确可重试视频均受规则约束。已提交请求照常记账，importing/unknown 不由开关改写。
- 来源停用时可修改此本地选项，不访问来源目录、不启用扫描；真正重新处理须等来源启用且同步恢复。启用来源在未暂停时请求一次现有调度触发，不新增调度器；暂停状态下只保存，继续时生效。

## 4. 识别和运行时准入

视频元数据读取产生明确的“未检查 / 普通视频 / Live Photo 动态部分”结果。旧 metadata 缺少字段必须解码为未检查，不得当成普通视频。新字段应向后兼容旧记录的 JSON；来源 schema 升级后由旧版本拒绝高版本库，禁止依赖旧版本忽略新策略。

认定动态部分的必要条件：非空 ContentIdentifier，且存在可读取的 Live Photo 静态帧时间元数据样本。只检查轨道声明不代替样本读取。初版不根据 UUID 外形、时长、视频尺寸、编码、同名照片或目录名称推断。

| 来源选项 | 识别结果 | 行为 |
| --- | --- | --- |
| 开启 | 完整证据确认动态部分 | skipped，独立原因 livePhotoVideo；不向 Photos 提交 |
| 开启 | 成功读取，证据不足 | 沿用普通视频判重/导入；不凭片面线索排除 |
| 开启 | 未检查或读取失败/超时 | 补检或按既有文件错误/deferred机制等待；不得将失败视作普通视频 |
| 关闭 | 任意可正常读取视频 | 沿用视频流程，不执行本策略的跳过 |

HEIC 无论先到后到均独立处理；已确认动态部分的 MOV 记录为策略性跳过，不持续占 pending，也不要求配套 HEIC 已成功导入。这是“照片未到时 MOV 也不先导入”的实现，不表示照片一定已备份成功。恢复文件的完整 Live Photo 播放能力不在范围内。

实现须覆盖两处：扫描首次登记，以及串行提交队列进入尝试之前。既有未变化文件会跳过扫描解析，因此旧 pending/到期 retry 必须补检。补检只更新匹配同一 file ID、source ID、size/mtime 的未提交记录；元数据更新不得覆盖成功快照、importing/unknown 或外部已变化文件。

本地候选也受资格约束：开启策略来源的旧未检查、无成功且明确未提交的视频，在完成分类前不能成为最终“疑似重复跳过”的依据。先分类该候选再形成结论，分类失败应按既有等待机制延后，不能把未知候选直接排除后冒进导入。确认动态部分后不得继续作为待导入候选；如已有其他无成功跳过项以此行作为证据，则在同一候选失效路径中精确撤销该证据并按普通规则重新评估，覆盖match_evidence和dedup_dependency两类关系，不全库重判。成功历史和importing/unknown保留原有候选保护语义。关闭设置只重开本策略skip的规则不变；这里是开启后撤销失效候选所必需的局部处理。

提交与开关切换须有同一份来源配置版本或等价条件校验：分类结果带源属性及选项版本，写skip和beginAttempt的事务都复核。任意await返回后重新检查暂停、来源状态、属性和选项，过期结果不得覆盖新设置。仅检查beginAttempt不够：视频必须复用现有guarded create的beforeMutation接口，在PhotoKit performChanges闭包内、创建资产请求之前检查线程安全的来源策略版本。

engine是来源策略变更的单一所有者；成功持久化后向同步准入令牌发布新版本，发布完成才向UI确认保存。最终beforeMutation以该令牌的原子检查为准入线性化点：旧版本尚未通过检查时由新值阻断；旧版本已经通过最终检查时视为在途，闭包不再await，继续完成并记账。设置保存后的新准入只可使用新版本。准入令牌只负责来源选项版本及提交许可，复用已有小范围guard机制，不建设通用提交管线；数据库事务不得跨越PhotoKit或媒体读取等待。

调用gateway本身不是不可撤销边界，gateway内部仍有await。若gateway在beforeMutation处明确返回“未发生mutation”，允许对匹配的普通视频attempt使用独立、受约束的明确未提交回退，再按最新设置决定pending或策略skip；不能复用依赖advanced evidence的deferAdvancedAttempt。只有明确未发生mutation的证据允许回退，取消/超时/未知回调均不允许；真正已经开始创建的请求保留结果与成功历史。

复用 ReadExecutor，实际元数据样本读取也在受控物理槽位内，正常完成先释放槽位；busy/timeout/槽位耗尽保留既有 deferred 语义。无需解码视频帧、读取原片全集、增设外部工具或导入 PhotoKit 来判断身份。对标记剥离/不完整的其他备份不承诺完整识别覆盖。

## 5. UI 设计及评审检查点

在现有设置“来源”列表的每条来源下方增加本来源选项；不放到全局“同步选项”，不把控件挤进现有路径/启停/移除按钮同一横行。现有 SourceRowLabel 的两行内部结构保持，新增区域属于外层 sourceRow。

文字线框（结构示意，不是原生截图）：

```text
[文件夹] …/Photos/MobileBackup           [停用] [移除]
         已启用
         ☑ 跳过第三方生成的 Live Photo 预览视频  (?)
```

2026-10-20 用户明确修订：checkbox文案固定为“跳过第三方生成的 Live Photo 预览视频”，右侧为原生问号图标questionmark.circle；删除开关下方常驻说明行。以上线框里的(?)表示问号帮助按钮。Live Photo不是静态照片，不能再把它与照片部分混称。

问号浮层标题“关于此选项”，正文分三段：

“Live Photo 包含照片与动态片段。配套 MOV 通常由 iPhone 拍摄时生成；Synology 等第三方工具可能将它与照片分开备份，有些工具还会另生成预览副本。MOV 并不一定是第三方新生成的文件。”

“勾选后，跳过可识别的 Live Photo 配套动态视频，避免将其导入为独立短视频；照片部分仍按现有同步与判重规则处理。关闭后，此前因此跳过的视频也会重新检查。”

“不会修改源文件或删除已导入内容；普通视频和 Photos 中已有的 Live Photo 不受影响。”

对“第三方生成的预览视频”的产品文案，技术识别范围仍以§4中MOV内部双标志为准；标记被剥离的衍生预览视频不保证可识别，也不扩成扫描第三方全部预览缓存。浮层不得把Live Photo本身称作静态照片，不暗示HEIC中包含全部动态数据，不承诺识别所有预览副本。

复用HoverDetailsButton的原生浮层交互：hover约200ms打开，指针进入浮层可继续阅读，离开按钮和浮层联合区域约200ms关闭；点击或键盘激活固定打开，Escape/点击外部关闭并恢复触发控件焦点。不新增帮助窗口或导航页。

使用原生 checkbox Toggle及灰色问号帮助按钮；开关旁无自定义颜色或徽标。每个控件的VoiceOver名称包含完整来源路径；可通过键盘聚焦和Space切换，问号按钮辅助功能名称“了解 Live Photo 预览视频过滤”，帮助不能仅hover可见。标识符绑定source UUID，避免同名目录混淆。

该来源操作进行中时，该来源开关及启用/停用/移除沿用 changingSources 防重入；持久化期间显示行内“正在保存…”且控件禁用。其他来源仍可操作。demo 禁用真实动作，GUIQA 用临时 store/fake runtime 覆盖实际切换与失败回退。未 ready 时禁用；停用来源不是禁用此偏好设置的理由。成功后使用已持久化值，避免无反馈的长时间显示旧值或失败时假保存。

设置仍宽 600pt、内容不超过 680pt；仅来源列表在常规场景内滚动，通知/登录启动/诊断区域仍可达。增加行高后继续按实际测量分配高度，列表至少容纳一个完整可操作来源卡片，不能让现有44pt最小视口截断本来源选项。长文案或辅助功能字号由现有受限外层滚动兜底，不缩小字体、不裁掉 checkbox 或操作按钮。长路径仍保持原来的省略与完整路径访问。

本轮设计评审须独立检查：来源归属是否清楚，默认开启/停用来源/关闭效果是否表达一致，异步保存与其他操作是否互斥，1/2/30来源及长路径/明暗模式是否可达，统计和错误是否混淆。

实现后必须用最终编译的真实 SourceSettings/子视图和合成来源生成浅/深色、0/1/2/30来源、开关开/关、停用、保存失败、长路径和列表顶/底的图。离屏图不能宣称是真实键盘/VoiceOver或窗口交互；后者用隔离原生测试宿主验证。沿用不启动生产App、不抢焦点/不发送全局按键约束。先独立设计一致性检查，再交用户人工验收；本轮文档评审不替代最终UI验收。

## 6. 统计与日志

维持四状态。新增明确策略 skip reason，不伪装 unsupportedFormat 或 suspectedDuplicate；进入既有 skipped 计数，不计文件失败、来源故障，不发故障通知。不建立新的仪表盘或逐文件管理页。

每个新跳过/重新评估的持久状态转变记录来源、路径、策略原因和版本；重复扫描不重复制造状态转变或持续日志。跳过不是成功历史，不写 success_id，也不成为已成功导入的候选证明。关闭后 pending 增加/已处理比例回退属于重新处理，不是丢失记录。

## 7. 一次性精确清理与数据库回退

这是独立临时维护工具，不加入 App、不形成一般性清库/删除功能，不把精确12条例外推广到其他成功历史。

### 7.1 固定目标和只读预检

原调查固定为 2026-10-20 21:42:22–21:53:31 导入的12个 MOV：

- `MobileBackup/问题不大/`：IMG_7774、7779、7780、7781、7785。
- `MobileBackup/iPhone/2022/09/`：IMG_9869、9873、9884、9894、9900、9901、9902。

不得使用“最新12个”“全部短视频”“按文件名删除”等动态扩大集合。私有清单冻结 file ID、source ID、relative path、stamp、success ID、succeeded_at 和清理前整行；存 ignored work，不把真实资产ID/数据库写进Git。

本轮 `work/livephoto-cleanup-20261020/manifest.json` 已只读匹配12条 imported、12个不同success ID、没有其他文件记录共享这些success ID。目标自身的match_evidence/file_fingerprint/advanced_match_evidence/dedup_dependency均为0，指向目标的match_evidence和dedup_dependency均为0，目标asset ID没有photos_representation/photos_index_exclusion/fingerprint_task记录。photos_content_change有1条对应的图库观察事件，它不是导入成功证明，应保留给原有图库协调流程，不伪造或回退图库游标。当前未调用 Photos，尚未验证这些资产此刻可删除；该清单也不是用户数据库的全量备份。

工具默认 dry-run。执行前用正常 PhotoKit 权限读取清单中的精确 ID，核对全部为独立视频资产、原始资源文件名与清单一致、不属于 Live Photo 复合资产，并冻结库上下文/资源身份及可用修改信息。任何少项、权限受限、图库不一致、资产身份变化、数量不是12，均停止写入并输出差异。未授权通过脚本绕过系统提示。

### 7.2 写入顺序与可恢复性

1. 仅在新功能可交付、目标来源选项开启且不会由旧App立即重导的条件下清理；不得在仍会导入这些MOV的旧运行环境中先复位数据库。工具不自行安装或启动App。
2. 要求App已退出，取得与App相同的instance.lock；锁冲突停止，不杀App、不删除锁、不绕过锁。整个维护期间持有同一锁；不跨PhotoKit await持数据库写事务。
3. 用SQLite在线备份API创建唯一、不可覆盖的完整备份，校验可读/完整性；另保存精确12行及依赖证据、前置条件和写入日志。SQL回退只操作这12条，不能用旧全库覆盖他人新数据。
4. 写前重核清单、数据库和Photos预检快照；将阶段意图写到持久日志后，通过一次PhotoKit变更请求删除精确12个资产。采用正常系统删除语义，可进入“最近删除”并按系统规则同步到iCloud；不清空最近删除，不触及HEIC/原始Live Photo/其他资产。
5. 只有收到并持久记录明确成功回调后，才在单个SQLite事务中将对应12个file_record恢复为无成功关系、无提交意图的pending。保留文件/来源身份、源属性与普通metadata；清除success_id、success_metadata_json、succeeded_at、attempt_id、placeholder_id、submitted_at、重试/错误/旧策略重新评估字段，恢复为干净未提交状态。清理仅属于这些记录的成功/尝试缓存和判定证据，更新实际需要的本地候选revision/重新评估游标；不得清空全库或其他成功历史。本工具以7.1中无跨记录依赖的固定清单为前提，写前若出现其他行依赖目标、共享success ID或新增目标Photos索引缓存，停止并报告范围变化；不能为完成清理而自动重开或改写其他文件。这一受限工具不承担通用依赖修复。
6. 事务必须比较清理前身份及关键成功字段，实际影响行数精确为12；验证foreign_key_check/integrity_check及其他行未变证据。完成后仍保持App退出。以后启用新版App扫描时，这些pending再按默认开启策略成为livePhotoVideo跳过，而非再次导入。

Photos与SQLite无共同事务：删除明确失败则数据库不变；回调丢失/崩溃为未知时保持成功历史，禁止根据一次fetch缺失清除。Photos成功且DB回退失败时保存“删除已完成、DB待回退”日志，下次只重放同一SQL阶段，不能再提交删除。不得自动重新导入视频来补偿，备份只能恢复数据库，不能声称恢复了Photos资产。

执行前冻结12行精确前态、预期后态及涉及的revision/证据变更。resume取得相同锁后分三种：12行全为前态且已持久证明删除成功→执行SQL；12行全为预期后态且revision/相关证据匹配→只补完成日志，不再UPDATE/再次bump revision；混合状态或任何其他差异→停止。这覆盖SQL已提交但完成日志尚未写入便崩溃的窗口；执行日志仍必须在删除成功回调后、SQL开始前可靠落盘。不会以Photos暂时fetch不到替代成功日志。

脚本可拆成明确dry-run / apply / resume阶段，但只服务这份12项清单；不得接收任意SQL或模糊Photos搜索作为删除范围。具体临时文件布局及PhotoKit授权宿主沿用当前工程已有的受控工具模式，在实施计划中落实。若实现仍需新增未经本设计覆盖的权限/图库范围或通用基础设施，回报范围差异后再决定。

## 8. 验证与交付关卡

产品最小回归：

- 完整双标记、仅ContentIdentifier、仅静态帧标记、无标记、畸形样本、读取失败/超时；普通1–3秒视频不误判；照片缺失仍拦动态部分。
- 新来源/现存v10来源默认on、停用及重新添加保留偏好、SQLite迁移事务失败保护与旧JSON未检查解码。
- 两来源不同设置互不影响；关闭仅重新排队本策略skip；切换期间旧异步分类/skip/准入失效；暂停/停用/删除与设置更新交错。
- 新发现和升级前pending/到期retry拦截；已提交unknown与成功记录不被改写；重复扫描与重启计数稳定。
- 旧未检查候选先污染普通视频判重、随后被策略排除的交错；只撤销因此失效的两类依赖证据。gateway已经进入但尚未通过最终beforeMutation时切换选项，以及通过最终准入后的成功回调记账。
- 现有bounded读取资源约束与公平性，暂停/取消后底层槽位释放正确，无额外帧解码或原片缓存。
- 真实原生UI保存成功/失败、防连点、键盘可达、各布局状态；统计沿用同一快照。

临时工具：只用UUID临时SQLite和fake Photos测试身份不匹配、共享success ID、锁冲突、备份失败、删除失败、删除未知、删除成功/SQL失败及resume、SQL已提交/完成日志前崩溃的幂等resume、rowcount漂移和其他记录不变。脚本涉及Python时应用python-development-guidelines。自动测试不得调用生产库或个人Photos；真实清理执行单独记账。

相关检查先行；最终完整验收遵循scripts/validate.py。因新增SQLite/元数据读取与资源边界，实施计划显式选择full scale profile；定向元数据系统验证记录本轮样本和平台局限。独立deep review覆盖持久化/并发/清理；tester验证集成结果；UI人工验收单列。若日后发布，仍需最终集成deep review及package-release.sh的确切源码归档验证，等价评审不重复。

本轮写完规格后先自审及独立设计评审，再由用户审阅书面规格。通过后进入writing-plans编写实施计划并选择执行方式；尚未开始产品或维护脚本实现，不执行Photos删除、DB回退、App安装/启动、合并或发布。

## 9. 设计评审记录

2026-10-20由独立deep_reviewer审阅UI、来源持久化/提交竞争和精确清理方案。首轮提出：旧pending候选污染普通视频判重、gateway入口与实际mutation边界混淆、SQL提交后完成日志前崩溃的resume缺口。已在§4、§7.2和验证清单补充，针对新增段落复核通过，三项在规格层面关闭，无剩余高/中问题。来源级UI结构/禁用/保存/列表可达规则可接受；未对尚未实现的原生界面作视觉或交互通过声明。该记录不是代码评审或测试结果。
