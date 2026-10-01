#!/usr/bin/env bash

get_env_value() {
  local file="$1"
  local key="$2"
  [[ -f "${file}" ]] || return 0
  grep -E "^${key}=" "${file}" | tail -n 1 | cut -d'=' -f2- | tr -d '"' | tr -d "'"
}

set_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp

  if is_sim; then
    return 0
  fi

  [[ -f "${file}" ]] || touch "${file}"
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

load_config_file() {
  local file="$1"
  local line key value

  [[ -f "${file}" ]] || {
    log_error "config 파일이 없습니다: ${file}"
    exit 1
  }

  log_info "config 로드: ${file}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    key="${key#"${key%%[![:space:]]*}"}"
    [[ -z "${key}" ]] && continue
    printf -v "${key}" '%s' "${value}"
    export "${key}"
  done < "${file}"
}

setup_env_files() {
  local stack_dir="$1"
  local hospital="$2"
  local env_file="${stack_dir}/.env"
  local db_file="${stack_dir}/db-encrypt.env"
  local sync_file="${stack_dir}/sync.env"

  if [[ ! -f "${env_file}" || ! -f "${db_file}" || ! -f "${sync_file}" ]]; then
    if is_sim; then
      env_file="${CARED_HOME}/${EXAMPLE_DIR}/.env"
      db_file="${CARED_HOME}/${EXAMPLE_DIR}/db-encrypt.env"
      sync_file="${CARED_HOME}/${EXAMPLE_DIR}/sync.env"
    else
      log_error "env 파일이 없습니다. pre 에서 .env / db-encrypt.env / sync.env 를 완료하세요."
      exit 1
    fi
  fi

  set_env_value "${env_file}" "CONFIG_DIR" "../${hospital}-v215/configs"
  set_env_value "${env_file}" "HOST_NAME" "${hospital}"
  if [[ -n "${SYNC_IMAGE_TAG:-}" ]]; then
    set_env_value "${env_file}" "SYNC_IMAGE_TAG" "${SYNC_IMAGE_TAG}"
  fi
  if [[ -n "${DB_ENCRYPTION_KEY:-}" ]]; then
    set_env_value "${db_file}" "DB_ENCRYPTION_KEY" "${DB_ENCRYPTION_KEY}"
  fi
  if [[ -n "${DB_ENCRYPTION_KEY_HASH:-}" ]]; then
    set_env_value "${db_file}" "DB_ENCRYPTION_KEY_HASH" "${DB_ENCRYPTION_KEY_HASH}"
  fi
  if [[ -n "${VC_MYSQL_PASSWORD:-}" ]]; then
    set_env_value "${db_file}" "VC_MYSQL_PASSWORD" "${VC_MYSQL_PASSWORD}"
  fi
  if [[ -n "${VCSYNC_EMR_HOSPITAL:-}" ]]; then
    set_env_value "${sync_file}" "VCSYNC_EMR_HOSPITAL" "${VCSYNC_EMR_HOSPITAL}"
  fi
  if [[ -n "${VCSYNC_EMR_HOST:-}" ]]; then
    set_env_value "${sync_file}" "VCSYNC_EMR_HOST" "${VCSYNC_EMR_HOST}"
  fi
  if [[ -n "${VCSYNC_EMR_PORT:-}" ]]; then
    set_env_value "${sync_file}" "VCSYNC_EMR_PORT" "${VCSYNC_EMR_PORT}"
  fi
  if [[ -n "${VCSYNC_EMR_SERVICE:-}" ]]; then
    set_env_value "${sync_file}" "VCSYNC_EMR_SERVICE" "${VCSYNC_EMR_SERVICE}"
  fi

  VOLUME_DIR="$(get_env_value "${env_file}" "VOLUME_DIR")"
  DB_ENCRYPTION_KEY="${DB_ENCRYPTION_KEY:-$(get_env_value "${db_file}" "DB_ENCRYPTION_KEY")}"
  export VOLUME_DIR DB_ENCRYPTION_KEY
}
