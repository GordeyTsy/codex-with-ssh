#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR%/scripts}"
CONFIG_DIR="${ROOT_DIR}/configs"
REPORTS_DIR="${ROOT_DIR}/reports"

mkdir -p "${CONFIG_DIR}" "${REPORTS_DIR}"

log_info() {
  printf '==> %s\n' "$*"
}

log_warn() {
  printf '==> warning: %s\n' "$*" >&2
}

log_error() {
  printf '==> error: %s\n' "$*" >&2
}

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
    -*)
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

SSH_DIR="${HOME}/.ssh"
mkdir -p "${SSH_DIR}"

SSH_CONFIG_PATH="${SSH_CONFIG_PATH:-${SSH_DIR}/config}"
SSH_IDENTITY_PATH="${SSH_IDENTITY_PATH:-${CONFIG_DIR}/id-codex-ssh}"
SSH_KNOWN_HOSTS_PATH="${SSH_KNOWN_HOSTS_PATH:-${CONFIG_DIR}/ssh-known_hosts}"
SSH_INVENTORY_PATH="${SSH_INVENTORY_PATH:-${CONFIG_DIR}/ssh-hosts.json}"
SSH_REPORT_PATH="${SSH_REPORT_PATH:-${REPORTS_DIR}/ssh-inventory.md}"
SSH_BASTION_USER="${SSH_BASTION_USER:-codex}"
SSH_PROXY_URL="${SSH_PROXY_URL:-}"
SSH_PROXY_CONNECT_TIMEOUT="${SSH_PROXY_CONNECT_TIMEOUT:-20}"
SSH_PROXY_IDLE_TIMEOUT="${SSH_PROXY_IDLE_TIMEOUT:-0}"
SSH_PROXY_READ_TIMEOUT="${SSH_PROXY_READ_TIMEOUT:-0}"
SSH_GENERATED_KEY_COMMENT="${SSH_GENERATED_KEY_COMMENT:-codex@workspace}"

parse_bastion_endpoint() {
  "${PYTHON_BIN}" <<'PY'
import os
import sys
from urllib.parse import urlparse

endpoint = os.environ.get("SSH_BASTION_ENDPOINT", "").strip()
host = os.environ.get("SSH_BASTION_HOST", "").strip()
port = os.environ.get("SSH_BASTION_PORT", "").strip()

if endpoint:
    parsed = urlparse(endpoint if '://' in endpoint else f"ssh://{endpoint}")
    if parsed.hostname:
        host = parsed.hostname
    if parsed.port:
        port = str(parsed.port)
    elif parsed.path and not port:
        try:
            port = str(int(parsed.path.strip("/")))
        except Exception:
            pass

host = host.strip()
port = port.strip()
if not host:
    sys.exit("SSH bastion host is not configured (set SSH_BASTION_ENDPOINT or SSH_BASTION_HOST/SSH_BASTION_PORT).")

if not port:
    port = "22"

print(host)
print(port)
PY
}

