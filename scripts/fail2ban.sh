#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # globals are used by the scripts that source this file
# fail2ban.sh — bans IPs that guess SSH passwords. One drop-in file, easy to remove.
# An existing user-written [sshd] jail is never overridden.

F2B_ACTION="skip"           # skip | install | keep
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
    skip) log_info "Fail2ban disabled (MVN_FAIL2BAN=skip)"; return 0 ;;
    auto) ;;
    *) die "${EXIT_PRECOND}" "MVN_FAIL2BAN must be auto or skip" ;;
  esac
  [[ "${MVN_F2B_MAXRETRY}" =~ ^[0-9]{1,3}$ ]] && ((10#${MVN_F2B_MAXRETRY} >= 1)) \
    || die "${EXIT_PRECOND}" "MVN_F2B_MAXRETRY must be a number >= 1"
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
      "$(IFS=,; echo "${F2B_PORTS[*]}")" "${MVN_F2B_MAXRETRY}" "${MVN_F2B_FINDTIME}" "${MVN_F2B_BANTIME}" ;;
    keep) printf 'fail2ban already has your own [sshd] jail: leave it unchanged' ;;
    *) printf 'skipped' ;;
  esac
}

f2b_render() { # backend ignore-list -> jail file content on stdout
  local backend="$1" ignore="$2"
  printf '# Managed by MVN Deploy. Safe to delete; uninstall.sh removes it.\n'
  printf '[sshd]\nenabled = true\nport = %s\nbackend = %s\n' "$(IFS=,; echo "${F2B_PORTS[*]}")" "${backend}"
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

_f2b_write_and_start() { # backend
  local tmp="${F2B_JAIL_FILE}.tmp.$$"
  install -d -m 755 "$(dirname "${F2B_JAIL_FILE}")"
  f2b_render "$1" "${F2B_IGNORE}" > "${tmp}"
  chmod 644 "${tmp}"
  mv -f -- "${tmp}" "${F2B_JAIL_FILE}"
  if ! run_logged fail2ban-client -t; then return 1; fi
  run_logged systemctl enable fail2ban || true
  run_logged systemctl restart fail2ban || return 1
  _f2b_wait_ready
}

f2b_apply() {
  case "${F2B_ACTION}" in
    skip) report_add "Fail2ban" "SKIPPED" "not requested"; return 0 ;;
  esac
  if ! command -v fail2ban-client > /dev/null 2>&1; then
    log_warn "fail2ban-client is missing; SSH brute-force protection was not set up"
    report_add "Fail2ban" "WARN" "not installed"
    return 0
  fi

  if [[ "${F2B_ACTION}" == "keep" ]]; then
    run_logged systemctl enable --now fail2ban || true
    log_ok "Your own fail2ban [sshd] jail was left unchanged"
    report_add "Fail2ban" "OK" "existing configuration kept"
    return 0
  fi

  F2B_IGNORE="$(_f2b_ignore_list)"
  local first="auto" second="systemd"
  if [[ ! -f /var/log/auth.log ]]; then first="systemd"; second="auto"; fi   # no rsyslog: read the journal

  if _f2b_write_and_start "${first}" || _f2b_write_and_start "${second}"; then
    state_set f2b_jail 1
    log_ok "Fail2ban is protecting SSH (jail sshd, ports ${F2B_PORTS[*]})"
    report_add "Fail2ban" "OK" "sshd jail, ban ${MVN_F2B_BANTIME} after ${MVN_F2B_MAXRETRY} failures"
  else
    rm -f -- "${F2B_JAIL_FILE}"
    run_logged systemctl restart fail2ban || true
    log_warn "Fail2ban could not be started with the generated jail; the file was removed again (SSH access is unaffected)"
    report_add "Fail2ban" "WARN" "could not start; see log"
  fi
  return 0
}

f2b_verify() {
  [[ "${F2B_ACTION}" == "skip" ]] && return 0
  if systemctl is-active --quiet fail2ban 2> /dev/null && fail2ban-client status sshd > /dev/null 2>&1; then
    _v_ok "Fail2ban is active (sshd jail running)"
  else
    _v_warn "Fail2ban sshd jail is not running: SSH has no brute-force protection (check: journalctl -u fail2ban)"
  fi
  return 0
}
