# PhotoKit 单项读取错误隔离验收

产品快照：`a190279fe2d7f4e5e7aa9aab5f26b3f1376b1ab6`。批准契约见[设计 §4.3.1](../superpowers/specs/2026-09-28-photosync-0.2.0-advanced-dedup-design.md)，步骤见[实施计划](../superpowers/plans/2026-10-08-photokit-read-error-isolation.md)。这是本单元的自动验收，不是整个 0.2.0 的合并、发布或真实图库验收。

## 行为

- PhotoKit 单个表示的终结读取错误（包括实测形状的 Cocoa -1）记录阶段、domain/code、详情及重试事实；健康照片继续建指纹。original/current 分别处理。
- schema v7 在已有失败任务上保存明确分类。错误缺口不算成功向量，不参与候选查询；旧错误文本保持未分类，不能直接升级为可忽略错误。
- 已知授权、图库、网络、取消、逻辑超时和物理占用，以及模型／存储错误保留既有阻断或等待语义。已知底层错误被普通 NSError 包装时也受保护；循环或无法完整检查的错误链不能获得豁免。
- 同类错误再次失败保留健康候选的版本；重试成功加入向量或转为阻塞错误时，原子撤销旧 publication，已经准备好的旧判重结果不能直接提交。
- 日志单列 `readErrors`，ready 仍只统计实际向量。UI 结构、原生控件、0.98 阈值、模型、资源预算及来源文件策略不变。

## 自动验证

独立深度审阅与修复复核均为 **SPEC PASS / QUALITY APPROVED**。最终 canonical 命令：

```sh
python3 scripts/validate.py --output-dir "$PWD/work/validation-read-error-isolation-20261008-03" --derived-data "$PWD/work/validation-read-error-isolation-20261008-03-derived"
```

退出码 0，`validation.json` 为 passed；277 个源条目的前后 manifest 相同：`14227ac43e9fdf9903e4de8036771f5768366c202b6835df650de50e22fad02c`。Xcode 26.6 / Swift 6.3.3，本机 Apple Silicon。

| 检查 | 结果 |
| --- | --- |
| 完整 XCTest | 571 项，0 失败，2 项跳过 |
| 工具测试 | 94 项，全部通过 |
| 固定模型／用例集 | 资源校验与 33 例模型回归通过 |
| 规模与历史 | 10 万、15 万、20 万表示，以及 20 万表示＋10 万成功历史，四档通过 |
| 恢复竞态 | stamp、advanced-preparation 两组 RED/GREEN 通过 |
| 正常 Universal Release 构建 | 退出 0，app/Core 均为 arm64＋x86_64，两个架构的最低目标均为 macOS 13.0 |

两项 XCTest 跳过分别是随后由 canonical 专门运行的规模子进程，以及需要显式本地输入的 saved-vector replay；没有将它们计为通过。四档热准备／增量准备 P95 分别为 306/329、398/465、663/720、871/979 ms，均满足现行 2 秒预算；查询阶段持久行写入为 0。最后一档还覆盖约 60 秒闲置后的恢复查询（1,044 ms）。这些是合成实际调用链数据，不包含真实 PhotoKit/iCloud 获取时间。

就绪检查的合成 SQL 字节码探针确认三条检查没有读取 representation 向量列；完整测试保留索引和完整性断言。该探针位于 ignored `work/read-error-isolation-task1/`，不是常规套件中的独立查询计划断言。

证据：`work/validation-read-error-isolation-20261008-03/`；正常 Release 日志为 `work/validation-read-error-isolation-20261008-03-release.log`，产物在同名前缀的 `-release-derived/`。没有签名发行、打包、安装或启动生产应用。

## 中间发现和限制

首轮完整测试发现两条旧迁移测试仍期待 schema v6，已在 `3bcb012` 修正，保留其他数据／历史断言。第二轮因窄复核确认嵌套 NSError 保护遗漏而停止；`a190279` 修复后才执行上面的完整通过验收。首轮失败及第二轮中止的 `-01`、`-02` 证据保留，不能替代最终结果。

真实 Photos／iCloud 续测尚未以新宿主完成。已保留旧运行原库，并创建逐行一致的恢复副本：539 个 ready 表示、15,368 个 pending、1 个历史未分类读取错误。新只读宿主已完成独立静态审阅、固定快照构建、完整哈希及 ad-hoc 签名核验，最终 `self-test`／`retry-self-test`／`read-error-self-test` 均退出 0、报告 Photos mutation 为 0。

最终嵌入 Core 已将新恢复副本迁移到 v7：完整性及外键检查通过；539 个向量（2,207,744 字节）的键／内容摘要和原重试数据不变，15,369 个历史 failure_kind 均保持 NULL；清单核对资格被撤销且 publication 仍为 NULL。旧原库字节哈希未变，fake 自测没有接触这两份库。证据位于 ignored `work/real-photos-icloud/20261008-read-error-isolation/host/` 的最终测试、manifest 及 migration-before/after 记录。

真实阶段已具备只读门闩，目前仅启动新宿主的 Photos 授权入口；尚未恢复建指纹。额外发现 `/Volumes/home` 未挂载，源目录清单差异未测量，不能视作零变化；等待挂载恢复后继续 source-metadata／扫描／导出。Photos 索引不依赖该源挂载，可独立推进。普通本地查看或原片导出成功，不证明 PhotoKit 图像读取路径已恢复。

错误缺口可能导致漏掉仅由该表示证明的重复，报告必须披露可用候选覆盖范围。macOS 13 实机缺口保持；Intel 实机按用户指示不做。未新增 GUI 手工验收或正式签名／公证验收。旧 v5 降级测试保留新增列，因此单独不能证明无该列的真实 v5 升级；v6 的共用添加／回滚路径已有直接测试，v5 的事务接线已审阅。
