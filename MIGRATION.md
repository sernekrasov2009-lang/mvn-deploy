# Migrating the existing repository to the 0.2.0 layout

This archive is a clean replacement layout based on the project goals and the
files shown during development. It was not produced by an authenticated GitHub
checkout; the live repository could not be fetched in this runtime. Before
pushing, compare the archive with the current repository and keep any personal
changes you added after the conversation.

The old prototype modules `scripts/logger.sh`, `scripts/reality.sh`, `scripts/service.sh`,
`scripts/users.sh`, `scripts/xray.sh`, `templates/xray.json.tpl`, and
`templates/xray.service.tpl` belong to the abandoned custom-Xray implementation.
The replacement uses `scripts/xui.sh` to run the official 3x-ui installer, so
those old files should be removed from the Git repository after reviewing them.

Suggested workflow from Git Bash, in your existing local clone:

1. Back up the repository folder or make a Git branch:

   ```bash
   git switch -c refactor/official-3x-ui-deployment
   git status
   ```

2. Extract the downloaded archive to a temporary folder. Copy the new files and
   folders into the root of `Documents/mvn-deploy`, overwriting files when asked.
   Do not overwrite the `.git` folder.

3. Remove only the obsolete prototype files listed above (if they exist):

   ```bash
   rm -f scripts/logger.sh scripts/reality.sh scripts/service.sh scripts/users.sh scripts/xray.sh
   rm -f templates/xray.json.tpl templates/xray.service.tpl
   rmdir templates 2>/dev/null || true
   ```

4. Review the result and run local syntax checks:

   ```bash
   bash tests/smoke.sh
   git status --short
   git diff --check
   ```

5. Commit and push:

   ```bash
   git add -A
   git commit -m "Refactor deployment around official 3x-ui installer"
   git push -u origin refactor/official-3x-ui-deployment
   ```

6. Inspect the branch on GitHub before merging it into `main`. To test that
   branch on a disposable VPS before merging, run (after the push succeeds):

   ```bash
   MVN_DEPLOY_BRANCH=refactor/official-3x-ui-deployment bash <(curl -fsSL https://raw.githubusercontent.com/sernekrasov2009-lang/mvn-deploy/refactor/official-3x-ui-deployment/bootstrap.sh)
   ```

   Do not test the installer first on a server that already hosts your working
   VPN; use a fresh test VPS.
