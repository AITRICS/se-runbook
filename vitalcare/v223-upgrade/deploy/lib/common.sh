#!/usr/bin/env bash

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

DEPLOY_HOME="${V223_DEPLOY_HOME:-/home/aitrics/vc-deploy-v223}"
VC_DEPLOY_REPO="${V223_REPO:-https://github.com/AITRICS/vc-deploy.git}"
EXAMPLE_DIR_NAME="upgrade-example-2.2.3"
ECR_REGISTRY="997245385850.dkr.ecr.ap-northeast-2.amazonaws.com"
CLOUDBEAVER_IMAGE="${ECR_REGISTRY}/se-tools/cloudbeaver:26.2.0-r1"
DEFAULT_SYNC_TAG="vc-v2.2.3-latest"
DEFAULT_VC_TAG="vc-v2.2.3"
TMUX_SESSION="v223-upgrade"

log_info()  { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
log_warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
log_step()  { printf "\n${CYAN}==> %s${NC}\n" "$*"; }

require_cmd() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      log_error "필요한 명령이 없습니다: ${cmd}"
      exit 1
    fi
  done
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-}"
  local hint="y/n"
  local answer

  case "${default}" in
    y|Y) hint="Y/n" ;;
    n|N) hint="y/N" ;;
  esac

  while true; do
    read -r -p "${prompt} (${hint}): " answer
    if [[ -z "${answer}" ]]; then
      answer="${default}"
    fi
    case "${answer}" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
    esac
    echo "y 또는 n 으로 답하세요."
  done
}

ask_choice() {
  local prompt="$1"
  shift
  local options=("$@")
  local i input

  echo
  echo "${prompt}"
  for i in "${!options[@]}"; do
    printf "  %s) %s\n" "$((i + 1))" "${options[$i]}"
  done

  while true; do
    read -r -p "> " input
    if [[ "${input}" =~ ^[0-9]+$ ]] && ((input >= 1 && input <= ${#options[@]})); then
      CHOICE="${input}"
      CHOICE_LABEL="${options[$((input - 1))]}"
      return 0
    fi
    echo "1~${#options[@]} 중에서 고르세요."
  done
}

prompt_value() {
  local label="$1"
  local default="${2:-}"
  local input
  if [[ -n "${default}" ]]; then
    read -r -p "${label} (${default}): " input
    printf '%s\n' "${input:-${default}}"
  else
    read -r -p "${label}: " input
    printf '%s\n' "${input}"
  fi
}

prompt_required() {
  local label="$1"
  local default="${2:-}"
  local value
  while true; do
    value="$(prompt_value "${label}" "${default}")"
    if [[ -n "${value}" ]]; then
      printf '%s\n' "${value}"
      return 0
    fi
    echo "값을 입력하세요." >&2
  done
}

prompt_secret() {
  local label="$1"
  local first second
  while true; do
    read -r -s -p "${label}: " first
    printf '\n' >&2
    if [[ -z "${first}" ]]; then
      echo "값을 입력하세요." >&2
      continue
    fi
    read -r -s -p "${label} 확인: " second
    printf '\n' >&2
    if [[ "${first}" == "${second}" ]]; then
      printf '%s\n' "${first}"
      return 0
    fi
    echo "두 입력이 다릅니다. 다시 입력하세요." >&2
  done
}

normalize_hospital() {
  printf '%s\n' "$1"
}

validate_hospital() {
  local name="$1"
  if [[ "${name}" =~ [A-Z] ]]; then
    log_error "병원 폴더 이름에 영문 대문자는 쓸 수 없습니다: ${name}"
    exit 1
  fi
}

get_kv() {
  local file="$1"
  local key="$2"
  local line
  [[ -f "${file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == "${key}="* ]] || continue
    printf '%s\n' "${line#"${key}"=}"
    return 0
  done < "${file}"
}

set_kv() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp line found=0
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" == "${key}="* || "${line}" == "#${key}="* ]]; then
      printf '%s=%s\n' "${key}" "${value}"
      found=1
    else
      printf '%s\n' "${line}"
    fi
  done < "${file}" > "${tmp}"
  if [[ "${found}" -eq 0 ]]; then
    printf '%s=%s\n' "${key}" "${value}" >> "${tmp}"
  fi
  mv "${tmp}" "${file}"
}

comment_kv() {
  local file="$1"
  local key="$2"
  local tmp line
  [[ -f "${file}" ]] || return 0
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" == "${key}="* ]]; then
      printf '#%s\n' "${line}"
    else
      printf '%s\n' "${line}"
    fi
  done < "${file}" > "${tmp}"
  mv "${tmp}" "${file}"
}

mask_len() {
  local value="$1"
  printf '입력됨 (%s자)\n' "${#value}"
}

ensure_tmux() {
  [[ -n "${V223_IN_TMUX:-}" ]] && return 0

  require_cmd tmux

  if [[ -n "${TMUX:-}" ]]; then
    log_warn "이미 tmux 안에 있습니다. 이 세션은 스크립트가 끝나도 끄지 않습니다."
    export V223_IN_TMUX=1
    return 0
  fi

  if tmux has-session -t "${TMUX_SESSION}" 2>/dev/null; then
    log_warn "이미 ${TMUX_SESSION} 세션이 있습니다. 그 세션으로 붙습니다."
    exec tmux attach -t "${TMUX_SESSION}"
  fi

  local arg quoted=""
  for arg in "$@"; do
    quoted+=" $(printf '%q' "${arg}")"
  done

  exec tmux new-session -s "${TMUX_SESSION}" \
    "V223_IN_TMUX=1 V223_OWN_TMUX=1 $(printf '%q' "$0")${quoted}"
}

finish_tmux() {
  if [[ "${V223_OWN_TMUX:-}" == "1" ]]; then
    echo
    log_info "작업이 끝났습니다. Enter 를 누르면 tmux 세션(${TMUX_SESSION})을 종료합니다."
    read -r _
  fi
}
