#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # globals are used by the scripts that source this file
# backup.sh — backup and restore of everything MVN Deploy and 3x-ui keep on disk:
#   /etc/x-ui (panel database, credentials file, our certificates), /etc/mvn-deploy (config),
#   the MVN Deploy state directory and the fail2ban jail file. Firewall rules are not included.
# Archives are root-only (mode 600) because they contain the panel database and credentials.

BACKUP_STOPPED=0
BACKUP_ONLINE=0
BACKUP_LAST=""

backup_state_rel() { printf '%s' "${MVN_STATE_DIR#/}"; }

backup_paths() { # relative paths that exist right now, one per line
  local p
  for p in etc/x-ui etc/mvn-deploy "$(backup_state_rel)" etc/fail2ban/jail.d/mvn-deploy.local; do
    [[ -e "/${p}" ]] && printf '%s\n' "${p}"
  done
  return 0
}

_backup_resume() {
  if ((BACKUP_STOPPED)); then
    svc_start x-ui > /dev/null 2>&1 || log_warn "x-ui could not be started again: run  systemctl start x-ui"
    BACKUP_STOPPED=0
  fi
}

# backup_create [label]: prints the archive path on success.
backup_create() {
  local label="${1:-}" stamp out stage rc=0
  local -a paths=()
  command -v tar > /dev/null 2>&1 || {
    log_error "tar is required for backups"
    return 1
  }
  mapfile -t paths < <(backup_paths)
  ((${#paths[@]})) || {
    log_error "Nothing to back up: neither 3x-ui nor MVN Deploy data was found"
    return 1
  }

  install -d -m 700 "${MVN_BACKUP_DIR}"
  stamp="$(date +%Y%m%d-%H%M%S)"
  out="${MVN_BACKUP_DIR}/mvn-backup-${stamp}${label:+-${label}}.tar.gz"
  stage="$(mktemp -d /tmp/mvn-backup.XXXXXX)"
  {
    printf 'created=%s\nhost=%s\nmvn_version=%s\nos=%s\npaths=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(hostname 2> /dev/null || echo unknown)" "${MVN_VERSION}" "${OS_PRETTY:-unknown}" "${paths[*]}"
  } > "${stage}/MANIFEST.txt"

  # A SQLite database is only consistent when the panel is not writing to it.
  if [[ "${BACKUP_ONLINE}" != "1" ]] && svc_active x-ui; then
    log_info "Stopping x-ui for a few seconds to get a consistent database copy (use --online to skip)"
    if svc_stop x-ui; then BACKUP_STOPPED=1; fi
  fi
  trap '_backup_resume' INT TERM
  (umask 077 && tar -czf "${out}" -C / "${paths[@]}" -C "${stage}" MANIFEST.txt) || rc=$?
  _backup_resume
  trap - INT TERM
  rm -rf -- "${stage}"
  if ((rc != 0)); then
    rm -f -- "${out}"
    log_error "Creating the backup failed (tar exit ${rc})"
    return 1
  fi
  chmod 600 -- "${out}"
  (cd "${MVN_BACKUP_DIR}" && sha256sum "$(basename "${out}")" > "$(basename "${out}").sha256")
  BACKUP_LAST="${out}"
  _backup_rotate
  log_ok "Backup created: ${out} ($(du -h "${out}" | cut -f1))"
  printf '%s\n' "${out}"
}

_backup_rotate() {
  local keep="${MVN_BACKUP_KEEP:-10}" f n=0
  [[ "${keep}" =~ ^[0-9]+$ ]] && ((keep >= 1)) || keep=10
  while IFS= read -r f; do
    n=$((n + 1))
    if ((n > keep)); then rm -f -- "${f}" "${f}.sha256"; fi
  done < <(ls -1t "${MVN_BACKUP_DIR}"/mvn-backup-*.tar.gz 2> /dev/null || true)
}

backup_list() {
  local f
  if ! compgen -G "${MVN_BACKUP_DIR}/mvn-backup-*.tar.gz" > /dev/null; then
    echo "No backups in ${MVN_BACKUP_DIR}"
    return 0
  fi
  while IFS= read -r f; do
    printf '%s  %s  %s\n' "$(date -r "${f}" '+%Y-%m-%d %H:%M')" "$(du -h "${f}" | cut -f1)" "${f}"
  done < <(ls -1t "${MVN_BACKUP_DIR}"/mvn-backup-*.tar.gz)
}

# backup_validate_archive <file>: refuse anything that could write outside our own paths.
BACKUP_REASON=""
backup_validate_archive() {
  local f="$1" name line allowed state_rel
  BACKUP_REASON=""
  [[ -f "${f}" ]] || {
    BACKUP_REASON="file not found"
    return 1
  }
  state_rel="$(backup_state_rel)"
  allowed="^(etc/x-ui|etc/mvn-deploy|${state_rel}|etc/fail2ban/jail\\.d/mvn-deploy\\.local)(/.*)?$"
  tar -tzf "${f}" > /dev/null 2>&1 || {
    BACKUP_REASON="not a readable .tar.gz archive"
    return 1
  }
  while IFS= read -r line; do
    case "${line:0:1}" in
      - | d) ;;
      *)
        BACKUP_REASON="contains links or special files"
        return 1
        ;;
    esac
  done < <(tar -tvzf "${f}" 2> /dev/null || echo "x unreadable")
  while IFS= read -r name; do
    name="${name#./}"
    [[ -n "${name}" ]] || continue
    if [[ "${name}" == /* || "${name}" == *..* ]]; then
      BACKUP_REASON="unsafe path: ${name}"
      return 1
    fi
    if [[ "${name}" == "MANIFEST.txt" ]]; then continue; fi
    if [[ ! "${name}" =~ ${allowed} ]]; then
      BACKUP_REASON="unexpected path: ${name}"
      return 1
    fi
  done < <(tar -tzf "${f}")
  return 0
}

# backup_restore <file> <assume-yes>
backup_restore() {
  local f="$1" yes="${2:-0}"
  if ! backup_validate_archive "${f}"; then
    log_error "Refusing to restore ${f}: ${BACKUP_REASON}"
    return 1
  fi
  echo "Backup: ${f}"
  tar -xzOf "${f}" MANIFEST.txt 2> /dev/null | sed 's/^/  /' || true
  if [[ "${yes}" != "1" ]]; then
    if is_noninteractive; then
      log_error "Restore replaces the current panel data. Re-run with --yes to confirm in unattended mode."
      return 1
    fi
    ask_yes_no "Replace the current 3x-ui data and MVN Deploy settings with this backup?" n || {
      echo "Aborted."
      return 3
    }
  fi
  log_info "Saving the current state first (label: pre-restore)"
  backup_create pre-restore > /dev/null || {
    log_error "Could not create the safety backup; nothing was changed"
    return 1
  }

  local was_active=0
  if svc_active x-ui; then
    was_active=1
    svc_stop x-ui || true
  fi
  local rc=0
  tar -xzf "${f}" -C / --no-same-owner --exclude=MANIFEST.txt || rc=$?
  [[ -f "${XUI_RESULT_FILE}" ]] && chmod 600 -- "${XUI_RESULT_FILE}"
  if ((was_active)) || svc_exists x-ui; then svc_start x-ui || log_warn "x-ui did not start: check  systemctl status x-ui"; fi
  if [[ -f /etc/fail2ban/jail.d/mvn-deploy.local ]] && svc_active fail2ban; then svc_restart fail2ban || true; fi
  if ((rc != 0)); then
    log_error "Extraction reported errors (tar exit ${rc}); the pre-restore backup is in ${MVN_BACKUP_DIR}"
    return 1
  fi
  log_ok "Restore finished. Firewall rules are not part of a backup: run  mvn-deploy doctor  to check ports."
}
