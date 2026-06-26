#!/bin/sh
# Alpine VM bootstrap — runs on first boot inside the QEMU VM.
# Sets up root SSH access and installs essential packages.
# Connect via:  ssh root@localhost -p 2222   (password: alpine)

echo "=== Alpine VM Bootstrap Starting ==="

# ---------------------------------------------------------------------------
# Package mirror configuration (NEW-16)
# ---------------------------------------------------------------------------
# Use a fast mirror (mirrors.aliyun.com) instead of the default
# dl-cdn.alpinelinux.org. The Aliyun CDN has PoPs across Asia and
# dramatically reduces apk download times over SLIRP networking.
# If the mirror is unreachable, fall back to the official CDN.
# Override at build time by setting LINXR_APK_MIRROR before this runs.
LINXR_APK_MIRROR="${LINXR_APK_MIRROR:-mirrors.aliyun.com/alpine/v3.19}"
LINXR_APK_FALLBACK="dl-cdn.alpinelinux.org/alpine/v3.19"

# Test mirror reachability (3s timeout); fall back if needed.
# Check both aarch64 (phone) and x86_64 (emulator) index files.
if wget -q -T 3 -O /dev/null "https://${LINXR_APK_MIRROR}/main/aarch64/APKINDEX.tar.gz" 2>/dev/null \
|| wget -q -T 3 -O /dev/null "https://${LINXR_APK_MIRROR}/main/x86_64/APKINDEX.tar.gz" 2>/dev/null; then
    APK_HOST="$LINXR_APK_MIRROR"
    echo "Using fast Alpine mirror: https://$APK_HOST"
else
    APK_HOST="$LINXR_APK_FALLBACK"
    echo "Fast mirror unreachable, falling back to: https://$APK_HOST"
fi

# Rewrite /etc/apk/repositories to use the selected mirror
cat > /etc/apk/repositories <<REPOEOF
https://${APK_HOST}/main
https://${APK_HOST}/community
REPOEOF

apk update 2>/dev/null || true
echo "Alpine repositories configured."

# ---------------------------------------------------------------------------
# Expand filesystem to fill the virtual disk
# ---------------------------------------------------------------------------
echo "Expanding filesystem to fill disk..."
if ! command -v resize2fs >/dev/null 2>&1; then
    apk add --no-cache e2fsprogs >/dev/null 2>&1 || true
fi
resize2fs /dev/vda 2>/dev/null || true
echo "Disk expansion complete: $(df -h / | awk 'NR==2{print $2}') total"

# ---------------------------------------------------------------------------
# Set root password
# ---------------------------------------------------------------------------
echo "root:alpine" | chpasswd 2>/dev/null || true
echo "Root password set to: alpine"

# ---------------------------------------------------------------------------
# Install and configure OpenSSH
# ---------------------------------------------------------------------------
if ! command -v sshd >/dev/null 2>&1; then
    echo "Installing openssh..."
    apk add --no-cache openssh
fi

# Generate host keys if missing
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
    ssh-keygen -A
fi

# Allow root login with password
sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config

# Ensure the settings are present (append if not already set)
grep -q "^PermitRootLogin yes" /etc/ssh/sshd_config \
    || echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
grep -q "^PasswordAuthentication yes" /etc/ssh/sshd_config \
    || echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config

# ---------------------------------------------------------------------------
# SSH performance tuning for SLIRP/TCG environment
# ---------------------------------------------------------------------------
# UseDNS no:    Disables reverse DNS lookup on client IP.
#               DEFAULT is "yes" — causes 2-5s delay per connection because
#               the lookup goes through QEMU's single-threaded SLIRP DNS proxy.
#               This is the SINGLE BIGGEST latency fix for terminal slowness.
#
# GSSAPIAuthentication no:  Disables Kerberos/GSSAPI auth negotiation.
#               No GSSAPI libs on Alpine, so this just adds timeout delays.
#
# Compression no:  Disable SSH compression — all traffic is localhost, so
#               compression just wastes emulated CPU cycles.
#
# ClientAliveInterval 15:   Sends keepalive every 15s to detect dead connections.
#
# MaxStartups 10:3:20:  Accept up to 10 unauthenticated connections before
#               rate-limiting. Prevents drops when opening multiple tabs.
#
# LoginGraceTime 30:  Reduced from 120s — frees sshd resources faster.

grep -q "^UseDNS" /etc/ssh/sshd_config \
    && sed -i 's/^UseDNS.*/UseDNS no/' /etc/ssh/sshd_config \
    || echo "UseDNS no" >> /etc/ssh/sshd_config

