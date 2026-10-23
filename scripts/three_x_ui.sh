#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # globals are used by the scripts that source this file
# three_x_ui.sh — installs 3x-ui through ITS OFFICIAL installer. Nothing else here
# installs Xray, writes an Xray config or creates a separate xray.service.

XUI_ACTION="install"        # install | reinstall | keep
XUI_PANEL_PORT_VAL=""
XUI_PANEL_URL=""
XUI_CREDS_NOTE=""
XUI_INSTALLED_BY_US=0

xui_plan() {
  if [[ -n "${MVN_XUI_VERSION}" && ! "${MVN_XUI_VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z]+)*$ ]]; then
    die "${EXIT_PRECOND}" "MVN_XUI_VERSION must look like v3.7.0 (or be empty for the latest stable release)"
  fi
  [[ "${MVN_XUI_INSTALLER_REF}" =~ ^[A-Za-z0-9._-]+$ ]] \
    || die "${EXIT_PRECOND}" "MVN_XUI_INSTALLER_REF contains invalid characters"
  if [[ -n "${MVN_XUI_INSTALLER_SHA256}" && ! "${MVN_XUI_INSTALLER_SHA256}" =~ ^[0-9a-f]{64}$ ]]; then
    die "${EXIT_PRECOND}" "MVN_XUI_INSTALLER_SHA256 must be 64 lowercase hex characters"
  fi

  if [[ "${XUI_PRESENT}" == "1" ]]; then
    if [[ "${MVN_FORCE_XUI_REINSTALL}" == "1" ]]; then
      XUI_ACTION="reinstall"
    else
      XUI_ACTION="keep"
    fi
  else
    XUI_ACTION="install"
  fi

  if [[ "${XUI_ACTION}" == "keep" ]]; then
    XUI_SSL_EFFECTIVE="existing"      # an existing panel is never reconfigured
    return 0
  fi

  # Panel port and HTTPS: questions in interactive mode, flags/env/config otherwise.
  xui_ask_options
  xui_resolve_ssl_mode
  if [[ -n "${MVN_XUI_PANEL_PORT}" ]]; then
    if xui_port_problem "${MVN_XUI_PANEL_PORT}"; then
      die "${EXIT_PRECOND}" "Panel port ${MVN_XUI_PANEL_PORT} cannot be used: ${XUI_PORT_PROBLEM}"
    fi
    if [[ "${MVN_XUI_PANEL_PORT}" == "443" ]]; then
      log_warn "Panel on 443: VPN inbounds on 443 will not be possible while the panel uses it"
    fi
  fi
  xui_ssl_preflight
}

xui_plan_text() {
  case "${XUI_ACTION}" in
    keep) printf 'already installed - kept as is (port, credentials and HTTPS are not changed)' ;;
    *)
      printf 'official installer (version: %s); panel port: %s; HTTPS: %s' \
        "${MVN_XUI_VERSION:-latest stable}" "${MVN_XUI_PANEL_PORT:-random}" \
        "$(case "${XUI_SSL_EFFECTIVE}" in
          ip) printf "Let's Encrypt for the IP (fallback: %s)" "${MVN_XUI_SSL_FALLBACK}" ;;
          domain) printf "Let's Encrypt for %s (fallback: %s)" "${MVN_XUI_DOMAIN}" "${MVN_XUI_SSL_FALLBACK}" ;;
          selfsigned) printf 'self-signed certificate' ;;
          none) printf 'none, plain HTTP' ;;
        esac)"
      ;;
  esac
}

_xui_setting_show() { "${XUI_FOLDER}/x-ui" setting -show true 2> /dev/null || true; }

xui_wait_active() {
  local i
  for ((i = 0; i < 45; i++)); do
    svc_active x-ui && return 0
    sleep 1
  done
  log_error "Service x-ui did not become active. Status and journal were saved to the log."
  svc_dump x-ui
  return 1
}

