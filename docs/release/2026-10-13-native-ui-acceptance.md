# PhotosYNC 原生 UI 验收记录（2026-10-13）

当前结论：**本轮前端人工验收通过。** 用户于2026-10-13（Asia/Shanghai）在本轮真实截图送验后明确回复“人工验收通过”；批准的是下列代码与已披露限制的送验版本。 首次候选被用户指出三处偏差，原先相关视觉通过结论已撤回；下列记录对应修正后的代码，不能用自动回归代签人工验收。

## 本轮修正及代码边界

行为/测试冻结提交：`d3d117201da38dcb5f8df2c7a00d5dc185b3bbb8`。本轮反馈实现为 `db774de`；`d3d1172` 另修正截图宿主错误标记为 captured 的报告问题。以后仅编辑证据文档和被忽略的审阅产物；产品视图、模型、fixture 的 SHA256 均核对冻结提交。

| 用户标注 | 本轮修改 | 当前证据 |
| --- | --- | --- |
| 四个按钮破坏原型秩序 | 上排两个等宽原生 bordered 按钮；下排纯文字，设置左对齐、退出右对齐，上方横分隔和中央短竖线 | syncing/offline 明暗主体，原生几何与 OCR 回归 |
| 分析文字和 info 位置不对 | 去掉重复小标题；“已分析 42680 / 100000 张”和唯一 info 相邻置于条上，说明在条下，来源显示等待分析 | analyzing 明暗主体；实际 active/key 深色原图已确认主蓝 |
| 浮层截图及本次扫描排版不对 | 本次扫描按标签/值分行对齐；检查86、新增24、阶段、时间及存在时的失败数使用现有字段 | 实际打开的独立原生浮层；异常材质截图未标通过 |
| 目录末级字号不得放大 | 全行相同 caption 字号、正常字重；前缀 secondary、末级 primary，从前省略、完整路径 help | 菜单与设置的长路径/超长末级主体 |

相对 `f467ed49f5c34637437aa936dbe13f8c91ef2b33`，Core、AppModel、SyncRuntime、SyncStatusPresentation、产品入口、Info/版本/entitlements 及 Core 编译成员没有变化。操作、使能、来源身份、统计口径、提交/恢复及后端接口均沿用原实现。审阅宿主使用 UUID 临时存储及合成数据，不启动真实 runtime，不扫描来源，不访问生产 Photos 或数据库。

## 构建、回归与评审

完整入口（全新输出及 DerivedData）：

```bash
python3 scripts/validate.py \
  --output-dir "$PWD/work/validation-native-ui-feedback-1-retry2" \
  --derived-data "$PWD/work/validation-native-ui-feedback-1-retry2-derived"
```

| 项目 | 本轮结果 |
| --- | --- |
| Debug build-for-testing | 成功、exit0 |
| 聚焦回归 | 52项、0失败：20 AppViewTests、24展示契约、8 AppModelTests |
| 完整无过滤 XCTest | 604项、2项显式跳过、0失败，正常结束、97.272秒 |
| Tests/Tools | 96项通过、52.104秒 |
| 模型、资源及回归 | 8项自测、两种执行配置、33案例/42图片、资源及 runtime 检查通过 |
| 四组规模回归 | 100k、150k、200k及200k+100k成功历史；均 budget_pass=true |
| 受控续体竞态 | stamp、advanced-preparation 两组通过 |
| 源码一致性 | 307项清单前后相同，unchanged_after_validation=true |
| 独立评审 | 原完整分支评审覆盖未变区域；本轮规格/质量评审及单项修复复核通过，无范围内遗留阻断 |

`validation.json` status=passed，SHA256：`5d3679efb2a4ae89162192e6dc7bb6ddfc0ea0a5da83ca218a5c18785e2c9485`。源码清单 SHA256：`932f6249ef4f7be9ce7fa3835d494bb29f90e97c194bcd3dc120e3fe104a96b8`。验证前后工作树干净。环境：macOS27.0.1、Xcode27.0（27A266a）、Swift6.4。

两个显式跳过：规模测试由 canonical 子进程覆盖；现有向量 replay 需要显式本地输入，本次未执行。不把后者标为通过。

同一源码 retry1 曾有一项既有 SourceReader 20ms 超时测试失败；精确用例单独执行1项/0失败（28ms），全新 retry2 完整通过。表现支持时序敏感，但根因未确认。原失败日志及单独执行日志保留在 `work/validation-native-ui-feedback-1-retry1/`；没有修改 Core、延长测试超时、过滤测试或跳过门槛。早先因报告修复而中断的构建也保留。

