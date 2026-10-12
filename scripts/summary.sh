#!/usr/bin/env bash
set -Eeuo pipefail
BASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$BASE_DIR/scripts/lib.sh"

result_file="/etc/x-ui/install-result.env"
printf '\n============================================================\n'
printf ' MVN Deploy — deployment summary\n'
printf '============================================================\n'
printf ' Panel: 3x-ui (manages the bundled Xray-core)\n'
printf ' Service: x-ui.service\n'

if [[ -r "$result_file" ]]; then
    url="$(read_env_value "$result_file" XUI_ACCESS_URL || true)"
    username="$(read_env_value "$result_file" XUI_USERNAME || true)"
    password="$(read_env_value "$result_file" XUI_PASSWORD || true)"
    port="$(read_env_value "$result_file" XUI_PANEL_PORT || true)"
    [[ -n "$url" ]] && printf ' Panel URL: %s\n' "$url"
    [[ -n "$port" ]] && printf ' Panel port: %s/tcp\n' "$port"
    [[ -n "$username" ]] && printf ' Username: %s\n' "$username"
    [[ -n "$password" ]] && printf ' Password: %s\n' "$password"
    printf ' Credentials file: %s (root-only; sudo cat to view again)\n' "$result_file"
else
    printf ' Panel credentials: not available in the upstream result file.\n'
    printf ' Run: sudo x-ui\n'
fi

printf '\n Firewall baseline (if UFW was enabled): SSH, TCP/80, TCP/443, UDP/443 and panel TCP port.\n'
printf ' BBR: see sysctl net.ipv4.tcp_congestion_control\n'
printf ' Service status: systemctl status x-ui\n'
printf ' Management menu: sudo x-ui\n'
printf '\nIMPORTANT: save the panel credentials securely. Do not paste them into public issues/logs.\n'
printf 'Custom inbound ports created later in 3x-ui must be opened in UFW and in any provider firewall.\n'
printf '============================================================\n\n'
