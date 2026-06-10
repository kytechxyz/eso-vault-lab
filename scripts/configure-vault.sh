#!/usr/bin/env bash
# configure-vault.sh
# Configures a Vault dev-mode instance for ESO Kubernetes auth.
# Assumes: vault-0 pod is running in the vault namespace with VAULT_TOKEN=root.
# Run AFTER Vault and ESO are installed via Helm.

set -euo pipefail

VAULT_NS="vault"
VAULT_POD="vault-0"
VAULT_ADDR="http://127.0.0.1:8200"
VAULT_TOKEN="root"

vault_exec() {
  kubectl exec -n "${VAULT_NS}" "${VAULT_POD}" -- \
    env VAULT_ADDR="${VAULT_ADDR}" VAULT_TOKEN="${VAULT_TOKEN}" \
    "$@"
}

echo "==> Enabling KV v2 secrets engine at path: secret/"
vault_exec vault secrets enable -path=secret kv-v2 || \
  echo "    (already enabled — continuing)"

echo "==> Writing test secret: secret/myapp/config"
vault_exec vault kv put secret/myapp/config \
  DB_PASSWORD=supersecret \
  API_KEY=abc123

echo "==> Enabling Kubernetes auth method"
vault_exec vault auth enable kubernetes || \
  echo "    (already enabled — continuing)"

echo "==> Configuring Kubernetes auth (in-cluster)"
vault_exec vault write auth/kubernetes/config \
  kubernetes_host=https://kubernetes.default.svc

echo "==> Creating ESO read policy"
vault_exec vault policy write eso-read-policy - <<'EOF'
path "secret/data/myapp/*" {
  capabilities = ["read"]
}
EOF

echo "==> Creating Vault role bound to ESO ServiceAccount"
vault_exec vault write auth/kubernetes/role/eso-role \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso-read-policy \
  ttl=1h

echo ""
echo "==> Vault configuration complete."
echo "    Next: kubectl apply -f manifests/eso/clustersecretstore.yaml"
echo "          kubectl apply -f manifests/eso/externalsecret.yaml"
