#!/usr/bin/env bash

VC_SCRIPT_IMAGE="${VC_SCRIPT_IMAGE:-997245385850.dkr.ecr.ap-northeast-2.amazonaws.com/dev/vc-script:v2.2.2}"

# vc-script:v2.2.2 prompt 순서 (이미지에 VC_MYSQL_USER/PASSWORD 가 박혀 있으면 user/pass 질문은 생략)
# 1. Version (214 for v2.1.5)
# 2. DB encrypt key
# 3. DB host
# 4. DB port
# 5. Prediction scores
# 6. Medical scores
# 7. Base date
# 8. Use AltICU

run_inspect() {
  local out_dir="$1"
  local log_file="${out_dir}/vc-script.log"
  local failed_file="${out_dir}/vc-script.failed"
  local version="${INSPECT_VERSION:-214}"
  local db_host="${INSPECT_DB_HOST:-127.0.0.1}"
  local db_port="${INSPECT_DB_PORT:-13306}"
  local encrypt_key="${DB_ENCRYPTION_KEY:-}"
  local prediction="${INSPECT_PREDICTION_SCORES:-MAES,SEPS,MORS,CARED}"
  local medical="${INSPECT_MEDICAL_SCORES:-NEWS,MEWS}"
  local base_date="${INSPECT_BASE_DATE:-$(date +%Y-%m-%d)}"
  local alticu="${INSPECT_USE_ALTICU:-N}"

  log_step "검수 스크립트 실행  (${VC_SCRIPT_IMAGE})"
  if ! is_sim; then
    mkdir -p "${out_dir}"
  fi

  if [[ -z "${encrypt_key}" && -f "./db-encrypt.env" ]]; then
    encrypt_key="$(get_env_value "./db-encrypt.env" "DB_ENCRYPTION_KEY")"
  fi
  if [[ -z "${encrypt_key}" && -f "${CARED_HOME}/${EXAMPLE_DIR}/db-encrypt.env" ]]; then
    encrypt_key="$(get_env_value "${CARED_HOME}/${EXAMPLE_DIR}/db-encrypt.env" "DB_ENCRYPTION_KEY")"
  fi
  if is_sim; then
    log_info "version=${version} host=${db_host}:${db_port} date=${base_date}"
    echo
    log_step "검수 전체 결과"
    echo
    log_step "FAILED 항목만"
    log_info "FAILED 항목 없음"
    return 0
  fi
  require_nonempty "DB_ENCRYPTION_KEY" "${encrypt_key}"

  log_info "version=${version} host=${db_host}:${db_port} date=${base_date}"

  if ! printf '%s\n' \
      "${version}" \
      "${encrypt_key}" \
      "${db_host}" \
      "${db_port}" \
      "${prediction}" \
      "${medical}" \
      "${base_date}" \
      "${alticu}" \
    | docker run -i --rm --pull never --name "vc-script-${HOSPITAL}" \
        --net="host" --pid="host" \
        "${VC_SCRIPT_IMAGE}" 2>&1 | tee "${log_file}"; then
    log_warn "vc-script 컨테이너 exit code가 0이 아닙니다. 로그는 그대로 표시합니다."
  fi

  echo
  log_step "검수 전체 결과"
  cat "${log_file}"

  grep -E "FAILED" "${log_file}" > "${failed_file}" || true

  echo
  log_step "FAILED 항목만"
  if [[ -s "${failed_file}" ]]; then
    echo -e "${RED}"
    cat "${failed_file}"
    echo -e "${NC}"
    log_warn "FAILED $(wc -l < "${failed_file}" | tr -d ' ')건"
    return 1
  fi

  log_info "FAILED 항목 없음"
  return 0
}
