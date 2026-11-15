#!/bin/sh
# Runs inside Docker (linux/arm64 Alpine container).
# Builds a minimal Alpine Linux rootfs with dropbear + sudo,
# then packages it as base.qcow2.gz in /out.
set -e

# ---------------------------------------------------------------------------
# Configurable disk size
# ---------------------------------------------------------------------------
# This is the virtual size of the root filesystem baked into base.qcow2.gz.
# It must be kept in sync with VM_DISK_SIZE_GB in VmManager.kt so the overlay
# matches the pre-expanded filesystem and avoids a slow resize2fs at boot.
DISK_SIZE_GB=4

ROOTFS=/tmp/rootfs
IMAGE_SIZE="${DISK_SIZE_GB}G"

echo "--- Installing build tools ---"
apk add --no-cache e2fsprogs qemu-img

# â”€â”€ Bootstrap rootfs â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
echo "--- Bootstrapping Alpine rootfs ---"
mkdir -p "${ROOTFS}/etc/apk/keys"
cp /etc/apk/keys/* "${ROOTFS}/etc/apk/keys/"
cp /etc/apk/repositories "${ROOTFS}/etc/apk/"
# docker and fuse-overlayfs are in community â€” ensure it's enabled
ALPINE_RELEASE=$(cut -d. -f1,2 /etc/alpine-release 2>/dev/null || echo "3.20")
ALPINE_BRANCH="v${ALPINE_RELEASE}"
echo "Detected Alpine branch: ${ALPINE_BRANCH}"

grep -q 'community' "${ROOTFS}/etc/apk/repositories" || \
    echo "https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/community" >> "${ROOTFS}/etc/apk/repositories"
# host container also needs community for the --root apk calls
grep -q 'community' /etc/apk/repositories || \
    echo "https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/community" >> /etc/apk/repositories

apk --root "${ROOTFS}" --initdb --no-cache add \
    alpine-base \
    openrc \
    dropbear \
    dropbear-openrc \
    openssh-client \
    sudo \
    bash \
    shadow \
    e2fsprogs \
    e2fsprogs-extra \
    docker \
    crun \
    podman \
    netavark \
    fuse-overlayfs \
    iptables \
    iptables-legacy \
    ip6tables \
    kmod \
    nodejs \
    npm \
    py3-pip \
    py3-fastapi \
    uvicorn \
    curl \
    ca-certificates \
    tar \
    findutils \
    coreutils \
    socat \
    conntrack-tools \
    git

# ---------------------------------------------------------------------------
# Package mirror configuration (NEW-16) — baked into base.qcow2
# ---------------------------------------------------------------------------
# Default to the official Alpine CDN; set LINXR_APK_MIRROR (host/path, no
# scheme) to bake another mirror. Reachability is tested at image-build time
# and the CDN is used if the mirror is unreachable. At runtime
# init_bootstrap.sh rewrites the list from Settings > Package mirror.
LINXR_APK_MIRROR="${LINXR_APK_MIRROR:-dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}}"
LINXR_APK_FALLBACK="dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}"
if wget -q -T 3 -O /dev/null "https://${LINXR_APK_MIRROR}/main/aarch64/APKINDEX.tar.gz" 2>/dev/null \
|| wget -q -T 3 -O /dev/null "https://${LINXR_APK_MIRROR}/main/x86_64/APKINDEX.tar.gz" 2>/dev/null; then
    APK_HOST="$LINXR_APK_MIRROR"
    echo "Using fast Alpine mirror: https://$APK_HOST"
else
    APK_HOST="$LINXR_APK_FALLBACK"
    echo "Fast mirror unreachable, falling back to: https://$APK_HOST"
fi
cat > "${ROOTFS}/etc/apk/repositories" <<REPOEOF
https://${APK_HOST}/main
https://${APK_HOST}/community
REPOEOF

# npm registry (NEW-16)
mkdir -p "${ROOTFS}/root/.npm"
chroot "${ROOTFS}" npm config set registry https://registry.npmmirror.com
chroot "${ROOTFS}" npm config set fetch-retry-maxtimeout 120000
chroot "${ROOTFS}" npm config set fetch-retry-mintimeout 20000
chroot "${ROOTFS}" npm config set fetch-retries 5

# pip mirror (NEW-16)
mkdir -p "${ROOTFS}/root/.config/pip"
cat > "${ROOTFS}/root/.config/pip/pip.conf" <<'PIPEOF'
[global]
index-url = https://pypi.tuna.tsinghua.edu.cn/simple
trusted-host = pypi.tuna.tsinghua.edu.cn
timeout = 120
retries = 5
PIPEOF


# â”€â”€ Directory skeleton â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
mkdir -p "${ROOTFS}/proc" \
         "${ROOTFS}/sys" \
         "${ROOTFS}/sys/fs/cgroup" \
         "${ROOTFS}/dev" \
         "${ROOTFS}/dev/net" \
         "${ROOTFS}/run" \
         "${ROOTFS}/tmp" \
         "${ROOTFS}/root" \
         "${ROOTFS}/etc/sudoers.d" \
         "${ROOTFS}/etc/docker" \
         "${ROOTFS}/lib/modules" \
         "${ROOTFS}/mnt/sdcard"

mknod -m 666 "${ROOTFS}/dev/null"    c 1 3 2>/dev/null || true
mknod -m 666 "${ROOTFS}/dev/zero"    c 1 5 2>/dev/null || true
mknod -m 666 "${ROOTFS}/dev/urandom" c 1 9 2>/dev/null || true
mknod -m 600 "${ROOTFS}/dev/console" c 5 1 2>/dev/null || true
mknod -m 666 "${ROOTFS}/dev/tty"     c 5 0 2>/dev/null || true
mknod -m 660 "${ROOTFS}/dev/vda"     b 252 0 2>/dev/null || true
mknod -m 666 "${ROOTFS}/dev/net/tun" c 10 200 2>/dev/null || true
mknod -m 666 "${ROOTFS}/dev/fuse"    c 10 229 2>/dev/null || true

# â”€â”€ OpenRC runlevels â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
echo "--- Configuring OpenRC ---"
# Verbose boot so we can see which service stalls under TCG.
printf 'rc_verbose="yes"\nrc_logger="YES"\nrc_log_path="/tmp/openrc.log"\n' >> "${ROOTFS}/etc/rc.conf"
# Disable verbose OpenRC logging for boot speed. /etc/rc.conf is sourced by
# OpenRC, so later assignments override earlier ones (rc_verbose / rc_logger).
echo 'rc_logger="NO"'   >> "${ROOTFS}/etc/rc.conf"
echo 'rc_verbose="NO"'  >> "${ROOTFS}/etc/rc.conf"
mkdir -p "${ROOTFS}/etc/runlevels/sysinit" \
         "${ROOTFS}/etc/runlevels/boot" \
         "${ROOTFS}/etc/runlevels/default" \
         "${ROOTFS}/etc/runlevels/shutdown"

for svc in devfs dmesg mdev; do
    [ -f "${ROOTFS}/etc/init.d/${svc}" ] && \
        ln -sf /etc/init.d/${svc} "${ROOTFS}/etc/runlevels/sysinit/${svc}" 2>/dev/null || true
done
for svc in bootmisc hostname modules sysctl syslog; do
    [ -f "${ROOTFS}/etc/init.d/${svc}" ] && \
        ln -sf /etc/init.d/${svc} "${ROOTFS}/etc/runlevels/boot/${svc}" 2>/dev/null || true
done
for svc in networking dropbear local; do
    [ -f "${ROOTFS}/etc/init.d/${svc}" ] && \
        ln -sf /etc/init.d/${svc} "${ROOTFS}/etc/runlevels/default/${svc}" 2>/dev/null || true
done
# Docker is installed but not started at boot; it can be started manually
# after the VM is running. This avoids boot stalls under TCG.
rm -f "${ROOTFS}/etc/runlevels/default/docker"
rm -f "${ROOTFS}/etc/runlevels/boot/docker"
for svc in killprocs mount-ro savecache; do
    [ -f "${ROOTFS}/etc/init.d/${svc}" ] && \
        ln -sf /etc/init.d/${svc} "${ROOTFS}/etc/runlevels/shutdown/${svc}" 2>/dev/null || true
done

# â”€â”€ Networking â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
printf 'auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet static\n    address 10.0.2.15\n    netmask 255.255.255.0\n    gateway 10.0.2.2\n' \
    > "${ROOTFS}/etc/network/interfaces"

# DNS
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\noptions timeout:5 attempts:3 rotate\n' \
    > "${ROOTFS}/etc/resolv.conf"

echo "linxr" > "${ROOTFS}/etc/hostname"

printf '/dev/vda\t/\text4\trw,relatime\t0 1\ntmpfs\t/tmp\ttmpfs\tdefaults\t0 0\n' \
    > "${ROOTFS}/etc/fstab"

# â”€â”€ iptables-legacy (virt kernel has no nf_tables; Alpine iptables defaults to nft) â”€â”€
# Symlink in both /sbin and /usr/sbin so dockerd finds it regardless of PATH
ln -sf /sbin/iptables-legacy  "${ROOTFS}/sbin/iptables"    2>/dev/null || true
ln -sf /sbin/ip6tables-legacy "${ROOTFS}/sbin/ip6tables"   2>/dev/null || true
ln -sf /sbin/iptables-legacy  "${ROOTFS}/usr/sbin/iptables"  2>/dev/null || true
ln -sf /sbin/ip6tables-legacy "${ROOTFS}/usr/sbin/ip6tables" 2>/dev/null || true

# â”€â”€ sysctl â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
cat >> "${ROOTFS}/etc/sysctl.conf" << 'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
fs.inotify.max_user_instances=256
fs.inotify.max_user_watches=65536
EOF

# â”€â”€ Docker daemon config â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
cat > "${ROOTFS}/etc/docker/daemon.json" << 'EOF'
{
  "storage-driver": "vfs",
  "iptables": false,
  "bridge": "none",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

# â”€â”€ subuid/subgid for rootless containers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
echo 'root:100000:65536' >> "${ROOTFS}/etc/subuid"
echo 'root:100000:65536' >> "${ROOTFS}/etc/subgid"

# â”€â”€ Kernel modules for Docker bridge networking â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# Alpine linux-virt ships ip_tables, bridge, br_netfilter, veth etc. as loadable
# .ko files (not built-in). Docker requires them at runtime. Copy the actual .ko
# files from the build container's linux-virt installation into the rootfs so
# 
echo "--- Installing linux-virt kernel modules into rootfs ---"
apk add --no-cache linux-virt

KVER=""
for d in /lib/modules/*-virt; do
    [ -d "$d" ] && { KVER="${d##*/}"; break; }
