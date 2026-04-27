#!/bin/bash
# rnv.sh - Restore NVIDIA GPU to host after VFIO passthrough
# Universal version - works on any Linux system with NVIDIA GPU
#
# Usage: sudo ./rnv.sh
# Config: ~/.config/gpu-passthrough/config.sh (created by dnv.sh)
#
# Key features:
# - PCI remove + rescan for hardware-level GPU reset (critical for RTX 50 / Blackwell GSP)
# - Correct module load order (nvidia -> uvm -> modeset -> drm)
# - Self-check at the end (verifies driver binding, device nodes, Vulkan)
# - Fallback hint to restart display manager if Vulkan apps still fail

set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root. Try: sudo $0"
    exit 1
fi

# ===== Load config =====
if [ -n "${SUDO_USER:-}" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    USER_HOME="$HOME"
fi
CONFIG_FILE="${USER_HOME}/.config/gpu-passthrough/config.sh"

if [ ! -f "$CONFIG_FILE" ]; then
    error "Config not found at $CONFIG_FILE"
    error "Run dnv.sh first to generate it"
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

if [ -z "${GPU_PCI:-}" ]; then
    error "GPU_PCI not set in $CONFIG_FILE"
    exit 1
fi

PCI_DEVICES=("$GPU_PCI")
[ -n "${AUDIO_PCI:-}" ] && PCI_DEVICES+=("$AUDIO_PCI")
if [ -n "${EXTRA_PCI:-}" ]; then
    for pci in $EXTRA_PCI; do
        PCI_DEVICES+=("$pci")
    done
fi

info "PCI devices to restore: ${PCI_DEVICES[*]}"

# ===== 1. Remove module load block =====
info "Removing nvidia module load block"
rm -f /run/modprobe.d/no-nvidia.conf

# ===== 2. Unload kvmfr =====
if [ "${USE_KVMFR:-no}" = "yes" ]; then
    info "Unloading kvmfr"
    rmmod kvmfr 2>/dev/null || true
fi

# ===== 3. Unbind from vfio-pci =====
info "Unbinding from vfio-pci"
for pci in "${PCI_DEVICES[@]}"; do
    if [ -L "/sys/bus/pci/devices/${pci}/driver" ] && \
       readlink "/sys/bus/pci/devices/${pci}/driver" 2>/dev/null | grep -q vfio-pci; then
        echo "$pci" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null \
            && info "  $pci unbound from vfio-pci"
    fi
done

# ===== 4. Clear driver_override =====
info "Clearing driver_override"
for pci in "${PCI_DEVICES[@]}"; do
    echo "" > "/sys/bus/pci/devices/${pci}/driver_override" 2>/dev/null || true
done

# ===== 5. Pre-load nvidia modules (BEFORE PCI remove) =====
# Critical: must happen while devices are still on the bus, otherwise modprobe
# fails with "No such device". After remove+rescan, modules are already in place
# and the kernel auto-binds them on rescan.
info "Pre-loading nvidia kernel modules"

modprobe nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_TemporaryFilePath=/var/tmp \
    || { error "nvidia module load failed"; exit 1; }
info "  nvidia loaded"

modprobe nvidia_uvm     || warn "nvidia_uvm load failed"
info "  nvidia_uvm loaded"

modprobe nvidia_modeset || warn "nvidia_modeset load failed"
info "  nvidia_modeset loaded"

modprobe nvidia_drm modeset=1 fbdev=1 || warn "nvidia_drm load failed"
info "  nvidia_drm loaded (modeset=1)"

# ===== 6. PCI remove + rescan: hardware-level reset =====
# This is THE critical step that distinguishes this script from naive approaches.
# A simple driver rebind leaves GPU state dirty; remove+rescan forces full
# re-initialization including GSP firmware (essential for RTX 40/50 series).
info "Performing PCI remove + rescan (hardware reset)"

# Remove in reverse order: audio first, then GPU, then extras
remove_order=()
[ -n "${AUDIO_PCI:-}" ] && remove_order+=("$AUDIO_PCI")
remove_order+=("$GPU_PCI")
if [ -n "${EXTRA_PCI:-}" ]; then
    for pci in $EXTRA_PCI; do
        remove_order+=("$pci")
    done
fi

for pci in "${remove_order[@]}"; do
    echo 1 > "/sys/bus/pci/devices/${pci}/remove" 2>/dev/null || true
done

sleep 1

info "PCI rescan, rediscovering devices"
echo 1 > /sys/bus/pci/rescan

sleep 2

# ===== 7. Fallback: manual probe if not auto-bound =====
gpu_driver=$(lspci -k -s "$GPU_PCI" 2>/dev/null | grep "Kernel driver in use:" | awk '{print $NF}')
if [ -z "$gpu_driver" ] || [ "$gpu_driver" != "nvidia" ]; then
    warn "GPU not auto-bound to nvidia, manual probe"
    for pci in "${PCI_DEVICES[@]}"; do
        echo "$pci" > /sys/bus/pci/drivers_probe 2>/dev/null || true
    done
    sleep 1
fi

# ===== 8. Create user-space device nodes =====
info "Creating/refreshing user-space device nodes"
if command -v nvidia-modprobe >/dev/null 2>&1; then
    nvidia-modprobe -c 0 -u 2>/dev/null || warn "  nvidia-modprobe -u failed"
    nvidia-modprobe -c 0 -m 2>/dev/null || warn "  nvidia-modprobe -m failed"
else
    warn "  nvidia-modprobe not installed (install nvidia-utils package)"
fi

udevadm trigger --subsystem-match=drm 2>/dev/null
udevadm settle 2>/dev/null

# ===== 9. Enable persistence mode =====
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi -pm 1 >/dev/null 2>&1 || true
fi

systemctl start nvidia-persistenced 2>/dev/null || true

# ===== 10. Self-check =====
echo ""
info "=== Verification ==="

ok=1

for pci in "${PCI_DEVICES[@]}"; do
    driver=$(lspci -k -s "$pci" 2>/dev/null | grep "Kernel driver in use:" | awk '{print $NF}')
    if [ "$pci" = "$GPU_PCI" ]; then
        if [ "$driver" = "nvidia" ]; then
            info "✓ GPU ($pci) bound to nvidia"
        else
            error "✗ GPU driver = ${driver:-none} (expected nvidia)"
            ok=0
        fi
    elif [ "$pci" = "${AUDIO_PCI:-}" ]; then
        if [ "$driver" = "snd_hda_intel" ]; then
            info "✓ Audio ($pci) bound to snd_hda_intel"
        else
            warn "✗ Audio driver = ${driver:-none}"
        fi
    else
        info "  $pci driver = ${driver:-none}"
    fi
done

# Check critical device nodes
for dev in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-modeset /dev/nvidia-uvm /dev/nvidia-uvm-tools; do
    if [ -e "$dev" ]; then
        info "✓ $dev exists"
    else
        error "✗ $dev missing"
        ok=0
    fi
done

if nvidia-smi >/dev/null 2>&1; then
    info "✓ nvidia-smi works"
else
    error "✗ nvidia-smi failed"
    ok=0
fi

if command -v vulkaninfo >/dev/null 2>&1; then
    if __NV_PRIME_RENDER_OFFLOAD=1 vulkaninfo --summary 2>/dev/null | grep -q "NVIDIA"; then
        info "✓ Vulkan recognizes NVIDIA GPU"
    else
        warn "✗ Vulkan does not see NVIDIA GPU"
        ok=0
    fi
fi

nvidia_refs=$(lsmod | awk '/^nvidia / {print $3}')
if [ -n "$nvidia_refs" ] && [ "$nvidia_refs" -gt 10 ]; then
    warn "⚠ nvidia module ref count = $nvidia_refs (high, may indicate stale state)"
fi

echo ""
if [ "$ok" = "1" ]; then
    info "==================================="
    info "  GPU restored, ready for host use"
    info "==================================="
    echo ""
    info "Tips for gaming:"
    info "  - On hybrid laptops, set Vulkan apps to use NVIDIA via:"
    info "      __NV_PRIME_RENDER_OFFLOAD=1 __VK_LAYER_NV_optimus=NVIDIA_only \\"
    info "      __GLX_VENDOR_LIBRARY_NAME=nvidia <command>"
    info "  - For Steam games, add the above to Launch Options before %command%"
else
    warn "==================================="
    warn "  Some checks failed"
    warn "==================================="
    if [ -n "${DISPLAY_MANAGER:-}" ]; then
        warn "  If Vulkan apps (e.g. games via Proton) still fail, try:"
        warn "    sudo systemctl restart $DISPLAY_MANAGER"
        warn "  This will log you out but rebuilds the entire graphics stack."
    else
        warn "  If Vulkan apps still fail, restart your display manager"
        warn "  (sddm/gdm/lightdm) to rebuild the graphics stack."
    fi
fi

echo ""
lspci -k -s "$GPU_PCI"
[ -n "${AUDIO_PCI:-}" ] && lspci -k -s "$AUDIO_PCI"
