#!/usr/bin/env bash
# ==============================================================================
# Entrypoint for EasyTier + SSH + Caddy on Render Container (No-TUN Smoltcp)
# Production-Hardened Edition
# ==============================================================================
set -Eeuo pipefail

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"
}

warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*" >&2
}

err() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
}

generate_secure_secret() {
    head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 18
}

log "=========================================================="
log "Starting EasyTier Render Container Initialization..."
log "=========================================================="

# ------------------------------------------------------------------------------
# 1. SSH Server Configuration & Credentials Setup
# ------------------------------------------------------------------------------
log "Configuring OpenSSH server..."

# Generate host keys if not present
ssh-keygen -A >/dev/null 2>&1 || true

# Prepare SSH runtime directories
mkdir -p /var/run/sshd /root/.ssh
chmod 700 /root/.ssh

# Configure sshd_config
cat > /etc/ssh/sshd_config << 'EOF'
Port 22
Port 2222
ListenAddress 0.0.0.0
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
ChallengeResponseAuthentication no
# UsePAM no (Alpine OpenSSH has no PAM support)
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/ssh/sftp-server
ClientAliveInterval 30
ClientAliveCountMax 3
EOF

# Setup SSH password
if [ -n "${SSH_PASS:-}" ]; then
    echo "root:${SSH_PASS}" | chpasswd
    log "SSH root password configured from SSH_PASS."
else
    RANDOM_PASS=$(generate_secure_secret)
    echo "root:${RANDOM_PASS}" | chpasswd
    warn "SSH_PASS not provided! Generated random secure root password: ${RANDOM_PASS}"
    SSH_PASS="$RANDOM_PASS"
fi

# Setup SSH Public Key
DEFAULT_SSH_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMQTME8tnsRLdvdTA/BHvjBYv0un5Ih7lKgRz+voFVUx render-pxed-mesh"
if [ -n "${SSH_PUBKEY:-}" ]; then
    echo "${SSH_PUBKEY}" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    log "SSH public key installed to /root/.ssh/authorized_keys."
elif [ -n "${DEFAULT_SSH_PUBKEY}" ]; then
    echo "${DEFAULT_SSH_PUBKEY}" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    log "Default pxed SSH public key installed to /root/.ssh/authorized_keys."
fi

# Ensure root shell is bash
chsh -s /bin/bash root >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# 2. EasyTier CLI Arguments Preparation
# ------------------------------------------------------------------------------
log "Preparing EasyTier arguments..."

ET_ARGS=()

# Basic network identity
if [ -z "${ET_NAME:-}" ]; then
    ET_NAME="mango-mesh"
fi
if [ -z "${ET_SECRET:-}" ]; then
    ET_SECRET="M4ngo#Mesh_SecKey@2026"
fi

ET_ARGS+=(--network-name "$ET_NAME")
ET_ARGS+=(--network-secret "$ET_SECRET")

# IP configuration
if [ -n "${ET_IP:-}" ]; then
    ET_ARGS+=(-i "$ET_IP")
    log "EasyTier static IP: $ET_IP"
elif [ "${ET_DHCP:-false}" = "true" ]; then
    ET_ARGS+=(-d)
    log "EasyTier DHCP mode enabled."
else
    DEFAULT_IP="10.144.144.90"
    ET_ARGS+=(-i "$DEFAULT_IP")
    log "EasyTier IP not set; using default: $DEFAULT_IP"
fi

# Always listen on local ws port for Caddy reverse proxy
ET_ARGS+=(-l "ws://127.0.0.1:11010")

# Critical: Render container has no /dev/net/tun or CAP_NET_ADMIN
# EasyTier smoltcp user-space TCP/IP stack will handle incoming L3/L4 traffic
ET_ARGS+=(--no-tun)
ET_ARGS+=(--use-smoltcp)

# Ports to expose over virtual IP smoltcp network (SSH and backup port, sing-box mixed proxy)
ET_ARGS+=(--tcp-whitelist 22 2222 10808)

# Optional hostname
if [ -n "${ET_HOSTNAME:-}" ]; then
    ET_ARGS+=(--hostname "$ET_HOSTNAME")
else
    ET_ARGS+=(--hostname "render-box")
fi

# Default peers if ET_PEERS is not provided
DEFAULT_PEERS="tcp://212.64.10.215:11010,tcp://104.208.65.233:11010"
if [ -z "${ET_PEERS:-}" ]; then
    ET_PEERS="$DEFAULT_PEERS"
fi

# Peer connections (ET_PEERS can be space or comma separated)
if [ -n "${ET_PEERS:-}" ]; then
    IFS=', ' read -r -a PEER_ARRAY <<< "$ET_PEERS"
    for peer in "${PEER_ARRAY[@]}"; do
        if [ -n "$peer" ]; then
            ET_ARGS+=(-p "$peer")
            log "Configured EasyTier peer: $peer"
        fi
    done