done
echo "Kernel version: $KVER"

# Copy all kernel modules to guest rootfs
mkdir -p "${ROOTFS}/lib/modules/$KVER"
cp -r "/lib/modules/$KVER/." "${ROOTFS}/lib/modules/$KVER/"

# Build module dependency database inside rootfs
depmod -b "${ROOTFS}" "$KVER"
echo "--- Kernel modules ready (KVER=$KVER) ---"

# Record what this image ships so a running VM (and bug reports) can tell
# which Alpine and kernel versions an APK contains (#33).
cat > "${ROOTFS}/etc/linxr-release" <<RELEOF
ALPINE_VERSION=$(cat "${ROOTFS}/etc/alpine-release" 2>/dev/null || cat /etc/alpine-release)
KERNEL_VERSION=${KVER}
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RELEOF
cat "${ROOTFS}/etc/linxr-release"

# Runs in sysinit after mdev so /dev is populated.
# Docker networking modules are intentionally NOT loaded here — see start().
cat > "${ROOTFS}/etc/init.d/cgroups" << 'EOF'
#!/sbin/openrc-run
description="Mount cgroup2 and create device nodes"
depend() {
    need sysfs
    after mdev
    before sshd docker
}
start() {
    ebegin "Mounting cgroup2"
    mountpoint -q /sys/fs/cgroup || mount -t cgroup2 cgroup2 /sys/fs/cgroup
    printf '+cpuset +cpu +io +memory +hugetlb +pids\n' \
        > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true

    # /dev/fuse and /dev/net/tun are required by Docker and containers.
    # mdev populates /dev at sysinit but doesn't create these â€” do it here.
    [ -c /dev/fuse ] || mknod -m 666 /dev/fuse c 10 229
    mkdir -p /dev/net
    [ -c /dev/net/tun ] || mknod -m 666 /dev/net/tun c 10 200

    # Docker networking modules (bridge, br_netfilter, veth, nf_nat, ...) are
    # NOT loaded here. Boot speed under TCG: 20 sequential modprobes cost
    # ~30s. Since dockerd isn't started at boot, the modules will be loaded
    # on demand by the kernel / docker service when actually needed.

    eend 0
}
EOF
chmod +x "${ROOTFS}/etc/init.d/cgroups"
ln -sf /etc/init.d/cgroups "${ROOTFS}/etc/runlevels/sysinit/cgroups"

