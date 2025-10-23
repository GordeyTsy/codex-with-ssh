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
SSH_BUILD_IMAGE=${SSH_BUILD_IMAGE:-auto}
SSH_PUSH_IMAGE=${SSH_PUSH_IMAGE:-}
SSH_DOCKERFILE=${SSH_DOCKERFILE:-${ROOT_DIR}/images/ssh-bastion/Dockerfile}
SSH_BUILD_CONTEXT=${SSH_BUILD_CONTEXT:-${ROOT_DIR}/images/ssh-bastion}
SSH_PUBLIC_HOST=${SSH_PUBLIC_HOST:-}
SSH_PUBLIC_PORT=${SSH_PUBLIC_PORT:-}
SSH_PUBLIC_SCHEME=${SSH_PUBLIC_SCHEME:-https}
SSH_SERVICE_PORT=${SSH_SERVICE_PORT:-80}
SSH_TUNNEL_SECRET_NAME=${SSH_TUNNEL_SECRET_NAME:-ssh-bastion-tunnel}
SSH_TUNNEL_USER=${SSH_TUNNEL_USER:-codex}
SSH_TUNNEL_TOKEN=${SSH_TUNNEL_TOKEN:-}
SSH_HTTP_TUNNEL_PORT=${SSH_HTTP_TUNNEL_PORT:-${SSH_TUNNEL_PORT:-8080}}
SSH_MOTD_CONTENT=${SSH_MOTD_CONTENT:-$'Codex SSH bastion\nИспользуйте codex-hostctl list, чтобы увидеть найденные цели.'}
SSH_NODE_NAME=${SSH_NODE_NAME:-}
SSH_GENERATE_WORKSPACE_KEY=${SSH_GENERATE_WORKSPACE_KEY:-auto}
SSH_WORKSPACE_KEY_TYPE=${SSH_WORKSPACE_KEY_TYPE:-ed25519}
SSH_WORKSPACE_KEY_COMMENT=${SSH_WORKSPACE_KEY_COMMENT:-codex@workspace}
SSH_WORKSPACE_KEY_OUTPUT=${SSH_WORKSPACE_KEY_OUTPUT:-${ROOT_DIR}/configs/workspace-key}

if [[ -n "${SSH_IMAGE_REGISTRY}" ]]; then
  SSH_BASTION_IMAGE_REF="${SSH_IMAGE_REGISTRY%/}/${SSH_BASTION_IMAGE}"
else
  SSH_BASTION_IMAGE_REF="${SSH_BASTION_IMAGE}"
fi

if [[ -n "${SSH_PUBLIC_HOST}" && -z "${SSH_PUBLIC_PORT}" ]]; then
  SSH_PUBLIC_PORT=443
fi

case "${SSH_BUILD_IMAGE}" in
  auto|true|false)
    ;;
  *)
    echo "SSH_BUILD_IMAGE must be one of: auto, true, false" >&2
    exit 1
    ;;
esac

if [[ -z "${SSH_PUSH_IMAGE}" ]]; then
  if [[ -n "${SSH_IMAGE_REGISTRY}" ]]; then
    SSH_PUSH_IMAGE=true
  else
    SSH_PUSH_IMAGE=false
  fi
fi

case "${SSH_PUSH_IMAGE}" in
  true|false)
    ;;
  *)
    echo "SSH_PUSH_IMAGE must be one of: true, false" >&2
    exit 1
    ;;
esac

NEED_BUILD=false
case "${SSH_BUILD_IMAGE}" in
  true)
    NEED_BUILD=true
    ;;
  auto)
    NEED_BUILD=true
    ;;
esac