xui_run_installer() {
  local url="https://raw.githubusercontent.com/mhsanaei/3x-ui/${MVN_XUI_INSTALLER_REF}/install.sh"
  local script="${WORK_DIR}/3x-ui-install.sh" out="${WORK_DIR}/3x-ui-install.out" rc=0 actual

  log_info "Downloading the official 3x-ui installer (ref: ${MVN_XUI_INSTALLER_REF})"
  retry 3 5 curl -fsSL --connect-timeout 15 --max-time 120 -o "${script}" "${url}" \
    || die "${EXIT_FAIL}" "Cannot download the 3x-ui installer from ${url}"
  [[ -s "${script}" ]] && head -n 1 "${script}" | has_match '^#!' \
    || die "${EXIT_FAIL}" "The downloaded 3x-ui installer is empty or not a script"
  if [[ -n "${MVN_XUI_INSTALLER_SHA256}" ]]; then
    actual="$(sha256sum "${script}" | awk '{print $1}')"
    [[ "${actual}" == "${MVN_XUI_INSTALLER_SHA256}" ]] \
      || die "${EXIT_FAIL}" "3x-ui installer checksum mismatch (expected ${MVN_XUI_INSTALLER_SHA256}, got ${actual}); not running it"
    log_ok "3x-ui installer checksum verified"
  else
    log_info "Installer checksum is not pinned (set MVN_XUI_INSTALLER_SHA256 to verify it)"
  fi

  local -a env_args=("XUI_NONINTERACTIVE=1") args=()
  # Let's Encrypt modes go to the installer; self-signed/none: the installer skips SSL and
  # xui_tls_finalize adds the certificate afterwards.
  case "${XUI_SSL_EFFECTIVE}" in
    ip | domain) env_args+=("XUI_SSL_MODE=${XUI_SSL_EFFECTIVE}") ;;
  esac
  if [[ "${XUI_SSL_EFFECTIVE}" == "domain" ]]; then env_args+=("XUI_DOMAIN=${MVN_XUI_DOMAIN}"); fi
  if [[ -n "${MVN_XUI_PANEL_PORT}" ]]; then env_args+=("XUI_PANEL_PORT=${MVN_XUI_PANEL_PORT}"); fi
  if [[ -n "${MVN_XUI_ACME_EMAIL}" ]]; then env_args+=("XUI_ACME_EMAIL=${MVN_XUI_ACME_EMAIL}"); fi
  if [[ -n "${XUI_PUBLIC_IP}" ]]; then env_args+=("XUI_SERVER_IP=${XUI_PUBLIC_IP}"); fi
  if [[ -n "${MVN_XUI_VERSION}" ]]; then args+=("${MVN_XUI_VERSION}"); fi

  log_info "Running the 3x-ui installer (unattended). This can take a few minutes..."
  # The installer prints generated credentials, so its output goes to a root-only temp
  # file and is NEVER copied into the shared log.
  ( umask 022; env "${env_args[@]}" bash "${script}" "${args[@]}" < /dev/null > "${out}" 2>&1 ) || rc=$?

  if ((rc != 0)); then
    log_error "The 3x-ui installer failed (exit code ${rc}). Last lines (credentials redacted):"
    tail -n 25 "${out}" | redact_stream | while IFS= read -r l; do log_error "  ${l}"; done
    rm -f -- "${out}"
    die "${EXIT_FAIL}" "3x-ui installation failed"
  fi
  rm -f -- "${out}" "${script}"
  log_ok "3x-ui installer finished"
  XUI_INSTALLED_BY_US=1
}

