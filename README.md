# GPU Hot-Swap Scripts for Linux Gaming + VFIO Passthrough

Two scripts to dynamically detach your NVIDIA GPU from the host and pass it through to a VM (e.g. for gaming in a Windows VM via Looking Glass), then cleanly restore it back to the host without rebooting.

This is useful for users who:
- Game on Linux but need a Windows VM occasionally (anti-cheat, VR, etc.)
- Want a single-GPU passthrough setup without dual-booting
- Use Looking Glass for low-latency VM display

## Why these scripts?

Most existing scripts work for "easy" cases — desktop with two GPUs, older NVIDIA cards. They tend to break on:

- **Hybrid laptops** (Intel/AMD iGPU + NVIDIA dGPU)
- **RTX 40/50 series cards** with GSP firmware (state corruption after VFIO use)
- **Wayland / modern compositors** (graphics stack not properly rebuilt after GPU return)
- **Vulkan applications** (DXVK/Proton games failing with cryptic errors even when `nvidia-smi` works)

These scripts handle all of the above. Specifically:

- Aggressive process cleanup (uses `lsof` to catch mmap'd references that `fuser` misses)
- Correct module load/unload order
- **PCI remove + rescan** for true hardware-level reset (critical for Blackwell/Ada GSP recovery)
- `NVreg_PreserveVideoMemoryAllocations=1` for state preservation
- Comprehensive self-check at the end (driver binding, device nodes, Vulkan)
- Auto-detection of GPU, audio, CPU vendor, and display manager
- Optional Looking Glass (kvmfr) integration

## Requirements

- IOMMU enabled in BIOS (VT-d for Intel, AMD-Vi for AMD)
- Kernel boot params: `intel_iommu=on iommu=pt` (or `amd_iommu=on iommu=pt`)
- NVIDIA proprietary driver installed (open or closed)
- `vfio-pci` module available (built into most distro kernels)
- Optional: Looking Glass kvmfr module (https://looking-glass.io/)

## Installation

```bash
chmod +x dnv.sh rnv.sh
```

First run will create a config file at `~/.config/gpu-passthrough/config.sh` with auto-detected values. Review it, edit if needed, then re-run.

## Usage

```bash
# Detach NVIDIA from host, prepare for VM
sudo ./dnv.sh

# After your VM session ends, restore to host
sudo ./rnv.sh
```

## Configuration

Edit `~/.config/gpu-passthrough/config.sh`:

```bash
GPU_PCI="0000:01:00.0"         # Your NVIDIA GPU PCI address
AUDIO_PCI="0000:01:00.1"       # GPU HDMI audio (optional)
EXTRA_PCI=""                    # Other devices to pass through (USB, NVMe...)
KVM_MODULE="kvm_intel"         # or "kvm_amd"
KVM_NESTED="yes"
USE_KVMFR="no"                 # set "yes" if using Looking Glass
KVMFR_SIZE_MB="128"
DISPLAY_MANAGER="sddm"         # used as fallback hint if Vulkan still fails
```

Find your GPU PCI address with:
```bash
lspci -D | grep -i nvidia
```

## Hybrid Laptop Tip

On laptops with Intel/AMD iGPU + NVIDIA dGPU, Vulkan apps may default to the iGPU. For Steam games, add to Launch Options:

```
__NV_PRIME_RENDER_OFFLOAD=1 __VK_LAYER_NV_optimus=NVIDIA_only __GLX_VENDOR_LIBRARY_NAME=nvidia %command%
```

## Troubleshooting

**`rnv.sh` finishes but Vulkan apps (Proton games) fail with `InitializeEngineGraphics failed` or `Failed to create D3D11 device`:**

This means the graphics stack didn't fully rebuild. Most reliable fix:

```bash
sudo systemctl restart sddm   # or gdm, lightdm — whichever you use
```

This logs you out but completely rebuilds the graphics stack. The `rnv.sh` script will print the right command for your DM at the end if checks fail.

**`dnv.sh` says "module still loaded" — VM won't start:**

Some process is still holding the GPU. Check with:
```bash
sudo lsof /dev/nvidia*
```
Common culprits: nvidia-persistenced, nvidia-powerd, gamemode, browser hardware acceleration. Stop them and retry.

**`rnv.sh`: "could not insert 'nvidia': No such device":**

This means modules tried to load while devices were absent from the bus. The script handles this internally by loading modules *before* PCI remove. If you still see this, your config file may have a wrong PCI address.

**RTX 40/50 series specific:** If `nvidia-smi` works but games fail, the GSP firmware likely didn't fully reset. Re-run `rnv.sh` (the PCI remove+rescan should fix it). If it persistently fails, your only options are:

1. Restart display manager (preferred)
2. Reboot

This is a known limitation of GSP-based cards in dynamic passthrough scenarios. NVIDIA's drivers were not designed for repeated host-VM-host transitions.

## Credits

Originally developed for Kubuntu + RTX 5070 Ti Laptop GPU (Blackwell), then generalized.
Thanks to the Arch Wiki VFIO guide and r/VFIO community.

## License

MIT — share freely, modify as needed.
