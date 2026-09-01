# Clash Lab Kit

![GitHub License](https://img.shields.io/github/license/Spectator-Zh/clash-lab-kit)
![GitHub top language](https://img.shields.io/github/languages/top/Spectator-Zh/clash-lab-kit)

开箱即用的 Linux 命令行 Mihomo 工具包，**面向实验室多用户服务器环境和端侧设备**。
无需 root 权限即可完成安装、端口避让、节点管理与 Web 控制，解决旧内核不兼容
AnyTLS 等新协议，以及纯命令行环境中配置和维护代理较繁琐的问题。

Forked from [SaladDay/clash-for-lab](https://github.com/SaladDay/clash-for-lab).

## 主要增强

- **开箱即用**：放入 `config.yaml` 或传入订阅链接，执行 `bash install.sh` 即可安装并启动。
- **适合多用户服务器**：完全运行在用户目录，自动避让端口冲突，不干扰其他用户或系统级代理。
- **兼容新协议**：内置较新的 Mihomo 内核，并支持独立更新内核，解决旧内核不兼容 AnyTLS 等协议的问题。
- **终端代理刷新**：重启后如端口变化，执行 `clash proxy reload` 即可让当前终端使用最新端口。
- **Mihomo 内核更新**：使用 `clash mihomo version|update` 查看版本或安全更新内核。
- **安全安装与更新**：配置校验通过后再原子写入，失败自动回滚，不留下半套安装。
- **节点测速**：`clash refresh [关键词]` 可测试全部节点或按地区筛选并切换到最快节点。
- **受限节点清理**：按名称快速删除香港节点，或逐个检测并删除 OpenAI 明确标记为地区受限的节点。
- **Web 控制台**：内置 Zashboard，通过 `clash ui` 查看访问地址。

## 文档索引

- [快速开始](#快速开始)
  - [环境要求](#环境要求)
  - [安装步骤](#安装步骤)
  - [校验 Release 安装包](#校验-release-安装包)
  - [验证安装](#验证安装)
- [最近更新](#最近更新)
  - [2026-09-01：v1.2.0 程序版本与当前终端自动刷新](#2026-09-01v120-程序版本与当前终端自动刷新)
  - [2026-08-29：安全默认值与更新可靠性](#2026-08-29安全默认值与更新可靠性)
  - [2026-08-27：双架构与订阅兼容性](#2026-08-27双架构与订阅兼容性)
  - [2026-08-21：修复用户级自动启动](#2026-08-21修复用户级自动启动)
  - [2026-08-20：受限节点清理](#2026-08-20受限节点清理)
- [使用教程](#使用教程)
  - [基本命令](#1-基本命令)
  - [使用流程](#2-使用流程)
  - [高级功能](#3-高级功能)
- [项目结构](#项目结构)
  - [安装后目录结构](#安装后目录结构)
- [常见问题](#常见问题)

## 快速开始

### 环境要求

- **用户权限**：普通用户权限即可，**无需 sudo 或 root**
- **系统架构**：Linux x86_64/AMD64、Linux aarch64/ARM64（包括 NVIDIA Jetson Orin）
- **Shell 支持**：`bash`（Ubuntu 默认 Shell；不支持 Zsh）
- **配置来源**：需要有效的 Clash/Mihomo `config.yaml` 或订阅链接

### 安装步骤

#### 1. 克隆项目

```bash
git clone https://github.com/Spectator-Zh/clash-lab-kit.git
cd clash-lab-kit
```
- 如果已经配置 GitHub SSH 密钥，也可以使用：

```bash
git clone git@github.com:Spectator-Zh/clash-lab-kit.git
cd clash-lab-kit
```

#### 2. 添加配置并安装

方式 A：把 Clash/Mihomo YAML 配置放到仓库根目录：

```bash
cp /path/to/your/config.yaml ./config.yaml
bash install.sh
```

方式 B：直接把订阅链接传给安装脚本：

```bash
bash install.sh 'https://your-subscription-url'
```

> 默认会安装在`~/tools/mihomo/`目录下

* [ ] TODO: 自定义安装路径

安装过程中会：

- 在任何安装操作前检查仓库根目录 `config.yaml` 或命令行订阅链接
- 自动检测系统架构
- 准备适配的 Mihomo 内核、配置依赖数据和 Zashboard
- 在独立暂存目录中校验原始配置与最终运行配置
- 校验通过后一次性写入正式安装目录；失败时自动清理本次暂存文件
- 配置用户环境变量
- 设置命令行别名
- 检测并分配可用端口
- 安装成功后询问是否开启登录自动启动；启用后，该用户登录并建立 systemd 用户会话时会自动启动 Clash
- 使用订阅链接安装时，安装成功后询问是否开启每2天一次的订阅自动更新

两个可选功能在非交互安装中默认不启用，不会阻塞自动化脚本。可分别使用
`clash autostart off` 和 `clash update auto off` 随时关闭。

不传订阅链接时，安装器只读取仓库根目录的 `config.yaml`；文件不存在或为空会
立即退出，不会创建安装目录或下载组件。安装脚本校验成功后会安装到
`~/tools/mihomo/` 并自动启动。仓库根目录的
`config.yaml`、订阅地址、运行配置和缓存文件均被 Git 忽略，不会被提交。

### 校验 Release 安装包

每个 Release 安装包都配有一个同名的 `.sha256` 文件。只需下载当前架构的
安装包及其校验文件，然后执行标准校验命令，不需要添加 `--ignore-missing`。

```bash
sha256sum -c *.sha256
```

无论只下载一个架构还是同时下载两个架构，这条命令都会校验当前目录已有的安装包。
输出文件名后跟 `OK` 表示校验通过；如果显示 `FAILED`，请重新下载安装包。

### 验证安装

```bash
# 检查服务状态
clash status

# 测试网络连接
curl -I https://www.google.com
```

## 最近更新

后续新增功能会按日期记录在这里，最新内容置顶。

### 2026-09-01：v1.2.0 程序版本与当前终端自动刷新

- 运行环境统一为 Bash，不再修改 `.zshrc` 或支持 Zsh。
- 当前最新正式 Release 和本次程序版本均为 `v1.2.0`。后续小改动默认以最新
  正式 Release 的 `vX.Y` 为基线递增第三位；当前基线的小版本依次为
  `v1.2.1`、`v1.2.2`。例如最新正式 Release 变为 `v1.3.0` 后，小版本从
  `v1.3.1` 开始。
- 新增 `clash version`，显示已安装的 Clash Lab Kit 程序版本和程序更新对应的
  Git 提交。
- `clash update app` 会显示更新前后版本、短提交号，以及本次跨越版本中与用户
  有关的变化。
- 程序更新完成后直接刷新当前终端中的 Clash 命令，无需重开终端或加载整个
  `.bashrc`。

### 2026-08-29：安全默认值与更新可靠性

- Web 管理端默认仅监听 `127.0.0.1`，远程访问使用 SSH 端口转发。
- 配置、Mixin 和订阅更新先生成并校验临时文件，成功后再替换；重启失败会恢复
  三份原配置和原运行状态，普通命令失败不会退出当前终端。
- 同一用户的写操作使用 `flock` 互斥，避免人工操作与自动更新同时覆盖配置、
  PID 或备份；状态查询等只读命令不受影响。
- Mihomo 新内核替换后如果重启失败，会自动恢复旧内核并再次启动。
- 安装后从任意目录执行更新，下载缓存都固定使用 `~/tools/mihomo/cache/`；程序
  和内核更新增加总超时，网络不通时能够正常失败和回退。

### 2026-08-27：双架构与订阅兼容性

- **NVIDIA Jetson Orin 支持**：新增 Linux aarch64/ARM64 完整资源与安装流程，
  已在 NVIDIA Jetson Orin 的 **Ubuntu 20.04.6 LTS**（`5.10.216-tegra`）上完成
  从零安装、订阅更新、systemd、端口避让、代理出站和错误架构拒绝等实机验收。
- **订阅 UA 更新与兼容性增强**：订阅请求的 User-Agent 已由
  `clash-verge/v2.0.4` 更新为 `clash-verge/v2.5.2`，**增加对部分根据客户端 UA
  分流的订阅链接的支持**；下载仍保留直连、当前代理和 wget 回退链路。
- 安装器会按宿主机架构精确选择 Mihomo、yq 和 subconverter，不再使用可能
  混入其他架构资源的通配符。
- ARM64 内置 Mihomo v1.19.25、yq v4.45.1 和 subconverter v0.9.0；
  AMD64 与 ARM64 使用相同的组件版本。
- 发布安装目录前会校验全部压缩资源的 SHA256，并检查三个可执行文件的
  ELF 架构；资源损坏或架构不匹配时安装会失败并清理暂存目录。
- 安装预检和运行阶段失败都会返回非零退出码，便于 SSH 与自动化脚本可靠判断结果。
- WSL2 中若 Windows 主机端口经 localhost 转发到 Linux、但未显示在 Linux
  `ss`/`netstat` 中，安装器也能识别冲突并自动避让。
- Release 为每个架构的安装包分别提供同名 `.sha256`，只下载当前架构时也能
  直接使用 `sha256sum -c *.sha256` 完成校验。

### 2026-08-21：修复用户级自动启动

- 修复 systemd 用户服务在非交互式 Shell 中找不到 `clash`、导致
  `clash autostart on` 启用成功但服务启动失败的问题。
- 自动启动仍使用完整的 `clash on` 流程，会检测端口占用并自动分配空闲端口；
  同一用户打开多个终端不会重复启动 Mihomo。
- 使用 `clash autostart on|off|status` 开启、关闭或查看登录后自动启动。
  端口变化后，已打开的终端执行 `clash proxy reload` 即可刷新代理环境。

### 2026-08-20：受限节点清理

- `clash hkkill`：删除名称包含 `香港` 或 `hongkong`（忽略大小写）的节点。
- `clash hkkillpro`：隔离测试全部节点，只删除 OpenAI API 明确返回
  `unsupported_country_region_territory` 的节点。

两条命令都会先备份配置并校验删除后的结果。`hkkillpro` 不会删除 Cloudflare
challenge、普通 403、超时或 TLS/DNS 测试异常的节点。

## 使用教程

### 1. 基本命令

执行 `clash help` 查看所有可用命令：

```bash
$ clash help
Usage:
    clash COMMAND  [OPTION]
    mihomo COMMAND [OPTION]
    mihomoctl COMMAND [OPTION]

Commands:
    on                      开启代理
    off                     关闭代理
    refresh [关键词]        测速并选择最快节点，可按名称筛选
    restart                 重启代理服务
    autostart [on|off|status] 登录后自动启动
    proxy    [reload|off|status]   刷新、关闭或查看当前终端代理
    port     [status|auto|set]     代理端口模式设置
    ui                      Web 控制台地址
    status                  进程运行状态
    tun      [on|off|status]       Tun 模式 (需要权限)
    lan      [on|off|status]       局域网访问控制
    mixin    [-e|-r]        Mixin 配置文件
    secret   [SECRET]       Web 控制台密钥
    subscribe [URL]         设置或查看订阅地址
    update   [auto|log]     更新订阅配置；auto 支持 on|off|status
    update   app            更新 Clash Lab Kit 程序
    update   kernel         更新 Mihomo 内核
    mihomo   [version|update] 管理 mihomo 内核


```

### 2. 使用流程

#### 2.1 启动代理服务

```bash
clash on
```

#### 2.2 检查运行状态

```bash
# 查看详细状态信息
clash status

# 输出示例：
# 😼 订阅地址: https://your-subscription-url
# 😼 mihomo 进程状态: 运行中
# 😼 进程 PID: 276368
# 😼 运行时间: 04:53
# 😼 配置文件: /home/fangjingluo/tools/mihomo/runtime.yaml
# 😼 日志文件: /home/fangjingluo/tools/mihomo/logs/mihomo.log
# 😼 代理端口: 54016
# 😼 管理端口: 19090
# 😼 DNS端口: 15353
# 😼 系统代理：开启
# http_proxy： http://127.0.0.1:54016
# socks_proxy：socks5h://127.0.0.1:54016
```

#### 2.3 停止代理服务

```bash
# 停止代理
clash off
```

### 3. 高级功能

#### 3.1 固定代理端口

```bash
# 查看当前端口模式和端口
clash port status

# 固定代理端口（如 7890），如遇冲突可按提示重新输入或切换自动
clash port set 7890

# 切换回自动分配端口
clash port auto
```

#### 3.2 节点测速与自动选择

```bash
# 测试全部节点并选择本轮最快节点
clash refresh

# 只测试名称包含指定关键词的节点
clash refresh 日本
clash refresh 新加坡
clash refresh IPLC
```

自动选择组默认每 5 分钟通过 `https://chatgpt.com/cdn-cgi/trace` 主动检测节点。
关键词筛选只影响本次手动选择；后续定时检测仍会在全部节点中自动选择。

#### 3.3 局域网访问控制

```bash
# 查看局域网访问状态
clash lan status

# 开启局域网访问（允许其他设备通过本机 IP 使用代理）
clash lan on

# 关闭局域网访问（仅本机可用）
clash lan off
```

开启局域网访问后，其他设备可以通过以下方式使用代理：
- HTTP 代理：`http://your-server-ip:port`
- SOCKS5 代理：`socks5://your-server-ip:port`

> 注意：开启局域网访问前，请确保网络环境安全，避免代理被未授权使用。

#### 3.4 Web 控制台管理

```bash
# 查看控制台地址
clash ui

# 设置访问密钥（推荐）
clash secret your-password

# 查看当前密钥
clash secret
```

Web 管理端默认只监听 `127.0.0.1`，不会直接暴露给局域网或公网。远程服务器上
推荐使用 SSH 端口转发；如果 `clash ui` 显示的管理端口不是 `9090`，请将下面
命令中的两个 `9090` 都替换成实际端口：

```bash
ssh -L 9090:127.0.0.1:9090 user@server
```

保持 SSH 连接后，在本地浏览器打开 `http://127.0.0.1:9090/ui/`。`clash lan on`
只控制代理端口的局域网访问，不会开放 Web 管理端。

通过浏览器访问 Web 控制台可以：

- 切换代理节点
- 查看实时日志
- 监控流量统计
- 测试节点延迟

#### 3.5 登录后自动启动

```bash
# 开启、关闭或查看用户级自动启动
clash autostart on
clash autostart off
clash autostart status
```

该功能由 `clash` 自动创建并管理用户级 systemd 服务，不需要直接执行
`systemctl`。默认在用户登录并建立 systemd 用户会话后启动；不会擅自开启
linger，因此用户从未登录时不会仅因服务器开机而启动。

#### 3.6 更新 Clash Lab Kit 程序

```bash
# 查看 Clash Lab Kit 程序版本和当前提交
clash version

# 更新控制脚本和自动启动服务定义
clash update app

# 更新 Mihomo 内核
clash update kernel
```

程序更新会保留现有订阅、节点配置、Mixin、端口设置和日志，并在写入前备份
当前文件。更新器通过 `resources/app-manifest.yaml` 获取版本化文件清单和 SHA256，
全部下载、校验成功后才事务化替换；Mixin 只更新默认模板副本，不覆盖用户配置。
旧版本尚无 manifest 时仍兼容原来的脚本更新。GitHub 查询和文件下载都有明确
总超时，避免直连不通时无限等待。
manifest 同时记录程序版本和用户可感知的变更。更新完成后会显示更新前后的版本、
提交和本次跨越版本中与用户有关的变化，并直接重新加载 Clash 自身脚本；当前终端
无需重新打开，也无需执行 `source ~/.bashrc`。

#### 3.7 订阅管理

```bash
# 设置订阅地址
clash subscribe https://your-subscription-url

# 查看当前订阅
clash subscribe

# 更新订阅配置
clash update

# 开启自动更新（每2天；不带 on 也兼容）
clash update auto on

# 关闭或查看自动更新状态
clash update auto off
clash update auto status

# TODO:自定义更新天数
```

建议优先使用 HTTPS 订阅地址。HTTP 订阅没有 TLS 保护，订阅令牌和返回配置可能
在传输链路上被读取或篡改；目前为了兼容仅提供 HTTP 的订阅服务仍允许使用。

#### 3.8 Mihomo 内核管理

```bash
# 查看当前 mihomo 版本
clash mihomo version

# 更新到最新稳定版 mihomo
clash mihomo update

# 更新到指定版本
clash mihomo update v1.19.25

# 使用自定义下载地址更新（ARM64 示例；URL 必须与当前 CPU 架构匹配）
clash mihomo update --url https://github.com/MetaCubeX/mihomo/releases/download/v1.19.25/mihomo-linux-arm64-v1.19.25.gz
```

#### 3.9 高级配置

```bash
# 编辑自定义配置（Mixin）
clash mixin -e

# 查看运行时配置
clash mixin -r

# 启用 TUN 模式（需要管理员预先授予 TUN/网络管理权限）
clash tun on
```

普通 HTTP/SOCKS 代理模式不需要 root。TUN 模式需要访问 `/dev/net/tun`，并修改
路由或策略规则，因此通常需要 root；也可以由管理员预先为 Mihomo 配置
`CAP_NET_ADMIN` 等必要能力后，再由普通用户启动。未完成这些权限配置时，
`clash tun on` 可能写入配置，但 Mihomo 无法正常建立 TUN 接口。

**Mixin 配置说明**：

Mixin 配置文件（`~/tools/mihomo/mixin.yaml`）用于自定义代理行为，支持以下配置：

- `mode`：代理模式（rule/global/direct），默认为 rule 模式
- `allow-lan`：局域网访问控制
- `external-controller`：Web 控制台监听地址
- 其他高级配置项

通过 Web UI 修改的配置（如代理模式）会在下次启动时保留。

## 项目结构

```
clash-lab-kit/
├── install.sh              # 主安装脚本
├── uninstall.sh            # 卸载脚本
├── THIRD_PARTY_NOTICES.md  # 第三方组件、许可证与对应源码
├── third_party/licenses/   # 随安装包分发的第三方许可证全文
├── script/                 # 脚本目录
│   ├── clashctl.sh         # 主控制脚本
│   └── common.sh           # 公共函数库
├── resources/              # 资源文件
│   ├── mixin.yaml          # Mixin 配置模板
│   ├── app-manifest.yaml   # 程序更新文件、版本和 SHA256 清单
│   ├── Country.mmdb        # GeoIP 数据库
│   └── zip/                # AMD64/ARM64 预下载资源压缩包
└── README.md               # 项目文档
```

### 安装后目录结构

```
~/tools/mihomo/             # 用户安装目录
├── bin/                    # 二进制文件
│   ├── mihomo              # 主程序
│   ├── subconverter        # 订阅转换工具
│   └── yq                  # YAML 处理工具
├── config/                 # 配置文件
│   ├── mihomo.pid          # 进程 ID 文件
│   ├── ports.conf          # 实际监听端口状态
│   ├── port.pref           # 端口模式偏好
│   └── operation.lock      # 同一用户写操作互斥锁
├── cache/                  # 安装后的程序与内核下载缓存
├── config.yaml             # 主配置文件
├── mixin.yaml              # 自定义配置
├── runtime.yaml            # 运行时合并配置
├── Country.mmdb            # GeoIP 数据库
├── GeoSite.dat             # GeoSite 数据库（按需下载）
├── url                     # 当前订阅来源
├── logs/                   # 日志文件
│   └── mihomo.log          # 运行日志
└── ui/                     # Web 控制台文件
```

## 常见问题

### Q: SSH 断开或终端窗口关闭后，代理服务会停止吗？

A: 不会。服务使用 `nohup` 在后台运行，SSH 断开或终端窗口关闭后仍会保持运行。

### Q: 如何在多个终端会话中使用代理？

A: 同一用户的所有终端共用一个 Mihomo 进程，但每个终端分别保存自己的代理
环境变量。新打开的终端会自动读取当前端口；如果执行 `clash restart` 后端口
发生变化，已经打开的终端仍可能保留旧端口，需要在这些终端中执行
`clash proxy reload` 刷新代理环境，或重新打开终端。

### Q: 如何更换订阅地址？

A: 使用 `clash subscribe new-url` 命令更换，系统会自动更新配置。

### Q: 可以只升级内核，不动其他配置吗？

A: 可以。执行 `clash mihomo update` 即可只替换 `~/tools/mihomo/bin/mihomo`，保留现有配置、订阅和运行目录结构。
更新器会自动选择当前架构；传入 `--url` 时也会在替换前拒绝错误架构的内核。

### Q: Web 控制台无法访问怎么办？

A: Web 管理端默认只监听本机，远程访问时按照“Web 控制台管理”章节建立 SSH
端口转发，再打开本地地址。管理端口默认是 9090，但发生端口冲突时会自动变化，
请以 `clash ui` 或 `clash status` 显示的实际端口为准。

### Q: 如何让局域网内其他设备使用代理？

A: 使用 `clash lan on` 开启局域网访问，然后在其他设备上配置代理服务器为本机 IP 和代理端口。可以通过 `clash status` 查看当前代理端口。

### Q: 代理模式在重启后会恢复默认吗？

A: 不会。通过 Web UI 修改的代理模式（rule/global/direct）会自动保存到 mixin 配置中，重启后会保留您的设置。

## 致谢

感谢 [SaladDay/clash-for-lab](https://github.com/SaladDay/clash-for-lab) 及其上游项目的工作。

### 相关项目

- [mihomo](https://github.com/MetaCubeX/mihomo) - 高性能的代理内核
- [subconverter](https://github.com/tindy2013/subconverter) - 订阅转换工具
- [zashboard](https://github.com/Zephyruso/zashboard) - Web 控制台界面
- [yq](https://github.com/mikefarah/yq) - YAML 处理工具

### 参考资料

- [Clash 知识库](https://clash.wiki/)
- [Clash 配置文档](https://clash.wiki/configuration/configuration-reference.html)
- [mihomo 文档](https://wiki.metacubex.one/)

## 许可证

Clash Lab Kit 自身脚本采用仓库根目录 [MIT License](LICENSE)。内置的 Mihomo、
subconverter、yq 和 Zashboard 保留各自上游许可证；版本、官方来源、对应源码、
许可证全文位置和内置资产 SHA256 见
[第三方软件声明](THIRD_PARTY_NOTICES.md)。其中当前打包的 Mihomo v1.19.25 与
subconverter v0.9.0 使用 GPLv3，yq v4.45.1 与 Zashboard v2.3.0 使用 MIT。

## 免责声明

1. 编写本项目主要目的为学习和研究 Shell 编程，不得将本项目中任何内容用于违反国家/地区/组织等的法律法规或相关规定的其他用途。
2. 本项目保留随时对免责声明进行补充或更改的权利，直接或间接使用本项目内容的个人或组织，视为接受本项目的特别声明。
3. 使用本项目所产生的任何后果由使用者自行承担。

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=Spectator-Zh/clash-lab-kit&type=Date)](https://www.star-history.com/#Spectator-Zh/clash-lab-kit&Date)