## 真实截图与视觉核对

图册入口：`http://127.0.0.1:8766/`；原型对照：`http://127.0.0.1:8766/comparison/index.html`。

| 产物 | 证据及用途 |
| --- | --- |
| `work/ui-polish/feedback-1-review-d3d1172/` | 17场景×明暗×菜单/设置及设置底部，共70张原生主体 PNG，清单绑定干净 d3d1172 |
| `work/ui-polish/comparison/` | 六组对照，主体按320/600pt显示；保留原图，不变形、不重新着色 |
| `work/ui-polish/feedback-1-sck/` | 实际点击打开后捕获的独立统计 popover，两组行可见、没有原组合图分块断层；非激活材质仅作结构证据 |
| `work/ui-polish/feedback-1-active/` | 用户授权前台补拍的隔离实验；每次独立目录、原始清单与失败均保留，不能把进程exit0当截图合格 |

已逐项核对：操作两列、信息顺序/info位置、两行路径/同字号、同步150/200的蓝/深灰/浅灰60/15/25、完成200/200、未知/过期/未确认状态、单一分析进度、设置0/1/30来源和固定区域。主按钮与底部操作可以用原生控件实现本轮要求。单来源菜单自然高213pt，分析225pt；30来源设置669pt，不照抄原型的空白卡片高度。

本轮送验时已披露的材质差异（用户现已确认人工验收通过）：分析 ProgressView 已在真实激活态确认主蓝；最新浅色浮层已稳定为326×326pt、没有断层，原图仍呈灰色材质。灰色原图只用于如实报告结构与材质差异，未判视觉合格。旧缩小中的弹窗、透明内容位图或拼接断层图不作通过证据。各批只捕获自己核对 PID/windowID 的窗口，不包含个人桌面。

用户已明确授权“允许你临时激活隔离审阅窗口”。授权仅用于合成数据审阅宿主；记录启动前前台应用，结束时仅在宿主仍占前台且原应用仍运行时恢复，否则不抢回焦点。失败请求不重复循环。补拍结果在下方追加，与产品改动及自动验证分开。

### 前台捕获的权限边界

公开 LaunchServices 正常启动时，启动器已有录屏许可，但独立宿主 `CGPreflightScreenCaptureAccess=false`。因此该批次在创建窗口/点击/调用捕获 API 之前停止，未生成 PNG；原前台 QQ 保持不变，启动器和宿主均已确认退出。未弹出许可请求或修改系统权限。该结果不能推断产品外观，更不能宣称材质合格。

移除录屏 API 后的内容位图批次仍未获得 active/key：宿主 running=true、窗口 visible=true，但 active=false/key=false，前台仍为 QQ；未生成 PNG，两进程退出。故录屏许可并非该次激活失败的解释，也不能据此推断产品颜色。

用户随后回复“现在可以手动点击”。用户参与的隔离路径随后取得真实 active/running/key/frontmost 证据。最终宿主28770，手动激活后两景在6.504秒内完成；独立窗口原始捕获通过连续三次稳定几何核对，未改色/裁图/拼接。

### 最新有效激活态证据

原图与完整记录：`work/ui-polish/feedback-1-active/user-guided/`，11项产品/模型/fixture SHA256 均等于 d3d1172；实际运行时仅根线程证据文档有修改。编译快照另外包含本轮自动生成的 `.playwright-mcp` 日志目录，随后已移入 ignored work。旧 `activationRequested=true` 字段来自继承清单，不代表该路径调用 activate；以保存的源码和 active/key/frontmost trace 为准。

| 文件 | 核对结果 |
| --- | --- |
| menu-bitmap-analyzing-dark.png | 640×450px / 320×225pt，42680/100000；原生蓝条像素0/111/255/255，raw同位置颜色一致 |
| menu-raw-analyzing-dark.png | 640×514px，含原生窗口装饰；ownID52221 |
| menu-bitmap-syncing-light.png | 640×426px / 320×213pt，主操作等宽、底部纯文字两列 |
| popup-raw-syncing-light.png | 652×652px / 326×326pt，实际ownID52234，active/key为true；120/30/49/1/0与86/24/阶段/时间齐全、无分块断层 |

原图八张完整保留，原始 PNG 的 SHA/透明度及只读像素核对见 pixel-inspection.json。浅色 raw 浮层内采样136/136/136/255，材质仍灰；不能据此认定产品背景需要改白，也未偷偷重着色或改产品背景。原生 popup 内容位图缺少材质，不能替代 raw 外观图。

