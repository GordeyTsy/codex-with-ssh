# Kubernetes Connectivity Diagnostic Report (Generation 1)

## Summary
- Reproduced the `kubectl` failure in this environment: TLS handshake aborts because the presented certificate lacks any IP Subject Alternative Names (SANs) for `193.164.155.89`, so Go-based clients refuse it.
- Direct egress to the cluster IPs (`193.164.155.89`, `62.118.136.124`) is blocked; traffic must traverse the corporate HTTP proxy (`proxy:8080`).
- The proxy performs TLS interception and substitutes its own certificate (`CN=egress-proxy`) without IP SAN entries, triggering the validation error.
- Even when the proxy variables are cleared, the connection still flows through the intercepting proxy (likely via transparent routing), so the SAN issue persists.
- Compared against the "known-good" remote server results, confirming that the cluster endpoint is healthy and reachable when no proxy MITM is involved.

## Environment Observations
- `kubectl` client: `v1.34.1` with Go's strict SAN checking. `KUBECONFIG` points at `.kube/config`, targeting `https://193.164.155.89:10443` (alternate endpoint `62.118.136.124:10443`).
- Global proxy variables (`HTTP(S)_PROXY=http://proxy:8080`, etc.) are exported; additional trust bundles reference `/usr/local/share/ca-certificates/envoy-mitmproxy-ca-cert.crt`.
- Cluster CA embedded in the kubeconfig is self-issued (`CN=kubernetes`, valid 2025-2035) and differs from the MITM certificate actually observed from this environment.

## Tests Performed

### 1. Baseline kubectl call
```bash
KUBECONFIG=.kube/config kubectl get pods -n kube-system
```
Result: Fails with `tls: failed to verify certificate: x509: cannot validate certificate for 193.164.155.89 because it doesn't contain any IP SANs`.

### 2. Inspect proxy-related environment
```bash
env | grep -i proxy
```
Result: Multiple proxy variables force HTTPS traffic through `proxy:8080`.

### 3. Probe API directly with curl (bypass proxy)
```bash
curl -vk --noproxy '*' https://193.164.155.89:10443/version
```
Result: Immediate `Network is unreachable`, showing direct routing is blocked.

### 4. Probe API with curl through proxy
```bash
curl -vk https://193.164.155.89:10443/version
curl -vk https://62.118.136.124:10443/version
```
Result: CONNECT tunnel established via proxy, but proxy returns its own certificate (`CN=egress-proxy`, issuer `CN=egress-proxy`) and the upstream connection ultimately fails with `upstream connect error ... Connection refused`. The substituted certificate lacks IP SAN entries.

### 5. Attempt kubectl with proxy variables cleared
```bash
HTTPS_PROXY= HTTP_PROXY= KUBECONFIG=.kube/config kubectl get nodes
```
Result: Same SAN validation failure, indicating transparent interception or inherited proxy settings.

### 6. Verbose kubectl trace
```bash
HTTPS_PROXY= HTTP_PROXY= KUBECONFIG=.kube/config kubectl --v=8 get --raw /healthz
```
Result: Confirms the request still hits `https://193.164.155.89:10443/healthz` and aborts during TLS verification with the identical SAN error.

### 7. Extract cluster CA certificate
```bash
KUBECONFIG=.kube/config kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > /tmp/kube-ca.crt
openssl x509 -in /tmp/kube-ca.crt -noout -subject -issuer -dates -fingerprint -sha256
```
Result: CA is self-issued (`CN=kubernetes`). Its fingerprint does not match the `egress-proxy` certificate presented via the HTTP proxy.

### 8. Reference remote test results
Reviewed `test-main-server-results.txt` and `test-remote-server-results.txt`, which demonstrate successful `kubectl` operations from network locations without the intercepting proxy, confirming the cluster endpoints are healthy.

## Findings & Root Cause
1. **Mandatory proxy path** — All outbound HTTPS traffic to the cluster IPs is forced through `proxy:8080`; direct routing is unavailable. The proxy implements TLS interception, replacing the Kubernetes API server certificate.
2. **Certificate mismatch** — The substituted certificate (`CN=egress-proxy`) lacks any IP SAN entries, so Go's TLS stack (used by `kubectl`) cannot validate it for an IP-based URL. This triggers the error seen in all kubectl invocations.
3. **Upstream reachability via proxy** — Even with interception, the proxy cannot reach the Kubernetes control plane (`Connection refused`). This suggests the proxy cannot open the upstream TCP connection, possibly due to firewall rules blocking it, or the proxy intentionally denying that destination.

Because the remote diagnostics show normal operation without the proxy, the issue is isolated to this environment's egress controls rather than the Kubernetes cluster itself.

## Recommendations
1. **Avoid TLS interception for cluster IPs**
   - Ask the network team to disable TLS MITM for `193.164.155.89` and `62.118.136.124`, or to add static bypass rules so traffic is not routed through the intercepting proxy.
   - Alternatively, request a DNS name for the API server and ensure the proxy-presented certificate contains the corresponding SAN, then update the kubeconfig to use that DNS name.
2. **Allow raw connectivity through the proxy**
   - Ensure the proxy is permitted to open TCP tunnels to ports `10443` on both cluster IPs; the current `Connection refused` indicates the proxy or upstream firewall blocks it.
3. **Short-term workaround (if policy allows)**
   - Establish an SSH/VPN tunnel to a host with working kubectl access (e.g., the remote VDS) and proxy kubectl through that tunnel.
   - Or, run kubectl directly on a machine inside the cluster network where the proxy is not enforcing TLS interception.

## Optional Server-Side Tests
If you can run commands from the Kubernetes control plane network, please capture:
1. `openssl s_client -connect 193.164.155.89:10443 -showcerts | openssl x509 -noout -subject -issuer -text | head -n 20`
   - Confirms the API server certificate details (SAN entries, issuer) without proxy interference.
2. `sudo iptables -nvL | grep 10443`
   - Verifies there are no firewall rules blocking the proxy's subnet.
3. `sudo ss -tnlp | grep 10443`
   - Ensures the API server is listening on the expected address/port.

Recording these results will help demonstrate to the network team that the cluster endpoint is healthy and that the problem lies in the proxy/TLS interception path.
