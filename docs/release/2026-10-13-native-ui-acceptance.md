# PhotosYNC 原生 UI 验收记录（2026-10-13）

当前结论：**首次前端人工验收未通过，正在修正**。用户指出底部按钮列秩序、分析文字/info 位置、统计浮层截图及“本次扫描”排版偏差；这些区域的“视觉对照完成”结论撤回。下文自动验证和图片仅对应旧 e3e3a3f 候选，不能证明本轮修正通过。菜单、设置与 demo 的路径统一 caption 字号/字重、仅颜色区分的要求继续保留。修正后重做真实截图、视觉核对和完整自动验证，仍需用户明确验收。

## 确切快照与最新证据

最终行为、测试和截图快照：**e3e3a3f19c9b8e89f5795287bb5f9fcd2c1e2acc**。此后只更新本文和实施计划的证据记录，不改变验证过的代码或测试。每个 source.json / manifest 保存 HEAD、dirty status/diff、编译 Swift 文件 SHA256、同次 Debug Core/Info.plist 校验值和 OS/Xcode/Swift。两份最终捕获清单均为该提交、sourceStatus 为空。

| 产物 | 内容 |
| --- | --- |
| work/ui-polish/index.html | 图册入口，对应 http://127.0.0.1:8766/ |
| work/ui-polish/review-e3e3a3f-final/index.html / manifest.json | 70张真实主体PNG：17场景×浅/深×菜单/设置=68，另many设置底部2张 |
| work/ui-polish/probe-e3e3a3f-final-retry1/index.html / probe-manifest.json | 四份实际原生窗口组合截图；仅本进程窗口，浅/深外观仅设置于隔离app/window |
| 同目录 compositor-syncing-light-48175.png / compositor-syncing-dark-48183.png | 真正点击打开的统计popover及父测试宿主；不是独立详情组件拼图 |
| 同目录 compositor-many-light-48186.png / compositor-many-dark-48192.png | 真正打开的移除确认框，只取消、未确认移除 |
| work/ui-polish/comparison/index.html / comparison-{syncing,2,3,settings,5,6}.png | 六组原型与实现配对，保留各场景的差异说明；原始主体按320/600pt显示、不变形、不重新着色 |
| work/validation-native-ui-final-retry1/validation.json / validation-report.md | 完整自动验收exit0，status=passed，源码清单前后相同 |
| work/ui-polish/final-capture-report.md | 最终捕获命令、原图、源码身份与明确缺口 |

独立宿主标识 local.photosync.ui-review；同次构建版本0.2.0 beta / build7。XCTest的Bundle.main属于测试执行环境，不能作为产品版本证据。

旧版review-task3-*、probe-task3-*、d1ea044捕获与首轮probe-e3e3a3f-final均保留为历史证据。首轮e3e3a3f深色确认框捕获失败，没有对应PNG并明确标unverified；同一稳定命令在全新retry1目录重试一次后齐全。不得用旧图代替上表最新版。

## 构建与自动验证

| 项目 | 本轮结果 |
| --- | --- |
| Debug build-for-testing | TEST BUILD SUCCEEDED，exit0；canonical使用全新DerivedData |
| 最后聚焦回归 | 47项、0失败、exit0：15 AppViewTests、24 SyncStatusPresentationTests、8 AppModelTests |
| 完整无过滤XCTest | 599项，2项显式跳过，0失败，exit0，正常结束；97.883秒 |
| Tests/Tools | 96项、0失败、exit0；110.927秒 |
| 模型与资源 | 固定资源SHA通过；两个执行配置共8项model self-test、33-case regression、injected runtime与资源报告通过 |
| 优化规模回归 | 100000、150000、200000条记录，以及200000条+100000成功历史，四组均通过；各1项测试、0失败、budget_pass=true |
| 受控续体竞态 | stamp和advanced-preparation两组均passed；门闩只进入隔离拷贝，不进入产品源码 |
| 源码一致性 | 307项清单前后同SHA：598de9db0a820a51d1665a8268cc986b96e74911a4d8f6edfb1399104fda603c；unchanged_after_validation=true |
| 独立评审 | task评审、完整集成评审和一轮定向修复复核完成；无Critical/Important遗留，两项Minor已在e3e3a3f修复 |
| 人工结论 | 等待用户验收；未验证原生交互不由自动回归代签 |

