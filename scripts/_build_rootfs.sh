#!/bin/sh
# Runs inside Docker (linux/arm64 Alpine container).
# Builds a minimal Alpine Linux rootfs with openssh + sudo,
# then packages it as base.qcow2.gz in /out.
set -e

ROOTFS=/tmp/rootfs
IMAGE_SIZE=2G

echo "--- Installing build tools ---"
apk add --no-cache e2fsprogs qemu-img

# ── Bootstrap rootfs ─────────────────────────────────────────────────────────
echo "--- Bootstrapping Alpine rootfs ---"
mkdir -p "${ROOTFS}/etc/apk/keys"
cp /etc/apk/keys/* "${ROOTFS}/etc/apk/keys/"
cp /etc/apk/repositories "${ROOTFS}/etc/apk/"
# docker and fuse-overlayfs are in community — ensure it's enabled
grep -q 'community' "${ROOTFS}/etc/apk/repositories" || \
    echo "https://dl-cdn.alpinelinux.org/alpine/v3.19/community" >> "${ROOTFS}/etc/apk/repositories"
# host container also needs community for the --root apk calls
grep -q 'community' /etc/apk/repositories || \
    echo "https://dl-cdn.alpinelinux.org/alpine/v3.19/community" >> /etc/apk/repositories

apk --root "${ROOTFS}" --initdb --no-cache add \
    alpine-base \
    openrc \
    openssh \
    sudo \
    bash \
    shadow \
    e2fsprogs \
    e2fsprogs-extra \
    docker \
    fuse-overlayfs \
    iptables \
    iptables-legacy \
    ip6tables \
    kmod

# ── Directory skeleton ────────────────────────────────────────────────────────
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
         "${ROOTFS}/lib/modules"

mknod -m 666 "${ROOTFS}/dev/null"    c 1 3 2>/dev/null || true
mknod -m 666 "${ROOTFS}/dev/zero"    c 1 5 2>/dev/null || true
mknod -m 666 "${ROOTFS}/dev/urandom" c 1 9 2>/dev/null || true
mknod -m 600 "${ROOTFS}/dev/console" c 5 1 2>/dev/null || true
mknod -m 666 "${ROOTFS}/dev/tty"     c 5 0 2>/dev/null || true
mknod -m 660 "${ROOTFS}/dev/vda"     b 252 0 2>/dev/null || true
mknod -m 666 "${ROOTFS}/dev/net/tun" c 10 200 2>/dev/null || true
mknod -m 666 "${ROOTFS}/dev/fuse"    c 10 229 2>/dev/null || true

# ── OpenRC runlevels ─────────────────────────────────────────────────────────
echo "--- Configuring OpenRC ---"
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
for svc in networking sshd local docker; do
    [ -f "${ROOTFS}/etc/init.d/${svc}" ] && \
        ln -sf /etc/init.d/${svc} "${ROOTFS}/etc/runlevels/default/${svc}" 2>/dev/null || true
done
for svc in killprocs mount-ro savecache; do
    [ -f "${ROOTFS}/etc/init.d/${svc}" ] && \
        ln -sf /etc/init.d/${svc} "${ROOTFS}/etc/runlevels/shutdown/${svc}" 2>/dev/null || true
done

# ── Networking ───────────────────────────────────────────────────────────────
printf 'auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet static\n    address 10.0.2.15\n    netmask 255.255.255.0\n    gateway 10.0.2.2\n' \
    > "${ROOTFS}/etc/network/interfaces"

# DNS
printf 'nameserver 10.0.2.3\nnameserver 8.8.8.8\n' \
    > "${ROOTFS}/etc/resolv.conf"

echo "linxr" > "${ROOTFS}/etc/hostname"

printf '/dev/vda\t/\text4\trw,relatime\t0 1\ntmpfs\t/tmp\ttmpfs\tdefaults\t0 0\n' \
    > "${ROOTFS}/etc/fstab"

# ── iptables-legacy (virt kernel has no nf_tables; Alpine iptables defaults to nft) ──
# Symlink in both /sbin and /usr/sbin so dockerd finds it regardless of PATH
ln -sf /sbin/iptables-legacy  "${ROOTFS}/sbin/iptables"    2>/dev/null || true
ln -sf /sbin/ip6tables-legacy "${ROOTFS}/sbin/ip6tables"   2>/dev/null || true
ln -sf /sbin/iptables-legacy  "${ROOTFS}/usr/sbin/iptables"  2>/dev/null || true
ln -sf /sbin/ip6tables-legacy "${ROOTFS}/usr/sbin/ip6tables" 2>/dev/null || true

# ── sysctl ────────────────────────────────────────────────────────────────────
cat >> "${ROOTFS}/etc/sysctl.conf" << 'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
fs.inotify.max_user_instances=256
fs.inotify.max_user_watches=65536
EOF

# ── Docker daemon config ──────────────────────────────────────────────────────
cat > "${ROOTFS}/etc/docker/daemon.json" << 'EOF'
{
  "storage-driver": "overlay2",
  "exec-opts": ["native.cgroupdriver=cgroupfs"],
  "iptables": true,
  "ip-masq": true,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

# ── subuid/subgid for rootless containers ─────────────────────────────────────
echo 'root:100000:65536' >> "${ROOTFS}/etc/subuid"
echo 'root:100000:65536' >> "${ROOTFS}/etc/subgid"

# ── Kernel modules for Docker bridge networking ───────────────────────────────
# Alpine linux-virt ships ip_tables, bridge, br_netfilter, veth etc. as loadable
# .ko files (not built-in). Docker requires them at runtime. Copy the actual .ko
# files from the build container's linux-virt installation into the rootfs so
# modprobe can load them in the guest.
echo "--- Installing linux-virt kernel modules into rootfs ---"
apk add --no-cache linux-virt

KVER=$(ls /lib/modules/ | grep '\-virt' | head -1)
echo "Kernel version: $KVER"

# Alpine ships .ko.gz (gzip-compressed modules). kmod handles them natively.
# List of modules needed for Docker bridge networking.
DOCKER_MODULES="
kernel/lib/libcrc32c.ko.gz
kernel/net/ipv6/ipv6.ko.gz
kernel/net/802/stp.ko.gz
kernel/net/llc/llc.ko.gz
kernel/net/ipv4/netfilter/nf_defrag_ipv4.ko.gz
kernel/net/ipv6/netfilter/nf_defrag_ipv6.ko.gz
kernel/net/netfilter/x_tables.ko.gz
kernel/net/netfilter/nf_conntrack.ko.gz
kernel/net/netfilter/nf_nat.ko.gz
kernel/net/netfilter/xt_conntrack.ko.gz
kernel/net/netfilter/xt_MASQUERADE.ko.gz
kernel/net/netfilter/xt_addrtype.ko.gz
kernel/net/ipv4/netfilter/ip_tables.ko.gz
kernel/net/ipv4/netfilter/iptable_filter.ko.gz
kernel/net/ipv4/netfilter/iptable_nat.ko.gz
kernel/net/bridge/bridge.ko.gz
kernel/net/bridge/br_netfilter.ko.gz
kernel/drivers/net/veth.ko.gz
kernel/fs/fuse/fuse.ko.gz
kernel/fs/overlayfs/overlay.ko.gz
"

for MOD_PATH in $DOCKER_MODULES; do
    SRC="/lib/modules/$KVER/$MOD_PATH"
    DST="${ROOTFS}/lib/modules/$KVER/$MOD_PATH"
    if [ -f "$SRC" ]; then
        mkdir -p "$(dirname "$DST")"
        cp "$SRC" "$DST"
        echo "  copied: $MOD_PATH"
    else
        echo "  WARNING: $SRC not found — skipping"
    fi
done

# Copy module metadata files so modprobe/depmod can resolve dependencies
mkdir -p "${ROOTFS}/lib/modules/$KVER"
for META in modules.builtin modules.order modules.builtin.modinfo; do
    SRC="/lib/modules/$KVER/$META"
    [ -f "$SRC" ] && cp "$SRC" "${ROOTFS}/lib/modules/$KVER/$META"
done

# Build module dependency database inside rootfs
depmod -b "${ROOTFS}" "$KVER"
echo "--- Kernel modules ready (KVER=$KVER) ---"

# ── cgroup2 + device nodes + modprobe OpenRC service ─────────────────────────
# Runs in sysinit after mdev so /dev is populated.
# Also loads the Docker networking kernel modules before dockerd starts.
cat > "${ROOTFS}/etc/init.d/cgroups" << 'EOF'
#!/sbin/openrc-run
description="Mount cgroup2, create device nodes, load Docker kernel modules"
depend() {
    need sysfs
    after mdev
    before diskexpand sshd docker
}
start() {
    ebegin "Mounting cgroup2"
    mountpoint -q /sys/fs/cgroup || mount -t cgroup2 cgroup2 /sys/fs/cgroup
    printf '+cpuset +cpu +io +memory +hugetlb +pids\n' \
        > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true

    # /dev/fuse and /dev/net/tun are required by Docker and containers.
    # mdev populates /dev at sysinit but doesn't create these — do it here.
    [ -c /dev/fuse ] || mknod -m 666 /dev/fuse c 10 229
    mkdir -p /dev/net
    [ -c /dev/net/tun ] || mknod -m 666 /dev/net/tun c 10 200

    # Load kernel modules required for Docker bridge networking.
    # These are loadable .ko files in Alpine linux-virt (not built-in).
    ebegin "Loading Docker networking modules"
    modprobe libcrc32c     2>/dev/null || true
    modprobe ipv6          2>/dev/null || true
    modprobe stp           2>/dev/null || true
    modprobe llc           2>/dev/null || true
    modprobe nf_defrag_ipv4 2>/dev/null || true
    modprobe nf_defrag_ipv6 2>/dev/null || true
    modprobe x_tables      2>/dev/null || true
    modprobe nf_conntrack  2>/dev/null || true
    modprobe nf_nat        2>/dev/null || true
    modprobe xt_conntrack  2>/dev/null || true
    modprobe xt_MASQUERADE 2>/dev/null || true
    modprobe xt_addrtype   2>/dev/null || true
    modprobe ip_tables     2>/dev/null || true
    modprobe iptable_filter 2>/dev/null || true
    modprobe iptable_nat   2>/dev/null || true
    modprobe bridge        2>/dev/null || true
    modprobe br_netfilter  2>/dev/null || true
    modprobe veth          2>/dev/null || true
    modprobe fuse          2>/dev/null || true
    modprobe overlay       2>/dev/null || true

    # Apply bridge sysctl now that br_netfilter is loaded
    sysctl -w net.bridge.bridge-nf-call-iptables=1  2>/dev/null || true
    sysctl -w net.bridge.bridge-nf-call-ip6tables=1 2>/dev/null || true

    eend 0
}
EOF
chmod +x "${ROOTFS}/etc/init.d/cgroups"
ln -sf /etc/init.d/cgroups "${ROOTFS}/etc/runlevels/sysinit/cgroups"

# ── diskexpand OpenRC service — resize2fs runs before sshd ───────────────────
# This runs in the boot runlevel (completes before default/sshd starts).
# It expands the ext4 filesystem to fill whatever virtual disk size was set
# when user.qcow2 was created (e.g. 8 GB, 50 GB).
cat > "${ROOTFS}/etc/init.d/diskexpand" << 'EOF'
#!/sbin/openrc-run
description="Expand filesystem to fill virtual disk"
depend() {
    after modules bootmisc
    use dev
}
start() {
    [ -f /etc/.disk_expanded ] && return 0
    ebegin "Expanding filesystem to disk size"
    /usr/sbin/resize2fs /dev/vda >/tmp/resize.log 2>&1
    local ret=$?
    /bin/df -h / >> /tmp/resize.log 2>&1
    [ $ret -eq 0 ] && /bin/touch /etc/.disk_expanded
    eend 0
}
EOF
chmod +x "${ROOTFS}/etc/init.d/diskexpand"
ln -sf /etc/init.d/diskexpand "${ROOTFS}/etc/runlevels/boot/diskexpand"

# ── inittab — ttyAMA0 console ─────────────────────────────────────────────────
cat > "${ROOTFS}/etc/inittab" << 'EOF'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
ttyAMA0::respawn:/sbin/getty -L ttyAMA0 115200 vt100
::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
EOF

# ── SSH ───────────────────────────────────────────────────────────────────────
echo "--- Configuring SSH ---"
chroot "${ROOTFS}" ssh-keygen -A

# Use sed to override any existing (uncommented) directives — first match wins
# in sshd_config, so we can't just append when lines already exist.
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/'       "${ROOTFS}/etc/ssh/sshd_config"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "${ROOTFS}/etc/ssh/sshd_config"
sed -i 's/^#\?UsePAM.*/UsePAM no/'                          "${ROOTFS}/etc/ssh/sshd_config"
# Fallback: append if sed found nothing to replace
grep -q '^PermitRootLogin'       "${ROOTFS}/etc/ssh/sshd_config" || echo 'PermitRootLogin yes'       >> "${ROOTFS}/etc/ssh/sshd_config"
grep -q '^PasswordAuthentication' "${ROOTFS}/etc/ssh/sshd_config" || echo 'PasswordAuthentication yes' >> "${ROOTFS}/etc/ssh/sshd_config"
grep -q '^UsePAM'                "${ROOTFS}/etc/ssh/sshd_config" || echo 'UsePAM no'                >> "${ROOTFS}/etc/ssh/sshd_config"

