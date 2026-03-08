#!/usr/bin/env bash
set -euo pipefail

# Algolia data overview via REST API.
# Requirements: bash, curl, jq
#
# Usage:
#   export ALGOLIA_APP_ID="YOUR_APP_ID"
#   export ALGOLIA_ADMIN_KEY="YOUR_ADMIN_KEY"
#   ./algolia_overview.sh
#
# Optional flags:
#   --output FILE             JSON report output file (default: algolia-overview-<timestamp>.json)
#   --sample-records N        Fetch up to N sample records per index via /browse (default: 0)
#   --include-logs            Include the latest logs (default: off)
#   --log-length N            Number of log entries to fetch (default: 25)
#   --include-api-keys        Include API key metadata with masked values (default: off)
#   --page-size N             Indices fetched per page from /1/indexes (default: 100)
#   --host HOST               Override API host (default: https://<APP_ID>.algolia.net)
#   --help                    Show this help

SAMPLE_RECORDS=0
INCLUDE_LOGS=0
LOG_LENGTH=25
INCLUDE_API_KEYS=0
PAGE_SIZE=100
OUTPUT_FILE=""
HOST=""

usage() {
  cat <<'USAGE'
Algolia data overview via REST API.
Requirements: bash, curl, jq

Usage:
  export ALGOLIA_APP_ID="YOUR_APP_ID"
  export ALGOLIA_ADMIN_KEY="YOUR_ADMIN_KEY"
  ./algolia_overview.sh

Optional flags:
  --output FILE             JSON report output file (default: algolia-overview-<timestamp>.json)
  --sample-records N        Fetch up to N sample records per index via /browse (default: 0)
  --include-logs            Include the latest logs (default: off)
  --log-length N            Number of log entries to fetch (default: 25)
  --include-api-keys        Include API key metadata with masked values (default: off)
  --page-size N             Indices fetched per page from /1/indexes (default: 100)
  --host HOST               Override API host (default: https://<APP_ID>.algolia.net)
  --help                    Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT_FILE="${2:?Missing value for --output}"
      shift 2
      ;;
    --sample-records)
      SAMPLE_RECORDS="${2:?Missing value for --sample-records}"
      shift 2
      ;;
    --include-logs)
      INCLUDE_LOGS=1
      shift
      ;;
    --log-length)
      LOG_LENGTH="${2:?Missing value for --log-length}"
      shift 2
      ;;
    --include-api-keys)
      INCLUDE_API_KEYS=1
      shift
      ;;
    --page-size)
      PAGE_SIZE="${2:?Missing value for --page-size}"
      shift 2
      ;;
    --host)
      HOST="${2:?Missing value for --host}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_cmd curl
require_cmd jq

: "${ALGOLIA_APP_ID:?Set ALGOLIA_APP_ID in your environment}"
: "${ALGOLIA_ADMIN_KEY:?Set ALGOLIA_ADMIN_KEY in your environment}"

if [[ -z "$HOST" ]]; then
  HOST="https://${ALGOLIA_APP_ID}.algolia.net"
fi

if [[ -z "$OUTPUT_FILE" ]]; then
  OUTPUT_FILE="algolia-overview-$(date +%Y%m%d-%H%M%S).json"
fi

die() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARN: $*" >&2
}

urlencode() {
  jq -rn --arg v "$1" '$v|@uri'
}

api_request() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local tmp_body tmp_code http_code

  tmp_body="$(mktemp)"
  tmp_code="$(mktemp)"

  if [[ -n "$body" ]]; then
    curl --silent --show-error \
      --request "$method" \
      --url "${HOST}${path}" \
      --header 'accept: application/json' \
      --header 'content-type: application/json' \
      --header "x-algolia-application-id: ${ALGOLIA_APP_ID}" \
      --header "x-algolia-api-key: ${ALGOLIA_ADMIN_KEY}" \
      --data "$body" \
      --output "$tmp_body" \
      --write-out '%{http_code}' > "$tmp_code"
  else
    curl --silent --show-error \
      --request "$method" \
      --url "${HOST}${path}" \
      --header 'accept: application/json' \
      --header "x-algolia-application-id: ${ALGOLIA_APP_ID}" \
      --header "x-algolia-api-key: ${ALGOLIA_ADMIN_KEY}" \
      --output "$tmp_body" \
      --write-out '%{http_code}' > "$tmp_code"
  fi

  http_code="$(cat "$tmp_code")"
  rm -f "$tmp_code"

  if [[ ! "$http_code" =~ ^2 ]]; then
    echo "--- ${method} ${path} failed with HTTP ${http_code} ---" >&2
    cat "$tmp_body" >&2 || true
    rm -f "$tmp_body"
    return 1
  fi

  cat "$tmp_body"
  rm -f "$tmp_body"
}

