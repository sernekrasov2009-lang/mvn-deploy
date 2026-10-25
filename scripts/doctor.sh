#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # globals are used by the scripts that source this file
# doctor.sh — read-only diagnostics (mvn-deploy doctor) and a short overview (mvn-deploy status).
# Exit code of doctor: 0 = no FAIL (warnings are allowed), 1 = at least one FAIL.

DOC_OKS=0
DOC_WARNS=0
DOC_FAILS=0

_d_ok() {
  DOC_OKS=$((DOC_OKS + 1))
  printf '  %s[ OK ]%s %s\n' "${C_GREEN}" "${C_RESET}" "$1"
}
_d_warn() {
  DOC_WARNS=$((DOC_WARNS + 1))
  printf '  %s[WARN]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$1"
}
_d_fail() {
  DOC_FAILS=$((DOC_FAILS + 1))
  printf '  %s[FAIL]%s %s\n' "${C_RED}" "${C_RESET}" "$1"
}
_d_info() { printf '         %s\n' "$1"; }
_d_section() { printf '\n%s%s%s\n' "${C_BOLD:-}" "$1" "${C_RESET}"; }

_doctor_system() {
  _d_section "System"
  local free mem swap load itotal ifree year ntp
  _d_info "${OS_PRETTY} | ${ARCH:-?} | init: ${PLAT_INIT} | packages: ${PLAT_PM:-none}"
  case "${PLAT_SUPPORT:-}" in
    supported) _d_ok "Distribution is supported" ;;
    derivative) _d_warn "Distribution is a derivative (best effort): ${PLAT_NOTE}" ;;
    *) _d_warn "Distribution is not on the supported list: ${PLAT_NOTE:-unknown}" ;;
  esac
  [[ "${PLAT_INIT}" == "none" ]] && _d_fail "No supported init system (systemd/OpenRC)"

  free="$(df -Pm / 2> /dev/null | awk 'NR==2 {print $4}')"
  if [[ "${free}" =~ ^[0-9]+$ ]]; then
    if ((free < 100)); then
      _d_fail "Only ${free} MB free on /"
    elif ((free < 500)); then
      _d_warn "Low disk space: ${free} MB free on /"
    else _d_ok "Disk space: ${free} MB free on /"; fi
  fi
  read -r itotal ifree < <(df -Pi / 2> /dev/null | awk 'NR==2 {print $2, $4}') || true
  if inodes_low "${itotal:-}" "${ifree:-}"; then _d_fail "Almost out of inodes (${ifree} left)"; fi

  mem="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2> /dev/null || true)"
  swap="$(awk '/^SwapTotal:/ {print int($2/1024)}' /proc/meminfo 2> /dev/null || true)"
  if [[ "${mem}" =~ ^[0-9]+$ ]]; then
    if ((mem < 256)); then
      _d_warn "Only ${mem} MB RAM (swap ${swap:-0} MB): the panel may be killed when memory runs out"
    else _d_ok "Memory: ${mem} MB RAM, ${swap:-0} MB swap"; fi
  fi
  load="$(cut -d' ' -f1-3 /proc/loadavg 2> /dev/null || true)"
  [[ -n "${load}" ]] && _d_info "Load average: ${load}"

  year="$(date +%Y)"
  if ((year >= MIN_YEAR)); then _d_ok "System clock looks right ($(date '+%Y-%m-%d %H:%M %Z'))"; else _d_fail "System clock is wrong (year ${year}): TLS and certificates will fail"; fi
  if [[ "${PLAT_INIT}" == "systemd" ]] && command -v timedatectl > /dev/null 2>&1; then
    ntp="$(timedatectl show -p NTPSynchronized --value 2> /dev/null || true)"
    [[ "${ntp}" == "no" ]] && _d_warn "Clock is not NTP-synchronized (timedatectl set-ntp true)"
  fi
  [[ -f /var/run/reboot-required ]] && _d_warn "A reboot is required (kernel/library updates are pending)"
  return 0
}

_doctor_network() {
  _d_section "Network"
  local ip
  if _resolve_ok github.com; then _d_ok "DNS works (github.com resolves)"; else _d_fail "DNS cannot resolve github.com: check /etc/resolv.conf"; fi
  if _tcp_probe github.com 443; then _d_ok "github.com:443 is reachable"; else _d_warn "github.com:443 is not reachable (updates and Let's Encrypt need internet access)"; fi
  if command -v curl > /dev/null 2>&1; then
    ip="$(_public_ipv4)"
    if [[ -n "${ip}" ]]; then
      _d_info "Public IPv4: ${ip}"
      _is_private_ipv4 "${ip}" && _d_warn "The public address ${ip} is private/NAT: Let's Encrypt for the IP cannot work"
    else
      _d_warn "Could not detect the public IPv4 address"
    fi
  fi
  return 0
}

