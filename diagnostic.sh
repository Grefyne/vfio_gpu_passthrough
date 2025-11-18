#!/bin/bash
# Comprehensive diagnostic script for NVIDIA GPU passthrough setup

set -e

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_NC='\033[0m' # No Color

echo "=== NVIDIA GPU Passthrough Diagnostic ==="
echo

# Check if running as root for some checks
if [ "$EUID" -eq 0 ]; then
    echo -e "${COLOR_YELLOW}Running as root${COLOR_NC}"
else
    echo -e "${COLOR_YELLOW}Running as non-root (some checks may be limited)${COLOR_NC}"
fi
echo

# 1. Detect NVIDIA devices
echo "=== NVIDIA PCI Devices ==="
if lspci -nn | grep -i nvidia > /dev/null; then
    lspci -nn | grep -i nvidia | while IFS= read -r line; do
        pci_addr=$(echo "$line" | awk '{print $1}')
        vendor_device=$(echo "$line" | grep -oP '\[\K[0-9a-f]{4}:[0-9a-f]{4}(?=\])')
        echo -e "${COLOR_GREEN}Found:${COLOR_NC} $line"
        echo "  PCI Address: $pci_addr"
        echo "  Vendor:Device ID: $vendor_device"

        # Check current driver
        current_driver=$(lspci -k -s "$pci_addr" | grep "Kernel driver in use:" | awk '{print $5}')
        if [ -n "$current_driver" ]; then
            echo "  Current driver: $current_driver"
        else
            echo "  Current driver: none"
        fi
        echo
    done
else
    echo -e "${COLOR_RED}No NVIDIA devices found${COLOR_NC}"
fi
echo

# 2. Check CPU vendor for IOMMU parameter
echo "=== CPU Information ==="
cpu_vendor=$(lscpu | grep "Vendor ID:" | awk '{print $3}')
echo "CPU Vendor: $cpu_vendor"
if [ "$cpu_vendor" = "GenuineIntel" ]; then
    echo -e "${COLOR_GREEN}Intel CPU detected - use intel_iommu parameter${COLOR_NC}"
    iommu_param="intel_iommu=on"
elif [ "$cpu_vendor" = "AuthenticAMD" ]; then
    echo -e "${COLOR_GREEN}AMD CPU detected - use amd_iommu parameter${COLOR_NC}"
    iommu_param="amd_iommu=on"
else
    echo -e "${COLOR_YELLOW}Unknown CPU vendor${COLOR_NC}"
    iommu_param="unknown"
fi
echo

# 3. Check IOMMU status in kernel
echo "=== IOMMU Status ==="
if dmesg | grep -i -e "IOMMU enabled" -e "IOMMU: enabled" > /dev/null 2>&1; then
    echo -e "${COLOR_GREEN}IOMMU is enabled in kernel${COLOR_NC}"
    dmesg | grep -i iommu | head -5
elif dmesg | grep -i iommu > /dev/null 2>&1; then
    echo -e "${COLOR_YELLOW}IOMMU mentioned in dmesg but may not be enabled${COLOR_NC}"
    dmesg | grep -i iommu | head -5
else
    echo -e "${COLOR_RED}IOMMU not found in kernel messages${COLOR_NC}"
    echo "You may need to enable it in BIOS and add kernel parameters"
fi
echo

# 4. Check GRUB configuration
echo "=== GRUB Configuration ==="
if [ -f /etc/default/grub ]; then
    cmdline=$(grep "^GRUB_CMDLINE_LINUX=" /etc/default/grub | head -1)
    echo "$cmdline"

    if echo "$cmdline" | grep -q "intel_iommu=on\|amd_iommu=on"; then
        echo -e "${COLOR_GREEN}IOMMU parameter found in GRUB${COLOR_NC}"
    else
        echo -e "${COLOR_YELLOW}IOMMU parameter NOT found in GRUB${COLOR_NC}"
        if [ "$iommu_param" != "unknown" ]; then
            echo "Suggestion: Add '$iommu_param iommu=pt' to GRUB_CMDLINE_LINUX"
        fi
    fi

    if [ -f /etc/default/grub.backup ]; then
        echo -e "${COLOR_GREEN}Backup exists: /etc/default/grub.backup${COLOR_NC}"
    else
        echo -e "${COLOR_YELLOW}No backup found: /etc/default/grub.backup${COLOR_NC}"
    fi
