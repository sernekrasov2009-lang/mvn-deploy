# Миграция старого репозитория

Старая архитектура (свой Xray, Reality-конфиг, свой xray.service, свои клиенты) больше не нужна.
Историю Git не переписывайте — архитектурный переход одним-двумя новыми коммитами:

```bash
git rm scripts/xray.sh scripts/reality.sh scripts/service.sh scripts/users.sh
git rm templates/xray.json.tpl templates/xray.service.tpl
git commit -m "Remove standalone Xray/Reality pipeline (3x-ui is installed via its official installer)"
# затем скопируйте из этого пакета: install.sh update.sh uninstall.sh config/ scripts/ docs/ tests/ tools/ README.md .gitattributes .gitignore
bash tests/lint.sh
git add -A && git commit -m "Implement 3x-ui based deployment pipeline"
```

Сохраните существующий `LICENSE`. Параметры `REALITY_DEST`, `REALITY_SERVER_NAME`, `XRAY_CONFIG_FILE` удалены из `defaults.conf`.
Если на тестовом сервере остался `xray.service` от старой версии, MVN Deploy покажет его как конфликт.
