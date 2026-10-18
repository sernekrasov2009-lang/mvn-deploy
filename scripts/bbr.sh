#!/usr/bin/env bash
# shellcheck shell=bash
# bbr.sh — enable TCP BBR (+ fq) only when the kernel supports it.

BBR_RESULT="skipped"   # enabled | unchanged | unsupported | failed | skipped
BBR_SYSCTL_FILE="/etc/sysctl.d/99-mvn-deploy-bbr.conf"
BBR_MODULES_FILE="/etc/modules-load.d/mvn-deploy-bbr.conf"

_bbr_available() { grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2> /dev/null; }

_bbr_persisted_elsewhere() {
  local -a files=(/etc/sysctl.conf)
  local f
  for f in /etc/sysctl.d/*.conf; do
    [[ -e "${f}" && "${f}" != "${BBR_SYSCTL_FILE}" ]] && files+=("${f}")
  done
  grep -Eqs '^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr' "${files[@]}" \
    && grep -Eqs '^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=[[:space:]]*fq' "${files[@]}"
}

bbr_plan_text() {
  if [[ "${MVN_BBR}" == "skip" ]]; then printf 'skipped (MVN_BBR=skip)'; return; fi
  if [[ "${BBR_CC_CURRENT}" == "bbr" && "${BBR_QDISC_CURRENT}" == "fq" ]]; then
    printf 'already active; persistence will be checked'
  elif grep -qw bbr <<< "${BBR_AVAILABLE}"; then
    printf 'enable bbr + fq via %s' "${BBR_SYSCTL_FILE}"
  else
    printf 'bbr not listed by the kernel; will try to load tcp_bbr, otherwise warn'
  fi
}

bbr_apply() {
  if [[ "${MVN_BBR}" == "skip" ]]; then
    BBR_RESULT="skipped"; report_add "BBR" "SKIPPED" "MVN_BBR=skip"; return 0
  fi
  [[ "${MVN_BBR}" == "auto" ]] || die "${EXIT_PRECOND}" "MVN_BBR must be auto or skip"

  if ! _bbr_available; then
    run_logged modprobe tcp_bbr || true
  fi
  if ! _bbr_available; then
    BBR_RESULT="unsupported"
    log_warn "This kernel does not support BBR; network settings were not changed"
    report_add "BBR" "UNSUPPORTED" "kernel has no bbr"
    return 0
  fi

  sys_detect_bbr
  if [[ "${BBR_CC_CURRENT}" == "bbr" && "${BBR_QDISC_CURRENT}" == "fq" ]] \
    && { [[ -f "${BBR_SYSCTL_FILE}" ]] || _bbr_persisted_elsewhere; }; then
    BBR_RESULT="unchanged"
    log_ok "BBR is already enabled and persistent; no changes needed"
    report_add "BBR" "OK" "already enabled"
    return 0
  fi

  # Apply live first: if the kernel/container refuses, nothing is persisted.
  if ! run_logged sysctl -w net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbr; then
    BBR_RESULT="failed"
    log_warn "Could not apply BBR at runtime (restricted container?); nothing was persisted"
    report_add "BBR" "FAILED" "sysctl refused the change"
    return 0
  fi

  local tmp
  tmp="$(mktemp /etc/sysctl.d/.mvn-bbr.XXXXXX)"
  cat > "${tmp}" << 'EOT'
# Managed by MVN Deploy — TCP BBR congestion control with the fq qdisc.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOT
  chmod 644 -- "${tmp}"
  mv -f -- "${tmp}" "${BBR_SYSCTL_FILE}"
  state_set bbr_file "${BBR_SYSCTL_FILE}"

  if grep -q '^tcp_bbr ' /proc/modules 2> /dev/null; then
    mkdir -p /etc/modules-load.d
    printf '# Managed by MVN Deploy\ntcp_bbr\n' > "${BBR_MODULES_FILE}"
    state_set bbr_modules_file "${BBR_MODULES_FILE}"
  fi
  run_logged sysctl --system || log_warn "sysctl --system reported errors (see log)"

  sys_detect_bbr
  if [[ "${BBR_CC_CURRENT}" == "bbr" && "${BBR_QDISC_CURRENT}" == "fq" ]]; then
    BBR_RESULT="enabled"
    log_ok "BBR enabled (tcp_congestion_control=bbr, default_qdisc=fq)"
    report_add "BBR" "OK" "enabled; persisted in ${BBR_SYSCTL_FILE}"
  else
    BBR_RESULT="failed"
    log_warn "BBR values are not active after sysctl --system (${BBR_CC_CURRENT}/${BBR_QDISC_CURRENT}); a later sysctl file may override them"
    report_add "BBR" "FAILED" "values not active"
  fi
}
