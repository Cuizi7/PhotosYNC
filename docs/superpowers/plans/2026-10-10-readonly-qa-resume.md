# 只读 QA 安全续跑 Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development with one implementation owner, one scoped reviewer and one integrated tester. Preserve existing evidence and do not repeat product verification.

**Goal:** 完成已批准的限定真实判重测试，图库通知或个别来源读取失败不会迫使重做已经确认的来源工作。

**Architecture:** 继续使用同一冻结范围、QA Store 和公开 Core。仅复用经过来源身份、冻结 stamp 和版本核对的源数据；每次评分都重新查询当前正常发布的候选。来源错误独立列为等待／未评分，不能获得不同照片结论。2026-10-10 用户明确批准此项 QA 持久化和验收规则调整。

**Tech Stack:** 私有 Swift 宿主、既有 SQLite Store、SourceVectorRecord sidecar、离线 Python 审计脚本。

**Spec:** [真实图库验证计划](../../release/2026-10-06-real-photos-icloud-validation-plan.md)，本计划细化用户批准的 QA 续跑方式。

## Global Constraints

- 固定 256 Photos 资产、3,017 来源图片、原 50 独立候选及其摘要；模型和 `score >= 0.98` 不变。
- 产品 Sources/Tests/scripts、生产数据库、真实来源和 Photos 资产不修改。实现及 fake 只落 ignored 私有 QA 路径；新宿主真实构建／启动由 root 另行开启。
- 保留旧宿主、旧日志和失败结果；不得用 SQL 提升索引、手写 token、改真值或重抽原 50 项。
- 初始就绪、正常通知覆盖、逐查询 token 核对和最终统一快照继续成立。源工作缓存不是候选评分缓存。
- 保留 1,800 秒单轮 Source 评分上限；有限未完成轮保留源指纹，下一轮重新评分。不得以未完成结果交付盲审。

## Review Focus

1. 不同来源、变更 stamp、非 pending 或已有成功历史的元数据不能复用。
2. 来源指纹的版本、stamp、尺寸、归属、Float32 长度／单位范数及原始字节摘要须一致；部分写入不能授予复用权。
3. 零 ID 通知也走正常 coordinator；授权、上下文、模型、存储或未分类失败仍阻断。
4. 已分类来源错误保留原错误和未评分语义，不增加 duplicate/distinct/notCompared，不制造 SourceFile 成功记录。
5. 原 50 不可用样本不替换；审计工具明确分母，不能将等待／缺口或旧评分当作当前不同照片。

## Task 1：修订并验证私有 QA 的续跑与证据契约

**Files:** `work/real-photos-icloud/20261010-bounded-mobilebackup/host/AuditHost.swift` 及既有 fake 构建／测试入口；同根 `analysis/audit_tools.py`、`analysis/readiness_facts.py` 与其私有合成测试。Root 单独维护正式文档。

**Interfaces:** 继续使用 `SyncStore.file`、`PhotosIndexCoordinator.processDueWork`、`readyToken`、`SyncStore.vectorCandidates`；消费 `SourceVectorRecord` 的现有 stamp/version/binary/size/eligibility，加原始 binary SHA256。`ScanRow` 显式标记 metadata/fingerprint 复用和强类型来源错误；`ScanSummary` 添加 `sourceReadErrors` 及专用源错误 journal 引用。

- [ ] 先写 RED：同源同 stamp 的 pending/no-success 元数据复用、拒绝错误身份/变更 stamp/成功记录；正常空 delta 恢复而未就绪继续阻断；合法源指纹复用但错误长度/范数/版本/stamp/摘要及部分写入不能复用。
- [ ] 最小修改既有函数：metadata 先查已确认 Store 记录并重新核对当前 stamp；需要时正常协调通知／刷新 metadata 后再查就绪。上下文及 fingerprint 版本固定。Source 扫描复用合法 sidecar，但每行都用新 token 调用真实候选查询，不复用旧 evaluation。
- [ ] 写 RED 并隔离 `MetadataError.unreadable`，仅限实际 metadata/decode 阶段：当前 before/after stamp 与冻结值一致时写 waiting/未评分行及专用错误 journal，继续健康兄弟项。模型、资源占用、存储、未知和来源变更不进入此分支。错误行无候选、evaluation 或评分 token。
- [ ] 审计契约 RED/GREEN：完整执行允许 `waiting == sourceReadErrors`，所有等待必须由专用错误 journal 和行数据证明；计数包含 waiting。候选完整就绪门槛不变。独立候选准备只消费源错误 journal，不读取算法分数；已失败的原 50 项记 unavailable，不替换。dual 排除等待样本并校验其没有任何判重结论。未知／缺日志／伪造错误计数／旧 token／部分执行均拒绝。
- [ ] 运行最小相关 fake／合成测试，保留实际退出码、RED/GREEN、输入／结果 SHA 和 typed Main；对照 Core 保持不变。冻结新私有输入，交独立评审及 tester。不要实际构建或启动新 Photos 宿主，不提交私有数据。

## Task 2：恢复真实只读与后续收尾

- [ ] Root 复核新宿主、保留旧包、新 manifest/compiled bindings、正常系统权限；复用同一 QA 数据。来源 metadata 重核冻结 stamp，报告新读／复用／失败数。
- [ ] 50 张 pilot 的真实新算／复用时间分开记录；完整轮超时仍停在未完成，有限重跑仅复用合法源指纹，每轮重新查询当前候选。
- [ ] 全部来源尝试完成、最终统一评分快照／已分类缺口和实际退出证据成立后，按原流程独立盲审、双向抽查。保持原 50 标签先封存的顺序。
- [ ] 继续原三项收尾：最后单张 canary 和定向最近删除，再从最终已提交源码进行本地发行。此修订不开放写入阶段。
