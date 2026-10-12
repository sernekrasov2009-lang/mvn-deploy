#!/usr/bin/env bash
set -Eeuo pipefail
BASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$BASE_DIR/scripts/lib.sh"
require_root
export DEBIAN_FRONTEND=noninteractive

log_info "Refreshing apt package indexes..."
apt-get update
log_info "Installing required packages..."
apt-get install -y --no-install-recommends ca-certificates curl openssl tar gzip ufw iproute2 procps
log_ok "Required packages installed"
