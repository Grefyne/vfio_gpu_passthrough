# GPU Passthrough Quick Reference

## First Time Setup

```bash
# 1. Check prerequisites
./diagnostic.sh

# 2. Install passthrough configuration
sudo ./system-config.sh

# 3. Reboot
sudo reboot

# 4. Verify it worked
./diagnostic.sh
lspci -k -s 01:00.0  # Should show: Kernel driver in use: vfio-pci
```

## Daily Usage - Toggle Between Modes

### Check Current Status
```bash
sudo ./toggle-passthrough.sh status
```

### Use GPU for Host (Gaming/Desktop)
```bash
sudo ./toggle-passthrough.sh disable
sudo reboot
# After reboot: NVIDIA drivers loaded, GPU works normally
```

### Use GPU for VMs (Passthrough)
```bash
sudo ./toggle-passthrough.sh enable
sudo reboot
# After reboot: GPU bound to VFIO, ready for VM passthrough
```

## Scripts Overview

| Script | Purpose | When to Use |
|--------|---------|-------------|
| `system-config.sh` | Initial setup (softdep method) | Run once to configure everything |
| `toggle-passthrough.sh` | Toggle on/off | Daily use - switch between modes |
| `rollback.sh` | Complete removal | Only if removing passthrough entirely |
| `diagnostic.sh` | System check | Troubleshooting, verify setup |

## What Each Mode Does

### Passthrough ENABLED (for VMs)
- ✅ GPU bound to `vfio-pci` driver
- ✅ GPU available for VM passthrough
- ❌ GPU unavailable to host
- ❌ No NVIDIA drivers on host

### Passthrough DISABLED (for Host)
- ✅ NVIDIA drivers loaded normally
- ✅ GPU works for gaming/desktop/CUDA
- ❌ GPU not available for VM passthrough

## How Toggle Works

**Enable:**
- Uncomments lines in `/etc/modprobe.d/vfio.conf`
- Updates initramfs
- Requires reboot

**Disable:**
- Comments out lines in `/etc/modprobe.d/vfio.conf`
- Updates initramfs
- Requires reboot

Configuration file stays in place - just toggled on/off.

## Troubleshooting

### GPU not binding to VFIO after enable
```bash
# Check config is uncommented
cat /etc/modprobe.d/vfio.conf

# Should see:
# softdep nvidia pre: vfio-pci
# NOT:
# #softdep nvidia pre: vfio-pci

# Verify IOMMU
dmesg | grep -i iommu

# Check VFIO modules
lsmod | grep vfio
```

### NVIDIA drivers not loading after disable
```bash
# Check config is commented
cat /etc/modprobe.d/vfio.conf

# Should see:
# #softdep nvidia pre: vfio-pci

# Manually load NVIDIA module
sudo modprobe nvidia

# Check for errors
dmesg | grep nvidia
```

### Start Over
```bash
# Remove everything and start fresh
sudo ./rollback.sh
sudo reboot

# Then re-run setup
sudo ./system-config.sh
```

## File Locations

```
/etc/modprobe.d/vfio.conf           # Main config (toggled)
/etc/modules-load.d/vfio.conf       # VFIO module loading
/etc/default/grub                   # IOMMU parameters
```

## Your GPU Details

- **GPU**: 01:00.0 - GeForce RTX 5060 Ti (10de:2d04)
- **Audio**: 01:00.1 - NVIDIA HDMI Audio (10de:22eb)
- **iGPU**: 74:00.0 - AMD Radeon (for host display)
- **IOMMU**: AMD (amd_iommu=on iommu=pt)
