#!/bin/bash
# Toggle GPU passthrough on/off without removing configuration
# This script comments/uncomments VFIO config to enable/disable passthrough

set -e

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_BLUE='\033[0;34m'
COLOR_NC='\033[0m'

VFIO_CONF="/etc/modprobe.d/vfio.conf"
VFIO_MODULES="/etc/modules-load.d/vfio.conf"
BIND_LIST="/etc/vfio-bind.list"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${COLOR_RED}Error: This script must be run as root${COLOR_NC}"
    echo "Usage: sudo $0 {enable|disable|status|single}"
    exit 1
fi

# Function to check current status
check_status() {
    if [ ! -f "$VFIO_CONF" ]; then
        echo "not_configured"
        return
    fi

    # Check if softdep lines are commented
    if grep -q "^#softdep nvidia pre: vfio-pci" "$VFIO_CONF" 2>/dev/null; then
        echo "disabled"
    elif grep -q "^softdep nvidia pre: vfio-pci" "$VFIO_CONF" 2>/dev/null; then
        echo "enabled"
    else
        echo "unknown"
    fi
}

# Per-PCI single GPU toggle helpers

normalize_bdf() {
    local bdf="$1"
    if [[ "$bdf" =~ ^0000: ]]; then
        echo "$bdf"
    else
        echo "0000:$bdf"
    fi
}

single_set() {
    if [ -z "$1" ]; then
        echo -e "${COLOR_RED}Error: GPU BDF required${COLOR_NC}"
        echo "Usage: sudo $0 single set <GPU_BDF> [AUDIO_BDF]"
        exit 1
    fi

    local gpu_bdf="$1"
    local audio_bdf="$2"

    # Basic BDF validation
    if ! echo "$gpu_bdf" | grep -Eq '^[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$|^0000:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$'; then
        echo -e "${COLOR_RED}Invalid GPU BDF: $gpu_bdf${COLOR_NC}"
        exit 1
    fi
    if [ -n "$audio_bdf" ] && ! echo "$audio_bdf" | grep -Eq '^[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$|^0000:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$'; then
        echo -e "${COLOR_RED}Invalid AUDIO BDF: $audio_bdf${COLOR_NC}"
        exit 1
    fi

    mkdir -p /etc
    local tmp="${BIND_LIST}.tmp.$$"
    echo "# vfio-bind list" > "$tmp"
    echo "# One BDF per line; optional comments allowed" >> "$tmp"
    echo "$(normalize_bdf "$gpu_bdf")" >> "$tmp"
    [ -n "$audio_bdf" ] && echo "$(normalize_bdf "$audio_bdf")" >> "$tmp"
    mv "$tmp" "$BIND_LIST"
    echo -e "${COLOR_GREEN}Saved per-PCI binding list to: $BIND_LIST${COLOR_NC}"
    cat "$BIND_LIST"
    echo
    echo "Run: sudo $0 single enable && sudo reboot  to activate binding"
}

single_enable() {
    if [ ! -s "$BIND_LIST" ]; then
        echo -e "${COLOR_RED}No BDFs configured in $BIND_LIST${COLOR_NC}"
        echo "Use: sudo $0 single set <GPU_BDF> [AUDIO_BDF]"
        exit 1
    fi

    echo "Enabling per-PCI binding via initramfs hook..."
    update-initramfs -u
    echo -e "${COLOR_GREEN}✓ Initramfs updated${COLOR_NC}"
    echo
    echo -e "${COLOR_YELLOW}IMPORTANT: Reboot required for changes to take effect${COLOR_NC}"
    read -p "Do you want to reboot now? (y/n): " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Rebooting in 5 seconds... (Ctrl+C to cancel)"
        sleep 5
        reboot
    else
        echo "Please reboot manually when ready: sudo reboot"
    fi
}

