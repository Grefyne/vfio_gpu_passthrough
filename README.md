# NVIDIA GPU Passthrough for QEMU/KVM

A modern, clean GPU passthrough setup for NVIDIA GPUs using the **softdep method** (industry standard, Arch Wiki recommended). Enables passing NVIDIA GPUs to virtual machines while keeping the host system stable and recoverable.

## Features

- ✅ **Industry Standard**: Uses `softdep` instead of blacklisting (safer, cleaner)
- ✅ **Single Script Setup**: One command to configure everything
- ✅ **Toggle Mode**: Switch between passthrough and host use without reinstalling
- ✅ **Auto-Detection**: Automatically finds GPU PCI addresses and device IDs
- ✅ **Safe Fallback**: NVIDIA drivers can still load if VFIO fails
- ✅ **Comprehensive Diagnostics**: Verify setup before and after configuration
- ✅ **Complete Rollback**: One command to remove everything and restore backups

## Quick Start

```bash
# 1. Check prerequisites
./diagnostic.sh

# 2. Install passthrough configuration
sudo ./system-config.sh

# 3. Reboot
sudo reboot

# 4. Verify it worked
./diagnostic.sh
lspci -k | grep -A 2 VGA  # Should show "Kernel driver in use: vfio-pci"
```

## How It Works

The setup uses the **softdep method**:

1. **Boot-time Configuration**: IOMMU enabled in GRUB
2. **Module Load Order**: `softdep` ensures VFIO-PCI loads BEFORE NVIDIA drivers
3. **Device Binding**: VFIO-PCI claims specific GPU vendor:device IDs
4. **Fallback Safety**: If VFIO fails, NVIDIA drivers can still load

### Configuration File

Creates a single config file `/etc/modprobe.d/vfio.conf`:

```bash
# Ensure vfio-pci loads before any NVIDIA drivers
softdep nvidia pre: vfio-pci
softdep nvidia_modeset pre: vfio-pci
softdep nvidia_uvm pre: vfio-pci
softdep nvidia_drm pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci

# Bind specific device IDs to VFIO-PCI
options vfio-pci ids=10de:2d04,10de:22eb
```

## Toggle Between Modes

Use the toggle script to switch between passthrough and host use:

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

## Scripts

| Script | Purpose | When to Use |
|--------|---------|-------------|
| `system-config.sh` | Initial setup using softdep method | Run once to configure everything |
| `toggle-passthrough.sh` | Toggle passthrough on/off | Daily use - switch between modes |
| `rollback.sh` | Complete removal | Only if removing passthrough entirely |
| `diagnostic.sh` | System check | Troubleshooting, verify setup |

## Requirements

### Hardware
- NVIDIA GPU (discrete)
- CPU with IOMMU support (Intel VT-d or AMD-Vi)
- Motherboard with IOMMU support
- Integrated GPU or second GPU for host display (recommended)

### Software
- Linux distribution with systemd
- GRUB bootloader
- QEMU/KVM or libvirt for running VMs

### Tested On

**Development System:**
- **CPU**: AMD Ryzen 9 9950X (16-Core, with AMD-Vi IOMMU)
- **Integrated GPU**: AMD Radeon Graphics (Granite Ridge) - Used for host display
- **Passthrough GPU**: NVIDIA GeForce RTX 5060 Ti (10de:2d04)
- **OS**: Ubuntu 24.04 LTS
- **Kernel**: 6.17.0-6-generic

This configuration demonstrates:
- ✅ AMD CPU with integrated graphics (iGPU provides host display)
- ✅ NVIDIA discrete GPU passed through to VMs
- ✅ Seamless switching between passthrough and host use
- ✅ No display issues during mode changes

## Documentation

- **`README.md`** - This file (overview and quick start)
- **`QUICKSTART.md`** - Quick reference for daily use
- **`IMPROVEMENTS.md`** - Technical details about the softdep method
- **`CLAUDE.md`** - Detailed architecture and troubleshooting

## Example Configuration

For this system:
- `01:00.0` - GeForce RTX 5060 Ti (10de:2d04)
- `01:00.1` - NVIDIA HDMI Audio (10de:22eb)
- `74:00.0` - AMD Radeon iGPU (for host display)

Device addresses and IDs are automatically detected by `system-config.sh`.

## Advantages Over Traditional Methods

### Traditional Approach
- 3-4 separate configuration files
- Blacklist NVIDIA drivers (nuclear option)
- No fallback if VFIO fails
- Complex two-part setup process

### Our Approach
- Single configuration file
- Control load order with softdep (surgical)
- Safe fallback to NVIDIA drivers
- One script does everything
- Toggle feature for dual-use scenarios

## Safety Features

- ✅ **Auto-detection**: No hardcoded values that could be wrong
- ✅ **Backups**: All modified files backed up before changes
- ✅ **Idempotent**: Safe to run `system-config.sh` multiple times
- ✅ **Confirmation prompts**: User must confirm before changes
- ✅ **Rollback script**: Complete reversal of all changes
- ✅ **Error handling**: Scripts exit on errors instead of continuing

## Troubleshooting

### GPU not binding to VFIO after reboot
```bash
# Run diagnostic
./diagnostic.sh

# Check IOMMU is enabled
dmesg | grep -i iommu

# Verify configuration
cat /etc/modprobe.d/vfio.conf

# Check kernel command line
cat /proc/cmdline | grep iommu
```

### Display not working after setup
If you lose display after enabling passthrough:
1. Boot to recovery mode (hold Shift during boot)
2. Select "Root shell prompt"
3. Run: `./rollback.sh` (from repository directory)
4. Or manually:
   ```bash
   rm -f /etc/modprobe.d/vfio.conf
   rm -f /etc/modules-load.d/vfio.conf
   update-initramfs -u
   reboot
   ```

## Credits

Inspired by:
- [Arch Wiki GPU Passthrough Guide](https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF)
- [k-amin07's VFIO Guide](https://gist.github.com/k-amin07/47cb06e4598e0c81f2b42904c6909329)
- [k-amin07's VFIO Switcher](https://github.com/k-amin07/VFIO-Switcher)

## License

MIT License - See LICENSE file for details

## Contributing

Contributions welcome! This setup has been tested on AMD systems with NVIDIA GPUs. If you test on Intel systems or different GPU models, please share your experience.

## Disclaimer

Use at your own risk. While this setup includes safety features and backups, GPU passthrough involves modifying system configuration. Always have a backup plan for system access (SSH, serial console, or recovery mode).
