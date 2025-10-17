#!/usr/bin/env bash
set -euo pipefail

command -v kubectl >/dev/null 2>&1 || {
  echo "kubectl is required" >&2
  exit 1
}
command -v envsubst >/dev/null 2>&1 || {
  echo "envsubst is required (part of gettext)" >&2
  exit 1
}

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MANIFEST_DIR="${ROOT_DIR}/manifests/ssh-bastion"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

SSH_NAMESPACE=${SSH_NAMESPACE:-codex-ssh}
SSH_DEPLOYMENT_NAME=${SSH_DEPLOYMENT_NAME:-ssh-bastion}
SSH_SERVICE_NAME=${SSH_SERVICE_NAME:-ssh-bastion}
SSH_SERVICE_TYPE=${SSH_SERVICE_TYPE:-NodePort}
SSH_SERVICE_NODE_PORT=${SSH_SERVICE_NODE_PORT:-32222}
SSH_PVC_NAME=${SSH_PVC_NAME:-codex-ssh-data}
SSH_PVC_SIZE=${SSH_PVC_SIZE:-1Gi}
SSH_STORAGE_CLASS=${SSH_STORAGE_CLASS:-}
SSH_CONFIGMAP_NAME=${SSH_CONFIGMAP_NAME:-ssh-bastion-config}
SSH_AUTHORIZED_SECRET=${SSH_AUTHORIZED_SECRET:-ssh-authorized-keys}
SSH_BASTION_IMAGE=${SSH_BASTION_IMAGE:-codex-ssh-bastion:latest}
SSH_IMAGE_REGISTRY=${SSH_IMAGE_REGISTRY:-}
SSH_MOTD_CONTENT=${SSH_MOTD_CONTENT:-"Codex SSH bastion\nИспользуйте codex-hostctl list, чтобы увидеть найденные цели."}

if [[ -n "${SSH_IMAGE_REGISTRY}" ]]; then
  SSH_BASTION_IMAGE_REF="${SSH_IMAGE_REGISTRY%/}/${SSH_BASTION_IMAGE}"
else
  SSH_BASTION_IMAGE_REF="${SSH_BASTION_IMAGE}"
fi

if [[ "${SSH_SERVICE_TYPE}" == "NodePort" && -n "${SSH_SERVICE_NODE_PORT}" ]]; then
  SSH_SERVICE_NODE_PORT_LINE=$'      nodePort: '"${SSH_SERVICE_NODE_PORT}"
else
  SSH_SERVICE_NODE_PORT_LINE=""
fi

if [[ -n "${SSH_STORAGE_CLASS}" ]]; then
  SSH_STORAGE_CLASS_BLOCK=$'  storageClassName: '"${SSH_STORAGE_CLASS}"
else
  SSH_STORAGE_CLASS_BLOCK=""
fi

if [[ -n "${SSH_MOTD_CONTENT}" ]]; then
  MOTD_BLOCK=""
  while IFS= read -r line; do
    MOTD_BLOCK+=$'    '"${line}"$'\n'
  done <<<"${SSH_MOTD_CONTENT}"
  SSH_MOTD_CONTENT_BLOCK=${MOTD_BLOCK%$'\n'}
else
  SSH_MOTD_CONTENT_BLOCK='    Codex SSH bastion'
fi

export SSH_NAMESPACE SSH_DEPLOYMENT_NAME SSH_SERVICE_NAME SSH_SERVICE_TYPE \
  SSH_SERVICE_NODE_PORT SSH_SERVICE_NODE_PORT_LINE SSH_PVC_NAME SSH_PVC_SIZE \
  SSH_STORAGE_CLASS_BLOCK SSH_CONFIGMAP_NAME SSH_AUTHORIZED_SECRET \
  SSH_BASTION_IMAGE_REF SSH_MOTD_CONTENT_BLOCK

render() {
  local source="$1"
  local target="$2"
  envsubst <"${source}" >"${target}"
}

render "${MANIFEST_DIR}/namespace.yaml" "${TMP_DIR}/namespace.yaml"
render "${MANIFEST_DIR}/pvc.yaml" "${TMP_DIR}/pvc.yaml"
render "${MANIFEST_DIR}/configmap.yaml" "${TMP_DIR}/configmap.yaml"
render "${MANIFEST_DIR}/deployment.yaml" "${TMP_DIR}/deployment.yaml"
render "${MANIFEST_DIR}/service.yaml" "${TMP_DIR}/service.yaml"

printf 'Applying manifests to namespace %s\n' "${SSH_NAMESPACE}"
kubectl apply -f "${TMP_DIR}/namespace.yaml"
kubectl apply -f "${TMP_DIR}/pvc.yaml"
kubectl apply -f "${TMP_DIR}/configmap.yaml"
kubectl apply -f "${TMP_DIR}/deployment.yaml"
kubectl apply -f "${TMP_DIR}/service.yaml"

if [[ -n "${SSH_AUTHORIZED_KEYS_FILE:-}" ]]; then
  printf 'Updating authorized_keys secret %s\n' "${SSH_AUTHORIZED_SECRET}"
  kubectl -n "${SSH_NAMESPACE}" create secret generic "${SSH_AUTHORIZED_SECRET}" \
    --from-file=authorized_keys="${SSH_AUTHORIZED_KEYS_FILE}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

cat <<INFO
---
Deployment applied.

Проверить rollout:
  kubectl -n ${SSH_NAMESPACE} rollout status deployment/${SSH_DEPLOYMENT_NAME}

Проверить сервис:
  kubectl -n ${SSH_NAMESPACE} get svc ${SSH_SERVICE_NAME} -o wide

Тестовое подключение:
  ssh -p ${SSH_SERVICE_NODE_PORT} codex@<node-ip>
или c ProxyJump:
  ssh -J codex@<node-ip>:${SSH_SERVICE_NODE_PORT} target-host

Обновить authorized_keys:
  kubectl -n ${SSH_NAMESPACE} create secret generic ${SSH_AUTHORIZED_SECRET} \
    --from-file=authorized_keys=<path> --dry-run=client -o yaml | kubectl apply -f -

Экспорт инвентаря из пода:
  kubectl -n ${SSH_NAMESPACE} exec deploy/${SSH_DEPLOYMENT_NAME} -- codex-hostctl export
---
INFO
