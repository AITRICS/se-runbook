#!/usr/bin/env bash

fallback_compose_images() {
  cat <<EOF
${ECR_REGISTRY}/prod/rabbitmq:4.1.5-management-alpine-ec2f8af
${ECR_REGISTRY}/prod/backend:${DEFAULT_VC_TAG}
${ECR_REGISTRY}/prod/vc-frontend:${DEFAULT_VC_TAG}
${ECR_REGISTRY}/prod/vc-frontend-admin:${DEFAULT_VC_TAG}
${ECR_REGISTRY}/prod/screening-service:${DEFAULT_VC_TAG}
${ECR_REGISTRY}/prod/dlq-manager:${DEFAULT_VC_TAG}
${ECR_REGISTRY}/prod/vcsm-kotlin:${DEFAULT_VC_TAG}
${ECR_REGISTRY}/prod/scoring-service:${DEFAULT_VC_TAG}
${ECR_REGISTRY}/prod/mongo:8.0.5-9170fe7@sha256:ae850b5babc98702bf35cb3913d21ff33274bd1933ba4a6a51314dcb4459f464
${ECR_REGISTRY}/prod/mysql:8.4.7-oraclelinux9-5dd443f
nginx:1.31.0
${ECR_REGISTRY}/prod/vc-sync-adapter:${DEFAULT_SYNC_TAG}
EOF
}

substitute_image_vars() {
  local image="$1"
  local env_file="$2"
  local vc_tag sync_tag
  vc_tag="$(get_kv "${env_file}" "VC_IMAGE_TAG")"
  sync_tag="$(get_kv "${env_file}" "VC_SYNC_IMAGE_TAG")"
  vc_tag="${vc_tag:-${DEFAULT_VC_TAG}}"
  sync_tag="${sync_tag:-${DEFAULT_SYNC_TAG}}"
  image="${image//\$\{VC_IMAGE_TAG\}/${vc_tag}}"
  image="${image//\$\{VC_SYNC_IMAGE_TAG\}/${sync_tag}}"
  printf '%s\n' "${image}"
}

collect_images_from_file() {
  local file="$1"
  local env_file="$2"
  local dir line inc image
  dir="$(cd "$(dirname "${file}")" && pwd)"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    if [[ "${line}" =~ ^[[:space:]]*-[[:space:]]*(\.\./[^[:space:]]+\.yaml) ]]; then
      inc="${dir}/${BASH_REMATCH[1]}"
      if [[ -f "${inc}" ]]; then
        collect_images_from_file "${inc}" "${env_file}"
      fi
      continue
    fi
    if [[ "${line}" =~ ^[[:space:]]*image:[[:space:]]*([^[:space:]#]+) ]]; then
      image="$(substitute_image_vars "${BASH_REMATCH[1]}" "${env_file}")"
      COMPOSE_IMAGES+=("${image}")
    fi
  done < "${file}"
}

load_compose_images() {
  local compose_file="$1"
  local env_file="$2"
  COMPOSE_IMAGES=()
  if [[ -n "${compose_file}" && -f "${compose_file}" ]]; then
    collect_images_from_file "${compose_file}" "${env_file}"
  fi
  if [[ "${#COMPOSE_IMAGES[@]}" -eq 0 ]]; then
    return 1
  fi
  return 0
}

image_loaded() {
  local ref="$1"
  local base
  if docker image inspect "${ref}" >/dev/null 2>&1; then
    return 0
  fi
  if [[ "${ref}" == *"@sha256:"* ]]; then
    base="${ref%%@sha256:*}"
    if docker image inspect "${base}" >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

latest_vc_script_image() {
  local id created ref best_created="" best_ref=""
  local ids
  ids="$(docker images -q --filter reference='*vc-script*' 2>/dev/null | sort -u)"
  [[ -n "${ids}" ]] || return 1

  for id in ${ids}; do
    created="$(docker inspect -f '{{.Created}}' "${id}" 2>/dev/null || true)"
    ref="$(docker inspect -f '{{if .RepoTags}}{{index .RepoTags 0}}{{else}}{{index .RepoDigests 0}}{{end}}' "${id}" 2>/dev/null || true)"
    [[ -n "${ref}" && "${ref}" != "[]" ]] || continue
    if [[ -z "${best_created}" || "${created}" > "${best_created}" ]]; then
      best_created="${created}"
      best_ref="${ref}"
    fi
  done

  [[ -n "${best_ref}" ]] || return 1
  printf '%s\n' "${best_ref}"
}
