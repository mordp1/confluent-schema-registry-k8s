#!/usr/bin/env bash
# =============================================================================
# Delete subjects from local Schema Registry — allows a clean re-migration.
#
# Two source modes:
#   Default     Fetch subject list from Confluent Cloud (same source as
#               migrate-from-cloud.sh) — deletes only what was migrated.
#   --from-local  Fetch subject list from the local SR itself — deletes
#               everything present locally, including subjects not in CC.
#               Use this when local SR has referencing schemas that prevent
#               deletion of CC subjects.
#
# Handles schema reference ordering automatically: subjects that fail with
# HTTP 422 (reference conflict) are retried after their dependents are gone.
#
# Usage:
#   export CONFLUENT_SR_URL="https://psrc-xxxxx.eu-central-1.aws.confluent.cloud"
#   export CONFLUENT_SR_API_KEY="your-api-key"
#   export CONFLUENT_SR_API_SECRET="your-api-secret"
#
#   # Delete only CC subjects (default)
#   ./delete-migrated.sh \
#     --local-sr-url http://localhost:18081 \
#     --local-user admin \
#     --local-password <pass> \
#     --permanent
#
#   # Delete ALL subjects from local SR (handles reference conflicts)
#   ./delete-migrated.sh \
#     --local-sr-url http://localhost:18081 \
#     --local-user admin \
#     --local-password <pass> \
#     --from-local --permanent
#
# Required environment variables (not needed with --from-local):
#   CONFLUENT_SR_URL        Confluent Cloud SR endpoint (no trailing slash)
#   CONFLUENT_SR_API_KEY    Confluent Cloud SR API key
#   CONFLUENT_SR_API_SECRET Confluent Cloud SR API secret
#
# Options:
#   --local-sr-url      Local Schema Registry URL (default: http://localhost:18081)
#   --local-user        Local SR basic auth username (default: admin)
#   --local-password    Local SR basic auth password (required unless --dry-run)
#   --from-local        Use local SR as the subject list source instead of CC
#   --subject-filter    Extended regex to filter subject names (grep -E)
#   --permanent         Hard delete (permanent=true) — removes schema IDs too
#   --dry-run           List subjects that would be deleted without touching local SR
#   --continue-on-error Do not abort on non-retryable failures
# =============================================================================
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
LOCAL_SR_URL="http://localhost:18081"
LOCAL_USER="admin"
LOCAL_PASS=""
SUBJECT_FILTER=""
PERMANENT=false
DRY_RUN=false
FROM_LOCAL=false
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
    --from-local)        FROM_LOCAL=true;         shift   ;;
    --continue-on-error) CONTINUE_ON_ERROR=true;  shift   ;;
    -h|--help)
      sed -n '/^# Usage:/,/^# ====/{s/^# //;p}' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1 (use --help)"; exit 1 ;;
  esac
done

# ── Validation ────────────────────────────────────────────────────────────────
if [[ "${FROM_LOCAL}" == false ]]; then
  : "${CONFLUENT_SR_URL:?ERROR: CONFLUENT_SR_URL env var must be set (or use --from-local)}"
  : "${CONFLUENT_SR_API_KEY:?ERROR: CONFLUENT_SR_API_KEY env var must be set (or use --from-local)}"
  : "${CONFLUENT_SR_API_SECRET:?ERROR: CONFLUENT_SR_API_SECRET env var must be set (or use --from-local)}"
fi

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

# ── URL-encode ────────────────────────────────────────────────────────────────
urlencode() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$1"
  else
    echo "$1" | sed 's/ /%20/g; s/#/%23/g; s/\[/%5B/g; s/\]/%5D/g'
  fi
}

# ── REST helpers ──────────────────────────────────────────────────────────────
cc_get() {
  curl -sf \
    -u "${CONFLUENT_SR_API_KEY}:${CONFLUENT_SR_API_SECRET}" \
    -H "Accept: application/vnd.schemaregistry.v1+json" \
    "${CONFLUENT_SR_URL}${1}"
}

local_get() {
  curl -sf \
    -u "${LOCAL_USER}:${LOCAL_PASS}" \
    -H "Accept: application/vnd.schemaregistry.v1+json" \
    "${LOCAL_SR_URL}${1}"
}

