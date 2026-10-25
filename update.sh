#!/usr/bin/env bash
# MVN Deploy — update MVN Deploy's OWN files to a chosen release.
# It does not update 3x-ui/Xray (use 3x-ui's own mechanism) and never touches 3x-ui data.
# shellcheck disable=SC2034  # BACKUP_ONLINE is read by the sourced backup module
set -Eeuo pipefail
# Predictable environment: English tool output (we parse it), complete PATH (su without "-"), sane umask.
export LC_ALL=C LANG=C
export PATH="${PATH:+${PATH}:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
umask 022
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
for _m in logger common platform backup; do
  # shellcheck source=/dev/null
  source "${SELF_DIR}/scripts/${_m}.sh"
done
load_user_config # same precedence as install.sh: environment > config file > defaults
# shellcheck source=config/defaults.conf
source "${SELF_DIR}/config/defaults.conf"
require_safe_dir MVN_INSTALL_DIR "${MVN_INSTALL_DIR}"

UPD_TMP=""
cleanup_upd() {
  if [[ -n "${UPD_TMP}" ]]; then rm -rf -- "${UPD_TMP}"; fi
  return 0
}
trap cleanup_upd EXIT

main() {
  local ref="${MVN_REF:-}" check=0
  while (($#)); do
    case "$1" in
      --ref)
        ref="${2:?--ref needs a value}"
        shift
        ;;
      --check) check=1 ;;
      -h | --help)
        echo "Usage: sudo bash update.sh --ref vX.Y.Z [--check]"
        return 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        return 2
        ;;
    esac
    shift
  done
  [[ "${EUID}" -eq 0 ]] || {
    echo "Run as root: sudo bash update.sh" >&2
    return 2
  }
  [[ -n "${ref}" ]] || {
    echo "Specify the target release: --ref vX.Y.Z" >&2
    return 2
  }
  [[ -f "${MVN_INSTALL_DIR}/install.sh" ]] || {
    echo "MVN Deploy is not installed in ${MVN_INSTALL_DIR}; run install.sh first." >&2
    return 2
  }
  log_init

  local new_ver old_ver="${MVN_VERSION}"
  UPD_TMP="$(mktemp -d /tmp/mvn-deploy-upd.XXXXXX)"
  bash "${MVN_INSTALL_DIR}/install.sh" --fetch-only "${UPD_TMP}/new" --ref "${ref}" # verifies the checksum
  new_ver="$(sed -n 's/^MVN_VERSION="\(.*\)"$/\1/p' "${UPD_TMP}/new/config/defaults.conf" | head -n 1)"
  [[ -n "${new_ver}" ]] || {
    log_error "Cannot read the version of the downloaded release"
    return 1
  }
  log_info "Installed: ${old_ver}  ->  target: ${new_ver} (${ref})"
  if ((check)); then
    log_info "Check only: nothing changed."
    return 0
  fi

  (
    umask 077
    mkdir -p -- "${MVN_BACKUP_DIR}"
  )
  chmod 700 -- "${MVN_BACKUP_DIR}"
  local stamp b
  stamp="$(date +%Y%m%d-%H%M%S)"
  b="${MVN_BACKUP_DIR}/mvn-deploy-${old_ver}-${stamp}.tar.gz"
  (
    umask 077
    tar -czf "${b}" -C "$(dirname -- "${MVN_INSTALL_DIR}")" "$(basename -- "${MVN_INSTALL_DIR}")"
  )
  if [[ -f /etc/mvn-deploy/mvn-deploy.conf ]]; then cp -a /etc/mvn-deploy/mvn-deploy.conf "${MVN_BACKUP_DIR}/mvn-deploy.conf.${stamp}"; fi
  log_ok "Backup of the current version: ${b}"
  # Panel data too (database, certificates, settings): a failure here is a warning, never a stop.
  plat_detect_init
  if [[ -d /etc/x-ui ]]; then
    BACKUP_ONLINE=1 # read by backup_create (sourced module)
    backup_create pre-update > /dev/null || log_warn "Could not back up the panel data before the update; continuing"
  fi

  rm -rf -- "${MVN_INSTALL_DIR}.old"
  mv -- "${MVN_INSTALL_DIR}" "${MVN_INSTALL_DIR}.old"
  if ! mv -- "${UPD_TMP}/new" "${MVN_INSTALL_DIR}"; then
    mv -- "${MVN_INSTALL_DIR}.old" "${MVN_INSTALL_DIR}"
    log_error "Could not put the new version in place; the previous version was restored"
    return 1
  fi
  chmod 755 -- "${MVN_INSTALL_DIR}"
  rm -rf -- "${MVN_INSTALL_DIR}.old"
  state_set version "${new_ver}"
  log_ok "MVN Deploy updated to ${new_ver}. 3x-ui and its data were not touched."
}
main "$@"
exit $?
