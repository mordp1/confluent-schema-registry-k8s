# cp-schema-registry — Confluent Cloud to Self-Hosted Migration

A self-contained toolkit for running **Confluent Schema Registry Community Edition** on Kubernetes and migrating schemas from **Confluent Cloud**.

Includes a local Helm chart, migration scripts (live pull and file-based), smoke tests, and production-ready examples for EKS with MSK.

> Tested with Confluent Platform **8.2.0** (Jetty 12) and **7.7.1** (Jetty 9) on kind and EKS.

---

## Repository structure

```
.
├── charts/
│   └── cp-schema-registry/        # Local Helm chart (official confluentinc image)
│       ├── Chart.yaml
│       ├── values.yaml             # Chart defaults (all options documented)
│       └── templates/
│
├── deploy/                         # Helm values overlays + Kubernetes manifests
│   ├── values-local.yaml           # Local testing (kind / minikube + Strimzi)
│   ├── values-production.yaml      # EKS production (3 replicas, PDB, anti-affinity)
│   ├── values-msk-sasl.yaml        # Amazon MSK SASL/SCRAM-SHA-512 connectivity
│   ├── ingress-nginx.yaml          # NGINX Ingress Controller example
│   ├── ingress-alb.yaml            # AWS ALB Ingress example
│   ├── ingress-nlb.yaml            # AWS NLB via Service example
│   ├── secret-auth.yaml            # HTTP Basic Auth secret template
│   ├── secret-msk-sasl.yaml        # MSK SASL credentials secret template
│   ├── externalsecret-msk-sasl.yaml # Same via External Secrets Operator
│   └── pdb.yaml                    # Standalone PodDisruptionBudget
│
├── migration/                      # Schema migration scripts
│   ├── migrate-from-cloud.sh       # Strategy B: live pull from Confluent Cloud REST API
│   ├── import-schemas.sh           # Strategy A: import from local .json export files
│   ├── validate-migration.sh       # Compare Cloud vs local schemas
│   ├── delete-migrated.sh          # Clean up local SR for re-migration
│   └── .env.example                # Credentials template
│
├── smoke-test.sh                   # 6 automated auth + schema registration tests
└── .gitignore
```

---

## Why a local chart?

The official `confluentinc/cp-helm-charts` repository only publishes an umbrella chart — individual sub-charts like `cp-schema-registry` are not installable standalone. This chart extends the original with:

- `volumes` / `volumeMounts` support (required for JAAS Secret mount)
- `customLivenessProbe` / `customReadinessProbe` (tcpSocket by default — safe with Basic auth)
- `schemaRegistryOpts` to set `SCHEMA_REGISTRY_OPTS` (JVM flags)
- `customEnv` as a proper list (supports `valueFrom` / `secretKeyRef`)
- `fullnameOverride` to control resource naming
- PodDisruptionBudget, SecurityContext, ServiceAccount templates

---

## Prerequisites

```bash
brew install kubectl helm jq curl
```

---

## Deploy — Local (kind / minikube)

### 1. Create the auth Secret

Edit `deploy/secret-auth.yaml` — replace the placeholder passwords with values generated via `openssl rand -base64 32`, then apply:

```bash
kubectl apply -f deploy/secret-auth.yaml -n schema-registry
```

### 2. Deploy Schema Registry

```bash
helm upgrade --install schema-registry ./charts/cp-schema-registry \
  --namespace schema-registry --create-namespace \
  -f deploy/values-local.yaml
```

### 3. Watch rollout

```bash
kubectl rollout status deployment/schema-registry -n schema-registry
```

### 4. Port-forward and test

```bash
kubectl port-forward svc/schema-registry -n schema-registry 18081:8081 &
curl -u admin:changeme-admin-password http://localhost:18081/subjects | jq
```

### 5. Run smoke tests

```bash
./smoke-test.sh
# Override defaults if needed:
NAMESPACE=schema-registry ADMIN_PASS=your-password ./smoke-test.sh
```

---

## Deploy — EKS Production

### Prerequisites

- AWS Load Balancer Controller or existing internal NGINX ingress controller
- Amazon MSK cluster with SASL/SCRAM enabled
- (Optional) cert-manager or a wildcard TLS Secret

### 1. Create secrets

```bash
# HTTP Basic Auth
kubectl apply -f deploy/secret-auth.yaml -n schema-registry

# MSK SASL credentials (manual — or use externalsecret-msk-sasl.yaml for ESO)
kubectl apply -f deploy/secret-msk-sasl.yaml -n schema-registry
```

