#!/usr/bin/env bash
# k8s-gvisor-check.sh
# Read-only readiness and troubleshooting diagnostics for Kubernetes + gVisor
# on Raspberry Pi / Debian-family Linux.
#
# It does not install packages, edit configuration, load modules, change
# sysctls, restart services, or alter the cluster. Some checks use sudo when
# available; the script will still run without it, but some results may be
# incomplete.
#
# Usage:
#   sudo ./k8s-gvisor-check.sh
#   ./k8s-gvisor-check.sh --help
#
# Optional environment:
#   DIAG_LOG=/path/to/report.txt ./k8s-gvisor-check.sh
#   SKIP_DOCKER_SMOKE=1 ./k8s-gvisor-check.sh

set -uo pipefail
export LC_ALL=C
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

VERSION="2.0.0"
PASS=0
WARN=0
FAIL=0
INFO=0
REPORT=""
TMP_DIR=""

usage() {
  cat <<'EOF'
k8s-gvisor-check.sh — read-only Kubernetes + gVisor diagnostics

Options:
  -h, --help       Show this help and exit

Environment variables:
  DIAG_LOG=PATH    Also write output to PATH (parent directory must exist)
  SKIP_DOCKER_SMOKE=1
                   Skip the Docker-to-gVisor smoke test

Run as your normal user for permission diagnostics, or with sudo for more
complete service/configuration inspection. No system changes are made.
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -n "${DIAG_LOG:-}" ]]; then
  if ! : >"$DIAG_LOG" 2>/dev/null; then
    printf 'Cannot write DIAG_LOG=%s\n' "$DIAG_LOG" >&2
    exit 2
  fi
  REPORT="$DIAG_LOG"
fi

