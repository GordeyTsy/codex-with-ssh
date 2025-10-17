# Kubernetes Connectivity Investigation Report

## Summary
- Verified that `kubectl` v1.34.1 is installed in the workspace container, but it is not functional out-of-the-box because no kubeconfig is provisioned. 【e799b0†L1-L3】【9a7a87†L1-L7】
- Confirmed that no kube-related environment variables or default kubeconfig directory exist initially, leading `kubectl` to fall back to `localhost:8080` and fail. 【902583†L1-L1】【08b182†L1-L2】【6e5f58†L1-L12】
- Detected that outbound connectivity to `62.118.136.124:10443` is only possible through the mandatory HTTP(S) proxy, which returns 503 responses for raw API requests; direct socket connections are blocked. 【3395a9†L1-L18】【eacacb†L1-L2】【3e0844†L1-L2】【7ea5a4†L1-L10】
- After temporarily recreating the provided kubeconfig, `kubectl` still fails because the API server certificate lacks an IP Subject Alternative Name for `62.118.136.124`, and even with TLS skipping, the proxy relays `503 Service Unavailable`. 【1aac38†L1-L28】【c634d0†L1-L17】【9758a2†L1-L11】

## Test Details
1. **Client tooling check**  
   `kubectl version --client` confirms the CLI version shipped in the environment. 【e799b0†L1-L3】

2. **Environment configuration**  
   - `env | grep -i kube` showed no preset kube-related environment variables. 【902583†L1-L1】  
   - `ls -la ~/.kube` initially failed because the directory was absent. 【08b182†L1-L2】  
   - `kubectl config view` and `kubectl config get-contexts` returned empty structures. 【9a7a87†L1-L7】【c871e2†L1-L2】

3. **Default `kubectl` behaviour without configuration**  
   `kubectl get pods` attempted to contact `localhost:8080` and failed with `connection refused`, proving that no cluster endpoint is configured. 【6e5f58†L1-L12】

4. **Network path diagnostics**  
   - Environment variables reveal an enforced HTTP(S) proxy (`proxy:8080`). 【3395a9†L1-L18】  
   - Direct TCP probes (`nc -4 -zv 62.118.136.124 10443`) fail with "Network is unreachable", and forcing `curl` to bypass the proxy reproduces the same failure. 【eacacb†L1-L2】【3e0844†L1-L2】  
   - Using the proxy (`curl -kI https://62.118.136.124:10443/healthz`) reaches an envoy front proxy but receives `503 Service Unavailable`, indicating either proxy filtering or upstream issues. 【7ea5a4†L1-L10】【010661†L1-L10】

5. **Testing with supplied kubeconfig**  
   - Recreated the provided kubeconfig under `~/.kube/config` solely for diagnostics. 【1aac38†L1-L28】  
   - `kubectl get pods -A` now targets the remote API but fails TLS validation because the certificate does not advertise the raw IP in its SAN list. 【c634d0†L1-L17】  
   - Even disabling verification (`kubectl --insecure-skip-tls-verify=true get namespaces`) results in `503 Service Unavailable`, consistent with the proxy behaviour above. 【9758a2†L1-L11】

## Findings & Root Cause Hypothesis
- The workspace container is missing any kubeconfig by default, so `kubectl` cannot operate until one is supplied.  
- Outbound connections to the Kubernetes API IP are blocked unless they traverse the corporate HTTP(S) proxy. The proxy terminates TLS with a custom CA (`envoy-mitmproxy`), but still relays 503 errors for API requests.  
- The API server's certificate (or the proxy's reissued certificate) lacks an IP Subject Alternative Name, which modern Kubernetes clients require when connecting via raw IP. This causes TLS failures even when the kubeconfig is present.  
- Combined, these factors explain why `kubectl` cannot reach the cluster from this environment without additional setup (e.g., distributing the kubeconfig, updating certificates/SANs, and ensuring the proxy allows the API traffic).

## Recommended Follow-up Actions
1. **Workspace-side**  
   - Provision the kubeconfig automatically (or document manual placement) for the agent workspace.  
   - Add `62.118.136.124` to `NO_PROXY` if direct routing becomes available; otherwise, verify with platform ops whether the proxy supports CONNECT tunnelling for this endpoint.  
   - Request a certificate containing the IP SAN or switch the kubeconfig `server` field to a DNS name covered by the certificate.

2. **Server-side checks (please run and share results)**  
   - `openssl s_client -connect 62.118.136.124:10443 -showcerts | openssl x509 -noout -ext subjectAltName` — confirm which SANs are present on the API certificate.  
   - `kubectl --context team-a-dev@kubernetes get --raw=/healthz` from within the cluster’s trusted network — verify that the API responds with `ok` (without proxy interference).  
   - If a proxy is required, test `curl -x http://<your-proxy>:8080 https://62.118.136.124:10443/healthz` to ensure the proxy can successfully tunnel requests without returning 503.

*Report generated on 2025-10-12 for tracking.*
