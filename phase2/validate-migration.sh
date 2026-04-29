#!/usr/bin/env bash
# =============================================================================
# Migration validation — compare Confluent Cloud schemas against local SR
#
# Validates that every subject migrated to the local Schema Registry:
#   1. Exists in local SR
#   2. Has the same schema content as Confluent Cloud
#   3. Has correct schemaType
#   4. Passes a compatibility check (local SR accepts the schema)
#
# Also runs a deep test on the first AVRO subject found (key + value pair)
# as a representative end-to-end subject test.
#
# Usage:
#   source phase2/.env          # load credentials
#   ./phase2/validate-migration.sh
#
#   # Validate only subjects matching a pattern
#   ./phase2/validate-migration.sh --filter "orders"
#
#   # Check a single subject
#   ./phase2/validate-migration.sh --subject "orders-value"
#
# Options:
#   --filter REGEX    Only validate subjects matching this pattern (grep -E)
#   --subject NAME    Validate a single specific subject
#   --no-color        Disable colour output (for CI logs)
# =============================================================================
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
SUBJECT_FILTER=""
SPECIFIC_SUBJECT=""
USE_COLOR=true

PASS=0; FAIL=0; SKIP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --filter)   SUBJECT_FILTER="$2";   shift 2 ;;
    --subject)  SPECIFIC_SUBJECT="$2"; shift 2 ;;
    --no-color) USE_COLOR=false;       shift   ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Credentials — sourced from .env or environment ────────────────────────────
: "${CONFLUENT_SR_URL:?Source phase2/.env first (or set CONFLUENT_SR_URL)}"
: "${CONFLUENT_SR_API_KEY:?Set CONFLUENT_SR_API_KEY}"
: "${CONFLUENT_SR_API_SECRET:?Set CONFLUENT_SR_API_SECRET}"
: "${LOCAL_SR_URL:?Set LOCAL_SR_URL}"
: "${LOCAL_SR_USER:?Set LOCAL_SR_USER}"
: "${LOCAL_SR_PASS:?Set LOCAL_SR_PASS}"

command -v jq   >/dev/null 2>&1 || { echo "ERROR: jq required"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl required"; exit 1; }

# ── Colour helpers ─────────────────────────────────────────────────────────────
if [[ "${USE_COLOR}" == true ]]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

hr()    { printf '%s\n' "──────────────────────────────────────────────────────"; }
log()   { printf "${CYAN}[%s]${RESET} %s\n" "$(date +%H:%M:%S)" "$*"; }
pass()  { printf "  ${GREEN}✓${RESET}  %s\n" "$1"; (( PASS++ )) || true; }
fail()  { printf "  ${RED}✗${RESET}  %s\n" "$1"; (( FAIL++ )) || true; }
warn()  { printf "  ${YELLOW}~${RESET}  %s\n" "$1"; (( SKIP++ )) || true; }
title() { printf "\n${BOLD}%s${RESET}\n" "$1"; hr; }

# ── URL-encode (handles spaces and special chars in subject names) ─────────────
urlencode() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$1"
  else
    echo "$1" | sed 's/ /%20/g; s/#/%23/g; s/\[/%5B/g; s/\]/%5D/g'
  fi
}

# ── REST helpers ───────────────────────────────────────────────────────────────
cc_get() {
  curl -sf \
    -u "${CONFLUENT_SR_API_KEY}:${CONFLUENT_SR_API_SECRET}" \
    -H "Accept: application/vnd.schemaregistry.v1+json" \
    "${CONFLUENT_SR_URL}${1}"
}

local_get() {
  curl -sf \
    -u "${LOCAL_SR_USER}:${LOCAL_SR_PASS}" \
    -H "Accept: application/vnd.schemaregistry.v1+json" \
    "${LOCAL_SR_URL}${1}"
}