> Edit the secrets and replace placeholder values with real credentials before applying.

### 2. Choose an exposure strategy

| File | When to use |
|---|---|
| `deploy/ingress-nginx.yaml` | Internal NGINX ingress controller already exists |
| `deploy/ingress-alb.yaml` | AWS ALB Ingress Controller — shared ALB, WAF, path routing |
| `deploy/ingress-nlb.yaml` | Dedicated NLB per service, PrivateLink future support |

### 3. Deploy

```bash
helm upgrade --install schema-registry ./charts/cp-schema-registry \
  --namespace schema-registry --create-namespace \
  -f deploy/values-local.yaml \
  -f deploy/values-production.yaml \
  -f deploy/values-msk-sasl.yaml \
  -f deploy/ingress-nginx.yaml    # or ingress-alb.yaml / ingress-nlb.yaml
```

---

## Migrate schemas from Confluent Cloud

### Setup credentials

```bash
cp migration/.env.example migration/.env
# Edit migration/.env with your Confluent Cloud SR URL, API key/secret, and local SR password
source migration/.env
```

### Strategy A — File-based import

Use this when you have exported `.json` files from Confluent Cloud:

```bash
./migration/import-schemas.sh \
  --dir ./schemas \
  --sr-url "${LOCAL_SR_URL}" \
  --user   "${LOCAL_SR_USER}" \
  --password "${LOCAL_SR_PASS}" \
  --import-mode
```

Dry-run first to validate files without POSTing:

```bash
./migration/import-schemas.sh --dir ./schemas --dry-run
```

Expected input format (one `.json` per subject or per version):

```json
{
  "subject":    "orders-value",
  "version":    1,
  "id":         100042,
  "schemaType": "AVRO",
  "schema":     "{\"type\":\"record\",\"name\":\"Order\",...}",
  "references": []
}
```

### Strategy B — Live pull from Confluent Cloud

Connects directly to the Confluent Cloud Schema Registry REST API and mirrors subjects to your local SR:

```bash
./migration/migrate-from-cloud.sh \
  --local-sr-url   "${LOCAL_SR_URL}" \
  --local-user     "${LOCAL_SR_USER}" \
  --local-password "${LOCAL_SR_PASS}" \
  --import-mode
```

| Flag | Description |
|---|---|
| `--dry-run` | List subjects that would be migrated, without POSTing |
| `--all-versions` | Migrate all schema versions (default: latest only) |
| `--subject-filter "^orders-"` | Only migrate subjects matching this regex |
| `--import-mode` | Preserve original Confluent Cloud schema IDs |
| `--save-dir ./audit` | Save each fetched schema as a `.json` file |
| `--continue-on-error` | Skip failures instead of aborting |

> **`--import-mode` is recommended** when producers/consumers reference schemas by numeric ID. Without it, new IDs are assigned and existing serialized messages may fail to deserialize.
>
> `--import-mode` requires a **clean (empty) local SR** or IDs must not conflict with any already registered locally. If re-migrating, run `delete-migrated.sh --permanent` first (see below).

### Validate the migration

```bash
source migration/.env
./migration/validate-migration.sh
```

Per subject the script checks:
1. Subject exists in local SR
2. Schema content matches Confluent Cloud (canonical JSON comparison)
3. `schemaType` matches (AVRO / JSON / PROTOBUF)
4. Schema ID preserved (warns if IDs differ — expected without `--import-mode`)
5. Backward compatibility check
6. Round-trip POST returns 200 (idempotency)

Filter to a subset:

```bash
./migration/validate-migration.sh --filter "^orders-"
./migration/validate-migration.sh --subject "orders-value"
./migration/validate-migration.sh --no-color   # CI-friendly
```

### Re-migrate (clean slate)

If you need to redo the migration with correct settings:

```bash
# 1. Dry run — see what would be deleted
./migration/delete-migrated.sh \
  --local-sr-url "${LOCAL_SR_URL}" \
  --local-user   "${LOCAL_SR_USER}" \
  --local-password "${LOCAL_SR_PASS}" \
  --from-local --dry-run

# 2. Hard delete everything from local SR (--from-local is important: it also
#    removes schemas not in CC, such as local reference schemas that would
#    otherwise block deletion of the CC subjects they depend on)
./migration/delete-migrated.sh \
  --local-sr-url "${LOCAL_SR_URL}" \
  --local-user   "${LOCAL_SR_USER}" \
  --local-password "${LOCAL_SR_PASS}" \
  --from-local --permanent

# 3. Re-migrate
./migration/migrate-from-cloud.sh \
  --local-sr-url   "${LOCAL_SR_URL}" \
  --local-user     "${LOCAL_SR_USER}" \
  --local-password "${LOCAL_SR_PASS}" \
  --all-versions \
  --import-mode
```

