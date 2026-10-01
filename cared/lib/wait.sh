#!/usr/bin/env bash

# vc-monorepo release/vc/v2.1.5 기준 한 사이클 종료 로그
# observer         : observer run end
# sync             : sync end :
# scoring-manager  : Finish recording scores

wait_for_cycle() {
  local service="$1"
  local pattern="$2"
  local timeout_sec="${3:-2700}"
  local since start now logs printed=0

  since="$(iso_now)"
  start="$(date +%s)"

  log_step "${service} 한 사이클 대기"
  log_info "pattern: ${pattern}"
  log_info "dc logs -f ${service}  / timeout ${timeout_sec}s"
  if is_sim; then
    log_info "${service} 한 사이클 종료 로그 확인"
    return 0
  fi

  while true; do
    logs="$(dc logs --since "${since}" --no-color "${service}" 2>/dev/null || true)"
    if [[ -n "${logs}" ]]; then
      printf '%s\n' "${logs}" | awk -v n="${printed}" 'NR > n { print }'
      printed="$(printf '%s\n' "${logs}" | wc -l | tr -d ' ')"
    fi

    if printf '%s\n' "${logs}" | grep -E -- "${pattern}" >/dev/null; then
      log_info "${service} 한 사이클 종료 로그 확인"
      return 0
    fi

    if [[ "$(dc ps --format '{{.State}}' "${service}" 2>/dev/null | tail -n 1)" != "running" ]]; then
      log_error "${service} 컨테이너가 내려갔습니다."
      dc logs --tail 80 "${service}" || true
      return 1
    fi

    now="$(date +%s)"
    if (( now - start >= timeout_sec )); then
      log_error "${service} 한 사이클 로그를 ${timeout_sec}s 안에 못 찾았습니다: ${pattern}"
      dc logs --since "${since}" --no-color --tail 80 "${service}" || true
      return 1
    fi
    sleep 5
  done
}
