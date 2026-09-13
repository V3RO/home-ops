#!/usr/bin/env bash
# Creates/updates the Bitwarden access-token secret consumed by
# external-secrets, mirroring the old external_secrets_secret.tofu logic:
# wait for the namespace to exist, then apply an Opaque secret with a
# `token` key.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

: "${BITWARDEN_ACCESS_TOKEN:?Set BITWARDEN_ACCESS_TOKEN before running this script}"
KUBECONFIG="${KUBECONFIG:-${ROOT_DIR}/generated/kubeconfig}"
NAMESPACE="external-secrets"

echo "Waiting for namespace '${NAMESPACE}'..."
for i in $(seq 1 60); do
  if kubectl --kubeconfig "${KUBECONFIG}" get ns "${NAMESPACE}" >/dev/null 2>&1; then
    echo "Namespace ${NAMESPACE} found."
    break
  fi
  sleep 5
  if [ "$i" -eq 60 ]; then
    echo "Timeout waiting for namespace ${NAMESPACE}" >&2
    exit 1
  fi
done

kubectl --kubeconfig "${KUBECONFIG}" -n "${NAMESPACE}" create secret generic bitwarden-access-token \
  --from-literal=token="${BITWARDEN_ACCESS_TOKEN}" \
  --dry-run=client -o yaml \
  | kubectl --kubeconfig "${KUBECONFIG}" apply -f -
