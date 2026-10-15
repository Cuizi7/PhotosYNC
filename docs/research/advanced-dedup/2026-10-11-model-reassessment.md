# 真实副本漏判原因与模型重新评估

2026-10-11。研究基线为 `4e3a847`，产品行为基线 `536200e`；本轮未修改产品模型、0.98 阈值、Photos 索引或导入流程。

## 结论

**一例真实同帧副本的主要问题已定位到 Photos 取图尺寸及缩放路径。优先修正输入获取，再评估模型，现有证据不支持直接换成更大的语义模型。** 不能把一例归因外推为另外 18 例均已解释或修复。

这例照片的 Source 与 Photos 原始资源大小、SHA256 和完整文件字节一致。通过同一 ImageIO / 方向 / sRGB / 320×320 预处理解码，张量逐字节一致，官方 SSCD Large 得分为 1.0。PhotoKit 请求的原始版**栅格**与原始编码文件是不同接口；请求尺寸改变时，分数显著改变。

| Photos 输入路径 | 实际进入共同预处理前的尺寸 | 对 Source 的官方 SSCD Large FP32 余弦 |
| --- | --- | ---: |
| 原始编码资源，同一 ImageIO 解码 | 4096×3072，EXIF 方向 6 | 1.000000 |
| PhotoKit original，目标边 320 | 240×320，方向已展平 | 0.914457 |
| PhotoKit original，目标边 640 | 480×640 | 0.982387 |
| PhotoKit original，目标边 1600 | 1200×1600 | 0.996123 |
| PhotoKit original，目标边 4096 | 3072×4096 | 0.997965 |

所有路径最终都生成同样尺寸的 320×320 张量。较大的请求保留了更多图像信息，改变的是进入共同预处理前的栅格及 PhotoKit 内部处理；本试验没有独立隔离某个插值核、锐化、色彩或解码步骤。不要据此断言“只改一个插值算法即可修复”。

同一实际张量的官方 TorchScript CPU FP32 得分 0.914457，与当前 CoreML FP16 得分 0.914595 接近，三份输出与 CoreML 的向量余弦均超过 0.999993。进一步对同一输入核对 CPU/MPS，差异小于百万分之一。方向盲审及几何数组控制也排除了这例的旋转、镜像、坐标翻转解释。

## 8 组模型及预处理对照

本轮冻结 **83 个配对用例**：新发现的 19 个同帧正例、同次盲审中的 31 个不同照片负例，以及用户批准的 active-suite 33 例（14 正、19 负）。没有恢复已移除的信息看板或旋转用例，没有修改人工标签。

使用现有匿名 JPEG 预览和原回归文件，共 142 个图像输入。真实 Photos 预览最长边仅 320，Source 预览最长边到 1600，不能等同实际 HEIC / PhotoKit 原始输入。各模型按自身原生预处理运行；DINOv2 另做全画面 224×224、不中心裁剪控制。

下表使用**每个模型在全部 50 个负例上观察到的共同零误判边界**，报告该边界之上的正例数量。它是同组样本的分离能力诊断，**不是独立校准、选定的新阈值或生产误判率保证**。不能为真实组和原回归组各选一个边界后拼成一个方案。

| 模型 / 输入策略 | 新正例 / 19 | 原正例 / 14 | 负例误判 / 50 | 热推理 P95 |
| --- | ---: | ---: | ---: | ---: |
| SSCD Large，原生全画面 320 | 0 | 14 | 0 | 29.10 ms |
| SSCD ResNet50 mixup，全画面 320 | 3 | 14 | 0 | 16.92 ms |
| DINOv2 Base，原生中心裁剪 | 0 | 13 | 0 | 24.64 ms |
| DINOv2 Base，全画面 224 控制 | 0 | 13 | 0 | 21.77 ms |
| DINOv2 Large，原生中心裁剪 | 0 | 13 | 0 | 55.91 ms |
| DINOv2 Large，全画面 224 控制 | 0 | 12 | 0 | 55.80 ms |
| SigLIP2 Base fixed 224，原生全画面 | 0 | 14 | 0 | 17.32 ms |
| Apple Vision revision 2，原生 scaleFill | 0 | 7 | 0 | 9.86 ms |

这不是“所有模型均完全识别不了真实副本”。例如，在只看 50 个真实配对的组内边界时，SSCD mixup 可分开 19/19，DINOv2 Large 全画面可覆盖 15/19，SigLIP2 为 12/19；加入应保留的编辑、裁剪和连拍回归负例后，就不能维持相同召回及零误判。更高的语义相似分数没有解决产品要求的内容边界。

典型限制：DINOv2 对显著色调编辑或裁剪给出很高余弦；SigLIP2 将不同路面连拍打到约 0.9927；Vision 的共同边界被色调编辑负例限制。SSCD mixup 比 Large 在本次 JPEG 代理筛选上更好，但尚无正确取图下的优势证据，不能直接替换产品。

## 输入路径与性能限制

额外对同一对 JPEG 做了原生 Core 预处理和官方 PIL 预处理控制：Core 张量回放余弦为 0.944729，PIL 为 0.814195。两边无方向错误、均对应 sRGB，但解码、缩放和渲染细节没有逐项隔离。**不同输入路径对这类高门槛任务有明显影响**，不能拿 JPEG 代理筛选分数直接替代产品实际输入分数。

