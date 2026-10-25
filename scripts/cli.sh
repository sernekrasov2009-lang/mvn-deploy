#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # globals are used by the scripts that source this file
# cli.sh — shared start-up for the maintenance commands (doctor, status, backup, restore).
# Everything here is read-only: it never aborts on an unsupported OS, because a diagnostic tool
# has to work on exactly the machines where something is wrong.

cli_init() {
  [[ "${EUID}" -eq 0 ]] || die "${EXIT_PRECOND}" "This command needs root: run it with sudo"
  load_user_config
  # shellcheck source=config/defaults.conf
  source "${ROOT}/config/defaults.conf"
  require_safe_dir MVN_INSTALL_DIR "${MVN_INSTALL_DIR}"
  require_safe_dir MVN_STATE_DIR "${MVN_STATE_DIR}"
  detect_interactivity
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    PLAT_ID="$(. /etc/os-release && printf '%s' "${ID:-}")"
    # shellcheck disable=SC1091
    PLAT_ID_LIKE="$(. /etc/os-release && printf '%s' "${ID_LIKE:-}")"
    # shellcheck disable=SC1091
    PLAT_VERSION="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
    # shellcheck disable=SC1091
    OS_PRETTY="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-${ID:-unknown}}")"
    plat_classify "${PLAT_ID}" "${PLAT_ID_LIKE}" "${PLAT_VERSION}"
  else
    OS_PRETTY="unknown"
  fi
  plat_detect_pm || true
  plat_detect_init
  ARCH="$(plat_map_arch "$(uname -m 2> /dev/null || true)")"
  return 0
}
