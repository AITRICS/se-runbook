#!/usr/bin/env bash

print_usage() {
  echo "사용:"
  echo "  ./deploy.sh pre    사전점검"
  echo "  ./deploy.sh run    실 배포  (pre 통과 후)"
  echo "  ./deploy.sh post   사후점검  (run 완료 후)"
  echo
  echo "각 명령에서 실행 / 미리보기를 고른다."
}

ask_mode() {
  local title="$1"
  echo
  echo "${title}"
  echo
  ask_choice "무엇을 할까요?" \
    "실행" \
    "미리보기 (실행하지 않고 과정만 보기)" \
    "종료"
  case "${CHOICE}" in
    1) SIMULATION=0 ;;
    2) SIMULATION=1 ;;
    3) log_info "종료"; exit 0 ;;
  esac
}

# 1-based index를 CHOICE 에 넣는다. 표시만 하고 값은 전역으로 반환.
ask_choice() {
  local prompt="$1"
  shift
  local options=("$@")
  local i input

  echo
  echo "${prompt}"
  for i in "${!options[@]}"; do
    echo "  $((i + 1))) ${options[$i]}"
  done

  while true; do
    read -r -p "> " input
    if [[ "${input}" =~ ^[0-9]+$ ]] && ((input >= 1 && input <= ${#options[@]})); then
      CHOICE="${input}"
      CHOICE_VALUE="${options[$((input - 1))]}"
      return 0
    fi
    echo "1~${#options[@]} 중에서 고르세요."
  done
}

list_saved_configs() {
  local f
  SAVED_CONFIGS=()
  [[ -d "${SCRIPT_DIR}/config" ]] || return 0
  for f in "${SCRIPT_DIR}/config/"*.env; do
    [[ -f "${f}" ]] || continue
    [[ "$(basename "${f}")" == "example.env" ]] && continue
    SAVED_CONFIGS+=("${f}")
  done
}

wizard() {
  local options i

  ask_mode "CARED v2.1.5 배포 (run)"
  require_pre_done

  HOSPITAL="$(prompt_value "영문 병원 이름" "${HOSPITAL}")"
  HOSPITAL="$(normalize_hospital "${HOSPITAL}")"
  validate_hospital "${HOSPITAL}"
  load_fail_state
  if [[ -f "${SCRIPT_DIR}/config/${HOSPITAL}.env" ]]; then
    CONFIG_FILE="${SCRIPT_DIR}/config/${HOSPITAL}.env"
  fi

  options=()
  if [[ "${FAILED_STEP}" == "prepare" ]]; then
    options+=("처음부터  ← 실패")
  else
    options+=("처음부터")
  fi
  for i in "${!STEPS[@]}"; do
    [[ "${STEPS[$i]}" == "prepare" ]] && continue
    if [[ "${STEPS[$i]}" == "${FAILED_STEP}" ]]; then
      options+=("${STEPS[$i]} 부터  ← 실패")
    else
      options+=("${STEPS[$i]} 부터")
    fi
  done
  ask_choice "어디서부터 할까요?" "${options[@]}"
  if [[ "${CHOICE}" -eq 1 ]]; then
    FROM_STEP="prepare"
  else
    FROM_STEP="${STEPS[$((CHOICE - 1))]}"
  fi
}

ask_image_source() {
  ask_choice "도커 이미지는 어떻게 준비됐나요?" \
    "서버에 이미 로드해 둠" \
    "AWS 다운로드"
  case "${CHOICE}" in
    1) IMAGE_SOURCE="loaded" ;;
    2) IMAGE_SOURCE="aws" ;;
  esac
}

print_plan() {
  local mode="배포 실행"
  [[ "${SIMULATION}" -eq 1 ]] && mode="미리보기"

  echo
  echo "----------------------------------------"
  echo "  모드      : ${mode}"
  echo "  병원      : ${HOSPITAL}"
  echo "  작업 경로 : ${STACK_DIR}"
  echo "  compose   : ${HOSPITAL}-v215"
  echo "  시작      : ${FROM_STEP}"
  echo "----------------------------------------"
  echo
}
