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
SSH_STORAGE_TYPE=${SSH_STORAGE_TYPE:-auto}
SSH_HOSTPATH_PATH=${SSH_HOSTPATH_PATH:-}
SSH_CONFIGMAP_NAME=${SSH_CONFIGMAP_NAME:-ssh-bastion-config}
SSH_AUTHORIZED_SECRET=${SSH_AUTHORIZED_SECRET:-ssh-authorized-keys}
SSH_BASTION_IMAGE=${SSH_BASTION_IMAGE:-codex-ssh-bastion:latest}
SSH_IMAGE_REGISTRY=${SSH_IMAGE_REGISTRY:-}
SSH_MOTD_CONTENT=${SSH_MOTD_CONTENT:-"Codex SSH bastion\nИспользуйте codex-hostctl list, чтобы увидеть найденные цели."}
SSH_NODE_NAME=${SSH_NODE_NAME:-}
SSH_GENERATE_WORKSPACE_KEY=${SSH_GENERATE_WORKSPACE_KEY:-auto}
SSH_WORKSPACE_KEY_TYPE=${SSH_WORKSPACE_KEY_TYPE:-ed25519}
SSH_WORKSPACE_KEY_COMMENT=${SSH_WORKSPACE_KEY_COMMENT:-codex@workspace}

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

case "${SSH_STORAGE_TYPE}" in
  auto)
    if [[ -n "${SSH_HOSTPATH_PATH}" ]]; then
      EFFECTIVE_STORAGE_TYPE=hostpath
    else
      EFFECTIVE_STORAGE_TYPE=pvc
    fi
    ;;
  pvc|hostpath)
    EFFECTIVE_STORAGE_TYPE="${SSH_STORAGE_TYPE}"
    ;;
  *)
    echo "SSH_STORAGE_TYPE must be one of: auto, pvc, hostpath" >&2
    exit 1
    ;;
esac

case "${EFFECTIVE_STORAGE_TYPE}" in
  pvc)
    SSH_DATA_VOLUME_BLOCK=$'        - name: bastion-data\n          persistentVolumeClaim:\n            claimName: '"${SSH_PVC_NAME}"
    ;;
  hostpath)
    if [[ -z "${SSH_HOSTPATH_PATH}" ]]; then
      echo "SSH_HOSTPATH_PATH must be set when using hostPath storage" >&2
      exit 1
    fi
    SSH_DATA_VOLUME_BLOCK=$'        - name: bastion-data\n          hostPath:\n            path: '"${SSH_HOSTPATH_PATH}"$'\n            type: DirectoryOrCreate'
    ;;
esac

printf 'Using %s storage for bastion data\n' "${EFFECTIVE_STORAGE_TYPE}"

if [[ -n "${SSH_NODE_NAME}" ]]; then
  SSH_NODE_PLACEMENT_BLOCK=$'      nodeName: '"${SSH_NODE_NAME}"
else
  SSH_NODE_PLACEMENT_BLOCK=""
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
  SSH_BASTION_IMAGE_REF SSH_MOTD_CONTENT_BLOCK SSH_DATA_VOLUME_BLOCK \
  SSH_NODE_PLACEMENT_BLOCK EFFECTIVE_STORAGE_TYPE

case "${SSH_GENERATE_WORKSPACE_KEY}" in
  true|false|auto)
    ;;
  *)
    echo "SSH_GENERATE_WORKSPACE_KEY must be one of: auto, true, false" >&2
    exit 1
    ;;
esac

render() {
  local source="$1"
  local target="$2"
  envsubst <"${source}" >"${target}"
}

render "${MANIFEST_DIR}/namespace.yaml" "${TMP_DIR}/namespace.yaml"
if [[ "${EFFECTIVE_STORAGE_TYPE}" == "pvc" ]]; then
  render "${MANIFEST_DIR}/pvc.yaml" "${TMP_DIR}/pvc.yaml"
fi
render "${MANIFEST_DIR}/configmap.yaml" "${TMP_DIR}/configmap.yaml"
render "${MANIFEST_DIR}/deployment.yaml" "${TMP_DIR}/deployment.yaml"
render "${MANIFEST_DIR}/service.yaml" "${TMP_DIR}/service.yaml"

printf 'Applying manifests to namespace %s\n' "${SSH_NAMESPACE}"
kubectl apply -f "${TMP_DIR}/namespace.yaml"

SECRET_EXISTS=false
if kubectl -n "${SSH_NAMESPACE}" get secret "${SSH_AUTHORIZED_SECRET}" >/dev/null 2>&1; then
  SECRET_EXISTS=true
fi

GENERATE_WORKSPACE_KEY=false
if [[ -n "${SSH_AUTHORIZED_KEYS_FILE:-}" ]]; then
  :
elif [[ "${SSH_GENERATE_WORKSPACE_KEY}" == "true" ]]; then
  GENERATE_WORKSPACE_KEY=true
elif [[ "${SSH_GENERATE_WORKSPACE_KEY}" == "auto" && "${SECRET_EXISTS}" == false ]]; then
  GENERATE_WORKSPACE_KEY=true
fi

WORKSPACE_PRIVATE_KEY_PATH=""
if [[ "${GENERATE_WORKSPACE_KEY}" == true ]]; then
  command -v ssh-keygen >/dev/null 2>&1 || {
    echo "ssh-keygen is required when SSH_GENERATE_WORKSPACE_KEY is enabled" >&2
    exit 1
  }
  WORKSPACE_KEY_BASE="${TMP_DIR}/codex-workspace-key"
  ssh-keygen -t "${SSH_WORKSPACE_KEY_TYPE}" -N "" -C "${SSH_WORKSPACE_KEY_COMMENT}" \
    -f "${WORKSPACE_KEY_BASE}" >/dev/null
  SSH_AUTHORIZED_KEYS_FILE="${WORKSPACE_KEY_BASE}.pub"
  WORKSPACE_PRIVATE_KEY_PATH="${WORKSPACE_KEY_BASE}"
  printf 'Generated new workspace key pair (%s)\n' "${SSH_WORKSPACE_KEY_TYPE}"
fi

if [[ -n "${SSH_AUTHORIZED_KEYS_FILE:-}" ]]; then
  printf 'Updating authorized_keys secret %s\n' "${SSH_AUTHORIZED_SECRET}"
  kubectl -n "${SSH_NAMESPACE}" create secret generic "${SSH_AUTHORIZED_SECRET}" \
    --from-file=authorized_keys="${SSH_AUTHORIZED_KEYS_FILE}" \
    --dry-run=client -o yaml | kubectl apply -f -
  SECRET_EXISTS=true
elif [[ "${SECRET_EXISTS}" == false ]]; then
  echo "Secret ${SSH_AUTHORIZED_SECRET} does not exist and no key material was provided" >&2
  exit 1
fi

if [[ "${EFFECTIVE_STORAGE_TYPE}" == "pvc" ]]; then
  kubectl apply -f "${TMP_DIR}/pvc.yaml"
fi
kubectl apply -f "${TMP_DIR}/configmap.yaml"
kubectl apply -f "${TMP_DIR}/deployment.yaml"
kubectl apply -f "${TMP_DIR}/service.yaml"

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

if [[ -n "${WORKSPACE_PRIVATE_KEY_PATH}" ]]; then
  printf '\nСохраните приватный ключ для Codex Workspace (секрет SSH_KEY):\n\n'
  cat "${WORKSPACE_PRIVATE_KEY_PATH}"
  printf '\n'
fi
