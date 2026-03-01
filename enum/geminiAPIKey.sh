#!/usr/bin/env bash
set -u -o pipefail

BASE_URL="https://generativelanguage.googleapis.com"
API_KEY="${GEMINI_API_KEY:-}"
UPLOAD_PATH=""
DETAIL_LIMIT=3
declare -a INTERACTION_IDS=()

# ---------- styling ----------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
else
  C_RESET=""
  C_BOLD=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
fi

section() { printf "\n%s%s%s\n" "$C_BOLD" "$1" "$C_RESET"; }
ok()      { printf "%s[OK]%s %s\n"   "$C_GREEN" "$C_RESET" "$*"; }
warn()    { printf "%s[WARN]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
fail()    { printf "%s[FAIL]%s %s\n" "$C_RED" "$C_RESET" "$*"; }
info()    { printf "%s[INFO]%s %s\n" "$C_BLUE" "$C_RESET" "$*"; }

usage() {
  cat <<'EOF'
Usage:
  gemini_enum.sh [-k API_KEY] [-u /path/to/file] [-n DETAIL_LIMIT] [-i INTERACTION_ID ...]

Optionen:
  -k API_KEY          Gemini API Key (alternativ via Env: GEMINI_API_KEY)
  -u FILE             Datei hochladen (optional)
  -n DETAIL_LIMIT     Wie viele Detail-GETs pro Sammlung (Default: 3)
  -i INTERACTION_ID   Gespeicherte Interaction-ID abrufen (mehrfach nutzbar)
  -h                  Hilfe

Beispiele:
  export GEMINI_API_KEY="..."
  ./gemini_enum.sh
  ./gemini_enum.sh -u ./test.pdf
  ./gemini_enum.sh -i v1_abc123 -i v1_def456
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    fail "Benötigtes Kommando fehlt: $1"
    exit 1
  }
}

is_success() {
  [[ "${1:-}" =~ ^2[0-9][0-9]$ ]]
}

tmpfiles=()
cleanup() {
  local f
  for f in "${tmpfiles[@]:-}"; do
    [[ -n "$f" && -e "$f" ]] && rm -f "$f"
  done
}
trap cleanup EXIT

new_tmp() {
  local f
  f="$(mktemp)"
  tmpfiles+=("$f")
  printf '%s' "$f"
}

LAST_BODY=""
LAST_STATUS=""
LAST_URL=""

http_get() {
  local path="$1"
  local query="${2:-}"
  LAST_BODY="$(new_tmp)"
  LAST_URL="${BASE_URL}${path}"
  [[ -n "$query" ]] && LAST_URL="${LAST_URL}?${query}"

  LAST_STATUS="$(curl -sS \
    -H "x-goog-api-key: ${API_KEY}" \
    -o "$LAST_BODY" \
    -w "%{http_code}" \
    "$LAST_URL" || true)"
}

http_get_full_url() {
  local url="$1"
  LAST_BODY="$(new_tmp)"
  LAST_URL="$url"

  LAST_STATUS="$(curl -sS \
    -H "x-goog-api-key: ${API_KEY}" \
    -o "$LAST_BODY" \
    -w "%{http_code}" \
    "$LAST_URL" || true)"
}

error_message() {
  jq -r '.error.message // .message // empty' "$LAST_BODY" 2>/dev/null || true
}

show_json_head() {
  local filter="${1:-.}"
  if jq -e . >/dev/null 2>&1 <"$LAST_BODY"; then
    jq "$filter" "$LAST_BODY" 2>/dev/null | sed -n '1,20p'
  else
    sed -n '1,20p' "$LAST_BODY"
  fi
}

show_error_body() {
  local msg
  msg="$(error_message)"
  if [[ -n "$msg" ]]; then
    printf "  %s\n" "$msg"
  else
    show_json_head '.'
  fi
}

detail_resource() {
  local resource_name="$1"   # e.g. files/abc , models/gemini-2.5-flash
  local extra_query="${2:-}" # e.g. include_input=true

  http_get "/v1beta/${resource_name}" "$extra_query"

  if is_success "$LAST_STATUS"; then
    ok "GET ${LAST_URL} -> HTTP ${LAST_STATUS}"
    show_json_head 'if type=="object" then with_entries(select(.value != null)) else . end'
  else
    fail "GET ${LAST_URL} -> HTTP ${LAST_STATUS}"
    show_error_body
  fi
}

