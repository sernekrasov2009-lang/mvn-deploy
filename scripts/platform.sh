#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # globals are used by the scripts that source this file
# platform.sh — what are we running on? Distribution family, package manager, init system,
# CPU architecture, plus thin wrappers so the other modules never call apt/systemctl directly.
#
# Supported distributions are the ones the OFFICIAL 3x-ui installer handles (it decides by the ID
# in /etc/os-release): ubuntu, debian, armbian | fedora, amzn, rhel, almalinux, rocky, ol, centos |
# arch, manjaro, parch | opensuse-leap, opensuse-tumbleweed | alpine. Debian/Ubuntu derivatives
# (ID_LIKE=debian) work because that installer falls back to apt for unknown IDs.

PLAT_ID=""; PLAT_ID_LIKE=""; PLAT_VERSION=""
PLAT_FAMILY=""      # debian | rhel | arch | suse | alpine
PLAT_PM=""          # apt | dnf | yum | pacman | zypper | apk
PLAT_INIT=""        # systemd | openrc | none
PLAT_SUPPORT=""     # supported | derivative | old | unknown
PLAT_NOTE=""

# ---------- version helpers ----------
ver_ge() { # a b -> 0 when a >= b (version sort); an empty a means "rolling" and passes
  local a="${1:-}" b="${2:-}"
  [[ -n "${a}" ]] || return 0
  [[ "$(printf '%s\n%s\n' "${b}" "${a}" | sort -V | head -n 1)" == "${b}" ]]
}

# plat_classify <id> <id_like> <version_id>: pure, sets PLAT_FAMILY / PLAT_SUPPORT / PLAT_NOTE.
plat_classify() {
  local id="${1:-}" like="${2:-}" ver="${3:-}" min=""
  PLAT_FAMILY=""; PLAT_SUPPORT="unknown"; PLAT_NOTE=""
  case "${id}" in
    debian)                       PLAT_FAMILY="debian"; min="12" ;;
    ubuntu)                       PLAT_FAMILY="debian"; min="20.04" ;;
    armbian | raspbian)           PLAT_FAMILY="debian"; min="" ;;
    rhel | almalinux | rocky | ol) PLAT_FAMILY="rhel"; min="8" ;;
    centos)                       PLAT_FAMILY="rhel"; min="8" ;;
    fedora)                       PLAT_FAMILY="rhel"; min="39" ;;
    amzn)                         PLAT_FAMILY="rhel"; min="2023" ;;
    virtuozzo)                    PLAT_FAMILY="rhel"; min="7" ;;
    arch | manjaro | parch)       PLAT_FAMILY="arch"; min="" ;;
    opensuse-leap)                PLAT_FAMILY="suse"; min="15.5" ;;
    opensuse-tumbleweed)          PLAT_FAMILY="suse"; min="" ;;
    alpine)                       PLAT_FAMILY="alpine"; min="3.18" ;;
    *)
      # Unknown ID: only Debian/Ubuntu derivatives are safe, because the official installer uses apt for them.
      if [[ " ${like} " == *" debian "* || " ${like} " == *" ubuntu "* ]]; then
        PLAT_FAMILY="debian"; PLAT_SUPPORT="derivative"
        PLAT_NOTE="${id:-this system} is a Debian/Ubuntu derivative; treated as Debian (best effort)"
        return 0
      fi
      PLAT_NOTE="${id:-unknown} is not a distribution the official 3x-ui installer supports"
      return 0
      ;;
  esac
  if [[ -n "${min}" ]] && ! ver_ge "${ver}" "${min}"; then
    PLAT_SUPPORT="old"
    PLAT_NOTE="${id} ${ver} is older than the minimum maintained release (${id} ${min}); its package repositories are usually offline"
    return 0
  fi
  PLAT_SUPPORT="supported"
  return 0
}

# plat_pm_for_family: picks the package manager that really exists on this machine.
plat_detect_pm() {
  local c
  PLAT_PM=""
  case "${PLAT_FAMILY}" in
    debian) c="apt-get" ;;
    rhel) if command -v dnf > /dev/null 2>&1; then c="dnf"; else c="yum"; fi ;;
    arch) c="pacman" ;;
    suse) c="zypper" ;;
    alpine) c="apk" ;;
    *) c="" ;;
  esac
  if [[ -n "${c}" ]] && command -v "${c}" > /dev/null 2>&1; then
    case "${c}" in apt-get) PLAT_PM="apt" ;; *) PLAT_PM="${c}" ;; esac
    return 0
  fi
  for c in apt-get dnf yum zypper pacman apk; do
    if command -v "${c}" > /dev/null 2>&1; then
      case "${c}" in apt-get) PLAT_PM="apt" ;; *) PLAT_PM="${c}" ;; esac
      return 0
    fi
  done
  return 1
}

plat_detect_init() {
  if [[ -d /run/systemd/system ]]; then
    PLAT_INIT="systemd"
  elif command -v rc-service > /dev/null 2>&1 && command -v rc-update > /dev/null 2>&1; then
    PLAT_INIT="openrc"
  else
    PLAT_INIT="none"
  fi
}

