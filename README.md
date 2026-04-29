# Confluent Schema Registry on Kubernetes

A production-ready, self-contained example for running **Confluent Schema Registry Community Edition** on Kubernetes — from a local kind cluster all the way to EKS.

Includes:
- A local Helm chart using the official `confluentinc/cp-schema-registry` image (no Bitnami)
- HTTP Basic authentication with Jetty JAAS
- Schema migration scripts (file-based and live pull from Confluent Cloud)
- Smoke tests and migration validation
- EKS production overlay

> Tested with Confluent Platform **8.2.0** (Jetty 12) and **7.7.1** (Jetty 9) on kind and EKS.

---

## Repository structure

```
.
├── charts/
│   └── cp-schema-registry/        # Local Helm chart (official confluentinc image)
│       ├── Chart.yaml
│       ├── values.yaml             # All knobs documented
│       └── templates/
│           ├── deployment.yaml
│           ├── service.yaml
│           ├── serviceaccount.yaml
│           ├── pdb.yaml
│           ├── jmx-configmap.yaml
│           ├── _helpers.tpl
│           └── NOTES.txt
│
├── phase1/                         # Local kind cluster deployment
│   ├── values.yaml                 # Helm overrides (Strimzi Kafka, Basic auth, TCP probes)
│   ├── secret-auth.yaml            # Kubernetes Secret: jaas.conf + password.properties
│   └── smoke-test.sh               # 6 automated auth + schema registration tests
│
├── phase2/                         # Schema migration from Confluent Cloud
│   ├── migrate-from-cloud.sh       # Strategy B: live pull via Confluent Cloud REST API
│   ├── import-schemas.sh           # Strategy A: import from local .json export files
│   ├── validate-migration.sh       # Validation: compare Cloud vs local schemas
│   ├── .env                        # Credentials (gitignored — never committed)
│   └── .env.example                # Template for .env
│
├── phase3/                         # EKS production notes
│   ├── values-eks-overlay.yaml     # 3 replicas, NLB, anti-affinity, Prometheus JMX
│   └── pdb.yaml                    # PodDisruptionBudget (minAvailable: 2)
│
└── .gitignore
```

---

## Why a local chart?

The official `confluentinc/cp-helm-charts` repository only publishes an **umbrella chart** via Helm repo — individual sub-charts like `cp-schema-registry` are not installable standalone. This repo extracts and extends the sub-chart with:

- `volumes` / `volumeMounts` support (needed for JAAS Secret mount)
- Configurable probe type (`tcp` | `http`) — critical when Basic auth is enabled
- `schemaRegistryOpts` to set `SCHEMA_REGISTRY_OPTS` env var (for JVM flags)
- `customEnv` as a proper list (supports `valueFrom` / `secretKeyRef`)
- PodDisruptionBudget, SecurityContext, ServiceAccount templates

---

## Resource naming

Helm release `schema-registry` + chart `cp-schema-registry`:

| Resource | Name |
|---|---|
| Deployment | `schema-registry-cp-schema-registry` |
| Service | `schema-registry-cp-schema-registry` |
| Pod label | `app.kubernetes.io/name=cp-schema-registry` |
| ServiceAccount | `schema-registry-cp-schema-registry` |

---

## Phase 1 — Deploy to kind

### Prerequisites

```bash
# Tools
brew install kind kubectl helm jq

# A kind cluster with Strimzi Kafka already running in namespace 'kafka'
# Strimzi cluster name: my-cluster, PLAINTEXT listener on port 9092
```

### 1. Create the auth Secret

Edit `phase1/secret-auth.yaml` — replace `changeme-admin-password` and `changeme-readonly-password` with strong passwords generated via `openssl rand -base64 32`, then apply:

```bash
kubectl apply -f phase1/secret-auth.yaml -n kafka
```

### 2. Deploy Schema Registry

```bash
helm upgrade --install schema-registry ./charts/cp-schema-registry \
  --namespace kafka \
  --create-namespace \
  -f phase1/values.yaml
```

### 3. Watch rollout

```bash
kubectl rollout status deployment/schema-registry-cp-schema-registry -n kafka
```