probe_collection() {
  local title="$1"
  local path="$2"
  local query="$3"
  local list_filter="$4"
  local names_filter="$5"

  section "=== ${title} ==="
  http_get "$path" "$query"

  if is_success "$LAST_STATUS"; then
    local count
    count="$(jq -r "${list_filter} | length" "$LAST_BODY" 2>/dev/null || echo "?")"
    ok "GET ${LAST_URL} -> HTTP ${LAST_STATUS} (${count} Einträge)"

    local names_tmp
    names_tmp="$(new_tmp)"
    jq -r "$names_filter" "$LAST_BODY" 2>/dev/null | sed '/^$/d' > "$names_tmp" || true

    if [[ -s "$names_tmp" ]]; then
      info "Erste Namen:"
      sed -n "1,${DETAIL_LIMIT}p" "$names_tmp" | nl -w2 -s'. '
      echo
      info "Detail-Checks (max ${DETAIL_LIMIT}):"
      while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        detail_resource "$name"
        echo
      done < <(sed -n "1,${DETAIL_LIMIT}p" "$names_tmp")
    else
      warn "Keine Namen extrahierbar – Raw Preview:"
      show_json_head '.'
    fi
  else
    fail "GET ${LAST_URL} -> HTTP ${LAST_STATUS}"
    show_error_body
  fi
}

probe_file_search_documents() {
  local store_name="$1" # fileSearchStores/xyz

  section "--- Dokumente in ${store_name} ---"
  http_get "/v1beta/${store_name}/documents" "pageSize=100"

  if is_success "$LAST_STATUS"; then
    local count
    count="$(jq -r '(.documents // []) | length' "$LAST_BODY" 2>/dev/null || echo "?")"
    ok "GET ${LAST_URL} -> HTTP ${LAST_STATUS} (${count} Dokumente)"

    local docs_tmp
    docs_tmp="$(new_tmp)"
    jq -r '.documents[]?.name' "$LAST_BODY" 2>/dev/null | sed '/^$/d' > "$docs_tmp" || true

    if [[ -s "$docs_tmp" ]]; then
      sed -n "1,${DETAIL_LIMIT}p" "$docs_tmp" | nl -w2 -s'. '
      echo
      while IFS= read -r doc_name; do
        [[ -z "$doc_name" ]] && continue
        detail_resource "$doc_name"
        echo
      done < <(sed -n "1,${DETAIL_LIMIT}p" "$docs_tmp")
    fi
  else
    fail "GET ${LAST_URL} -> HTTP ${LAST_STATUS}"
    show_error_body
  fi
}

probe_interactions() {
  if [[ "${#INTERACTION_IDS[@]}" -eq 0 ]]; then
    section "=== Interactions ==="
    warn "Keine Interaction-IDs angegeben -> übersprungen"
    warn "Hinweis: Interactions sind per GET nur per bekannter ID abrufbar."
    return
  fi

  section "=== Interactions (bekannte IDs) ==="
  local id
  for id in "${INTERACTION_IDS[@]}"; do
    http_get "/v1beta/interactions/${id}" "include_input=true"
    if is_success "$LAST_STATUS"; then
      ok "GET ${LAST_URL} -> HTTP ${LAST_STATUS}"
      show_json_head 'if type=="object" then with_entries(select(.value != null)) else . end'
    else
      fail "GET ${LAST_URL} -> HTTP ${LAST_STATUS}"
      show_error_body
    fi
    echo
  done
}

upload_file() {
  local path="$1"

  section "=== Upload ==="

  if [[ ! -f "$path" ]]; then
    fail "Datei nicht gefunden: $path"
    return 1
  fi

  local mime_type
  if command -v file >/dev/null 2>&1; then
    mime_type="$(file -b --mime-type -- "$path" 2>/dev/null || true)"
  fi
  [[ -z "${mime_type:-}" ]] && mime_type="application/octet-stream"

  local num_bytes
  num_bytes="$(wc -c < "$path" | tr -d ' ')"
  local display_name
  display_name="$(basename -- "$path")"

  info "Datei: $path"
  info "MIME:  $mime_type"
  info "Bytes: $num_bytes"

  local start_headers start_body upload_body
  start_headers="$(new_tmp)"
  start_body="$(new_tmp)"
  upload_body="$(new_tmp)"

  local metadata
  metadata="$(jq -nc --arg dn "$display_name" '{file:{display_name:$dn}}')"

  local start_status
  start_status="$(curl -sS \
    -D "$start_headers" \
    -o "$start_body" \
    -w "%{http_code}" \
    -H "x-goog-api-key: ${API_KEY}" \
    -H "X-Goog-Upload-Protocol: resumable" \
    -H "X-Goog-Upload-Command: start" \
    -H "X-Goog-Upload-Header-Content-Length: ${num_bytes}" \
    -H "X-Goog-Upload-Header-Content-Type: ${mime_type}" \
    -H "Content-Type: application/json" \
    -d "$metadata" \
    "${BASE_URL}/upload/v1beta/files" || true)"

  if ! is_success "$start_status"; then
    fail "Upload-Start fehlgeschlagen -> HTTP ${start_status}"
    if jq -e . >/dev/null 2>&1 <"$start_body"; then
      jq '.' "$start_body" | sed -n '1,20p'
    else
      sed -n '1,20p' "$start_body"
    fi
    return 1
  fi

  local upload_url
  upload_url="$(
    awk 'BEGIN{IGNORECASE=1} /^x-goog-upload-url:/ {sub(/\r$/,"",$2); print $2}' "$start_headers" | tail -n1
  )"

  if [[ -z "$upload_url" ]]; then
    fail "Konnte x-goog-upload-url nicht auslesen."
    sed -n '1,20p' "$start_headers"
    return 1
  fi

  local finish_status
  finish_status="$(curl -sS \
    -o "$upload_body" \
    -w "%{http_code}" \
    -H "Content-Length: ${num_bytes}" \
    -H "X-Goog-Upload-Offset: 0" \
    -H "X-Goog-Upload-Command: upload, finalize" \
    --data-binary "@${path}" \
    "$upload_url" || true)"

  if ! is_success "$finish_status"; then
    fail "Upload-Finalisierung fehlgeschlagen -> HTTP ${finish_status}"
    if jq -e . >/dev/null 2>&1 <"$upload_body"; then
      jq '.' "$upload_body" | sed -n '1,20p'
    else
      sed -n '1,20p' "$upload_body"
    fi
    return 1
  fi

  ok "Upload erfolgreich -> HTTP ${finish_status}"
  jq '{file: {name: .file.name, uri: .file.uri, mimeType: .file.mimeType, state: .file.state, sizeBytes: .file.sizeBytes}}' "$upload_body" 2>/dev/null \
    | sed -n '1,20p'

  local uploaded_name
  uploaded_name="$(jq -r '.file.name // empty' "$upload_body" 2>/dev/null || true)"
  if [[ -n "$uploaded_name" ]]; then
    echo
    info "Detail-GET für hochgeladene Datei:"
    detail_resource "$uploaded_name"
  fi
}

