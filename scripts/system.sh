#!/bin/bash

set -e

echo "[SYSTEM] Checking operating system..."

if [ -f /etc/os-release ]; then
    . /etc/os-release
else
    echo "Unsupported system"
    exit 1
fi


case "$ID" in
    debian|ubuntu)
        echo "[OK] Supported OS: $PRETTY_NAME"
        ;;
    *)
        echo "[ERROR] Unsupported OS: $PRETTY_NAME"
        exit 1
        ;;
esac


if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Run as root"
    exit 1
fi


echo "[OK] Root access confirmed"
