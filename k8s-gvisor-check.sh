#!/usr/bin/env bash
#
# k8s-gvisor-check.sh
# Read-only pre-flight checks for:
#   - Raspberry Pi 5 / ARM64
#   - Debian / Linux
#   - Kubernetes
#   - containerd
#   - gVisor
#   - Kubernetes networking / CNI prerequisites
# This script DOES NOT modify the system.
# It is safe to run repeatedly.

set -u

PASS=0
WARN=0
FAIL=0

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
RESET='\033[0m'

pass() {
    echo -e "  ${GREEN}[PASS]${RESET} $1"
    PASS=$((PASS + 1))
}

warn() {
    echo -e "  ${YELLOW}[WARN]${RESET} $1"
    WARN=$((WARN + 1))
}

fail() {
    echo -e "  ${RED}[FAIL]${RESET} $1"
    FAIL=$((FAIL + 1))
}

info() {
    echo -e "  ${BLUE}[INFO]${RESET} $1"
}

section() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# -------------------------------------------------------------------
# Header
# -------------------------------------------------------------------

clear 2>/dev/null || true

echo "============================================================"
echo " Kubernetes + gVisor Compatibility Check"
echo " Raspberry Pi / Linux"
echo "============================================================"
echo
echo "This script performs READ-ONLY compatibility checks."
echo
echo "It will NOT:"
echo "  - install Kubernetes"
echo "  - modify Docker"
echo "  - modify containerd"
echo "  - modify gVisor"
echo "  - load kernel modules"
echo "  - change sysctl settings"
echo "  - change firewall rules"
echo "  - modify networking"
echo

# -------------------------------------------------------------------
# Privilege check
# -------------------------------------------------------------------

section "PRIVILEGES"

if [[ $EUID -eq 0 ]]; then
    pass "Running as root"
else
    info "Running as user: $(id -un)"

    if command_exists sudo && sudo -n true 2>/dev/null; then
        pass "sudo is available without prompting"
    elif command_exists sudo; then
        info "sudo is available; privileged checks may prompt for your password"
    else
        warn "sudo is not available; some checks may be incomplete"
    fi
fi

# -------------------------------------------------------------------
# System
# -------------------------------------------------------------------

section "SYSTEM"

OS_NAME="unknown"
OS_VERSION="unknown"

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_NAME="${PRETTY_NAME:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
fi

info "Hostname: $(hostname)"
info "OS: $OS_NAME"
info "Kernel: $(uname -r)"
info "Architecture: $(uname -m)"
info "CPU cores: $(nproc)"

echo
info "Memory:"
free -h | sed 's/^/    /'

if [[ "$(uname -m)" == "aarch64" ]]; then
    pass "System architecture is ARM64 (aarch64)"
else
    warn "System architecture is $(uname -m); ARM64 was expected"
fi

KERNEL_MAJOR=$(uname -r | cut -d. -f1)
KERNEL_MINOR=$(uname -r | cut -d. -f2)

if [[ "$KERNEL_MAJOR" -gt 5 ]] ||
   [[ "$KERNEL_MAJOR" -eq 5 && "$KERNEL_MINOR" -ge 6 ]]; then
    pass "Kernel $(uname -r) is new enough for gVisor"
else
    fail "Kernel $(uname -r) may be too old for the intended gVisor setup"
fi

# -------------------------------------------------------------------
# Raspberry Pi detection
# -------------------------------------------------------------------

section "HARDWARE"

if [[ -f /proc/device-tree/model ]]; then
    PI_MODEL=$(tr -d '\0' < /proc/device-tree/model)

    info "Device: $PI_MODEL"

    if echo "$PI_MODEL" | grep -qi "Raspberry Pi 5"; then
        pass "Raspberry Pi 5 detected"
    else
        info "Device is not identified as a Raspberry Pi 5"
    fi
else
    info "Raspberry Pi device-tree model unavailable"
fi

# -------------------------------------------------------------------
# cgroups
# -------------------------------------------------------------------

section "CGROUPS"

CGROUP_FS=$(stat -fc %T /sys/fs/cgroup 2>/dev/null || true)

info "cgroup filesystem: ${CGROUP_FS:-unknown}"

if [[ "$CGROUP_FS" == "cgroup2fs" ]]; then
    pass "cgroup v2 detected"
elif [[ "$CGROUP_FS" == "tmpfs" ]]; then
    warn "Could not positively identify cgroup v2"
else
    warn "Unexpected cgroup filesystem: ${CGROUP_FS:-unknown}"
fi

if mount | grep -q 'type cgroup2'; then
    pass "cgroup2 is mounted"
else
    warn "Could not find a cgroup2 mount"
