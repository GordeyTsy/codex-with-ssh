# Codex SSH Bastion

*A Russian translation is available in [README.ru.md](README.ru.md).*

This repository delivers an SSH bastion that lives inside a trusted Kubernetes cluster and keeps track of every hop that passes through it. The image ships with wrappers around `ssh/scp/sftp` that capture jump chains and fingerprints, while the deployment script renders all manifests and prints the exact values you need to configure a Codex workspace.

---

## 1. What’s in the repository

- **Image sources** – [`images/ssh-bastion/`](images/ssh-bastion/) contains the Dockerfile, entrypoint, telemetry wrappers, and the `codex-hostctl` CLI.
- **Manifest templates** – [`manifests/ssh-bastion/`](manifests/ssh-bastion/) keeps namespace, ConfigMap, Deployment, and Service templates. They are filled via `envsubst` during deployment.
- **Host script** – [`scripts/deploy-ssh-bastion.sh`](scripts/deploy-ssh-bastion.sh) is the single entry point: it can (optionally) build/push the image, applies manifests, waits for rollout, and prints the Codex-facing endpoint together with the SSH private key.
- **Workspace script** – [`scripts/setup-codex-workspace.sh`](scripts/setup-codex-workspace.sh) installs the private key, refreshes `~/.ssh/config`, wires in the HTTP-based tunnel helper, and keeps the AGENTS documentation in sync.

---

## 2. Deploying on the admin host

Requirements: `kubectl`, `envsubst`, `docker` (when `SSH_BUILD_IMAGE=true` or a registry push is needed).

1. Adjust the environment (see [.env.host.example](.env.host.example)). In particular:
   - `SSH_PUBLIC_HOST` – the address exposed to Codex (for example `<keen-dns-domain>` that forwards to your node).
   - `SSH_SERVICE_NODE_PORT` – the NodePort forwarded by your router or load balancer.
   - `SSH_STORAGE_TYPE`/`SSH_HOSTPATH_PATH` – choose `hostpath` when you want a shared directory such as `/srv/codex-ssh`.
2. Run the deployment script from this repository:

   ```bash
   set -a
   source .env.host.example
   set +a
   scripts/deploy-ssh-bastion.sh
   ```

   The script restarts the deployment, waits for the rollout, then prints four key lines:

   ```
   SSH_GW_NODE=<keen-dns-domain>:443
   SSH_GW_USER=codex
   SSH_GW_TOKEN=<generated-secret>
   SSH_KEY=-----BEGIN OPENSSH PRIVATE KEY-----…
   ```

   Copy them immediately—Codex needs `SSH_GW_NODE`/`SSH_GW_USER`/`SSH_GW_TOKEN` as variables and `SSH_KEY` as a secret. KeenDNS terminates on port 443, so workspaces that can only issue TLS-friendly `CONNECT` requests are able to reach the bastion. Raw `ssh` against `<keen-dns-domain>:443` will fail by design—the HTTPS tunnel is mandatory.

3. Validate from the admin host (replace placeholders as required):

   ```bash
   kubectl -n codex-ssh get pods -o wide
   kubectl -n codex-ssh get svc ssh-bastion -o wide
  curl -i http://<node-ip>:32222/healthz   # expect HTTP 200 from the HTTP tunnel gateway
   kubectl -n codex-ssh port-forward service/ssh-bastion-internal 2222:22 &
   ssh -p 2222 codex@127.0.0.1      # остановите port-forward после проверки (Ctrl+C)
   ```

   A successful login prints the MOTD with the known targets.

---

## 3. Configure the Codex workspace

1. In **Settings → Variables** add: 
  - `SSH_GW_NODE=<keen-dns-domain>:443` (port 443 keeps corporate proxies happy because they only allow TLS-friendly tunnels).
  - `SSH_GW_USER=codex`
  - `SSH_GW_TOKEN=<the token printed by the deploy script>`
  - *(optional)* `SSH_HTTP_INSECURE=1` if your HTTPS endpoint presents a mismatched or self-signed certificate.
2. In **Settings → Secrets** add: `SSH_KEY=<the private key printed by the deploy script>`.
3. In the workspace container, run:

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

   The helper script writes the key to `configs/id-codex-ssh`, injects a managed `ProxyCommand` that invokes `scripts/ssh-http-proxy.py`, refreshes `~/.ssh/config`, downloads the bastion inventory, and updates any `AGENTS.md` it finds.

   If the Codex container resumes from cache, rerun the helper manually unless you configured the maintenance script in step 4.
   ```bash
   export PROJECT_PATH="$(pwd)"
   cd /workspace/codex-with-ssh || exit 0
   ./scripts/setup-codex-workspace.sh
   cd "$PROJECT_PATH"
   ```
4. For long-lived environments, place the same snippet into Codex’ **Maintenance script** so the configuration is re-applied when the container resumes.

### 3.1 Optional TLS alternatives

The default setup relies on a NodePort that KeenDNS (or another reverse proxy) forwards over HTTPS. If your cluster supports a direct HTTPS endpoint you can:

- Expose the Service as `LoadBalancer` (`SSH_SERVICE_TYPE=LoadBalancer`) and supply `SSH_PUBLIC_HOST`/`SSH_PUBLIC_PORT` with the allocated address.
- Or terminate TLS via an Ingress controller and point KeenDNS (or an external DNS record) at the ingress host. In that case set `SSH_PUBLIC_SCHEME=https` and use the ingress hostname in `SSH_PUBLIC_HOST`.

The workspace flow remains unchanged: Codex still connects through the HTTP tunnel helper using the HTTPS URL you provide.

### 3.2 Workspace smoke test

After the helper has updated your SSH config you can run a non-interactive smoke test that proves the HTTPS HTTP tunnel works end-to-end from inside Codex:

```bash
cd /workspace/codex-with-ssh
./scripts/test-http-tunnel.sh
```

The script writes the private key to a temporary location, composes a one-off `ssh_config` with the managed `ProxyCommand`, and executes `codex-hostctl list` through the bastion. It streams the proxy’s verbose logs to stderr, so any failure (network reachability, authentication, inventory access) is immediately visible. This makes the helper suitable for Codex’ “Tests” hook; you only need the same variables and secret from step 3.

---

## 4. Configurable variables

| Variable | Purpose | Default |
| --- | --- | --- |
| `SSH_NAMESPACE` | Namespace that holds all resources. | `codex-ssh` |
| `SSH_DEPLOYMENT_NAME` | Deployment name. | `ssh-bastion` |
| `SSH_SERVICE_NAME` | Service name. | `ssh-bastion` |
| `SSH_SERVICE_TYPE` | Service exposure mode (`NodePort`, `LoadBalancer`, `ClusterIP`). | `NodePort` |
| `SSH_SERVICE_PORT` | Service port exposed to the tunnel clients. | `80` |
| `SSH_SERVICE_NODE_PORT` | NodePort bound on each node (only used for `NodePort`). | `32222` |
| `SSH_PUBLIC_HOST` | Public DNS name (KeenDNS or similar) that fronts the NodePort. | — |
| `SSH_PUBLIC_PORT` | Public port served by the reverse proxy. | `443` |
| `SSH_PUBLIC_SCHEME` | URL scheme advertised to Codex (usually `https`). | `https` |
| `SSH_HTTP_TUNNEL_PORT` | Container port listened by the HTTP tunnel gateway. | `8080` |
| `SSH_HTTP_INSECURE` | Set to `1` to let the workspace helper skip TLS verification (useful for self-signed or mismatched certificates). | `0` |
| `SSH_HTTP_SNI` | Override SNI/Host header passed by the proxy helper. | — |
| `SSH_HTTP_CA_FILE` | Custom CA bundle path consumed by the proxy helper. | — |
| `SSH_TUNNEL_SECRET_NAME` | Secret storing `user:token` for the tunnel. | `ssh-bastion-tunnel` |
| `SSH_TUNNEL_USER` | Username for the tunnel. | `codex` |
| `SSH_TUNNEL_TOKEN` | Optional fixed token; empty value lets the script generate one. | – |
| `SSH_STORAGE_TYPE` | Persistent storage backend (`auto`, `pvc`, `hostpath`). | `auto` |
| `SSH_HOSTPATH_PATH` | HostPath directory (used when storage is `hostpath`). | — |
| `SSH_IMAGE_REGISTRY` | Registry prefix for pushing the bastion image. | — |
| `SSH_BUILD_IMAGE`/`SSH_PUSH_IMAGE` | Control local image build/push. | `auto`/`(derived)` |
| `SSH_GENERATE_WORKSPACE_KEY` | Auto-generate `authorized_keys` when absent. | `auto` |
| `SSH_MOTD_CONTENT` | Text printed before the dynamic MOTD. | Multi-line default |

## 5. What the bastion records

- Every `ssh/scp/sftp` invocation runs through the wrappers in `/opt/codex-ssh/bin`. They analyse `ProxyJump` chains, record each hop, and store the result in `/var/lib/codex-ssh/inventory.json`.
- The MOTD lists all known targets in the format `alias: user@host`. When you log in through Codex you instantly see every destination that was previously discovered—even when reaching it requires a multi-hop chain that includes on-prem nodes.
- For direct, in-cluster maintenance you can use the internal service `ssh-bastion-internal.codex-ssh.svc.cluster.local:22` (for example, start a debug pod and run `ssh codex@ssh-bastion-internal.codex-ssh.svc.cluster.local`).
- Use `codex-hostctl` inside the pod for manual adjustments:
  - `codex-hostctl list` – table view rendered in the terminal.
  - `codex-hostctl export` – JSON export consumed by the workspace helper.
  - `codex-hostctl rename <id> <new-alias>` – change human-friendly labels (`KeeneticOS` → `router`, etc.).
  - `codex-hostctl motd` – regenerate the banner that appears on login.
- Inventory and labels live on the PVC/hostPath, so restarts or new pods reuse the same data. Scale above one replica only when you back the bastion with a shared volume (PVC is recommended for multi-replica setups).

---

## 6. Maintenance

- **Rotate keys** – rerun the deploy script. With `SSH_GENERATE_WORKSPACE_KEY=auto` it produces a new key whenever the secret is absent; to reuse your own key, set `SSH_AUTHORIZED_KEYS_FILE=<path>` before executing the script.
- **Rotate the tunnel token** – set `SSH_TUNNEL_TOKEN=<new-token>` before running the deploy script; otherwise the existing credentials are retained and printed again.
- **Update the image** – either build locally (`SSH_BUILD_IMAGE=true`) or push a prebuilt tag (`SSH_IMAGE_REGISTRY=<registry>`). The deploy script automatically restarts the deployment after applying manifests.
- **Troubleshooting** – `kubectl -n codex-ssh logs deploy/ssh-bastion` tails the bastion logs; readiness relies on a simple TCP probe to port 22.

---

## 7. Cleanup

```bash
kubectl -n codex-ssh delete deployment/ssh-bastion service/ssh-bastion service/ssh-bastion-internal \
  configmap/ssh-bastion-config secret/ssh-authorized-keys
kubectl -n codex-ssh delete pvc/codex-ssh-data   # skip for hostPath deployments
# Optional: kubectl delete namespace codex-ssh
```

When using hostPath storage, remove the on-node directory manually once the deployment is gone.
