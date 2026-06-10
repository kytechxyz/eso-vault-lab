#!/usr/bin/env bash
# cleanup.sh
# Tears down ESO and Vault. Leaves the kind cluster intact.
# Pass --cluster to also delete the kind cluster.

set -euo pipefail

echo "==> Removing ExternalSecret and ClusterSecretStore"
kubectl delete -f manifests/eso/externalsecret.yaml --ignore-not-found
kubectl delete -f manifests/eso/clustersecretstore.yaml --ignore-not-found

echo "==> Uninstalling External Secrets Operator"
helm uninstall external-secrets -n external-secrets || true
kubectl delete namespace external-secrets --ignore-not-found

echo "==> Uninstalling Vault"
helm uninstall vault -n vault || true
kubectl delete namespace vault --ignore-not-found

if [[ "${1:-}" == "--cluster" ]]; then
  echo "==> Deleting kind cluster: go-dev-cluster"
  kind delete cluster --name go-dev-cluster
fi

echo "==> Cleanup complete."
