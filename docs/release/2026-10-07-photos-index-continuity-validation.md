# Photos 索引连续性修复验收（2026-10-07）

实现与自动验收完成。冻结源码 `387194748dd7e59aa3738a495ce272703d874be0`，tree `af3627f4004663fcddda832d883afddd7b9d04b7`。独立审阅和修复差异复核均为 SPEC PASS / QUALITY APPROVED，无开放中高严重性发现。此后收口仅修改文档，不把文档提交冒充新的行为测试。

本记录证明开发源码、合成/项目 fixture 回归和私有只读宿主离线准备通过；不证明修复后真实 Photos/iCloud 已验收，也不是合并、发行或安装记录。设计见 [spec §4](../superpowers/specs/2026-09-28-photosync-0.2.0-advanced-dedup-design.md)，步骤见 [实施计划](../superpowers/plans/2026-10-07-photos-index-continuity.md)。

## 已实现的行为

- 清单核对、表示有效性和判重发布分离。普通 full-reconcile 不清空全库向量；未知表示保留字节但不可参与决定。相关变化替换相应任务，无关向量、发行身份和有效退避保留。
- UUID 清单会话固定枚举基线，通知序号与覆盖终点独立；分页期间的完整已分类变化可以归并。未知或未覆盖的新变化仍阻止旧终点发布。
- schema v6 在原 SQLite 增加轻量 `photos_content_change` 义务记录及 `fingerprint_task.issuance_revision`。大集合有界落盘，129 个已知变化不污染其余资产；进程 UUID 防止重启后混用同值通知序号。迁移保留向量、成功/unknown 记录，撤销旧 publication。
- metadata 中性更新需真实 producer 证据及输入事实校验，不能凭同尺寸/同修改时间复用。不可变发行修订让无关在途结果可接纳，已替换/删除/编辑后的晚结果不能复活旧表示。
- 完整核对推进 checkpoint 前回放旧持久 token 至拟保存 token 的变化，覆盖通知尚未送达的编辑及启动回放间隙；局部增量保留旧 checkpoint。历史覆盖期间撤销旧提交许可，最终 ready 才恢复新许可。
- 生产诊断接入现有日志，区分通知、分类/回退原因、清单终点及保留/待验证数量。SSCD、0.98、FP16/ANE/GPU、SQLite 精确评分、来源只读及原生布局不变。

产品提交：`5b40b85` 基础实现，`6775a70` 检查点/未知恢复修复，`7be38a3` 持久历史覆盖与提交屏障。`3871947` 仅补合成规模网关的新协议适配和非法区间拒绝测试，未修改产品默认保守行为或验收断言。

## 构建与自动验收

```sh
python3 scripts/validate.py \
  --output-dir "$PWD/work/validation-index-continuity-20261007-r3" \
  --derived-data "$PWD/work/validation-index-continuity-20261007-r3-derived"
xcodebuild -project PhotoSync.xcodeproj -scheme PhotoSync -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$PWD/work/release-index-continuity-20261007-derived" \
  CODE_SIGNING_ALLOWED=NO build
```

两个命令均 exit 0，使用正常 Xcode 系统服务访问权限。canonical `validation.json.status=passed`；273 项源码清单前后 SHA256 均为 `9bfb8a1450e80da462bc1f90e5e6703b77f20c32e0ad8a8060df15a0273a0ec6`。

| 检查 | 结果 |
| --- | --- |
| 完整 XCTest | 545 项，2 项显式跳过，0 失败；63.576 秒 |
| Tools | 94/94 通过 |
| 实际模型 | 33 例通过；两种允许配置各 4 组 golden 通过 |
| 规模 | 100k、150k、200k、200k＋100k 成功历史四档全部通过 |
| 受控竞态 | stamp、advanced-preparation 均通过 GREEN/预期 RED 检查 |
| 正常 Universal Release | App/Core 均 arm64＋x86_64，每切片最低 macOS 13.0；图标及模型/策略/自检资源存在 |

两项跳过分别是由 canonical 独立进程执行的规模用例，以及需要显式本地输入的可选旧向量回放，不替代实际 33 例。配置名不是实际硬件调度跟踪。本轮没有再做独立统计校准。

回归覆盖真实 gateway 注入层＋临时 SQLite：十万行单项更新、129 项分批、持续分页中性/成员变化、未知恢复＋非空中性变化/删除、延迟详情与在途结果、重试期限、发行修订、v5 迁移保留、部分批次重开、跨进程义务、检查点前/后的延迟通知、历史写失败和旧提交许可失效。它们不调用真实照片库。

