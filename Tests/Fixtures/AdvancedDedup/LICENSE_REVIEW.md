# 高级判重素材：许可与隐私预审报告

初审日期：2026-09-29；子集复核日期：2026-10-02
审阅者：独立 reviewer（`review_dedup_design`）
变更类别：测试素材及来源记录；未涉及产品实现。
结论：**原有公开来源素材的许可结论继续有效；新增六张用户附件仅限本次本地测试，未取得独立公开再分发许可。当前授权范围内的来源记录、元数据清理和隐私预审无阻断项。用户无需另行复核许可网页。**

## 绑定范围与结论边界

- 数据集：`photosync-advanced-dedup-v1`，版本 `2026-10-02-review-7`。
- `manifest.content_sha256`：`6c4854844ce958fa5514cb4ccb7e2ccbafd8750b05e5279ca2720bc74691d8a1`。
- 范围：保留 20 个外部公开照片来源、10 个原创合成面板家族及新增 6 个用户附件来源，共 36 条；当前活动来源 34 个。共 63 张图片、44 个案例（11 正例、23 负例、10 边界例）；`cc-09-1`、`cc-09-2` 仅保留历史来源记录。
- 本报告确认来源、已记录许可依据、署名与改动说明、文件对应关系，并汇总独立视觉和元数据隐私预审。
- **批准来源明确分离**：用户于 2026-10-02 明确要求“新增三组用例，都判不重”，因此 `N051/N052/N053` 已记录为用户批准；其余 41 个案例的 manifest 初始字段仍为 pending/null，实际进度以用户导出及浏览器为准。本 reviewer 不代为批准内容，不确认模型精度或阈值，也不代表已经上传。
- 本报告与 `LICENSES.md`、`sources.json`、`license-evidence.json`、`contributions.json`、`manifest.json` 一同保留。更换图片、来源、许可或变换后须重新核对，不能把本报告直接用于另一内容哈希。仅改变审阅页面控件不改变本报告绑定的素材。

## review-7 用户附件加入与使用边界

本次仅增加 `N051/N052/N053` 及六张附件，原 41 条 case、57 条 image 和 30 条来源记录整条不变。直接前版为 `2026-10-02-review-6`，内容哈希 `076891577cf031db1942f3eacb8fbcc0a562bcb229966def6026366abdf9d117`；原 manifest 位于 `work/dedup-additions-v7/previous-manifest.json`。v6 主迁移仅覆盖原有 41 条未改变病例，新增三项不冒用历史审批。

- `N051`：虚化与景深编辑，`derived_photo + import`。
- `N052`：色调与明暗编辑，`derived_photo + import`。
- `N053`：相近时刻街景，`different_photo + import`。

三项 `expected.content_result` 均为 `not_duplicate`，`review_status=approved`，且保存 `basis=explicit_user_message`、日期 `2026-10-02` 和原指令。新页面从明确 expected 初始化这三项批准，其余仍遵循已有进度；后续用户修改仍应形成其自己的审批状态。

六个来源均如实记录为 `User-provided; redistribution license unspecified`、`distribution_status=local_testing_only`，作者身份未独立确认。本次用户提供文件并要求加入测试，足以限定用于此次本地测试；这不将文件改标为 CC0，也不授权把它们连同完整数据集推送到公开仓库、公开托管或随产品分发。本次不执行上述发布动作，无需为本地加入转交用户再次进行版权网页审阅。

### 新增文件逐项绑定

所有原片读取仅针对用户提供的六个具体附件。清理在副本上进行；以下原始及结果 SHA256 本次独立重新核对。来源 ID、相对路径、尺寸、字节数及处理说明保留于 `contributions.json` 和 manifest。

