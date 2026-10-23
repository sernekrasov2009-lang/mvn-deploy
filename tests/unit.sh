#!/usr/bin/env bash
# Unit tests for pure helper functions (no root, no systemd required).
# shellcheck disable=SC1090,SC2034  # sourced modules and variables used by them
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/logger.sh"; source "${ROOT}/scripts/common.sh"
for _m in platform panel_tls three_x_ui firewall fail2ban; do source "${ROOT}/scripts/${_m}.sh"; done; unset _m
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

# distribution classification
cls() { plat_classify "$@"; printf '%s/%s' "${PLAT_FAMILY}" "${PLAT_SUPPORT}"; }
assert_eq "$(cls debian "" 12)" "debian/supported" "debian 12"; assert_eq "$(cls debian "" "")" "debian/supported" "debian testing/sid"
assert_eq "$(cls debian "" 10)" "debian/old" "debian 10"; assert_eq "$(cls debian "" 11)" "debian/old" "debian 11 is EOL"; assert_eq "$(cls ubuntu debian 24.04)" "debian/supported" "ubuntu 24.04"
assert_eq "$(cls ubuntu debian 18.04)" "debian/old" "ubuntu 18.04"; assert_eq "$(cls ubuntu debian 26.04)" "debian/supported" "newer ubuntu"
assert_eq "$(cls linuxmint "ubuntu debian" 22)" "debian/derivative" "mint"; assert_eq "$(cls kali debian 2025.3)" "debian/derivative" "kali"
assert_eq "$(cls almalinux "rhel centos fedora" 9.4)" "rhel/supported" "alma 9"; assert_eq "$(cls rocky "rhel centos fedora" 8.10)" "rhel/supported" "rocky 8"
assert_eq "$(cls rhel fedora 10.0)" "rhel/supported" "rhel 10"; assert_eq "$(cls ol fedora 9.3)" "rhel/supported" "oracle 9"
assert_eq "$(cls centos rhel 7)" "rhel/old" "centos 7"; assert_eq "$(cls centos "rhel fedora" 9)" "rhel/supported" "centos stream 9"
assert_eq "$(cls fedora "" 42)" "rhel/supported" "fedora 42"; assert_eq "$(cls amzn "fedora" 2023)" "rhel/supported" "amazon 2023"; assert_eq "$(cls amzn "centos rhel fedora" 2)" "rhel/old" "amazon 2"
assert_eq "$(cls arch "" "")" "arch/supported" "arch"; assert_eq "$(cls manjaro arch "")" "arch/supported" "manjaro"
assert_eq "$(cls opensuse-leap "suse opensuse" 15.6)" "suse/supported" "leap 15.6"; assert_eq "$(cls opensuse-tumbleweed "opensuse suse" 20261001)" "suse/supported" "tumbleweed"
assert_eq "$(cls alpine "" 3.22.1)" "alpine/supported" "alpine 3.22"; assert_eq "$(cls alpine "" 3.12.0)" "alpine/old" "alpine 3.12"
assert_eq "$(cls endeavouros arch "")" "/unknown" "arch derivative is not safe with the official installer"
assert_eq "$(cls gentoo "" "")" "/unknown" "gentoo"
assert_true ver_ge 24.04 20.04; assert_false ver_ge 18.04 20.04; assert_true ver_ge "" 9; assert_true ver_ge 10 9
assert_eq "$(plat_map_arch x86_64)" amd64; assert_eq "$(plat_map_arch aarch64)" arm64; assert_eq "$(plat_map_arch armv7l)" armv7
assert_eq "$(plat_map_arch i686)" 386; assert_eq "$(plat_map_arch s390x)" s390x; assert_eq "$(plat_map_arch riscv64)" ""
# package names per manager
for pm in apt dnf yum pacman zypper apk; do PLAT_PM="${pm}"; assert_true test -n "$(pkg_names iproute)"; assert_true test -n "$(pkg_names procps)"; done
PLAT_PM=apt; assert_eq "$(pkg_names iproute)" iproute2; assert_eq "$(pkg_names procps)" procps
PLAT_PM=dnf; assert_eq "$(pkg_names iproute)" iproute; assert_eq "$(pkg_names procps)" procps-ng; assert_eq "$(pkg_names pysystemd)" python3-systemd
PLAT_PM=pacman; assert_eq "$(pkg_names pysystemd)" python-systemd; PLAT_PM=apk; assert_eq "$(pkg_names iproute)" "iproute2 iproute2-ss"
# package-manager failure hints
hf="${T}/pkg.out"
printf 'E: Could not get lock /var/lib/dpkg/lock-frontend\n' > "${hf}"; assert_true grep -q "Another package manager" <(pkg_hint "${hf}")
printf 'Temporary failure resolving archive.ubuntu.com\n' > "${hf}"; assert_true grep -q "unreachable" <(pkg_hint "${hf}")
printf 'No match for argument: fail2ban\n' > "${hf}"; assert_true grep -q "not available" <(pkg_hint "${hf}")
printf 'dpkg was interrupted, you must manually run dpkg --configure -a\n' > "${hf}"; assert_true grep -q "dpkg --configure -a" <(pkg_hint "${hf}")
printf 'write error: No space left on device\n' > "${hf}"; assert_true grep -q "disk is full" <(pkg_hint "${hf}")
PLAT_PM=""
PLAT_INIT="systemd"

