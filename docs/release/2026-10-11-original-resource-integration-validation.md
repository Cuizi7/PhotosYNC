# 原始资源共同解码：实施与验收

2026-10-11。本次产品实现和定向只读验收完成，保留在 `codex/photosync-0.2.0-design`；未合并、推送、打包、安装或启动生产应用。行为冻结为 `cd32bd61a31ac0613e8e90ceb45095cc355b9de0`，之后的收尾仅修改文档。

## 实现与升级

Photos 使用公开 `PHAssetResourceManager.requestData` 流式取得精确绑定的 `.photo` / 编辑当前版 `.fullSizePhoto`，写入私有短期文件；Source 和 Photos URL 均进入同一 `EncodedImageDecoder`，再经相同的方向、sRGB、320×320 stretch 和归一化处理。保持 SSCD Large FP16、ANE 优先/GPU 降级及阈值 0.98。不会自动退回 PhotoKit 320 预览。

共同解码保留最长边 4096 和 512 MiB decoded allowance。编码临时文件单独限制为 512 MiB，同卷保留 128 MiB；最多一个物理 Photos 请求。逻辑取消/超时不能提前释放请求、预算或文件，所有权覆盖实际像素消费；仅清理已知且无活跃 owner、身份吻合的应用遗留项。超限/不支持的表示记录单项读取缺口，存储/空间、网络、授权等全局问题继续等待。

新输入契约 `encoded-resource-imageio-v1`，fingerprintVersion 为 `fb20bd364a329b23363c0178af9b6af33657feedecdd7c7485531bedd43e242c`；policyVersion 为 `33036418cef48b6952faefc73f8d1e6a7a2c3a5115af2735a6464d1601e96e2e`。模型包 SHA256 仍为 `026e7a43660e29c307941a88dbe35b9c14468693333ff926e9b984eef3b4b8d0`，权重、四组 golden 和原标签不变。新发行绑定记录位于 `docs/research/advanced-dedup/original-resource-v1/`，保留旧研究记录的原字节与事实。

Schema v8 保留支持的 v3–v7 数据并撤销旧就绪发布。Photos 旧预览向量必须重新生成；Source 的数值算法未变，仅允许正式旧 FP16 版本 `ec805406fa61e91384e4bf29ae29a52694b80e3755afd7768da80a6db70c9a1d` 的 current/attempt/success 行事务重绑定。向量、stamp、尺寸、状态、成功关系和 unknown 保护不变；事实或向量碰撞不一致则回滚，未知其他版本继续阻断。不能据此重导入已成功照片或扫描停用来源。

实施提交：`08846d2` 共同解码/物理资源所有权，`c0fda23` 输入身份/历史迁移/发行链，`bb9de45` 移除重复发行检查，`cd32bd6` 修正五处旧 schema 测试预期。各任务及跨块独立评审 SPEC/QUALITY 均通过；没有未解决的必修问题。

## 完整自动验收

本机 arm64，macOS 27.0.1、Xcode 27.0 (27A266a)、Swift 6.4。执行统一入口：

```sh
python3 scripts/validate.py \
  --output-dir "$PWD/work/validation-original-resource-product-cd32bd6-20261011-191500" \
  --derived-data "$PWD/work/validation-original-resource-product-cd32bd6-20261011-191500-derived"
```

最终退出 0，`validation.json` 为 passed；301 项源码清单运行前后相同，SHA256 `c9cffb04fb984831311a03b4ee57e56588997c4aee5b6170a6a2c7e68c75ee9c`。清单包含当时待提交的设计文档；当前行为/测试/资源仍是同一冻结版本，后续仅文档收尾，不把新文档树伪称为另一轮实测。

| 验收 | 结果 |
|---|---|
| Debug build-for-testing | 通过 |
| 全量 XCTest | 589 项，2 跳过、0 失败 |
| Python Tools | 96 项通过 |
| 资源/许可/固定 fixture 校验 | 通过 |
| active33 内容/动作回归 | 33/33；14 判重、11 跳过 |
| 请求的 CPU+ANE / CPU+GPU golden | 各 4 项，共 8 项通过；不推断实际处理器分配 |
| continuation 回归 | stamp、advanced-preparation 均通过 |
| Release 规模测试宿主 | 构建及四档规模均通过 |

全量 XCTest 的两项明确跳过为规模测试（另由 canonical 子进程完整执行）及依赖显式私人旧向量的 replay；不是把失败测试排除。受控测试覆盖相同编码输入的张量等价、EXIF、精确资源选择、>64 MiB 自制图片、额度/空间/身份、取消/无 terminal、阻塞 writer、lease 并发释放和历史碰撞/回滚。任务 1 最终聚焦 198 项、任务 2 最终聚焦 102 项均无失败，完整门槛覆盖最后五处测试预期修正。

| 合成表示/成功历史规模 | hot preparation P95 |
|---|---:|
| 100,000 | 255 ms |
| 150,000 | 399 ms |
| 200,000 | 533 ms |
| 200,000 + 100,000 成功历史 | 827 ms |

四档均满足既定 2,000 ms preparation 和变化后就绪预算；最大档完成约 60 秒 idle 及恢复查询，峰值 RSS 约 1.56 GB。它们使用合成持久向量、fake Photos 和受控实际图，不是十万张真实图库原片获取或全库建指纹耗时。

