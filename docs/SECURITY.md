# Security model and limitations

- Run only as root on a server you administer.
- `bootstrap.sh` downloads this repository over HTTPS. Review the script or pin a known commit/archive before using it for sensitive systems.
- `scripts/xui.sh` downloads the official MHSanaei/3x-ui installation script over HTTPS, checks it with `bash -n`, and runs it. A syntax check is not a cryptographic signature verification; the upstream project remains a software trust dependency.
- 3x-ui's generated credential file is expected at `/etc/x-ui/install-result.env` with mode `600`; never publish it.
- The default panel TLS mode is `ip`, relying on current upstream 3x-ui and ACME/IP-certificate support. Certificate issuance can fail because of provider networking, rate limits, or DNS/IP constraints. Verify that the printed panel URL uses HTTPS before entering credentials.
- Do not use `MVN_XUI_SSL_MODE=none` on a public interface unless the panel is protected by a trusted TLS reverse proxy or reached only through a secure tunnel.
- UFW defaults incoming traffic to deny only when enabling it from an inactive state. SSH access is added first; existing active UFW rules are never reset. Still, review the rules and keep VPS provider console access available during initial setup.
- UFW cannot configure a cloud provider's separate firewall/security group.
- Baseline VPN ports are TCP/443 and UDP/443. If other inbound ports are later created in 3x-ui, explicitly allow them in both firewalls.
- The project does not change SSH daemon settings, disable password authentication, create Unix users, or delete existing data.
- On servers where 3x-ui is already installed, the installer skips reinstallation. It does not overwrite credentials, inbounds, or the panel database.

## Recommended operating practice

1. Use a fresh VPS for the first deployment test.
2. Keep the provider console/recovery terminal open when enabling a firewall.
3. After deployment, verify HTTPS, the systemd service, firewall rules, and the BBR sysctl values.
4. Keep the operating system and 3x-ui/Xray components updated via their supported update paths.
5. Make and test a backup of `/etc/x-ui` before panel updates or configuration changes.
