#!/usr/bin/env bash
set -euo pipefail

umask 077

DATA_DIR="${DATA_DIR:-/var/lib/codex-ssh}"
WRAPPER_HOME="${WRAPPER_HOME:-/opt/codex-ssh}"
ORIGINAL_DIR="${WRAPPER_HOME}/originals"
CONFIG_DIR="/config/configmap"
AUTH_DIR="/config/authorized_keys"
MOTD_DIR="/config/motd"
CODex_USER="codex"
CODex_HOME="/home/${CODex_USER}"

log() {
  echo "[entrypoint] $*" >&2
}

ensure_file() {
  local path="$1" content="$2" owner="$3" mode="$4"
  if [ ! -s "$path" ]; then
    printf '%s' "$content" >"$path"
  fi
  chown "$owner" "$path"
  chmod "$mode" "$path"
}

log "Preparing data directory ${DATA_DIR}"
mkdir -p "${DATA_DIR}"
chown -R ${CODex_USER}:${CODex_USER} "${DATA_DIR}"
chmod 700 "${DATA_DIR}"

ensure_file "${DATA_DIR}/inventory.json" "[]" "${CODex_USER}:${CODex_USER}" 600
ensure_file "${DATA_DIR}/labels.json" "{}" "${CODex_USER}:${CODex_USER}" 600

# On some hostPath volumes files may keep stale ownership after container
# recreation (for example when an earlier image wrote them as root:root).
# Normalize permissions to keep codex-hostctl readable/writable.
find "${DATA_DIR}" -maxdepth 1 -type f -exec chown "${CODex_USER}:${CODex_USER}" {} +
find "${DATA_DIR}" -maxdepth 1 -type f -exec chmod 600 {} +
chown "${CODex_USER}:${CODex_USER}" "${DATA_DIR}"
chmod 700 "${DATA_DIR}"

if [ -d "${AUTH_DIR}" ]; then
  AUTH_FILE="${AUTH_DIR}/authorized_keys"
  if [ -s "$AUTH_FILE" ]; then
    log "Installing authorized_keys"
    install -d -m 700 -o ${CODex_USER} -g ${CODex_USER} "${CODex_HOME}/.ssh"
    install -m 600 -o ${CODex_USER} -g ${CODex_USER} "$AUTH_FILE" "${CODex_HOME}/.ssh/authorized_keys"
  else
    log "Warning: authorized_keys file is missing or empty" >&2
  fi
else
  log "Warning: authorized_keys secret is not mounted" >&2
fi

if [ -d "${CONFIG_DIR}" ]; then
  if [ -f "${CONFIG_DIR}/sshd_config" ]; then
    log "Installing sshd configuration snippet"
    install -d -m 755 /etc/ssh/sshd_config.d
    install -m 600 "${CONFIG_DIR}/sshd_config" /etc/ssh/sshd_config.d/50-codex.conf
  fi
  if [ -f "${CONFIG_DIR}/motd" ]; then
    cp "${CONFIG_DIR}/motd" /etc/motd.base
  fi
fi

# Debian ships a default 'Subsystem sftp' directive; drop it so our snippet can
# redefine the subsystem without triggering duplicate errors.
if grep -qE '^[[:space:]]*Subsystem[[:space:]]+sftp' /etc/ssh/sshd_config; then
  log "Removing default sftp subsystem from sshd_config"
  sed -i -E '/^[[:space:]]*Subsystem[[:space:]]+sftp/d' /etc/ssh/sshd_config
fi

if [ -d "${MOTD_DIR}" ]; then
  chown ${CODex_USER}:${CODex_USER} "${MOTD_DIR}"
fi

if [ -f /etc/motd.base ]; then
  CODEX_SSH_MOTD=$(cat /etc/motd.base)
  export CODEX_SSH_MOTD
fi

log "Ensuring wrapper binaries"
for tool in ssh scp sftp; do
  original="/usr/bin/${tool}"
  backup="${ORIGINAL_DIR}/${tool}"
  if [ -x "$original" ] && [ ! -e "$backup" ]; then
    mv "$original" "$backup"
  fi
  ln -sf "${WRAPPER_HOME}/bin/${tool}" "$original"
done

log "Generating host keys if needed"
ssh-keygen -A

if command -v update-motd >/dev/null 2>&1; then
  update-motd --disable
fi

log "Rendering MOTD"
if command -v codex-hostctl >/dev/null 2>&1; then
  if ! codex-hostctl motd >/etc/motd.new; then
    log "codex-hostctl motd failed; falling back to base message"
    cp /etc/motd.base /etc/motd.new 2>/dev/null || true
  fi
  mv /etc/motd.new /etc/motd
  chmod 644 /etc/motd
fi

install -d -m 755 /run/sshd

HTTP_TUNNEL_BIN="${WRAPPER_HOME}/bin/http_tunnel_server.py"
if [ -x "${HTTP_TUNNEL_BIN}" ]; then
  log "Starting HTTP tunnel server on ${HTTP_TUNNEL_LISTEN_HOST:-0.0.0.0}:${HTTP_TUNNEL_LISTEN_PORT:-8080}"
  python3 "${HTTP_TUNNEL_BIN}" &
fi

log "Starting sshd"
exec /usr/sbin/sshd -D -e