# firewalld: command syntax against a recording stub (a real firewalld needs a full system)
mkdir -p "${T}/fwbin"
cat > "${T}/fwbin/firewall-cmd" << 'FWEOF'
#!/usr/bin/env bash
echo "firewall-cmd $*" >> "${FWLOG}"
case "$1" in
  --state) echo running ;;
  --get-default-zone) echo public ;;
  --get-zone-of-interface=*) echo public ;;
  --query-port=* | --zone=*--query-port=*) exit 1 ;;
esac
for a in "$@"; do case "${a}" in --query-port=*) exit 1 ;; esac; done
exit 0
FWEOF
chmod +x "${T}/fwbin/firewall-cmd"
FWLOG="${T}/fw.log"; export FWLOG; : > "${FWLOG}"
OLDP="${PATH}"; PATH="${T}/fwbin:${PATH}"
FW_BACKEND=firewalld; FW_ZONE=""
assert_true fw_allow 22 tcp ssh; assert_true fw_allow 10000:10100 tcp extra
assert_true grep -q "firewall-cmd --permanent --zone=public --add-port=22/tcp" "${FWLOG}"
assert_true grep -q "firewall-cmd --zone=public --add-port=22/tcp" "${FWLOG}"
assert_true grep -q "add-port=10000-10100/tcp" "${FWLOG}"
assert_true grep -q "^firewalld_rule=public 22/tcp ssh" "$(state_file)"
PATH="${OLDP}"; FW_BACKEND=""; FW_ZONE=""

