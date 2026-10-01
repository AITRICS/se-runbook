#!/usr/bin/env bash
# VitalCare 2.2.3 업그레이드 사전점검. Ubuntu 22.04 / 24.04.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/images.sh
source "${SCRIPT_DIR}/lib/images.sh"

PASSES=()
WARNS=()
FAILS=()

usage() {
  cat <<EOF
사용: ./pre.sh

VitalCare 2.2.3 업그레이드 전에 서버 상태를 확인한다.
시작 시 시뮬레이션을 보여 주고, 확인한 뒤에 실제 점검을 한다.

점검 항목
  - CPU / RAM / Disk
  - 실행 중인 docker compose 프로젝트
  - 외부망 가능 여부에 따라
      가능: ECR 로그인, ECR 통신, git clone
      불가: 2.2.3 이미지 로드, ${DEPLOY_HOME}, NTP
EOF
}

record_pass() { PASSES+=("$1"); log_info "PASS  $1"; }
record_warn() { WARNS+=("$1"); log_warn "WARN  $1"; }
record_fail() { FAILS+=("$1"); log_error "FAIL  $1"; }

show_simulation() {
  cat <<EOF

${BOLD}VitalCare 2.2.3 업그레이드 사전점검 시뮬레이션${NC}
처음 보는 사람을 위한 예행연습이다. 지금은 아무것도 실행하지 않는다.

1. CPU 코어, 1초 사용률, load average 를 보여 준다.
2. RAM 총량 / 사용 / available 을 보여 준다.
3. 마운트별 디스크 사용률을 보여 준다. 85% 이상이면 WARN.
4. \`docker compose ls\` 로 지금 떠 있는 compose 프로젝트만 보여 준다.
5. 외부망을 쓸 수 있는지 묻는다.

   가능하다고 하면
     - ~/.docker/config.json 에 ${ECR_REGISTRY} 로그인 기록이 있는지
     - 그 레지스트리로 HTTPS 가 닿는지 (401 도 통신 성공)
     - git ls-remote ${VC_DEPLOY_REPO} 가 되는지

   불가능하다고 하면
     - 병원 폴더 docker-compose.yaml 과 include 에 적힌 이미지가 로컬에 있는지
     - CloudBeaver 이미지 ${CLOUDBEAVER_IMAGE}
     - vc-script 이미지 ${VC_SCRIPT_IMAGE}
     - ${DEPLOY_HOME} 디렉터리가 있는지
     - timedatectl 기준으로 NTP 가 켜져 있는지

6. 마지막에 PASS / WARN / FAIL 요약을 찍고, FAIL 이 있으면 종료 코드 1.

실제 배포는 ./run.sh 이다. 이 스크립트는 서버를 변경하지 않는다.

EOF
}

cpu_usage_percent() {
  local user1 nice1 system1 idle1 iowait1 irq1 soft1 steal1
  local user2 nice2 system2 idle2 iowait2 irq2 soft2 steal2
  local total1 idle_all1 total2 idle_all2 dtotal didle
  read -r _ user1 nice1 system1 idle1 iowait1 irq1 soft1 steal1 _ < /proc/stat
  sleep 1
  read -r _ user2 nice2 system2 idle2 iowait2 irq2 soft2 steal2 _ < /proc/stat
  total1=$((user1 + nice1 + system1 + idle1 + iowait1 + irq1 + soft1 + steal1))
  idle_all1=$((idle1 + iowait1))
  total2=$((user2 + nice2 + system2 + idle2 + iowait2 + irq2 + soft2 + steal2))
  idle_all2=$((idle2 + iowait2))
  dtotal=$((total2 - total1))
  didle=$((idle_all2 - idle_all1))
  if [[ "${dtotal}" -le 0 ]]; then
    echo "n/a"
    return 0
  fi
  echo $(( (dtotal - didle) * 100 / dtotal ))
}

check_resources() {
  local cores load usage mem_total mem_used mem_avail mem_pct
  local line usepct mount

  log_step "CPU / RAM / Disk"

  cores="$(nproc)"
  load="$(cut -d' ' -f1-3 /proc/loadavg)"
  usage="$(cpu_usage_percent)"
  echo "CPU   cores=${cores}  usage=${usage}%  load=${load}"
  record_pass "CPU 확인 (cores=${cores}, usage=${usage}%, load=${load})"

  mem_total="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
  mem_avail="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"
  mem_used=$((mem_total - mem_avail))
  mem_pct=$((mem_used * 100 / mem_total))
  echo "RAM   $(free -h | awk '/^Mem:/ {print "total="$2, "used="$3, "available="$7}')  used=${mem_pct}%"
  if [[ "${mem_pct}" -ge 90 ]]; then
    record_warn "RAM 사용률 ${mem_pct}%"
  else
    record_pass "RAM 확인 (used=${mem_pct}%)"
  fi

  echo
  df -hP -x tmpfs -x devtmpfs -x squashfs
  echo
  while read -r line; do
    [[ "${line}" == Filesystem* ]] && continue
    usepct="$(awk '{print $5}' <<<"${line}" | tr -d '%')"
    mount="$(awk '{print $6}' <<<"${line}")"
    [[ "${usepct}" =~ ^[0-9]+$ ]] || continue
    if [[ "${usepct}" -ge 85 ]]; then
      record_warn "디스크 ${mount} 사용률 ${usepct}%"
    fi
  done < <(df -P -x tmpfs -x devtmpfs -x squashfs)
  record_pass "디스크 목록 확인"

  if [[ ! -d /aitrics-vc ]]; then
    record_warn "/aitrics-vc 가 없습니다. VOLUME_DIR 기본값은 /aitrics-vc/v2.2.3 입니다."
  fi
}

check_compose_projects() {
  log_step "실행 중인 docker compose 프로젝트"
  if ! docker info >/dev/null 2>&1; then
    record_fail "docker 데몬에 접속하지 못했습니다. 권한 또는 서비스 상태를 확인하세요."
    return 0
  fi
  echo
  docker compose ls
  echo
  record_pass "docker compose 프로젝트 목록 표시"
}

check_ecr_login() {
  local config="${HOME}/.docker/config.json"
  log_step "ECR 로그인"
  if [[ -f "${config}" ]] && grep -q "${ECR_REGISTRY}" "${config}"; then
    record_pass "docker 설정에 ${ECR_REGISTRY} 로그인 기록이 있습니다."
  else
    record_fail "ECR 로그인 기록이 없습니다. aws ecr get-login-password | docker login --username AWS --password-stdin ${ECR_REGISTRY}"
  fi
}

check_ecr_reachability() {
  local code
  log_step "ECR 통신"
  if ! command -v curl >/dev/null 2>&1; then
    record_fail "curl 이 없어 ECR 통신을 확인하지 못했습니다."
    return 0
  fi
  code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 \
    "https://${ECR_REGISTRY}/v2/" || true)"
  case "${code}" in
    200|401|403)
      record_pass "ECR 통신 가능 (HTTP ${code})"
      ;;
    000|"")
      record_fail "ECR(${ECR_REGISTRY})에 연결하지 못했습니다."
      ;;
    *)
      record_warn "ECR 응답이 예상과 다릅니다 (HTTP ${code}). 연결은 됐습니다."
      ;;
  esac
}

check_git_clone() {
  local err
  log_step "git clone 가능 여부"
  require_cmd git
  err="$(mktemp)"
  if GIT_TERMINAL_PROMPT=0 timeout 20 git ls-remote "${VC_DEPLOY_REPO}" HEAD >/dev/null 2>"${err}"; then
    record_pass "git ls-remote ${VC_DEPLOY_REPO}"
  else
    record_fail "git clone 에 쓸 원격 저장소에 접근하지 못했습니다: ${VC_DEPLOY_REPO}"
    sed 's/^/    /' "${err}" >&2 || true
  fi
  rm -f "${err}"
}

resolve_compose_file() {
  local candidates=() dir name
  COMPOSE_FILE=""
  COMPOSE_ENV_FILE=""
  COMPOSE_SOURCE=""

  if [[ -d "${DEPLOY_HOME}" ]]; then
    for dir in "${DEPLOY_HOME}"/*; do
      [[ -f "${dir}/docker-compose.yaml" ]] || continue
      candidates+=("${dir}")
    done
  fi

  if [[ "${#candidates[@]}" -eq 0 ]]; then
    COMPOSE_SOURCE="기본 2.2.3 이미지 목록"
    return 0
  fi

  echo
  echo "이미지 확인에 쓸 compose 파일을 고르세요."
  local options=()
  for dir in "${candidates[@]}"; do
    options+=("${dir}/docker-compose.yaml")
  done
  options+=("병원 폴더가 없다. 기본 2.2.3 목록으로 확인")
  ask_choice "어느 파일로 볼까요?" "${options[@]}"
  if [[ "${CHOICE}" -gt "${#candidates[@]}" ]]; then
    COMPOSE_SOURCE="기본 2.2.3 이미지 목록"
    return 0
  fi
  dir="${candidates[$((CHOICE - 1))]}"
  COMPOSE_FILE="${dir}/docker-compose.yaml"
  COMPOSE_ENV_FILE="${dir}/.env"
  name="$(basename "${dir}")"
  COMPOSE_SOURCE="${name}/docker-compose.yaml"
}

check_loaded_images() {
  local image source images=()
  log_step "2.2.3 도커 이미지 로드"
  if ! docker info >/dev/null 2>&1; then
    record_fail "docker 데몬에 접속하지 못해 이미지를 확인하지 못했습니다."
    return 0
  fi

  resolve_compose_file
  if [[ -n "${COMPOSE_FILE}" ]]; then
    if load_compose_images "${COMPOSE_FILE}" "${COMPOSE_ENV_FILE}"; then
      images=("${COMPOSE_IMAGES[@]}")
      source="${COMPOSE_SOURCE}"
    else
      record_warn "${COMPOSE_FILE} 에서 image 를 읽지 못했습니다. 기본 목록을 사용합니다."
      source="기본 2.2.3 이미지 목록"
    fi
  else
    source="${COMPOSE_SOURCE}"
    record_warn "병원 compose 파일이 없어 기본 2.2.3 이미지 목록으로 확인합니다."
  fi

  if [[ "${#images[@]}" -eq 0 ]]; then
    while IFS= read -r image; do
      [[ -n "${image}" ]] && images+=("${image}")
    done < <(fallback_compose_images)
  fi

  echo "기준: ${source}"
  local uniq
  uniq="$(printf '%s\n' "${images[@]}" | awk 'NF && !seen[$0]++')"
  while IFS= read -r image; do
    if image_loaded "${image}"; then
      record_pass "image  ${image}"
    else
      record_fail "image 없음  ${image}"
    fi
  done <<<"${uniq}"

  echo
  echo "CloudBeaver"
  if image_loaded "${CLOUDBEAVER_IMAGE}"; then
    record_pass "image  ${CLOUDBEAVER_IMAGE}"
  else
    record_fail "image 없음  ${CLOUDBEAVER_IMAGE}"
  fi

  echo
  echo "vc-script"
  if image_loaded "${VC_SCRIPT_IMAGE}"; then
    record_pass "image  ${VC_SCRIPT_IMAGE}"
  else
    record_fail "image 없음  ${VC_SCRIPT_IMAGE}"
  fi
}

check_deploy_home() {
  log_step "vc-deploy 디렉터리"
  if [[ -d "${DEPLOY_HOME}" ]]; then
    record_pass "디렉터리 있음  ${DEPLOY_HOME}"
    if [[ ! -f "${DEPLOY_HOME}/${EXAMPLE_DIR_NAME}/docker-compose.yaml" ]]; then
      record_warn "${DEPLOY_HOME}/${EXAMPLE_DIR_NAME}/docker-compose.yaml 이 없습니다. 저장소 전체가 복사됐는지 확인하세요."
    fi
  else
    record_fail "디렉터리가 없습니다: ${DEPLOY_HOME}"
  fi
}

check_ntp() {
  local ntp synced
  log_step "NTP"
  if ! command -v timedatectl >/dev/null 2>&1; then
    record_fail "timedatectl 이 없어 NTP 를 확인하지 못했습니다."
    return 0
  fi
  timedatectl status || true
  ntp="$(timedatectl show -p NTP --value 2>/dev/null || true)"
  synced="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  if [[ "${ntp}" == "yes" ]]; then
    record_pass "NTP 사용 중"
  else
    record_fail "NTP 가 꺼져 있습니다. timedatectl set-ntp true 또는 chrony 설정을 확인하세요."
  fi
  if [[ "${synced}" == "yes" ]]; then
    record_pass "NTP 동기화됨"
  else
    record_warn "아직 NTP 동기화 시각이 아닙니다 (NTPSynchronized=${synced:-unknown})."
  fi
}

print_summary() {
  local item
  echo
  echo "----------------------------------------"
  echo " 사전점검 요약"
  echo "  PASS ${#PASSES[@]}   WARN ${#WARNS[@]}   FAIL ${#FAILS[@]}"
  echo "----------------------------------------"
  if [[ "${#WARNS[@]}" -gt 0 ]]; then
    echo "WARN"
    for item in "${WARNS[@]}"; do
      echo "  - ${item}"
    done
  fi
  if [[ "${#FAILS[@]}" -gt 0 ]]; then
    echo "FAIL"
    for item in "${FAILS[@]}"; do
      echo "  - ${item}"
    done
    echo
    log_error "실패한 항목이 있습니다. 해결한 뒤 ./pre.sh 를 다시 실행하세요."
    exit 1
  fi
  echo
  log_info "사전점검이 끝났습니다. 다음 단계는 ./run.sh 입니다."
}

main() {
  case "${1:-}" in
    -h|--help)
      usage
      exit 0
      ;;
    "")
      ;;
    *)
      log_error "모르는 인자: $1"
      usage
      exit 1
      ;;
  esac

  require_cmd awk
  show_simulation
  if ! ask_yes_no "시뮬레이션을 확인했습니다. 사전점검을 시작할까요?" "y"; then
    log_info "종료합니다. 점검은 실행하지 않았습니다."
    exit 0
  fi

  check_resources
  check_compose_projects

  echo
  if ask_yes_no "이 서버에서 외부망을 쓸 수 있나요?"; then
    check_ecr_login
    check_ecr_reachability
    check_git_clone
  else
    check_loaded_images
    check_deploy_home
    check_ntp
  fi

  print_summary
}

main "$@"