fi

echo
info "cgroup mounts:"
mount | grep cgroup | sed 's/^/    /' || true

# Check systemd cgroup hierarchy where possible
if command_exists systemd-detect-virt; then
    info "Virtualization: $(systemd-detect-virt 2>/dev/null || echo none)"
fi

# -------------------------------------------------------------------
# containerd
# -------------------------------------------------------------------

section "CONTAINERD"

if command_exists containerd; then
    pass "containerd executable found"
    info "Version: $(containerd --version)"
else
    fail "containerd executable not found"
fi

if systemctl list-unit-files containerd.service >/dev/null 2>&1; then
    if systemctl is-active --quiet containerd; then
        pass "containerd service is running"
    else
        warn "containerd service exists but is not currently running"
    fi

    echo
    info "containerd service status:"
    systemctl status containerd --no-pager --lines=5 2>/dev/null |
        sed 's/^/    /' || true
else
    warn "containerd systemd service was not found"
fi

# Check containerd socket
if [[ -S /run/containerd/containerd.sock ]]; then
    pass "containerd socket exists: /run/containerd/containerd.sock"
else
    warn "containerd socket not found at /run/containerd/containerd.sock"
fi

# -------------------------------------------------------------------
# Docker
# -------------------------------------------------------------------

section "DOCKER"

DOCKER_AVAILABLE=false

if command_exists docker; then
    pass "Docker executable found"
    DOCKER_AVAILABLE=true

    # Query Docker through sudo because the current user may not
    # belong to the docker group.
    DOCKER_VERSION_OUTPUT=$(sudo docker version --format '{{.Server.Version}}' 2>&1 || true)

    if [[ "$DOCKER_VERSION_OUTPUT" =~ ^[0-9] ]]; then
        pass "Docker daemon is reachable"
        info "Docker Engine: $DOCKER_VERSION_OUTPUT"
    else
        warn "Docker executable exists, but Docker daemon could not be queried"
        info "This is commonly caused by the current user lacking access to /var/run/docker.sock"
    fi
else
    info "Docker executable not found"
fi

if [[ -f /etc/docker/daemon.json ]]; then
    pass "/etc/docker/daemon.json exists"

    echo
    info "Docker runtime configuration:"
    sudo cat /etc/docker/daemon.json 2>/dev/null |
        sed 's/^/    /' || warn "Could not read /etc/docker/daemon.json"
else
    info "/etc/docker/daemon.json does not exist"
fi

# -------------------------------------------------------------------
# gVisor
# -------------------------------------------------------------------

section "GVISOR"

if command_exists runsc; then
    pass "runsc executable found"

    RUNSC_VERSION=$(sudo runsc --version 2>/dev/null || true)

    if [[ -n "$RUNSC_VERSION" ]]; then
        echo "$RUNSC_VERSION" | sed 's/^/  [INFO] /'
    else
        warn "runsc exists but version could not be queried"
    fi
else
    fail "runsc executable not found"
fi

if command_exists containerd-shim-runsc-v1; then
    pass "containerd-shim-runsc-v1 found"
    info "Path: $(command -v containerd-shim-runsc-v1)"
else
    fail "containerd-shim-runsc-v1 not found"
    info "This is required for Kubernetes → containerd → gVisor integration"
fi

# Docker → gVisor smoke test
if [[ "$DOCKER_AVAILABLE" == true ]] && command_exists runsc; then
    echo
    info "Testing Docker → gVisor runtime..."

    GVISOR_TEST_OUTPUT=$(
        sudo docker run --rm --runtime=runsc ubuntu:24.04 uname -r 2>&1
    ) || true

    if echo "$GVISOR_TEST_OUTPUT" | grep -q "gvisor"; then
        pass "Docker can successfully launch a gVisor container"
        info "Container kernel: $(echo "$GVISOR_TEST_OUTPUT" | tail -n1)"
    else
        warn "Docker → gVisor test did not report a gVisor kernel"
        info "Output:"
        echo "$GVISOR_TEST_OUTPUT" | sed 's/^/    /'
    fi
fi

# -------------------------------------------------------------------
# Kernel / boot parameters
# -------------------------------------------------------------------

section "KERNEL / BOOT PARAMETERS"

info "Kernel command line:"
echo "    $(cat /proc/cmdline)"

# cgroup memory configuration
CMDLINE=$(cat /proc/cmdline)

if echo "$CMDLINE" | grep -qw 'cgroup_enable=memory'; then
    pass "cgroup_enable=memory present in kernel command line"
else
    info "cgroup_enable=memory not explicitly present in kernel command line"
fi