_doctor_panel() {
  _d_section "3x-ui panel"
  local port path cert end epoch days mode owner
  if ! svc_exists x-ui && [[ ! -x "${XUI_FOLDER}/x-ui" ]]; then
    _d_fail "3x-ui is not installed (run: mvn-deploy install)"
    return 0
  fi
  if svc_active x-ui; then _d_ok "x-ui service is running"; else _d_fail "x-ui service is NOT running (systemctl status x-ui)"; fi
  if svc_enabled x-ui; then _d_ok "x-ui starts on boot"; else _d_warn "x-ui is not enabled for boot"; fi

  port="$(_xui_setting_show | sed -n 's/^[[:space:]]*port:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1)"
  path="$(_xui_setting_show | sed -n 's/^[[:space:]]*webBasePath:[[:space:]]*\(.*\)$/\1/p' | head -n 1 | tr -d '[:space:]')"
  path="${path#/}"
  if valid_port "${port}"; then
    XUI_PANEL_PORT_VAL="${port}"
    if [[ -n "$(ss -ltnH "sport = :${port}" 2> /dev/null)" ]]; then _d_ok "Panel port ${port} is listening"; else _d_fail "Nothing listens on the panel port ${port}"; fi
    XUI_PROBE_TRIES=3
    if xui_probe_scheme "${port}" "${path}"; then
      case "${XUI_SCHEME}" in
        https) _d_ok "Panel answers over HTTPS" ;;
        *) _d_warn "Panel answers over plain HTTP: log in only through an SSH tunnel, or enable HTTPS in the x-ui menu" ;;
      esac
    else
      _d_fail "Panel does not answer on 127.0.0.1:${port}"
    fi
  else
    _d_warn "Could not read the panel port (x-ui setting -show)"
  fi

  cert="$(_xui_cert_path)"
  if [[ -n "${cert}" ]]; then
    if [[ -r "${cert}" ]]; then
      end="$(openssl x509 -enddate -noout -in "${cert}" 2> /dev/null | sed 's/^notAfter=//' || true)"
      epoch="$(date -d "${end}" +%s 2> /dev/null || true)"
      if [[ "${epoch}" =~ ^[0-9]+$ ]]; then
        days=$(((epoch - $(date +%s)) / 86400))
        if ((days < 0)); then
          _d_fail "The panel certificate EXPIRED ${days#-} day(s) ago"
        elif ((days < 3)); then
          _d_warn "The panel certificate expires in ${days} day(s) (short-lived Let's Encrypt IP certificates renew automatically; check the cron/acme job if this persists)"
        elif ((days < 14)); then
          _d_warn "The panel certificate expires in ${days} days"
        else _d_ok "Panel certificate valid for ${days} more days"; fi
      fi
    else
      _d_warn "Certificate file ${cert} is not readable"
    fi
  else
    _d_info "No certificate configured in the panel"
  fi

  if [[ -f "${XUI_RESULT_FILE}" ]]; then
    mode="$(stat -c '%a' "${XUI_RESULT_FILE}")"
    owner="$(stat -c '%u' "${XUI_RESULT_FILE}")"
    if [[ "${mode}" == "600" && "${owner}" == "0" ]]; then _d_ok "Credentials file is root-only (600)"; else _d_warn "Credentials file ${XUI_RESULT_FILE} has mode ${mode} owner ${owner}: run chmod 600 and chown root"; fi
  fi
  return 0
}

