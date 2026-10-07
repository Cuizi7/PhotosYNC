# Photos 索引连续性修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. 用户已明确要求实施，使用当前隔离工作树，不重复询问执行方式。

**Goal:** 图库清单核对和普通变化不再销毁全库指纹；同时保持对未知内容、未覆盖事件及过期决定的阻断。

**Architecture:** 分离稳定枚举会话、通知覆盖终点、表示有效性和最终 publication。继续用现有 SQLite、串行任务队列和 PhotoKit 适配；同一所有者串行修改这些紧密耦合的接口，保持完整的回归周期。

**Tech Stack:** Swift、公开 PhotoKit、SQLite、XCTest；最低 macOS 13。

**Spec:** [高级判重设计](../specs/2026-09-28-photosync-0.2.0-advanced-dedup-design.md) §4.1–4.4、§9–11；设计冻结 `9235ce9`。

## Global Constraints

- SSCD Large FP16、ANE 优先/GPU 降级、0.98、SQLite 精确 Float32 评分不变。
- 源目录严格只读；本实施和自动验收不访问真实 Photos、生产数据库或 MobileBackup，不启动生产 App。真实只读恢复另按已批准的分阶段计划执行，不进行 Photos 写入。
- 保留四种来源状态、成功历史、unknown 提交保护、物理资源租约、原生 UI 布局和既有视频判重。
- `revision` 不是像素版本。相同摘要不覆盖已知内容变化，也不能弥补历史断档。
- 完整校验前不得 ready。未知向量可保留字节，但不可作为有效候选。
- 有证据的无变化对账：零取图、零推理、零无变化表示/任务行写；允许少量全局检查点写。
- 不新增常驻全量向量缓存、第二数据库、无界事件队列或无关存储重构。
- 使用当前 worktree；只做本地提交。没有合并、推送、发布授权。Intel 实机不测，macOS 13 实机缺口保留。

## Review Focus

- 事件详情晚到、重复投递、频道溢出：关闭 publication，保留义务及字节；不能用同名原因合并未知事件。
- 每页之间都有中性通知：枚举身份保持稳定，覆盖终点可前进；真实变化没有覆盖时拒绝旧令牌。
- 同 revision 的编辑和删除后重插：不得复活旧任务或旧向量。
- 重启/崩溃时只有部分清单或部分变化批次：不把缺失当删除，不误报完整连续性。
- metadata-only 更新仍影响文件名/视频视图；原生分析进度不得重置，保留字节数不冒充 ready 数。

### Task 1: 完整实现事件证据、非破坏性核对及在途任务有效性

**Files / ownership:** `Sources/PhotoSyncCore/Photos/PhotoKitGateway.swift`、`PhotosIndexGateway.swift`、`PhotosRepresentationReader.swift`（仅输入事实/修订的必要变化）；`Sources/PhotoSyncCore/Sync/PhotosIndexCoordinator.swift`；`Sources/PhotoSyncCore/Storage/SyncStore.swift`、`Schema.sql`（仅必要迁移）；`Matching/AdvancedDedupTypes.swift`；`Sources/PhotoSyncApp/SyncRuntime.swift`（仅接线）。测试限 `PhotoKitContractTests.swift`、`PhotosIndexCoordinatorTests.swift`、`AdvancedDedupStoreTests.swift`、`AdvancedDedupServiceTests.swift`、`AdvancedRuntimeTests.swift` 及其共享 fake/现有原生 progress 测试。若需抽出小型 Photos 连续性值类型文件，加入项目 target，不做无关文件拆分。

**Interfaces:** 保留 `PhotosIndexCoordinator.reconcile/processDueWork/libraryChanged/readyToken/progress` 调用边界、`SyncStore.completeRepresentation` 的任务发行校验和 `PhotosCandidateSnapshot` 最终提交 fence。演进 `PhotosIndexGateway` 清单接口以显式携带枚举身份和覆盖终点，不能继续把 raw generation 当固定全轮枚举身份。`PhotosIndexDelta` 的完整覆盖声明与批次必须区分：批次不是新的完整 interval。`PhotoKitLifecycle` 注入层必须覆盖真实 producer 分类逻辑，测试不能只向 coordinator 喂一个可信标签。

**Persistence decision:** 优先沿用表示 `state` 与非空 `vector` 分离：待验证设为不可查询状态但保留字节；task 的发行身份在真正替换时变更，无关对账不变。若有界变化集合需要新增持久表/字段，只能加到现有 SQLite，以事务迁移保留全部既有向量/成功历史，旧库撤销 publication 并重新建立覆盖证明；未知高版本继续拒绝。新增项须在编码前补入本计划的具体接口/迁移记录，说明为何已有表无法表示，不引入第二快照。未知区间不能靠默认“连续”字段升级成已证明连续。

