# Live Photo 预筛选与问题状态修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 超过 10 秒的普通视频不再进入 Live Photo 识别，消除未解决提示闪烁和无进展补齐循环，交付 0.3.0 beta4。

**Architecture:** 沿用现有图库清点、来源逐目录识别和补齐协调器。轻量描述携带视频时长，识别策略与实际读取分离；持久问题与瞬时活动分别投影，补齐查询及执行共用准入条件。保留现有 PhotoKit 提交、验证、旧单项移除与未知结果恢复边界。

**Tech Stack:** Swift / PhotoKit / SQLite / SwiftUI / XCTest，macOS 13+。

**Spec:** 本文“批准范围”及既有 `docs/superpowers/specs/2026-10-21-task-progress-and-scheduling-repair-design.md`。用户已明确要求写计划后直接执行、完成 beta 发布；不再重复申请实施或本地合并授权。

## 批准范围与约束

- 阈值固定为 `duration > 10` 秒；恰好 10 秒、未知、非有限或无效时长继续识别。仅作用于普通视频；Photos 已标为 Live Photo 或当前修订已有明确配对身份时不跳过。此为产品筛选规则，不宣称 Apple 格式限制。
- 来源与图库两入口一致。跳过识别不等于跳过同步，不更改普通视频判重/导入，不伪造“原文件没有标识”的结论。筛选结果可以缓存，但必须与当前修订绑定。
- 图库时长取 `PHAsset.duration`；不为读取时长请求原片。旧描述缺少新字段时只刷新未完成的普通视频描述，分批续跑；不重启首次全库清点，不重算已完成结果。旧超限项在得到时长后也可被新规则排除。
- 已删除关联项目保持停止补齐，不复活、不再提示重试；未知/已提交的写入证据仍优先恢复，不能因删除状态丢掉安全阻断。
- 未解决问题与执行活动分开。健康任务运行、批次切换、等待和暂停不能清除真实问题；解决后才撤下。保持六种整体状态及每任务一行、等宽纯色进度条。
- 读取超限给出明确的资源限制原因；未确认身份的项目称“项目/视频”，不能直接称为 Live Photo。历史原始错误不靠字符串猜类型；没有 typed 原因时保留通用说明。
- 只对满足前置条件的补齐任务进入执行状态和 Photos 快照读取。识别后仍可发现新配对，但不能让未核对潜在完整目标的 planned 任务反复空转。保留暂停/上下文/来源准入和提交前二次守卫。
- 日志区分实际阶段推进、无进展和失败；不能将 `false` 正常返回记录成补齐完成。保持匿名 handle 与窗口聚合，不记录个人文件名或资产 ID。
- 不调整 512 MiB 资源预算；不改个人数据库、图库、来源或运行中应用，不提交私人素材；不推送远端或安装生产 App。

## Review Focus

- 旧描述升级与重启：刷新失败不热循环；成功历史、已识别配对及已完成清点保持。
- 阈值边界与长视频已识别身份：既减少原片读取，也不阻止正常视频导入或已有配对补齐。
- 删除与未知写入并存：只取消可明确停止的工作，不丢提交结果或释放未知阻断。
- 持续问题与健康工作并存：菜单、设置、hover 口径一致，无闪烁、无假完成。
- 识别事件频繁到来且补齐依赖未完成：不产生 Photos 快照洪流，依赖满足后自动继续。

## Task 1：10 秒预筛选与升级续跑

**Files:** `Domain/LivePhotoTypes.swift`, `Photos/PhotoKitLivePhotoReader.swift`, `Sync/LivePhotoInventoryCoordinator.swift`, `Sync/SyncEngine.swift`, `Storage/SyncStore.swift`（均在 `Sources/PhotoSyncCore/`）；`Tests/PhotoSyncCoreTests/LivePhotoInventoryTests.swift`, `LivePhotoDirectoryTests.swift`, `LivePhotoStoreTests.swift`。

**Interfaces:** 描述增加向后兼容的可选时长与描述版本；公共纯策略判断普通长视频。新增明确的“按时长排除”观察结果。Store 分批刷新旧的未完成普通视频描述，精确查询当前配对身份。

