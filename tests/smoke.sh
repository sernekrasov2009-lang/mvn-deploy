#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

count=0
while IFS= read -r -d '' file; do
    bash -n "$file"
    printf '[OK] Bash syntax: %s\n' "${file#"$ROOT"/}"
    ((count += 1))
done < <(find "$ROOT" -type f -name '*.sh' -not -path '*/.git/*' -print0)

(( count > 0 )) || { echo "No shell scripts found." >&2; exit 1; }

if command -v shellcheck >/dev/null 2>&1; then
    find "$ROOT" -type f -name '*.sh' -not -path '*/.git/*' -print0 | xargs -0 shellcheck
    echo '[OK] ShellCheck passed'
else
    echo '[INFO] ShellCheck is not installed; Bash syntax checks passed.'
fi
