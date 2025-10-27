# Руководство для codex-with-ssh

## Обзор
- **Назначение.** Этот репозиторий поднимает SSH-бастион в namespace `codex-ssh`, чтобы Codex выходил в инфраструктуру через цепочку `Codex → https://<keen-dns-domain> → <node-ip>:<node-port> → pod ssh-bastion → внутренние сервера`.
- **Совместное использование.** Проект `codex-with-kubernetes` (namespace `k8s-gw`) остаётся отдельным — его манифесты и скрипты не трогаем внутри `codex-with-ssh`.
- **Реальные адреса.** В README используем плейсхолдеры `<keen-dns-domain>/<node-ip>/<node-port>`; конкретные значения храним только во внутренних заметках.
- **Важно.** KeenDNS работает как HTTPS reverse proxy, поэтому прямой `ssh codex@<keen-dns-domain>:443` невозможен — требуется HTTPS-тоннель.

## Скрипт развёртывания (`scripts/deploy-ssh-bastion.sh`)
1. Перед запуском выставляем переменные (см. `.env.host.example`):
   - `SSH_PUBLIC_HOST=<keen-dns-domain>` — адрес, который получит Codex.
   - `SSH_NODE_NAME=<preferred-node>`, `SSH_HOSTPATH_PATH=/srv/codex-ssh` — хост-путь для общего инвентаря.
   - `SSH_IMAGE_REGISTRY=<registry>` — реестр для образа.
2. Запускаем:
   ```bash
   set -a
   source .env.host.example
   set +a
   scripts/deploy-ssh-bastion.sh
   ```
3. Скрипт строит/публикует образ (если включено), применяет манифесты и ждёт rollout. В конце печатает ключевые строки, которые обязательно сохраняем: `SSH_GW_NODE`, `SSH_GW_USER`, `SSH_GW_TOKEN`, а также приватный ключ в PEM и однострочном (`SSH_KEY_BASE64=…`) формате. URL/логин/токен идут в переменные Codex, ключ — в секрет (`SSH_KEY_BASE64` или `SSH_KEY`).
4. Проверяем:
   - `kubectl -n codex-ssh get pods -o wide`
   - `kubectl -n codex-ssh get svc ssh-bastion -o wide`
   - `curl -i http://<node-ip>:32222/healthz` (ожидаем HTTP 200 — значит NodePort доступен)
   - `kubectl -n codex-ssh port-forward service/ssh-bastion-internal 2222:22 &` и `ssh -p 2222 codex@127.0.0.1` для прямого входа в под

## Поведение пода
- Образ слушает `22/tcp`, стартует `sshd` через `/usr/sbin/sshd -D -e`.
- В entrypoint режем дефолтный `Subsystem sftp` из `/etc/ssh/sshd_config`, чтобы не конфликтовал с конфигом из ConfigMap.
- Данные (`inventory.json`, `labels.json`) лежат в `/var/lib/codex-ssh` и монтируются как `hostPath` (`/srv/codex-ssh`). Поэтому при рестарте/пересоздании под не теряет информацию.

### Инвентарь
- Обёртки `ssh/scp/sftp` записывают в инвентарь:
  - `target` (например, `admin@10.0.0.5`)
  - `jump_chain` (включая промежуточные узлы)
  - `fingerprint`
  - временную метку `last_seen`
- MOTD формируется через `codex-hostctl motd` и показывает список хостов, например  
  `<node-alias>: admin@10.0.0.5\nrouter: admin@10.0.0.10\n<remote>: user@10.0.70.200`.
- Пользовательский alias назначается так: `kubectl -n codex-ssh exec deploy/ssh-bastion -- codex-hostctl rename keenetic-os router`.
- Список внутри Codex синхронизируется командой `codex-hostctl export`, которую вызывает workspace-скрипт.

## Codex workspace
1. В Codex:
   - Variables: `SSH_GW_NODE=<keen-dns-domain>:443`, `SSH_GW_USER=codex`, `SSH_GW_TOKEN=<token>`
   - Secret: `SSH_KEY_BASE64=<значение из вывода>` (или `SSH_KEY=<PEM>`, если удобнее).
2. Внутри контейнера выполняем:
   ```bash
   export PROJECT_PATH="$(pwd)"
   cd /workspace || true
   if [ ! -d codex-with-ssh ]; then
     git clone https://github.com/GordeyTsy/codex-with-ssh.git
   fi
   cd codex-with-ssh
   ./scripts/setup-codex-workspace.sh
   cd "$PROJECT_PATH"
   ```
3. Скрипт:
   - кладёт ключ в `configs/id-codex-ssh`;
   - прописывает `ProxyCommand`, который вызывает `scripts/ssh-http-proxy.py` и ходит к HTTPS-ендпойнту KeenDNS;
   - обновляет `~/.ssh/config` и хранит ключи в `configs/ssh-known_hosts`;
   - скачивает инвентарь (`codex-hostctl export`) и обновляет инструкции в `AGENTS.md`.
4. Сценарий выше следует добавить и в Maintanence Script, чтобы контейнер поддерживал конфигурацию после «пробуждения».

## Обслуживание
- **Образ.** Для обновлений:  
  `docker build -t registry:443/codex-ssh-bastion:latest images/ssh-bastion`  
  `docker push registry:443/codex-ssh-bastion:latest`
- **Перезапуск:** `kubectl -n codex-ssh rollout restart deployment/ssh-bastion`.
- **Проверка readiness:** `kubectl -n codex-ssh get pods` (проба — `nc` к `127.0.0.1:22` внутри пода).
- **Ключи:** если нужен кастомный `authorized_keys`, положить файл и указать `SSH_AUTHORIZED_KEYS_FILE` перед запуском скрипта.

## Диагностика
- Логи: `kubectl -n codex-ssh logs deploy/ssh-bastion -f`.
- Содержимое данных: `kubectl -n codex-ssh exec deploy/ssh-bastion -- ls -l /var/lib/codex-ssh`.
- Для ручного администрирования внутри кластера используем `ssh-bastion-internal.codex-ssh.svc.cluster.local:22`.

<!-- BEGIN CODEX SSH INVENTORY -->
### SSH inventory

Inventory unavailable: inventory endpoint returned no data.

ℹ️ Rename a target: `codex-hostctl rename <old> <new>`.

### Workspace usage

1. Open an interactive shell through the bastion: `ssh <alias>`.
2. Run a quick command: `ssh <alias> "uptime"` or any other remote command.
3. Transfer files over the tunnel: `scp ./local.txt <alias>:/tmp/`.
4. After adding new routes on the bastion, refresh the inventory with `codex-hostctl export` and rerun this helper.

Tunnel endpoint: ssh-http-proxy → https://codex-ssh.cyberspace.keenetic.link:443
ProxyCommand helper: /home/gt/projects/my/codex-with-ssh/scripts/ssh-http-proxy.py
<!-- END CODEX SSH INVENTORY -->
