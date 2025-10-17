#!/usr/bin/env bash
set -euo pipefail

# Deploys the NodePort-based Kubernetes API gateway inside the cluster.
# Requires kubectl access to the target cluster.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR%/scripts}"
MANIFEST_DIR="${ROOT_DIR}/manifests"

NAMESPACE="${NAMESPACE:-k8s-gw}"
SECRET_NAME="${SECRET_NAME:-cluster-ca}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-k8s-api-gw}"
SERVICE_NAME="${SERVICE_NAME:-k8s-api-gw}"

EXPOSE_MODE="${EXPOSE_MODE:-nodeport}"
EXPOSE_MODE_LOWER="$(printf '%s' "${EXPOSE_MODE}" | tr '[:upper:]' '[:lower:]')"

case "${EXPOSE_MODE_LOWER}" in
  nodeport)
    INGRESS_ENABLED=0
    DEFAULT_SERVICE_TYPE="NodePort"
    ;;
  https|ingress)
    INGRESS_ENABLED=1
    DEFAULT_SERVICE_TYPE="ClusterIP"
    ;;
  *)
    echo "Unsupported EXPOSE_MODE '${EXPOSE_MODE}'. Expected 'nodeport' or 'https'." >&2
    exit 1
    ;;
esac

SERVICE_TYPE="${SERVICE_TYPE:-${DEFAULT_SERVICE_TYPE}}"
SERVICE_TYPE_UPPER="$(printf '%s' "${SERVICE_TYPE}" | tr '[:lower:]' '[:upper:]')"

SERVICE_NODE_PORT_RAW="${SERVICE_NODE_PORT:-}"
if [[ -z "${SERVICE_NODE_PORT_RAW}" && -n "${GW_NODE_PORT:-}" ]]; then
  SERVICE_NODE_PORT_RAW="${GW_NODE_PORT}"
fi
SERVICE_NODE_PORT="${SERVICE_NODE_PORT_RAW}"
UPSTREAM_API="${UPSTREAM_API:-10.0.70.200:6443}"
SA_NAME="${SA_NAME:-codex-gw}"
TOKEN_SECRET_NAME="${TOKEN_SECRET_NAME:-${SA_NAME}-token}"
CLUSTERROLEBINDING_NAME="${CLUSTERROLEBINDING_NAME:-${SA_NAME}-admin}"
CONTEXT_NAME="${CONTEXT_NAME:-$(kubectl config current-context)}"
AUTH_MODE="${AUTH_MODE:-passthrough}"
ALLOW_INJECT="${ALLOW_INJECT:-0}"

INGRESS_NAME="${INGRESS_NAME:-${SERVICE_NAME}}"
INGRESS_CLASS_NAME="${INGRESS_CLASS_NAME:-}"
INGRESS_EXTRA_ANNOTATIONS="${INGRESS_EXTRA_ANNOTATIONS:-}"
INGRESS_PROXY_BODY_SIZE="${INGRESS_PROXY_BODY_SIZE:-64m}"
TLS_SECRET_NAME="${TLS_SECRET_NAME:-${SERVICE_NAME}-tls}"
TLS_GENERATE_SELF_SIGNED="${TLS_GENERATE_SELF_SIGNED:-0}"
TLS_COMMON_NAME="${TLS_COMMON_NAME:-k8s-api-gw.local}"
TLS_SELF_SIGNED_DAYS="${TLS_SELF_SIGNED_DAYS:-365}"
TLS_CERT_FILE="${TLS_CERT_FILE:-}"
TLS_KEY_FILE="${TLS_KEY_FILE:-}"
TLS_CERT_DATA="${TLS_CERT:-${TLS_CERT_DATA:-}}"
TLS_KEY_DATA="${TLS_KEY:-${TLS_KEY_DATA:-}}"
TLS_SANS="${TLS_SANS:-}"
SELF_SIGNED_USED=0

TOTAL_STEPS=6
if (( INGRESS_ENABLED )); then
  ((TOTAL_STEPS+=1))
