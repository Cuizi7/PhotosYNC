# 照片判重固定素材

当前回归由 [active-suite.json](active-suite.json) 选择 **33 例 / 42 张图片**：内容预期 14 重复、19 不重；导入动作 11 跳过、22 导入。0.98 是用户选择，回归不证明统计误跳过率；产品规则见[视觉索引](../../../docs/visual-index.md)。

## 读取与修改

- [expected-results.json](expected-results.json) 是内容结论和导入动作的唯一真值；query/candidate 有方向，高分辨率来源可能内容重复但仍需导入。
- [manifest.json](manifest.json)、[human-review.json](human-review.json) 与内容哈希共同绑定冻结底本。底本保留 44 例 / 63 图，供完整性校验；实际模型回归只运行 active suite，不能混报数量。
- 旧 research evaluate/accept 协议不接受新范围；不要改标签让模型通过。新增/修改素材须另建冻结版本并重新审批、绑定哈希。
- 图片不进入 App 资源；日常测试不联网、不读个人图库或 Downloads。素材完整性检查不等于模型验证。

```sh
python3 scripts/dedup-fixtures/validate.py --require-approved
python3 scripts/dedup-fixtures/test_validation.py
python3 -m http.server 8765 --bind 127.0.0.1 --directory Tests/Fixtures/AdvancedDedup
```

浏览本地 `review.html` 查看 33 项及冻结标签。可选重建使用 `scripts/dedup-fixtures/build.py`，需要经核对的原图缓存及固定 Pillow；当前测试直接用仓库固定字节，无须重建。

## 许可与隐私

Commons、自制面板和六张用户提供照片的许可不同，不能统一称 CC0。参见 [LICENSES](LICENSES.md)、[许可核对](LICENSE_REVIEW.md)、[公开测试用途授权](PUBLICATION_AUTHORIZATION.md)；来源与审批原始 JSON 保留不变。

六张用户图仅获准用于本公开仓库的 PhotosYNC 测试；已去除照片 metadata、保留核实的标准色彩配置，尺寸/像素/JPEG 扫描数据未改。该授权不扩展到其他照片或通用再分发。素材生成与审批细节以同目录机器记录为准。