结束时宿主仍前台，恢复启动前 Codex10623，请求accepted=true、最终frontmost10623；宿主28770已确认退出。没有新系统权限、全局输入或生产访问；仅本进程info点击。用户视觉验收已明确通过；未独立实测的原生交互项目继续按下文记录。

## 原生交互和人工关卡

菜单主体是真实 StatusMenu 内容的原生绘制，不能冒称系统 MenuBarExtra 弹出交互。实际 popover 从原生宿主真正打开，未静态拼接。首次确认框明暗原图和取消观测保留为旧候选历史；本轮未改确认行为。

仍待验证：物理 hover 进入/离开、完整路径系统 tooltip、独立 Space/Return 固定、Escape/外部点击关闭和键盘焦点环；已有 inactive 宿主 Escape 失败保留。仅窗口继续存在不足以证明键盘固定成功，离屏 help 属性不足以证明物理 tooltip。

交付顺序已完成：最终真实截图 → 配对视觉检查/修正 → 用户明确验收 → 记录用户结论。首次拒绝及后续修正均保留为历史，最终“人工验收通过”由用户提供。

### 用户验收结论及快照

- 日期：2026-10-13（Asia/Shanghai）。用户原文：“人工验收通过”。
- 代码/测试与完整自动验证快照：`d3d117201da38dcb5f8df2c7a00d5dc185b3bbb8`；送验时文档HEAD为 `43f53d0`，此后收尾仅修改证据文档。
- 主体截图manifest：`work/ui-polish/feedback-1-review-d3d1172/manifest.json`，SHA256 `49fab16ab05083a16c75f5cb99e87e5ea441f9c25c12e28b430f11f795da41a6`。
- 实际激活态manifest：`work/ui-polish/feedback-1-active/user-guided/active-manifest.json`，SHA256 `d3fac9baf452ac5fbd2abaf0aa7754573e5d17ae3f8c3b9f8fb86af18df58858`。
- 送验配对清单：`work/ui-polish/comparison/pairs.json`，批准前SHA256 `05a837a81e480448fa5a52f9c47735550a572a9f0743f46c9781f2eb2b5a9f74`；批准后只更新状态文字，原PNG保持不变。
- 浅色原始浮层偏灰及其原因未确认、未独立实测的物理/键盘交互，均在送验时明示；用户接受当前送验版本。人工结论不改写捕获机制和未运行项目的技术证据。
- 用户随后明确要求收尾并向本分支来源分支提PR；目标为 `codex/photosync-0.2.0-design`，其本地来源基线为 `f467ed49f5c34637437aa936dbe13f8c91ef2b33`。PR只包含本轮前端变化，不执行合并或发布。

## 已验收的代表原图（PR内可直接查看）

以下文件从已送验原PNG逐字节复制；完整源路径和SHA256见 [provenance.json](assets/2026-10-13-native-ui-acceptance/provenance.json)。未裁图、改色、拼接浮层或更改产品：

- [同步浅色菜单](assets/2026-10-13-native-ui-acceptance/syncing-light-menu.png)
- [真实激活态分析深色菜单](assets/2026-10-13-native-ui-acceptance/analyzing-dark-menu.png)
- [实际打开的浅色统计浮层（已披露捕获材质偏灰）](assets/2026-10-13-native-ui-acceptance/syncing-light-popover.png)
- [30来源浅色设置](assets/2026-10-13-native-ui-acceptance/many-light-settings.png)

## 本轮未执行

没有启动/安装生产 PhotosYNC、访问真实 Photos/来源/生产库、改变图库/系统权限/通知/登录项；没有 macOS13/14 实机验证、打包/发布、Developer ID/公证或合并。构建、自动测试、GUI合成截图、真实 Photos、平台兼容和分发结论分别记录，不能互相替代。

历史 e3e3a3f 的599项测试及首次截图只用于回溯；当前自动验证与主体截图以 d3d1172 及上列最新目录为准。


## PR收尾

2026-10-13 已按用户要求创建 [PR #1](https://github.com/Cuizi7/PhotosYNC/pull/1)：`codex/native-ui-polish` → `codex/photosync-0.2.0-design`。来源基线f467ed4与远端PR base完全一致；PR创建前最终深度集成评审通过，无Critical/Important遗留。产品/测试仍等于完整验证的d3d1172；之后只记录验收与PR证据，未重新改变行为。

已推送来源基线和前端分支、保留PR工作树、归档本计划的局部工作证据。未合并或发布应用。
