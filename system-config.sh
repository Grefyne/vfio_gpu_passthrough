#!/bin/bash
# Improved NVIDIA GPU Passthrough Setup using softdep
# Single script that uses proper kernel module dependency management
# Based on Arch Wiki and best practices

set -e  # Exit on error

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_BLUE='\033[0;34m'
COLOR_NC='\033[0m'

BACKUP_DIR="/root/gpu-passthrough-backups-$(date +%Y%m%d-%H%M%S)"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${COLOR_RED}Error: This script must be run as root${COLOR_NC}"
    echo "Usage: sudo $0"
    exit 1
fi

echo "=== NVIDIA GPU Passthrough Setup (Improved) ==="
echo
echo "This script will:"
echo "  1. Enable IOMMU in GRUB"
echo "  2. Configure VFIO to bind your NVIDIA GPU using softdep"
echo "  3. Ensure proper module load order (VFIO before NVIDIA)"
echo "  4. Create backups of all modified files"
echo
echo -e "${COLOR_BLUE}Advantages of this approach:${COLOR_NC}"
echo "  - Uses softdep instead of blacklisting (cleaner, safer)"
echo "  - Single configuration file instead of multiple"
echo "  - NVIDIA drivers can still load if VFIO fails (fallback)"
echo "  - Industry standard approach (Arch Wiki recommended)"
echo
echo

# Detect NVIDIA devices automatically
echo "Detecting NVIDIA devices..."
nvidia_devices=$(lspci -nn | grep -i nvidia)

if [ -z "$nvidia_devices" ]; then
    echo -e "${COLOR_RED}Error: No NVIDIA devices found${COLOR_NC}"
    exit 1
fi

echo -e "${COLOR_GREEN}Found NVIDIA devices:${COLOR_NC}"
echo "$nvidia_devices"
echo

# Extract PCI addresses and vendor:device IDs
gpu_pci_addr=$(echo "$nvidia_devices" | grep "VGA\|3D" | head -1 | awk '{print $1}')
audio_pci_addr=$(echo "$nvidia_devices" | grep "Audio" | head -1 | awk '{print $1}')

gpu_vendor_device=$(echo "$nvidia_devices" | grep "VGA\|3D" | head -1 | grep -oP '\[\K[0-9a-f]{4}:[0-9a-f]{4}(?=\])')
audio_vendor_device=$(echo "$nvidia_devices" | grep "Audio" | head -1 | grep -oP '\[\K[0-9a-f]{4}:[0-9a-f]{4}(?=\])')

if [ -z "$gpu_pci_addr" ]; then
    echo -e "${COLOR_RED}Error: Could not detect GPU PCI address${COLOR_NC}"
    exit 1
fi

echo "GPU PCI Address: $gpu_pci_addr"
echo "GPU Vendor:Device: $gpu_vendor_device"

if [ -n "$audio_pci_addr" ]; then
    echo "Audio PCI Address: $audio_pci_addr"
    echo "Audio Vendor:Device: $audio_vendor_device"
fi
echo

# Detect CPU vendor for IOMMU parameter
cpu_vendor=$(lscpu | grep "Vendor ID:" | awk '{print $3}')
if [ "$cpu_vendor" = "GenuineIntel" ]; then
    iommu_param="intel_iommu=on"
elif [ "$cpu_vendor" = "AuthenticAMD" ]; then
    iommu_param="amd_iommu=on"
else
    echo -e "${COLOR_RED}Error: Unknown CPU vendor: $cpu_vendor${COLOR_NC}"
    exit 1
fi

echo "CPU Vendor: $cpu_vendor"
echo "IOMMU Parameter: $iommu_param"
echo

# Pre-flight checks for hybrid graphics systems
echo "=== Pre-flight Checks ==="