local_put() {
  curl -s -w "\n%{http_code}" \
    -u "${LOCAL_USER}:${LOCAL_PASS}" \
    -X PUT \
    -H "Content-Type: application/vnd.schemaregistry.v1+json" \
    -d "${2}" \
    "${LOCAL_SR_URL}${1}"
}

local_delete() {
  curl -s -w "\n%{http_code}" \
    -u "${LOCAL_USER}:${LOCAL_PASS}" \
    -X DELETE \
    -H "Accept: application/vnd.schemaregistry.v1+json" \
    "${LOCAL_SR_URL}${1}"
}

# ── Ensure READWRITE mode ─────────────────────────────────────────────────────
# IMPORT/READONLY mode (left over from an interrupted migration) blocks DELETE.
ensure_readwrite_mode() {
  local r current code
  r=$(curl -sf -u "${LOCAL_USER}:${LOCAL_PASS}" \
    -H "Accept: application/vnd.schemaregistry.v1+json" \
    "${LOCAL_SR_URL}/mode" 2>/dev/null || echo '{"mode":"UNKNOWN"}')
  current=$(echo "${r}" | jq -r '.mode // "UNKNOWN"')

  if [[ "${current}" == "READWRITE" ]]; then
    log "SR mode: READWRITE ✓"
    return
  fi

  log "SR mode is '${current}' — resetting to READWRITE"
  r=$(local_put "/mode" '{"mode":"READWRITE"}')
  code=$(echo "${r}" | tail -1)
  if [[ "${code}" == "200" ]]; then
    log "SR mode reset to READWRITE ✓"
  else
    log "WARNING: could not reset SR mode (HTTP ${code}) — deletes may fail"
  fi
}