if [[ "${NEED_BUILD}" == true || "${SSH_PUSH_IMAGE}" == true ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "docker is required when SSH_BUILD_IMAGE or SSH_PUSH_IMAGE is enabled" >&2
    exit 1
  fi
fi

if [[ "${NEED_BUILD}" == true ]]; then
  if [[ ! -f "${SSH_DOCKERFILE}" ]]; then
    echo "Dockerfile not found at ${SSH_DOCKERFILE}" >&2
    exit 1
  fi
  SSH_DOCKERFILE="$(cd "$(dirname "${SSH_DOCKERFILE}")" && pwd)/$(basename "${SSH_DOCKERFILE}")"
  if [[ -z "${SSH_BUILD_CONTEXT}" ]]; then
    SSH_BUILD_CONTEXT="$(dirname "${SSH_DOCKERFILE}")"
  elif [[ -d "${SSH_BUILD_CONTEXT}" ]]; then
    SSH_BUILD_CONTEXT="$(cd "${SSH_BUILD_CONTEXT}" && pwd)"
  else
    echo "Build context ${SSH_BUILD_CONTEXT} does not exist" >&2
    exit 1
  fi
elif [[ -n "${SSH_BUILD_CONTEXT}" && ! -d "${SSH_BUILD_CONTEXT}" ]]; then
  echo "Build context ${SSH_BUILD_CONTEXT} does not exist" >&2
  exit 1
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

if [[ "${NEED_BUILD}" == true ]]; then
  printf 'Building bastion image %s\n' "${SSH_BASTION_IMAGE_REF}"
  docker build -t "${SSH_BASTION_IMAGE_REF}" -f "${SSH_DOCKERFILE}" "${SSH_BUILD_CONTEXT}"
fi

if [[ "${SSH_PUSH_IMAGE}" == true ]]; then
  printf 'Pushing bastion image %s\n' "${SSH_BASTION_IMAGE_REF}"
  docker push "${SSH_BASTION_IMAGE_REF}"
fi

TUNNEL_SECRET_EXISTS=false
EXISTING_TUNNEL_TOKEN=""
if [[ -n "${SSH_NODE_NAME}" ]]; then
  SSH_NODE_PLACEMENT_BLOCK=$'      nodeName: '"${SSH_NODE_NAME}"
else
  SSH_NODE_PLACEMENT_BLOCK=""
fi

if [[ -n "${SSH_MOTD_CONTENT}" ]]; then
  MOTD_RENDERED="$(printf '%b' "${SSH_MOTD_CONTENT}")"
  MOTD_BLOCK=""
  while IFS= read -r line; do
    MOTD_BLOCK+=$'    '"${line}"$'\n'
  done <<<"${MOTD_RENDERED}"
  SSH_MOTD_CONTENT_BLOCK=${MOTD_BLOCK%$'\n'}
else
  SSH_MOTD_CONTENT_BLOCK='    Codex SSH bastion'
fi

export SSH_NAMESPACE SSH_DEPLOYMENT_NAME SSH_SERVICE_NAME SSH_SERVICE_TYPE \
  SSH_SERVICE_NODE_PORT SSH_SERVICE_NODE_PORT_LINE SSH_PVC_NAME SSH_PVC_SIZE \
  SSH_STORAGE_CLASS_BLOCK SSH_CONFIGMAP_NAME SSH_AUTHORIZED_SECRET \
  SSH_BASTION_IMAGE_REF SSH_MOTD_CONTENT_BLOCK SSH_DATA_VOLUME_BLOCK \
  SSH_NODE_PLACEMENT_BLOCK EFFECTIVE_STORAGE_TYPE SSH_SERVICE_PORT \
  SSH_HTTP_TUNNEL_PORT SSH_TUNNEL_SECRET_NAME

case "${SSH_GENERATE_WORKSPACE_KEY}" in
  true|false|auto)
    ;;
  *)
    echo "SSH_GENERATE_WORKSPACE_KEY must be one of: auto, true, false" >&2
    exit 1
    ;;
esac

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
render "${MANIFEST_DIR}/service-internal.yaml" "${TMP_DIR}/service-internal.yaml"

printf 'Ensuring namespace %s exists\n' "${SSH_NAMESPACE}"
kubectl apply -f "${TMP_DIR}/namespace.yaml"

