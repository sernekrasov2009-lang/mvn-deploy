#!/bin/bash

set -e


BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$BASE_DIR/scripts/logger.sh"
source "$BASE_DIR/config/defaults.conf"


mkdir -p "$XRAY_CONFIG_DIR"


log_info "Generating client UUID..."

UUID=$(cat /proc/sys/kernel/random/uuid)


log_info "Generating Reality keys..."


KEYS=$(xray x25519)


PRIVATE_KEY=$(echo "$KEYS" | grep "Private key" | awk '{print $3}')

PUBLIC_KEY=$(echo "$KEYS" | grep "Public key" | awk '{print $3}')


SHORT_ID=$(openssl rand -hex 8)


log_ok "UUID generated"
log_ok "Reality keys generated"


cat > "$XRAY_CONFIG_FILE" <<EOF
{
  "log": {
    "loglevel": "warning"
  },

  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",

      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],

        "decryption": "none"
      },

      "streamSettings": {
        "network": "tcp",

        "security": "reality",

        "realitySettings": {

          "show": false,

          "dest": "$REALITY_DEST",

          "serverNames": [
            "$REALITY_SERVER_NAME"
          ],

          "privateKey": "$PRIVATE_KEY",

          "shortIds": [
            "$SHORT_ID"
          ]
        }
      }
    }
  ],

  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF


echo "$UUID" > /etc/mvn_uuid
echo "$PUBLIC_KEY" > /etc/mvn_public
echo "$SHORT_ID" > /etc/mvn_shortid


log_ok "Reality configuration created"
