# Kubernetes Connectivity Diagnostic Report

## Summary
- All `kubectl` requests that target `https://62.118.136.124:10443` fail with TLS validation errors when routed through the workspace's mandatory HTTPS proxy.
- The corporate proxy (Envoy MITM) rewrites the server certificate and serves a certificate whose Subject Alternative Name (SAN) is of type **DNS** with the literal value `62.118.136.124`. Go-based clients such as `kubectl` treat the target as an IP address and therefore expect an **IP SAN**, causing the `x509: cannot validate certificate for 62.118.136.124 because it doesn't contain any IP SANs` error.
- Bypassing the proxy (by extending `NO_PROXY`) eliminates the SAN mismatch, but the environment then cannot reach the remote host directly (`connect: network is unreachable`).
- Because of the mandatory proxy, the certificate embedded in `.kube/config` (`certificate-authority-data`) is never presented; instead, the proxy's MITM CA signs the session, so trusting the cluster CA alone is insufficient in this environment.

## Environment Facts
- `kubectl` client version: `v1.34.1` (Go 1.22). Newer Go releases enforce RFC-compliant SAN matching without the legacy CN fallback.【2b9d87†L1-L3】
- Proxy-related variables are globally enforced (e.g., `HTTPS_PROXY=http://proxy:8080`, `SSL_CERT_FILE=/usr/local/share/ca-certificates/envoy-mitmproxy-ca-cert.crt`).【976849†L1-L17】
- The kubeconfig provided by the user points at an IP address (`https://62.118.136.124:10443`) and bundles a dedicated CA certificate intended for the real cluster endpoint.【962b08†L6-L34】

## Tests Performed
| # | Command | Result | Notes |
|---|---------|--------|-------|
| 1 | `KUBECONFIG=.kube/config kubectl cluster-info` | ❌ TLS validation failed (`x509: cannot validate certificate for 62.118.136.124 because it doesn't contain any IP SANs`).【ee1148†L1-L19】 | Confirms the original symptom.
| 2 | `KUBECONFIG=.kube/config kubectl get pods -A` | ❌ Same SAN-related TLS failure.【9715cb†L1-L16】 | Reproduces the issue on another API call.
| 3 | `curl -v --cacert ca.crt https://62.118.136.124:10443/version` | ❌ TLS failure (`SSL certificate problem: unsuitable certificate purpose`) while going through the proxy.【624402†L1-L26】 | Shows the proxy presents its own certificate, which the cluster CA cannot validate.
| 4 | `openssl s_client -proxy proxy:8080 -connect 62.118.136.124:10443 -showcerts` | ✅ Connection succeeds via proxy and reveals the issued certificate chain. The leaf cert is `CN=62.118.136.124` signed by `CN=egress-proxy` (OpenAI).【9345ba†L1-L37】 | Confirms HTTPS is intercepted by the proxy.
| 5 | `openssl x509 -in proxy-cert.pem -text -noout` | ✅ Shows SAN extension is `DNS:62.118.136.124` (type DNS, not IP).【f65343†L1-L32】 | Explains the SAN mismatch observed by Go clients.
| 6 | `NO_PROXY=62.118.136.124 KUBECONFIG=.kube/config kubectl get pods -A` | ❌ Direct connection attempt fails with `connect: network is unreachable`.【e37896†L1-L11】 | Indicates outbound traffic must traverse the proxy.

## Conclusions
1. The workspace must traverse the corporate HTTPS proxy (`proxy:8080`) to reach external IPs. The proxy performs TLS interception (MITM) and rewrites the certificate chain.
2. The proxy-generated leaf certificate only contains a **DNS**-type SAN entry (`DNS:62.118.136.124`). When `kubectl` (Go 1.22) connects to an IP, it insists on SAN entries of type **IP**. Because no IP-type SAN is present, Go rejects the certificate before even considering the CA trust chain, producing the SAN error seen in every `kubectl` invocation.
3. The kubeconfig's embedded CA (`certificate-authority-data`) is never used in practice because the proxy certificate replaces the server certificate. Therefore, trusting the proxy's CA is necessary, but alone it still fails due to the SAN-type mismatch.
4. Direct access without the proxy is blocked in this environment, so the only viable fix is on the proxy or by changing the Kubernetes API endpoint to a DNS hostname that matches the SAN type the proxy issues.

## Recommendations
1. **Preferred fix:** Configure the proxy (Envoy MITM) to emit certificates that include an IP-type SAN when the CONNECT target is an IP address. This would satisfy Go's verification logic without changes to the kubeconfig.
2. **Alternative:** If possible, change the Kubernetes API server endpoint to use a DNS hostname (e.g., `server: https://<hostname>:10443`) that resolves to the same IP. Ensure that hostname is present as a DNS SAN in the real cluster certificate and that the proxy mirrors it. Kubectl would then validate against a DNS SAN instead of requiring an IP SAN.
3. **Temporary workaround (not ideal):** Launch kubectl with `HTTPS_PROXY` unset and custom routing (e.g., VPN, SSH tunnel) that allows direct connectivity to `62.118.136.124:10443`, so the cluster's real certificate (signed by the provided CA) is presented. This might not be feasible within the current workspace due to firewall restrictions (as seen in Test #6).
4. **Do not** attempt to bypass TLS verification using `--insecure-skip-tls-verify` for production workflows; it would negate security checks and is generally prohibited.

## Optional Server-Side Verification
If you have access to the Kubernetes control plane or another environment without the proxy, please run the following to confirm the real server certificate already includes an IP SAN (or to capture its actual SAN set):
1. `openssl s_client -connect 62.118.136.124:10443 -showcerts </dev/null | openssl x509 -noout -text`
2. Share the output of `kubectl version --short` (or `kubectl version --client --short` and `kubectl version --server --short`) from the working environment for comparison.
3. Provide the value of `echo $HTTPS_PROXY` (or confirm it is unset) on the environment where the kubeconfig currently works.

Recording these results will help determine whether aligning the endpoint to a DNS name is sufficient or whether proxy adjustments are required.