grep -q "^GSSAPIAuthentication" /etc/ssh/sshd_config \
    && sed -i 's/^GSSAPIAuthentication.*/GSSAPIAuthentication no/' /etc/ssh/sshd_config \
    || echo "GSSAPIAuthentication no" >> /etc/ssh/sshd_config

grep -q "^Compression" /etc/ssh/sshd_config \
    || echo "Compression no" >> /etc/ssh/sshd_config

grep -q "^ClientAliveInterval" /etc/ssh/sshd_config \
    || echo "ClientAliveInterval 15" >> /etc/ssh/sshd_config

grep -q "^MaxStartups" /etc/ssh/sshd_config \
    || echo "MaxStartups 10:3:20" >> /etc/ssh/sshd_config

grep -q "^LoginGraceTime" /etc/ssh/sshd_config \
    || echo "LoginGraceTime 30" >> /etc/ssh/sshd_config

echo "sshd performance tuning applied."

# ---------------------------------------------------------------------------
# Network hardening for SLIRP user-mode networking (Issue #19)
# ---------------------------------------------------------------------------
# QEMU's SLIRP stack is single-threaded and drops packets under high
# concurrency (e.g. npm install opening 50+ parallel HTTP connections).
# These sysctl settings increase kernel-level buffers and tune TCP to
# be more resilient under software emulation (TCG) latency.
echo "Tuning network stack for SLIRP compatibility..."

# --- DNS resilience ---
# Force Cloudflare + Google DNS as fallback in case QEMU's DHCP-advertised
# DNS (set via -netdev dns=) doesn't take effect or user runs older QEMU.
cat > /etc/resolv.conf <<'DNSEOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:5 attempts:3 rotate
DNSEOF

# --- TCP buffer sizes ---
# Increase default and max socket buffer sizes.
# Alpine defaults (212992 bytes) are too small for bursty workloads
# over the virtio-net + SLIRP path. 4MB max / 1MB default handles npm.
sysctl -w net.core.rmem_max=4194304      2>/dev/null || true
sysctl -w net.core.wmem_max=4194304      2>/dev/null || true
sysctl -w net.core.rmem_default=1048576  2>/dev/null || true
sysctl -w net.core.wmem_default=1048576  2>/dev/null || true

# --- TCP auto-tuning range ---
# min=4KB, default=1MB, max=4MB (per-connection buffers)
sysctl -w net.ipv4.tcp_rmem="4096 1048576 4194304"  2>/dev/null || true
sysctl -w net.ipv4.tcp_wmem="4096 1048576 4194304"  2>/dev/null || true

# --- TCP timer tuning ---
# Reduce FIN_WAIT2 timeout — reclaims SLIRP connection slots 4x faster.
sysctl -w net.ipv4.tcp_fin_timeout=15          2>/dev/null || true

# Enable TCP window scaling and timestamps for better throughput
sysctl -w net.ipv4.tcp_window_scaling=1        2>/dev/null || true
sysctl -w net.ipv4.tcp_timestamps=1            2>/dev/null || true

# Lower keepalive — detect dead SLIRP connections faster
sysctl -w net.ipv4.tcp_keepalive_time=60       2>/dev/null || true
sysctl -w net.ipv4.tcp_keepalive_intvl=10      2>/dev/null || true
sysctl -w net.ipv4.tcp_keepalive_probes=5      2>/dev/null || true

# --- Connection tracking ---
# Increase conntrack table. SLIRP maps every guest TCP connection to
# a host socket; large npm installs can exhaust defaults.
sysctl -w net.netfilter.nf_conntrack_max=16384 2>/dev/null || true

# --- Persist for subsequent boots ---
cat >> /etc/sysctl.conf <<'SYSEOF'
# Linxr SLIRP network tuning
net.core.rmem_max=4194304
net.core.wmem_max=4194304
net.core.rmem_default=1048576
net.core.wmem_default=1048576
net.ipv4.tcp_rmem=4096 1048576 4194304
net.ipv4.tcp_wmem=4096 1048576 4194304
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=5
SYSEOF

echo "Network tuning applied."

# ---------------------------------------------------------------------------
# npm / Node.js retry configuration for SLIRP environments
# ---------------------------------------------------------------------------
# Even with TCP tuning, TCG's CPU overhead means npm's default 10-second
# fetch timeout can still expire under load. Pre-configure npm to retry
# more aggressively. Only runs if npm/Node.js is installed.
if command -v npm >/dev/null 2>&1 || [ -d /usr/lib/node_modules ]; then
    npm config set registry https://registry.npmmirror.com        2>/dev/null || true
    npm config set fetch-retry-maxtimeout 120000 2>/dev/null || true
    npm config set fetch-retry-mintimeout 20000  2>/dev/null || true
    npm config set fetch-retries 5               2>/dev/null || true
    echo "npm registry set to npmmirror.com + retry config for SLIRP."
