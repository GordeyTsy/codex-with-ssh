# Шлюз API Kubernetes через NodePort или HTTPS

*English documentation is available in [README.md](README.md).* 

## 1. Назначение проекта
Опубликовать API Kubernetes для рабочей среды Codex, обходя корпоративный TLS-прокси. Во внутреннем кластере запускается NGINX на NodePort, который принимает HTTP-запросы из Codex и проксирует их к настоящему API-серверу через HTTPS с проверкой по штатному кластерному CA.

## 2. Архитектура
- **Шлюз** – манифесты `cm-nginx.conf.yaml` и `deploy.yaml` разворачивают обратный прокси NGINX в пространстве имён `k8s-gw`.
- **Режимы публикации**
  - *NodePort (по умолчанию)* – сервис типа NodePort слушает порт 80 на каждом узле.
  - *HTTPS через ingress* – скрипт может создать ресурс Ingress и TLS-секрет, чтобы отдавать шлюз через контроллер ingress.
- **Режимы аутентификации**
  - `AUTH_MODE=passthrough` (режим по умолчанию) – токен не подставляется, каждый клиент обязан передавать свой bearer-токен (например, через секрет Codex `K8S_TOKEN`). Это рекомендуемый вариант.
  - `AUTH_MODE=inject` – шлюз подставляет сервисный токен `codex-gw-token`. Любой клиент, имеющий доступ к NodePort, получает права cluster-admin. Перед запуском установите `ALLOW_INJECT=1`, подтверждая осознанный выбор.
- **Подготовка Codex** – скрипт `setup-codex-workspace.sh` устанавливает `kubectl` и создаёт kubeconfig, направленный на NodePort.

## 3. Предварительные требования на хосте администратора
- `kubectl` с правами администратора на целевом кластере.
- Доступ из Codex хотя бы к одному узлу кластера на выбранном NodePort (диапазон `30000-32767`).
- (Необязательно) заранее задайте переменные окружения, чтобы изменить поведение `deploy-nodeport-gateway.sh`. Все доступные
  параметры описаны ниже.

