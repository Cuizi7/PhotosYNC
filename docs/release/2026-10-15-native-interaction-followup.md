# PR #1：原生交互补验记录（2026-10-15）

结论：本轮接受交互覆盖缺口，未发现足以修改产品的缺陷证据。有限探针在宿主资格检查阶段停止；**新增产品交互断言为0，通过0，产品失败0**，不能将进程正常退出写成验收通过。2026-10-13用户已批准的视觉验收及其披露限制保持有效。

## 逐项复核

| 评审意见 | 作者判断 | 实际结果及剩余缺口 |
| --- | --- | --- |
| hover延迟、按钮与浮层联合区域、延迟关闭取消、固定、消失重开清理 | 接受补验需求，不接受已有缺陷的推断 | 未进入输入阶段；200ms时序、物理hover及完整路径tooltip均未新增验证 |
| 独立Space/Return固定、Escape/外部点击关闭、可见焦点恢复 | 接受补验需求，不接受旧inactive宿主失败即可证明产品缺陷的推断 | 激活/key/事件队列校准前提未成立，所有这些行为仍未验证；不以firstResponder布尔值代替可见焦点 |
| 实际SwiftUI MenuBarExtra(.window)及设置/退出/扫描/暂停入口 | 部分接受 | 已构造真实隔离场景、发现公开状态栏按钮，但未确认内容打开；所有操作入口均未执行，不以普通NSWindow替代实际菜单验收 |
| 浅色浮层偏灰的捕获原因 | 部分接受，保留有限调查范围 | 本轮没有新捕获或材质对照；原因仍未确认，不硬编码白底、不改色，也不撤销既有用户验收 |

## 实际执行与边界

探针源码及构建记录绑定起始HEAD `2f3604b609c24f07ae6d88df727cbfb8d6314c6d`。单独编译的SwiftUI App复用未变的产品视图及既有UUID临时fixture，声明真正的`MenuBarExtra(...).menuBarExtraStyle(.window)`，排除生产`PhotoSyncApp.swift`入口。`allowsSystemIntegrations=false`；没有启动runtime、访问真实来源、生产数据库或Photos。只签名隔离副本，没有修改原Core。

首次探针PID30944，运行约1.97秒、exit0。其启动处理器先调用了`NSApp.setActivationPolicy(.regular)`，未记录该调用的返回值；这与随后完全不设置策略的被动诊断分开记录：

1. 在本进程公开窗口/视图树发现唯一`NSStatusBarButton`，调用一次公开`performClick(nil)`。等待后未通过`sync-details`标识确认内容打开。该发现方式是经验探针，标识缺失不能证明内容绝未打开，也不能证明物理点击失效。
2. 创建本进程校准窗口后，仅请求一次激活；返回false，始终inactive、无keyWindow、前台PID保持29832。随后停止，未发送任何`NSApp.postEvent`，未进入校准或产品交互。
3. 原始报告的两个断言属于“菜单打开”和“事件队列校准”的资格检查，均为unverified；不是两个产品失败。未创建产品内容的普通窗口回退、未执行任何操作入口、未生成新PNG。

随后仅追加一次被动诊断，PID33648，约1.79秒、exit0。四次观察均有唯一enabled状态栏按钮，公开`action=nil`、`target=nil`；应用注册策略为regular，但仍inactive、无keyWindow。零激活、点击、事件、窗口显示或捕获请求；首次探针产物逐字节保留。该结果只说明未暴露普通target/action路由，不能推断SwiftUI内部路由有缺陷。

两次宿主均已退出。没有全局键鼠事件、光标移动、私有API或新权限请求。状态窗口的特殊`NSWindow.windowNumber`（如`1<<32`）未当作有效`CGWindowID`使用。到此停止自动尝试，不重复激活或凭未验证结果修产品。

## 可追溯证据与原验证复用

本次仅新增证据文档及[JSON摘要](assets/2026-10-15-native-interaction-followup/evidence.json)。摘要是原始日志的字段投影，包含原文件SHA256、实际资格断言、前台/key记录、编译文件校验和退出证据，不能当作独立产品测试报告。原始源码、构建参数、日志、JSON和副本保留在本地被忽略的`work/pr-1-interaction-followup-20261015/`。

产品、测试及Xcode project与完整验证快照`d3d117201da38dcb5f8df2c7a00d5dc185b3bbb8`的差异为空。复核既有canonical报告SHA256仍为`5d3679efb2a4ae89162192e6dc7bb6ddfc0ea0a5da83ca218a5c18785e2c9485`：604项XCTest（2显式跳过、0失败）、96项Tools，以及模型/资源、四组规模和两组续体竞态通过。本轮没有重跑或改写这些结果；[原验收记录](2026-10-13-native-ui-acceptance.md)继续披露此前20ms测试单次失败及完整重跑情况。

PR仍为[PR #1](https://github.com/Cuizi7/PhotosYNC/pull/1)，`codex/native-ui-polish` → `codex/photosync-0.2.0-design`。本轮远端ref核对时目标tip为`dafd622756fdab47c73e6fdc877139541abcd7cb`，分叉点仍为`f467ed49f5c34637437aa936dbe13f8c91ef2b33`。目标后续变化不涉及Sources、hostless XCTest或project；它新增的发布工具验证与本PR的96项历史证据分开记录，不把别处分支的97项结果写成本PR的新实测。

后续若继续原生交互验收，须先使隔离菜单真实打开并取得输入所有权及正向校准，再分别观察物理hover、独立Space/Return、关闭/重开和可见焦点。当前不把这些缺口升级为已复现缺陷或新的合并阻断。没有合并、发布、安装/启动生产应用或扩大系统/平台验收范围。
