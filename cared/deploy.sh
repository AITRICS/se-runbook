#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/env.sh
source "${SCRIPT_DIR}/lib/env.sh"
# shellcheck source=lib/compose.sh
source "${SCRIPT_DIR}/lib/compose.sh"
# shellcheck source=lib/wait.sh
source "${SCRIPT_DIR}/lib/wait.sh"
# shellcheck source=lib/inspect.sh
source "${SCRIPT_DIR}/lib/inspect.sh"
# shellcheck source=lib/cli.sh
source "${SCRIPT_DIR}/lib/cli.sh"
# shellcheck source=lib/collision.sh
source "${SCRIPT_DIR}/lib/collision.sh"
# shellcheck source=lib/images.sh
source "${SCRIPT_DIR}/lib/images.sh"
# shellcheck source=lib/state.sh
source "${SCRIPT_DIR}/lib/state.sh"
# shellcheck source=lib/check.sh
source "${SCRIPT_DIR}/lib/check.sh"

CARED_REPO="${CARED_REPO:-https://github.com/AITRICS/cared-deploy.git}"
CARED_HOME="${CARED_HOME:-${HOME}/cared-deploy}"
EXAMPLE_DIR="${EXAMPLE_DIR:-example-2.1.5}"
CYCLE_TIMEOUT="${CYCLE_TIMEOUT:-2700}"
SIMULATION=0
FROM_STEP="prepare"
HOSPITAL=""
CONFIG_FILE=""
STACK_DIR=""
IMAGE_SOURCE=""

STEPS=(
  prepare
  mysql
  sync-migration
  backend-migration
  backend
  frontend
  observer
  sync
  chmod
  scoring
  inspect
)

should_run() {
  local current="$1"
  local started=0
  local step
  for step in "${STEPS[@]}"; do
    [[ "${step}" == "${FROM_STEP}" ]] && started=1
    if [[ "${started}" -eq 1 && "${step}" == "${current}" ]]; then
      return 0
    fi
  done
  return 1
}

run_step() {
  local name="$1"
  shift
  CURRENT_STEP="${name}"
  if should_run "${name}"; then
    "$@"
  else
    log_info "skip: ${name}"
  fi
}

ensure_cared_home() {
  log_step "cared-deploy 준비  (${CARED_HOME})"

  if [[ -d "${CARED_HOME}/.git" || -d "${CARED_HOME}/${EXAMPLE_DIR}" ]]; then
    log_info "이미 있습니다: ${CARED_HOME}"
    return 0
  fi

  if [[ -d "${CARED_HOME}" ]]; then
    log_error "${CARED_HOME} 은 있지만 cared-deploy 구성이 아닙니다."
    exit 1
  fi

  if command -v git >/dev/null 2>&1; then
    log_info "git clone ${CARED_REPO}"
    if ! is_sim; then
      git clone "${CARED_REPO}" "${CARED_HOME}"
    fi
    return 0
  fi

  log_error "git이 없습니다. cared-deploy를 ${CARED_HOME} 에 직접 복사한 뒤 다시 실행하세요."
  exit 1
}

copy_stack_dir() {
  local src="${CARED_HOME}/${EXAMPLE_DIR}"
  local dest="${STACK_DIR}"

  log_step "스택 폴더 복사  ${EXAMPLE_DIR} -> $(basename "${dest}")"

  if [[ ! -d "${src}" ]]; then
    if is_sim; then
      log_info "생성: ${dest}"
      return 0
    fi
    log_error "예시 폴더가 없습니다: ${src}"
    exit 1
  fi

  if [[ -d "${dest}" ]]; then
    log_info "이미 있습니다: ${dest}"
    return 0
  fi

  if ! is_sim; then
    cp -R "${src}" "${dest}"
  fi
  log_info "생성: ${dest}"
}

prepare() {
  ensure_cared_home
  copy_stack_dir
  step_env
}

step_env() {
  setup_env_files "${STACK_DIR}" "${HOSPITAL}"

  local init_script="${STACK_DIR}/init-deploy-settings.sh"
  if [[ ! -x "${init_script}" ]]; then
    init_script="${CARED_HOME}/${EXAMPLE_DIR}/init-deploy-settings.sh"
  fi
  if [[ -x "${init_script}" ]]; then
    log_step "볼륨 디렉터리 생성"
    if ! is_sim; then
      sudo "${init_script}"
    fi
  fi
}

