#!/usr/bin/env bash
set -Eeuo pipefail
cat <<'NOTICE'
MVN Deploy is an installer, not an independent VPN runtime. It does not create
an MVN Deploy systemd service. 3x-ui and its database/configuration are managed
by the upstream x-ui tool.

This script intentionally does NOT delete /etc/x-ui, /usr/local/x-ui, users,
inbounds, credentials, or firewall rules automatically.

To manage/remove 3x-ui, run:
  sudo x-ui

To inspect MVN Deploy's BBR setting:
  cat /etc/sysctl.d/99-mvn-deploy-bbr.conf

Review every removal action and back up /etc/x-ui before making changes.
NOTICE
