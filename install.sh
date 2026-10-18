#!/usr/bin/env bash
#
# MVN Deploy — one-command VPN server deployment (official 3x-ui + UFW + BBR).
# https://github.com/sernekrasov2009-lang/mvn-deploy
#
# Pinned release (recommended):
#   curl -fsSL https://raw.githubusercontent.com/sernekrasov2009-lang/mvn-deploy/v1.0.0/install.sh -o /tmp/mvn-deploy-install.sh && sudo bash /tmp/mvn-deploy-install.sh
# Development (mutable main, unverified; needs MVN_ALLOW_DEV=1):
#   sudo MVN_ALLOW_DEV=1 bash /tmp/mvn-deploy-install.sh
#
set -Eeuo pipefail

MVN_REPO="sernekrasov2009-lang/mvn-deploy"
# Release tags set this to their own tag (vX.Y.Z); during development it is "main".
MVN_PINNED_REF="main"

# ============================================================================
# Bootstrap layer — self-contained: must work when install.sh is a single file.
# ============================================================================
_b_say() { printf '[mvn-deploy] %s\n' "$*"; }
_b_die() { printf '[mvn-deploy] ERROR: %s\n' "$*" >&2; exit 2; }
_b_has_match() { local o; o="$(grep "$@" || true)"; [[ -n "${o}" ]]; }

usage() {
  cat << 'USAGE'
MVN Deploy — prepares a clean Debian/Ubuntu VPS: official 3x-ui, UFW, BBR, checks.

Usage: sudo bash install.sh [options]

  -y, --yes, --non-interactive   never prompt; ambiguous/dangerous situations abort
      --dry-run, --plan          run checks and print the plan; change nothing
      --ref <tag|branch>         project version to download when bootstrapping
      --config <file>            user config (MVN_NAME=value lines)
      --fetch-only <dir>         download+verify the project into <dir> and exit
  -h, --help                     show this help

Environment (also usable in /etc/mvn-deploy/mvn-deploy.conf): see docs/INSTALL.md
  MVN_FIREWALL=auto|skip  MVN_SSH_PORTS  MVN_EXTRA_TCP_PORTS  MVN_EXTRA_UDP_PORTS
  MVN_BBR=auto|skip  MVN_XUI_VERSION  MVN_XUI_SSL_MODE=none|ip|domain  MVN_XUI_DOMAIN
  MVN_ALLOW_CONFLICTS=1  MVN_APT_UPGRADE=1  MVN_FORCE_XUI_REINSTALL=1
  MVN_SHA256 (release archive checksum)  MVN_ALLOW_DEV=1 (allow unverified branch)
USAGE
}

_self_dir() {
  local src="${BASH_SOURCE[0]:-}"
  [[ -n "${src}" && -f "${src}" ]] || return 1
  (cd -- "$(dirname -- "${src}")" && pwd -P)
}

_b_http_get() { # url dest
  if command -v curl > /dev/null 2>&1; then
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 -o "$2" "$1"
  elif command -v wget > /dev/null 2>&1; then
    wget -q --tries=3 --timeout=30 -O "$2" "$1"
  else
    return 127
  fi
}

_b_ensure_downloader() {
  command -v curl > /dev/null 2>&1 && return 0
  command -v wget > /dev/null 2>&1 && return 0
  [[ "${EUID}" -eq 0 ]] || _b_die "curl or wget is required (and root to install it)"
  command -v apt-get > /dev/null 2>&1 || _b_die "curl or wget is required"
  _b_say "Installing curl..."
  DEBIAN_FRONTEND=noninteractive apt-get update -q > /dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q ca-certificates curl > /dev/null
}

