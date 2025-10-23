#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR%/scripts}"

log() { printf '==> %s\n' "$*"; }
err() { printf '==> error: %s\n' "$*" >&2; }

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    err "Environment variable ${name} is required."
    exit 1
  fi
}

require_env "SSH_KEY"
require_env "SSH_GW_TOKEN"

SSH_GW_USER="${SSH_GW_USER:-codex}"
SSH_HTTP_PROXY_SCRIPT="${SSH_HTTP_PROXY_SCRIPT:-${ROOT_DIR}/scripts/ssh-http-proxy.py}"

if ! command -v python3 >/dev/null 2>&1; then
  err "python3 is required."
  exit 1
fi

if ! command -v ssh >/dev/null 2>&1; then
  err "ssh client is required."
  exit 1
fi

if [[ ! -f "${SSH_HTTP_PROXY_SCRIPT}" ]]; then
  err "Proxy helper ${SSH_HTTP_PROXY_SCRIPT} is missing."
  exit 1
fi

parse_gateway_endpoint() {
  python3 - <<'PY'
import os
import sys
from urllib.parse import urlparse

endpoint = os.environ.get("SSH_GW_NODE", "").strip() or os.environ.get("SSH_BASTION_ENDPOINT", "").strip()
if endpoint and "://" not in endpoint:
    endpoint = f"https://{endpoint}"
if not endpoint:
    host = os.environ.get("SSH_BASTION_HOST", "").strip()
    port = os.environ.get("SSH_BASTION_PORT", "").strip()
    if not host:
        sys.exit("Gateway endpoint is not configured (set SSH_GW_NODE or SSH_BASTION_HOST/SSH_BASTION_PORT).")
    port = port or "443"
    endpoint = f"https://{host}:{port}"

parsed = urlparse(endpoint)
if parsed.scheme.lower() not in {"https", "http"}:
    sys.exit("Unsupported scheme in gateway endpoint")
host = parsed.hostname
port = parsed.port or (443 if parsed.scheme == "https" else 80)
print(parsed.scheme)
print(host)
print(port)
PY
}

readarray -t gw_parts < <(parse_gateway_endpoint)
if [[ ${#gw_parts[@]} -ne 3 ]]; then
  err "Failed to parse SSH_GW_NODE."
  exit 1
fi
GW_SCHEME="${gw_parts[0]}"
GW_HOST="${gw_parts[1]}"
GW_PORT="${gw_parts[2]}"
GW_ENDPOINT="${GW_SCHEME}://${GW_HOST}:${GW_PORT}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

KEY_PATH="${TMP_DIR}/id"
printf '%s\n' "${SSH_KEY%$'\r'}" >"${KEY_PATH}"
chmod 600 "${KEY_PATH}"

CONFIG_PATH="${TMP_DIR}/ssh_config"
KNOWN_HOSTS="${TMP_DIR}/known_hosts"
touch "${KNOWN_HOSTS}"
chmod 600 "${KNOWN_HOSTS}"

cat >"${CONFIG_PATH}" <<EOF
Host bastion-http-test
    HostName 127.0.0.1
    Port 22
    User ${SSH_GW_USER}
    IdentityFile ${KEY_PATH}
    IdentitiesOnly yes
    UserKnownHostsFile ${KNOWN_HOSTS}
    StrictHostKeyChecking accept-new
    ProxyCommand python3 ${SSH_HTTP_PROXY_SCRIPT} --endpoint ${GW_ENDPOINT} --user ${SSH_GW_USER} --token ${SSH_GW_TOKEN} --target %h:%p --verbose
EOF

log "Connecting to bastion via HTTPS tunnel (${GW_ENDPOINT})"
if ssh -F "${CONFIG_PATH}" -o BatchMode=yes bastion-http-test -- "codex-hostctl list"; then
  log "SSH tunnel test succeeded."
else
  err "SSH command failed."
  exit 1
fi
