# MVN Deploy

Одна команда — подготовленный VPN-сервер. MVN Deploy берёт чистый VPS (Debian/Ubuntu), ставит
**официальную 3x-ui** (она управляет Xray-core), настраивает UFW и TCP BBR, проверяет результат и
показывает адрес панели. Клиентов и inbound-ы вы создаёте уже в панели 3x-ui.

> Статус: версия `0.1.0-dev`. Код написан по спецификации ([docs/SPECIFICATION.txt](docs/SPECIFICATION.txt)),
> прошёл `bash -n` и юнит-тесты, но **ещё не проверен на реальных VPS**. Не объявляйте v1.0.0, пока не
> пройдена матрица из раздела 12 спецификации.

## Что делает

1. Проверяет ОС (Debian 12/13, Ubuntu 22.04/24.04), архитектуру (amd64/arm64), root, systemd, apt, сеть, диск, время.
2. Составляет «снимок» и **план**; `--dry-run` показывает план и ничего не меняет.
3. Ставит только нужные пакеты (без полного `apt upgrade`, если не просили).
4. Запускает официальный установщик 3x-ui (`XUI_NONINTERACTIVE=1`), вывод с паролем не попадает в общий лог.
5. UFW: сначала SSH, потом порт панели и выбранные порты; чужие/существующие правила не сбрасываются.
6. BBR + fq через `/etc/sysctl.d/99-mvn-deploy-bbr.conf`, только если ядро поддерживает.
7. Проверяет службу, порты, firewall, BBR, права файлов и печатает отчёт.

Не делает: собственная панель, ссылки/QR, свой Xray/xray.service, смена SSH-порта, отключение паролей SSH,
перезагрузка, изменение облачного firewall провайдера.

## Установка

Релиз (рекомендуется, после публикации тега):

```bash
curl -fsSL https://raw.githubusercontent.com/sernekrasov2009-lang/mvn-deploy/v1.0.0/install.sh -o /tmp/mvn-deploy-install.sh && sudo bash /tmp/mvn-deploy-install.sh
```

Разработка (ветка `main` изменяема и не проверяется контрольной суммой):

```bash
curl -fsSL https://raw.githubusercontent.com/sernekrasov2009-lang/mvn-deploy/main/install.sh -o /tmp/mvn-deploy-install.sh && sudo MVN_ALLOW_DEV=1 bash /tmp/mvn-deploy-install.sh --dry-run
```

Подробности и все параметры — [docs/INSTALL.md](docs/INSTALL.md). Проблемы — [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).
Безопасность — [docs/SECURITY.md](docs/SECURITY.md). Миграция старого репозитория — [docs/MIGRATION.md](docs/MIGRATION.md).

## Структура

```
install.sh  update.sh  uninstall.sh  config/defaults.conf
scripts/    logger common system dependencies security three_x_ui firewall bbr verify
docs/       INSTALL TROUBLESHOOTING SECURITY MIGRATION SPECIFICATION
tests/      lint.sh unit.sh        tools/make-release.sh
```

## Разработка

```bash
bash tests/lint.sh        # bash -n, ShellCheck, git diff --check, поиск секретов, unit-тесты
bash tools/make-release.sh v1.0.0   # dist/*.tar.gz + .sha256 для GitHub Release
```

Git Bash в Windows не воспроизводит systemd/apt/UFW — полную установку проверяйте на временном VPS.
Лицензия: используйте уже существующий `LICENSE` репозитория (этот пакет его не содержит и не меняет).
