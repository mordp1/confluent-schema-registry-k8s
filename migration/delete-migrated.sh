#!/usr/bin/env bash
# =============================================================================
# Delete subjects from local Schema Registry that were migrated from
# Confluent Cloud — allows a clean re-migration.
#
# Fetches the subject list from Confluent Cloud (same source as
# migrate-from-cloud.sh) and deletes each matching subject from the local SR.
#
# Usage:
#   export CONFLUENT_SR_URL="https://psrc-xxxxx.us-east-2.aws.confluent.cloud"
#   export CONFLUENT_SR_API_KEY="your-api-key"
#   export CONFLUENT_SR_API_SECRET="your-api-secret"
#
#   ./delete-migrated.sh \
#     --local-sr-url  http://localhost:18081 \
#     --local-user    admin \
#     --local-password changeme-admin-password
#
#   # Delete only subjects matching a pattern (same filter as migration):
#   ./delete-migrated.sh --subject-filter "^orders-" ...
#
#   # Permanent hard delete (removes all versions and schema IDs):
#   ./delete-migrated.sh --permanent ...
#
#   # Dry run — list what would be deleted without touching the local SR:
#   ./delete-migrated.sh --dry-run
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
#   --permanent         Hard delete (permanent=true) — removes schema IDs too
#   --dry-run           List subjects that would be deleted without touching local SR
#   --continue-on-error Do not abort on first DELETE failure
# =============================================================================
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
LOCAL_SR_URL="http://localhost:18081"
LOCAL_USER="admin"
LOCAL_PASS=""
SUBJECT_FILTER=""
PERMANENT=false
DRY_RUN=false
CONTINUE_ON_ERROR=false

SUCCESS=0; FAIL=0; SKIP=0

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local-sr-url)      LOCAL_SR_URL="$2";       shift 2 ;;
    --local-user)        LOCAL_USER="$2";         shift 2 ;;
    --local-password)    LOCAL_PASS="$2";         shift 2 ;;
    --subject-filter)    SUBJECT_FILTER="$2";     shift 2 ;;
    --permanent)         PERMANENT=true;          shift   ;;
    --dry-run)           DRY_RUN=true;            shift   ;;
    --continue-on-error) CONTINUE_ON_ERROR=true;  shift   ;;
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

# ── Logging helpers ───────────────────────────────────────────────────────────
log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '  ✓  %s\n' "$1"; (( SUCCESS++ )) || true; }
err()  { printf '  ✗  %s\n' "$1"; (( FAIL++ )) || true; }
skip() { printf '  –  %s\n' "$1"; (( SKIP++ )) || true; }

# ── URL-encode (mirrors migrate-from-cloud.sh) ────────────────────────────────
urlencode() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$1"
  else
    echo "$1" | sed 's/ /%20/g; s/#/%23/g; s/\[/%5B/g; s/\]/%5D/g'
  fi
}

# ── Confluent Cloud REST helper ───────────────────────────────────────────────
cc_get() {
  local path="$1"
  curl -sf \
    -u "${CONFLUENT_SR_API_KEY}:${CONFLUENT_SR_API_SECRET}" \
    -H "Accept: application/vnd.schemaregistry.v1+json" \
    "${CONFLUENT_SR_URL}${path}"
}

# ── Local SR DELETE helper ────────────────────────────────────────────────────
local_delete() {
  local path="$1"
  curl -s -w "\n%{http_code}" \
    -u "${LOCAL_USER}:${LOCAL_PASS}" \
    -X DELETE \
    -H "Accept: application/vnd.schemaregistry.v1+json" \
    "${LOCAL_SR_URL}${path}"
}

# ── Delete one subject from local SR ─────────────────────────────────────────
delete_subject() {
  local subject="$1"
  local encoded
  encoded=$(urlencode "${subject}")

  local path="/subjects/${encoded}"
  [[ "${PERMANENT}" == true ]] && path="${path}?permanent=true"

  local response http_code body
  response=$(local_delete "${path}")
  http_code=$(echo "${response}" | tail -1)
  body=$(echo "${response}" | sed '$d')

  case "${http_code}" in
    200)
      local versions
      versions=$(echo "${body}" | jq -r 'if type=="array" then "versions: \(join(","))" else . end' 2>/dev/null || echo "${body}")
      ok "${subject} deleted (${versions})"
      ;;
    404)
      skip "${subject}: not found in local SR (already absent)"
      ;;
    *)
      local msg
      msg=$(echo "${body}" | jq -r '.message // .error_code // empty' 2>/dev/null || echo "${body}")
      err "${subject}: DELETE failed (HTTP ${http_code}) — ${msg}"
      if [[ "${CONTINUE_ON_ERROR}" == false ]]; then
        log "Aborting. Use --continue-on-error to proceed past failures."
        exit 1
      fi
      ;;
  esac
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  local delete_type="soft delete"
  [[ "${PERMANENT}" == true ]] && delete_type="PERMANENT delete"

  log "================================================================"
  log " Delete Migrated Schemas — Strategy B source"
  log " Source SR (list) : ${CONFLUENT_SR_URL}"
  log " Target SR URL    : ${LOCAL_SR_URL}"
  log " Delete type      : ${delete_type}"
  log " Dry run          : ${DRY_RUN}"
  [[ -n "${SUBJECT_FILTER}" ]] && log " Subject filter   : ${SUBJECT_FILTER}"
  log "================================================================"

  # ── Fetch subject list from Confluent Cloud ───────────────────────────────
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
    log "After filter '${SUBJECT_FILTER}': ${#subjects[@]} subject(s) to delete"
  else
    while IFS= read -r s; do subjects+=("$s"); done \
      < <(echo "${all_subjects_json}" | jq -r '.[]')
  fi

  if [[ ${#subjects[@]} -eq 0 ]]; then
    log "No subjects matched. Nothing to delete."
    exit 0
  fi

  # ── Dry-run: just list ────────────────────────────────────────────────────
  if [[ "${DRY_RUN}" == true ]]; then
    log "DRY RUN — subjects that would be deleted from local SR:"
    for s in "${subjects[@]}"; do
      echo "  → ${s}"
    done
    log "Total: ${#subjects[@]} subjects (not deleted — dry run)"
    exit 0
  fi

  # ── Confirmation prompt (non-permanent is reversible; permanent is not) ───
  if [[ "${PERMANENT}" == true ]]; then
    echo ""
    echo "  WARNING: --permanent will hard-delete all versions and schema IDs."
    echo "  This cannot be undone. Type 'yes' to confirm:"
    read -r confirm
    if [[ "${confirm}" != "yes" ]]; then
      log "Aborted."
      exit 1
    fi
  fi

  # ── Delete each subject ───────────────────────────────────────────────────
  for subject in "${subjects[@]}"; do
    delete_subject "${subject}"
  done

  log "================================================================"
  log " Done  ✓=${SUCCESS}  ✗=${FAIL}  –(skipped/absent)=${SKIP}"
  log "================================================================"

  [[ "${FAIL}" -gt 0 ]] && exit 1 || exit 0
}

main
