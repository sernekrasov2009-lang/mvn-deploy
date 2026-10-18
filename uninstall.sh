#!/usr/bin/env bash
# MVN Deploy — conservative uninstall. Removes only what MVN Deploy itself created.
# 3x-ui and its database are NEVER removed silently.
set -Eeuo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
for _m in logger common; do
  # shellcheck source=/dev/null
  source "${SELF_DIR}/scripts/${_m}.sh"
done
# shellcheck source=config/defaults.conf
source "${SELF_DIR}/config/defaults.conf"

REMOVE_XUI=0
YES=0
for a in "$@"; do
  case "${a}" in
    --backup-xui) REMOVE_XUI=1 ;;
    -y | --yes) YES=1 ;;
    -h | --help)
      cat << 'USAGE'
Usage: sudo bash uninstall.sh [--yes] [--backup-xui]
  (default)     remove MVN Deploy's sysctl/modules files and its non-SSH UFW rules,
                then its own files. SSH rules, UFW itself and 3x-ui are kept.
  --backup-xui  additionally back up the 3x-ui data (/etc/x-ui) and show how to remove
                3x-ui with its own tool. It does NOT uninstall 3x-ui by itself.
USAGE
      exit 0 ;;
    *) echo "Unknown option: ${a}" >&2; exit 2 ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || { echo "Run as root: sudo bash uninstall.sh" >&2; exit 2; }
log_init

confirm() { ((YES)) && return 0; ask_yes_no "$1" n; }

main() {
  echo "MVN Deploy uninstall will:"
  echo "  - remove ${MVN_STATE_DIR}-tracked files: BBR sysctl/modules files created by MVN Deploy"
  echo "  - delete UFW rules created by MVN Deploy EXCEPT SSH rules (removing them could lock you out)"
  echo "  - keep UFW enabled state, 3x-ui, its database and Xray untouched"
  confirm "Proceed?" || { echo "Aborted."; exit 3; }

  local f spec role
  for key in bbr_file bbr_modules_file; do
    f="$(state_get "${key}")"
    if [[ -n "${f}" && -f "${f}" ]]; then rm -f -- "${f}"; log_ok "Removed ${f}"; fi
  done
  if command -v sysctl > /dev/null 2>&1; then run_logged sysctl --system || true; fi
  log_info "Live BBR setting stays until the next reboot; nothing else was reverted."

  if command -v ufw > /dev/null 2>&1; then
    while read -r spec role; do
      [[ -n "${spec}" ]] || continue
      if [[ "${role}" == "ssh" ]]; then
        log_info "Keeping SSH rule ${spec}"
      else
        run_logged ufw delete allow "${spec}" && log_ok "Removed UFW rule ${spec} (${role})" || log_warn "Could not remove UFW rule ${spec}"
        state_del ufw_rule "${spec} ${role}"
      fi
    done < <(state_list ufw_rule)
  fi

  if ((REMOVE_XUI)); then
    ( umask 077; mkdir -p -- "${MVN_BACKUP_DIR}" )
    chmod 700 -- "${MVN_BACKUP_DIR}"
    local b="${MVN_BACKUP_DIR}/x-ui-data-$(date +%Y%m%d-%H%M%S).tar.gz"
    if [[ -d /etc/x-ui ]]; then
      ( umask 077; tar -czf "${b}" -C / etc/x-ui )
      log_ok "3x-ui data backed up to ${b} (root only)"
    fi
    echo "To remove 3x-ui itself run its own tool:  x-ui uninstall"
  else
    echo "3x-ui was left installed. To remove it later: sudo bash uninstall.sh --backup-xui, then run: x-ui uninstall"
  fi

  if confirm "Delete MVN Deploy's own files (${MVN_INSTALL_DIR}, ${MVN_STATE_DIR})? Logs are kept."; then
    local keep_dir="${SELF_DIR}"
    rm -rf -- "${MVN_STATE_DIR}"
    [[ "${keep_dir}" == "${MVN_INSTALL_DIR}" ]] && { cd /; rm -rf -- "${MVN_INSTALL_DIR}"; }
    log_ok "MVN Deploy files removed"
  fi
}
main
exit 0
