#!/usr/bin/env bash
# =============================================================================
# swap-driver.sh — NVIDIA driver swap script for leodagan
# =============================================================================
#
# Swaps between stock apt NVIDIA drivers and CI-built P2P-patched kernel
# modules from the lebot-labs/nvidia-open-gpu-p2p fork.
#
# Usage:
#   sudo ./swap-driver.sh <version> [--patched|--stock] [--artifact-dir <path>]
#
# Examples:
#   sudo ./swap-driver.sh 590 --artifact-dir /tmp/nvidia-ko/   # Install P2P-patched 590
#   sudo ./swap-driver.sh 590 --stock                           # Install stock apt 590 driver
#   sudo ./swap-driver.sh 570 --stock                           # Downgrade to stock 570 driver
#   sudo ./swap-driver.sh 570 --artifact-dir /tmp/nvidia-ko-570 # Install P2P-patched 570
#
# Prerequisites:
#   - Must be run as root (or via sudo)
#   - Target apt package must be available in apt cache
#
# Options:
#   --patched              Install P2P-patched kernel modules (default)
#   --stock                Install stock apt driver without custom modules
#   --artifact-dir <path>  Use local .ko files instead of downloading from CI
#
# What it does:
#   1. Resolves version and validates the target apt package
#   2. Installs the apt package if not already present (provides userspace libs)
#   3. Stops k3s-agent, nvidia-persistenced, and kills GPU-holding processes
#   4. Unloads all nvidia kernel modules (with retries)
#   5. For --patched: copies .ko files from --artifact-dir
#      to /lib/modules/$(uname -r)/updates/dkms/
#   6. Runs depmod -a and modprobes all nvidia modules
#   7. Regenerates CDI spec for container runtimes
#   8. Restarts containerd, docker, k3s-agent, nvidia-persistenced
#   9. Verifies with nvidia-smi
#
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Version mapping: short -> full version, apt package name
# Add new entries here when new driver branches are created.
# ---------------------------------------------------------------------------
declare -A VERSION_MAP=(
    [570]="570.211.01"
    [590]="590.48.01"
)

declare -A APT_PACKAGE_MAP=(
    [570]="nvidia-driver-570-server-open"
    [590]="nvidia-driver-590-server-open"
)

# All nvidia kernel modules in unload order (dependents first)
NVIDIA_MODULES=(nvidia_uvm nvidia_drm nvidia_modeset nvidia_peermem nvidia)

# Corresponding .ko file names (for patched install)
NVIDIA_KO_FILES=(nvidia.ko nvidia-uvm.ko nvidia-drm.ko nvidia-modeset.ko nvidia-peermem.ko)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${GREEN}==>${NC} $*"; }

die() {
    err "$@"
    exit 1
}

