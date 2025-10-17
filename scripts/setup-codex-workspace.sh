#!/usr/bin/env bash
set -euo pipefail

# Prepares the Codex workspace with kubectl and a kubeconfig pointing at the NodePort gateway.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR%/scripts}"
CONFIG_DIR="${ROOT_DIR}/configs"

OUT_PATH_DEFAULT="${CONFIG_DIR}/kubeconfig-nodeport"
OUT_PATH="${OUT_PATH_DEFAULT}"
DEFAULT_KUBECONFIG_DIR="${HOME}/.kube"
DEFAULT_KUBECONFIG_PATH="${DEFAULT_KUBECONFIG_DIR}/config"
DEFAULT_KUBECONFIG_BACKUP="${DEFAULT_KUBECONFIG_PATH}.bak"
SYNC_DEFAULT_KUBECONFIG="${SYNC_DEFAULT_KUBECONFIG:-1}"
DEFAULT_KUBECONFIG_UPDATED=0
DEFAULT_KUBECONFIG_BACKED_UP=0
DEFAULT_KUBECONFIG_EXISTED_BEFORE=0
if [[ -f "${DEFAULT_KUBECONFIG_PATH}" ]]; then
  DEFAULT_KUBECONFIG_EXISTED_BEFORE=1
fi

OUT_PATH_BACKUP=""
OUT_PATH_EXISTED_BEFORE=0
OUT_PATH_CREATED=0
NEW_BRIDGE_STARTED=0
NEW_BRIDGE_PID=""

cleanup_on_exit() {
  local exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    if [[ "${NEW_BRIDGE_STARTED}" == "1" && -n "${NEW_BRIDGE_PID}" ]]; then
      if kill -0 "${NEW_BRIDGE_PID}" 2>/dev/null; then
        kill "${NEW_BRIDGE_PID}" 2>/dev/null || true
        sleep 0.2
        if kill -0 "${NEW_BRIDGE_PID}" 2>/dev/null; then
          kill -9 "${NEW_BRIDGE_PID}" 2>/dev/null || true
        fi
      fi
      rm -f "${HTTPS_BRIDGE_PID_FILE}" "${HTTPS_BRIDGE_META_FILE}"
    fi

    if [[ "${DEFAULT_KUBECONFIG_UPDATED}" == "1" ]]; then
      if [[ "${DEFAULT_KUBECONFIG_EXISTED_BEFORE}" == "1" && -f "${DEFAULT_KUBECONFIG_BACKUP}" ]]; then
        cp "${DEFAULT_KUBECONFIG_BACKUP}" "${DEFAULT_KUBECONFIG_PATH}" 2>/dev/null || true
      else
        rm -f "${DEFAULT_KUBECONFIG_PATH}"
      fi
    fi

    if [[ "${OUT_PATH_CREATED}" == "1" ]]; then
      if [[ "${OUT_PATH_EXISTED_BEFORE}" == "1" && -n "${OUT_PATH_BACKUP}" && -f "${OUT_PATH_BACKUP}" ]]; then
        mv "${OUT_PATH_BACKUP}" "${OUT_PATH}" 2>/dev/null || true
      else
        rm -f "${OUT_PATH}"
      fi
    elif [[ -n "${OUT_PATH_BACKUP}" ]]; then
      rm -f "${OUT_PATH_BACKUP}" 2>/dev/null || true
    fi

    echo "setup-codex-workspace.sh failed (exit ${exit_code}); attempted to restore previous workspace state." >&2
  else
    if [[ -n "${OUT_PATH_BACKUP}" && -f "${OUT_PATH_BACKUP}" ]]; then
      rm -f "${OUT_PATH_BACKUP}"
    fi
  fi
}

trap 'cleanup_on_exit' EXIT

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "${1}" in
    -o|--output)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for ${1}" >&2
        exit 1
      fi
      OUT_PATH="${2}"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -* )
      echo "Unknown option '${1}'" >&2
      exit 1
      ;;
    *)
      POSITIONAL+=("${1}")
      shift
      ;;
  esac
done

