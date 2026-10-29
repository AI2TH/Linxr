#!/bin/sh
# Alpine VM bootstrap — runs on first boot inside the QEMU VM.
# Sets up root SSH access and installs essential packages.
# Connect via:  ssh root@localhost -p 2222   (password: alpine)

echo "=== Alpine VM Bootstrap Starting ==="

# Remove slow Go CLI plugins immediately to prevent docker CLI from hanging on TCG CPU
rm -rf /usr/libexec/docker/cli-plugins 2>/dev/null || true

# ---------------------------------------------------------------------------
# Package mirror configuration (NEW-16)
# ---------------------------------------------------------------------------
cat > /etc/apk/repositories <<REPOEOF
https://dl-cdn.alpinelinux.org/alpine/v3.20/main
https://dl-cdn.alpinelinux.org/alpine/v3.20/community
REPOEOF

# Check if we need to install anything
NEEDS_INSTALL=0
if ! command -v resize2fs >/dev/null 2>&1; then
    NEEDS_INSTALL=1
fi
if ! command -v sshd >/dev/null 2>&1 && ! command -v dropbear >/dev/null 2>&1; then
    NEEDS_INSTALL=1
fi
if ! command -v sudo >/dev/null 2>&1; then
    NEEDS_INSTALL=1
fi
if ! command -v curl >/dev/null 2>&1; then
    NEEDS_INSTALL=1
fi

if [ "$NEEDS_INSTALL" -eq 1 ]; then
    apk update 2>/dev/null || true
    apk add --no-cache curl 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Expand filesystem to fill the virtual disk
# ---------------------------------------------------------------------------
if [ ! -f /etc/.disk_expanded ]; then
    echo "Expanding filesystem to fill disk..."
    if ! command -v resize2fs >/dev/null 2>&1; then
        apk add --no-cache e2fsprogs >/dev/null 2>&1 || true
    fi
    resize2fs /dev/vda 2>/dev/null && touch /etc/.disk_expanded || true
    echo "Disk expansion complete: $(df -h / | awk 'NR==2{print $2}') total"
else
    echo "Filesystem already expanded, skipping resize2fs."
fi

# ---------------------------------------------------------------------------
# Set root password
# ---------------------------------------------------------------------------
echo "root:alpine" | chpasswd 2>/dev/null || true
echo "Root password set to: alpine"

# ---------------------------------------------------------------------------
# Install and configure OpenSSH
# ---------------------------------------------------------------------------
if ! command -v sshd >/dev/null 2>&1 && ! command -v dropbear >/dev/null 2>&1; then
    echo "Installing openssh..."
    apk add --no-cache openssh
fi

if command -v sshd >/dev/null 2>&1; then
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
fi

# ---------------------------------------------------------------------------
# Network hardening for SLIRP user-mode networking (Issue #19)
# ---------------------------------------------------------------------------
# QEMU's SLIRP stack is single-threaded and drops packets under high
# concurrency (e.g. npm install opening 50+ parallel HTTP connections).
# These sysctl settings increase kernel-level buffers and tune TCP to
# be more resilient under software emulation (TCG) latency.
echo "Tuning network stack for SLIRP compatibility..."

# --- DNS resilience ---
# Fast Cloudflare DNS (1.1.1.1 / 1.0.0.1) with Google DNS (8.8.8.8 / 8.8.4.4) fallback.
cat > /etc/resolv.conf <<'DNSEOF'
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
nameserver 8.8.4.4
options timeout:2 attempts:2
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

# --- IPv6, MTU, and MSS tuning for mobile carrier & QEMU SLIRP ---
# QEMU SLIRP only routes IPv4. Dual-stack clients hang on IPv6 DNS/connect timeouts.
# Lowering MTU to 1200 prevents TLS Client Hello drops over cellular/Wi-Fi virtio paths.
sysctl -w net.ipv6.conf.all.disable_ipv6=1      2>/dev/null || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1  2>/dev/null || true
sysctl -w net.ipv4.tcp_mtu_probing=2            2>/dev/null || true
ip link set eth0 mtu 1200                       2>/dev/null || true

# nftables MSS clamping and IPv6 immediate reject
nft add table ip filter 2>/dev/null || true
nft 'add chain ip filter output { type filter hook output priority 0 ; policy accept ; }' 2>/dev/null || true
nft add rule ip filter output tcp flags syn tcp option maxseg size set 1160 2>/dev/null || true

