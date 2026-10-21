# 原生 Live Photo 实现与验收

日期：2026-10-21。开发分支：`codex/native-live-photo-completion`。首次完整验收的行为与测试快照为 `332d002d04ed63085abdb8d6278dc901cc8e29a3`，随后仅文档收尾提交为 `11a9b6a`。用户后续批准的标题清理修订见末节；下方首次验收数据保留为该快照的历史证据。未完成项目不计为通过。

## 实现范围

默认以 HEIC/JPEG 和 MOV 原资源创建一个原生 Live Photo，缺半先保存、后到补齐。源目录只读；文件夹先完成直属枚举与识别再放行。历史 Photos 项目纳入统一身份索引与补齐流程，首次全库识别使用固定完成标记，后续仅续跑未完成或增量工作。新增 schema v11，不清空成功历史。没有新设置、独立清理脚本或生产数据维护。

配对依赖真实身份、角色及资源版本。新建或复用目标后，核对原资源逐字节一致、原生对象可用和音轨保留；受保护信息、编辑或额外资源无法确认时保留旧项。所有创建和清理沿用一个实际提交槽位。未知结果持久阻断新提交，暂停不丢弃晚到的成功证据。

## 当前证据

| 边界 | 结果与范围 |
| --- | --- |
| 构建 | Xcode 27.1（27A9275）、Swift 6.4，macOS 27.0.1；部署目标 macOS 13，Debug arm64/x86_64 `build-for-testing` 通过。 |
| 自动检查 | 首次 canonical（332d002）：847 项 XCTest（2 项明确跳过、0 失败）、102 项 Tools；两种续体竞态均有 GREEN 和预期断言失败的 RED。标题修订的最新结果见末节。 |
| 规模 | full 四档全部通过，原阈值未降低；新增 10 万级混合 Live Photo 身份缓存的分批枚举与中断续跑、索引查询、第二次启动零全扫及预算归零断言。缓存恢复 fixture 不代表读取十万份真实媒体；JSON 明示缓存量与实际本轮识别量。 |
| GUI | 既有菜单/分析详情离屏测试；未启动正常生产 PhotosYNC、未抢占用户前台。原生 PHLivePhotoView 在后台静音完整播放约 3.446 秒；90 帧视频与 132,300 个音频采样解码成功、峰值约 0.1。使用已证明与导入原件逐字节相等的本地自制资源。Photos.app 手动手势/外放听感未验证。 |
| 真实媒体读取 | 经本次用户授权，从本机 Photos 导出一对原生 Live Photo，仅本地、禁止网络。产品 Core 识别两侧相同配对 ID、正确角色、实际 still-image-time 样本及音轨；原生对象非 degraded，尺寸 5712×4284。 |
| 真实 PhotoKit 写入 | 用户批准当前系统图库最多 3 项自制新增及精确清理；3 项创建成功，修复后的 Core 验证原生 Live Photo、身份/静态帧/音轨及原始字节一致，源未变；3 项已收到删除成功回调。最近删除保留，原有资产和生产数据库未改。 |
| 平台/分发 | 本机标准照片授权及精确 QA 删除成功；macOS 13 实机、Intel 实机、iCloud 多设备未验证。未安装、打包、公证、合并或推送。 |

本地证据位于忽略的 `work/livephoto-*-latest.log`、`work/livephoto-task9-review-build.log` 和私有 `work/livephoto-real-validation/`。真实素材、资源 ID、个人图库信息和本地数据库不得提交。导出一对原件的体积约 2.69 MB + 3.56 MB；另一候选本地原件不可用后停止，没有扩大导出范围。

## 已知系统限制

- SDK 27 没有公开标题读取接口。用户随后明确取消标题保护，标题 unknown 不再阻止精确单项清理；原资源、版本和其他受保护信息仍须核实。首次真实 QA 没有执行历史 12 个 MOV 的产品清理，本次也不操作它们。
- 公共 API 没有稳定物理图库 ID。恢复历史工作要求已知资产存在的正向证据；证据缺失时保持待核实，不自动把新图库接到旧任务或重置一次性标记。不能宣称任意图库切换均可自动识别。
- 原资源缺少标识、同 ID 多版本、云端完整候选未知、超预算等可以延迟补齐；已有单项与成功历史保留。源大小/mtime 未变不证明原资源相同。
- 未知删除结果须等待确证，可能需要人工调查；事件 ID 匹配或一次 fetch 缺失均不能自动确认成功。用户拒绝后不反复弹删除提示。

## 可审阅的真实系统测试清单