if kubectl -n "${SSH_NAMESPACE}" get secret "${SSH_TUNNEL_SECRET_NAME}" >/dev/null 2>&1; then
  TUNNEL_SECRET_EXISTS=true
  existing_auth_b64="$(kubectl -n "${SSH_NAMESPACE}" get secret "${SSH_TUNNEL_SECRET_NAME}" -o jsonpath='{.data.auth}' 2>/dev/null || true)"
  if [[ -n "${existing_auth_b64}" ]]; then
    existing_auth="$(printf '%s' "${existing_auth_b64}" | base64 --decode 2>/dev/null || true)"
    if [[ "${existing_auth}" == "${SSH_TUNNEL_USER}:"* ]]; then
      EXISTING_TUNNEL_TOKEN="${existing_auth#${SSH_TUNNEL_USER}:}"
    fi
  fi
fi

if [[ -z "${SSH_TUNNEL_TOKEN}" ]]; then
  if [[ -n "${EXISTING_TUNNEL_TOKEN}" ]]; then
    SSH_TUNNEL_TOKEN="${EXISTING_TUNNEL_TOKEN}"
  else
    SSH_TUNNEL_TOKEN="$(python3 - <<'PY'
import secrets
import string
alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range(32)))
PY
)"
  fi
fi

TUNNEL_AUTH_VALUE="${SSH_TUNNEL_USER}:${SSH_TUNNEL_TOKEN}"
printf 'Configuring tunnel secret %s (user=%s)\n' "${SSH_TUNNEL_SECRET_NAME}" "${SSH_TUNNEL_USER}"
TUNNEL_SECRET_MANIFEST="${TMP_DIR}/tunnel-secret.yaml"
kubectl -n "${SSH_NAMESPACE}" create secret generic "${SSH_TUNNEL_SECRET_NAME}" \
  --from-literal=auth="${TUNNEL_AUTH_VALUE}" \
  --dry-run=client -o yaml >"${TUNNEL_SECRET_MANIFEST}"
kubectl apply -f "${TUNNEL_SECRET_MANIFEST}"

SECRET_EXISTS=false
if kubectl -n "${SSH_NAMESPACE}" get secret "${SSH_AUTHORIZED_SECRET}" >/dev/null 2>&1; then
  SECRET_EXISTS=true
fi
if [[ "${SSH_STORAGE_TYPE}" == "pvc" ]]; then
  kubectl apply -f "${TMP_DIR}/pvc.yaml"
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

  if [[ -n "${SSH_WORKSPACE_KEY_OUTPUT}" ]]; then
    mkdir -p "$(dirname "${SSH_WORKSPACE_KEY_OUTPUT}")"
    cp "${WORKSPACE_PRIVATE_KEY_PATH}" "${SSH_WORKSPACE_KEY_OUTPUT}"
    chmod 600 "${SSH_WORKSPACE_KEY_OUTPUT}"
    WORKSPACE_PRIVATE_KEY_PATH="${SSH_WORKSPACE_KEY_OUTPUT}"
  fi
fi

if [[ -n "${SSH_AUTHORIZED_KEYS_FILE:-}" ]]; then
  printf 'Updating authorized_keys secret %s\n' "${SSH_AUTHORIZED_SECRET}"
  kubectl -n "${SSH_NAMESPACE}" create secret generic "${SSH_AUTHORIZED_SECRET}" \
    --from-file=authorized_keys="${SSH_AUTHORIZED_KEYS_FILE}" \
    --dry-run=client -o yaml | kubectl apply -f -
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
kubectl apply -f "${TMP_DIR}/service-internal.yaml"

kubectl -n "${SSH_NAMESPACE}" rollout restart deployment/"${SSH_DEPLOYMENT_NAME}"
kubectl -n "${SSH_NAMESPACE}" rollout status deployment/"${SSH_DEPLOYMENT_NAME}" --timeout=5m

SERVICE_NODE_PORT_VALUE=""
SERVICE_CLUSTER_PORT_VALUE=""
SERVICE_HOST_VALUE=""
SERVICE_ENDPOINT_NOTE=""
SERVICE_INTERNAL_NODE_IP=""