# plat_map_arch <uname -m>: the names the official installer knows; prints nothing if unknown.
plat_map_arch() {
  case "${1:-}" in
    x86_64 | x64 | amd64) echo "amd64" ;;
    aarch64 | arm64 | armv8*) echo "arm64" ;;
    armv7*) echo "armv7" ;;
    armv6*) echo "armv6" ;;
    armv5*) echo "armv5" ;;
    i?86 | x86) echo "386" ;;
    s390x) echo "s390x" ;;
  esac
}

# ---------- run a command, keep its output for diagnosis ----------
# run_capture <outfile> <command...>: output goes to <outfile> and to the log file.
run_capture() {
  local out="$1" rc=0
  shift
  _log_write CMD "$*"
  "$@" > "${out}" 2>&1 || rc=$?
  if [[ "${LOG_READY:-0}" -eq 1 ]]; then cat "${out}" >> "${LOG_FILE}" 2> /dev/null || true; fi
  return "${rc}"
}

# ---------- services (systemd / OpenRC) ----------
_svc_name() { local n="${1%.service}"; printf '%s' "${n}"; }

svc_exists() {
  local n; n="$(_svc_name "$1")"
  case "${PLAT_INIT}" in
    systemd) systemctl cat "${n}.service" > /dev/null 2>&1 ;;
    openrc) [[ -x "/etc/init.d/${n}" ]] ;;
    *) return 1 ;;
  esac
}
svc_active() {
  local n; n="$(_svc_name "$1")"
  case "${PLAT_INIT}" in
    systemd) systemctl is-active --quiet "${n}" 2> /dev/null ;;
    openrc) rc-service "${n}" status > /dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}
svc_enabled() {
  local n; n="$(_svc_name "$1")"
  case "${PLAT_INIT}" in
    systemd) systemctl is-enabled --quiet "${n}" 2> /dev/null ;;
    openrc) rc-update show default 2> /dev/null | awk '{print $1}' | grep -qx "${n}" ;;
    *) return 1 ;;
  esac
}
svc_enable() {
  local n; n="$(_svc_name "$1")"
  case "${PLAT_INIT}" in
    systemd) systemctl enable "${n}" ;;
    openrc) rc-update add "${n}" default ;;
    *) return 1 ;;
  esac
}
svc_start() {
  local n; n="$(_svc_name "$1")"
  case "${PLAT_INIT}" in
    systemd) systemctl start "${n}" ;;
    openrc) rc-service "${n}" start ;;
    *) return 1 ;;
  esac
}
svc_restart() {
  local n; n="$(_svc_name "$1")"
  case "${PLAT_INIT}" in
    systemd) systemctl restart "${n}" ;;
    openrc) rc-service "${n}" restart ;;
    *) return 1 ;;
  esac
}
svc_stop() {
  local n; n="$(_svc_name "$1")"
  case "${PLAT_INIT}" in
    systemd) systemctl stop "${n}" ;;
    openrc) rc-service "${n}" stop ;;
    *) return 1 ;;
  esac
}
svc_enable_now() { svc_enable "$1" || true; svc_start "$1"; }

# svc_dump <name>: status + recent journal into the log (for failures).
svc_dump() {
  local n; n="$(_svc_name "$1")"
  case "${PLAT_INIT}" in
    systemd)
      run_logged systemctl status "${n}" --no-pager -l || true
      run_logged journalctl -u "${n}" -n 40 --no-pager || true
      ;;
    openrc) run_logged rc-service "${n}" status || true ;;
  esac
}

# ---------- packages ----------
# Logical package -> real package name(s) for the detected package manager.
pkg_names() {
  case "$1:${PLAT_PM}" in
    iproute:apt | iproute:pacman | iproute:zypper) echo "iproute2" ;;
    iproute:dnf | iproute:yum) echo "iproute" ;;
    iproute:apk) echo "iproute2 iproute2-ss" ;;
    procps:apt | procps:zypper) echo "procps" ;;
    procps:dnf | procps:yum | procps:pacman | procps:apk) echo "procps-ng" ;;
    pysystemd:pacman) echo "python-systemd" ;;
    pysystemd:apt | pysystemd:dnf | pysystemd:yum | pysystemd:zypper) echo "python3-systemd" ;;
    pysystemd:apk) echo "" ;;
    *) echo "$1" ;;
  esac
}

pkg_installed() { # real package name
  case "${PLAT_PM}" in
    apt) dpkg-query -W -f='${Status}' "$1" 2> /dev/null | grep -q 'install ok installed' ;;
    dnf | yum | zypper) rpm -q "$1" > /dev/null 2>&1 ;;
    pacman) pacman -Qi "$1" > /dev/null 2>&1 ;;
    apk) apk info -e "$1" > /dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

