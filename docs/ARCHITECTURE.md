# Архитектура

MVN Deploy — набор bash-модулей. Точки входа (`install.sh`, `update.sh`, `uninstall.sh`, `bin/mvn-deploy`) только
подключают модули и вызывают их функции. Модули не запускают код при загрузке: они лишь определяют функции и глобальные переменные.

## Принципы

1. **Сначала чтение, потом изменения.** Стадии 1–3 ничего не меняют; `--dry-run` останавливается после плана.
2. **Не ломать доступ.** SSH разрешается до включения firewall; при неудаче firewall выключается обратно.
3. **Необязательное не прерывает обязательное.** Firewall, fail2ban, BBR и дополнительные пакеты при сбое дают предупреждение.
4. **Никакого `eval` и `source` для пользовательских данных.** Конфиг читается строгим разбором с белым списком ключей.
5. **Своё удаляем, чужое не трогаем.** Каждое созданное правило или файл записывается в состояние; `uninstall.sh` удаляет только записанное.
6. **Английский вывод утилит** (`LC_ALL=C`): мы разбираем их вывод.

## Поток установки

```
install.sh ── bootstrap (скачать проект, проверить SHA-256) ── основной запуск
 1 preflight   sys_check_*          system.sh, platform.sh
 2 inventory   sys_detect_*         system.sh
 3 plan        xui_plan fw_plan f2b_plan deps_compute_missing
 4 deps        deps_install fw_prepare          dependencies.sh
 5 security    sec_prepare                       security.sh
 6 3x-ui       xui_apply (+ panel_tls)           three_x_ui.sh, panel_tls.sh
 7 firewall    fw_apply                          firewall.sh
 8 fail2ban    f2b_apply                         fail2ban.sh
 9 bbr         bbr_apply                         bbr.sh
10 verify      verify_all                        verify.sh
11 report      report_print                      common.sh
```

Каждая стадия запускается через `run_stage`: имя стадии попадает в сообщение об ошибке (`trap ERR`), статус — в итоговую таблицу.

## Модули

| Файл | Ответственность |
|---|---|
| `scripts/logger.sh` | цвета, `log_*`, журнал (`/var/log/mvn-deploy`), маскирование секретов |
| `scripts/common.sh` | `die`, `retry`, подтверждения, состояние (`state_*`), разбор портов, **загрузка конфига (kv и YAML)**, отчёт |
| `scripts/platform.sh` | семейство дистрибутива, пакетный менеджер, init; `pkg_*` и `svc_*` — **единственное место, где вызываются apt/dnf/systemctl** |
| `scripts/system.sh` | проверки и инвентаризация (диск, время, сеть, SSH-порты, firewall, конфликты) |
| `scripts/dependencies.sh` | какие пакеты не хватает и как их поставить |
| `scripts/security.sh` | права, каталог проекта, команда `mvn-deploy` |
| `scripts/three_x_ui.sh` | запуск официального установщика, чтение результата, адрес панели |
| `scripts/panel_tls.sh` | HTTPS панели: Let's Encrypt, самоподписанный сертификат, проверка схемы |
| `scripts/firewall.sh` | UFW и firewalld за общим интерфейсом `fw_allow` / `fw_status_allows` |
| `scripts/fail2ban.sh` | jail `sshd` одним файлом |
| `scripts/bbr.sh` | TCP BBR + fq |
| `scripts/verify.sh` | проверка итогового состояния |
| `scripts/backup.sh` | резервные копии и восстановление |
| `scripts/doctor.sh`, `scripts/cli.sh` | `mvn-deploy doctor` / `status` |

## Состояние

`/var/lib/mvn-deploy/state` — строки `ключ=значение` (права 600). Примеры: `ufw_rule=22/tcp ssh`, `firewalld_rule=public 443/tcp extra`,
`f2b_jail=1`, `cli_link=/usr/local/bin/mvn-deploy`. По ним `uninstall.sh` знает, что удалять.

## Как написать свой модуль

1. Создайте `scripts/имя.sh` с заголовком `#!/usr/bin/env bash` и `# shellcheck shell=bash`. Только функции и переменные.
2. Определите `имя_plan` (только чтение; заполняет переменные и тексты плана), `имя_apply` (изменения) и при необходимости `имя_verify`.
3. Пакеты ставьте через `pkg_install_safe`, службы включайте через `svc_*`, команды выполняйте через `run_logged`.
4. Необязательные возможности при сбое возвращайте как предупреждение: `report_add "Имя" "WARN" "причина"` и `return 0`.
5. Добавьте модуль в список в `install.sh` и (если нужен в командах) в `bin/mvn-deploy`.
6. Напишите тесты в `tests/unit.sh` и запустите `bash tests/lint.sh`.

## Тесты

| Уровень | Что | Где |
|---|---|---|
| Статика | `bash -n`, ShellCheck, shfmt, поиск секретов | `tests/lint.sh` |
| Unit | чистые функции, разбор конфига, классификация ОС, команды firewalld на заглушках, проверка архивов | `tests/unit.sh` |
| Dry-run | определение ОС и план на 16 образах дистрибутивов | `.github/workflows/ci.yml` |
| Интеграция | реальная установка на Ubuntu 22.04/24.04, `doctor`, backup/restore, повторный запуск, удаление | `.github/workflows/ci.yml` |