优先用用户确认的独立测试账号系统图库。若在当前个人系统图库执行，须明确授权具体新增/清理范围；不得切换系统图库、开关 iCloud、访问生产同步数据库或启动会自动扫描的生产 App。

1. 准备独立 QA 目录和 UUID 临时数据库，自制带共享 UUID、实际 timed metadata、可辨方向的画面和音轨的 HEIC/JPEG+MOV。源设为只读，测试前后比较字节；使用测试前缀和持久记录的精确新资产 ID。
2. 最小系统写入范围为三个新增资产：普通照片一个、普通 MOV 一个、由同一对资源创建的完整 Live Photo 一个。只清理这三个有成功回调及精确 ID 证据的 QA 新资产，沿用系统删除确认；不动任何原有资产，不清空最近删除。启用 iCloud 时这些新增/删除可能同步。
3. 核对实际产品 gateway 的成对创建、`.photo/.pairedVideo` 资源、原始文件名、原件逐字节相等、原生对象非 degraded 且尺寸非零，以及视频方向/时长/静态帧位置/音轨。使用原生查看器实际播放画面及声音；加载探针不能代替播放。
4. 在隔离 QA 状态逐项验证：照片先到、MOV 先到、已有普通单项、仅 Photos 两半、已存在完整目标复用、目录顺序、暂停及重启不重跑全扫。每项增量资产数另行记录，不把三项最小探针当作全流程已通过。
5. 清理路径用其他受保护信息已知的自制状态验证；标题未知、不同或仅标题变化不阻止清理，其他信息未知仍保留旧项。测试系统删除确认只针对明确新建 QA 项；拒绝、超时及未知结果保留证据，不盲目重试。
6. 清点新增 ID、资源和 Recently Deleted，记录实际保留项；近期删除残留不称为完整回滚。真实 iCloud 多设备和 macOS 13 实机另列结果。

## 首次自动验收与评审（332d002）

最终命令：

```bash
python3 scripts/validate.py --scale-profile full \
  --output-dir "$PWD/work/validation-livephoto-native-final" \
  --derived-data "$PWD/work/validation-livephoto-native-final-derived"
```

退出码 0。完整无过滤 XCTest 847 项（2 跳过、0 失败）；Tools 102 项通过；full 必需和实际集合均为 100k、150k、200k、200k+100k 历史；两种续体竞态（stamp、advanced-preparation）GREEN 通过且 RED 在指定断言失败。源码 manifest 为 `8a6db149bfdfc99e240ce1462b29acac9815219ae007a83872a824df5add535a`（368 项），验收前后相同，并经主代理再次核对当前文件。报告位于忽略的 `work/validation-livephoto-native-final/validation-report.md`、`validation.json` 及同目录原始日志。

本轮是 macOS 27.0.1 arm64 上的开发验收；不等于发行归档验收或旧系统/Intel 实机通过。后续文档提交没有重新编译或修改行为、测试、harness；保留冻结快照与报告对应关系，不把旧 manifest 写成最终文档快照的 manifest。

完整集成 `deep_reviewer` 已审阅 `773a493..8b631cb`，未确认 Critical，提出六项 Important，未搁置其他判断、无 Minor。主代理逐项加入失败用例并串行修复：

| 发现 | 修复与回归 |
| --- | --- |
| 最终文件守卫抛错误记 unknown | 保留实际未派发证据；`testFinalGuardFilesystemFailureHasDefiniteNoSubmissionEvidence` 覆盖成对创建与清理。 |
| 旧 LP 阻断污染普通文件 attempt | 未派发调用明确 deferral，原请求继续阻断；恢复中的 LP block 和实际 ordinary engine 均有回归。既有两个测试仍检查原始请求的 typed checkpoint/unknown，仅把后来未派发调用的期望改为 deferral。 |
| checked 目标无法复用 | 按精确资源和 revision 复用已确认身份；已盘点目标、连续两批后到副本回归。 |
| 未就绪目录组阻塞无关组 | 每次最多尝试 64 个组，轮转并跳过无进展准入；另一 Photos-only 组可完成。 |
| 相同完整目标不断生成操作 | 将已逐字节确认等价的资源随操作持久化，按版本标记已处理；两个完整目标、多轮 tick 后操作数稳定，不执行 Photos mutation。 |
| Core 默认目录准入放行 | 默认拒绝来源成员；生产 runtime 显式提供当前目录轮次守卫，Photos-only 仍可运行。测试用例需明确注入已就绪准入。 |

自制系统素材及工具保存在忽略的 `work/livephoto-system-qa/`：512×384 HEIC、3 秒动态 MOV、440 Hz 音轨、共同 UUID 及实际 timed still-image-time；源为只读。QA app 的 `--plan` 不调用 Photos；获授权的 `--apply-create` 实际新增三项，`--apply-cleanup` 只接受三项明确成功且未处理过的精确 ID。创建、核验和清理结果见下文。该工具不会加入发行 App。

