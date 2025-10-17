# Kubernetes Connectivity Diagnostic Report (Generation 1)

## Overview
- **Date:** 2025-10-12
- **Environment:** OpenAI sandbox container `/workspace/obsidian-k8s-web-client`
- **Kubeconfig under test:** `.kube/config` (default context `team-a-dev@kubernetes`, API server `https://193.164.155.89:10443` with CA bundle and token embedded)
- **Reference:** Same kubeconfig is known to work from the French VDS host provided by the user.

## Executive Summary
1. When the sandbox honours the default outbound proxy (`http://proxy:8080`), `kubectl` fails TLS validation because the proxy terminates TLS and substitutes its own certificate (`CN=egress-proxy`) that lacks IP Subject Alternative Names for either cluster endpoint.
2. When the proxy is bypassed, TCP connections to both `193.164.155.89:10443` and `62.118.136.124:10443` fail immediately with `Network is unreachable`, demonstrating that the sandbox has no direct route to either API endpoint.
3. Because of points 1 and 2, no successful handshake with the real Kubernetes API occurs, so the embedded CA data and service-account token never get used by the client.
4. The working behaviour on the VDS host indicates that the cluster itself is healthy; the problem is specific to this sandbox network perimeter.

## Detailed Test Log

| Step | Command | Result |
| --- | --- | --- |
| 1 | `cat .kube/config` | Confirmed context, embedded CA, and token for `https://193.164.155.89:10443`. |
| 2 | `KUBECONFIG=.kube/config kubectl version` | TLS verification fails: `x509: cannot validate certificate ... doesn't contain any IP SANs`. |
| 3 | `curl -vk https://193.164.155.89:10443/version` | Through proxy: CONNECT succeeds, proxy serves `CN=egress-proxy` certificate, returns `503 upstream connect error ... Connection refused`. |
| 4 | `curl -vk https://62.118.136.124:10443/version` | Identical behaviour via proxy as Step 3. |
| 5 | `env | grep -i proxy` | Shows enforced proxy variables (`HTTP(S)_PROXY=http://proxy:8080`). |
| 6 | `HTTPS_PROXY= HTTP_PROXY= https_proxy= http_proxy= kubectl version` | With proxy disabled, request fails earlier: `dial tcp ... connect: network is unreachable`. |
| 7 | `HTTPS_PROXY= HTTP_PROXY= https_proxy= http_proxy= curl -vk https://193.164.155.89:10443/version` | Immediate connect failure `Network is unreachable`. |
| 8 | `HTTPS_PROXY= HTTP_PROXY= https_proxy= http_proxy= curl -vk https://62.118.136.124:10443/version` | Same `Network is unreachable` failure. |
| 9 | `openssl s_client -connect 193.164.155.89:10443 </dev/null` | Without proxy support, exits with `connect:errno=101 (Network is unreachable)`. |
| 10 | `nc -vz 193.164.155.89 10443` and `nc -vz 62.118.136.124 10443` | Both report `Network is unreachable`, confirming Layer-3 egress block. |

Command transcripts are included below.

### Step 1 – kubeconfig inspection
```
$ cat .kube/config
(apiVersion, clusters, users ...)
```

### Step 2 – kubectl through proxy
```
$ KUBECONFIG=.kube/config kubectl version
Client Version: v1.34.1
Kustomize Version: v5.7.1
Unable to connect to the server: tls: failed to verify certificate: x509: cannot validate certificate for 193.164.155.89 because it doesn't contain any IP SANs
```

### Step 3 – curl via proxy (193.164.155.89)
```
$ curl -vk https://193.164.155.89:10443/version
* CONNECT proxy:8080
* Server certificate: CN=egress-proxy (OpenAI)
< HTTP/1.1 503 Service Unavailable
upstream connect error or disconnect/reset before headers. reset reason: remote connection failure, transport failure reason: delayed connect error: Connection refused
```

### Step 4 – curl via proxy (62.118.136.124)
```
$ curl -vk https://62.118.136.124:10443/version
* CONNECT proxy:8080
* Server certificate: CN=egress-proxy (OpenAI)
< HTTP/1.1 503 Service Unavailable
upstream connect error or disconnect/reset before headers. reset reason: remote connection failure, transport failure reason: delayed connect error: Connection refused
```

### Step 5 – proxy variables
```
$ env | grep -i proxy
HTTP_PROXY=http://proxy:8080
HTTPS_PROXY=http://proxy:8080
(no_proxy excludes the cluster IPs)
```

### Step 6 – kubectl without proxy
```
$ HTTPS_PROXY= HTTP_PROXY= https_proxy= http_proxy= KUBECONFIG=.kube/config kubectl version
Client Version: v1.34.1
Kustomize Version: v5.7.1
Unable to connect to the server: dial tcp 193.164.155.89:10443: connect: network is unreachable
```

### Steps 7 & 8 – curl without proxy
```
$ HTTPS_PROXY= HTTP_PROXY= https_proxy= http_proxy= curl -vk https://193.164.155.89:10443/version
* Immediate connect fail ... Network is unreachable
```
```
$ HTTPS_PROXY= HTTP_PROXY= https_proxy= http_proxy= curl -vk https://62.118.136.124:10443/version
* Immediate connect fail ... Network is unreachable
```

### Step 9 – openssl direct test
```
$ openssl s_client -connect 193.164.155.89:10443 </dev/null
... connect:errno=101
```

### Step 10 – netcat probes
```
$ nc -vz 193.164.155.89 10443
nc: connect to 193.164.155.89 port 10443 (tcp) failed: Network is unreachable
```
```
$ nc -vz 62.118.136.124 10443
nc: connect to 62.118.136.124 port 10443 (tcp) failed: Network is unreachable
```

## Conclusions & Recommendations
- The sandbox cannot reach either API endpoint directly (likely due to outbound firewalling). Even if direct connectivity were allowed, the enforced HTTP(S) proxy would still need to be bypassed or extended with correct TLS interception certificates and routing to the cluster.
- To restore functionality you can:
  1. **Allow direct egress** from the sandbox to ports `10443/tcp` on `193.164.155.89` and `62.118.136.124`, and add those IPs to the `no_proxy` list; *or*
  2. **Configure the proxy** to forward these destinations without TLS interception, importing the Kubernetes API CA into the proxy trust store; *or*
  3. **Set up a bastion/VPN** (for example, SSH tunnel through the working VDS host) and point `kubectl` at `https://127.0.0.1:<forwarded-port>` with matching `no_proxy` entries.

## Optional Server-Side Checks
If you need corroborating evidence from the cluster side, please collect the following and share the outputs:
1. `kubectl get apiservices` and `kubectl get --raw='/readyz?verbose'` from a host that has connectivity (e.g., the French VDS) to confirm the API server is healthy.
2. `sudo ss -tnlp | grep 10443` on the control-plane node(s) to verify the listener is up and bound to both public IPs.
3. `sudo journalctl -u kube-apiserver --since "10 minutes ago"` to confirm there are no recent errors.