- [ ] **Step 1 — RED。** 加入并实际运行代表性失败测试：full-reconcile 保留 vector 字节；129 个已知变化不污染其余条目；真实 gateway 分类链路的中性通知在每页之间到来仍完成同一枚举；相关/无关在途结果分离。记录行为失败而非环境/编译失败。
- [ ] **Step 2 — Gateway 证据。** 保留 SDK 保证的 `fetchResultBeforeChanges === before` 校验。用公开 object 内容变化详情结合输入/资格事实判别；不能根据时间相关或 iCloud 名称判断中性。记录 raw notification、具体 producer fallback、已知/未知内容范围。固定枚举基线与按序覆盖 endpoint；页面失败可重开轻量会话，但不抹向量。原始事件先关闭 admission，详情完成后才能推进覆盖。对完整大集合做有界批次，不以 128 作为内容可信度上限。
- [ ] **Step 3 — SQLite / coordinator。** 移除 generic full-reconcile 到全库 `vector=NULL` 的含义。保留已完成和待办事实、有效重试期限；未知表示留字节且不参与 publication。只有可靠删除/完整清单缺失才墓碑化。完整批次持久化后才确认 interval；每次 await 后复查相关有效性，最后用当前 context/index/covered endpoint 短 fence 发布。无关变化不使在途结果失效；已知相关/未知输入不 ready，物理结束后才释放。
- [ ] **Step 4 — GREEN 与补充回归。** 十万条单项变化；非增量但有充分内容连续性证据零重算；历史断档+相同 metadata 不复用；129-ID 两种表示容量/重复事件/删除重插；中性通知持续的初建收敛；未覆盖新增/内容/未知事件拒绝发布；分页/任务/迁移崩溃恢复；metadata/video 更新；进度保留。断言真实 SQLite 行写/向量字节、模型/读次数和租约，不只断言日志。
- [ ] **Step 5 — 聚焦验证和提交。** 用独立 `work/index-continuity-*` DerivedData build-for-testing，再对相关 XCTest bundle/套件运行测试；保留准确退出码和数量。不在此重复 canonical/性能负载。提交 `fix: preserve Photos fingerprints across catalog reconciliation`，报告 RED/GREEN、接口/迁移决定、限制、自查。

### Task 2: 独立集成审阅、最终验收及交付证据

**Files / ownership:** 控制线程更新本计划、spec 当前状态、`docs/research/advanced-dedup/photokit-contract.md`、`docs/release/0.2.0-advanced-dedup-validation.md` 与真实验收计划的恢复条件。Reviewer 只读；tester 不改实现；Task 1 所有者负责范围内修复。

**Interfaces:** 消费 Task 1 冻结提交及报告；通过当前 `scripts/validate.py` canonical 入口，不能拿历史 `bc27a425` 或 fake 测试声称真实 Photos 通过。

- [ ] **Step 1 — 一次深度审阅。** 对整个 Task 1 跨层差异做 spec+quality 审阅，特别检查上述五项风险、可信证据来源及存储候选 SQL；此审阅同时是该单一实施任务的最终集成审阅。只对后续修复差异复审，不重复同等门槛。
- [ ] **Step 2 — 最终 canonical。** tester 在最后行为/测试快照运行 `python3 scripts/validate.py --output-dir "$PWD/work/validation-index-continuity-<unique>" --derived-data "$PWD/work/validation-index-continuity-<unique>-derived"`，保留完整 XCTest/Tools/实际模型/四档规模/竞态验证及前后源码身份。正常 Universal build 只在 canonical 未覆盖时补一次；不运行 Intel/Rosetta。若测试失败，定位修复后重新完成受影响门槛，不能跳过失败。
- [ ] **Step 3 — 文档收口。** 记录实现提交、测试命令/结果、核对/复用/待验证/重算口径、证据与缺口；旧性能和真实失败原样保留。同步旧集成计划末尾到本计划，避免重跑已完成 P1–P14。
- [ ] **Step 4 — 准备恢复真实只读验收。** 新实现需重建只读宿主、绑定新哈希、重新审阅读写边界后才能沿用既有授权继续；旧 READY/hash 不批准新二进制。先验证通知分类和索引收敛，完整 ready 后才 MobileBackup 扫描/盲审。真实验收单列结果，不以自动测试代替；不扩为写入验收。