两项XCTest跳过：testControlledScaleThroughActualGraph由上述canonical子进程另行运行；testExistingVectorReplayUsesSQLiteBackend需要显式本地向量输入，本次未执行该回放。没有将跳过项宣称为已执行。

完整入口：

```bash
python3 scripts/validate.py \
  --output-dir "$PWD/work/validation-native-ui-final-retry1" \
  --derived-data "$PWD/work/validation-native-ui-final-retry1-derived"
```

首轮因模型权重仍为133字节LFS指针在前置资源阶段停止，记录保留于work/validation-native-ui-final/。使用既有hydration脚本从本地LFS对象恢复精确提交权重后，资源校验通过：88,329,408字节，SHA256 be1b28a5be24ca216884b6a04db291f58bd484328ac5307f9577fd27295cb338。未联网、未改变模型字节契约或Core逻辑；Git LFS正常过滤后暂存diff和工作树状态为空，随后才运行全新retry1。

环境：macOS27.0.1、Xcode27.0（27A266a）、Swift6.4。继承的CoreDevice/CoreSimulator、AppIntents、XCTest部署目标诊断和confstr临时目录fallback均保留在日志；不称输出pristine，不作为新前端源码故障。

## 主体视觉对照

| 场景 | 观察与结果 |
| --- | --- |
| 同步中120/30/49/1/0 | 150/200，蓝/深灰/浅灰60/15/25，连续6pt轨道；两行来源，底部两排动作固定 |
| 完成170/30/0/0/0 | 200/200，85/15，无假零色段；状态继续由原model决定 |
| 分析已知/未知、iCloud等待 | 仅显示图库前景进度，保留未知总数、等待原因和说明；不叠加同步进度 |
| nil/过期/未确认提交/文件错误 | nil不造零；过期旧值有“统计暂未更新”；importing算未完成；问题与失败数量仍可见 |
| 0/1/30来源设置 | 600pt、短内容收缩、高≤680；many669pt，来源列表滚动而标题、选项和诊断固定 |
| 根/Unicode/长路径/超长末级 | 现有布局用例和最终长末级图覆盖；全行caption/相同字重，前缀secondary、末级primary，从前省略；第二行失败数量保留 |
| 设置文字与动作 | “设置”无省略号，“添加来源目录…”保留；既有actions/Binding/disabled/order/identity不变 |

六组配对图检查了顺序、字体颜色、间距、比例、路径省略和固定区域，没有已知未解决的主体布局规格偏差。原型较大的末级字号已由用户最新要求替代。原生控件字号、按钮固有宽度、单色状态符号、自然窗口高度与示意卡片不同；按已批准原生规格，不拉伸到ImageGen像素。同步单来源图高212pt，设置单来源426pt，many菜单543pt/设置669pt。示例数量和构建版本不照抄原型。

### 操作使能对照（保留原规则）

| 合成场景 | 立即扫描 | 暂停/继续 | 设置/退出 |
| --- | --- | --- | --- |
| 同步/分析进行中 | 禁用 | 暂停同步，可用 | 原入口 |
| 已暂停/正在暂停 | 禁用 | 继续同步，可用 | 原入口 |
| 已完成 | 可用 | 暂停同步，可用 | 原入口 |
| 未授权且有启用来源 | 禁用 | 按原canTogglePause可用 | 原入口 |
| 提交未确认、activeWork=false | 原ready/authorized规则，不新增前端阻断 | 原规则 | 原入口 |
| 无来源、ready/authorized=true | 原规则可用，不新增hasSource条件 | 禁用 | 原入口 |
| demo | 禁用 | 禁用 | 原入口 |

