# Codex SSH Bastion

*English documentation is available in [README.md](README.md).*

Репозиторий разворачивает SSH-бастион в кластере Kubernetes и включает готовый контейнерный образ с учётом требований Codex.

## 1. Состав
- **Образ** – каталог [`images/ssh-bastion/`](images/ssh-bastion/) содержит Dockerfile, entrypoint, CLI `codex-hostctl` и обёртки `ssh/scp/sftp`.
- **Манифесты** – шаблоны в [`manifests/ssh-bastion/`](manifests/ssh-bastion/) описывают Namespace, PVC, ConfigMap, Deployment и Service. Они параметризуются скриптом `deploy-ssh-bastion.sh`.
- **Хранилище** – по умолчанию используется PVC (`/var/lib/codex-ssh`), который хранит инвентарь подключений и пользовательские метки. При необходимости PVC можно заменить на директорию узла (`hostPath`).
- **Скрипты** – [`scripts/deploy-ssh-bastion.sh`](scripts/deploy-ssh-bastion.sh) применяет манифесты, при необходимости обновляет секрет `authorized_keys` и выводит подсказки по проверке.

## 2. Поведение контейнера
Entry-point выполняет:
1. Создание системного пользователя `codex`, подготовку директории `/var/lib/codex-ssh` с правами `0700` и файлов `inventory.json`, `labels.json`.
2. Копирование ключей из секрета Kubernetes в `~codex/.ssh/authorized_keys` (права `600`).
3. Перенос оригинальных бинарей `ssh`, `scp`, `sftp` в `/opt/codex-ssh/originals/` и замена их обёртками, которые перед запуском клиента записывают параметры подключения в инвентарь.
4. Применение сниппета `sshd_config` из ConfigMap, генерация host-ключей (`ssh-keygen -A`) и обновление MOTD через `codex-hostctl motd`.
5. Запуск OpenSSH (`/usr/sbin/sshd -D -e`). В конфигурации отключены парольная аутентификация, root-доступ и X11; разрешён только пользователь `codex` и `internal-sftp`.

### 2.1 CLI `codex-hostctl`
- `codex-hostctl record` – служебная команда, вызываемая обёртками для фиксации подключения.
- `codex-hostctl list` – табличный список (id, имя, цель, порт, цепочка jump, fingerprint, `last_seen`).
- `codex-hostctl export` – JSON для синхронизации с рабочим пространством.
- `codex-hostctl rename <id> <name>` – присвоение читаемого имени (пустое значение удаляет метку).
- `codex-hostctl motd` – текст для `/etc/motd` (используется entry-point’ом).

## 3. Развёртывание
```bash
SSH_NAMESPACE=codex-ssh \
SSH_SERVICE_NODE_PORT=32222 \
SSH_IMAGE_REGISTRY=ghcr.io/gordeytsy \
SSH_BASTION_IMAGE=codex-ssh-bastion:latest \
SSH_AUTHORIZED_SECRET=ssh-authorized-keys \
scripts/deploy-ssh-bastion.sh
```

Скрипт создаёт временные файлы, прогоняет их через `envsubst` и применяет `kubectl apply`. Если секрет `authorized_keys` отсутствует, скрипт сгенерирует новую пару ключей `ed25519` (тип можно изменить) и выведет приватный ключ, который нужно сохранить в секрет Codex. При наличии `SSH_AUTHORIZED_KEYS_FILE` секрет перегенерируется из указанного файла вместо генерации ключа.

### 3.1 Переменные окружения
| Переменная | Значение по умолчанию | Описание |
| --- | --- | --- |
| `SSH_NAMESPACE` | `codex-ssh` | Namespace для всех объектов. |
| `SSH_DEPLOYMENT_NAME` | `ssh-bastion` | Имя Deployment. |
| `SSH_SERVICE_NAME` | `ssh-bastion` | Имя Service. |
| `SSH_SERVICE_TYPE` | `NodePort` | Тип сервиса (`NodePort`, `LoadBalancer`, `ClusterIP`). |
| `SSH_SERVICE_NODE_PORT` | `32222` | Фиксированный NodePort; используется только при `SSH_SERVICE_TYPE=NodePort`. |
| `SSH_NODE_NAME` | — | Привязка пода к конкретному узлу. Оставьте пустым, чтобы полагаться на планировщик. |
| `SSH_PVC_NAME` | `codex-ssh-data` | Имя PersistentVolumeClaim. |
| `SSH_PVC_SIZE` | `1Gi` | Запрашиваемый объём диска. |
| `SSH_STORAGE_CLASS` | — | StorageClass. Оставьте пустым для значения по умолчанию. |
| `SSH_STORAGE_TYPE` | `pvc` | Тип хранилища (`pvc` или `hostpath`). |
| `SSH_HOSTPATH_PATH` | — | Путь на узле для `hostPath` (обязателен при `SSH_STORAGE_TYPE=hostpath`). |
| `SSH_CONFIGMAP_NAME` | `ssh-bastion-config` | Имя ConfigMap с MOTD и `sshd_config`. |
| `SSH_AUTHORIZED_SECRET` | `ssh-authorized-keys` | Секрет с публичными ключами. |
| `SSH_BASTION_IMAGE` | `codex-ssh-bastion:latest` | Имя и тег образа без префикса реестра. |
| `SSH_IMAGE_REGISTRY` | — | Префикс реестра (`registry.example.com/team`). |
| `SSH_MOTD_CONTENT` | `Codex SSH bastion\nИспользуйте codex-hostctl list, чтобы увидеть найденные цели.` | Базовое сообщение MOTD. |
| `SSH_AUTHORIZED_KEYS_FILE` | — | Путь до `authorized_keys`; при указании секрет обновится автоматически. |
| `SSH_GENERATE_WORKSPACE_KEY` | `auto` | Управление генерацией ключа для Codex (`auto`, `true`, `false`). |
| `SSH_WORKSPACE_KEY_TYPE` | `ed25519` | Тип ключа при генерации (`ed25519`, `rsa`, ...). |
| `SSH_WORKSPACE_KEY_COMMENT` | `codex@workspace` | Комментарий, добавляемый к сгенерированному ключу. |

