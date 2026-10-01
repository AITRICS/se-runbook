#!/usr/bin/env bash

REQUIRED_MOUNTS=("/" "/aitrics-vc")

# 병원 서버에서 성공했을 때 보이는 예시. 미리보기에서 마운트가 없을 때 같은 문구를 쓴다.
SIM_DF_ROOT="/dev/sdb1       439G   30G  388G   7% /"
SIM_DF_VC="/dev/sda2       878G   13G  821G   2% /aitrics-vc"

df_line() {
  local target="$1"
  df -h 2>/dev/null | awk -v t="${target}" '$NF == t { print; found = 1 } END { exit !found }'
}

mount_point_of() {
  local target="$1"
  if command -v findmnt >/dev/null 2>&1; then
    findmnt -n -o TARGET --target "${target}" 2>/dev/null || true
    return 0
  fi
  df -P "${target}" 2>/dev/null | awk 'NR==2 { print $6 }'
}

cpu_stat_idle_total() {
  awk '/^cpu / { idle = $5 + $6; total = 0; for (i = 2; i <= NF; i++) total += $i; print idle, total }' /proc/stat
}

cpu_usage_pct() {
  local idle1 total1 idle2 total2
  if [[ -r /proc/stat ]]; then
    read -r idle1 total1 < <(cpu_stat_idle_total)
    sleep 0.5
    read -r idle2 total2 < <(cpu_stat_idle_total)
    awk -v i1="${idle1}" -v t1="${total1}" -v i2="${idle2}" -v t2="${total2}" '
      BEGIN {
        dt = t2 - t1
        if (dt <= 0) { print "?"; exit }
        printf "%.0f", (1 - (i2 - i1) / dt) * 100
      }
    '
    return 0
  fi
  if command -v top >/dev/null 2>&1; then
    top -l 2 -n 0 -s 1 2>/dev/null | awk '
      /CPU usage/ {
        for (i = 1; i <= NF; i++) {
          if ($i == "idle") {
            idle = $(i - 1)
            gsub(/%/, "", idle)
          }
        }
      }
      END {
        if (idle == "") { print "?"; exit }
        printf "%.0f", 100 - idle
      }
    '
    return 0
  fi
  echo "?"
}

mem_line_linux() {
  awk '
    /MemTotal:/ { t = $2 }
    /MemAvailable:/ { a = $2 }
    END {
      if (t <= 0) exit
      used = t - a
      printf "%.1fGi  /  %.1fGi  (%d%%)\n", used / 1024 / 1024, t / 1024 / 1024, used * 100 / t
    }
  ' /proc/meminfo
}

mem_used_pct() {
  if [[ -r /proc/meminfo ]]; then
    awk '/MemTotal:/ { t = $2 } /MemAvailable:/ { a = $2 } END { if (t > 0) printf "%d", (t - a) * 100 / t }' /proc/meminfo
    return 0
  fi
  echo "0"
}

check_mounts() {
  local failed=0 target line mp usepct

  log_step "디스크 마운트"

  for target in "${REQUIRED_MOUNTS[@]}"; do
    line="$(df_line "${target}" || true)"
    mp="$(mount_point_of "${target}")"
    if [[ -n "${line}" && "${mp}" == "${target}" ]]; then
      usepct="$(awk '{ print $5 }' <<<"${line}")"
      log_info "${line}"
      usepct="${usepct%\%}"
      if [[ "${usepct}" =~ ^[0-9]+$ ]] && (( usepct >= 90 )); then
        log_warn "${target} 사용량 ${usepct}%"
      fi
      continue
    fi
    if is_sim; then
      if [[ "${target}" == "/" ]]; then
        log_info "${SIM_DF_ROOT}"
      else
        log_info "${SIM_DF_VC}"
      fi
      continue
    fi
    if [[ ! -e "${target}" ]]; then
      log_error "없음: ${target}"
    elif [[ -z "${line}" ]]; then
      log_error "df 실패: ${target}"
    else
      log_error "${target} 가 별도 마운트가 아닙니다. 현재 마운트: ${mp:-없음}"
    fi
    failed=1
  done

  if [[ "${failed}" -ne 0 ]]; then
    log_error "/ 와 /aitrics-vc 가 각각 따로 마운트되어야 합니다."
    return 1
  fi
  log_info "디스크가 정상적으로 마운트되어 있습니다."
}

