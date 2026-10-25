#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # globals are used by the scripts that source this file
# firewall.sh — local firewall management through UFW (Debian/Ubuntu/Arch/Alpine) or firewalld
# (RHEL family, openSUSE). Existing rules are never deleted or reset; SSH is always allowed BEFORE
# a deny-incoming policy is enabled; foreign firewalls (raw nftables/iptables) are never touched.
# A firewall that cannot be set up (container, missing kernel modules, no package) degrades to a
# loud warning: it must never abort a deployment or lock the administrator out.

FW_ACTION="skip" # skip | add | enable
FW_BACKEND=""    # ufw | firewalld
FW_SSH_PORTS=()
FW_TCP_EXTRA=()
FW_UDP_EXTRA=()
FW_USER_TCP=()
FW_FAILED=0
FW_ZONE=""

# fw_forget_acme_port: Let's Encrypt was not used after all, so port 80 is no longer needed.
fw_forget_acme_port() {
  local -a keep=()
  local p
  for p in "${FW_TCP_EXTRA[@]}"; do
    if [[ "${p}" != "80" ]] || array_contains "80" "${FW_USER_TCP[@]}"; then keep+=("${p}"); fi
  done
  FW_TCP_EXTRA=("${keep[@]}")
}

fw_default_backend() {
  case "${PLAT_PM}" in
    dnf | yum | zypper) echo "firewalld" ;;
    *) echo "ufw" ;;
  esac
}

fw_plan() {
  FW_ACTION="skip"
  FW_BACKEND=""
  case "${MVN_FIREWALL}" in
    skip)
      log_info "Firewall management disabled (MVN_FIREWALL=skip)"
      return 0
      ;;
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
  FW_USER_TCP=("${FW_TCP_EXTRA[@]}")
  if [[ "${XUI_SSL_EFFECTIVE}" == "ip" || "${XUI_SSL_EFFECTIVE}" == "domain" ]] && ! array_contains "80" "${FW_TCP_EXTRA[@]}"; then
    FW_TCP_EXTRA+=("80") # needed by the Let's Encrypt HTTP-01 challenge and its renewals
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
      log_warn "Another firewall is active: ${FW_DETAIL}. MVN Deploy will not reset it or enable another one on top of it."
      if [[ "${MVN_DRY_RUN}" == "1" ]]; then
        log_warn "A real run would ask whether to continue without firewall changes (or use MVN_FIREWALL=skip)"
      elif is_noninteractive; then
        die "${EXIT_ABORT}" "Unattended mode cannot decide about a foreign firewall. Set MVN_FIREWALL=skip to continue without firewall changes."
      else
        ask_yes_no "Continue WITHOUT any firewall changes (you must open ports yourself)?" n ||
          die "${EXIT_ABORT}" "Aborted by user"
      fi
      FW_ACTION="skip"
      return 0
      ;;
    ufw-active)
      FW_BACKEND="ufw"
      FW_ACTION="add"
      ;;
    firewalld-active)
      FW_BACKEND="firewalld"
      FW_ACTION="add"
      ;;
    ufw-inactive)
      FW_BACKEND="ufw"
      FW_ACTION="enable"
      ;;
    firewalld-inactive)
      FW_BACKEND="firewalld"
      FW_ACTION="enable"
      ;;
    *)
      FW_BACKEND="$(fw_default_backend)"
      FW_ACTION="enable"
      ;;
  esac

  if [[ "${FW_ACTION}" == "enable" ]]; then
    if [[ -n "${VIRT_KIND}" ]]; then
      log_warn "Container (${VIRT_KIND}): enabling the firewall may be refused by the host; if so it is skipped with a warning"
    fi
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
  fi
  return 0
}

fw_plan_text() {
  local b="${FW_BACKEND:-firewall}"
  case "${FW_ACTION}" in
    skip) printf 'no local firewall changes' ;;
    add) printf '%s already active: add rules only (ssh: %s)' "${b}" "${FW_SSH_PORTS[*]:-unknown}" ;;
    enable) printf 'enable %s (deny incoming); allow ssh %s first, then the panel port, tcp: %s udp: %s' \
      "${b}" "${FW_SSH_PORTS[*]:-?}" "${FW_TCP_EXTRA[*]:-none}" "${FW_UDP_EXTRA[*]:-none}" ;;
  esac
}

