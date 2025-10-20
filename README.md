# Codex SSH Bastion

*A Russian translation is available in [README.ru.md](README.ru.md).*

This repository deploys a managed SSH bastion inside a trusted Kubernetes cluster and provides a container image that records every connection for audit purposes.

## 1. Components included
- **Images** – [`images/ssh-bastion/`](images/ssh-bastion/) contains the Dockerfile, entrypoint, and helper utilities (`codex-hostctl`, SSH/SCP/SFTP wrappers). The image is published as `codex-ssh-bastion` and runs OpenSSH with additional telemetry.
- **Manifests** – [`manifests/ssh-bastion/`](manifests/ssh-bastion/) stores templates for the Namespace, PVC, ConfigMap, Deployment, and Service. They are parameterised through environment variables and rendered by the deployment script.
- **Persistent storage** – by default the pod mounts a PVC at `/var/lib/codex-ssh`, which keeps the inventory (`inventory.json`) and user labels (`labels.json`). When necessary the PVC can be replaced with a node `hostPath` directory.
- **Scripts** – [`scripts/deploy-ssh-bastion.sh`](scripts/deploy-ssh-bastion.sh) renders the manifests, optionally refreshes the `authorized_keys` secret, and prints follow-up instructions.

## 2. Container architecture
The Debian-based image launches OpenSSH Server and an entrypoint script that:
1. Creates a passwordless `codex` system user and prepares `/var/lib/codex-ssh` with permissions `700`.
2. Copies `authorized_keys` from the Kubernetes secret into `~codex/.ssh/authorized_keys` and enforces mode `600`.
3. Moves the system `ssh/scp/sftp` binaries to `/opt/codex-ssh/originals/` and replaces them with wrappers that parse `-J`, `-p/-P`, `-o ProxyJump`, then record routing details in `inventory.json`.
4. Generates host keys (`ssh-keygen -A`), applies the `sshd_config` snippet from the ConfigMap, and renders the MOTD with the current inventory.
5. Provides the `codex-hostctl` CLI with the following commands:
   - `codex-hostctl list` – table view of the inventory.
   - `codex-hostctl export` – JSON output with `id`, `name`, `target`, `port`, `jump_chain`, `fingerprint`, `last_seen` (consumed by Codex workspaces).
   - `codex-hostctl rename <id> <name>` – assign a readable alias to a host.
   - `codex-hostctl motd` – generate the message of the day from the inventory (used by the entrypoint).

## 3. Deploying to Kubernetes
```bash
SSH_NAMESPACE=codex-ssh \
SSH_SERVICE_NODE_PORT=32222 \
SSH_BASTION_IMAGE=codex-ssh-bastion:latest \
SSH_IMAGE_REGISTRY=ghcr.io/gordeytsy \
SSH_AUTHORIZED_SECRET=ssh-authorized-keys \
scripts/deploy-ssh-bastion.sh
```

The script requires `kubectl` and `envsubst`. It generates a temporary directory with manifests and applies the Namespace, PVC, ConfigMap, Deployment, and Service in sequence. When the `authorized_keys` secret is missing, the script creates a fresh `ed25519` key pair (configurable) and prints the private key so it can be stored as the Codex workspace secret. When `SSH_AUTHORIZED_KEYS_FILE` is present, the secret is refreshed with `kubectl create secret generic ... --dry-run=client | kubectl apply -f -` instead of generating a new key.

### 3.1 Configurable variables
| Variable | Purpose | Default |
| --- | --- | --- |
| `SSH_NAMESPACE` | Namespace that holds all resources. | `codex-ssh` |
| `SSH_DEPLOYMENT_NAME` | Deployment name. | `ssh-bastion` |
| `SSH_SERVICE_NAME` | Service name. | `ssh-bastion` |
| `SSH_SERVICE_TYPE` | Service type (`NodePort`, `LoadBalancer`, `ClusterIP`). | `NodePort` |
| `SSH_SERVICE_NODE_PORT` | Fixed NodePort (used only when type is `NodePort`). | `32222` |
| `SSH_NODE_NAME` | Pin the pod to a specific node (leave empty to rely on the scheduler). | — |
| `SSH_PVC_NAME` | PersistentVolumeClaim name. | `codex-ssh-data` |
| `SSH_PVC_SIZE` | Requested volume size. | `1Gi` |
| `SSH_STORAGE_CLASS` | StorageClass (leave empty to use the cluster default). | — |
| `SSH_STORAGE_TYPE` | Storage backend (`pvc` or `hostpath`). | `pvc` |
| `SSH_HOSTPATH_PATH` | Node path for the hostPath volume (required when `SSH_STORAGE_TYPE=hostpath`). | — |
| `SSH_CONFIGMAP_NAME` | ConfigMap name with the MOTD and `sshd_config` snippet. | `ssh-bastion-config` |
| `SSH_AUTHORIZED_SECRET` | Secret that contains `authorized_keys`. | `ssh-authorized-keys` |
| `SSH_BASTION_IMAGE` | Image tag without the registry prefix. | `codex-ssh-bastion:latest` |
| `SSH_IMAGE_REGISTRY` | Registry prefix (leave empty if the tag is already fully qualified). | — |
| `SSH_MOTD_CONTENT` | Base MOTD text (split into lines). | `Codex SSH bastion\nИспользуйте codex-hostctl list, чтобы увидеть найденные цели.` |
| `SSH_AUTHORIZED_KEYS_FILE` | Local path to the `authorized_keys` file for secret refresh. | — |
| `SSH_GENERATE_WORKSPACE_KEY` | Auto-generate a workspace key pair (`auto`, `true`, `false`). | `auto` |
| `SSH_WORKSPACE_KEY_TYPE` | Key type for generation (`ed25519`, `rsa`, ...). | `ed25519` |
| `SSH_WORKSPACE_KEY_COMMENT` | Comment stored in the generated key. | `codex@workspace` |

