#!/usr/bin/env bash
# =============================================================================
# Strategy A — File-based schema import
#
# Reads Confluent Cloud schema export JSON files and imports them into a local
# (or target) Schema Registry instance via REST API.
#
# Expected input file format (standard Confluent Cloud export):
#   {
#     "subject":    "orders-value",
#     "version":    3,
#     "id":         100042,
#     "schemaType": "AVRO",     ← optional; defaults to AVRO if absent
#     "schema":     "{...}",    ← JSON-escaped Avro/JSON/Protobuf schema string
#     "references": []          ← optional; needed for cross-subject references
#   }
#
# One file per subject, or one file per subject+version — both supported.
#
# Usage:
#   ./import-schemas.sh --dir ./schemas \
#                       --sr-url http://localhost:18081 \
#                       --user admin \
#                       --password changeme-admin-password
#
#   ./import-schemas.sh --dir ./schemas --dry-run
#
#   ./import-schemas.sh --dir ./schemas --filter "^orders-" \
#                       --sr-url http://localhost:18081 \
#                       --user admin --password <pass>
#
# Options:
#   --dir            Directory containing .json export files (required)
#   --sr-url         Schema Registry base URL (default: http://localhost:18081)
#   --user           Basic auth username (default: admin)
#   --password       Basic auth password (required unless --dry-run)
#   --dry-run        Parse and validate files without POSTing to SR
#   --subject        Import only this exact subject name
#   --filter         Import subjects matching this extended regex (grep -E)
#   --import-mode    Switch local SR to IMPORT mode before import (preserves
#                    original schema IDs from Confluent Cloud). IMPORTANT: this
#                    requires the local SR to support IMPORT mode (Community
#                    Edition does support it as of CP 6.0+). The mode is
#                    restored to READWRITE automatically after import.
#   --continue-on-error  Do not abort on first POST failure (default: fail fast)
# =============================================================================
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
SR_URL="http://localhost:18081"
SR_USER="admin"
SR_PASS=""
SCHEMA_DIR=""
DRY_RUN=false
SUBJECT_FILTER=""
SPECIFIC_SUBJECT=""
IMPORT_MODE=false
CONTINUE_ON_ERROR=false

SUCCESS=0; FAIL=0; SKIP=0

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)              SCHEMA_DIR="$2";       shift 2 ;;
    --sr-url)           SR_URL="$2";           shift 2 ;;
    --user)             SR_USER="$2";          shift 2 ;;
    --password)         SR_PASS="$2";          shift 2 ;;
    --dry-run)          DRY_RUN=true;          shift   ;;
    --subject)          SPECIFIC_SUBJECT="$2"; shift 2 ;;
    --filter)           SUBJECT_FILTER="$2";   shift 2 ;;
    --import-mode)      IMPORT_MODE=true;      shift   ;;
    --continue-on-error) CONTINUE_ON_ERROR=true; shift ;;
    -h|--help)
      sed -n '/^# Usage:/,/^# =====/{s/^# //;p}' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1 (use --help for usage)"; exit 1 ;;
  esac
done

# ── Validation ────────────────────────────────────────────────────────────────
[[ -z "${SCHEMA_DIR}" ]]  && { echo "ERROR: --dir is required"; exit 1; }
[[ ! -d "${SCHEMA_DIR}" ]] && { echo "ERROR: directory not found: ${SCHEMA_DIR}"; exit 1; }
if [[ "${DRY_RUN}" == false && -z "${SR_PASS}" ]]; then
  echo "ERROR: --password is required (or use --dry-run to skip POST)"
  exit 1
