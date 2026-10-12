#!/bin/bash

set -e


BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$BASE_DIR/scripts/logger.sh"
source "$BASE_DIR/config/defaults.conf"


XRAY_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name')


log_info "Latest Xray version: $XRAY_VERSION"


ARCH=$(uname -m)


case "$ARCH" in

    x86_64)
        XRAY_ARCH="64"
        ;;

    aarch64|arm64)
        XRAY_ARCH="arm64-v8a"
        ;;

    *)
        log_error "Unsupported architecture: $ARCH"
        exit 1
        ;;

esac


log_ok "Architecture detected: $ARCH"


TMP_DIR=$(mktemp -d)


DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip"


log_info "Downloading Xray..."

curl -L "$DOWNLOAD_URL" -o "$TMP_DIR/xray.zip"


unzip -o "$TMP_DIR/xray.zip" -d "$TMP_DIR"


install -m 755 "$TMP_DIR/xray" /usr/local/bin/xray


mkdir -p "$XRAY_PATH"


log_ok "Xray installed"


xray version