SERVICE_TYPE_ACTUAL="$(kubectl -n "${SSH_NAMESPACE}" get svc "${SSH_SERVICE_NAME}" -o jsonpath='{.spec.type}')"
if [[ -z "${SERVICE_TYPE_ACTUAL}" ]]; then
  SERVICE_TYPE_ACTUAL="${SSH_SERVICE_TYPE}"
fi

case "${SERVICE_TYPE_ACTUAL}" in
  NodePort)
    SERVICE_NODE_PORT_VALUE="$(kubectl -n "${SSH_NAMESPACE}" get svc "${SSH_SERVICE_NAME}" -o jsonpath='{.spec.ports[0].nodePort}')"
    if [[ -z "${SERVICE_NODE_PORT_VALUE}" ]]; then
      SERVICE_NODE_PORT_VALUE="${SSH_SERVICE_NODE_PORT}"
    fi
  if [[ -n "${SSH_PUBLIC_PORT}" ]]; then
      SERVICE_NODE_PORT_VALUE="${SSH_PUBLIC_PORT}"
    fi
    if [[ -n "${SSH_NODE_NAME}" ]]; then
      node_addresses="$(kubectl get node "${SSH_NODE_NAME}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
      if [[ -n "${node_addresses}" ]]; then
        read -r SERVICE_INTERNAL_NODE_IP _ <<<"${node_addresses}"
        SERVICE_INTERNAL_NODE_IP="${SERVICE_INTERNAL_NODE_IP//[[:space:]]/}"
      fi
    fi
    if [[ -z "${SERVICE_INTERNAL_NODE_IP}" ]]; then
      cluster_addresses="$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
      if [[ -n "${cluster_addresses}" ]]; then
        read -r SERVICE_INTERNAL_NODE_IP _ <<<"${cluster_addresses}"
        SERVICE_INTERNAL_NODE_IP="${SERVICE_INTERNAL_NODE_IP//[[:space:]]/}"
      fi
    fi
    if [[ -n "${SSH_PUBLIC_HOST}" ]]; then
      SERVICE_HOST_VALUE="${SSH_PUBLIC_HOST}"
    else
      SERVICE_HOST_VALUE="${SERVICE_INTERNAL_NODE_IP}"
    fi
    if [[ -z "${SERVICE_HOST_VALUE}" ]]; then
      SERVICE_HOST_VALUE="<node-ip>"
      SERVICE_ENDPOINT_NOTE="(replace <node-ip> with a reachable node address)"
    fi
    ;;
  LoadBalancer)
    SERVICE_CLUSTER_PORT_VALUE="$(kubectl -n "${SSH_NAMESPACE}" get svc "${SSH_SERVICE_NAME}" -o jsonpath='{.spec.ports[0].port}')"
    SERVICE_HOST_VALUE="$(kubectl -n "${SSH_NAMESPACE}" get svc "${SSH_SERVICE_NAME}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [[ -z "${SERVICE_HOST_VALUE}" ]]; then
      SERVICE_HOST_VALUE="$(kubectl -n "${SSH_NAMESPACE}" get svc "${SSH_SERVICE_NAME}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    fi
    SERVICE_HOST_VALUE="${SERVICE_HOST_VALUE//[[:space:]]/}"
    if [[ -z "${SERVICE_HOST_VALUE}" ]]; then
      SERVICE_HOST_VALUE="<load-balancer-host>"
      SERVICE_ENDPOINT_NOTE="(replace placeholder with the assigned external address)"
    fi
    ;;
  ClusterIP|*)
    SERVICE_CLUSTER_PORT_VALUE="$(kubectl -n "${SSH_NAMESPACE}" get svc "${SSH_SERVICE_NAME}" -o jsonpath='{.spec.ports[0].port}')"
    SERVICE_HOST_VALUE="<cluster-ip>"
    SERVICE_ENDPOINT_NOTE="(expose the service externally or port-forward before using it from Codex)"
    ;;
esac

SSH_GW_NODE_VALUE=""
if [[ "${SERVICE_TYPE_ACTUAL}" == "NodePort" ]]; then
  if [[ -n "${SERVICE_NODE_PORT_VALUE}" ]]; then
    SSH_GW_NODE_VALUE="${SERVICE_HOST_VALUE}:${SERVICE_NODE_PORT_VALUE}"
  fi