| 来源 ID | 原始 SHA256 | 清理后 SHA256 |
| --- | --- | --- |
| `user-01-1` | `e110cbe20bbef9c2d029d00597dfeac3f908ad81b29044ba86b1593011c0bd06` | `ba204289b0231cbfd163b26499dd976dffdcbbd73ef56f17cf16b47e05f9f477` |
| `user-01-2` | `3154732431b89d5a356c4de3806950d9126b3a358b95585efd037bc9eabec486` | `8fb5449ed4e1a8a4f416c8456662d4ca158b571909f28440c90576656d77808d` |
| `user-02-1` | `722ad4fe26460a231c93f7e070eca9ac5cb629f8b66c94047622704b1ce2ed75` | `cc67f0722c6e407bf8adde1c7aca37e745769f21682c36b6ef78510c927365cb` |
| `user-02-2` | `2314197cc0531302c9dfef3d7265b6e93d3fb7e1180f03bd693fcf4af552429b` | `f8edc6bede8172ed2b5238350d327648555aca3147512533f69ffeb6ba843aef` |
| `user-03-1` | `2bc5d3b9a5d220fffac622ffcec1ced7fd06a9799f2d9d9c21ddb25e48946f3e` | `4db9665cf9212049c069f45ba0fc85442469a1e677190a40f5fcde4409a6736c` |
| `user-03-2` | `b3d5562f97e867e6ac4af8df5f00ee1670542c459aabc0ea8b746ebc70228e67` | `b42d46e083aafdce60600aa42f533bbd40ac52c147c702367b4f083d97a7b7eb` |

### 清理与隐私证据

处理只去除 metadata，并保留图像原有 ICC：ExifTool `-all= -tagsFromFile @ -ICC_Profile`。本次独立重读六组原片/副本，确认尺寸、解码像素、JPEG 扫描数据、ICC 原始字节均未改变；六份最终文件再次由 ExifTool 检查，无 EXIF、GPS、XMP、IPTC 或 Comment。`work/dedup-additions-v7/sanitization-checks.json` 记录了首次处理及原片未修改的证据。

五张图保留 Display P3 ICC、一张无 ICC；保留的两种配置按 SHA256 精确列入白名单，未接受任意用户自定义 profile：

- `20789fdbea9835251a4f0796c8bf45cbd964896044886540da21ffc7457af0ab`：Display P3，内嵌 `Copyright Apple Inc., 2022`。
- `7e1c7ec53e8ea35fed3e169dee62115ac045f26c7bc256fab16a5c26c29eacbd`：Display P3，内嵌 `Copyright Apple Inc., 2015`。

ICC 作为原有颜色说明连同其版权字段原样保留，避免清理导致颜色显示改变；此处不另外宣称获得 Apple profile 的独立再分发许可。它们随新增附件受同一本地测试范围约束。

新增视觉证据来自 `/root/fixture_visual_review` 于本轮实际查看六张原图后的反馈（本 reviewer 未重复视觉检查）：玩偶与建筑图未见可识别人脸、个人文字或牌照；街景远处人物和车辆没有可辨认人脸或可可靠读出的完整号牌。路牌、纪念物和道路布局仍保留场景线索，未进行地理定位。该代理判断清理后适合本地测试，没有必须遮挡的个人标识；这既不保证画面完全无位置线索，也不构成公开传播授权。

**旋转语义仍待定**：先前暂退的 `B015/B017/B019` 不恢复，过去三条批准仍不作为冻结产品规则或阈值验收依据。本次新增编辑类“不判重”批准仅对应用户明确提供的三组案例。

## 原有公开来源素材的许可依据与使用条件

