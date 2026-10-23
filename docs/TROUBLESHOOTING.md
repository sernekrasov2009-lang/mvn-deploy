# Решение проблем

Журнал: `/var/log/mvn-deploy/install.log` (root, 600). Состояние: `/var/lib/mvn-deploy/`.
Перед любым изменением скрипт проверяет систему: при ошибке на этом этапе **ничего не изменено**.

## Проверки перед установкой

| Симптом | Причина и решение |
|---|---|
| `Unsupported system` | Дистрибутив неизвестен или слишком старый (Debian 10, Ubuntu 18.04, CentOS 7…). См. [COMPATIBILITY.md](COMPATIBILITY.md). Принудительно: `MVN_ALLOW_UNSUPPORTED_OS=1` |
| `Unsupported CPU architecture` | 3x-ui не собирается под эту архитектуру (например, riscv64) |
| `No supported init system` | Контейнер без systemd/OpenRC. Нужна полноценная виртуальная машина |
| `No supported package manager` | Не найден apt/dnf/yum/zypper/pacman/apk |
| `Required commands are missing` | Нет базовых утилит (coreutils, util-linux, glibc-bin). Установите их |
| `Not enough free disk space` / `out of inodes` / `not writable` | Освободите место (`df -h`, `df -i`), проверьте, что `/tmp` и `/var/lib` доступны на запись |
| `System clock looks wrong` | `timedatectl set-ntp true` или `date -s`; без верного времени не работают TLS и Let's Encrypt |
| `DNS resolution failed for github.com` | Проверьте `/etc/resolv.conf` и `getent hosts github.com` |
| `Cannot connect to github.com:443` | Исходящий фильтр провайдера, **сеть только с IPv6** (у GitHub нет IPv6: нужен NAT64/DNS64 или IPv4), либо прокси: `export HTTPS_PROXY=…; sudo -E bash …` |
| `TLS to GitHub failed` | Неверное время или устаревший `ca-certificates` |
| `Another MVN Deploy run is in progress` | Параллельный запуск; дождитесь или удалите `/run/lock/mvn-deploy.lock` после проверки, что процесса нет |
| Предупреждение о малой памяти | Меньше 256 МБ ОЗУ: добавьте swap, иначе установка может быть убита OOM |
| Предупреждение о контейнере | LXC/OpenVZ/Docker: BBR и firewall может запретить хост; это предупреждения, не ошибки |

## Пакеты

Скрипт сам повторяет сетевые операции, чинит прерванный `dpkg` и подсказывает причину сбоя.

| Подсказка | Что делать |
|---|---|
| Другой менеджер пакетов занят | Работает автообновление; подождите несколько минут и запустите снова |
| Прерванная операция dpkg | `sudo dpkg --configure -a`, затем снова |
| Репозитории недоступны | DNS, firewall, прокси или умерший mirror (`curl -I https://github.com`) |
| Пакет недоступен в репозиториях | Репозиторий отключён или релиз снят с поддержки; для RHEL-семейства может понадобиться EPEL |
| Диск заполнен | Освободите место и повторите |
| Ключ репозитория / время | Проверьте `date` и настройки репозитория |

Необязательные пакеты (ufw/firewalld, fail2ban, kmod, procps) при неудаче дают предупреждение, остальная установка продолжается.

## Панель и HTTPS

| Симптом | Причина и решение |
|---|---|
| `Let's Encrypt will not work here: port 80 …` | Порт 80 занят (nginx/apache). Освободите его или выберите `--ssl selfsigned` |
| `domain resolves to … but this server is …` | A-запись домена не указывает на сервер. Исправьте DNS и подождите обновления; или `MVN_ALLOW_DNS_MISMATCH=1` |
| `address … is not public (NAT)` | Сервер за NAT: публичный сертификат на IP невозможен, применяется самоподписанный |
| `Let's Encrypt certificate was NOT issued` | Порт 80 закрыт у провайдера, неверный DNS или лимиты Let's Encrypt. Панель получила самоподписанный сертификат |
| Браузер предупреждает о сертификате | Самоподписанный сертификат: примите его один раз либо используйте домен |
| Панель не открывается снаружи | Облачный firewall провайдера; порт: `x-ui settings`; правила: `sudo ufw status` или `sudo firewall-cmd --list-all` |
| `x-ui` не запустилась | `systemctl status x-ui`, `journalctl -u x-ui -n 50` (OpenRC: `rc-service x-ui status`); статус и журнал также в логе установки |
| Забыли пароль панели | `x-ui settings` или меню `x-ui` |

## Firewall и SSH

| Симптом | Что делать |
|---|---|
| `Unattended mode cannot decide…` | Найден чужой firewall или конфликт. Задайте явно: `MVN_FIREWALL=skip`, `MVN_SSH_PORTS=…`, `MVN_ALLOW_CONFLICTS=1` |
| Docker добавил правила iptables | Скрипт считает это чужим firewall и не вмешивается: откройте порты сами или `MVN_FIREWALL=skip` |
| `Enabling … failed … switched off again` | Контейнер или ядро без поддержки; firewall оставлен выключенным, доступ сохранён. Откройте порты у провайдера |
| Потерян доступ по SSH | Консоль провайдера: `sudo ufw allow <ssh-порт>/tcp` или `sudo ufw disable`; для firewalld: `sudo firewall-cmd --permanent --add-port=<порт>/tcp && sudo firewall-cmd --reload` |
| fail2ban не запустился | Файл `/etc/fail2ban/jail.d/mvn-deploy.local` удалён автоматически, SSH не затронут; смотрите `journalctl -u fail2ban` |
| Вас заблокировал fail2ban | `sudo fail2ban-client set sshd unbanip <адрес>`; постоянные исключения: `MVN_F2B_IGNORE_IPS` |

## Прочее

| Симптом | Что делать |
|---|---|
| BBR `UNSUPPORTED/FAILED` | Ядро или контейнер не позволяет; остальное работает |
| `Config … must be owned by root` | `sudo chown root:root /etc/mvn-deploy/mvn-deploy.conf && sudo chmod 600 …` |
| Нужно начать заново | `sudo bash /opt/mvn-deploy/uninstall.sh`, затем установка; 3x-ui при этом не удаляется |