# Check for integrated graphics
igpu_count=$(lspci | grep -c -i "VGA.*AMD\|VGA.*Intel" || echo "0")
if [ "$igpu_count" -gt 0 ]; then
    echo -e "${COLOR_GREEN}Detected integrated graphics${COLOR_NC}"
    lspci | grep -i "VGA.*AMD\|VGA.*Intel"
    echo

    # Check PRIME mode
    if command -v prime-select > /dev/null 2>&1; then
        prime_mode=$(prime-select query 2>/dev/null || echo "unknown")
        echo "PRIME mode: $prime_mode"

        if [ "$prime_mode" = "on-demand" ] || [ "$prime_mode" = "nvidia" ]; then
            echo -e "${COLOR_RED}⚠ WARNING: PRIME is set to '$prime_mode'${COLOR_NC}"
            echo -e "${COLOR_YELLOW}This may cause issues. Consider switching to iGPU-only mode:${COLOR_NC}"
            echo "  sudo prime-select intel"
            echo "  Then log out and log back in"
            echo
        elif [ "$prime_mode" = "intel" ]; then
            echo -e "${COLOR_GREEN}✓ PRIME correctly set to iGPU mode${COLOR_NC}"
        fi
    fi

    # Check and disable nvidia-persistenced
    if systemctl is-active nvidia-persistenced.service > /dev/null 2>&1; then
        echo -e "${COLOR_YELLOW}Stopping nvidia-persistenced.service...${COLOR_NC}"
        systemctl stop nvidia-persistenced.service
        systemctl disable nvidia-persistenced.service
        echo -e "${COLOR_GREEN}✓ nvidia-persistenced.service stopped and disabled${COLOR_NC}"
    elif systemctl is-enabled nvidia-persistenced.service > /dev/null 2>&1; then
        echo -e "${COLOR_YELLOW}Disabling nvidia-persistenced.service...${COLOR_NC}"
        systemctl disable nvidia-persistenced.service
        echo -e "${COLOR_GREEN}✓ nvidia-persistenced.service disabled${COLOR_NC}"
    else
        echo -e "${COLOR_GREEN}✓ nvidia-persistenced.service already disabled${COLOR_NC}"
    fi
    echo

    # Check which GPU is being used for display
    if command -v nvidia-smi > /dev/null 2>&1; then
        if nvidia-smi > /dev/null 2>&1; then
            nvidia_disp=$(nvidia-smi 2>/dev/null | grep -c "Disp.A.*On" || echo "0")
            if [ -n "$nvidia_disp" ] && [ "$nvidia_disp" -gt 0 ] 2>/dev/null; then
                echo -e "${COLOR_YELLOW}⚠ NVIDIA GPU is currently being used for display${COLOR_NC}"
                echo "After setup, the system will fall back to iGPU automatically."
            else
                echo -e "${COLOR_GREEN}✓ NVIDIA GPU is not being used for display${COLOR_NC}"
            fi
        else
            echo -e "${COLOR_GREEN}✓ NVIDIA driver not loaded (GPU available for passthrough)${COLOR_NC}"
        fi
    else
        echo -e "${COLOR_YELLOW}nvidia-smi not available - cannot check display status${COLOR_NC}"
    fi
else
    echo -e "${COLOR_YELLOW}No integrated graphics detected${COLOR_NC}"
    echo -e "${COLOR_RED}⚠ WARNING: After setup, NVIDIA GPU will be unavailable to host!${COLOR_NC}"
    echo "You will need SSH access if display doesn't work."
    echo
fi
echo

# Confirmation
echo -e "${COLOR_YELLOW}This will configure GPU passthrough using the softdep method.${COLOR_NC}"
echo -e "${COLOR_YELLOW}Your NVIDIA GPU will be bound to VFIO-PCI after reboot.${COLOR_NC}"
echo
read -p "Continue with configuration? (y/n): " -r
if [[ ! $REPLY =~ ^[Yy]([Ee][Ss])?$ ]]; then
    echo "Aborted."
    exit 0
fi
echo

# Create backup directory
echo "Creating backup directory: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
echo

# 1. Backup and update GRUB configuration
echo "=== Configuring GRUB ==="
if [ -f /etc/default/grub ]; then
    # Create backup
    cp /etc/default/grub "$BACKUP_DIR/grub.backup"
    echo -e "${COLOR_GREEN}Backed up /etc/default/grub${COLOR_NC}"

    # Check if IOMMU parameters already present
    if grep -q "$iommu_param" /etc/default/grub; then
        echo -e "${COLOR_YELLOW}IOMMU parameters already present in GRUB${COLOR_NC}"
    else
        # Add IOMMU parameters to GRUB_CMDLINE_LINUX
        current_cmdline=$(grep '^GRUB_CMDLINE_LINUX=' /etc/default/grub | head -1)

        if echo "$current_cmdline" | grep -q 'GRUB_CMDLINE_LINUX=""'; then
            # Empty, just add parameters
            sed -i "s/^GRUB_CMDLINE_LINUX=\"\"/GRUB_CMDLINE_LINUX=\"$iommu_param iommu=pt\"/" /etc/default/grub
        else
            # Has existing parameters, append
            sed -i "s/^GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"$iommu_param iommu=pt /" /etc/default/grub
        fi

        echo -e "${COLOR_GREEN}Added IOMMU parameters to GRUB${COLOR_NC}"
    fi

    # Update GRUB
    echo "Updating GRUB..."
    update-grub
    echo -e "${COLOR_GREEN}GRUB updated${COLOR_NC}"
else
    echo -e "${COLOR_RED}Error: /etc/default/grub not found${COLOR_NC}"
    exit 1
fi
echo