早期失败独立保留：默认沙箱的图标工具失败后，正常授权环境构建成功；随后全量发现五处旧 v7 预期，在 `cd32bd6` 修正并重新完整运行。没有绕过图标、模型、测试、规模或 continuation 门槛。

## 实际产品只读验证

私有原生宿主嵌入本次 canonical 的 Core，通过正常 LaunchServices 启动，调用保留真实 observer 的公开 `PhotoKitGateway.readRepresentation` 及实际 Source/common preprocessing/Core ML 路径。只读取已冻结的 50 组 Source/original 配对，阈值、资源绑定和人工标签固定；没有启动 SyncRuntime、访问生产数据库或调用 Photos 写入 API。

输入 SHA256 `97d212c1e0b25f3601865a0069bba8cd887bb4ca08c5e13e7064e2e56f8f68ab`。最终宿主 SHA256 `db138be26e119154e5d2a0b300049b2fb1d966765ac3fe47aaa2351c1ea1da0a`；嵌入的重新签名 Core SHA256 `9c18a27c2b755c6184b50c35babf097363dadae1dca34f453e8c098ea38a9e01`，与 canonical 可执行段和 20 个资源绑定一致。

| 冻结标签 | 完成/符合预期 | 实际策略动作 | 分数边界 |
|---|---:|---|---:|
| 副本：19 个高置信正例 | 19/19 | 19 skip | 最低 0.984066010 |
| 不同照片：30 高置信 + MB-006 中置信 | 31/31 | 31 importFile | 最高 0.865148246 |

50/50 完整评分，零未评分、零漏判、零配对误跳过；这些是策略的预期动作，没有实际导入。19 正例原始像素面积都相等，本次真实样本未覆盖 importHigherResolution，相关受控动作回归仍单列。50 配对不是全库候选检索或统计置信验收；两轮是同一批样本，独立分母仍为 50。

独立验证复算全部 Float32 点积位、检查张量/向量尺寸、有限值、归一化及哈希；Double cosine 最大差 8.34e-7。18/19 正例的记录编码 SHA/尺寸及模型张量相同，MB-004 编码/张量不同但分数 0.984066010。少量分数超过 1 至 5.96e-7 是 Float32 点积舍入，不影响阈值判定。

每组记录唯一持有的原片暂存目录、编码 stamp/哈希及持有前后快照；50 个确切路径在退出后均不存在。Source 的 device/inode/size/mtime 前后稳定，Photos 描述符原始资源与 revision 绑定稳定。最终图像/字节预算、Source 物理占用和 pending operations 均为 0。暂存编码大小总计 **276,014,339 bytes（263.23 MiB）**，不是网络或 iCloud 传输量；查询已有向量不重复执行此暂存步骤。

原生退出回执 0、terminal drained；启动命令退出 0 独立记录，随后 PID 不存在，RunningBoard 报告 launchd `(0, 0, 0)` 退出及移除进程。没有用启动命令成功代替真实宿主退出。

本次 Debug Core 的热样本阶段计时：Photos 获取/解码准备中位 98.9 ms、P95 310.6 ms；Source metadata/解码及剩余 QA 导出开销中位 482.3 ms、P95 882.4 ms。模型调用阶段包含 QA 张量落盘，Source/Photos 中位约 14 ms，不能称为纯 NN 或 Release 性能。请求/选择 CPU+ANE 的诊断不证明物理 ANE/GPU 使用。

私有宿主先经独立安全审阅：日志失败/取消逃离实际 drain 的 P2 已用受控 RED/GREEN 修正；首轮 50/50 评分正确，但 `/var` 与 `/private/var` 的观察路径差异漏掉 owner，保留为取证不完整。随后以同一 FD/inode 自制复现，修复观察与空集合清理假证据，17 项合成检查及差异复审通过，再以相同 50 组补跑。最终两轮全部分数位和 200 个数值文件相同；首轮不被重新标为完整清理验收。

私有证据根 `work/real-photos-icloud/20261011-original-resource-product/`；最终 attempt 为 `attempt-20261011-cd32bd6-ownerfix-root2/`，独立结果及无个人路径/图片的分数表位于 `verification/final-root2/`。图片、张量、映射、Source 路径和资产身份不进入仓库或发行资源。

## 选择、代价与剩余边界

- 独立编码上限/空间保留限制一份在途原片的暂存量；极大编码文件可能形成可审计读取缺口，不生成旧预览替代向量。
- 精确 Source-only 版本重绑定与 v8 门禁避免成功历史遗漏；未知版本或不一致碰撞保持阻断。门禁不能强制撤销已打开的旧连接，仍依赖既有实例检查。
- 已验证构建、自动门槛及真实固定原始版配对；未对生产数据库执行迁移或重建完整真实索引，未以真实全库查询衡量误跳过率。
- 当前编辑版/撤销、确定网络必需资源的 network-disabled→enabled 路径及断开恢复未在本次真实素材中验证，不能由原片读取成功推断实际 iCloud 字节来源；相关选择/等待/取消有受控测试。
- macOS 13 实机缺口按用户决定保留，Intel 实机验证跳过。GUI、登录/通知、Developer ID/公证、发行签名/DMG、合并/推送及写入 canary 本轮未执行。

计划和契约分别见[实施计划](../superpowers/plans/2026-10-11-original-resource-integration.md)、[共同解码设计](../superpowers/specs/2026-10-11-original-resource-common-decoder-design.md)。详细独立评审、失败和完整命令日志随本次私有实施证据归档；本记录保存可公开的结果与边界。
