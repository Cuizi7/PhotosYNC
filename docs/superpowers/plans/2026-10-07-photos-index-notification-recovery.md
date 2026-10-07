# Photos 索引通知恢复修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development。用户已批准先更新 spec/plan，再实施；复用当前隔离 worktree，不重复询问执行方式。

**Goal:** 初建过程中，已完成的清单核对解除通知交付 dirty；候选快照与通知处理不制造虚假基线断档，已验证指纹可持续复用。

**Architecture:** 沿用 PhotoKitGateway、PhotoKitCandidateIndex、PhotosIndexChangeChannel 和既有 coordinator。区分清单确认与最终 ready/admission 确认，在既有同步边界内协调通知入场、排队和快照；先用受控交错证明问题，再修复原因。无需 schema 迁移、新数据库或新常驻缓存。

**Tech Stack:** Swift、公开 PhotoKit、SQLite、XCTest；最低 macOS 13。

**Spec:** [高级判重设计](../specs/2026-09-28-photosync-0.2.0-advanced-dedup-design.md) §4.1.4，以及 §4.1–4.4 既有约束。

## Global Constraints

- SSCD Large FP16、ANE 优先/GPU 降级、0.98、SQLite 精确 Float32 评分不变。
- 源目录严格只读；产品 Photos 写入仍仅新增，但本轮全部真实测试禁用写入。不访问生产 SQLite，不启动生产 App，不修改 iCloud/TCC 设置。
- 未覆盖变化或未知内容不得 ready；保留向量字节不等于授权参与判重。最终 publication 和历史 admission 检查不放宽。
- 保留任务发行身份、有效退避、物理租约、成功/unknown 历史、原生 UI 和视频判重行为。
- 不增加 schema、公开接口兼容层、第二日志系统、无界队列、全量向量缓存或无关重构；必要的小型内部测试 seam 须明确职责。
- 受控回归只用 fake PhotoKit、自制媒体和临时 SQLite。实际 Photos 只在 Task 3 的已批准只读宿主执行。
- 使用本地提交，不合并、推送、发行或安装生产 App；Intel 实机不测，macOS 13 实机缺口保留。

## Review Focus

- 旧 inventory ack 与较新通知/未完成详情交错：不能清除新义务或恢复旧 admission。
- observer 入场到队列接纳期间 snapshot 抢先：不产生虚假 baseline gap，不死锁或忙循环。
- 两个并发通知及排队事件：严格覆盖代次，不能靠最终 metadata 相同合并丢失的编辑。
- 初建只有部分指纹时中性通知持续：既有向量保留，后续增量不能反复升级为 full。
- 真实输入变化、删除重插、权限撤销及历史失败：保持保守阻断，旧任务不能复活。

## 既有证据与范围

代码基线 `4e6d8ba`（行为冻结 `3871947`）。之前连续性计划已经完成，不重新执行其实施任务。本次实测事实见 [只读报告](../../research/advanced-dedup/2026-10-07-mobilebackup-real-photos-audit.md)。私有旧会话已经正常停止，`READY` 已关闭，保留 48 个向量和日志；115 次成功读取、93 次接受 completion 与 48 个最终 ready 行须分开解读。

dirty 清理时机已由实际日志和源码确认。`candidate-baseline-gap` 已观察到，但具体并发交错未证实。禁止先改比较条件来让测试变绿；必须在真实 gateway 注入链路复现或取得更具体证据。

### Task 1: 修复通知确认与候选基线顺序，并补受控回归

**Files / ownership:** `Sources/PhotoSyncCore/Photos/PhotoKitGateway.swift`、`PhotosIndexGateway.swift`；必要时 `Sources/PhotoSyncCore/Sync/PhotosIndexCoordinator.swift` 仅诊断/确认接线；`Tests/PhotoSyncCoreTests/PhotoKitContractTests.swift`、`PhotosIndexCoordinatorTests.swift` 及现有共享 fake。一个实现者串行拥有这些耦合改动，不改存储 schema、模型、UI、来源扫描或 QA 宿主。

**Interfaces:** 保留 `acknowledgeInventory(expectedGeneration:)` 与 `acknowledgeReconciliation(expectedGeneration:)`、`candidateSnapshot()`、`recordLibraryChangeForTesting()`、`changes()`。复用 `PhotoKitState.acknowledgeReconciliation` 内两次代次/详情检查和最终锁内确认回调；inventory 确认只解除已覆盖频道 dirty，不开放 history admission。候选索引仍通过现有串行队列获取/应用真实 lifecycle 详情，保留 SDK fetch-result 身份检查。