`c2f559d` 的完整自动验收通过：844 XCTest（2 跳过、0 失败）、102 Tools、四档 full profile 和两种续体竞态 GREEN/预期 RED。该结果是后续真实读取修复前的历史证据，不能代替最后源码的验收。

用户随后明确授权当前系统图库最多三个自制 QA 新增及精确清理，并手动开启 QA 工具的完整照片访问。三个新增均收到成功回调；后续只读验证发现 AVFoundation 无法从无后缀的临时 `encoded` 文件读取 MOV（-11828/-12847）。新增自制视频经真实 raw stream→原生 metadata reader 的测试重现同一错误，证明原来的 metadata fixture 与 fake-resource 检查未覆盖这个组合。

修复从公开 Photos resource UTI 取得容器后缀，在已有受管临时文件创建时使用经过校验的名称，保持原始字节、物理 lease 和总预算，不额外复制媒体。macOS 14 才有公开 MIME override，当前仍保持最低 macOS 13。安全清理同时识别 legacy `encoded` 与验证过的 `encoded.<suffix>`，保留 owner 锁、inode/权限/marker 检查。聚焦 100 项测试通过；原三项 QA 会话继续只读核验，未创建第四项。上述最终 canonical 覆盖了此修复。

此修复已由 deep_reviewer 限定复核 `c2f559d..332d002`，无新增缺陷、无搁置判断。此前完整评审的六项 Important 均已通过失败回归后修复，无遗留 Minor。只读复核没有改变验收快照。

未发布的开发提交不能作为发行包证据；Photos.app 手动播放、外放听感、iCloud 多设备及 macOS 13 实机仍未验证。

## 限定系统验证结果

- 用户明确批准最多三个自制 QA 新增及精确清理，随后手动开启 QA 工具的完整照片访问。首次创建使用 `c2f559d`，普通照片、MOV、原生 Live Photo 各一个，三者均有 placeholder 检查点及明确成功回调；没有第四次创建。新修复未改变成对创建代码。
- 仅读取同一三项的核验宿主，通过标准开发框架搜索路径加载 `332d002` 的 Core；加载路径与 Core 校验值已记录。两份导入原资源与自制输入逐字节一致；原生类型、双角色、配对身份、实际 still-image-time、非零播放对象、时长/方向及音轨通过产品验证。
- 原 QA 宿主按确切成功 ID 删除这三项，`cleanupConfirmed=true`；最近删除保留，不宣称完整回滚。没有删除或编辑任何先存资产，也没有读取或维护生产同步数据库。源字节及准备时的校验值一致。
- 原生 PHLivePhotoView 使用同字节本地原件，后台静音 full 播放开始/结束、约 3.446 秒；视频解码 90 帧、音频 132,300 采样且非零。它验证原生组件与解码，不能替代 Photos.app 手动播放或外放听感测试。
- 只读 tester 已核对上述日志、三项唯一成功 ID 的计数、删除成功、Core 哈希与源码绑定，以及自制源文件的准备哈希。所有 ID、真实导出原件、生成素材和 QA 工具均留在忽略的 `work/`。

本次初始 QA 探针没有只读续验入口，后续补了独立只读宿主。额外读取权限的询问过早：标准 App 方式已有读取授权，错误实际来自 MOV 解析；命令行进程的授权结果不能当作标准 App 无权读取。该诊断过程没有扩大新增上限。

## 改动与目标对应

| 改动范围 | 对应批准目标 |
| --- | --- |
| LivePhotoTypes、MediaRecord、LivePhotoMetadataReader | 精确身份、角色与版本，缺半先保存；不以名称或外观作配对证明。 |
| Schema.sql、SyncStore | v11 事务迁移、一次盘点进度、组预留和恢复证据；保留成功历史。 |
| LivePhotoPhotosGateway、PhotoKitLivePhotoReader、PhotoKitGateway、PhotosResourceReader | 原资源和预算、成对创建、共享唯一 mutation、验证与精确删除边界；包含真实 MOV 暂存识别修复。 |
| LivePhotoInventoryCoordinator、LivePhotoCoordinator、LivePhotoRetirementPolicy、SyncEngine | 全库一次识别及增量、逐目录放行、统一补齐/复用/恢复和保守清理。 |
| SyncRuntime、AppModel、GlobalStatus、SyncStatusPresentation、SyncProgressView | 接入同一运行图、无来源历史任务和暂停、在既有界面展示补齐状态；无新设置。 |
| project.pbxproj 与全部受影响 XCTest | 目标成员关系；身份/存储/资源/并发/runtime/UI/规模行为回归和旧迁移 fixture 兼容。 |
| README、运行时契约、设计/计划与本验收记录 | 当前功能、批准范围、实际证据和限制；旧方案明确标为历史，不作为当前实现依据。 |

