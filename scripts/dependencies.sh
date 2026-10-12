#!/bin/bash

set -e


BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$BASE_DIR/scripts/logger.sh"


log_info "Updating package list..."

apt update -y


log_info "Installing required packages..."


apt install -y \
curl \
wget \
jq \
unzip \
openssl \
qrencode


log_ok "Dependencies installed"
