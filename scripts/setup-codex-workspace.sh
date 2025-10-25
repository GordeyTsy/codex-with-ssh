#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR%/scripts}"
CONFIG_DIR="${ROOT_DIR}/configs"

mkdir -p "${CONFIG_DIR}"

log_info() { printf '==> %s\n' "$*"; }
log_warn() { printf '==> warning: %s\n' "$*" >&2; }
log_error() { printf '==> error: %s\n' "$*" >&2; }

usage() {
  cat <<'USAGE'
Usage: ${0##*/} [options]

Options:
  -g, --generate-key    Generate a new ed25519 key pair instead of reading SSH_KEY.
  -h, --help            Show this message.
USAGE
}

GENERATE_KEY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--generate-key)
      GENERATE_KEY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -* )
      log_error "Unknown option: $1"
      usage
      exit 1
      ;;
    *)
      log_error "Unexpected argument: $1"
      usage
      exit 1
      ;;
  esac
done

PYTHON_BIN="$(command -v python3 || true)"
if [[ -z "${PYTHON_BIN}" ]]; then
  log_error "python3 is required."
  exit 1
fi

if ! command -v ssh >/dev/null 2>&1; then
  log_error "ssh client is required."
  exit 1
fi

SSH_DIR="${HOME}/.ssh"
mkdir -p "${SSH_DIR}"

SSH_CONFIG_PATH="${SSH_CONFIG_PATH:-${SSH_DIR}/config}"
SSH_IDENTITY_PATH="${SSH_IDENTITY_PATH:-${CONFIG_DIR}/id-codex-ssh}"
SSH_KNOWN_HOSTS_PATH="${SSH_KNOWN_HOSTS_PATH:-${CONFIG_DIR}/ssh-known_hosts}"
SSH_INVENTORY_PATH="${SSH_INVENTORY_PATH:-${CONFIG_DIR}/ssh-hosts.json}"
SSH_REPORT_PATH="${SSH_REPORT_PATH:-}"
SSH_BASTION_USER="${SSH_BASTION_USER:-codex}"
SSH_GENERATED_KEY_COMMENT="${SSH_GENERATED_KEY_COMMENT:-codex@workspace}"
SSH_GW_USER="${SSH_GW_USER:-codex}"
SSH_GW_TOKEN="${SSH_GW_TOKEN:-}"
SSH_HTTP_PROXY_SCRIPT="${SSH_HTTP_PROXY_SCRIPT:-${ROOT_DIR}/scripts/ssh-http-proxy.py}"
SSH_HTTP_READ_TIMEOUT="${SSH_HTTP_READ_TIMEOUT:-25}"
SSH_HOST_LABEL_OVERRIDES="${SSH_HOST_LABEL_OVERRIDES:-}"
PROJECT_ROOT_FOR_NOTES="${PROJECT_ROOT_FOR_NOTES:-${ROOT_DIR}}"
SSH_HTTP_INSECURE="${SSH_HTTP_INSECURE:-0}"
SSH_HTTP_SNI="${SSH_HTTP_SNI:-}"
SSH_HTTP_CA_FILE="${SSH_HTTP_CA_FILE:-}"

if [[ -z "${SSH_KEY:-}" ]]; then
  if [[ -n "${SSH_KEY_BASE64:-}" ]]; then
    SSH_KEY="${SSH_KEY_BASE64}"
  elif [[ -n "${SSH_KEY_B64:-}" ]]; then
    SSH_KEY="${SSH_KEY_B64}"
  fi
fi

if [[ -z "${SSH_GW_TOKEN}" ]]; then
  log_error "SSH_GW_TOKEN is not set. Provide the token from deploy-ssh-bastion.sh output."
  exit 1
fi

if [[ ! -f "${SSH_HTTP_PROXY_SCRIPT}" ]]; then
  log_error "Proxy helper ${SSH_HTTP_PROXY_SCRIPT} is missing."
  exit 1
fi