### 4. Port-forward and test

```bash
kubectl port-forward svc/schema-registry-cp-schema-registry -n kafka 18081:8081 &

curl -u admin:changeme-admin-password http://localhost:18081/subjects | jq
```

### 5. Run smoke tests

```bash
chmod +x phase1/smoke-test.sh
./phase1/smoke-test.sh
```

---

## Phase 2 — Migrate schemas from Confluent Cloud

### Setup credentials

```bash
cp phase2/.env.example phase2/.env
# Edit phase2/.env with your Confluent Cloud SR URL, API key/secret, and local SR password
source phase2/.env
```

### Strategy A — File-based import

Use this when you have exported `.json` files from Confluent Cloud (via `confluent schema-registry export` or similar):

```bash
./phase2/import-schemas.sh \
  --dir ./schemas \
  --sr-url "${LOCAL_SR_URL}" \
  --user   "${LOCAL_SR_USER}" \
  --password "${LOCAL_SR_PASS}"
```

Dry-run first to validate files without POSTing:

```bash
./phase2/import-schemas.sh --dir ./schemas --dry-run
```

Expected input file format (one `.json` per subject or per version):

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

Connects directly to the Confluent Cloud Schema Registry REST API and mirrors subjects into your local SR:

```bash
./phase2/migrate-from-cloud.sh \
  --local-sr-url   "${LOCAL_SR_URL}" \
  --local-user     "${LOCAL_SR_USER}" \
  --local-password "${LOCAL_SR_PASS}"
```

Useful flags:

| Flag | Description |
|---|---|
| `--dry-run` | List subjects that would be migrated, without POSTing |
| `--all-versions` | Migrate all schema versions (default: latest only) |
| `--subject-filter "^orders-"` | Only migrate subjects matching this regex |
| `--import-mode` | Set local SR to IMPORT mode to preserve original Confluent Cloud schema IDs |
| `--save-dir ./audit` | Save each fetched schema as a `.json` file for audit trail |
| `--continue-on-error` | Skip failures instead of aborting on first error |

**Preserving schema IDs** (recommended when producers/consumers reference schemas by numeric ID):

```bash
./phase2/migrate-from-cloud.sh \
  --local-sr-url   "${LOCAL_SR_URL}" \
  --local-user     "${LOCAL_SR_USER}" \
  --local-password "${LOCAL_SR_PASS}" \
  --import-mode
```

> Note: `--import-mode` requires a clean (empty) local SR, or IDs must not conflict with any already registered locally.

### Validate the migration

```bash
source phase2/.env
./phase2/validate-migration.sh
```

For each subject the script checks:
1. Subject exists in local SR
2. Schema content matches Confluent Cloud (canonical JSON comparison)
3. `schemaType` matches (AVRO / JSON / PROTOBUF)
4. Schema ID preserved (warns if IDs differ — expected when run without `--import-mode`)
5. Backward compatibility check against local SR
6. Round-trip POST returns 200 (idempotency)

Filter to a subset:

```bash
./phase2/validate-migration.sh --filter "^orders-"
./phase2/validate-migration.sh --subject "orders-value"
./phase2/validate-migration.sh --no-color   # CI-friendly output
```

---

## Phase 3 — EKS production

Apply the production overlay on top of `phase1/values.yaml`:

```bash
helm upgrade --install schema-registry ./charts/cp-schema-registry \
  --namespace kafka \
  -f phase1/values.yaml \
  -f phase3/values-eks-overlay.yaml
```

What the overlay enables:

| Setting | Value |
|---|---|
| Replicas | 3 |
| Service type | `LoadBalancer` (AWS NLB, internal) |
| PDB | `minAvailable: 2` |
| JVM | G1GC, 1 GB heap |
| Liveness probe | `exec` (reads password from mounted Secret — auth-safe) |
| Pod anti-affinity | Zone-spread (`topology.kubernetes.io/zone`) |
| Prometheus JMX exporter | Enabled on port 5556 |

Apply the standalone PodDisruptionBudget:

```bash
kubectl apply -f phase3/pdb.yaml -n kafka
```

---

## Known gotchas

