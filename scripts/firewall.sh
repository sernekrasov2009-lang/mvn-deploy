#!/usr/bin/env bash
# shellcheck shell=bash
# firewall.sh — local UFW management. Existing rules are never deleted or reset;
# SSH is always allowed BEFORE a deny-incoming policy is enabled.

FW_ACTION="skip"            # skip | ufw-add | ufw-enable
FW_SSH_PORTS=()
FW_TCP_EXTRA=()
FW_UDP_EXTRA=()

fw_plan() {
  FW_ACTION="skip"
  case "${MVN_FIREWALL}" in
    skip) log_info "Firewall management disabled (MVN_FIREWALL=skip)"; return 0 ;;
    auto) ;;
    *) die "${EXIT_PRECOND}" "MVN_FIREWALL must be auto or skip" ;;
  esac

  # Optional extra ports (ask only in interactive mode and only if not preset).
  if ! is_noninteractive && [[ "${MVN_DRY_RUN}" != "1" ]]; then
    [[ -z "${MVN_EXTRA_TCP_PORTS}" ]] && MVN_EXTRA_TCP_PORTS="$(ask_value 'Additional TCP ports to open now (e.g. 443; empty = none)' '')"
    [[ -z "${MVN_EXTRA_UDP_PORTS}" ]] && MVN_EXTRA_UDP_PORTS="$(ask_value 'Additional UDP ports to open now (empty = none)' '')"
  fi
  parse_port_list FW_TCP_EXTRA "${MVN_EXTRA_TCP_PORTS}" || die "${EXIT_PRECOND}" "Invalid MVN_EXTRA_TCP_PORTS"
  parse_port_list FW_UDP_EXTRA "${MVN_EXTRA_UDP_PORTS}" || die "${EXIT_PRECOND}" "Invalid MVN_EXTRA_UDP_PORTS"
  if [[ "${MVN_XUI_SSL_MODE}" != "none" ]] && ! array_contains "80" "${FW_TCP_EXTRA[@]}"; then
    FW_TCP_EXTRA+=("80")   # needed by the Let's Encrypt HTTP-01 challenge
  fi

  local -a override=()
  parse_port_list override "${MVN_SSH_PORTS}" || die "${EXIT_PRECOND}" "Invalid MVN_SSH_PORTS"
  FW_SSH_PORTS=("${SSH_PORTS_DETECTED[@]}")
  local p
  for p in "${override[@]}"; do
    array_contains "${p}" "${FW_SSH_PORTS[@]}" || FW_SSH_PORTS+=("${p}")
  done

  case "${FW_KIND}" in
    foreign)
      log_warn "Another firewall is active: ${FW_DETAIL}. MVN Deploy will not reset it or enable UFW on top of it."
      if [[ "${MVN_DRY_RUN}" == "1" ]]; then
        log_warn "A real run would ask whether to continue without firewall changes (or use MVN_FIREWALL=skip)"
      elif is_noninteractive; then
        die "${EXIT_ABORT}" "Unattended mode cannot decide about a foreign firewall. Set MVN_FIREWALL=skip to continue without firewall changes."
      else
        ask_yes_no "Continue WITHOUT any firewall changes (you must open ports yourself)?" n \
          || die "${EXIT_ABORT}" "Aborted by user"
      fi
      FW_ACTION="skip"
      ;;
    ufw-active)
      FW_ACTION="ufw-add"
      ;;
    *)
      FW_ACTION="ufw-enable"
      if ((${#FW_SSH_PORTS[@]} == 0)); then
        if [[ "${MVN_DRY_RUN}" == "1" ]]; then
          log_warn "SSH port could not be detected; a real run would ask for it (or use MVN_SSH_PORTS)"
        elif is_noninteractive; then
          die "${EXIT_ABORT}" "Cannot detect the SSH port. Set MVN_SSH_PORTS=<port> or MVN_FIREWALL=skip. Nothing was changed."
        else
          local ans=""
          while ((${#FW_SSH_PORTS[@]} == 0)); do
            ans="$(ask_value 'SSH port could not be detected. Enter your SSH port(s)' '')"
            parse_port_list FW_SSH_PORTS "${ans}" 2> /dev/null || FW_SSH_PORTS=()
          done
        fi
      fi
      ;;
  esac
}

fw_plan_text() {
  case "${FW_ACTION}" in
    skip) printf 'no local firewall changes' ;;
    ufw-add) printf 'UFW already active: add rules only (ssh: %s)' "${FW_SSH_PORTS[*]:-unknown}" ;;
    ufw-enable) printf 'enable UFW (deny incoming); allow ssh %s first, then the panel port, tcp: %s udp: %s' \
      "${FW_SSH_PORTS[*]:-?}" "${FW_TCP_EXTRA[*]:-none}" "${FW_UDP_EXTRA[*]:-none}" ;;
  esac
}

_ufw_rule_added() { ufw show added 2> /dev/null | has_match -E "^ufw allow ${1}( |$)"; }

# fw_allow <port-or-range> <tcp|udp> <role>
fw_allow() {
  local spec="$1/$2" role="$3"
  if _ufw_rule_added "${spec}"; then
    log_file_only "UFW rule already present: ${spec}"
    return 0
  fi
  run_logged ufw allow "${spec}" comment "mvn-deploy: ${role}" \
    || die "${EXIT_FAIL}" "Failed to add UFW rule ${spec}"
  state_add ufw_rule "${spec} ${role}"
  log_ok "Allowed ${spec} (${role})"
}

# fw_status_allows <port-or-range> <proto>
fw_status_allows() {
  ufw status 2> /dev/null | has_match -E "^${1}(/${2})?[[:space:]]+(\(v6\)[[:space:]]+)?ALLOW"
}

fw_apply() {
  if [[ "${FW_ACTION}" == "skip" ]]; then
    report_add "Firewall" "SKIPPED" "no local firewall changes"
    return 0
  fi
  command -v ufw > /dev/null 2>&1 || die "${EXIT_FAIL}" "ufw is not installed"

  local p
  if [[ "${FW_ACTION}" == "ufw-enable" ]]; then
    run_logged ufw default deny incoming || die "${EXIT_FAIL}" "ufw default deny incoming failed"
    run_logged ufw default allow outgoing || die "${EXIT_FAIL}" "ufw default allow outgoing failed"
  fi

  # 1) SSH first.
  for p in "${FW_SSH_PORTS[@]}"; do fw_allow "${p}" tcp ssh; done
  if [[ "${FW_ACTION}" == "ufw-enable" ]]; then
    for p in "${FW_SSH_PORTS[@]}"; do
      _ufw_rule_added "${p}/tcp" || die "${EXIT_FAIL}" "SSH rule for ${p}/tcp is not present; refusing to enable the firewall"
    done
  fi
  # 2) panel port, 3) chosen extras.
  if [[ -n "${XUI_PANEL_PORT_VAL}" ]]; then
    fw_allow "${XUI_PANEL_PORT_VAL}" tcp panel
  else
    log_warn "Panel port unknown: no firewall rule was created for the panel"
  fi
  for p in "${FW_TCP_EXTRA[@]}"; do fw_allow "${p}" tcp extra; done
  for p in "${FW_UDP_EXTRA[@]}"; do fw_allow "${p}" udp extra; done

  # 4) enable only after the rule set is verified.
  if [[ "${FW_ACTION}" == "ufw-enable" ]]; then
    log_info "Enabling UFW..."
    run_logged ufw --force enable || die "${EXIT_FAIL}" "Failed to enable UFW"
    local ok=1
    ufw status 2> /dev/null | has_match -i '^Status: active' || ok=0
    for p in "${FW_SSH_PORTS[@]}"; do fw_status_allows "${p}" tcp || ok=0; done
    if ((ok == 0)); then
      run_logged ufw disable || true
      die "${EXIT_FAIL}" "Post-enable check failed (SSH not allowed or UFW inactive); UFW was disabled again to keep access"
    fi
    state_set ufw_enabled_by_mvn 1
  fi
  log_ok "Firewall configured"
  report_add "Firewall" "OK" "$(fw_plan_text)"
}
