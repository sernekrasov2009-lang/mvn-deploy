# Решение проблем

Журнал: `/var/log/mvn-deploy/install.log` (root, 600). Состояние: `/var/lib/mvn-deploy/`.

| Симптом | Что делать |
|---|---|
| `Unsupported OS/architecture` | Нужны Debian 12/13, Ubuntu 22.04/24.04, amd64/arm64. Ничего не менялось. |
| `systemd is not running` | Контейнеры без systemd не поддерживаются. |
| `Cannot connect to github.com:443` | Проверьте DNS/исходящий трафик/время сервера. |
| `Unattended mode cannot decide…` | Задайте явно: `MVN_FIREWALL=skip`, `MVN_SSH_PORTS=…`, `MVN_ALLOW_CONFLICTS=1`. |
| Другой firewall (firewalld/nftables/iptables) | MVN Deploy его не трогает; откройте SSH, порт панели и VPN-порты сами. |
| Панель не открывается снаружи | Облачный firewall провайдера; порт панели: `x-ui settings`; `sudo ufw status`. |
| `x-ui` не запустилась | `systemctl status x-ui`, `journalctl -u x-ui -n 50`; статус и журнал также в логе установки. |
| BBR `UNSUPPORTED/FAILED` | Ядро/контейнер не позволяет; это честное предупреждение, остальное работает. |
| Потерян доступ по SSH после UFW | Через консоль провайдера: `sudo ufw allow <ssh-порт>/tcp` или `sudo ufw disable`. |
| Забыли пароль панели | `x-ui settings` / меню `x-ui` (сброс штатными средствами 3x-ui). |
