# Kubernetes Connectivity Investigation Report

## Overview
- **Date:** 2025-10-12
- **Environment:** Obsidian web client container (`root@4dfdf4d06543`)
- **Tooling:** `kubectl v1.34.1`
- **Objective:** Diagnose why `kubectl` cannot reach the remote Kubernetes API that works from the French VDS reference host.

## Findings Summary
1. The container initially has no kubeconfig, so `kubectl` defaults to `localhost:8080` and immediately fails with a connection refusal. 【F:report-73125.md†L15-L17】【97d07a†L1-L4】
2. Injecting the provided kubeconfig allows `kubectl` to reach `https://193.164.155.89:10443`, but every request fails during TLS verification because the presented server certificate lacks an IP Subject Alternative Name (SAN) for `193.164.155.89`. 【7019c6†L1-L7】【758c47†L1-L17】【ee6fc8†L1-L18】
3. Outbound traffic in this environment is forced through the corporate HTTP(S) proxy (`proxy:8080`), and direct connections to the cluster IP are blocked (`Network is unreachable`). 【1ed8d3†L1-L18】【0a5e79†L1-L3】
4. The proxy establishes an HTTPS tunnel to the cluster, but the cluster’s certificate still fails validation even when using the supplied CA bundle (`unsuitable certificate purpose`). 【56f723†L1-L34】

## Detailed Test Log
| Step | Command | Result |
|------|---------|--------|
| 1 | `kubectl version` | Client at v1.34.1; server unreachable because default localhost endpoint refused connection. 【97d07a†L1-L4】 |
| 2 | `kubectl config view` | Empty configuration confirmed (no clusters, contexts, or users). 【7019c6†L1-L7】 |
| 3 | Added supplied kubeconfig to `~/.kube/config` | Configuration loads correctly (verified via verbose request logging). 【ee6fc8†L1-L18】 |
| 4 | `kubectl get pods -A --request-timeout=5s` | TLS handshake fails: `x509: cannot validate certificate ... no IP SANs`. 【758c47†L1-L17】 |
| 5 | `env | grep -i proxy` | Environment enforces HTTP(S) proxy `proxy:8080`. 【1ed8d3†L1-L18】 |
| 6 | `ping 193.164.155.89` | Direct network path blocked (`Network is unreachable`). 【0a5e79†L1-L3】 |
| 7 | `curl --cacert /tmp/kube-ca.crt https://193.164.155.89:10443/version -v` | HTTPS tunnel established through proxy, but TLS fails (`unsuitable certificate purpose`). 【56f723†L1-L34】 |

## Preliminary Conclusions
- The toolbox container can only reach the cluster through the corporate proxy. The proxy allows the TLS handshake to complete but does not mitigate the certificate validation failure.
- The Kubernetes API server (or the certificate presented through the proxy tunnel) does not advertise the external IP `193.164.155.89` in its Subject Alternative Name. Go 1.15+ based clients (including `kubectl v1.34.1`) require a matching SAN entry for IP-based connections, so the handshake aborts.
- This behavior differs from the reference host either because it trusts a different CA, uses a hostname instead of the IP, or runs an older `kubectl`/Go toolchain that still honored the deprecated CN fallback.

## Recommended Next Steps
1. **Server-side:** Issue an API server certificate that includes the public IP (or a routable DNS name) in its SAN list, or expose the API via a hostname and update the kubeconfig accordingly.
2. **Client-side workaround:** If immediate remediation is needed, consider adding `insecure-skip-tls-verify: true` for the cluster entry (not recommended long-term) or establishing a local DNS entry that maps a certificate-approved hostname to the IP.
3. **Network confirmation:** Validate from the server side whether the API server presents a certificate with proper SANs and whether any middleboxes alter the certificate chain. (Please provide results if additional remote tests are performed.)

## Pending External Tests
- [ ] Confirm from the server side which SANs are included in the certificate served at `193.164.155.89:10443`.
- [ ] Verify whether the reference host relies on a hostname or different kubeconfig when accessing the cluster.

