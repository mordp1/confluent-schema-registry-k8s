#!/usr/bin/env bash
# =============================================================================
# Schema Registry smoke tests — Phase 1 (kind-kafka-test cluster)
#
# Runs a port-forward to the Schema Registry pod and executes 5 tests:
#   1. Unauthenticated GET /subjects  → expect 401 (auth is enforced)
#   2. Authenticated  GET /subjects   → expect 200
#   3. Register an Avro schema        → expect 200 with schema ID
#   4. Read back the registered schema
#   5. Write attempt with read-only user → expect 403
#
# Usage:
#   chmod +x smoke-test.sh
#   ./smoke-test.sh                      # run full smoke tests
#   ./smoke-test.sh --patch-probes       # fix liveness probe restart loop first
#
# Prerequisites:
#   - kubectl, curl, jq installed
#   - kind-kafka-test context active and schema-registry deployed
# =============================================================================
set -euo pipefail

NAMESPACE="kafka"
CONTEXT="kind-kafka-test"
LOCAL_PORT="18081"      # local port to forward to (avoids conflicts with :8081)
SR_URL="http://localhost:${LOCAL_PORT}"

# Must match password.properties in secret-auth.yaml
ADMIN_USER="admin"
ADMIN_PASS="changeme-admin-password"
READONLY_USER="readonly"
READONLY_PASS="changeme-readonly-password"

PASS=0; FAIL=0
PF_PID=""

# ── Utilities ─────────────────────────────────────────────────────────────────
hr()   { printf '\n%s\n' "──────────────────────────────────────────────────"; }
ok()   { printf '  ✓  %s\n' "$1"; (( PASS++ )) || true; }
fail() { printf '  ✗  %s\n' "$1"; (( FAIL++ )) || true; }

kube() { kubectl --context="${CONTEXT}" -n "${NAMESPACE}" "$@"; }

# ── Patch probes ──────────────────────────────────────────────────────────────
# Run this ONCE after initial helm install to stop the liveness/readiness probe
# restart loop caused by HTTP 401 on /subjects when auth is enabled.
# (If you used values.yaml from this repo, tcpSocket probes are already set and
#  this patch is not needed — it's included as a fallback for manual installs.)
patch_probes() {
  hr
  echo "Patching deployment probes → tcpSocket (workaround for 401 on /subjects)"
  local deploy
  deploy=$(kube get deploy -l app.kubernetes.io/name=cp-schema-registry \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -z "${deploy}" ]]; then
    echo "  No schema-registry deployment found. Is it deployed?"
    exit 1
  fi

  kube patch deployment "${deploy}" --type=json -p='[
    {
      "op": "replace",
      "path": "/spec/template/spec/containers/0/livenessProbe",
      "value": {
        "tcpSocket": {"port": 8081},
        "initialDelaySeconds": 30,
        "periodSeconds": 10,
        "failureThreshold": 6
      }
    },
    {
      "op": "replace",
      "path": "/spec/template/spec/containers/0/readinessProbe",
      "value": {
        "tcpSocket": {"port": 8081},
        "initialDelaySeconds": 20,
        "periodSeconds": 10,
        "failureThreshold": 3
      }
    }
  ]'
  ok "Probes patched to tcpSocket"
  echo "  Waiting for rollout..."
  kube rollout status deployment/"${deploy}" --timeout=120s
}

# ── Port-forward ──────────────────────────────────────────────────────────────
start_port_forward() {
  hr
  echo "Starting port-forward: localhost:${LOCAL_PORT} → schema-registry:8081"
  local pod
  pod=$(kube get pods -l app.kubernetes.io/name=cp-schema-registry \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -z "${pod}" ]]; then
    echo "ERROR: no running cp-schema-registry pod found. Check: kubectl -n ${NAMESPACE} get pods"
    exit 1
  fi

  kube port-forward "pod/${pod}" "${LOCAL_PORT}:8081" &>/tmp/sr-pf.log &
  PF_PID=$!
  # Give it a moment to establish
  sleep 2
  if ! kill -0 "${PF_PID}" 2>/dev/null; then
    echo "ERROR: port-forward failed. Check /tmp/sr-pf.log"
    cat /tmp/sr-pf.log
    exit 1
  fi
  echo "  Pod: ${pod} | PID: ${PF_PID}"
}

cleanup() {
  [[ -n "${PF_PID}" ]] && kill "${PF_PID}" 2>/dev/null || true
}
trap cleanup EXIT

# ── Test helpers ──────────────────────────────────────────────────────────────
http_code() {
  curl -s -o /dev/null -w "%{http_code}" "$@"
}

sr_get() {
  curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -H "Accept: application/vnd.schemaregistry.v1+json" \
    "$@"
}

sr_post() {
  curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -X POST \
    -H "Content-Type: application/vnd.schemaregistry.v1+json" \
    "$@"
}

