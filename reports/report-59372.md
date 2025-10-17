# Kubernetes Access Diagnostics Report

## Summary
- `kubectl` is installed (v1.34.1) but, without an explicit kubeconfig path, defaults to `http://localhost:8080` and fails to reach a cluster.
- A kubeconfig is available at `.kube/config`, yet API calls using it fail with `x509: cannot validate certificate for 62.118.136.124 because it doesn't contain any IP SANs`.
- Outbound traffic goes through an Envoy proxy that presents a self-signed `CN=egress-proxy` certificate without an IP Subject Alternative Name for the cluster endpoint, leading to TLS validation errors in modern `kubectl` builds.
- Direct connections to `62.118.136.124:10443` (without the proxy) appear blocked from this environment, resulting in `Network is unreachable` errors for raw TCP/ICMP probes.

## Environment Checks
- `kubectl version --client` → `Client Version: v1.34.1` confirming the CLI is present. *(see `kubectl version --client` output)*
- `kubectl get pods` (no kubeconfig) attempts `http://localhost:8080` and fails with connection refused. *(see `kubectl get pods` output)*
- `.kube/config` exists in the repo and defines the `team-a-dev@kubernetes` context. *(see `cat .kube/config` & `kubectl config get-contexts` outputs)*

## Connectivity & TLS Tests (using `.kube/config`)
- `KUBECONFIG=.kube/config kubectl version` and `kubectl get pods -A` both fail with `tls: failed to verify certificate... IP SANs`. *(see respective command outputs)*
- `kubectl --kubeconfig .kube/config cluster-info` repeats the same TLS validation failure. *(see command output)*
- Disabling `HTTP(S)_PROXY` for the command does not change the TLS error, indicating certificate verification happens before any proxy bypass succeeds. *(see command output with proxy vars cleared)*

## Network Layer Observations
- `ping 62.118.136.124` → `Network is unreachable`, so ICMP is blocked. *(see ping output)*
- `curl -vk https://62.118.136.124:10443` goes through proxy `proxy:8080`, negotiates TLS with a self-signed `CN=egress-proxy` certificate, then fails because the proxy cannot reach the upstream (`503 Service Unavailable`). *(see verbose curl output)*
- `openssl s_client -connect 62.118.136.124:10443` without proxy support fails with `Network is unreachable`, confirming direct TCP to the cluster IP is not allowed from this environment. *(see openssl output)*

## Certificate Inspection
- Decoded the embedded `certificate-authority-data` and confirmed it is a self-signed `CN=kubernetes` certificate with only `DNS:kubernetes` in the Subject Alternative Names (no IP entries). *(see certificate dump)*
- Because the kubeconfig references the API server by IP (`https://62.118.136.124:10443`), modern Go/TLS clients require that IP to appear in the server certificate SAN list; otherwise verification fails.

## Likely Root Cause
The combination of (a) the kubeconfig pointing to the API server via IP address, (b) the proxy intercepting TLS and presenting a certificate without matching IP SANs, and (c) the API server certificate itself lacking an IP SAN for `62.118.136.124`, causes `kubectl` (Go 1.22-based) to abort TLS handshakes. Older clients that still allowed Common Name fallback may have succeeded, explaining the discrepancy with the reference environment.

## Suggested Next Steps / Server-Side Tests
1. **Confirm the API server certificate SANs** on the cluster host (e.g., `openssl x509 -in /etc/kubernetes/pki/apiserver.crt -text`). Ensure the public IP is listed.
2. **Regenerate or reissue the API server certificate** (or configure a DNS name with matching SAN) so that clients connecting via IP or DNS meet TLS validation requirements.
3. **Add the cluster endpoint to the `NO_PROXY` list** (client-side) if proxy interception is not desired. Verify whether requests bypass the proxy and succeed once the certificate issue is resolved.
4. **From the server/VPN side**, attempt `curl -vk https://62.118.136.124:10443` to confirm the certificate chain and SAN contents that working hosts observe.