readarray -t bastion_info < <(parse_bastion_endpoint)
if [[ ${#bastion_info[@]} -ne 2 ]]; then
  log_error "Failed to parse bastion endpoint."
  exit 1
fi
BASTION_HOST="${bastion_info[0]}"
BASTION_PORT="${bastion_info[1]}"

ensure_file_permissions() {
  local path="$1"
  local mode="$2"
  if [[ -f "${path}" ]]; then
    chmod "${mode}" "${path}"
  fi
}

write_private_key() {
  local key_path="$1"
  local content="$2"
  printf '%s\n' "${content}" >"${key_path}.tmp"
  chmod 600 "${key_path}.tmp"
  mv "${key_path}.tmp" "${key_path}"
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
else
  if [[ -z "${SSH_KEY:-}" ]]; then
    log_error "SSH_KEY is not set. Export SSH_KEY or run with --generate-key."
    exit 1
  fi
  log_info "Writing SSH key to ${SSH_IDENTITY_PATH}"
  write_private_key "${SSH_IDENTITY_PATH}" "${SSH_KEY%$'\r'}"
  if [[ -f "${SSH_IDENTITY_PATH}.pub" ]]; then
    chmod 600 "${SSH_IDENTITY_PATH}.pub"
  fi
fi

ensure_file_permissions "${SSH_IDENTITY_PATH}" 600

KNOWN_HOSTS_TMP="$(mktemp)"
cleanup_tmp() {
  rm -f "${KNOWN_HOSTS_TMP}"
}
trap cleanup_tmp EXIT

if [[ -f "${SSH_KNOWN_HOSTS_PATH}" ]]; then
  cat "${SSH_KNOWN_HOSTS_PATH}" >>"${KNOWN_HOSTS_TMP}" 2>/dev/null || true
fi

if command -v ssh-keyscan >/dev/null 2>&1; then
  log_info "Refreshing bastion host key (${BASTION_HOST}:${BASTION_PORT})"
  if ssh-keyscan -p "${BASTION_PORT}" -H "${BASTION_HOST}" >>"${KNOWN_HOSTS_TMP}" 2>/dev/null; then
    true
  else
    log_warn "Failed to retrieve bastion host key via ssh-keyscan."
  fi
else
  log_warn "ssh-keyscan not available; skipping host key refresh."
fi

if [[ -s "${KNOWN_HOSTS_TMP}" ]]; then
  sort -u "${KNOWN_HOSTS_TMP}" >"${SSH_KNOWN_HOSTS_PATH}.tmp"
  chmod 600 "${SSH_KNOWN_HOSTS_PATH}.tmp"
  mv "${SSH_KNOWN_HOSTS_PATH}.tmp" "${SSH_KNOWN_HOSTS_PATH}"
else
  : >"${SSH_KNOWN_HOSTS_PATH}"
  chmod 600 "${SSH_KNOWN_HOSTS_PATH}"
fi

build_bastion_block() {
  local proxy_line=""
  if [[ -n "${SSH_PROXY_URL}" ]]; then
    proxy_line="    ProxyCommand /usr/bin/env python3 ${SCRIPT_DIR}/connect_via_proxy.py --proxy=${SSH_PROXY_URL} --destination-host %h --destination-port %p --connect-timeout ${SSH_PROXY_CONNECT_TIMEOUT}"
    if [[ "${SSH_PROXY_IDLE_TIMEOUT}" != "0" ]]; then
      proxy_line+=" --idle-timeout=${SSH_PROXY_IDLE_TIMEOUT}"
    fi
    if [[ "${SSH_PROXY_READ_TIMEOUT}" != "0" ]]; then
      proxy_line+=" --read-timeout=${SSH_PROXY_READ_TIMEOUT}"
    fi
  fi
  cat <<EOF
Host codex-ssh-bastion
    HostName ${BASTION_HOST}
    Port ${BASTION_PORT}
    User ${SSH_BASTION_USER}
    IdentityFile ${SSH_IDENTITY_PATH}
    IdentitiesOnly yes
    UserKnownHostsFile ${SSH_KNOWN_HOSTS_PATH}
    StrictHostKeyChecking yes
${proxy_line}
EOF
}

write_config_block() {
  local config_block="$1"
  local marker_begin="# >>> codex-with-ssh (managed)"
  local marker_end="# <<< codex-with-ssh (managed)"
  local tmp_file
  tmp_file="$(mktemp)"
  printf '%s\n' "${config_block}" >"${tmp_file}"
  "${PYTHON_BIN}" <<'PY' "${SSH_CONFIG_PATH}" "${marker_begin}" "${marker_end}" "${tmp_file}"
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

HOST_BLOCKS=""

log_info "Updating SSH config at ${SSH_CONFIG_PATH}"
write_config_block "$(build_bastion_block)"

fetch_inventory() {
  local output_path="$1"
  if ! command -v ssh >/dev/null 2>&1; then
    log_warn "ssh client not available; skipping inventory fetch."
    return 1
  fi
  local ssh_opts=(
    -F "${SSH_CONFIG_PATH}"
    -o BatchMode=yes
    -o ConnectTimeout=20
    codex-ssh-bastion
    -- "codex-hostctl" "export" "--format" "json"
  )
  log_info "Fetching SSH inventory from bastion"
  if ssh "${ssh_opts[@]}" >"${output_path}.tmp"; then
    mv "${output_path}.tmp" "${output_path}"
    return 0
  fi
  rm -f "${output_path}.tmp"
  return 1
}

INVENTORY_AVAILABLE=0
if fetch_inventory "${SSH_INVENTORY_PATH}"; then
  INVENTORY_AVAILABLE=1
else
  log_warn "Failed to download inventory; continuing with bastion-only config."
fi

SUMMARY_FILE="$(mktemp)"
SCAN_FILE="$(mktemp)"
CONFIG_FILE="$(mktemp)"

if [[ "${INVENTORY_AVAILABLE}" == "1" ]]; then
  INVENTORY_STATUS="available"
else
  INVENTORY_STATUS="missing"
fi

"${PYTHON_BIN}" <<'PY' "${INVENTORY_STATUS}" "${SSH_INVENTORY_PATH}" "${SSH_IDENTITY_PATH}" "${SSH_KNOWN_HOSTS_PATH}" "${SUMMARY_FILE}" "${SCAN_FILE}" "${CONFIG_FILE}" "${SSH_HOST_LABEL_OVERRIDES:-}" 
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
        if isinstance(data, dict):
            for key in ("hosts", "items", "targets", "nodes"):
                if key in data:
                    hosts_raw = data[key]
                    break
            else:
                if "name" in data:
                    hosts_raw = [data]
        elif isinstance(data, list):
            hosts_raw = data
        else:
            error_message = "некорректный формат JSON"
else:
    if status != "available":
        error_message = "не удалось получить данные"

if not isinstance(hosts_raw, list):
    hosts_raw = [hosts_raw]

result_hosts = []
seen_aliases = set()
scan_targets = {}

def pick_first(entry, *candidates):
    for name in candidates:
        value = entry.get(name)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None

for item in hosts_raw:
    if not isinstance(item, dict):
        continue
    alias = pick_first(item, "alias", "name", "host", "hostname", "target")
    if not alias:
        continue
    alias = alias.strip()
    if alias == "codex-ssh-bastion":
        continue
    if alias in seen_aliases:
        continue
    seen_aliases.add(alias)
    hostname = pick_first(item, "hostname", "host", "address", "target", "ip")
    port_raw = pick_first(item, "port", "ssh_port", "target_port")
    user = pick_first(item, "user", "username", "login")
    labels_value = item.get("labels") or item.get("tags") or item.get("groups")
    if isinstance(labels_value, str):
        labels = [labels_value.strip()]
    elif isinstance(labels_value, list):
        labels = [str(v).strip() for v in labels_value if str(v).strip()]
    else:
        labels = []
    chain_value = None
    for key in ("proxy_jump", "proxy_jumps", "jump", "jumps", "via", "chain", "hops", "path", "proxyChain"):
        if key in item:
            chain_value = item[key]
            break
    chain = []
    if chain_value:
        if isinstance(chain_value, str):
            parts = [p.strip() for p in chain_value.replace(',', ' ').split() if p.strip()]
            chain = parts
        elif isinstance(chain_value, list):
            parts = []
            for value in chain_value:
                if isinstance(value, str):
                    value = value.strip()
                    if value:
                        parts.append(value)
                elif isinstance(value, dict):
                    nested = pick_first(value, "alias", "name", "host", "hostname")
                    if nested:
                        parts.append(nested)
            chain = parts
    chain = [hop for hop in chain if hop and hop != alias]
    normalized_chain = []
    for hop in chain:
        if hop not in normalized_chain:
            normalized_chain.append(hop)
    full_chain = ["codex-ssh-bastion"]
    for hop in normalized_chain:
        if hop != "codex-ssh-bastion":
            full_chain.append(hop)
    try:
        port = int(port_raw) if port_raw else 22
    except Exception:
        port = 22
    entry = {
        "alias": alias,
        "hostname": hostname or alias,
        "port": port,
        "user": user or "",
        "labels": labels,
        "chain": full_chain,
        "comment": pick_first(item, "comment", "description", "note") or "",
    }
    if hostname:
        scan_targets[(hostname, port)] = {
            "hostname": hostname,
            "port": port,
        }
    result_hosts.append(entry)

result_hosts.sort(key=lambda item: item["alias"].lower())
scan_list = list(scan_targets.values())

lines = ["### SSH-инвентарь", ""]
if error_message:
    lines.append(f"Инвентарь недоступен: {error_message}.")
elif not result_hosts:
    lines.append("Инвентарь пуст — codex-hostctl не вернул целей.")
else:
    lines.append("| Имя | ProxyJump | Хост | Пользователь | Порт | Метки |")
    lines.append("| --- | --------- | ---- | ------------ | ---- | ----- |")
    for entry in result_hosts:
        alias = entry["alias"]
        label = label_overrides.get(alias, alias)
        chain_display = " → ".join(entry["chain"])
        hostname = entry["hostname"] or "—"
        user = entry["user"] or "—"
        port = entry["port"]
        labels = ", ".join(entry["labels"]) if entry["labels"] else "—"
        lines.append(f"| {label} | {chain_display} | {hostname} | {user} | {port} | {labels} |")
lines.extend([
    "",
    "ℹ️ Переименовать цель: `codex-hostctl rename <old> <new>`.",
])
summary_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

config_lines = []
if result_hosts:
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
        config_lines.append("    StrictHostKeyChecking yes")
        if entry["chain"]:
            config_lines.append(f"    ProxyJump {','.join(entry['chain'])}")
        config_lines.append("")
config_path.write_text("\n".join(config_lines), encoding="utf-8")

with scan_path.open("w", encoding="utf-8") as fh:
    json.dump(scan_list, fh)
PY

HOST_BLOCKS="$(<"${CONFIG_FILE}")"

if [[ -n "${HOST_BLOCKS//[[:space:]]/}" ]]; then
  write_config_block "$(build_bastion_block)

${HOST_BLOCKS}"
fi

if [[ -s "${SCAN_FILE}" ]]; then
  if command -v ssh >/dev/null 2>&1 && command -v ssh-keyscan >/dev/null 2>&1; then
    log_info "Refreshing known hosts for inventory targets"
    while IFS=$'\t' read -r host port; do
      [[ -z "${host}" ]] && continue
      if [[ -z "${port}" ]]; then
        port=22
      fi
      if ssh -F "${SSH_CONFIG_PATH}" codex-ssh-bastion -- "ssh-keyscan" -H -p "${port}" "${host}" >>"${KNOWN_HOSTS_TMP}" 2>/dev/null; then
          true
        else
          log_warn "Failed to scan host key for ${host}:${port} via bastion"
        fi
    done < <("${PYTHON_BIN}" -c 'import json,sys; data=json.load(open(sys.argv[1]));
for entry in data:
    host = entry.get("hostname")
    port = entry.get("port", 22)
    if host:
        print(f"{host}\t{port}")' "${SCAN_FILE}")
  else
    log_warn "Skipping inventory host key refresh (ssh/ssh-keyscan missing)"
  fi
fi

if [[ -s "${KNOWN_HOSTS_TMP}" ]]; then
  sort -u "${KNOWN_HOSTS_TMP}" >"${SSH_KNOWN_HOSTS_PATH}.tmp"
  chmod 600 "${SSH_KNOWN_HOSTS_PATH}.tmp"
  mv "${SSH_KNOWN_HOSTS_PATH}.tmp" "${SSH_KNOWN_HOSTS_PATH}"
fi

SUMMARY_CONTENT="$(<"${SUMMARY_FILE}")"

printf '%s' "${SUMMARY_CONTENT}" >"${SSH_REPORT_PATH}" 2>/dev/null || true

mapfile -t agents_files < <(find "${ROOT_DIR}" -name AGENTS.md -type f -print)
if [[ ${#agents_files[@]} -gt 0 ]]; then
  SUMMARY_TMP="$(mktemp)"
  printf '%s' "${SUMMARY_CONTENT}" >"${SUMMARY_TMP}"
  "${PYTHON_BIN}" <<'PY' "${SUMMARY_TMP}" "${#agents_files[@]}" "${agents_files[@]}"
import pathlib
import sys

summary_path = pathlib.Path(sys.argv[1])
count = int(sys.argv[2])
files = [pathlib.Path(p) for p in sys.argv[3:3+count]]
summary = summary_path.read_text()
marker_begin = "<!-- BEGIN CODEX SSH INVENTORY -->"
marker_end = "<!-- END CODEX SSH INVENTORY -->"
block = f"{marker_begin}\n{summary}\n{marker_end}\n"
for path in files:
    text = path.read_text()
    start = text.find(marker_begin)
    end = text.find(marker_end)
    if start != -1 and end != -1 and end >= start:
        end += len(marker_end)
        text = text[:start] + text[end:]
    if text and not text.endswith("\n"):
        text += "\n"
    path.write_text(text + block)
PY
  rm -f "${SUMMARY_TMP}"
fi

rm -f "${SUMMARY_FILE}" "${SCAN_FILE}" "${CONFIG_FILE}"

log_info "Setup complete."
