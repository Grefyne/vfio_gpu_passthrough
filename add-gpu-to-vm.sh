#!/bin/bash
# Add NVIDIA GPU passthrough to existing libvirt/virt-manager VM
# This script adds PCI passthrough devices to a VM configuration

set -e

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_BLUE='\033[0;34m'
COLOR_NC='\033[0m'

# Check for VM name argument
if [ -z "$1" ]; then
    echo -e "${COLOR_RED}Error: VM name required${COLOR_NC}"
    echo
    echo "Usage: $0 <vm-name> [--system]"
    echo
    echo "Options:"
    echo "  --system    Use system libvirt connection (requires sudo)"
    echo "  (default)   Use user session connection"
    echo
    echo "Available VMs (user session):"
    virsh --connect qemu:///session list --all 2>/dev/null || echo "  None found or not running"
    echo
    echo "Available VMs (system, requires sudo):"
    sudo virsh --connect qemu:///system list --all 2>/dev/null || echo "  None found or permission denied"
    exit 1
fi

VM_NAME="$1"
VIRSH_CONNECT="qemu:///session"

# Check if --system flag is provided
if [ "$2" = "--system" ]; then
    if [ "$EUID" -ne 0 ]; then
        echo -e "${COLOR_RED}Error: --system requires root privileges${COLOR_NC}"
        echo "Usage: sudo $0 <vm-name> --system"
        exit 1
    fi
    VIRSH_CONNECT="qemu:///system"
fi

# Set virsh command based on connection
if [ "$VIRSH_CONNECT" = "qemu:///system" ]; then
    VIRSH="virsh --connect qemu:///system"
else
    VIRSH="virsh --connect qemu:///session"
fi

echo "Using connection: $VIRSH_CONNECT"
echo

# Check if VM exists
if ! ${VIRSH} dominfo "$VM_NAME" > /dev/null 2>&1; then
    echo -e "${COLOR_RED}Error: VM '$VM_NAME' not found on $VIRSH_CONNECT${COLOR_NC}"
    echo
    echo "Available VMs:"
    ${VIRSH} list --all
    exit 1
fi

echo "=== Add NVIDIA GPU to VM: $VM_NAME ==="
echo

# Detect NVIDIA devices and select the one bound to vfio-pci
echo "Detecting NVIDIA devices..."
nvidia_devices=$(lspci -nn | grep -i nvidia)

selected_gpu=""
for addr in $(echo "$nvidia_devices" | grep "VGA\|3D" | awk '{print $1}'); do
    if lspci -k -s "$addr" | grep -q "Kernel driver in use: vfio-pci"; then
        selected_gpu="$addr"
        break
    fi
done

if [ -z "$selected_gpu" ]; then
    echo -e "${COLOR_RED}Error: No NVIDIA GPU bound to vfio-pci found${COLOR_NC}"
    echo "Enable per-PCI binding and reboot, then try again."
    exit 1
fi

gpu_pci_addr="$selected_gpu"

# Try to find matching audio function (same slot .1)
maybe_audio=$(echo "$gpu_pci_addr" | sed 's/\.0$/.1/')
if lspci -nn -s "$maybe_audio" | grep -qi "Audio"; then
    audio_pci_addr="$maybe_audio"
else
    audio_pci_addr=$(echo "$nvidia_devices" | grep "Audio" | awk '{print $1}' | grep -E "^$(echo $gpu_pci_addr | cut -d: -f1):$(echo $gpu_pci_addr | cut -d: -f2 | cut -d. -f1)\\.")
fi

gpu_vendor_device=$(lspci -nn -s "$gpu_pci_addr" | grep -oP '\\[\K[0-9a-f]{4}:[0-9a-f]{4}(?=\\])' | head -1)
if [ -n "$audio_pci_addr" ]; then
    audio_vendor_device=$(lspci -nn -s "$audio_pci_addr" | grep -oP '\\[\K[0-9a-f]{4}:[0-9a-f]{4}(?=\\])' | head -1)
