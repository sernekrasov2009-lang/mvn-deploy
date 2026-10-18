#!/usr/bin/env bash
# shellcheck shell=bash
# common.sh — helpers shared by all modules: errors, prompts, state, ports, report.
# shellcheck disable=SC2034  # globals here are used by the scripts that source this file

EXIT_FAIL=1       # a stage failed
EXIT_PRECOND=2    # unsupported/invalid environment, nothing was changed
EXIT_ABORT=3      # a decision is needed (or the user declined)

WORK_DIR=""
REPORT_ROWS=()

die() { local code="$1"; shift; log_error "$*"; exit "${code}"; }

cleanup_work_dir() {
  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    rm -rf -- "${WORK_DIR}"
  fi
}

# ---------- interactivity ----------
is_noninteractive() { [[ "${MVN_NONINTERACTIVE:-0}" == "1" ]]; }

detect_interactivity() {
  if [[ "${MVN_NONINTERACTIVE:-0}" != "1" ]]; then
    if ! ( : < /dev/tty ) 2> /dev/null; then
      MVN_NONINTERACTIVE=1
    fi
  fi
}

# ask_yes_no "question" [y|n]  — returns 0 for yes. Unattended: returns the default.
ask_yes_no() {
  local q="$1" def="${2:-n}" ans hint="[y/N]"
  [[ "${def}" == "y" ]] && hint="[Y/n]"
  if is_noninteractive; then [[ "${def}" == "y" ]]; return; fi
  read -r -p "${q} ${hint} " ans < /dev/tty || ans=""
  ans="${ans:-${def}}"
  [[ "${ans}" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ask_value "prompt" [default]  — prints the answer. Unattended: prints the default.
ask_value() {
  local q="$1" def="${2:-}" ans
  if is_noninteractive; then printf '%s' "${def}"; return 0; fi
  read -r -p "${q}${def:+ [${def}]}: " ans < /dev/tty || ans=""
  printf '%s' "${ans:-${def}}"
}

# need_confirm "question" "hint for unattended mode" — 0 = proceed.
need_confirm() {
  local q="$1" hint="$2"
  if [[ "${MVN_DRY_RUN:-0}" == "1" ]]; then
    log_warn "A real run would need a decision: ${q} (${hint})"
    return 0
  fi
  if is_noninteractive; then
    log_error "${q} — unattended mode cannot decide. ${hint}"
    return 1
  fi
  ask_yes_no "${q}" n
}

# retry <attempts> <delay-seconds> <command...>
retry() {
  local n="$1" d="$2" i rc=0
  shift 2
  for ((i = 1; i <= n; i++)); do
    "$@" && return 0
    rc=$?
    if ((i < n)); then
      log_warn "Attempt ${i}/${n} failed: $1 ...; retrying in ${d}s"
      sleep "${d}"
    fi
  done
  return "${rc}"
}

# ---------- directory safety ----------
# Directories that MVN Deploy deletes with rm -rf must be absolute, at least two levels deep,
# free of "..", and named after the project. This protects against a mistyped config value
# such as MVN_INSTALL_DIR=/usr.
safe_dir_ok() { # path
  local p="${1:-}"
  [[ "${p}" =~ ^/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$ ]] && [[ "${p}" != *..* ]] && [[ "${p##*/}" == *mvn-deploy* ]]
}

require_safe_dir() { # label path
  safe_dir_ok "${2:-}" \
    || die "${EXIT_PRECOND}" "$1 must be an absolute path (2+ levels) whose last part contains 'mvn-deploy'; got '${2:-}'"
}

# ---------- locking ----------
acquire_lock() {
  # A dry run must not create anything on the system.
  if [[ "${MVN_DRY_RUN:-0}" == "1" ]]; then return 0; fi
  mkdir -p "$(dirname -- "${MVN_LOCK_FILE}")" 2> /dev/null || true
  exec 9> "${MVN_LOCK_FILE}" || die "${EXIT_PRECOND}" "Cannot open lock file ${MVN_LOCK_FILE}"
  flock -n 9 || die "${EXIT_FAIL}" "Another MVN Deploy run is in progress (lock: ${MVN_LOCK_FILE})"
}

# ---------- state (root-only key=value file) ----------
state_file() { printf '%s/state' "${MVN_STATE_DIR}"; }

state_init() {
  ( umask 077; mkdir -p -- "${MVN_STATE_DIR}"; [[ -f "${MVN_STATE_DIR}/state" ]] || : > "${MVN_STATE_DIR}/state" )
  chmod 700 -- "${MVN_STATE_DIR}"
  chmod 600 -- "${MVN_STATE_DIR}/state"
}

state_get() { # key
  local f; f="$(state_file)"
  [[ -f "${f}" ]] || return 0
  sed -n "s/^${1}=//p" "${f}" | tail -n 1
}

state_list() { # key  -> all values
  local f; f="$(state_file)"
  [[ -f "${f}" ]] || return 0
  sed -n "s/^${1}=//p" "${f}"
}

state_set() { # key value (replaces)
  local f tmp; f="$(state_file)"
  state_init
  tmp="$(mktemp "${MVN_STATE_DIR}/.state.XXXXXX")"
  { grep -v "^${1}=" "${f}" || true; printf '%s=%s\n' "$1" "$2"; } > "${tmp}"
  chmod 600 -- "${tmp}"
  mv -f -- "${tmp}" "${f}"
}

state_add() { # key value (appends if the exact pair is absent)
  local f; f="$(state_file)"
  state_init
  grep -qxF "${1}=${2}" "${f}" || printf '%s=%s\n' "$1" "$2" >> "${f}"
}

state_del() { # key value
  local f tmp; f="$(state_file)"
  [[ -f "${f}" ]] || return 0
  tmp="$(mktemp "${MVN_STATE_DIR}/.state.XXXXXX")"
  { grep -vxF "${1}=${2}" "${f}" || true; } > "${tmp}"
  chmod 600 -- "${tmp}"
  mv -f -- "${tmp}" "${f}"
}

# ---------- ports ----------
valid_port() { [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }

valid_port_spec() { # N or A:B
  local s="${1:-}" a b
  [[ "${s}" =~ ^[0-9]+(:[0-9]+)?$ ]] || return 1
  if [[ "${s}" == *:* ]]; then
    a="${s%%:*}"; b="${s##*:}"
    valid_port "${a}" && valid_port "${b}" && ((10#${a} < 10#${b}))
  else
    valid_port "${s}"
  fi
}

# parse_port_list <out-array-name> "<comma/space separated>" — validates, de-duplicates.
parse_port_list() {
  local -n _pl_out="$1"
  local raw="${2//,/ }" tok x dup
  local -a toks=()
  _pl_out=()
  read -r -a toks <<< "${raw}"
  for tok in "${toks[@]}"; do
    valid_port_spec "${tok}" || { log_error "Invalid port or port range: '${tok}'"; return 1; }
    dup=0
    for x in "${_pl_out[@]}"; do [[ "${x}" == "${tok}" ]] && dup=1; done
    [[ "${dup}" -eq 1 ]] || _pl_out+=("${tok}")
  done
  return 0
}

array_contains() { # needle elements...
  local n="$1" e; shift
  for e in "$@"; do [[ "${e}" == "${n}" ]] && return 0; done
  return 1
}

# ---------- parsing / secrets ----------
# kv_get <file> <KEY>  — reads KEY=VALUE without sourcing the file.
kv_get() {
  local f="$1" k="$2" v
  [[ -r "${f}" ]] || return 1
  v="$(sed -n "s/^${k}=//p" "${f}" | head -n 1)"
  v="${v#\'}"; v="${v%\'}"; v="${v#\"}"; v="${v%\"}"; v="${v//\\/}"
  printf '%s' "${v}"
}

# redact_stream: filter that strips ANSI codes and masks credential-looking lines.
redact_stream() {
  sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g; s/((user(name)?|pass(word)?|token|secret|key|access url|dsn)[^:=]*[:=][[:space:]]*).*/\1[redacted]/I'
}

# load_user_config: parse /etc/mvn-deploy/mvn-deploy.conf safely. Environment wins.
load_user_config() {
  local f="${MVN_CONFIG_FILE:-/etc/mvn-deploy/mvn-deploy.conf}" line key val owner mode
  [[ -f "${f}" ]] || return 0
  owner="$(stat -c '%u' "${f}")"; mode="$(stat -c '%a' "${f}")"
  if [[ "${owner}" != "0" ]] || ((8#${mode} & 8#022)); then
    die "${EXIT_PRECOND}" "Config ${f} must be owned by root and not group/world-writable"
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "${line}" ]] && continue
    if [[ ! "${line}" =~ ^(MVN_[A-Z0-9_]+)=(.*)$ ]]; then
      die "${EXIT_PRECOND}" "Invalid line in ${f}: only MVN_NAME=value is allowed"
    fi
    key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    val="${val#\"}"; val="${val%\"}"; val="${val#\'}"; val="${val%\'}"
    if [[ ! "${val}" =~ ^[A-Za-z0-9._:/,@\ -]*$ ]]; then
      die "${EXIT_PRECOND}" "Unsafe characters in value of ${key} in ${f}"
    fi
    if [[ -z "${!key+x}" ]]; then printf -v "${key}" '%s' "${val}"; fi
  done < "${f}"
}

# ---------- final report ----------
report_add() { REPORT_ROWS+=("$1|$2|$3"); } # stage|status|detail

report_print() {
  local row stage status detail color
  printf '\n%-18s %-12s %s\n' "STAGE" "STATUS" "DETAIL"
  for row in "${REPORT_ROWS[@]}"; do
    IFS='|' read -r stage status detail <<< "${row}"
    case "${status}" in
      OK) color="${C_GREEN}" ;;
      FAILED) color="${C_RED}" ;;
      *) color="${C_YELLOW}" ;;
    esac
    printf '%-18s %s%-12s%s %s\n' "${stage}" "${color}" "${status}" "${C_RESET}" "${detail}"
  done
}

# has_match <grep-args...>: like `grep -q`, but reads ALL of stdin. Plain `grep -q` exits
# early, which can SIGPIPE the producer and fail the pipeline under `set -o pipefail`.
has_match() { local out; out="$(grep "$@" || true)"; [[ -n "${out}" ]]; }
