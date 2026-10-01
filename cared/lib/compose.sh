#!/usr/bin/env bash

our_compose_project() {
  echo "${HOSPITAL}-v215"
}

require_our_compose_project() {
  local project="${COMPOSE_PROJECT_NAME:-}"
  if [[ -z "${HOSPITAL}" ]]; then
    log_error "병원 이름이 없습니다. 기존 vc-deploy 를 건드리지 않기 위해 중단합니다."
    return 1
  fi
  if [[ -z "${project}" ]]; then
    project="$(our_compose_project)"
    COMPOSE_PROJECT_NAME="${project}"
    export COMPOSE_PROJECT_NAME
  fi
  if [[ "${project}" != "$(our_compose_project)" ]]; then
    log_error "compose project 가 $(our_compose_project) 가 아닙니다: ${project}"
    log_error "기존 vc-deploy 를 건드리지 않기 위해 중단합니다."
    return 1
  fi
}

cid_in_our_project() {
  local cid="$1"
  local project
  project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "${cid}" 2>/dev/null || true)"
  [[ "${project}" == "${COMPOSE_PROJECT_NAME}" ]]
}

dc() {
  local project
  if is_sim; then
    return 0
  fi
  require_our_compose_project || return 1
  project="${COMPOSE_PROJECT_NAME}"
  case "${1:-}" in
    down|kill|rm)
      log_error "dc ${1} 는 쓰지 않습니다. 실패해도 기존 vc-deploy 를 내리지 않습니다."
      return 1
      ;;
  esac
  if docker compose version >/dev/null 2>&1; then
    docker compose -p "${project}" "$@"
  else
    docker-compose -p "${project}" "$@"
  fi
}

compose_up() {
  log_step "dc up -d $*"
  dc up -d --pull never "$@"
}

wait_mysql_healthy() {
  local timeout="${1:-180}"
  local start now status
  start="$(date +%s)"

  log_info "mysql healthy 대기 (timeout ${timeout}s)"
  if is_sim; then
    log_info "mysql healthy"
    return 0
  fi
  while true; do
    status="$(dc ps --format '{{.Health}}' mysql 2>/dev/null | tail -n 1)"
    if [[ "${status}" == "healthy" ]]; then
      log_info "mysql healthy"
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= timeout )); then
      log_error "mysql이 ${timeout}s 안에 healthy가 되지 않았습니다. status=${status}"
      dc ps mysql || true
      dc logs --tail 80 mysql || true
      return 1
    fi
    sleep 3
  done
}

compose_up_oneshot() {
  local service="$1"
  local cid code log_pid

  log_step "dc up ${service} (exit code 0 확인)"
  if is_sim; then
    log_info "${service} exit code=0"
    return 0
  fi
  dc up -d --pull never --force-recreate --no-deps "${service}"
  cid="$(dc ps -a -q "${service}" | tail -n 1)"
  [[ -n "${cid}" ]] || {
    log_error "${service} 컨테이너를 찾지 못했습니다."
    return 1
  }
  if ! cid_in_our_project "${cid}"; then
    log_error "${service} 가 이 작업(${COMPOSE_PROJECT_NAME}) 이 아닙니다. 기존 스택을 건드리지 않습니다."
    return 1
  fi

  dc logs -f "${service}" &
  log_pid=$!
  code="$(docker wait "${cid}")"
  kill "${log_pid}" 2>/dev/null || true
  wait "${log_pid}" 2>/dev/null || true

  if [[ "${code}" != "0" ]]; then
    log_error "${service} exit code=${code}"
    dc logs --tail 80 "${service}" || true
    return 1
  fi

  log_info "${service} exit code=0"
}

check_backend_or_encrypt() {
  local retries="${1:-30}"
  local i status
  log_info "backend 기동 확인 (db-encrypt.env 이상하면 여기서 깨집니다)"
  if is_sim; then
    log_info "backend running"
    return 0
  fi

  for ((i = 1; i <= retries; i++)); do
    status="$(dc ps --format '{{.State}}' backend 2>/dev/null | tail -n 1)"
    if [[ "${status}" == "running" ]]; then
      log_info "backend running"
      return 0
    fi
    sleep 3
  done

  log_error "backend가 running이 아닙니다. db-encrypt.env를 먼저 확인하세요."
  dc ps backend || true
  dc logs --tail 80 backend || true
  return 1
}