原 12 张外部照片逐图具有 CC0 模板证据，其中 `cc-09-1`、`cc-09-2` 已退役，当前活动图片使用其余 10 个 CC0 来源。CC0 涵盖权利人能够放弃的版权和相关权利，并提供放弃无效时的许可后备，允许复制、修改和再分发；本集继续保留来源以便审计。另 10 个原创虚构面板由本项目的素材声明采用 CC0，并未借此重新许可产品代码。[CC0 1.0 原文](https://creativecommons.org/publicdomain/zero/1.0/legalcode.en)

4 张野草莓照片的固定 revision 使用 `PD-self`：作者主动释入公有领域，并给出无法释权时的无条件使用后备。作者 Philip Jägenstedt、逐图标题和来源仍保留。[Commons PD-self 模板](https://commons.wikimedia.org/wiki/Template:PD-self)

4 张鸟图的固定 revision 使用 `PD-USGov-FWS`，同时保留 Flickr 审核通过的 `cc-by-2.0` 记录。报告不把美国政府作品的公有领域结论扩写成所有地区均无任何条件；本集同时落实 CC BY 2.0 的署名与通知条件：保留作者、原标题、来源链接、许可链接、原有版权通知，并标明衍生处理，不添加限制素材许可权利的条款或技术措施。CC BY 2.0 允许复制、衍生与再分发；不要求把整个项目改为该许可。[PD-USGov-FWS 模板](https://commons.wikimedia.org/wiki/Template:PD-USGov-FWS)、[CC BY 2.0 原文第 3、4 条](https://creativecommons.org/licenses/by/2.0/legalcode)

以上模板与许可原文于 2026-09-29 首次审阅时通过 agent-reach 的 Jina 网页读取后端核对；逐图事实采用仓库保留的官方文件页 revision 证据，没有把 Commons 网站整体许可当作图片许可。

## 20 张外部来源核对记录（含 2 个退役来源）

下表包含已退役的 `cc-09-1`、`cc-09-2` 历史证据；每行在初审时均核对了：作者、来源页、许可模板、revision，以及原始缓存的官方 SHA1 与 manifest SHA256。完整 SHA1、下载地址和原始尺寸保留在 manifest；下表列出原始文件 SHA256，避免仅凭相同文件名认定来源。

| 来源 | 作者 | 依据 | 固定 revision | 原始 SHA256 |
| --- | --- | --- | --- | --- |
| [cc-01-1](https://commons.wikimedia.org/wiki/File:Fragaria_vesca_close-up_1.jpg) | Philip Jägenstedt | PD-self | [1259394370](https://commons.wikimedia.org/w/index.php?oldid=1259394370) | `d9c1e4223d956f274a4bbddd34e8a0e3ab6e073614e5be32062b19311dae3416` |
| [cc-01-2](https://commons.wikimedia.org/wiki/File:Fragaria_vesca_close-up_2.jpg) | Philip Jägenstedt | PD-self | [1259394374](https://commons.wikimedia.org/w/index.php?oldid=1259394374) | `d07eac708184b3f9bdb032158902faedc3a0c2aeccf6f8e8fb8d0bfc8b4a458c` |
| [cc-02-1](https://commons.wikimedia.org/wiki/File:Fragaria_vesca_close-up_3.jpg) | Philip Jägenstedt | PD-self | [1259394377](https://commons.wikimedia.org/w/index.php?oldid=1259394377) | `a16bc5e7d82a2deab8739dd628060bb0f0a682e385f984212dde68e32b8e0c15` |
| [cc-02-2](https://commons.wikimedia.org/wiki/File:Fragaria_vesca_close-up_4.jpg) | Philip Jägenstedt | PD-self | [1028283722](https://commons.wikimedia.org/w/index.php?oldid=1028283722) | `054200f4f0e6944c8ff6f2ec137924787febda3368b198802908d552394dc8c2` |
| [cc-03-1](https://commons.wikimedia.org/wiki/File:A_mother_cat_of_Meitei_domestic_cat_breed_(Meitei_house_cat_variety)_suckling_her_only_little_newborn_baby_kitten_01.jpg) | Haoreima | CC0 | [1235171670](https://commons.wikimedia.org/w/index.php?oldid=1235171670) | `9ab6582a07069fa12e7e0d149a97178294dd49058f19d4cf5c22d991800f6f29` |
| [cc-03-2](https://commons.wikimedia.org/wiki/File:A_mother_cat_of_Meitei_domestic_cat_breed_(Meitei_house_cat_variety)_suckling_her_only_little_newborn_baby_kitten_02.jpg) | Haoreima | CC0 | [1235171609](https://commons.wikimedia.org/w/index.php?oldid=1235171609) | `e99ad43836bb810b3964b1162906f80dc1b6c72444a46ef16a5f0b7baba5f8d5` |
| [cc-04-1](https://commons.wikimedia.org/wiki/File:A_mother_cat_of_Meitei_domestic_cat_breed_(Meitei_house_cat_variety)_suckling_her_only_little_newborn_baby_kitten_03.jpg) | Haoreima | CC0 | [1235171623](https://commons.wikimedia.org/w/index.php?oldid=1235171623) | `24487fdbba7edcd8c067b7ab90ea351136daac2e169cda8e885095beb42fa4ea` |
| [cc-04-2](https://commons.wikimedia.org/wiki/File:A_mother_cat_of_Meitei_domestic_cat_breed_(Meitei_house_cat_variety)_suckling_her_only_little_newborn_baby_kitten_04.jpg) | Haoreima | CC0 | [1235171633](https://commons.wikimedia.org/w/index.php?oldid=1235171633) | `2fe324a1166ab58c3736e8cf5e2332580d8522e0f4b8e8398dd86cdcc6f6157e` |
| [cc-05-1](https://commons.wikimedia.org/wiki/File:A_least_tern_at_the_Nantucket_National_Wildlife_Refuge,_MA._Credit-_Amanda_Boyd-USFWS_(5974496795).jpg) | Amanda Boyd / U.S. Fish and Wildlife Service, Northeast Region | PD-USGov-FWS + CC BY 2.0 记录 | [1003274225](https://commons.wikimedia.org/w/index.php?oldid=1003274225) | `a96fbcb8c0977e49b8d374a575a5d16d0770d93745b6005a7a35be9f47eb4498` |
| [cc-05-2](https://commons.wikimedia.org/wiki/File:A_least_tern_at_the_Nantucket_National_Wildlife_Refuge,_MA._Credit-_Amanda_Boyd-USFWS_(5974497191).jpg) | Amanda Boyd / U.S. Fish and Wildlife Service, Northeast Region | PD-USGov-FWS + CC BY 2.0 记录 | [969873173](https://commons.wikimedia.org/w/index.php?oldid=969873173) | `79e77f20176b07173104e83a6464f3e5b328d186e7399773b093ce27ba2bec25` |
| [cc-06-1](https://commons.wikimedia.org/wiki/File:A_common_tern_at_the_Nantucket_National_Wildlife_Refuge,_MA._Credit-_Amanda_Boyd-USFWS_(5974497409).jpg) | Amanda Boyd / U.S. Fish and Wildlife Service, Northeast Region | PD-USGov-FWS + CC BY 2.0 记录 | [996421974](https://commons.wikimedia.org/w/index.php?oldid=996421974) | `8451fa90498e70172c36230153af8290555a2d8c9934148e3f02c87753fd9b28` |
| [cc-06-2](https://commons.wikimedia.org/wiki/File:A_roseate_tern_at_the_Nantucket_National_Wildlife_Refuge,_MA._Credit-_Amanda_Boyd-USFWS_(5975057838).jpg) | Amanda Boyd / U.S. Fish and Wildlife Service, Northeast Region | PD-USGov-FWS + CC BY 2.0 记录 | [1003637893](https://commons.wikimedia.org/w/index.php?oldid=1003637893) | `2544965f7a5bbd2ff5a7b38c203d86eaee5e2b25009face4ddbf1ea579b20ccf` |
| [cc-07-1](https://commons.wikimedia.org/wiki/File:2866Close-up_photographs_of_wild_flowers_in_the_Philippines_02.jpg) | Judgefloro | CC0 | [972255541](https://commons.wikimedia.org/w/index.php?oldid=972255541) | `50ce3da72ec7d1bb79cee091f995c4cf34867bd37b0cdca13c0b05c524ef5a69` |
| [cc-07-2](https://commons.wikimedia.org/wiki/File:2866Close-up_photographs_of_wild_flowers_in_the_Philippines_03.jpg) | Judgefloro | CC0 | [972255548](https://commons.wikimedia.org/w/index.php?oldid=972255548) | `87af10fa97d35a6b492d79f4bb25fd4eeb09503cd1228d58a3ee306e067fa78c` |
| [cc-08-1](https://commons.wikimedia.org/wiki/File:2866Close-up_photographs_of_wild_flowers_in_the_Philippines_05.jpg) | Judgefloro | CC0 | [972255562](https://commons.wikimedia.org/w/index.php?oldid=972255562) | `9a189c03a9f027346f5066cf7f7ada6bf7dad8bdb961e07e8544600ea3064561` |
| [cc-08-2](https://commons.wikimedia.org/wiki/File:2866Close-up_photographs_of_wild_flowers_in_the_Philippines_14.jpg) | Judgefloro | CC0 | [972255626](https://commons.wikimedia.org/w/index.php?oldid=972255626) | `c0558d8ef5f50751a0e0285394ecd9e9e5bc3b46219b3e1146927d11a8f07e47` |
| [cc-09-1](https://commons.wikimedia.org/wiki/File:Campbells_Bay_2014-01-18_14-39-06_NZ_Auckland.jpg) | Jan Helebrant | CC0 | [1069884421](https://commons.wikimedia.org/w/index.php?oldid=1069884421) | `77d44cf6731b97d03d3d120a44caefea801436306b0697aa89699cdc51e2fae4` |
| [cc-09-2](https://commons.wikimedia.org/wiki/File:Campbells_Bay_cliffs_2014-01-18_14-53-24_NZ_Auckland.jpg) | Jan Helebrant | CC0 | [1069884452](https://commons.wikimedia.org/w/index.php?oldid=1069884452) | `8a7d962ae21e94a1c8c732be6a96944556c9b08a0a9b974d0bcca1d1bee384eb` |
| [cc-10-1](https://commons.wikimedia.org/wiki/File:Furlong_Gulch.jpg) | Thewellman | CC0 | [1155818068](https://commons.wikimedia.org/w/index.php?oldid=1155818068) | `bc83f9dbe3bc4c4c7357da1d80237fe79781b1c3341fcad300d5a8350b773c1e` |
| [cc-10-2](https://commons.wikimedia.org/wiki/File:Kortum_Trail_viewed_from_Peaked_Hill.jpg) | Thewellman | CC0 | [954463713](https://commons.wikimedia.org/w/index.php?oldid=954463713) | `2c44233019c1cbae008fbb758632215830539f930c6bf873fdd768286e39dc56` |

## 四张鸟图的完整署名及衍生说明

共同署名：**Amanda Boyd / U.S. Fish and Wildlife Service, Northeast Region**。许可记录：[CC BY 2.0](https://creativecommons.org/licenses/by/2.0/)。以下图片及其变体基于所列原作制作，不暗示原作者认可 PhotosYNC。

- `cc-05-1`：[A least tern at the Nantucket National Wildlife Refuge, MA. Credit- Amanda Boyd-USFWS (5974496795).jpg](https://commons.wikimedia.org/wiki/File:A_least_tern_at_the_Nantucket_National_Wildlife_Refuge,_MA._Credit-_Amanda_Boyd-USFWS_(5974496795).jpg)；[原始 Flickr 来源](https://flickr.com/photos/43322816@N08/5974496795)。
- `cc-05-2`：[A least tern at the Nantucket National Wildlife Refuge, MA. Credit- Amanda Boyd-USFWS (5974497191).jpg](https://commons.wikimedia.org/wiki/File:A_least_tern_at_the_Nantucket_National_Wildlife_Refuge,_MA._Credit-_Amanda_Boyd-USFWS_(5974497191).jpg)；[原始 Flickr 来源](https://flickr.com/photos/43322816@N08/5974497191)。
- `cc-06-1`：[A common tern at the Nantucket National Wildlife Refuge, MA. Credit- Amanda Boyd-USFWS (5974497409).jpg](https://commons.wikimedia.org/wiki/File:A_common_tern_at_the_Nantucket_National_Wildlife_Refuge,_MA._Credit-_Amanda_Boyd-USFWS_(5974497409).jpg)；[原始 Flickr 来源](https://flickr.com/photos/43322816@N08/5974497409)。
- `cc-06-2`：[A roseate tern at the Nantucket National Wildlife Refuge, MA. Credit- Amanda Boyd-USFWS (5975057838).jpg](https://commons.wikimedia.org/wiki/File:A_roseate_tern_at_the_Nantucket_National_Wildlife_Refuge,_MA._Credit-_Amanda_Boyd-USFWS_(5975057838).jpg)；[原始 Flickr 来源](https://flickr.com/photos/43322816@N08/5975057838)。

原始文件 `cc-06-2.original` 中存在 IPTC `CopyrightNotice`，首次审阅时用 ExifTool 读取并在此原样保留：**Boyd Amanda, U.S. Fish and Wildlife Service**。其余三张鸟图没有在首次审阅查询的作者、版权、权利及使用条件字段中返回额外通知。剥离嵌入 metadata 不撤销此处保留的版权与来源说明；分发这四张的变体时须一同提供本报告及素材许可文件。

四张鸟图均经过方向处理、复制到新 RGB 图像、剥离原 metadata、以最长边不超过 1280 的基准重新编码 JPEG；原尺寸低于上限时不放大。`cc-05-1` 与 `cc-06-1` 在本版各仅保留基准和降饱和度变体；`cc-05-2` 与 `cc-06-2` 各仅保留基准。四张来源的正例重压缩、正例半尺寸、PNG、改名与虚构 EXIF，以及负例重压缩（quality 55）/半尺寸变体均已删除。逐张路径、处理参数和结果 SHA256 均在 manifest 的 `images` 条目中。

## 其他变换与隐私预审

外部照片的基准处理及测试变体均可从原始来源追溯。除基准缩放与 metadata 清理外，当前测试包含重压缩、缩小、PNG、裁剪和降饱和度，旋转变体已全部暂退；改名和虚构 EXIF 用例保留原基准码流或像素。变体沿用相应来源的许可依据，不把外部照片改标为项目原创。

特别记录：`cc-09-1` 与 `cc-09-2` 的历史基准曾为移除可见人物做额外裁剪，分别采用原方向像素框 `[3150,1230,3370,1490]` 和 `[1900,1450,3500,2550]`。因此这些基准不是完整原始画面；其他章节的通用“完整画面缩小”描述不应覆盖这两项明确例外。该裁剪及后续变换有既存 manifest 记录，CC0 允许衍生处理。review-5 已移出 `cc-09-2` 的全部图片，review-6 进一步移出 `cc-09-1` 的全部图片；此段仅为历史追溯。

隐私结论采用以下已完成的独立检查，未要求用户重新承担许可或隐私勾选：

- 照片视觉预审 `work/dedup-fixtures-visual-review/formal-review.json` 绑定该报告记录的 review-1 manifest 哈希；其结论通过本次未改字节子集核对续用。原覆盖 10 张联系表、80 个照片视图及全部边界案例。报告确认正式 cc09 裁剪中没有可见人物或身份文本；cc08-1 的手指已明确记录且不具可识别身份信息。改名和 metadata 变体的等价关系另有程序检查。
- 合成预审 `work/dedup-fixtures-synthetic-review/visual-review.json` 原覆盖 10 个家族的全部 30 张图，本版保留其中 21 张未改字节图片，未发现真实个人或地址信息，虚构数据提示可见。该报告没有单独的 manifest 哈希；原视觉审阅者已重新查看正式 PNG，将 06/09/10 的数值转录纠正为 2.90/850/6.5，并记录纠正原因。复核确认这些仍是不同内容的虚构数值变体，不影响许可或隐私结论。本次采用其图像覆盖、虚构数据标记及无个人信息的结论，不把它解释成用户内容批准。
- 独立 ExifTool 报告 `work/dedup-fixtures-final-validation/report.md` 原覆盖 review-1 的 130 张图：无嵌入 GPS、XMP、IPTC 或 Comment，当时 10 张 metadata 用例含四个固定虚构 EXIF 字段。本版删除其中 9 张，当前仅 1 张保留固定虚构 EXIF，原有其余 56 张无 EXIF；原 57 图字节完全未改，清理结论据此续用。新增 6 图的 EXIF 均为空，ICC 保留例外及独立检查见上文。

在当前本地测试范围内未发现需要用户进一步处理的隐私阻断；新增街景仍有场景线索，不能称为完全匿名素材。上述结论限于本次固定图片及记录的检查范围；它不认证模型准确率、真实 Photos 行为或任意将来的替换图片。

## 本次核验记录

首次许可审阅的旧来源结论保持。本次聚焦核对：原 41 个案例、57 张图片、30 条来源整条未改；新增 3 项明确用户批准和 6 个本地使用来源与 contributions 完全对应；六个原始哈希和六个最终哈希、尺寸、解码像素、JPEG 扫描、ICC 一致；六张最终文件的 ExifTool 隐私字段为空；当前 63 图实际 SHA256、规范化 manifest 哈希及 v6 主迁移 41 项指纹均匹配。Python/JS 的新增审批初始化与校验仅在本轮范围内审阅，浏览器交互由 tester 单独验证。本 reviewer 仅修改本报告，没有改动 manifest、图片或浏览器进度。

修复复核：新增批准的校验已同时要求明确用户指令、`basis=explicit_user_message` 和日期 `2026-10-02`；错误 basis 或空日期有拒绝用例。`--require-approved` 的错误文案已改为其余案例尚未完成整体批准，不再否认这三项已批准的事实。主线程回报六项工具测试和 44/63 完整性校验通过；tester 回报 UI 为 44 项、36 已批准、8 待审阅，旧 33 项批准保留，新三项均不重并导入，导出 44 项，无 JavaScript/HTTP 错误。本 reviewer 已只读复核相应校验与测试代码，未重复执行这些测试。

本次参考证据的文件 SHA256（`work/` 报告仅为本机证据，其关键结论已写入本文）：

- `Tests/Fixtures/AdvancedDedup/sources.json`：`264a654313a37ce0f3c264f3dcc0d23ea6fe89cb72710b6fd2d6c5c51f51f429`。
- `Tests/Fixtures/AdvancedDedup/license-evidence.json`：`89c076c6c8503e605f685064b07417e42dd87bdb198fb4ac3f0aec8c75991b4e`。
- `Tests/Fixtures/AdvancedDedup/LICENSES.md`：`96312b98802bb17a584d7ba16a8a709a03dba0c16a98cc816cc4e4732359445b`。
- `work/dedup-fixtures-visual-review/formal-review.json`：`bb4a2f2d90f8b77aeba0fe612fc450477e072ab4f3185e43eb3dc3255b91a984`。
- `work/dedup-fixtures-synthetic-review/visual-review.json`：`dcee45a809e8f4683fa5c26d9cfce9389c3fa1756094c334840115da3a6122ee`。

- `Tests/Fixtures/AdvancedDedup/contributions.json`：`ef734fc96566b6badd026b772329fd03bacb409a982f606998ea78a3397b8a8f`。
- `work/dedup-additions-v7/sanitization-checks.json`：`16721b58c4f21f518d64b815cc6fcf6c51d109587240599527945346044ebf65`。

## 最终结论

- 原公开来源素材：既有许可与隐私结论沿用，版权通知不变。
- 新增六张附件：本地测试范围内通过；独立公开再分发许可未指定，不能将整套当前素材宣称为公开许可通过。
- 当前记录：36 个来源、34 个活动来源、63 张图片、44 个案例；其中新增 3 项内容批准来自明确用户指令。
- 隐私：已清理 metadata，保留固定 Display P3 ICC；街景场景线索仍可见，未定位。
- 本次未上传、公开托管或发布。内容批准、许可范围与发布授权分别记录，互不替代。

## 2026-10-02 全量标签固化补记

本节更新前文的内容审批进度，未重新裁定图片许可。用户最终导出已将 44 个当前案例全部批准；图片、用户附件许可范围和原审阅 manifest 均未改变。冻结版本为 **`2026-10-02-v1`**，标签的权威入口为 `expected-results.json`，原始导出按原字节保存为 `human-review.json`。

| 身份 | 绑定值 |
| --- | --- |
| 素材 manifest 版本 | `2026-10-02-review-7` |
| 素材 `manifest.content_sha256` | `6c4854844ce958fa5514cb4ccb7e2ccbafd8750b05e5279ca2720bc74691d8a1` |
| 冻结标签 `expected-results.content_sha256` | `cf2f44b72427bb87a5c89ca0a106bff2a0ed2a43f470702dff494502c486ba95` |
| 原始导出 `human-review.json` 文件 SHA256 | `5db705debe0ca4c139f5d89c4e360456553d2bd8155105637349d749095177a7` |

本次独立核对原始导出字节哈希、冻结标签的规范化内容哈希、manifest 身份、44 项全量批准、病例引用及派生标签一致性。冻结结果为 14 项内容重复、30 项内容不重复；最终动作分别为 11 项跳过、33 项导入，其中 3 项“同图但保留高清版本”仍导入。旋转案例 `B015/B017/B019` 不在冻结集合中，旋转语义继续待定。

manifest 中原有 41 项 pending/null 是当时被用户审阅的提案快照，不再代表当前审批进度；保留这些字段和原哈希是为了绑定真实审阅对象，不能直接拿它们覆盖权威冻结标签。后续回归读取冻结标签并核验其与原导出的对应关系。只读页面优先展示冻结结果，保留旧浏览器进度，不以旧 localStorage 覆盖已接收的全量导出。

代码聚焦复核覆盖全量审批、精确身份、病例引用、标签一致性、冻结文件禁止覆盖、重建同内容校验和只读展示。未重复前轮图片、隐私或许可调查；本节也不将 44 项人工批准描述为模型测试已通过或发行阈值已成立。

**标签固化不等于公开分发许可。** 六张用户附件仍为 `local_testing_only`，独立公开再分发许可仍未指定。原公开来源的署名、版权通知及许可说明继续有效；本次没有上传、公开托管或产品发布。整套当前素材不能因标签全部获批而被认定为可公开分发。