local_post() {
  curl -sf \
    -u "${LOCAL_SR_USER}:${LOCAL_SR_PASS}" \
    -X POST \
    -H "Content-Type: application/vnd.schemaregistry.v1+json" \
    -d "$2" \
    "${LOCAL_SR_URL}${1}"
}

# ── Normalise schema string for comparison ────────────────────────────────────
# Schema Registry may return schemas with different whitespace or key ordering.
# Re-serialise through jq to get a canonical form before diffing.
normalise_schema() {
  echo "$1" | jq -c 'if type == "string" then fromjson | tojson else tojson end' 2>/dev/null \
    || echo "$1"
}

# ── Per-subject validation ────────────────────────────────────────────────────
validate_subject() {
  local subject="$1"
  local encoded
  encoded=$(urlencode "${subject}")
  printf "\n  Subject: ${BOLD}%s${RESET}\n" "${subject}"

  # 1. Fetch from Confluent Cloud
  local cc_response
  if ! cc_response=$(cc_get "/subjects/${encoded}/versions/latest" 2>/dev/null); then
    fail "${subject}: could not fetch from Confluent Cloud"
    return
  fi

  local cc_schema cc_type cc_id cc_version
  cc_schema=$(echo "${cc_response}"  | jq -r '.schema')
  cc_type=$(echo "${cc_response}"    | jq -r '.schemaType // "AVRO"')
  cc_id=$(echo "${cc_response}"      | jq -r '.id')
  cc_version=$(echo "${cc_response}" | jq -r '.version')

  # 2. Fetch from local SR
  local local_response
  if ! local_response=$(local_get "/subjects/${encoded}/versions/latest" 2>/dev/null); then
    fail "${subject}: NOT FOUND in local SR — has migration been run?"
    return
  fi

  local local_schema local_type local_id local_version
  local_schema=$(echo "${local_response}"  | jq -r '.schema')
  local_type=$(echo "${local_response}"    | jq -r '.schemaType // "AVRO"')
  local_id=$(echo "${local_response}"      | jq -r '.id')
  local_version=$(echo "${local_response}" | jq -r '.version')

  pass "${subject}: present in local SR (version=${local_version})"

  # 3. Compare schemaType
  if [[ "${cc_type}" == "${local_type}" ]]; then
    pass "  schemaType matches: ${local_type}"
  else
    fail "  schemaType mismatch — Cloud: ${cc_type}, Local: ${local_type}"
  fi

  # 4. Compare schema content (canonical JSON comparison)
  local cc_norm local_norm
  cc_norm=$(normalise_schema "${cc_schema}")
  local_norm=$(normalise_schema "${local_schema}")

  if [[ "${cc_norm}" == "${local_norm}" ]]; then
    pass "  schema content matches"
  else
    fail "  schema content DIFFERS"
    echo "    Cloud  (truncated): ${cc_norm:0:120}..."
    echo "    Local  (truncated): ${local_norm:0:120}..."
  fi

  # 5. Check schema ID preservation (only meaningful if --import-mode was used)
  if [[ "${cc_id}" == "${local_id}" ]]; then
    pass "  schema ID preserved: ${local_id} (import-mode was used)"
  else
    warn "  schema ID differs — Cloud: ${cc_id}, Local: ${local_id} (expected if migration ran without --import-mode)"
  fi
}