# fw_prepare: make sure the chosen firewall tool exists. Never fatal.
fw_degrade() {
  log_warn "$1: the firewall will NOT be changed. Open the ports in your provider panel or set up a firewall yourself."
  FW_ACTION="skip"
  FW_FAILED=1
}

fw_prepare() {
  [[ "${FW_ACTION}" == "enable" ]] || return 0
  case "${FW_BACKEND}" in
    ufw) deps_install_optional ufw ufw || fw_degrade "ufw could not be installed" ;;
    firewalld) deps_install_optional firewall-cmd firewalld || fw_degrade "firewalld could not be installed" ;;
  esac
  return 0
}

# ---------- UFW primitives ----------
_ufw_rule_added() { ufw show added 2> /dev/null | has_match -E "^ufw allow ${1}( |$)"; }

# ---------- firewalld primitives ----------
_fwd_spec() { printf '%s' "${1/:/-}"; } # ufw ranges use A:B, firewalld uses A-B
_fwd_running() { firewall-cmd --state 2> /dev/null | has_match -i '^running'; }

_fwd_zone() { # the zone that really serves the public interface
  local z="" dev
  if _fwd_running; then
    dev="$(ip -4 route show default 2> /dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
    if [[ -n "${dev}" ]]; then z="$(firewall-cmd --get-zone-of-interface="${dev}" 2> /dev/null || true)"; fi
    [[ "${z}" == "no zone" ]] && z=""
    [[ -n "${z}" ]] || z="$(firewall-cmd --get-default-zone 2> /dev/null || true)"
  else
    z="$(firewall-offline-cmd --get-default-zone 2> /dev/null || true)"
  fi
  printf '%s' "${z:-public}"
}

_fwd_query() { # port-spec proto
  firewall-cmd --zone="${FW_ZONE:-$(_fwd_zone)}" --query-port="$(_fwd_spec "$1")/$2" > /dev/null 2>&1
}

_fwd_allow() { # spec(port or range) proto role
  local spec rc=0 zone="${FW_ZONE:-$(_fwd_zone)}"
  spec="$(_fwd_spec "$1")/$2"
  if _fwd_running; then
    if firewall-cmd --zone="${zone}" --query-port="${spec}" > /dev/null 2>&1; then
      log_file_only "firewalld rule already present: ${spec} (${zone})"
      return 0
    fi
    run_logged firewall-cmd --permanent --zone="${zone}" --add-port="${spec}" || rc=1
    run_logged firewall-cmd --zone="${zone}" --add-port="${spec}" || rc=1
  else
    run_logged firewall-offline-cmd --zone="${zone}" --add-port="${spec}" || rc=$?
    [[ "${rc}" == "11" ]] && rc=0 # ALREADY_ENABLED
  fi
  ((rc == 0)) || return 1
  state_add firewalld_rule "${zone} ${spec} $3"
  return 0
}

# ---------- generic API ----------
# fw_allow <port-or-range> <tcp|udp> <role>; returns 1 on failure (the caller decides how serious it is)
fw_allow() {
  local spec="$1/$2" role="$3"
  case "${FW_BACKEND}" in
    ufw)
      if _ufw_rule_added "${spec}"; then
        log_file_only "UFW rule already present: ${spec}"
        return 0
      fi
      if ! run_logged ufw allow "${spec}" comment "mvn-deploy: ${role}"; then
        log_error "Failed to add UFW rule ${spec}"
        return 1
      fi
      state_add ufw_rule "${spec} ${role}"
      ;;
    firewalld)
      if ! _fwd_allow "$1" "$2" "${role}"; then
        log_error "Failed to add firewalld rule ${spec}"
        return 1
      fi
      ;;
    *) return 1 ;;
  esac
  log_ok "Allowed ${spec} (${role})"
}

# fw_status_allows <port-or-range> <proto>: is the port open right now?
fw_status_allows() {
  case "${FW_BACKEND}" in
    ufw) ufw status 2> /dev/null | has_match -E "^${1}(/${2})?[[:space:]]+(\\(v6\\)[[:space:]]+)?ALLOW" ;;
    firewalld) _fwd_query "$1" "$2" ;;
    *) return 1 ;;
  esac
}

fw_is_active() {
  case "${FW_BACKEND}" in
    ufw) ufw status 2> /dev/null | has_match -i '^Status: active' ;;
    firewalld) _fwd_running ;;
    *) return 1 ;;
  esac
}