else
    log "No external ET_PEERS defined. Container will wait passively on ws://127.0.0.1:11010"
fi

# Console log level
ET_ARGS+=(--console-log-level "${ET_LOG_LEVEL:-info}")

# ------------------------------------------------------------------------------
# 3. Process Management & Background Services
# ------------------------------------------------------------------------------
PIDS=()

cleanup() {
    log "Received shutdown signal. Stopping all background processes..."
    for pid in "${PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done
    wait || true
    log "All processes terminated. Container exit."
    exit 0
}

trap cleanup SIGINT SIGTERM SIGHUP

# Start SSH daemon
log "Starting sshd on ports 22 and 2222..."
/usr/sbin/sshd -D -e &
PID_SSHD=$!
PIDS+=("$PID_SSHD")

# Start EasyTier Core
log "Starting easytier-core..."
/usr/local/bin/easytier-core "${ET_ARGS[@]}" &
PID_ET=$!
PIDS+=("$PID_ET")

# Start ttyd (Emergency web terminal)
TTYD_USER="${TTYD_USER:-admin}"
TTYD_PASS="${TTYD_PASS:-$SSH_PASS}"
log "Starting ttyd on 127.0.0.1:7681 (/shell) with Basic Auth..."
/usr/local/bin/ttyd \
    --port 7681 \
    --interface 127.0.0.1 \
    --base-path "/shell" \
    --writable \
    --credential "${TTYD_USER}:${TTYD_PASS}" \
    /bin/bash &
PID_TTYD=$!
PIDS+=("$PID_TTYD")

# Start Caddy Reverse Proxy
PORT="${PORT:-10000}"
export PORT
log "Starting Caddy on port $PORT..."
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
PID_CADDY=$!
PIDS+=("$PID_CADDY")

# Start Komari Agent (if binary exists and env configured)
PID_KOMARI=""
DEFAULT_KOMARI_TOKEN="3WU9ZdCTvrDeUW8wIkYdWA"
if [ -n "${KOMARI_TOKEN:-}" ]; then
    AGENT_TOKEN="${KOMARI_TOKEN}"
elif [ -z "${AGENT_TOKEN:-}" ] && [ -n "${DEFAULT_KOMARI_TOKEN}" ]; then
    AGENT_TOKEN="${DEFAULT_KOMARI_TOKEN}"
fi

if [ -n "${AGENT_TOKEN:-}" ] && [ ! -f /etc/komari-agent.env ]; then
    cat > /etc/komari-agent.env << EOF
export AGENT_ENDPOINT="${KOMARI_ENDPOINT:-https://vps.mangoqwq.com}"
export AGENT_TOKEN="${AGENT_TOKEN}"
export AGENT_INCLUDE_MOUNTPOINTS="/"
export AGENT_INCLUDE_NICS="eth0"
export AGENT_DISABLE_WEB_SSH="true"
export AGENT_DISABLE_AUTO_UPDATE="true"
export AGENT_MONTH_ROTATE="1"
export AGENT_INTERVAL="3"
export AGENT_PREFER_IP_VERSION="4"
EOF
    chmod 600 /etc/komari-agent.env
fi

if [ -x /usr/local/bin/komari-agent ] && [ -f /etc/komari-agent.env ]; then
    log "Starting komari-agent..."
    (
        set -a
        . /etc/komari-agent.env
        set +a
        exec /usr/local/bin/komari-agent --prefer-cgroup-limits
    ) >/var/log/komari-agent.log 2>&1 &
    PID_KOMARI=$!
    PIDS+=("$PID_KOMARI")
    log "komari-agent started (PID $PID_KOMARI)."
else
    log "komari-agent binary or /etc/komari-agent.env not present; skipping."
fi

