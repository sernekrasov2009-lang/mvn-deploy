# Changelog

## 0.1.0-dev
- Исправлено: `update.sh` падал с `tmp: unbound variable`, возвращал код 1 при успехе и оставлял папку в /tmp; при сбое замены каталога теперь восстанавливается прежняя версия.
- Исправлено: `update.sh` и `uninstall.sh` теперь читают `/etc/mvn-deploy/mvn-deploy.conf`, как и `install.sh`.
- Безопасность: каталоги, удаляемые через `rm -rf` (`MVN_INSTALL_DIR`, `MVN_STATE_DIR`), проверяются (`require_safe_dir`).
- Исправлено: вопрос про `apt upgrade` больше не зависит от `MVN_FIREWALL`; `uninstall.sh` удаляет установленную копию и при запуске не из неё.
- `--dry-run` больше не создаёт лог и lock-файл; убрано лишнее сообщение «Stage failed» при неудачной верификации.
- ShellCheck проходит без предупреждений; добавлены unit-тесты.
- Новая архитектура: официальный установщик 3x-ui + UFW + BBR + verify; bootstrap с проверкой SHA-256; dry-run; update/uninstall.
- Не проверено на реальных VPS.