else
    echo -e "${COLOR_RED}/etc/default/grub not found${COLOR_NC}"
fi
echo

# 5. Check kernel modules
echo "=== Loaded Kernel Modules ==="
echo "NVIDIA modules:"
if lsmod | grep nvidia > /dev/null; then
    lsmod | grep nvidia | awk '{print "  " $1 " (size: " $2 ", used by: " $3 ")"}'
else
    echo -e "  ${COLOR_YELLOW}No NVIDIA modules loaded${COLOR_NC}"
fi
echo

echo "VFIO modules:"
if lsmod | grep vfio > /dev/null; then
    lsmod | grep vfio | awk '{print "  " $1 " (size: " $2 ", used by: " $3 ")"}'
else
    echo -e "  ${COLOR_YELLOW}No VFIO modules loaded${COLOR_NC}"
fi
echo

# 6. Check modprobe configurations
echo "=== Modprobe Configurations ==="
if ls /etc/modprobe.d/*nvidia* 2>/dev/null | grep -q .; then
    echo "NVIDIA configs found:"
    ls -l /etc/modprobe.d/*nvidia* 2>/dev/null
else
    echo -e "${COLOR_YELLOW}No NVIDIA modprobe configs found${COLOR_NC}"
fi
echo

if ls /etc/modprobe.d/*vfio* 2>/dev/null | grep -q .; then
    echo "VFIO configs found:"
    ls -l /etc/modprobe.d/*vfio* 2>/dev/null
    echo
    echo "Content:"
    cat /etc/modprobe.d/*vfio* 2>/dev/null
else
    echo -e "${COLOR_YELLOW}No VFIO modprobe configs found${COLOR_NC}"
fi
echo

# 7. Check modules-load.d
echo "=== Module Auto-load Configuration ==="
if ls /etc/modules-load.d/*.conf 2>/dev/null | grep -q .; then
    echo "Found module loader configs:"
    for conf in /etc/modules-load.d/*.conf; do
        echo "  $conf:"
        cat "$conf" | grep -v '^#' | grep -v '^$' | sed 's/^/    /'
    done
else
    echo -e "${COLOR_YELLOW}No module loader configs in /etc/modules-load.d/${COLOR_NC}"
fi
echo

# 8. Check systemd service
echo "=== Systemd Service Status ==="
if systemctl list-unit-files | grep -q nvidia-passthrough.service; then
    echo "Service found:"
    systemctl status nvidia-passthrough.service --no-pager || true
else
    echo -e "${COLOR_YELLOW}nvidia-passthrough.service not installed${COLOR_NC}"
fi
echo

# 9. Check IOMMU groups
echo "=== IOMMU Groups (for NVIDIA devices) ==="
if [ -d /sys/kernel/iommu_groups ]; then
    for d in /sys/kernel/iommu_groups/*/devices/*; do
        if [ -e "$d" ]; then
            device=$(basename "$d")
            if lspci -nn -s "$device" | grep -qi nvidia; then
                group=$(basename $(dirname $(dirname "$d")))
                echo -e "${COLOR_GREEN}IOMMU Group $group:${COLOR_NC}"
                lspci -nn -s "$device"
            fi
        fi
    done
else
    echo -e "${COLOR_RED}IOMMU groups not found - IOMMU may not be enabled${COLOR_NC}"
fi
echo

# 10. Check hybrid graphics configuration
echo "=== Hybrid Graphics Configuration ==="

# Check for integrated graphics
igpu_count=$(lspci | grep -c -i "VGA.*AMD\|VGA.*Intel")
if [ "$igpu_count" -gt 0 ]; then
    echo -e "${COLOR_GREEN}Integrated graphics detected:${COLOR_NC}"
    lspci | grep -i "VGA.*AMD\|VGA.*Intel"
    echo

    # Check PRIME mode
    if command -v prime-select > /dev/null 2>&1; then
        prime_mode=$(prime-select query 2>/dev/null || echo "unknown")
        echo "PRIME mode: $prime_mode"

        if [ "$prime_mode" = "on-demand" ] || [ "$prime_mode" = "nvidia" ]; then
            echo -e "${COLOR_RED}⚠ PRIME is set to '$prime_mode' - will cause issues with passthrough!${COLOR_NC}"
            echo "Run: sudo prime-select intel"
        elif [ "$prime_mode" = "intel" ]; then
            echo -e "${COLOR_GREEN}✓ PRIME correctly set to iGPU mode${COLOR_NC}"
        fi
        echo
    else
        echo -e "${COLOR_YELLOW}prime-select not available (may not be needed)${COLOR_NC}"
        echo
    fi

    # Check nvidia-persistenced
    if systemctl is-active nvidia-persistenced.service > /dev/null 2>&1; then
        echo -e "${COLOR_RED}⚠ nvidia-persistenced.service is ACTIVE - will conflict with VFIO!${COLOR_NC}"
        echo "Run: sudo systemctl disable nvidia-persistenced.service"
        echo "     sudo systemctl stop nvidia-persistenced.service"
    elif systemctl is-enabled nvidia-persistenced.service > /dev/null 2>&1; then
        echo -e "${COLOR_YELLOW}⚠ nvidia-persistenced.service is enabled but not running${COLOR_NC}"
        echo "Consider: sudo systemctl disable nvidia-persistenced.service"
    else
        echo -e "${COLOR_GREEN}✓ nvidia-persistenced.service is disabled${COLOR_NC}"
    fi
    echo

    # Check which GPU is being used for display
    if command -v nvidia-smi > /dev/null 2>&1; then
        if nvidia-smi > /dev/null 2>&1; then
            nvidia_disp=$(nvidia-smi 2>/dev/null | grep -c "Disp.A.*On" || true)
            if [ -n "$nvidia_disp" ] && [ "$nvidia_disp" -gt 0 ] 2>/dev/null; then
                echo -e "${COLOR_RED}⚠ NVIDIA GPU is being used for display!${COLOR_NC}"
                echo "Connect monitor to motherboard ports and switch PRIME mode"
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
    echo -e "${COLOR_RED}⚠ WARNING: You will lose display when GPU passthrough is active!${COLOR_NC}"
    echo "Consider enabling integrated graphics in BIOS or using SSH"
fi
echo

# 11. Summary and recommendations
echo "=== Summary & Recommendations ==="
echo

# Check if setup is ready
ready=true

if ! lspci -nn | grep -i nvidia > /dev/null; then
    echo -e "${COLOR_RED}✗ No NVIDIA GPU detected${COLOR_NC}"
    ready=false
else
    echo -e "${COLOR_GREEN}✓ NVIDIA GPU detected${COLOR_NC}"
fi

# Check IOMMU - if groups exist and have devices, it's working
if [ -d /sys/kernel/iommu_groups ] && [ -n "$(ls -A /sys/kernel/iommu_groups 2>/dev/null)" ]; then
    echo -e "${COLOR_GREEN}✓ IOMMU is enabled (IOMMU groups present)${COLOR_NC}"
elif dmesg 2>/dev/null | grep -qi "amd-vi\|intel.*iommu.*enabled\|iommu.*enabled"; then
    echo -e "${COLOR_GREEN}✓ IOMMU appears to be enabled${COLOR_NC}"
else
    echo -e "${COLOR_RED}✗ IOMMU not enabled${COLOR_NC}"
    ready=false
fi

if ! modinfo vfio_pci > /dev/null 2>&1; then
    echo -e "${COLOR_RED}✗ vfio_pci module not available${COLOR_NC}"
    ready=false
else
    echo -e "${COLOR_GREEN}✓ vfio_pci module available${COLOR_NC}"
fi

# Check PRIME if integrated graphics present
if [ "$igpu_count" -gt 0 ] && command -v prime-select > /dev/null 2>&1; then
    prime_mode=$(prime-select query 2>/dev/null || echo "unknown")
    if [ "$prime_mode" = "on-demand" ] || [ "$prime_mode" = "nvidia" ]; then
        echo -e "${COLOR_RED}✗ PRIME mode needs to be switched to 'intel'${COLOR_NC}"
        ready=false
    fi
fi

# Check nvidia-persistenced
if systemctl is-active nvidia-persistenced.service > /dev/null 2>&1; then
    echo -e "${COLOR_RED}✗ nvidia-persistenced.service must be stopped${COLOR_NC}"
    ready=false
fi

echo
if [ "$ready" = true ]; then
    echo -e "${COLOR_GREEN}System appears ready for GPU passthrough!${COLOR_NC}"
else
    echo -e "${COLOR_RED}System NOT ready - fix the issues above first${COLOR_NC}"
fi
