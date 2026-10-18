#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # globals are used by the scripts that source this file
# security.sh — minimal, safe, reversible hardening of MVN Deploy's own footprint.
# It deliberately does NOT touch sshd (port, root login, password auth) or reboot.

sec_prepare() {
  state_init
  WORK_DIR="$(mktemp -d /tmp/mvn-deploy.XXXXXX)"   # mode 0700

  # Keep a persistent copy of the project so update.sh / uninstall.sh work later.
  require_safe_dir MVN_INSTALL_DIR "${MVN_INSTALL_DIR}"
  if [[ "${SELF_DIR}" != "${MVN_INSTALL_DIR}" ]]; then
    local new="${MVN_INSTALL_DIR}.new.$$"
    rm -rf -- "${new}"
    mkdir -p -- "${new}"
    cp -a -- "${SELF_DIR}/." "${new}/"
    rm -rf -- "${new}/.git"
    chmod 755 -- "${new}"
    rm -rf -- "${MVN_INSTALL_DIR}"
    mv -- "${new}" "${MVN_INSTALL_DIR}"
    log_file_only "Project copy installed to ${MVN_INSTALL_DIR}"
  fi
  state_set version "${MVN_VERSION}"
  log_ok "Working directories prepared (log and state are root-only)"
  report_add "Security prep" "OK" "root-only log/state, project copy in ${MVN_INSTALL_DIR}"
}

# sec_protect_secrets: tighten permissions of files that hold credentials.
sec_protect_secrets() {
  if [[ -f "${XUI_RESULT_FILE}" ]]; then
    chown root:root -- "${XUI_RESULT_FILE}" 2> /dev/null || true
    chmod 600 -- "${XUI_RESULT_FILE}"
  fi
}