elif [[ -n "${SERVICE_CLUSTER_PORT_VALUE}" && -n "${SERVICE_HOST_VALUE}" ]]; then
  SSH_GW_NODE_VALUE="${SERVICE_HOST_VALUE}:${SERVICE_CLUSTER_PORT_VALUE}"
fi

SSH_GW_URI_VALUE=""
if [[ -n "${SSH_GW_NODE_VALUE}" ]]; then
  if [[ -n "${SSH_PUBLIC_SCHEME}" ]]; then
    SSH_GW_URI_VALUE="${SSH_PUBLIC_SCHEME}://${SSH_GW_NODE_VALUE}"
  else
    SSH_GW_URI_VALUE="${SSH_GW_NODE_VALUE}"
  fi
fi

cat <<INFO
---
Deployment applied.

Codex workspace configuration:
  SSH_GW_NODE=${SSH_GW_NODE_VALUE:-<node-or-dns>:${SSH_SERVICE_NODE_PORT}} ${SERVICE_ENDPOINT_NOTE}
  SSH_GW_URI=${SSH_GW_URI_VALUE:-${SSH_PUBLIC_SCHEME}://<node-or-dns>:${SSH_SERVICE_NODE_PORT}}
  SSH_GW_USER=${SSH_TUNNEL_USER}
  SSH_GW_TOKEN=${SSH_TUNNEL_TOKEN}
  SSH_KEY    -> см. вывод ниже

Проверка на хосте:
  kubectl -n ${SSH_NAMESPACE} get pods -o wide
  kubectl -n ${SSH_NAMESPACE} get svc ${SSH_SERVICE_NAME} -o wide
  curl -i http://${SERVICE_INTERNAL_NODE_IP:-<node-ip>}:${SSH_SERVICE_NODE_PORT}/healthz  # ожидаем HTTP 200 от HTTP-шлюза

Обновить authorized_keys:
  kubectl -n ${SSH_NAMESPACE} create secret generic ${SSH_AUTHORIZED_SECRET} \
    --from-file=authorized_keys=<path> --dry-run=client -o yaml | kubectl apply -f -

Экспорт инвентаря из пода:
  kubectl -n ${SSH_NAMESPACE} exec deploy/${SSH_DEPLOYMENT_NAME} -- codex-hostctl export

Внутрикластерный доступ без моста:
  kubectl -n ${SSH_NAMESPACE} run -it --rm test-shell --image=debian:bookworm-slim -- bash
  apt-get update && apt-get install -y openssh-client
  ssh codex@${SSH_SERVICE_NAME}-internal.${SSH_NAMESPACE}.svc.cluster.local
---
INFO

if [[ -n "${WORKSPACE_PRIVATE_KEY_PATH}" ]]; then
  printf '\nСохраните приватный ключ для Codex Workspace (секрет SSH_KEY):\n\n'
  cat "${WORKSPACE_PRIVATE_KEY_PATH}"
  printf '\n'
else
  if [[ -n "${SSH_WORKSPACE_KEY_OUTPUT}" && -f "${SSH_WORKSPACE_KEY_OUTPUT}" ]]; then
    printf '\nИспользуйте сохранённый приватный ключ (%s).\n' "${SSH_WORKSPACE_KEY_OUTPUT}"
    cat "${SSH_WORKSPACE_KEY_OUTPUT}"
    printf '\n'
  elif [[ -n "${SSH_AUTHORIZED_KEYS_FILE:-}" ]]; then
    printf '\nПриватный ключ не выводится, так как использован подготовленный authorized_keys (%s).\n' "${SSH_AUTHORIZED_KEYS_FILE}"
  else
    printf '\nПриватный ключ не был сгенерирован автоматически (секрет %s уже существует). Удалите секрет или установите SSH_GENERATE_WORKSPACE_KEY=true, чтобы выпустить новую пару ключей.\n' "${SSH_AUTHORIZED_SECRET}"
  fi
fi