При `SSH_STORAGE_TYPE=hostpath` скрипт пропускает создание PVC и монтирует указанную директорию узла напрямую.

## 4. Обновление `authorized_keys`
1. По умолчанию скрипт развёртывания создаёт новую пару ключей, если секрет `authorized_keys` отсутствует, и выводит приватный ключ для секрета Codex (`SSH_KEY`).
2. Чтобы управлять секретом вручную, подготовьте файл с публичными ключами.
3. Выполните:
   ```bash
   kubectl -n ${SSH_NAMESPACE:-codex-ssh} create secret generic ${SSH_AUTHORIZED_SECRET:-ssh-authorized-keys} \
     --from-file=authorized_keys=./authorized_keys --dry-run=client -o yaml | kubectl apply -f -
   ```
4. При необходимости перезапустите Deployment (`kubectl rollout restart`). Entry-point проверит наличие и права файла; сообщения об ошибках появятся в `kubectl logs`.

## 5. Инвентарь и переименования
- `kubectl exec deploy/${SSH_DEPLOYMENT_NAME} -- codex-hostctl list`
- `kubectl exec deploy/${SSH_DEPLOYMENT_NAME} -- codex-hostctl rename srv-01:22 prod-srv-01`
- `kubectl exec deploy/${SSH_DEPLOYMENT_NAME} -- codex-hostctl export > inventory.json`

Обёртки `ssh`, `scp`, `sftp` регистрируют подключения автоматически, анализируя параметры `-J`, `-p/-P`, `-o ProxyJump`. Fingerprint заполняется через `ssh-keyscan` (таймаут 5 секунд). Все изменения пишутся в PVC и сохраняются между рестартами.

## 6. Безопасность
- Включён только пользователь `codex`; парольная аутентификация отключена.
- `AuthorizedKeysFile` указывает на файл из секрета; права корректируются entry-point’ом.
- Проброшены только 22-й порт контейнера и NodePort/LoadBalancer сервиса.
- MOTD напоминает об экспортных командах и о `codex-hostctl rename`.

## 7. Интеграция с Codex Workspace
- Храните приватный ключ в секрете Codex (`SSH_KEY`), публичный ключ – в Kubernetes-секрете `authorized_keys`.
- Рабочее пространство может синхронизировать список целей с помощью `codex-hostctl export` (через `kubectl exec`).
- Для пользовательских меток используйте `codex-hostctl rename`; их значение сохраняется в `labels.json`.

## 8. Сборка образа
После обновления исходников соберите образ:
```bash
docker build -t "${SSH_IMAGE_REGISTRY:-<public-registry>}/codex-ssh-bastion:latest" images/ssh-bastion
```
и опубликуйте его в вашем реестре, прежде чем обновлять Deployment.

## 9. Остановка и удаление
Временно остановить бастион (оставив ресурсы) можно командой:
```bash
kubectl -n ${SSH_NAMESPACE:-codex-ssh} scale deployment/${SSH_DEPLOYMENT_NAME:-ssh-bastion} --replicas=0
```

Полное удаление (подберите команды под тип хранилища):
```bash
kubectl -n ${SSH_NAMESPACE:-codex-ssh} delete deployment/${SSH_DEPLOYMENT_NAME:-ssh-bastion} \
  service/${SSH_SERVICE_NAME:-ssh-bastion} \
  configmap/${SSH_CONFIGMAP_NAME:-ssh-bastion-config} \
  secret/${SSH_AUTHORIZED_SECRET:-ssh-authorized-keys}

# Удалите PVC, если он использовался (для hostPath пропустите)
kubectl -n ${SSH_NAMESPACE:-codex-ssh} delete pvc/${SSH_PVC_NAME:-codex-ssh-data}

# Namespace удаляйте только если он выделен под бастион
kubectl delete namespace ${SSH_NAMESPACE:-codex-ssh}
```
При `SSH_STORAGE_TYPE=hostpath` удалите директорию на узле вручную, если она больше не нужна.
