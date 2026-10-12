#!/bin/bash

set -e


BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$BASE_DIR/scripts/logger.sh"


log_info "Checking operating system..."


if [ -f /etc/os-release ]; then
    source /etc/os-release
else
    log_error "Cannot detect operating system"
    exit 1
fi


case "$ID" in

    debian|ubuntu)
        log_ok "Supported OS: $PRETTY_NAME"
        ;;

    *)
        log_error "Unsupported OS: $PRETTY_NAME"
        exit 1
        ;;

esac


if [ "$EUID" -ne 0 ]; then
    log_error "Run installer as root"
    exit 1
fi


log_ok "Root access confirmed"