step_mysql() {
  compose_up mysql
  wait_mysql_healthy
}

step_sync_migration() {
  compose_up_oneshot sync-migration
}

step_backend_migration() {
  compose_up_oneshot backend-migration
}

step_backend() {
  compose_up backend
  check_backend_or_encrypt
}

step_frontend() {
  compose_up frontend admin
}

step_observer() {
  compose_up observer
  wait_for_cycle observer "observer run end" "${CYCLE_TIMEOUT}"
}

step_sync() {
  compose_up sync
  wait_for_cycle sync "sync end :" "${CYCLE_TIMEOUT}"
}

step_chmod() {
  local volume_dir
  volume_dir="$(get_env_value "${STACK_DIR}/.env" "VOLUME_DIR")"
  if [[ -z "${volume_dir}" ]]; then
    volume_dir="$(get_env_value "${CARED_HOME}/${EXAMPLE_DIR}/.env" "VOLUME_DIR")"
  fi
  [[ -n "${volume_dir}" ]] || {
    log_error "VOLUME_DIR이 비어 있습니다. .env를 확인하세요."
    exit 1
  }

  log_step "로그 권한 열기 (scoring-manager / screening-service)"
  if ! is_sim; then
    sudo mkdir -p "${volume_dir}/logs"
    sudo chmod 777 -R "${volume_dir}/logs"
  fi
  log_info "chmod 777 -R ${volume_dir}/logs"
}

step_scoring() {
  compose_up scoring-manager scoring-service screening-service
  wait_for_cycle scoring-manager "Finish recording scores" "${CYCLE_TIMEOUT}"
}

step_inspect() {
  run_inspect "${STACK_DIR}/inspect"
}

# run 은 pre 에서 이미지가 준비된 것을 전제로 한다. pull 하지 않는다.
run_deploy() {
  if ! is_sim; then
    require_cmd docker
  fi

  run_step prepare prepare

  if is_sim; then
    :
  else
    [[ -d "${STACK_DIR}" ]] || {
      log_error "스택 폴더가 없습니다: ${STACK_DIR}"
      exit 1
    }
    cd "${STACK_DIR}"
  fi
  COMPOSE_PROJECT_NAME="$(compose_project)"
  export COMPOSE_PROJECT_NAME
  require_our_compose_project

  CURRENT_STEP="mysql"
  guard_existing_stack
  run_step mysql step_mysql
  run_step sync-migration step_sync_migration
  run_step backend-migration step_backend_migration
  run_step backend step_backend
  run_step frontend step_frontend
  run_step observer step_observer
  run_step sync step_sync
  run_step chmod step_chmod
  run_step scoring step_scoring
  run_step inspect step_inspect

  DEPLOY_OK=1
  log_step "배포 자동화 종료"
  log_info "작업 경로: ${STACK_DIR}"
}

cmd_pre() {
  ask_mode "CARED v2.1.5 사전점검"
  ask_image_source
  if run_preflight; then
    mark_pre_done
  else
    clear_pre_done
    return 1
  fi
}

cmd_run() {
  wizard

  trap 'exit 130' INT
  trap on_deploy_exit EXIT


  if [[ -n "${CONFIG_FILE}" ]]; then
    load_config_file "${CONFIG_FILE}"
  fi

  STACK_DIR="${CARED_HOME}/${HOSPITAL}-v215"
  print_plan

  confirm "이 설정으로 진행할까요?" || {
    log_warn "중단"
    exit 1
  }

  run_deploy
}

cmd_post() {
  ask_mode "CARED v2.1.5 사후점검"
  HOSPITAL="$(prompt_value "영문 병원 이름" "${HOSPITAL}")"
  HOSPITAL="$(normalize_hospital "${HOSPITAL}")"
  validate_hospital "${HOSPITAL}"
  require_run_done
  STACK_DIR="${CARED_HOME}/${HOSPITAL}-v215"
  COMPOSE_PROJECT_NAME="$(compose_project)"
  export COMPOSE_PROJECT_NAME
  if run_postcheck; then
    mark_post_done
  else
    return 1
  fi
}

main() {
  case "${1:-}" in
    pre) cmd_pre ;;
    run) cmd_run ;;
    post) cmd_post ;;
    -h|--help|"") print_usage ;;
    *)
      log_error "모르는 명령: ${1}"
      print_usage
      exit 1
      ;;
  esac
}

main "$@"