# ── Tests ─────────────────────────────────────────────────────────────────────
test_unauth_401() {
  hr
  echo "TEST 1 — Unauthenticated GET /subjects → expect 401"
  local code
  code=$(http_code "${SR_URL}/subjects")
  if [[ "${code}" == "401" ]]; then
    ok "Got 401 — authentication is enforced"
  else
    fail "Expected 401, got ${code}"
  fi
}

test_auth_200() {
  hr
  echo "TEST 2 — Authenticated GET /subjects → expect 200"
  local body code
  code=$(http_code -u "${ADMIN_USER}:${ADMIN_PASS}" "${SR_URL}/subjects")
  if [[ "${code}" == "200" ]]; then
    body=$(sr_get "${SR_URL}/subjects")
    ok "Got 200 — current subjects: ${body}"
  else
    fail "Expected 200, got ${code}"
  fi
}

test_register_schema() {
  hr
  echo "TEST 3 — Register Avro schema for subject 'smoke-test-value'"

  # An Avro record schema with a few representative field types.
  # The 'schema' field must be a JSON-escaped string (not a nested object).
  local payload='{
    "schemaType": "AVRO",
    "schema": "{\"type\":\"record\",\"name\":\"SmokeTestEvent\",\"namespace\":\"io.example.schemaregistry\",\"doc\":\"Smoke-test schema for Schema Registry validation\",\"fields\":[{\"name\":\"id\",\"type\":\"string\",\"doc\":\"Unique event identifier\"},{\"name\":\"eventType\",\"type\":\"string\"},{\"name\":\"timestamp\",\"type\":\"long\",\"logicalType\":\"timestamp-millis\"},{\"name\":\"payload\",\"type\":[\"null\",\"string\"],\"default\":null}]}"
  }'

  local response schema_id
  response=$(sr_post -d "${payload}" "${SR_URL}/subjects/smoke-test-value/versions")
  schema_id=$(echo "${response}" | jq -r '.id // empty')

  if [[ -n "${schema_id}" ]]; then
    ok "Schema registered — id=${schema_id}"
    # Store for next test
    export REGISTERED_SCHEMA_ID="${schema_id}"
  else
    fail "Registration failed — response: ${response}"
  fi
}

test_read_back_schema() {
  hr
  echo "TEST 4 — Read back 'smoke-test-value/versions/latest'"
  local response subject version id
  response=$(sr_get "${SR_URL}/subjects/smoke-test-value/versions/latest")
  subject=$(echo "${response}" | jq -r '.subject // empty')
  version=$(echo "${response}" | jq -r '.version // empty')
  id=$(echo "${response}" | jq -r '.id // empty')

  if [[ "${subject}" == "smoke-test-value" && -n "${id}" ]]; then
    ok "Schema retrieved — subject=${subject} version=${version} id=${id}"
  else
    fail "Read-back failed — response: ${response}"
  fi
}

test_readonly_cannot_write() {
  hr
  echo "TEST 5 — Read-only user write attempt → expect 401 or 403"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "${READONLY_USER}:${READONLY_PASS}" \
    -X POST \
    -H "Content-Type: application/vnd.schemaregistry.v1+json" \
    -d '{"schemaType":"AVRO","schema":"{\"type\":\"string\"}"}' \
    "${SR_URL}/subjects/unauthorized-write-attempt/versions")

  if [[ "${code}" == "401" || "${code}" == "403" ]]; then
    ok "Got ${code} — read-only user write blocked"
  else
    fail "Expected 401/403 for read-only write, got ${code}"
  fi
}

test_global_config() {
  hr
  echo "TEST 6 — GET /config → check global compatibility level"
  local compat
  compat=$(sr_get "${SR_URL}/config" | jq -r '.compatibilityLevel // empty')
  if [[ -n "${compat}" ]]; then
    ok "Global compatibility level: ${compat}"
  else
    fail "Could not retrieve /config"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo "================================================================"
  echo "  Schema Registry Smoke Tests — kind-kafka-test / namespace:kafka"
  echo "================================================================"

  if [[ "${1:-}" == "--patch-probes" ]]; then
    patch_probes
    echo ""
    echo "Done. Re-run without --patch-probes to execute smoke tests."
    exit 0
  fi

  command -v jq  >/dev/null 2>&1 || { echo "ERROR: jq is required (brew install jq)"; exit 1; }
  command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required"; exit 1; }

  start_port_forward

  test_unauth_401
  test_auth_200
  test_register_schema
  test_read_back_schema
  test_readonly_cannot_write
  test_global_config

  hr
  echo ""
  echo "  Results: ${PASS} passed, ${FAIL} failed"

  if [[ "${FAIL}" -gt 0 ]]; then
    echo "  FAILED — check output above"
    exit 1
  else
    echo "  All smoke tests passed ✓"
    echo ""
    echo "  Next steps:"
    echo "    • Run schema migration: cd ../phase2 && ./import-schemas.sh --help"
    echo "    • Access Kafka UI: kubectl port-forward svc/kafka-ui 8080:8080 -n kafka"
    exit 0
  fi
}

main "$@"
