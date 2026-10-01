#!/usr/bin/env bash

CARED_CONTAINERS=(
  nginx-cared
  mysql-cared
  mongodb-cared
  sync-migration-cared
  backend-migration-cared
  backend-cared
  frontend-cared
  admin-cared
  sync-cared
  observer-cared
  scoring-manager-cared
  scoring-service-cared
  screening-service-cared
)

CARED_PORTS=(1080 13000 14000 13306 37017)

VC_DEPLOY_CONTAINERS=(
  mysql
  mongodb
  backend
  frontend
  admin
  sync
  observer
  scoring-manager
  scoring-service
  screening-service
  nginx
  nginx-1.31.0
)

compose_project() {
  our_compose_project
}

container_project() {
  local name="$1"
  docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "${name}" 2>/dev/null || true
}

container_exists() {
  docker inspect "${1}" >/dev/null 2>&1
}

port_listening() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -lnt 2>/dev/null | grep -qE ":${port}[[:space:]]"
    return $?
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi
  return 1
}

our_container_owns_port() {
  local port="$1"
  local project
  project="$(compose_project)"
  docker ps --filter "label=com.docker.compose.project=${project}" \
    --format '{{.Ports}}' 2>/dev/null | grep -qE "(^|[:,])${port}->"
}

guard_containers() {
  local project name other
  local failed=0
  project="$(compose_project)"

  for name in "${VC_DEPLOY_CONTAINERS[@]}"; do
    if container_exists "${name}"; then
      log_info "기존 vc-deploy 컨테이너 유지: ${name}"
    fi
  done

  for name in "${CARED_CONTAINERS[@]}"; do
    if ! container_exists "${name}"; then
      continue
    fi
    other="$(container_project "${name}")"
    if [[ "${other}" == "${project}" ]]; then
      log_info "이 작업의 컨테이너 재사용: ${name}"
      continue
    fi
    log_error "컨테이너 이름 충돌: ${name}  (project=${other:-없음})"
    log_error "기존 스택을 내리지 않습니다. override 의 container_name 을 바꾸세요."
    failed=1
  done

  return "${failed}"
}

guard_ports() {
  local port failed=0
  for port in "${CARED_PORTS[@]}"; do
    if ! port_listening "${port}"; then
      continue
    fi
    if our_container_owns_port "${port}"; then
      log_info "포트 ${port} 는 이 작업이 이미 사용 중"
      continue
    fi
    log_error "포트 ${port} 가 이미 사용 중입니다. 기존 vc-deploy / 다른 프로세스와 겹칩니다."
    failed=1
  done
  return "${failed}"
}

guard_existing_stack() {
  local failed=0

  log_step "기존 vc-deploy 와 충돌하는지 검사"
  log_info "compose project: $(compose_project)"
  log_info "컨테이너 접미사: -cared"
  log_info "포트: ${CARED_PORTS[*]}"

  export COMPOSE_PROJECT_NAME
  COMPOSE_PROJECT_NAME="$(compose_project)"

  if is_sim; then
    if ! command -v docker >/dev/null 2>&1; then
      log_info "충돌 없음. 기존 vc-deploy 는 그대로 두고 이 작업만 올립니다."
      return 0
    fi
  fi

  guard_containers || failed=1
  guard_ports || failed=1

  if [[ "${failed}" -ne 0 ]]; then
    log_error "기존 배포와 겹칩니다. 이 상태로 올리면 vc-deploy 를 건드릴 수 있어 중단합니다."
    return 1
  fi

  log_info "충돌 없음. 기존 vc-deploy 는 그대로 두고 이 작업만 올립니다."
}
