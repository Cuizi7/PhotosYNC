# Photos 通知恢复修复验收（2026-10-07）

冻结产品／测试提交 `b15742fbcc4fe16a75ecdfacdc189c8bfac0cd79`，tree `ba37d24b7e8a94d3de742c18123971dc87d56405`。修订 spec/plan 的前置提交为 `3b2c465`。实现、独立深度审阅和完整自动验收完成；真实 Photos 恢复测试另行记录，不能由自动结果推导通过。

## 修复与受控证据

- 清单确认在已覆盖代次的最终锁内校验后清除通知交付 dirty，不等待全部指纹就绪。历史 admission／判重 publication 仍由最终 ready 独立开放。
- 新的短提交锁协调 observer 版本登记＋详情入队，以及 snapshot 版本捕获＋入队；生命周期加载、回调和等待队列均在锁外。保留版本相等、SDK fetch-result 身份、输入事实、任务发行和最终准入检查。
- 清单确认补齐授权／图库可用性检查；旧确认、尚未分类的新通知和 journal 写入失败均不能清除新义务。
- 现有诊断补实际／期望候选基线，以及清单确认和 ready 确认的区分。没有新增 schema、模型、阈值、UI、数据库或日志系统。

先观察两条行为 RED（清单确认后仍 full、快照越过未排队通知），再修复；另有授权丢失 RED。保留移动后的诊断但撤去顺序保护的受控 mutation 仍失败。最终聚焦验证 132 项、0 失败，包含真实 gateway 注入层、coordinator 和临时 SQLite；新增用例检查增量交付、向量字节、零重读／推理、并发通知、旧准入拒绝及存储失败。门闩限定内部测试构造器，仅建立时序，不提供内容证据。

独立评审 **SPEC PASS / QUALITY APPROVED**，没有开放中高严重性发现。报告和 RED/GREEN 证据见 `.superpowers/sdd/2026-10-07-photos-index-notification-recovery/`、`work/notification-recovery-red/`、`work/notification-recovery-mutation/`、`work/notification-recovery-green/`。真实 event 43 的确切交错仍未得到历史证据证明；受控复现证明的是旧代码缺陷。

## 完整自动验收与正常构建

```sh
python3 scripts/validate.py \
  --output-dir "$PWD/work/validation-notification-recovery-20261007" \
  --derived-data "$PWD/work/validation-notification-recovery-20261007-derived"
xcodebuild -project PhotoSync.xcodeproj -scheme PhotoSync -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$PWD/work/release-notification-recovery-20261007-derived" \
  CODE_SIGNING_ALLOWED=NO build
```

均 exit 0；canonical `validation.json.status=passed`。275 项源码清单前后 SHA256 相同：`6293e7f672e114835d964813a1e50dd5e2dbbe1da83e667ebff1fac10e4837c1`。

| 检查 | 结果 |
| --- | --- |
| 完整 XCTest | 552 项总数，含 2 项显式跳过，0 失败 |
| Tools | 94 项，0 失败 |
| 实际模型回归 | 33 例全部执行通过；ANE/GPU 两种允许配置各 4 项自检通过 |
| 合成规模 | 100k、150k、200k、200k＋100k 成功历史四档全部通过 |
| 续体竞态 | stamp、advanced-preparation 的预期 RED 和当前 GREEN 均通过验收 |
| 常规 Universal Release | App/Core 均 arm64＋x86_64，每切片及 bundle 最低 macOS 13.0 |

两项 XCTest 跳过是由 canonical 独立执行的规模用例和需要显式本地输入的旧向量回放。模型报告中的 `skip_count=11` 是预期算法动作数，不是未执行的测试。测试宿主链接的 SDK XCTest 支持库有较高系统版本警告，正常 App/Core 最低版本单独核实；不替代 macOS 13 实机验证。既有无 AppIntents 依赖的元数据提取警告不影响构建。

## 只读恢复准备及边界

新私有目录 `work/real-photos-icloud/20261007-notification-recovery/`。旧会话正常停止后的 QA 库通过 SQLite backup 复制，完整性检查通过，48 个 rowid/vector 字节序列一致，旧库哈希未变；没有复制授权结果或 READY，也没有直接提升旧向量有效性。

宿主仅替换输出目录、执行门闩及冻结产品提交，逆替换精确复现此前独立审阅的宿主源码／recipe。新源码 SHA256 `bb2ec8fb1aae60ff6c731130ffb12e90caf9dfd2bd91630d2bdf0a58cedca0a9`；recipe `ecc7b48d57f245ee70ffbda20068d4062a681b8928007e1c020011ec5abaec65`。从 fresh archive 和新 DerivedData 构建，38 项哈希及 deep strict 私有 ad-hoc 签名核验通过；宿主/Core 为 arm64、最低 13.0。

fake-only self-test exit 0，写入独立 UUID 目录：写入调用 0、精确评分 oracle 405 matches、合成推理及覆盖／会话／物理租约检查通过。48 向量恢复库在自测前后哈希保持 `a23c9d048758c1841a9325e3a44d2f915709add2d62b15dbc87c31b49d66be2d`。详情在新目录 `offline-build-report.md`。

真实恢复须重新核对来源、当前系统授权及图库历史；先确认进度保留和通知分类，再继续完整建库、MobileBackup 评分及盲审。当前文档仅证明代码与离线准备完成，真实进度见 [MobileBackup 实测](../research/advanced-dedup/2026-10-07-mobilebackup-real-photos-audit.md)。未做 Photos 写入、生产 App 启动、GUI／macOS 13 实机／Intel 实机、安装、打包发行、Developer ID 或公证；正常构建和私有 QA 签名不是发行验收。
