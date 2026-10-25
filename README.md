# PhotosYNC

macOS 菜单栏工具：把选定目录中的照片、视频导入系统“照片”图库，避免重复导入，并将精确配对的 HEIC/JPEG + MOV 补齐为原生 Live Photo。

## 使用

1. 安装 App，点击“授权访问照片”，授予系统图库读写权限。
2. 在设置中添加来源目录。启动时及每 30 分钟扫描；可立即扫描、暂停或停用来源。
3. 照片按视觉内容判重，视频按文件名和可靠元数据判重；缺半的 Live Photo 先保存，另一半可用后补齐。

来源始终只读，不移动、转码或自动挂载。普通同步只新增；完整 Live Photo 验证后可删除精确替代的旧单项，标题可能丢失，其余信息无法保全时留旧项。成功导入历史不会因停用来源或删除图库资产而清空。

设置可调整图像处理峰值内存预算，默认 **2 GiB**；它用于解码和视觉判重，不是整个进程的内存上限。

## 安装与数据

支持 macOS 13 及以上，提供 Universal arm64/x86_64 本地包，使用 ad-hoc 签名，未做 Developer ID 签名或公证。发布变更见 [CHANGELOG](CHANGELOG.md)。

运行数据在 `~/Library/Application Support/PhotoSync/`，日志在其 `Logs/` 子目录。升级前正常退出并备份完整目录（含 SQLite WAL/SHM）；数据库升级后不支持直接降级。用旧库覆盖可能丢失新成功证据，导致重复导入。

## 开发

阅读 [AGENTS.md](AGENTS.md) 后，按[文档导航](docs/README.md)选择相关主题。构建、测试和打包命令集中在[验证与发布](docs/testing/README.md)。模型使用 Git LFS，App 运行时不下载模型。