没有新增 Python 产品代码或修改 canonical/续体 harness；没有与批准目标无关的顺手修复。完整分支评审及后续限定评审可复用；未再次派发同一完整评审。

## 实施取舍记录

以下为首次实施台账中全部 14 项取舍，按作出顺序保留判断错误时的代价；没有遗留 Minor。其中标题保护已由下节用户明确批准的修订替代。

- Task 1: Ruling: generated Maker Note identifiers use canonical 36-character UUIDs — ImageIO pads shorter test values with periods, unlike QuickTime; keep reader exact rather than trimming identity bytes — cost if wrong: unsupported noncanonical identifiers remain distinct.
- Task 2: Ruling: downlevel migration fixtures retain newer independent tables/columns; v11 DDL is idempotent and validates indexed columns, and the prior-v10 fixture explicitly sets version10 after dropping v10-era nullable columns — preserve historical migration coverage — cost if wrong: malformed downlevel schemas must still fail atomically (collision test).
- Task 3: Ruling: SDK27 has caption/keywords/rating but no public title accessor; title remains unknown, so those old assets fail automatic retirement information checks — obey spec's unknown-is-not-empty rule — cost if wrong: complete Live Photos can coexist with retained old components until user resolves information preservation.
- Task 4: Ruling: typed Live Photo change facts persist at the existing producer/store boundary, before consumers can acknowledge; no second AsyncStream consumer or event framework — avoids competing consumers and loss during replay — cost if wrong: producer persistence failure must keep admission closed.
- Task 4: Ruling: add indexed operation→asset membership and nullable needsDescriptor queue entries within unreleased schema v11 — exact deletion lookup and incremental new asset discovery need durable keys before resource reads — cost if wrong: migration/schema parity and replay race tests must remain green.
- Task 6: Ruling: pass optional original filenames with paired input URLs — Photos resource exports have temporary names, so explicit names preserve originals — cost if wrong: resource naming differs after completion.
- Task 7: Ruling: unknown retirement remains durably blocked until affirmative completion evidence exists — deletion-ID matches and a missing fetch alone cannot prove our mutation succeeded — cost if wrong: manual investigation can be required after a lost deletion callback.
- Task 8: Ruling: construct the shared graph for source-independent history, but prepare/infer the image model only while image sources are eligible — otherwise disabling the final source incorrectly permits model fallback — cost if wrong: model preparation moves to the next eligible runtime tick.
- Task 8: Ruling: keep exact semantic status-copy assertion, check visible OCR by the stable words 来源 and 不可用 — native OCR repeatedly misreads 录 as 求 in an unchanged offline row — cost if wrong: OCR alone would not catch a middle-word typo, covered by the exact semantic assertion. This test-only adjustment unblocks required UI acceptance; no production copy changed.
- Task 9: Ruling: opaque Photos tokens cannot identify the physical library — restore historical operations only after positive known-asset evidence; inconclusive switching/permission continuity waits without resetting the once marker — cost if wrong: a legitimate library with all anchors removed needs investigation before historical work resumes.
- Task 9: Ruling: add nullable handled-target/resource-discovery/frozen-source stamps within unreleased v11 — later exact copies can reuse a known complete target without duplicate creation, unchanged ambiguity cannot create operations forever, and Photos-input selection cannot bypass source invalidation — cost if wrong: migration parity and reservation tests must reject malformed or stale state.
- Task 9: Ruling: scale evidence covers 100k cached observations plus sparse pending identification, not 100k physical metadata reads — preserves original scale thresholds while exercising indexed mixed Live Photo state and once-resume behavior — cost if wrong: full uncached identification throughput is not characterized.
- Task 9: Ruling: preserve the public UTI container suffix on the owned Photos temporary file — public AVURLAsset MIME override requires macOS14, so typed temp names retain macOS13 compatibility without copying/transcoding source media or changing budget — cost if wrong: unsupported containers remain pending; ownership validation/cleanup must handle both legacy encoded and validated encoded.<suffix> without deleting unknown files.
- Task 9: Ruling: task-done audits the freshly completed same-332d002 canonical reports, all hashes and current source manifest instead of launching a duplicate full suite — AGENTS forbids repeating successful unchanged-snapshot verification, and final documentation is applied only after this audit — cost if wrong: stale or altered evidence could misstate completion, so audit requires exact HEAD, unchanged complete manifest, all four scale reports,847 XCTest/102 Tools and both GREEN/expected-RED continuation results.