if echo "$CMDLINE" | grep -qw 'cgroup_memory=1'; then
    pass "cgroup_memory=1 present in kernel command line"
else
    info "cgroup_memory=1 not explicitly present in kernel command line"
fi

# -------------------------------------------------------------------
# Kernel modules
# -------------------------------------------------------------------

section "KERNEL MODULES"

if lsmod | grep -q '^overlay'; then
    pass "overlay kernel module loaded"
else
    warn "overlay kernel module is not currently loaded"
fi

if lsmod | grep -q '^br_netfilter'; then
    pass "br_netfilter kernel module loaded"
else
    warn "br_netfilter kernel module is not currently loaded"
fi

echo
info "Relevant loaded modules:"
lsmod | grep -E '^(overlay|br_netfilter|nf_|bridge)' |
    sed 's/^/    /' || info "No matching modules currently loaded"

echo
info "Checking br_netfilter availability:"

if command_exists modinfo; then
    if modinfo br_netfilter >/dev/null 2>&1; then
        pass "br_netfilter kernel module is available"
    else
        warn "br_netfilter kernel module is not available"
    fi
else
    info "modinfo is unavailable"
fi

# -------------------------------------------------------------------
# Network interfaces
# -------------------------------------------------------------------

section "NETWORK INTERFACES"

if command_exists ip; then
    info "Interfaces:"
    ip -br addr | sed 's/^/    /'

    echo
    info "Routes:"
    ip route | sed 's/^/    /'
else
    fail "ip command not found"
fi

# -------------------------------------------------------------------
# Kubernetes networking prerequisites
# -------------------------------------------------------------------

section "KUBERNETES NETWORKING PREREQUISITES"

IP_FORWARD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "unknown")

if [[ "$IP_FORWARD" == "1" ]]; then
    pass "IPv4 forwarding enabled"
elif [[ "$IP_FORWARD" == "0" ]]; then
    warn "IPv4 forwarding is disabled"
else
    warn "Could not determine IPv4 forwarding state"
fi

BRIDGE_IPTABLES=$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null || echo "missing")

if [[ "$BRIDGE_IPTABLES" == "1" ]]; then
    pass "bridge-nf-call-iptables enabled"
elif [[ "$BRIDGE_IPTABLES" == "0" ]]; then
    warn "bridge-nf-call-iptables is disabled"
else
    info "bridge-nf-call-iptables is unavailable/not configured"
fi

BRIDGE_IP6TABLES=$(sysctl -n net.bridge.bridge-nf-call-ip6tables 2>/dev/null || echo "missing")

if [[ "$BRIDGE_IP6TABLES" == "1" ]]; then
    pass "bridge-nf-call-ip6tables enabled"
elif [[ "$BRIDGE_IP6TABLES" == "0" ]]; then
    warn "bridge-nf-call-ip6tables is disabled"
else
    info "bridge-nf-call-ip6tables is unavailable/not configured"
fi

# Print all relevant networking sysctls
echo
info "Relevant networking sysctls:"

sysctl -a 2>/dev/null |
    grep -E '(^net\.ipv4\.ip_forward|^net\.ipv6\.conf.*forwarding|^net\.bridge\.bridge-nf)' |
    sed 's/^/    /' || true

# -------------------------------------------------------------------
# nftables
# -------------------------------------------------------------------

section "NFTABLES"

if command_exists nft; then
    pass "nft command found"

    echo
    info "nftables ruleset:"
    sudo nft list ruleset 2>/dev/null |
        sed 's/^/    /' || warn "Could not read nftables ruleset"
else
    warn "nft command not found"
fi

# -------------------------------------------------------------------
# iptables
# -------------------------------------------------------------------

section "IPTABLES"

if command_exists iptables; then
    pass "iptables command found"

    info "iptables version:"
    iptables --version 2>&1 | sed 's/^/    /'

    echo
    info "iptables rules:"
    sudo iptables -L -n -v 2>/dev/null |
        sed 's/^/    /' || warn "Could not read iptables rules"
else
    warn "iptables command not found"
fi

if command_exists ip6tables; then
    pass "ip6tables command found"

    info "ip6tables version:"
    ip6tables --version 2>&1 | sed 's/^/    /'
else
    info "ip6tables command not found"
fi

# -------------------------------------------------------------------
# iptables backend
# -------------------------------------------------------------------

section "IPTABLES BACKEND"