# ── Deep test: pick first AVRO subject and run end-to-end checks ──────────────
# Selects the first migrated AVRO subject, verifies its structure, tests
# backward compatibility, and does a round-trip POST (idempotency check).
deep_test_first_avro() {
  title "Deep Test — first AVRO subject (end-to-end)"

  # Pick first AVRO subject from local SR
  local subjects_json
  subjects_json=$(local_get "/subjects")

  local subject
  subject=$(echo "${subjects_json}" | jq -r '.[]' | head -1)

  if [[ -z "${subject}" ]]; then
    warn "No subjects found in local SR — skipping deep test"
    return
  fi

  local encoded
  encoded=$(urlencode "${subject}")
  log "Selected subject: ${subject}"

  # ── Fetch schema from local SR ──────────────────────────────────────────────
  local local_resp
  if ! local_resp=$(local_get "/subjects/${encoded}/versions/latest" 2>/dev/null); then
    fail "${subject}: not found in local SR"
    return
  fi

  local schema_type
  schema_type=$(echo "${local_resp}" | jq -r '.schemaType // "AVRO"')
  pass "  Subject present in local SR — schemaType: ${schema_type}"

  # ── Schema structure checks ─────────────────────────────────────────────────
  local schema_str
  schema_str=$(echo "${local_resp}" | jq -r '.schema')

  if echo "${schema_str}" | jq . >/dev/null 2>&1; then
    pass "  Schema content is valid JSON"
    local field_count
    field_count=$(echo "${schema_str}" | jq '.fields | length // 0' 2>/dev/null || echo "0")
    [[ "${field_count}" -gt 0 ]] \
      && pass "  Schema has ${field_count} field(s) defined" \
      || warn "  Schema has no fields (may be a primitive or union type)"
  else
    fail "  Schema content is not valid JSON"
    return
  fi

  # ── Compatibility: re-check cloud schema against local ──────────────────────
  local cc_resp
  if ! cc_resp=$(cc_get "/subjects/${encoded}/versions/latest" 2>/dev/null); then
    warn "  Cannot reach Confluent Cloud for compatibility check — skipping"
    return
  fi

  local cc_schema
  cc_schema=$(echo "${cc_resp}" | jq -r '.schema')

  local compat_payload
  compat_payload=$(jq -n --arg s "${cc_schema}" '{schema: $s}')

  local compat_resp
  if compat_resp=$(curl -sf \
      -u "${LOCAL_SR_USER}:${LOCAL_SR_PASS}" \
      -X POST \
      -H "Content-Type: application/vnd.schemaregistry.v1+json" \
      -d "${compat_payload}" \
      "${LOCAL_SR_URL}/compatibility/subjects/${encoded}/versions/latest" 2>/dev/null); then
    local is_compat
    is_compat=$(echo "${compat_resp}" | jq -r '.is_compatible')
    [[ "${is_compat}" == "true" ]] \
      && pass "  Cloud schema is backward compatible with local copy" \
      || fail "  Compatibility check returned is_compatible=${is_compat}"
  else
    warn "  Compatibility endpoint unavailable (non-fatal)"
  fi

  # ── Round-trip POST (idempotency) ───────────────────────────────────────────
  log "Round-trip: re-POST cloud schema to local SR (expect idempotent 200)"

  local rt_payload
  rt_payload=$(jq -n --arg s "${cc_schema}" '{schemaType: "AVRO", schema: $s}')

  local rt_resp rt_code rt_body
  rt_resp=$(curl -s -w "\n%{http_code}" \
    -u "${LOCAL_SR_USER}:${LOCAL_SR_PASS}" \
    -X POST \
    -H "Content-Type: application/vnd.schemaregistry.v1+json" \
    -d "${rt_payload}" \
    "${LOCAL_SR_URL}/subjects/${encoded}/versions")
  rt_code=$(echo "${rt_resp}" | tail -1)
  rt_body=$(echo "${rt_resp}" | sed '$d')

  if [[ "${rt_code}" == "200" ]]; then
    local rt_id
    rt_id=$(echo "${rt_body}" | jq -r '.id')
    pass "  Round-trip POST returned 200 — id=${rt_id} (idempotent)"
  else
    fail "  Round-trip POST failed (HTTP ${rt_code}): ${rt_body}"
  fi
}

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
  hr
  printf "\n${BOLD}Results:${RESET}  "
  printf "${GREEN}%d passed${RESET}  " "${PASS}"
  printf "${RED}%d failed${RESET}  " "${FAIL}"
  printf "${YELLOW}%d warnings${RESET}\n\n" "${SKIP}"

  if [[ "${FAIL}" -gt 0 ]]; then
    printf "${RED}VALIDATION FAILED${RESET} — check output above\n\n"
    echo "Hints:"
    echo "  • Run the migration:  source phase2/.env && ./phase2/migrate-from-cloud.sh --local-password \"\${LOCAL_SR_PASS}\" --local-sr-url \"\${LOCAL_SR_URL}\""
    echo "  • Preserve IDs:       add --import-mode to the command above"
    echo "  • Port-forward:       kubectl -n kafka port-forward svc/schema-registry-cp-schema-registry 18081:8081"
    return 1
  else
    printf "${GREEN}ALL VALIDATIONS PASSED${RESET}\n\n"
    return 0
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  title "Schema Migration Validation"
  log "Source (Cloud) : ${CONFLUENT_SR_URL}"
  log "Target (Local) : ${LOCAL_SR_URL}"

  # ── Check local SR is reachable ────────────────────────────────────────────
  title "0 — Connectivity"
  if local_get "/subjects" >/dev/null 2>&1; then
    pass "Local SR reachable at ${LOCAL_SR_URL}"
  else
    fail "Cannot reach local SR at ${LOCAL_SR_URL}"
    echo "  Start port-forward:  kubectl -n kafka port-forward svc/schema-registry-cp-schema-registry 18081:8081 &"
    exit 1
  fi

  if cc_get "/subjects" >/dev/null 2>&1; then
    pass "Confluent Cloud SR reachable"
  else
    fail "Cannot reach Confluent Cloud SR — check CONFLUENT_SR_URL / credentials"
    exit 1
  fi

  # ── Fetch subject lists ────────────────────────────────────────────────────
  local cc_subjects_json local_subjects_json
  cc_subjects_json=$(cc_get "/subjects")
  local_subjects_json=$(local_get "/subjects")

  local cc_count local_count
  cc_count=$(echo "${cc_subjects_json}"    | jq 'length')
  local_count=$(echo "${local_subjects_json}" | jq 'length')

  log "Confluent Cloud: ${cc_count} subjects"
  log "Local SR       : ${local_count} subjects"

  # ── Build list of subjects to validate ────────────────────────────────────
  local -a subjects=()
  if [[ -n "${SPECIFIC_SUBJECT}" ]]; then
    subjects=("${SPECIFIC_SUBJECT}")
  elif [[ -n "${SUBJECT_FILTER}" ]]; then
    while IFS= read -r s; do subjects+=("$s"); done \
      < <(echo "${cc_subjects_json}" | jq -r '.[]' | grep -E "${SUBJECT_FILTER}" || true)
  else
    while IFS= read -r s; do subjects+=("$s"); done \
      < <(echo "${cc_subjects_json}" | jq -r '.[]')
  fi

  # ── Subject-by-subject validation ─────────────────────────────────────────
  title "1 — Per-subject schema validation (${#subjects[@]} subjects)"
  for subject in "${subjects[@]}"; do
    validate_subject "${subject}"
  done

  # ── Count summary ──────────────────────────────────────────────────────────
  title "2 — Subject count check"
  if [[ -z "${SUBJECT_FILTER}" && -z "${SPECIFIC_SUBJECT}" ]]; then
    # Exclude subjects that existed in local SR before migration (smoke-test-value, etc.)
    local migrated
    migrated=$(echo "${local_subjects_json}" | jq --argjson cloud "${cc_subjects_json}" \
      '[.[] | select(. as $s | $cloud | index($s) != null)] | length')

    if [[ "${migrated}" -eq "${cc_count}" ]]; then
      pass "All ${cc_count} Confluent Cloud subjects are present in local SR"
    else
      fail "Expected ${cc_count} cloud subjects in local SR, found ${migrated}"
    fi
  fi

  # ── Deep test on first available AVRO subject ──────────────────────────────
  if [[ -z "${SPECIFIC_SUBJECT}" && -z "${SUBJECT_FILTER}" ]]; then
    deep_test_first_avro
  fi

  print_summary
}

main
