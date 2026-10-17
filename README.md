# 🚀 Render Engine: EasyTier (No-TUN) + SSH + Caddy + Web Terminal + sing-box 极简云原生运维引擎

[![Render Deploy](https://img.shields.io/badge/Render-Free%20Web%20Service-46E3B7?logo=render&logoColor=white)](https://render.com)
[![Alpine Linux](https://img.shields.io/badge/Alpine-3.20%20(x86__64)-0D597F?logo=alpinelinux&logoColor=white)](https://alpinelinux.org/)
[![EasyTier](https://img.shields.io/badge/EasyTier-v2.6.4%20(smoltcp)-FF6600)](https://github.com/EasyTier/EasyTier)
[![Caddy](https://img.shields.io/badge/Caddy-v2%20Multiplexing-1F88C0?logo=caddy&logoColor=white)](https://caddyserver.com/)
[![tmux](https://img.shields.io/badge/tmux-Session%20Persistence-1BB954?logo=tmux&logoColor=white)](https://github.com/tmux/tmux)
[![sing-box](https://img.shields.io/badge/sing--box-v1.10+-E53E3E)](https://github.com/SagerNet/sing-box)
[![Memory Footprint](https://img.shields.io/badge/RAM-~50MB%20Footprint-blueviolet)](#-核心特性)

专为 **Render.com 免费 Docker Web Service** 量身定制的生产级运维底座。在**完全无宿主特权（No-TUN / 无 `/dev/net/tun` / 无 `CAP_NET_ADMIN`）**的受限容器内，实现了全套自愈网络与远程运维能力：

- 零公网端口暴露风险，通过 **EasyTier 用户态协议栈（smoltcp）** 接入个人 P2P 虚拟网格；
- 通过 **Caddy 单公网端口 4 路复用** 分流存活探针、组网隧道、持久化 Web 终端及双向代理；
- 内置 **tmux 会话守护** 与 **WebSocket 边缘保活**，彻底根治 Web Terminal 频繁断线与重连丢失上下文痛点；
- 内置 **MangoHub (Komari) 真实磁盘配额对齐**，彻底解决 Render 多租户宿主机 OverlayFS 386GB 虚假告警；
- 全套二进制常驻内存仅 **30~50MB**，轻松驾驭 Render 512MB 免费配额，稳定运行不 OOM。

---

## 📐 架构拓扑与多路复用设计

Render 免费实例仅允许监听一个外部端口（环境变量 `$PORT`，默认 10000），由 Caddy 统一接管流量并分流：

```text
                           Render Public Edge (Port 10000 / HTTPS / WSS)
                                                 │
                                    ┌────────────┴────────────┐
                                    │   Caddy Web Multiplexer │
                                    └────────────┬────────────┘
                                                 │
       ┌──────────────────────┬──────────────────┴──────────────────┬──────────────────────┐
       ▼                      ▼                                     ▼                      ▼
Path: /health          Path: /et (WS)                        Path: /shell/          Path: /vless-ws
┌──────────────┐   ┌────────────────────────┐            ┌──────────────────────┐   ┌──────────────────────┐
│ 200 OK 探活  │   │ EasyTier WebSocket 监听│            │ ttyd 应急 Web 终端   │   │ sing-box VLESS 入站  │
│ (防 15m 休眠)│   │ (127.0.0.1:11010)      │            │ (BasicAuth 认证保护) │   │ (127.0.0.1:20808)    │
└──────────────┘   └──────────┬─────────────┘            └──────────┬───────────┘   └──────────────────────┘
                              │                                     │
                    [smoltcp 用户态网络栈]                  [tmux 持久化守护会话]
                              │                                     │
               ┌──────────────┴──────────────┐             ┌────────┴───────────┐
               ▼                             ▼             ▼                    ▼
   OpenSSH (Port 22 / 2222)       sing-box (Port 10808)  [main] 会话保持   鼠标滚轮 / 5万行历史
   (密钥 / 密码双认证)            (虚拟网内 Mixed 代理)    (断网/刷新无缝接回) (最新视窗动态拉伸)
```

---

## 🌟 核心特性与生产级治理

### 1. 极致轻量化（防 512MB OOM）
基于 Alpine Linux 精简环境，所有核心组件（Caddy、EasyTier、ttyd、sing-box、komari-agent）均为纯 C / Rust / Go 原生二进制构建，移除 Python/Node 等重型解释器，**整机全套常驻内存仅约 30MB ~ 50MB**，留出 90% 冗余给用户日常运维。

### 2. EasyTier 用户态 smoltcp 虚拟网格
无视云平台容器对 `/dev/net/tun` 设备的限制，启用 `--no-tun --use-smoltcp`，在用户空间模拟轻量级 TCP/IP 协议栈，不仅能够与本地 PC、VPS 形成低延迟加密 Mesh 局域网，还能直接通过虚拟 IP 穿透登录容器 SSH。

### 3. 持久化 Web Shell（ttyd + tmux 原生保活）
针对浏览器 Web 终端的典型痛点进行了全面深度治理：
- **心跳防掐断**：ttyd 开启 `--ping-interval 15`，Caddy 开启 `flush_interval -1`，主动双向保活，彻底阻断 Cloudflare（100s 阈值）和 AWS ALB（60~100s 阈值）因空闲无按键直接切断连接的问题；
- **重连零丢失**：接入 `/usr/local/bin/ttyd-session`，自动 Attach 到名为 `main` 的后台常驻 tmux 会话；无论网络颠簸、页面刷新还是电脑休眠唤醒，重新进入即刻无缝恢复之前的全量输出与运行中的程序；
- **全屏交互升级**：预置 `set -g mouse on`，无需快捷键即可用**鼠标滚轮/触控板上下回滚**查看多达 50,000 行历史，自带暗黑简约状态栏；
- **优雅停机保护**：容器退出或平滑重启时显式下发 `tmux kill-server`，通知所有前后台任务优雅收尾，杜绝直接遭遇底层 `SIGKILL` 导致数据受损。

### 4. 磁盘配额对齐（告别 386GB 虚假爆满告警）
在无特权 Docker 容器中，`df -h /` 与探针调用 `statvfs` 会直接穿透汇报底层 Kubernetes 宿主机节点的真实 OverlayFS 物理状态（显示 386.9 GB / 82%~91% 满）。本仓库深度适配 MangoHub，通过 `AGENT_FORCE_DISK_TOTAL` 注入 5GB 虚拟配额，并以内核跳过虚拟文件系统遍历计算真实占用（实际仅 ~190MB），监控面板彻底恢复绿灯。

### 5. 生产级单例看门狗与熔断器
`entrypoint.sh` 具备 5 秒级健康巡视与自动拉活机制，重构了独立命名 PID 实时生命周期追踪，杜绝长期运行下僵死 PID 累积，并为各关键服务配备最大连续崩溃熔断上限（`MAX_FAILURES=5`），杜绝死循环日志爆炸。

---

## 📋 环境变量速查表

在 Render Web Service 控制台的 **Environment** 中配置以下变量即可灵活开箱即用：

| 变量名 | 默认值 / 推荐示例 | 说明 |
| :--- | :--- | :--- |
| **`PORT`** | `10000` | Render 外部公网端口（平台自动注入，无需手动改动） |
| **`ET_NAME`** | `mango-mesh` | EasyTier 虚拟网名称（需与组网节点保持一致） |
| **`ET_SECRET`** | `YourSecretKey@2026` | EasyTier 虚拟网加密密钥（需与组网节点保持一致） |
| **`ET_IP`** | `10.144.144.90` | 容器在虚拟网内的静态 IPv4 地址 |
| **`ET_HOSTNAME`** | `render-box` | 节点在虚拟网格中显示的主机名 |
| **`ET_PEERS`** | `tcp://vps.example.com:11010` | *(可选)* 初始对等节点或中继 Hub 地址（逗号/空格分隔） |
| **`SSH_PUBKEY`** | `ssh-ed25519 AAAAC3...` | *(推荐)* 管理机公钥内容（写入 `authorized_keys`，实现免密直连） |
| **`SSH_PASS`** | `YourSecurePassword` | *(可选)* root 密码（留空则容器启动时自动生成 18 位随机强密码） |
| **`TTYD_USER`** | `admin` | 应急 Web 终端 BasicAuth 用户名 |
| **`TTYD_PASS`** | `YourSecurePassword` | 应急 Web 终端 BasicAuth 密码（留空则默认回退复用 `SSH_PASS`） |
| **`KOMARI_TOKEN`** | `3WU9ZdCTvrDeUW8w...` | *(可选)* MangoHub (Komari) 监控探针节点 Token |
| **`KOMARI_FORCE_DISK_TOTAL`** | `5368709120` (5GB) | 覆盖探针汇报的磁盘配额，开启容器真实体积度量 |
| **`SINGBOX_UUID`** | `1da2cc31-2c34-4b0b...` | sing-box VLESS 入站鉴权 UUID |

---

## 🚀 极速部署指南（3 分钟上线）

### 步骤 1：Fork 或推送代码到个人 GitHub
```bash
git clone https://github.com/dengyie/render-engine.git
cd render-engine
# 推送到您自己的私有或公开 GitHub 仓库
```

### 步骤 2：在 Render 一键创建 Web Service
1. 登录 [Render Dashboard](https://dashboard.render.com/)，点击 **New +** $\to$ **Web Service**；
2. 选择你推送的 GitHub 仓库；
3. 关键配置项选择：
   - **Environment**：`Docker`
   - **Region**：按需选择（如 `Oregon`, `Singapore`, `Frankfurt`）
   - **Instance Type**：`Free`
   - **Health Check Path**：填入 `/health`（关键，用于探活检测）
4. 在 **Environment Variables** 添加你的自定义变量（如 `ET_NAME`, `ET_SECRET`, `SSH_PUBKEY` 等）；
5. 点击 **Create Web Service**，等待 2 分钟构建完成即可！

---

## 💻 客户端组网与连接指引

部署完成后，Render 会分配一个公共域名，例如 `https://render-engine.onrender.com`。

### 1. 本地客户端通过 WSS 穿透加入网格
在你的本地电脑（macOS / Linux / Windows）运行官方 EasyTier：
```bash
sudo easytier-core \
  --network-name "mango-mesh" \
  --network-secret "YourSecretKey@2026" \
  --ipv4 "10.144.144.100" \
  --peers "wss://render-engine.onrender.com/et"
```
> **提示**：通过 `easytier-cli peer` 查看状态，看到对应节点处于 `Connected` 状态即表示 P2P / 穿透打通。

### 2. 通过虚拟 IP 直接 SSH 登录
```bash
# 密钥直接登录
ssh root@10.144.144.90

# 或指定端口 2222 登录
ssh -p 2222 root@10.144.144.90
```

### 3. 配置本地 `~/.ssh/config`（一键秒连）
在本地终端配置文件中添加：
```sshconfig
Host render-box
    HostName 10.144.144.90
    Port 22
    User root
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 15
    ServerAliveCountMax 3
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
```
配置完成后，直接敲 `ssh render-box` 即可秒级进入容器终端！

---

## 🛠️ 应急 Web Terminal 访问与技巧

当外部网络环境封锁了 EasyTier 或公网环境临时需要排障时：
1. 访问：`https://<your-app>.onrender.com/shell/`
2. 输入 BasicAuth 账号密码（`TTYD_USER` / `TTYD_PASS`）；
3. **日常体验操作**：
   - **滚轮翻页**：直接用鼠标向上滑动触控板即可查看前序几万行历史；
   - **断线恢复**：即便关闭浏览器标签页或网络中断，重新打开瞬间回到上次的会话与任务；
   - **多窗口管理**：支持 tmux 原生快捷键，`Ctrl-b c` 新建窗口，`Ctrl-b n`/`p` 切换窗口，或直接鼠标点击底部状态栏切换；
   - **彻底重置**：若需完全销毁并重建环境，仅需在终端输入 `exit` 退出 tmux session，下次刷新即可自动获得崭新的终端会话。

---

## ⏰ 防止 Render 免费实例休眠（Keepalive）

Render 免费实例在无外部 HTTP 流量 **15 分钟** 后会自动休眠。可通过配置第三方拨测保持 7x24 小时常驻在线：
1. 注册免费的 [Uptime Kuma](https://github.com/louislam/uptime-kuma) 或 [UptimeRobot](https://uptimerobot.com/)；
2. 添加 HTTP(S) 监控项：
   - 目标 URL：`https://<your-app>.onrender.com/health`
   - 监控频率：每 **5 ~ 10 分钟** 发送一次 GET 请求；
   - 判定状态：返回 `200 OK` 即可；
3. 实例将永久保持活跃状态，随叫随到。

---

## 🌐 代理服务配置 (sing-box)

1. **虚拟网内 Mixed 代理（HTTP / SOCKS5）**：
   - 监听：`0.0.0.0:10808`（白名单放行）
   - 组网节点可直接将代理设置为 `socks5://10.144.144.90:10808` 或 `http://10.144.144.90:10808`，直接借由容器出口访问外网。
2. **公网 VLESS-WebSocket 接入**：
   - 监听路径：`wss://<your-app>.onrender.com/vless-ws`
   - 传输层：Caddy 负责 TLS 终结与反向代理，配合预设 `SINGBOX_UUID` 实现远程加密访问。

---

## 📄 开源许可证

本项目基于 [MIT License](LICENSE) 开源发布，欢迎自由 Star、Fork 与二次定制！
