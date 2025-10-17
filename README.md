# Kubernetes API Gateway via NodePort or HTTPS

*Русская версия документации: см. [README.ru.md](README.ru.md).* 

## 1. Project Goal
Expose a Kubernetes control plane to the Codex workspace without relying on custom DNS or terminating TLS in the untrusted corporate proxy. The in-cluster NGINX gateway listens on a NodePort, receives plain HTTP from the workspace, and forwards traffic to the real API server using the official cluster CA and mutual TLS verification.

## 2. Architecture Overview
- **Gateway** – `manifests/cm-nginx.conf.yaml` + `manifests/deploy.yaml` deploy an NGINX reverse proxy in namespace `k8s-gw`.
- **Exposure modes**
  - *NodePort (default)* – `Service` type `NodePort` exposes port 80 on every node.
  - *HTTPS ingress* – the script can generate an `Ingress` object and optional TLS secret to publish the gateway via an ingress controller.
- **Authentication modes**
  - `AUTH_MODE=passthrough` (default) – no token injection. Every client must supply a bearer token (e.g., via workspace secret `K8S_TOKEN`). Recommended for real environments and the new default.
  - `AUTH_MODE=inject` – the gateway injects the long-lived service-account token stored in `codex-gw-token`. Anyone who can reach the NodePort becomes cluster-admin. Set `ALLOW_INJECT=1` to acknowledge the risk before using this mode.
- **Workspace setup** – `scripts/setup-codex-workspace.sh` installs `kubectl` and generates a kubeconfig that talks to the NodePort endpoint.

## 3. Prerequisites on the Admin Host
- `kubectl` with admin rights against the target cluster.
- Outbound TCP access from Codex to at least one cluster node on the chosen NodePort (`30000-32767`).
- (Optional) Pre-set environment variables to tune the deployment. Every variable accepted by
  `deploy-nodeport-gateway.sh` is documented below.

### 3.1 `deploy-nodeport-gateway.sh` variables
| Variable | Default | Purpose |
| --- | --- | --- |
| `NAMESPACE` | `k8s-gw` | Namespace that hosts every gateway object.
| `SECRET_NAME` | `cluster-ca` | Name of the secret that stores the upstream cluster CA (`ca.crt`).
| `DEPLOYMENT_NAME` | `k8s-api-gw` | Name of the NGINX deployment. Also used by the rollout commands.
| `SERVICE_NAME` | `k8s-api-gw` | Name of the Service that exposes the deployment.
| `EXPOSE_MODE` | `nodeport` | `nodeport` keeps the Service as NodePort. Set `https` to generate an Ingress and serve HTTPS through the cluster.
| `SERVICE_TYPE` | `NodePort` (or `ClusterIP` when `EXPOSE_MODE=https`) | Service type applied to the gateway. Override when you prefer `LoadBalancer` or another value.
| `SERVICE_NODE_PORT` | — | Optional fixed NodePort (30000-32767). Use it to pre-open firewalls or keep automation deterministic; the script validates the range and falls back to auto-assignment when unset. `GW_NODE_PORT` is accepted as a backwards-compatible alias.
| `INGRESS_NAME` | `${SERVICE_NAME}` | Name of the generated Ingress when `EXPOSE_MODE=https`. Ignored for NodePort deployments.
| `INGRESS_HOST` / `INGRESS_HOSTS` | — | Hostname (or comma-separated list) routed to the ingress. `INGRESS_HOSTS` takes precedence over `INGRESS_HOST`. Leave empty to accept all hosts.
| `INGRESS_CLASS_NAME` | — | Ingress class to target. Leave unset to rely on the cluster default.
| `INGRESS_PROXY_BODY_SIZE` | `64m` | Value assigned to the `nginx.ingress.kubernetes.io/proxy-body-size` annotation.
| `INGRESS_EXTRA_ANNOTATIONS` | — | Additional ingress annotations. Provide one `key: value` entry per line (the script handles indentation).
| `UPSTREAM_API` | `10.0.70.200:6443` | Host and port of the real Kubernetes API server inside the cluster.
| `SA_NAME` | `codex-gw` | Service account bound to cluster-admin and used by the deployment.
| `TOKEN_SECRET_NAME` | `${SA_NAME}-token` | Long-lived `kubernetes.io/service-account-token` secret consumed by NGINX.
| `CLUSTERROLEBINDING_NAME` | `${SA_NAME}-admin` | ClusterRoleBinding that grants cluster-admin to the service account.
| `CONTEXT_NAME` | Current kubeconfig context | Determines which cluster kubeconfig data is read from.
| `AUTH_MODE` | `passthrough` | `passthrough` requires client-supplied `Authorization` headers; `inject` embeds the SA token into every request.
| `ALLOW_INJECT` | `0` | Must be set to `1` when using `AUTH_MODE=inject` to opt into the unsafe token-injection mode.
| `TLS_SECRET_NAME` | `${SERVICE_NAME}-tls` | TLS secret referenced by the ingress. It is created or updated when certificate data is supplied.
| `TLS_CERT_FILE` / `TLS_KEY_FILE` | — | Paths to the certificate and key files written into `TLS_SECRET_NAME`.
| `TLS_CERT` / `TLS_KEY` | — | Raw PEM contents for the TLS secret when files are not available (`TLS_CERT_DATA` / `TLS_KEY_DATA` are accepted aliases).
| `TLS_GENERATE_SELF_SIGNED` | `0` | Set to `1` to let the script mint a self-signed certificate for `TLS_SECRET_NAME`.
| `TLS_COMMON_NAME` | `k8s-api-gw.local` | Common Name used for self-signed certificates (and the default DNS SubjectAltName).
| `TLS_SANS` | — | Extra SubjectAltName entries when generating a self-signed certificate. Comma-separated list such as `DNS:gw.example.com,IP:192.168.10.10`.
| `TLS_SELF_SIGNED_DAYS` | `365` | Validity period (in days) for self-signed certificates.
| `CLUSTER_CA_B64` | auto-detected | Base64-encoded PEM CA bundle. Use this when the kubeconfig lacks `certificate-authority-data`.

