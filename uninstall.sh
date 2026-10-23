#!/usr/bin/env bash
# MVN Deploy — conservative uninstall. Removes only what MVN Deploy itself created.
# 3x-ui and its database are NEVER removed silently.
set -Eeuo pipefail
# Predictable environment: English tool output (we parse it), complete PATH (su without "-"), sane umask.
export LC_ALL=C LANG=C
export PATH="${PATH:+${PATH}:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
umask 022
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
for _m in logger common platform; do
  # shellcheck source=/dev/null
  source "${SELF_DIR}/scripts/${_m}.sh"
done
load_user_config                                  # same precedence as install.sh: environment > config file > defaults
# shellcheck source=config/defaults.conf
source "${SELF_DIR}/config/defaults.conf"
require_safe_dir MVN_INSTALL_DIR "${MVN_INSTALL_DIR}"
require_safe_dir MVN_STATE_DIR "${MVN_STATE_DIR}"

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
detect_interactivity
plat_detect_init
log_init

confirm() { ((YES)) && return 0; ask_yes_no "$1" n; }

main() {
  echo "MVN Deploy uninstall will:"
  echo "  - remove ${MVN_STATE_DIR}-tracked files: BBR sysctl/modules files created by MVN Deploy"
  echo "  - delete UFW/firewalld rules created by MVN Deploy EXCEPT SSH rules (removing them could lock you out)"
  echo "  - remove the fail2ban jail file created by MVN Deploy (the fail2ban package stays installed)"
  echo "  - keep UFW enabled state, 3x-ui, its database, its certificate and Xray untouched"
  confirm "Proceed?" || { echo "Aborted."; exit 3; }

  local f spec role
  for key in bbr_file bbr_modules_file; do
    f="$(state_get "${key}")"
    if [[ -n "${f}" && -f "${f}" ]]; then rm -f -- "${f}"; log_ok "Removed ${f}"; fi
  done
  if command -v sysctl > /dev/null 2>&1; then run_logged sysctl --system || true; fi
  log_info "Live BBR setting stays until the next reboot; nothing else was reverted."

  local jail="/etc/fail2ban/jail.d/mvn-deploy.local"
  if [[ -f "${jail}" && -n "$(state_get f2b_jail)" ]]; then
    rm -f -- "${jail}"
    if svc_active fail2ban; then run_logged svc_restart fail2ban || true; fi
    log_ok "Removed the fail2ban jail ${jail} (the fail2ban package was left installed)"
  fi

  if command -v firewall-cmd > /dev/null 2>&1; then
    local zone
    while read -r zone spec role; do
      [[ -n "${spec}" ]] || continue
      if [[ "${role}" == "ssh" ]]; then
        log_info "Keeping SSH rule ${spec}"
      else
        if firewall-cmd --state > /dev/null 2>&1; then
          run_logged firewall-cmd --permanent --zone="${zone}" --remove-port="${spec}" || true
          run_logged firewall-cmd --zone="${zone}" --remove-port="${spec}" || true
        else
          run_logged firewall-offline-cmd --zone="${zone}" --remove-port="${spec}" || true
        fi
        log_ok "Removed firewalld rule ${spec} (${role}, zone ${zone})"
        state_del firewalld_rule "${zone} ${spec} ${role}"
      fi
    done < <(state_list firewalld_rule)
  fi

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
    local b
    b="${MVN_BACKUP_DIR}/x-ui-data-$(date +%Y%m%d-%H%M%S).tar.gz"
    if [[ -d /etc/x-ui ]]; then
      ( umask 077; tar -czf "${b}" -C / etc/x-ui )
      log_ok "3x-ui data backed up to ${b} (root only)"
    fi
    echo "To remove 3x-ui itself run its own tool:  x-ui uninstall"
  else
    echo "3x-ui was left installed. To remove it later: sudo bash uninstall.sh --backup-xui, then run: x-ui uninstall"
  fi

  if confirm "Delete MVN Deploy's own files (${MVN_INSTALL_DIR}, ${MVN_STATE_DIR})? Logs are kept."; then
    rm -rf -- "${MVN_STATE_DIR}"
    if [[ "${SELF_DIR}" == "${MVN_INSTALL_DIR}" ]]; then cd /; fi
    rm -rf -- "${MVN_INSTALL_DIR}"
    log_ok "MVN Deploy files removed"
  fi
}
main
exit 0