### CP 8.x — Jetty 12 JAAS class renamed

Confluent Platform 8.x upgraded from Jetty 9 to Jetty 12. The JAAS `PropertyFileLoginModule` moved to a new package:

| CP version | Class |
|---|---|
| CP 7.x and earlier (Jetty 9) | `org.eclipse.jetty.jaas.spi.PropertyFileLoginModule` |
| CP 8.x and later (Jetty 12) | `org.eclipse.jetty.security.jaas.spi.PropertyFileLoginModule` |

Using the old class with CP 8.x causes **silent 401 on every authenticated request** — the pod starts healthy but all credentials are rejected. The `secret-auth.yaml` in this repo uses the correct class for CP 8.x.

To verify which class your version uses:

```bash
POD=$(kubectl get pod -n kafka -l app.kubernetes.io/name=cp-schema-registry -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n kafka "$POD" -- python3 -c "
import zipfile
jar = '/usr/share/java/confluent-security/schema-registry/jetty-security-12.0.25.jar'
with zipfile.ZipFile(jar) as z:
    for n in z.namelist():
        if 'PropertyFile' in n: print(n)
"
```

### HTTP Basic auth + Kubernetes probes → restart loop

When `authentication.method: BASIC` is enabled, `GET /subjects` returns `401`. Kubernetes treats 4xx as a probe failure and restarts the pod endlessly.

**Fix:** use `livenessProbe.type: tcp` (port reachability check — auth-agnostic). The chart and `phase1/values.yaml` default to `type: tcp`. Only switch to `type: http` when authentication is disabled.

### `helm install` fails on existing release

```
Error: INSTALLATION FAILED: cannot re-use a name that is still in use
```

Use `helm upgrade --install` — it installs on first run and upgrades on subsequent runs. All commands in this guide already use this form.

### Port-forward drops after pod restart

After `helm upgrade` or `kubectl rollout restart`, the port-forward loses its connection. Restart it:

```bash
kubectl port-forward svc/schema-registry-cp-schema-registry -n kafka 18081:8081 &
```

### Subject names with spaces

Confluent Cloud allows subject names containing spaces (e.g. `"My Topic"`). The migration and validation scripts URL-encode subject names via `python3 urllib.parse.quote`. If python3 is unavailable, a `sed`-based fallback handles spaces and a few common special characters.

---

## Security notes

- **Never commit `phase2/.env`** — it is in `.gitignore`. Copy from `.env.example` and fill in locally.
- Passwords in `secret-auth.yaml` are placeholders. Replace them before any real deployment.
- Generate strong passwords: `openssl rand -base64 32`
- For production, store credentials in AWS Secrets Manager, HashiCorp Vault, or Azure Key Vault and inject via the external-secrets operator or Vault agent injector.
- The Secret `defaultMode: 0400` ensures password files are owner-read-only inside the pod.

---

## Quick reference

```bash
# Deploy
helm upgrade --install schema-registry ./charts/cp-schema-registry \
  -n kafka -f phase1/values.yaml

# Port-forward
kubectl port-forward svc/schema-registry-cp-schema-registry -n kafka 18081:8081 &

# List subjects
curl -u admin:changeme-admin-password http://localhost:18081/subjects | jq

# Register a schema
curl -u admin:changeme-admin-password \
  -X POST http://localhost:18081/subjects/orders-value/versions \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  -d '{
    "schemaType": "AVRO",
    "schema": "{\"type\":\"record\",\"name\":\"Order\",\"namespace\":\"io.example\",\"fields\":[{\"name\":\"id\",\"type\":\"string\"},{\"name\":\"amount\",\"type\":\"double\"}]}"
  }'

# Migrate from Confluent Cloud
source phase2/.env
./phase2/migrate-from-cloud.sh \
  --local-sr-url "${LOCAL_SR_URL}" \
  --local-user   "${LOCAL_SR_USER}" \
  --local-password "${LOCAL_SR_PASS}"

# Validate migration
./phase2/validate-migration.sh

# Smoke tests
./phase1/smoke-test.sh

# Watch pod logs
kubectl logs -n kafka -l app.kubernetes.io/name=cp-schema-registry -f
```
