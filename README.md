# Render 免费容器 EasyTier (No-TUN) + SSH + Caddy 极简部署

本仓库专为 **Render 免费 Web Service** 打造，提供在**无特权（No-TUN / 无 `CAP_NET_ADMIN`）**容器环境下运行最新版 **EasyTier P2P Mesh VPN** 与 **OpenSSH Server** 的完整解决方案。

通过 Caddy 单端口反向代理实现 HTTP 健康检查、EasyTier WebSocket 隧道与紧急 Web 终端分流，使本地机器能够直接与该容器组网，并通过 EasyTier 虚拟 IP 直接 SSH 登录。

---

## 🌟 核心特性

- **极低内存消耗（防 512MB OOM）**：基于 `alpine:latest`，纯 C/Rust/Go 二进制（Caddy + EasyTier + ttyd + OpenSSH），不引入 Python/Node.js 等重型运行时，全套常驻内存仅约 30~50MB。
- **Render 单端口多路复用**：由 Caddy 监听 `$PORT`（默认 10000），Render 边缘网关自动提供 HTTPS/WSS 终结：
  - `GET /health`：存活探针，返回 `OK`，供 UptimeRobot / Cron 定时 Ping 保活及 Render 健康检查。
  - `/et`（或通用 WebSocket 升级）：反向代理至容器内部 `127.0.0.1:11010`，本地 EasyTier 可直接通过 `wss://<render-app>.onrender.com/et` 接入！
  - `/shell/*`：内置 `ttyd` 极轻量终端（带 Basic Auth 认证），提供应急 Web 终端，防止网络配置错误失联。
- **EasyTier smoltcp 用户态网络栈**：使用 `--no-tun --use-smoltcp`，完美解决云原生无特权容器缺乏 `/dev/net/tun` 设备及无法创建虚拟网卡的问题，直接劫持并转发容器内的 SSH 流量。
- **免密与密码认证双支持**：支持注入 `SSH_PUBKEY` 与 `SSH_PASS`，自动配置 `/root/.ssh/authorized_keys`，并支持监听 `22` 与 `2222` 双端口。
- **进程守护**：`entrypoint.sh` 包含完整的故障自愈与退出信号捕获，保证任意子进程意外挂掉时自动拉起。

---

## 🚀 部署到 Render 步骤

### 方式 1：通过 Git 仓库一键部署（推荐）

1. 将当前目录代码推送到你的 GitHub 仓库（例如 `render-easytier`）：
   ```bash
   cd render-easytier
   git init
   git add .
   git commit -m "feat: initial easytier render service"
   git branch -M main
   git remote add origin https://github.com/<your-username>/render-easytier.git
   git push -u origin main
   ```

2. 登录 [Render Dashboard](https://dashboard.render.com/)：
   - 点击 **New +** -> **Web Service**。
   - 选择刚刚推送的 GitHub 仓库。
   - **Environment** 选择 `Docker`。
   - **Instance Type** 选择 `Free`。
   - **Health Check Path** 填写 `/health`。

3. 在 **Environment Variables** 添加以下环境变量（详见配置说明）：

| 环境变量名 | 默认值 / 示例 | 说明 |
| :--- | :--- | :--- |
| `ET_NAME` | `render-mesh` | EasyTier 网络名称（需与本地保持一致） |
| `ET_SECRET` | `MySecret123456` | EasyTier 网络密钥（需与本地保持一致） |
| `ET_IP` | `10.144.144.10` | 容器在虚拟网内的 IP |
| `ET_HOSTNAME` | `render-box` | 节点显示主机名 |
| `ET_PEERS` | *(留空)* | 可选。对端公网节点（若有公共 VPS 可填入） |
| `SSH_PASS` | `YourPassword123` | Root 用户登录密码（留空则自动生成随机密码并在日志中打印） |
| `SSH_PUBKEY` | `ssh-ed25519 AAAAC3...` | 你的公钥内容（`~/.ssh/id_ed25519.pub`，用于免密登录） |
| `TTYD_USER` | `admin` | Web 应急终端登录用户名 |
| `TTYD_PASS` | `YourPassword123` | Web 应急终端登录密码 |

4. 点击 **Create Web Service** 开始构建，等待部署成功后，会获得 Render 分配的域名，例如：`https://easytier-mesh.onrender.com`。

---

## 💻 本地连接与组网使用指南

部署成功后，假设你的 Render 域名为 `easytier-mesh.onrender.com`。

### 1. 本地启动 EasyTier 客户端连入容器

在你的本地 macOS/Linux/Windows 电脑上安装 EasyTier（需具备管理员/root 权限以创建本地 tun 网卡）：

#### 命令方式启动：
```bash
sudo easytier-core \
  --network-name "render-mesh" \
  --network-secret "MySecret123456" \
  --ipv4 "10.144.144.20" \
  --peers "wss://easytier-mesh.onrender.com/et"
```

> **注意：**
> 1. `--network-name` 和 `--network-secret` 必须与 Render 容器环境变量完全一致。
> 2. `--ipv4` 指定本地电脑在虚拟网内的 IP（如 `10.144.144.20`），不可与容器的 `10.144.144.10` 冲突。
> 3. `--peers` 填入 `wss://<你的-render-域名>/et`，Render 的 HTTPS 边缘网关会自动升级 WSS 并反代给容器内的 EasyTier。

#### 检查组网状态：
在另一个终端执行：
```bash
easytier-cli peer
```
若看到 `easytier-mesh.onrender.com` 对应的节点状态为 `Connected`，说明两端已成功建立 P2P/中继链路！

---

### 2. 通过虚拟 IP 登录容器 SSH

组网成功后，直接通过容器的 EasyTier 虚拟 IP (`10.144.144.10`) 登录：

```bash
# 密码登录（端口 22 或 2222 均可）
ssh root@10.144.144.10

# 或指定端口 2222
ssh -p 2222 root@10.144.144.10
```

---

### 3. 配置本地 `~/.ssh/config`（一键免密连接）

在你的本地电脑编辑 `~/.ssh/config`，加入以下配置块：

```sshconfig
Host render-box
    HostName 10.144.144.10
    Port 22
    User root
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 30
    ServerAliveCountMax 3
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
```

保存后，无论何时只要本地 EasyTier 处于运行状态，即可直接在终端敲入：
```bash
ssh render-box
```
秒级进入 Render 容器的 Bash 环境！

---

## 🛠️ 紧急维护通道：Web Terminal (`ttyd`)

如果在特殊网络环境下 EasyTier 无法直连，或者组网参数配置错误导致失联：
1. 用浏览器打开：`https://<your-render-domain>/shell/`
2. 浏览器会弹出 Basic Auth 认证弹窗：
   - 用户名：`admin`（或环境变量 `TTYD_USER`）
   - 密码：环境变量 `TTYD_PASS`（或 `SSH_PASS`）
3. 验证通过后直接在浏览器中打开全功能 Bash Shell，可检查容器内部网络、查看 `easytier-cli` 状态或修改密码。

---

## ⏰ 防止 Render 免费实例休眠（保活）

Render Free Tier 容器在 15 分钟无 HTTP 流量时会自动休眠。可通过配置监控进行存活探测：

1. 注册免费的 [UptimeRobot](https://uptimerobot.com/) 或在已有 VPS 上配置 `crontab`。
2. 监控 URL：`https://<your-render-domain>/health`
3. 监控间隔：每 **10 分钟** 发送一次 HTTP GET 请求。
4. 返回 `200 OK`，实例即可持久保持唤醒状态。
