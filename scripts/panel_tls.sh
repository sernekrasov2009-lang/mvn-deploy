#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # globals are used by the scripts that source this file
# panel_tls.sh — HTTPS for the 3x-ui panel.
#   ip          Let's Encrypt certificate for the server IP (via the official installer)
#   domain      Let's Encrypt certificate for a domain (via the official installer)
#   selfsigned  local certificate; always works, the browser shows a warning once
#   none        plain HTTP (not recommended)
# Let's Encrypt can fail (busy port 80, wrong DNS, rate limits). The official installer then
# silently leaves the panel on HTTP, so MVN Deploy checks the real result and, if needed,
# switches to a self-signed certificate (MVN_XUI_SSL_FALLBACK) instead of leaving HTTP.

XUI_SSL_EFFECTIVE="none" # none | ip | domain | selfsigned | existing
XUI_PUBLIC_IP=""
XUI_SCHEME="" # http | https | "" (panel did not answer locally)
XUI_TLS_NOTE=""
MVN_TLS_DIR="/etc/x-ui/mvn-ssl"

_valid_domain() { [[ "${1:-}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; }
_valid_ipv4() { [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && [[ ! "${1}" =~ (^|\.)(25[6-9]|2[6-9][0-9]|[3-9][0-9][0-9])(\.|$) ]]; }

# Private, loopback, link-local and CGNAT ranges cannot get a public certificate.
_is_private_ipv4() {
  local a b
  IFS=. read -r a b _ _ <<< "${1:-}"
  [[ "${a}" =~ ^[0-9]+$ && "${b}" =~ ^[0-9]+$ ]] || return 1
  ((a == 10 || a == 127 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) || (a == 169 && b == 254) || (a == 100 && b >= 64 && b <= 127)))
}

_public_ipv4() {
  local u r
  for u in https://api4.ipify.org https://ipv4.icanhazip.com https://4.ident.me; do
    r="$(curl -fsS --max-time 4 "${u}" 2> /dev/null | tr -d '[:space:]' || true)"
    if _valid_ipv4 "${r}"; then
      printf '%s' "${r}"
      return 0
    fi
  done
  return 0
}

_local_src_ipv4() { ip -4 route get 1.1.1.1 2> /dev/null | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}' || true; }

# xui_resolve_ssl_mode: pure; turns MVN_XUI_SSL_MODE (+ domain) into XUI_SSL_EFFECTIVE.
xui_resolve_ssl_mode() {
  local m="${MVN_XUI_SSL_MODE:-}"
  [[ -n "${m}" ]] || m="auto"
  case "${m}" in
    auto) if [[ -n "${MVN_XUI_DOMAIN:-}" ]]; then XUI_SSL_EFFECTIVE="domain"; else XUI_SSL_EFFECTIVE="ip"; fi ;;
    ip | domain | selfsigned | none) XUI_SSL_EFFECTIVE="${m}" ;;
    *) die "${EXIT_PRECOND}" "MVN_XUI_SSL_MODE must be auto, ip, domain, selfsigned or none (got '${m}')" ;;
  esac
  case "${MVN_XUI_SSL_FALLBACK:-selfsigned}" in
    selfsigned | none) ;;
    *) die "${EXIT_PRECOND}" "MVN_XUI_SSL_FALLBACK must be selfsigned or none" ;;
  esac
  if [[ "${XUI_SSL_EFFECTIVE}" == "domain" ]] && ! _valid_domain "${MVN_XUI_DOMAIN:-}"; then
    die "${EXIT_PRECOND}" "HTTPS for a domain needs a valid domain name (MVN_XUI_DOMAIN / --domain)"
  fi
  if [[ -n "${MVN_XUI_DOMAIN:-}" ]] && ! _valid_domain "${MVN_XUI_DOMAIN}"; then
    die "${EXIT_PRECOND}" "MVN_XUI_DOMAIN is not a valid domain name: ${MVN_XUI_DOMAIN}"
  fi
  return 0
}

_ssl_degrade() { # reason — Let's Encrypt cannot work; continue with the configured fallback
  local fb="${MVN_XUI_SSL_FALLBACK:-selfsigned}"
  log_warn "Let's Encrypt will not work here: $1"
  if ! is_noninteractive && [[ "${MVN_DRY_RUN:-0}" != "1" ]]; then
    ask_yes_no "Continue with '${fb}' instead?" y || die "${EXIT_ABORT}" "Aborted by user. Nothing was changed."
  fi
  log_warn "Using '${fb}' for the panel instead (HTTPS stays on with 'selfsigned'; the browser will warn once)"
  XUI_SSL_EFFECTIVE="${fb}"
}