When `SSH_STORAGE_TYPE=hostpath` the script skips the PVC manifest and mounts the supplied node path directly.

After applying the manifests the script prints reminders:
- `kubectl -n <ns> rollout status deployment/<deploy>` – check the deployment rollout.
- `kubectl -n <ns> get svc <service> -o wide` – inspect the NodePort or external IP.
- Test command `ssh -p <node-port> codex@<node-ip>` (or via ProxyJump).
- Snippet for refreshing the `authorized_keys` secret.
- Command to export the inventory: `kubectl exec ... -- codex-hostctl export`.

## 4. Managing the `authorized_keys` secret
1. By default the deployment script generates a new key pair whenever the `authorized_keys` secret is missing and prints the private key for the Codex workspace secret (`SSH_KEY`).
2. To manage the secret manually, prepare an `authorized_keys` file (for example, `ssh-keygen -t ed25519 -f ./codex-ssh && cat codex-ssh.pub > authorized_keys`).
3. Update the secret:
   ```bash
   kubectl -n ${SSH_NAMESPACE:-codex-ssh} create secret generic ${SSH_AUTHORIZED_SECRET:-ssh-authorized-keys} \
     --from-file=authorized_keys=./authorized_keys --dry-run=client -o yaml | kubectl apply -f -
   ```
4. Restart the deployment if needed: `kubectl -n ${SSH_NAMESPACE} rollout restart deployment/${SSH_DEPLOYMENT_NAME}`.
5. Inspect the logs: `kubectl -n ${SSH_NAMESPACE} logs deployment/${SSH_DEPLOYMENT_NAME}` – the entrypoint warns when keys are missing or have incorrect permissions.

## 5. Working with `codex-hostctl`
Inside the pod the files `/var/lib/codex-ssh/inventory.json` and `/var/lib/codex-ssh/labels.json` are available. Common scenarios:
- `kubectl exec deploy/${SSH_DEPLOYMENT_NAME} -- codex-hostctl list` – table with target hosts.
- `kubectl exec deploy/${SSH_DEPLOYMENT_NAME} -- codex-hostctl rename srv-01:22 prod-srv-01` – assign a readable name.
- `kubectl exec deploy/${SSH_DEPLOYMENT_NAME} -- codex-hostctl export > inventory.json` – export for synchronisation inside the workspace.

The SSH/SCP/SFTP wrappers automatically invoke `codex-hostctl record ...`, adding an entry on every connection. Fingerprints are filled with `ssh-keyscan` (5-second timeout).

## 6. Persistent storage and security
- The PVC is mounted with permissions `0700`; consequently, ProxyJump chains and custom names survive pod restarts.
- The `sshd_config` disables password login, root access, and X11, allowing only the `codex` user and `internal-sftp`.
- The container runs `sshd` as root (required for the daemon), while user sessions run as `codex`.
- The MOTD is refreshed during container start and prints the list of available targets so operators see up-to-date information.

## 7. Codex workspace integration
- The workspace must use the external NodePort (or LoadBalancer) address and the private key that matches `authorized_keys`.
- Workspace scripts can poll `codex-hostctl export` via `kubectl exec` to synchronise `inventory.json`.
- To display custom labels, run `codex-hostctl rename` inside the cluster; the changes remain on the PVC across restarts.

## 8. Building the image
After updating the sources, rebuild the image:
```bash
docker build -t "${SSH_IMAGE_REGISTRY:-<public-registry>}/codex-ssh-bastion:latest" images/ssh-bastion
```
and push it to the required registry before rolling out the deployment.

## 9. Shutting down and cleanup
To temporarily stop the bastion without deleting resources:
```bash
kubectl -n ${SSH_NAMESPACE:-codex-ssh} scale deployment/${SSH_DEPLOYMENT_NAME:-ssh-bastion} --replicas=0
```

For a full teardown (choose the commands that match your storage type):
```bash
kubectl -n ${SSH_NAMESPACE:-codex-ssh} delete deployment/${SSH_DEPLOYMENT_NAME:-ssh-bastion} \
  service/${SSH_SERVICE_NAME:-ssh-bastion} \
  configmap/${SSH_CONFIGMAP_NAME:-ssh-bastion-config} \
  secret/${SSH_AUTHORIZED_SECRET:-ssh-authorized-keys}

# Remove the PVC when it is in use (skip for hostPath)
kubectl -n ${SSH_NAMESPACE:-codex-ssh} delete pvc/${SSH_PVC_NAME:-codex-ssh-data}

# Delete the namespace only if it is dedicated to the bastion
kubectl delete namespace ${SSH_NAMESPACE:-codex-ssh}
```
When `SSH_STORAGE_TYPE=hostpath` remove the on-node directory manually if it is no longer needed.
