#!/usr/bin/env bash

CURRENT_STEP=""
FAILED_STEP=""
FAILED_AT=""
DEPLOY_OK=0
PRE_DONE=0
RUN_DONE=0
POST_DONE=0

state_dir() {
  echo "${SCRIPT_DIR}/state"
}

phase_file() {
  echo "$(state_dir)/phase"
}

hospital_file() {
  echo "$(state_dir)/${HOSPITAL}"
}

state_get() {
  local file="$1"
  local key="$2"
  [[ -f "${file}" ]] || return 0
  grep -E "^${key}=" "${file}" | tail -n 1 | cut -d'=' -f2-
}

state_set() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp

  mkdir -p "$(dirname "${file}")"
  touch "${file}"
  tmp="$(mktemp)"
  awk -v k="${key}" -v v="${value}" '
    BEGIN { replaced = 0 }
    $0 ~ "^" k "=" {
      print k "=" v
      replaced = 1
      next
    }
    { print }
    END {
      if (replaced == 0) print k "=" v
    }
  ' "${file}" > "${tmp}"
  mv "${tmp}" "${file}"
}

load_phase() {
  PRE_DONE="$(state_get "$(phase_file)" "PRE_DONE")"
  PRE_DONE="${PRE_DONE:-0}"
}

load_hospital_state() {
  local file
  FAILED_STEP=""
  FAILED_AT=""
  RUN_DONE=0
  POST_DONE=0
  [[ -n "${HOSPITAL}" ]] || return 0
  file="$(hospital_file)"
  [[ -f "${file}" ]] || return 0
  FAILED_STEP="$(state_get "${file}" "FAILED_STEP")"
  FAILED_AT="$(state_get "${file}" "FAILED_AT")"
  RUN_DONE="$(state_get "${file}" "RUN_DONE")"
  POST_DONE="$(state_get "${file}" "POST_DONE")"
  RUN_DONE="${RUN_DONE:-0}"
  POST_DONE="${POST_DONE:-0}"
}

load_fail_state() {
  load_hospital_state
}

save_fail_state() {
  local step="${1:-${CURRENT_STEP:-unknown}}"
  if is_sim || [[ -z "${HOSPITAL}" ]]; then
    return 0
  fi
  state_set "$(hospital_file)" "FAILED_STEP" "${step}"
  state_set "$(hospital_file)" "FAILED_AT" "$(iso_now)"
}

clear_fail_state() {
  if is_sim || [[ -z "${HOSPITAL}" ]]; then
    return 0
  fi
  [[ -f "$(hospital_file)" ]] || return 0
  state_set "$(hospital_file)" "FAILED_STEP" ""
  state_set "$(hospital_file)" "FAILED_AT" ""
}

print_sim_next_hint() {
  echo
  log_info "다음 단계로 넘어가려면 이 단계를 완료해야 합니다. (작업자 판단에 따라 pass 가능)"
}

mark_pre_done() {
  if is_sim; then
    print_sim_next_hint
    return 0
  fi
  state_set "$(phase_file)" "PRE_DONE" "1"
  state_set "$(phase_file)" "PRE_AT" "$(iso_now)"
  PRE_DONE=1
}

clear_pre_done() {
  if is_sim; then
    return 0
  fi
  state_set "$(phase_file)" "PRE_DONE" "0"
  PRE_DONE=0
}

mark_run_done() {
  if is_sim; then
    print_sim_next_hint
    return 0
  fi
  if [[ -z "${HOSPITAL}" ]]; then
    return 0
  fi
  state_set "$(hospital_file)" "RUN_DONE" "1"
  state_set "$(hospital_file)" "RUN_AT" "$(iso_now)"
  RUN_DONE=1
}

mark_post_done() {
  if is_sim; then
    print_sim_next_hint
    return 0
  fi
  if [[ -z "${HOSPITAL}" ]]; then
    return 0
  fi
  state_set "$(hospital_file)" "POST_DONE" "1"
  state_set "$(hospital_file)" "POST_AT" "$(iso_now)"
  POST_DONE=1
}

require_pre_done() {
  if is_sim; then
    return 0
  fi
  load_phase
  if [[ "${PRE_DONE}" != "1" ]]; then
    log_error "사전점검이 끝나지 않았습니다."
    log_error "./deploy.sh pre 를 먼저 실행하세요."
    exit 1
  fi
}

require_run_done() {
  if is_sim; then
    return 0
  fi
  load_hospital_state
  if [[ "${RUN_DONE}" != "1" ]]; then
    log_error "${HOSPITAL} 실 배포가 끝나지 않았습니다."
    log_error "./deploy.sh run 을 먼저 끝까지 실행하세요."
    exit 1
  fi
}

on_deploy_exit() {
  local code=$?
  if [[ "${DEPLOY_OK}" -eq 1 ]]; then
    clear_fail_state
    mark_run_done
    return 0
  fi
  if is_sim || [[ -z "${HOSPITAL}" || -z "${CURRENT_STEP}" ]]; then
    return 0
  fi
  if [[ "${code}" -ne 0 ]]; then
    save_fail_state "${CURRENT_STEP}"
    log_error "실패 지점 저장: ${CURRENT_STEP}"
    log_error "실패는 ${HOSPITAL}-v215 안에만 남깁니다. 기존 vc-deploy 는 내리지 않습니다."
    if ! is_sim && command -v docker >/dev/null 2>&1; then
      case "${CURRENT_STEP}" in
        prepare) ;;
        *) dc ps -a || true ;;
      esac
    fi
  fi
}