fi
command -v jq   >/dev/null 2>&1 || { echo "ERROR: jq required (brew install jq)"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl required"; exit 1; }

# ── Logging helpers ───────────────────────────────────────────────────────────
log()  { printf '[%s] %s\n'    "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '  ✓  %s\n'   "$1"; (( SUCCESS++ )) || true; }
err()  { printf '  ✗  %s\n'   "$1"; (( FAIL++ )) || true; }
skip() { printf '  –  %s\n'   "$1"; (( SKIP++ )) || true; }

# ── SR mode management ────────────────────────────────────────────────────────
# IMPORT mode: Schema Registry accepts schemas with an explicit ID field,
# allowing you to preserve the original IDs from Confluent Cloud. This is
# important when consumers / producers reference schemas by numeric ID rather
# than subject+version — a mismatch would cause deserialization failures.
#
# Community edition caveat: IMPORT mode is available in CP Community Edition
# but the schema IDs from Confluent Cloud may conflict with IDs already used
# locally if you registered any schemas before the migration. Start with a
# clean registry for a clean import, or resolve ID conflicts first.

set_mode() {
  local mode="$1"
  [[ "${DRY_RUN}" == true ]] && return
  log "Setting Schema Registry mode → ${mode}"
  local response code
  response=$(curl -s -w "\n%{http_code}" \
    -u "${SR_USER}:${SR_PASS}" \
    -X PUT \
    -H "Content-Type: application/vnd.schemaregistry.v1+json" \
    -d "{\"mode\":\"${mode}\"}" \
    "${SR_URL}/mode")
  code=$(echo "${response}" | tail -1)
  [[ "${code}" != "200" ]] && log "  WARNING: failed to set mode (HTTP ${code}) — continuing"
}

# ── Process a single export file ──────────────────────────────────────────────
process_file() {
  local filepath="$1"
  local filename
  filename=$(basename "${filepath}")

  # ── Validate required fields ──────────────────────────────────────────────
  local missing
  if ! missing=$(jq -re '
    if (.subject == null or .subject == "") then "subject"
    elif (.schema == null or .schema == "") then "schema"
    else "" end' "${filepath}" 2>/dev/null); then
    err "${filename}: jq parse failed — not valid JSON"
    return
  fi
  if [[ -n "${missing}" ]]; then
    err "${filename}: missing required field '${missing}'"
    return
  fi

  local subject schema schema_type references
  subject=$(jq -r '.subject'         "${filepath}")
  schema=$(jq -r '.schema'           "${filepath}")
  # Default to AVRO when schemaType is absent (matches Confluent Cloud export behaviour)
  schema_type=$(jq -r '.schemaType // "AVRO"' "${filepath}")
  references=$(jq -c '.references // []'       "${filepath}")

  # ── Apply subject filters ─────────────────────────────────────────────────
  if [[ -n "${SPECIFIC_SUBJECT}" && "${subject}" != "${SPECIFIC_SUBJECT}" ]]; then
    skip "${subject}: skipped (not matching --subject filter)"
    return
  fi
  if [[ -n "${SUBJECT_FILTER}" ]] && ! echo "${subject}" | grep -qE "${SUBJECT_FILTER}"; then
    skip "${subject}: skipped (does not match --filter '${SUBJECT_FILTER}')"
    return
  fi

  # ── Dry-run path ──────────────────────────────────────────────────────────
  if [[ "${DRY_RUN}" == true ]]; then
    # Verify the 'schema' value is itself valid JSON
    if echo "${schema}" | jq . >/dev/null 2>&1; then
      ok "${subject} (${schema_type}): valid — would POST to ${SR_URL}/subjects/${subject}/versions"
    else
      err "${subject}: 'schema' field is not valid JSON — check escaping in export file"
    fi
    return
  fi

  # ── Build POST payload ────────────────────────────────────────────────────
  # The /versions endpoint payload format:
  #   { "schemaType": "AVRO|JSON|PROTOBUF", "schema": "<escaped-string>", "references": [...] }
  # The 'schema' value is already a JSON-escaped string in Confluent exports.
  # Using jq --arg ensures correct re-escaping if the value came from a nested object.
  local payload
  payload=$(jq -n \
    --arg   st   "${schema_type}" \
    --arg   sc   "${schema}" \
    --argjson refs "${references}" \
    '{schemaType: $st, schema: $sc, references: $refs}')

  # ── POST to Schema Registry ───────────────────────────────────────────────
  local response http_code body
  response=$(curl -s -w "\n%{http_code}" \
    -u "${SR_USER}:${SR_PASS}" \
    -X POST \
    -H "Content-Type: application/vnd.schemaregistry.v1+json" \
    -d "${payload}" \
    "${SR_URL}/subjects/${subject}/versions")

  http_code=$(echo "${response}" | tail -1)
  body=$(echo "${response}" | sed '$d')

  case "${http_code}" in
    200)
      local id
      id=$(echo "${body}" | jq -r '.id // "?"')
      ok "${subject} (${schema_type}): registered → id=${id}"
      ;;
    409)
      # 409 Conflict = schema already registered (idempotent — treat as success)
      local id
      id=$(echo "${body}" | jq -r '.id // "?"')
      ok "${subject} (${schema_type}): already exists → id=${id} (idempotent)"
      ;;
    *)
      local msg
      msg=$(echo "${body}" | jq -r '.message // .error_code // empty' 2>/dev/null || echo "${body}")
      err "${subject}: POST failed (HTTP ${http_code}) — ${msg}"
      if [[ "${CONTINUE_ON_ERROR}" == false ]]; then
        log "Aborting on first failure. Use --continue-on-error to skip failed subjects."
        set_mode "READWRITE"
        exit 1
      fi
      ;;
  esac
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  log "================================================================"
  log " Schema Import — Strategy A (file-based)"
  log " Source dir    : ${SCHEMA_DIR}"
  log " Target SR URL : ${SR_URL}"
  log " Dry run       : ${DRY_RUN}"
  log " Import mode   : ${IMPORT_MODE}"
  [[ -n "${SUBJECT_FILTER}" ]]   && log " Subject filter : ${SUBJECT_FILTER}"
  [[ -n "${SPECIFIC_SUBJECT}" ]] && log " Subject exact  : ${SPECIFIC_SUBJECT}"
  log "================================================================"

  # Collect files sorted by name (consistent ordering for reproducibility)
  local files=()
  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(find "${SCHEMA_DIR}" -maxdepth 3 -name "*.json" -print0 | sort -z)

  if [[ ${#files[@]} -eq 0 ]]; then
    log "ERROR: no .json files found under ${SCHEMA_DIR}"
    exit 1
  fi
  log "Found ${#files[@]} .json file(s)"

  [[ "${IMPORT_MODE}" == true ]] && set_mode "IMPORT"

  for f in "${files[@]}"; do
    process_file "${f}"
  done

  [[ "${IMPORT_MODE}" == true ]] && set_mode "READWRITE"

  log "================================================================"
  log " Done  ✓=${SUCCESS}  ✗=${FAIL}  –(skipped)=${SKIP}"
  log "================================================================"

  [[ "${FAIL}" -gt 0 ]] && exit 1 || exit 0
}

main