# xui_ssl_preflight: read-only checks that predict Let's Encrypt problems.
xui_ssl_preflight() {
  [[ "${XUI_SSL_EFFECTIVE}" == "ip" || "${XUI_SSL_EFFECTIVE}" == "domain" ]] || return 0
  local listeners resolved
  listeners="$(ss -ltnpH 'sport = :80' 2> /dev/null | head -n 1 || true)"
  if [[ -n "${listeners}" ]]; then
    _ssl_degrade "port 80 is already used by another service (${listeners##* })"
    return 0
  fi
  XUI_PUBLIC_IP="$(_public_ipv4)"
  if [[ -z "${XUI_PUBLIC_IP}" ]]; then
    _ssl_degrade "the public IPv4 address of this server could not be detected"
    return 0
  fi
  if _is_private_ipv4 "${XUI_PUBLIC_IP}"; then
    _ssl_degrade "the detected address ${XUI_PUBLIC_IP} is not public (NAT/private network)"
    return 0
  fi
  if [[ "${XUI_SSL_EFFECTIVE}" == "domain" ]]; then
    resolved="$({ getent ahostsv4 "${MVN_XUI_DOMAIN}" 2> /dev/null || getent hosts "${MVN_XUI_DOMAIN}" 2> /dev/null; } | awk '$1 ~ /^[0-9.]+$/ {print $1; exit}' || true)"
    if [[ -z "${resolved}" ]]; then
      _ssl_degrade "${MVN_XUI_DOMAIN} does not resolve yet (create an A record pointing to ${XUI_PUBLIC_IP})"
    elif [[ "${resolved}" != "${XUI_PUBLIC_IP}" ]]; then
      if [[ "${MVN_ALLOW_DNS_MISMATCH:-0}" == "1" ]]; then
        log_warn "${MVN_XUI_DOMAIN} resolves to ${resolved}, this server is ${XUI_PUBLIC_IP}; continuing (MVN_ALLOW_DNS_MISMATCH=1)"
      else
        _ssl_degrade "${MVN_XUI_DOMAIN} resolves to ${resolved}, but this server is ${XUI_PUBLIC_IP}"
      fi
    fi
  fi
  return 0
}

# xui_ask_options: interactive questions (panel port, HTTPS). Skipped when values are preset.
xui_ask_options() {
  is_noninteractive && return 0
  [[ "${MVN_DRY_RUN:-0}" == "1" ]] && return 0

  local v tries=0
  if [[ -z "${MVN_XUI_PANEL_PORT:-}" ]]; then
    while ((tries < 5)); do
      tries=$((tries + 1))
      v="$(ask_value 'Panel port (Enter = random port)' '')"
      [[ -z "${v}" ]] && break
      if xui_port_problem "${v}"; then
        log_warn "Port ${v}: ${XUI_PORT_PROBLEM}"
      else
        MVN_XUI_PANEL_PORT="${v}"
        break
      fi
    done
  fi

  if [[ -z "${MVN_XUI_SSL_MODE:-}" ]]; then
    printf '\nHTTPS for the 3x-ui panel:\n'
    printf '  1) IP address     - Let'"'"'s Encrypt, free, no browser warning (needs port 80)  [default]\n'
    printf '  2) Domain name    - Let'"'"'s Encrypt; the domain must already point to this server\n'
    printf '  3) Self-signed    - always works; the browser shows a warning once\n'
    printf '  4) HTTP only      - NOT recommended (use an SSH tunnel)\n'
    v="$(ask_value 'Choose 1-4' '1')"
    case "${v}" in
      2) MVN_XUI_SSL_MODE="domain" ;;
      3) MVN_XUI_SSL_MODE="selfsigned" ;;
      4) MVN_XUI_SSL_MODE="none" ;;
      *) MVN_XUI_SSL_MODE="ip" ;;
    esac
  fi
  if [[ "${MVN_XUI_SSL_MODE}" == "domain" && -z "${MVN_XUI_DOMAIN:-}" ]]; then
    tries=0
    while ((tries < 5)); do
      tries=$((tries + 1))
      v="$(ask_value 'Domain name (for example vpn.example.com)' '')"
      if _valid_domain "${v}"; then
        MVN_XUI_DOMAIN="${v}"
        break
      fi
      log_warn "That does not look like a valid domain name"
    done
  fi
  return 0
}

