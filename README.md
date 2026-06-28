# ESO × Vault — Kubernetes Secret Management Lab

A production-pattern implementation of External Secrets Operator (ESO) with HashiCorp Vault on a local kind cluster. Demonstrates the JWT-based Kubernetes authentication path end to end: **Vault KV secret → ClusterSecretStore → ExternalSecret → reconciled Kubernetes Secret**.

---

## What This Addresses

Secrets landing in Git is the most common compliance failure in platform migrations. The pattern here — GitOps-compatible secret management where the secret value never touches a manifest or a repository — is what mature platform teams implement when they move workloads off legacy secret injection (vaulted files, CM-delivered env vars, legacy Ansible vault).

This lab builds the mental model for operating ESO at scale: what the trust chain actually is, where it can fail, and what the reconciliation loop looks like under rotation.

---

## Architecture

```
┌──────────────────────────── kind: go-dev-cluster ──────────────────────────────┐
│                                                                                  │
│  ns: vault                              ns: external-secrets                    │
│  ┌──────────────────────────┐           ┌────────────────────────────────────┐  │
│  │  vault-0 (dev mode)      │           │  ESO controller pod                │  │
│  │                          │  k8s auth │                                    │  │
│  │  KV v2 engine (secret/)  │◄─────────►│  ClusterSecretStore: vault-backend │  │
│  │   └ myapp/config         │  JWT      └────────────────┬───────────────────┘  │
│  │      ├ DB_PASSWORD        │                           │ watches              │
│  │      └ API_KEY            │           ns: default     │                      │
│  └──────────────────────────┘           ┌───────────────▼───────────────────┐  │
│            ▲                            │  ExternalSecret: myapp-config     │  │
│            │ short-lived Vault token    └───────────────┬───────────────────┘  │
│            └──────────────── creates ──────────────────►│                      │
│                                         ┌───────────────▼───────────────────┐  │
│                                         │  Secret: myapp-config             │  │
│                                         └───────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────────┘
```

**Trust chain:** ESO authenticates to Vault using its own Kubernetes ServiceAccount JWT — no static tokens. Vault validates the JWT against the cluster's TokenReview API, returns a short-lived token scoped to `eso-read-policy`, and ESO uses that token to read `secret/data/myapp/config`. The Kubernetes Secret is created and owned by the ExternalSecret controller, which reconciles on `refreshInterval`.

---

## Stack

| Component                 | Version           |
| ------------------------- | ----------------- |
| Kubernetes (kind)         | v1.35.0           |
| External Secrets Operator | v2.6.0            |
| HashiCorp Vault           | latest (dev mode) |
| Helm                      | 3.x               |

---

## Prerequisites

- Docker running
- `kind`, `kubectl`, `helm` installed (asdf recommended on Apple Silicon)
- No cloud account, GPU, or external dependencies required — fully local

---

## Setup

### 1. Create the cluster

```bash
kind create cluster --name go-dev-cluster
kubectl cluster-info --context kind-go-dev-cluster
```

### 2. Install Vault (dev mode)

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
kubectl create namespace vault
helm install vault hashicorp/vault \
  --namespace vault \
  --set server.dev.enabled=true \
  --set server.dev.devRootToken=root \
  --set injector.enabled=false
kubectl wait --for=condition=ready pod/vault-0 -n vault --timeout=60s
```

### 3. Install External Secrets Operator

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=external-secrets \
  -n external-secrets --timeout=90s
```

> **Verify CRD API version before continuing.** ESO v2.x dropped `v1beta1`:
>
> ```bash
> kubectl get crd clustersecretstores.external-secrets.io \
>   -o jsonpath='{.spec.versions[*].name}'
> # Expected output: v1
> ```
>
> If `v1beta1` appears with `served=false`, all manifests must use `external-secrets.io/v1`.
> If results look wrong, clear the kubectl discovery cache:
>
> ```bash
> rm -rf ~/.kube/cache/discovery/
> ```