_fw_cmd_present() {
  case "${FW_BACKEND}" in
    ufw) command -v ufw > /dev/null 2>&1 ;;
    firewalld) command -v firewall-cmd > /dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

_fw_enable_backend() {
  case "${FW_BACKEND}" in
    ufw)
      run_logged ufw default deny incoming || return 1
      run_logged ufw default allow outgoing || return 1
      ;;
  esac
  return 0
}

_fw_turn_on() {
  case "${FW_BACKEND}" in
    ufw)
      run_logged ufw --force enable || return 1
      run_logged svc_enable ufw || true # Arch/Alpine: the package does not enable its unit
      ;;
    firewalld)
      run_logged svc_enable_now firewalld || return 1
      local i
      for ((i = 0; i < 15; i++)); do
        _fwd_running && return 0
        sleep 1
      done
      return 1
      ;;
  esac
}

_fw_turn_off() {
  case "${FW_BACKEND}" in
    ufw) run_logged ufw disable || true ;;
    firewalld) run_logged svc_stop firewalld || true ;;
  esac
}

fw_apply() {
  if [[ "${FW_ACTION}" == "skip" ]]; then
    if ((FW_FAILED)); then report_add "Firewall" "WARN" "could not be set up; see the warnings"; else report_add "Firewall" "SKIPPED" "no local firewall changes"; fi
    return 0
  fi
  if ! _fw_cmd_present; then
    fw_degrade "${FW_BACKEND} is not installed"
    report_add "Firewall" "WARN" "tool missing"
    return 0
  fi

  local p
  if [[ "${FW_ACTION}" == "enable" ]]; then
    if ! _fw_enable_backend; then
      fw_degrade "${FW_BACKEND} refused its default policy (container or missing kernel support)"
      report_add "Firewall" "WARN" "refused by the system"
      return 0
    fi
  fi
  if [[ "${FW_BACKEND}" == "firewalld" ]]; then
    FW_ZONE="$(_fwd_zone)"
    log_info "firewalld zone used for the rules: ${FW_ZONE}"
  fi

  # 1) SSH first. If an SSH rule cannot be created, nothing is enabled.
  for p in "${FW_SSH_PORTS[@]}"; do
    if ! fw_allow "${p}" tcp ssh; then
      if [[ "${FW_ACTION}" == "enable" ]]; then
        fw_degrade "The SSH rule for ${p}/tcp could not be created, so the firewall was NOT enabled (to keep you from being locked out)"
        report_add "Firewall" "WARN" "ssh rule failed"
        return 0
      fi
      log_warn "SSH rule ${p}/tcp could not be added to the active firewall"
    fi
  done
  # 2) panel port, 3) chosen extras (a failure here is a warning, not a stop).
  if [[ -n "${XUI_PANEL_PORT_VAL}" ]]; then
    fw_allow "${XUI_PANEL_PORT_VAL}" tcp panel || log_warn "The panel port ${XUI_PANEL_PORT_VAL}/tcp is NOT open in the firewall"
  else
    log_warn "Panel port unknown: no firewall rule was created for the panel"
  fi
  for p in "${FW_TCP_EXTRA[@]}"; do fw_allow "${p}" tcp extra || log_warn "${p}/tcp could not be opened"; done
  for p in "${FW_UDP_EXTRA[@]}"; do fw_allow "${p}" udp extra || log_warn "${p}/udp could not be opened"; done

  # 4) enable only after the rule set exists, then check that SSH is still allowed.
  if [[ "${FW_ACTION}" == "enable" ]]; then
    log_info "Enabling ${FW_BACKEND}..."
    local ok=1
    _fw_turn_on || ok=0
    if ((ok)); then
      fw_is_active || ok=0
      for p in "${FW_SSH_PORTS[@]}"; do fw_status_allows "${p}" tcp || ok=0; done
    fi
    if ((ok == 0)); then
      _fw_turn_off
      fw_degrade "Enabling ${FW_BACKEND} failed or SSH was not allowed afterwards; it was switched off again to keep your access"
      report_add "Firewall" "WARN" "enable failed; rolled back"
      return 0
    fi
    if [[ "${FW_BACKEND}" == "ufw" ]]; then state_set ufw_enabled_by_mvn 1; else state_set firewalld_enabled_by_mvn 1; fi
  fi
  log_ok "Firewall configured (${FW_BACKEND})"
  report_add "Firewall" "OK" "${FW_BACKEND}: $(fw_plan_text)"
  return 0
}
