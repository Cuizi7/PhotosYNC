# PhotosYNC 原生 UI 候选证据（2026-10-13）

当前结论：**聚焦自动验证通过，等待用户验收**。本轮截图仍为候选：用户已要求末级目录保持与路径前缀相同字号，仅用原色突出；该产品修正由 Task 2 所有者执行，之后须刷新主体矩阵和瞬态证据。这里的通过不代表前端人工验收通过。

## 源码、隔离与证据入口

- 本轮产品视图基线：`4a7e629`；测试、宿主和截图校验为 Task 3 working diff。各 `source.json` / manifest 记录实际 HEAD、dirty stat/status、编译 Swift 文件 SHA256、同次 Debug Core/Info.plist 校验值、OS/Xcode/Swift。没有复用正常 `PhotoSyncApp.swift` 入口。
- 独立审阅宿主：`local.photosync.ui-review`，同次构建读取的版本为 **0.2.0 beta / build 7**。XCTest 视图的 `Bundle.main` 来自 XCTest 执行环境，版本展示可能使用测试进程 metadata/后备值，不能据此解释产品或独立宿主版本。
- 每个模型：UUID 临时 SQLite；只造合成来源描述，固定示例日期 2026-10-13；`allowsSystemIntegrations == false`。不创建 Photos gateway/engine，不运行 bootstrap/tick，不访问生产数据库、真实来源、Photos 或权限设置。
- 主体矩阵：`work/ui-polish/review-task3-final/index.html` 和 `manifest.json`。17 场景 × 浅/深 × 菜单/设置 = 68 张，另有 many 设置底部 2 张。所有图片经布局收敛、宽高、像素变化及写入后 PNG 复读检查。
- XCTest 原图：`work/ui-polish/screens-task3-final/`，同样 70 张场景主体/底部图。
- 实际原生窗口探针：`work/ui-polish/probe-task3-final/probe-manifest.json`，原始 PNG 在同目录。本轮 WindowServer 截图确实来自所记录的 test-host transient window ID；macOS `screencapture -l` 返回其父宿主组合，因此当前这份旧清单的单窗尺寸检查拒绝了图片。宿主已修正为本进程可见窗口组合边界校验，待字体修正后的刷新验证。失败没有改写为成功。
- 构建/测试/编译日志：`work/ui-polish/task3-final-build.log`、`task3-final-tests.log`、`task3-final-host-typecheck.log`。`work/` 全部为忽略产物，不提交 PNG、数据库或 app bundle。

## 本轮验证

| 项目 | 实际结果 |
| --- | --- |
| Debug build-for-testing | exit 0，`TEST BUILD SUCCEEDED`；sandbox 内 SwiftUI macro server 无法执行，使用获准的环境构建 |
| AppViewTests | **15 项、0 失败、exit 0、正常结束**；最终运行 38.329 秒 |
| 新场景/隔离检查 | syncing=120/30/49/1/0、known=200；completed=170/30/0/0/0；unknown 保留 importing=1；many=30 来源；所有模型系统集成禁用 |
| PNG/尺寸失败检查 | 缺失、空白、零逻辑尺寸和不匹配比例被拒绝；无输出变量仍验证所有场景与真实图像 |
| 主体截图 | 两套宿主矩阵均产出完整 70 张；320pt 菜单、600pt 设置、设置高≤680pt；many 主体菜单 543pt/设置 669pt；短内容自然收缩 |
| 瞬态窗口 | syncing 浅/深：本窗口鼠标点击真实打开 popover；many 浅/深：真实打开移除确认框，Escape 关闭；均未确认移除 |
| 不抢焦点 | 探针 `applicationActiveBefore/AfterInput=false`、host key-window before/after=false；没有 `activate`、全局事件或全局按键 |
| 公共活跃控件外观尝试 | 测试宿主设置 `controlActiveState=.active`，清单明确仅比较控件颜色；非 key 宿主的原生分析进度条仍呈灰色，不作为真实焦点证据 |
| 最后宿主代码 | `swiftc -typecheck` exit 0；`bash -n` exit 0。组合截图校验/图册更新没有再次运行原生窗口实验，以便让出产品字体修正所有权 |
| 最终完整验收 | **controller-owned，尚未执行**；后续由 controller 调度 integrated reviewer/tester 和 fresh-dir `scripts/validate.py` |

## 原生交互的已验证与缺口

`NSView.cacheDisplay` 的 popover 图含透明/系统材质限制；相应浅/深背景只用于图册展示原 PNG，未裁图、P 图或拼装详情组件。确认框 contentView bitmap 近乎空白被明确拒绝；已有 Screen Recording 许可下的定向 WindowServer 原图可看见实际确认框。没有请求或更改录屏/Accessibility 权限。

SwiftUI 菜单/来源的 actionable identifier 与 help text 未被公开的本进程 AX 遍历暴露；探针保留该事实，随后只在已视检 PNG 的固定尺寸中使用本宿主 hitTest/mouse 输入。尺寸变更时 fallback 会拒绝。实际确认框公开 AX 节点有“取消/移除来源”，取消 AX press 返回 false，Escape 关闭成功。popover 的本窗口/瞬态窗口 Escape 未关闭，清理仅关闭该探针实际创建的窗口。

尚未验证：物理 hover→进入 popover、完整路径系统 tooltip、独立 Space/Return 固定、外部点击关闭、系统键盘焦点环及焦点恢复；没有把已打开窗口持续可见当作 Space/Return 成功。`--interactive` 可在用户控制的测试会话中补验；宿主只 `orderFront`，不主动激活。

## 重现入口

先用当前源码 build-for-testing，再执行（输出目录必须全新）：

```bash
bash Tests/UIReview/run-ui-review.sh \
  --derived-data "$PWD/work/ui-polish-task2-derived" \
  --output-dir "$PWD/work/ui-polish/review-<unique>"

# 有界、仅测试宿主窗口的原生交互探针；不激活，不请求系统权限。
bash Tests/UIReview/run-ui-review.sh \
  --derived-data "$PWD/work/ui-polish-task2-derived" \
  --output-dir "$PWD/work/ui-polish/probe-<unique>" --probe

# 用户控制会话，不等于自动交互通过。
bash Tests/UIReview/run-ui-review.sh \
  --derived-data "$PWD/work/ui-polish-task2-derived" \
  --output-dir "$PWD/work/ui-polish/interactive-<unique>" \
  --interactive --scenario syncing --appearance light
```

本轮未做：真实 Photos、网络/原片来源、macOS 13/14 实机、通知/登录项/权限、更改生产配置、发布打包、安装或启动生产 App、合并或推送。冻结 Core、AppModel、SyncRuntime、SyncStatusPresentation、PhotoSyncApp、Info.plist 的相对冻结基线 diff 为空；Xcode 仅新增测试 target 的 ReviewFixtures 成员。