nft add table ip6 filter 2>/dev/null || true
nft 'add chain ip6 filter output { type filter hook output priority 0 ; policy accept ; }' 2>/dev/null || true
nft add rule ip6 filter output reject 2>/dev/null || true

# --- Persist for subsequent boots ---
cat >> /etc/sysctl.conf <<'SYSEOF'
# Linxr SLIRP network tuning
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv4.tcp_mtu_probing=2
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
    cat > /root/.npmrc <<'NPMEOF'
registry=https://registry.npmmirror.com
fetch-retry-maxtimeout=120000
fetch-retry-mintimeout=20000
fetch-retries=5
NPMEOF
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
echo "Starting SSH daemon..."
if command -v sshd >/dev/null 2>&1; then
    /usr/sbin/sshd
    sleep 1
    if pgrep sshd >/dev/null 2>&1; then
        echo "=== OpenSSH is ready on port 22 ==="
    else
        echo "ERROR: sshd failed to start"
        exit 1
    fi
elif command -v dropbear >/dev/null 2>&1; then
    if pgrep dropbear >/dev/null 2>&1; then
        echo "=== Dropbear is already running on port 22 ==="
    else
        /usr/sbin/dropbear -E -p 22
        sleep 1
        if pgrep dropbear >/dev/null 2>&1; then
            echo "=== Dropbear started on port 22 ==="
        else
            echo "ERROR: dropbear failed to start"
            exit 1
        fi
    fi
else
    echo "ERROR: No SSH daemon (sshd or dropbear) found"
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
    # Remove slow Go CLI plugins to prevent docker CLI from hanging on emulated CPU
    rm -rf /usr/libexec/docker/cli-plugins 2>/dev/null || true

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
  "mtu": 1200,
  "dns": ["1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4"]
}
DOCKEREOF

    if pgrep dockerd >/dev/null 2>&1 && [ -S /var/run/docker.sock ]; then
        echo "=== Docker daemon is already running ==="
    else
        # Only clean docker state on very first bootstrap, NOT on every restart
        if [ ! -f /etc/docker/.initialized ]; then
            rm -rf /var/lib/docker/* 2>/dev/null || true
            touch /etc/docker/.initialized
        fi

        # Clean up stale pid/sock files
        rm -f /var/run/docker.pid /var/run/docker/containerd/containerd.pid /run/containerd/containerd.sock /var/run/docker.sock

        if ! pgrep containerd >/dev/null 2>&1; then
            echo "Starting containerd daemon..."
            containerd >/var/log/containerd.log 2>&1 &
            for i in $(seq 1 15); do
                if [ -S /run/containerd/containerd.sock ]; then
                    echo "containerd socket is ready after ${i}s"
                    break
                fi
                sleep 1
            done
        fi

        # Start dockerd directly in background pointing to containerd
        echo "Starting Docker daemon..."
        dockerd --containerd=/run/containerd/containerd.sock > /var/log/dockerd.log 2>&1 &

        # Poll for /var/run/docker.sock — dockerd creates it when fully initialized.
        echo "Waiting for Docker socket..."
        DOCKER_READY=0
        for i in $(seq 1 20); do
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
            echo "WARNING: Docker socket not ready after 20s. Check /var/log/dockerd.log"
            tail -5 /var/log/dockerd.log 2>/dev/null || true
        fi
    fi
fi

# ---------------------------------------------------------------------------
# K3s Kubernetes RSA Acceleration & Client Tuning (NEW-24)
# ---------------------------------------------------------------------------
# On emulated TCG CPU architectures, default ECDSA P-256 scalar multiplication
# in Go takes ~4.5s per handshake (causing 10s mTLS timeout cascade failures).
# Pre-configure K3s to enforce fast RSA 2048 ciphers, disable WatchList feature
# gate, and set GODEBUG=tlsmlkem=0 to prevent post-quantum ML-KEM handshake delays.
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml <<'K3SEOF'
write-kubeconfig-mode: "644"
kube-apiserver-arg:
  - "feature-gates=WatchList=false"
  - "enable-priority-and-fairness=false"
  - "tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305"
K3SEOF

# Disable Go ML-KEM for kubectl and internal clients to prevent handshake timeouts
mkdir -p /etc/profile.d
cat > /etc/profile.d/k3s.sh <<'PROFEIO'
export GODEBUG="tlsmlkem=0"
PROFEIO
chmod +x /etc/profile.d/k3s.sh

echo "=== Bootstrap Complete ==="