- [ ] **Step 1 — 两条 RED。** 写入并运行有意义的失败用例：① 先有 full-reconcile，再完整核对并 inventory ack，指纹仍有 pending，随后中性事件必须交付 incremental 且没有重读已 ready 图像；② 用门闩阻塞 observer 入场与详情入队之间，发起候选 snapshot，证明当前版本出现基线断档/错误重建。诊断注入仅用于确定性时序，不用真实图库、随意 sleep 或修改期望绕过失败。记录确切行为失败及日志；若②无法复现，报告新证据并收窄原因，不凭猜测修改安全 guard。
- [ ] **Step 2 — 最小修复。** 在正确的锁内确认已覆盖通知交付状态。让通知代次、排队顺序及 candidateSnapshot 的重建基线一致，维持 observer 第一时间关闭 admission；检查持锁调用、同步队列重入和取消时的物理工作边界。给基线失败补实际/期望代次诊断，给清单确认与最终 ready 确认保留可区分证据。不得把 unknown 标成中性，不关闭 observer，不删除版本检查。
- [ ] **Step 3 — GREEN 与负向回归。** 在真实 gateway + coordinator/临时 store 链路验证：未 ready 清单确认后继续增量；已 ready 向量字节、读/推理计数保持；较新/未分类事件拒绝旧 ack；并发两个通知保持顺序且旧 snapshot 不可提交；真正内容修改/删除和授权不可用仍拒绝旧结果；历史覆盖/存储失败不开放 publication。复用已有有意义回归，避免大量镜像实现的测试。
- [ ] **Step 4 — 聚焦验证和提交。** 新 `work/notification-recovery-*` DerivedData build-for-testing 后运行相关无宿主 XCTest。记录 RED/GREEN、命令、结果、源码身份，提交范围内改动。实现报告解释锁顺序、确认职责、是否证实历史实测根因，列出剩余不确定性。此时不重复完整 canonical，也不调用真实 Photos。

### Task 2: 独立审阅、完整验收与文档绑定

**Files / ownership:** Reviewer 只读 Task 1 完整差异及相关锁/发布调用；tester 运行验收不改代码；原实现者处理明确范围内 findings。控制线程更新本计划、spec 状态、PhotoKit contract、实测恢复计划和脱敏结果。

- [ ] **Step 1 — 一次深度集成审阅。** 同时覆盖 spec 和 quality，重点审查 ack 原子性、重入/死锁、并发通知顺序、真实未知保护和测试是否能排除错误实现。这是本修复单元的最终集成审阅，后续只复审修复差异，不重复既有大分支评审。
- [ ] **Step 2 — 当前最终快照 canonical。** 执行 `python3 scripts/validate.py --output-dir "$PWD/work/validation-notification-recovery-<unique>" --derived-data "$PWD/work/validation-notification-recovery-<unique>-derived"`，要求完整 XCTest/Tools/模型/四档规模/竞态全通过。最后行为/测试修改必须被该验收覆盖；失败须处理并保留证据，不能跳过。若 canonical 未覆盖正常 Universal Release，再补一次独立 build，不执行 Intel/Rosetta。
- [ ] **Step 3 — 收口证据。** 更新 `docs/research/advanced-dedup/photokit-contract.md` 和真实测试计划的修复状态；新增 `docs/release/2026-10-07-photos-notification-recovery-validation.md`，记录冻结提交、实际计数/命令/未覆盖项。既有真实失败和旧 canonical 保留，不改写为本次成功。

### Task 3: 绑定修复后的只读宿主并恢复真实验证

**Files / ownership:** 仅 ignored `work/real-photos-icloud/` 的新宿主/范围文件/私有证据；只读 tester 独占真实命令，root 负责范围和批次批准。产品版本以 Task 2 最终冻结为准。

- [ ] **Step 1 — 精确宿主与恢复数据。** 新 archive/DerivedData 构建并核对 Core/host/模型哈希及签名；宿主复用既有只读适配逻辑，仅必要绑定改动，不恢复旧 READY。正常停止的 QA 数据库通过一致副本保存并恢复，源旧库与 48 个向量留存；新 Core 仍必须完成历史和清单核对，不直接提升旧行有效性。若需要调整只读宿主行为，独立评审其差异并重跑 fake-only 安全/转发/数值检查。
- [ ] **Step 2 — 正常授权和有界复验。** 沿用用户对生产 Photos 只读及 MobileBackup 扫描的授权，LaunchServices 后台启动；仅系统确实要求时请求用户操作。每批最多 500 次允许联网表示请求/30 分钟，单物理读取/模型队列，检查点核对健康后顺序继续。先确认既有向量复用、已知中性通知不升级完整核对、旧任务拒绝和实际进度收敛；异常重复工作时保存证据，不盲重启或清库。
- [ ] **Step 3 — 回到 V3-MB。** 上述复验健康后继续完整建库，取得有效 ready 才扫描 MobileBackup 试点/全部图片及既定独立盲审、双向抽查；完整步骤沿用真实验证计划 MB3–MB7，不另造抽样或调整阈值。若 OS 授权或实际环境阻塞，如实记录已经完成的代码修复/自动验收和未完成真实阶段，不将准备工作当作成功实测。