本机已重新核对为 M2 Pro / 32 GiB。PyTorch 表中是 FP32 MPS、batch 1、同步 forward 的 30 次热重复 P95；不含输入传输、输出复制、文件解码、PhotoKit 或 iCloud，不能写成 ANE 或完整导入时间。七组 CPU/MPS 控制通过，所有配对分数已独立复算。

PyTorch 峰值 RSS 约 731–880 MiB，包含 Python/库、加载过程和保存的预处理张量；MPS GPU 内存不能完整计入 RSS。DINOv2 Large 全画面的 MPS driver sampled allocation 约 2.19 GB，是另一种口径，不能与 RSS 简单相加或当成模型常驻内存。Vision 峰值 RSS 约 136.8 MiB，内部预处理及首次模型加载不由公开 API 分开暴露。

已记录的新模型热重复区间没有与原片捕获的保守区间重叠；早期三个过程没有完整 UTC 字段，未补造时间。机器其他活动未锁定，性能数据仅是本轮探索量级。原片捕获前读取过该资产的原始资源，因此这些尺寸对照也不是冷 iCloud 获取速度试验。

## 公开资料与许可

[SSCD 官方说明](https://github.com/facebookresearch/sscd-copy-detection/blob/main/README.md)推荐短边 288 或全画面拉伸 320，不使用常见分类中心裁剪。其 0.75 / 90% precision 示例特指 `sscd_disc_mixup` 在 DISC 的数据，不能迁移为本产品阈值；0.98 并非模型对所有副本应有的分数保证。[原论文](https://openaccess.thecvf.com/content/CVPR2022/papers/Pizzi_A_Self-Supervised_Descriptor_for_Image_Copy_Detection_CVPR_2022_paper.pdf)研究模糊、压缩、色彩等变换下的检测，但不承诺任意取图路径的零漏判。

检查了官方仓库全部公开 issue 历史，并搜索了仓库外公开讨论，未找到与这次 PhotoKit 尺寸导致同帧 0.91 完全对应的已知推理故障。官方 [issue #5](https://github.com/facebookresearch/sscd-copy-detection/issues/5)讨论训练复现及公开/内部实现差异；另一项目的 [SSCD 评分讨论](https://github.com/YuxinWenRick/diffusion_memorization/issues/5)涉及 ground-truth 获取及生成图配对问题，两者都不能当作本次模型 bug 的证据。Exa 搜索受免费额度限制，使用 GitHub 公开检索和网页搜索补查；不把“未找到”视作没有问题的证明。

SSCD 权重的 MIT 许可已获[作者明确说明](https://github.com/facebookresearch/sscd-copy-detection/issues/12#issuecomment-1736328008)。本轮另下载并固定公开 Apache-2.0 模型：

- [DINOv2 Base](https://huggingface.co/facebook/dinov2-base/tree/f9e44c814b77203eaa57a6bdbbd535f21ede1415)，FP32 safetensors 346,345,912 字节。
- [DINOv2 Large](https://huggingface.co/facebook/dinov2-large/tree/47b73eefe95e8d44ec3623f8890bd894b6ea2d6c)，1,217,522,888 字节。
- [SigLIP2 Base fixed 224](https://huggingface.co/google/siglip2-base-patch16-224/tree/75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2)，完整多模态 safetensors 1,500,800,904 字节；仅执行图像分支，文件大小不是图像分支权重大小。

标准 DINOv2 与 Cell-DINO 的专用非商业许可不可混同。本轮未申请 gated 权重或使用非商业模型。SigLIP2 首次探针误用了 NaFlex 的 `Siglip2VisionModel`，在处理任何图片前加载失败；根据固定 checkpoint 的 `model_type=siglip` 改用公开 `SiglipVisionModel` 后成功。未忽略权重 shape mismatch、改权重或删除失败证据。

## 建议的后续边界

1. 保留 SSCD Large 和 0.98，先将 Photos 取图尺寸与模型输入尺寸解耦。640 在这例刚过门槛；1600 留出明显余量，值得作为接下来的实验候选，尚不是已批准产品默认值。
2. 在冻结的 19 组上用实际 Source 指纹与新的 Photos 640 / 1600 表示验证，保留 31 个真实负例及全部 33 个回归用例，再核对读取时间、解码预算和 iCloud 行为。不要只测漏判恢复而忽略误跳过。
3. 取图或预处理语义变更须更新 spec、plan 和 fingerprintVersion，并重新生成相应 Photos 表示；不能将旧 320 指纹与新指纹混用。已有与该变化无关的恢复、SQLite、串行提交及源只读证据可以保留。
4. 如果正确取图后仍有交叠，再评估模型或候选后精细复核。此时应使用一致的高质量实际输入，不能根据本轮低分辨率代理数据拟合复杂规则。

未进行产品修复、索引迁移、真实 Photos 写入、canary、打包、合并或推送。所有私人图片、原始资源、张量、逐例分数、签名/退出记录和失败产物保存在 ignored `work/`，不会进入公开仓库；本文件仅包含聚合研究事实。
