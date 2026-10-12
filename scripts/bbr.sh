#!/usr/bin/env bash
set -Eeuo pipefail
BASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$BASE_DIR/scripts/lib.sh"
# shellcheck source=config/defaults.conf
source "$BASE_DIR/config/defaults.conf"
require_root

if [[ ! -r /proc/sys/net/ipv4/tcp_available_congestion_control ]]; then
    log_warn "Kernel does not expose TCP congestion-control options; skipping BBR."
    exit 0
fi
available="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control)"
if ! grep -qw bbr <<<"$available"; then
    log_warn "This kernel does not offer BBR (available: $available). No BBR setting was written."
    exit 0
fi

backup_dir="/var/backups/mvn-deploy"
install -d -m 700 "$backup_dir"
previous_file=''
if [[ -e "$BBR_SYSCTL_FILE" ]]; then
    backup_file="$backup_dir/99-mvn-deploy-bbr.conf.$(date -u +%Y%m%dT%H%M%SZ).bak"
    cp -a "$BBR_SYSCTL_FILE" "$backup_file"
    previous_file="$backup_file"
    log_info "Existing MVN Deploy BBR file backed up to $backup_file"
fi

install -d -m 755 "$(dirname "$BBR_SYSCTL_FILE")"
tmp_file="$(mktemp "$(dirname "$BBR_SYSCTL_FILE")/.mvn-bbr.XXXXXX")"
trap 'rm -f "$tmp_file"' EXIT
cat >"$tmp_file" <<'SYSCTL'
# Managed by MVN Deploy. TCP BBR congestion control + FQ queue discipline.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
SYSCTL
chmod 644 "$tmp_file"
mv -f "$tmp_file" "$BBR_SYSCTL_FILE"
trap - EXIT

if ! sysctl -p "$BBR_SYSCTL_FILE" >/dev/null; then
    log_warn "Could not apply BBR settings; restoring the previous config if one existed."
    if [[ -n "$previous_file" ]]; then
        cp -a "$previous_file" "$BBR_SYSCTL_FILE"
        sysctl -p "$BBR_SYSCTL_FILE" >/dev/null 2>&1 || true
    else
        rm -f "$BBR_SYSCTL_FILE"
    fi
    exit 0
fi
actual="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
if [[ "$actual" == "bbr" ]]; then
    log_ok "TCP BBR enabled (qdisc=fq) and persisted in $BBR_SYSCTL_FILE"
else
    log_warn "Requested BBR but kernel reports '$actual'. Check the VPS kernel and provider limitations."
fi
