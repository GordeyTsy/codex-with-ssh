# Руководство для codex-with-ssh

## Обзор
- **Назначение проекта.** Репозиторий `codex-with-ssh` разворачивает промежуточный SSH-шлюз внутри доверенного кластера, чтобы рабочее пространство Codex получило доступ к изолированным целям, минуя корпоративный TLS-прокси. Путь запроса: `Codex → https://codex-ssh.cyberspace.keenetic.link → узел gt-dell-730:32222 → SSH-под → конечные серверы`. Трафик до KeenDNS-узла шифруется HTTPS, далее NodePort `32222` перенаправляет поток в SSH-под, откуда ProxyJump-дирижирует к конечным хостам.
- **Правило плейсхолдеров.** Настоящие адреса (`codex-ssh.cyberspace.keenetic.link`, `192.168.1.115`, `32222`) фиксируются только в этом документе и во внутренних заметках. В README и коде используем исключительно плейсхолдеры вида `<keen-dns-domain>`, `<node-ip>`, `<node-port>`.

## Подготовка кластера
- **Переменные/секреты администрирования кластера.**
  - `SSH_NAMESPACE` – namespace для SSH-пода (по умолчанию `codex-ssh`).
  - `SSH_DEPLOYMENT_NAME` – имя deployment (по умолчанию `codex-ssh`), совпадает с rollout-таргетом.
  - `SSH_SERVICE_NAME` – сервис, публикующий pod (по умолчанию `codex-ssh`).
  - `SSH_SERVICE_TYPE` – тип сервиса (`NodePort`, `LoadBalancer`, и т.д.). Для текущей схемы оставляем `NodePort`.
  - `SSH_SERVICE_NODE_PORT` – закреплённый NodePort. Фактическое значение: `32222`.
  - `SSH_BASTION_IMAGE` – контейнерный образ SSH-бастиона (по умолчанию публичный `ghcr.io/gordeytsy/codex-ssh-bastion:latest`).
  - `SSH_IMAGE_REGISTRY` – реестр, из которого тянем образ. По умолчанию любой публичный; при on-prem override указываем `10.0.70.200/<name>:latest`.
- **Инструкции по сборке образа.**
  1. Скопировать `manifests/cm-nginx.conf.yaml` и `manifests/deploy.yaml` в рабочую директорию билда, добавить `Dockerfile` на основе `nginx:1.25-alpine`, который кладёт `nginx.conf` в `/etc/nginx/nginx.conf` и добавляет `openssh-client`.
  2. Собрать образ: `docker build -f Dockerfile -t ghcr.io/gordeytsy/codex-ssh-bastion:latest .`.
  3. Для приватного реестра выполнить `docker tag` на `10.0.70.200/<name>:latest` и `docker push` в нужное хранилище.
  4. Зафиксировать используемый тег в `SSH_BASTION_IMAGE` и при необходимости обновить `SSH_IMAGE_REGISTRY`.

## Подготовка workspace
- **Переменные и секреты Codex.**
  - `SSH_BASTION_ENDPOINT` или (`SSH_BASTION_HOST` + `SSH_BASTION_PORT`) – внешний адрес KeenDNS и NodePort; фактические значения: `codex-ssh.cyberspace.keenetic.link` и `32222`.
  - `SSH_PROXY_URL` – URL корпоративного прокси, который требуется обойти; храним как секрет.
  - `SSH_KEY` – приватный ключ доступа к SSH-поду. Обновление описано ниже.
  - Дополнительные override: `SSH_IDENTITY_PATH`, `SSH_KNOWN_HOSTS_PATH`, `SSH_CONFIG_PATH`, `SSH_HOST_LABEL_OVERRIDES` (список `alias=Label` через запятую для человекочитаемых названий в отчёте).
- **Обновление секрета `SSH_KEY`.**
  1. Сгенерировать ключ: `ssh-keygen -t ed25519 -f ./tmp/codex-ssh -C codex@workspace`.
  2. Записать публичную часть в Kubernetes secret и/или `authorized_keys` SSH-пода.
  3. В Codex workspace обновить секрет `SSH_KEY` через интерфейс Projects → Secrets.
  4. Перезапустить `setup-codex-workspace.sh`, чтобы обновить `known_hosts`, `ssh-config` и отчёт по инвентарю.

## Схема инвентаризации и переименование хостов
- Используем `scripts/setup-codex-workspace.sh` для генерации `configs/ssh-hosts.json` с цепочками `ProxyJump`.
- Команда `codex-hostctl rename <old> <new>` применяется внутри workspace, чтобы привести названия к корпоративному стандарту. Скрипт добавляет прокси-цепочки вида `codex-workspace → bastion → final-host`.
- `setup-codex-workspace.sh` автоматически добавляет в `AGENTS.md` список целей и цепочек ProxyJump; ручные корректировки вносим после запуска скрипта.

## Подсказки по логам и диагностике
- Проверить статус deployment: `kubectl -n ${SSH_NAMESPACE} rollout status deployment/${SSH_DEPLOYMENT_NAME}`.
- Убедиться в доступности NodePort: `kubectl -n ${SSH_NAMESPACE} get svc ${SSH_SERVICE_NAME} -o wide` (ожидаемый NodePort `32222`, рабочий узел `192.168.1.115`).
- Логи SSH-пода: `kubectl -n ${SSH_NAMESPACE} logs deployment/${SSH_DEPLOYMENT_NAME} -f`.
- Диагностика workspace: `ssh -J codex@codex-ssh.cyberspace.keenetic.link:32222 target-host` и `kubectl --kubeconfig=configs/kubeconfig-nodeport get nodes`.

## FAQ и обновление AGENTS
- **Как обновить этот документ?** Вносим изменения через PR, соблюдая правило про реальные адреса.
- **Что делает `setup-codex-workspace.sh`?** Скрипт подтягивает список доступных целей и цепочек ProxyJump через `codex-hostctl export`, синхронизирует `configs/ssh-hosts.json`, обновляет `AGENTS.md` и помечает активный ключ `SSH_KEY`.
- **Где искать конфигурацию ProxyJump?** После запуска скрипта сводная таблица целей доступна в `reports/ssh-inventory.md` и копируется сюда.