# panel HTTPS helpers
assert_true _valid_domain vpn.example.com; assert_false _valid_domain "bad domain"; assert_false _valid_domain localhost; assert_false _valid_domain "a.b;rm"
assert_true _valid_ipv4 203.0.113.7; assert_false _valid_ipv4 999.1.1.1; assert_false _valid_ipv4 1.2.3
for ip in 10.1.2.3 192.168.0.5 172.16.9.9 172.31.1.1 127.0.0.1 100.64.0.1 169.254.1.1; do assert_true _is_private_ipv4 "${ip}"; done
for ip in 8.8.8.8 172.32.0.1 100.128.0.1 203.0.113.7; do assert_false _is_private_ipv4 "${ip}"; done
MVN_XUI_DOMAIN=""; MVN_XUI_SSL_MODE=""; xui_resolve_ssl_mode; assert_eq "${XUI_SSL_EFFECTIVE}" "ip" "auto without domain -> ip"
MVN_XUI_DOMAIN="vpn.example.com"; xui_resolve_ssl_mode; assert_eq "${XUI_SSL_EFFECTIVE}" "domain" "auto with domain -> domain"
MVN_XUI_SSL_MODE="selfsigned"; xui_resolve_ssl_mode; assert_eq "${XUI_SSL_EFFECTIVE}" "selfsigned" "explicit selfsigned"
MVN_XUI_SSL_MODE="none"; xui_resolve_ssl_mode; assert_eq "${XUI_SSL_EFFECTIVE}" "none" "explicit none"
MVN_XUI_DOMAIN=""; MVN_XUI_SSL_MODE="domain"
assert_false bash -c "source '${ROOT}/scripts/logger.sh'; source '${ROOT}/scripts/common.sh'; source '${ROOT}/scripts/panel_tls.sh'; MVN_XUI_SSL_MODE=domain MVN_XUI_DOMAIN='' xui_resolve_ssl_mode" 2> /dev/null
assert_false bash -c "source '${ROOT}/scripts/logger.sh'; source '${ROOT}/scripts/common.sh'; source '${ROOT}/scripts/panel_tls.sh'; MVN_XUI_SSL_MODE=bogus xui_resolve_ssl_mode" 2> /dev/null
SSH_PORTS_DETECTED=(22 2222)
assert_true xui_port_problem 22; assert_true xui_port_problem 2222; assert_true xui_port_problem 80; assert_true xui_port_problem abc; assert_true xui_port_problem 70000
assert_false xui_port_problem 48217

# self-signed certificate against a fake x-ui, then scheme probing against real servers
mkdir -p "${T}/xui" "${T}/bin"
printf '#!/usr/bin/env bash\necho "$@" >> "%s/xui-calls"\n[[ "$1 $2 $3" == "setting -getCert true" ]] && echo "cert: ${FAKE_CERT:-}"\nexit 0\n' "${T}" > "${T}/xui/x-ui"; chmod +x "${T}/xui/x-ui"
printf '#!/bin/sh\nexit 0\n' > "${T}/bin/systemctl"; chmod +x "${T}/bin/systemctl"
XUI_FOLDER="${T}/xui"; MVN_TLS_DIR="${T}/tls"; XUI_PUBLIC_IP="203.0.113.7"; MVN_XUI_DOMAIN=""
OLDPATH="${PATH}"; PATH="${T}/bin:${PATH}"
assert_true xui_make_selfsigned
assert_eq "$(stat -c %a "${MVN_TLS_DIR}/key.pem")" "600" "self-signed key mode"
assert_true grep -q "IP Address:203.0.113.7" <(openssl x509 -in "${MVN_TLS_DIR}/cert.pem" -noout -ext subjectAltName)
assert_true grep -q "cert -webCert ${MVN_TLS_DIR}/cert.pem -webCertKey ${MVN_TLS_DIR}/key.pem" "${T}/xui-calls"
MVN_XUI_DOMAIN="vpn.example.com"; assert_true xui_make_selfsigned
assert_true grep -q "DNS:vpn.example.com" <(openssl x509 -in "${MVN_TLS_DIR}/cert.pem" -noout -ext subjectAltName)