single_disable() {
    if [ -f "$BIND_LIST" ]; then
        cp "$BIND_LIST" "${BIND_LIST}.backup.$(date +%Y%m%d-%H%M%S)" || true
        : > "$BIND_LIST"
    fi
    echo "Disabling per-PCI binding (empty list)..."
    update-initramfs -u
    echo -e "${COLOR_GREEN}✓ Initramfs updated${COLOR_NC}"
    echo
    echo -e "${COLOR_YELLOW}IMPORTANT: Reboot required for changes to take effect${COLOR_NC}"
    read -p "Do you want to reboot now? (y/n): " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Rebooting in 5 seconds... (Ctrl+C to cancel)"
        sleep 5
        reboot
    else
        echo "Please reboot manually when ready: sudo reboot"
    fi
}

single_status() {
    echo "=== Single-GPU (per-PCI) Passthrough Status ==="
    if [ -s "$BIND_LIST" ]; then
        echo "Binding list: $BIND_LIST"
        echo "---"
        cat "$BIND_LIST"
        echo "---"
        echo
        while IFS= read -r line; do
            case "$line" in ''|'#'*) continue ;; esac
            bdf="$line"
            short=$(echo "$bdf" | sed 's/^0000://')
            echo "Device $bdf:"
            lspci -nn -s "$short" || true
            drv=$(lspci -k -s "$short" | awk -F: '/Kernel driver in use/ {print $2}' | xargs)
            echo "  Driver: ${drv:-none}"
            echo
        done < "$BIND_LIST"
    else
        echo "No BDFs configured (file missing or empty): $BIND_LIST"
    fi
}

auto_toggle() {
    echo "=== Automatic GPU Passthrough Toggle ==="
    echo

    if [ -s "$BIND_LIST" ]; then
        echo "Detected per-PCI binding list: $BIND_LIST"

        local first_bdf
        first_bdf=""
        while IFS= read -r line; do
            case "$line" in ''|'#'*) continue ;; esac
            first_bdf="$line"
            break
        done < "$BIND_LIST"

        if [ -n "$first_bdf" ]; then
            local short_bdf
            short_bdf=$(echo "$first_bdf" | sed 's/^0000://')
            local drv
            drv=$(lspci -k -s "$short_bdf" | awk -F: '/Kernel driver in use/ {print $2}' | xargs)

            echo "Primary BDF: $first_bdf"
            echo "Current driver: ${drv:-none}"
            echo

            if [ "$drv" = "vfio-pci" ]; then
                echo "GPU is currently bound to VFIO (VM side)."
                echo "Toggling to host (disabling per-PCI binding)..."
                echo
                single_disable
                return
            else
                echo "GPU is currently not bound to VFIO (driver: ${drv:-none})."
                echo "Toggling to VM (enabling per-PCI binding)..."
                echo
                single_enable
                return
            fi
        else
            echo "No usable BDF found in $BIND_LIST, falling back to global status."
            echo
        fi
    fi

    local status
    status=$(check_status)

    echo "Using global VFIO configuration status: $status"
    echo

    case "$status" in
        enabled)
            echo "Global passthrough is ENABLED; toggling to DISABLED (host)."
            echo
            disable_passthrough
            ;;
        disabled)
            echo "Global passthrough is DISABLED; toggling to ENABLED (VM)."
            echo
            enable_passthrough
            ;;
        not_configured)
            echo -e "${COLOR_RED}GPU passthrough not configured!${COLOR_NC}"
            echo
            echo "Run initial setup first:"
            echo "  sudo ./system-config.sh"
            echo
            return 1
            ;;
        *)
            echo -e "${COLOR_YELLOW}Unknown VFIO configuration state. No automatic toggle performed.${COLOR_NC}"
            echo
            return 1
            ;;
    esac
}

