# render-engine

[English Documentation](README.md) | 简体中文文档

[![Render Deploy](https://img.shields.io/badge/Render-Free%20Web%20Service-46E3B7?logo=render&logoColor=white)](https://render.com)
[![Alpine Linux](https://img.shields.io/badge/Alpine-3.20%20(x86__64)-0D597F?logo=alpinelinux&logoColor=white)](https://alpinelinux.org/)
[![EasyTier](https://img.shields.io/badge/EasyTier-v2.6.4%20(smoltcp)-FF6600)](https://github.com/EasyTier/EasyTier)
[![Caddy](https://img.shields.io/badge/Caddy-v2%20Multiplexing-1F88C0?logo=caddy&logoColor=white)](https://caddyserver.com/)
[![tmux](https://img.shields.io/badge/tmux-Session%20Persistence-1BB954?logo=tmux&logoColor=white)](https://github.com/tmux/tmux)
[![sing-box](https://img.shields.io/badge/sing--box-v1.10+-E53E3E)](https://github.com/SagerNet/sing-box)
[![Memory Footprint](https://img.shields.io/badge/RAM-~50MB%20Footprint-blueviolet)](#关键技术实现)
[![LINUX DO](https://img.shields.io/badge/Thanks-LINUX%20DO-f59e0b?logo=discourse&logoColor=white)](https://linux.do)

该项目针对 Render.com 免费 Docker Web Service 运行环境设计。系统在单个容器内整合了 EasyTier 用户态网格组网（smoltcp）、OpenSSH 服务端、基于 ttyd 与 tmux 的持久化 Web 终端以及 sing-box 代理组件，由 Caddy 负责前端单端口流量分流。

容器运行在无 `/dev/net/tun` 设备与无 `CAP_NET_ADMIN` 特权的受限环境中。全套组件常驻内存介于 30 MB 至 50 MB 之间，远低于平台 512 MB 的内存上限。

---

## 架构设计

Render 免费实例仅开放由环境变量 `$PORT`（默认 10000）指定的单一公网端口。Caddy 负责终结外部 HTTPS 与 WebSocket 流量，依据请求路径将流量转发至容器内部的对应组件：

```text
                           Render Public Edge (Port 10000 / HTTPS / WSS)
                                                 │
                                    ┌────────────┴────────────┐
                                    │   Caddy Multiplexer     │
                                    └────────────┬────────────┘
                                                 │
       ┌──────────────────────┬──────────────────┴──────────────────┬──────────────────────┐
       ▼                      ▼                                     ▼                      ▼
Path: /health          Path: /et (WS)                        Path: /shell/          Path: /vless-ws
┌──────────────┐   ┌────────────────────────┐            ┌──────────────────────┐   ┌──────────────────────┐
│ 存活探针     │   │ EasyTier WebSocket     │            │ ttyd Web 终端        │   │ sing-box VLESS       │
│ (200 OK)     │   │ (127.0.0.1:11010)      │            │ (Basic 身份认证)     │   │ (127.0.0.1:20808)    │
└──────────────┘   └──────────┬─────────────┘            └──────────┬───────────┘   └──────────────────────┘
                              │                                     │
                    [smoltcp 网络协议栈]                    [tmux 会话: main]
                              │                                     │
               ┌──────────────┴──────────────┐             ┌────────┴───────────┐
               ▼                             ▼             ▼                    ▼
   OpenSSH (端口 22 / 2222)       sing-box (端口 10808)   连接中断状态保持      鼠标滚轮滑动 /
   (公钥与密码双认证)             (虚拟网内混合代理)      重连自动恢复上下文    50,000 行历史缓冲
```

### 路由分发规划

| 请求路径 | 传输协议 | 后端目标 | 功能说明 |
| :--- | :--- | :--- | :--- |
| `/health` | HTTP GET | 内存直接响应（`200 OK`） | 供平台健康检查及外部保活探针探测 |
| `/et` | WebSocket | `127.0.0.1:11010` | EasyTier 对等节点传输通道 |
| `/shell/` | WebSocket / HTTP | `127.0.0.1:7681` | 受 Basic 认证保护的 ttyd 浏览器终端 |
| `/vless-ws` | WebSocket | `127.0.0.1:20808` | sing-box VLESS WebSocket 入站代理 |

---

## 关键技术实现

### 1. EasyTier 用户态虚拟网格（smoltcp）
受限容器不具备 Linux 网络管理特权（`CAP_NET_ADMIN`），也无法创建 `/dev/net/tun` 设备。EasyTier 通过 `--no-tun --use-smoltcp` 参数启动，在用户空间运行独立的 TCP/IP 协议栈来处理虚拟 IP 数据包的路由与封装。防火墙白名单放行 TCP 22、2222 以及 10808 端口，允许网格内部成员直接互通。

### 2. Web 终端断联防护与会话持久化
穿透 Cloudflare CDN 与 AWS Application Load Balancer 时，空闲超过 60 至 100 秒的 WebSocket 会被边缘网关阻断。如果直接运行原生 shell 二进制，一旦客户端连接中断，子进程会立即收到挂断信号退出。

针对上述两类边界问题，系统实施了针对性处理：
- **WebSocket 传输保活**：`ttyd` 启动时指定 `--ping-interval 15`，每隔 15 秒主动下发心跳帧，规避边缘网关因空闲掐断连接。Caddy 对 `/shell*` 路由配置 `flush_interval -1`，关闭反向代理的缓冲区延迟。
- **tmux 会话守护**：`ttyd` 执行 `/usr/local/bin/ttyd-session` 包装脚本，以 `tmux -f /root/.tmux.conf new-session -A -s main /bin/bash` 命令启动终端。网络掉线或页面刷新只会注销 tmux 客户端，后台运行的会话不受影响。新连接接入后会自动 Attach 回已有的 `main` 会话，保持原有的工作目录、变量与正在运行的进程。
- **终端环境配置**：`/root/.tmux.conf` 启用了鼠标模式（`mouse on`），设置 50,000 行历史缓冲区（`history-limit 50000`），开启最新客户端窗口大小自适应（`window-size latest`），并将按键延迟设为零（`escape-time 0`）。
- **容器平滑停机**：容器接收到停机信号时，退出函数先调用 `tmux kill-server` 关闭终端会话树，使前后台程序在底层收到强制终结信号前完成数据刷盘。

### 3. 多租户容器磁盘指标对齐
在 Kubernetes 共享主机集群上，无特权容器执行 `statvfs("/")` 会直接返回宿主机底层物理盘的全局容量与已用量（通常显示已用 300+ GB，占用率达 80% 至 90%），造成监控系统误报磁盘满载。

系统内置的 `komari-agent` 检测到 `AGENT_FORCE_DISK_TOTAL` 或 `KOMARI_FORCE_DISK_TOTAL` 环境变量后，会把磁盘总容量锁定为预设虚拟配额（默认 5 GiB），并以 apparent size 方式计算根目录真实体积，在遍历目录时自动跳过 `/proc`、`/sys`、`/dev`、`/run` 伪文件系统。

### 4. 进程看门狗与熔断机制
`/entrypoint.sh` 作为 PID 1 运行，执行间隔为 5 秒的存活检测循环。看门狗直接维护各项服务的独立进程标识（`PID_CADDY`、`PID_ET`、`PID_SSHD`、`PID_TTYD`、`PID_KOMARI`、`PID_SINGBOX`），避免失效标识堆积。当单一服务的连续异常重启次数达到 5 次时，系统触发熔断终止容器，防止死循环耗尽资源。

---

## 环境变量配置

在 Render 控制台的 Environment 面板中设置以下参数：

| 变量名 | 默认值 / 推荐示例 | 功能说明 |
| :--- | :--- | :--- |
| `PORT` | `10000` | 平台分配的容器公网端口 |
| `ET_NAME` | `render-mesh` | EasyTier 虚拟网名称 |
| `ET_SECRET` | *(随机值)* | EasyTier 虚拟网通信密钥 |
| `ET_IP` | `10.144.144.90` | 容器在虚拟网内的静态 IPv4 地址 |
| `ET_HOSTNAME` | `render-box` | 在虚拟网对等列表中的主机名 |
| `ET_PEERS` | *(可选)* | 外部 EasyTier 对等节点地址列表，以逗号分隔 |
| `SSH_PUBKEY` | *(可选)* | 写入 `/root/.ssh/authorized_keys` 的 OpenSSH 公钥 |
| `SSH_PASS` | *(随机18位)* | OpenSSH root 用户登录密码 |
| `TTYD_USER` | `admin` | `/shell/` 终端 Basic 认证用户名 |
| `TTYD_PASS` | 同 `SSH_PASS` | `/shell/` 终端 Basic 认证密码 |
| `KOMARI_TOKEN` | *(可选)* | MangoHub 节点认证凭据 |
| `KOMARI_FORCE_DISK_TOTAL` | `5368709120` | 磁盘虚拟配额字节数（示例为 5 GiB） |
| `SINGBOX_UUID` | `1da2cc31-2c34-4b0b-b83c-ce3f7b8e6c2c` | sing-box VLESS 鉴权用户标识 |

---

## 部署流程

1. 把本仓库代码推送至 GitHub 个人仓库。
2. 登录 [Render Dashboard](https://dashboard.render.com/)，新建一个 **Web Service**。
3. 关联该仓库并设定参数：
   - **Environment**：`Docker`
   - **Instance Type**：`Free`
   - **Health Check Path**：`/health`
4. 在 **Environment Variables** 区域填入业务参数。
5. 点击部署，等待构建完成即可获取平台分配的域名（例如 `https://your-service.onrender.com`）。

---

## 客户端连接指南

### 1. 运行 EasyTier 客户端接入网格
在客户端主机上启动 EasyTier 进程，把对端地址指向容器的 WebSocket 路径：

```bash
sudo easytier-core \
  --network-name "render-mesh" \
  --network-secret "YourSecretKey" \
  --ipv4 "10.144.144.100" \
  --peers "wss://your-service.onrender.com/et"
```

查询网格连通状态：
```bash
easytier-cli peer
```

### 2. 通过虚拟 IP 登录 SSH
在网格打通后，直接指定容器虚拟 IP 发起连接：

```bash
ssh root@10.144.144.90
# 或连接备用端口 2222
ssh -p 2222 root@10.144.144.90
```

编辑客户端 `~/.ssh/config` 文件添加快捷配置：

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

保存后直接执行快捷连接命令：
```bash
ssh render-box
```

### 3. 使用 Web 终端排障
当本地网络环境无法直连虚拟网时，使用浏览器访问应急终端：
1. 打开 `https://your-service.onrender.com/shell/`。
2. 输入 `TTYD_USER` 与 `TTYD_PASS` 设定的认证凭据。
3. 终端会自动载入 `tmux` 会话。如果在终端内键入 `exit`，系统会销毁当前会话，下次刷新将重新生成干净的初始环境。

### 4. 实例防休眠配置
Render 免费实例在连续 15 分钟无入站 HTTP 请求后会进入休眠状态。在外部监控系统（如 Uptime Kuma 或定时任务）中添加 HTTP GET 监控项，以 5 至 10 分钟为周期请求 `https://your-service.onrender.com/health`，保持实例持续响应。

### 5. 代理服务接入
- **虚拟网内混合代理**：容器在 `0.0.0.0:10808` 监听 HTTP 与 SOCKS5 流量。网格内节点可把代理地址指向 `socks5://10.144.144.90:10808` 或 `http://10.144.144.90:10808`。
- **公网 VLESS 入站**：客户端通过 `wss://your-service.onrender.com/vless-ws` 接入，流量经 Caddy 解密后投递至 `127.0.0.1:20808`。

---

## 致谢

鸣谢 [LINUX DO](https://linux.do) 社区在技术交流与方案探讨中的支持与反馈。

---

## 许可证

本项目依据 [MIT License](LICENSE) 条款开源发布。