# Root filesystem growth (when the user picks a disk larger than DISK_SIZE_GB
# in Settings) is handled by /bootstrap/init_bootstrap.sh, which compares the
# block device size with the ext4 size on every boot. There is no OpenRC
# diskexpand service: the custom /sbin/init below never runs OpenRC.

# â”€â”€ inittab â€” ttyAMA0 console â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
cat > "${ROOTFS}/etc/inittab" << 'EOF'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
ttyAMA0::respawn:/sbin/getty -L ttyAMA0 115200 vt100
::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
EOF

# â”€â”€ SSH â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# Root login: the app generates a random root password per install and
# passes it in through QEMU fw_cfg (opt/root_password); /sbin/init below sets
# it before Dropbear starts. Settings -> SSH access shows it and can switch
# the VM to key-only login.

echo "--- Configuring dropbear ---"
# Dropbear is used instead of OpenSSH because its handshake is much lighter
# under TCG and avoids the multi-second banner/key-exchange delays that
# caused the app to stay stuck at "Booting...".
# Dropbear runs root login by default when root has a password.
# Ensure dropbear starts in default runlevel.
ln -sf /etc/init.d/dropbear "${ROOTFS}/etc/runlevels/default/dropbear" 2>/dev/null || true

# No host keys are baked into the image: every install would share them, so
# anyone could impersonate any user's VM. /sbin/init generates one ed25519
# key on first boot (fast, unlike RSA under TCG) and keeps it in user.qcow2.
mkdir -p "${ROOTFS}/etc/dropbear"
rm -f "${ROOTFS}"/etc/dropbear/dropbear_*_host_key

