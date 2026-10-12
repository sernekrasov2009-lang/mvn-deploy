#!/usr/bin/env bash
# Download the current repository archive and run its modular installer.
set -Eeuo pipefail

REPO="sernekrasov2009-lang/mvn-deploy"
BRANCH="${MVN_DEPLOY_BRANCH:-main}"
ARCHIVE_URL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"

if ! command -v curl >/dev/null 2>&1; then
    echo "[ERROR] curl is required. Install curl first." >&2
    exit 1
fi
if ! command -v tar >/dev/null 2>&1; then
    echo "[ERROR] tar is required. Install tar first." >&2
    exit 1
fi

WORK_DIR="$(mktemp -d -t mvn-deploy.XXXXXX)"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT INT TERM
mkdir -p "$WORK_DIR/repo"

echo "[+] Downloading MVN Deploy from ${REPO} (${BRANCH})..."
curl --proto '=https' --tlsv1.2 -fsSL "$ARCHIVE_URL" -o "$WORK_DIR/source.tar.gz"
tar -xzf "$WORK_DIR/source.tar.gz" --strip-components=1 -C "$WORK_DIR/repo"

if [[ ! -f "$WORK_DIR/repo/install.sh" ]]; then
    echo "[ERROR] The downloaded archive does not contain install.sh." >&2
    exit 1
fi

bash "$WORK_DIR/repo/install.sh" "$@"
