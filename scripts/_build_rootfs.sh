#!/bin/sh
# Runs inside Docker (linux/arm64 Alpine container).
# Builds a minimal Alpine Linux rootfs with openssh + sudo,
# then packages it as base.qcow2.gz in /out.
set -e

ROOTFS=/tmp/rootfs
IMAGE_SIZE=1500M

echo "--- Installing build tools ---"
apk add --no-cache e2fsprogs qemu-img

# ── Bootstrap rootfs ─────────────────────────────────────────────────────────
echo "--- Bootstrapping Alpine rootfs ---"
mkdir -p "${ROOTFS}/etc/apk/keys"
cp /etc/apk/keys/* "${ROOTFS}/etc/apk/keys/"
cp /etc/apk/repositories "${ROOTFS}/etc/apk/"

apk --root "${ROOTFS}" --initdb --no-cache add \
    alpine-base \
    openrc \
    openssh \
    sudo \
    bash \
    shadow

# ── Directory skeleton ────────────────────────────────────────────────────────
mkdir -p "${ROOTFS}/proc" \
         "${ROOTFS}/sys" \
         "${ROOTFS}/dev" \
         "${ROOTFS}/run" \
         "${ROOTFS}/tmp" \
         "${ROOTFS}/root" \
         "${ROOTFS}/etc/sudoers.d"

mknod -m 666 "${ROOTFS}/dev/null"    c 1 3 2>/dev/null || true
mknod -m 666 "${ROOTFS}/dev/zero"    c 1 5 2>/dev/null || true
mknod -m 666 "${ROOTFS}/dev/urandom" c 1 9 2>/dev/null || true
mknod -m 600 "${ROOTFS}/dev/console" c 5 1 2>/dev/null || true
mknod -m 666 "${ROOTFS}/dev/tty"     c 5 0 2>/dev/null || true
mknod -m 660 "${ROOTFS}/dev/vda"     b 252 0 2>/dev/null || true

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
for svc in networking sshd local; do
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

ls -lh /out/base.qcow2.gz
echo "Done."
