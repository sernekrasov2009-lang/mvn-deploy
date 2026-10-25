#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # globals are used by the scripts that source this file
# fail2ban.sh — bans IPs that guess SSH passwords. One drop-in file, easy to remove.
# An existing user-written [sshd] jail is never overridden.

F2B_ACTION="skip" # skip | install | keep
F2B_JAIL_FILE="/etc/fail2ban/jail.d/mvn-deploy.local"
F2B_PORTS=()
F2B_BACKEND="auto"
F2B_IGNORE=""

_f2b_user_sshd_jail() { # does a hand-written config already define [sshd]?
  local f
  for f in /etc/fail2ban/jail.local /etc/fail2ban/jail.d/*.local; do
    [[ -f "${f}" && "${f}" != "${F2B_JAIL_FILE}" ]] || continue
    if grep -Eq '^[[:space:]]*\[sshd\]' "${f}" 2> /dev/null; then return 0; fi
  done
  return 1
}

f2b_plan() {
  F2B_ACTION="skip"
  case "${MVN_FAIL2BAN:-auto}" in
    skip)
      log_info "Fail2ban disabled (MVN_FAIL2BAN=skip)"
      return 0
      ;;
    auto) ;;
    *) die "${EXIT_PRECOND}" "MVN_FAIL2BAN must be auto or skip" ;;
  esac
  [[ "${MVN_F2B_MAXRETRY}" =~ ^[0-9]{1,3}$ ]] && ((10#${MVN_F2B_MAXRETRY} >= 1)) ||
    die "${EXIT_PRECOND}" "MVN_F2B_MAXRETRY must be a number >= 1"
  [[ "${MVN_F2B_FINDTIME}" =~ ^[0-9]+[smhdw]?$ ]] || die "${EXIT_PRECOND}" "MVN_F2B_FINDTIME must look like 10m"
  [[ "${MVN_F2B_BANTIME}" =~ ^[0-9]+[smhdw]?$ ]] || die "${EXIT_PRECOND}" "MVN_F2B_BANTIME must look like 1h"
  local t
  for t in ${MVN_F2B_IGNORE_IPS//,/ }; do
    [[ "${t}" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]] || die "${EXIT_PRECOND}" "MVN_F2B_IGNORE_IPS has an invalid entry: ${t}"
  done

  local -a override=()
  parse_port_list override "${MVN_SSH_PORTS}" || die "${EXIT_PRECOND}" "Invalid MVN_SSH_PORTS"
  F2B_PORTS=("${SSH_PORTS_DETECTED[@]}")
  local p
  for p in "${override[@]}"; do
    array_contains "${p}" "${F2B_PORTS[@]}" || F2B_PORTS+=("${p}")
  done
  if ((${#F2B_PORTS[@]} == 0)); then F2B_PORTS=("22"); fi

  if _f2b_user_sshd_jail; then F2B_ACTION="keep"; else F2B_ACTION="install"; fi
}

f2b_plan_text() {
  case "${F2B_ACTION}" in
    install) printf 'install fail2ban; sshd jail on port(s) %s (%s failures in %s -> ban %s; your current SSH address is never banned)' \
      "$(
        IFS=,
        echo "${F2B_PORTS[*]}"
      )" "${MVN_F2B_MAXRETRY}" "${MVN_F2B_FINDTIME}" "${MVN_F2B_BANTIME}" ;;
    keep) printf 'fail2ban already has your own [sshd] jail: leave it unchanged' ;;
    *) printf 'skipped' ;;
  esac
}

f2b_render() { # backend ignore-list [logpath] -> jail file content on stdout
  local backend="$1" ignore="$2" logpath="${3:-}"
  printf '# Managed by MVN Deploy. Safe to delete; uninstall.sh removes it.\n'
  printf '[sshd]\nenabled = true\nport = %s\nbackend = %s\n' "$(
    IFS=,
    echo "${F2B_PORTS[*]}"
  )" "${backend}"
  if [[ -n "${logpath}" ]]; then printf 'logpath = %s\n' "${logpath}"; fi
  printf 'maxretry = %s\nfindtime = %s\nbantime = %s\nignoreip = %s\n' \
    "${MVN_F2B_MAXRETRY}" "${MVN_F2B_FINDTIME}" "${MVN_F2B_BANTIME}" "${ignore}"
}

_f2b_ignore_list() {
  local ip extra="${MVN_F2B_IGNORE_IPS//,/ }"
  ip="$(_session_ssh_client_ip || true)"
  printf '127.0.0.1/8 ::1%s%s' "${ip:+ ${ip}}" "${extra:+ ${extra}}"
}

_f2b_wait_ready() {
  local i
  for ((i = 0; i < 20; i++)); do
    if fail2ban-client status sshd > /dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

_f2b_write_and_start() { # backend [logpath]
  local tmp="${F2B_JAIL_FILE}.tmp.$$"
  install -d -m 755 "$(dirname "${F2B_JAIL_FILE}")"
  f2b_render "$1" "${F2B_IGNORE}" "${2:-}" > "${tmp}"
  chmod 644 "${tmp}"
  mv -f -- "${tmp}" "${F2B_JAIL_FILE}"
  if ! run_logged fail2ban-client -t; then return 1; fi
  run_logged svc_enable fail2ban || true
  run_logged svc_restart fail2ban || return 1
  _f2b_wait_ready
}

# _f2b_candidates: "backend|logpath" pairs to try, best guess first. Distributions differ:
# Debian/Ubuntu log to auth.log, RHEL family to /var/log/secure, minimal images only to the journal.
_f2b_candidates() {
  local -a c=()
  if [[ -f /var/log/auth.log ]]; then c+=("auto|/var/log/auth.log"); fi
  if [[ -f /var/log/secure ]]; then c+=("auto|/var/log/secure"); fi
  if [[ "${PLAT_INIT}" == "systemd" ]] && command -v journalctl > /dev/null 2>&1; then c+=("systemd|"); fi
  if [[ -f /var/log/messages ]]; then c+=("auto|/var/log/messages"); fi
  ((${#c[@]})) || c+=("systemd|" "auto|")
  printf '%s\n' "${c[@]}"
}

# _f2b_install: package(s) for this distribution; never fatal.
_f2b_install() {
  command -v fail2ban-client > /dev/null 2>&1 && return 0
  if [[ "${PLAT_FAMILY}" == "rhel" ]]; then pkg_enable_epel || log_warn "EPEL could not be enabled; fail2ban may be unavailable"; fi
  deps_install_optional fail2ban-client fail2ban || return 1
  local n
  for n in $(pkg_names pysystemd); do
    pkg_installed "${n}" || pkg_install_safe "${n}" || log_file_only "optional package ${n} not installed"
  done
  if [[ "${FW_BACKEND}" == "firewalld" && "${PLAT_FAMILY}" == "rhel" ]]; then
    pkg_installed fail2ban-firewalld || pkg_install_safe fail2ban-firewalld || log_file_only "fail2ban-firewalld not installed"
  fi
  command -v fail2ban-client > /dev/null 2>&1
}

f2b_apply() {
  case "${F2B_ACTION}" in
    skip)
      report_add "Fail2ban" "SKIPPED" "not requested"
      return 0
      ;;
  esac
  if [[ "${F2B_ACTION}" == "install" ]] && ! _f2b_install; then
    log_warn "fail2ban could not be installed on ${OS_PRETTY}: SSH brute-force protection was not set up (everything else is unaffected)"
    report_add "Fail2ban" "WARN" "package unavailable"
    F2B_ACTION="skip"
    return 0
  fi
  if ! command -v fail2ban-client > /dev/null 2>&1; then
    log_warn "fail2ban-client is missing; SSH brute-force protection was not set up"
    report_add "Fail2ban" "WARN" "not installed"
    return 0
  fi

  if [[ "${F2B_ACTION}" == "keep" ]]; then
    run_logged svc_enable_now fail2ban || true
    log_ok "Your own fail2ban [sshd] jail was left unchanged"
    report_add "Fail2ban" "OK" "existing configuration kept"
    return 0
  fi

  F2B_IGNORE="$(_f2b_ignore_list)"
  local cand be lp started=0
  while IFS= read -r cand; do
    be="${cand%%|*}"
    lp="${cand#*|}"
    if _f2b_write_and_start "${be}" "${lp}"; then
      started=1
      break
    fi
    log_file_only "fail2ban did not start with backend=${be} logpath=${lp:-none}; trying the next option"
  done < <(_f2b_candidates)

  if ((started)); then
    state_set f2b_jail 1
    log_ok "Fail2ban is protecting SSH (jail sshd, ports ${F2B_PORTS[*]})"
    report_add "Fail2ban" "OK" "sshd jail, ban ${MVN_F2B_BANTIME} after ${MVN_F2B_MAXRETRY} failures"
  else
    rm -f -- "${F2B_JAIL_FILE}"
    run_logged svc_restart fail2ban || true
    log_warn "Fail2ban could not be started with the generated jail; the file was removed again (SSH access is unaffected). See: journalctl -u fail2ban"
    report_add "Fail2ban" "WARN" "could not start; see log"
  fi
  return 0
}

f2b_verify() {
  [[ "${F2B_ACTION}" == "skip" ]] && return 0
  if svc_active fail2ban && fail2ban-client status sshd > /dev/null 2>&1; then
    _v_ok "Fail2ban is active (sshd jail running)"
  else
    _v_warn "Fail2ban sshd jail is not running: SSH has no brute-force protection (check: journalctl -u fail2ban)"
  fi
  return 0
}
