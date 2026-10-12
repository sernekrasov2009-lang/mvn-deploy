#!/usr/bin/env bash
set -Eeuo pipefail
BASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$BASE_DIR/scripts/lib.sh"
require_root

command -v x-ui >/dev/null 2>&1 || [[ -x /usr/bin/x-ui ]] || die "The x-ui management command is missing."
systemctl is-active --quiet x-ui || {
    systemctl --no-pager --full status x-ui || true
    die "x-ui.service is not active."
}
log_ok "x-ui.service is active"

if systemctl is-enabled --quiet x-ui; then
    log_ok "x-ui.service is enabled at boot"
else
    log_warn "x-ui.service is not enabled at boot; trying to enable it."
    systemctl enable x-ui
fi

if [[ -s /etc/x-ui/install-result.env ]]; then
    chmod 600 /etc/x-ui/install-result.env
    chown root:root /etc/x-ui/install-result.env
    log_ok "3x-ui installation result exists and is root-only (mode 600)"
else
    log_warn "No /etc/x-ui/install-result.env found; credentials/port cannot be summarized automatically."
fi
