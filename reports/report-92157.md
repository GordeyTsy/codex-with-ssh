# Kubernetes Connectivity Investigation Report

## Overview
- **Date:** 2025-10-12 16:16:32 UTC
- **Context:** Diagnosing why `kubectl` cannot access the remote cluster using the provided kubeconfig.

## Environment Checks
- `kubectl` client version: `v1.34.1` (built with Go 1.22) as reported by `kubectl version --client`. This enforces strict x509 SAN checks for IP-based endpoints.
- System-wide proxy variables are configured to route HTTPS traffic through `http://proxy:8080`. (`HTTPS_PROXY`, `HTTP_PROXY`, and related variables are set.)

## Test Matrix

| # | Test | Command | Result |
|---|------|---------|--------|
| 1 | Baseline API call via kubeconfig | `KUBECONFIG=.kube/config kubectl get pods -A` | **Fail** – TLS validation error `x509: cannot validate certificate for 193.164.155.89 because it doesn't contain any IP SANs` |
| 2 | Disable TLS verification | `KUBECONFIG=.kube/config kubectl --insecure-skip-tls-verify=true get pods -A` | **Fail** – Proxy forwards request but upstream responds `503 ServiceUnavailable` |
| 3 | Disable proxy usage | `HTTPS_PROXY= HTTP_PROXY= ... kubectl get pods -A` | **Fail** – Direct routing blocked with `connect: network is unreachable` |
| 4 | Raw HTTPS check through proxy | `curl -v https://193.164.155.89:10443/api --cacert envoy-mitmproxy-ca-cert.crt` | **Fail** – TLS handshake aborted: `SSL certificate problem: unsuitable certificate purpose` |
| 5 | Inspect proxy-issued certificate | `openssl s_client -proxy proxy:8080 -connect 193.164.155.89:10443 -servername 193.164.155.89 | openssl x509 -noout -text` | **Observation** – Proxy generates certificate with SAN type **DNS** = `193.164.155.89`, no IP SAN entry. |

## Findings

1. **Proxy interception:** Outbound HTTPS is intercepted by an Envoy-based proxy that issues its own certificates. Evidence: `curl` shows the CONNECT tunnel terminates at `proxy:8080`, and the presented certificate is issued by `CN=egress-proxy`.
2. **SAN mismatch:** The proxy-signed certificate encodes the cluster IP as a DNS SAN (`DNS:193.164.155.89`) instead of an IP SAN. Go-based clients (including kubectl v1.34.1) treat numeric hostnames as IP literals and require an `IP Address` SAN. Hence the TLS verification failure in Test #1.
3. **Direct access blocked:** When bypassing the proxy (clearing `HTTPS_PROXY`), connections fail with `connect: network is unreachable`, indicating egress to `193.164.155.89:10443` is not permitted except through the proxy.
4. **Insecure skip still broken:** Even with TLS verification disabled, the proxy returns `503 ServiceUnavailable`, suggesting the proxy cannot successfully establish TLS with the upstream API server when the client does not validate certificates (likely because the proxy expects mutual TLS validation to succeed).

## Conclusions
- The kubeconfig itself is valid (works on external VDS), but this environment's mandatory HTTPS proxy rewrites certificates in a way incompatible with Go's IP SAN requirements.
- Since direct egress is blocked, `kubectl` cannot reach the cluster without the proxy fixing its certificate generation (adding an IP SAN entry) or without switching the kubeconfig server endpoint to a DNS name that appears in the certificate SANs.

## Recommended Next Steps
1. **Proxy configuration fix:** Update the proxy to include an `IP Address` SAN for numeric hosts when minting certificates, or disable certificate rewriting for the cluster endpoint.
2. **Use DNS endpoint (if available):** If the Kubernetes API is reachable via a hostname, update the kubeconfig `server:` field to that DNS name so that the proxy-issued certificate's DNS SAN matches.
3. **Proxy bypass (if policy allows):** Extend `NO_PROXY` with `193.164.155.89` and ensure routing permits direct egress; otherwise this will continue to fail.
4. **Server-side tests:** Pending – please run from the server side: `kubectl get --raw=/readyz` and share output to confirm API health.

