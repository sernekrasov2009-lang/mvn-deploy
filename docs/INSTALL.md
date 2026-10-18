# Установка

## Требования
Root (`sudo`), Debian 12/13 или Ubuntu 22.04/24.04, amd64 или arm64, systemd, apt, доступ к GitHub,
≥ 500 МБ свободного места, корректное время. Облачный firewall провайдера проверьте сами.

## Режимы
- Интерактивный (по умолчанию): спрашивает только при неоднозначности (чужой firewall, неизвестный SSH-порт,
  найденный конфликтующий сервис, доп. порты, необязательный `apt upgrade`).
- Без вопросов: `-y` / `MVN_NONINTERACTIVE=1`, а также когда нет TTY. Опасная неоднозначность = **ошибка до изменений**.
- `--dry-run`: только проверки и план.

## Параметры (переменные окружения или `/etc/mvn-deploy/mvn-deploy.conf`)
Файл — строки `MVN_ИМЯ=значение` (читаются безопасно, не исполняются; владелец root, без записи для group/other). Окружение приоритетнее файла.

| Переменная | По умолчанию | Смысл |
|---|---|---|
| `MVN_FIREWALL` | `auto` | `skip` — не трогать firewall |
| `MVN_SSH_PORTS` | — | дополнительные SSH-порты (к автоопределённым) |
| `MVN_EXTRA_TCP_PORTS` / `MVN_EXTRA_UDP_PORTS` | — | `443`, `443,8443`, `10000:10100` |
| `MVN_BBR` | `auto` | `skip` — не включать BBR |
| `MVN_XUI_VERSION` | последняя стабильная | тег, например `v3.7.0` |
| `MVN_XUI_SSL_MODE` / `MVN_XUI_DOMAIN` | `none` | `ip` / `domain` — сертификат Let's Encrypt силами установщика 3x-ui (откроется 80/tcp) |
| `MVN_XUI_INSTALLER_SHA256` | — | закрепить sha256 официального `install.sh` |
| `MVN_ALLOW_CONFLICTS=1` | 0 | продолжить при найденном xray/sing-box/marzban и т.п. |
| `MVN_APT_UPGRADE=1` | 0 | полный `apt upgrade` |
| `MVN_FORCE_XUI_REINSTALL=1` | 0 | перезапустить установщик 3x-ui поверх существующей |
| `MVN_SHA256` | — | контрольная сумма архива при bootstrap |

Пример без вопросов: `sudo MVN_EXTRA_TCP_PORTS=443 bash install.sh -y`

## После установки
- Пароль/токен: `sudo cat /etc/x-ui/install-result.env` (права 600) или `x-ui settings`. MVN Deploy их **не печатает и не логирует**.
- По умолчанию панель работает по **HTTP** на случайном порту. Используйте SSH-туннель или включите TLS (`MVN_XUI_SSL_MODE`, либо меню `x-ui`).
- Для каждого нового inbound откройте порт: `sudo ufw allow <порт>/tcp` (и в облачном firewall провайдера).

## Повторный запуск, обновление, удаление
- Повторный запуск не переустанавливает 3x-ui, не меняет пароль, не дублирует правила и sysctl-файл.
- `sudo bash /opt/mvn-deploy/update.sh --ref vX.Y.Z` — обновляет только файлы MVN Deploy (с бэкапом и проверкой sha256). 3x-ui обновляется её штатными средствами.
- `sudo bash /opt/mvn-deploy/uninstall.sh` — убирает только созданное MVN Deploy (BBR-файлы, не-SSH правила UFW); 3x-ui и её БД остаются.
  `--backup-xui` делает бэкап `/etc/x-ui` и подсказывает `x-ui uninstall`.