check_cpu_ram() {
  local cpu mem pct

  log_step "CPU / RAM"
  cpu="$(cpu_usage_pct)"
  if is_sim && [[ "${cpu}" == "?" ]]; then
    cpu="12"
  fi
  log_info "CPU: ${cpu}%"

  if command -v free >/dev/null 2>&1; then
    echo
    free -h
    echo
  fi
  if [[ -r /proc/meminfo ]]; then
    mem="$(mem_line_linux)"
    pct="$(mem_used_pct)"
    log_info "RAM: ${mem}"
  elif is_sim; then
    pct="26"
    log_info "RAM: 8.0Gi  /  31.0Gi  (26%)"
  else
    pct="0"
    log_info "RAM: (free /proc/meminfo 없음)"
  fi

  if [[ "${cpu}" =~ ^[0-9]+$ ]] && (( cpu >= 90 )); then
    log_warn "CPU 사용량 ${cpu}%"
  fi
  if [[ "${pct}" =~ ^[0-9]+$ ]] && (( pct >= 90 )); then
    log_warn "RAM 사용량 ${pct}%"
  fi
}

check_compose_projects() {
  log_step "현재 실행 중인 docker compose 프로젝트"
  if ! command -v docker >/dev/null 2>&1; then
    if is_sim; then
      docker compose ls 2>/dev/null || true
      return 0
    fi
    log_error "docker 가 없습니다."
    return 1
  fi

  if docker compose ls >/dev/null 2>&1; then
    docker compose ls
    return 0
  fi
  if docker-compose ls >/dev/null 2>&1; then
    docker-compose ls
    return 0
  fi
  log_error "docker compose ls 를 실행할 수 없습니다."
  return 1
}

check_env_settings() {
  log_step "env 설정"
  log_info ".env & db-encrypt.env & sync.env 설정을 완료해 주세요."
}

run_preflight() {
  local failed=0
  check_mounts || failed=1
  check_cpu_ram
  check_compose_projects || failed=1
  check_env_settings
  step_images || failed=1
  echo
  if [[ "${failed}" -ne 0 ]]; then
    log_error "사전점검 실패"
    return 1
  fi
  log_info "사전점검 통과"
}

check_our_stack() {
  local project="$1"
  local names count

  log_step "이 작업 스택  (${project})"
  if is_sim; then
    if command -v docker >/dev/null 2>&1; then
      docker ps -a --filter "label=com.docker.compose.project=${project}" \
        --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
      echo
    fi
    log_info "떠 있는 컨테이너 13개: nginx-cared mysql-cared mongodb-cared backend-cared frontend-cared admin-cared sync-cared observer-cared scoring-manager-cared scoring-service-cared screening-service-cared"
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    log_error "docker 가 없습니다."
    return 1
  fi

  docker ps -a --filter "label=com.docker.compose.project=${project}" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

  count="$(docker ps --filter "label=com.docker.compose.project=${project}" \
    --format '{{.ID}}' 2>/dev/null | wc -l | tr -d ' ')"
  names="$(docker ps --filter "label=com.docker.compose.project=${project}" \
    --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')"

  echo
  if [[ "${count}" -eq 0 ]]; then
    log_error "${project} 에서 떠 있는 컨테이너가 없습니다."
    return 1
  fi
  log_info "떠 있는 컨테이너 ${count}개: ${names}"
}

run_postcheck() {
  local failed=0
  local project

  project="$(our_compose_project)"
  check_mounts || failed=1
  check_cpu_ram
  check_compose_projects || failed=1
  check_our_stack "${project}" || failed=1
  echo
  if [[ "${failed}" -ne 0 ]]; then
    log_error "사후점검 실패"
    return 1
  fi
  log_info "사후점검 통과"
}
