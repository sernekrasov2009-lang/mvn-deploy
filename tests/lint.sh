#!/usr/bin/env bash
# Local quality gate: bash -n, ShellCheck, git diff --check, secret scan, unit tests.
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${ROOT}" || exit 1
fail=0
mapfile -t files < <({
  find . -name '*.sh' -not -path './.git/*'
  echo ./bin/mvn-deploy
} | sort)

echo "== bash -n =="
for f in "${files[@]}"; do bash -n "${f}" || {
  echo "syntax error: ${f}"
  fail=1
}; done

echo "== ShellCheck =="
if command -v shellcheck > /dev/null 2>&1; then
  shellcheck -x -S warning "${files[@]}" || fail=1
else
  echo "shellcheck is not installed (apt install shellcheck / brew install shellcheck)"
  fail=1
fi

echo "== shfmt =="
if command -v shfmt > /dev/null 2>&1; then
  shfmt -d -i 2 -ci -sr "${files[@]}" || fail=1
else
  echo "shfmt is not installed, skipped (CI runs it)"
fi

echo "== git diff --check =="
if git rev-parse --git-dir > /dev/null 2>&1; then git diff --check || fail=1; else echo "not a git repo, skipped"; fi

echo "== secret scan =="
if grep -rInE --exclude-dir=.git --exclude=lint.sh \
  -e 'BEGIN [A-Z ]*PRIVATE KEY' \
  -e '(password|passwd|token|secret)[A-Za-z_]*[[:space:]]*=[[:space:]]*["'\''][^"'\''$ ]{6,}["'\'']' .; then
  echo "possible secret committed"
  fail=1
fi
if grep -rInE --exclude-dir=.git --exclude=lint.sh --exclude=unit.sh --exclude='*.md' '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' . | grep -vE '1\.1\.1\.1|127\.0\.0\.1|0\.0\.0\.0|1\.2\.3\.4|5\.6\.7\.8|192\.0\.2\.|198\.51\.100\.|203\.0\.113\.'; then
  echo "hard-coded IP address found"
  fail=1
fi

echo "== unit tests =="
bash tests/unit.sh || fail=1

((fail == 0)) && echo "ALL CHECKS PASSED" || echo "CHECKS FAILED"
exit "${fail}"
