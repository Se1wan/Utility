#!/usr/bin/env bash
set -euo pipefail

ACCOUNT="<Account_Name>"
ACCOUNT_KEY="<Key>"
CONTAINER="<Container_Name>"
VERSION="<YYYY-MM-DD>"
DATE_UTC="$(LC_ALL=C TZ=GMT date -u '+%a, %d %b %Y %H:%M:%S GMT')"

CANONICAL_HEADERS="x-ms-date:${DATE_UTC}\nx-ms-version:${VERSION}\n"
CANONICAL_RESOURCE="/${ACCOUNT}/${CONTAINER}\ncomp:list\nrestype:container"

STRING_TO_SIGN="GET\n\n\n\n\n\n\n\n\n\n\n\n${CANONICAL_HEADERS}${CANONICAL_RESOURCE}"

HEX_KEY="$(printf '%s' "$ACCOUNT_KEY" | base64 -d | xxd -p -c 1000)"
SIGNATURE="$(
  printf '%b' "$STRING_TO_SIGN" \
  | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${HEX_KEY}" -binary \
  | base64
)"

curl -sS \
  -H "x-ms-date: ${DATE_UTC}" \
  -H "x-ms-version: ${VERSION}" \
  -H "Authorization: SharedKey ${ACCOUNT}:${SIGNATURE}" \
  "https://${ACCOUNT}.blob.core.windows.net/${CONTAINER}?restype=container&comp=list"
