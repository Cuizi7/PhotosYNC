# 导入吞吐 review findings 修复计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 reviewer 发现的 PhotoKit 增量路径 O(N) 校验、GUIQA 全量候选回退和旧协议默认实现绕过 generation 保护的问题，并补齐关键并发与迁移验证。

**Architecture:** PhotoKit 变化明细只携带本次 inserted/changed/removed 资产，索引用当前 asset-ID map 做 O(Δ) 一致性检查；任何 ID 不符合连续性时放弃增量并在下一次 snapshot 安全全量重建。PhotosGateway 将 generation snapshot 和带 token 的 create 变成所有实现都必须提供的主接口，旧的全量读取只保留为测试/诊断便利方法。GUIQA readonly 通过自己的缓存和 Photos change observer 失效缓存，不再依赖协议默认的全量加载。

**Tech Stack:** Swift、公开 PhotoKit、Swift concurrency、SQLite、XCTest；最低 macOS 13；不改变 schema v3 文件状态语义。

**Spec:** `docs/superpowers/plans/2026-09-19-import-throughput.md`、`docs/specs/2026-09-18-runtime-state-and-recovery.md`、`Design/Validation.md`。

## Global Constraints

- 源目录严格只读，Photos 只新增资产；不增加并发 Photos 提交，不计算内容哈希。
- 文件状态仍只有 `pending`、`importing`、`imported`、`skipped`；不重判历史 skipped，不清理或迁移生产数据库。
- Photos 变化不确定、权限撤回、检查点失败或提交结果 unknown 时必须保守阻断；只有明确未提交才允许重试。
- 所有 PHPhotoLibrary change observer 回调只入队，不直接修改共享候选 map；候选索引和生命周期对象在单一串行上下文访问。
- 修复在 `codex/import-throughput-fix` worktree 实施；不修改当前运行的 beta2，不合并、不推送、不打包。

## Review Focus

- 连续 PHChange 中删除/插入/修改资产的 ID 不一致：必须回退全量重建，不能返回缺失或重复候选。
- GUIQA readonly 连续扫描大量文件：候选加载次数必须与扫描轮次/图库变化同阶，而不是与文件数同阶。
- 旧 fake 或第三方 PhotosGateway：编译时必须实现 generation snapshot 和 token-bound create，不能静默获得 generation=0 的安全旁路。
- keyset drain 在 cursor 已越过旧记录后恢复 pending、未来 retry、暂停/停用 await 和新记录追加：不能漏导、重复提交或破坏四状态。
- 现有 v3 数据库打开、重开和索引创建失败：必须保留历史和状态，不能把索引问题当作空库。

---

### Task 1: 将 PHChange 增量一致性校验改为 O(Δ)

**Files:**
- Modify: `Sources/PhotoSyncCore/Photos/PhotoKitGateway.swift`
- Test: `Tests/PhotoSyncCoreTests/PhotoKitContractTests.swift`

**Interfaces:**
- Consumes: 当前 `PhotoKitCandidateIndexChange.incremental` 的 removed/changed/afterAssetIDs 结构和 `PhotoKitCandidateIndex.byAsset`。
- Produces: `PhotoKitCandidateIndexChange.incremental(removedAssetIDs:changedAssets:)`，不再要求枚举 `fetchResultAfterChanges` 取得全库 ID。

- [ ] **Step 1: Write the failing test**

在 fake lifecycle 中增加 `candidateIndexChangeCallCount` 和增量 payload 计数；写 `testIncrementalChangeDoesNotEnumerateAfterFetchResult`，先返回一个只有本次变更资产的 delta，并断言 100 次连续变化只调用一次 `loadCandidateAssets`，每次 delta 只携带 1 个 removed/1 个 changed。旧结构无法构造不含 afterAssetIDs 的增量结果，测试先因接口仍要求 `afterAssetIDs` 或因全量 after 集合计数失败而 RED。

- [ ] **Step 2: Run test to verify it fails**

```sh
xcodebuild -project PhotoSync.xcodeproj -scheme PhotoSync \
  -destination 'platform=macOS' -derivedDataPath work/review-fixes-task1-red \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```

Expected: the new test fails because production change extraction still enumerates `fetchResultAfterChanges` and constructs `afterAssetIDs`.

- [ ] **Step 3: Write minimal implementation**

Change the internal enum and lifecycle method to carry only the delta:

```swift
enum PhotoKitCandidateIndexChange: Sendable {
    case incremental(
        removedAssetIDs: Set<String>,
        insertedAssets: [PhotoKitCandidateAsset],
        changedAssets: [PhotoKitCandidateAsset]
    )
    case reload
}
```

In `SystemPhotoKitLifecycle.candidateIndexChange(for:)`, keep the retained fetch-result identity and `hasIncrementalChanges` checks, but stop enumerating `fetchResultAfterChanges`. Convert only `insertedObjects` and `changedObjects` to `PhotoKitCandidateAsset`; keep `removedObjects` IDs. Set `fetchedAssets` to `fetchResultAfterChanges` without iterating it.

In `PhotoKitCandidateIndex.enqueueChange`, validate continuity in O(Δ):

```swift
guard indexedGeneration == generation - 1 else { return }
guard removedAssetIDs.allSatisfy({ byAsset[$0] != nil }) else { return }
guard insertedAssets.allSatisfy({ byAsset[$0.identifier] == nil }) else { return }
guard changedAssets.allSatisfy({ byAsset[$0.identifier] != nil }) else { return }
guard Set(insertedAssets.map(\.identifier)).count == insertedAssets.count,
      Set(changedAssets.map(\.identifier)).count == changedAssets.count,
      Set(removedAssetIDs).isDisjoint(with: Set(insertedAssets.map(\.identifier))) else { return }
```

Apply removals, replacements, and insertions under the existing serial queue. Any failed continuity check leaves the state unindexed; the next `candidateSnapshot()` performs a complete replacement rebuild. Do not silently accept an unknown removed/changed ID.

- [ ] **Step 4: Run tests to verify it passes**

```sh
xcrun xctest -XCTest PhotoKitContractTests \
  work/review-fixes-task1-green/Build/Products/Debug/PhotoSyncCoreTests.xctest
```

Expected: all PhotoKit contract tests pass, including 100 incremental own-asset changes; the fake reports one full asset load and 100 bounded deltas.

- [ ] **Step 5: Commit**

```sh
git add Sources/PhotoSyncCore/Photos/PhotoKitGateway.swift Tests/PhotoSyncCoreTests/PhotoKitContractTests.swift
git commit -m "perf: make PhotoKit incremental validation delta bounded"
```

### Task 2: Make snapshot/generation APIs mandatory and cache GUIQA readonly candidates

**Files:**
- Modify: `Sources/PhotoSyncCore/Photos/PhotosGateway.swift`
- Modify: `Sources/PhotoSyncCore/Photos/PhotoKitGateway.swift`
- Modify: `Sources/PhotoSyncCore/Sync/SyncEngine.swift`
- Modify: `Sources/PhotoSyncApp/GUIQAReadOnlyPhotosGateway.swift`
- Modify: `Sources/PhotoSyncApp/GUIQARuntime.swift`
- Test: `Tests/PhotoSyncCoreTests/PhotoKitContractTests.swift`
- Test: `Tests/PhotoSyncCoreTests/GUIQAReadOnlyPhotosGatewayTests.swift`
- Test: `Tests/PhotoSyncCoreTests/EngineTests.swift`
- Test: `Tests/PhotoSyncCoreTests/TestSupport.swift`
- Test: `Tests/Regression/ContinuationRace.swift`

**Interfaces:**
- Consumes: Task 1's delta-only `PhotoKitCandidateIndexChange`.
- Produces: required `PhotosGateway.candidateSnapshot()` and required `PhotosGateway.create(... expectedGeneration:onPlaceholder:)`; `loadCandidates()` and the unbound `create` become convenience methods only.

- [ ] **Step 1: Write the failing tests**

Add these tests before changing the protocol:

1. `testAllPhotosGatewayConformersProvideGenerationBoundSnapshot` uses every fake/GUIQA gateway through `any PhotosGateway`, obtains a snapshot, triggers a generation change, and asserts the old snapshot is rejected before the gateway's create boundary is reached.
2. `testGUIQAReadonlyCachesCandidatesUntilLibraryChange` calls `candidateSnapshot()` for 100 source files through the readonly gateway and asserts the underlying access layer loads once; a simulated change invalidates the cache and the next call loads once more.
3. `testEngineScanUsesOneReadonlySnapshotPerRound` runs a multi-file GUIQA scan and asserts candidate loading is bounded by scan rounds, not media count.

Expected RED: old conformers compile through protocol defaults and GUIQA is enumerated once per call, so the call-count and required-method assertions fail.

- [ ] **Step 2: Run tests to verify they fail**

