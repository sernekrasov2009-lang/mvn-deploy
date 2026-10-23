# Changelog

## 0.1.0-dev
- Новое: поддержка семейств Debian/Ubuntu, RHEL (Alma, Rocky, RHEL, Oracle, CentOS Stream, Fedora, Amazon Linux), Arch/Manjaro, openSUSE и Alpine. Слой `platform.sh`: определение дистрибутива, пакетный менеджер (apt/dnf/yum/pacman/zypper/apk), systemd и OpenRC.
- Новое: firewalld как второй firewall-бэкенд (RHEL, SUSE); учитывается зона сетевого интерфейса; правила SSH создаются до включения.
- Новое: fail2ban подбирает источник логов под дистрибутив (auth.log, /var/log/secure, журнал), на RHEL подключает EPEL; нехватка пакета не прерывает установку.
- Надёжность: диагностика сбоев пакетных менеджеров с подсказками, починка прерванного dpkg, проверка inodes/записи/памяти/контейнера, различение сбоев DNS, соединения и TLS, предупреждение про IPv6-only сеть.
- Надёжность: сбой firewall (контейнер, нет пакета, ядро) больше не обрывает установку: откат и предупреждение; доступ по SSH сохраняется.
- Надёжность: английский вывод утилит (`LC_ALL=C`), полный `PATH` (запуск через `su` без `-`), `umask 022`.
- CI: GitHub Actions: lint и unit-тесты, dry-run на 17 образах дистрибутивов, полная установка на Ubuntu 22.04/24.04.
- Переименовано: `MVN_APT_UPGRADE` -> `MVN_PKG_UPGRADE` (старое имя работает). Новое: `MVN_ALLOW_UNSUPPORTED_OS`.
- README переписан; добавлены docs/COMPATIBILITY.md и расширенный docs/TROUBLESHOOTING.md.
- Новое: выбор порта панели (`--panel-port`) и HTTPS (`--ssl auto|ip|domain|selfsigned|none`, `--domain`); интерактивные вопросы при запуске без `-y`.
- Новое: HTTPS проверяется по факту; если Let's Encrypt не выдал сертификат, панель получает самоподписанный (`MVN_XUI_SSL_FALLBACK`). Предварительные проверки порта 80, публичного IP и DNS домена.
- Новое: fail2ban (jail `sshd`, один файл в `jail.d`, свой jail пользователя не перезаписывается); удаляется через `uninstall.sh`.
- Адрес панели в итоге строится по ответу самой панели (http/https), а не по сводке установщика.
- Исправлено: `update.sh` падал с `tmp: unbound variable`, возвращал код 1 при успехе и оставлял папку в /tmp; при сбое замены каталога теперь восстанавливается прежняя версия.
- Исправлено: `update.sh` и `uninstall.sh` теперь читают `/etc/mvn-deploy/mvn-deploy.conf`, как и `install.sh`.
- Безопасность: каталоги, удаляемые через `rm -rf` (`MVN_INSTALL_DIR`, `MVN_STATE_DIR`), проверяются (`require_safe_dir`).
- Исправлено: вопрос про `apt upgrade` больше не зависит от `MVN_FIREWALL`; `uninstall.sh` удаляет установленную копию и при запуске не из неё.
- `--dry-run` больше не создаёт лог и lock-файл; убрано лишнее сообщение «Stage failed» при неудачной верификации.
- ShellCheck проходит без предупреждений; добавлены unit-тесты.
- Новая архитектура: официальный установщик 3x-ui + UFW + BBR + verify; bootstrap с проверкой SHA-256; dry-run; update/uninstall.
- Не проверено на реальных VPS.