# xui_port_problem <port>: sets XUI_PORT_PROBLEM and returns 0 when the port must not be used.
XUI_PORT_PROBLEM=""
xui_port_problem() {
  local p="${1}" s sshx="${MVN_SSH_PORTS:-}"
  sshx="${sshx//,/ }"
  XUI_PORT_PROBLEM=""
  if ! valid_port "${p}"; then
    XUI_PORT_PROBLEM="not a valid port (1-65535)"
    return 0
  fi
  if [[ "${p}" == "80" ]]; then
    XUI_PORT_PROBLEM="port 80 is reserved for certificate issuing"
    return 0
  fi
  for s in "${SSH_PORTS_DETECTED[@]}" ${sshx}; do
    if [[ "${s}" == "${p}" ]]; then
      XUI_PORT_PROBLEM="this is your SSH port"
      return 0
    fi
  done
  if command -v ss > /dev/null 2>&1 && [[ -n "$(ss -ltnH "sport = :${p}" 2> /dev/null)" ]]; then
    XUI_PORT_PROBLEM="already in use by another program"
    return 0
  fi
  return 1
}

_xui_cert_path() {
  "${XUI_FOLDER}/x-ui" setting -getCert true 2> /dev/null |
    sed -n 's/^[[:space:]]*cert:[[:space:]]*//p' | head -n 1 | tr -d '[:space:]' || true
}

# xui_make_selfsigned: creates the key pair and registers it in the panel.
xui_make_selfsigned() {
  local host san ip crt key
  ip="${XUI_PUBLIC_IP:-}"
  [[ -n "${ip}" ]] || ip="$(_local_src_ipv4)"
  host="${MVN_XUI_DOMAIN:-${ip}}"
  [[ -n "${host}" ]] || host="localhost"
  if _valid_ipv4 "${host}"; then san="IP:${host}"; else san="DNS:${host}"; fi
  if [[ -n "${ip}" && "${host}" != "${ip}" ]]; then san="${san},IP:${ip}"; fi
  crt="${MVN_TLS_DIR}/cert.pem"
  key="${MVN_TLS_DIR}/key.pem"

  install -d -m 700 "${MVN_TLS_DIR}"
  run_logged openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "${key}" -out "${crt}" -days 3650 -subj "/CN=${host}" -addext "subjectAltName=${san}" ||
    {
      log_error "openssl could not create the self-signed certificate"
      return 1
    }
  chmod 600 "${key}"
  chmod 644 "${crt}"
  run_logged "${XUI_FOLDER}/x-ui" cert -webCert "${crt}" -webCertKey "${key}" ||
    {
      log_error "x-ui refused the certificate paths"
      return 1
    }
  run_logged svc_restart x-ui || true
  xui_wait_active || return 1
  state_set selfsigned_cert 1
  return 0
}

# xui_probe_scheme <port> <path>: asks the panel itself; sets XUI_SCHEME.
xui_probe_scheme() {
  local port="$1" path="${2#/}" i code tries="${XUI_PROBE_TRIES:-20}"
  XUI_SCHEME=""
  for ((i = 0; i < tries; i++)); do
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 4 "https://127.0.0.1:${port}/${path}" 2> /dev/null || true)"
    if [[ "${code}" =~ ^[1-5][0-9][0-9]$ ]]; then
      XUI_SCHEME="https"
      return 0
    fi
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "http://127.0.0.1:${port}/${path}" 2> /dev/null || true)"
    if [[ "${code}" =~ ^[1-5][0-9][0-9]$ ]]; then
      XUI_SCHEME="http"
      return 0
    fi
    sleep 1
  done
  return 1
}

# xui_tls_finalize: runs right after OUR run of the official installer; checks and repairs HTTPS.
xui_tls_finalize() {
  [[ "${XUI_INSTALLED_BY_US}" == "1" ]] || return 0
  local cert
  cert="$(_xui_cert_path)"
  case "${XUI_SSL_EFFECTIVE}" in
    ip | domain)
      if [[ -n "${cert}" ]]; then
        XUI_TLS_NOTE="Let's Encrypt certificate (${XUI_SSL_EFFECTIVE}), renewed automatically"
        return 0
      fi
      log_warn "The Let's Encrypt certificate was NOT issued (the official installer left the panel on HTTP)."
      log_warn "Common reasons: port 80 closed at the VPS provider, wrong DNS, or Let's Encrypt rate limits."
      XUI_SSL_EFFECTIVE="${MVN_XUI_SSL_FALLBACK:-selfsigned}"
      ;;
  esac
  case "${XUI_SSL_EFFECTIVE}" in
    selfsigned)
      if xui_make_selfsigned; then
        XUI_TLS_NOTE="self-signed certificate (the browser warns once; accept it, or use a domain + Let's Encrypt)"
        log_ok "Panel HTTPS enabled with a self-signed certificate"
      else
        XUI_SSL_EFFECTIVE="none"
        XUI_TLS_NOTE="HTTPS could not be enabled"
        log_warn "Could not enable a self-signed certificate; the panel stays on HTTP"
      fi
      ;;
    none) XUI_TLS_NOTE="plain HTTP (HTTPS was not requested)" ;;
  esac
  return 0
}