fi
CURRENT_STEP=1
TMP_FILES=()
trap 'rm -f "${TMP_FILES[@]}"' EXIT

step() {
  local message="$1"
  printf '[%d/%d] %s\n' "${CURRENT_STEP}" "${TOTAL_STEPS}" "${message}"
  ((CURRENT_STEP++))
}

trim() {
  local var="$1"
  var="${var#${var%%[![:space:]]*}}"
  var="${var%${var##*[![:space:]]}}"
  printf '%s' "$var"
}

HOST_INPUT="${INGRESS_HOSTS:-${INGRESS_HOST:-}}"
IFS_ORIGINAL="$IFS"
declare -a INGRESS_HOST_ARRAY=()
if [[ -n "${HOST_INPUT}" ]]; then
  IFS=',' read -ra _ingress_hosts <<< "${HOST_INPUT}"
  for raw_host in "${_ingress_hosts[@]}"; do
    host_trimmed="$(trim "${raw_host}")"
    if [[ -n "${host_trimmed}" ]]; then
      INGRESS_HOST_ARRAY+=("${host_trimmed}")
    fi
  done
fi
IFS="$IFS_ORIGINAL"

if [[ -n "${SERVICE_NODE_PORT}" ]]; then
  if [[ "${SERVICE_TYPE_UPPER}" != "NODEPORT" ]]; then
    echo "SERVICE_NODE_PORT is only valid when SERVICE_TYPE=NodePort (current: ${SERVICE_TYPE})." >&2
    exit 1
  fi
  if ! [[ "${SERVICE_NODE_PORT}" =~ ^[0-9]+$ ]]; then
    echo "SERVICE_NODE_PORT must be a numeric NodePort within 30000-32767." >&2
    exit 1
  fi
  SERVICE_NODE_PORT=$((10#${SERVICE_NODE_PORT}))
  if (( SERVICE_NODE_PORT < 30000 || SERVICE_NODE_PORT > 32767 )); then
    echo "SERVICE_NODE_PORT '${SERVICE_NODE_PORT}' is outside the NodePort range 30000-32767." >&2
    exit 1
  fi
fi

case "${AUTH_MODE}" in
  passthrough)
    ;;
  inject)
    if [[ "${ALLOW_INJECT}" != "1" ]]; then
      cat <<'EOF' >&2
ERROR: AUTH_MODE=inject requires explicit opt-in.
Set ALLOW_INJECT=1 if you understand that every client will receive the
cluster-admin service-account token. Otherwise leave AUTH_MODE unset to
use passthrough authentication.
EOF
      exit 1
    fi
    ;;
  *)
    echo "Unsupported AUTH_MODE '${AUTH_MODE}'. Expected 'inject' or 'passthrough'." >&2
    exit 1
    ;;
esac

HEALTHZ_PROBE_HEADERS=""

if [[ "${AUTH_MODE}" == "inject" ]]; then
  PRIMARY_AUTH_BLOCK=$'          proxy_set_header Authorization "Bearer __UPSTREAM_TOKEN__";\n'
  HEALTHZ_AUTH_BLOCK=$'          proxy_set_header Authorization "Bearer __UPSTREAM_TOKEN__";\n'
else
  PRIMARY_AUTH_BLOCK=$'          if ($http_authorization = "") {\n            return 401;\n          }\n          proxy_set_header Authorization $http_authorization;\n'
  HEALTHZ_AUTH_BLOCK="${PRIMARY_AUTH_BLOCK}"
  HEALTHZ_PROBE_HEADERS=$'            httpHeaders:\n            - name: Authorization\n              value: "Bearer __UPSTREAM_TOKEN__"\n'
fi

if [[ -z "${CONTEXT_NAME}" ]]; then
  echo "Unable to determine kubeconfig context. Set CONTEXT_NAME explicitly." >&2
  exit 1
fi

