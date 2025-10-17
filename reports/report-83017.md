# Kubernetes Connectivity Diagnostic Report

## Summary
- Local `kubectl` cannot reach `https://62.118.136.124:10443` because TLS verification fails: the proxy-presented certificate is missing a Subject Alternative Name (SAN) entry for the target IP, causing `x509` validation errors. 【68afe2†L1-L16】【f079a0†L1-L5】
- All raw API probes (`/version`, `/healthz`) experience the same SAN validation failure, confirming the issue is independent of the Kubernetes API verb used. 【82d825†L1-L3】【2c0d24†L1-L3】
- Direct socket access to the control plane IP is blocked (`connect: errno=101`), forcing traffic through the corporate `http://proxy:8080` egress proxy where TLS is man-in-the-middled by an Envoy certificate lacking the needed SAN entries. 【419b33†L1-L6】【30fc47†L1-L40】【342ced†L1-L18】
- Proxy-intercepted HTTPS requests return 503 errors after the tunnel is established, indicating the proxy cannot reach the upstream API endpoint (connection refused). 【30fc47†L33-L40】【914143†L33-L40】

## Environment Notes
- Client: `kubectl v1.34.1` (flag `--short` removed; attempting it returns an "unknown flag" error). 【d3d988†L1-L3】【6cbefa†L1-L3】【4673e5†L1-L3】
- Proxy configuration enforced via environment variables (`HTTPS_PROXY`, `REQUESTS_CA_BUNDLE`, etc.), pointing to `proxy:8080` and an Envoy MITM root CA. 【342ced†L1-L18】

## Local Test Matrix
| Test | Command | Result |
| --- | --- | --- |
| List pods | `kubectl --context team-a-dev@kubernetes get pods --all-namespaces -o wide` | Fails with `x509: cannot validate certificate for 62.118.136.124 because it doesn't contain any IP SANs`. 【68afe2†L1-L16】 |
| Version probe | `kubectl --context team-a-dev@kubernetes version` | Same SAN error prevents server version retrieval. 【f079a0†L1-L5】 |
| Server health | `kubectl --context team-a-dev@kubernetes get --raw=/healthz` | Same SAN error. 【2c0d24†L1-L3】 |
| Version endpoint | `kubectl --context team-a-dev@kubernetes get --raw=/version` | Same SAN error. 【82d825†L1-L3】 |
| Proxy-aware version (deprecated flag) | `kubectl version --client --short` | Command invalid on v1.34+ (`--short` removed). 【6cbefa†L1-L3】 |
| Forced server query | `kubectl --context team-a-dev@kubernetes version --server=true` | Proxy responds with `503 Service Unavailable`. 【063250†L1-L4】 |
| Direct TLS probe | `openssl s_client -connect 62.118.136.124:10443 -servername kubernetes -showcerts` | Fails: `Network is unreachable` (cannot bypass proxy). 【419b33†L1-L6】 |
| HTTPS via proxy | `curl -vk https://62.118.136.124:10443/` | Connects through proxy, receives Envoy `egress-proxy` certificate without required SAN; upstream connection refused, returning 503. 【30fc47†L1-L40】 |
| Healthz via proxy | `curl -vk https://62.118.136.124:10443/healthz` | Identical to `/`, returning 503 after proxy handshake. 【914143†L1-L40】 |

## Analysis
1. **Mandatory Proxy Path** – Direct socket attempts to `62.118.136.124:10443` fail with `errno=101`, proving direct routing is blocked and all traffic is forced through the Envoy proxy. 【419b33†L1-L6】
2. **TLS Interception** – Requests forwarded through the proxy receive a re-issued certificate (`CN=egress-proxy`, self-signed by the proxy) instead of the Kubernetes API certificate. This leaf certificate lacks SAN entries for `62.118.136.124`, triggering the `x509` validation failure in `kubectl`. 【30fc47†L21-L32】
3. **Upstream Reachability** – Even after establishing the CONNECT tunnel, Envoy returns `503` with "remote connection failure" / "Connection refused", indicating it cannot reach the upstream API endpoint on behalf of the client. 【30fc47†L33-L40】【914143†L33-L40】
4. **Server-side Contrast** – The reference environment (provided by the user) reaches the API directly and observes the legitimate `CN=kube-apiserver` certificate that includes the necessary SAN entries. This highlights that the issue is confined to the local environment's forced-proxy path rather than the Kubernetes cluster itself.

## Recommendations
1. **Bypass or Reconfigure Proxy for the API IP**
   - Add `62.118.136.124` (and other control-plane IPs) to `no_proxy`/`NO_PROXY`, then ensure routing permits direct access. If networking rules prohibit this, request an exception allowing direct egress for that IP/port.
2. **If Proxy Use Is Mandatory**
   - Ask the proxy team to enable transparent TCP tunneling without TLS interception for `62.118.136.124:10443`, or provide a certificate that includes `62.118.136.124` in its SAN list so TLS hostname validation succeeds.
   - Confirm the proxy has reachability to the upstream control plane; the `503` errors suggest the proxy currently cannot connect even if TLS validation were to pass.
3. **Short-term Workaround** (only if security policy allows): run `kubectl` with `--insecure-skip-tls-verify` or set `insecure-skip-tls-verify: true` in the kubeconfig context to validate functionality, but follow up with a permanent fix addressing the proxy/certificate issues.

## Optional Follow-up Tests for the Server Side
_No additional remote tests required at this time; the problem lies in the local proxy path. If proxy configuration changes are made, re-run the local test matrix above to confirm resolution._