### 4. Configure Vault

```bash
bash scripts/configure-vault.sh
```

This script enables the KV v2 engine, writes the test secret, enables Kubernetes auth, creates the `eso-read-policy`, and binds it to the ESO ServiceAccount via the `eso-role` role.

Or run the steps manually — see the script for the individual `vault exec` commands.

### 5. Apply manifests

```bash
kubectl apply -f manifests/eso/clustersecretstore.yaml
kubectl apply -f manifests/eso/externalsecret.yaml
```

### 6. Verify

```bash
bash scripts/verify.sh
```

Expected ExternalSecret status:

```json
[{ "reason": "SecretSynced", "status": "True", "type": "Ready" }]
```

Expected decoded Secret values:

```
API_KEY: abc123
DB_PASSWORD: supersecret
```

### 7. Rotation test

```bash
# Update the secret in Vault
kubectl exec -n vault vault-0 -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root \
  vault kv put secret/myapp/config \
    DB_PASSWORD=rotated-v2 \
    API_KEY=new-key-xyz

# Wait one refreshInterval, then re-read
sleep 65
kubectl get secret myapp-config -n default \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'
# DB_PASSWORD: rotated-v2
```

### Cleanup

```bash
bash scripts/cleanup.sh
# Pass --cluster to also tear down the kind cluster
```

---

## Failure Modes

Three issues surfaced during this lab. Worth knowing before you hit them.

**1. ESO v2.x dropped `v1beta1`**

ESO v2.6.0 sets `served=false` for `v1beta1`. Manifests using `apiVersion: external-secrets.io/v1beta1` will fail. All resources — `ClusterSecretStore`, `ExternalSecret`, `SecretStore` — must use `apiVersion: external-secrets.io/v1`. This is a hard deprecation, not a warning.

**2. Vault CLI has no `-token` flag**

`vault login -token=root` does not work. Token auth requires the `VAULT_TOKEN` environment variable. Pass it with `env VAULT_TOKEN=root vault kv get ...`. This is consistent across Vault v1.x; the flag simply does not exist.

**3. Stale `kubectl` discovery cache**

After CRD installation, `kubectl` can return "resource type not found" even when the CRD is present and ready. The local discovery cache has a 10-minute TTL and doesn't invalidate on CRD creation. Clear it with:

```bash
rm -rf ~/.kube/cache/discovery/
```

---

## Key Concepts

**JWT-based Kubernetes auth (not static tokens)**

ESO never holds a long-lived Vault token. It presents its own ServiceAccount JWT to Vault's `auth/kubernetes/login` endpoint. Vault calls the cluster's TokenReview API to validate the JWT, then returns a short-lived token scoped only to what the policy allows. No static secret required to authenticate to your secrets backend.

**`ClusterSecretStore` vs `SecretStore`**

`ClusterSecretStore` is cluster-scoped — any `ExternalSecret` in any namespace can reference it. `SecretStore` is namespace-scoped. For shared infrastructure (one Vault, multiple teams), `ClusterSecretStore` is the correct primitive. Namespace isolation for multi-tenant patterns requires `SecretStore` per team namespace.

**ExternalSecret ownership model**

The reconciled Kubernetes Secret carries `ownerReferences` pointing to the `ExternalSecret` that created it. When the `ExternalSecret` is deleted, the owned Secret is garbage-collected. Secrets don't outlive their governance object — which is the point.

---

## What's Next

- [ ] Replace Vault dev mode with HA Vault using a production `vault-values.yaml`
- [ ] Add namespace-isolated `SecretStore` example (multi-tenant pattern)
- [ ] Integrate with the admission webhook (Phase 1): enforce that all Secrets must be owned by an ExternalSecret — no manually created Secrets
- [ ] Add `PrometheusRule` alerting on `ExternalSecretSyncFailure`

---

_Part of [The Single Thread](https://github.com/kytechxyz) — a portfolio project bridging traditional infrastructure engineering into cloud-native platform patterns._
