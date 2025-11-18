# GPU Passthrough Setup - Improvements Made

## Summary

Upgraded the GPU passthrough configuration from a **blacklist-based approach** to the **softdep method**, following Arch Wiki best practices and industry standards.

## What Changed

### Before (Old Approach)
- **Two-part script**: `system-config_pt1.sh` + `system-config_pt2.sh`
- **3-4 configuration files**:
  - `/etc/modprobe.d/nvidia-passthrough-blacklist.conf` (blacklist)
  - `/etc/modprobe.d/vfio-passthrough.conf` (device IDs)
  - `/etc/modules-load.d/vfio-passthrough.conf` (module loading)
  - `/etc/systemd/system/nvidia-passthrough.service` (runtime setup)
- **Nuclear approach**: Completely blacklisted NVIDIA drivers
- **No fallback**: If VFIO failed, no GPU at all

### After (New Approach)
- **Single script**: `system-config.sh`
- **2 configuration files**:
  - `/etc/modprobe.d/vfio.conf` (softdep + device IDs)
  - `/etc/modules-load.d/vfio.conf` (module loading)
- **Surgical approach**: Controls load order, doesn't block drivers
- **Safe fallback**: If VFIO fails, NVIDIA drivers can still load
- **Auto-cleanup**: Removes old blacklist configs automatically

## Key Configuration File

The new `/etc/modprobe.d/vfio.conf` contains:

```bash
# Ensure vfio-pci loads before any NVIDIA drivers
softdep nvidia pre: vfio-pci
softdep nvidia_modeset pre: vfio-pci
softdep nvidia_uvm pre: vfio-pci
softdep nvidia_drm pre: vfio-pci

# Ensure vfio-pci loads before HD audio driver
softdep snd_hda_intel pre: vfio-pci

# Bind specific device IDs to VFIO-PCI
options vfio-pci ids=10de:2d04,10de:22eb
```

## How It Works

1. **Boot starts** → Kernel begins loading modules
2. **VFIO modules load early** (via `/etc/modules-load.d/vfio.conf`)
3. **softdep triggers** → If NVIDIA wants to load, kernel loads `vfio-pci` FIRST
4. **VFIO-PCI claims GPU** → Binds to vendor:device IDs `10de:2d04,10de:22eb`
5. **NVIDIA sees nothing** → No devices available, so NVIDIA modules don't load
6. **Result** → GPU bound to VFIO, ready for passthrough

## Advantages

### 1. **Cleaner**
- Single configuration file vs 3-4 separate files
- No blacklist pollution
- Easier to understand and maintain

### 2. **Safer**
- NVIDIA drivers can still load if VFIO fails
- Better error recovery
- Less likely to break system

### 3. **Industry Standard**
- Arch Wiki recommended method
- Used by most GPU passthrough guides
- Better community support

### 4. **Better User Experience**
- One script instead of two
- Auto-cleanup of old configs
- Clear explanations in output

### 5. **Toggle Feature (NEW)**
- Switch between passthrough and host use without removing config
- Just comments/uncomments configuration lines
- Perfect for dual-use scenarios (VMs + gaming/desktop)
- Inspired by: https://github.com/k-amin07/VFIO-Switcher

**Example toggle workflow:**
```bash
# Setup once
sudo ./system-config.sh

# Want to use GPU for gaming on host?
sudo ./toggle-passthrough.sh disable
sudo reboot

# Back to VMs?
sudo ./toggle-passthrough.sh enable
sudo reboot

# Check current mode
sudo ./toggle-passthrough.sh status
```

## Migration Path

### If You Already Ran Part 1 (Old Script)

You have two options:

**Option A: Clean slate (recommended)**
```bash
sudo ./rollback.sh  # Removes all old configs
sudo reboot
sudo ./system-config.sh  # Run new improved script
sudo reboot
```

**Option B: Direct upgrade**
```bash
sudo ./system-config.sh  # Automatically cleans up old configs
sudo reboot
```

The new script will:
- Remove old blacklist files
- Remove old VFIO configs
- Remove old systemd service
- Create new softdep-based config
- Preserve your GRUB settings (IOMMU already enabled)

## Files Updated

1. **`system-config.sh`** - Complete rewrite using softdep
2. **`toggle-passthrough.sh`** - NEW: Toggle passthrough on/off without removing config
3. **`rollback.sh`** - Updated to handle both old and new configs
4. **`CLAUDE.md`** - Documentation updated with new architecture
5. **`system-config_pt1.sh`** - Fixed bugs (nvidia-persistenced, integer comparison)
6. **`system-config_pt2.sh`** - Fixed missing device ID files bug

## Testing

The new script has NOT been tested yet. Recommended testing steps:

```bash
# 1. Run diagnostics first
./diagnostic.sh

# 2. Run new script (will auto-cleanup old configs)
sudo ./system-config.sh

# 3. Reboot
sudo reboot

# 4. Verify VFIO binding
lspci -k -s 01:00.0  # Should show "Kernel driver in use: vfio-pci"
./diagnostic.sh       # Should show all checks passing
```

## Rollback (If Needed)

```bash
sudo ./rollback.sh
sudo reboot
```

The rollback script handles both old and new configurations.

## References

- Original inspiration: https://gist.github.com/k-amin07/47cb06e4598e0c81f2b42904c6909329
- Arch Wiki: GPU Passthrough
- softdep documentation: `man modprobe.d`