if command_exists update-alternatives; then
    IPTABLES_ALTERNATIVE=$(
        update-alternatives --query iptables 2>/dev/null |
        grep '^Value:' |
        head -n1 |
        cut -d' ' -f2-
    )

    if [[ -n "$IPTABLES_ALTERNATIVE" ]]; then
        info "iptables implementation: $IPTABLES_ALTERNATIVE"

        if echo "$IPTABLES_ALTERNATIVE" | grep -q nft; then
            pass "iptables is using the nftables backend"
        elif echo "$IPTABLES_ALTERNATIVE" | grep -q legacy; then
            warn "iptables is using the legacy backend"
        fi
    else
        info "Could not determine iptables backend"
    fi
else
    info "update-alternatives unavailable"
fi

# -------------------------------------------------------------------
# Bridge networking
# -------------------------------------------------------------------

section "BRIDGE NETWORKING"

if command_exists bridge; then
    info "Current Linux bridges:"
    bridge link show 2>/dev/null | sed 's/^/    /' || true

    echo
    info "Bridge VLAN information:"
    bridge vlan show 2>/dev/null | sed 's/^/    /' || true
else
    info "bridge command unavailable"
fi

# -------------------------------------------------------------------
# DNS
# -------------------------------------------------------------------

section "DNS"

if command_exists resolvectl; then
    info "resolvectl status:"
    resolvectl status 2>/dev/null |
        sed -n '1,80p' |
        sed 's/^/    /' || true
elif [[ -f /etc/resolv.conf ]]; then
    info "/etc/resolv.conf:"
    cat /etc/resolv.conf | sed 's/^/    /'
else
    warn "Could not determine DNS configuration"
fi

# -------------------------------------------------------------------
# Storage
# -------------------------------------------------------------------

section "STORAGE"

ROOT_AVAIL_KB=$(df -Pk / | awk 'NR==2 {print $4}')
ROOT_AVAIL_GB=$((ROOT_AVAIL_KB / 1024 / 1024))

info "Root filesystem:"
df -h / | sed 's/^/    /'

echo
info "Block devices:"
lsblk | sed 's/^/    /'

if [[ "$ROOT_AVAIL_GB" -ge 20 ]]; then
    pass "At least 20 GiB available on root filesystem (${ROOT_AVAIL_GB} GiB)"
elif [[ "$ROOT_AVAIL_GB" -ge 10 ]]; then
    warn "Only ${ROOT_AVAIL_GB} GiB available; enough for experimentation, but storage is getting tight"
else
    fail "Less than 10 GiB available on root filesystem (${ROOT_AVAIL_GB} GiB)"
fi

# Detect microSD root device
ROOT_DEVICE=$(findmnt -n -o SOURCE / 2>/dev/null || true)

if echo "$ROOT_DEVICE" | grep -q 'mmcblk'; then
    warn "Root filesystem is on microSD storage ($ROOT_DEVICE)"
    info "Suitable for initial experimentation, but SSD/NVMe is recommended for sustained Kubernetes workloads"
fi

# -------------------------------------------------------------------
# Memory
# -------------------------------------------------------------------

section "MEMORY"

TOTAL_MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
TOTAL_MEM_GB=$((TOTAL_MEM_KB / 1024 / 1024))

if [[ "$TOTAL_MEM_GB" -ge 4 ]]; then
    pass "At least 4 GiB RAM available (${TOTAL_MEM_GB} GiB detected)"
else
    warn "Only ${TOTAL_MEM_GB} GiB RAM detected; Kubernetes will be constrained"
fi

# -------------------------------------------------------------------
# Swap
# -------------------------------------------------------------------

section "SWAP"

SWAP_TOTAL=$(free -h | awk '/^Swap:/ {print $2}')
SWAP_USED=$(free -h | awk '/^Swap:/ {print $3}')

info "Swap total: $SWAP_TOTAL"
info "Swap used:  $SWAP_USED"

if swapon --show --noheadings 2>/dev/null | grep -q .; then
    pass "Swap is configured"

    echo
    info "Active swap:"
    swapon --show | sed 's/^/    /'
else
    info "No active swap detected"
fi

# -------------------------------------------------------------------
# Kubernetes tools
# -------------------------------------------------------------------

section "KUBERNETES TOOLS"

if command_exists kubeadm; then
    pass "kubeadm is installed"
    kubeadm version -o short 2>/dev/null |
        sed 's/^/  [INFO] kubeadm: /' || true
else
    info "kubeadm is not installed yet"
fi

if command_exists kubelet; then
    pass "kubelet is installed"
    kubelet --version 2>/dev/null |
        sed 's/^/  [INFO] kubelet: /' || true
else
    info "kubelet is not installed yet"
fi

if command_exists kubectl; then
    pass "kubectl is installed"
    kubectl version --client --output=yaml 2>/dev/null |
        grep -E 'gitVersion:' |
        sed 's/^/  [INFO] /' || true