### 3.1 Переменные `deploy-nodeport-gateway.sh`
| Переменная | Значение по умолчанию | Назначение |
| --- | --- | --- |
| `NAMESPACE` | `k8s-gw` | Пространство имён, в котором создаются все объекты шлюза.
| `SECRET_NAME` | `cluster-ca` | Имя секрета с корневым сертификатом кластера (`ca.crt`).
| `DEPLOYMENT_NAME` | `k8s-api-gw` | Имя Deployment с NGINX; используется командами rollout.
| `SERVICE_NAME` | `k8s-api-gw` | Имя сервиса, публикующего Deployment.
| `EXPOSE_MODE` | `nodeport` | `nodeport` оставляет сервис в режиме NodePort. Значение `https` добавляет Ingress и настраивает HTTPS на уровне кластера.
| `SERVICE_TYPE` | `NodePort` (или `ClusterIP` при `EXPOSE_MODE=https`) | Тип Kubernetes-сервиса. При необходимости задайте `LoadBalancer` или другое значение.
| `SERVICE_NODE_PORT` | — | Необязательный фиксированный NodePort (30000-32767). Полезно для предварительного открытия фаерволов и детерминированной автоматизации; скрипт проверяет диапазон и без значения оставляет автоназначение. Допускается псевдоним `GW_NODE_PORT` для обратной совместимости.
| `INGRESS_NAME` | `${SERVICE_NAME}` | Имя Ingress при `EXPOSE_MODE=https`. Для NodePort-режима игнорируется.
| `INGRESS_HOST` / `INGRESS_HOSTS` | — | Хост (или список через запятую), который должен обрабатываться ingress'ом. Переменная `INGRESS_HOSTS` имеет приоритет. Оставьте пустой, чтобы принимать все хосты.
| `INGRESS_CLASS_NAME` | — | Имя класса ingress (например, `nginx`). Без значения используется класс по умолчанию.
| `INGRESS_PROXY_BODY_SIZE` | `64m` | Значение аннотации `nginx.ingress.kubernetes.io/proxy-body-size`.
| `INGRESS_EXTRA_ANNOTATIONS` | — | Дополнительные аннотации ingress. Указывайте по одной строке `ключ: значение` — скрипт добавит нужные отступы.
| `UPSTREAM_API` | `10.0.70.200:6443` | Внутренний адрес и порт реального API сервера Kubernetes.
| `SA_NAME` | `codex-gw` | Сервисный аккаунт, привязанный к cluster-admin и используемый подом.
| `TOKEN_SECRET_NAME` | `${SA_NAME}-token` | Секрет типа `kubernetes.io/service-account-token`, из которого NGINX читает токен.
| `CLUSTERROLEBINDING_NAME` | `${SA_NAME}-admin` | ClusterRoleBinding, выдающий права cluster-admin сервисному аккаунту.
| `CONTEXT_NAME` | Текущий контекст kubeconfig | Определяет, из какого контекста брать данные о кластере.
| `AUTH_MODE` | `passthrough` | `passthrough` требует заголовок `Authorization` от клиента; `inject` подставляет SA-токен всем клиентам.
| `ALLOW_INJECT` | `0` | Должна быть равна `1` при использовании `AUTH_MODE=inject`, чтобы явно подтвердить небезопасный режим.
| `TLS_SECRET_NAME` | `${SERVICE_NAME}-tls` | TLS-секрет, к которому привязывается ingress. Создаётся/обновляется при наличии сертификата.
| `TLS_CERT_FILE` / `TLS_KEY_FILE` | — | Пути к файлам сертификата и ключа, загружаемым в `TLS_SECRET_NAME`.
| `TLS_CERT` / `TLS_KEY` | — | Содержимое сертификата и ключа в формате PEM, если удобнее передавать их напрямую (`TLS_CERT_DATA` / `TLS_KEY_DATA` тоже поддерживаются).
| `TLS_GENERATE_SELF_SIGNED` | `0` | Значение `1` заставляет скрипт выпустить самоподписанный сертификат.
| `TLS_COMMON_NAME` | `k8s-api-gw.local` | Common Name, используемый при генерации самоподписанного сертификата (и добавляемый в SAN по умолчанию).
| `TLS_SANS` | — | Дополнительные SAN при генерации сертификата. Список через запятую, например `DNS:gw.example.com,IP:192.168.10.10`.
| `TLS_SELF_SIGNED_DAYS` | `365` | Срок действия самоподписанного сертификата (в днях).
| `CLUSTER_CA_B64` | автоопределяется | CA в base64. Укажите вручную, если kubeconfig не содержит `certificate-authority-data`.

Скрипт старается получить значения из kubeconfig автоматически. Переопределяйте их, если нужно использовать другие имена, уже
существующие сервисные аккаунты или проксировать запросы на нестандартную конечную точку API.

## 4. Развёртывание шлюза (хост администратора)
```bash
cd /path/to/k8s-expose-apiserver
./scripts/deploy-nodeport-gateway.sh
```
По умолчанию сервис остаётся NodePort, а клиенты должны передавать собственный bearer-токен (`AUTH_MODE=passthrough`). Изменяйте параметры только по необходимости:
```bash
ALLOW_INJECT=1 AUTH_MODE=inject ./scripts/deploy-nodeport-gateway.sh
```
Скрипт выполняет:
1. Создание/обновление namespace, сервисного аккаунта, RBAC, секрета с CA и токена.
2. При необходимости — создание или обновление TLS-секрета (если переданы файлы либо включена генерация самоподписанного сертификата).
3. Шаблонизацию и применение ConfigMap, Deployment и Service (а также Ingress при `EXPOSE_MODE=https`).
4. Перезапуск шлюза, ожидание успешного развёртывания и вывод подсказок по подключению в выбранном режиме.

### NodePort (по умолчанию)
Если достаточно открытого HTTP-соединения между Codex и кластером, оставляйте режим NodePort — скрипт покажет список внутренних IP узлов и назначенный порт:
```bash
./scripts/deploy-nodeport-gateway.sh
```
При необходимости можно зафиксировать порт или поменять тип сервиса:
```bash
SERVICE_NODE_PORT=30443 ./scripts/deploy-nodeport-gateway.sh
SERVICE_TYPE=LoadBalancer ./scripts/deploy-nodeport-gateway.sh
```

