# PhotosYNC 原生 UI 候选证据（2026-10-13）

当前结论：**聚焦自动验证通过，真实截图已刷新，等待用户验收**。末级路径与前缀均为 caption/相同字重，仅 primary/secondary 颜色区别；本轮基于用户修正后的视图。截图仍是候选证据，没有用户结论前不能宣布前端人工验收通过。

## 确切源码与最新证据

产品视图源码为 **`d1ea0449dc61943593429edc224366acad02d094`**（`fix(ui): keep source path typography uniform`）。每个 `source.json` / manifest 保存源码 HEAD、dirty stat/status、编译 Swift 文件 SHA256、同次 Debug Core/Info.plist 校验值、OS/Xcode/Swift。

| 最新产物 | 内容与源码身份 |
| --- | --- |
| `work/ui-polish/review-d1ea044-final/index.html` / `manifest.json` | **70 张**真实主体 PNG；sourceCommit 为上述 d1ea044，生成时 sourceStatus 为空。17 场景 × 浅/深 × 菜单/设置 = 68，另 many 设置底部 2 张 |
| `work/ui-polish/probe-d1ea044-native-appearance/index.html` / `probe-manifest.json` | 最新真实瞬态窗口图册；产品源仍 d1ea044；dirty 仅 Task 3 的 `ReviewHost.swift` / `run-ui-review.sh`，清单记录全部编译文件 hash。校准字号修正后的 212pt menu，给本测试 app/window 设置所选原生外观，不改变系统外观 |
| 同目录 `compositor-syncing-light-47565.png` / `compositor-syncing-dark-47571.png` | 实际点击打开的统计 popover，WindowServer 原图包含其父测试宿主组合；两种原生外观均已核对。浅色原图仍有明显灰色/材质断层，不能据此验收 active 材质 |
| 同目录 `compositor-many-light-47575.png` / `compositor-many-dark-47582.png` | 实际打开的移除确认框；只取消，未确认移除。两种原生外观均已核对 |
| `work/ui-polish/task2-caption-build.log` / `task2-caption-tests.log` | 用户字号修正后的 build-for-testing 与 15 项 AppViewTests 结果；由 Task 2 所有者运行，本轮已读取正常结束/数量/失败数 |

较早 `review-task3-*`、`probe-task3-*` 和首次 `probe-d1ea044-final` 保留为历史候选/失败证据，**不要用它们替代上表最新版**。首次 d1ea044 probe 的 dark 原生外壳尚未跟随测试外观；该测试宿主问题已修正并重新捕获，未修改产品 UI。

独立宿主 ID 是 `local.photosync.ui-review`；同次构建读取版本 **0.2.0 beta / build 7**。XCTest 的 `Bundle.main` 属于 XCTest 执行环境，可能展示测试 metadata/后备版本；不能据此解释产品或独立宿主版本。

## 本轮实际验证

| 项目 | 结果 |
| --- | --- |
| 最新 Debug build-for-testing | `TEST BUILD SUCCEEDED`，exit 0（Task 2 字号修正后的构建） |
| 最新 AppViewTests | **15 项、0 失败、exit 0、正常结束**；35.067 秒（Task 2 同源码运行） |
| 场景隔离/数据 | syncing=120/30/49/1/0、known=200；completed=170/30/0/0/0；unknown importing=1；many=30 来源；所有模型 `allowsSystemIntegrations=false` |
| 最新主体 capture script | exit 0，明确 `Validated 70-image matrix`。布局收敛、宽高、像素变化、写入后 PNG 复读、缺失/空白/零尺寸/比例错误检查均执行 |
| 最新布局 | menu320pt，settings600pt、高≤680pt。syncing menu212/settings426；many menu543/settings669，顶/底都有浅/深图 |
| 最新 native probe | exit 0，4 个实际新 transient window 及 4 份 WindowServer 原图；own-window group 校验全部 `captured` |
| 组合捕获尺寸 | light popover1274×620 / dark1270×616px；确认框均1200×1402px。清单包含目标 ID、本进程可见窗口 IDs/组合 bounds/真实像素与逻辑尺寸，允许16pt系统组合边缘差；不裁图、不改 PNG |
| 原生外观 | 浅色 app/window=Aqua，深色 app/window=DarkAqua。设置的是隔离测试进程外观，不改变 macOS/用户设置 |
| 不抢焦点 | 各探针 `applicationActiveBefore/AfterInput=false`，host key-window before/after=false；没有 activate、全局输入/按键 |
| 确认框取消 | 浅/深均 actual opened，Escape 关闭；Cancel AX press 返回 false；没有调用 destructive action |
| popover 关闭/键盘 | 实际点击打开；宿主与瞬态本地 Escape 未关闭，清理仅关闭探针创建的窗口。已有窗口在 Space/Return 后持续可见仅记 presence，不宣告独立固定/焦点成功 |
| 最终完整验收 | **controller-owned，尚未执行**；需 integrated reviewer/tester 和 fresh-dir `scripts/validate.py`，结果不能由本轮聚焦验证推断 |

