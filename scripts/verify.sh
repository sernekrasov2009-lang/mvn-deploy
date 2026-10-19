#!/usr/bin/env bash
# shellcheck shell=bash
# verify.sh — verify the result instead of trusting exit codes.

VERIFY_FAILS=0
VERIFY_WARNS=0

_v_ok()   { log_ok "$1"; }
_v_warn() { log_warn "$1"; VERIFY_WARNS=$((VERIFY_WARNS + 1)); }
_v_fail() { log_error "$1"; VERIFY_FAILS=$((VERIFY_FAILS + 1)); }

_perm() { stat -c '%a' "$1" 2> /dev/null || echo "?"; }

verify_all() {
  VERIFY_FAILS=0; VERIFY_WARNS=0
  local p

  # 3x-ui service
  if systemctl is-active --quiet x-ui 2> /dev/null; then _v_ok "x-ui service is active"; else _v_fail "x-ui service is NOT active"; fi
  if systemctl is-enabled --quiet x-ui 2> /dev/null; then _v_ok "x-ui starts on boot"; else _v_warn "x-ui is not enabled for boot"; fi
  [[ -x "${XUI_FOLDER}/x-ui" ]] && _v_ok "x-ui binary present" || _v_fail "x-ui binary not found in ${XUI_FOLDER}"

  # Panel port (local check only)
  if [[ -n "${XUI_PANEL_PORT_VAL}" ]]; then
    if command -v ss > /dev/null 2>&1 && [[ -n "$(ss -ltnH "sport = :${XUI_PANEL_PORT_VAL}" 2> /dev/null)" ]]; then
      _v_ok "Panel port ${XUI_PANEL_PORT_VAL} is listening locally"
    else
      _v_warn "Panel port ${XUI_PANEL_PORT_VAL} is not seen listening locally"
    fi
  else
    _v_warn "Panel port is unknown"
  fi
  case "${XUI_SCHEME}" in
    https) _v_ok "Panel answers over HTTPS${XUI_TLS_NOTE:+ (${XUI_TLS_NOTE})}" ;;
    http) _v_warn "Panel answers over plain HTTP: do not log in over the internet without an SSH tunnel or TLS" ;;
    *) _v_warn "Panel did not answer locally on port ${XUI_PANEL_PORT_VAL:-?}" ;;
  esac

  # Credentials
  if [[ -f "${XUI_RESULT_FILE}" ]]; then
    [[ "$(_perm "${XUI_RESULT_FILE}")" == "600" ]] && _v_ok "Credentials file is root-only (600)" || _v_fail "Credentials file ${XUI_RESULT_FILE} has unsafe permissions"
  elif [[ -x "${XUI_FOLDER}/x-ui" ]]; then
    _v_ok "Credentials are available via 'x-ui settings'"
  fi

  # Firewall
  case "${FW_ACTION}" in
    skip) _v_warn "Local firewall was not managed by MVN Deploy; make sure SSH and the panel port are reachable" ;;
    ufw-add | ufw-enable)
      if ufw status 2> /dev/null | has_match -i '^Status: active'; then
        _v_ok "UFW is active"
        for p in "${FW_SSH_PORTS[@]}"; do
          fw_status_allows "${p}" tcp && _v_ok "SSH ${p}/tcp is allowed" || _v_fail "SSH ${p}/tcp is NOT allowed in UFW"
        done
        if [[ -n "${XUI_PANEL_PORT_VAL}" ]]; then
          fw_status_allows "${XUI_PANEL_PORT_VAL}" tcp && _v_ok "Panel ${XUI_PANEL_PORT_VAL}/tcp is allowed" || _v_fail "Panel port ${XUI_PANEL_PORT_VAL}/tcp is NOT allowed in UFW"
        fi
        for p in "${FW_TCP_EXTRA[@]}"; do fw_status_allows "${p}" tcp && _v_ok "${p}/tcp is allowed" || _v_fail "${p}/tcp is NOT allowed"; done
        for p in "${FW_UDP_EXTRA[@]}"; do fw_status_allows "${p}" udp && _v_ok "${p}/udp is allowed" || _v_fail "${p}/udp is NOT allowed"; done
        systemctl is-enabled --quiet ufw 2> /dev/null && _v_ok "UFW starts on boot" || _v_warn "UFW service is not enabled for boot"
      else
        _v_fail "UFW is not active"
      fi
      ;;
  esac

  # Fail2ban
  f2b_verify

  # BBR
  case "${BBR_RESULT}" in
    enabled | unchanged)
      sys_detect_bbr
      if [[ "${BBR_CC_CURRENT}" == "bbr" && "${BBR_QDISC_CURRENT}" == "fq" ]]; then _v_ok "BBR active (bbr + fq)"; else _v_fail "BBR is expected but not active (${BBR_CC_CURRENT}/${BBR_QDISC_CURRENT})"; fi
      [[ -f "${BBR_SYSCTL_FILE}" ]] || _bbr_persisted_elsewhere && _v_ok "BBR persists across reboots" || _v_warn "BBR persistence not confirmed"
      ;;
    unsupported) _v_warn "BBR is not supported by this kernel (reported honestly, nothing changed)" ;;
    failed) _v_warn "BBR could not be enabled" ;;
    skipped) log_info "BBR skipped by configuration" ;;
  esac

  # Files and permissions
  [[ "$(_perm "${MVN_STATE_DIR}")" == "700" ]] && _v_ok "State directory is root-only" || _v_warn "State directory permissions are not 700"
  [[ "${LOG_READY}" -eq 1 && "$(_perm "${LOG_FILE}")" == "600" ]] && _v_ok "Log file is root-only (600)" || _v_warn "Log file is missing or not 600"

  log_info "Note: these checks run on the server. External reachability from the internet is NOT verified."
}
