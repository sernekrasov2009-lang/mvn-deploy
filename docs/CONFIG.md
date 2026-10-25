# Конфигурация

Один файл позволяет разворачивать одинаковые серверы без ответов на вопросы:

```bash
sudo cp config/example.yml /etc/mvn-deploy/mvn-deploy.yml
sudo chown root:root /etc/mvn-deploy/mvn-deploy.yml && sudo chmod 600 /etc/mvn-deploy/mvn-deploy.yml
sudo bash install.sh -y                     # файл подхватывается сам
sudo bash install.sh -y --config deploy.yml # или явно
```

**Приоритет:** флаги командной строки и переменные окружения → файл → значения по умолчанию.
Файл должен принадлежать root и не быть доступным на запись другим (иначе скрипт откажется его читать).
Если файл указан через `--config`, но не найден, это ошибка. Без `--config` ищутся по порядку
`/etc/mvn-deploy/mvn-deploy.yml`, `.yaml`, `.conf`.

## Формат

Поддерживается намеренно небольшое подмножество YAML (содержимое файла никогда не выполняется как код):
строки `ключ: значение`, комментарии `#`, списки `[443, 8443]` или построчно через `- 443`, значения `true/false/yes/no`.
Неизвестные ключи и опасные символы в значениях приводят к ошибке с номером строки.
Старый формат `MVN_ИМЯ=значение` (`mvn-deploy.conf`) тоже работает.

## Ключи

| Ключ | Переменная | По умолчанию | Описание |
|---|---|---|---|
| `panel_port` | `MVN_XUI_PANEL_PORT` | случайный | порт панели 3x-ui |
| `ssl` | `MVN_XUI_SSL_MODE` | `auto` | `auto`, `ip`, `domain`, `selfsigned`, `none` |
| `domain` | `MVN_XUI_DOMAIN` | | домен для Let's Encrypt |
| `ssl_fallback` | `MVN_XUI_SSL_FALLBACK` | `selfsigned` | `selfsigned` или `none`, если сертификат не выдан |
| `acme_email` | `MVN_XUI_ACME_EMAIL` | | e-mail для Let's Encrypt |
| `xui_version` | `MVN_XUI_VERSION` | последняя | версия 3x-ui, например `v3.7.0` |
| `extra_tcp_ports` | `MVN_EXTRA_TCP_PORTS` | | порты под inbound-ы (TCP), диапазон `10000:10100` |
| `extra_udp_ports` | `MVN_EXTRA_UDP_PORTS` | | то же для UDP |
| `ssh_ports` | `MVN_SSH_PORTS` | авто | дополнительные SSH-порты |
| `firewall` | `MVN_FIREWALL` | `auto` | `true`/`false` (`false` = не трогать firewall) |
| `fail2ban` | `MVN_FAIL2BAN` | `auto` | `true`/`false` |
| `bbr` | `MVN_BBR` | `auto` | `true`/`false` |
| `f2b_maxretry` / `f2b_findtime` / `f2b_bantime` | `MVN_F2B_*` | `5` / `10m` / `1h` | параметры fail2ban |
| `f2b_ignore_ips` | `MVN_F2B_IGNORE_IPS` | | адреса, которые никогда не банятся |
| `pkg_upgrade` | `MVN_PKG_UPGRADE` | `false` | полное обновление пакетов |
| `allow_conflicts` | `MVN_ALLOW_CONFLICTS` | `false` | продолжать при найденных xray/sing-box |
| `allow_unsupported_os` | `MVN_ALLOW_UNSUPPORTED_OS` | `false` | попробовать на системе вне списка |
| `allow_dns_mismatch` | `MVN_ALLOW_DNS_MISMATCH` | `false` | не отказываться от Let's Encrypt при несовпадении DNS |
| `force_xui_reinstall` | `MVN_FORCE_XUI_REINSTALL` | `false` | переустановить уже установленную 3x-ui |
| `backup_keep` | `MVN_BACKUP_KEEP` | `10` | сколько резервных копий хранить |
