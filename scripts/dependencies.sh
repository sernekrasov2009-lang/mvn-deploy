#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # globals are used by the scripts that source this file
# dependencies.sh — install only the system packages MVN Deploy needs, on any supported distribution.
# Tools are detected by COMMAND, not by package name: that avoids conflicts such as curl vs curl-minimal.

DEPS_MISSING=()       # logical names of REQUIRED tools that are missing
DEPS_PKGS=()          # real package names for them
DEPS_OPTIONAL=()      # recommended packages; failing to install them only produces warnings

_ca_ok() { [[ -s /etc/ssl/certs/ca-certificates.crt || -s /etc/pki/tls/certs/ca-bundle.crt || -s /etc/ssl/ca-bundle.pem || -s /etc/ssl/cert.pem ]]; }

# deps_compute_missing: read-only.
deps_compute_missing() {
  DEPS_MISSING=(); DEPS_PKGS=(); DEPS_OPTIONAL=()
  local l n
  local -a req=() opt=()

  command -v curl > /dev/null 2>&1 || req+=(curl)
  command -v tar > /dev/null 2>&1 || req+=(tar)
  command -v openssl > /dev/null 2>&1 || req+=(openssl)
  { command -v ip > /dev/null 2>&1 && command -v ss > /dev/null 2>&1; } || req+=(iproute)
  _ca_ok || req+=(ca-certificates)
  command -v sysctl > /dev/null 2>&1 || opt+=(procps)
  command -v modprobe > /dev/null 2>&1 || opt+=(kmod)
  command -v flock > /dev/null 2>&1 || opt+=(util-linux)

  for l in "${req[@]}"; do
    DEPS_MISSING+=("${l}")
    for n in $(pkg_names "${l}"); do DEPS_PKGS+=("${n}"); done
  done
  for l in "${opt[@]}"; do
    for n in $(pkg_names "${l}"); do DEPS_OPTIONAL+=("${n}"); done
  done
  if [[ "${FW_ACTION:-skip}" == "enable" ]]; then
    case "${FW_BACKEND:-}" in
      ufw) command -v ufw > /dev/null 2>&1 || DEPS_OPTIONAL+=(ufw) ;;
      firewalld) command -v firewall-cmd > /dev/null 2>&1 || DEPS_OPTIONAL+=(firewalld) ;;
    esac
  fi
  if [[ "${F2B_ACTION:-skip}" == "install" ]] && ! command -v fail2ban-client > /dev/null 2>&1; then
    DEPS_OPTIONAL+=(fail2ban)
  fi
  return 0
}

_pkg_refresh_checked() {
  local out rc=0 h
  out="$(mktemp "${WORK_DIR:-/tmp}/pkgref.XXXXXX")"
  retry 3 6 run_capture "${out}" _pkg_refresh_cmd || rc=1
  if ((rc != 0)); then
    log_error "Updating the package index failed (${PLAT_PM})"
    while IFS= read -r h; do log_error "  hint: ${h}"; done < <(pkg_hint "${out}")
    tail -n 6 "${out}" 2> /dev/null | redact_stream | while IFS= read -r h; do log_error "  | ${h}"; done
  fi
  rm -f -- "${out}"
  return "${rc}"
}

deps_install() {
  deps_compute_missing
  if ((${#DEPS_PKGS[@]} == 0)) && ((${#DEPS_OPTIONAL[@]} == 0)) && [[ "${MVN_PKG_UPGRADE}" != "1" ]]; then
    log_ok "All required packages are already installed"
    report_add "Dependencies" "OK" "no changes needed"
    return 0
  fi

  log_info "Updating the package index (${PLAT_PM})..."
  _pkg_refresh_checked || die "${EXIT_FAIL}" "Cannot update the package index. See the hints above and ${LOG_FILE}"

  if ((${#DEPS_PKGS[@]})); then
    log_info "Installing required packages: ${DEPS_PKGS[*]}"
    pkg_install_safe "${DEPS_PKGS[@]}" \
      || die "${EXIT_FAIL}" "Failed to install required packages: ${DEPS_PKGS[*]} (see the hints above and ${LOG_FILE})"
  fi

  # Recommended extras: never fatal. Firewall and fail2ban packages are handled by their own stages.
  local -a extras=() p
  for p in "${DEPS_OPTIONAL[@]}"; do
    case "${p}" in ufw | firewalld | fail2ban) ;; *) extras+=("${p}") ;; esac
  done
  if ((${#extras[@]})); then
    log_info "Installing recommended packages: ${extras[*]}"
    pkg_install_safe "${extras[@]}" || log_warn "Could not install: ${extras[*]} (continuing; related features may be limited)"
  fi

  if [[ "${MVN_PKG_UPGRADE}" == "1" ]]; then
    log_info "Running the optional full system upgrade (requested)..."
    retry 2 8 run_logged _pkg_upgrade_cmd || die "${EXIT_FAIL}" "The full system upgrade failed (see ${LOG_FILE})"
  fi

  if [[ -f /var/run/reboot-required ]]; then
    log_warn "The system reports that a reboot is required (kernel/library updates). MVN Deploy does not reboot the server."
  fi
  log_ok "Dependencies ready"
  report_add "Dependencies" "OK" "${DEPS_PKGS[*]:-none}${extras[*]:+; extras: ${extras[*]}}"
}

# deps_install_optional <command-to-check> <package...>: installs a firewall/fail2ban package.
# Returns 1 (and warns) on failure; the caller decides how to degrade.
deps_install_optional() {
  local cmd="$1"
  shift
  command -v "${cmd}" > /dev/null 2>&1 && return 0
  log_info "Installing: $*"
  if [[ "${PLAT_PM}" != "pacman" ]]; then _pkg_refresh_checked || true; fi
  pkg_install_safe "$@"
}