```sh
xcodebuild -project PhotoSync.xcodeproj -scheme PhotoSync \
  -destination 'platform=macOS' -derivedDataPath work/review-fixes-task2-red \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```

Expected: the new GUIQA call-count tests fail against the uncached readonly adapter.

- [ ] **Step 3: Write minimal implementation**

Change `PhotosGateway` so the required surface is:

```swift
func candidateSnapshot() async throws -> PhotosCandidateSnapshot
func create(
    fileURL: URL,
    kind: MediaKind,
    expectedGeneration: Int,
    onPlaceholder: @escaping @Sendable (String) throws -> Void
) async throws -> String
func reconcile(placeholder: String?) async throws -> ImportEvidence
```

Keep `loadCandidates()` and the unbound `create` only as explicit convenience extensions that call the required methods; remove the default implementation of `candidateSnapshot` that calls full `loadCandidates`.

Update every fake, GUIQA adapter, continuation regression gateway, and test gateway to implement the required methods. No implementation may use a fixed generation token as a silent fallback.

Give `GUIQAReadOnlyPhotosGateway` a serialized cache containing the last `PhotosCandidateSnapshot` and a monotonically increasing generation. Extend `GUIQAReadOnlyPhotosAccessing` with a change/invalidation seam; the real readonly access registers a `PHPhotoLibraryChangeObserver`, while the fake test access calls `invalidate()`. On a change, clear the cached snapshot before returning to the engine. The readonly `create` continues to reject writes, but it must validate the expected generation before reaching that rejection.

Pass one immutable snapshot into each source scan round instead of calling `candidateSnapshot()` inside every file iteration. The drain still obtains a fresh snapshot before each possible real submission; cached GUIQA calls remain O(1), and a PhotoKit change invalidates the cache before the next admission.

- [ ] **Step 4: Run tests to verify it passes**

```sh
xcrun xctest -XCTest PhotoKitContractTests \
  work/review-fixes-task2-green/Build/Products/Debug/PhotoSyncCoreTests.xctest
xcrun xctest -XCTest GUIQAReadOnlyPhotosGatewayTests \
  work/review-fixes-task2-green/Build/Products/Debug/PhotoSyncCoreTests.xctest
xcrun xctest -XCTest EngineTests \
  work/review-fixes-task2-green/Build/Products/Debug/PhotoSyncCoreTests.xctest
```

Expected: protocol dispatch, GUIQA cache invalidation, multi-file scan call counts, generation admission, and existing recovery tests all pass.

- [ ] **Step 5: Commit**

```sh
git add Sources Tests
git commit -m "fix: require cached Photos snapshots across gateways"
```

### Task 3: Add keyset/recovery/migration regression coverage and final validation

**Files:**
- Modify: `Tests/PhotoSyncCoreTests/StoreTests.swift`
- Modify: `Tests/PhotoSyncCoreTests/EngineTests.swift`
- Modify: `.superpowers/sdd/2026-09-19-import-throughput/progress.md`

- [ ] Add a deterministic interleaving test that persists an older pending/importing row before a later row, advances the drain cursor to the later row, returns the older row to pending through `recoverImports`, and proves the next nil-cursor drain imports it exactly once.
- [ ] Add tests for a pending row appended after the cursor, a future `next_retry_at` row, source disable during stamp/create await, and a late successful callback. Assert state, success history, create count, and no duplicate submission.
- [ ] Add fresh-v3, reopened-v3, and migrated-v2 fixtures that query `sqlite_master` for `file_state_created_order`, preserve file state/history, and verify a failed index creation aborts open without replacing the database.
- [ ] Run the required final gate from the exact committed source:

```sh
python3 scripts/validate.py \
  --output-dir "$PWD/work/validation-review-fixes-final" \
  --derived-data "$PWD/work/validation-review-fixes-final-derived"
```

- [ ] Read `validation.json`, `xctest.log`, `tool-tests.log`, and `continuation-race.log`; require nonzero XCTest count, zero failures, 21 Python tool tests, continuation race passed, and unchanged source manifest.
- [ ] Record that real Photos, GUIQA native interaction, and packaging remain separate acceptance boundaries unless explicitly authorized.
- [ ] Commit tests/ledger updates only after the final gate passes.

## Final review and acceptance

- [ ] Run a fresh read-only review against `b237512..HEAD`, explicitly checking the O(Δ) change path, mandatory gateway API, GUIQA call counts, cursor interleavings, and schema migration.
- [ ] Classify real Critical/Important findings before any merge; do not merge or push as part of this plan.
