# render-engine

English | [简体中文](README.zh-CN.md)

[![Render Deploy](https://img.shields.io/badge/Render-Free%20Web%20Service-46E3B7?logo=render&logoColor=white)](https://render.com)
[![Alpine Linux](https://img.shields.io/badge/Alpine-3.20%20(x86__64)-0D597F?logo=alpinelinux&logoColor=white)](https://alpinelinux.org/)
[![EasyTier](https://img.shields.io/badge/EasyTier-v2.6.4%20(smoltcp)-FF6600)](https://github.com/EasyTier/EasyTier)
[![Caddy](https://img.shields.io/badge/Caddy-v2%20Multiplexing-1F88C0?logo=caddy&logoColor=white)](https://caddyserver.com/)
[![tmux](https://img.shields.io/badge/tmux-Session%20Persistence-1BB954?logo=tmux&logoColor=white)](https://github.com/tmux/tmux)
[![sing-box](https://img.shields.io/badge/sing--box-v1.10+-E53E3E)](https://github.com/SagerNet/sing-box)
[![Memory Footprint](https://img.shields.io/badge/RAM-~50MB%20Footprint-blueviolet)](#technical-implementations)
[![LINUX DO](https://img.shields.io/badge/Thanks-LINUX%20DO-f59e0b?logo=discourse&logoColor=white)](https://linux.do)

Single-container runtime environment for Render.com free Docker web services. It runs an EasyTier user-space mesh VPN (smoltcp), an OpenSSH server, a persistent web terminal (ttyd with tmux), and a sing-box proxy behind a Caddy port multiplexer.

The container operates without `/dev/net/tun` or `CAP_NET_ADMIN` privileges. Total resident memory ranges from 30 MB to 50 MB, remaining well below the 512 MB platform memory limit.

---

## Architecture

Render free web services expose a single public HTTP port designated by the `$PORT` environment variable (default: `10000`). Caddy terminates incoming HTTP/WebSocket traffic and dispatches requests based on path routing:

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
│ Health probe │   │ EasyTier WebSocket     │            │ ttyd web terminal    │   │ sing-box VLESS       │
│ (200 OK)     │   │ (127.0.0.1:11010)      │            │ (Basic Authentication│   │ (127.0.0.1:20808)    │
└──────────────┘   └──────────┬─────────────┘            └──────────┬───────────┘   └──────────────────────┘
                              │                                     │
                    [smoltcp network stack]                 [tmux session: main]
                              │                                     │
               ┌──────────────┴──────────────┐             ┌────────┴───────────┐
               ▼                             ▼             ▼                    ▼
   OpenSSH (Port 22 / 2222)       sing-box (Port 10808)  State persistence    Mouse scrolling /
   (Key and password auth)        (Mixed in-mesh proxy)  across reconnects    50k line scrollback
```

### Route Allocation

| Path | Protocol | Target | Purpose |
| :--- | :--- | :--- | :--- |
| `/health` | HTTP GET | Inline response (`200 OK`) | Platform health check and external keepalive probe |
| `/et` | WebSocket | `127.0.0.1:11010` | EasyTier peer tunnel |
| `/shell/` | WebSocket / HTTP | `127.0.0.1:7681` | ttyd browser terminal with HTTP Basic Authentication |
| `/vless-ws` | WebSocket | `127.0.0.1:20808` | sing-box VLESS WebSocket ingress |

---

## Technical Implementations

### 1. User-Space Mesh Networking (EasyTier smoltcp)
The container runtime lacks Linux network administration capabilities (`CAP_NET_ADMIN`) and cannot open `/dev/net/tun`. EasyTier executes with `--no-tun --use-smoltcp`, driving an internal user-space TCP/IP stack that handles virtual IP routing without host kernel support. Port access rules whitelist TCP ports 22, 2222, and 10808 for inter-mesh communication.

### 2. Web Terminal Persistence (ttyd and tmux)
Web terminal connections through Cloudflare edge nodes and AWS Application Load Balancers terminate idle WebSockets after 60 to 100 seconds. Direct execution of shell binaries causes process termination upon client disconnection.

This repository addresses both conditions:
- **WebSocket Keepalive**: `ttyd` runs with `--ping-interval 15`, issuing heartbeat frames every 15 seconds to prevent edge proxy timeouts. Caddy applies `flush_interval -1` on the `/shell*` route to disable response buffer delays.
- **Session Persistence**: `ttyd` executes `/usr/local/bin/ttyd-session`, running `tmux -f /root/.tmux.conf new-session -A -s main /bin/bash`. Client disconnects detach the tmux client while background processes remain active. Subsequent browser connections attach back to the existing `main` session without loss of working directory, shell variables, or command history.
- **Terminal Capabilities**: `/root/.tmux.conf` enables mouse wheel scrolling (`mouse on`), configures a 50,000-line history buffer (`history-limit 50000`), enables dynamic client window adaptation (`window-size latest`), and eliminates escape key delay (`escape-time 0`).
- **Graceful Termination**: The shutdown handler executes `tmux kill-server` during container termination, giving child tasks an opportunity to flush disk writes before receiving host termination signals.

### 3. Filesystem Metric Normalization
In unprivileged containers on Kubernetes, `statvfs("/")` returns metrics from the host node block device (typically 300+ GB used, reporting 80% to 90% utilization), triggering false disk capacity alarms on monitoring dashboards.

When `AGENT_FORCE_DISK_TOTAL` or `KOMARI_FORCE_DISK_TOTAL` is present, the bundled `komari-agent` overrides the reported volume total with a fixed virtual allocation (default: 5 GiB) and calculates used capacity using apparent file sizes across the root filesystem, explicitly bypassing pseudo-filesystems (`/proc`, `/sys`, `/dev`, `/run`).

### 4. Process Supervisor and Circuit Breaker
`entrypoint.sh` acts as PID 1, running a 5-second polling loop. Individual process IDs (`PID_CADDY`, `PID_ET`, `PID_SSHD`, `PID_TTYD`, `PID_KOMARI`, `PID_SINGBOX`) are tracked directly to prevent stale identifier leaks. A circuit breaker terminates the container if any single managed service crashes more than 5 consecutive times.

---

## Configuration

Set the following environment variables in the Render dashboard:

| Variable | Default / Example | Description |
| :--- | :--- | :--- |
| `PORT` | `10000` | Public container listening port managed by Render |
| `ET_NAME` | `render-mesh` | EasyTier mesh network identifier |
| `ET_SECRET` | *(Random)* | EasyTier shared network secret |
| `ET_IP` | `10.144.144.90` | Static IPv4 address within the EasyTier mesh |
| `ET_HOSTNAME` | `render-box` | Hostname displayed in EasyTier peer tables |
| `ET_PEERS` | *(Optional)* | Comma-separated list of external EasyTier peer addresses |
| `SSH_PUBKEY` | *(Optional)* | OpenSSH public key appended to `/root/.ssh/authorized_keys` |
| `SSH_PASS` | *(Random 18-char)* | Root password for OpenSSH authentication |
| `TTYD_USER` | `admin` | HTTP Basic Authentication username for `/shell/` |
| `TTYD_PASS` | Matches `SSH_PASS` | HTTP Basic Authentication password for `/shell/` |
| `KOMARI_TOKEN` | *(Optional)* | Authentication token for MangoHub / Komari telemetry |
| `KOMARI_FORCE_DISK_TOTAL`| `5368709120` | Virtual disk total in bytes for metric override (5 GiB) |
| `SINGBOX_UUID` | `1da2cc31-2c34-4b0b-b83c-ce3f7b8e6c2c` | User identifier for sing-box VLESS inbound |

---

## Deployment

1. Fork or push this repository to GitHub.
2. Sign in to the [Render Dashboard](https://dashboard.render.com/) and create a new **Web Service**.
3. Link the repository and set:
   - **Environment**: `Docker`
   - **Instance Type**: `Free`
   - **Health Check Path**: `/health`
4. Populate required variables in the **Environment Variables** section.
5. Deploy the service. Render assigns a public hostname (for example, `https://your-service.onrender.com`).

---

## Client Usage

### 1. EasyTier Peer Connection
Start an EasyTier instance on the local client using the WebSocket endpoint:

```bash
sudo easytier-core \
  --network-name "render-mesh" \
  --network-secret "YourSecretKey" \
  --ipv4 "10.144.144.100" \
  --peers "wss://your-service.onrender.com/et"
```

Verify connection status:
```bash
easytier-cli peer
```

### 2. SSH Access via Virtual IP
Connect directly to the container through the virtual IP assigned in the mesh:

```bash
ssh root@10.144.144.90
# Or using backup port 2222
ssh -p 2222 root@10.144.144.90
```

To configure client-side shortcut access, add the following entry to `~/.ssh/config`:

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

Connect using:
```bash
ssh render-box
```

### 3. Web Terminal Access
Access the emergency console via web browser:
1. Navigate to `https://your-service.onrender.com/shell/`.
2. Enter the credentials defined by `TTYD_USER` and `TTYD_PASS`.
3. The session attaches to `tmux` automatically. Enter `exit` inside the shell to destroy and reinitialize the session.

### 4. Spindown Prevention
Render free instances suspend after 15 minutes without inbound HTTP requests. To maintain continuous operation, configure an external uptime monitor (such as Uptime Kuma or a cron job) to issue an HTTP GET request to `https://your-service.onrender.com/health` every 5 to 10 minutes.

### 5. Proxy Services
- **In-Mesh Mixed Proxy**: Listening on `0.0.0.0:10808` inside the container. Mesh participants can route HTTP and SOCKS5 traffic using `socks5://10.144.144.90:10808` or `http://10.144.144.90:10808`.
- **Public VLESS Inbound**: Listening on `wss://your-service.onrender.com/vless-ws`, handled by Caddy TLS termination and routed to sing-box on `127.0.0.1:20808`.

---

## Acknowledgments

Special thanks to the [LINUX DO](https://linux.do) community for valuable discussions and technical feedback.

---

## License

This project is licensed under the [MIT License](LICENSE).
