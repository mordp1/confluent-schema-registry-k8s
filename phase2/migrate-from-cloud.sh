#!/usr/bin/env bash
# =============================================================================
# Strategy B — Live pull from Confluent Cloud Schema Registry
#
# Connects to Confluent Cloud SR, lists subjects, fetches schemas, and POSTs
# them to a local (target) Schema Registry instance.
#
# Usage:
#   export CONFLUENT_SR_URL="https://psrc-xxxxx.us-east-2.aws.confluent.cloud"
#   export CONFLUENT_SR_API_KEY="your-api-key"
#   export CONFLUENT_SR_API_SECRET="your-api-secret"
#
#   ./migrate-from-cloud.sh \
#     --local-sr-url  http://localhost:18081 \
#     --local-user    admin \
#     --local-password changeme-admin-password
#
#   # Migrate only subjects matching a pattern:
#   ./migrate-from-cloud.sh --subject-filter "^orders-" ...
#
#   # Migrate all versions (not just latest):
#   ./migrate-from-cloud.sh --all-versions ...
#
#   # Dry run — list subjects without migrating:
#   ./migrate-from-cloud.sh --dry-run
#
# Required environment variables:
#   CONFLUENT_SR_URL        Confluent Cloud SR endpoint (no trailing slash)
#   CONFLUENT_SR_API_KEY    Confluent Cloud SR API key
#   CONFLUENT_SR_API_SECRET Confluent Cloud SR API secret
#
# Options:
#   --local-sr-url      Local Schema Registry URL (default: http://localhost:18081)
#   --local-user        Local SR basic auth username (default: admin)
#   --local-password    Local SR basic auth password (required unless --dry-run)
#   --subject-filter    Extended regex to filter subject names (grep -E)
#                       Examples: "^orders-"  "-(key|value)$"  "payments\."
#   --all-versions      Migrate ALL versions per subject (default: latest only)
#   --dry-run           List subjects that would be migrated without POSTing
#   --import-mode       Set local SR to IMPORT mode to preserve original schema IDs
#   --continue-on-error Do not abort on first POST failure
#   --save-dir DIR      Save fetched schemas as JSON files in DIR (for audit trail
#                       or for re-importing later via import-schemas.sh Strategy A)
# =============================================================================
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
LOCAL_SR_URL="http://localhost:18081"
LOCAL_USER="admin"
LOCAL_PASS=""
SUBJECT_FILTER=""
ALL_VERSIONS=false
DRY_RUN=false
IMPORT_MODE=false
CONTINUE_ON_ERROR=false
SAVE_DIR=""

SUCCESS=0; FAIL=0; SKIP=0

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local-sr-url)      LOCAL_SR_URL="$2";    shift 2 ;;
    --local-user)        LOCAL_USER="$2";      shift 2 ;;
    --local-password)    LOCAL_PASS="$2";      shift 2 ;;
    --subject-filter)    SUBJECT_FILTER="$2";  shift 2 ;;
    --all-versions)      ALL_VERSIONS=true;    shift   ;;
    --dry-run)           DRY_RUN=true;         shift   ;;
    --import-mode)       IMPORT_MODE=true;     shift   ;;
    --continue-on-error) CONTINUE_ON_ERROR=true; shift ;;
    --save-dir)          SAVE_DIR="$2";        shift 2 ;;
    -h|--help)
      sed -n '/^# Usage:/,/^# ====/{s/^# //;p}' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1 (use --help)"; exit 1 ;;
  esac
done

# ── Validation ────────────────────────────────────────────────────────────────
: "${CONFLUENT_SR_URL:?ERROR: CONFLUENT_SR_URL env var must be set}"
: "${CONFLUENT_SR_API_KEY:?ERROR: CONFLUENT_SR_API_KEY env var must be set}"
: "${CONFLUENT_SR_API_SECRET:?ERROR: CONFLUENT_SR_API_SECRET env var must be set}"

if [[ "${DRY_RUN}" == false && -z "${LOCAL_PASS}" ]]; then
  echo "ERROR: --local-password is required (or use --dry-run)"
  exit 1
