#!/bin/sh
# Alpine VM bootstrap — runs on first boot inside the QEMU VM.
# Sets up root SSH access and installs essential packages.
# Connect via:  ssh root@localhost -p 2222   (password: alpine)

echo "=== Alpine VM Bootstrap Starting ==="

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

echo "=== Bootstrap Complete ==="