if [[ ${#POSITIONAL[@]} -gt 0 ]]; then
  OUT_PATH="${POSITIONAL[0]}"
fi

if [[ -z "${OUT_PATH}" ]]; then
  OUT_PATH="${OUT_PATH_DEFAULT}"
fi

OUT_PATH_BACKUP="${OUT_PATH}.previous"
if [[ -f "${OUT_PATH}" ]]; then
  OUT_PATH_EXISTED_BEFORE=1
fi

trim_string() {
  local value="${1-}"
  while [[ "${value}" == [[:space:]]* ]]; do
    value="${value#[[:space:]]}"
  done
  while [[ "${value}" == *[[:space:]] ]]; do
    value="${value%[[:space:]]}"
  done
  printf '%s' "${value}"
}

GW_ENDPOINT="${GW_ENDPOINT:-}"
GW_NODE="${GW_NODE:-}"
GW_NODE_PORT="${GW_NODE_PORT:-}"
GW_NODE_FALLBACK_SCHEME="${GW_NODE_FALLBACK_SCHEME-https}"
GW_AUTO_TLS="${GW_AUTO_TLS:-1}"
GW_AUTO_TLS_PORTS="${GW_AUTO_TLS_PORTS:-}"
TOKEN="${K8S_TOKEN:-}"
CLUSTER_NAME="${CLUSTER_NAME:-gw-nodeport}"
USER_NAME="${USER_NAME:-codex-gw}"
CTX_NAME="${CTX_NAME:-nodeport}"
INSTALL_DIR="${KUBECTL_INSTALL_DIR:-$HOME/.local/bin}"
SKIP_INSTALL="${SKIP_KUBECTL_INSTALL:-0}"
CA_FILE="${K8S_CA_FILE:-${GW_CA_FILE:-}}"
CA_DATA_B64="${K8S_CA_DATA_B64:-${GW_CA_DATA_B64:-}}"
CA_DATA="${K8S_CA_DATA:-${GW_CA_DATA:-}}"
SCHEME_OVERRIDE="${GW_SCHEME:-}"
TLS_SERVER_NAME="${K8S_TLS_SERVER_NAME:-${GW_TLS_SERVER_NAME:-}}"
INSECURE_SKIP="${K8S_INSECURE_SKIP_TLS_VERIFY:-${GW_INSECURE_SKIP_TLS_VERIFY:-}}"
HTTPS_BRIDGE_TARGET="${HTTPS_BRIDGE_TARGET:-${K8S_HTTPS_BRIDGE_TARGET:-}}"
HTTPS_BRIDGE_LISTEN_HOST="${HTTPS_BRIDGE_LISTEN_HOST:-127.0.0.1}"
HTTPS_BRIDGE_LISTEN_PORT="${HTTPS_BRIDGE_LISTEN_PORT:-18080}"
HTTPS_BRIDGE_SNI="${HTTPS_BRIDGE_SNI:-}"
HTTPS_BRIDGE_CA_FILE="${HTTPS_BRIDGE_CA_FILE:-}"
HTTPS_BRIDGE_INSECURE="${HTTPS_BRIDGE_INSECURE:-0}"
HTTPS_BRIDGE_CONNECT_TIMEOUT="${HTTPS_BRIDGE_CONNECT_TIMEOUT:-}"
HTTPS_BRIDGE_IDLE_TIMEOUT="${HTTPS_BRIDGE_IDLE_TIMEOUT:-}"
HTTPS_BRIDGE_LOG_FILE="${HTTPS_BRIDGE_LOG_FILE:-${CONFIG_DIR}/https-bridge.log}"
HTTPS_BRIDGE_PID_FILE="${HTTPS_BRIDGE_PID_FILE:-${CONFIG_DIR}/https-bridge.pid}"
HTTPS_BRIDGE_META_FILE="${HTTPS_BRIDGE_META_FILE:-${CONFIG_DIR}/https-bridge.meta}"
PROXY_URL="${PROXY_URL:-}"
BRIDGE_LISTEN_HOST="${BRIDGE_LISTEN_HOST:-}"
BRIDGE_LISTEN_PORT="${BRIDGE_LISTEN_PORT:-}"
ACTIVE_BRIDGE_PID=""
ACTIVE_BRIDGE_TARGET=""

stop_existing_bridge_process() {
  local pid_file="${1}"
  local meta_file="${2}"
  local log_file="${3}"

  if [[ ! -f "${pid_file}" ]]; then
    return 0
  fi

  local old_pid
  old_pid="$(<"${pid_file}")"

  if [[ -n "${old_pid}" ]]; then
    if kill -0 "${old_pid}" 2>/dev/null; then
      echo "Stopping previous HTTPS bridge (pid ${old_pid})..." >&2
      if ! kill "${old_pid}" 2>/dev/null; then
        echo "Unable to signal existing HTTPS bridge (pid ${old_pid}). Remove ${pid_file} manually." >&2
        exit 1
      fi
      for _ in {1..50}; do
        if kill -0 "${old_pid}" 2>/dev/null; then
          sleep 0.1
        else
          break
        fi
      done
      if kill -0 "${old_pid}" 2>/dev/null; then
        echo "Existing HTTPS bridge (pid ${old_pid}) did not stop; sending SIGKILL." >&2
        kill -9 "${old_pid}" 2>/dev/null || true
        sleep 0.1
      fi
    fi
  fi

  rm -f "${pid_file}"
  if [[ -n "${meta_file}" ]]; then
    rm -f "${meta_file}" 2>/dev/null || true
  fi
  if [[ -n "${log_file}" ]]; then
    rm -f "${log_file}" 2>/dev/null || true
  fi
}

SERVICE_NODE_PORT_RAW="${SERVICE_NODE_PORT:-}"
if [[ -z "${GW_NODE_PORT}" && -n "${SERVICE_NODE_PORT_RAW}" ]]; then
  GW_NODE_PORT="${SERVICE_NODE_PORT_RAW}"
fi

if [[ -n "${GW_NODE_PORT}" ]]; then
  GW_NODE_PORT="$(trim_string "${GW_NODE_PORT}")"
fi

read_cached_endpoint() {
  local file="${1}"

  if [[ ! -f "${file}" ]]; then
    return 1
  fi

  local line=""
  IFS= read -r line < "${file}" || true
  line="${line%$'\r'}"
  line="$(trim_string "${line}")"

  if [[ -z "${line}" ]]; then
    return 1
  fi

  printf '%s' "${line}"
  return 0
}

extract_server_from_kubeconfig() {
  local file="${1}"

  if [[ ! -f "${file}" ]]; then
    return 1
  fi

  local value=""
  value="$(awk '
    match($0, /^[[:space:]]*server:[[:space:]]*(.+)$/, m) {
      value = m[1]
      gsub(/^[[:space:]]+/, "", value)
      gsub(/[[:space:]]+$/, "", value)
      if (length(value) >= 2 && substr(value, 1, 1) == substr(value, length(value), 1) && (substr(value, 1, 1) == "\"" || substr(value, 1, 1) == "'\''")) {
        value = substr(value, 2, length(value) - 2)
      }
      print value
      exit
    }
  ' "${file}")"

  value="${value%$'\r'}"
  value="$(trim_string "${value}")"

  if [[ -z "${value}" ]]; then
    return 1
  fi

  printf '%s' "${value}"
  return 0
}

update_endpoint_cache() {
  local value="${1}"

  if [[ -z "${value}" ]]; then
    return 0
  fi

  if [[ "${GW_ENDPOINT_CACHE_EXISTED_BEFORE}" == "1" && -z "${GW_ENDPOINT_CACHE_BACKUP}" && -f "${GW_ENDPOINT_CACHE_FILE}" ]]; then
    GW_ENDPOINT_CACHE_BACKUP="${GW_ENDPOINT_CACHE_FILE}.previous"
    cp "${GW_ENDPOINT_CACHE_FILE}" "${GW_ENDPOINT_CACHE_BACKUP}" 2>/dev/null || true
  fi

  printf '%s\n' "${value}" > "${GW_ENDPOINT_CACHE_FILE}.tmp"
  chmod 600 "${GW_ENDPOINT_CACHE_FILE}.tmp"
  mv "${GW_ENDPOINT_CACHE_FILE}.tmp" "${GW_ENDPOINT_CACHE_FILE}"
  GW_ENDPOINT_CACHE_UPDATED=1
}

mkdir -p "${CONFIG_DIR}"

stop_existing_bridge_process "${HTTPS_BRIDGE_PID_FILE}" "${HTTPS_BRIDGE_META_FILE}" "${HTTPS_BRIDGE_LOG_FILE}"

resolve_project_root() {
  local candidates=(
    "${PROJECT_PATH:-}"
    "${WORKSPACE_PROJECT_PATH:-}"
    "${CALLER_PROJECT_PATH:-}"
    "${ORIGINAL_PROJECT_PATH:-}"
    "${PWD}"
    "${ROOT_DIR}"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -n "${candidate}" && -d "${candidate}" ]]; then
      (cd "${candidate}" && pwd)
      return 0
    fi
  done
  return 1
}

PROJECT_ROOT_FOR_NOTES="$(resolve_project_root 2>/dev/null || true)"

write_bridge_metadata() {
  local meta_file="${1}"
  local listen_host="${2}"
  local listen_port="${3}"
  local target_url="${4}"

  if [[ -z "${meta_file}" ]]; then
    return 0
  fi

  cat >"${meta_file}" <<EOF
LISTEN_HOST=${listen_host}
LISTEN_PORT=${listen_port}
TARGET_URL=${target_url}
EOF
}

start_https_bridge() {
  local target_url="${1}"
  local listen_host="${2}"
  local listen_port="${3}"
  local sni_value="${4}"
  local ca_file="${5}"
  local insecure_flag="${6}"
  local connect_timeout="${7}"
  local idle_timeout="${8}"
  local log_file="${9}"
  local pid_file="${10}"
  local meta_file="${11}"

  if [[ -z "${target_url}" ]]; then
    return 0
  fi

  if [[ -n "${GW_ENDPOINT}" ]]; then
    echo "HTTPS_BRIDGE_TARGET cannot be combined with GW_ENDPOINT." >&2
    exit 1
  fi

  if [[ "${target_url}" != https://* ]]; then
    echo "HTTPS_BRIDGE_TARGET must be an https:// URL (got '${target_url}')." >&2
    exit 1
  fi

  if [[ ! -f "${SCRIPT_DIR}/https_bridge.py" ]]; then
    echo "Missing helper script ${SCRIPT_DIR}/https_bridge.py" >&2
    exit 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to launch the HTTPS bridge." >&2
    exit 1
  fi

  if [[ -f "${pid_file}" ]]; then
    local old_pid
    old_pid="$(<"${pid_file}")"
    if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
      echo "Stopping existing HTTPS bridge (pid ${old_pid})..."
      if ! kill "${old_pid}" 2>/dev/null; then
        echo "Unable to signal existing HTTPS bridge (pid ${old_pid}). Remove ${pid_file} manually." >&2
        exit 1
      fi
      for _ in {1..50}; do
        if kill -0 "${old_pid}" 2>/dev/null; then
          sleep 0.1
        else
          break
        fi
      done
      if kill -0 "${old_pid}" 2>/dev/null; then
        echo "Existing HTTPS bridge (pid ${old_pid}) did not stop; sending SIGKILL." >&2
        kill -9 "${old_pid}" 2>/dev/null || true
        sleep 0.1
      fi
    fi
    rm -f "${pid_file}"
  fi

  echo "Starting local HTTPS bridge http://${listen_host}:${listen_port} -> ${target_url}" >&2

  local args=("--listen" "${listen_host}" "--listen-port" "${listen_port}" "--target" "${target_url}" "--pid-file" "${pid_file}")

  if [[ -n "${sni_value}" ]]; then
    args+=("--sni" "${sni_value}")
  fi

  if [[ -n "${ca_file}" ]]; then
    if [[ ! -f "${ca_file}" ]]; then
      echo "HTTPS bridge CA file '${ca_file}' not found." >&2
      exit 1
    fi
    args+=("--ca-file" "${ca_file}")
  fi

  case "${insecure_flag}" in
    1|true|TRUE|True|yes|YES|Yes)
      args+=("--insecure")
      ;;
    0|false|FALSE|False|no|NO|No|'')
      ;;
    *)
      echo "Unsupported value for HTTPS_BRIDGE_INSECURE: '${insecure_flag}'" >&2
      exit 1
      ;;
  esac

  if [[ -n "${connect_timeout}" ]]; then
    args+=("--connect-timeout" "${connect_timeout}")
  fi

  if [[ -n "${idle_timeout}" ]]; then
    args+=("--idle-timeout" "${idle_timeout}")
  fi

  : > "${log_file}"
  args+=("--log-file" "${log_file}")
  nohup python3 "${SCRIPT_DIR}/https_bridge.py" "${args[@]}" >/dev/null 2>&1 &
  local bridge_pid=$!

  sleep 0.5
  if ! kill -0 "${bridge_pid}" 2>/dev/null; then
    echo "Failed to start local HTTPS bridge. Check log file: ${log_file}" >&2
    exit 1
  fi

  if [[ -f "${pid_file}" ]]; then
    ACTIVE_BRIDGE_PID="$(<"${pid_file}")"
  else
    ACTIVE_BRIDGE_PID="${bridge_pid}"
  fi

  NEW_BRIDGE_STARTED=1
  NEW_BRIDGE_PID="${ACTIVE_BRIDGE_PID}"

  ACTIVE_BRIDGE_TARGET="${target_url}"
  PROXY_URL="http://${listen_host}:${listen_port}"
  BRIDGE_LISTEN_HOST="${listen_host}"
  BRIDGE_LISTEN_PORT="${listen_port}"
  GW_ENDPOINT="${target_url}"
  SCHEME_OVERRIDE=""

  write_bridge_metadata "${meta_file}" "${listen_host}" "${listen_port}" "${target_url}"

  echo "HTTPS bridge running with pid ${ACTIVE_BRIDGE_PID}. Logs: ${log_file}" >&2
}

sync_default_kubeconfig() {
  local source_path="${1}"
  local dest_path="${2}"
  local backup_path="${3}"

  if [[ "${SYNC_DEFAULT_KUBECONFIG}" == "0" ]]; then
    return 0
  fi

  if [[ -z "${source_path}" || -z "${dest_path}" ]]; then
    return 1
  fi

  mkdir -p "$(dirname "${dest_path}")"

  if [[ -f "${dest_path}" ]]; then
    if ! cmp -s "${source_path}" "${dest_path}"; then
      cp "${dest_path}" "${backup_path}"
      DEFAULT_KUBECONFIG_BACKED_UP=1
    fi
  fi

  cp "${source_path}" "${dest_path}.tmp"
  mv "${dest_path}.tmp" "${dest_path}"
  chmod 600 "${dest_path}"
  DEFAULT_KUBECONFIG_UPDATED=1
}

update_agents_notice() {
  local project_root="${1}"
  local message="${2}"

  if [[ -z "${project_root}" ]]; then
    return 0
  fi

  if [[ ! -d "${project_root}" ]]; then
    return 0
  fi

  local -a agents_files=()
  while IFS= read -r -d '' file; do
    agents_files+=("${file}")
  done < <(find "${project_root}" -maxdepth 10 -type f -name AGENTS.md -print0 2>/dev/null)

  if [[ ${#agents_files[@]} -eq 0 ]]; then
    agents_files=("${project_root%/}/AGENTS.md")
  fi

  local message_b64
  message_b64="$(printf '%s' "${message}" | base64 -w0)"

  local marker_start="<!-- k8s-expose-apiserver-bridge -->"
  local marker_end="<!-- /k8s-expose-apiserver-bridge -->"

  for agents_file in "${agents_files[@]}"; do
    mkdir -p "$(dirname "${agents_file}")"
    python3 - "${agents_file}" "${message_b64}" "${marker_start}" "${marker_end}" <<'PY'
import base64
import sys
from pathlib import Path

path = Path(sys.argv[1])
message = base64.b64decode(sys.argv[2]).decode()
marker_start = sys.argv[3]
marker_end = sys.argv[4]

existing = path.read_text() if path.exists() else ""

block = f"{marker_start}\n{message.rstrip()}\n{marker_end}\n"

if marker_start in existing and marker_end in existing:
    prefix, _sep, rest = existing.partition(marker_start)
    _middle, _sep2, suffix = rest.partition(marker_end)
    new_content = prefix.rstrip() + "\n\n" + block + suffix.lstrip("\n")
else:
    new_content = existing.rstrip() + ("\n\n" if existing.strip() else "") + block

path.write_text(new_content)
PY
  done
}

emit_bridge_notice() {
  if [[ -z "${PROJECT_ROOT_FOR_NOTES}" ]]; then
    return 0
  fi

  if [[ -z "${ACTIVE_BRIDGE_PID}" || -z "${PROXY_URL}" ]]; then
    return 0
  fi

  local target_value="${ACTIVE_BRIDGE_TARGET:-${HTTPS_BRIDGE_TARGET:-}}"
  if [[ -z "${target_value}" ]]; then
    return 0
  fi

  local kubeconfig_path="${OUT_PATH}"

  read -r -d '' notice_body <<EOF || true
## Kubernetes API bridge

A local HTTP bridge process (PID ${ACTIVE_BRIDGE_PID}) listens on ${PROXY_URL} and forwards requests to ${target_value}. kubectl is already configured via ~/.kube/config (mirrored from ${kubeconfig_path}). The bridge keeps the Kubernetes API reachable until you stop the process or remove the pid file at '${HTTPS_BRIDGE_PID_FILE}'.
EOF

  update_agents_notice "${PROJECT_ROOT_FOR_NOTES}" "${notice_body}"
}

if [[ -n "${HTTPS_BRIDGE_TARGET}" ]]; then
  start_https_bridge "${HTTPS_BRIDGE_TARGET}" "${HTTPS_BRIDGE_LISTEN_HOST}" "${HTTPS_BRIDGE_LISTEN_PORT}" \
    "${HTTPS_BRIDGE_SNI}" "${HTTPS_BRIDGE_CA_FILE}" "${HTTPS_BRIDGE_INSECURE}" \
    "${HTTPS_BRIDGE_CONNECT_TIMEOUT}" "${HTTPS_BRIDGE_IDLE_TIMEOUT}" \
    "${HTTPS_BRIDGE_LOG_FILE}" "${HTTPS_BRIDGE_PID_FILE}" "${HTTPS_BRIDGE_META_FILE}"
fi

if [[ -z "${GW_ENDPOINT}" ]]; then
  if [[ -n "${GW_NODE}" ]]; then
    if [[ "${GW_NODE}" == *:* ]]; then
      GW_ENDPOINT="${GW_NODE}"
    else
      if [[ -n "${GW_NODE_PORT}" ]]; then
        GW_ENDPOINT="${GW_NODE}:${GW_NODE_PORT}"
      else
        fallback_scheme="$(trim_string "${GW_NODE_FALLBACK_SCHEME:-}")"
        if [[ -z "${fallback_scheme}" || "${GW_NODE}" =~ ^[0-9.]+$ ]]; then
          echo "GW_NODE_PORT not provided; refusing to assume a default port for '${GW_NODE}'." >&2
          echo "Provide GW_NODE_PORT or include the port in GW_NODE (for example 'node.example.com:30124')." >&2
          echo "Alternatively, set GW_ENDPOINT to an explicit URL." >&2
          exit 1
        fi
        echo "GW_NODE_PORT not provided; assuming ${fallback_scheme}://${GW_NODE}." >&2
        GW_ENDPOINT="${fallback_scheme}://${GW_NODE}"
      fi
    fi
  fi
fi

if [[ -z "${GW_ENDPOINT}" ]]; then
  echo "Provide GW_ENDPOINT or GW_NODE (with optional GW_NODE_PORT)." >&2
  exit 1
fi

maybe_apply_auto_scheme() {
  local endpoint="${1}"

  if [[ -z "${endpoint}" ]]; then
    return 0
  fi

  if [[ "${endpoint}" == *"://"* ]]; then
    return 0
  fi

  if [[ "${endpoint}" != *:* ]]; then
    return 0
  fi

  if [[ -n "${SCHEME_OVERRIDE}" ]]; then
    return 0
  fi

  if [[ "${GW_AUTO_TLS}" == "0" ]]; then
    return 0
  fi

  local port
  port="${endpoint##*:}"

  if [[ -z "${port}" ]]; then
    return 0
  fi

  if [[ -n "${GW_AUTO_TLS_PORTS}" ]]; then
    local IFS=','
    local candidate
    for candidate in ${GW_AUTO_TLS_PORTS}; do
      candidate="${candidate//[[:space:]]/}"
      if [[ -n "${candidate}" && "${port}" == "${candidate}" ]]; then
        SCHEME_OVERRIDE="https"
        return 0
      fi
    done
  fi

  if [[ "${port}" =~ ^[0-9]+$ ]]; then
    if [[ "${port}" == 443 ]]; then
      SCHEME_OVERRIDE="https"
      return 0
    fi

    if [[ "${port}" == 6443 ]]; then
      SCHEME_OVERRIDE="https"
      return 0
    fi

    if [[ "${port}" == *443 ]]; then
      SCHEME_OVERRIDE="https"
      return 0
    fi
  fi
}

maybe_apply_auto_scheme "${GW_ENDPOINT}"

resolve_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then
    command -v kubectl
    return 0
  fi

  if [[ -x "${INSTALL_DIR}/kubectl" ]]; then
    echo "${INSTALL_DIR}/kubectl"
    return 0
  fi

  return 1
}

DID_INSTALL=0
KUBECTL_BIN=""

ensure_kubectl() {
  local existing
  if existing="$(resolve_kubectl)"; then
    KUBECTL_BIN="${existing}"
    return 0
  fi

  if [[ "${SKIP_INSTALL}" == "1" ]]; then
    echo "kubectl not found and SKIP_KUBECTL_INSTALL=1. Aborting." >&2
    exit 1
  fi

  echo "kubectl not found; installing to ${INSTALL_DIR}..."
  mkdir -p "${INSTALL_DIR}"

  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *)
      echo "Unsupported architecture '${arch}'." >&2
      exit 1
      ;;
  esac

  local release
  release="${KUBECTL_VERSION:-$(curl -Ls https://dl.k8s.io/release/stable.txt)}"
  curl -Lo "${INSTALL_DIR}/kubectl" "https://dl.k8s.io/release/${release}/bin/linux/${arch}/kubectl"
  chmod +x "${INSTALL_DIR}/kubectl"

  DID_INSTALL=1
  KUBECTL_BIN="${INSTALL_DIR}/kubectl"

  if ! command -v kubectl >/dev/null 2>&1; then
    export PATH="${INSTALL_DIR}:${PATH}"
  fi

  echo "kubectl ${release} installed."
}

ensure_kubectl

if [[ -z "${KUBECTL_BIN:-}" ]]; then
  if KUBECTL_BIN="$(resolve_kubectl)"; then
    :
  else
    echo "Unable to locate kubectl even after installation." >&2
    exit 1
  fi
fi

KUBECTL_CMD="${KUBECTL_BIN}"

PATH_HINT=""
if [[ "${DID_INSTALL}" == "1" ]]; then
  case ":$PATH:" in
    *":${INSTALL_DIR}:"*) ;;
    *) PATH_HINT="export PATH=${INSTALL_DIR}:\$PATH" ;;
  esac
