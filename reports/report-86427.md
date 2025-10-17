# Kubernetes Connectivity Diagnostic Report (Environment A)

## Overview
- **Date:** 2025-10-12
- **Environment:** `/workspace/obsidian-k8s-web-client` (OpenAI-provided sandbox)
- **Kubeconfig:** `.kube/config` (points to `https://193.164.155.89:10443`, namespace `team-a`, service account token `team-a-dev`)
- **Objective:** Investigate why `kubectl` fails while the same kubeconfig is known to work from the French VDS bastion.

## Summary of Findings
1. `kubectl` cannot complete TLS handshakes because the outbound HTTPS proxy (`http://proxy:8080`) terminates TLS and presents an `egress-proxy` certificate that lacks SAN entries for `193.164.155.89`. Consequently, the Go TLS stack aborts before any Kubernetes API call is issued.
2. Direct connections from the sandbox to `193.164.155.89:10443` are blocked at the network layer (`connect: errno=101`), preventing us from bypassing the proxy or validating the upstream API certificate directly with `openssl`.
3. All HTTPS traffic routed through the proxy receives HTTP 503 `upstream connect error` responses, indicating the proxy itself cannot reach the Kubernetes API endpoint.
4. The kubeconfig embedded CA bundle therefore never takes effect, and the error message (`x509: cannot validate certificate ... because it doesn't contain any IP SANs`) reflects the proxy certificate, not the actual apiserver certificate. The same kubeconfig works on the French VDS because that host has direct network reachability and no intercepting proxy.

## Detailed Test Log

| Step | Command | Result |
| --- | --- | --- |
| 1 | `KUBECONFIG=.kube/config kubectl version` | Client info prints, server handshake fails: `tls: failed to verify certificate ... doesn't contain any IP SANs`. |
| 2 | `KUBECONFIG=.kube/config kubectl get --raw=/version` | Same TLS failure as Step&nbsp;1. |
| 3 | `KUBECONFIG=.kube/config kubectl get --raw=/healthz` | Same TLS failure as Step&nbsp;1. |
| 4 | `KUBECONFIG=.kube/config kubectl cluster-info` | Repeats the TLS failure on every discovery attempt. |
| 5 | `openssl s_client -connect 193.164.155.89:10443 -servername kubernetes -showcerts </dev/null` | Fails immediately with `Network is unreachable (errno 101)`, confirming we cannot establish a direct TCP connection to the cluster. |
| 6 | `curl -vk https://193.164.155.89:10443[/healthz]` | Uses the sandbox HTTPS proxy, succeeds in creating a CONNECT tunnel, but the TLS server certificate is `CN=egress-proxy`. Proxy responds with `503 Service Unavailable` / `upstream connect error ... Connection refused`. |
| 7 | `echo $HTTPS_PROXY` | Shows proxy configured as `http://proxy:8080`, so all HTTPS clients (including `kubectl`) will traverse it unless `no_proxy` is amended. |

Command transcripts are included below for completeness.

### 1. Kubectl version probes
```
$ KUBECONFIG=.kube/config kubectl version
Client Version: v1.34.1
Kustomize Version: v5.7.1
Unable to connect to the server: tls: failed to verify certificate: x509: cannot validate certificate for 193.164.155.89 because it doesn't contain any IP SANs
```
```
$ KUBECONFIG=.kube/config kubectl get --raw=/version
Unable to connect to the server: tls: failed to verify certificate: x509: cannot validate certificate for 193.164.155.89 because it doesn't contain any IP SANs
```
```
$ KUBECONFIG=.kube/config kubectl cluster-info
...
Unable to connect to the server: tls: failed to verify certificate: x509: cannot validate certificate for 193.164.155.89 because it doesn't contain any IP SANs
```

### 2. Direct TLS attempts
```
$ openssl s_client -connect 193.164.155.89:10443 -servername kubernetes -showcerts </dev/null
...
connect:errno=101
```

### 3. Proxy-mediated HTTPS attempts
```
$ curl -vk https://193.164.155.89:10443
* Uses proxy env variable https_proxy == 'http://proxy:8080'
* CONNECT 193.164.155.89:10443 HTTP/1.1
< HTTP/1.1 503 Service Unavailable
...
upstream connect error or disconnect/reset before headers. reset reason: remote connection failure, transport failure reason: delayed connect error: Connection refused
```
```
$ curl -vk https://193.164.155.89:10443/healthz
(same proxy 503 response as above)
```

### 4. Environment variables
```
$ echo $HTTPS_PROXY
http://proxy:8080
```

## Comparison with Working Bastion (User-provided reference)
The French VDS host reports:
- `kubectl version --client --short` → `Client Version: v1.34.1`
- `kubectl version --server --short` → successfully reaches API `v1.32.1`
- `openssl s_client -connect 62.118.136.124:10443` → receives the real `CN=kube-apiserver` certificate signed by `CN=kubernetes` with SANs for `62.118.136.124` and `193.164.155.89`.
- `curl -vk https://62.118.136.124:10443` → gets HTTP 403 Forbidden (expected for anonymous access), proving layer 4 reachability.

This contrast shows the kubeconfig itself and the cluster certificates are valid; the issue is isolated to outbound connectivity restrictions in the sandbox.

## Conclusions
- The sandbox is behind an egress proxy that intercepts TLS and cannot reach `193.164.155.89:10443`. Because the proxy certificate does not match the target IP, `kubectl` aborts with an IP SAN error.
- Direct egress to `193.164.155.89:10443` is blocked (no route), so the proxy is the only path but is misconfigured or firewalled from the cluster.

## Recommended Remediations
1. **Add an explicit bypass:** Set `no_proxy=193.164.155.89,62.118.136.124` (and export the same for uppercase variants) before running `kubectl`, assuming direct routing can be enabled.
2. **Open outbound firewall rules:** Allow the sandbox to reach `193.164.155.89:10443` (or `62.118.136.124:10443`) without going through the intercepting proxy.
3. **If proxy usage is mandatory:** Import the proxy's CA certificate into a custom trust store and configure `kubectl` with `SSL_CERT_FILE` pointing to it, then ensure the proxy itself is allowed to reach the Kubernetes API.
4. **Validate post-change:** Re-run the kubectl and curl tests listed above to confirm successful 200/401/403 responses instead of TLS errors.

## (Optional) Follow-up Tests for Bastion Operator
If verification from the bastion side is required, please run the following and share the output:
1. `date && kubectl --context team-a-dev@kubernetes get --raw=/readyz`
2. `curl -vk https://62.118.136.124:10443/livez?verbose`
3. `openssl s_client -connect 62.118.136.124:10443 -servername kubernetes -showcerts | openssl x509 -noout -issuer -subject -ext subjectAltName`
These will confirm API readiness endpoints and certificate SANs remain healthy on the cluster side.
