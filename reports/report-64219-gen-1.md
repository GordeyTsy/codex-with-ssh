# Connectivity investigation report (generation 1)

## Summary
- kubectl in the sandbox cannot reach either API endpoint (62.118.136.124:10443 or 193.164.155.89:10443) because every HTTPS request is forced through the corporate egress proxy at `proxy:8080`.
- The proxy performs TLS interception with a certificate whose Subject Alternative Name list lacks the raw IPs, so TLS validation fails before any Kubernetes traffic is exchanged.【0a9e11†L1-L15】【deb085†L11-L19】
- Even when TLS verification is disabled, the proxy cannot open a TCP session to the Kubernetes API servers and returns `503 Service Unavailable` with the reason `remote connection failure ... Connection refused`.【36754a†L1-L12】【9d309c†L1-L41】
- Attempting to bypass the proxy (by expanding `NO_PROXY`) results in an immediate `connect: network is unreachable`, confirming there is no direct route from the sandbox to the cluster without the proxy.【ae183d†L1-L14】【4afea2†L1-L10】

## Environment observations
- The sandbox exports multiple proxy-related environment variables that force all HTTP(S) clients (kubectl, curl, Go) through `http://proxy:8080` and trusts the MITM CA located at `/usr/local/share/ca-certificates/envoy-mitmproxy-ca-cert.crt`.【af6826†L1-L18】
- `kubectl version` succeeds only for the local client metadata; the server call fails with the TLS Subject Alternative Name error described above.【b3ccbc†L1-L5】

## Reproduced failures
1. **kubectl via default proxy settings**  
   ```bash
   KUBECONFIG=/root/.kube/config kubectl get pods -A -o wide
   ```  
   Result: TLS handshake terminates because the proxy-issued certificate does not contain IP SANs for `193.164.155.89` / `62.118.136.124`.【0a9e11†L1-L15】

2. **kubectl with proxy disabled (direct connect attempt)**  
   ```bash
   KUBECONFIG=/root/.kube/config HTTPS_PROXY= HTTP_PROXY= \
     NO_PROXY=localhost,127.0.0.1,::1,62.118.136.124,193.164.155.89 \
     kubectl get pods -A -o wide
   ```  
   Result: `dial tcp ... connect: network is unreachable` for both addresses, showing that the sandbox has no route to those IPs without going through the proxy.【ae183d†L1-L14】

3. **kubectl with TLS verification disabled (forces proxy path)**  
   ```bash
   # temporary change for diagnostic purposes
   kubectl config set-cluster kubernetes --insecure-skip-tls-verify=true
   kubectl get pods -A -o wide --request-timeout=10s
   ```  
   Result: Proxy answers `Error from server (ServiceUnavailable)` because the upstream TCP connection is refused. Restoring the original kubeconfig afterwards returns to the initial TLS failure state.【36754a†L1-L12】

4. **curl through the proxy**  
   ```bash
   curl -vk https://62.118.136.124:10443/
   curl -vk https://193.164.155.89:10443/
   ```  
   Result: Both commands traverse `proxy:8080`, negotiate TLS with a certificate issued to `CN=egress-proxy`, then fail with `503 Service Unavailable` reporting `remote connection failure ... Connection refused`.【9d309c†L1-L41】【0c6c1e†L1-L40】

5. **curl bypassing the proxy**  
   ```bash
   NO_PROXY=... curl -vk https://62.118.136.124:10443/
   NO_PROXY=... curl -vk https://193.164.155.89:10443/
   ```  
   Result: Immediate `Network is unreachable`, matching the kubectl behaviour without the proxy.【4afea2†L1-L10】【0a1071†L1-L11】

6. **kubectl HTTP trace**  
   ```bash
   kubectl get --raw=/version -v=9
   ```  
   Result: Confirms that `kubectl` resolves `proxy` to `172.30.1.67:8080`, opens the CONNECT tunnel there, and then aborts because the intercepted certificate lacks the required IP SANs.【deb085†L11-L19】

## Analysis
- The sandbox is forced to use an egress proxy that generates on-the-fly TLS certificates. The generated certificate is only valid for the hostname `egress-proxy` and therefore fails hostname verification when clients connect to raw IP addresses. Any kubectl or curl request that respects the proxy environment variables will hit this TLS error before reaching the Kubernetes API.
- Disabling TLS verification reveals a second blocker: the proxy itself cannot establish TCP sessions to `62.118.136.124:10443` or `193.164.155.89:10443`. It immediately returns Envoy's `upstream connect error ... Connection refused`, which is what kubectl reports as `Error from server (ServiceUnavailable)` when TLS verification is skipped.
- When attempting to bypass the proxy, the sandbox kernel reports `connect: network is unreachable`, indicating that outbound connectivity to the public Internet is fully restricted and the proxy is the only possible egress path.
- Because of these two constraints, kubectl currently has no viable path to the cluster from this sandbox.

## Recommendations / next steps
1. **Allow the proxy to reach the API endpoints**: verify that `172.30.1.67` (the proxy) is permitted to open TCP connections to `62.118.136.124:10443` and `193.164.155.89:10443`. At the server side you can check firewall rules or run `sudo tcpdump -nn -i <interface> port 10443` to see whether connection attempts from that IP arrive.
2. **Adjust TLS interception for IP targets**: if proxy access is required, configure the proxy to mint certificates that include IP Subject Alternative Names for these endpoints, or expose the API through a DNS hostname that the proxy certificate can cover. Without this, kubectl will continue to fail TLS validation even if the TCP connection succeeds.
3. **(Optional) Provide a direct egress bypass**: if policy permits, extend `NO_PROXY` to include the Kubernetes API IPs *and* open direct routing from the sandbox to those addresses. This would avoid the proxy entirely and allow the CA bundle from the kubeconfig to validate the real kube-apiserver certificate.
4. **Server-side verification** (if you need me to confirm): run the following on the cluster side and share the results:
   - `sudo ss -tnlp | grep 10443` to ensure the apiserver is listening on the expected interfaces.
   - `sudo tcpdump -nn -i <public-interface> host 172.30.1.67 and port 10443` for a short period while I retry, to confirm whether the proxy's SYN packets arrive or are filtered upstream.
   - `sudo iptables -S` (or equivalent firewall listing) to confirm whether the proxy's source IP range is allowed.

Once either the proxy connectivity or the TLS hostname issue is resolved, kubectl should work in this environment.