fi

echo -e "${COLOR_GREEN}Found:${COLOR_NC}"
echo "GPU: $gpu_pci_addr (${gpu_vendor_device:-unknown})"
if [ -n "$audio_pci_addr" ]; then
    echo "Audio: $audio_pci_addr (${audio_vendor_device:-unknown})"
fi
echo

echo -e "${COLOR_GREEN}✓ GPU is bound to vfio-pci${COLOR_NC}"
echo

# Check permissions and limits for user session VMs
if [ "$VIRSH_CONNECT" = "qemu:///session" ]; then
    echo "=== Checking User Session VM Requirements ==="

    issues_found=false

    # Check if user is in kvm group
    if ! groups "$USER" 2>/dev/null | grep -q "\bkvm\b"; then
        echo -e "${COLOR_YELLOW}⚠ User not in 'kvm' group${COLOR_NC}"
        issues_found=true
    else
        echo -e "${COLOR_GREEN}✓ User in kvm group${COLOR_NC}"
    fi

    # Check if user is in libvirt group
    if ! groups "$USER" 2>/dev/null | grep -q "\blibvirt\b"; then
        echo -e "${COLOR_YELLOW}⚠ User not in 'libvirt' group${COLOR_NC}"
        issues_found=true
    else
        echo -e "${COLOR_GREEN}✓ User in libvirt group${COLOR_NC}"
    fi

    # Check VFIO device permissions
    if [ -d /dev/vfio ]; then
        vfio_perms_ok=true
        for device in /dev/vfio/*; do
            if [ -e "$device" ] && [ "$device" != "/dev/vfio/vfio" ]; then
                device_group=$(stat -c '%G' "$device" 2>/dev/null)
                if [ "$device_group" != "kvm" ]; then
                    vfio_perms_ok=false
                    break
                fi
            fi
        done

        if [ "$vfio_perms_ok" = true ]; then
            echo -e "${COLOR_GREEN}✓ VFIO device permissions OK${COLOR_NC}"
        else
            echo -e "${COLOR_YELLOW}⚠ VFIO devices not owned by kvm group${COLOR_NC}"
            issues_found=true
        fi
    fi

    # Check memlock limits (only if ulimit is available)
    if command -v ulimit > /dev/null 2>&1; then
        memlock_limit=$(ulimit -l 2>/dev/null || echo "unknown")
        if [ "$memlock_limit" = "unlimited" ]; then
            echo -e "${COLOR_GREEN}✓ Memory lock limit: unlimited${COLOR_NC}"
        else
            echo -e "${COLOR_YELLOW}⚠ Memory lock limit: $memlock_limit (should be unlimited)${COLOR_NC}"
            issues_found=true
        fi
    fi

    echo

    if [ "$issues_found" = true ]; then
        echo -e "${COLOR_YELLOW}=== Permission Issues Detected ===${COLOR_NC}"
        echo
        echo "To fix these issues, run:"
        echo "  sudo ./fix-vfio-permissions.sh"
        echo "  sudo ./fix-memlock-limits.sh"
        echo
        echo "Then log out and log back in for changes to take effect."
        echo
        read -p "Continue anyway? (y/n): " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted. Please fix permissions first."
            exit 1
        fi
        echo
    fi
fi

# Parse PCI address (format: 01:00.0 -> domain=0, bus=0x01, slot=0x00, function=0x0)
parse_pci() {
    local pci="$1"
    local bus=$(echo "$pci" | cut -d: -f1)
    local slot=$(echo "$pci" | cut -d: -f2 | cut -d. -f1)
    local func=$(echo "$pci" | cut -d. -f2)

    echo "domain='0x0000' bus='0x$bus' slot='0x$slot' function='0x$func'"
}

gpu_pci_parsed=$(parse_pci "$gpu_pci_addr")
audio_pci_parsed=$(parse_pci "$audio_pci_addr")

echo "Parsed PCI addresses:"
echo "GPU:   $gpu_pci_parsed"
if [ -n "$audio_pci_addr" ]; then
    echo "Audio: $audio_pci_parsed"
fi
echo

# Check current VM state
vm_state=$(${VIRSH} domstate "$VM_NAME")
if [ "$vm_state" = "running" ]; then
    echo -e "${COLOR_YELLOW}Warning: VM is currently running${COLOR_NC}"
    echo "The VM must be shut down to modify hardware configuration."
    echo
    read -p "Shut down VM now? (y/n): " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Shutting down VM..."
        ${VIRSH} shutdown "$VM_NAME"
        echo "Waiting for shutdown..."
        sleep 5
    else
        echo "Please shut down the VM and run this script again."
        exit 1
    fi
fi

# Backup current VM configuration
echo "Creating backup of VM configuration..."
BACKUP_FILE="$VM_NAME-backup-$(date +%Y%m%d-%H%M%S).xml"
${VIRSH} dumpxml "$VM_NAME" > "$BACKUP_FILE"
echo -e "${COLOR_GREEN}Backup saved: $BACKUP_FILE${COLOR_NC}"
echo

# Create temporary XML files for GPU and audio
TEMP_GPU_XML=$(mktemp)
TEMP_AUDIO_XML=$(mktemp)

cat > "$TEMP_GPU_XML" << EOF
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address $gpu_pci_parsed/>
  </source>
  <rom bar='on'/>
</hostdev>
EOF

if [ -n "$audio_pci_addr" ]; then
    cat > "$TEMP_AUDIO_XML" << EOF
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address $audio_pci_parsed/>
  </source>
</hostdev>
EOF
fi

echo "=== GPU Configuration to Add ==="
echo "GPU device:"
cat "$TEMP_GPU_XML"
echo
if [ -n "$audio_pci_addr" ]; then
    echo "Audio device:"
    cat "$TEMP_AUDIO_XML"
    echo
fi
echo "=============================="
echo

read -p "Add GPU passthrough to VM '$VM_NAME'? (y/n): " -r
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    rm -f "$TEMP_GPU_XML" "$TEMP_AUDIO_XML"
    exit 0
fi

# Add GPU device
echo "Adding GPU to VM configuration..."
${VIRSH} attach-device "$VM_NAME" "$TEMP_GPU_XML" --config
echo -e "${COLOR_GREEN}✓ GPU added${COLOR_NC}"

# Add audio device if present
if [ -n "$audio_pci_addr" ]; then
    echo "Adding audio device to VM configuration..."
    ${VIRSH} attach-device "$VM_NAME" "$TEMP_AUDIO_XML" --config
    echo -e "${COLOR_GREEN}✓ Audio added${COLOR_NC}"
fi

echo

# Cleanup
rm -f "$TEMP_GPU_XML" "$TEMP_AUDIO_XML"

# Additional recommendations
echo "=== Configuration Complete ==="
echo
echo -e "${COLOR_GREEN}NVIDIA GPU has been added to VM: $VM_NAME${COLOR_NC}"
echo
echo "Next steps:"
echo "  1. Start the VM: virsh start $VM_NAME"
echo "     Or use virt-manager GUI"
echo
echo "  2. In Windows 11:"
echo "     - Install NVIDIA drivers from nvidia.com"
echo "     - Reboot Windows after driver installation"
echo "     - GPU should appear in Device Manager"
echo
echo "  3. Optional optimizations (edit VM in virt-manager):"
echo "     - CPU: Use 'host-passthrough' mode"
echo "     - CPU: Enable 'Copy host CPU configuration'"
echo "     - Add: <feature policy='disable' name='hypervisor'/> to hide VM"
echo "     - Memory: Use hugepages for better performance"
echo
echo "Backup saved at: $BACKUP_FILE"
echo "To restore: virsh define $BACKUP_FILE"
echo