xui_collect_info() {
  local port="" path="" url="" host="" rest
  XUI_CREDS_NOTE=""

  if [[ -r "${XUI_RESULT_FILE}" ]]; then
    port="$(kv_get "${XUI_RESULT_FILE}" XUI_PANEL_PORT || true)"
    path="$(kv_get "${XUI_RESULT_FILE}" XUI_WEB_BASE_PATH || true)"
    url="$(kv_get "${XUI_RESULT_FILE}" XUI_ACCESS_URL || true)"
    XUI_CREDS_NOTE="file: ${XUI_RESULT_FILE} (root only; read it with: sudo cat ${XUI_RESULT_FILE})"
  fi

  if ! valid_port "${port}" && [[ -x "${XUI_FOLDER}/x-ui" ]]; then
    port="$(_xui_setting_show | sed -n 's/^[[:space:]]*port:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1)"
    path="$(_xui_setting_show | sed -n 's/^[[:space:]]*webBasePath:[[:space:]]*\(.*\)$/\1/p' | head -n 1 | tr -d '[:space:]')"
    path="${path#/}"; path="${path%/}"
  fi
  if [[ -z "${XUI_CREDS_NOTE}" ]]; then
    XUI_CREDS_NOTE="unchanged by MVN Deploy; show them with: x-ui settings  (or the x-ui menu to reset)"
  fi

  if valid_port "${port}"; then
    XUI_PANEL_PORT_VAL="${port}"
  else
    XUI_PANEL_PORT_VAL=""
    log_warn "Could not determine the 3x-ui panel port; open it manually in the firewall (run: x-ui settings)"
    return 0
  fi
  [[ "${path}" =~ ^[A-Za-z0-9/_-]*$ ]] || path=""
  path="${path#/}"

  # Ask the panel itself whether it speaks HTTPS: the installer's own summary can be wrong.
  xui_probe_scheme "${XUI_PANEL_PORT_VAL}" "${path}" || log_warn "The panel did not answer on 127.0.0.1:${XUI_PANEL_PORT_VAL}"

  # Host for the address: the domain we configured, else the host of the installer's URL, else the public IP.
  if [[ "${XUI_INSTALLED_BY_US}" == "1" && -n "${MVN_XUI_DOMAIN}" && ( "${XUI_SSL_EFFECTIVE}" == "domain" || "${XUI_SSL_EFFECTIVE}" == "selfsigned" ) ]]; then
    host="${MVN_XUI_DOMAIN}"
  elif [[ "${url}" =~ ^https?://([^/:[:space:]]+) && "${BASH_REMATCH[1]}" != *SERVER_IP_UNKNOWN* ]]; then
    host="${BASH_REMATCH[1]}"
  fi
  if [[ -z "${host}" ]]; then host="${XUI_PUBLIC_IP}"; fi
  if [[ -z "${host}" ]]; then host="$(_local_src_ipv4)"; fi
  rest="${XUI_PANEL_PORT_VAL}/${path}"
  XUI_PANEL_URL="${XUI_SCHEME:-http}://${host:-<server-ip>}:${rest}"
}

xui_apply() {
  case "${XUI_ACTION}" in
    keep)
      log_ok "3x-ui is already installed; the official installer is NOT re-run (set MVN_FORCE_XUI_REINSTALL=1 to force it)"
      if ! svc_active x-ui; then
        log_warn "Service x-ui is not active; trying to start it"
        run_logged svc_start x-ui || true
      fi
      ;;
    install | reinstall)
      xui_run_installer
      ;;
  esac
  xui_wait_active || die "${EXIT_FAIL}" "x-ui is not running"
  sec_protect_secrets
  xui_tls_finalize
  if [[ "${XUI_SSL_EFFECTIVE}" != "ip" && "${XUI_SSL_EFFECTIVE}" != "domain" ]]; then fw_forget_acme_port; fi
  xui_collect_info
  if [[ "${XUI_INSTALLED_BY_US}" == "1" ]]; then state_set xui_installed_by_mvn 1; fi
  if [[ -n "${XUI_PANEL_PORT_VAL}" ]]; then state_set panel_port "${XUI_PANEL_PORT_VAL}"; fi
  log_ok "3x-ui service is active (panel port: ${XUI_PANEL_PORT_VAL:-unknown})"
  report_add "3x-ui" "OK" "${XUI_ACTION}; service active; ${XUI_SCHEME:-no-answer}${XUI_TLS_NOTE:+; ${XUI_TLS_NOTE}}"
}
