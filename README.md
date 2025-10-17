# Codex SSH Bastion

*Русская версия документации доступна в [README.ru.md](README.ru.md).*  
Эта репозитория разворачивает управляемый SSH-бастион внутри доверенного Kubernetes-кластера и поставляет контейнерный образ, который собирает инвентарь подключений.

## 1. Что входит в решение
- **Образы** – каталог [`images/ssh-bastion/`](images/ssh-bastion/) содержит Dockerfile, entrypoint и утилиты (`codex-hostctl`, обёртки `ssh/scp/sftp`). Образ публикуется как `codex-ssh-bastion` и запускает OpenSSH c дополнительной телеметрией.
- **Манифесты** – в [`manifests/ssh-bastion/`](manifests/ssh-bastion/) лежат шаблоны для Namespace, PVC, ConfigMap, Deployment и Service. Они параметризуются переменными окружения и применяются через скрипт.
- **Устойчивая память** – PVC монтируется в `/var/lib/codex-ssh`, где хранится инвентарь (`inventory.json`) и пользовательские ярлыки (`labels.json`).
- **Скрипты** – [`scripts/deploy-ssh-bastion.sh`](scripts/deploy-ssh-bastion.sh) шаблонизирует манифесты, при необходимости обновляет секрет с `authorized_keys` и выводит подсказки по подключению.

## 2. Архитектура контейнера
Контейнерный образ на базе Debian запускает OpenSSH Server и entrypoint, который:
1. Создаёт системного пользователя `codex` без пароля, настраивает директорию данных `/var/lib/codex-ssh` (права `700`).
2. Копирует `authorized_keys` из секрета Kubernetes в `~codex/.ssh/authorized_keys` и фиксирует права `600`.
3. Переименовывает системные `ssh/scp/sftp` в `/opt/codex-ssh/originals/` и подменяет их обёртками, которые парсят `-J`, `-p/-P`, `-o ProxyJump` и записывают сведения о маршруте в `inventory.json`.
4. Генерирует hostkeys (`ssh-keygen -A`), применяет сниппет конфигурации `sshd_config` из ConfigMap и рендерит MOTD с текущим инвентарём.
5. Предоставляет CLI `codex-hostctl` со следующими командами:
   - `codex-hostctl list` – табличный вывод инвентаря.
   - `codex-hostctl export` – JSON с полями `id`, `name`, `target`, `port`, `jump_chain`, `fingerprint`, `last_seen` (используется рабочей средой Codex).
   - `codex-hostctl rename <id> <name>` – назначение читаемого имени узлу.
   - `codex-hostctl motd` – генерация сообщения дня на основе инвентаря (используется entrypoint’ом).

## 3. Развёртывание в Kubernetes
```bash
SSH_NAMESPACE=codex-ssh \
SSH_SERVICE_NODE_PORT=32222 \
SSH_BASTION_IMAGE=codex-ssh-bastion:latest \
SSH_IMAGE_REGISTRY=ghcr.io/gordeytsy \
SSH_AUTHORIZED_SECRET=ssh-authorized-keys \
SSH_AUTHORIZED_KEYS_FILE=./authorized_keys \
scripts/deploy-ssh-bastion.sh
```

Скрипт потребует `kubectl` и `envsubst`. Он генерирует временную директорию с манифестами и последовательно применяет Namespace, PVC, ConfigMap, Deployment и Service. При наличии `SSH_AUTHORIZED_KEYS_FILE` секрет обновляется через `kubectl create secret generic ... --dry-run=client | kubectl apply -f -`.

### 3.1 Настраиваемые переменные
| Переменная | Назначение | Значение по умолчанию |
| --- | --- | --- |
| `SSH_NAMESPACE` | Namespace, в котором размещаются все ресурсы. | `codex-ssh` |
| `SSH_DEPLOYMENT_NAME` | Имя Deployment. | `ssh-bastion` |
| `SSH_SERVICE_NAME` | Имя Service. | `ssh-bastion` |
| `SSH_SERVICE_TYPE` | Тип сервиса (`NodePort`, `LoadBalancer`, `ClusterIP`). | `NodePort` |
| `SSH_SERVICE_NODE_PORT` | Фиксированный NodePort (используется только когда тип `NodePort`). | `32222` |
| `SSH_PVC_NAME` | Имя PersistentVolumeClaim. | `codex-ssh-data` |
| `SSH_PVC_SIZE` | Размер запрашиваемого тома. | `1Gi` |
| `SSH_STORAGE_CLASS` | StorageClass (оставьте пустым, чтобы использовать кластерный по умолчанию). | — |
| `SSH_CONFIGMAP_NAME` | Имя ConfigMap с MOTD и сниппетом `sshd_config`. | `ssh-bastion-config` |
| `SSH_AUTHORIZED_SECRET` | Секрет с файлом `authorized_keys`. | `ssh-authorized-keys` |
| `SSH_BASTION_IMAGE` | Тег образа без префикса реестра. | `codex-ssh-bastion:latest` |
| `SSH_IMAGE_REGISTRY` | Реестр (оставьте пустым, если тег уже полный). | — |
| `SSH_MOTD_CONTENT` | Базовое сообщение MOTD (текст, разбивается по строкам). | `Codex SSH bastion\nИспользуйте codex-hostctl list, чтобы увидеть найденные цели.` |
| `SSH_AUTHORIZED_KEYS_FILE` | Локальный путь до файла `authorized_keys` для обновления секрета. | — |