# 2. Create single VFIO configuration file using softdep
echo "=== Creating VFIO Configuration (softdep method) ==="
vfio_file="/etc/modprobe.d/vfio.conf"

# Backup if exists
if [ -f "$vfio_file" ]; then
    cp "$vfio_file" "$BACKUP_DIR/vfio.conf.backup"
    echo -e "${COLOR_YELLOW}Backed up existing VFIO config${COLOR_NC}"
fi

# Build the IDs list
vfio_ids="$gpu_vendor_device"
if [ -n "$audio_vendor_device" ]; then
    vfio_ids="$vfio_ids,$audio_vendor_device"
fi

cat > "$vfio_file" << EOF
# VFIO GPU Passthrough Configuration
# Created by system-config.sh (improved version)
#
# GPU: $gpu_pci_addr ($gpu_vendor_device)
$([ -n "$audio_vendor_device" ] && echo "# Audio: $audio_pci_addr ($audio_vendor_device)")
#
# Using softdep ensures VFIO loads before NVIDIA drivers
# This is safer than blacklisting - NVIDIA can still load if VFIO fails

# Ensure vfio-pci loads before any NVIDIA drivers
softdep nvidia pre: vfio-pci
softdep nvidia_modeset pre: vfio-pci
softdep nvidia_uvm pre: vfio-pci
softdep nvidia_drm pre: vfio-pci

# Ensure vfio-pci loads before HD audio driver
softdep snd_hda_intel pre: vfio-pci

# Bind specific device IDs to VFIO-PCI (disabled by default)
# options vfio-pci ids=$vfio_ids
EOF

echo -e "${COLOR_GREEN}Created: $vfio_file${COLOR_NC}"
echo "Content:"
cat "$vfio_file"
echo

# 3. Configure VFIO modules to load early
echo "=== Configuring Early VFIO Module Loading ==="
modules_file="/etc/modules-load.d/vfio.conf"

# Backup if exists
if [ -f "$modules_file" ]; then
    cp "$modules_file" "$BACKUP_DIR/vfio-modules.conf.backup"
    echo -e "${COLOR_YELLOW}Backed up existing modules config${COLOR_NC}"
fi

cat > "$modules_file" << 'EOF'
# Load VFIO modules early for GPU passthrough
# Created by system-config.sh
vfio
vfio_iommu_type1
vfio_pci
EOF

echo -e "${COLOR_GREEN}Created: $modules_file${COLOR_NC}"
echo

# 3b. Install initramfs early hook for per-PCI binding
echo "=== Installing per-PCI VFIO bind initramfs hook ==="
hook_dir="/etc/initramfs-tools/scripts/init-top"
hook_path="$hook_dir/vfio-bind"

mkdir -p "$hook_dir"

cat > "$hook_path" << 'EOF'
#!/bin/sh
# Early initramfs hook: bind selected PCI devices to vfio-pci by BDF
# Reads BDFs from /etc/vfio-bind.list (one per line), ignores comments and blanks

PREREQ=""

prereqs() {
    echo "$PREREQ"
}

case "$1" in
    prereqs)
        prereqs
        exit 0
        ;;
esac

. /scripts/functions

# Ensure vfio-pci is available in initramfs
modprobe vfio_pci 2>/dev/null || true

BIND_LIST="/etc/vfio-bind.list"

if [ -r "$BIND_LIST" ]; then
    while IFS= read -r line; do
        # strip comments and whitespace
        case "$line" in
            ''|'#'*) continue ;;
        esac

        BDF="$line"
        case "$BDF" in
            0000:*) ;;
            *) BDF="0000:$BDF" ;;
        esac

        DEV_PATH="/sys/bus/pci/devices/$BDF"
        [ -e "$DEV_PATH" ] || continue

        # Set driver override to vfio-pci
        echo vfio-pci > "$DEV_PATH/driver_override" 2>/dev/null || true

        # Unbind from current driver if bound
        if [ -L "$DEV_PATH/driver" ]; then
            CURDRV=$(basename "$(readlink -f "$DEV_PATH/driver")")
            echo "$BDF" > "/sys/bus/pci/drivers/$CURDRV/unbind" 2>/dev/null || true
        fi

        # Bind to vfio-pci
        echo "$BDF" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true
    done < "$BIND_LIST"
fi

exit 0
EOF

chmod 0755 "$hook_path"
echo -e "${COLOR_GREEN}Installed: $hook_path${COLOR_NC}"
echo

# 3c. Install hook to include /etc/vfio-bind.list into initramfs
echo "=== Installing initramfs include hook for vfio-bind.list ==="
hook_copy_dir="/etc/initramfs-tools/hooks"
hook_copy_path="$hook_copy_dir/vfio-bind-list"

mkdir -p "$hook_copy_dir"

