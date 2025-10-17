# Kubernetes Connectivity Investigation Report

## Summary
- Kubernetes client configuration loads successfully, but API calls fail in this environment.
- Outbound traffic must traverse an HTTP proxy (`proxy:8080`), which performs TLS interception.
- The proxy-generated certificate for `62.118.136.124:10443` lacks an IP Subject Alternative Name entry, causing the Go TLS stack (used by `kubectl`) to reject the connection.
- When proxy variables are unset, direct connectivity to the cluster IP is blocked (`connect: network is unreachable`).

## Environment Details
- `kubectl` client: `v1.34.1` with `kustomize v5.7.1`.  
- Proxy-related environment variables are set globally (`HTTP(S)_PROXY=http://proxy:8080`, etc.).

## Tests Performed

### 1. Validate kubeconfig basics
```
KUBECONFIG=.kube/config kubectl config get-contexts
```
Result: kubeconfig parses correctly and reports the expected context (`team-a-dev@kubernetes`).

### 2. Attempt to list pods through proxy (default behaviour)
```
KUBECONFIG=.kube/config kubectl get pods -o wide --all-namespaces
```
Result: TLS verification error - `x509: cannot validate certificate for 62.118.136.124 because it doesn't contain any IP SANs`.

### 3. Force TLS skip verification
```
KUBECONFIG=.kube/config kubectl --insecure-skip-tls-verify=true get namespaces
```
Result: Request reaches proxy but returns `503 Service Unavailable` (`the server is currently unable to handle the request`).

### 4. Inspect proxy behaviour with curl
```
curl -vk https://62.118.136.124:10443/version
```
Observations:
- Traffic goes through `proxy:8080`.
- TLS handshake terminates at a certificate issued by `CN=egress-proxy`.
- Proxy returns `503` with `upstream connect error ... Connection refused`.

### 5. Enumerate proxy-related environment variables
```
env | grep -i proxy
```
Result: Confirms multiple proxy environment variables point to `http://proxy:8080` and custom CA certs.

### 6. Examine intercepted certificate
```
openssl s_client -connect 62.118.136.124:10443 -proxy proxy:8080 | openssl x509 -noout -text
```
Result: Proxy presents a certificate with `Subject CN = 62.118.136.124` but **SAN contains `DNS:62.118.136.124` instead of an IP SAN entry**, triggering Go's IP verification failure.

### 7. Disable proxy and retry
```
HTTPS_PROXY= HTTP_PROXY= https_proxy= http_proxy= KUBECONFIG=.kube/config kubectl get pods -A
```
Result: Direct connection attempt fails with `dial tcp ...: connect: network is unreachable`, confirming egress must traverse the proxy.

## Conclusion
`kubectl` in this environment is forced through an intercepting proxy. The proxy dynamically issues certificates that omit the required IP-type Subject Alternative Name, so the Go TLS verifier rejects connections to raw IP endpoints. When skipping TLS verification, the proxy still cannot reach the upstream cluster (503). Direct traffic without the proxy is blocked. Therefore, connectivity to `https://62.118.136.124:10443` cannot be established from this environment without either (1) configuring the proxy to include IP SANs or to allow tunnelling without interception, or (2) switching the kubeconfig server field to a hostname that matches the proxy-issued certificate.

## Suggested Server-Side / External Tests
If you can run checks from a network location without this proxy, please provide:
1. `kubectl version --short`
2. `kubectl get --raw=/version`
3. `openssl s_client -connect 62.118.136.124:10443 -servername kubernetes -showcerts`
4. `dig +short kubernetes`

These results will help confirm that the cluster itself is healthy and that only the proxy path is problematic.
