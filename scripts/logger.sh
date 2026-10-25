#!/usr/bin/env bash
# shellcheck shell=bash
# logger.sh — unified console output and log file.

LOG_FILE=""
LOG_READY=0
MVN_WARNINGS=()

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_BOLD=$'\033[1m'
else
  C_RESET=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_BOLD=""
fi

# log_init: create the log directory/file with restricted permissions.
log_init() {
  LOG_FILE="${MVN_LOG_FILE:-/var/log/mvn-deploy/install.log}"
  if [[ "${MVN_DRY_RUN:-0}" == "1" ]]; then
    LOG_READY=0
    return 0
  fi # dry run: console only
  local dir
  dir="$(dirname -- "${LOG_FILE}")"
  # New directories are created 0700, the file 0600.
  if (
    umask 077
    mkdir -p -- "${dir}" && : >> "${LOG_FILE}"
  ) 2> /dev/null; then
    chmod 600 -- "${LOG_FILE}" 2> /dev/null || true
    LOG_READY=1
  else
    LOG_READY=0
    printf '%s[WARN]%s Cannot write log file %s; continuing without a log file\n' \
      "${C_YELLOW}" "${C_RESET}" "${LOG_FILE}" >&2
  fi
}

_strip_ansi() { sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g'; }

_log_write() { # level message
  [[ "${LOG_READY}" -eq 1 ]] || return 0
  local msg="${2//$'\033'/}"
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$1" "${msg}" >> "${LOG_FILE}" 2> /dev/null || true
}

log_info() {
  printf '%s[INFO]%s %s\n' "${C_BLUE}" "${C_RESET}" "$*"
  _log_write INFO "$*"
}
log_ok() {
  printf '%s[ OK ]%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"
  _log_write OK "$*"
}
log_warn() {
  printf '%s[WARN]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2
  _log_write WARN "$*"
  MVN_WARNINGS+=("$*")
}
log_error() {
  printf '%s[FAIL]%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2
  _log_write ERROR "$*"
}
log_step() {
  printf '\n%s== %s ==%s\n' "${C_BOLD}" "$*" "${C_RESET}"
  _log_write STEP "$*"
}
log_file_only() { _log_write "${2:-DEBUG}" "$1"; }

# run_logged <command...>: run a command; stdout/stderr go to the log file only.
# Never use it for commands whose output can contain secrets.
run_logged() {
  _log_write CMD "$*"
  local rc=0
  if [[ "${LOG_READY}" -eq 1 ]]; then
    "$@" >> "${LOG_FILE}" 2>&1 || rc=$?
  else
    "$@" > /dev/null 2>&1 || rc=$?
  fi
  return "${rc}"
}
