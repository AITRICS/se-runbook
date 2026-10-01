#!/usr/bin/env bash
# VitalCare 2.2.3 업그레이드 실행. Ubuntu 22.04 / 24.04.
# tmux 세션 안에서 initiate / script / fix-defect 를 돌리고, 끝나면 그 세션을 종료한다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/images.sh
source "${SCRIPT_DIR}/lib/images.sh"

STATE_DIR="${SCRIPT_DIR}/state"
SQL_FILE="${SCRIPT_DIR}/sql/truncate.sql"

HOSPITAL=""
STACK_DIR=""
PROJECT_NAME=""
MODE=""

UP_SERVICES=(
  mysql
  mongodb
  rabbitmq
  backend-migration
  sync-migration
  backend
  frontend
  admin
  nginx
  scoring-service
  vcsm-kotlin
  screening-service
  dlq-manager
)

usage() {
  cat <<EOF
사용:
  ./run.sh                 메뉴에서 고른다
  ./run.sh initiate        저장소/병원폴더/환경변수/스택 기동
  ./run.sh script          observer, sync live, vc-script
  ./run.sh fix-defect      truncate 안내, restore, live 여부

시작 시 시뮬레이션을 보여 준 뒤에 진행한다.
실행은 tmux 세션 ${TMUX_SESSION} 안에서 하고, 끝나면 그 세션을 종료한다.
작업 경로: ${DEPLOY_HOME}/<병원폴더>
기준 템플릿: ${EXAMPLE_DIR_NAME}
EOF
}