# â”€â”€ sdcard share service â€” mount Android /sdcard via 9p â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# VmManager exposes the Android external storage directory as a virtio-9p
# device with mount tag "sdcard". This service mounts it at /mnt/sdcard
# inside the VM, falling back to a tmpfs placeholder if the host share is
# unavailable (e.g. permission denied).
cat > "${ROOTFS}/etc/init.d/sdcardshare" << 'EOF'
#!/sbin/openrc-run
description="Mount Android /sdcard share"
depend() {
    after modules bootmisc
    use dev
}
start() {
    ebegin "Mounting /sdcard share"
    mkdir -p /mnt/sdcard
    if mount -t 9p -o trans=virtio,version=9p2000.L,uid=0,gid=0,rw sdcard /mnt/sdcard 2>/tmp/sdcard_mount.log; then
        eend 0
    else
        ewarn "sdcard 9p mount failed; using empty placeholder"
        mount -t tmpfs -o size=1M tmpfs /mnt/sdcard 2>/dev/null || true
        eend 0
    fi
}
EOF
chmod +x "${ROOTFS}/etc/init.d/sdcardshare"
ln -sf /etc/init.d/sdcardshare "${ROOTFS}/etc/runlevels/boot/sdcardshare"

# â”€â”€ Credentials â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# Fallback only: replaced on every boot by the per-install password from
# fw_cfg. The app falls back to it (and then sets its own password) when the
# guest kernel cannot read fw_cfg.
echo "root:alpine" | chroot "${ROOTFS}" chpasswd

# â”€â”€ sudo â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
printf '%%wheel ALL=(ALL) NOPASSWD: ALL\n' >> "${ROOTFS}/etc/sudoers"
printf 'root ALL=(ALL) NOPASSWD: ALL\n'    >  "${ROOTFS}/etc/sudoers.d/root"
chmod 440 "${ROOTFS}/etc/sudoers"
chmod 440 "${ROOTFS}/etc/sudoers.d/root"

# Replace standard OpenRC init with custom high-speed init script to boot in seconds
echo "--- Installing high-speed custom init ---"
rm -f "${ROOTFS}/sbin/init"
cat > "${ROOTFS}/sbin/init" << 'EOF'
#!/bin/sh
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# Mount API filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts
mount -t tmpfs -o mode=1777 tmpfs /tmp
mount -t tmpfs -o mode=0755 tmpfs /run

# Ensure modules are loaded
modprobe 9p 2>/dev/null || true
modprobe 9pnet_virtio 2>/dev/null || true
modprobe overlay 2>/dev/null || true

# Mount tmpfs on writeable system paths (directories already exist in Alpine)
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /run
mount -t tmpfs tmpfs /var/log
mount -t tmpfs tmpfs /var/run

# Mount cgroup2 and create device nodes for Docker and Kubernetes (k3s)
mkdir -p /sys/fs/cgroup
mount -t cgroup2 cgroup2 /sys/fs/cgroup
printf '+cpuset +cpu +io +memory +hugetlb +pids\n' > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
[ -c /dev/fuse ] || mknod -m 666 /dev/fuse c 10 229
[ -c /dev/kmsg ] || mknod -m 660 /dev/kmsg c 1 11
mkdir -p /dev/net
[ -c /dev/net/tun ] || mknod -m 666 /dev/net/tun c 10 200

