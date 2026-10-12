#!/bin/bash

set -e


VERSION="1.0.0"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


source "$BASE_DIR/scripts/logger.sh"


clear


echo "
====================================
        MVN Deploy v$VERSION
     Xray VLESS Reality Installer
====================================
"


if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root"
    exit 1
fi


log_ok "Root access confirmed"


source "$BASE_DIR/config/defaults.conf"


bash "$BASE_DIR/scripts/system.sh"

bash "$BASE_DIR/scripts/dependencies.sh"

bash "$BASE_DIR/scripts/xray.sh"

bash "$BASE_DIR/scripts/reality.sh"

bash "$BASE_DIR/scripts/service.sh"

log_ok "Base installation completed"