# ---------- args ----------
while getopts ":k:u:n:i:h" opt; do
  case "$opt" in
    k) API_KEY="$OPTARG" ;;
    u) UPLOAD_PATH="$OPTARG" ;;
    n) DETAIL_LIMIT="$OPTARG" ;;
    i) INTERACTION_IDS+=("$OPTARG") ;;
    h)
      usage
      exit 0
      ;;
    :)
      fail "Option -$OPTARG benötigt ein Argument"
      usage
      exit 1
      ;;
    \?)
      fail "Unbekannte Option: -$OPTARG"
      usage
      exit 1
      ;;
  esac
done

# ---------- checks ----------
need_cmd curl
need_cmd jq

if [[ -z "$API_KEY" ]]; then
  fail "Kein API Key gesetzt. Nutze -k oder export GEMINI_API_KEY=..."
  exit 1
fi

section "Gemini API GET Enumerator"
info "Base URL:     $BASE_URL"
info "Detail-Limit: $DETAIL_LIMIT"
[[ -n "$UPLOAD_PATH" ]] && info "Upload:       $UPLOAD_PATH"
[[ "${#INTERACTION_IDS[@]}" -gt 0 ]] && info "Interactions: ${#INTERACTION_IDS[@]} ID(s)"

# ---------- probes ----------
probe_collection \
  "Models" \
  "/v1beta/models" \
  "pageSize=100" \
  '(.models // [])' \
  '.models[]?.name'

probe_collection \
  "Files" \
  "/v1beta/files" \
  "pageSize=100" \
  '(.files // [])' \
  '.files[]?.name'

probe_collection \
  "Cached Contents" \
  "/v1beta/cachedContents" \
  "pageSize=100" \
  '(.cachedContents // [])' \
  '.cachedContents[]?.name'

probe_collection \
  "Tuned Models" \
  "/v1beta/tunedModels" \
  "pageSize=100" \
  '(.tunedModels // [])' \
  '.tunedModels[]?.name'

section "=== File Search Stores ==="
http_get "/v1beta/fileSearchStores" "pageSize=100"
if is_success "$LAST_STATUS"; then
  store_count="$(jq -r '(.fileSearchStores // []) | length' "$LAST_BODY" 2>/dev/null || echo "?")"
  ok "GET ${LAST_URL} -> HTTP ${LAST_STATUS} (${store_count} Stores)"

  stores_tmp="$(new_tmp)"
  jq -r '.fileSearchStores[]?.name' "$LAST_BODY" 2>/dev/null | sed '/^$/d' > "$stores_tmp" || true

  if [[ -s "$stores_tmp" ]]; then
    sed -n "1,${DETAIL_LIMIT}p" "$stores_tmp" | nl -w2 -s'. '
    echo
    while IFS= read -r store_name; do
      [[ -z "$store_name" ]] && continue
      detail_resource "$store_name"
      echo
      probe_file_search_documents "$store_name"
      echo
    done < <(sed -n "1,${DETAIL_LIMIT}p" "$stores_tmp")
  else
    warn "Keine Stores gefunden."
  fi
else
  fail "GET ${LAST_URL} -> HTTP ${LAST_STATUS}"
  show_error_body
fi

probe_collection \
  "Batches" \
  "/v1beta/batches" \
  "pageSize=100" \
  '(.batches // .operations // [])' \
  '(.batches // .operations // [])[]?.name'

probe_interactions

if [[ -n "$UPLOAD_PATH" ]]; then
  upload_file "$UPLOAD_PATH"
fi

section "Fertig"
ok "Enumeration abgeschlossen."