_pkg_refresh_cmd() {
  case "${PLAT_PM}" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get update -q -o DPkg::Lock::Timeout=300 ;;
    dnf) dnf makecache -y -q ;;
    yum) yum makecache -y -q ;;
    zypper) zypper --non-interactive --gpg-auto-import-keys refresh ;;
    apk) apk update ;;
    pacman) true ;;   # pacman is refreshed on demand (partial upgrades are risky on Arch)
    *) return 1 ;;
  esac
}
_pkg_install_cmd() {
  case "${PLAT_PM}" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y -q -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@" ;;
    dnf) dnf install -y -q "$@" ;;
    yum) yum install -y -q "$@" ;;
    pacman) pacman -S --noconfirm --needed "$@" ;;
    zypper) zypper --non-interactive install --no-recommends "$@" ;;
    apk) apk add "$@" ;;
    *) return 1 ;;
  esac
}
_pkg_upgrade_cmd() {
  case "${PLAT_PM}" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -q -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold ;;
    dnf) dnf upgrade -y -q ;;
    yum) yum update -y -q ;;
    pacman) pacman -Syu --noconfirm ;;
    zypper) zypper --non-interactive update ;;
    apk) apk upgrade ;;
    *) return 1 ;;
  esac
}

# pkg_hint <output-file>: translate a package-manager failure into advice (one line per hint).
pkg_hint() {
  local f="$1"
  [[ -s "${f}" ]] || return 0
  if grep -Eqi 'could not get lock|unable to acquire the dpkg|waiting for cache lock|is locked by another process|another app is currently holding|database is locked|failed to obtain lock|system management is locked|unable to lock' "${f}"; then
    echo "Another package manager is running (automatic updates?). Wait a few minutes and run the installer again."
  fi
  if grep -Eqi 'dpkg was interrupted|dpkg --configure -a' "${f}"; then
    echo "A previous package operation was interrupted. Run: dpkg --configure -a   and then run the installer again."
  fi
  if grep -Eqi 'temporary failure resolving|could not resolve|name or service not known|cannot find a valid baseurl|failed to download metadata|failed to synchronize|failed retrieving file|could not connect|connection timed out|no route to host' "${f}"; then
    echo "The package repositories are unreachable (DNS, firewall, proxy, or a dead mirror). Check: curl -I https://github.com and your resolv.conf."
  fi
  if grep -Eqi 'no space left on device' "${f}"; then
    echo "The disk is full. Free some space (df -h) and run the installer again."
  fi
  if grep -Eqi 'no_pubkey|gpg|signature|not valid yet|expired|repomd.xml' "${f}"; then
    echo "A repository key/signature or the system clock is wrong. Check 'date' and the repository configuration."
  fi
  if grep -Eqi 'unable to locate package|no match for argument|target not found|nothing provides|not found in package names|no package .* available|error: package .* not found' "${f}"; then
    echo "A required package is not available in the enabled repositories (repository disabled or the release is end-of-life)."
  fi
  return 0
}

# pkg_repair: fix the most common half-finished package state, then the caller retries.
pkg_repair() {
  case "${PLAT_PM}" in
    apt)
      log_info "Trying to repair an interrupted package state (dpkg --configure -a)"
      run_logged dpkg --configure -a || true
      DEBIAN_FRONTEND=noninteractive run_logged apt-get install -f -y -q || true
      ;;
  esac
  return 0
}

# pkg_install_safe <package...>: install with one repair+retry; never dies; prints hints on failure.
pkg_install_safe() {
  local out rc=0
  out="$(mktemp "${WORK_DIR:-/tmp}/pkg.XXXXXX")"
  if ! retry 2 8 run_capture "${out}" _pkg_install_cmd "$@"; then
    rc=1
    if [[ "${PLAT_PM}" == "pacman" ]] && grep -Eqi '404|failed retrieving|target not found' "${out}"; then
      log_warn "pacman database looks stale; refreshing it (pacman -Sy) and retrying"
      if run_capture "${out}" pacman -Sy --noconfirm --needed "$@"; then rc=0; fi
    fi
    if ((rc != 0)) && grep -Eqi 'dpkg was interrupted|dpkg --configure -a' "${out}"; then
      pkg_repair
      if run_capture "${out}" _pkg_install_cmd "$@"; then rc=0; fi
    fi
  fi
  if ((rc != 0)); then
    local h
    while IFS= read -r h; do log_error "  hint: ${h}"; done < <(pkg_hint "${out}")
    tail -n 6 "${out}" 2> /dev/null | redact_stream | while IFS= read -r h; do log_error "  | ${h}"; done
  fi
  rm -f -- "${out}"
  return "${rc}"
}

# pkg_enable_epel: EL-family only, needed for fail2ban. Never fatal.
pkg_enable_epel() {
  [[ "${PLAT_FAMILY}" == "rhel" ]] || return 0
  case "${PLAT_ID}" in fedora | amzn) return 0 ;; esac
  pkg_installed epel-release && return 0
  pkg_install_safe epel-release
}