### HTTPS через ingress контроллер
Для публикации шлюза через ingress установите `EXPOSE_MODE=https`. Можно либо использовать готовую пару сертификат/ключ, либо поручить скрипту сгенерировать самоподписанный сертификат.

**Пример: внешний домен и готовый сертификат**
```bash
EXPOSE_MODE=https \
INGRESS_HOST=gateway.example.com \
TLS_CERT_FILE=/path/to/fullchain.pem \
TLS_KEY_FILE=/path/to/privkey.pem \
./scripts/deploy-nodeport-gateway.sh
```
Дополнительно доступны `INGRESS_HOSTS` (несколько хостов через запятую), `INGRESS_CLASS_NAME` для выбора ingress-контроллера и `INGRESS_EXTRA_ANNOTATIONS` для своих аннотаций.

**Пример: самоподписанный сертификат без публичного DNS**
```bash
EXPOSE_MODE=https \
TLS_GENERATE_SELF_SIGNED=1 \
TLS_COMMON_NAME=k8s-api.local \
TLS_SANS=DNS:k8s-api.local,IP:192.168.1.50 \
./scripts/deploy-nodeport-gateway.sh
```
Скрипт сохранит материалы в `TLS_SECRET_NAME` и напомнит раздать доверенный CA клиентам (например, через переменную `GW_CA_DATA`).

## 5. Внешний TLS-терминатор (KeenDNS и т.п.)
Если TLS завершается на внешнем прокси, оставляйте шлюз в режиме NodePort и проксируйте внешний 443 на выданный порт. В Codex укажите `GW_ENDPOINT=https://<ваш-домен>`, чтобы помощник работал по HTTPS. В режиме `inject` обязательно ограничьте доступ на внешнем уровне — сам NodePort не требует аутентификации.

## 6. Подготовка Codex Workspace
Когда другому проекту Codex требуется `kubectl`, настройте его так, чтобы вспомогательные скрипты запускались из этого репозитория и не засоряли рабочий каталог.

1. В разделе **Variables** добавьте координаты шлюза:
   - *NodePort* — `GW_ENDPOINT=http://<ip-узла>:<node-port>` (скрипт развёртывания выводит подсказку с одним из IP и выданным NodePort). Переменные `GW_NODE` и `GW_NODE_PORT` по-прежнему поддерживаются, если хотите передавать хост и порт отдельно или доверить выбор схемы помощнику.
   - *Ingress/HTTPS* — `GW_ENDPOINT=https://<ingress-хост>` (или `https://<ip>` вместе с `GW_TLS_SERVER_NAME=<имя-сертификата>` при самоподписанном сертификате). При необходимости добавьте `GW_CA_DATA`/`GW_CA_FILE`, если сертификат не доверенный.
   - `HTTPS_BRIDGE_TARGET` — ваш HTTPS-эндпоинт (например, `https://example.com`), чтобы включить локальный HTTP→HTTPS мост.
   - При необходимости добавьте и другие параметры, которые понимает `scripts/setup-codex-workspace.sh` (например, `GW_ENDPOINT`, `GW_AUTO_TLS_PORTS`, `KUBECTL_VERSION`, `SYNC_DEFAULT_KUBECONFIG`).
2. В **Secrets** сохраните `K8S_TOKEN`, чтобы kubeconfig получил bearer-токен. Оставляйте секрет пустым только если прокси в кластере самостоятельно подставляет учётные данные.
3. В выпадающем списке **Скрипт установки** выберите «Вручную» и вставьте следующий код. Он клонирует репозиторий в `/workspace`, запускает настройку и возвращается в исходный каталог. Переменная `PROJECT_PATH` нужна, чтобы скрипт добавил уведомление о работающем мосте и kubeconfig во все `AGENTS.md` вашего проекта.

   ```bash
   set -euo pipefail
   export PROJECT_PATH="$(pwd)"
   cd /workspace
   if [ ! -d k8s-expose-apiserver ]; then
     git clone https://github.com/GordeyTsy/k8s-expose-apiserver.git
   fi
   cd /workspace/k8s-expose-apiserver
   ./scripts/setup-codex-workspace.sh
   cd "$PROJECT_PATH"
   ```

