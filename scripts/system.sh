#!/usr/bin/env bash
set -Eeuo pipefail
BASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$BASE_DIR/scripts/lib.sh"

require_root
[[ -r /etc/os-release ]] || die "Cannot identify this operating system (/etc/os-release missing)."
# shellcheck disable=SC1091
source /etc/os-release

case "${ID:-}" in
    debian)
        case "${VERSION_ID:-}" in
            12|13) ;;
            *) die "Supported Debian versions: 12 and 13. Detected: ${PRETTY_NAME:-unknown}." ;;
        esac
        ;;
    ubuntu)
        case "${VERSION_ID:-}" in
            22.04|24.04|26.04) ;;
            *) die "Supported Ubuntu versions: 22.04, 24.04 and 26.04. Detected: ${PRETTY_NAME:-unknown}." ;;
        esac
        ;;
    *) die "This first release supports Debian 12/13 and Ubuntu 22.04/24.04/26.04 only. Detected: ${PRETTY_NAME:-unknown}." ;;
esac

command -v systemctl >/dev/null 2>&1 || die "systemd/systemctl is required."
systemctl is-system-running >/dev/null 2>&1 || {
    state="$(systemctl is-system-running 2>/dev/null || true)"
    [[ "$state" == "degraded" ]] || die "systemd is not fully available (state: ${state:-unknown})."
}
command -v apt-get >/dev/null 2>&1 || die "apt-get is required."

log_ok "Supported operating system: ${PRETTY_NAME:-$ID}"
log_ok "systemd and apt-get detected"
