[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
Type=simple

User=root

ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json

Restart=on-failure
RestartSec=5

LimitNOFILE=1048576


[Install]
WantedBy=multi-user.target
