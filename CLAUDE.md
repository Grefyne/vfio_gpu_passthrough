# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.


## directives to claude code:
Always use context7 when I need code generation, setup or configuration steps, or
library/API documentation. This means you should automatically use the Context7 MCP
tools to resolve library id and get library docs without me having to explicitly ask.

## Project Overview

This is a NVIDIA GPU passthrough setup for QEMU/KVM virtual machines on Linux. The repository contains scripts and configuration files to unbind NVIDIA GPUs from the host system and pass them through to guest VMs using VFIO-PCI.

## Architecture

The setup uses the **softdep method** (industry standard, Arch Wiki recommended):

1. **Boot-time Configuration**: IOMMU enabled in GRUB
2. **Module Load Order**: `softdep` ensures VFIO-PCI loads BEFORE NVIDIA drivers
3. **Device Binding**: VFIO-PCI claims specific GPU vendor:device IDs
4. **Fallback Safety**: If VFIO fails, NVIDIA drivers can still load (no blacklist)

### Key Components

**Installation Script (`system-config.sh`)**:
- Auto-detects GPU PCI addresses and vendor:device IDs
- Creates timestamped backups before any modifications
- Uses softdep instead of blacklisting (cleaner, safer)
- Single configuration file approach
- Idempotent - safe to run multiple times

**Configuration Files** (NEW - softdep approach):
- `etc/modprobe.d/vfio.conf`: Single file with softdep directives + device IDs
- `etc/modules-load.d/vfio.conf`: Early VFIO module loading

**Old Configuration Files** (deprecated, removed by new script):
- `etc/modprobe.d/nvidia-passthrough-blacklist.conf`: Old blacklist approach
- `etc/modprobe.d/vfio-passthrough.conf`: Old device binding
- `etc/modules-load.d/vfio-passthrough.conf`: Old module loader
- `etc/systemd/system/nvidia-passthrough.service`: No longer needed

**Diagnostic & Management**:
- `diagnostic.sh`: Comprehensive system check (IOMMU, modules, PCI devices, readiness)
- `toggle-passthrough.sh`: Toggle passthrough on/off without removing config (recommended)
- `rollback.sh`: Completely removes all passthrough config and restores backups

### PCI Device Management

The system auto-detects NVIDIA devices at installation time. For this system:
- `01:00.0` - GeForce RTX 5060 Ti (10de:2d04)
- `01:00.1` - NVIDIA HDMI Audio (10de:22eb)

Device addresses and IDs are automatically discovered by `system-config.sh` and written into all generated files, ensuring consistency.

## Common Commands

### Full Installation Workflow
```bash
# 1. Run diagnostics first
./diagnostic.sh

# 2. Install passthrough configuration (prompts for confirmation)
sudo ./system-config.sh

# 3. Reboot
sudo reboot

# 4. After reboot, GPU is bound to VFIO and ready for passthrough
```

### Toggle Passthrough On/Off (Recommended)
Use the toggle script to switch between host use and passthrough without removing configuration:

```bash
# Check current status
sudo ./toggle-passthrough.sh status

# Disable passthrough (use GPU on host for gaming/desktop)
sudo ./toggle-passthrough.sh disable
sudo reboot

# Re-enable passthrough (use GPU for VMs)
sudo ./toggle-passthrough.sh enable
sudo reboot
```

**Workflow:**
1. Run `system-config.sh` once to set everything up
2. Use `toggle-passthrough.sh` to switch between modes as needed
3. Reboot between mode changes

### Complete Removal (Rollback)
Only use this if you want to completely remove passthrough configuration:

```bash
sudo ./rollback.sh  # Removes all passthrough config, restores backups
sudo reboot
```

### Diagnostics
```bash
./diagnostic.sh  # Comprehensive check: IOMMU, modules, PCI devices, readiness
```

### Manual Checks
```bash
# Find GPU PCI IDs
lspci | grep -i nvidia
lspci -nn | grep -i nvidia  # Also show vendor:device IDs

# Check VFIO binding status
lsmod | grep vfio
dmesg | grep -i vfio
ls -l /sys/bus/pci/drivers/vfio-pci/

# Check if IOMMU is enabled
dmesg | grep -i iommu

# View systemd service status
systemctl status nvidia-passthrough.service
```

## Important Configuration Points

### Auto-Generated Configuration
The `system-config.sh` script auto-generates all configuration files with correct values:
- PCI addresses are auto-detected from `lspci`
- Vendor:device IDs are extracted automatically
- CPU vendor (Intel/AMD) is detected for correct IOMMU parameters
- All files are generated with consistent values

**Files in `etc/` and `usr/local/bin/` are templates** - the actual deployed files are created by `system-config.sh` in system locations (`/etc/`, `/usr/local/bin/`).

### softdep Method (NEW)
The improved `system-config.sh` uses `softdep` directives instead of blacklisting:
```bash
# /etc/modprobe.d/vfio.conf
softdep nvidia pre: vfio-pci
softdep nvidia_modeset pre: vfio-pci
softdep nvidia_uvm pre: vfio-pci
softdep nvidia_drm pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci
options vfio-pci ids=10de:2d04,10de:22eb
```

**Advantages**:
- Cleaner than blacklisting - controls load order, not blocking
- Safer - NVIDIA drivers can still load if VFIO fails
- Industry standard (Arch Wiki recommended)
- Single configuration file instead of 3-4 separate files

### GRUB Configuration
`system-config.sh` automatically adds IOMMU parameters to GRUB based on CPU vendor:
- Intel: `intel_iommu=on iommu=pt`
- AMD: `amd_iommu=on iommu=pt`

Requires `update-grub` and reboot (handled by the script).

### Backup Location
Backups are created in timestamped directories:
```
/root/gpu-passthrough-backups-YYYYMMDD-HHMMSS/
```
Keep track of this location for manual recovery if needed.

## Safety Features

### What's Safe
- ✅ **Auto-detection**: No hardcoded values that could be wrong
- ✅ **Backups**: All modified files backed up before changes
- ✅ **Idempotent**: Safe to run `system-config.sh` multiple times
- ✅ **Confirmation prompts**: User must confirm before changes
- ✅ **Rollback script**: Complete reversal of all changes
- ✅ **Error handling**: Scripts exit on errors instead of continuing
- ✅ **softdep safety**: NVIDIA drivers can still load if VFIO fails (no blacklist)
- ✅ **Auto-cleanup**: New script removes old blacklist-based configs automatically

### Risks to Be Aware Of
- ⚠️ GPU becomes unavailable to host after setup - need SSH or alternate display
- ⚠️ IOMMU must be supported by hardware (CPU + motherboard)
- ⚠️ Changes require reboot to take full effect
- ⚠️ If this is your only GPU, losing passthrough config could mean no video output

### Recovery Path
If you lose display after enabling passthrough:
1. Boot to recovery mode (hold Shift during boot)
2. Select "Root shell prompt"
3. Run the rollback script: `./rollback.sh` (from repository directory)
4. Or manually remove config files:
   ```bash
   rm -f /etc/modprobe.d/vfio.conf
   rm -f /etc/modules-load.d/vfio.conf
   update-initramfs -u
   reboot
   ```

## File Deployment

Configuration files in `etc/` and scripts in `usr/local/bin/` are meant to be deployed to their respective system locations:
- `etc/modprobe.d/*` → `/etc/modprobe.d/`
- `etc/systemd/system/*` → `/etc/systemd/system/`
- `usr/local/bin/*` → `/usr/local/bin/`

The repository mirrors the system directory structure for clarity.
