# 用户附件的公开仓库测试用途记录（2026-10-14）

本记录补充 N051–N053 六张附件的公开使用范围，适用于下表中的确切清理后文件。

## 直接用户指令

用户在建立测试集时明确：“这个用例集后续会被上传到 github 上，作为日常测试的一部分。”随后本人提供三组共六张附件，要求“新增三组用例，都判不重”，并要求固化最终测试集。2026-10-14，用户明确要求将包含该测试集的当前分支“提个 pr 到 main”。

结合这些直接指令，本次获准将下列文件作为 PhotosYNC 测试素材保存到公开的 `Cuizi7/PhotosYNC` 仓库，用于该项目的回归测试和用例审阅。授权针对这些已清理、已审阅的副本；原附件、其他个人照片和私有真实图库 QA 资料不在此记录范围中。

## 文件绑定

| 文件 | 清理后文件 SHA256 |
| --- | --- |
| `images/user-01-1.jpg` | `ba204289b0231cbfd163b26499dd976dffdcbbd73ef56f17cf16b47e05f9f477` |
| `images/user-01-2.jpg` | `8fb5449ed4e1a8a4f416c8456662d4ca158b571909f28440c90576656d77808d` |
| `images/user-02-1.jpg` | `cc67f0722c6e407bf8adde1c7aca37e745769f21682c36b6ef78510c927365cb` |
| `images/user-02-2.jpg` | `f8edc6bede8172ed2b5238350d327648555aca3147512533f69ffeb6ba843aef` |
| `images/user-03-1.jpg` | `4db9665cf9212049c069f45ba0fc85442469a1e677190a40f5fcde4409a6736c` |
| `images/user-03-2.jpg` | `b42d46e083aafdce60600aa42f533bbd40ac52c147c702367b4f083d97a7b7eb` |

图片只做已记录的 metadata 清理，保留核验过的色彩配置和版权通知。来源、变换、原始哈希、隐私检查及冻结标签继续由 `contributions.json`、`manifest.json`、`LICENSE_REVIEW.md` 和 `expected-results.json` 记录。

## 与冻结记录的关系

`contributions.json` 和 manifest 中的 `local_testing_only`、`redistribution license unspecified` 保留当时的采集记录及审阅对象身份。它们不是用户随后禁止公开的指令；当前公开仓库测试用途按本补充记录执行。图片字节、冻结真值和模型验收身份保持原绑定。

本记录没有指定 CC0、改写作者身份、声称已独立证明权属，或新增通用再分发许可证。Commons 素材、原创合成图形及 ICC 的既有许可和通知仍分别适用。公开仓库测试用途与通用素材授权应分别解读。

既有 `CI=true` 拒绝策略尚未调整；本次 PR 不把本地完整回归描述为已配置公共 CI。是否扩展 CI 或素材使用范围属于后续工作。
