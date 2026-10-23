#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # globals are used by the scripts that source this file
# system.sh — environment checks (read-only) and pre-change inventory.

OS_ID=""; OS_VERSION_ID=""; OS_PRETTY=""; ARCH=""
SSH_PORTS_DETECTED=()
FW_KIND="none"      # none | ufw-inactive | ufw-active | firewalld-inactive | firewalld-active | foreign
FW_DETAIL=""
XUI_PRESENT=0
CONFLICTS=()
BBR_CC_CURRENT=""; BBR_QDISC_CURRENT=""; BBR_AVAILABLE=""
IS_RERUN=0

sys_require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "${EXIT_PRECOND}" "Root privileges are required. Re-run with: sudo bash $0"
  fi
}

sys_check_bash() {
  if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
    die "${EXIT_PRECOND}" "Bash 4.3+ is required (found ${BASH_VERSION})"
  fi
}

sys_detect_os() {
  [[ -r /etc/os-release ]] || die "${EXIT_PRECOND}" "/etc/os-release is missing or unreadable; cannot identify the distribution"
  # shellcheck disable=SC1091
  PLAT_ID="$(. /etc/os-release && printf '%s' "${ID:-}")"
  # shellcheck disable=SC1091
  PLAT_ID_LIKE="$(. /etc/os-release && printf '%s' "${ID_LIKE:-}")"
  # shellcheck disable=SC1091
  PLAT_VERSION="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
  # shellcheck disable=SC1091
  OS_PRETTY="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-${ID:-unknown}}")"
  OS_ID="${PLAT_ID}"; OS_VERSION_ID="${PLAT_VERSION}"

  plat_classify "${PLAT_ID}" "${PLAT_ID_LIKE}" "${PLAT_VERSION}"
  case "${PLAT_SUPPORT}" in
    supported) ;;
    derivative) log_warn "${PLAT_NOTE}" ;;
    *)
      if [[ "${MVN_ALLOW_UNSUPPORTED_OS:-0}" == "1" ]]; then
        log_warn "${PLAT_NOTE}. Continuing because MVN_ALLOW_UNSUPPORTED_OS=1 (at your own risk)."
      else
        die "${EXIT_PRECOND}" "Unsupported system: ${OS_PRETTY}. ${PLAT_NOTE}. Supported families: Debian/Ubuntu, RHEL-compatible (Alma, Rocky, RHEL, Oracle, CentOS Stream, Fedora, Amazon Linux 2023), Arch/Manjaro, openSUSE, Alpine. To try anyway: MVN_ALLOW_UNSUPPORTED_OS=1. Nothing was changed."
      fi
      ;;
  esac

  plat_detect_pm || die "${EXIT_PRECOND}" "No supported package manager found (apt, dnf, yum, pacman, zypper or apk). Nothing was changed."
  plat_detect_init

  ARCH="$(plat_map_arch "$(uname -m 2> /dev/null || true)")"
  [[ -n "${ARCH}" ]] || die "${EXIT_PRECOND}" "Unsupported CPU architecture: '$(uname -m 2> /dev/null || echo unknown)'. 3x-ui publishes builds for amd64, arm64, armv7, armv6, armv5, 386 and s390x. Nothing was changed."
  case "${ARCH}" in
    amd64 | arm64) ;;
    *) log_warn "Architecture ${ARCH} is supported by the 3x-ui installer but is not tested by MVN Deploy" ;;
  esac
}