cleanup() {
  [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT

emit() {
  printf '%s\n' "$*"
  if [[ -n "$REPORT" ]]; then printf '%s\n' "$*" >>"$REPORT"; fi
}

section() { emit ""; emit "================================================================"; emit "$*"; emit "================================================================"; }
note() { emit "  INFO: $*"; INFO=$((INFO + 1)); }
pass() { emit "  PASS: $*"; PASS=$((PASS + 1)); }
warn() { emit "  WARN: $*"; WARN=$((WARN + 1)); }
fail() { emit "  FAIL: $*"; FAIL=$((FAIL + 1)); }
detail() { emit "        $*"; }

have() { command -v "$1" >/dev/null 2>&1; }

# Prefer sudo for privileged read-only queries when available. If sudo requires
# a password and cannot run non-interactively, fall back to the unprivileged
# command and let the check report limited access.
as_root() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    "$@"
  elif have sudo && sudo -n true >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}

capture() {
  # capture COMMAND [ARGS...]; prints stdout/stderr, tolerates unavailable tools.
  "$@" 2>&1 || true
}

is_active() {
  have systemctl && systemctl is-active --quiet "$1"
}

read_sysctl() {
  local key="$1" file="/proc/sys/${1//./\/}"
  if [[ -r "$file" ]]; then
    tr -d '\n' < "$file"
  elif have sysctl; then
    sysctl -n "$key" 2>/dev/null || printf 'unavailable'
  else
    printf 'unavailable'
  fi
}

show_file_if_present() {
  local f="$1" max_lines="${2:-100}"
  if [[ -f "$f" ]]; then
    detail "File: $f"
    if [[ -r "$f" ]]; then
      sed -n "1,${max_lines}p" "$f" | sed 's/^/        | /'
      local lines
      lines=$(wc -l <"$f" 2>/dev/null || echo 0)
      if (( lines > max_lines )); then detail "... truncated after ${max_lines} lines"; fi
    else
      detail "Not readable as current user."
    fi
  fi
}

TMP_DIR=$(mktemp -d 2>/dev/null || true)

section "KUBERNETES + GVISOR PI DIAGNOSTICS v${VERSION}"
emit "Timestamp: $(date -Is 2>/dev/null || date)"
emit "Hostname:  $(hostname 2>/dev/null || echo unknown)"
emit "User:      $(id 2>/dev/null || echo unknown)"
emit "Report:    ${REPORT:-stdout only}"
emit "Scope:     read-only checks; no system changes"

section "1. HARDWARE, OS AND KERNEL"
ARCH=$(uname -m 2>/dev/null || echo unknown)
KERNEL=$(uname -r 2>/dev/null || echo unknown)
OS_PRETTY=""
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_PRETTY="${PRETTY_NAME:-unknown}"
fi
emit "OS:          ${OS_PRETTY:-unknown}"
emit "Architecture: ${ARCH}"
emit "Kernel:       ${KERNEL}"
if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
  pass "64-bit ARM userspace detected."
else
  warn "Architecture is '$ARCH'; verify compatibility of Kubernetes and gVisor packages."
fi

if have tr; then
  MODEL=""
  for f in /proc/device-tree/model /sys/firmware/devicetree/base/model; do
    if [[ -r "$f" ]]; then MODEL=$(tr -d '\000' <"$f"); break; fi
  done
  if [[ -n "$MODEL" ]]; then
    emit "Device model: $MODEL"
    if [[ "$MODEL" == *"Raspberry Pi 5"* ]]; then pass "Raspberry Pi 5 identified."; else note "Device-tree model is not Raspberry Pi 5; checks are still applicable to many Linux hosts."; fi
  else
    note "Device model not exposed via device tree (possibly a VM or restricted environment)."
  fi
fi

if [[ -r /etc/debian_version ]]; then emit "Debian version: $(cat /etc/debian_version)"; fi
if [[ -r /proc/cmdline ]]; then emit "Kernel cmdline: $(cat /proc/cmdline)"; fi
if have lscpu; then
  emit "CPU summary:"
  lscpu 2>/dev/null | grep -E '^(Architecture|CPU\(s\)|On-line CPU|Model name|Vendor ID|Thread|Core|Socket|Flags):' | sed 's/^/  /' || true
fi
if have vcgencmd; then
  emit "Firmware-reported throttling:"
  vcgencmd get_throttled 2>&1 | sed 's/^/  /' || true
fi

section "2. MEMORY, SWAP AND STORAGE"
if have free; then free -h | sed 's/^/  /'; fi
if [[ -r /proc/swaps ]]; then
  emit "Swap devices:"
  sed -n '1,8p' /proc/swaps | sed 's/^/  /'
  if [[ $(awk 'NR>1 {n++} END {print n+0}' /proc/swaps) -gt 0 ]]; then
    warn "Swap is enabled. Kubernetes kubelet commonly requires swap to be disabled unless configured for swap support."
  else
    pass "No active swap devices reported."
  fi
fi
emit "Filesystem capacity:"
df -hPT / /var /var/lib/containerd /var/lib/kubelet 2>/dev/null | awk '!seen[$7]++' | sed 's/^/  /' || true
ROOT_AVAIL_KB=$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4+0}')
if [[ -n "$ROOT_AVAIL_KB" ]]; then
  if (( ROOT_AVAIL_KB < 2*1024*1024 )); then
    warn "Less than 2 GiB free on root filesystem; images and Kubernetes state may exhaust storage."
  elif (( ROOT_AVAIL_KB < 5*1024*1024 )); then
    warn "Less than 5 GiB free on root filesystem; monitor image and log growth."
  else
    pass "Root filesystem has at least 5 GiB free."
  fi
fi
if have findmnt; then
  emit "Relevant mounts:"
  findmnt -T / -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null | sed 's/^/  /' || true
  findmnt -T /var/lib/containerd -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null | sed 's/^/  /' || true
fi
if [[ -d /sys/fs/cgroup ]]; then
  emit "Cgroup filesystem:"
  stat -fc '  filesystem type: %T' /sys/fs/cgroup 2>/dev/null || true
  if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
    pass "Unified cgroup v2 detected."
    detail "Controllers: $(cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null)"
  else
    warn "cgroup v2 controller file not found; this may be a cgroup v1 or hybrid setup."
  fi
else
  fail "/sys/fs/cgroup is missing."
fi

section "3. PACKAGE AND TOOL INVENTORY"
for cmd in bash systemctl journalctl mount findmnt ip ss awk sed grep; do
  if have "$cmd"; then pass "$cmd: $(command -v "$cmd")"; else warn "$cmd not found."; fi
