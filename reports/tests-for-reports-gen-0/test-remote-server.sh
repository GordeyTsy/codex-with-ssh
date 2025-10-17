#!/usr/bin/env bash
# Diagnostic script to be executed on a remote host (e.g., bastion) with working access to the cluster.
# It consolidates every remote-side verification requested across the investigation reports so results
# can be captured in a single run.

set -u
set -o pipefail
set -f

KUBECTL_CONTEXT="${KUBECTL_CONTEXT:-team-a-dev@kubernetes}"
API_PORT="${API_PORT:-10443}"
API_HOSTS=("62.118.136.124" "193.164.155.89")
PROXY_URL="${PROXY_URL:-}"  # Optional explicit proxy to test CONNECT behaviour.

run() {
  local cmd="$1"
  echo
  echo ">>> $cmd"
  if ! bash -c "set -o pipefail; set -f; $cmd"; then
    local status=$?
    echo "!!! command exited with status $status" >&2
  fi
}

echo "### Remote diagnostics started at $(date -u +'%%Y-%%m-%%dT%%H:%%M:%%SZ')"
echo "### Using kubectl context: ${KUBECTL_CONTEXT}"

run "env | grep -i proxy || true"
run "echo \$HTTPS_PROXY"
run "echo \$NO_PROXY"
run "echo \$REQUESTS_CA_BUNDLE"

run "kubectl --context \"${KUBECTL_CONTEXT}\" config current-context"
run "kubectl --context \"${KUBECTL_CONTEXT}\" cluster-info"
run "kubectl --context \"${KUBECTL_CONTEXT}\" get nodes -o wide"
run "kubectl --context \"${KUBECTL_CONTEXT}\" get pods -A -o wide"

# Capture kubectl version details (try both legacy --short and modern output for completeness).
run "kubectl --context \"${KUBECTL_CONTEXT}\" version --short"
run "kubectl --context \"${KUBECTL_CONTEXT}\" version"
run "kubectl --context \"${KUBECTL_CONTEXT}\" version --client --short"
run "kubectl --context \"${KUBECTL_CONTEXT}\" version --server --short"
run "kubectl --context \"${KUBECTL_CONTEXT}\" version --output=yaml"

# Raw API probes that were requested.
run "kubectl --context \"${KUBECTL_CONTEXT}\" get --raw=/version"
run "kubectl --context \"${KUBECTL_CONTEXT}\" get --raw=/healthz"
run "kubectl --context \"${KUBECTL_CONTEXT}\" get --raw=/readyz"
run "kubectl --context \"${KUBECTL_CONTEXT}\" get --raw=/livez?verbose"
run "kubectl --context \"${KUBECTL_CONTEXT}\" get --raw='/.well-known/openid-configuration'"
run "kubectl --context \"${KUBECTL_CONTEXT}\" get --raw=/openid/v1/jwks"

# Optional readiness command with timestamp as requested in one report.
run "date && kubectl --context \"${KUBECTL_CONTEXT}\" get --raw=/readyz"

# DNS insight requested in report-48239.
run "dig +short kubernetes"

for host in "${API_HOSTS[@]}"; do
  run "echo '### Testing API endpoint ${host}:${API_PORT}'"
  run "openssl s_client -connect ${host}:${API_PORT} -servername kubernetes -showcerts </dev/null"
  run "openssl s_client -connect ${host}:${API_PORT} -servername kubernetes -showcerts </dev/null | openssl x509 -noout -issuer -subject -ext subjectAltName"
  run "openssl s_client -connect ${host}:${API_PORT} -showcerts </dev/null | openssl x509 -noout -text"
  run "curl -vk \"https://${host}:${API_PORT}/\""
  run "curl -vk \"https://${host}:${API_PORT}/api\""
  run "curl -vk \"https://${host}:${API_PORT}/healthz\""
  run "curl -vk \"https://${host}:${API_PORT}/livez?verbose\""
  run "curl -vk \"https://${host}:${API_PORT}/readyz\""
  run "curl -vk \"https://${host}:${API_PORT}/version\""
  if [[ -n "${PROXY_URL}" ]]; then
    run "curl -x \"${PROXY_URL}\" -vk \"https://${host}:${API_PORT}/healthz\""
  fi
  run "curl -vk \"https://${host}:${API_PORT}/.well-known/openid-configuration\""
  run "curl -vk \"https://${host}:${API_PORT}/openid/v1/jwks\""
  run "curl -vk \"https://${host}:${API_PORT}/metrics\""
done

echo
echo "### Remote diagnostics complete"