## 隔离、渲染方法及明确缺口

宿主编译当前 App Swift 文件并明确排除 `PhotoSyncApp.swift`；没有正常 app 单实例入口。模型使用 UUID 临时 SQLite，仅造合成来源描述，固定示例日期 2026-10-13；不创建 Photos gateway/engine，不运行 bootstrap/tick，不访问生产数据库、真实来源、Photos 或系统权限设置。图册中系统开关禁用源于 injected 模型隔离，不能当作产品使能规则改动。

主体图使用 `NSView.cacheDisplay` 的真实原生绘制；菜单内容是 StatusMenu，而不是系统 MenuBarExtra 弹出截图。测试 `.controlActiveState=.active` 仅用于活跃控件颜色比较，未激活窗口；原生分析进度条在非 key 宿主仍为灰色，保留该限制。

实际 popover 的 cacheDisplay PNG 包含透明/系统材质限制，图册在对应浅/深背景展示原 PNG。确认框 view bitmap 近乎空白，被明确拒绝；已有 Screen Recording 许可下的 `screencapture -x -o -l <verified-own-ID>` 捕获了真实确认框及其父测试宿主组合。没有请求或更改录屏/Accessibility 权限，没有个人桌面截图，也没有拼装静态详情冒充浮层。

最新浅色 compositor popover `compositor-syncing-light-47565.png` 本身也有明显灰色/材质断层；限制不只存在于 cacheDisplay。compositor 的 `captured` 仅确认本进程窗口的捕获取得和组合几何有效，不证明 active 窗口的系统材质外观可接受。宿主未激活，保留原图和该限制，不据此修改产品样式。

菜单/来源的 actionable identifier 与 help text 未被公开本进程 AX 遍历暴露；探针保留该事实，仅在视检 PNG 的固定尺寸中使用本宿主 hitTest/mouse 输入，尺寸变化则拒绝 fallback。实际 alert 的公开 AX 节点包含取消/移除来源。

尚未验证：物理 hover→进入 popover、完整路径系统 tooltip、独立 Space/Return 固定、外部点击关闭、系统键盘焦点环及焦点恢复、实际 active 窗口下的系统材质。`--interactive` 仅提供用户控制的测试会话；不主动激活，不等于自动验收通过。

## 重现入口

使用当前源码的 Debug build-for-testing，所有输出目录必须全新：

```bash
bash Tests/UIReview/run-ui-review.sh \
  --derived-data "$PWD/work/ui-polish-task2-derived" \
  --output-dir "$PWD/work/ui-polish/review-<unique>"

# 有界、只操作测试宿主窗口；已有权限才执行 compositor capture。
bash Tests/UIReview/run-ui-review.sh \
  --derived-data "$PWD/work/ui-polish-task2-derived" \
  --output-dir "$PWD/work/ui-polish/probe-<unique>" --probe

# 用户控制会话，窗口 ID / PID 记录在 interactive-manifest.json。
bash Tests/UIReview/run-ui-review.sh \
  --derived-data "$PWD/work/ui-polish-task2-derived" \
  --output-dir "$PWD/work/ui-polish/interactive-<unique>" \
  --interactive --scenario syncing --appearance light
```

本轮未做真实 Photos、来源/网络/原片验收、macOS 13/14 实机、通知/登录项/权限、生产配置变更、发布打包、安装/启动生产 App、合并或推送。冻结 Core、AppModel、SyncRuntime、SyncStatusPresentation、PhotoSyncApp、Info.plist 相对冻结基线 diff 为空；Task 3 的 Xcode 变更仅新增 test-target fixture 成员，整条分支另含 Task 1/2 新视图的 app/test target 成员，未加入 Core。