done
for cmd in containerd ctr crictl nerdctl runsc containerd-shim-runsc-v1 docker kubelet kubeadm kubectl; do
  if have "$cmd"; then
    emit "$cmd: $(command -v "$cmd")"
    case "$cmd" in
      containerd|ctr|crictl|nerdctl|runsc|docker|kubelet|kubeadm|kubectl)
        VER=$("$cmd" --version 2>&1 | head -n 1 || true)
        [[ -n "$VER" ]] && detail "$VER"
        ;;
    esac
  else
    emit "$cmd: not found"
  fi
done

section "4. SYSTEMD SERVICES"
if have systemctl; then
  for svc in containerd docker kubelet; do
    if systemctl list-unit-files "${svc}.service" --no-legend 2>/dev/null | grep -q "${svc}\.service"; then
      state=$(systemctl is-active "$svc" 2>/dev/null || true)
      enabled=$(systemctl is-enabled "$svc" 2>/dev/null || true)
      emit "$svc.service: active=${state:-unknown}, enabled=${enabled:-unknown}"
      if [[ "$svc" == "containerd" ]]; then
        if [[ "$state" == "active" ]]; then pass "containerd service is active."; else fail "containerd service is not active."; fi
      elif [[ "$svc" == "docker" ]]; then
        [[ "$state" == "active" ]] && pass "Docker service is active." || warn "Docker service is not active (not required if Kubernetes uses containerd directly)."
      elif [[ "$svc" == "kubelet" ]]; then
        [[ "$state" == "active" ]] && pass "kubelet service is active." || note "kubelet is not active; expected before Kubernetes installation or if the node is stopped."
      fi
      emit "Recent ${svc} journal (last 12 lines):"
      as_root journalctl -u "$svc" -n 12 --no-pager 2>/dev/null | sed 's/^/  /' || true
    else
      note "$svc.service unit not found."
    fi
  done
else
  warn "systemctl not available; service status cannot be checked."
fi