# ── Try to delete one subject ─────────────────────────────────────────────────
# Return codes:
#   0  deleted successfully
#   1  not found / already absent (HTTP 404 on both passes)
#   2  reference conflict — retry later (HTTP 422)
#   3  unrecoverable error
#
# When --permanent is set, Schema Registry requires a two-step process:
#   1. Soft delete  → DELETE /subjects/{subject}
#   2. Hard delete  → DELETE /subjects/{subject}?permanent=true
# Calling ?permanent=true directly on an active subject returns 404 in
# most SR versions because it only looks for already-soft-deleted subjects.
try_delete() {
  local subject="$1"
  local encoded response http_code body msg

  encoded=$(urlencode "${subject}")

  # ── Step 1: soft delete (always required) ───────────────────────────────
  response=$(local_delete "/subjects/${encoded}")
  http_code=$(echo "${response}" | tail -1)
  body=$(echo "${response}" | sed '$d')

  case "${http_code}" in
    200) ;;   # soft-deleted — proceed to hard delete if --permanent
    404)
      # Already absent or already soft-deleted; still attempt hard delete
      # in case it was soft-deleted in a previous run.
      if [[ "${PERMANENT}" == false ]]; then
        skip "${subject}: not found in local SR (already absent)"
        return 1
      fi
      ;;
    422)
      msg=$(echo "${body}" | jq -r '.message // empty' 2>/dev/null || echo "${body}")
      printf '  ⟳  %s: reference conflict — will retry (%s)\n' "${subject}" "${msg}"
      return 2
      ;;
    *)
      msg=$(echo "${body}" | jq -r '.message // .error_code // empty' 2>/dev/null \
              || echo "${body}")
      err "${subject}: soft DELETE failed (HTTP ${http_code}) — ${msg}"
      return 3
      ;;
  esac

  # ── Step 2: hard delete (only when --permanent) ──────────────────────────
  if [[ "${PERMANENT}" == false ]]; then
    local versions
    versions=$(echo "${body}" | jq -r '[.[] | tostring] | join(",")' 2>/dev/null \
                 || echo "${body}")
    ok "${subject} soft-deleted (versions: ${versions})"
    return 0
  fi

  response=$(local_delete "/subjects/${encoded}?permanent=true")
  http_code=$(echo "${response}" | tail -1)
  body=$(echo "${response}" | sed '$d')

  case "${http_code}" in
    200)
      local versions
      versions=$(echo "${body}" | jq -r '[.[] | tostring] | join(",")' 2>/dev/null \
                   || echo "${body}")
      ok "${subject} permanently deleted (versions: ${versions})"
      return 0
      ;;
    404)
      # Soft-deleted with no versions left — already gone
      ok "${subject} permanently deleted (no versions remaining)"
      return 0
      ;;
    *)
      msg=$(echo "${body}" | jq -r '.message // .error_code // empty' 2>/dev/null \
              || echo "${body}")
      err "${subject}: hard DELETE failed (HTTP ${http_code}) — ${msg}"
      return 3
      ;;
  esac
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  local source_label delete_type
  source_label="${FROM_LOCAL:+local SR}"
  source_label="${source_label:-Confluent Cloud}"
  delete_type="soft delete"
  [[ "${PERMANENT}" == true ]] && delete_type="PERMANENT delete"

  log "================================================================"
  log " Delete Migrated Schemas"
  log " Source (list)    : ${source_label}"
  [[ "${FROM_LOCAL}" == false ]] && log " CC SR URL        : ${CONFLUENT_SR_URL}"
  log " Target SR URL    : ${LOCAL_SR_URL}"
  log " Delete type      : ${delete_type}"
  log " Dry run          : ${DRY_RUN}"
  [[ -n "${SUBJECT_FILTER}" ]] && log " Subject filter   : ${SUBJECT_FILTER}"
  log "================================================================"

  # ── Fetch subject list ────────────────────────────────────────────────────
  local all_subjects_json total
  if [[ "${FROM_LOCAL}" == true ]]; then
    log "Fetching subject list from local SR..."
    all_subjects_json=$(local_get "/subjects")
  else
    log "Fetching subject list from Confluent Cloud..."
    all_subjects_json=$(cc_get "/subjects")
  fi
  total=$(echo "${all_subjects_json}" | jq 'length')
  log "Found ${total} subject(s)"

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

  # ── Dry-run ───────────────────────────────────────────────────────────────
  if [[ "${DRY_RUN}" == true ]]; then
    log "DRY RUN — subjects that would be deleted:"
    for s in "${subjects[@]}"; do echo "  → ${s}"; done
    log "Total: ${#subjects[@]} subjects (not deleted — dry run)"
    exit 0
  fi

  ensure_readwrite_mode

  if [[ "${PERMANENT}" == true ]]; then
    echo ""
    echo "  WARNING: --permanent will hard-delete all versions and schema IDs."
    echo "  This cannot be undone. Type 'yes' to confirm:"
    read -r confirm
    if [[ "${confirm}" != "yes" ]]; then log "Aborted."; exit 1; fi
  fi

  # ── First pass ───────────────────────────────────────────────────────────
  local -a retry_queue=()
  local rc
  for subject in "${subjects[@]}"; do
    try_delete "${subject}" && rc=$? || rc=$?
    case "${rc}" in
      2) retry_queue+=("${subject}") ;;          # 422 reference conflict → retry
      3) [[ "${CONTINUE_ON_ERROR}" == false ]] && \
           { log "Aborting. Use --continue-on-error to skip errors."; exit 1; } ;;
    esac
  done

  # ── Retry pass (resolves reference ordering) ─────────────────────────────
  # After deleting referencing subjects, the referenced ones can now be deleted.
  if [[ ${#retry_queue[@]} -gt 0 ]]; then
    log "Retrying ${#retry_queue[@]} subject(s) with reference conflicts..."
    for subject in "${retry_queue[@]}"; do
      try_delete "${subject}" && rc=$? || rc=$?
      if [[ "${rc}" -eq 2 || "${rc}" -eq 3 ]]; then
        err "${subject}: still failed after retry"
        (( FAIL++ )) || true
        [[ "${CONTINUE_ON_ERROR}" == false ]] && \
          { log "Aborting. Use --continue-on-error to skip errors."; exit 1; }
      fi
    done
  fi

  log "================================================================"
  log " Done  ✓=${SUCCESS}  ✗=${FAIL}  –(skipped/absent)=${SKIP}"
  log "================================================================"

  [[ "${FAIL}" -gt 0 ]] && exit 1 || exit 0
}

main