sys_check_tools() {
  local t missing=()
  for t in awk sed grep df getent install mktemp sha256sum stat timeout sort; do
    command -v "${t}" > /dev/null 2>&1 || missing+=("${t}")
  done
  if ((${#missing[@]})); then
    local -a pk=()
    local m p
    for m in "${missing[@]}"; do
      p="$(pkg_for_tool "${m}")"
      array_contains "${p}" "${pk[@]}" || pk+=("${p}")
    done
    if [[ "${MVN_DRY_RUN:-0}" == "1" ]]; then
      die "${EXIT_PRECOND}" "Basic commands are missing: ${missing[*]}. A real run installs them (${pk[*]}); a dry run changes nothing, so install them first and repeat."
    fi
    log_warn "Basic commands are missing (${missing[*]}): minimal image. Installing ${pk[*]}"
    _pkg_refresh_cmd > /dev/null 2>&1 || true
    pkg_install_safe "${pk[@]}" || die "${EXIT_PRECOND}" "Could not install ${pk[*]}. Install them manually and run again."
    missing=()
    for t in awk sed grep df getent install mktemp sha256sum stat timeout sort; do
      command -v "${t}" > /dev/null 2>&1 || missing+=("${t}")
    done
    ((${#missing[@]} == 0)) || die "${EXIT_PRECOND}" "Required commands are still missing after installation: ${missing[*]}"
  fi
  case "${PLAT_INIT}" in
    systemd | openrc) ;;
    *)
      # Test hook for CI containers: a dry run may proceed without an init system.
      if [[ "${MVN_ALLOW_NO_INIT:-0}" == "1" && "${MVN_DRY_RUN:-0}" == "1" ]]; then
        log_warn "No init system found; continuing only because this is a dry run with MVN_ALLOW_NO_INIT=1"
      else
        die "${EXIT_PRECOND}" "No supported init system found (need systemd as PID 1, or OpenRC). Containers without an init system are not supported."
      fi
      ;;
  esac
}

sys_check_disk() {
  local free
  free="$(df -Pm / | awk 'NR==2 {print $4}')"
  [[ "${free}" =~ ^[0-9]+$ ]] || die "${EXIT_PRECOND}" "Cannot determine free disk space"
  ((free >= MIN_FREE_MB)) || die "${EXIT_PRECOND}" "Not enough free disk space: ${free} MB (need ${MIN_FREE_MB} MB). Free some space (df -h, apt/dnf clean) and run again."
  local ifree
  ifree="$(df -Pi / 2> /dev/null | awk 'NR==2 {print $4}')"
  if [[ "${ifree}" =~ ^[0-9]+$ ]] && ((ifree < 5000)); then
    die "${EXIT_PRECOND}" "The filesystem is almost out of inodes (${ifree} left); installation would fail"
  fi
  local d
  for d in /tmp /var/lib; do
    [[ -w "${d}" ]] || die "${EXIT_PRECOND}" "${d} is not writable (read-only filesystem?)"
  done
}

sys_check_time() {
  local year ntp
  year="$(date +%Y)"
  ((year >= MIN_YEAR)) || die "${EXIT_PRECOND}" "System clock looks wrong (year ${year}); TLS downloads would fail. Set the date (timedatectl set-ntp true) and run again."
  if [[ "${PLAT_INIT}" == "systemd" ]] && command -v timedatectl > /dev/null 2>&1; then
    ntp="$(timedatectl show -p NTPSynchronized --value 2> /dev/null || true)"
    if [[ "${ntp}" == "no" ]]; then log_warn "System clock is not NTP-synchronized (certificates and Let's Encrypt need a correct time)"; fi
  fi
  return 0
}

_tcp_probe() { timeout 8 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$1" "$2" 2> /dev/null; }
_resolve_ok() { getent ahosts "$1" > /dev/null 2>&1 || getent hosts "$1" > /dev/null 2>&1; }

sys_check_network() {
  if [[ "${MVN_SKIP_NETWORK_CHECK:-0}" == "1" ]]; then
    log_warn "Network check skipped (MVN_SKIP_NETWORK_CHECK=1)"
    return 0
  fi
  local host rc
  for host in github.com raw.githubusercontent.com; do
    _resolve_ok "${host}" \
      || die "${EXIT_PRECOND}" "DNS resolution failed for ${host}. Check /etc/resolv.conf (test: getent hosts ${host}) and that the server has internet access."
    retry 3 3 _tcp_probe "${host}" 443 \
      || die "${EXIT_PRECOND}" "Cannot connect to ${host}:443. Typical causes: outbound filtering by the provider/firewall, an IPv6-only network (GitHub has no IPv6: use NAT64/DNS64 or an IPv4 address), or a required proxy (export HTTPS_PROXY and run sudo -E)."
  done
  if command -v curl > /dev/null 2>&1; then
    rc=0
    curl -fsS --max-time 20 -o /dev/null https://raw.githubusercontent.com > /dev/null 2>&1 || rc=$?
    case "${rc}" in
      0 | 22) ;;   # 22 = HTTP error status, TLS itself worked
      60 | 35 | 51 | 58 | 77) die "${EXIT_PRECOND}" "TLS to GitHub failed (curl exit ${rc}). Check the system clock (date) and install/update ca-certificates." ;;
      *) log_warn "HTTPS test to GitHub returned curl exit ${rc}; downloads may fail" ;;
    esac
  fi
}

# sys_check_resources: warnings only; small or containerised servers still work.
VIRT_KIND=""
sys_check_resources() {
  local mem swap
  mem="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2> /dev/null || true)"
  swap="$(awk '/^SwapTotal:/ {print int($2/1024)}' /proc/meminfo 2> /dev/null || true)"
  if [[ "${mem}" =~ ^[0-9]+$ ]] && ((mem < 256)); then
    log_warn "Only ${mem} MB of RAM: the installation may be killed by the OOM killer. Add swap (fallocate -l 512M /swapfile; mkswap; swapon) if it fails."
  elif [[ "${mem}" =~ ^[0-9]+$ ]] && ((mem < 512)) && [[ "${swap}" == "0" ]]; then
    log_warn "${mem} MB of RAM and no swap: busy panels may run out of memory; consider adding swap"
  fi
  if command -v systemd-detect-virt > /dev/null 2>&1; then
    VIRT_KIND="$(systemd-detect-virt --container 2> /dev/null || true)"
    [[ "${VIRT_KIND}" == "none" ]] && VIRT_KIND=""
  fi
  if [[ -z "${VIRT_KIND}" && -d /proc/vz && ! -d /proc/bc ]]; then VIRT_KIND="openvz"; fi
  if [[ -n "${VIRT_KIND}" ]]; then
    log_warn "Running inside a container (${VIRT_KIND}): BBR and the firewall may be restricted by the host; failures there are reported as warnings"
  fi
  return 0
}

# ---------- inventory ----------
_session_ssh_conn() { # prints "client_ip client_port server_ip server_port" of the current SSH session, if any
  local pid=$$ conn="${SSH_CONNECTION:-}" ppid guard=0
  while [[ -z "${conn}" && "${pid}" -gt 1 && "${guard}" -lt 30 ]]; do
    if [[ -r "/proc/${pid}/environ" ]]; then
      conn="$(tr '\0' '\n' < "/proc/${pid}/environ" 2> /dev/null | sed -n 's/^SSH_CONNECTION=//p' | head -n 1 || true)"
    fi
    ppid="$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/${pid}/status" 2> /dev/null || true)"
    [[ -n "${ppid}" && "${ppid}" != "${pid}" ]] || break
    pid="${ppid}"; guard=$((guard + 1))
  done
  if [[ -n "${conn}" ]]; then printf '%s\n' "${conn}"; fi
  return 0
}

_session_ssh_port() { # prints the server port of the current SSH session, if any
  local conn _a _b _c port
  conn="$(_session_ssh_conn)"
  [[ -n "${conn}" ]] || return 0
  read -r _a _b _c port <<< "${conn}"
  valid_port "${port:-}" && printf '%s\n' "${port}"
  return 0
}

_session_ssh_client_ip() { # prints the client address of the current SSH session, if any
  local conn ip _b
  conn="$(_session_ssh_conn)"
  [[ -n "${conn}" ]] || return 0
  read -r ip _b <<< "${conn}"
  [[ "${ip}" =~ ^[0-9A-Fa-f:.]+$ ]] && printf '%s\n' "${ip}"
  return 0
}

sys_detect_ssh_ports() {
  local -a found=()
  local p sshd_bin

  while read -r p; do
    [[ -n "${p}" ]] && found+=("${p}")
  done < <(_session_ssh_port)

  sshd_bin="$(command -v sshd 2> /dev/null || true)"
  if [[ -z "${sshd_bin}" && -x /usr/sbin/sshd ]]; then sshd_bin="/usr/sbin/sshd"; fi
  if [[ -n "${sshd_bin}" ]]; then
    while read -r p; do
      valid_port "${p}" && found+=("${p}")
    done < <("${sshd_bin}" -T 2> /dev/null | awk '$1=="port" {print $2}' || true)
  fi

  # systemd socket activation (Ubuntu 24.04 ssh.socket) can listen on other ports than sshd_config.
  if [[ "${PLAT_INIT}" == "systemd" ]] && svc_active ssh.socket; then
    while read -r p; do
      valid_port "${p}" && found+=("${p}")
    done < <(systemctl show ssh.socket -p Listen 2> /dev/null | grep -Eo ':[0-9]+ \(Stream\)' | grep -Eo '[0-9]+' || true)
  fi

  if command -v ss > /dev/null 2>&1; then
    while read -r p; do
      valid_port "${p}" && found+=("${p}")
    done < <(ss -ltnpH 2> /dev/null | awk '/users:\(\("sshd"/ {n=split($4,a,":"); print a[n]}' || true)
  fi

  SSH_PORTS_DETECTED=()
  if ((${#found[@]})); then
    mapfile -t SSH_PORTS_DETECTED < <(printf '%s\n' "${found[@]}" | sort -un)
  fi
}

_iptables_restrictive() {
  command -v iptables > /dev/null 2>&1 || return 1
  iptables -S 2> /dev/null | grep -Ev '^-P (INPUT|FORWARD|OUTPUT) ACCEPT$|^-N ' | has_match .
}

sys_detect_firewall() {
  FW_KIND="none"; FW_DETAIL=""
  local inactive="" inactive_detail=""
  if command -v ufw > /dev/null 2>&1; then
    if ufw status 2> /dev/null | has_match -i '^Status: active'; then
      FW_KIND="ufw-active"; FW_DETAIL="UFW is active"; return 0
    fi
    inactive="ufw-inactive"; inactive_detail="UFW is installed but inactive"
  fi
  if command -v firewall-cmd > /dev/null 2>&1; then
    if svc_active firewalld && firewall-cmd --state 2> /dev/null | has_match -i 'running'; then
      FW_KIND="firewalld-active"; FW_DETAIL="firewalld is active"; return 0
    fi
    # Both installed but idle: prefer the tool that is native to the distribution family.
    if [[ -z "${inactive}" || "${PLAT_FAMILY}" == "rhel" || "${PLAT_FAMILY}" == "suse" ]]; then
      inactive="firewalld-inactive"; inactive_detail="firewalld is installed but inactive"
    fi
  elif svc_active firewalld; then
    FW_KIND="foreign"; FW_DETAIL="firewalld service is running but firewall-cmd is missing"; return 0
  fi
  if command -v nft > /dev/null 2>&1 && nft list ruleset 2> /dev/null | has_match -E 'policy (drop|reject)|[[:space:]](drop|reject)([[:space:]]|$)'; then
    FW_KIND="foreign"; FW_DETAIL="nftables has restrictive rules"; return 0
  fi
  if _iptables_restrictive; then
    FW_KIND="foreign"; FW_DETAIL="iptables has custom rules or a non-ACCEPT policy"; return 0
  fi
  if [[ -n "${inactive}" ]]; then FW_KIND="${inactive}"; FW_DETAIL="${inactive_detail}"; fi
  return 0
}

sys_detect_xui() {
  XUI_PRESENT=0
  if [[ -x "${XUI_FOLDER}/x-ui" ]] || svc_exists x-ui; then
    XUI_PRESENT=1
  fi
}

sys_detect_conflicts() {
  CONFLICTS=()
  local u
  for u in "${CONFLICT_UNITS[@]}"; do
    if svc_exists "${u}"; then CONFLICTS+=("${u}"); fi
  done
  if [[ -x /usr/local/bin/xray ]]; then CONFLICTS+=("/usr/local/bin/xray (standalone Xray)"); fi
  return 0
}

sys_detect_bbr() {
  BBR_CC_CURRENT="$(cat /proc/sys/net/ipv4/tcp_congestion_control 2> /dev/null || true)"
  BBR_QDISC_CURRENT="$(cat /proc/sys/net/core/default_qdisc 2> /dev/null || true)"
  BBR_AVAILABLE="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2> /dev/null || true)"
}

sys_detect_rerun() {
  IS_RERUN=0
  if [[ -n "$(state_get last_run)" ]]; then IS_RERUN=1; fi
}

# sys_snapshot: root-only pre-change record (no secrets). Keeps the 5 latest.
sys_snapshot() {
  state_init
  local dir="${MVN_STATE_DIR}/snapshots" f
  ( umask 077; mkdir -p -- "${dir}" )
  f="${dir}/snapshot-$(date +%Y%m%d-%H%M%S).txt"
  (
    umask 077
    {
      echo "os=${OS_PRETTY} arch=${ARCH}"
      echo "ssh_ports=${SSH_PORTS_DETECTED[*]:-}"
      echo "firewall=${FW_KIND} (${FW_DETAIL})"
      echo "x-ui_present=${XUI_PRESENT}"
      echo "bbr=${BBR_CC_CURRENT}/${BBR_QDISC_CURRENT} available=${BBR_AVAILABLE}"
      echo "--- ufw status ---"
      ufw status verbose 2> /dev/null || true
      echo "--- firewalld ---"
      firewall-cmd --list-all 2> /dev/null || true
      echo "--- listening ports ---"
      ss -ltnuH 2> /dev/null || true
    } > "${f}"
  )
  # shellcheck disable=SC2012
  ls -1t "${dir}"/snapshot-*.txt 2> /dev/null | tail -n +6 | while read -r old; do rm -f -- "${old}"; done
  log_file_only "Pre-change snapshot saved: ${f}"
}
