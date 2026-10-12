<div align="center">

# MVN Deploy

**One-command VPN server deployment**

Deploy a clean Debian/Ubuntu VPS with **3x-ui + its managed Xray-core**, a safe UFW baseline, and TCP BBR when supported.

[![CI](https://github.com/sernekrasov2009-lang/mvn-deploy/actions/workflows/ci.yml/badge.svg)](https://github.com/sernekrasov2009-lang/mvn-deploy/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

</div>

## Quick start

On a fresh Debian 12/13 or Ubuntu 22.04/24.04/26.04 VPS, connect over SSH as root and run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sernekrasov2009-lang/mvn-deploy/main/bootstrap.sh)
```

To test a review branch before merging, use its name in `MVN_DEPLOY_BRANCH` and the raw bootstrap URL.

For automation using reviewed defaults:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sernekrasov2009-lang/mvn-deploy/main/bootstrap.sh) --yes
```

## What it does

- checks OS, root privileges, systemd and required package manager;
- installs a small set of required packages;
- safely prepares firewall rules for SSH, ACME/HTTP, HTTPS, UDP/443, and the real 3x-ui panel port;
- enables TCP BBR + `fq` if the running kernel supports BBR;
- invokes the official 3x-ui installation script in unattended mode;
- requests the upstream panel's IP-based TLS mode;
- verifies `x-ui.service` and prints the generated panel access details.

## What it intentionally does not do

- does not install a second, separate Xray-core;
- does not create custom Xray JSON or a competing Xray systemd service;
- does not create VPN clients, UUIDs, QR codes, or VLESS links;
- does not change SSH authentication settings or delete existing panel data;
- does not configure a VPS provider's external firewall.

3x-ui is responsible for Xray-core, panel settings, inbounds, clients, statistics, and its supported update process.

## Important safety notes

- Test on a fresh VPS first and keep provider console access available.
- UFW uses default incoming deny when activated from an inactive state. The installer allows SSH first, then common service ports and the panel port. Existing active UFW rules are not reset.
- If you create an inbound on a port other than TCP/443 or UDP/443, open that port in UFW and the provider firewall if one exists.
- The generated panel credentials are stored in `/etc/x-ui/install-result.env` with mode `600`. Treat them as secrets.
- Verify that the panel URL uses HTTPS before entering credentials. The default TLS mode is `ip`; ACME certificate issuance can still fail in restrictive provider networks.

## Docs

- [Installation and operation](docs/INSTALL.md)
- [Migration from the current prototype](MIGRATION.md)
- [Security model](docs/SECURITY.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)

## Development checks

```bash
bash tests/smoke.sh
```

CI runs syntax checks and ShellCheck on project shell scripts. Contributions should keep modules idempotent, preserve existing panel data, and never silently reset the firewall.

## Upstream dependency

3x-ui: https://github.com/MHSanaei/3x-ui

MVN Deploy orchestrates the upstream installer; it does not repackage 3x-ui or Xray-core.

## License

MIT. The upstream 3x-ui project has its own license and terms; see its repository for details.