section "5. CONTAINERD AND CRI CONFIGURATION"
if have containerd; then
  emit "containerd version:"
  capture containerd --version | sed 's/^/  /'
  if have systemctl && systemctl is-active --quiet containerd; then
    pass "containerd is running."
  else
    warn "containerd may not be running; CRI checks can fail."
  fi

  emit "containerd config paths:"
  for f in /etc/containerd/config.toml /etc/containerd/conf.d/*.toml; do
    [[ -f "$f" ]] && emit "  $f"
  done

  if have containerd; then
    CONFIG_DUMP=""
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
      CONFIG_DUMP=$(containerd config dump 2>&1 || true)
    elif have sudo && sudo -n true >/dev/null 2>&1; then
      CONFIG_DUMP=$(sudo containerd config dump 2>&1 || true)
    else
      CONFIG_DUMP=$(containerd config dump 2>&1 || true)
    fi
    if [[ -n "$CONFIG_DUMP" && "$CONFIG_DUMP" != *"permission denied"* ]]; then
      emit "Effective containerd configuration highlights (from 'containerd config dump'):"
      printf '%s\n' "$CONFIG_DUMP" | grep -n -E -i '^(version|root|state|disabled_plugins|imports)|cri|runtime_type|runtime_path|runtime_engine|runsc|SystemdCgroup|sandbox_image|bin_dir|conf_dir|snapshotter|enable_selinux' | head -n 100 | sed 's/^/  /' || true
      if printf '%s\n' "$CONFIG_DUMP" | grep -Eiq 'disabled_plugins[[:space:]]*=.*cri'; then
        fail "The effective containerd config appears to disable the CRI plugin."
      elif printf '%s\n' "$CONFIG_DUMP" | grep -Eiq 'io\.containerd\.(grpc\.)?v1\.cri'; then
        pass "CRI-related configuration appears in containerd config dump; confirm plugin status below."
      else
        warn "No obvious CRI configuration markers found in config dump; inspect the full configuration."
      fi
      if printf '%s\n' "$CONFIG_DUMP" | grep -Eiq 'runsc'; then
        pass "A gVisor/runsc reference appears in the effective containerd configuration."
      else
        warn "No runsc reference found in effective containerd config. Docker's runsc runtime is separate from containerd's CRI runtime configuration."
      fi
    else
      warn "Could not read effective containerd configuration; try running the script with sudo."
    fi
  fi

  if have ctr; then
    emit "containerd plugins (CRI-related rows):"
    as_root ctr plugins ls 2>&1 | grep -E -i 'TYPE|cri|runtime|snapshot' | head -n 35 | sed 's/^/  /' || true
    if as_root ctr plugins ls 2>/dev/null | grep -Eiq 'io\.containerd\.(grpc\.)?v1\.cri.*ok|cri.*ok'; then
      pass "containerd plugin listing reports a CRI plugin in an OK state."
    else
      warn "Could not confirm a healthy CRI plugin from 'ctr plugins ls'. Check the full plugin list and containerd logs."
    fi
  else
    warn "'ctr' is missing; cannot inspect containerd plugins."
  fi

  if have crictl; then
    emit "crictl runtime status:"
    as_root crictl info 2>&1 | head -n 45 | sed 's/^/  /' || true
  else
    note "'crictl' not installed; optional CRI diagnostics are unavailable."
  fi
else
  fail "containerd executable not found."
fi
show_file_if_present /etc/containerd/config.toml 120

section "6. GVISOR RUNTIME"
RUNSC_PATH=$(command -v runsc 2>/dev/null || true)
SHIM_PATH=$(command -v containerd-shim-runsc-v1 2>/dev/null || true)
if [[ -n "$RUNSC_PATH" ]]; then
  pass "runsc found at $RUNSC_PATH"
  runsc --version 2>&1 | head -n 5 | sed 's/^/  /' || true
  emit "runsc spec/runtime details:"
  runsc --help 2>&1 | head -n 2 | sed 's/^/  /' || true
else
  fail "runsc executable not found in PATH."
fi
if [[ -n "$SHIM_PATH" ]]; then
  pass "containerd gVisor shim found at $SHIM_PATH"
  ls -l "$SHIM_PATH" 2>/dev/null | sed 's/^/  /' || true
else
  warn "containerd-shim-runsc-v1 not found in PATH. Check the installed gVisor package and containerd runtime setup."
fi
if have runsc; then
  emit "gVisor host compatibility/version check:"
  runsc --version 2>&1 | sed 's/^/  /' || true
fi

section "7. DOCKER STATUS AND GVISOR SMOKE TEST"
if have docker; then
  emit "Docker client: $(docker --version 2>&1 | head -n 1)"
  if docker info >/dev/null 2>&1; then
    pass "Docker daemon is reachable as the current user."
    docker info --format '  Server version: {{.ServerVersion}}; runtimes: {{json .Runtimes}}; default runtime: {{.DefaultRuntime}}' 2>&1 || true
    if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q runsc; then
      pass "Docker reports a runsc runtime."
    else
      warn "Docker daemon is reachable, but its runtime list does not clearly include runsc."
    fi
    if [[ "${SKIP_DOCKER_SMOKE:-0}" != "1" ]]; then
      emit "Attempting Docker -> gVisor smoke test (may need to pull ubuntu:24.04):"
      SMOKE_OUT=$(docker run --rm --runtime=runsc ubuntu:24.04 uname -r 2>&1)
      SMOKE_RC=$?
      if [[ $SMOKE_RC -eq 0 ]]; then
        emit "  Output: $SMOKE_OUT"
        if [[ "$SMOKE_OUT" == *gvisor* || "$SMOKE_OUT" == *gVisor* ]]; then
          pass "Docker successfully launched a container using gVisor."
        else
          warn "Container started, but kernel string did not clearly identify gVisor; inspect output and runtime configuration."
        fi
      else
        warn "Docker -> gVisor smoke test failed (exit $SMOKE_RC)."
        detail "$SMOKE_OUT"
        detail "This test requires Docker daemon access and may need network access to pull the image."
      fi
    else
      note "Docker smoke test skipped by SKIP_DOCKER_SMOKE=1."
    fi
  else
    warn "Docker executable exists, but the daemon could not be queried as the current user."
    detail "Try: sudo docker info"
    detail "This may be a socket permission issue, stopped daemon, or unavailable Docker service."
    if [[ "${SKIP_DOCKER_SMOKE:-0}" != "1" ]]; then
      if have sudo && sudo -n docker info >/dev/null 2>&1; then
        pass "Docker daemon is reachable with non-interactive sudo."
        sudo docker info --format '  Server version: {{.ServerVersion}}; runtimes: {{json .Runtimes}}; default runtime: {{.DefaultRuntime}}' 2>&1 || true
        emit "Attempting privileged Docker -> gVisor smoke test:"
        SMOKE_OUT=$(sudo docker run --rm --runtime=runsc ubuntu:24.04 uname -r 2>&1)
        SMOKE_RC=$?
        if [[ $SMOKE_RC -eq 0 ]]; then
          emit "  Output: $SMOKE_OUT"
          pass "Docker successfully launched a container using gVisor (via sudo)."
        else
          warn "Privileged Docker -> gVisor smoke test failed (exit $SMOKE_RC)."
          detail "$SMOKE_OUT"
        fi
      else
        note "Not retrying Docker with sudo because passwordless sudo is unavailable; run 'sudo docker info' manually if desired."
      fi
    fi
  fi
  show_file_if_present /etc/docker/daemon.json 100
else
  note "Docker is not installed. Docker checks are optional when Kubernetes uses containerd directly."
fi

section "8. KERNEL MODULES AND SYSCTL NETWORK PREREQUISITES"
for mod in overlay br_netfilter; do
  if [[ -d "/sys/module/$mod" ]]; then
    pass "Kernel module '$mod' is loaded."
  elif have lsmod && lsmod | awk '{print $1}' | grep -qx "$mod"; then
    pass "Kernel module '$mod' is loaded."
  else
    warn "Kernel module '$mod' does not appear loaded. Whether it is needed depends on the networking/CNI and kernel configuration."
  fi
done

for key in net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv6.conf.all.forwarding; do
  value=$(read_sysctl "$key")
  emit "$key = $value"
  case "$key" in
    net.ipv4.ip_forward)
      [[ "$value" == "1" ]] && pass "IPv4 forwarding is enabled." || warn "IPv4 forwarding is not enabled; most Kubernetes pod networking setups require it."
      ;;
    net.bridge.bridge-nf-call-iptables|net.bridge.bridge-nf-call-ip6tables)
      if [[ "$value" == "1" ]]; then pass "$key is enabled."
      elif [[ "$value" == "unavailable" ]]; then note "$key unavailable (often because br_netfilter is not loaded); requirements depend on CNI and iptables mode."
      else warn "$key is not enabled; verify whether your chosen CNI requires bridge netfilter."
      fi
      ;;
    net.ipv6.conf.all.forwarding)
      [[ "$value" == "1" ]] && pass "IPv6 forwarding is enabled." || note "IPv6 forwarding is not enabled; only relevant if using IPv6 pod networking."
      ;;
  esac
done

if [[ -r /proc/cmdline ]]; then
  CMDLINE=$(cat /proc/cmdline)
  if [[ "$CMDLINE" == *cgroup_enable=memory* || -f /sys/fs/cgroup/cgroup.controllers ]]; then
    pass "Kernel boot configuration/cgroup state suggests memory cgroups may be available."
  else
    warn "No cgroup_enable=memory token found and cgroup v2 controller status was not conclusive; verify memory cgroup support."
  fi
fi
if [[ -r /sys/fs/cgroup/cgroup.controllers ]]; then
  CONTROLLERS=$(cat /sys/fs/cgroup/cgroup.controllers)
  for c in cpu cpuset memory pids; do
    if grep -qw "$c" <<<"$CONTROLLERS"; then pass "cgroup v2 controller '$c' is available."; else warn "cgroup v2 controller '$c' not listed in root controllers."; fi
  done
fi

section "9. NETWORK INTERFACES, ROUTES, DNS AND FIREWALL"
if have ip; then
  emit "Addresses:"
  ip -brief address 2>&1 | sed 's/^/  /' || true
  emit "Links:"
  ip -brief link 2>&1 | sed 's/^/  /' || true
  emit "Routes (IPv4):"
  ip route show 2>&1 | head -n 30 | sed 's/^/  /' || true
  emit "Routes (IPv6):"
  ip -6 route show 2>&1 | head -n 20 | sed 's/^/  /' || true
else
  warn "'ip' command not found; interface and route diagnostics unavailable."
fi
if [[ -r /etc/resolv.conf ]]; then
  emit "/etc/resolv.conf:"
  sed -n '1,30p' /etc/resolv.conf | sed 's/^/  /'
fi
if have getent; then
  emit "DNS lookup test for registry.k8s.io:"
  getent ahosts registry.k8s.io 2>&1 | head -n 8 | sed 's/^/  /' || true
else
  note "'getent' unavailable; DNS lookup test skipped."
fi

if have nft; then
  emit "nftables version:"
  nft --version 2>&1 | sed 's/^/  /'
  emit "nftables ruleset summary (first 80 lines; may require sudo):"
  as_root nft list ruleset 2>&1 | head -n 80 | sed 's/^/  /' || true
else
  note "nft command not found."
fi
if have iptables; then
  emit "iptables version/backend:"
  iptables --version 2>&1 | sed 's/^/  /'
  emit "iptables filter table (first 60 lines; may require sudo):"
  as_root iptables -S 2>&1 | head -n 60 | sed 's/^/  /' || true
else
  note "iptables command not found."
fi
if have ip6tables; then
  emit "ip6tables version/backend:"
  ip6tables --version 2>&1 | sed 's/^/  /'
else
  note "ip6tables command not found; only matters for IPv6-enabled configurations."
fi
if have bridge; then
  emit "Bridge interfaces:"
  bridge link show 2>&1 | head -n 40 | sed 's/^/  /' || true
else
  note "'bridge' utility not found (usually provided by iproute2)."
fi

section "10. CNI AND KUBERNETES CONFIGURATION FILES"
for d in /etc/cni/net.d /opt/cni/bin /etc/kubernetes /var/lib/kubelet /var/lib/containerd/io.containerd.grpc.v1.cri; do
  if [[ -d "$d" ]]; then
    emit "Directory exists: $d"
    if [[ "$d" == "/etc/cni/net.d" ]]; then
      find "$d" -maxdepth 1 -type f -printf '  %f\n' 2>/dev/null | head -n 30 || true
      for f in "$d"/*; do
        [[ -f "$f" ]] || continue
        detail "CNI config: $f"
        sed -n '1,80p' "$f" 2>/dev/null | sed 's/^/    | /' || true
      done
    elif [[ "$d" == "/etc/kubernetes" ]]; then
      find "$d" -maxdepth 2 -type f -printf '  %p\n' 2>/dev/null | head -n 50 || true
    fi
  else
    note "Directory not present: $d"
  fi
done
if [[ -d /opt/cni/bin ]]; then
  emit "CNI binaries:"
  find /opt/cni/bin -maxdepth 1 -type f -printf '  %f\n' 2>/dev/null | sort | head -n 60 || true
fi

section "11. KUBERNETES TOOLS AND CLUSTER STATE"
for cmd in kubeadm kubelet kubectl crictl; do
  if have "$cmd"; then
    emit "$cmd version:"
    case "$cmd" in
      kubectl) kubectl version --client 2>&1 | head -n 8 | sed 's/^/  /' || true ;;
      kubeadm) kubeadm version -o short 2>&1 | sed 's/^/  /' || true ;;
      kubelet) kubelet --version 2>&1 | sed 's/^/  /' || true ;;
      crictl) crictl --version 2>&1 | sed 's/^/  /' || true ;;
    esac
  else
    note "$cmd not installed."
  fi
done
if have kubectl; then
  emit "kubectl cluster reachability:"
  KUBE_OUT=$(kubectl cluster-info 2>&1)
  KUBE_RC=$?
  if [[ $KUBE_RC -eq 0 ]]; then
    pass "kubectl can reach a Kubernetes API server."
    printf '%s\n' "$KUBE_OUT" | head -n 12 | sed 's/^/  /'
    emit "Node summary:"
    kubectl get nodes -o wide 2>&1 | head -n 15 | sed 's/^/  /' || true
    emit "RuntimeClasses:"
    kubectl get runtimeclass 2>&1 | head -n 25 | sed 's/^/  /' || true
  else
    note "kubectl could not reach a cluster using the current kubeconfig."
    detail "$KUBE_OUT"
  fi
fi
if have crictl; then
  emit "CRI endpoint configuration:"
  crictl config 2>&1 | head -n 30 | sed 's/^/  /' || true
  emit "CRI containers (if runtime is reachable):"
  as_root crictl ps -a 2>&1 | head -n 20 | sed 's/^/  /' || true
fi

section "12. COMMON KUBERNETES PORTS"
if have ss; then
  emit "Listening TCP sockets (common Kubernetes ports):"
  ss -lnt 2>&1 | awk 'NR==1 || /:6443[[:space:]]|:2379[[:space:]]|:2380[[:space:]]|:10250[[:space:]]|:10257[[:space:]]|:10259[[:space:]]|:30000[[:space:]]|:32767[[:space:]]/' | sed 's/^/  /' || true
  emit "Listening UDP sockets (common CNI/DNS ports):"
  ss -lnu 2>&1 | awk 'NR==1 || /:53[[:space:]]|:4789[[:space:]]|:8472[[:space:]]|:51820[[:space:]]/' | sed 's/^/  /' || true
else
  note "'ss' unavailable; port checks skipped."
fi
note "Port requirements vary by cluster role, CNI, and enabled features; a listening port is context, not automatically a conflict."

section "13. TIME, PACKAGE STATE AND LOGGING"
emit "Time:"
date 2>&1 | sed 's/^/  /'
if have timedatectl; then timedatectl status 2>&1 | head -n 15 | sed 's/^/  /' || true; fi
if have apt; then
  emit "APT package-state summary:"
  dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' 2>/dev/null \
    | grep -E '^(containerd|containerd.io|docker|docker-ce|runc|runsc|gvisor|kubelet|kubeadm|kubectl|kubernetes-cni|cri-tools)' \
    | head -n 40 | sed 's/^/  /' || true
fi
if have journalctl; then
  emit "Recent kernel messages mentioning memory, filesystem, networking, or cgroups (last 30 matches):"
  as_root journalctl -k -b --no-pager 2>/dev/null \
    | grep -Ei 'oom|out of memory|I/O error|ext4.*error|mmc.*error|cgroup|overlay|br_netfilter|nf_tables|iptables|throttl|under.?voltage' \
    | tail -n 30 | sed 's/^/  /' || true
fi

section "14. SUMMARY AND NEXT STEPS"
emit "Counts: PASS=${PASS} WARN=${WARN} FAIL=${FAIL} INFO=${INFO}"
if (( FAIL > 0 )); then
  emit "RESULT: BLOCKERS FOUND — investigate FAIL items first."
elif (( WARN > 0 )); then
  emit "RESULT: CONDITIONALLY READY — review WARN items against your chosen Kubernetes distribution and CNI."
else
  emit "RESULT: NO OBVIOUS BLOCKERS FOUND — this is not a guarantee that cluster installation or gVisor CRI workloads will succeed."
fi
emit ""
emit "Important interpretation notes:"
emit "  - Docker's runsc runtime and containerd's CRI runtime configuration are separate."
emit "  - A Docker gVisor smoke test does not prove Kubernetes can launch RuntimeClass workloads."
emit "  - CRI plugin status, effective containerd config, CNI config, kubelet settings, and RuntimeClass testing are the key in-cluster checks."
emit "  - Kernel module, bridge-filter, IPv6, and port warnings depend on your selected CNI and cluster configuration."
emit "  - Run again with sudo for more complete service, journal, firewall, and config diagnostics."
if [[ -n "$REPORT" ]]; then emit "Report saved to: $REPORT"; fi
emit "Finished."