# Start sing-box (Dual inbound: mixed on 10808 for mesh, vless-ws on 20808 for Caddy)
PID_SINGBOX=""
SINGBOX_UUID="${SINGBOX_UUID:-1da2cc31-2c34-4b0b-b83c-ce3f7b8e6c2c}"
mkdir -p /etc/sing-box /var/log/sing-box
if [ ! -f /etc/sing-box/config.json ]; then
    cat > /etc/sing-box/config.json << EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "0.0.0.0",
      "listen_port": 10808
    },
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "127.0.0.1",
      "listen_port": 20808,
      "users": [
        {
          "uuid": "${SINGBOX_UUID}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/vless-ws"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
fi

if command -v sing-box >/dev/null 2>&1; then
    log "Starting sing-box..."
    sing-box run -c /etc/sing-box/config.json >/var/log/sing-box/sing-box.log 2>&1 &
    PID_SINGBOX=$!
    PIDS+=("$PID_SINGBOX")
    log "sing-box started (PID $PID_SINGBOX, mixed 0.0.0.0:10808, vless-ws 127.0.0.1:20808)."
else
    log "sing-box binary not found in PATH; skipping."
fi

log "All services initiated successfully."
log "Caddy: :$PORT (/health, /et, /shell, /vless-ws)"
log "EasyTier: ws://127.0.0.1:11010"
log "SSHD: 127.0.0.1:22 and 127.0.0.1:2222"
log "ttyd: 127.0.0.1:7681 (/shell)"
log "sing-box: 0.0.0.0:10808 (mixed), 127.0.0.1:20808 (vless-ws)"

# ------------------------------------------------------------------------------
# 4. Supervise Processes Loop with Crash-Loop Circuit Breaker
# ------------------------------------------------------------------------------
FAIL_COUNT_CADDY=0
FAIL_COUNT_ET=0
FAIL_COUNT_SSHD=0
FAIL_COUNT_TTYD=0
MAX_FAILURES=5

while true; do
    # Check Caddy
    if ! kill -0 "$PID_CADDY" 2>/dev/null; then
        ((FAIL_COUNT_CADDY++)) || true
        err "Caddy process died! (Failure count: $FAIL_COUNT_CADDY/$MAX_FAILURES)"
        if [ "$FAIL_COUNT_CADDY" -ge "$MAX_FAILURES" ]; then
            err "Caddy exceeded maximum crash limit. Aborting container to trigger restart."
            exit 1
        fi
        caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
        PID_CADDY=$!
    fi

    # Check EasyTier
    if ! kill -0 "$PID_ET" 2>/dev/null; then
        ((FAIL_COUNT_ET++)) || true
        err "EasyTier core process died! (Failure count: $FAIL_COUNT_ET/$MAX_FAILURES)"
        if [ "$FAIL_COUNT_ET" -ge "$MAX_FAILURES" ]; then
            err "EasyTier core exceeded maximum crash limit. Aborting container to trigger restart."
            exit 1
        fi
        /usr/local/bin/easytier-core "${ET_ARGS[@]}" &
        PID_ET=$!
    fi

    # Check SSHD
    if ! kill -0 "$PID_SSHD" 2>/dev/null; then
        ((FAIL_COUNT_SSHD++)) || true
        err "sshd process died! (Failure count: $FAIL_COUNT_SSHD/$MAX_FAILURES)"
        if [ "$FAIL_COUNT_SSHD" -ge "$MAX_FAILURES" ]; then
            err "sshd exceeded maximum crash limit. Aborting container to trigger restart."
            exit 1
        fi
        /usr/sbin/sshd -D -e &
        PID_SSHD=$!
    fi

    # Check ttyd
    if ! kill -0 "$PID_TTYD" 2>/dev/null; then
        ((FAIL_COUNT_TTYD++)) || true
        err "ttyd process died! (Failure count: $FAIL_COUNT_TTYD/$MAX_FAILURES)"
        if [ "$FAIL_COUNT_TTYD" -ge "$MAX_FAILURES" ]; then
            err "ttyd exceeded maximum crash limit. Aborting container to trigger restart."
            exit 1
        fi
        /usr/local/bin/ttyd \
            --port 7681 \
            --interface 127.0.0.1 \
            --base-path "/shell" \
            --writable \
            --credential "${TTYD_USER}:${TTYD_PASS}" \
            /bin/bash &
        PID_TTYD=$!
    fi

    # Check Komari Agent
    if [ -x /usr/local/bin/komari-agent ] && [ -f /etc/komari-agent.env ]; then
        if [ -n "$PID_KOMARI" ] && ! kill -0 "$PID_KOMARI" 2>/dev/null; then
            warn "komari-agent process died. Restarting..."
            (
                set -a
                . /etc/komari-agent.env
                set +a
                exec /usr/local/bin/komari-agent --prefer-cgroup-limits
            ) >>/var/log/komari-agent.log 2>&1 &
            PID_KOMARI=$!
        fi
    fi

    # Check sing-box
    if command -v sing-box >/dev/null 2>&1 && [ -f /etc/sing-box/config.json ]; then
        if [ -n "$PID_SINGBOX" ] && ! kill -0 "$PID_SINGBOX" 2>/dev/null; then
            warn "sing-box process died. Restarting..."
            sing-box run -c /etc/sing-box/config.json >>/var/log/sing-box/sing-box.log 2>&1 &
            PID_SINGBOX=$!
        fi
    fi

    sleep 5
done
