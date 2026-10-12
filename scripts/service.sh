#!/bin/bash

set -e


BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$BASE_DIR/scripts/logger.sh"
source "$BASE_DIR/config/defaults.conf"


SERVICE_FILE="/etc/systemd/system/xray.service"


log_info "Creating Xray systemd service..."


cp "$BASE_DIR/templates/xray.service.tpl" "$SERVICE_FILE"


systemctl daemon-reload


log_info "Checking Xray configuration..."


xray run -test -config "$XRAY_CONFIG_FILE"


systemctl enable xray


systemctl restart xray


if systemctl is-active --quiet xray; then
    log_ok "Xray service is running"
else
    log_error "Xray failed to start"
    systemctl status xray
    exit 1
fi