# ---------------------------------------------------------------------------
# Resolve version: accept short (590) or full (590.48.01) form
# Sets: FULL_VERSION, SHORT_VERSION, APT_PACKAGE
# ---------------------------------------------------------------------------
resolve_version() {
    local input="$1"

    # Check if input is a short version (just a number like 570, 590)
    if [[ -n "${VERSION_MAP[$input]+x}" ]]; then
        SHORT_VERSION="$input"
        FULL_VERSION="${VERSION_MAP[$input]}"
        APT_PACKAGE="${APT_PACKAGE_MAP[$input]}"
        return 0
    fi

    # Check if input is a full version — reverse-lookup the short version
    for short in "${!VERSION_MAP[@]}"; do
        if [[ "${VERSION_MAP[$short]}" == "$input" ]]; then
            SHORT_VERSION="$short"
            FULL_VERSION="$input"
            APT_PACKAGE="${APT_PACKAGE_MAP[$short]}"
            return 0
        fi
    done

    die "Unknown version: $input\nKnown versions: ${!VERSION_MAP[*]}"
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
usage() {
    echo "Usage: $0 <version> [--patched|--stock] [--artifact-dir <path>]"
    echo ""
    echo "  version               Driver version: short (570, 590) or full (570.211.01, 590.48.01)"
    echo "  --patched             Install P2P-patched kernel modules (default)"
    echo "  --stock               Install stock apt driver without custom modules"
    echo "  --artifact-dir <path> Directory containing .ko files to install"
    exit 1
}

if [[ $# -lt 1 ]]; then
    usage
fi

VERSION_INPUT="$1"
MODE="patched"  # default
ARTIFACT_DIR=""

shift
while [[ $# -gt 0 ]]; do
    case "$1" in
        --patched) MODE="patched" ;;
        --stock)   MODE="stock" ;;
        --artifact-dir)
            shift
            [[ $# -eq 0 ]] && die "--artifact-dir requires a path"
            ARTIFACT_DIR="$1"
            ;;
        -h|--help) usage ;;
        *)         die "Unknown argument: $1" ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root (use sudo)."
fi

resolve_version "$VERSION_INPUT"

KERNEL_VERSION="$(uname -r)"
MODULE_DIR="/lib/modules/${KERNEL_VERSION}/updates/dkms"

step "Driver swap configuration"
info "Target version:  ${FULL_VERSION} (${SHORT_VERSION})"
info "Mode:            ${MODE}"
info "APT package:     ${APT_PACKAGE}"
info "Kernel:          ${KERNEL_VERSION}"
if [[ "$MODE" == "patched" ]]; then
    info "Artifact dir:    ${ARTIFACT_DIR}"
    info "Module dir:      ${MODULE_DIR}"
fi

# Show current driver
echo ""
info "Current driver:"
if [[ -f /proc/driver/nvidia/version ]]; then
    cat /proc/driver/nvidia/version | head -1
else
    warn "No NVIDIA driver currently loaded."
fi

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
echo ""
if [[ "$MODE" == "patched" ]]; then
    echo -e "${YELLOW}This will install P2P-patched NVIDIA ${FULL_VERSION} kernel modules.${NC}"
else
    echo -e "${YELLOW}This will install stock NVIDIA ${FULL_VERSION} driver from apt.${NC}"
fi
echo -e "${YELLOW}GPU workloads (k3s-agent, containers) will be temporarily stopped.${NC}"
echo ""
read -r -p "Proceed? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    info "Aborted."
    exit 0
fi

# ---------------------------------------------------------------------------
# Step 1: Ensure apt package is installed (provides userspace libs)
# ---------------------------------------------------------------------------
step "Checking apt package: ${APT_PACKAGE}"
if dpkg -l "$APT_PACKAGE" 2>/dev/null | grep -q "^ii"; then
    ok "Package ${APT_PACKAGE} is already installed."
else
    info "Installing ${APT_PACKAGE} (userspace libraries)..."
    apt-get update -qq
    apt-get install -y "$APT_PACKAGE" || die "Failed to install ${APT_PACKAGE}. Is it available in your apt sources?"
    ok "Package ${APT_PACKAGE} installed."
fi

# ---------------------------------------------------------------------------
# Step 2: For --patched, validate artifact directory
# ---------------------------------------------------------------------------
if [[ "$MODE" == "patched" ]]; then
    step "Validating P2P-patched kernel modules"

    if [[ -z "$ARTIFACT_DIR" ]]; then
        die "Patched mode requires --artifact-dir <path> pointing to a directory with .ko files."
    fi

    if [[ ! -d "$ARTIFACT_DIR" ]]; then
        die "Artifact directory does not exist: ${ARTIFACT_DIR}"
    fi

    KO_COUNT=$(find "$ARTIFACT_DIR" -maxdepth 1 -name "*.ko" | wc -l)
    if [[ "$KO_COUNT" -eq 0 ]]; then
        die "No .ko files found in ${ARTIFACT_DIR}"
    fi
    ok "Found ${KO_COUNT} kernel module(s) in ${ARTIFACT_DIR}:"
    find "$ARTIFACT_DIR" -maxdepth 1 -name "*.ko" -exec basename {} \; | sort | while read -r f; do
        info "  ${f}"
    done
fi

# ---------------------------------------------------------------------------
# Step 3: Stop services holding the GPU
# ---------------------------------------------------------------------------
step "Stopping GPU-dependent services"

# Stop k3s-agent
if systemctl is-active --quiet k3s-agent 2>/dev/null; then
    info "Stopping k3s-agent..."
    systemctl stop k3s-agent
    ok "k3s-agent stopped."
else
    info "k3s-agent is not running."
fi

# Stop nvidia-persistenced
if systemctl is-active --quiet nvidia-persistenced 2>/dev/null; then
    info "Stopping nvidia-persistenced..."
    systemctl stop nvidia-persistenced
    ok "nvidia-persistenced stopped."
else
    info "nvidia-persistenced is not running."
fi

# Kill any remaining processes using /dev/nvidia*
info "Killing processes holding /dev/nvidia* devices..."
if command -v fuser &>/dev/null; then
    fuser -k /dev/nvidia* 2>/dev/null || true
fi
# Also check for common offenders by name
for proc in dcgm-exporter nv-hostengine nvidia-smi; do
    if pgrep -x "$proc" &>/dev/null; then
        info "  Killing ${proc}..."
        pkill -9 -x "$proc" 2>/dev/null || true
    fi
done

# Give processes a moment to exit
sleep 2
ok "GPU processes cleared."

# ---------------------------------------------------------------------------
# Step 4: Unload nvidia kernel modules
# ---------------------------------------------------------------------------
step "Unloading NVIDIA kernel modules"

MAX_RETRIES=5
for attempt in $(seq 1 $MAX_RETRIES); do
    all_unloaded=true
    for mod in "${NVIDIA_MODULES[@]}"; do
        if lsmod | grep -q "^${mod}"; then
            info "Unloading ${mod}... (attempt ${attempt}/${MAX_RETRIES})"
            if rmmod "$mod" 2>/dev/null; then
                ok "  ${mod} unloaded."
            else
                warn "  ${mod} still in use."
                all_unloaded=false
            fi
        fi
    done

    if $all_unloaded; then
        break
    fi

    if [[ $attempt -eq $MAX_RETRIES ]]; then
        # Show what's still holding modules
        err "Failed to unload all modules after ${MAX_RETRIES} attempts."
        info "Remaining loaded nvidia modules:"
        lsmod | grep nvidia || true
        info "Processes using nvidia devices:"
        fuser -v /dev/nvidia* 2>/dev/null || true
        die "Cannot proceed — nvidia modules are still in use."
    fi

    info "Waiting 3s before retry..."
    sleep 3
done

# Final verification
if lsmod | grep -q "^nvidia"; then
    die "nvidia modules are still loaded. Cannot proceed."
fi
ok "All NVIDIA modules unloaded."

# ---------------------------------------------------------------------------
# Step 5: Install modules
# ---------------------------------------------------------------------------
if [[ "$MODE" == "patched" ]]; then
    step "Installing P2P-patched kernel modules"
    mkdir -p "$MODULE_DIR"

    # Remove any DKMS-built compressed modules so modprobe uses our .ko files
    info "Removing DKMS-built .ko.zst files from ${MODULE_DIR}/"
    find "$MODULE_DIR" -maxdepth 1 -name "nvidia*.ko.zst" -exec rm -v {} \;

    info "Copying .ko files to ${MODULE_DIR}/"
    find "$ARTIFACT_DIR" -maxdepth 1 -name "*.ko" -exec cp -v {} "$MODULE_DIR/" \;
    ok "Patched modules installed."
else
    step "Restoring stock kernel modules"
    # Remove any patched modules so the stock ones from the apt package take effect
    if [[ -d "$MODULE_DIR" ]]; then
        for ko in "${NVIDIA_KO_FILES[@]}"; do
            if [[ -f "${MODULE_DIR}/${ko}" ]]; then
                info "Removing patched module: ${MODULE_DIR}/${ko}"
                rm -f "${MODULE_DIR}/${ko}"
            fi
        done
    fi
    ok "Stock modules restored (apt package modules will be used)."
fi

# ---------------------------------------------------------------------------
# Step 6: depmod + modprobe
# ---------------------------------------------------------------------------
step "Rebuilding module dependencies"
depmod -a
ok "depmod complete."

step "Loading NVIDIA kernel modules"
modprobe nvidia
modprobe nvidia_uvm
modprobe nvidia_modeset
modprobe nvidia_drm
modprobe nvidia_peermem 2>/dev/null || warn "nvidia_peermem not available (optional)."
ok "NVIDIA modules loaded."

# ---------------------------------------------------------------------------
# Step 7: Regenerate CDI spec
# ---------------------------------------------------------------------------
step "Regenerating CDI spec"
if command -v nvidia-ctk &>/dev/null; then
    nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
    ok "CDI spec regenerated."
else
    warn "nvidia-ctk not found — skipping CDI spec generation."
fi

# ---------------------------------------------------------------------------
# Step 8: Restart container runtimes and services
# ---------------------------------------------------------------------------
step "Restarting container runtimes"

if systemctl is-enabled --quiet containerd 2>/dev/null; then
    info "Restarting containerd..."
    systemctl restart containerd
    ok "containerd restarted."
fi

if systemctl is-enabled --quiet docker 2>/dev/null; then
    info "Restarting docker..."
    systemctl restart docker
    ok "docker restarted."
fi

step "Starting GPU services"

if systemctl is-enabled --quiet nvidia-persistenced 2>/dev/null; then
    info "Starting nvidia-persistenced..."
    systemctl start nvidia-persistenced
    ok "nvidia-persistenced started."
fi

if systemctl is-enabled --quiet k3s-agent 2>/dev/null; then
    info "Starting k3s-agent..."
    systemctl start k3s-agent
    ok "k3s-agent started."
fi

# ---------------------------------------------------------------------------
# Step 9: Verification
# ---------------------------------------------------------------------------
step "Verification"

echo ""
info "Driver version:"
if [[ -f /proc/driver/nvidia/version ]]; then
    cat /proc/driver/nvidia/version | head -1
else
    warn "/proc/driver/nvidia/version not found."
fi

echo ""
info "nvidia-smi:"
if command -v nvidia-smi &>/dev/null; then
    nvidia-smi --query-gpu=index,name,driver_version,memory.total --format=csv,noheader || warn "nvidia-smi failed."
else
    warn "nvidia-smi not found."
fi

echo ""
info "Loaded nvidia modules:"
lsmod | grep nvidia || warn "No nvidia modules loaded."

# Check if patched modules are in place
echo ""
if [[ "$MODE" == "patched" ]]; then
    patched_count=$(find "$MODULE_DIR" -name "nvidia*.ko" 2>/dev/null | wc -l)
    if [[ "$patched_count" -gt 0 ]]; then
        ok "P2P-patched modules active (${patched_count} .ko files in ${MODULE_DIR})."
    else
        warn "No patched .ko files found in ${MODULE_DIR} — something may have gone wrong."
    fi
else
    patched_count=$(find "$MODULE_DIR" -name "nvidia*.ko" 2>/dev/null | wc -l)
    if [[ "$patched_count" -eq 0 ]]; then
        ok "Stock driver active (no patched overrides in ${MODULE_DIR})."
    else
        warn "Found ${patched_count} patched .ko files still in ${MODULE_DIR}."
    fi
fi

echo ""
ok "Driver swap complete: NVIDIA ${FULL_VERSION} (${MODE})."
