#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$BASE_DIR/scripts/lib.sh"
# shellcheck source=config/defaults.conf
source "$BASE_DIR/config/defaults.conf"

usage() {
    cat <<'USAGE'
MVN Deploy — one-command 3x-ui server deployment

Usage:
  sudo bash install.sh [options]

Options:
  -y, --yes             Use safe defaults without interactive questions.
      --skip-bbr        Do not configure TCP BBR.
      --skip-firewall   Do not configure UFW.
  -h, --help            Show this help.

Environment overrides:
  MVN_DEPLOY_NONINTERACTIVE=1   Same effect as --yes.
  MVN_DEPLOY_ENABLE_FIREWALL=0  Disable UFW setup by default.
  MVN_DEPLOY_ENABLE_BBR=0       Disable BBR setup by default.
  MVN_XUI_SSL_MODE=ip|none      Upstream 3x-ui panel TLS mode (default: ip).
USAGE
}

SKIP_BBR=0
SKIP_FIREWALL=0
while (($#)); do
    case "$1" in
        -y|--yes) export MVN_DEPLOY_NONINTERACTIVE=1 ;;
        --skip-bbr) SKIP_BBR=1 ;;
        --skip-firewall) SKIP_FIREWALL=1 ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "Unknown option: $1"; usage; exit 2 ;;
    esac
    shift
done

require_root
log_info "$PROJECT_NAME v$PROJECT_VERSION starting."

# Avoid operating on unrelated firewall stacks or unsupported distributions.
bash "$BASE_DIR/scripts/system.sh"
bash "$BASE_DIR/scripts/dependencies.sh"

if (( SKIP_FIREWALL == 0 )) && [[ "${MVN_DEPLOY_ENABLE_FIREWALL:-1}" != "0" ]]; then
    # Open challenge/SSH ports on an already-active UFW before the upstream
    # installer attempts certificate issuance. On an inactive UFW this only
    # prepares rules; it does not enable the firewall yet.
    bash "$BASE_DIR/scripts/firewall.sh" prepare
else
    log_warn "UFW setup has been skipped by request."
fi

if (( SKIP_BBR == 0 )) && [[ "${MVN_DEPLOY_ENABLE_BBR:-1}" != "0" ]]; then
    bash "$BASE_DIR/scripts/bbr.sh"
else
    log_warn "BBR setup has been skipped by request."
fi

bash "$BASE_DIR/scripts/xui.sh"

if (( SKIP_FIREWALL == 0 )) && [[ "${MVN_DEPLOY_ENABLE_FIREWALL:-1}" != "0" ]]; then
    bash "$BASE_DIR/scripts/firewall.sh" apply
fi

bash "$BASE_DIR/scripts/verify.sh"
bash "$BASE_DIR/scripts/summary.sh"
log_ok "Deployment flow finished. Review the notes printed above before disconnecting."