# Let's Encrypt did not produce a certificate -> verified fallback to self-signed
XUI_INSTALLED_BY_US=1; XUI_SSL_EFFECTIVE="ip"; MVN_XUI_SSL_FALLBACK="selfsigned"; MVN_XUI_DOMAIN=""; FAKE_CERT=""; export FAKE_CERT
rm -rf "${MVN_TLS_DIR}"; xui_tls_finalize 2> /dev/null
assert_eq "${XUI_SSL_EFFECTIVE}" "selfsigned" "LE failed -> selfsigned"; assert_true test -s "${MVN_TLS_DIR}/cert.pem"
# Let's Encrypt worked -> nothing is replaced
XUI_SSL_EFFECTIVE="ip"; FAKE_CERT="/root/cert/ip/fullchain.pem"; rm -rf "${MVN_TLS_DIR}"; xui_tls_finalize 2> /dev/null
assert_eq "${XUI_SSL_EFFECTIVE}" "ip" "LE ok stays ip"; assert_false test -e "${MVN_TLS_DIR}/cert.pem"
# fallback none -> stays on HTTP, no certificate made
XUI_SSL_EFFECTIVE="domain"; MVN_XUI_SSL_FALLBACK="none"; FAKE_CERT=""; xui_tls_finalize 2> /dev/null
assert_eq "${XUI_SSL_EFFECTIVE}" "none" "LE failed + fallback none"
# interactive questions (answers fed through a stub)
is_noninteractive() { return 1; }
feed() { printf '%s\n' "$@" > "${T}/answers"; }
ask_value() { local a; a="$(head -n 1 "${T}/answers")"; sed -i '1d' "${T}/answers"; printf '%s' "${a}"; }
feed 48217 2
MVN_DRY_RUN=0; MVN_XUI_PANEL_PORT=""; MVN_XUI_SSL_MODE=""; MVN_XUI_DOMAIN="vpn.example.com"
xui_ask_options > /dev/null
assert_eq "${MVN_XUI_PANEL_PORT}" "48217" "asked port"; assert_eq "${MVN_XUI_SSL_MODE}" "domain" "asked mode"
feed 22 "" 3; MVN_XUI_PANEL_PORT=""; MVN_XUI_SSL_MODE=""; xui_ask_options > /dev/null 2>&1
assert_eq "${MVN_XUI_PANEL_PORT}" "" "SSH port refused, Enter = random"; assert_eq "${MVN_XUI_SSL_MODE}" "selfsigned" "asked selfsigned"
unset -f is_noninteractive ask_value
source "${ROOT}/scripts/common.sh"
PATH="${OLDPATH}"

if command -v python3 > /dev/null 2>&1; then
  free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
  XUI_PROBE_TRIES=3
  PATH="${T}/bin:${OLDPATH}"; MVN_XUI_DOMAIN=""; xui_make_selfsigned > /dev/null 2>&1; PATH="${OLDPATH}"
  hp="$(free_port)"; python3 -m http.server "${hp}" --bind 127.0.0.1 > /dev/null 2>&1 & hpid=$!
  sp="$(free_port)"
  python3 - "${sp}" "${MVN_TLS_DIR}/cert.pem" "${MVN_TLS_DIR}/key.pem" > /dev/null 2>&1 << 'PYEOF' &
import http.server, ssl, sys
srv = http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), http.server.SimpleHTTPRequestHandler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(sys.argv[2], sys.argv[3])
srv.socket = ctx.wrap_socket(srv.socket, server_side=True); srv.serve_forever()
PYEOF
  spid=$!
  sleep 1.5
  xui_probe_scheme "${hp}" "" || true; assert_eq "${XUI_SCHEME}" "http" "probe plain http"
  xui_probe_scheme "${sp}" "" || true; assert_eq "${XUI_SCHEME}" "https" "probe https (self-signed)"
  kill "${hpid}" "${spid}" 2> /dev/null || true; wait 2> /dev/null || true
  assert_false xui_probe_scheme "$(free_port)" ""; assert_eq "${XUI_SCHEME}" "" "probe closed port"
fi

# fail2ban jail rendering
F2B_PORTS=(22 2222); MVN_F2B_MAXRETRY=5; MVN_F2B_FINDTIME=10m; MVN_F2B_BANTIME=1h
jail="$(f2b_render systemd "127.0.0.1/8 ::1 198.51.100.4")"
assert_true grep -qx "port = 22,2222" <<< "${jail}"; assert_true grep -qx "backend = systemd" <<< "${jail}"
assert_true grep -qx "ignoreip = 127.0.0.1/8 ::1 198.51.100.4" <<< "${jail}"; assert_true grep -qx "maxretry = 5" <<< "${jail}"

# retry
n=0; flaky() { n=$((n + 1)); ((n >= 3)); }
assert_true retry 3 0 flaky 2> /dev/null
assert_false retry 2 0 false 2> /dev/null

echo "passed=${PASS} failed=${FAIL}"
((FAIL == 0))