fi
command -v jq   >/dev/null 2>&1 || { echo "ERROR: jq required (brew install jq)"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl required"; exit 1; }

[[ -n "${SAVE_DIR}" ]] && mkdir -p "${SAVE_DIR}"

# ── Logging helpers ───────────────────────────────────────────────────────────
log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '  ✓  %s\n' "$1"; (( SUCCESS++ )) || true; }
err()  { printf '  ✗  %s\n' "$1"; (( FAIL++ )) || true; }
skip() { printf '  –  %s\n' "$1"; (( SKIP++ )) || true; }

# ── URL-encode a string (spaces and special chars in subject names) ───────────
urlencode() {
  # Uses python3 if available, otherwise a sed-based fallback for basic cases.
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$1"
  else
    echo "$1" | sed 's/ /%20/g; s/#/%23/g; s/\[/%5B/g; s/\]/%5D/g'
  fi
}

# ── Confluent Cloud REST helpers ──────────────────────────────────────────────
# All requests to Confluent Cloud use API key/secret as HTTP Basic credentials.
# The Content-Type header is required even on GET requests by some SR versions.
cc_get() {
  local path="$1"
  curl -sf \
    -u "${CONFLUENT_SR_API_KEY}:${CONFLUENT_SR_API_SECRET}" \
    -H "Accept: application/vnd.schemaregistry.v1+json" \
    "${CONFLUENT_SR_URL}${path}"
}

# ── Local SR REST helpers ─────────────────────────────────────────────────────
local_post() {
  local path="$1"
  local payload="$2"
  curl -s -w "\n%{http_code}" \
    -u "${LOCAL_USER}:${LOCAL_PASS}" \
    -X POST \
    -H "Content-Type: application/vnd.schemaregistry.v1+json" \
    -d "${payload}" \
    "${LOCAL_SR_URL}${path}"
}

local_put() {
  local path="$1"
  local payload="$2"
  curl -s -w "\n%{http_code}" \
    -u "${LOCAL_USER}:${LOCAL_PASS}" \
    -X PUT \
    -H "Content-Type: application/vnd.schemaregistry.v1+json" \
    -d "${payload}" \
    "${LOCAL_SR_URL}${path}"
}

# ── SR mode management ────────────────────────────────────────────────────────
set_mode() {
  local mode="$1"
  [[ "${DRY_RUN}" == true ]] && return
  log "Setting local SR mode → ${mode}"
  local r
  r=$(local_put "/mode" "{\"mode\":\"${mode}\"}")
  local code; code=$(echo "${r}" | tail -1)
  [[ "${code}" != "200" ]] && log "  WARNING: mode set returned HTTP ${code}"
}

# ── Migrate a single (subject, version JSON) pair ────────────────────────────
migrate_version() {
  local subject="$1"
  local version_json="$2"
  local version_num="${3:-?}"

  local schema schema_type references payload
  schema=$(echo "${version_json}"       | jq -r '.schema')
  schema_type=$(echo "${version_json}"  | jq -r '.schemaType // "AVRO"')
  references=$(echo "${version_json}"   | jq -c '.references // []')

  # ── Optionally save to disk ───────────────────────────────────────────────
  if [[ -n "${SAVE_DIR}" ]]; then
    local safe_subject
    # Replace / and : with _ for filesystem safety
    safe_subject=$(echo "${subject}" | tr '/: ' '___')
    echo "${version_json}" > "${SAVE_DIR}/${safe_subject}_v${version_num}.json"
  fi

  payload=$(jq -n \
    --arg   st   "${schema_type}" \
    --arg   sc   "${schema}" \
    --argjson refs "${references}" \
    '{schemaType: $st, schema: $sc, references: $refs}')

  local encoded_subject
  encoded_subject=$(urlencode "${subject}")
  local response http_code body
  response=$(local_post "/subjects/${encoded_subject}/versions" "${payload}")
  http_code=$(echo "${response}" | tail -1)
  body=$(echo "${response}" | sed '$d')

  case "${http_code}" in
    200)
      local id; id=$(echo "${body}" | jq -r '.id // "?"')
      ok "${subject}@v${version_num} (${schema_type}): id=${id}"
      ;;
    409)
      local id; id=$(echo "${body}" | jq -r '.id // "?"')
      ok "${subject}@v${version_num}: already registered → id=${id} (idempotent)"
      ;;
    *)
      local msg; msg=$(echo "${body}" | jq -r '.message // .error_code // empty' 2>/dev/null || echo "${body}")
      err "${subject}@v${version_num}: POST failed (HTTP ${http_code}) — ${msg}"
      if [[ "${CONTINUE_ON_ERROR}" == false ]]; then
        log "Aborting. Use --continue-on-error to proceed past failures."
        set_mode "READWRITE"
        exit 1
      fi
      ;;
  esac
}

