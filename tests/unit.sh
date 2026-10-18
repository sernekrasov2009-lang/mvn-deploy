#!/usr/bin/env bash
# Unit tests for pure helper functions (no root, no systemd required).
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/logger.sh"; source "${ROOT}/scripts/common.sh"
MVN_NONINTERACTIVE=1
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
assert_eq() { [[ "$1" == "$2" ]] && ok || bad "$3: expected '$2', got '$1'"; }
assert_true()  { if "$@"; then ok; else bad "expected success: $*"; fi; }
assert_false() { if "$@"; then bad "expected failure: $*"; else ok; fi; }

# ports
assert_true valid_port 22; assert_true valid_port 65535
assert_false valid_port 0; assert_false valid_port 65536; assert_false valid_port abc
assert_true valid_port_spec 10000:10100; assert_false valid_port_spec 10100:10000; assert_false valid_port_spec 1:2:3
declare -a arr=()
parse_port_list arr "443, 8443 443 10000:10100"; assert_eq "${arr[*]}" "443 8443 10000:10100" "parse_port_list dedupe"
assert_false parse_port_list arr "22,abc"
parse_port_list arr ""; assert_eq "${#arr[@]}" "0" "empty list"
assert_true array_contains b a b c; assert_false array_contains z a b c

# kv_get: parses without sourcing
printf "XUI_PANEL_PORT=2053\nXUI_PASSWORD=\$(touch %s/pwned)\nXUI_WEB_BASE_PATH='abc'\n" "${T}" > "${T}/r.env"
assert_eq "$(kv_get "${T}/r.env" XUI_PANEL_PORT)" "2053" "kv_get port"
assert_eq "$(kv_get "${T}/r.env" XUI_WEB_BASE_PATH)" "abc" "kv_get quoted"
kv_get "${T}/r.env" XUI_PASSWORD > /dev/null; assert_false test -e "${T}/pwned"

# redaction
out="$(printf 'Username: admin\nPassword: s3cret\nAccess URL: http://1.2.3.4:2053/xyz\nPort: 2053\n\033[32mAPI Token: tok\033[0m\n' | redact_stream)"
assert_false grep -q 's3cret' <<< "${out}"; assert_false grep -q 'tok$' <<< "${out}"; assert_false grep -q 'xyz' <<< "${out}"
assert_true grep -q 'Port: 2053' <<< "${out}"

# state
MVN_STATE_DIR="${T}/state"
state_set a 1; state_set a 2; state_add r "22/tcp ssh"; state_add r "22/tcp ssh"; state_add r "2053/tcp panel"
assert_eq "$(state_get a)" "2" "state_set replaces"
assert_eq "$(state_list r | wc -l | tr -d ' ')" "2" "state_add dedupes"
state_del r "2053/tcp panel"; assert_eq "$(state_list r | wc -l | tr -d ' ')" "1" "state_del"
assert_eq "$(stat -c %a "${MVN_STATE_DIR}")" "700" "state dir mode"

# user config: whitelisted keys only, env wins
if [[ "${EUID}" -eq 0 ]]; then
  printf 'MVN_BBR=skip\nMVN_EXTRA_TCP_PORTS=443,8443 # c\n' > "${T}/c.conf"; chmod 600 "${T}/c.conf"
  MVN_CONFIG_FILE="${T}/c.conf"; MVN_BBR="auto"; unset MVN_EXTRA_TCP_PORTS || true
  load_user_config
  assert_eq "${MVN_BBR}" "auto" "env beats file"; assert_eq "${MVN_EXTRA_TCP_PORTS}" "443,8443" "file fills unset"
  printf 'PATH=/tmp\n' > "${T}/bad.conf"; chmod 600 "${T}/bad.conf"
  assert_false bash -c "source '${ROOT}/scripts/logger.sh'; source '${ROOT}/scripts/common.sh'; MVN_CONFIG_FILE='${T}/bad.conf' load_user_config"
  printf 'MVN_BBR=$(id)\n' > "${T}/bad2.conf"; chmod 600 "${T}/bad2.conf"
  assert_false bash -c "source '${ROOT}/scripts/logger.sh'; source '${ROOT}/scripts/common.sh'; MVN_CONFIG_FILE='${T}/bad2.conf' load_user_config"
fi

# safe directories (these get rm -rf'ed)
assert_true safe_dir_ok /opt/mvn-deploy; assert_true safe_dir_ok /var/lib/mvn-deploy
for bad in / /usr /opt /opt/foo /usr/local /opt/mvn-deploy/../etc relative/mvn-deploy "/opt/mvn deploy" ""; do assert_false safe_dir_ok "${bad}"; done

# retry
n=0; flaky() { n=$((n + 1)); ((n >= 3)); }
assert_true retry 3 0 flaky 2> /dev/null
assert_false retry 2 0 false 2> /dev/null

echo "passed=${PASS} failed=${FAIL}"
((FAIL == 0))
