# Live Photo 变化处理与读取日志 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 避免未改变资源的通知造成 Live Photo 重读，令完整增量通知仅处理变化项，并用匿名分段日志定位原件慢读。

**Architecture:** 在现有 observer → journal → inventory 链路传递每项 Live Photo 资源未变证据，普通图库日志仍完整保存。系统通知按完整增量/非增量两条既有语义处理；读取器在原来的物理请求与租约生命周期内收集时序，不改变并发、超时或预算。

**Tech Stack:** Swift、PhotoKit、SQLite、XCTest；最低 macOS 13。

**Spec:** 用户已批准上一轮诊断报告的修复建议（“修，并且加日志”）；本节与下方约束作为本轮精简设计。原始只读证据在 `work/beta4-runtime-analysis/findings.md`。继续串行实施，不再重复请求授权，用户随后明确要求本轮完成后 merge/release；不安装或启动生产应用。

## 约束与验收

- 中性判断必须同时满足完整对象明细、`assetContentChanged == false`、同一资产/上下文的 Live Photo 描述一致。不能把视觉索引的 inputUnchanged 或空 content 集合当作 Live Photo 未变证明。
- 普通 journal 的 generation、删除和内容义务不丢弃；默认/未知、真实内容变化、混合批次中的变化项、历史恢复继续保守失效。删除与未知提交的既有安全边界不变。
- 完整增量通知仅访问增删改明细；非增量仍完整核对。缺失/畸形明细、before identity 或 generation 断裂不能发布部分变化。
- 日志沿用现有 IndexDiagnostics / RunLogger；使用 run-local 匿名资产/资源/请求 handle，不记录文件名、路径、原 ID、元数据值或系统错误原文。记录请求开始、首批数据等待、数据交付跨度、写入累计、末批数据到完成回调、最终收尾、字节和块数。慢读等待期间有有界心跳；不逐块打印。
- 补记录资源类型、普通视频时长、用途、失效原因与通知增量/全量及访问量；测量只用于诊断，不决定提交、重试或成功状态。
- 保持现有单通道读取、600/610 秒期限、512 MiB 预算及物理资源占用语义。先用日志分清长尾，不在本轮增加并发/预取或改 Photos 写入方式。
- 源目录、生产数据库及图库只读；不启动、重启或安装生产 App。无需 UI 改版。

## Review Focus

- 混合中性/内容变化通知、历史未知变化及删除，不能由中性快路径放过旧结果。
- 延迟通知和跨 generation 的持久记录，不能误恢复已失效观察。
- 增量 moved/inserted/changed/removed 索引口径及不完整明细，必须保持完整性守卫。
- 同步回调、取消早于句柄、超时后的迟到数据和双完成，日志不能改变物理资源生命周期。
- 空资源、失败、无首批数据、长等待及大量小块，日志有界且分段定义明确。

## Task 1：每项 Live Photo 未变证据

**Files:** `Sources/PhotoSyncCore/Photos/PhotoKitGateway.swift`、`PhotoKitLivePhotoReader.swift`、`Sources/PhotoSyncCore/Storage/SyncStore.swift`；`Tests/PhotoSyncCoreTests/LivePhotoKitContractTests.swift`、`LivePhotoStoreTests.swift`。

**Interfaces:** `PhotoKitCandidateAsset.livePhotoInputsUnchanged` 默认 false；observer 传递经验证的资产集合，`recordPhotosChanges(...livePhotoUnchanged: Set<String> = [])` 保守默认不变。描述等同性与内容未变证明同时参与，不能绕过 queued/unresolved 提交守卫。

- [x] 写 observer → SQLite → inventory commit 回归，确认原行为使已读取结果失败；补混合批次、描述差异、未知及删除对照。
- [x] 实现每资产证据，仅跳过确定未变资产的 LP 失效，普通日志仍更新；相关测试 GREEN 后提交。

## Task 2：通知增量访问

**Files:** `Sources/PhotoSyncCore/Photos/PhotoKitGateway.swift`；`Tests/PhotoSyncCoreTests/PhotoKitContractTests.swift`。

**Interfaces:** 在现有文件保存每项真实旧对象快照，提取按 ID 查找和原子更新的映射函数供 SystemPhotoKitLifecycle 使用；不假定 changedObjects 是旧版本。完整增量使用增删改明细，非增量保留全量 membership 核对。诊断记录实际访问数量与回退原因。

- [x] 合成 16,225 项、一个 changed 的计数回归；增删改/移动、非增量、缺失与越界明细回归。证明旧路径访问全库后修复为变化规模。
- [x] 运行 gateway / representation / inventory 契约回归，GREEN 后提交。

## Task 3：物理读取分段诊断

**Files:** `Sources/PhotoSyncCore/Photos/LivePhotoPhotosGateway.swift`、`PhotoKitGateway.swift`、`PhotoKitLivePhotoReader.swift`、`Sources/PhotoSyncCore/Logging/IndexDiagnostics.swift`；`Tests/PhotoSyncCoreTests/LivePhotoResourceTests.swift`、`LivePhotoKitContractTests.swift`。

**Interfaces:** 每个物理请求拥有只读时序诊断对象，由 IndexDiagnostics 提供匿名身份与窗口汇总。单调时钟可注入；原 requester 回调和取消接口保持语义。新增证据不进入持久业务表。

- [x] 受控时钟/回调复现首包慢、传输慢、完成回调慢；断言分段数字、匿名字段、有界输出和汇总，不依赖 sleep 竞态。
- [x] 覆盖取消/超时/失败/空资源/重复完成，确认无额外读取、预算和物理槽位仍由原终止回调释放。
- [x] 相关回归 GREEN 后提交；在合成读取上实际捕获并核对日志。

## Task 4：集成验证

- [ ] 对 `4d1df57..最终行为提交` 做一次深度评审；旧范围评审复用，修复后只复核变更边界。
- [ ] 针对受影响行为先聚焦验证；按最新授权合并 main 后，从确切提交执行一次 `env -u RQDATAC2_CONF scripts/package-release.sh --scale-profile full`，在归档内完整验收。预期完整 XCTest、Tools、四档规模、两类续体均通过。
- [ ] tester 独立核对同一快照证据，不重复整套。记录真实系统验证缺口与新日志字段含义。核对 Universal 架构、签名、版本、DMG、校验和及 provenance，发布 beta4/build21；版本或目标已存在时不覆盖。
