#!/usr/bin/env bash

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "\n${CYAN}==> $*${NC}"; }

is_sim() { [[ "${SIMULATION:-0}" -eq 1 ]]; }

confirm() {
  local message="${1:-계속 진행할까요?}"
  local answer
  read -r -p "${message} (y/n): " answer
  [[ "${answer}" == "y" || "${answer}" == "Y" ]]
}

prompt_value() {
  local label="$1"
  local current="${2:-}"
  local input
  if [[ -n "${current}" ]]; then
    read -r -p "${label} [${current}]: " input
    echo "${input:-${current}}"
  else
    read -r -p "${label}: " input
    echo "${input}"
  fi
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      log_error "필요한 명령어가 없습니다: ${cmd}"
      exit 1
    fi
  done
}

normalize_hospital() {
  local name="$1"
  echo "${name}" | tr '[:upper:]' '[:lower:]' | tr -d ' '
}

validate_hospital() {
  local name="$1"
  if [[ ! "${name}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    log_error "병원 이름은 영문 소문자/숫자/하이픈만 가능합니다: ${name}"
    exit 1
  fi
}

iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

require_nonempty() {
  local key="$1"
  local value="$2"
  if [[ -z "${value}" ]]; then
    log_error "${key} 값이 비어 있습니다. 설정 파일이나 입력을 확인하세요."
    exit 1
  fi
}