_b_confirm() { # question
  ( : < /dev/tty ) 2> /dev/null || return 1
  local a=""
  read -r -p "$1 [y/N] " a < /dev/tty || return 1
  [[ "${a}" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# _b_fetch_project <ref> <dest-dir>
_b_fetch_project() {
  local ref="$1" dest="$2" mode url tmp archive expected actual
  [[ "${ref}" =~ ^[A-Za-z0-9._/-]+$ && "${ref}" != *..* ]] || _b_die "Invalid ref: ${ref}"
  _b_ensure_downloader
  tmp="$(mktemp -d /tmp/mvn-deploy-dl.XXXXXX)"
  archive="${tmp}/project.tar.gz"

  if [[ "${ref}" =~ ^v[0-9]+(\.[0-9]+)*([-.][0-9A-Za-z.]+)?$ ]]; then
    mode="release"
    url="https://github.com/${MVN_REPO}/releases/download/${ref}/mvn-deploy-${ref}.tar.gz"
    _b_say "Downloading release ${ref}..."
    _b_http_get "${url}" "${archive}" || { rm -rf "${tmp}"; _b_die "Cannot download ${url}"; }
    expected="${MVN_SHA256:-}"
    if [[ -z "${expected}" ]]; then
      _b_http_get "${url}.sha256" "${tmp}/sum" || { rm -rf "${tmp}"; _b_die "Cannot download checksum ${url}.sha256"; }
      expected="$(awk '{print $1; exit}' "${tmp}/sum")"
    fi
    [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || { rm -rf "${tmp}"; _b_die "Checksum is missing or malformed"; }
  else
    mode="dev"
    if [[ "${MVN_ALLOW_DEV:-0}" != "1" ]]; then
      _b_say "Ref '${ref}' is a mutable branch, not a verified release."
      _b_confirm "Run unverified code as root from branch '${ref}'?" || _b_die "Aborted. Use a release tag, or set MVN_ALLOW_DEV=1."
    fi
    url="https://github.com/${MVN_REPO}/archive/refs/heads/${ref}.tar.gz"
    _b_say "Downloading branch ${ref} (UNVERIFIED)..."
    _b_http_get "${url}" "${archive}" || { rm -rf "${tmp}"; _b_die "Cannot download ${url}"; }
    expected="${MVN_SHA256:-}"
  fi

  if [[ -n "${expected}" ]]; then
    actual="$(sha256sum "${archive}" | awk '{print $1}')"
    if [[ "${actual}" != "${expected}" ]]; then
      rm -rf "${tmp}"
      _b_die "Checksum mismatch (expected ${expected}, got ${actual}). Archive was NOT executed."
    fi
    _b_say "Checksum verified."
  elif [[ "${mode}" == "dev" ]]; then
    _b_say "WARNING: no checksum verification in development mode."
  fi

  if tar -tzf "${archive}" 2> /dev/null | _b_has_match -E '(^/|(^|/)\.\.(/|$))'; then
    rm -rf "${tmp}"; _b_die "Archive contains unsafe paths; refusing to extract."
  fi
  mkdir -p -- "${dest}"
  tar -xzf "${archive}" -C "${dest}" --strip-components=1 || { rm -rf "${tmp}"; _b_die "Extraction failed (incomplete download?)"; }
  rm -rf "${tmp}"
  [[ -f "${dest}/install.sh" && -f "${dest}/scripts/logger.sh" && -f "${dest}/config/defaults.conf" ]] \
    || _b_die "Downloaded project is incomplete"
}

# ---------- argument parsing ----------
MVN_REF="${MVN_REF:-}"
FETCH_ONLY_DEST=""
while (($#)); do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    -y | --yes | --non-interactive) MVN_NONINTERACTIVE=1 ;;
    --dry-run | --plan) MVN_DRY_RUN=1 ;;
    --ref) [[ $# -ge 2 ]] || _b_die "--ref needs a value"; MVN_REF="$2"; shift ;;
    --config) [[ $# -ge 2 ]] || _b_die "--config needs a value"; MVN_CONFIG_FILE="$2"; shift ;;
    --fetch-only) [[ $# -ge 2 ]] || _b_die "--fetch-only needs a directory"; FETCH_ONLY_DEST="$2"; shift ;;
    *) _b_die "Unknown option: $1 (see --help)" ;;
  esac
  shift
done
MVN_REF="${MVN_REF:-${MVN_PINNED_REF}}"

if [[ -n "${FETCH_ONLY_DEST}" ]]; then
  _b_fetch_project "${MVN_REF}" "${FETCH_ONLY_DEST}"
  _b_say "Project downloaded to ${FETCH_ONLY_DEST}"
  exit 0
fi

SELF_DIR=""
if SELF_DIR="$(_self_dir)" && [[ -f "${SELF_DIR}/scripts/logger.sh" && -f "${SELF_DIR}/config/defaults.conf" ]]; then
  :
else
  # Single-file launch: fetch the whole versioned project, then run it.
  [[ "${EUID}" -eq 0 ]] || _b_die "Run as root: sudo bash install.sh"
  boot_dir="$(mktemp -d /tmp/mvn-deploy-src.XXXXXX)"
  _b_fetch_project "${MVN_REF}" "${boot_dir}/project"
  child_in=/dev/null
  if ( : < /dev/tty ) 2> /dev/null; then child_in=/dev/tty; fi
  rc=0
  bash "${boot_dir}/project/install.sh" "$@" < "${child_in}" || rc=$?
  rm -rf "${boot_dir}"
  exit "${rc}"
fi

# ============================================================================
# Main layer
# ============================================================================
for _m in logger common system dependencies security three_x_ui firewall bbr verify; do
  # shellcheck source=/dev/null
  source "${SELF_DIR}/scripts/${_m}.sh"
done
unset _m

sys_require_root
sys_check_bash
detect_interactivity
load_user_config                                  # environment wins over the file
# shellcheck source=config/defaults.conf
source "${SELF_DIR}/config/defaults.conf"         # defaults only fill what is still unset
detect_interactivity
log_init

CURRENT_STAGE="init"
trap 'cleanup_work_dir' EXIT
trap 'rc=$?; trap - ERR; log_error "Stage failed: ${CURRENT_STAGE} (line ${LINENO}, exit ${rc}). Details: ${LOG_FILE:-n/a}"; exit "${rc}"' ERR
trap 'log_error "Interrupted during stage: ${CURRENT_STAGE}"; exit 130' INT TERM

run_stage() { CURRENT_STAGE="$1"; log_step "$1"; "$2"; }

PLAN_LINES=()
plan_add() { PLAN_LINES+=("$1"); }

# ---------------- stages ----------------
stage_preflight() {
  acquire_lock
  sys_detect_os
  sys_check_tools
  sys_check_disk
  sys_check_time
  sys_check_network
  log_ok "Preflight passed: ${OS_PRETTY}, ${ARCH}"
  report_add "Preflight" "OK" "${OS_PRETTY}, ${ARCH}"
}

stage_inventory() {
  sys_detect_rerun
  sys_detect_ssh_ports
  sys_detect_firewall
  sys_detect_xui
  sys_detect_conflicts
  sys_detect_bbr
  log_info "SSH ports detected: ${SSH_PORTS_DETECTED[*]:-none}"
  log_info "Firewall: ${FW_KIND}${FW_DETAIL:+ (${FW_DETAIL})}"
  log_info "3x-ui already installed: $([[ ${XUI_PRESENT} == 1 ]] && echo yes || echo no)"
  log_info "BBR now: ${BBR_CC_CURRENT:-?}/${BBR_QDISC_CURRENT:-?}"
  [[ "${IS_RERUN}" == "1" ]] && log_info "This is a repeated run: existing settings will be kept"
  if [[ "${MVN_DRY_RUN}" != "1" ]]; then sys_snapshot; fi
  report_add "Inventory" "OK" "firewall=${FW_KIND}, xui_present=${XUI_PRESENT}"
}

stage_plan() {
  if ((${#CONFLICTS[@]})); then
    log_warn "Other VPN/proxy components found: ${CONFLICTS[*]}"
    if [[ "${MVN_ALLOW_CONFLICTS}" == "1" ]]; then
      log_warn "Continuing because MVN_ALLOW_CONFLICTS=1"
    else
      need_confirm "Continue although a conflicting service may exist?" "Set MVN_ALLOW_CONFLICTS=1 to proceed." \
        || die "${EXIT_ABORT}" "Aborted: conflicting service detected. Nothing was changed."
    fi
  fi

  if [[ "${MVN_FIREWALL}" != "skip" ]] && ! is_noninteractive && [[ "${MVN_DRY_RUN}" != "1" && "${MVN_APT_UPGRADE}" != "1" ]]; then
    ask_yes_no "Also run an optional full 'apt upgrade'?" n && MVN_APT_UPGRADE=1
  fi

  xui_plan
  fw_plan

  plan_add "System: ${OS_PRETTY} (${ARCH})"
  deps_compute_missing
  plan_add "Packages to install: ${DEPS_MISSING[*]:-none}$([[ ${MVN_APT_UPGRADE} == 1 ]] && echo ' + full apt upgrade')"
  case "${XUI_ACTION}" in
    install) plan_add "3x-ui: run the OFFICIAL installer (version: ${MVN_XUI_VERSION:-latest stable}, SSL mode: ${MVN_XUI_SSL_MODE})" ;;
    reinstall) plan_add "3x-ui: RE-run the official installer (forced)" ;;
    keep) plan_add "3x-ui: already installed — keep as is (only make sure the service runs)" ;;
  esac
  plan_add "Firewall: $(fw_plan_text)"
  plan_add "BBR: $(bbr_plan_text)"
  plan_add "Not touched: sshd settings, provider (cloud) firewall, reboot, VPN clients/inbounds"

  log_info "Planned changes:"
  local l
  for l in "${PLAN_LINES[@]}"; do printf '  - %s\n' "${l}"; log_file_only "PLAN: ${l}"; done

  if [[ "${MVN_DRY_RUN}" == "1" ]]; then
    log_ok "Dry run finished: no changes were made."
    exit 0
  fi
}

stage_deps()     { deps_install; }
stage_security() { sec_prepare; }
stage_xui() {
  if [[ "${MVN_XUI_SSL_MODE}" != "none" && "${FW_ACTION}" == "ufw-add" ]]; then
    fw_allow 80 tcp acme    # HTTP-01 challenge must pass while UFW is already active
  fi
  xui_apply
}
stage_firewall() { fw_apply; }
stage_bbr()      { bbr_apply; }
stage_verify()   { verify_all; }

stage_report() {
  state_set last_run "$(date +%Y-%m-%dT%H:%M:%S%z)"
  report_print
  echo
  if ((VERIFY_FAILS > 0)); then
    log_error "Deployment finished WITH ERRORS (${VERIFY_FAILS} failed check(s)). See ${LOG_FILE}"
  else
    printf '%sDeployment completed.%s\n' "${C_GREEN}" "${C_RESET}"
  fi
  printf '  Panel address : %s\n' "${XUI_PANEL_URL:-unknown (run: x-ui settings)}"
  printf '  Credentials   : %s\n' "${XUI_CREDS_NOTE}"
  printf '  Log file      : %s\n' "${LOG_FILE}"
  printf '  MVN Deploy    : %s (%s)\n' "${MVN_VERSION}" "${MVN_INSTALL_DIR}"
  echo
  echo "Next steps:"
  echo "  1. Check the firewall of your VPS provider (cloud panel): open the panel port and your VPN ports."
  [[ "${XUI_PANEL_URL}" == http://* ]] && echo "  2. The panel runs over plain HTTP: use an SSH tunnel or set up TLS in 3x-ui before logging in over the internet."
  echo "  3. Create inbounds/clients in the 3x-ui panel. For every new inbound port run, e.g.: ufw allow <port>/tcp"
  if ((${#MVN_WARNINGS[@]})); then
    echo
    echo "Warnings:"
    local w
    for w in "${MVN_WARNINGS[@]}"; do printf '  - %s\n' "${w}"; done
  fi
  ((VERIFY_FAILS == 0))
}

main() {
  printf '%s%s — One-command VPN Server Deployment (v%s)%s\n' "${C_BOLD}" "${PROJECT_NAME}" "${MVN_VERSION}" "${C_RESET}"
  log_file_only "Run started; dry_run=${MVN_DRY_RUN} noninteractive=${MVN_NONINTERACTIVE}" INFO
  run_stage "1. Preflight" stage_preflight
  run_stage "2. Inventory" stage_inventory
  run_stage "3. Plan" stage_plan
  run_stage "4. Dependencies" stage_deps
  run_stage "5. Security preparation" stage_security
  run_stage "6. 3x-ui" stage_xui
  run_stage "7. Firewall" stage_firewall
  run_stage "8. BBR" stage_bbr
  run_stage "9. Verification" stage_verify
  CURRENT_STAGE="10. Final report"
  stage_report
}

main