_doctor_firewall() {
  _d_section "Firewall"
  local p
  sys_detect_ssh_ports
  sys_detect_firewall
  case "${FW_KIND}" in
    ufw-active) FW_BACKEND="ufw" ;;
    firewalld-active) FW_BACKEND="firewalld" ;;
    foreign)
      _d_info "${FW_DETAIL}: MVN Deploy does not manage it; check the ports yourself"
      return 0
      ;;
    *)
      _d_warn "No active local firewall (${FW_DETAIL:-none}): rely on your provider's firewall or enable one"
      return 0
      ;;
  esac
  _d_ok "${FW_BACKEND} is active"
  for p in "${SSH_PORTS_DETECTED[@]}"; do
    if fw_status_allows "${p}" tcp; then _d_ok "SSH ${p}/tcp is allowed"; else _d_fail "SSH ${p}/tcp is NOT allowed (you could lose access)"; fi
  done
  if [[ -n "${XUI_PANEL_PORT_VAL}" ]]; then
    if fw_status_allows "${XUI_PANEL_PORT_VAL}" tcp; then _d_ok "Panel ${XUI_PANEL_PORT_VAL}/tcp is allowed"; else _d_warn "Panel ${XUI_PANEL_PORT_VAL}/tcp is not allowed: the panel is unreachable from outside"; fi
  fi
  svc_enabled "${FW_BACKEND}" && _d_ok "${FW_BACKEND} starts on boot" || _d_warn "${FW_BACKEND} is not enabled for boot"
  return 0
}

_doctor_protection() {
  _d_section "Protection and tuning"
  local banned cc qd
  if command -v fail2ban-client > /dev/null 2>&1; then
    if svc_active fail2ban && fail2ban-client status sshd > /dev/null 2>&1; then
      banned="$(fail2ban-client status sshd 2> /dev/null | sed -n 's/.*Currently banned:[[:space:]]*\([0-9]*\).*/\1/p' | head -n 1)"
      _d_ok "Fail2ban sshd jail is running (${banned:-0} address(es) banned now)"
    else
      _d_warn "Fail2ban is installed but the sshd jail is not running (journalctl -u fail2ban)"
    fi
  else
    _d_warn "Fail2ban is not installed: SSH has no brute-force protection"
  fi
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2> /dev/null || true)"
  qd="$(sysctl -n net.core.default_qdisc 2> /dev/null || true)"
  if [[ "${cc}" == "bbr" ]]; then _d_ok "TCP BBR is active (qdisc ${qd:-?})"; else _d_warn "TCP congestion control is '${cc:-unknown}', not bbr"; fi
  sys_detect_conflicts
  if ((${#CONFLICTS[@]})); then _d_warn "Other VPN/proxy software found: ${CONFLICTS[*]}"; else _d_ok "No conflicting VPN/proxy services found"; fi
  return 0
}

doctor_run() {
  printf '%sMVN Deploy doctor%s (v%s)\n' "${C_BOLD:-}" "${C_RESET}" "${MVN_VERSION}"
  _doctor_system
  _doctor_network
  _doctor_panel
  _doctor_firewall
  _doctor_protection
  _d_section "Summary"
  printf '  %s ok, %s warning(s), %s failure(s)\n' "${DOC_OKS}" "${DOC_WARNS}" "${DOC_FAILS}"
  if ((DOC_FAILS > 0)); then
    echo "  Fix the [FAIL] items first. Details: docs/TROUBLESHOOTING.md and /var/log/mvn-deploy/install.log"
    return 1
  fi
  return 0
}

status_run() {
  local last
  XUI_PROBE_TRIES=2
  printf '%sMVN Deploy%s v%s on %s\n' "${C_BOLD:-}" "${C_RESET}" "${MVN_VERSION}" "${OS_PRETTY}"
  if svc_exists x-ui || [[ -x "${XUI_FOLDER}/x-ui" ]]; then
    printf '  3x-ui:        %s%s\n' "$(svc_active x-ui && echo running || echo STOPPED)" "$(svc_enabled x-ui && echo ', enabled on boot' || echo ', not enabled on boot')"
    xui_collect_info
    printf '  Panel:        %s\n' "${XUI_PANEL_URL:-unknown}"
    printf '  Credentials:  %s\n' "${XUI_CREDS_NOTE:-unknown}"
  else
    printf '  3x-ui:        not installed\n'
  fi
  sys_detect_firewall
  printf '  Firewall:     %s\n' "${FW_DETAIL:-none}"
  if command -v fail2ban-client > /dev/null 2>&1 && svc_active fail2ban; then printf '  Fail2ban:     running\n'; else printf '  Fail2ban:     not running\n'; fi
  printf '  TCP BBR:      %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2> /dev/null || echo unknown)"
  last="$(ls -1t "${MVN_BACKUP_DIR}"/mvn-backup-*.tar.gz 2> /dev/null | head -n 1 || true)"
  printf '  Last backup:  %s\n' "${last:-none (create one: mvn-deploy backup)}"
  printf '  Uptime:       %s\n' "$(uptime -p 2> /dev/null || echo unknown)"
  return 0
}
