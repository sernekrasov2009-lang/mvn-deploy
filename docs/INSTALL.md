# Installation and operation

## One-command deployment

Run this on a **fresh Debian 12/13 or Ubuntu 22.04/24.04/26.04 VPS** as root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sernekrasov2009-lang/mvn-deploy/main/bootstrap.sh)
```

The bootstrap downloads the selected repository branch archive and launches `install.sh`. By default the selected branch is `main`; set `MVN_DEPLOY_BRANCH` to test a review branch. The installer:

1. verifies root, supported OS, systemd and apt;
2. installs basic tools and UFW;
3. prepares SSH + HTTP/HTTPS firewall allowances without resetting existing rules;
4. enables TCP BBR if the running kernel offers it;
5. downloads and syntax-checks the official 3x-ui installer;
6. runs upstream 3x-ui in unattended mode and requests IP-based TLS;
7. reads the upstream root-only result file to allow the actual panel port;
8. verifies the service and prints access details.

3x-ui itself installs and manages Xray-core. MVN Deploy does not install a second Xray binary, write a competing Xray config, or create a separate Xray systemd unit.

## Interactive and unattended modes

The normal command may ask before enabling UFW on a clean server. This is intentional: UFW's default incoming policy denies traffic not explicitly allowed. For automation with the reviewed defaults:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sernekrasov2009-lang/mvn-deploy/main/bootstrap.sh) --yes
```

Local checkout:

```bash
sudo bash install.sh
sudo bash install.sh --yes
sudo bash install.sh --yes --skip-firewall
sudo bash install.sh --yes --skip-bbr
```

Environment settings:

- `MVN_DEPLOY_NONINTERACTIVE=1` — use defaults without prompts.
- `MVN_DEPLOY_ENABLE_FIREWALL=0` — skip UFW setup.
- `MVN_DEPLOY_ENABLE_BBR=0` — skip BBR setup.
- `MVN_XUI_SSL_MODE=ip|none` — override the 3x-ui TLS mode. `ip` is the default; `none` is not recommended for a publicly exposed login.

Example:

```bash
MVN_DEPLOY_ENABLE_FIREWALL=0 bash install.sh --yes
```

## Panel credentials

The upstream installer writes login details to `/etc/x-ui/install-result.env` with file mode `600` (root-only). MVN Deploy prints the access URL, port, username and password at the end. To view them again:

```bash
sudo cat /etc/x-ui/install-result.env
```

Treat this file like a password. Do not attach it to public GitHub issues, screenshots, or chat messages.

## Firewall behavior

On a fresh UFW installation, the installer allows SSH port(s), TCP/80, TCP/443, UDP/443, and the detected 3x-ui panel TCP port before enabling UFW. It then sets default incoming policy to deny and outgoing policy to allow. It never runs `ufw reset` and does not delete existing custom rules.

If UFW was already active, it only adds/ensures the listed allow rules and leaves existing default policies unchanged. It will not enable UFW if the 3x-ui panel port cannot be detected.

Ports opened here apply only to the VPS operating system. Some VPS providers also have a separate network firewall/security group; configure matching rules there when needed.

When adding a new inbound port in 3x-ui, open the matching protocol/port separately. Examples:

```bash
sudo ufw allow 8443/tcp
sudo ufw allow 8443/udp
sudo ufw status numbered
```

Open only ports that are actually used.

## BBR

If the running kernel exposes `bbr`, MVN Deploy writes `/etc/sysctl.d/99-mvn-deploy-bbr.conf` and applies `fq` + BBR. If BBR is unavailable, the script warns and continues without writing an unsupported setting.

Verify:

```bash
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc
```

BBR affects TCP congestion control; it does not guarantee a particular speed or latency.

## Managing the panel

```bash
sudo x-ui
sudo systemctl status x-ui
sudo journalctl -u x-ui -n 100 --no-pager
```

Use the upstream 3x-ui management menu to manage inbounds, clients, certificates, service status and updates. MVN Deploy intentionally does not create clients, QR codes, VLESS links, or a competing management UI.
