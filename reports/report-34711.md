# Kubernetes Connectivity Diagnostic Report

## Summary
- `kubectl` is installed (v1.34.1) but cannot reach the cluster endpoint defined in `.kube/config`.
- When proxy variables are active, TLS handshakes fail because the presented certificate lacks an IP Subject Alternative Name (SAN) for `193.164.155.89`.
- Bypassing the proxy removes the TLS error but the outbound TCP connection to `193.164.155.89:10443` is blocked (`Network is unreachable`).
- The embedded cluster CA certificate only advertises `DNS:kubernetes`, so IP-based access requires reissuing certificates or switching to a DNS host.

## Environment Checks
- `kubectl version --client` → `Client Version: v1.34.1`, confirming the CLI is present. 【3eca53†L1-L3】
- Current context from `.kube/config` is `team-a-dev@kubernetes`. 【7b1d84†L2-L32】【edeb9a†L1-L3】
- HTTP(S) traffic is routed through `proxy:8080` by default. 【415196†L1-L18】

## Connectivity & TLS Tests
1. **Baseline API call through proxy**
   ```bash
   KUBECONFIG=.kube/config kubectl get pods -A -o wide
   ```
   Result: TLS validation error — `x509: cannot validate certificate for 193.164.155.89 because it doesn't contain any IP SANs`. 【d1c619†L1-L16】

2. **Cluster info via same kubeconfig**
   ```bash
   KUBECONFIG=.kube/config kubectl cluster-info
   ```
   Result: Same TLS error referencing the missing IP SAN. 【bd3788†L1-L17】

3. **Skip TLS verification (still proxied)**
   ```bash
   KUBECONFIG=.kube/config kubectl --insecure-skip-tls-verify=true get namespaces
   ```
   Result: Proxy reaches upstream but returns `503 Service Unavailable`. 【8e2e3d†L1-L12】

4. **Disable proxy variables for the call**
   ```bash
   HTTPS_PROXY= HTTP_PROXY= https_proxy= http_proxy= KUBECONFIG=.kube/config kubectl get pods -A
   ```
   Result: Fails earlier with `dial tcp 193.164.155.89:10443: connect: network is unreachable`, proving the proxy is the only allowed egress path. 【d2c8e7†L1-L12】

5. **Direct ICMP/TCP probes without proxy**
   - `ping -c 4 193.164.155.89` → `Network is unreachable`. 【657566†L1-L2】
   - `openssl s_client -connect 193.164.155.89:10443 -servername kubernetes` → network unreachable (errno 101). 【6f7771†L1-L6】

6. **Inspect proxied HTTPS session**
   ```bash
   curl -vk https://193.164.155.89:10443/version
   ```
   Observations: traffic goes through `proxy:8080`, Envoy serves a self-signed `CN=egress-proxy` certificate and returns `503 Service Unavailable` because the upstream refused the connection. 【32bb23†L1-L46】

## Certificate Analysis
- The kubeconfig embeds a certificate authority whose SAN list contains only `DNS:kubernetes`, no IP entries. 【5e62be†L1-L17】【44fe60†L1-L38】
- Modern Go clients (including `kubectl v1.34`) require an IP SAN when connecting via IP; CN fallback is disabled, leading to the observed TLS failure.

## Conclusions
- Requests must traverse the corporate proxy, which intercepts TLS and does not supply an IP SAN matching `193.164.155.89`. Even if the proxy allowed the TLS handshake, the upstream cluster certificate also lacks an IP SAN.
- Disabling the proxy is not an option because raw egress to the cluster IP is blocked.
- The cluster becomes reachable only if either (a) a DNS name with a matching SAN is used in the kubeconfig, (b) the proxy is configured to tunnel without interception and the API server certificate is regenerated with the IP SAN, or (c) firewall rules are adjusted to permit direct egress.

## Suggested Server-Side / External Tests
Run these from a host that can already access the cluster and share the outputs for correlation:
1. `kubectl version --short`
2. `kubectl get --raw=/version`
3. `openssl s_client -connect 193.164.155.89:10443 -showcerts`
4. `openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep -A3 "Subject Alternative Name"`

These checks confirm the upstream certificate SANs and ensure the API server is healthy when contacted without the proxy.