# Function to show status
show_status() {
    local status=$(check_status)

    echo "=== GPU Passthrough Status ==="
    echo

    if [ "$status" = "not_configured" ]; then
        echo -e "${COLOR_YELLOW}Status: NOT CONFIGURED${COLOR_NC}"
        echo
        echo "GPU passthrough has not been set up yet."
        echo "Run: sudo ./system-config.sh"
        echo
        return
    fi

    if [ "$status" = "enabled" ]; then
        echo -e "${COLOR_GREEN}Status: ENABLED${COLOR_NC}"
        echo
        echo "GPU passthrough is currently ACTIVE."
        echo "NVIDIA GPU will be bound to VFIO-PCI on next boot."
        echo
        echo "To disable and use GPU on host:"
        echo "  sudo $0 disable"
        echo "  sudo reboot"
        echo
    elif [ "$status" = "disabled" ]; then
        echo -e "${COLOR_BLUE}Status: DISABLED${COLOR_NC}"
        echo
        echo "GPU passthrough is currently INACTIVE."
        echo "NVIDIA GPU will be available to host on next boot."
        echo
        echo "To enable for VM passthrough:"
        echo "  sudo $0 enable"
        echo "  sudo reboot"
        echo
    else
        echo -e "${COLOR_YELLOW}Status: UNKNOWN${COLOR_NC}"
        echo "Configuration file exists but format is unexpected."
        echo "You may need to run: sudo ./system-config.sh"
        echo
    fi

    # Show config file content
    if [ -f "$VFIO_CONF" ]; then
        echo "Configuration file: $VFIO_CONF"
        echo "---"
        cat "$VFIO_CONF"
        echo "---"
    fi
    echo
}

# Function to enable passthrough
enable_passthrough() {
    local status=$(check_status)

    if [ "$status" = "not_configured" ]; then
        echo -e "${COLOR_RED}Error: GPU passthrough not configured!${COLOR_NC}"
        echo
        echo "Please run the initial setup first:"
        echo "  sudo ./system-config.sh"
        echo
        exit 1
    fi

    if [ "$status" = "enabled" ]; then
        echo -e "${COLOR_YELLOW}GPU passthrough is already enabled!${COLOR_NC}"
        echo "No changes needed."
        exit 0
    fi

    echo "=== Enabling GPU Passthrough ==="
    echo

    # Create backup
    BACKUP_FILE="${VFIO_CONF}.backup.$(date +%Y%m%d-%H%M%S)"
    cp "$VFIO_CONF" "$BACKUP_FILE"
    echo -e "${COLOR_GREEN}Created backup: $BACKUP_FILE${COLOR_NC}"

    # Uncomment only softdep lines
    sed -i 's/^#\(softdep .*$\)/\1/' "$VFIO_CONF"
    # Ensure global ID binding stays disabled
    sed -i 's/^options vfio-pci ids=/# options vfio-pci ids=/' "$VFIO_CONF"

    echo -e "${COLOR_GREEN}✓ Uncommented VFIO configuration${COLOR_NC}"
    echo

    # Update initramfs
    echo "Updating initramfs..."
    update-initramfs -u
    echo -e "${COLOR_GREEN}✓ Initramfs updated${COLOR_NC}"
    echo

    echo -e "${COLOR_GREEN}=== GPU Passthrough ENABLED ===${COLOR_NC}"
    echo
    echo "Configuration:"
    cat "$VFIO_CONF"
    echo
    echo -e "${COLOR_YELLOW}IMPORTANT: You must reboot for changes to take effect!${COLOR_NC}"
    echo
    echo "After reboot:"
    echo "  - NVIDIA GPU will be bound to vfio-pci"
    echo "  - GPU will be unavailable to host"
    echo "  - GPU will be available for VM passthrough"
    echo
    read -p "Do you want to reboot now? (y/n): " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Rebooting in 5 seconds... (Ctrl+C to cancel)"
        sleep 5
        reboot
    else
        echo "Please reboot manually when ready: sudo reboot"
    fi
}