elif [[ "${KUBECTL_BIN}" == "${INSTALL_DIR}/kubectl" ]] && ! command -v kubectl >/dev/null 2>&1; then
  PATH_HINT="export PATH=${INSTALL_DIR}:\$PATH"
fi

if [[ -n "${CA_FILE}" ]]; then
  if [[ ! -f "${CA_FILE}" ]]; then
    echo "Certificate authority file '${CA_FILE}' not found." >&2
    exit 1
  fi
  CA_DATA_B64="$(base64 -w0 "${CA_FILE}")"
fi

if [[ -n "${CA_DATA}" && -z "${CA_DATA_B64}" ]]; then
  CA_DATA_B64="$(printf '%s' "${CA_DATA}" | base64 -w0)"
fi

SERVER_VALUE="${GW_ENDPOINT}"
if [[ "${SERVER_VALUE}" != http://* && "${SERVER_VALUE}" != https://* ]]; then
  if [[ -n "${SCHEME_OVERRIDE}" ]]; then
    SERVER_VALUE="${SCHEME_OVERRIDE}://${SERVER_VALUE}"
  else
    SERVER_VALUE="http://${SERVER_VALUE}"
  fi
fi

if [[ -n "${PROXY_URL}" ]]; then
  HOST_FOR_NO_PROXY="${BRIDGE_LISTEN_HOST:-127.0.0.1}"
else
  HOST_FOR_NO_PROXY="${SERVER_VALUE#*://}"
  HOST_FOR_NO_PROXY="${HOST_FOR_NO_PROXY%%/*}"
  HOST_FOR_NO_PROXY="${HOST_FOR_NO_PROXY%%:*}"
fi

if [[ "${OUT_PATH_EXISTED_BEFORE}" == "1" ]]; then
  cp "${OUT_PATH}" "${OUT_PATH_BACKUP}" 2>/dev/null || true
fi
OUT_PATH_CREATED=1

cat > "${OUT_PATH}" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: ${CLUSTER_NAME}
  cluster:
    server: ${SERVER_VALUE}
EOF

if [[ -n "${CA_DATA_B64}" ]]; then
  cat >> "${OUT_PATH}" <<EOF
    certificate-authority-data: ${CA_DATA_B64}
EOF
fi

if [[ -n "${TLS_SERVER_NAME}" ]]; then
  cat >> "${OUT_PATH}" <<EOF
    tls-server-name: ${TLS_SERVER_NAME}
EOF
fi

if [[ -n "${PROXY_URL}" ]]; then
  cat >> "${OUT_PATH}" <<EOF
    proxy-url: ${PROXY_URL}
EOF
fi

if [[ -n "${INSECURE_SKIP}" ]]; then
  case "${INSECURE_SKIP}" in
    1|true|TRUE|True|yes|YES|Yes)
      cat >> "${OUT_PATH}" <<'EOF'
    insecure-skip-tls-verify: true
EOF
      ;;
    0|false|FALSE|False|no|NO|No)
      ;;
    *)
      echo "Unsupported value for K8S_INSECURE_SKIP_TLS_VERIFY: '${INSECURE_SKIP}'" >&2
      exit 1
      ;;
  esac