> Both `delete-migrated.sh` and `migrate-from-cloud.sh` handle schema reference ordering automatically: subjects that fail with HTTP 422 (reference conflict) are queued and retried after their dependencies are resolved.

---

## Known gotchas

### CP 8.x — Jetty 12 JAAS class renamed

Confluent Platform 8.x upgraded from Jetty 9 to Jetty 12. The JAAS `PropertyFileLoginModule` moved packages:

| CP version | Class |
|---|---|
| CP ≤ 7.x (Jetty 9) | `org.eclipse.jetty.jaas.spi.PropertyFileLoginModule` |
| CP ≥ 8.x (Jetty 12) | `org.eclipse.jetty.security.jaas.spi.PropertyFileLoginModule` |

Using the old class with CP 8.x causes **silent 401 on every authenticated request** — the pod starts healthy but all credentials are rejected. `deploy/secret-auth.yaml` uses the correct class for CP 8.x.

### HTTP Basic auth + Kubernetes probes → restart loop

When `authentication.method: BASIC` is enabled, `GET /subjects` returns `401`. Kubernetes treats 4xx as probe failure and restarts the pod.

**Fix:** use `tcpSocket` probes (port reachability check — auth-agnostic). All values files in this repo already use tcpSocket. To patch an existing deployment:

```bash
./smoke-test.sh --patch-probes
```

### NGINX ingress — configuration-snippet blocked

In ingress-nginx ≥ 1.9 (post CVE-2025-1974), `configuration-snippet` annotations are disabled by default. If you see:

```
admission webhook denied: annotation group ConfigurationSnippet contains risky annotation
```

Either remove the `configuration-snippet` block from `deploy/ingress-nginx.yaml` (Authorization headers are forwarded by default in most setups), or enable snippets in the controller:

```bash
kubectl patch configmap ingress-nginx-controller -n ingress-nginx \
  --patch '{"data":{"allow-snippet-annotations":"true"}}'
```

### --import-mode assigns new IDs if `id` field is missing from payload

The migration scripts now include `id` and `version` in the POST payload when `--import-mode` is active. If you used an older version of the script without this fix, re-migrate using `delete-migrated.sh --permanent` first.

---

## Quick reference

```bash
# Deploy (local)
helm upgrade --install schema-registry ./charts/cp-schema-registry \
  -n schema-registry --create-namespace -f deploy/values-local.yaml

# Port-forward
kubectl port-forward svc/schema-registry -n schema-registry 18081:8081 &

# List subjects
curl -u admin:changeme-admin-password http://localhost:18081/subjects | jq

# Register a schema
curl -u admin:changeme-admin-password \
  -X POST http://localhost:18081/subjects/orders-value/versions \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  -d '{"schemaType":"AVRO","schema":"{\"type\":\"record\",\"name\":\"Order\",\"namespace\":\"io.example\",\"fields\":[{\"name\":\"id\",\"type\":\"string\"},{\"name\":\"amount\",\"type\":\"double\"}]}"}'

# Smoke tests
./smoke-test.sh

# Migrate from Confluent Cloud
source migration/.env
./migration/migrate-from-cloud.sh \
  --local-sr-url "${LOCAL_SR_URL}" \
  --local-user   "${LOCAL_SR_USER}" \
  --local-password "${LOCAL_SR_PASS}" \
  --import-mode

# Validate migration
./migration/validate-migration.sh

# Watch pod logs
kubectl logs -n schema-registry -l app.kubernetes.io/name=cp-schema-registry -f
```

---

## Security notes

- **Never commit `migration/.env`** — it is in `.gitignore`. Copy from `.env.example` and fill in locally.
- Passwords in `deploy/secret-auth.yaml` are placeholders. Replace before any real deployment.
- Generate strong passwords: `openssl rand -base64 32`
- For production, store credentials in AWS Secrets Manager, HashiCorp Vault, or Azure Key Vault and inject via the External Secrets Operator (`deploy/externalsecret-msk-sasl.yaml`).
- The Secret `defaultMode: 0400` ensures password files are owner-read-only inside the pod.
