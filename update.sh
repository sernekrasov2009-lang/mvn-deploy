#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Run as root: sudo bash update.sh" >&2
    exit 1
fi
if ! command -v x-ui >/dev/null 2>&1; then
    echo "3x-ui command not found. Install the panel first with install.sh." >&2
    exit 1
fi
cat <<'NOTICE'
MVN Deploy does not replace the upstream 3x-ui updater.
The official x-ui management menu will open. Choose its update option and read
its confirmation carefully. Do not run upgrades while clients depend on the server.
NOTICE
exec x-ui
