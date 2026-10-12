# Troubleshooting

## Installer says unsupported OS

This first release targets Debian 12/13 and Ubuntu 22.04/24.04/26.04 with systemd and apt. It intentionally refuses to make assumptions on other distributions.

## SSH might be blocked after enabling UFW

The installer allows the port reported by the current SSH session, or ports reported by `sshd -T`. From the VPS provider console, inspect:

```bash
sudo ufw status numbered
sudo systemctl status ssh
sudo sshd -T | grep '^port '
```

Then allow the correct port before reconnecting, for example `sudo ufw allow 2222/tcp`. The provider's firewall/security group may need the same rule.

## 3x-ui panel does not open

```bash
sudo systemctl status x-ui --no-pager
sudo journalctl -u x-ui -n 100 --no-pager
sudo cat /etc/x-ui/install-result.env
sudo ufw status numbered
sudo ss -lntup
```

Check that `XUI_PANEL_PORT` is allowed by UFW and any provider firewall. The TLS certificate flow may fail if TCP/80 or required outbound ACME connections are blocked. Check that the printed URL uses `https://` before entering credentials.

## BBR was skipped

```bash
cat /proc/sys/net/ipv4/tcp_available_congestion_control
sysctl net.ipv4.tcp_congestion_control
uname -r
```

Some kernels or VPS environments do not expose BBR. MVN Deploy skips unsupported kernel settings instead of forcing a broken configuration.

## UFW was not enabled

If the panel port could not be detected, the script deliberately leaves inactive UFW inactive rather than guessing a port. Inspect `/etc/x-ui/install-result.env`. For an old installation without this file, determine the panel port from `sudo x-ui` or the panel settings, then add rules manually and enable UFW only after ensuring SSH access is allowed.

## Already-installed 3x-ui

The installer skips reinstallation to protect the database and inbounds. Inspect service state with `sudo systemctl status x-ui`; use `sudo x-ui` to manage the existing panel.