The script auto-detects values from your kubeconfig. Override them when you need different names, want to reuse an existing
service account, or must point the gateway at a non-standard API endpoint.

## 4. Deploy the Gateway (Admin Host)
```bash
cd /path/to/k8s-expose-apiserver
./scripts/deploy-nodeport-gateway.sh
```
The defaults keep the Service on a NodePort and require clients to present their own bearer token (`AUTH_MODE=passthrough`). Override only when necessary:
```bash
ALLOW_INJECT=1 AUTH_MODE=inject ./scripts/deploy-nodeport-gateway.sh
```
The script will:
1. Ensure namespace, service account, RBAC, CA secret, and token secret exist.
2. Create or update the TLS secret when certificate material is provided or self-signed generation is enabled.
3. Template and apply the NGINX ConfigMap, Deployment, and Service (plus the Ingress when `EXPOSE_MODE=https`).
4. Restart the gateway, wait for rollout success, and print connection guidance for the chosen exposure mode.

### NodePort workflow (default)
Keep NodePort when you only need an unencrypted endpoint between the Codex workspace and the cluster. After the rollout the script lists reachable node IPs and the assigned port:
```bash
./scripts/deploy-nodeport-gateway.sh
```
Pinning the port or the Service type follows the usual environment variable pattern:
```bash
SERVICE_NODE_PORT=30443 ./scripts/deploy-nodeport-gateway.sh
SERVICE_TYPE=LoadBalancer ./scripts/deploy-nodeport-gateway.sh
```

### HTTPS ingress managed by the cluster
Switch to `EXPOSE_MODE=https` when the gateway must be reachable through an ingress controller. Provide either an existing certificate/key pair or ask the script to mint a self-signed bundle.

**Expose an existing domain via ingress**
```bash
EXPOSE_MODE=https \
INGRESS_HOST=gateway.example.com \
TLS_CERT_FILE=/path/to/fullchain.pem \
TLS_KEY_FILE=/path/to/privkey.pem \
./scripts/deploy-nodeport-gateway.sh
```
Optional knobs: `INGRESS_HOSTS` for multiple hosts (comma separated), `INGRESS_CLASS_NAME` to target a specific ingress class, and `INGRESS_EXTRA_ANNOTATIONS` for custom annotations.

**Generate a self-signed certificate (no public DNS)**
```bash
EXPOSE_MODE=https \
TLS_GENERATE_SELF_SIGNED=1 \
TLS_COMMON_NAME=k8s-api.local \
TLS_SANS=DNS:k8s-api.local,IP:192.168.1.50 \
./scripts/deploy-nodeport-gateway.sh
```
The script stores the generated material in `TLS_SECRET_NAME` and prints a reminder to distribute the corresponding CA data to clients (for example via `GW_CA_DATA`).

## 5. Optional KeenDNS / external TLS edge
When you prefer a separate TLS terminator (KeenDNS, a reverse proxy, etc.), keep the gateway on NodePort and forward the external 443 to the reported NodePort. Supply `GW_ENDPOINT=https://your-hostname` to the workspace helper so it still speaks HTTPS. Consider enforcing authentication on the edge when `AUTH_MODE=inject` is active, because the in-cluster NodePort remains unauthenticated.