CLUSTER_NAME="$(kubectl config view --raw -o jsonpath="{.contexts[?(@.name==\"${CONTEXT_NAME}\")].context.cluster}")"
if [[ -z "${CLUSTER_NAME}" ]]; then
  echo "Failed to resolve cluster name for context '${CONTEXT_NAME}'." >&2
  exit 1
fi

if [[ -n "${CLUSTER_CA_B64:-}" ]]; then
  CA_B64="${CLUSTER_CA_B64}"
else
  CA_B64="$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name==\"${CLUSTER_NAME}\")].cluster.certificate-authority-data}")"
fi

if [[ -z "${CA_B64}" ]]; then
  echo "Unable to source certificate-authority-data; set CLUSTER_CA_B64 manually." >&2
  exit 1
fi

step "Ensuring namespace '${NAMESPACE}' exists..."
kubectl apply -f "${MANIFEST_DIR}/ns.yaml"

step "Publishing kube-apiserver CA to secret '${SECRET_NAME}'..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
type: Opaque
data:
  ca.crt: ${CA_B64}
EOF

step "Ensuring service account '${SA_NAME}' exists..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SA_NAME}
  namespace: ${NAMESPACE}
EOF

step "Granting cluster-admin via ClusterRoleBinding '${CLUSTERROLEBINDING_NAME}'..."
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${CLUSTERROLEBINDING_NAME}
subjects:
- kind: ServiceAccount
  name: ${SA_NAME}
  namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
EOF

step "Ensuring service account token secret '${TOKEN_SECRET_NAME}' exists..."
if ! kubectl -n "${NAMESPACE}" get secret "${TOKEN_SECRET_NAME}" >/dev/null 2>&1; then
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${TOKEN_SECRET_NAME}
  namespace: ${NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: ${SA_NAME}
type: kubernetes.io/service-account-token
EOF
fi

UPSTREAM_TOKEN_B64=""
for attempt in {1..15}; do
  UPSTREAM_TOKEN_B64="$(kubectl -n "${NAMESPACE}" get secret "${TOKEN_SECRET_NAME}" -o jsonpath='{.data.token}' 2>/dev/null || true)"
  if [[ -n "${UPSTREAM_TOKEN_B64}" ]]; then
    break
  fi
  sleep 2
done

if [[ -z "${UPSTREAM_TOKEN_B64}" ]]; then
  echo "Failed to retrieve token data from secret '${TOKEN_SECRET_NAME}'." >&2
  exit 1
fi

UPSTREAM_TOKEN="$(printf '%s' "${UPSTREAM_TOKEN_B64}" | base64 --decode)"

if (( INGRESS_ENABLED )); then
  step "Ensuring TLS secret '${TLS_SECRET_NAME}' is present..."

  TLS_CERT_PATH="${TLS_CERT_FILE}"
  TLS_KEY_PATH="${TLS_KEY_FILE}"

  if [[ -n "${TLS_CERT_DATA}" || -n "${TLS_KEY_DATA}" ]]; then
    if [[ -z "${TLS_CERT_DATA}" || -z "${TLS_KEY_DATA}" ]]; then
      echo "Provide both TLS_CERT and TLS_KEY (or TLS_CERT_DATA/TLS_KEY_DATA)." >&2
      exit 1
    fi
    TMP_TLS_CERT="$(mktemp)"
    TMP_TLS_KEY="$(mktemp)"
    TMP_FILES+=("${TMP_TLS_CERT}" "${TMP_TLS_KEY}")
    printf '%s' "${TLS_CERT_DATA}" > "${TMP_TLS_CERT}"
    printf '%s' "${TLS_KEY_DATA}" > "${TMP_TLS_KEY}"
    TLS_CERT_PATH="${TMP_TLS_CERT}"
    TLS_KEY_PATH="${TMP_TLS_KEY}"
  fi

  if [[ "${TLS_GENERATE_SELF_SIGNED}" == "1" ]]; then
    if [[ -n "${TLS_CERT_PATH}" || -n "${TLS_KEY_PATH}" ]]; then
      echo "TLS_GENERATE_SELF_SIGNED=1 cannot be combined with TLS_CERT_FILE/TLS_KEY_FILE or TLS_CERT/TLS_KEY." >&2
      exit 1
    fi
    if ! command -v openssl >/dev/null 2>&1; then
      echo "openssl is required to generate a self-signed certificate." >&2
      exit 1
    fi
    TMP_TLS_CERT="$(mktemp)"
    TMP_TLS_KEY="$(mktemp)"
    TMP_FILES+=("${TMP_TLS_CERT}" "${TMP_TLS_KEY}")

    declare -a SAN_ENTRIES=()
    if ((${#INGRESS_HOST_ARRAY[@]})); then
      for host in "${INGRESS_HOST_ARRAY[@]}"; do
        SAN_ENTRIES+=("DNS:${host}")
      done
    else
      SAN_ENTRIES+=("DNS:${TLS_COMMON_NAME}")
    fi

    if [[ -n "${TLS_SANS}" ]]; then
      IFS=',' read -ra _sans_parts <<< "${TLS_SANS}"
      for raw_san in "${_sans_parts[@]}"; do
        san_trimmed="$(trim "${raw_san}")"
        [[ -z "${san_trimmed}" ]] && continue
        if [[ "${san_trimmed}" =~ ^([A-Za-z]+):(.+)$ ]]; then
          san_prefix="${BASH_REMATCH[1]}"
          san_value="$(trim "${BASH_REMATCH[2]}")"
        else
          san_prefix="DNS"
          san_value="${san_trimmed}"
        fi
        san_prefix_upper="$(printf '%s' "${san_prefix}" | tr '[:lower:]' '[:upper:]')"
        case "${san_prefix_upper}" in
          DNS|IP)
            SAN_ENTRIES+=("${san_prefix_upper}:${san_value}")
            ;;
          *)
            echo "Unsupported TLS_SANS entry '${san_trimmed}'. Use DNS:<name> or IP:<address>." >&2
            exit 1
            ;;
        esac
      done
    fi

    SAN_JOINED=$(IFS=','; printf '%s' "${SAN_ENTRIES[*]}")
    if [[ -z "${SAN_JOINED}" ]]; then
      SAN_JOINED="DNS:${TLS_COMMON_NAME}"
    fi

    if ! openssl req -x509 -nodes -newkey rsa:2048 \
      -keyout "${TMP_TLS_KEY}" \
      -out "${TMP_TLS_CERT}" \
      -days "${TLS_SELF_SIGNED_DAYS}" \
      -subj "/CN=${TLS_COMMON_NAME}" \
      -addext "subjectAltName=${SAN_JOINED}" >/dev/null 2>&1; then
      echo "Failed to generate a self-signed certificate with openssl." >&2
      exit 1
    fi

    SELF_SIGNED_USED=1
    TLS_CERT_PATH="${TMP_TLS_CERT}"
    TLS_KEY_PATH="${TMP_TLS_KEY}"
  fi

  if [[ -n "${TLS_CERT_PATH}" || -n "${TLS_KEY_PATH}" ]]; then
    if [[ -z "${TLS_CERT_PATH}" || -z "${TLS_KEY_PATH}" ]]; then
      echo "Provide both TLS_CERT_FILE and TLS_KEY_FILE." >&2
      exit 1
    fi
    kubectl -n "${NAMESPACE}" create secret tls "${TLS_SECRET_NAME}" \
      --cert="${TLS_CERT_PATH}" \
      --key="${TLS_KEY_PATH}" \
      --dry-run=client -o yaml | kubectl apply -f -
  else
    if ! kubectl -n "${NAMESPACE}" get secret "${TLS_SECRET_NAME}" >/dev/null 2>&1; then
      cat <<EOF >&2
TLS secret '${TLS_SECRET_NAME}' was not found. Provide certificate data via TLS_CERT_FILE/TLS_KEY_FILE, TLS_CERT/TLS_KEY,
or enable TLS_GENERATE_SELF_SIGNED=1 to generate a local certificate.
EOF
      exit 1
    fi
  fi
fi

TMP_CM="$(mktemp)"
TMP_FILES+=("${TMP_CM}")
TMP_DEPLOY="$(mktemp)"
TMP_FILES+=("${TMP_DEPLOY}")

PRIMARY_AUTH_BLOCK="${PRIMARY_AUTH_BLOCK}" HEALTHZ_AUTH_BLOCK="${HEALTHZ_AUTH_BLOCK}" HEALTHZ_PROBE_HEADERS="${HEALTHZ_PROBE_HEADERS}" SERVICE_NODE_PORT="${SERVICE_NODE_PORT}" SERVICE_TYPE="${SERVICE_TYPE}" python3 - <<'PY' "${UPSTREAM_API}" "${UPSTREAM_TOKEN}" "${SA_NAME}" "${MANIFEST_DIR}/cm-nginx.conf.yaml" "${MANIFEST_DIR}/deploy.yaml" "${TMP_CM}" "${TMP_DEPLOY}"
import os
import sys
from pathlib import Path

upstream_api, upstream_token, sa_name, cm_path, deploy_path, cm_out, deploy_out = sys.argv[1:]

primary_block = os.environ["PRIMARY_AUTH_BLOCK"]
healthz_block = os.environ["HEALTHZ_AUTH_BLOCK"]
probe_headers = os.environ.get("HEALTHZ_PROBE_HEADERS", "")
service_node_port = os.environ.get("SERVICE_NODE_PORT", "").strip()
service_type = os.environ.get("SERVICE_TYPE", "NodePort")

cm = Path(cm_path).read_text()
cm = cm.replace('__UPSTREAM_API__', upstream_api)
cm = cm.replace('__PRIMARY_AUTH_BLOCK__', primary_block)
cm = cm.replace('__HEALTHZ_AUTH_BLOCK__', healthz_block)
cm = cm.replace('__UPSTREAM_TOKEN__', upstream_token)
Path(cm_out).write_text(cm)

deploy = Path(deploy_path).read_text()
deploy = deploy.replace('__SERVICE_ACCOUNT_NAME__', sa_name)
node_port_block = ""
if service_type.lower() == "nodeport" and service_node_port:
    node_port_block = f"    nodePort: {service_node_port}\n"
deploy = deploy.replace('__NODE_PORT_BLOCK__\n', node_port_block, 1)
deploy = deploy.replace('__NODE_PORT_BLOCK__', node_port_block, 1)
deploy = deploy.replace('__HEALTHZ_PROBE_HEADERS__\n', probe_headers, 1)
deploy = deploy.replace('__HEALTHZ_PROBE_HEADERS__', probe_headers, 1)
deploy = deploy.replace('__UPSTREAM_TOKEN__', upstream_token)
deploy = deploy.replace('__SERVICE_TYPE__', service_type)
Path(deploy_out).write_text(deploy)
PY

if (( INGRESS_ENABLED )); then
  TMP_INGRESS="$(mktemp)"
  TMP_FILES+=("${TMP_INGRESS}")
  {
    echo "apiVersion: networking.k8s.io/v1"
    echo "kind: Ingress"
    echo "metadata:"
    echo "  name: ${INGRESS_NAME}"
    echo "  namespace: ${NAMESPACE}"
    echo "  annotations:"
    echo "    nginx.ingress.kubernetes.io/backend-protocol: "HTTP""
    echo "    nginx.ingress.kubernetes.io/proxy-body-size: "${INGRESS_PROXY_BODY_SIZE}""
    if [[ -n "${INGRESS_EXTRA_ANNOTATIONS}" ]]; then
      while IFS= read -r raw_annotation; do
        annotation_trimmed="$(trim "${raw_annotation}")"
        [[ -z "${annotation_trimmed}" ]] && continue
        echo "    ${annotation_trimmed}"
      done <<< "${INGRESS_EXTRA_ANNOTATIONS}"
    fi
    echo "spec:"
    if [[ -n "${INGRESS_CLASS_NAME}" ]]; then
      echo "  ingressClassName: ${INGRESS_CLASS_NAME}"
    fi
    echo "  tls:"
    echo "  - secretName: ${TLS_SECRET_NAME}"
    if ((${#INGRESS_HOST_ARRAY[@]})); then
      echo "    hosts:"
      for host in "${INGRESS_HOST_ARRAY[@]}"; do
        echo "    - ${host}"
      done
    fi
    echo "  rules:"
    if ((${#INGRESS_HOST_ARRAY[@]})); then
      for host in "${INGRESS_HOST_ARRAY[@]}"; do
        echo "  - host: ${host}"
        echo "    http:"
        echo "      paths:"
        echo "      - path: /"
        echo "        pathType: Prefix"
        echo "        backend:"
        echo "          service:"
        echo "            name: ${SERVICE_NAME}"
        echo "            port:"
        echo "              number: 80"
      done
    else
      echo "  - http:"
      echo "      paths:"
      echo "      - path: /"
      echo "        pathType: Prefix"
      echo "        backend:"
      echo "          service:"
      echo "            name: ${SERVICE_NAME}"
      echo "            port:"
      echo "              number: 80"
    fi
  } > "${TMP_INGRESS}"
else
  kubectl -n "${NAMESPACE}" delete ingress "${INGRESS_NAME}" --ignore-not-found >/dev/null 2>&1 || true
fi

step "Applying manifests and rolling out the gateway..."
kubectl apply -f "${TMP_CM}"
kubectl apply -f "${TMP_DEPLOY}"
if (( INGRESS_ENABLED )); then
  kubectl apply -f "${TMP_INGRESS}"
fi
kubectl -n "${NAMESPACE}" rollout restart deploy/"${DEPLOYMENT_NAME}"
kubectl -n "${NAMESPACE}" rollout status deploy/"${DEPLOYMENT_NAME}" --timeout=5m

echo

if (( INGRESS_ENABLED )); then
  INGRESS_ADDRESSES="$(kubectl -n "${NAMESPACE}" get ingress "${INGRESS_NAME}" -o jsonpath='{range .status.loadBalancer.ingress[*]}{.ip}{.hostname}{"\n"}{end}' 2>/dev/null || true)"
  echo "Gateway ingress '${INGRESS_NAME}' is serving HTTPS."
  if ((${#INGRESS_HOST_ARRAY[@]})); then
    echo "Configured host rules:"
    for host in "${INGRESS_HOST_ARRAY[@]}"; do
      echo "  - ${host}"
    done
  else
    echo "Configured host rules: <all hosts>"
  fi
  if [[ -n "${INGRESS_ADDRESSES// }" ]]; then
    echo "Current ingress endpoints:"
    echo "${INGRESS_ADDRESSES}"
  else
    echo "Ingress endpoints are pending; run 'kubectl -n ${NAMESPACE} get ingress ${INGRESS_NAME}' to monitor provisioning."
  fi
  echo "TLS secret: ${TLS_SECRET_NAME}"
else
  if [[ "${SERVICE_TYPE_UPPER}" == "NODEPORT" ]]; then
    NODE_PORT="$(kubectl -n "${NAMESPACE}" get svc "${SERVICE_NAME}" -o jsonpath='{.spec.ports[0].nodePort}')"
    NODE_IPS="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')"
    echo "Gateway service '${SERVICE_NAME}' is exposed as NodePort: ${NODE_PORT}"
    echo "Reachable node IPs:"
    echo "${NODE_IPS}"
    echo
    echo "Provide one of the node IPs together with the NodePort to the Codex workspace setup script."
  else
    echo "Gateway service '${SERVICE_NAME}' is configured with type '${SERVICE_TYPE}'. Inspect the service to obtain connection details."
    NODE_PORT=""
  fi
fi

DEFAULT_ENDPOINT_HINT=""
if (( INGRESS_ENABLED )); then
  DEFAULT_ENDPOINT_HINT="https://<ingress-endpoint>"
  if ((${#INGRESS_HOST_ARRAY[@]})); then
    DEFAULT_ENDPOINT_HINT="https://${INGRESS_HOST_ARRAY[0]}"
  elif [[ -n "${INGRESS_ADDRESSES// }" ]]; then
    FIRST_INGRESS_ADDRESS="$(trim "$(printf '%s\n' "${INGRESS_ADDRESSES}" | head -n1)")"
    if [[ -n "${FIRST_INGRESS_ADDRESS}" ]]; then
      DEFAULT_ENDPOINT_HINT="https://${FIRST_INGRESS_ADDRESS}"
    fi
  fi
else
  if [[ -n "${NODE_PORT}" ]]; then
    FIRST_NODE_IP="$(printf '%s\n' "${NODE_IPS}" | head -n1 | tr -d '[:space:]')"
    if [[ -n "${FIRST_NODE_IP}" ]]; then
      DEFAULT_ENDPOINT_HINT="http://${FIRST_NODE_IP}:${NODE_PORT}"
    else
      DEFAULT_ENDPOINT_HINT="http://<node-ip>:${NODE_PORT}"
    fi
  fi
  if [[ -z "${DEFAULT_ENDPOINT_HINT}" ]]; then
    DEFAULT_ENDPOINT_HINT="http://<node-ip>:<node-port>"
  fi
fi

if [[ "${AUTH_MODE}" == "passthrough" ]]; then
  if (( INGRESS_ENABLED )); then
    cat <<EOF

Gateway authentication mode: passthrough
- Every client must present its own Kubernetes bearer token.
- Provide the HTTPS endpoint to the Codex workspace and preload a client token as a Codex Secret.
  • UI: Settings → Variables → add GW_ENDPOINT=${DEFAULT_ENDPOINT_HINT}
        Settings → Secrets  → add K8S_TOKEN=${UPSTREAM_TOKEN}
- When the certificate’s Common Name differs from the endpoint (for example when using TLS_COMMON_NAME=${TLS_COMMON_NAME}), set GW_TLS_SERVER_NAME="${TLS_COMMON_NAME}" and provide the CA via GW_CA_DATA or GW_CA_FILE as needed.
EOF
  else
    cat <<EOF

Gateway authentication mode: passthrough
- Every client must present its own Kubernetes bearer token.
- Provide a reachable node IP together with the NodePort to the Codex workspace helper.
  • UI: Settings → Variables → add GW_ENDPOINT=${DEFAULT_ENDPOINT_HINT}
        Settings → Secrets  → add K8S_TOKEN=${UPSTREAM_TOKEN}
- Replace <node-ip> with one of the addresses listed above if the placeholder remains. Use whichever node is reachable from your Codex project.
- When using non-public certificates or self-signed TLS bridges, provide the CA via GW_CA_DATA or GW_CA_FILE as needed.
EOF
  fi
else
  if (( INGRESS_ENABLED )); then
    cat <<EOF

Gateway authentication mode: inject
- The gateway injects a cluster-admin service-account token into every request.
- Anyone who can reach the ingress endpoint can act as cluster-admin.
- Record the HTTPS endpoint once per workspace (no Codex Secret is required unless you override the injected token).
  • UI: Settings → Variables → add GW_ENDPOINT=${DEFAULT_ENDPOINT_HINT}
- Switch to AUTH_MODE=passthrough to require per-client credentials.
EOF
  else
    cat <<EOF

Gateway authentication mode: inject
- The gateway injects a cluster-admin service-account token into every request.
- Anyone who can reach the NodePort can act as cluster-admin.
- Record the gateway endpoint once per workspace (no Codex Secret is required unless you override the injected token).
  • UI: Settings → Variables → add GW_ENDPOINT=${DEFAULT_ENDPOINT_HINT}
- Replace <node-ip> with one of the addresses listed above if the placeholder remains. Use whichever node is reachable from your Codex project.
- Switch to AUTH_MODE=passthrough to require per-client credentials.
EOF
  fi
fi

if (( INGRESS_ENABLED )) && [[ "${SELF_SIGNED_USED}" == "1" ]]; then
  cat <<'EOF'

NOTE: A self-signed certificate was generated for this ingress. Distribute the corresponding CA data to your clients (for example via GW_CA_DATA) if they must trust it.
EOF
fi