show_simulation() {
  cat <<EOF

${BOLD}VitalCare 2.2.3 업그레이드 실행 시뮬레이션${NC}
처음 보는 사람을 위한 예행연습이다. 지금은 아무것도 실행하지 않는다.
이 스크립트는 pre.sh 다음에 쓴다. 작업은 tmux 세션 ${TMUX_SESSION} 안에서 진행되고, 끝나면 세션이 닫힌다.

기준은 vc-deploy 의 ${EXAMPLE_DIR_NAME} 이다.
병원 폴더는 ${DEPLOY_HOME}/<병원이름> 으로 복사한다.
compose 가 ../mysql, ../vitalcare 를 include 하므로 폴더는 저장소 안에 둬야 한다.

[initiate]
  1. ${DEPLOY_HOME} 가 없으면 ${VC_DEPLOY_REPO} 를 clone 한다. 있으면 재사용한다.
  2. ${EXAMPLE_DIR_NAME} 을 병원 폴더로 복사한다.
  3. 환경변수를 하나씩 묻는다. 기본값은 괄호 안이다.
       HOST_NAME, CONFIG_DIR 은 병원 폴더 이름으로 넣는다.
       .env  VC_SYNC_IMAGE_TAG (${DEFAULT_SYNC_TAG})
       envs/db-encrypt.env  DB_ENCRYPTION_KEY, DB_ENCRYPTION_KEY_HASH
         값은 화면에 남지 않고, 기본값도 보여 주지 않는다.
       api 또는 view
         api  : envs/sync.env 의 API_BASE_URL
         view : VCSYNC_EMR_HOST, PORT, DB, SERVICE, USER, PASSWORD
  4. sudo 로 init-deploy-settings.sh 를 돌려 볼륨 디렉터리를 만든다.
  5. docker-compose.yaml 의 restore-sync, restore-observer 주석을 해제한다.
  6. sync 와 observer 는 띄우지 않고, 아래 순서대로 올린다.
$(printf '       - %s\n' "${UP_SERVICES[@]}")

[script]
  1. observer 를 live 로 올린다.  compose 명령은 \`observe run\`
  2. sync 를 live 로 올린다.      compose 명령은 \`sync\`
  3. 로컬에서 가장 최근 vc-script 이미지를 대화형으로 실행한다.
       docker run -it --rm --name vc-script --net=host <vc-script 이미지>
       DB host 127.0.0.1, DB port 3322 (mysql-v223)

[fix-defect]
  이전에 돌린 기록이 있으면 그 내용을 먼저 보여 주고, 그대로 돌릴지 묻는다.
  1. truncate 가 필요한지 묻는다.
       필요하면 sql/truncate.sql 을 복사하기 쉽게 출력한다. 스크립트가 실행하지는 않는다.
       docker exec -it mysql-v223 mysql -u root -p
  2. restore 를 돌릴지 묻는다.
       돌리면 기간을 받는다. 한 번 쓴 기간은 state/ 에 저장하고 다음 기본값으로 보여 준다.
       restore-sync     restore --start=YYYYMMDDHHMM --end=YYYYMMDDHHMM --min-interval=1
       restore-observer observe restore --start=YYYYMMDD --end=YYYYMMDD
       docker compose run 으로 command 를 override 해서 띄운다.
  3. sync 와 observer 를 live 로 띄울지 묻는다.
       띄운다고 하면 올린다.
       안 띄운다고 하면 여기서 끝낸다.

EOF
}

container_name() {
  case "$1" in
    mysql) echo mysql-v223 ;;
    mongodb) echo mongodb-v223 ;;
    rabbitmq) echo rabbitmq-v223 ;;
    sync-migration) echo sync-migration-v223 ;;
    backend-migration) echo backend-migration-v223 ;;
    vcsm-kotlin) echo vcsm-kotlin-v223 ;;
    dlq-manager) echo dlq-manager-v223 ;;
    scoring-service) echo scoring-service-v223 ;;
    sync) echo sync-v223 ;;
    observer) echo observer-v223 ;;
    backend) echo backend-v223 ;;
    frontend) echo frontend-v223 ;;
    admin) echo admin-v223 ;;
    screening-service) echo screening-service-v223 ;;
    nginx) echo nginx-1.31.0 ;;
    *) echo "$1" ;;
  esac
}

compose() {
  local -a files=(-f "${STACK_DIR}/docker-compose.yaml")
  if [[ -f "${STACK_DIR}/docker-compose.override.yaml" ]]; then
    files+=(-f "${STACK_DIR}/docker-compose.override.yaml")
  fi
  docker compose \
    --project-directory "${STACK_DIR}" \
    --project-name "${PROJECT_NAME}" \
    "${files[@]}" \
    "$@"
}

run_cmd() {
  log_info "실행: $*"
  "$@"
}

ask_hospital() {
  local current="${1:-}"
  HOSPITAL="$(prompt_required "병원 폴더 이름 (영문)" "${current}")"
  HOSPITAL="$(normalize_hospital "${HOSPITAL}")"
  validate_hospital "${HOSPITAL}"
  STACK_DIR="${DEPLOY_HOME}/${HOSPITAL}"
  PROJECT_NAME="${HOSPITAL}"
}

require_stack() {
  if [[ ! -f "${STACK_DIR}/docker-compose.yaml" ]]; then
    log_error "병원 폴더가 없습니다: ${STACK_DIR}"
    log_error "먼저 ./run.sh initiate 로 폴더를 만드세요."
    exit 1
  fi
}

ensure_repo() {
  log_step "vc-deploy 준비  (${DEPLOY_HOME})"
  if [[ -f "${DEPLOY_HOME}/${EXAMPLE_DIR_NAME}/docker-compose.yaml" ]]; then
    log_info "이미 있습니다. clone 하지 않습니다."
    return 0
  fi
  if [[ -d "${DEPLOY_HOME}" ]]; then
    log_error "${DEPLOY_HOME} 은 있지만 ${EXAMPLE_DIR_NAME} 이 없습니다."
    exit 1
  fi
  require_cmd git
  log_info "git clone ${VC_DEPLOY_REPO}"
  git clone "${VC_DEPLOY_REPO}" "${DEPLOY_HOME}"
}

copy_hospital_dir() {
  local src="${DEPLOY_HOME}/${EXAMPLE_DIR_NAME}"
  log_step "병원 폴더  ${src} -> ${STACK_DIR}"
  if [[ ! -d "${src}" ]]; then
    log_error "템플릿이 없습니다: ${src}"
    exit 1
  fi
  if [[ -d "${STACK_DIR}" ]]; then
    log_info "이미 있습니다: ${STACK_DIR}"
    ask_choice "이 폴더를 어떻게 할까요?" \
      "환경변수를 다시 설정하고 컨테이너를 올린다" \
      "환경변수는 그대로 두고 컨테이너만 올린다" \
      "종료"
    case "${CHOICE}" in
      1) RESET_ENV=1 ;;
      2) RESET_ENV=0 ;;
      3) log_info "종료합니다."; exit 0 ;;
    esac
    return 0
  fi
  cp -a "${src}" "${STACK_DIR}"
  RESET_ENV=1
  log_info "생성: ${STACK_DIR}"
}

configure_env() {
  local env_file="${STACK_DIR}/.env"
  local encrypt_file="${STACK_DIR}/envs/db-encrypt.env"
  local sync_file="${STACK_DIR}/envs/sync.env"
  local sync_tag key key_hash mode api_url
  local emr_host emr_port emr_db emr_service emr_user emr_password

  [[ "${RESET_ENV}" -eq 1 ]] || return 0

  log_step "환경변수"
  echo "HOST_NAME 과 CONFIG_DIR 은 병원 폴더 이름으로 넣습니다."
  echo "  HOST_NAME=${HOSPITAL}"
  echo "  CONFIG_DIR=../${HOSPITAL}/configs"
  set_kv "${env_file}" "HOST_NAME" "${HOSPITAL}"
  set_kv "${env_file}" "CONFIG_DIR" "../${HOSPITAL}/configs"

  sync_tag="$(get_kv "${env_file}" "VC_SYNC_IMAGE_TAG")"
  sync_tag="${sync_tag:-${DEFAULT_SYNC_TAG}}"
  sync_tag="$(prompt_required ".env  VC_SYNC_IMAGE_TAG" "${sync_tag}")"
  set_kv "${env_file}" "VC_SYNC_IMAGE_TAG" "${sync_tag}"

  echo
  echo "envs/db-encrypt.env  기본값은 보여 주지 않습니다. 입력은 화면에 표시되지 않습니다."
  key="$(prompt_secret "DB_ENCRYPTION_KEY")"
  key_hash="$(prompt_secret "DB_ENCRYPTION_KEY_HASH")"
  set_kv "${encrypt_file}" "DB_ENCRYPTION_KEY" "${key}"
  set_kv "${encrypt_file}" "DB_ENCRYPTION_KEY_HASH" "${key_hash}"
  chmod 600 "${encrypt_file}"

  ask_choice "연동 방식은 무엇인가요?" "api" "view"
  mode="${CHOICE_LABEL}"

  if [[ "${mode}" == "api" ]]; then
    echo
    echo "envs/sync.env 의 API_BASE_URL 을 설정합니다."
    api_url="$(prompt_required "API_BASE_URL")"
    set_kv "${sync_file}" "API_BASE_URL" "${api_url}"
    chmod 600 "${sync_file}"
  else
    echo
    echo "envs/sync.env 의 EMR(view) 값을 설정합니다."
    emr_host="$(prompt_required "VCSYNC_EMR_HOST")"
    emr_port="$(prompt_required "VCSYNC_EMR_PORT")"
    while [[ ! "${emr_port}" =~ ^[0-9]+$ ]]; do
      echo "포트는 숫자여야 합니다." >&2
      emr_port="$(prompt_required "VCSYNC_EMR_PORT")"
    done
    emr_db="$(prompt_required "VCSYNC_EMR_DB")"
    echo "오라클 서비스명이 없으면 - 를 입력하세요." >&2
    emr_service="$(prompt_required "VCSYNC_EMR_SERVICE" "-")"
    if [[ "${emr_service}" == "-" ]]; then
      emr_service=""
    fi
    emr_user="$(prompt_required "VCSYNC_EMR_USER")"
    emr_password="$(prompt_secret "VCSYNC_EMR_PASSWORD")"
    set_kv "${sync_file}" "VCSYNC_EMR_HOST" "${emr_host}"
    set_kv "${sync_file}" "VCSYNC_EMR_PORT" "${emr_port}"
    set_kv "${sync_file}" "VCSYNC_EMR_DB" "${emr_db}"
    set_kv "${sync_file}" "VCSYNC_EMR_SERVICE" "${emr_service}"
    set_kv "${sync_file}" "VCSYNC_EMR_USER" "${emr_user}"
    set_kv "${sync_file}" "VCSYNC_EMR_PASSWORD" "${emr_password}"
    comment_kv "${sync_file}" "API_BASE_URL"
    chmod 600 "${sync_file}"
  fi

  echo
  echo "----------------------------------------"
  echo "  병원 폴더          ${STACK_DIR}"
  echo "  HOST_NAME          ${HOSPITAL}"
  echo "  CONFIG_DIR         ../${HOSPITAL}/configs"
  echo "  VC_SYNC_IMAGE_TAG  ${sync_tag}"
  echo "  연동               ${mode}"
  if [[ "${mode}" == "api" ]]; then
    echo "  API_BASE_URL       ${api_url}"
  else
    echo "  EMR                ${emr_user}@${emr_host}:${emr_port}/${emr_db}"
  fi
  echo "  DB_ENCRYPTION_KEY       $(mask_len "${key}")"
  echo "  DB_ENCRYPTION_KEY_HASH  $(mask_len "${key_hash}")"
  echo "----------------------------------------"
}

uncomment_restore() {
  local file="${STACK_DIR}/docker-compose.yaml"
  local tmp line block=0
  log_step "restore-sync / restore-observer 주석 해제"
  if ! grep -q '^#  restore-sync:' "${file}"; then
    log_info "이미 주석이 해제되어 있습니다."
    return 0
  fi
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" == "#  restore-sync:" || "${line}" == "#  restore-observer:" ]]; then
      block=1
    fi
    if [[ "${block}" -eq 1 ]]; then
      if [[ "${line}" == \#* ]]; then
        line="${line:1}"
      fi
      printf '%s\n' "${line}"
      if [[ "${line}" == *sync-migration* && "${line}" != *"#"* ]]; then
        block=0
      fi
    else
      printf '%s\n' "${line}"
    fi
  done < "${file}" > "${tmp}"
  mv "${tmp}" "${file}"
  log_info "주석을 해제했습니다: ${file}"
}

prepare_volumes() {
  local script="${STACK_DIR}/init-deploy-settings.sh"
  log_step "볼륨 디렉터리"
  if [[ ! -f "${script}" ]]; then
    log_error "없습니다: ${script}"
    exit 1
  fi
  run_cmd sudo bash "${script}"
}

wait_healthy() {
  local name="$1"
  local i status
  for i in $(seq 1 60); do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${name}" 2>/dev/null || echo missing)"
    if [[ "${status}" == "healthy" ]]; then
      log_info "${name} healthy"
      return 0
    fi
    sleep 5
  done
  log_error "${name} 가 healthy 가 되지 않았습니다 (status=${status})."
  docker logs --tail 80 "${name}" >&2 || true
  return 1
}

wait_running() {
  local name="$1"
  local i status
  for i in $(seq 1 12); do
    status="$(docker inspect -f '{{.State.Status}}' "${name}" 2>/dev/null || echo missing)"
    case "${status}" in
      running)
        log_info "${name} running"
        return 0
        ;;
      exited|dead)
        log_error "${name} 가 바로 종료됐습니다."
        docker logs --tail 80 "${name}" >&2 || true
        return 1
        ;;
    esac
    sleep 2
  done
  log_error "${name} 가 running 이 되지 않았습니다 (status=${status})."
  docker logs --tail 80 "${name}" >&2 || true
  return 1
}

wait_oneshot() {
  local name="$1"
  local i status code
  for i in $(seq 1 120); do
    status="$(docker inspect -f '{{.State.Status}}' "${name}" 2>/dev/null || echo missing)"
    case "${status}" in
      exited)
        code="$(docker inspect -f '{{.State.ExitCode}}' "${name}")"
        if [[ "${code}" == "0" ]]; then
          log_info "${name} exit 0"
          return 0
        fi
        log_error "${name} exit ${code}"
        docker logs --tail 80 "${name}" >&2 || true
        return 1
        ;;
      missing)
        log_error "${name} 컨테이너가 없습니다."
        return 1
        ;;
    esac
    sleep 5
  done
  log_error "${name} 대기 시간이 지났습니다 (status=${status})."
  docker logs --tail 80 "${name}" >&2 || true
  return 1
}

up_service() {
  local svc="$1"
  local name
  name="$(container_name "${svc}")"
  log_step "${svc}  (${name})"
  run_cmd compose up -d --no-deps "${svc}"
  case "${svc}" in
    mysql|rabbitmq) wait_healthy "${name}" ;;
    backend-migration|sync-migration) wait_oneshot "${name}" ;;
    *) wait_running "${name}" ;;
  esac
}

up_stack_without_sync() {
  local svc
  log_step "sync / observer 를 제외하고 순서대로 기동"
  for svc in "${UP_SERVICES[@]}"; do
    up_service "${svc}"
  done
  echo
  compose ps
}

cmd_initiate() {
  local svc
  RESET_ENV=1
  ask_hospital
  echo
  echo "올릴 컨테이너 (sync, observer 제외)"
  for svc in "${UP_SERVICES[@]}"; do
    echo "  - ${svc}"
  done
  echo
  if ! ask_yes_no "이 병원으로 initiate 를 진행할까요?" "y"; then
    log_info "종료합니다."
    exit 0
  fi

  require_cmd docker
  ensure_repo
  copy_hospital_dir
  configure_env
  if ! ask_yes_no "이어서 볼륨을 만들고 컨테이너를 올릴까요?" "y"; then
    log_info "컨테이너는 올리지 않고 종료합니다."
    exit 0
  fi
  prepare_volumes
  uncomment_restore
  up_stack_without_sync
  log_step "initiate 종료"
  log_info "작업 경로: ${STACK_DIR}"
  log_info "sync 와 observer 는 띄우지 않았습니다. 다음 단계는 ./run.sh script 입니다."
}

up_live() {
  local svc
  for svc in observer sync; do
    log_step "${svc} live"
    run_cmd compose up -d --no-deps "${svc}"
    wait_running "$(container_name "${svc}")"
  done
}

cmd_script() {
  local image
  ask_hospital
  require_stack
  require_cmd docker
  echo
  echo "  observer live  (observe run)"
  echo "  sync live      (sync)"
  echo "  vc-script      host 네트워크, DB 127.0.0.1:3322"
  echo
  if ! ask_yes_no "script 를 진행할까요?" "y"; then
    log_info "종료합니다."
    exit 0
  fi

  up_live
  log_step "vc-script"
  if ! image="$(latest_vc_script_image)"; then
    log_error "로컬에 vc-script 이미지가 없습니다."
    exit 1
  fi
  log_info "이미지: ${image}"
  log_info "vc-script 질문에는 DB host 127.0.0.1, DB port 3322, DB Encryption 은 DB_ENCRYPTION_KEY 를 넣으세요."
  docker rm -f vc-script >/dev/null 2>&1 || true
  run_cmd docker run -it --rm --name vc-script --net=host "${image}"
  log_step "script 종료"
}

print_truncate_sql() {
  echo
  printf "${YELLOW}%s${NC}\n" "구분선 사이의 SQL 만 복사하세요. 구분선은 포함하지 마세요."
  printf "${YELLOW}%s${NC}\n" "실행 예: docker exec -it mysql-v223 mysql -u root -p"
  echo
  printf '%s\n' "---------- COPY START ----------"
  cat "${SQL_FILE}"
  printf '%s\n' "---------- COPY END ----------"
  echo
  log_info "MySQL 에서 실행을 마치면 Enter, 중단은 q"
  local answer
  read -r -p "> " answer
  if [[ "${answer}" == "q" || "${answer}" == "Q" ]]; then
    log_info "종료합니다. truncate 는 스크립트가 실행하지 않았습니다."
    exit 0
  fi
}

fix_state_file() {
  printf '%s\n' "${STATE_DIR}/${HOSPITAL}.fix"
}

load_fix_state() {
  local file line key value
  file="$(fix_state_file)"
  FIX_HAS_STATE=0
  FIX_TRUNCATE=""
  FIX_RESTORE=""
  FIX_SYNC_START=""
  FIX_SYNC_END=""
  FIX_OBS_START=""
  FIX_OBS_END=""
  FIX_MIN_INTERVAL="1"
  FIX_LIVE=""
  FIX_RAN_AT=""
  [[ -f "${file}" ]] || return 0
  FIX_HAS_STATE=1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    case "${key}" in
      truncate) FIX_TRUNCATE="${value}" ;;
      restore) FIX_RESTORE="${value}" ;;
      sync_start) FIX_SYNC_START="${value}" ;;
      sync_end) FIX_SYNC_END="${value}" ;;
      observer_start) FIX_OBS_START="${value}" ;;
      observer_end) FIX_OBS_END="${value}" ;;
      min_interval) FIX_MIN_INTERVAL="${value}" ;;
      live) FIX_LIVE="${value}" ;;
      ran_at) FIX_RAN_AT="${value}" ;;
    esac
  done < "${file}"
}

save_fix_state() {
  local file
  mkdir -p "${STATE_DIR}"
  file="$(fix_state_file)"
  cat > "${file}" <<EOF
truncate=${FIX_TRUNCATE}
restore=${FIX_RESTORE}
sync_start=${FIX_SYNC_START}
sync_end=${FIX_SYNC_END}
observer_start=${FIX_OBS_START}
observer_end=${FIX_OBS_END}
min_interval=${FIX_MIN_INTERVAL}
live=${FIX_LIVE}
ran_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
  chmod 600 "${file}"
}

show_previous_fix() {
  echo
  echo "----------------------------------------"
  echo " 이전 fix-defect  ${FIX_RAN_AT:-기록}"
  echo "  truncate   ${FIX_TRUNCATE:-모름}"
  echo "  restore    ${FIX_RESTORE:-모름}"
  if [[ "${FIX_RESTORE}" == "yes" ]]; then
    echo "  sync       ${FIX_SYNC_START} ~ ${FIX_SYNC_END}  (min-interval ${FIX_MIN_INTERVAL})"
    echo "  observer   ${FIX_OBS_START} ~ ${FIX_OBS_END}"
  fi
  echo "  live       ${FIX_LIVE:-모름}"
  echo "  파일       $(fix_state_file)"
  echo "----------------------------------------"
}

prompt_period() {
  local start_default="${FIX_SYNC_START:-202410180000}"
  local end_default="${FIX_SYNC_END:-202410180030}"
  local obs_start_default obs_end_default interval_default

  while true; do
    FIX_SYNC_START="$(prompt_required "restore-sync 시작 YYYYMMDDHHMM" "${start_default}")"
    FIX_SYNC_END="$(prompt_required "restore-sync 종료 YYYYMMDDHHMM" "${end_default}")"
    if [[ ! "${FIX_SYNC_START}" =~ ^[0-9]{12}$ || ! "${FIX_SYNC_END}" =~ ^[0-9]{12}$ ]]; then
      echo "형식은 YYYYMMDDHHMM 입니다. 예: 202410180000"
      continue
    fi
    if [[ "${FIX_SYNC_END}" < "${FIX_SYNC_START}" ]]; then
      echo "종료가 시작보다 빠릅니다."
      continue
    fi
    break
  done

  obs_start_default="${FIX_OBS_START:-${FIX_SYNC_START:0:8}}"
  obs_end_default="${FIX_OBS_END:-${FIX_SYNC_END:0:8}}"
  while true; do
    FIX_OBS_START="$(prompt_required "restore-observer 시작 YYYYMMDD" "${obs_start_default}")"
    FIX_OBS_END="$(prompt_required "restore-observer 종료 YYYYMMDD" "${obs_end_default}")"
    if [[ ! "${FIX_OBS_START}" =~ ^[0-9]{8}$ || ! "${FIX_OBS_END}" =~ ^[0-9]{8}$ ]]; then
      echo "형식은 YYYYMMDD 입니다. 예: 20241018"
      continue
    fi
    if [[ "${FIX_OBS_END}" < "${FIX_OBS_START}" ]]; then
      echo "종료가 시작보다 빠릅니다."
      continue
    fi
    break
  done

  interval_default="${FIX_MIN_INTERVAL:-1}"
  FIX_MIN_INTERVAL="$(prompt_required "restore-sync min-interval" "${interval_default}")"
  while [[ ! "${FIX_MIN_INTERVAL}" =~ ^[0-9]+$ ]]; do
    echo "min-interval 은 숫자입니다." >&2
    FIX_MIN_INTERVAL="$(prompt_required "restore-sync min-interval" "${interval_default}")"
  done
}

ensure_restore_dirs() {
  local volume_dir
  volume_dir="$(get_kv "${STACK_DIR}/.env" "VOLUME_DIR")"
  if [[ -z "${volume_dir}" ]]; then
    log_error "VOLUME_DIR 이 비어 있습니다. ${STACK_DIR}/.env 를 확인하세요."
    exit 1
  fi
  run_cmd sudo mkdir -p "${volume_dir}/logs/restore-sync" "${volume_dir}/logs/restore-observer"
  run_cmd sudo chown 1000:1000 "${volume_dir}/logs/restore-sync" "${volume_dir}/logs/restore-observer"
}

run_restore() {
  uncomment_restore
  ensure_restore_dirs
  log_step "restore-sync"
  run_cmd compose run --rm --no-deps restore-sync \
    restore --start="${FIX_SYNC_START}" --end="${FIX_SYNC_END}" --min-interval="${FIX_MIN_INTERVAL}"
  log_step "restore-observer"
  run_cmd compose run --rm --no-deps restore-observer \
    observe restore --start="${FIX_OBS_START}" --end="${FIX_OBS_END}"
}

cmd_fix_defect() {
  local replay=0
  ask_hospital
  require_stack
  require_cmd docker
  load_fix_state

  if [[ "${FIX_HAS_STATE}" -eq 1 ]]; then
    show_previous_fix
    if ask_yes_no "이전과 같이 돌릴까요?" "n"; then
      replay=1
    fi
  fi

  if [[ "${replay}" -eq 1 && "${FIX_RESTORE}" == "yes" && ! "${FIX_SYNC_START}" =~ ^[0-9]{12}$ ]]; then
    log_warn "저장된 restore 기간이 없습니다. 다시 입력합니다."
    prompt_period
  fi

  if [[ "${replay}" -eq 0 ]]; then
    if ask_yes_no "truncate 가 필요한가요?"; then
      FIX_TRUNCATE=yes
    else
      FIX_TRUNCATE=no
    fi
    if ask_yes_no "restore 를 돌릴까요?"; then
      FIX_RESTORE=yes
      prompt_period
    else
      FIX_RESTORE=no
    fi
    if ask_yes_no "sync 와 observer 를 live 로 띄울까요?"; then
      FIX_LIVE=yes
    else
      FIX_LIVE=no
    fi
  fi

  echo
  echo "----------------------------------------"
  echo "  truncate  ${FIX_TRUNCATE}"
  echo "  restore   ${FIX_RESTORE}"
  if [[ "${FIX_RESTORE}" == "yes" ]]; then
    echo "  sync      ${FIX_SYNC_START} ~ ${FIX_SYNC_END}  min-interval=${FIX_MIN_INTERVAL}"
    echo "  observer  ${FIX_OBS_START} ~ ${FIX_OBS_END}"
  fi
  echo "  live      ${FIX_LIVE}"
  echo "----------------------------------------"
  if ! ask_yes_no "이 설정으로 fix-defect 를 진행할까요?" "y"; then
    log_info "종료합니다. 기록은 바꾸지 않았습니다."
    exit 0
  fi

  if [[ "${FIX_TRUNCATE}" == "yes" ]]; then
    print_truncate_sql
  else
    log_info "truncate 없이 진행합니다."
  fi

  save_fix_state

  if [[ "${FIX_RESTORE}" == "yes" ]]; then
    run_restore
  else
    log_info "restore 없이 진행합니다."
  fi

  if [[ "${FIX_LIVE}" == "yes" ]]; then
    up_live
    log_info "observer 와 sync 를 live 로 띄웠습니다."
  else
    log_info "sync 와 observer 는 띄우지 않고 종료합니다."
  fi
  log_step "fix-defect 종료"
}

choose_mode() {
  if [[ -n "${MODE}" ]]; then
    return 0
  fi
  ask_choice "무엇을 할까요?" \
    "initiate    저장소, 병원 폴더, 환경변수, 스택 기동" \
    "script      observer live, sync live, vc-script" \
    "fix-defect  truncate 안내, restore, live 여부" \
    "종료"
  case "${CHOICE}" in
    1) MODE="initiate" ;;
    2) MODE="script" ;;
    3) MODE="fix-defect" ;;
    4) log_info "종료합니다."; exit 0 ;;
  esac
}

main() {
  case "${1:-}" in
    -h|--help)
      usage
      exit 0
      ;;
    initiate|script|fix-defect)
      MODE="$1"
      ;;
    "")
      MODE=""
      ;;
    *)
      log_error "모르는 명령: $1"
      usage
      exit 1
      ;;
  esac

  ensure_tmux "$@"
  trap finish_tmux EXIT

  show_simulation
  if ! ask_yes_no "시뮬레이션을 확인했습니다. 실제로 진행할까요?" "y"; then
    log_info "종료합니다. 작업은 실행하지 않았습니다."
    exit 0
  fi

  choose_mode
  case "${MODE}" in
    initiate) cmd_initiate ;;
    script) cmd_script ;;
    fix-defect) cmd_fix_defect ;;
  esac
}

main "$@"