# ── Migrate all versions or latest for one subject ────────────────────────────
migrate_subject() {
  local subject="$1"
  local encoded
  encoded=$(urlencode "${subject}")

  if [[ "${ALL_VERSIONS}" == true ]]; then
    local versions_json
    if ! versions_json=$(cc_get "/subjects/${encoded}/versions" 2>/dev/null); then
      err "${subject}: failed to fetch version list from Confluent Cloud"
      return
    fi
    local -a version_nums=()
    while IFS= read -r v; do version_nums+=("$v"); done \
      < <(echo "${versions_json}" | jq -r '.[]')

    for v in "${version_nums[@]}"; do
      local vdata
      if ! vdata=$(cc_get "/subjects/${encoded}/versions/${v}" 2>/dev/null); then
        err "${subject}@v${v}: fetch failed"
        continue
      fi
      migrate_version "${subject}" "${vdata}" "${v}"
    done
  else
    local vdata
    if ! vdata=$(cc_get "/subjects/${encoded}/versions/latest" 2>/dev/null); then
      err "${subject}: failed to fetch from Confluent Cloud (check subject name)"
      return
    fi
    local vnum; vnum=$(echo "${vdata}" | jq -r '.version // "latest"')
    migrate_version "${subject}" "${vdata}" "${vnum}"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  log "================================================================"
  log " Schema Migration — Strategy B (live pull from Confluent Cloud)"
  log " Source SR      : ${CONFLUENT_SR_URL}"
  log " Target SR URL  : ${LOCAL_SR_URL}"
  log " All versions   : ${ALL_VERSIONS}"
  log " Dry run        : ${DRY_RUN}"
  log " Import mode    : ${IMPORT_MODE}"
  [[ -n "${SUBJECT_FILTER}" ]] && log " Subject filter : ${SUBJECT_FILTER}"
  [[ -n "${SAVE_DIR}" ]]       && log " Save dir       : ${SAVE_DIR}"
  log "================================================================"

  # ── Fetch full subject list from Confluent Cloud ──────────────────────────
  log "Fetching subject list from Confluent Cloud..."
  local all_subjects_json
  all_subjects_json=$(cc_get "/subjects")
  local total; total=$(echo "${all_subjects_json}" | jq 'length')
  log "Found ${total} subject(s) in Confluent Cloud"

  # ── Apply subject filter ──────────────────────────────────────────────────
  local -a subjects=()
  if [[ -n "${SUBJECT_FILTER}" ]]; then
    while IFS= read -r s; do subjects+=("$s"); done \
      < <(echo "${all_subjects_json}" | jq -r '.[]' | grep -E "${SUBJECT_FILTER}" || true)
    log "After filter '${SUBJECT_FILTER}': ${#subjects[@]} subject(s) will be migrated"
  else
    while IFS= read -r s; do subjects+=("$s"); done \
      < <(echo "${all_subjects_json}" | jq -r '.[]')
  fi

  if [[ ${#subjects[@]} -eq 0 ]]; then
    log "No subjects to migrate."
    exit 0
  fi

  # ── Dry-run: just list ────────────────────────────────────────────────────
  if [[ "${DRY_RUN}" == true ]]; then
    log "DRY RUN — subjects that would be migrated:"
    for s in "${subjects[@]}"; do
      echo "  → ${s}"
    done
    log "Total: ${#subjects[@]} subjects (not migrated — dry run)"
    exit 0
  fi

  # ── Set IMPORT mode if requested ──────────────────────────────────────────
  [[ "${IMPORT_MODE}" == true ]] && set_mode "IMPORT"

  # ── Migrate each subject ──────────────────────────────────────────────────
  for subject in "${subjects[@]}"; do
    migrate_subject "${subject}" || true   # never let a single subject abort the loop
  done

  # ── Restore READWRITE mode ────────────────────────────────────────────────
  [[ "${IMPORT_MODE}" == true ]] && set_mode "READWRITE"

  log "================================================================"
  log " Done  ✓=${SUCCESS}  ✗=${FAIL}  –(skipped)=${SKIP}"
  log "================================================================"

  [[ "${FAIL}" -gt 0 ]] && exit 1 || exit 0
}

main
