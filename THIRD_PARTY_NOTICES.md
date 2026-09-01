# 第三方软件声明

Clash Lab Kit 自身脚本使用仓库根目录 `LICENSE` 中的 MIT License。发行包同时
再分发下列未修改的第三方官方 Release 资产；它们不因被放入本项目而改用本项目
许可证。

## 组件、许可证与源码

| 组件 | 打包版本 | 许可证 | 官方项目 | 对应源码 |
| --- | --- | --- | --- | --- |
| Mihomo | v1.19.25 | GPL-3.0-only | <https://github.com/MetaCubeX/mihomo> | <https://github.com/MetaCubeX/mihomo/tree/v1.19.25> |
| subconverter | v0.9.0 | GPL-3.0-only | <https://github.com/tindy2013/subconverter> | <https://github.com/tindy2013/subconverter/tree/v0.9.0> |
| yq | v4.45.1 | MIT | <https://github.com/mikefarah/yq> | <https://github.com/mikefarah/yq/tree/v4.45.1> |
| Zashboard | v2.3.0 `dist.zip` | MIT | <https://github.com/Zephyruso/zashboard> | <https://github.com/Zephyruso/zashboard/tree/v2.3.0> |

许可证全文：

- Mihomo v1.19.25 与 subconverter v0.9.0：`licenses/GPL-3.0-only.txt`
- yq v4.45.1：`licenses/yq-MIT.txt`
- Zashboard v2.3.0：`licenses/zashboard-MIT.txt`

Zashboard 的构建产物还包含其前端依赖和字体资源；这些内容分别受各自许可证
约束。依赖的精确版本可在 Zashboard v2.3.0 源码的 `pnpm-lock.yaml` 和
`package.json` 中查询。本声明不把 Zashboard 的 MIT License 扩展到这些独立依赖。

## GPLv3 对应源码获取

本项目打包的 Mihomo 和 subconverter 二进制与下列官方 Release 资产逐字节一致，
没有本项目补丁。接收二进制的用户可免费获得对应版本的完整上游源码：

- Mihomo v1.19.25：
  <https://github.com/MetaCubeX/mihomo/archive/refs/tags/v1.19.25.tar.gz>
- subconverter v0.9.0：
  <https://github.com/tindy2013/subconverter/archive/refs/tags/v0.9.0.tar.gz>

制作新的 Clash Lab Kit Release 时，应同时保留本文件、许可证全文和上述准确源码
获取信息；若以后修改 GPL 组件或自行构建二进制，还必须提供与所分发二进制完全
对应的修改源码和构建脚本。

## 当前内置资产校验

以下 SHA256 已于 2026-08-29 与对应官方 Release 资产逐字节复核：

```text
8d14bf2edbf2911db004abaed12754d63041eaf87e565af6f1e589883cd93ec8  mihomo-linux-amd64-compatible-v1.19.25.gz
0d2f19c4bf30121feff4ca51a1a5ddd7837ee1f9faaf930ca83533bca51e8b34  mihomo-linux-arm64-v1.19.25.gz
884a6d1168267eba076fcdd5171215bacf98c17948ab526e4cbbdcad5f7a0217  subconverter_linux64.tar.gz
0914688a0af211360271a4eef8a731f09852b47edf094d3758070b660544659e  subconverter_aarch64.tar.gz
290b22a62d0bd3590741557eb6391707a519893d81be975637bc13443140e057  yq_linux_amd64.tar.gz
d49a2cf12a4130a08b6fcbe09163ba3dfdbf6db9ce6b0336d6606ee44505c43d  yq_linux_arm64.tar.gz
4f5c8529621e9eda3b4fd6739ced8b9e0430ff776abdda1ea7ea87f1d55a5ae2  zashboard-v2.3.0-dist.zip
```

本文件是组件归属和再分发信息，不构成法律意见。
