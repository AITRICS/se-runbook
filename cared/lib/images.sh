#!/usr/bin/env bash

ECR_REGISTRY="${ECR_REGISTRY:-997245385850.dkr.ecr.ap-northeast-2.amazonaws.com}"
ECR_HOST="${ECR_HOST:-997245385850.dkr.ecr.ap-northeast-2.amazonaws.com}"
VC_SCRIPT_IMAGE="${VC_SCRIPT_IMAGE:-997245385850.dkr.ecr.ap-northeast-2.amazonaws.com/dev/vc-script:v2.2.2}"

resolve_sync_image_tag() {
  local tag="${SYNC_IMAGE_TAG:-}"
  if [[ -z "${tag}" && -n "${STACK_DIR:-}" && -f "${STACK_DIR}/.env" ]]; then
    tag="$(get_env_value "${STACK_DIR}/.env" "SYNC_IMAGE_TAG")"
  fi
  if [[ -z "${tag}" && -n "${CARED_HOME:-}" && -f "${CARED_HOME}/${EXAMPLE_DIR}/.env" ]]; then
    tag="$(get_env_value "${CARED_HOME}/${EXAMPLE_DIR}/.env" "SYNC_IMAGE_TAG")"
  fi
  echo "${tag:-vc-v2.1.5-latest}"
}

required_images() {
  local tag
  tag="$(resolve_sync_image_tag)"
  REQUIRED_IMAGES=(
    "nginx:1.31.0"
    "${ECR_REGISTRY}/prod/mysql:8.4.7-oraclelinux9-5dd443f"
    "${ECR_REGISTRY}/prod/mongo:8.0.5-9170fe7"
    "${ECR_REGISTRY}/prod/vc-sync-adapter:${tag}"
    "${ECR_REGISTRY}/prod/vc-backend:vc-v2.1.5"
    "${ECR_REGISTRY}/prod/vc-frontend:vc-v2.1.5"
    "${ECR_REGISTRY}/prod/vc-frontend-admin:vc-v2.1.5"
    "${ECR_REGISTRY}/prod/vc-screening-service:vc-v2.1.5"
    "${ECR_REGISTRY}/prod/vc-scoring-service:vc-v2.1.5"
    "${ECR_REGISTRY}/prod/vc-scoring-manager:vc-v2.1.5"
    "${VC_SCRIPT_IMAGE}"
  )
}

image_loaded() {
  docker image inspect "$1" >/dev/null 2>&1
}

print_required_images() {
  local img
  required_images
  for img in "${REQUIRED_IMAGES[@]}"; do
    log_info "필요: ${img}"
  done
}

check_images_loaded() {
  local img missing=0

  log_step "도커 이미지 확인 (서버에 이미 로드)"
  print_required_images

  if is_sim && ! command -v docker >/dev/null 2>&1; then
    required_images
    for img in "${REQUIRED_IMAGES[@]}"; do
      log_info "있음: ${img}"
    done
    log_info "필요한 이미지 모두 로드되어 있습니다."
    return 0
  fi

  require_cmd docker

  required_images
  for img in "${REQUIRED_IMAGES[@]}"; do
    if image_loaded "${img}"; then
      log_info "있음: ${img}"
    else
      log_error "없음: ${img}"
      missing=1
    fi
  done

  if [[ "${missing}" -ne 0 ]]; then
    log_error "서버에 없는 이미지가 있습니다. 로드한 뒤 다시 실행하세요."
    return 1
  fi

  log_info "필요한 이미지 모두 로드되어 있습니다."
}

ecr_reachable() {
  local code

  if command -v curl >/dev/null 2>&1; then
    code="$(curl -sS -o /dev/null -w '%{http_code}' \
      --connect-timeout 5 --max-time 10 \
      "https://${ECR_HOST}/v2/" 2>/dev/null || true)"
    case "${code}" in
      200|401|403) return 0 ;;
      *) return 1 ;;
    esac
  fi

  if timeout 5 bash -c "echo >/dev/tcp/${ECR_HOST}/443" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

check_aws_reachability() {
  log_step "AWS 통신 확인"
  log_info "대상: ${ECR_HOST}"
  log_info "로그인/pull 은 이 스크립트가 하지 않습니다."

  if is_sim && ! command -v curl >/dev/null 2>&1; then
    log_info "AWS ECR 통신 확인"
    return 0
  fi

  if ecr_reachable; then
    log_info "AWS ECR 통신 확인"
    return 0
  fi

  log_error "AWS ECR 에 닿지 않습니다: ${ECR_HOST}"
  log_error "네트워크 / 방화벽을 확인하세요. 로그인은 이 스크립트가 하지 않습니다."
  return 1
}

step_images() {
  case "${IMAGE_SOURCE:-}" in
    loaded) check_images_loaded ;;
    aws) check_aws_reachability ;;
    *)
      log_error "이미지 준비 방식을 고르지 않았습니다."
      return 1
      ;;
  esac
}