mask_key() {
  local key="$1"
  local len=${#key}
  if (( len <= 8 )); then
    printf '%s' '***'
  else
    printf '%s...%s' "${key:0:4}" "${key: -4}"
  fi
}

fetch_all_indices() {
  local page=0
  local nb_pages=1
  local first=1
  local all='[]'
  local resp items

  while (( page < nb_pages )); do
    resp="$(api_request GET "/1/indexes?page=${page}&hitsPerPage=${PAGE_SIZE}")" || die "Could not fetch indices page ${page}."
    items="$(jq '.items // []' <<<"$resp")"
    all="$(jq -cn --argjson a "$all" --argjson b "$items" '$a + $b')"
    nb_pages="$(jq -r '.nbPages // 1' <<<"$resp")"
    ((page+=1))
  done

  printf '%s' "$all"
}

extract_sample_metadata() {
  local index_name="$1"
  local encoded_index body resp
  encoded_index="$(urlencode "$index_name")"
  body="$(jq -cn --argjson n "$SAMPLE_RECORDS" '{hitsPerPage: $n}')"

  resp="$(api_request POST "/1/indexes/${encoded_index}/browse" "$body")" || {
    warn "Could not fetch sample records for index '${index_name}'."
    printf '%s' '{"sampleRecordCount":0,"sampleObjectIDs":[],"sampleFieldUnion":[]}'
    return 0
  }

  jq '{
      sampleRecordCount: ((.hits // []) | length),
      sampleObjectIDs: ((.hits // []) | map(.objectID) | map(select(. != null))),
      sampleFieldUnion: ((.hits // []) | map(keys_unsorted) | flatten | unique | sort)
    }' <<<"$resp"
}

fetch_index_settings_summary() {
  local index_name="$1"
  local encoded_index resp
  encoded_index="$(urlencode "$index_name")"

  resp="$(api_request GET "/1/indexes/${encoded_index}/settings")" || {
    warn "Could not fetch settings for index '${index_name}'."
    printf '%s' '{"_settingsFetchError":true}'
    return 0
  }

  jq '{
      searchableAttributes,
      attributesForFaceting,
      attributesToRetrieve,
      customRanking,
      ranking,
      replicas,
      primary,
      attributeForDistinct,
      distinct,
      queryLanguages,
      indexLanguages,
      paginationLimitedTo,
      hitsPerPage,
      unretrievableAttributes,
      disableTypoToleranceOnAttributes,
      numericAttributesForFiltering,
      userData,
      responseFields,
      maxValuesPerFacet,
      enableRules,
      enablePersonalization,
      mode
    }' <<<"$resp"
}

fetch_logs() {
  api_request GET "/1/logs?offset=0&length=${LOG_LENGTH}&type=all" || {
    warn "Could not fetch logs. Missing ACL 'logs' or request failed."
    printf '%s' '{"logsFetchError":true}'
  }
}

fetch_api_keys() {
  local resp
  resp="$(api_request GET "/1/keys")" || {
    warn "Could not fetch API keys. Missing required permission or request failed."
    printf '%s' '{"apiKeysFetchError":true}'
    return 0
  }

  jq '(.keys // [])
      | map({
          valueMasked: (.value[0:4] + "..." + .value[-4:]),
          createdAt,
          acl,
          description,
          indexes,
          maxHitsPerQuery,
          maxQueriesPerIPPerHour,
          queryParameters,
          referers,
          validity
        })' <<<"$resp"
}

main() {
  local started_at indices_count total_entries total_data_size total_file_size
  local indices_raw index_names overview_indices logs_json api_keys_json tmpfile

  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  indices_raw="$(fetch_all_indices)"

  indices_count="$(jq 'length' <<<"$indices_raw")"
  total_entries="$(jq '[.[].entries // 0] | add // 0' <<<"$indices_raw")"
  total_data_size="$(jq '[.[].dataSize // 0] | add // 0' <<<"$indices_raw")"
  total_file_size="$(jq '[.[].fileSize // 0] | add // 0' <<<"$indices_raw")"

  tmpfile="$(mktemp)"
  printf '[]' > "$tmpfile"

  while IFS= read -r index_name; do
    [[ -z "$index_name" ]] && continue

    settings_json="$(fetch_index_settings_summary "$index_name")"
    if (( SAMPLE_RECORDS > 0 )); then
      sample_json="$(extract_sample_metadata "$index_name")"
    else
      sample_json='{}'
    fi

    base_json="$(jq -c --arg name "$index_name" '.[] | select(.name == $name)' <<<"$indices_raw")"

    merged_json="$(jq -cn \
      --argjson base "$base_json" \
      --argjson settings "$settings_json" \
      --argjson sample "$sample_json" \
      '$base + {settingsSummary: $settings} + $sample')"

    jq -cn --slurpfile arr "$tmpfile" --argjson item "$merged_json" '$arr[0] + [$item]' > "${tmpfile}.new"
    mv "${tmpfile}.new" "$tmpfile"
  done < <(jq -r '.[].name' <<<"$indices_raw")

  overview_indices="$(cat "$tmpfile")"
  rm -f "$tmpfile"

  logs_json='null'
  api_keys_json='null'

  if (( INCLUDE_LOGS == 1 )); then
    logs_json="$(fetch_logs)"
  fi

  if (( INCLUDE_API_KEYS == 1 )); then
    api_keys_json="$(fetch_api_keys)"
  fi

  jq -n \
    --arg generatedAt "$started_at" \
    --arg appId "$ALGOLIA_APP_ID" \
    --arg host "$HOST" \
    --argjson indices "$overview_indices" \
    --argjson totalIndices "$indices_count" \
    --argjson totalEntries "$total_entries" \
    --argjson totalDataSize "$total_data_size" \
    --argjson totalFileSize "$total_file_size" \
    --argjson logs "$logs_json" \
    --argjson apiKeys "$api_keys_json" \
    '{
      generatedAt: $generatedAt,
      appId: $appId,
      host: $host,
      summary: {
        totalIndices: $totalIndices,
        totalEntries: $totalEntries,
        totalDataSize: $totalDataSize,
        totalFileSize: $totalFileSize
      },
      indices: $indices,
      logs: $logs,
      apiKeys: $apiKeys
    }' > "$OUTPUT_FILE"

  echo "Overview written to: $OUTPUT_FILE"
  echo
  jq -r '
    [
      "App ID: " + .appId,
      "Indices: " + (.summary.totalIndices|tostring),
      "Total entries: " + (.summary.totalEntries|tostring),
      "Total dataSize: " + (.summary.totalDataSize|tostring) + " bytes",
      "Total fileSize: " + (.summary.totalFileSize|tostring) + " bytes"
    ] | join("\n")
  ' "$OUTPUT_FILE"
  echo
  echo "Per-index summary:"
  jq -r '
    .indices[] |
    [
      .name,
      ((.entries // 0)|tostring),
      ((.dataSize // 0)|tostring),
      ((.fileSize // 0)|tostring),
      ((.numberOfPendingTasks // 0)|tostring),
      ((.settingsSummary.searchableAttributes // []) | length | tostring),
      ((.settingsSummary.attributesForFaceting // []) | length | tostring)
    ] | @tsv
  ' "$OUTPUT_FILE" | awk 'BEGIN {
      printf "%-35s %12s %12s %12s %10s %16s %12s\n", "INDEX", "ENTRIES", "DATASIZE", "FILESIZE", "PENDING", "SEARCHABLE_ATTR", "FACETS";
      printf "%s\n", "--------------------------------------------------------------------------------------------------------------------------";
    }
    {
      printf "%-35s %12s %12s %12s %10s %16s %12s\n", $1, $2, $3, $4, $5, $6, $7;
    }'
}

main "$@"