fi

cat >> "${OUT_PATH}" <<EOF
users:
- name: ${USER_NAME}
EOF

if [[ -n "${TOKEN}" ]]; then
  cat >> "${OUT_PATH}" <<EOF
  user:
    token: ${TOKEN}
EOF
else
  cat >> "${OUT_PATH}" <<'EOF'
  user: {}
EOF
fi

cat >> "${OUT_PATH}" <<EOF
contexts:
- name: ${CTX_NAME}
  context:
    cluster: ${CLUSTER_NAME}
    user: ${USER_NAME}
current-context: ${CTX_NAME}
EOF

chmod 600 "${OUT_PATH}"

emit_bridge_notice

sync_default_kubeconfig "${OUT_PATH}" "${DEFAULT_KUBECONFIG_PATH}" "${DEFAULT_KUBECONFIG_BACKUP}"

cat <<EOF
Kubeconfig written to: ${OUT_PATH}
EOF

if [[ "${DEFAULT_KUBECONFIG_UPDATED}" == "1" ]]; then
  echo "Default kubeconfig synced to: ${DEFAULT_KUBECONFIG_PATH}"
  if [[ "${DEFAULT_KUBECONFIG_BACKED_UP}" == "1" ]]; then
    echo "Previous kubeconfig backed up at: ${DEFAULT_KUBECONFIG_BACKUP}"
  fi