## 标题清理规则修订（2026-10-21）

用户明确决定不保护标题：已有完整 Live Photo 且原资源及其余清理条件核实后，删除精确配对的旧单项，不因标题未知、缺失、不同或仅标题快照变化而保留。旧标题可能丢失。原资源、配对身份、资源 revision、其他受保护信息、暂停及未知提交等守卫不变；不新增设置或数据库迁移。

改动仅涉及三处清理判断（信息已知、旧项与目标比较、清理前快照比较）、对应回归和本功能说明文档。保留标题字段及已有持久化形状；旧的未知信息保留、后到资源复用和暂停测试改用说明字段未知，继续保护其他信息。

RED：原策略在标题组合的 13 个断言失败；实际协调器的标题未知场景不能删除，标题单独变化场景抛 `libraryChanged`。最小修复后，策略 5、资源 11、协调器 26、共享提交 15，共 57 项聚焦测试通过。日志位于忽略的 `work/livephoto-title-{red-tests,red-coordinator,green-tests}.log`。

本修订采用 canonical `--scale-profile release`：没有改变资源读取、预算、索引、候选查询、模型或规模 harness；仍运行完整无过滤 XCTest、Tools、20 万表示＋10 万历史的最大混合规模及两种续体竞态。最初四档 full 结果仍只属于 `332d002`。

本轮不再新增或删除任何真实 Photos 项目，不读取生产数据库，也不启动正常生产 PhotosYNC。首次三个 QA 的系统授权、读写和清理证据保持原有范围，不称为本次新跑的真实清理测试。

修订只改变清理决策，不重置此前开发版已经持久化为无限期等待的操作。Photos 编辑若同时改变修改日期，资源 revision 仍会变化并按原规则延迟；标题内容本身不参与准入。此功能尚未发布或安装。

限定深度评审覆盖 `11a9b6a..c300952` 的三处生产判断、回归及文档，未发现缺陷或阻断项。未变的整分支行为复用此前完整评审；本次实际 PhotoKit/iCloud 和平台验收没有重跑，不作为新增系统验证结果。

最后行为与测试快照为 `c300952c16828a3d0f52307bfd3c4509dfbd3ab4`。最终完整命令：

```bash
python3 scripts/validate.py --scale-profile release \
  --output-dir "$PWD/work/validation-livephoto-title-retry" \
  --derived-data "$PWD/work/validation-livephoto-title-retry-derived"
```

退出码 0，报告 `Status: passed`：849 项无过滤 XCTest（2 跳过、0 失败）、102 项 Tools、required/executed 均恰为 `200000-history-100000`，两种续体竞态 GREEN 成功且 RED 在预期断言失败。368 项源码清单在验收前、验收后及主代理独立核对时一致，SHA-256 为 `8be423fedb933414d2a9f77bc83ad27350ebe919abe3bae8d6fcad8ce5296d63`。同目录 `validation-report.md`、`validation.json` 和原始日志保留。其后的提交仅更新本验证文档，不改变已验收的行为、测试或 harness。

本次保留了完整的性能调查记录，没有改动代码、测试数据或 2,000 ms 阈值来取得通过：

| 运行 | 热准备 p95 | 增量准备 p95 | 实际结论 |
| --- | --- | --- | --- |
| 首轮完整验收 `work/validation-livephoto-title-final` | 2,113.97 ms | 2,506.84 ms | 有效性能超限，exit 1；此前 849 项 XCTest 通过，Tools 和竞态尚未执行。 |
| 单次定向复测 `work/validation-livephoto-title-scale-diagnostic-20261021` | 1,049.10 ms | 1,457.74 ms | 同一 Release 包和门槛通过，仅为诊断结果，不能代替 canonical。增量 p99 为 4,321.87 ms。 |
| 上述最终完整重跑 `work/validation-livephoto-title-retry` | 814.84 ms | 891.51 ms | 全部 canonical 门槛通过。 |

失败集中在既有图片准备/SQLite 查询的尾延迟；静态调用链确认三处标题判断都只在 `LivePhotoCoordinator.readyToRetire`，该规模测量路径不实例化此协调器。定向复测采集的 26 份主机采样显示 CPU 空闲率 28.39%–75.98%、负载变化，未观察到多个 xctest 重叠；这些数据不能确定单次耗时的具体原因。超限未稳定复现，根因仍不确定，不称为已修复的性能问题。首轮失败、复测和最终完整结果均未覆盖或混用。
