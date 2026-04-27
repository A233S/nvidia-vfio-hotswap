#!/bin/bash
# dnv.sh - Detach NVIDIA GPU from host for VFIO passthrough
# Universal version - works on any Linux system with NVIDIA GPU + IOMMU
#
# Usage: sudo ./dnv.sh
# Config: ~/.config/gpu-passthrough/config.sh (auto-created on first run)

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

# ===== Config file location =====
if [ -n "${SUDO_USER:-}" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    USER_HOME="$HOME"
fi
CONFIG_DIR="${USER_HOME}/.config/gpu-passthrough"
CONFIG_FILE="${CONFIG_DIR}/config.sh"

detect_nvidia_gpu() {
    lspci -D | grep -iE "VGA|3D" | grep -i nvidia | head -1 | awk '{print $1}'
}

detect_gpu_audio() {
    local gpu_pci="$1"
    local base="${gpu_pci%.*}"
    local audio_pci="${base}.1"
    if [ -e "/sys/bus/pci/devices/${audio_pci}" ]; then
        if lspci -s "$audio_pci" | grep -qi audio; then
            echo "$audio_pci"
        fi
    fi
}

detect_kvm_module() {
    if grep -q "GenuineIntel" /proc/cpuinfo; then
        echo "kvm_intel"
    elif grep -q "AuthenticAMD" /proc/cpuinfo; then
        echo "kvm_amd"
    else
        echo ""
    fi
}

detect_display_manager() {
    systemctl list-units --type=service --state=running 2>/dev/null \
        | grep -oE '(sddm|gdm3?|lightdm)\.service' | head -1 | cut -d. -f1
}

init_config() {
    info "First run detected, creating config at $CONFIG_FILE"
    mkdir -p "$CONFIG_DIR"

    local detected_gpu
    detected_gpu=$(detect_nvidia_gpu)
    if [ -z "$detected_gpu" ]; then
        error "No NVIDIA GPU detected via lspci"
        detected_gpu="0000:00:00.0"
    else
        info "Auto-detected NVIDIA GPU: $detected_gpu"
    fi

    local detected_audio
    detected_audio=$(detect_gpu_audio "$detected_gpu")
    [ -n "$detected_audio" ] && info "Auto-detected GPU audio: $detected_audio"

    local detected_kvm
    detected_kvm=$(detect_kvm_module)

    local detected_dm
    detected_dm=$(detect_display_manager)

    cat > "$CONFIG_FILE" << EOF
# GPU Passthrough Configuration
# Edit this file if auto-detection got something wrong

# NVIDIA GPU PCI address (find with: lspci -D | grep -i nvidia)
GPU_PCI="$detected_gpu"

# GPU HDMI audio PCI address (leave empty if your GPU has no audio function)
AUDIO_PCI="$detected_audio"

# Additional PCI devices to pass through (USB controllers, NVMe, etc.)
# Format: space-separated list, e.g. "0000:04:00.0 0000:05:00.0"
EXTRA_PCI=""

# CPU virtualization module: kvm_intel or kvm_amd
KVM_MODULE="$detected_kvm"

# Enable nested virtualization (yes/no)
KVM_NESTED="yes"

# Load kvmfr module for Looking Glass? (yes/no)
USE_KVMFR="no"
KVMFR_SIZE_MB="128"

# Display manager service name (used by rnv.sh fallback)
# Common values: sddm, gdm, gdm3, lightdm
DISPLAY_MANAGER="$detected_dm"
EOF

    chown -R "${SUDO_USER:-root}:${SUDO_USER:-root}" "$CONFIG_DIR" 2>/dev/null || true

    info "Config created. Review it at: $CONFIG_FILE"
    info "Re-run this script after verifying the config."
    exit 0
}

if [ ! -f "$CONFIG_FILE" ]; then
    init_config
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

if [ -z "${GPU_PCI:-}" ] || [ "$GPU_PCI" = "0000:00:00.0" ]; then
    error "GPU_PCI not set in $CONFIG_FILE"
    exit 1
fi

if [ ! -e "/sys/bus/pci/devices/${GPU_PCI}" ]; then
    error "GPU at $GPU_PCI not found on PCI bus"
    error "Edit $CONFIG_FILE with the correct PCI address"
    exit 1
fi

PCI_DEVICES=("$GPU_PCI")
[ -n "${AUDIO_PCI:-}" ] && PCI_DEVICES+=("$AUDIO_PCI")
if [ -n "${EXTRA_PCI:-}" ]; then
    for pci in $EXTRA_PCI; do
        PCI_DEVICES+=("$pci")
    done
fi

info "PCI devices to detach: ${PCI_DEVICES[*]}"

# ===== 1. Block nvidia module auto-loading =====
info "Blocking nvidia module auto-load"
mkdir -p /run/modprobe.d
cat > /run/modprobe.d/no-nvidia.conf << 'EOF'
install nvidia /bin/false
install nvidia_drm /bin/false
install nvidia_modeset /bin/false
install nvidia_uvm /bin/false
EOF

# ===== 2. Kill all processes holding NVIDIA devices =====
info "Killing processes holding NVIDIA devices"
for i in 1 2 3; do
    if ls /dev/nvidia* >/dev/null 2>&1; then
        pids=$(lsof /dev/nvidia* 2>/dev/null | awk 'NR>1 {print $2}' | sort -u)
        if [ -z "$pids" ]; then
            info "No processes holding NVIDIA devices"
            break
        fi
        warn "Round $i: killing PIDs $pids"
        echo "$pids" | xargs -r kill -9 2>/dev/null
        sleep 1
    else
        break
    fi
done

if ls /dev/nvidia* >/dev/null 2>&1; then
    while fuser -k -9 /dev/nvidia* 2>/dev/null; do
        sleep 0.5
    done
fi

# ===== 3. Unload nvidia modules (reverse dependency order) =====
info "Unloading nvidia kernel modules"
for mod in nvidia_drm nvidia_modeset nvidia_uvm nvidia; do
    if lsmod | grep -q "^${mod} "; then
        if rmmod "$mod" 2>/dev/null; then
            info "  Unloaded $mod"
        else
            warn "  Failed to unload $mod, retrying"
            lsof /dev/nvidia* 2>/dev/null | awk 'NR>1 {print $2}' | sort -u | xargs -r kill -9
            sleep 1
            rmmod "$mod" 2>/dev/null || error "  $mod still loaded"
        fi
    fi
done

# ===== 4. Unbind from current driver =====
info "Unbinding devices from current driver"
for pci in "${PCI_DEVICES[@]}"; do
    if [ -e "/sys/bus/pci/devices/${pci}/driver" ]; then
        echo "$pci" > "/sys/bus/pci/devices/${pci}/driver/unbind" 2>/dev/null \
            && info "  $pci unbound" || warn "  $pci unbind failed"
    fi
done

# ===== 5. Load vfio-pci =====
info "Loading vfio-pci"
modprobe vfio-pci || { error "vfio-pci load failed"; exit 1; }

# ===== 6. Set driver_override =====
info "Setting driver_override = vfio-pci"
for pci in "${PCI_DEVICES[@]}"; do
    echo "vfio-pci" > "/sys/bus/pci/devices/${pci}/driver_override"
done

# ===== 7. Trigger driver probe =====
info "Triggering driver probe"
for pci in "${PCI_DEVICES[@]}"; do
    echo "$pci" > /sys/bus/pci/drivers_probe
done

# ===== 8. Load KVM and optional kvmfr =====
if [ -n "${KVM_MODULE:-}" ]; then
    info "Loading $KVM_MODULE"
    nested_arg=""
    [ "${KVM_NESTED:-no}" = "yes" ] && nested_arg="nested=1"
    modprobe "$KVM_MODULE" $nested_arg cpuid_fastpath=0 2>/dev/null \
        || warn "$KVM_MODULE load failed (check BIOS for VT-x/AMD-V)"

    if [ -e /sys/module/kvm/parameters/cpuid_fastpath ]; then
        echo "N" > /sys/module/kvm/parameters/cpuid_fastpath 2>/dev/null || true
    fi
fi

if [ "${USE_KVMFR:-no}" = "yes" ]; then
    info "Loading kvmfr (Looking Glass)"
    modprobe kvmfr static_size_mb="${KVMFR_SIZE_MB:-128}" 2>/dev/null \
        || warn "kvmfr load failed (install Looking Glass kernel module first)"
fi

# ===== 9. Verify =====
echo ""
info "=== Verification ==="
all_ok=1
for pci in "${PCI_DEVICES[@]}"; do
    driver=$(lspci -k -s "$pci" 2>/dev/null | grep "Kernel driver in use:" | awk '{print $NF}')
    if [ "$driver" = "vfio-pci" ]; then
        info "✓ $pci bound to vfio-pci"
    else
        error "✗ $pci driver = ${driver:-none} (expected vfio-pci)"
        all_ok=0
    fi
done

echo ""
if [ "$all_ok" = "1" ]; then
    info "==================================="
    info "  GPU detached, ready for VM use"
    info "==================================="
else
    error "==================================="
    error "  Some devices failed to bind"
    error "==================================="
fi

echo ""
lspci -k -s "$GPU_PCI"
[ -n "${AUDIO_PCI:-}" ] && lspci -k -s "$AUDIO_PCI"
