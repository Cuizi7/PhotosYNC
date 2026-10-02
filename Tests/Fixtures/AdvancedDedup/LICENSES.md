# 图片许可与来源

本文件仅针对本目录测试素材；不为 PhotosYNC 产品源码重新指定许可证。

## Wikimedia Commons 照片

逐张来源及作者见 `sources.json` 和 `manifest.json` 的 `sources`。
本批次只接纳文件页面明确标记 CC0 或 Public domain 的素材；下载前读取官方 Commons
`imageinfo.extmetadata` 并保留来源声明，原始下载 SHA1 与官方响应核对。

- **CC0-1.0**：https://creativecommons.org/publicdomain/zero/1.0/
  完整法律文本：https://creativecommons.org/publicdomain/zero/1.0/legalcode
- **Public domain**：每张文件页面记录的公开领域依据才是具体来源，包括作者自行放弃权利
  或政府作品声明；不能把网站上所有图片一概视为公有领域。

四张 `cc-05` / `cc-06` 鸟图的 Commons 当前版本使用 `PD-USGov-FWS`，同时其历史
Flickr 审核记录写有 CC-BY-2.0。为保留该条来源链的署名条件，本集明确署名
**Amanda Boyd / U.S. Fish and Wildlife Service, Northeast Region**，保留每张文件页和
[CC-BY-2.0 许可链接](https://creativecommons.org/licenses/by/2.0/)，并在 manifest 中逐图注明修改。
这四张不能写成上传者的 `PD-self` 放弃权利；见 `license-evidence.json` 中的确切 revision 与模板。

本项目对上述照片只做元数据剥离、完整画面缩小和记录在 manifest 中的测试变换。
保留来源和作者是便于审计，即使某项许可不强制要求署名。
不得以本说明暗示照片作者认可 PhotosYNC；本说明不覆盖可识别人脸或其他独立权利问题。

## 自制虚构信息面板

`synthetic-01` 至 `synthetic-10` 及其变体为本测试集制作的原创虚构图形，
不含真实账号、地址、工作内容或真实截图。贡献者将这些图形在法律允许的范围内以
**CC0 1.0 Universal** 贡献，适用上述 CC0 声明及法律文本。

图片中的数字、日期、状态和 metadata 均为测试数据。构造脚本和审阅页面属于项目工具，
本图形声明不自动为其他项目代码授予许可。

## 用户附件 N051–N053

六张用户提供的照片记录于 `contributions.json`，随 manifest 保留来源和原文件哈希。用户明确授权加入当前测试集，并指定“判不重”；这不是 CC0 声明，也不能据此编造作者身份或独立再分发许可证。

当前标记为 `local_testing_only`，新增图片的公开分发许可尚未补全，不适用上文 Commons 与合成面板的许可。没有上传或发布这些图片。公开发布前须明确这些附件的贡献许可。

处理仅剥离照片元数据，保留已核验的 Apple Display P3 ICC 配置及其版权通知；无缩放、重编码或内容编辑。许可及隐私复核见 `LICENSE_REVIEW.md`。

## 发布条件

44 项内容标签已于 2026-10-02 完成人工审阅并固化，没有上传到 GitHub。六张用户附件的公开再分发许可仍待补全；具备相应素材许可后，
分发固定图片时一并保留本文件、来源清单和 manifest；更换任何素材须重新核验来源及许可。