保留失败证据：`work/validation-index-continuity-20261007/` 是受限环境 actool 服务失败；`...-r2/` 执行 544 项后因合成 `P9ScalePhotos` 未适配历史覆盖接口而失败。修复保留原就绪/计数/性能断言；只有 `...-r3/` 是最终完整通过。详细独立报告在 `.superpowers/sdd/2026-10-07-photos-index-continuity/`，正常构建日志为 `work/release-index-continuity-20261007-build.log`。

## 受控性能与限制

临时 SQLite、合成向量和 fake Photos；实际本地 fixture 图像走当前产品模型。每档准备/查询 20 个样本，增删改各 5 个样本。它不是十万张真实 Photos 或 iCloud 端到端时延。

| 表示数 / 成功历史 | 查询 P95 ms | 缓存准备 P95 ms | 新图准备 P95 ms | 增删改最大 P95 ms | 峰值 RSS GiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| 100k / 0 | 167.49 | 228.47 | 269.15 | 129.68 | 0.64 |
| 150k / 0 | 251.28 | 354.42 | 420.29 | 221.13 | 0.87 |
| 200k / 0 | 335.23 | 459.43 | 522.35 | 289.85 | 1.61 |
| 200k / 100k | 620.64 | 753.29 | 819.38 | 314.53 | 1.70 |

各档纯查询零行写；有证据的无变化完整核对零推理、零表示/任务/排除行写，只有 3 条全局状态行写及 50,772 VFS 逻辑写字节。完整核对仍为 O(N)，本次分别 1.38/2.07/2.77/3.18 秒，不能与单张增量准备预算混为一谈。最大档单次 50 MP JPEG 为 933.47 ms，61 MP 16-bit PNG 为 2,415.28 ms；这些是单次大图观测，不能称全部请求都在两秒内。

最大档闲置 60.021 秒后 footprint 78,235,688 字节（74.61 MiB），RSS 1,400,930,304 字节（1.30 GiB）；磁盘读写/逻辑写/page-in 累计计数未增加，恢复查询 634.83 ms。footprint 和 RSS 不是同一个口径，这也不是单个常驻生产 App 或冷盘实验。VFS/process 计数不直接代表 SSD NAND 损耗或 Photos/iCloud 流量。

原始 scale 报告沿用旧 `CPU-only` scope 描述；源码的实际构造器仍调用 `p12ProductModel` 加载已验证 FP16 策略。此既有描述错误保留并在这里更正，原始测量文件不改写。

## 私有只读宿主与剩余系统验证

新目录 `work/real-photos-icloud/20261007-continuity-resume/` 的宿主源码经独立差异审查；从精确 Git archive 和新 DerivedData 构建，未取旧 framework。源码 SHA256 `d9ade31d461f20bb3f0b358ffa272b69becc05061a707e01b3a8316cd5dcc185`，recipe `eb83bca175fdba7d65b6ec0dad66b3acca6adea12fbb463b4c0a955a6cf5a0b5`。38 项归档/资源/二进制哈希和私有 ad-hoc 签名核验通过；Core 签名前后字节差异另用同源重签副本比对。宿主及嵌入 Core 为 arm64，不能拿它代替上述正常 Universal 包。

离线 self-test exit 0：17 个协议接口明确转发、history 参数/真假/类型错误传播、两个 create 入口在 delegate 前拒绝且调用数为零、预算、物理租约、nonce 控制、重试、私有 SQLite/图像流水线均通过。旧 fake 的会话失效模拟及合成历史证明按新契约适配；真实路径和安全限制未放宽。报告 `offline-build-report.md`、`host-review.md` 和失败尝试均留在新私有目录，旧实测目录未覆盖。READY 不存在，没有执行真实读取。

此前真实图库只读尝试的原始记录仍见 [MobileBackup 实测](../research/advanced-dedup/2026-10-07-mobilebackup-real-photos-audit.md)。修复后的 Photos/iCloud 收敛、MobileBackup 判重扫描/盲审、完整原生交互仍待后续系统阶段；本轮未访问真实图库、待同步目录或生产数据库。macOS 13 实机缺口保留，Intel 执行按用户要求不做。未合并、推送、安装、打包发行、Developer ID 签名或公证；私有 QA ad-hoc 签名不等于发行验收。
