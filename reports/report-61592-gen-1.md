# Kubernetes Connectivity Diagnostic Report (Generation 1)

## Summary
- `kubectl` reaches neither control-plane endpoint (`62.118.136.124` nor `193.164.155.89`) because the Envoy HTTPS proxy in this workspace terminates TLS and reissues certificates that only contain DNS-type SANs, triggering Go's IP SAN validation error. 【b8052e†L1-L16】【5ef222†L1-L14】【76591b†L1-L9】【236aa6†L1-L9】
- Even when the TLS verification is bypassed, the proxy cannot reach the upstream API servers and returns `503 Service Unavailable`, so API traffic never leaves the proxy. 【bd9b69†L1-L43】【3e0188†L1-L42】
- Attempts to bypass the proxy altogether fail immediately with `Network is unreachable`, proving direct egress to either endpoint is blocked from this environment. 【9c1669†L1-L7】【27a66e†L1-L7】【30560d†L1-L5】【ff48bf†L1-L5】
- Server-side diagnostics previously collected from the cluster show that the real kube-apiserver certificate already contains both public IPs in its SAN list, so the problem is isolated to the intercepting proxy path. 【F:test-main-server-results.txt†L193-L210】

## Environment Observations
- `kubectl version` (client only) demonstrates the SAN verification failure against `62.118.136.124`. 【f5a691†L1-L5】
- Proxy variables are globally enforced (`HTTP(S)_PROXY=http://proxy:8080`, etc.), confirming that all HTTPS traffic is forced through Envoy unless explicitly exempted. 【a55807†L1-L18】

## Detailed Findings

### 1. Kubernetes client failures
```bash
$ KUBECONFIG=~/.kube/config kubectl get pods -A -o wide
... tls: failed to verify certificate: x509: cannot validate certificate for 62.118.136.124 because it doesn't contain any IP SANs
```
```bash
$ KUBECONFIG=~/.kube/config-193 kubectl get pods -A
... tls: failed to verify certificate: x509: cannot validate certificate for 193.164.155.89 because it doesn't contain any IP SANs
```
The kubeconfig points at IP literals. When the proxy forges a certificate whose SAN is typed as DNS instead of IP, Go's TLS stack rejects it before sending any API calls. 【b8052e†L1-L16】【5ef222†L1-L14】【76591b†L1-L9】【236aa6†L1-L9】

### 2. Behaviour when forced through the proxy
```bash
$ curl -vk https://62.118.136.124:10443/version
* CONNECT proxy:8080
* Server certificate: CN=egress-proxy
< HTTP/1.1 503 Service Unavailable
upstream connect error ... Connection refused
```
```bash
$ curl -vk https://193.164.155.89:10443/version
* CONNECT proxy:8080
* Server certificate: CN=egress-proxy
< HTTP/1.1 503 Service Unavailable
upstream connect error ... Connection refused
```
Envoy successfully performs the CONNECT handshake but ultimately fails to establish the upstream TCP session, so every request dies at the proxy. 【bd9b69†L1-L43】【3e0188†L1-L42】

### 3. Behaviour when bypassing the proxy
```bash
$ HTTPS_PROXY= HTTP_PROXY= ... curl -vk https://62.118.136.124:10443/version
* Immediate connect fail ... Network is unreachable
```
```bash
$ HTTPS_PROXY= HTTP_PROXY= ... curl -vk https://193.164.155.89:10443/version
* Immediate connect fail ... Network is unreachable
```
```bash
$ timeout 5 openssl s_client -connect 62.118.136.124:10443
connect:errno=101
```
```bash
$ timeout 5 openssl s_client -connect 193.164.155.89:10443
connect:errno=101
```
Removing the proxy variables proves there is no permitted route to either IP/port pair from this sandbox. 【9c1669†L1-L7】【27a66e†L1-L7】【30560d†L1-L5】【ff48bf†L1-L5】

### 4. Certificate inspection via proxy
```bash
$ openssl s_client -proxy proxy:8080 -connect 62.118.136.124:10443 -servername 62.118.136.124 | openssl x509 -noout -ext subjectAltName
X509v3 Subject Alternative Name: critical
    DNS:62.118.136.124
```
```bash
$ openssl s_client -proxy proxy:8080 -connect 193.164.155.89:10443 -servername 193.164.155.89 | openssl x509 -noout -ext subjectAltName
X509v3 Subject Alternative Name: critical
    DNS:193.164.155.89
```
The Envoy-issued leaf certificates lack IP-type SAN entries, causing the `x509` validation error seen in `kubectl`. 【76591b†L1-L9】【236aa6†L1-L9】

### 5. Comparison with authoritative server data
Existing diagnostics from the control-plane host confirm the genuine kube-apiserver certificate already carries SANs for both public IPs, as well as the service CIDRs. Therefore, only the proxy-issued certificate is incorrect. 【F:test-main-server-results.txt†L193-L210】

## Recommended Remediation Paths
1. **Request a proxy bypass** for `62.118.136.124:10443` and `193.164.155.89:10443` so `kubectl` can negotiate TLS directly with the cluster.
2. **Alternatively, adjust the Envoy interception policy** to embed IP-type SAN entries in the reissued certificates for these endpoints. Without IP SANs, Go clients will continue to fail.
3. If neither is possible, establish an alternate transport (SSH tunnel, VPN, SOCKS proxy) that lets the workstation reach the API server without TLS interception.

## Optional Follow-up Tests (if additional confirmation is needed)
If you can run checks from a network path without the TLS-intercepting proxy, please share the outputs of:
1. `curl -vk https://193.164.155.89:10443/version`
2. `openssl s_client -connect 193.164.155.89:10443 -servername kubernetes -showcerts | openssl x509 -noout -ext subjectAltName`
These will verify the second advertised endpoint behaves identically to the first when accessed directly.
