#!/usr/bin/env bash
# shellcheck shell=bash
# system.sh — environment checks (read-only) and pre-change inventory.

OS_ID=""; OS_VERSION_ID=""; OS_PRETTY=""; ARCH=""
SSH_PORTS_DETECTED=()
FW_KIND="none"      # none | ufw-inactive | ufw-active | foreign
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
  [[ -r /etc/os-release ]] || die "${EXIT_PRECOND}" "/etc/os-release is missing or unreadable"
  # shellcheck disable=SC1091
  OS_ID="$(. /etc/os-release && printf '%s' "${ID:-}")"
  # shellcheck disable=SC1091
  OS_VERSION_ID="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
  # shellcheck disable=SC1091
  OS_PRETTY="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-${ID:-unknown}}")"

  array_contains "${OS_ID}:${OS_VERSION_ID}" "${SUPPORTED_OS[@]}" \
    || die "${EXIT_PRECOND}" "Unsupported OS: ${OS_PRETTY}. Supported: ${SUPPORTED_OS[*]}. Nothing was changed."

  local dpkg_arch
  dpkg_arch="$(dpkg --print-architecture 2> /dev/null || true)"
  ARCH="${dpkg_arch}"
  array_contains "${ARCH}" "${SUPPORTED_ARCH[@]}" \
    || die "${EXIT_PRECOND}" "Unsupported architecture: '${ARCH:-unknown}'. Supported: ${SUPPORTED_ARCH[*]}. Nothing was changed."
}

sys_check_tools() {
  local t missing=()
  for t in apt-get dpkg systemctl flock awk sed grep df getent install mktemp sha256sum stat timeout; do
    command -v "${t}" > /dev/null 2>&1 || missing+=("${t}")
  done
  if ((${#missing[@]})); then
    die "${EXIT_PRECOND}" "Required commands are missing: ${missing[*]}"
  fi
  [[ -d /run/systemd/system ]] || die "${EXIT_PRECOND}" "systemd is not running as PID 1 (containers without systemd are not supported)"
}

sys_check_disk() {
  local free
  free="$(df -Pm / | awk 'NR==2 {print $4}')"
  [[ "${free}" =~ ^[0-9]+$ ]] || die "${EXIT_PRECOND}" "Cannot determine free disk space"
  ((free >= MIN_FREE_MB)) || die "${EXIT_PRECOND}" "Not enough free disk space: ${free} MB (need ${MIN_FREE_MB} MB)"
}

sys_check_time() {
  local year ntp
  year="$(date +%Y)"
  ((year >= MIN_YEAR)) || die "${EXIT_PRECOND}" "System clock looks wrong (year ${year}); TLS downloads would fail"
  ntp="$(timedatectl show -p NTPSynchronized --value 2> /dev/null || true)"
  [[ "${ntp}" == "no" ]] && log_warn "System clock is not NTP-synchronized"
  return 0
}

_tcp_probe() { timeout 8 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$1" "$2" 2> /dev/null; }

sys_check_network() {
  if [[ "${MVN_SKIP_NETWORK_CHECK:-0}" == "1" ]]; then
    log_warn "Network check skipped (MVN_SKIP_NETWORK_CHECK=1)"
    return 0
  fi
  local host
  for host in github.com raw.githubusercontent.com; do
    getent ahosts "${host}" > /dev/null 2>&1 || die "${EXIT_PRECOND}" "DNS resolution failed for ${host}"
    retry 3 3 _tcp_probe "${host}" 443 || die "${EXIT_PRECOND}" "Cannot connect to ${host}:443"
  done
}

# ---------- inventory ----------
_session_ssh_port() { # prints the server port of the current SSH session, if any
  local pid=$$ conn="${SSH_CONNECTION:-}" ppid guard=0 _a _b _c port
  while [[ -z "${conn}" && "${pid}" -gt 1 && "${guard}" -lt 30 ]]; do
    if [[ -r "/proc/${pid}/environ" ]]; then
      conn="$(tr '\0' '\n' < "/proc/${pid}/environ" 2> /dev/null | sed -n 's/^SSH_CONNECTION=//p' | head -n 1 || true)"
    fi
    ppid="$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/${pid}/status" 2> /dev/null || true)"
    [[ -n "${ppid}" && "${ppid}" != "${pid}" ]] || break
    pid="${ppid}"; guard=$((guard + 1))
  done
  [[ -n "${conn}" ]] || return 0
  read -r _a _b _c port <<< "${conn}"
  valid_port "${port:-}" && printf '%s\n' "${port}"
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
  if systemctl is-active --quiet ssh.socket 2> /dev/null; then
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
  if command -v ufw > /dev/null 2>&1; then
    if ufw status 2> /dev/null | has_match -i '^Status: active'; then
      FW_KIND="ufw-active"; FW_DETAIL="UFW is active"; return 0
    fi
    FW_KIND="ufw-inactive"; FW_DETAIL="UFW is installed but inactive"
  fi
  if systemctl is-active --quiet firewalld 2> /dev/null; then
    FW_KIND="foreign"; FW_DETAIL="firewalld is active"; return 0
  fi
  if command -v nft > /dev/null 2>&1 && nft list ruleset 2> /dev/null | has_match -E 'policy (drop|reject)|[[:space:]](drop|reject)([[:space:]]|$)'; then
    FW_KIND="foreign"; FW_DETAIL="nftables has restrictive rules"; return 0
  fi
  if _iptables_restrictive; then
    FW_KIND="foreign"; FW_DETAIL="iptables has custom rules or a non-ACCEPT policy"; return 0
  fi
  return 0
}

sys_detect_xui() {
  XUI_PRESENT=0
  if [[ -x "${XUI_FOLDER}/x-ui" ]] || systemctl cat x-ui.service > /dev/null 2>&1; then
    XUI_PRESENT=1
  fi
}

sys_detect_conflicts() {
  CONFLICTS=()
  local u
  for u in "${CONFLICT_UNITS[@]}"; do
    if systemctl cat "${u}" > /dev/null 2>&1; then CONFLICTS+=("${u}"); fi
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
      echo "--- listening ports ---"
      ss -ltnuH 2> /dev/null || true
    } > "${f}"
  )
  # shellcheck disable=SC2012
  ls -1t "${dir}"/snapshot-*.txt 2> /dev/null | tail -n +6 | while read -r old; do rm -f -- "${old}"; done
  log_file_only "Pre-change snapshot saved: ${f}"
}
