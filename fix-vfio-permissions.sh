#!/bin/bash
# Fix VFIO device permissions for user session VMs
# Allows your user to access VFIO devices for GPU passthrough

set -e

COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_BLUE='\033[0;34m'
COLOR_NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root"
    echo "Usage: sudo $0"
    exit 1
fi

echo "=== Fixing VFIO Device Permissions ==="
echo

# Get the actual username
ACTUAL_USER="${SUDO_USER:-$USER}"
echo "Configuring VFIO access for user: $ACTUAL_USER"
echo

# Check if user is in kvm group
if ! groups "$ACTUAL_USER" | grep -q "\bkvm\b"; then
    echo "Adding $ACTUAL_USER to 'kvm' group..."
    usermod -aG kvm "$ACTUAL_USER"
    echo -e "${COLOR_GREEN}✓ Added to kvm group${COLOR_NC}"
else
    echo -e "${COLOR_GREEN}✓ Already in kvm group${COLOR_NC}"
fi

# Check if user is in libvirt group
if ! groups "$ACTUAL_USER" | grep -q "\blibvirt\b"; then
    echo "Adding $ACTUAL_USER to 'libvirt' group..."
    usermod -aG libvirt "$ACTUAL_USER"
    echo -e "${COLOR_GREEN}✓ Added to libvirt group${COLOR_NC}"
else
    echo -e "${COLOR_GREEN}✓ Already in libvirt group${COLOR_NC}"
fi
echo

# Create udev rule for VFIO devices
UDEV_RULE="/etc/udev/rules.d/99-vfio-permissions.rules"

cat > "$UDEV_RULE" << 'EOF'
# VFIO device permissions for GPU passthrough
# Allow kvm group to access VFIO devices

SUBSYSTEM=="vfio", OWNER="root", GROUP="kvm", MODE="0660"
EOF

echo -e "${COLOR_GREEN}✓ Created udev rule: $UDEV_RULE${COLOR_NC}"
echo "Content:"
cat "$UDEV_RULE"
echo

# Reload udev rules
echo "Reloading udev rules..."
udevadm control --reload-rules
udevadm trigger
echo -e "${COLOR_GREEN}✓ Udev rules reloaded${COLOR_NC}"
echo

# Set permissions on current VFIO devices immediately
echo "Setting permissions on current VFIO devices..."
if [ -d /dev/vfio ]; then
    chown root:kvm /dev/vfio/vfio
    chmod 660 /dev/vfio/vfio

    for device in /dev/vfio/*; do
        if [ "$device" != "/dev/vfio/vfio" ] && [ -e "$device" ]; then
            chown root:kvm "$device"
            chmod 660 "$device"
            echo "  $(basename $device) - permissions set"
        fi
    done
    echo -e "${COLOR_GREEN}✓ VFIO device permissions updated${COLOR_NC}"
else
    echo -e "${COLOR_YELLOW}Warning: /dev/vfio not found${COLOR_NC}"
fi
echo

# Show current VFIO devices
echo "Current VFIO devices:"
ls -l /dev/vfio/ 2>/dev/null || echo "  None found"
echo

echo "=== Configuration Complete ==="
echo
echo "User '$ACTUAL_USER' groups:"
groups "$ACTUAL_USER"
echo
echo -e "${COLOR_YELLOW}IMPORTANT: Log out and log back in for group changes to take effect!${COLOR_NC}"
echo
echo "After logging back in, verify groups with:"
echo "  groups"
echo "  (should include 'kvm' and 'libvirt')"
echo
echo "Then try starting your VM again."
echo
