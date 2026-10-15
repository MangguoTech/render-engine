# ==========================================
# Build / Base Stage: Alpine Linux (x86_64)
# Minimal footprint, low memory (< 512MB limit)
# ==========================================
FROM alpine:latest

LABEL maintainer="DevOps Team" \
      description="EasyTier with SSH & Caddy reverse proxy on Render Free Tier"

# Explicit upstream release versions for reproducible builds
ARG EASYTIER_VERSION="v2.6.4"
ARG TTYD_VERSION="1.7.7"

# Set environment
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PORT=10000

# Install runtime dependencies via Alpine apk
RUN apk update && \
    apk add --no-cache \
      bash \
      ca-certificates \
      curl \
      unzip \
      tar \
      gzip \
      openssh \
      iproute2 \
      tmux \
      vim \
      caddy \
      tzdata \
      procps && \
    rm -rf /var/cache/apk/*

# Download and install EasyTier (x86_64) with deterministic version URL
RUN set -eux; \
    echo "Downloading EasyTier ${EASYTIER_VERSION}..."; \
    ET_URL="https://github.com/EasyTier/EasyTier/releases/download/${EASYTIER_VERSION}/easytier-linux-x86_64-${EASYTIER_VERSION}.zip"; \
    curl -sSL "$ET_URL" -o /tmp/easytier.zip; \
    unzip -q /tmp/easytier.zip -d /tmp/easytier; \
    find /tmp/easytier -type f -name "easytier-core" -exec cp {} /usr/local/bin/ \; ; \
    find /tmp/easytier -type f -name "easytier-cli" -exec cp {} /usr/local/bin/ \; 2>/dev/null || true; \
    chmod +x /usr/local/bin/easytier-core; \
    [ -f /usr/local/bin/easytier-cli ] && chmod +x /usr/local/bin/easytier-cli || true; \
    rm -rf /tmp/easytier*

# Download and install ttyd for emergency web terminal
RUN set -eux; \
    echo "Downloading ttyd ${TTYD_VERSION}..."; \
    curl -sSL -o /usr/local/bin/ttyd "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64"; \
    chmod +x /usr/local/bin/ttyd

# Configure SSH server defaults
RUN mkdir -p /var/run/sshd /root/.ssh && \
    chmod 700 /root/.ssh && \
    # Set default root shell to /bin/bash
    sed -i -e "s|bin/ash|bin/bash|g" /etc/passwd

# Copy configuration files and entrypoint
COPY Caddyfile /etc/caddy/Caddyfile
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh

# Expose Render default port
EXPOSE 10000

# Working directory
WORKDIR /root

# Entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