cat > "$hook_copy_path" << 'EOF'
#!/bin/sh
set -e

PREREQ=""

prereqs() {
    echo "$PREREQ"
}

case "$1" in
    prereqs)
        prereqs
        exit 0
        ;;
esac

. /usr/share/initramfs-tools/hook-functions

if [ -e /etc/vfio-bind.list ]; then
    mkdir -p "$DESTDIR/etc"
    cp -p /etc/vfio-bind.list "$DESTDIR/etc/vfio-bind.list"
fi

exit 0
EOF

chmod 0755 "$hook_copy_path"
echo -e "${COLOR_GREEN}Installed: $hook_copy_path${COLOR_NC}"
echo

# 3d. Ensure vfio modules are included in initramfs
echo "=== Ensuring VFIO modules listed for initramfs ==="
INIT_MODULES="/etc/initramfs-tools/modules"
touch "$INIT_MODULES"
grep -q '^vfio$' "$INIT_MODULES" || echo 'vfio' >> "$INIT_MODULES"
grep -q '^vfio_iommu_type1$' "$INIT_MODULES" || echo 'vfio_iommu_type1' >> "$INIT_MODULES"
grep -q '^vfio_pci$' "$INIT_MODULES" || echo 'vfio_pci' >> "$INIT_MODULES"
echo -e "${COLOR_GREEN}✓ VFIO modules ensured in $INIT_MODULES${COLOR_NC}"
echo

# 4. Remove old configuration files if they exist (from previous scripts)
echo "=== Cleaning Up Old Configuration Files ==="
old_files=(
    "/etc/modprobe.d/nvidia-passthrough-blacklist.conf"
    "/etc/modprobe.d/vfio-passthrough.conf"
    "/etc/modules-load.d/vfio-passthrough.conf"
    "/etc/systemd/system/nvidia-passthrough.service"
    "/usr/local/bin/nvidia-passthrough-setup.sh"
)

cleaned=false
for old_file in "${old_files[@]}"; do
    if [ -f "$old_file" ]; then
        cp "$old_file" "$BACKUP_DIR/$(basename $old_file).old"
        rm "$old_file"
        echo -e "${COLOR_YELLOW}Removed old config: $old_file (backed up)${COLOR_NC}"
        cleaned=true
    fi
done

if [ "$cleaned" = true ]; then
    systemctl daemon-reload
    echo -e "${COLOR_GREEN}Cleaned up old configuration files${COLOR_NC}"
else
    echo "No old configuration files found"
fi
echo

# Update initramfs
echo "=== Updating initramfs ==="
update-initramfs -u
echo -e "${COLOR_GREEN}initramfs updated${COLOR_NC}"
echo

# Summary
echo "=== Setup Complete ==="
echo
echo -e "${COLOR_GREEN}✓ IOMMU enabled in GRUB ($iommu_param iommu=pt)${COLOR_NC}"
echo -e "${COLOR_GREEN}✓ VFIO configured with softdep (safer than blacklist)${COLOR_NC}"
echo -e "${COLOR_GREEN}✓ Device IDs to bind: $vfio_ids${COLOR_NC}"
echo -e "${COLOR_GREEN}✓ VFIO modules configured to load early${COLOR_NC}"
echo -e "${COLOR_GREEN}✓ Backups saved to: $BACKUP_DIR${COLOR_NC}"
echo

echo -e "${COLOR_BLUE}How this works:${COLOR_NC}"
echo "  1. VFIO modules load early in boot process"
echo "  2. softdep ensures VFIO-PCI loads BEFORE NVIDIA drivers"
echo "  3. VFIO-PCI claims your GPU (${gpu_vendor_device}) first"
echo "  4. NVIDIA drivers see no devices to bind, so they don't load"
echo "  5. If VFIO fails, NVIDIA drivers can still load (safe fallback)"
echo

echo -e "${COLOR_YELLOW}Next steps:${COLOR_NC}"
echo "  1. Reboot your system: sudo reboot"
echo "  2. After reboot, verify AMD iGPU is working"
echo "  3. Run diagnostic.sh to check VFIO binding"
echo "  4. Verify NVIDIA GPU is bound to vfio-pci:"
echo "     lspci -k -s $gpu_pci_addr"
echo

echo -e "${COLOR_YELLOW}Expected behavior after reboot:${COLOR_NC}"
echo "  - System boots with AMD iGPU providing display"
echo "  - NVIDIA GPU bound to vfio-pci driver"
echo "  - No NVIDIA kernel modules loaded"
echo "  - IOMMU groups active"
echo "  - GPU ready for VM passthrough"
echo

echo -e "${COLOR_GREEN}If you need to revert these changes, run: sudo ./rollback.sh${COLOR_NC}"
echo
