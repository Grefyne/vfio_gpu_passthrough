#!/bin/bash
# Fix memlock limits for VFIO GPU passthrough
# This allows VMs to lock memory required for GPU passthrough

set -e

COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root"
    echo "Usage: sudo $0"
    exit 1
fi

echo "=== Fixing Memory Lock Limits for VFIO ==="
echo

# Get the actual username (even when run with sudo)
ACTUAL_USER="${SUDO_USER:-$USER}"

echo "Configuring limits for user: $ACTUAL_USER"
echo

# Create limits configuration
LIMITS_FILE="/etc/security/limits.d/99-vfio-memlock.conf"

cat > "$LIMITS_FILE" << EOF
# Memory lock limits for VFIO GPU passthrough
# Created by fix-memlock-limits.sh

# Allow user to lock unlimited memory for VMs with GPU passthrough
$ACTUAL_USER soft memlock unlimited
$ACTUAL_USER hard memlock unlimited

# Also allow libvirt-qemu user (for system VMs)
@libvirt soft memlock unlimited
@libvirt hard memlock unlimited
EOF

echo -e "${COLOR_GREEN}✓ Created: $LIMITS_FILE${COLOR_NC}"
echo
echo "Configuration:"
cat "$LIMITS_FILE"
echo

# Also set it in libvirt qemu.conf for good measure
QEMU_CONF="/etc/libvirt/qemu.conf"

if [ -f "$QEMU_CONF" ]; then
    echo "Updating libvirt qemu.conf..."

    # Backup first
    cp "$QEMU_CONF" "$QEMU_CONF.backup-$(date +%Y%m%d-%H%M%S)"

    # Check if user line exists, if not add it
    if ! grep -q "^user = " "$QEMU_CONF"; then
        echo "user = \"$ACTUAL_USER\"" >> "$QEMU_CONF"
        echo -e "${COLOR_GREEN}✓ Added user configuration${COLOR_NC}"
    fi

    # Check if group line exists, if not add it
    if ! grep -q "^group = " "$QEMU_CONF"; then
        ACTUAL_GROUP=$(id -gn "$ACTUAL_USER")
        echo "group = \"$ACTUAL_GROUP\"" >> "$QEMU_CONF"
        echo -e "${COLOR_GREEN}✓ Added group configuration${COLOR_NC}"
    fi
fi
echo

echo "=== Configuration Complete ==="
echo
echo -e "${COLOR_YELLOW}IMPORTANT: You must log out and log back in (or reboot) for changes to take effect!${COLOR_NC}"
echo
echo "After logging back in, verify with:"
echo "  ulimit -l"
echo "  (should show 'unlimited')"
echo
echo "Then try starting your VM again."
echo
