# Codex SSH Bastion Deployment

*Русская версия документации: см. [README.ru.md](README.ru.md).*  
*Подробные значения переменных и примеры см. в [AGENTS.md — Подготовка кластера](AGENTS.md#подготовка-кластера) и [AGENTS.md — Подготовка workspace](AGENTS.md#подготовка-workspace).* 

## 1. Architecture and Traffic Flow
- **Multi-hop chain.** Codex workspace initiates SSH through the corporate proxy (when enabled), reaches the public HTTPS endpoint `<keen-dns-domain>`, continues to the pinned NodePort `<node-ip>:<node-port>`, lands in the SSH bastion Pod, and only then jumps to target infrastructure through declared ProxyJump chains.
- **Role of the Pod.** The bastion Pod terminates incoming SSH, applies jump-hop policies, renders inventory for workspace users, exposes health probes, and persists telemetry in `reports/`. It operates with the image referenced by `SSH_BASTION_IMAGE` and inherits registry overrides from `SSH_IMAGE_REGISTRY`.
- **Automatic route capture.** The workspace installs an `ssh` wrapper that records every successful hop sequence, exports them to `reports/ssh-routes.json`, and refreshes `AGENTS.md` notices so subsequent terminals reuse the same topology.
- **Script ecosystem.**
  - `scripts/deploy-ssh-bastion.sh` rolls out the Pod, service, and config maps according to the variables below.
  - `scripts/setup-codex-workspace.sh` prepares the Codex environment, writes SSH configs, bootstraps secrets, and registers the proxy connector.
  - `scripts/codex-hostctl` manages host aliases, ProxyJump chains, and metadata syncing between the workspace and repository.

## 2. Secrets and Environment Requirements
### 2.1 Shared inputs
| Name | Scope | Description |
| --- | --- | --- |
| `SSH_KEY` | Secret | Private key used by the workspace to authenticate against the bastion Pod. Store it in the project secrets vault; the public half must be present in the bastion authorized keys. |

### 2.2 Administrator variables
| Name | Default | Purpose |
| --- | --- | --- |
| `SSH_NAMESPACE` | `codex-ssh` | Namespace that contains the bastion deployment. |
| `SSH_DEPLOYMENT_NAME` | `codex-ssh` | Deployment name tracked by rollout status checks. |
| `SSH_SERVICE_NAME` | `codex-ssh` | Service exposing the Pod to `<node-ip>:<node-port>`. |
| `SSH_SERVICE_TYPE` | `NodePort` | Service type used for publishing the Pod. |
| `SSH_SERVICE_NODE_PORT` | — | Fixed NodePort advertised to the workspace (placeholder `<node-port>` when unset). |
| `SSH_BASTION_IMAGE` | See AGENTS | Container image for the Pod. |
| `SSH_IMAGE_REGISTRY` | Optional | Registry override applied when pulling the image (see section 5). |

### 2.3 Workspace variables
| Name | Source | Description |
| --- | --- | --- |
| `SSH_BASTION_HOST` | Secret or variable | External hostname for the bastion (use `<keen-dns-domain>` in documentation). |
| `SSH_BASTION_PORT` | Secret or variable | Public NodePort used by the workspace (placeholder `<node-port>`). |
| `SSH_BASTION_USER` | Secret or variable | Bastion login name mapped to the `SSH_KEY` credential. |
| `SSH_BASTION_ENDPOINT` | Derived | Full `user@host:port` string built by helper scripts; override only for custom routing. |
| `SSH_PROXY_URL` | Secret | URL of the corporate proxy the workspace must traverse. Leave unset when direct routing is allowed. |
| `SSH_PROXY_CONNECT_LOG` | Variable | Path for proxy connector logs (default `reports/ssh-proxy.log`). |

## 3. Setup Workflow
### 3.1 Administrator timeline
1. Generate an SSH key pair for workspace use and register the public key inside the bastion Pod configuration.
2. Export the required variables (see section 2.2 and AGENTS) and execute `scripts/deploy-ssh-bastion.sh` from a machine with cluster access. The script ensures namespace objects exist, publishes the NodePort, and records connection metadata under `reports/`.
3. Share the resulting `<keen-dns-domain>` and `<node-port>` placeholders with workspace maintainers. Sensitive values stay outside version control; update organization-specific details directly in [AGENTS.md](AGENTS.md).

### 3.2 Workspace timeline
1. Store `SSH_KEY`, `SSH_PROXY_URL`, and the `SSH_BASTION_*` values in the Codex project secrets UI.
2. Run `scripts/setup-codex-workspace.sh` as both setup and maintenance hook. The helper fetches or updates `scripts/codex-hostctl`, installs the `ssh` wrapper, refreshes `~/.ssh/config`, and records ProxyJump chains in `reports/ssh-inventory.md`.
3. Use `scripts/codex-hostctl list` to verify imported host aliases. Adjust names with `scripts/codex-hostctl rename <old> <new>`; each run updates the workspace `AGENTS.md` summary automatically.
4. When new infrastructure appears, rerun the setup script so that route capture, host inventory, and AGENTS notices stay in sync.

## 4. Corporate Proxy Integration
- **Connector design.** The workspace relies on a local connector invoked via `ProxyCommand` inside `~/.ssh/config`. The connector opens a tunnel to `SSH_PROXY_URL`, negotiates HTTPS CONNECT, and streams SSH payloads without exposing credentials.
- **Required inputs.** Set `SSH_PROXY_URL` to the corporate proxy endpoint (e.g., `https://<proxy-host>:<proxy-port>`). Optional variables: `SSH_PROXY_CONNECT_LOG` for the log file, `SSH_PROXY_SOCKET` to pin the Unix-domain socket used by the connector, and `SSH_PROXY_STRICT=1` to abort when the proxy cannot be reached.
- **`ssh` wrapper behaviour.** All workspace SSH calls are routed through `scripts/ssh-wrapper` installed by `setup-codex-workspace.sh`. The wrapper injects the appropriate `ProxyCommand`, watches for multi-hop success, and appends detailed traces to `reports/ssh-routes.json` and the proxy log file.
- **Troubleshooting.** Inspect `reports/ssh-proxy.log` for connector output, and check `reports/ssh-routes.json` for recorded hops. The setup script also mirrors the latest status inside the project `AGENTS.md` for quick reference.

## 5. Manual Image Builds and Registry Overrides
1. Prepare a workspace containing the manifests from `manifests/` and a Dockerfile tailored to your SSH bastion requirements.
2. Build the image locally, for example:
   ```bash
   docker build -t <registry>/<name>:tag .
   ```
3. Push the image to your registry and export `SSH_BASTION_IMAGE=<registry>/<name>:tag` along with `SSH_IMAGE_REGISTRY=<registry>` if the cluster requires explicit registry hints.
4. Document the selected registry, tag, and deployment parameters in [AGENTS.md — Подготовка кластера](AGENTS.md#подготовка-кластера) so future operators reuse consistent values.

This README purposely uses placeholders (`<keen-dns-domain>`, `<node-ip>`, `<node-port>`) for sensitive infrastructure. Replace them only in secure channels as described in [AGENTS.md](AGENTS.md).