# ── Credentials ───────────────────────────────────────────────────────────────
echo "root:alpine" | chroot "${ROOTFS}" chpasswd

# ── sudo ─────────────────────────────────────────────────────────────────────
printf '%%wheel ALL=(ALL) NOPASSWD: ALL\n' >> "${ROOTFS}/etc/sudoers"
printf 'root ALL=(ALL) NOPASSWD: ALL\n'    >  "${ROOTFS}/etc/sudoers.d/root"
chmod 440 "${ROOTFS}/etc/sudoers"
chmod 440 "${ROOTFS}/etc/sudoers.d/root"

# ── Build ext4 image (no loop mount needed) ───────────────────────────────────
echo "--- Creating ${IMAGE_SIZE} ext4 image ---"
mke2fs -t ext4 -d "${ROOTFS}" -L linxr /out/base.ext4 "${IMAGE_SIZE}"

echo "--- Converting to qcow2 ---"
qemu-img convert -f raw -O qcow2 -c /out/base.ext4 /out/base.qcow2
rm -f /out/base.ext4

echo "--- Compressing ---"
gzip -9 -c /out/base.qcow2 > /out/base.qcow2.gz
rm -f /out/base.qcow2

# Export kernel and initrd — must match the kernel version used for the modules
echo "--- Exporting kernel and initrd (${KVER}) ---"
cp /boot/vmlinuz-virt    /out/vmlinuz-virt
cp /boot/initramfs-virt  /out/initramfs-virt
chmod 644 /out/vmlinuz-virt /out/initramfs-virt
ls -lh /out/vmlinuz-virt /out/initramfs-virt

ls -lh /out/base.qcow2.gz
echo "Done."