此表仅比较原前端条件，不改变后端实际提交许可。设置来源启用/停用/移除、确认逻辑、授权入口、系统Binding、onAppear刷新与窗口高度回调均保持。系统集成开关在隔离模型中禁用，不代表生产规则变更。

## 实际瞬态证据与明确缺口

本轮真实点击打开了统计popover和移除确认框，两种原生外观均已捕获。确认框Escape取消成功；没有调用destructive action。所有probe记录appActive=false、host key-window=false；只用本进程窗口输入，没有activate、全局按键或新权限请求。

组合图像素：浅popover1272×618、深popover1270×618，浅确认框1200×1402、深确认框600×700。显示器backing scale不同，manifest保存原始像素/逻辑尺寸和本进程窗口bounds；四份图均通过归属及尺寸校验，允许16pt系统组合边缘差，不裁图、不改PNG、不包含个人桌面。

主体使用NSView.cacheDisplay的实际原生绘制；菜单是StatusMenu内容，不能冒称系统MenuBarExtra弹出交互。系统分析ProgressView在非key宿主仍灰色，即使测试环境controlActiveState=.active；产品tint和已导入均使用accentColor，真实激活颜色尚未验证。

popover的cacheDisplay有透明/系统材质限制；**浅色compositor原图也有明显灰色/透明材质边界**。captured仅证明获取和几何检查成功，不证明激活系统材质可接受。确认框近乎空白的view bitmap被拒绝；实际WindowServer图用已有录屏权限和verified-own-window-ID定向取得。

尚未验证：物理hover进入/离开popover、完整路径系统tooltip、独立Space/Return固定、外部点击关闭、真实键盘焦点环与恢复、active窗口材质和真实MenuBarExtra交互。非激活宿主的popover本地Escape未关闭；Space/Return仅观察到已有窗口继续存在，不能当作独立固定成功。公开AX未暴露菜单/来源actionable节点，alert节点可见但Cancel AX press返回false；这些失败事实保留。--interactive提供用户控制会话，不自动激活，不等于已验收。

## 重现、范围与待办

```bash
# 每次使用全新output目录，Debug DerivedData需来自当前源码。
bash Tests/UIReview/run-ui-review.sh \
  --derived-data "$PWD/work/ui-polish-task2-derived" \
  --output-dir "$PWD/work/ui-polish/review-<unique>"

# 有界本进程输入，已有权限才捕获实际窗口。
bash Tests/UIReview/run-ui-review.sh \
  --derived-data "$PWD/work/ui-polish-task2-derived" \
  --output-dir "$PWD/work/ui-polish/probe-<unique>" --probe

# 用户控制的原生会话；不抢前台焦点，窗口ID/PID写manifest。
bash Tests/UIReview/run-ui-review.sh \
  --derived-data "$PWD/work/ui-polish-task2-derived" \
  --output-dir "$PWD/work/ui-polish/interactive-<unique>" \
  --interactive --scenario syncing --appearance light
```

宿主排除PhotoSyncApp.swift，不使用生产App入口。UUID临时SQLite、合成来源描述和injected模型不启动engine/gateway/bootstrap/tick、不遍历来源。正常App未启动；没有真实Photos、来源/网络/原片验收、权限/通知/登录项设置、macOS13/14实机、打包、Developer ID/公证、安装、合并或推送。

冻结Core、AppModel、SyncRuntime、SyncStatusPresentation、PhotoSyncApp、Info.plist相对f467ed基线diff为空，Core目标成员不变。Task1/2视图只加入App和hostless tests，Task3 fixture只加入tests，review host不进入产品资源。只读metrics/局部popover状态、共享路径显示、设置列表布局和对应验证均映射到本次前端目标，没有附带后端修复或API变更。

待办：用户检查本图册并明确给结论；在用户控制前台的隔离host中补上述原生交互/active外观证据。未收到结论时保持待验收，分支codex/native-ui-polish及恢复ledger保留。
