#!/usr/bin/env bash
# MVN Deploy — update MVN Deploy's OWN files to a chosen release.
# It does not update 3x-ui/Xray (use 3x-ui's own mechanism) and never touches 3x-ui data.
set -Eeuo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
for _m in logger common; do
  # shellcheck source=/dev/null
  source "${SELF_DIR}/scripts/${_m}.sh"
done
# shellcheck source=config/defaults.conf
source "${SELF_DIR}/config/defaults.conf"

main() {
  local ref="${MVN_REF:-}" check=0
  while (($#)); do
    case "$1" in
      --ref) ref="${2:?--ref needs a value}"; shift ;;
      --check) check=1 ;;
      -h | --help) echo "Usage: sudo bash update.sh --ref vX.Y.Z [--check]"; return 0 ;;
      *) echo "Unknown option: $1" >&2; return 2 ;;
    esac
    shift
  done
  [[ "${EUID}" -eq 0 ]] || { echo "Run as root: sudo bash update.sh" >&2; return 2; }
  [[ -n "${ref}" ]] || { echo "Specify the target release: --ref vX.Y.Z" >&2; return 2; }
  [[ -f "${MVN_INSTALL_DIR}/install.sh" ]] || { echo "MVN Deploy is not installed in ${MVN_INSTALL_DIR}; run install.sh first." >&2; return 2; }
  log_init

  local tmp new_ver old_ver="${MVN_VERSION}"
  tmp="$(mktemp -d /tmp/mvn-deploy-upd.XXXXXX)"
  trap 'rm -rf -- "${tmp}"' EXIT
  bash "${MVN_INSTALL_DIR}/install.sh" --fetch-only "${tmp}/new" --ref "${ref}"   # verifies the checksum
  new_ver="$(sed -n 's/^MVN_VERSION="\(.*\)"$/\1/p' "${tmp}/new/config/defaults.conf" | head -n 1)"
  [[ -n "${new_ver}" ]] || { log_error "Cannot read the version of the downloaded release"; return 1; }
  log_info "Installed: ${old_ver}  ->  target: ${new_ver} (${ref})"
  if ((check)); then log_info "Check only: nothing changed."; return 0; fi

  ( umask 077; mkdir -p -- "${MVN_BACKUP_DIR}" )
  chmod 700 -- "${MVN_BACKUP_DIR}"
  local b="${MVN_BACKUP_DIR}/mvn-deploy-${old_ver}-$(date +%Y%m%d-%H%M%S).tar.gz"
  ( umask 077; tar -czf "${b}" -C "$(dirname -- "${MVN_INSTALL_DIR}")" "$(basename -- "${MVN_INSTALL_DIR}")" )
  [[ -f /etc/mvn-deploy/mvn-deploy.conf ]] && cp -a /etc/mvn-deploy/mvn-deploy.conf "${MVN_BACKUP_DIR}/mvn-deploy.conf.$(date +%Y%m%d-%H%M%S)"
  log_ok "Backup of the current version: ${b}"

  rm -rf -- "${MVN_INSTALL_DIR}.old"
  mv -- "${MVN_INSTALL_DIR}" "${MVN_INSTALL_DIR}.old"
  mv -- "${tmp}/new" "${MVN_INSTALL_DIR}"
  chmod 755 -- "${MVN_INSTALL_DIR}"
  rm -rf -- "${MVN_INSTALL_DIR}.old"
  state_set version "${new_ver}"
  log_ok "MVN Deploy updated to ${new_ver}. 3x-ui and its data were not touched."
}
main "$@"
exit $?