После применения скрипт выводит подсказки:
- `kubectl -n <ns> rollout status deployment/<deploy>` – проверка развёртывания.
- `kubectl -n <ns> get svc <service> -o wide` – получение NodePort или внешнего IP.
- Тестовая команда `ssh -p <node-port> codex@<node-ip>` (или с ProxyJump).
- Сниппет обновления секрета `authorized_keys`.
- Команда для экспорта инвентаря: `kubectl exec ... -- codex-hostctl export`.

## 4. Управление секретом `authorized_keys`
1. Подготовьте файл `authorized_keys` (например, `ssh-keygen -t ed25519 -f ./codex-ssh && cat codex-ssh.pub > authorized_keys`).
2. Обновите секрет:
   ```bash
   kubectl -n ${SSH_NAMESPACE:-codex-ssh} create secret generic ${SSH_AUTHORIZED_SECRET:-ssh-authorized-keys} \
     --from-file=authorized_keys=./authorized_keys --dry-run=client -o yaml | kubectl apply -f -
   ```
3. Перезапустите Deployment при необходимости: `kubectl -n ${SSH_NAMESPACE} rollout restart deployment/${SSH_DEPLOYMENT_NAME}`.
4. Проверьте логи: `kubectl -n ${SSH_NAMESPACE} logs deployment/${SSH_DEPLOYMENT_NAME}` – entrypoint предупредит, если ключи отсутствуют или имеют неверные права.

## 5. Работа с `codex-hostctl`
Внутри пода доступны файлы `/var/lib/codex-ssh/inventory.json` и `/var/lib/codex-ssh/labels.json`. Основные сценарии:
- `kubectl exec deploy/${SSH_DEPLOYMENT_NAME} -- codex-hostctl list` – табличный список целевых хостов.
- `kubectl exec deploy/${SSH_DEPLOYMENT_NAME} -- codex-hostctl rename srv-01:22 prod-srv-01` – присвоение читаемого имени.
- `kubectl exec deploy/${SSH_DEPLOYMENT_NAME} -- codex-hostctl export > inventory.json` – выгрузка для синхронизации в workspace.

Обёртки `ssh/scp/sftp` автоматически вызывают `codex-hostctl record ...`, добавляя запись в инвентарь при каждом подключении. Fingerprint заполняется с помощью `ssh-keyscan` (таймаут 5 секунд).

## 6. Устойчивое хранение и безопасность
- PVC монтируется с правами `0700`; благодаря этому после рестарта пода сохраняются цепочки ProxyJump и переименования.
- Конфигурация `sshd_config` отключает пароли, root-доступ и X11, разрешает только пользователя `codex` и использование `internal-sftp`.
- Контейнер запускает `sshd` от root (для корректной работы демона), но пользовательские сессии выполняются от `codex`.
- Обновление MOTD происходит при старте контейнера и записывает список доступных целей, чтобы оператор видел актуальную информацию при входе.

## 7. Интеграция с рабочим пространством Codex
- Рабочее пространство должно использовать внешний адрес NodePort (или LoadBalancer) и приватный ключ, соответствующий `authorized_keys`.
- Скрипты в workspace могут опрашивать `codex-hostctl export` через `kubectl exec` и синхронизировать `inventory.json`.
- Для отображения пользовательских меток необходимо выполнять `codex-hostctl rename` внутри кластера; изменения сохраняются в PVC и переживают рестарты.

## 8. Сборка образа
После обновления исходников обязательно соберите образ:
```bash
docker build -t "${SSH_IMAGE_REGISTRY:-<public-registry>}/codex-ssh-bastion:latest" images/ssh-bastion
```
и загрузите его в нужный реестр перед обновлением Deployment.