fi

if [[ -n "${PATH_HINT}" ]]; then
  echo "Add kubectl to PATH with: ${PATH_HINT}"
fi

if [[ -n "${HOST_FOR_NO_PROXY}" ]]; then
  echo "Consider extending NO_PROXY with: ${HOST_FOR_NO_PROXY}"
fi

if [[ -n "${HTTPS_BRIDGE_TARGET}" ]]; then
  echo "HTTPS bridge proxy: ${PROXY_URL} -> ${HTTPS_BRIDGE_TARGET}"
  echo "Bridge logs: ${HTTPS_BRIDGE_LOG_FILE}"
fi

if [[ -z "${TOKEN}" ]]; then
  echo "No client token embedded; ensure the gateway injects credentials (AUTH_MODE=inject)."
else
  echo "Embedded bearer token for user '${USER_NAME}'. Protect this kubeconfig."
fi

if ! KUBECONFIG="${OUT_PATH}" "${KUBECTL_CMD}" --request-timeout=5s version >/dev/null 2>&1; then
  echo "kubectl connectivity check failed while querying the server version. Check gateway reachability and NO_PROXY settings." >&2
  exit 1
fi

if ! KUBECONFIG="${OUT_PATH}" "${KUBECTL_CMD}" --request-timeout=5s get ns >/dev/null 2>&1; then
  echo "kubectl connectivity check failed when listing namespaces. Check gateway reachability and NO_PROXY settings." >&2
  exit 1
fi
echo $(kubectl get nodes -o wide)
echo "kubectl connectivity check succeeded."
