#!/usr/bin/env bash
#
# k8s-gvisor-check.sh
# Compatibility/pre-flight checks for:
#   - Raspberry Pi / ARM64
#   - Kubernetes
#   - containerd
#   - gVisor
#
# This script does NOT install or modify anything.

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
echo "This script performs read-only compatibility checks."
echo "It will NOT install or modify Kubernetes, Docker, containerd,"
echo "gVisor, kernel settings, or system configuration."
echo

# -------------------------------------------------------------------
# Basic system information
# -------------------------------------------------------------------

section "SYSTEM"

info "Hostname: $(hostname)"
info "OS: $(. /etc/os-release && echo "$PRETTY_NAME")"
info "Kernel: $(uname -r)"
info "Architecture: $(uname -m)"
info "CPU cores: $(nproc)"
info "Memory:"
free -h | sed 's/^/    /'

# Architecture
if [[ "$(uname -m)" == "aarch64" ]]; then
    pass "System architecture is ARM64 (aarch64)"
else
    warn "System architecture is $(uname -m); ARM64 was expected for this Pi/gVisor setup"
fi

# Kernel version
KERNEL_MAJOR=$(uname -r | cut -d. -f1)
KERNEL_MINOR=$(uname -r | cut -d. -f2)

if [[ "$KERNEL_MAJOR" -gt 5 ]] ||
   [[ "$KERNEL_MAJOR" -eq 5 && "$KERNEL_MINOR" -ge 6 ]]; then
    pass "Kernel $(uname -r) is new enough for gVisor"
else
    fail "Kernel $(uname -r) may be too old for the intended gVisor setup"
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
    warn "Could not positively identify cgroup v2; inspect /sys/fs/cgroup manually"
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
    systemctl status containerd --no-pager --lines=5 2>/dev/null | sed 's/^/    /' || true
else
    warn "containerd systemd service was not found"
fi

# -------------------------------------------------------------------
# Docker
# -------------------------------------------------------------------

section "DOCKER"

if command_exists docker; then
    pass "Docker executable found"

    DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)

    if [[ -n "$DOCKER_VERSION" ]]; then
        info "Docker Engine: $DOCKER_VERSION"
    else
        warn "Docker executable exists, but Docker daemon could not be queried"
    fi
else
    warn "Docker executable not found"
fi

if [[ -f /etc/docker/daemon.json ]]; then
    pass "/etc/docker/daemon.json exists"

    echo
    info "Docker runtime configuration:"
    sudo cat /etc/docker/daemon.json 2>/dev/null | sed 's/^/    /' || \
        warn "Could not read /etc/docker/daemon.json"
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
        info "$RUNSC_VERSION"
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

# Test Docker + gVisor if possible
if command_exists docker && command_exists runsc; then
    echo
    info "Testing Docker → gVisor runtime..."

    GVISOR_TEST_OUTPUT=$(sudo docker run --rm --runtime=runsc ubuntu:24.04 uname -r 2>&1 || true)

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
lsmod | grep -E 'overlay|br_netfilter' | sed 's/^/    /' || \
    info "No matching modules currently loaded"

# -------------------------------------------------------------------
# Networking / sysctl
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

# -------------------------------------------------------------------
# Disk
# -------------------------------------------------------------------

section "STORAGE"

ROOT_AVAIL_KB=$(df -Pk / | awk 'NR==2 {print $4}')
ROOT_AVAIL_GB=$((ROOT_AVAIL_KB / 1024 / 1024))

info "Root filesystem:"
df -h / | sed 's/^/    /'

info "Block devices:"
lsblk | sed 's/^/    /'

if [[ "$ROOT_AVAIL_GB" -ge 20 ]]; then
    pass "At least 20 GiB available on root filesystem (${ROOT_AVAIL_GB} GiB)"
elif [[ "$ROOT_AVAIL_GB" -ge 10 ]]; then
    warn "Only ${ROOT_AVAIL_GB} GiB available; enough for experimentation, but storage is getting tight"
else
    fail "Less than 10 GiB available on root filesystem (${ROOT_AVAIL_GB} GiB)"
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
# Kubernetes binaries
# -------------------------------------------------------------------

section "KUBERNETES TOOLS"

if command_exists kubeadm; then
    pass "kubeadm is installed"
    info "$(kubeadm version -o short 2>/dev/null || kubeadm version 2>/dev/null | head -n1)"
else
    info "kubeadm is not installed yet"
fi

if command_exists kubelet; then
    pass "kubelet is installed"
else
    info "kubelet is not installed yet"
fi

if command_exists kubectl; then
    pass "kubectl is installed"
else
    info "kubectl is not installed yet"
fi

# -------------------------------------------------------------------
# Summary
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
    echo -e "${YELLOW}RESULT: CONDITIONALLY READY${RESET}"
    echo
    echo "No hard blockers were detected, but review the warnings above"
    echo "before deploying Kubernetes."
elif [[ "$FAIL" -le 2 ]]; then
    echo -e "${YELLOW}RESULT: NOT YET READY${RESET}"
    echo
    echo "A small number of prerequisites are missing."
    echo "These should be straightforward to address before deployment."
else
    echo -e "${RED}RESULT: NOT READY${RESET}"
    echo
    echo "Multiple compatibility blockers were detected."
    echo "Do not proceed with Kubernetes installation until they are resolved."
fi

echo
echo "============================================================"
echo " End of compatibility check"
echo "============================================================"