## 6. Prepare the Codex Workspace
Run the helper from `/workspace/k8s-expose-apiserver` so your application repository stays clean. In the Codex project that needs `kubectl`, configure the setup as follows:

1. **Provide variables and secrets**

  - *NodePort mode* – set `GW_ENDPOINT=http://<node-ip>:<node-port>` (the deploy script prints a ready-to-use hint based on the detected NodePort and node IPs). Legacy inputs `GW_NODE` and `GW_NODE_PORT` remain available when you prefer to supply the host and port separately or let the helper derive the scheme.
  - *HTTPS ingress mode* – set `GW_ENDPOINT=https://<ingress-host>` (or `https://<load-balancer-ip>` together with `GW_TLS_SERVER_NAME=<tls-common-name>` when you rely on self-signed certificates). Supply the CA bundle via `GW_CA_DATA`/`GW_CA_FILE` when the certificate is not publicly trusted.
  - In **Secrets**, add `K8S_TOKEN=<bearer-token>` so the kubeconfig can authenticate against the gateway (passthrough mode).
  - Optional variables such as `HTTPS_BRIDGE_TARGET`, `HTTPS_BRIDGE_LISTEN_PORT`, or custom CA inputs can be supplied when you need the local HTTP→HTTPS bridge or custom trust roots.

2. **Setup script (Manual)**

   Paste the snippet below into the **Setup script** field. It clones this repository into `/workspace`, runs the bootstrapper, and returns to the original project directory. Exporting `PROJECT_PATH` lets the helper update your project's `AGENTS.md` files with bridge details.

   ```bash
   set -euo pipefail
   export PROJECT_PATH="$(pwd)"
   cd /workspace
   if [ ! -d k8s-expose-apiserver ]; then
     git clone https://github.com/GordeyTsy/k8s-expose-apiserver.git
   fi
   cd /workspace/k8s-expose-apiserver
   rm AGENTS.md
   ./scripts/setup-codex-workspace.sh
   cd "$PROJECT_PATH"
   ```

   On the first run the script installs `kubectl`, writes `configs/kubeconfig-nodeport`, syncs the same content into `~/.kube/config` (backing up any previous file), records the HTTPS bridge PID in `configs/https-bridge.pid`, and annotates every `AGENTS.md` under your project with the active bridge PID and bridge status.

3. **Maintenance script**

   When Codex restores a cached container it executes the maintenance helper. Reuse the same snippet from the setup step; the script now always checks the stored HTTPS bridge metadata, refreshes the `AGENTS.md` notice, and restarts the bridge only when the process or health checks fail. No dedicated `--service-scenario` flag is required anymore.

   ```bash
   set -euo pipefail
   export PROJECT_PATH="$(pwd)"
   cd /workspace/k8s-expose-apiserver || exit 0
   ./scripts/setup-codex-workspace.sh
   cd "$PROJECT_PATH"
   ```

### 6.1 Optional inputs
The helper accepts the following environment variables and CLI arguments in addition to `GW_NODE` and `K8S_TOKEN`:

