#!/usr/bin/env bash
# Diagnostic script to be executed on the Kubernetes control-plane (master) node.
# It aggregates every server-side verification requested across investigation reports.
# The goal is to capture cluster health, TLS certificate details, and control-plane reachability
# in a single run so the results can be shared back with the investigation tasks.

set -u
set -o pipefail
set -f

API_PORT="${API_PORT:-10443}"
API_HOSTS=("62.118.136.124" "193.164.155.89")

run() {
  local cmd="$1"
  echo
  echo ">>> $cmd"
  if ! bash -c "set -o pipefail; set -f; $cmd"; then
    local status=$?
    echo "!!! command exited with status $status" >&2
  fi
}

echo "### Kubernetes master diagnostics started at $(date -u +'%%Y-%%m-%%dT%%H:%%M:%%SZ')"

run "kubectl config current-context"
run "kubectl get nodes -o wide"
run "kubectl get pods -A -o wide"
run "kubectl cluster-info"
run "kubectl version --short"
run "kubectl version"
run "kubectl version --output=yaml"
run "kubectl get --raw=/version"
run "kubectl get --raw=/healthz"
run "kubectl get --raw=/readyz"
run "kubectl get --raw=/livez?verbose"
run "kubectl get --raw='/.well-known/openid-configuration'"

# Inspect the apiserver certificate on disk for SAN correctness.
run "sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text"
run "sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -ext subjectAltName"

# Capture live TLS details from both advertised control-plane IPs.
for host in "${API_HOSTS[@]}"; do
  run "echo '### Testing API endpoint ${host}:${API_PORT}'"
  run "openssl s_client -connect ${host}:${API_PORT} -servername kubernetes -showcerts </dev/null"
  run "openssl s_client -connect ${host}:${API_PORT} -servername kubernetes -showcerts </dev/null | openssl x509 -noout -ext subjectAltName"
  run "openssl s_client -connect ${host}:${API_PORT} -showcerts </dev/null | openssl x509 -noout -text"
  run "curl -vk \"https://${host}:${API_PORT}/\""
  run "curl -vk \"https://${host}:${API_PORT}/api\""
  run "curl -vk \"https://${host}:${API_PORT}/healthz\""
  run "curl -vk \"https://${host}:${API_PORT}/livez?verbose\""
  run "curl -vk \"https://${host}:${API_PORT}/readyz\""
  run "curl -vk \"https://${host}:${API_PORT}/version\""
  run "curl -vk \"https://${host}:${API_PORT}/openid/v1/jwks\""
  run "curl -vk \"https://${host}:${API_PORT}/.well-known/openid-configuration\""
  run "curl -vk \"https://${host}:${API_PORT}/metrics\""

done

echo
echo "### Diagnostics complete"