else
    info "kubectl is not installed yet"
fi

# -------------------------------------------------------------------
# Relevant ports
# -------------------------------------------------------------------

section "KUBERNETES PORTS"

if command_exists ss; then
    info "Currently listening TCP ports:"
    sudo ss -lntp 2>/dev/null | sed 's/^/    /' || true

    echo
    info "Currently listening UDP ports:"
    sudo ss -lnup 2>/dev/null | sed 's/^/    /' || true
else
    info "ss command unavailable"
fi

# -------------------------------------------------------------------
# Container runtime sockets/processes
# -------------------------------------------------------------------

section "CONTAINER RUNTIME PROCESSES"

info "Relevant processes:"
ps aux |
    grep -E 'containerd|dockerd|runsc|containerd-shim' |
    grep -v grep |
    sed 's/^/    /' || true

# -------------------------------------------------------------------
# Containerd configuration
# -------------------------------------------------------------------

section "CONTAINERD CONFIGURATION"

if [[ -f /etc/containerd/config.toml ]]; then
    pass "/etc/containerd/config.toml exists"

    echo
    info "Relevant containerd runtime configuration:"

    grep -nE \
        'version|SystemdCgroup|runtime_type|runtime_path|runsc|shim|runc' \
        /etc/containerd/config.toml 2>/dev/null |
        sed 's/^/    /' || true
else
    info "/etc/containerd/config.toml does not exist"
fi

# -------------------------------------------------------------------
# gVisor/containerd integration
# -------------------------------------------------------------------

section "GVISOR CONTAINERD INTEGRATION"

if command_exists containerd-shim-runsc-v1; then
    SHIM_PATH=$(command -v containerd-shim-runsc-v1)

    info "gVisor containerd shim: $SHIM_PATH"

    if [[ -x "$SHIM_PATH" ]]; then
        pass "gVisor containerd shim is executable"
    else
        warn "gVisor containerd shim exists but is not executable"
    fi
fi

# Check common binary locations
for path in \
    /usr/bin/runsc \
    /usr/local/bin/runsc \
    /usr/bin/containerd-shim-runsc-v1 \
    /usr/local/bin/containerd-shim-runsc-v1
do
    if [[ -e "$path" ]]; then
        info "Found: $path"
    fi
done

# -------------------------------------------------------------------
# Overall assessment
# -------------------------------------------------------------------

section "RESULT"

echo
echo "  PASS: $PASS"
echo "  WARN: $WARN"
echo "  FAIL: $FAIL"
echo

if [[ "$FAIL" -eq 0 && "$WARN" -eq 0 ]]; then

    echo -e "${GREEN}RESULT: READY${RESET}"
    echo
    echo "The environment looks good for Kubernetes + gVisor deployment."
    echo "No compatibility blockers were detected."

elif [[ "$FAIL" -eq 0 ]]; then

    echo -e "${YELLOW}RESULT: READY WITH WARNINGS${RESET}"
    echo
    echo "No hard compatibility blockers were detected."
    echo
    echo "Review the warnings above, particularly:"
    echo "  - br_netfilter"
    echo "  - bridge-nf-* sysctls"
    echo "  - storage capacity"
    echo "  - networking/firewall configuration"
    echo
    echo "These do not automatically prevent Kubernetes deployment."

elif [[ "$FAIL" -le 2 ]]; then

    echo -e "${YELLOW}RESULT: NOT YET READY${RESET}"
    echo
    echo "A small number of prerequisites are missing."
    echo "Resolve the FAIL items before deploying Kubernetes."

else

    echo -e "${RED}RESULT: NOT READY${RESET}"
    echo
    echo "Multiple compatibility blockers were detected."
    echo "Resolve the FAIL items before deploying Kubernetes."

fi

echo
echo "============================================================"
echo " Deployment guidance"
echo "============================================================"
echo

if [[ "$FAIL" -eq 0 ]]; then
    echo "Recommended next step:"
    echo
    echo "  1. Review the networking diagnostics above."
    echo "  2. Configure Kubernetes to use containerd."
    echo "  3. Configure containerd with both runc and runsc."
    echo "  4. Register a Kubernetes RuntimeClass named 'gvisor'."
    echo "  5. Test a normal pod."
    echo "  6. Test a gVisor pod and verify:"
    echo
    echo "       kubectl exec <pod> -- uname -r"
    echo
    echo "     Expected gVisor result:"
    echo "       4.19.0-gvisor"
else
    echo "Do not proceed with Kubernetes installation until the FAIL"
    echo "items above have been resolved."
fi

echo
echo "============================================================"
echo " End of compatibility check"
echo "============================================================"