| Variable | Default | Purpose |
| --- | --- | --- |
| `GW_NODE` | — | Hostname or IP (optionally with `:port`) of the gateway node/edge. Pair with `GW_NODE_PORT` when only the host is provided. |
| `GW_NODE_PORT` | — | NodePort exposed by the service when `GW_NODE` omits the port. When unset the helper falls back to `GW_NODE_FALLBACK_SCHEME` (default `https`) for DNS hostnames, but still aborts for bare IPs. |
| `GW_NODE_FALLBACK_SCHEME` | `https` | Scheme to assume when `GW_NODE` lacks a port. Set to an empty string to restore the previous "fail-fast" behaviour or override with `http` when your DNS endpoint speaks clear-text. |
| `GW_ENDPOINT` | auto-derived | Full endpoint used in the kubeconfig. Overrides the values derived from `GW_NODE`. |
| `GW_SCHEME` | — | Forces the scheme (`http`/`https`) when `GW_ENDPOINT` lacks one. |
| `GW_AUTO_TLS` | `1` | When `GW_SCHEME` is unset and `GW_ENDPOINT` lacks a scheme, automatically assume HTTPS for ports that look like TLS endpoints (ports ending in `443`, plus `6443`). Set to `0` to disable the heuristic. |
| `GW_AUTO_TLS_PORTS` | — | Comma-separated list of additional port numbers that should always imply HTTPS when `GW_AUTO_TLS` is enabled. |
| `HTTPS_BRIDGE_TARGET` | — | HTTPS URL that the local HTTP bridge should forward to. Required when reaching KeenDNS or other TLS frontends. |
| `HTTPS_BRIDGE_LISTEN_HOST` / `HTTPS_BRIDGE_LISTEN_PORT` | `127.0.0.1` / `18080` | Where the local HTTP listener should bind. |
| `K8S_TOKEN` | — | Client bearer token written into the kubeconfig (store in Codex **Secrets**). |
| `K8S_CA_FILE` / `GW_CA_FILE` | — | Path to a CA bundle that should be embedded into the kubeconfig. |
| `K8S_CA_DATA_B64` / `GW_CA_DATA_B64` | — | Base64-encoded CA content if you prefer to supply it inline. |
| `K8S_CA_DATA` / `GW_CA_DATA` | — | Raw (not base64) CA content; the script will encode it. |
| `K8S_TLS_SERVER_NAME` / `GW_TLS_SERVER_NAME` | — | Overrides the TLS server name for SNI/verification when reaching HTTPS gateways. |
| `K8S_INSECURE_SKIP_TLS_VERIFY` / `GW_INSECURE_SKIP_TLS_VERIFY` | — | Set to `true`/`1` to bypass certificate verification (discouraged). |
| `CLUSTER_NAME` | `gw-nodeport` | Name of the cluster entry inside the generated kubeconfig. |
| `USER_NAME` | `codex-gw` | User entry name stored inside the kubeconfig. |
| `CTX_NAME` | `nodeport` | Context name selected as current-context. |
| `KUBECTL_VERSION` | latest stable | Specific kubectl release to download when installation is required. |
| `KUBECTL_INSTALL_DIR` | `$HOME/.local/bin` | Directory that will contain the kubectl binary when auto-installed. |
| `SKIP_KUBECTL_INSTALL` | `0` | Set to `1` to fail instead of auto-installing kubectl. |
| `SYNC_DEFAULT_KUBECONFIG` | `1` | Set to `0` to skip mirroring the generated kubeconfig into `~/.kube/config`. |
| `OUT_PATH` (CLI arg) | `configs/kubeconfig-nodeport` | Output path for the generated kubeconfig; can also be provided as the first positional argument. |

### 6.2 After the setup script finishes
- The script already mirrors the kubeconfig into `~/.kube/config`, so `kubectl` works immediately. Keep `/workspace/k8s-expose-apiserver/configs/kubeconfig-nodeport` around if you want to reference it explicitly or share it elsewhere.
- Extend `NO_PROXY` with the Node IP/hostname or, when using the HTTPS bridge, with the local listener (e.g. `export NO_PROXY="${NO_PROXY},127.0.0.1"`).
- Tail `configs/https-bridge.log` if you need to debug the local HTTP→HTTPS bridge.
- The generated notice in each `AGENTS.md` lists the bridge PID, proxy URL, and reminders about the local listener.
- Each run stops any previously recorded HTTPS bridge PID before launching a fresh instance, so a stale process never interferes with a new setup.
- The helper refuses to succeed unless both `kubectl --request-timeout=5s version` and `kubectl --request-timeout=5s get ns` pass when executed against the freshly generated kubeconfig, so you can immediately invoke `kubectl` without extra steps.

## 7. Validate kubectl Access
After either the setup or maintenance run completes, confirm connectivity inside the Codex shell:

```bash
kubectl --request-timeout=10s version
kubectl get ns
```

When the HTTPS bridge is enabled you can also probe the upstream endpoint through the proxy:

```bash
curl --proxy http://127.0.0.1:18080 -H "Authorization: Bearer $K8S_TOKEN" -k "${HTTPS_BRIDGE_TARGET}/version"
```

`401` responses usually mean `K8S_TOKEN` is missing, while timeouts suggest that the gateway host is absent from `NO_PROXY` or that the recorded bridge PID is no longer running (see `configs/https-bridge.pid`).

## 8. Security Notes
- `AUTH_MODE=inject` is effectively cluster-admin for anyone who can reach the gateway. Protect the NodePort with network policies, firewalls, or an external auth layer. Export `ALLOW_INJECT=1` only after you accept this risk.
- Rotate the service-account token by deleting the secret (`kubectl -n k8s-gw delete secret codex-gw-token`) and rerunning the deploy script.
- Store workspace tokens in Codex **Secrets**, not plain variables or scripts committed to Git.

## 9. Cleanup
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
