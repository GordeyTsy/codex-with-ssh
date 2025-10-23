# Codex SSH Bastion

*English documentation is available in [README.md](README.md).*

Репозиторий разворачивает SSH-бастион внутри доверенного кластера Kubernetes и предоставляет образ с телеметрией, который запоминает все цепочки `ProxyJump`. Один скрипт на стороне администратора создаёт/обновляет ресурсы и выводит настройки для Codex; второй скрипт внутри workspace устанавливает ключ и синхронизирует инвентарь.

---

## 1. Состав репозитория

- **Исходники образа** – [`images/ssh-bastion/`](images/ssh-bastion/) включает Dockerfile, entrypoint, обёртки `ssh/scp/sftp` и CLI `codex-hostctl`.
- **Шаблоны манифестов** – [`manifests/ssh-bastion/`](manifests/ssh-bastion/) содержит Namespace, ConfigMap, Deployment и Service (рендерятся через `envsubst`).
- **Скрипт администратора** – [`scripts/deploy-ssh-bastion.sh`](scripts/deploy-ssh-bastion.sh) по желанию собирает/публикует образ, применяет манифесты, ожидает rollout и печатает итоговые значения `SSH_GW_NODE` и `SSH_KEY`.
- **Скрипт внутри Codex** – [`scripts/setup-codex-workspace.sh`](scripts/setup-codex-workspace.sh) размещает ключ, обновляет `~/.ssh/config`, подключает HTTP-тоннель и актуализирует инструкции в `AGENTS.md`.

---

## 2. Развёртывание на хосте

Требуется `kubectl`, `envsubst`, а при сборке/публикации образа – `docker`.

1. Настройте переменные (см. [.env.host.example](.env.host.example)):
   - `SSH_PUBLIC_HOST` – внешний адрес, доступный из Codex (например, `<keen-dns-domain>` с проброшенным NodePort).
   - `SSH_SERVICE_NODE_PORT` – порт узла, который пробрасывает KeenDNS/роутер.
   - `SSH_STORAGE_TYPE` и `SSH_HOSTPATH_PATH` – выберите `hostpath`, если нужно хранить данные на конкретном узле (`/srv/codex-ssh` и т.п.).
2. Выполните скрипт:

   ```bash
   set -a
   source .env.host.example
   set +a
   scripts/deploy-ssh-bastion.sh
   ```

   По завершении будет выведено:

   ```text
   SSH_GW_NODE=<keen-dns-domain>:443
   SSH_GW_USER=codex
   SSH_GW_TOKEN=<сгенерированный-токен>
   SSH_KEY=-----BEGIN OPENSSH PRIVATE KEY-----…
   ```

   Сохраните эти строки — `SSH_GW_NODE`/`SSH_GW_USER`/`SSH_GW_TOKEN` станут переменными в Codex, а `SSH_KEY` — секретом. KeenDNS слушает порт 443, поэтому Codex, требующий TLS-friendly `CONNECT`, сможет дотянуться до бастиона. Прямое `ssh codex@<keen-dns-domain>:443` работать не будет — требуется HTTPS-тоннель.

3. Проверьте состояние:

   ```bash
   kubectl -n codex-ssh get pods -o wide
   kubectl -n codex-ssh get svc ssh-bastion -o wide
  curl -i http://<node-ip>:32222/healthz   # ожидаем HTTP 200 — значит NodePort виден
   kubectl -n codex-ssh port-forward service/ssh-bastion-internal 2222:22 &
   ssh -p 2222 codex@127.0.0.1      # по завершении остановите port-forward (Ctrl+C)
   ```

   При успешном подключении MOTD покажет известные цели. Если контейнер Codex восстановился из кеша, запустите помощник ещё раз вручную, если он не добавлен в Maintenance script.

### 3.1 Альтернативные варианты HTTPS

- Если в кластере доступен `LoadBalancer`, задайте `SSH_SERVICE_TYPE=LoadBalancer`, а также `SSH_PUBLIC_HOST`/`SSH_PUBLIC_PORT` с фактическим внешним адресом.
- Либо поднимите Ingress, выдайте ему TLS-сертификат и установите `SSH_PUBLIC_HOST=<ingress-host>` (при необходимости измените `SSH_PUBLIC_SCHEME`).

Сценарий в Codex остаётся прежним: `setup-codex-workspace.sh` подключает HTTP-тоннель до указанного HTTPS-адреса.

---

## 3. Настройка Codex workspace

1. В **Settings → Variables** добавьте:
   - `SSH_GW_NODE=<keen-dns-domain>:443` (порт 443 проходит через корпоративный прокси, который разрешает только TLS-тоннели).
   - `SSH_GW_USER=codex`
   - `SSH_GW_TOKEN=<токен из вывода скрипта>`
   - *(опционально)* `SSH_HTTP_INSECURE=1`, если у HTTPS-ендпойнта самоподписанный сертификат или не совпадает имя хоста.
2. В **Settings → Secrets** добавьте `SSH_KEY=<приватный ключ из вывода скрипта>`.
3. Внутри контейнера выполните:

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

   Помощник положит ключ в `configs/id-codex-ssh`, пропишет `ProxyCommand`, который вызывает `scripts/ssh-http-proxy.py`, обновит `~/.ssh/config`, скачает инвентарь и добавит инструкцию в найденные `AGENTS.md`.

4. Для долгоживущих окружений поместите ту же последовательность в **Maintenance script**, чтобы конфигурация обновлялась после «пробуждения» контейнера.

### 3.1 Быстрый тест внутри Codex workspace

После подготовки конфигурации выполните из контейнера Codex smoke-тест:

```bash
cd /workspace/codex-with-ssh
./scripts/test-http-tunnel.sh
```

Скрипт формирует временный `ssh_config` с `ProxyCommand`, использующим `scripts/ssh-http-proxy.py`, и запускает `codex-hostctl list` через бастион. При любой сетевой или аутентификационной ошибке он завершится с ненулевым кодом и выведет подробности — удобно привязать его к шагу **Tests** Codex workspace.

---

## 4. Настраиваемые переменные

| Переменная | Назначение | Значение по умолчанию |
| --- | --- | --- |
| `SSH_NAMESPACE` | Namespace для всех объектов. | `codex-ssh` |
| `SSH_DEPLOYMENT_NAME` | Имя Deployment. | `ssh-bastion` |
| `SSH_SERVICE_NAME` | Имя Service. | `ssh-bastion` |
| `SSH_SERVICE_TYPE` | Режим экспонирования (`NodePort`/`LoadBalancer`/`ClusterIP`). | `NodePort` |
| `SSH_SERVICE_PORT` | Порт сервиса, который обслуживает HTTP-тоннель. | `80` |
| `SSH_SERVICE_NODE_PORT` | NodePort на узлах (используется при `NodePort`). | `32222` |
| `SSH_PUBLIC_HOST` | Внешний DNS (KeenDNS и т.п.), который смотрит на NodePort. | — |
| `SSH_PUBLIC_PORT` | Порт, опубликованный во внешнем DNS/прокси. | `443` |
| `SSH_PUBLIC_SCHEME` | Схема, которую нужно использовать в URL. | `https` |
| `SSH_HTTP_TUNNEL_PORT` | Порт контейнера, на котором слушает HTTP-шлюз. | `8080` |
| `SSH_HTTP_INSECURE` | Установите `1`, чтобы помощник игнорировал проверки TLS (например, при самоподписанном сертификате). | `0` |
| `SSH_HTTP_SNI` | Переопределяет SNI/Host, который используется прокси-скриптом. | — |
| `SSH_HTTP_CA_FILE` | Путь до пользовательского CA-бандла для прокси-скрипта. | — |
| `SSH_TUNNEL_SECRET_NAME` | Название секрета с `user:token`. | `ssh-bastion-tunnel` |
| `SSH_TUNNEL_USER` | Имя пользователя туннеля. | `codex` |
| `SSH_TUNNEL_TOKEN` | Фиксированный токен (пусто — сгенерировать автоматически). | — |
| `SSH_STORAGE_TYPE` | Тип хранилища (`auto`/`pvc`/`hostpath`). | `auto` |
| `SSH_HOSTPATH_PATH` | Каталог на узле (только для `hostpath`). | — |
| `SSH_IMAGE_REGISTRY` | Реестр, куда публикуется образ. | — |
| `SSH_BUILD_IMAGE` / `SSH_PUSH_IMAGE` | Управляют локальной сборкой/публикацией образа. | `auto` / зависит от реестра |
| `SSH_GENERATE_WORKSPACE_KEY` | Генерация `authorized_keys`, если секрет отсутствует. | `auto` |
| `SSH_MOTD_CONTENT` | Статический заголовок MOTD. | Текст по умолчанию |

## 5. Что делает бастион

- Обёртки `ssh/scp/sftp` перехватывают параметры `ProxyJump`, строят цепочку прыжков и записывают данные в `/var/lib/codex-ssh/inventory.json`.
- MOTD выводит все известные цели в формате `alias: user@host`; новые подключения автоматически пополняют список.
- Для ручного обслуживания внутри кластера можно использовать сервис `ssh-bastion-internal.codex-ssh.svc.cluster.local:22` (например, развернуть debug-под и подключиться командой `ssh codex@ssh-bastion-internal.codex-ssh.svc.cluster.local`).
- CLI `codex-hostctl` внутри пода:
  - `codex-hostctl list` – табличный список.
  - `codex-hostctl export` – JSON, который читает рабочий скрипт.
  - `codex-hostctl rename <id> <имя>` – переименование (например, `KeeneticOS` → `router`).
  - `codex-hostctl motd` – генерация баннера.
- Инвентарь хранится на PVC/hostPath, поэтому данные сохраняются между рестартами. Для нескольких реплик используйте общее хранилище (PVC), иначе список будет локальным для каждого пода.

---

## 6. Обслуживание

- **Ротация ключей** – перезапустите `deploy-ssh-bastion.sh`. При `SSH_GENERATE_WORKSPACE_KEY=auto` новая пара создаётся, если секрет отсутствует. Чтобы использовать свой ключ, перед запуском задайте `SSH_AUTHORIZED_KEYS_FILE=<путь>`.
- **Ротация токена туннеля** – установите `SSH_TUNNEL_TOKEN=<новый-токен>` перед запуском скрипта; иначе будет использован существующий секрет, и его значение снова появится в выводе.
- **Обновление образа** – включите `SSH_BUILD_IMAGE=true` или задайте `SSH_IMAGE_REGISTRY=<registry>` для публикации. Скрипт сам перезапускает Deployment.
- **Диагностика** – `kubectl -n codex-ssh logs deploy/ssh-bastion` показывает логи; проверка готовности — простой TCP check на 22 порт.

---

## 7. Удаление

```bash
kubectl -n codex-ssh delete deployment/ssh-bastion service/ssh-bastion service/ssh-bastion-internal \
  configmap/ssh-bastion-config secret/ssh-authorized-keys
kubectl -n codex-ssh delete pvc/codex-ssh-data   # пропустите для hostPath
# Необязательно: kubectl delete namespace codex-ssh
```

При использовании hostPath удалите директорию на узле вручную.
