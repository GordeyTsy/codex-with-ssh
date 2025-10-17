# Kubernetes Connectivity Diagnostic Report

## 1. Context
- Reference kubeconfig: `.kube/config` (context `team-a-dev@kubernetes`).
- Objective: explain why `kubectl` in this sandbox cannot reach the cluster that is reachable from the user's French VDS host.

## 2. Local Environment Findings (sandbox)
| Check | Command | Result |
| --- | --- | --- |
| `kubectl` CLI build | `kubectl version --client` | Client `v1.34.1` available; CLI itself works. 【50f049†L1-L3】 |
| Attempted short flag | `kubectl version --short` | Fails: flag not supported by this client build. 【2eef59†L2-L4】 |
| Server version probe | `kubectl version` | TLS handshake fails: proxy certificate lacks IP SAN for `193.164.155.89`. 【ffd9ff†L1-L5】 |
| Raw version endpoint | `kubectl get --raw=/version` | Same TLS failure because presented cert has no IP SAN. 【c87c1a†L1-L3】 |
| Health probe | `kubectl --context team-a-dev@kubernetes get --raw=/healthz` | TLS failure identical to above. 【dbf45c†L1-L3】 |
| Direct OpenSSL (no proxy support) | `openssl s_client -connect 62.118.136.124:10443 …` | Direct TCP blocked (`Network is unreachable`). 【d8f263†L1-L6】 |
| Proxy OpenSSL pipe | `… | openssl x509 -noout -text` | Unable to fetch certificate because TCP connect blocked pre-proxy. 【08b8b0†L1-L8】 |
| Proxy curl to API | `curl -vk https://62.118.136.124:10443` | Traffic forced through Envoy proxy; proxy presents self-signed `CN=egress-proxy` cert and returns 503 before upstream connection. 【fe2b8d†L1-L47】 |
| Proxy curl to `/healthz` | `curl -vk https://62.118.136.124:10443/healthz` | Same proxy certificate and `503` error; upstream never reached. 【310640†L1-L47】 |
| Proxy configuration | `echo $HTTPS_PROXY` | `http://proxy:8080`, confirming mandatory egress proxy. 【7b9583†L1-L2】 |
| Local CA in kubeconfig | decoded `certificate-authority-data` | Trust anchor is `CN=kubernetes` with only DNS SANs (no IP entries). 【94d0e7†L16-L41】 |
| Local host CA path | `openssl x509 -in /etc/kubernetes/pki/apiserver.crt -text` | File absent in sandbox (no local control plane). 【899bf0†L1-L7】 |

## 3. Observations from User's Working Host (French VDS)
- User-supplied `openssl s_client` output shows the real API server presents `CN=kube-apiserver` with SANs including `62.118.136.124` and `193.164.155.89`, valid until Oct 2026.
- `curl -vk https://62.118.136.124:10443` from that host reaches the API server and receives a `403 Forbidden` as anonymous user, demonstrating the control plane is reachable and enforces RBAC.
- `kubectl get --raw=/version` succeeds remotely, reporting Kubernetes `v1.32.1`.

## 4. Root Cause Analysis
1. **Mandatory egress proxy** — All HTTPS requests from this sandbox traverse `proxy:8080` (Envoy). The proxy performs TLS interception and reissues certificates signed by its own CA (`CN=egress-proxy`). 【fe2b8d†L1-L40】【310640†L1-L40】
2. **Proxy certificate lacks required SANs** — The intercepted certificate contains only `CN=egress-proxy` and no Subject Alternative Names for the target IP. Go 1.22+ (used by kubectl v1.34) rejects such certificates, yielding `x509: cannot validate certificate … because it doesn't contain any IP SANs`. 【ffd9ff†L1-L5】【c87c1a†L1-L3】
3. **Direct path blocked** — Attempting to bypass the proxy with raw TCP (`openssl s_client`) fails with `Network is unreachable`, so the sandbox cannot contact the cluster without the proxy. 【d8f263†L1-L6】
4. **Cluster certificate itself is valid** — Remote host confirms the real API server certificate already includes the public IPs, so the issue is not server misconfiguration but the intermediary proxy in this sandbox.

## 5. Recommended Remediation Steps
### Client-side (sandbox)
1. **Trust the proxy CA** — Import the Envoy proxy CA into the local trust store or set `SSL_CERT_FILE`/`REQUESTS_CA_BUNDLE` so Go accepts the reissued cert (must also include SANs or use DNS hostname).
2. **Use DNS name routed via proxy** — If the proxy certificate includes SANs for a DNS hostname (e.g., `kubernetes`), update kubeconfig `server:` field to that DNS name instead of IP so SAN validation passes.
3. **Request proxy exception** — Ask network admins to add `62.118.136.124:10443` / `193.164.155.89:10443` to `NO_PROXY` and permit direct egress.

### Server / Network-side (if client changes are impossible)
1. **Provide proxy SANs** — Reconfigure the Envoy TLS interception layer to mint certificates with SAN entries that include the upstream IP or a stable DNS name.
2. **Expose DNS endpoint** — Publish a DNS name (e.g., `kube-api.example`) that resolves internally and matches SAN entries, then update kubeconfig accordingly.

## 6. Optional Follow-up Tests for the Server Team
Please run these from the trusted environment (e.g., the French VDS) and share the outputs if further confirmation is needed:
1. `openssl s_client -connect 193.164.155.89:10443 -servername kubernetes -showcerts`
2. `curl -vk https://193.164.155.89:10443/healthz`
3. `kubectl --context team-a-dev@kubernetes get --raw=/readyz`

These will validate that the control plane remains reachable directly and that readiness endpoints respond as expected.