- [x] 写回归：10 / 10.001 秒、未知/无效、原生 Live Photo、已识别身份；长视频不请求原件但仍正常导入；旧超限描述刷新后终结，重启不重复刷新或全库清点。
- [x] 构建并运行上述相关 XCTest，记录预期 RED。
- [x] 实现最小策略、描述升级和两个入口；保留修订、权限与暂停验证。
- [x] 相关 XCTest GREEN，提交任务 1。

## Task 2：补齐准入与真实诊断

**Files:** `Sync/LivePhotoCoordinator.swift`, `Logging/IndexDiagnostics.swift`, 必要的 `Storage/SyncStore.swift`；`LivePhotoCoordinatorTests.swift`, `LivePhotoCoordinatorTests.swift`。

**Interfaces:** 抽取单一 planned 准入判断，供 `hasDueWork` 和执行选择共用；diagnostics 支持 completion 返回 Bool 的 progressed/no-progress 结果，不影响其他阶段。

- [x] 写回归：未知完整目标存在时多次 discovery 刷新不调用 candidateSnapshot、不读取/创建；前置条件完成后继续；暂停/停用来源仍遵守准入；无进展不会记为完成。
- [x] 运行 RED；实现选择前准入，保留执行中再次验证与有限批次。
- [x] 相关 XCTest GREEN，提交任务 2。

## Task 3：问题分类与稳定提示

**Files:** `Domain/LivePhotoTypes.swift`, `Sync/LivePhotoCoordinator.swift`, `Sync/LivePhotoInventoryCoordinator.swift`, `Storage/SyncStore.swift`, `Sources/PhotoSyncApp/SyncStatusPresentation.swift`；相关 Core/UI presentation tests。

**Interfaces:** 持久问题摘要独立于 `LivePhotoActivity`；deleted group 通过结构化删除事实排除人工处理分类，保留未知写入；新超限观察保存 typed 原因用于说明。

- [x] 写回归：同一问题贯穿 queued/working/waiting/paused；删除项目不提示重试、不重建；未知结果仍阻断；资源超限说明可追溯且不冒称已确认 Live Photo。
- [x] 运行 RED；实现摘要/投影和 hover 文案；只改变现有信息位置的内容，不新增设置或扩展布局。
- [x] 相关 XCTest GREEN；原生离屏浅/深色验证单/双任务、持续问题、hover 内容，记录系统菜单/物理悬停的证据边界；提交任务 3。

## Task 4：集成验收与发布

**Files:** `docs/validation/2026-10-22-live-photo-prefilter-beta4.md`, `docs/release/0.3.0-beta4.md`，既有版本配置、打包脚本与发布工具测试中的版本身份。

- [x] deep_reviewer 对最终集成 diff 做一次完整评审；修复范围内重要发现，只复核改变边界。tester 核对集成行为及证据。
- [x] 更新 0.3.0 / beta4 / build 21；聚焦工具测试通过，确保没有个人数据或无关改动。
- [ ] squash merge 至本地 main，核对树一致；从 main 确切提交执行 `scripts/package-release.sh --scale-profile full`，新目录 `outputs/releases/0.3.0-beta4/`。
- [ ] 核对 canonical 完整 XCTest、Tools、4 档规模、续体竞争，以及 Universal app/Core、图标、ad-hoc 签名、DMG、校验值和 provenance。创建本地版本 tag，交付链接；未做真实图库、安装、公证或远端发布如实说明。

## 聚焦验证入口

`xcodebuild -project PhotoSync.xcodeproj -scheme PhotoSync -destination 'platform=macOS' -derivedDataPath work/Beta4Derived CODE_SIGNING_ALLOWED=NO build-for-testing` 成功后，用 `xcrun xctest -XCTest PhotoSyncCoreTests.<TestClass> work/Beta4Derived/Build/Products/Debug/PhotoSyncCoreTests.xctest` 跑相关类。日志放 `work/beta4/`。

发布采用 full：本次涉及 SQLite 队列查询和资源工作量。开发阶段先聚焦回归；最终在打包归档内执行一次完整 canonical，不以局部测试替代发布门槛。
