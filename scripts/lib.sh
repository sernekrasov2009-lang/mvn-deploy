#!/usr/bin/env bash
# Shared helper functions. Source from project scripts.

if [[ -t 1 ]]; then
    _MVN_GREEN=$'\033[0;32m'
    _MVN_RED=$'\033[0;31m'
    _MVN_YELLOW=$'\033[1;33m'
    _MVN_RESET=$'\033[0m'
else
    _MVN_GREEN=''
    _MVN_RED=''
    _MVN_YELLOW=''
    _MVN_RESET=''
fi

log_info() { printf '[+] %s\n' "$*"; }
log_ok() { printf '%s[OK]%s %s\n' "$_MVN_GREEN" "$_MVN_RESET" "$*"; }
log_warn() { printf '%s[WARN]%s %s\n' "$_MVN_YELLOW" "$_MVN_RESET" "$*" >&2; }
log_error() { printf '%s[ERROR]%s %s\n' "$_MVN_RED" "$_MVN_RESET" "$*" >&2; }
die() { log_error "$*"; exit 1; }

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this installer as root (for example: sudo bash install.sh)."
}

ask_yes_no() {
    local prompt="$1" default="${2:-no}" answer=''
    if [[ "${MVN_DEPLOY_NONINTERACTIVE:-0}" == "1" || ! -t 0 ]]; then
        [[ "$default" == "yes" ]]
        return
    fi
    if [[ "$default" == "yes" ]]; then
        read -r -p "$prompt [Y/n] " answer || answer=''
        answer="${answer:-y}"
    else
        read -r -p "$prompt [y/N] " answer || answer=''
        answer="${answer:-n}"
    fi
    [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

valid_port() {
    local value="${1:-}"
    [[ "$value" =~ ^[0-9]{1,5}$ ]] && (( value >= 1 && value <= 65535 ))
}

# Read a simple KEY=value assignment without evaluating the file as shell code.
read_env_value() {
    local file="$1" key="$2" line value
    [[ -r "$file" ]] || return 1
    line="$(grep -m1 -E "^${key}=" "$file" || true)"
    [[ -n "$line" ]] || return 1
    value="${line#*=}"
    value="${value%$'\r'}"
    # The upstream result file uses printf %q; the values used here (ports) are
    # numeric and therefore never require shell escape evaluation.
    value="${value%\"}"; value="${value#\"}"
    value="${value%\'}"; value="${value#\'}"
    printf '%s' "$value"
}

get_ssh_ports() {
    local ports='' port
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        # SSH_CONNECTION format: client_ip client_port server_ip server_port.
        ports="$(awk '{print $4}' <<<"$SSH_CONNECTION")"
    elif command -v sshd >/dev/null 2>&1; then
        ports="$(sshd -T 2>/dev/null | awk 'tolower($1)=="port" {print $2}' | sort -un | paste -sd ' ' - || true)"
    fi
    ports="${ports//,/ }"
    [[ -n "$ports" ]] || ports=22
    while IFS= read -r port; do
        if [[ -n "$port" ]]; then
            printf '%s\n' "$port"
        fi
    done < <(tr ' ' '\n' <<<"$ports")
}

is_xui_installed() {
    [[ -x /usr/local/x-ui/x-ui || -x /usr/bin/x-ui ]] || systemctl list-unit-files x-ui.service --no-legend 2>/dev/null | grep -q '^x-ui\.service'
}