4. В поле **Сценарий обслуживания** разместите:

   ```bash
   set -euo pipefail
   export PROJECT_PATH="$(pwd)"
   cd /workspace/k8s-expose-apiserver || exit 0
   ./scripts/setup-codex-workspace.sh
   cd "$PROJECT_PATH"
   ```

   Этот шаг выполняется после восстановления контейнера из кэша: он проверяет, что HTTPS-мост и `kubectl` работают, обновляет уведомление в `AGENTS.md` и перезапускает мост только при необходимости.

Сохраните настройки и перезапустите рабочую среду. При первом запуске установится `kubectl`, создастся kubeconfig, его копия попадёт в `~/.kube/config` (предварительно сделается резервная копия), запишется PID локального моста и появится заметка в `AGENTS.md`.

## 7. Проверка и сопровождение доступа
- Kubeconfig сохраняется в `/workspace/k8s-expose-apiserver/configs/kubeconfig-nodeport`, а также зеркалируется в `~/.kube/config` (прошлый файл переименовывается в `config.bak`).
- Если задан `HTTPS_BRIDGE_TARGET`, запускается локальный мост (по умолчанию `http://127.0.0.1:18080`), его PID сохраняется в `configs/https-bridge.pid`, а в каждый `AGENTS.md` внутри `PROJECT_PATH` добавляется уведомление (на английском) с информацией о PID и параметрах моста.
- Базовые проверки:

  ```bash
  kubectl --request-timeout=10s version
  kubectl get ns
  ```

- Диагностика моста:

  ```bash
  cat /workspace/k8s-expose-apiserver/configs/https-bridge.pid
  ps -fp "$(cat /workspace/k8s-expose-apiserver/configs/https-bridge.pid)"
  tail -f /workspace/k8s-expose-apiserver/configs/https-bridge.log
  ```

- Каждый повторный запуск того же скрипта (включая сценарий обслуживания) проверяет `kubectl`, обновляет уведомление в `AGENTS.md` и при сбоях перезапускает мост автоматически. Следуйте подсказкам по `NO_PROXY` и PATH, которые выводит скрипт.
- Каждый запуск перед стартом нового моста пытается остановить процесс по PID из `configs/https-bridge.pid`, поэтому зависший экземпляр не мешает повторной настройке.
- Скрипт завершается ошибкой, если команды `kubectl --request-timeout=5s version` и `kubectl --request-timeout=5s get ns`, выполненные с новым kubeconfig, не проходят — после успеха `kubectl` готов к работе сразу.

## 8. Замечания по безопасности
- `AUTH_MODE=inject` фактически выдаёт права cluster-admin любому, кто добрался до NodePort. Ограничьте доступ сетевыми политиками, файрволом или внешней аутентификацией и выставляйте `ALLOW_INJECT=1` только полностью осознавая риск.
- Поверните сервисный токен, удалив секрет (`kubectl -n k8s-gw delete secret codex-gw-token`) и запустив скрипт развертывания повторно.
- Храните токены рабочего пространства в разделе **Secrets** Codex, а не в обычных переменных или скриптах в Git.

## 9. Очистка
```bash
kubectl delete -n k8s-gw service k8s-api-gw
kubectl delete -n k8s-gw deployment k8s-api-gw
kubectl delete -n k8s-gw configmap nginx-conf
kubectl delete -n k8s-gw secret cluster-ca
kubectl delete -n k8s-gw secret codex-gw-token
kubectl delete clusterrolebinding codex-gw-admin
kubectl delete -n k8s-gw serviceaccount codex-gw
kubectl delete ns k8s-gw
rm -f /workspace/k8s-expose-apiserver/configs/kubeconfig-nodeport
```
