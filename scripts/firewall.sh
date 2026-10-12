#!/usr/bin/env bash
set -Eeuo pipefail
BASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$BASE_DIR/scripts/lib.sh"
# shellcheck source=config/defaults.conf
source "$BASE_DIR/config/defaults.conf"
require_root

MODE="${1:-apply}"
[[ "$MODE" == "prepare" || "$MODE" == "apply" ]] || die "Usage: firewall.sh [prepare|apply]"

if systemctl is-active --quiet firewalld 2>/dev/null; then
    die "firewalld is active. Refusing to manage UFW concurrently."
fi
command -v ufw >/dev/null 2>&1 || die "ufw is not installed. Run scripts/dependencies.sh first."

add_rule() {
    local port="$1" proto="$2" comment="$3"
    valid_port "$port" || die "Invalid port for firewall rule: $port"
    ufw allow "${port}/${proto}" comment "$comment" >/dev/null
}

# Never reset the ruleset. On an already-active UFW, allow SSH before any other
# operation. Existing custom rules are preserved.
ssh_ports=()
while IFS= read -r port; do
    if valid_port "$port"; then
        ssh_ports+=("$port")
    fi
done < <(get_ssh_ports)
((${#ssh_ports[@]} > 0)) || ssh_ports=(22)

for port in "${ssh_ports[@]}"; do
    add_rule "$port" tcp "MVN Deploy: SSH"
done
add_rule "$DEFAULT_HTTP_PORT" tcp "MVN Deploy: HTTP and ACME"
add_rule "$DEFAULT_HTTPS_PORT" tcp "MVN Deploy: HTTPS and common VPN inbound"
add_rule "$DEFAULT_HTTPS_UDP_PORT" udp "MVN Deploy: common UDP VPN inbound"

if [[ "$MODE" == "prepare" ]]; then
    if ufw status 2>/dev/null | grep -q '^Status: active'; then
        log_ok "UFW is already active; SSH and ACME/VPN baseline rules were added without resetting existing rules."
    else
        log_info "UFW is inactive. Baseline rules are prepared but the firewall is not enabled until the panel port is known."
    fi
    exit 0
fi

result_file="/etc/x-ui/install-result.env"
panel_port=''
if [[ -f "$result_file" ]]; then
    panel_port="$(read_env_value "$result_file" XUI_PANEL_PORT || true)"
fi

if ! valid_port "$panel_port"; then
    # Old/manual installations may not have an install-result file. Do not guess
    # a port and risk locking the administrator out of the actual panel.
    if [[ "${MVN_DEPLOY_NONINTERACTIVE:-0}" != "1" && -t 0 ]]; then
        read -r -p "Could not detect the 3x-ui panel port. Enter its TCP port (blank = do not enable UFW): " panel_port || panel_port=''
    else
        log_warn "Could not safely detect the 3x-ui panel port; UFW will not be enabled by this run. Existing active UFW rules were not disabled."
        exit 0
    fi
fi

if ! valid_port "$panel_port"; then
    log_warn "No valid 3x-ui panel port supplied; leaving UFW activation unchanged."
    exit 0
fi
add_rule "$panel_port" tcp "MVN Deploy: 3x-ui panel"

if ufw status 2>/dev/null | grep -q '^Status: active'; then
    log_ok "UFW is active. Added/confirmed SSH, 80/tcp, 443/tcp, 443/udp and panel TCP/$panel_port rules. Existing rules and default policies were not reset."
else
    cat <<'WARNING'

Firewall safety notice:
  - UFW will be enabled with default incoming=deny and outgoing=allow.
  - SSH port(s), TCP/80, TCP/443, UDP/443 and the detected panel port are allowed first.
  - Any other service/custom inbound port must be allowed separately.
  - A VPS-provider firewall/security group is separate and may need matching rules.
WARNING
    if ! ask_yes_no "Enable UFW now with the listed baseline rules?" yes; then
        log_warn "UFW was not enabled. Baseline allow rules remain prepared."
        exit 0
    fi
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw --force enable
    log_ok "UFW enabled with SSH, HTTP/ACME, HTTPS, UDP/443 and 3x-ui panel rules."
fi
