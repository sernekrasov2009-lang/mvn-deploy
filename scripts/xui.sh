#!/usr/bin/env bash
set -Eeuo pipefail
BASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$BASE_DIR/scripts/lib.sh"
# shellcheck source=config/defaults.conf
source "$BASE_DIR/config/defaults.conf"
require_root

if is_xui_installed; then
    log_warn "3x-ui appears to be installed already. Skipping reinstall to protect its database, credentials and inbounds."
    if systemctl is-active --quiet x-ui 2>/dev/null; then
        log_ok "Existing x-ui.service is active"
    else
        log_warn "Existing x-ui.service is not active. Use 'systemctl status x-ui' to diagnose it."
    fi
    exit 0
fi

work_dir="$(mktemp -d -t mvn-xui.XXXXXX)"
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT INT TERM
installer="$work_dir/3x-ui-install.sh"

log_info "Downloading the official 3x-ui installer over HTTPS..."
curl --proto '=https' --tlsv1.2 -fsSL "$XUI_INSTALL_URL" -o "$installer"
[[ -s "$installer" ]] || die "The official installer download is empty."
bash -n "$installer" || die "The downloaded upstream installer failed Bash syntax validation."

ssl_mode="${MVN_XUI_SSL_MODE:-$DEFAULT_XUI_SSL_MODE}"
case "$ssl_mode" in
    ip|none) ;;
    *) die "Invalid MVN_XUI_SSL_MODE='$ssl_mode'; supported values are ip or none." ;;
esac
if [[ "$ssl_mode" == "none" ]]; then
    log_warn "TLS mode is 'none'. Do not expose the panel login over public HTTP; use an SSH tunnel or configure TLS before public access."
else
    log_info "Requesting upstream 3x-ui IP-certificate TLS mode. Certificate issuance can depend on network/provider rules."
fi

log_info "Running the official 3x-ui installer in non-interactive mode..."
set +e
XUI_NONINTERACTIVE=1 XUI_SSL_MODE="$ssl_mode" bash "$installer"
status=$?
set -e

if systemctl is-active --quiet x-ui 2>/dev/null && [[ -s /etc/x-ui/install-result.env ]]; then
    if (( status != 0 )); then
        log_warn "The upstream installer returned exit code $status but x-ui.service is active and credentials were saved. Inspect the output for TLS/setup warnings."
    else
        log_ok "Official 3x-ui install completed and result file exists."
    fi
else
    die "3x-ui installation could not be verified (installer exit code $status). Check the upstream output and rerun after resolving the reported error."
fi
