# 高级照片判重：当前用例范围与冻结底本

## 当前范围（2026-10-04）

用户要求暂时移除信息看板用例。`active-suite.json` 记录本次范围修订、父文件校验值和完整保留/排除 ID；当前为 **33 个用例、42 张图片、8 个活动 split_group**（图片共 15,166,227 字节），内容预期 **14 判重 / 19 判不重**，动作 **11 跳过 / 22 导入**。

停用的是 10 个数值变化和 1 个状态变化用例：`N031 N032 N033 N035 N037 N039 N041 N043 N045 N047 N049`。剩余用例的图片、方向、预期与原人工审批均不变。这是用户在查看结果后的范围调整，不是把反例改成正例，也不是一次新的模型通过记录。

`manifest.json`、`expected-results.json`、`human-review.json` 和全部 63 张 v1 图片继续原样保留，以便复核旧研究；被停用的图片也不得改作独立校准或封存样本。当前用例须以 `active-suite.json` 的保留 ID 从冻结底本取出；底本自身仍完整校验 44 例。当前审阅页展示 33 例。旧研究 `evaluate` / `accept` 入口尚未支持修订后的范围绑定，必须明确拒绝新研究，不能把旧 44 例协议当成新 33 例验收。

复用和后续研究安排见 [范围修订评估](../../../docs/research/advanced-dedup/2026-10-04-scope-reassessment.md)。

## v1 历史冻结记录

冻结版本 **2026-10-02-v1**，44 个已批准用例、63 张图片，共 15,671,932 字节。用户最终审阅已全部完成。本集保存日常回归输入和预期，尚未运行判重模型，不代表准确率、阈值或十万图库性能已通过验收。

## 回归读取契约

- `expected-results.json` 是最终预期的唯一入口：每例明确 `content_result`（duplicate/not_duplicate）、`relation` 和 `action`（skip/import）。
- `manifest.json` 是被审阅的固定内容清单，保留 review-7 版本和内容哈希。其 `proposed`、历史 `pending/expected=null` 是审阅前记录，不再用作回归真值。
- `human-review.json` 保存用户最终导出的原字节。最终标签绑定这份文件的 SHA256、manifest 内容 SHA256，并另有自身内容哈希。
- `contributions.json` 保留用户新增三组用例的来源与最初明确指令，不替代最终全量预期文件。

先运行完整性和审批校验，再由后续判重测试读取上述输入。不要从 P/N/B 前缀、group 或导入动作猜测内容标签；query/candidate 有方向，高清升级尤其不能随意反转。

```sh
python3 scripts/dedup-fixtures/validate.py --require-approved
python3 scripts/dedup-fixtures/test_validation.py
```

校验覆盖图片 SHA256、文件大小、尺寸、JPEG/PNG 元数据、固定虚构 EXIF 及 Display P3 配置白名单、文件引用、精确审批身份、44 项完整性、最终标签与原始导出一致性。它不运行 SSCD，也不等于产品验收。

## v1 历史覆盖与预期

| 类型 | 例数 | 内容预期 | 动作 |
| --- | ---: | --- | --- |
| 改名 1、metadata 1、JPEG 重压缩 3、半尺寸 3、PNG 3 | 11 | 判重 | 跳过 |
| 高清来源对图库小图：B002/B006/B020 | 3 | 判重 | 导入 |
| 明显裁剪 4、明显调色 3 | 7 | 判不重 | 导入 |
| 真实相似照片 9、数值变化面板 10、状态变化面板 1 | 20 | 判不重 | 导入 |
| N051 景深/虚化、N052 色调/明暗、N053 相近街景 | 3 | 判不重 | 导入 |

合计 **14 判重、30 判不重；11 跳过、33 导入**。同图不总等于跳过：高清版本必须保留。不同照片、明显编辑版本和关键文字变化不因整体相似而跳过；这些预期绑定具体样本，不泛化成“任意细微差异都不重”。

旋转 90° 的 B015/B017/B019 暂时移出，判重语义待后续能力评估，不以旧审批固化该规则。N025 因差异过大已删除。其余冗余压缩/缩小/状态变体按人工反馈精简，编号不重排、不复用。

活动用例分为 9 个 split_group；36 条来源记录中 34 条有活动图片，历史来源额外保留一个退役组。来源数、图片数、同源变体数都不是独立样本数。本集不作为阈值校准集或封存测试集，也不证明十万图库误判率。真实场景覆盖有限；未来不能通过反改已批准标签来让模型测试通过。

## 浏览当前用例

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory Tests/Fixtures/AdvancedDedup
```

访问 `http://127.0.0.1:8765/review.html`。页面依据 active suite 展示当前 33 项，标签来自冻结底本；可筛选、展开看图，不再修改预期。当前子集隐藏旧的全量审批导出，避免把 33 项导出误当成 v1 的完整 44 项批准。原浏览器 localStorage 保留且不会被覆盖；冻结结果以最终导出为准，不受旧草稿状态影响。页面不上传，来源链接只有点击才打开外部网站。

## 来源、许可与隐私

Commons 素材和自制信息面板的许可见 `LICENSES.md`、`LICENSE_REVIEW.md`、`sources.json`、`license-evidence.json`。来源记录保留作者、文件页、许可证据、固定 revision 和原始哈希；素材许可独立于产品源码。

未访问个人 Photos。既有 Commons 基准最长边不超过 1280，解码后重新编码清理 EXIF/XMP/IPTC/ICC/注释；退役 cc-09 来源的裁剪证据仍保留，但相应图片已移出。唯一 metadata 用例只含四个固定虚构字段。

用户附件不缩放、不重压缩，仅在副本上用 `exiftool -all= -tagsFromFile @ -ICC_Profile` 去除照片元数据，保留两种已核验的标准 Apple Display P3 配置。六图尺寸、解码像素、JPEG 扫描数据和已有色彩配置不变。源文件未修改。

N051–N053 的六张照片目前获准用于本地测试，独立公开再分发许可尚未指定；不标作 CC0，也不从标签批准推导作者权属。公开 GitHub 前须补齐贡献许可，本次固化没有上传。视觉预审未见可辨认人脸、可靠可读完整车牌或私人文字；街景/建筑仍有场景位置线索，室内照片仍展示陈列，未做地理定位。

## 复现与版本维护

日常回归直接使用固定图片，不联网、不下载图库。构造工具需要 Python 3.10+、Pillow 12.3.0；JPEG 编码器差异可能改变字节。

```sh
# 可选重建：需已有且经核对的 Commons 原图缓存，不会隐式联网。
python3 scripts/dedup-fixtures/build.py build --output work/dedup-fixtures-rebuilt
python3 scripts/dedup-fixtures/validate.py --dataset work/dedup-fixtures-rebuilt --require-approved
```

原图缓存位于 ignored 的 `work/dedup-fixtures-originals/`，不随素材发布。全新环境需要显式 `fetch` 准备公共原图后才能重新生成；用户附件直接复制本目录固定的清理后 JPEG，不读取 Downloads。重建内容哈希必须与审批绑定一致，才可复制冻结标签及审批证据。

本次固化入口为 `build.py freeze --reviews <最终导出文件>`；它拒绝错版本、缺项、重复 ID、未批准项、不一致标签及覆写已有冻结文件。未来变更须创建新冻结版本，重新绑定审批和校验值，不能改写 v1 的真值。`review-migration.json` 只保留审阅前版本及重建所需的历史记录，不参与当前只读页的最终预期选择。

未把素材加入 App 资源或产品发行包，尚未接入判重算法或变更现有产品 CI 门槛。产品行为和阈值验收见 0.2.0 spec 第 7 节。
