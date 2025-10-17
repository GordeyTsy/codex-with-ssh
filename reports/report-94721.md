# Kubernetes Connectivity Investigation Report

## Summary
- Confirmed `kubectl` v1.34.1 is installed locally, but all cluster calls using `.kube/config` fail TLS validation because the presented certificate lacks the target IP address in its Subject Alternative Name (SAN).【038395†L1-L3】【49798c†L3-L5】
- Outbound HTTPS is transparently intercepted by an Envoy MITM proxy that serves a self-signed `CN=egress-proxy` certificate, and direct egress to `62.118.136.124:10443` is blocked, so the genuine API server certificate cannot be observed from this environment.【9a764d†L1-L47】【2636c9†L1-L8】
- The kubeconfig’s embedded CA certificate only contains `DNS:kubernetes`, so even without interception the configuration is incompatible with modern Go TLS rules when connecting by IP address.【6e694e†L1-L34】【0a9d22†L1-L44】
- Remote test results provided by the user show the real API server presents `CN=kube-apiserver` with matching IP SANs and accepts TLS, confirming the cluster itself is healthy; the discrepancy stems from local network/proxy constraints.

## Local Environment Facts
- `kubectl version --client` → `Client Version: v1.34.1` (modern client, enforces SAN requirements).【038395†L1-L3】
- Attempting `kubectl version` without a kubeconfig tries `localhost:8080` and is refused (expected default behaviour).【54bdd9†L1-L4】
- Current kubeconfig targets `https://193.164.155.89:10443` and includes a bearer token for `team-a-dev` namespace access.【6e694e†L1-L34】
- Proxy-related environment variables force HTTPS through `http://proxy:8080`; disabling them still leaves the direct route unreachable (errno 101).【26aef4†L1-L18】【2636c9†L1-L8】

## TLS & Connectivity Diagnostics
| Command | Observation |
| --- | --- |
| `KUBECONFIG=.kube/config kubectl get --raw=/version` | TLS handshake fails: `x509: cannot validate certificate for 193.164.155.89 because it doesn't contain any IP SANs`.【98a0d3†L1-L3】 |
| `KUBECONFIG=.kube/config kubectl --context team-a-dev@kubernetes get --raw=/healthz` | Same SAN validation failure; API server not reachable through trusted chain.【31ba6d†L1-L4】 |
| `curl -vk https://62.118.136.124:10443` (proxy on) | Envoy MITM terminates TLS, presents `CN=egress-proxy`, upstream connection ultimately fails with `503`/`remote connection failure`; the real cluster certificate is never seen.【9a764d†L1-L47】 |
| `HTTPS_PROXY=…= curl -vk https://62.118.136.124:10443` (proxy bypass attempt) | Direct TCP connect immediately returns `Network is unreachable`, showing hard network block.【2636c9†L1-L8】 |
| `openssl s_client -connect 62.118.136.124:10443 -showcerts </dev/null` | Fails locally with `Network is unreachable`, corroborating the direct egress block.【ac85dc†L1-L6】 |

## Certificate Findings
- Decoded CA bundle from the kubeconfig is self-signed `CN=kubernetes` with **only** `DNS:kubernetes` in its SAN list, no IP entries.【0a9d22†L1-L44】
- Because the kubeconfig references the cluster by IP, Go-based clients reject the handshake when the serving certificate (as intercepted) lacks that IP SAN. Historical clients that accepted Common Name fallback would have succeeded, explaining reports of “working elsewhere.”

## Comparison With Remote (User-Provided) Tests
The user-supplied diagnostics from `root@main-vpn-fr` demonstrate:
- `kubectl get --raw=/version` succeeds and reports Kubernetes `v1.32.1`.
- `openssl s_client -connect 62.118.136.124:10443 -servername kubernetes -showcerts` retrieves a certificate issued by `CN=kubernetes` for `CN=kube-apiserver` **with IP SANs** `10.96.0.1`, `10.0.70.200`, `62.118.136.124`, and `193.164.155.89`.
- `curl -vk https://62.118.136.124:10443` reaches the API server and receives `HTTP/2 403` (expected for anonymous access), proving server-side TLS is configured correctly.
These results confirm the cluster itself is reachable and properly configured when the connection is made from a trusted network without interception.

## Root Cause Assessment
1. **Mandatory Proxy Interception:** All outbound HTTPS from the sandbox is intercepted by an Envoy MITM proxy that presents its own certificate without the cluster IP in SAN, breaking TLS validation for modern `kubectl` builds.【9a764d†L1-L47】
2. **Direct Egress Blocked:** Even when proxy variables are cleared, direct routing to `62.118.136.124:10443` is blocked (`Network is unreachable`), preventing us from bypassing the proxy to reach the authentic certificate.【2636c9†L1-L8】【ac85dc†L1-L6】
3. **Certificate Policy Mismatch:** The kubeconfig embeds a CA whose SAN list lacks the IP address, so any certificate signed by it must include the IP SAN. The real server certificate does, but the proxy-issued certificate does not, causing the verification error observed locally.【0a9d22†L1-L44】【49798c†L3-L5】

## Recommended Next Steps
### For Local/Sandbox Environment
1. **Request Proxy Exemption:** Ask infrastructure owners to add `62.118.136.124` and `193.164.155.89` to the proxy bypass list, or provide a SOCKS/VPN path that avoids TLS interception. This will allow `kubectl` to see the genuine server certificate.
2. **Import Proxy CA (short-term workaround):** If bypassing the proxy is impossible, import the MITM proxy CA and regenerate a kubeconfig whose cluster endpoint is addressed by a DNS name that matches the proxy-issued certificate SAN. This requires coordination with proxy administrators and may still violate security expectations.
3. **Use Alternative Environment:** Execute Kubernetes commands from a host on the same network as `root@main-vpn-fr`, where direct connectivity and correct certificates are available.

### For Cluster Administrators (if changes are acceptable)
1. **Provide DNS Endpoint:** Publish a DNS name (e.g., `kubernetes.example.com`) present in the kube-apiserver certificate SANs and update the kubeconfig server URL accordingly, ensuring compatibility even behind SAN-stripping proxies.
2. **Supply Updated CA Bundle:** Distribute the correct CA chain (including intermediate if any) so that clients can verify TLS when the proxy is bypassed.

## Outstanding Server-Side Checks (Optional)
No additional server-side tests are required at this time because the user-supplied results already confirm healthy API server TLS behaviour. If further validation is desired, re-run the following from a trusted host and share the outputs:
1. `kubectl --context team-a-dev@kubernetes get --raw=/healthz`
2. `openssl s_client -connect 62.118.136.124:10443 -servername kubernetes -showcerts | openssl x509 -noout -ext subjectAltName`
