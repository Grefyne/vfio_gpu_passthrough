#!/bin/bash
# Rollback script for GPU passthrough configuration
# This script removes GPU passthrough configuration and restores normal operation

set -e

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${COLOR_RED}Error: This script must be run as root${COLOR_NC}"
    echo "Usage: sudo $0"
    exit 1
fi

echo "=== GPU Passthrough Rollback ==="
echo
echo -e "${COLOR_YELLOW}This will remove GPU passthrough configuration and restore normal NVIDIA driver operation${COLOR_NC}"
echo
echo "This script will:"
echo "  1. Disable and remove nvidia-passthrough systemd service"
echo "  2. Remove modprobe blacklist and VFIO configurations"
echo "  3. Remove module loader configurations"
echo "  4. Restore GRUB configuration (if backup exists)"
echo "  5. Update initramfs"
echo
read -p "Do you want to continue? (y/n): " -r
if [[ ! $REPLY =~ ^[Yy]([Ee][Ss])?$ ]]; then
    echo "Aborted."
    exit 0
fi
echo

# Find the most recent backup directory
BACKUP_DIR=$(ls -td /root/gpu-passthrough-backups-* 2>/dev/null | head -1)

if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
    echo -e "${COLOR_GREEN}Found backup directory: $BACKUP_DIR${COLOR_NC}"
else
    echo -e "${COLOR_YELLOW}No backup directory found, will remove configs without restoring backups${COLOR_NC}"
fi
echo

# 1. Disable and remove systemd service
echo "=== Removing Systemd Service ==="
if systemctl is-enabled nvidia-passthrough.service >/dev/null 2>&1; then
    echo "Disabling nvidia-passthrough.service..."
    systemctl disable nvidia-passthrough.service
fi

if systemctl is-active nvidia-passthrough.service >/dev/null 2>&1; then
    echo "Stopping nvidia-passthrough.service..."
    systemctl stop nvidia-passthrough.service
fi

if [ -f /etc/systemd/system/nvidia-passthrough.service ]; then
    echo "Removing service file..."
    rm -f /etc/systemd/system/nvidia-passthrough.service
    systemctl daemon-reload
fi
echo -e "${COLOR_GREEN}Service removed${COLOR_NC}"
echo

# 2. Remove modprobe configurations
echo "=== Removing Modprobe Configurations ==="

# Remove old blacklist-based configs
if [ -f /etc/modprobe.d/nvidia-passthrough-blacklist.conf ]; then
    echo "Removing nvidia-passthrough-blacklist.conf (old config)..."
    rm -f /etc/modprobe.d/nvidia-passthrough-blacklist.conf
fi

if [ -f /etc/modprobe.d/vfio-passthrough.conf ]; then
    echo "Removing vfio-passthrough.conf (old config)..."
    rm -f /etc/modprobe.d/vfio-passthrough.conf
fi

# Remove new softdep-based config
if [ -f /etc/modprobe.d/vfio.conf ]; then
    echo "Removing vfio.conf (softdep config)..."
    rm -f /etc/modprobe.d/vfio.conf
fi

echo -e "${COLOR_GREEN}Modprobe configs removed${COLOR_NC}"
echo

# 3. Remove module loader configuration
echo "=== Removing Module Loader Configuration ==="

# Remove old module loader config
if [ -f /etc/modules-load.d/vfio-passthrough.conf ]; then
    echo "Removing vfio-passthrough.conf (old config)..."
    rm -f /etc/modules-load.d/vfio-passthrough.conf
fi

# Remove new module loader config
if [ -f /etc/modules-load.d/vfio.conf ]; then
    echo "Removing vfio.conf (new config)..."
    rm -f /etc/modules-load.d/vfio.conf
fi

echo -e "${COLOR_GREEN}Module loader config removed${COLOR_NC}"
echo

# 4. Restore GRUB configuration
echo "=== Restoring GRUB Configuration ==="
if [ -n "$BACKUP_DIR" ] && [ -f "$BACKUP_DIR/grub.backup" ]; then
    echo "Restoring GRUB from backup..."
    cp "$BACKUP_DIR/grub.backup" /etc/default/grub
    echo -e "${COLOR_GREEN}GRUB configuration restored${COLOR_NC}"
elif [ -f /etc/default/grub ]; then
    echo -e "${COLOR_YELLOW}No GRUB backup found, manually removing IOMMU parameters...${COLOR_NC}"
    # Remove IOMMU parameters
    sed -i 's/intel_iommu=on //g; s/amd_iommu=on //g; s/iommu=pt //g' /etc/default/grub
    echo -e "${COLOR_GREEN}IOMMU parameters removed from GRUB${COLOR_NC}"
else
    echo -e "${COLOR_YELLOW}GRUB configuration not found${COLOR_NC}"
fi

if [ -f /etc/default/grub ]; then
    echo "Updating GRUB..."
    update-grub
    echo -e "${COLOR_GREEN}GRUB updated${COLOR_NC}"
fi
echo

# 5. Update initramfs
echo "=== Updating Initramfs ==="
update-initramfs -u
echo -e "${COLOR_GREEN}Initramfs updated${COLOR_NC}"
echo

# 6. Optional: Remove scripts
echo "=== Optional: Remove GPU Passthrough Scripts ==="
echo "The following scripts in /usr/local/bin/ were created by system-config.sh:"
echo "  - nvidia-passthrough-setup.sh"
echo "  - launch-vm-with-gpu.sh"
echo "  - gpu-passthrough-rollback.sh"
echo
echo "This will ONLY remove these 3 scripts, not any other files in /usr/local/bin/"
echo
read -p "Do you want to remove these GPU passthrough scripts? (y/n): " -r
if [[ $REPLY =~ ^[Yy]([Ee][Ss])?$ ]]; then
    if [ -f /usr/local/bin/nvidia-passthrough-setup.sh ]; then
        rm -f /usr/local/bin/nvidia-passthrough-setup.sh
        echo "Removed nvidia-passthrough-setup.sh"
    fi
    if [ -f /usr/local/bin/launch-vm-with-gpu.sh ]; then
        rm -f /usr/local/bin/launch-vm-with-gpu.sh
        echo "Removed launch-vm-with-gpu.sh"
    fi
    if [ -f /usr/local/bin/gpu-passthrough-rollback.sh ]; then
        rm -f /usr/local/bin/gpu-passthrough-rollback.sh
        echo "Removed gpu-passthrough-rollback.sh"
    fi
    echo -e "${COLOR_GREEN}GPU passthrough scripts removed${COLOR_NC}"
else
    echo "GPU passthrough scripts kept in /usr/local/bin/"
fi
echo

# Summary
echo "========================================="
echo -e "${COLOR_GREEN}Rollback Complete!${COLOR_NC}"
echo "========================================="
echo
echo "GPU passthrough configuration has been removed."
echo
if [ -n "$BACKUP_DIR" ]; then
    echo "Original backups preserved in: $BACKUP_DIR"
    echo
fi
echo -e "${COLOR_YELLOW}IMPORTANT: You must REBOOT your system for changes to take effect${COLOR_NC}"
echo
echo "After reboot, NVIDIA drivers should load normally and your GPU"
echo "will be available to the host system again."
echo
read -p "Do you want to reboot now? (y/n): " -r
if [[ $REPLY =~ ^[Yy]([Ee][Ss])?$ ]]; then
    echo "Rebooting in 5 seconds... (Ctrl+C to cancel)"
    sleep 5
    reboot
else
    echo "Please reboot manually when ready"
fi