# Setup network interfaces statically (SLIRP)
ip link set dev lo up
ip link set dev eth0 up
ip addr add 10.0.2.15/24 dev eth0
ip route add default via 10.0.2.2

# Remount root filesystem read-write for user and resize2fs use
mount -o remount,rw /
for i in 1 2 3 4 5; do
    if touch /etc/.rw_check 2>/dev/null; then
        rm -f /etc/.rw_check
        break
    fi
    sleep 0.1
done

# Mount shared sdcard folder
mkdir -p /mnt/sdcard
mount -t 9p -o trans=virtio,version=9p2000.L,uid=0,gid=0,rw sdcard /mnt/sdcard 2>/tmp/sdcard_mount.log || true

# Copy bootstrap files from shared folder to guest root
if [ -d /mnt/sdcard/bootstrap ]; then
    mkdir -p /bootstrap
    cp -r /mnt/sdcard/bootstrap/. /bootstrap/
    chmod +x /bootstrap/*.sh 2>/dev/null || true
    chmod +x /bootstrap/*.py 2>/dev/null || true
fi

# Run init_bootstrap.sh in the background
if [ -f /bootstrap/init_bootstrap.sh ]; then
    sh /bootstrap/init_bootstrap.sh >/var/log/bootstrap.log 2>&1 &
fi

# Start API server in the background
if [ -f /bootstrap/api_server.py ]; then
    python3 -u /bootstrap/api_server.py >/var/log/api_server.log 2>&1 &
fi

# Per-install SSH credentials. The root password and the key-only flag come
# from QEMU fw_cfg (set by the app); the host key is generated on first boot
# and kept. /bootstrap/init_bootstrap.sh does the same for older images.
modprobe qemu_fw_cfg 2>/dev/null || true
FWCFG=/sys/firmware/qemu_fw_cfg/by_name/opt
mkdir -p /etc/dropbear
[ -s /etc/dropbear/dropbear_ed25519_host_key ] || \
    dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key >/dev/null 2>&1
touch /etc/dropbear/.linxr_per_install
pw="$(cat "$FWCFG/root_password/raw" 2>/dev/null)"
case "$pw" in
    ''|*[!A-Za-z0-9]*) echo "WARN: no per-install root password in fw_cfg" ;;
    *) printf 'root:%s\n' "$pw" | chpasswd ;;
esac
unset pw
DROPBEAR_ARGS="-E -p 22 -r /etc/dropbear/dropbear_ed25519_host_key"
if [ "$(cat "$FWCFG/ssh_key_only/raw" 2>/dev/null)" = "1" ] && [ -s /root/.ssh/authorized_keys ]; then
    DROPBEAR_ARGS="$DROPBEAR_ARGS -s"
fi

# Start Dropbear SSH
touch /var/log/lastlog
# shellcheck disable=SC2086 # DROPBEAR_ARGS is a list of options
/usr/sbin/dropbear $DROPBEAR_ARGS && echo "$DROPBEAR_ARGS" > /run/linxr-dropbear.args

# dockerd is NOT started here. /bootstrap/init_bootstrap.sh starts it only
# when the Docker engine is selected (/etc/linxr_engine.mode = docker), so the
# default FastTrack (crun + podman) mode pays no daemon cost at boot.

echo "Linxr VM booted successfully in seconds!"
while true; do
    sleep 3600 &
    wait $!
done
EOF
chmod +x "${ROOTFS}/sbin/init"


# â”€â”€ Build ext4 image (no loop mount needed) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
echo "--- Creating ${IMAGE_SIZE} ext4 image ---"
mke2fs -t ext4 -d "${ROOTFS}" -L linxr /out/base.ext4 "${IMAGE_SIZE}"

echo "--- Converting to qcow2 ---"
qemu-img convert -f raw -O qcow2 -c /out/base.ext4 /out/base.qcow2
rm -f /out/base.ext4

echo "--- Compressing ---"
gzip -9 -c /out/base.qcow2 > /out/base.qcow2.gz
rm -f /out/base.qcow2

# Export kernel and initrd â€” must match the kernel version used for the modules
echo "--- Exporting kernel and initrd (${KVER}) ---"
cp /boot/vmlinuz-virt    /out/vmlinuz-virt
cp /boot/initramfs-virt  /out/initramfs-virt
chmod 644 /out/vmlinuz-virt /out/initramfs-virt
ls -lh /out/vmlinuz-virt /out/initramfs-virt

ls -lh /out/base.qcow2.gz
echo "Done."
