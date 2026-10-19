#!/usr/bin/env bash
# shellcheck shell=bash
# dependencies.sh — install only the system packages MVN Deploy needs.

DEPS_MISSING=()
APT_OPTS=(-q -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

_pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2> /dev/null | has_match 'install ok installed'; }

# deps_compute_missing: read-only; fills DEPS_MISSING.
deps_compute_missing() {
  local -a want=(ca-certificates curl tar openssl iproute2 procps kmod util-linux)
  if [[ "${FW_ACTION:-skip}" == "ufw-enable" ]]; then want+=(ufw); fi
  if [[ "${F2B_ACTION:-skip}" == "install" ]]; then want+=(fail2ban python3-systemd); fi
  DEPS_MISSING=()
  local p
  for p in "${want[@]}"; do
    _pkg_installed "${p}" || DEPS_MISSING+=("${p}")
  done
}

_apt() { DEBIAN_FRONTEND=noninteractive apt-get "$@"; }

deps_install() {
  deps_compute_missing
  if ((${#DEPS_MISSING[@]} == 0)) && [[ "${MVN_APT_UPGRADE}" != "1" ]]; then
    log_ok "All required packages are already installed"
    report_add "Dependencies" "OK" "no changes needed"
    return 0
  fi

  log_info "Updating package index..."
  retry 3 5 run_logged _apt update "${APT_OPTS[@]}" || die "${EXIT_FAIL}" "apt-get update failed (see ${LOG_FILE})"

  if ((${#DEPS_MISSING[@]})); then
    log_info "Installing: ${DEPS_MISSING[*]}"
    run_logged _apt install -y "${APT_OPTS[@]}" "${DEPS_MISSING[@]}" \
      || die "${EXIT_FAIL}" "Failed to install required packages: ${DEPS_MISSING[*]}"
  fi

  if [[ "${MVN_APT_UPGRADE}" == "1" ]]; then
    log_info "Running optional full package upgrade (requested)..."
    run_logged _apt upgrade -y "${APT_OPTS[@]}" || die "${EXIT_FAIL}" "apt-get upgrade failed"
  fi

  if [[ -f /var/run/reboot-required ]]; then
    log_warn "The system reports that a reboot is required (kernel/library updates). MVN Deploy does not reboot the server."
  fi
  log_ok "Dependencies ready"
  report_add "Dependencies" "OK" "${DEPS_MISSING[*]:-upgrade only}"
}
