# Руководство для codex-with-ssh

## Обзор
- **Назначение.** Репозиторий разворачивает SSH-бастион внутри доверенного кластера, чтобы Codex мог подключаться к внутренним целям через ProxyJump. Фактическая цепочка: `Codex → https://codex-ssh.cyberspace.keenetic.link → узел gt-dell-730:32222 → Pod ssh-bastion → целевые серверы`.
- **Плейсхолдеры.** Реальные адреса (`codex-ssh.cyberspace.keenetic.link`, `gt-dell-730`, `32222`) допускаются только в этом файле и во внутренних заметках. В README и коде используем плейсхолдеры `<keen-dns-domain>`, `<node-ip>`, `<node-port>`.

## Кластер и развёртывание
- **Базовые переменные** (см. `scripts/deploy-ssh-bastion.sh`):
  - `SSH_NAMESPACE=codex-ssh` – namespace для всех ресурсов.
  - `SSH_DEPLOYMENT_NAME=ssh-bastion`, `SSH_SERVICE_NAME=ssh-bastion`.
  - `SSH_SERVICE_TYPE=NodePort`, `SSH_SERVICE_NODE_PORT=32222` (не менять, пока KeenDNS проброшен на этот порт).
  - `SSH_PVC_NAME=codex-ssh-data`, `SSH_PVC_SIZE=1Gi`, `SSH_STORAGE_CLASS` – вручную указывать только при необходимости.
  - `SSH_BASTION_IMAGE` – тег образа без реестра (по умолчанию `codex-ssh-bastion:latest`).
  - `SSH_IMAGE_REGISTRY=ghcr.io/gordeytsy` для публичного доступа или `10.0.70.200/<name>` для on-prem.
- **Развёртывание:**
  ```bash
  SSH_AUTHORIZED_SECRET=ssh-authorized-keys \
  SSH_AUTHORIZED_KEYS_FILE=./authorized_keys \
  SSH_IMAGE_REGISTRY=ghcr.io/gordeytsy \
  SSH_BASTION_IMAGE=codex-ssh-bastion:latest \
  scripts/deploy-ssh-bastion.sh
  ```
  Скрипт применяет Namespace, PVC, ConfigMap, Deployment, Service и, при наличии `SSH_AUTHORIZED_KEYS_FILE`, переупаковывает секрет `authorized_keys`.
- **Проверки после деплоя:**
  - `kubectl -n codex-ssh rollout status deployment/ssh-bastion`
  - `kubectl -n codex-ssh get svc ssh-bastion -o wide` (ожидаемый NodePort `32222`).
  - `ssh -p 32222 codex@192.168.1.115` – быстрая проверка с KeenDNS-балансером.

## Секрет `authorized_keys`
1. Генерация ключей: `ssh-keygen -t ed25519 -f ./tmp/codex-ssh -C codex@workspace`.
2. Обновление секрета:
   ```bash
   kubectl -n codex-ssh create secret generic ssh-authorized-keys \
     --from-file=authorized_keys=./tmp/codex-ssh.pub --dry-run=client -o yaml | kubectl apply -f -
   ```
3. При необходимости: `kubectl -n codex-ssh rollout restart deployment/ssh-bastion`.
4. Логи: `kubectl -n codex-ssh logs deployment/ssh-bastion -f` (entrypoint сообщает о правах и наличии ключей).

## Инвентарь и `codex-hostctl`
- Файлы `/var/lib/codex-ssh/inventory.json` и `/var/lib/codex-ssh/labels.json` лежат на PVC.
- Обёртки `ssh/scp/sftp` автоматически вызывают `codex-hostctl record`, собирая `target`, `jump_chain`, `port`, `fingerprint`.
- Основные команды:
  - `kubectl -n codex-ssh exec deploy/ssh-bastion -- codex-hostctl list`
  - `kubectl -n codex-ssh exec deploy/ssh-bastion -- codex-hostctl export`
  - `kubectl -n codex-ssh exec deploy/ssh-bastion -- codex-hostctl rename srv-01:22 prod-srv-01`
- MOTD в контейнере формируется `codex-hostctl motd` и напоминает об этих командах.

## Workspace Codex
- Секреты: `SSH_KEY` (приватный ключ), опционально `SSH_PROXY_URL`.
- Переменные: `SSH_BASTION_ENDPOINT=https://codex-ssh.cyberspace.keenetic.link:32222` или пара `SSH_BASTION_HOST`/`SSH_BASTION_PORT`.
- Рабочие скрипты должны периодически выполнять `kubectl exec ... codex-hostctl export`, чтобы синхронизировать список целей.
- Для переименования целей используем `codex-hostctl rename` внутри кластера; метки сохраняются на PVC и переживают рестарты.

## Обновление образа
- Исходники образа – `images/ssh-bastion/` (Dockerfile, entrypoint, скрипты).
- Сборка и публикация:
  ```bash
  docker build -t "${SSH_IMAGE_REGISTRY:-ghcr.io/gordeytsy}/codex-ssh-bastion:latest" images/ssh-bastion
  docker push "${SSH_IMAGE_REGISTRY:-ghcr.io/gordeytsy}/codex-ssh-bastion:latest"
  ```
- После загрузки в реестр выполните `kubectl -n codex-ssh rollout restart deployment/ssh-bastion`.

## Диагностика
- `kubectl -n codex-ssh logs deployment/ssh-bastion -f`
- `kubectl -n codex-ssh exec deploy/ssh-bastion -- ls -l /var/lib/codex-ssh`
- `ssh -J codex@codex-ssh.cyberspace.keenetic.link:32222 target-host` – проверка ProxyJump из workspace.
