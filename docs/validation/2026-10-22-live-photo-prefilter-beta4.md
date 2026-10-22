# Live Photo 预筛选与问题状态修复验证

基线 `3947394`（beta3）；计划见[beta4 实施计划](../superpowers/plans/2026-10-22-live-photo-prefilter-beta4.md)。开发使用隔离工作树、自制文件、临时 UUID SQLite 和 fake Photos，未修改运行中的应用、个人数据库、图库或来源。

## 行为与回归

- `1c51258`：图库 >10 秒普通视频原件读取由 1 次降为 0；等于 10 秒、无效时长、原生 Live Photo、已有身份继续识别。旧 held 描述定向刷新后结束识别，重启不重新枚举。来源长视频仍正常导入，已有身份保留。RED 为库存 27 项中的 3 个断言及来源 9 项中的 2 个断言；恢复实现后相关 48 项全部通过。
- `94a9b94`：重复 4 次发现刷新，前置条件未满足时 Photos 快照调用由 4 次降为 0，依赖清除后恢复创建；日志分别记录 `advanced` 与 `no-progress`。RED 64 项中 4 个断言失败；GREEN 64 项全部通过。
- `7a0a221`：持久问题在运行、排队、等待、排空和暂停时保留；删除组不再人工处理分类，未知提交仍阻断。资源上限带结构化字节预算和可读说明。RED 93 项中 14 个断言失败；补充测试发现超限计数未传入摘要，修复后最终 95 项全部通过，包含旧 checked 视频保留及非有限时长。

构建环境：Xcode 27.1 / Swift 6.4。聚焦日志 `work/beta4/task1-*`、`task2-*`、`task3-*`。最初一次错误的 XCTest 类过滤匹配到 0 项，已拒绝作为证据并改用 `Module.Class`；一次测试编译缺少 `try` 已修复，未计作行为 RED。

## UI

`work/beta4-ui-matrix/` 的 234 张原生离屏图像通过场景/尺寸/非空检查。人工模型检查了单/双任务、浅/深色、持续问题下的运行/等待/暂停及任务说明底部，进度和提示稳定，10 秒规则、资源限制及停止补齐说明可见。

图像由注入模型产生，不建立真实 engine/gateway 或访问个人图库；没有前台激活、全局按键或系统权限修改。图像源码清单在 `source.json`，捕获清单在 `manifest.json`。绘制时 Core 与最终实现只差随后修复的 store 计数传递；本组 fixture 直接注入该计数，绘制边界未变。系统菜单、物理 hover/Escape、焦点和材质不宣称验收通过。

## 集成与发布证据

独立 tester 在 `7a0a221` 已通过 76 项其他相关测试，包括 16 项 RuntimeIntegrationTests、目录、Store、resource 和 Kit 合约。沙箱内自制 MOV 的 H.264 编码服务不可用产生过 2 项环境失败，提升权限后同一五类全部通过；没有为此修改产品或放宽断言。

深度评审发现删除后的永久退避任务可能保留来源预留。`becf155` 让结构化删除事实先于重试/保护期限进入终止清理，未知写入仍优先阻断；专门回归先失败后通过。该提交同时修复新版本标记导致旧图片/原生 Live Photo 描述无谓失配的问题：相等性只忽略升级标记，仍比较上下文、修订、资源集合、角色、文件名、类型和时长。增加 batchSize=1、三项视频、描述刷新失败、重新打开数据库续跑的测试。最终相关 137 项通过，日志 `work/beta4/review-green-tests.log`；先前两类问题的 RED 在 `review-red-tests.log` 和 `review-legacy-red-tests.log`。

完整集成评审与 `becf155` 增量复核均已完成，无剩余严重/中等问题。

beta4/build21 发布工具的合成测试 20 项通过；随后补齐 provenance 的 build_number 身份后，重新运行发布身份聚焦用例 1 项通过。其余门槛仍由最终归档统一验证。

最终归档必须通过 `scripts/package-release.sh --scale-profile full`；四档分别为 10/15/20 万表示无成功历史，以及 20 万表示＋10 万成功历史。它们不代表实际 iCloud 下载速度。

随包 `validation/validation.json`、报告、源码清单、签名/架构/DMG 检查和 `PhotosYNC.provenance` 绑定确切提交，不能用上述聚焦回归替代完整发布门槛。真实 Photos 写入、平台实机、安装及公证未在本轮执行。

## 首次归档失败与后续开发

main `8eacc21` 的首次归档 `work/release-0.3.0-beta4.1xzJw9` 在完整 XCTest 阶段失败：911 项、2 项跳过、5 个失败断言，未生成发行目录或 tag。失败集中于 `AdvancedRuntimeTests` 两个场景及 `AppViewTests` 一个 OCR 几何定位场景。

独立复现确认新准入前移后，来源目录扫描结束未明确重新唤醒补齐，可能令已预留的配对无法推进。修复为非空来源扫描完成后保留一次待消费唤醒；任务仍被占用时在其结束后消费，继续遵守暂停、期限和实际准入。空来源扫描不额外消费识别项目。

另用受控门闩交错两次 `current()`，稳定复现活动数组得到 3 项而非两个协调器的 2 项。状态改为局部组装摘要和活动，再一次性发布；不在 await 之间清空、追加共享数组。OCR 曾将“索引”读成“素引”；布局测试按实际说明按钮左侧的原生文字位置定位，继续检查同一行和内容宽度，不改变原图、OCR 输入或词典。

上述修复后的聚焦验证为 96 项、0 失败，包含完整 AdvancedRuntimeTests 40 项。证据 `work/beta4/canonical-runtime-green-tests.log`；早先失败保留。用户随后要求开发后先诊断日志，新增修复不再合并/发布；分支 canonical 开发验收另行记录。

增量评审进一步发现较早的进度发布可在 await 后覆盖新摘要。扩展同一个受控测试，在挂起期间新增持久待处理项，RED 确认计数从 1 被回滚至 0（`work/beta4/publication-red-tests.log`）。发布改用递增代次拒绝过期写回，读取失败信息也只随当前发布提交，避免过期失败污染新状态。

补充修复后相关 96 项全部通过（`work/beta4/publication-green-tests.log`）；等待增量复核与完整开发验收。

## 最终分支开发验收

行为冻结提交 `e08b89099b8b5605ed47090e15b8569132e892a3` 的增量深度评审通过。`scripts/validate.py --scale-profile full` 退出 0，证据在 `work/validation-beta4-e08b890/validation.json`：完整 XCTest 912 项、2 项跳过、0 失败；Tools 102 项通过；四档规模和 stamp / advanced-preparation 两类续体竞争均通过。

两项 XCTest 跳过分别是由 canonical 子进程单独执行的规模样本，以及需要显式本地输入的历史向量重放；四档规模确实在本次随后执行。源码清单 381 项，验收前后 SHA-256 均为 `965c7c739e41a2949d85eccbda7f3531fb75b8f47b9bde6409cadf0930084994`。独立 tester 已核对完整结果、必要样本集合、报告哈希和未改动的源码清单，没有重复运行同一套测试。

新增修复继续留在 `codex/beta4-release-validation-fix`，不再合并或发布；没有 beta4 tag 或发行目录。此后仅追加验证和诊断文档，不改动已验收的产品代码。只读运行诊断另见 `work/beta4-runtime-analysis/findings.md`，其中额外发现的中性通知失效、全库通知遍历及慢读阻塞尚未修复，不能将本次开发验收解读为这些问题已解决。