parse_gateway_endpoint() {
  "${PYTHON_BIN}" - <<'PY'
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
  log_error "Failed to parse SSH_GW_NODE."
  exit 1
fi
GW_SCHEME="${gw_parts[0]}"
GW_HOST="${gw_parts[1]}"
GW_PORT="${gw_parts[2]}"
GW_ENDPOINT="${GW_SCHEME}://${GW_HOST}:${GW_PORT}"

ensure_permissions() {
  local path="$1" mode="$2"
  if [[ -f "${path}" ]]; then
    chmod "${mode}" "${path}"
  fi
}

write_private_key() {
  local dest="$1" content="$2"
  SSH_KEY_INPUT="${content}" "${PYTHON_BIN}" - "${dest}" <<'PY'
import os
import base64
import sys
import textwrap
from pathlib import Path

dest = Path(sys.argv[1])
data = os.environ.get("SSH_KEY_INPUT", "")
data = data.replace("\r", "")
data = textwrap.dedent(data)
if "\\n" in data and "\n" not in data:
    data = data.replace("\\n", "\n")
if "BEGIN OPENSSH" not in data:
    try:
        sanitized = "".join(data.split())
        decoded = base64.b64decode(sanitized.encode("utf-8")).decode("utf-8")
    except Exception:
        decoded = data
    else:
        if "BEGIN OPENSSH" in decoded:
            data = decoded
if not data.endswith("\n"):
    data += "\n"
tmp = dest.with_suffix(dest.suffix + ".tmp")
tmp.write_text(data, encoding="utf-8")
tmp.chmod(0o600)
tmp.replace(dest)
PY
}

if [[ "${GENERATE_KEY}" == "1" ]]; then
  if [[ -f "${SSH_IDENTITY_PATH}" ]]; then
    log_info "Removing previous key at ${SSH_IDENTITY_PATH}"
    rm -f "${SSH_IDENTITY_PATH}" "${SSH_IDENTITY_PATH}.pub"
  fi
  log_info "Generating a new ed25519 key pair at ${SSH_IDENTITY_PATH}"
  ssh-keygen -t ed25519 -C "${SSH_GENERATED_KEY_COMMENT}" -f "${SSH_IDENTITY_PATH}" -N ''
  log_info "Public key follows:"
  cat "${SSH_IDENTITY_PATH}.pub"
elif [[ -n "${SSH_KEY:-}" ]]; then
  log_info "Writing SSH key to ${SSH_IDENTITY_PATH}"
  write_private_key "${SSH_IDENTITY_PATH}" "${SSH_KEY%$'\r'}"
else
  log_error "SSH_KEY is not set. Export SSH_KEY or run with --generate-key."
  exit 1
fi

ensure_permissions "${SSH_IDENTITY_PATH}" 600

mkdir -p "${SSH_DIR}"
touch "${SSH_KNOWN_HOSTS_PATH}"
chmod 600 "${SSH_KNOWN_HOSTS_PATH}"

write_config_block() {
  local content="$1"
  local marker_begin="# >>> codex-with-ssh (managed)"
  local marker_end="# <<< codex-with-ssh (managed)"
  local tmp_file
  tmp_file="$(mktemp)"
  printf '%s\n' "${content}" >"${tmp_file}"
  "${PYTHON_BIN}" - "${SSH_CONFIG_PATH}" "${marker_begin}" "${marker_end}" "${tmp_file}" <<'PY'
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
marker_begin = sys.argv[2]
marker_end = sys.argv[3]
block_path = pathlib.Path(sys.argv[4])
block = block_path.read_text()
if not block.endswith("\n"):
    block += "\n"
managed = f"{marker_begin}\n{block}{marker_end}\n"
if config_path.exists():
    text = config_path.read_text()
else:
    text = ""
start = text.find(marker_begin)
end = text.find(marker_end)
if start != -1 and end != -1 and end >= start:
    end += len(marker_end)
    text = text[:start] + text[end:]
if text and not text.endswith("\n"):
    text += "\n"
config_path.write_text(text + managed)
config_path.chmod(0o600)
PY
  rm -f "${tmp_file}"
}

PROXY_COMMAND="python3 ${SSH_HTTP_PROXY_SCRIPT} --endpoint ${GW_ENDPOINT} --user ${SSH_GW_USER} --token ${SSH_GW_TOKEN} --target %h:%p --read-timeout ${SSH_HTTP_READ_TIMEOUT}"
if [[ "${SSH_HTTP_INSECURE}" != "0" ]]; then
  PROXY_COMMAND+=" --insecure"
fi
if [[ -n "${SSH_HTTP_CA_FILE}" ]]; then
  PROXY_COMMAND+=" --ca-file ${SSH_HTTP_CA_FILE}"
fi
if [[ -n "${SSH_HTTP_SNI}" ]]; then
  PROXY_COMMAND+=" --sni ${SSH_HTTP_SNI}"
fi

build_ssh_config() {
  cat <<EOF
Host codex-ssh-bastion
    HostName 127.0.0.1
    Port 22
    User ${SSH_BASTION_USER}
    IdentityFile ${SSH_IDENTITY_PATH}
    IdentitiesOnly yes
    UserKnownHostsFile ${SSH_KNOWN_HOSTS_PATH}
    StrictHostKeyChecking accept-new
    ProxyCommand ${PROXY_COMMAND}
EOF
}

log_info "Updating SSH config at ${SSH_CONFIG_PATH}"
write_config_block "$(build_ssh_config)"

fetch_inventory() {
  local output="$1"
  log_info "Fetching SSH inventory from bastion"
  if ssh -F "${SSH_CONFIG_PATH}" -o BatchMode=yes codex-ssh-bastion -- "codex-hostctl export --format json" >"${output}.tmp" 2>"${output}.err"; then
    mv "${output}.tmp" "${output}"
    rm -f "${output}.err"
    return 0
  fi
  log_warn "Failed to download inventory; see ${output}.err for details"
  rm -f "${output}.tmp"
  return 1
}

INVENTORY_AVAILABLE=0
if fetch_inventory "${SSH_INVENTORY_PATH}"; then
  INVENTORY_AVAILABLE=1
fi

SUMMARY_FILE="$(mktemp)"
SCAN_FILE="$(mktemp)"
CONFIG_FILE="$(mktemp)"

if [[ "${INVENTORY_AVAILABLE}" == "1" ]]; then
  INVENTORY_STATUS="available"
else
  INVENTORY_STATUS="missing"
fi

"${PYTHON_BIN}" - "${INVENTORY_STATUS}" "${SSH_INVENTORY_PATH}" "${SSH_IDENTITY_PATH}" "${SSH_KNOWN_HOSTS_PATH}" "${SUMMARY_FILE}" "${SCAN_FILE}" "${CONFIG_FILE}" "${SSH_HOST_LABEL_OVERRIDES:-}" "${GW_ENDPOINT}" "${SSH_HTTP_PROXY_SCRIPT}" "${ROOT_DIR}" <<'PY'
import json
import sys
from pathlib import Path

status = sys.argv[1]
inventory_path = Path(sys.argv[2])
identity_path = sys.argv[3]
known_hosts_path = sys.argv[4]
summary_path = Path(sys.argv[5])
scan_path = Path(sys.argv[6])
config_path = Path(sys.argv[7])
label_overrides_raw = sys.argv[8]
gateway_endpoint = sys.argv[9]
proxy_script = sys.argv[10]
project_root = Path(sys.argv[11])

label_overrides = {}
for item in label_overrides_raw.split(','):
    if not item.strip():
        continue
    if '=' in item:
        key, value = item.split('=', 1)
        label_overrides[key.strip()] = value.strip()

hosts_raw = []
error_message = None
if status == "available" and inventory_path.exists():
    try:
        data = json.loads(inventory_path.read_text())
    except Exception as exc:  # noqa: BLE001
        error_message = f"не удалось распарсить JSON ({exc})"
    else:
        if isinstance(data, list):
            hosts_raw = data
        else:
            error_message = "некорректный формат JSON"
else:
    if status != "available":
        error_message = "не удалось получить данные"

result_hosts = []
scan_list = []

for item in hosts_raw:
    if not isinstance(item, dict):
        continue
    alias = item.get("id") or item.get("alias") or item.get("name")
    hostname = item.get("target")
    if not alias or not hostname:
        continue
    port = int(item.get("port", 22) or 22)
    user = item.get("user", "")
    labels = item.get("labels") or []
    if isinstance(labels, str):
        labels = [labels]
    result_hosts.append({
        "alias": alias,
        "hostname": hostname,
        "port": port,
        "user": user,
        "labels": labels,
        "chain": item.get("jump_chain", []),
        "comment": item.get("comment", ""),
    })
    scan_list.append({"hostname": hostname, "port": port})

result_hosts.sort(key=lambda item: item["alias"].lower())

lines = ["### SSH-инвентарь", ""]
if error_message:
    lines.append(f"Инвентарь недоступен: {error_message}.")
elif not result_hosts:
    lines.append("Инвентарь пуст — codex-hostctl не вернул целей.")
else:
    lines.append("| Имя | ProxyCommand | Хост | Пользователь | Порт | Метки |")
    lines.append("| --- | ------------ | ---- | ------------ | ---- | ----- |")
    for entry in result_hosts:
        alias = entry["alias"]
        label = label_overrides.get(alias, alias)
        hostname = entry["hostname"] or "—"
        user = entry["user"] or "—"
        port = entry["port"]
        labels = ", ".join(entry["labels"]) if entry["labels"] else "—"
        lines.append(f"| {label} | ssh-http-proxy | {hostname} | {user} | {port} | {labels} |")
lines.extend([
    "",
    "ℹ️ Переименовать цель: `codex-hostctl rename <old> <new>`.",
    "",
    "### Using the SSH bastion",
    "",
    "1. Run `./scripts/setup-codex-workspace.sh` whenever the workspace starts (also add it to the Maintenance script so cached restores keep the tunnel alive).",
    "2. Connect to any listed alias with `ssh <alias>` — the managed SSH config injects the HTTP tunnel automatically.",
    "3. After teaching the bastion new routes, rerun the helper so the inventory and tunnel metadata stay fresh.",
    "",
    f"Туннель: ssh-http-proxy → {gateway_endpoint}",
    f"ProxyCommand script: {proxy_script}",
])

summary_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

config_lines = []
for entry in result_hosts:
    alias = entry["alias"]
    comment = entry["comment"].strip()
    labels = entry["labels"]
    config_lines.append(f"Host {alias}")
    if comment:
        config_lines.append(f"    # {comment}")
    if labels:
        config_lines.append(f"    # Labels: {', '.join(labels)}")
    config_lines.append(f"    HostName {entry['hostname']}")
    if entry["user"]:
        config_lines.append(f"    User {entry['user']}")
    if entry["port"] and entry["port"] != 22:
        config_lines.append(f"    Port {entry['port']}")
    config_lines.append(f"    IdentityFile {identity_path}")
    config_lines.append("    IdentitiesOnly yes")
    config_lines.append(f"    UserKnownHostsFile {known_hosts_path}")
    config_lines.append("    StrictHostKeyChecking accept-new")
    if entry["chain"]:
        config_lines.append(f"    ProxyJump {','.join(entry['chain'])}")
    config_lines.append("")

config_path.write_text("\n".join(config_lines), encoding="utf-8")

with scan_path.open("w", encoding="utf-8") as fh:
    json.dump(scan_list, fh)
PY

SUMMARY_CONTENT="$(<"${SUMMARY_FILE}")"

if [[ -n "${SSH_REPORT_PATH}" ]]; then
  printf '%s' "${SUMMARY_CONTENT}" >"${SSH_REPORT_PATH}" 2>/dev/null || true
fi

update_agents_notice() {
  local project_root="$1"
  local message="$2"
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
  local summary_b64
  summary_b64="$(printf '%s' "${message}" | base64 -w0)"
  local marker_begin="<!-- BEGIN CODEX SSH INVENTORY -->"
  local marker_end="<!-- END CODEX SSH INVENTORY -->"
  for file in "${agents_files[@]}"; do
    mkdir -p "$(dirname "${file}")"
    "${PYTHON_BIN}" - "${file}" "${summary_b64}" "${marker_begin}" "${marker_end}" <<'PY'
import base64
import sys
from pathlib import Path

path = Path(sys.argv[1])
summary = base64.b64decode(sys.argv[2]).decode()
marker_begin = sys.argv[3]
marker_end = sys.argv[4]

existing = path.read_text() if path.exists() else ""
block = f"{marker_begin}\n{summary.rstrip()}\n{marker_end}\n"

if marker_begin in existing and marker_end in existing:
    prefix, _sep, rest = existing.partition(marker_begin)
    _middle, _sep2, suffix = rest.partition(marker_end)
    new_content = prefix.rstrip() + "\n\n" + block + suffix.lstrip("\n")
else:
    new_content = existing.rstrip() + ("\n\n" if existing.strip() else "") + block

path.write_text(new_content)
PY
  done
}

update_agents_notice "${PROJECT_ROOT_FOR_NOTES:-${ROOT_DIR}}" "${SUMMARY_CONTENT}"

rm -f "${SUMMARY_FILE}" "${SCAN_FILE}" "${CONFIG_FILE}"

log_info "Setup complete."