# Function to disable passthrough
disable_passthrough() {
    local status=$(check_status)

    if [ "$status" = "not_configured" ]; then
        echo -e "${COLOR_YELLOW}GPU passthrough not configured, nothing to disable.${COLOR_NC}"
        exit 0
    fi

    if [ "$status" = "disabled" ]; then
        echo -e "${COLOR_YELLOW}GPU passthrough is already disabled!${COLOR_NC}"
        echo "No changes needed."
        exit 0
    fi

    echo "=== Disabling GPU Passthrough ==="
    echo

    # Create backup
    BACKUP_FILE="${VFIO_CONF}.backup.$(date +%Y%m%d-%H%M%S)"
    cp "$VFIO_CONF" "$BACKUP_FILE"
    echo -e "${COLOR_GREEN}Created backup: $BACKUP_FILE${COLOR_NC}"

    # Comment out softdep lines only (leave comments and other notes intact)
    sed -i 's/^\(softdep .*$\)/#\1/' "$VFIO_CONF"
    # Ensure global ID binding stays disabled
    sed -i 's/^options vfio-pci ids=/# options vfio-pci ids=/' "$VFIO_CONF"

    echo -e "${COLOR_GREEN}✓ Commented out VFIO configuration${COLOR_NC}"
    echo

    # Update initramfs
    echo "Updating initramfs..."
    update-initramfs -u
    echo -e "${COLOR_GREEN}✓ Initramfs updated${COLOR_NC}"
    echo

    echo -e "${COLOR_BLUE}=== GPU Passthrough DISABLED ===${COLOR_NC}"
    echo
    echo "Configuration (commented out):"
    cat "$VFIO_CONF"
    echo
    echo -e "${COLOR_YELLOW}IMPORTANT: You must reboot for changes to take effect!${COLOR_NC}"
    echo
    echo "After reboot:"
    echo "  - NVIDIA GPU will be available to host"
    echo "  - NVIDIA drivers will load normally"
    echo "  - GPU will work for desktop/gaming/compute"
    echo
    read -p "Do you want to reboot now? (y/n): " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Rebooting in 5 seconds... (Ctrl+C to cancel)"
        sleep 5
        reboot
    else
        echo "Please reboot manually when ready: sudo reboot"
    fi
}

# Main script logic
case "${1:-auto}" in
    auto)
        auto_toggle
        ;;
    enable)
        enable_passthrough
        ;;
    disable)
        disable_passthrough
        ;;
    status)
        show_status
        ;;
    single)
        subcmd="${2:-}"
        shift 2 || true
        case "$subcmd" in
            set)
                single_set "$@"
                ;;
            enable)
                single_enable
                ;;
            disable)
                single_disable
                ;;
            status)
                single_status
                ;;
            *)
                echo "Usage: sudo $0 single {set <GPU_BDF> [AUDIO_BDF]|enable|disable|status}"
                exit 1
                ;;
        esac
        ;;
    *)
        echo "Usage: sudo $0 {auto|enable|disable|status|single}" 
        echo
        echo "Commands:"
        echo "  auto     - Automatically toggle between host and VM based on current driver state"
        echo "  enable   - Enable GPU passthrough (uncomment VFIO config)"
        echo "  disable  - Disable GPU passthrough (comment out VFIO config)"
        echo "  status   - Show current passthrough status"
        echo "  single   - Per-PCI toggle for a single GPU"
        echo "            set <GPU_BDF> [AUDIO_BDF]  - Save target BDFs (e.g., 03:00.0 03:00.1)"
        echo "            enable/disable/status      - Manage per-PCI binding (reboot required)"
        echo
        echo "Example workflow:"
        echo "  1. Initial setup:             sudo ./system-config.sh"
        echo "  2. Configure single-GPU BDFs: sudo $0 single set 03:00.0 03:00.1"
        echo "  3. Simple toggle:             sudo $0 auto"
        echo "  4. Explicit VM:               sudo $0 single enable && sudo reboot"
        echo "  5. Explicit host:             sudo $0 single disable && sudo reboot"
        echo
        exit 1
        ;;
esac
