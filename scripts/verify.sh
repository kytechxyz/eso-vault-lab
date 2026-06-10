#!/usr/bin/env bash
# verify.sh
# Validates the full ESO -> Vault trust path after lab setup is complete.

set -euo pipefail

echo "==> ClusterSecretStore status"
kubectl get clustersecretstore vault-backend
echo ""

echo "==> ExternalSecret status"
kubectl get externalsecret myapp-config -n default \
  -o jsonpath='{.status.conditions}' | jq
echo ""

echo "==> Decoded Secret values"
kubectl get secret myapp-config -n default \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'
echo ""

echo "==> Vault auth round-trip (manual SA token login)"
SA_TOKEN=$(kubectl -n external-secrets create token external-secrets)
kubectl exec -n vault vault-0 -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root \
  vault write auth/kubernetes/login \
    role=eso-role \
    jwt="${SA_TOKEN}"
echo ""
echo "==> Verification complete. Expected: SecretSynced, policies=[eso-read-policy]"