fi

# ---------------------------------------------------------------------------
# pip mirror configuration (NEW-16)
# ---------------------------------------------------------------------------
# Use Tsinghua University mirror (pypi.tuna.tsinghua.edu.cn) for faster
# pip downloads over SLIRP. Falls back silently if pip not installed yet.
if command -v pip >/dev/null 2>&1 || command -v pip3 >/dev/null 2>&1; then
    mkdir -p /root/.config/pip
    cat > /root/.config/pip/pip.conf <<'PIPEOF'
[global]
index-url = https://pypi.tuna.tsinghua.edu.cn/simple
trusted-host = pypi.tuna.tsinghua.edu.cn
timeout = 120
retries = 5
PIPEOF
    echo "pip mirror set to Tsinghua (pypi.tuna.tsinghua.edu.cn)."
fi

# ---------------------------------------------------------------------------
# Install sudo
# ---------------------------------------------------------------------------
if ! command -v sudo >/dev/null 2>&1; then
    echo "Installing sudo..."
    apk add --no-cache sudo
fi

# Allow wheel group to use sudo without password
if ! grep -q "^%wheel" /etc/sudoers 2>/dev/null; then
    echo "%wheel ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
fi

# ---------------------------------------------------------------------------
# Start SSH daemon
# ---------------------------------------------------------------------------
echo "Starting sshd..."
/usr/sbin/sshd

# Verify sshd is listening
sleep 1
if pgrep sshd >/dev/null 2>&1; then
    echo "=== SSH is ready on port 22 ==="
    echo "=== Connect: ssh root@localhost -p 2222 ==="
    echo "=== Password: alpine ==="
else
    echo "ERROR: sshd failed to start"
    exit 1
fi

# ---------------------------------------------------------------------------
# Docker daemon startup (NEW-18)
# ---------------------------------------------------------------------------
# The OLD 23.apk had `docker run hello-world` working. Restore that behavior.
#
# Root causes of dockerd failure in QEMU virt environment (found via testing):
#   1. overlay2 storage driver fails: overlayfs kernel module version mismatch
#      (module built for 6.6.140, VM runs 6.6.142) → "no such device"
#   2. iptables module (ip_tables) not found → dockerd can't init firewall
#   3. bridge module not found → dockerd can't create docker0 bridge
#
# Fix: configure daemon.json with vfs storage driver (no kernel module needed),
# disable iptables and bridge networking (not needed for single-VM use case).
if command -v dockerd >/dev/null 2>&1; then
    echo "Configuring Docker daemon for QEMU virt environment..."
    mkdir -p /etc/docker

    # vfs: copy-on-write via plain directory copies — no kernel module needed.
    # iptables=false, bridge=none: skip modules that don't exist in virt kernel.
    # registry-mirrors: use Chinese mirrors for faster image pulls over SLIRP.
    cat > /etc/docker/daemon.json <<'DOCKEREOF'
{
  "storage-driver": "vfs",
  "iptables": false,
  "bridge": "none",
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://mirror.ccs.tencentyun.com"
  ]
}
DOCKEREOF

    # Clean any previous docker state from failed overlay2 attempts
    rm -rf /var/lib/docker/* 2>/dev/null || true

    # Start dockerd via OpenRC if the init script exists.
    # Note: the OpenRC service is named 'docker' not 'dockerd'.
    if [ -f /etc/init.d/docker ]; then
        rc-service docker start >/var/log/dockerd.log 2>&1
        echo "Docker started via rc-service docker (logging to /var/log/dockerd.log)"
    else
        # Fallback: start dockerd directly in background with logging
        dockerd > /var/log/dockerd.log 2>&1 &
        echo "Docker started directly (logging to /var/log/dockerd.log)"
    fi

    # Poll for /var/run/docker.sock — dockerd creates it when fully initialized.
    # vfs driver + containerd init can take 10-15s under TCG emulation.
    echo "Waiting for Docker socket..."
    DOCKER_READY=0
    for i in $(seq 1 30); do
        if [ -S /var/run/docker.sock ]; then
            DOCKER_READY=1
            echo "Docker socket ready after ${i}s"
            break
        fi
        sleep 1
    done

    if [ "$DOCKER_READY" -eq 1 ]; then
        echo "=== Docker daemon is running ==="
    else
        echo "WARNING: Docker socket not ready after 30s. Check /var/log/dockerd.log"
        tail -5 /var/log/dockerd.log 2>/dev/null || true
    fi
fi

echo "=== Bootstrap Complete ==="
