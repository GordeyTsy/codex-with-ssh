# Kubernetes connectivity investigation report

## Summary
- **Context:** Attempted to access the remote Kubernetes cluster at `https://193.164.155.89:10443` using the provided kubeconfig.
- **Outcome:** All `kubectl` calls fail before reaching the API server because the mandatory egress HTTPS proxy injects a certificate without an IP Subject Alternative Name (SAN), leading to TLS verification failures.
- **Key evidence:** `kubectl` consistently reports `x509: cannot validate certificate for 193.164.155.89 because it doesn't contain any IP SANs`, and an OpenSSL trace through the proxy shows the injected certificate chain.

## Test log (client side)

| Timestamp (UTC) | Command | Result |
| --- | --- | --- |
| 2025-10-12 16:15 | `kubectl get pods -A -o wide` | Fails with TLS verification error (`x509: cannot validate certificate for 193.164.155.89 because it doesn't contain any IP SANs`). |
| 2025-10-12 16:15 | `HTTPS_PROXY= HTTP_PROXY= NO_PROXY= kubectl get pods -A -o wide` | Same TLS verification failure, confirming it is not caused by proxy environment variables alone. |
| 2025-10-12 16:16 | `openssl s_client -connect 193.164.155.89:10443 -showcerts` | Connection blocked at the network layer (`connect:errno=101`), indicating direct egress is disallowed. |
| 2025-10-12 16:16 | `openssl s_client -proxy proxy:8080 -connect 193.164.155.89:10443 -showcerts` | Succeeds through the corporate proxy and displays a dynamically issued certificate with CN `193.164.155.89` but **no IP SANs**. |
| 2025-10-12 16:17 | `env | grep -i proxy` | Shows HTTPS/HTTP proxy variables and custom CA bundle injected into the environment. |

### Detailed outputs
- `kubectl get pods -A -o wide`
  ```
  tls: failed to verify certificate: x509: cannot validate certificate for 193.164.155.89 because it doesn't contain any IP SANs
  ```
- `openssl s_client -proxy proxy:8080 -connect 193.164.155.89:10443 -showcerts`
  ```
  depth=1 C = US, ST = California, L = San Francisco, O = OpenAI, CN = egress-proxy
  depth=0 CN = 193.164.155.89
  ...
  X509v3 Subject Alternative Name: (missing IP entries)
  ```

## Root cause analysis
1. The environment forces outbound HTTPS traffic through a MITM egress proxy (see `env | grep -i proxy` and the OpenSSL certificate chain).
2. The proxy re-issues certificates on the fly but only sets the CN to the target IP address without populating the IP SAN extension.
3. Modern Kubernetes clients (Go 1.17+) require the certificate SAN to include the IP when connecting via literal IP addresses. Without an IP SAN the certificate is invalid, causing `kubectl` to abort.
4. Because direct egress to `193.164.155.89:10443` is blocked (`connect:errno=101`), we cannot bypass the proxy; thus every request encounters the malformed proxy certificate and fails.

## Recommendations / Next steps
- **Preferred:** Obtain a DNS name for the API server and update the kubeconfig `server:` URL to use that hostname. The proxy-generated certificate will include the hostname SAN, allowing validation to pass.
- **Alternative:** Ask the proxy administrators to configure certificate generation with matching IP SANs or to whitelist the cluster endpoint from interception.
- **Temporary workaround (not recommended for production):** Launch `kubectl` with `KUBECONFIG` plus `--insecure-skip-tls-verify` or a local port-forwarding tunnel that terminates TLS before the proxy. This bypasses validation but should only be used for short-lived debugging.

## Server-side validation requests
If additional confirmation from the cluster side is required, please run the following and share the output:
1. `kubectl get --raw='/.well-known/openid-configuration'` (from a trusted environment) to confirm the control-plane certificate subject/SANs.
2. `openssl x509 -in /etc/kubernetes/pki/apiserver.crt -text -noout` (on the control-plane node) to verify the issued SAN entries.
3. `kubectl get nodes -o wide` to validate server accessibility from within the cluster's network perimeter.
