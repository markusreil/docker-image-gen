#!/bin/sh
# Generate an image via the local OpenAI-compatible bridge.
# Usage: generate-image.sh "<prompt>" [size] [model] [outfile]
# Env:   BRIDGE_URL (default http://localhost:8080/v1), BRIDGE_API_KEY (required)
set -eu

[ $# -ge 1 ] || { echo "usage: $0 \"<prompt>\" [size] [model] [outfile]" >&2; exit 2; }

PROMPT="$1"
SIZE="${2:-1024x1024}"
MODEL="${3:-sdxl}"
OUT="${4:-image.png}"
BRIDGE_URL="${BRIDGE_URL:-http://localhost:8080/v1}"
: "${BRIDGE_API_KEY:?set BRIDGE_API_KEY (the bridge /v1 bearer token)}"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

curl -fsS "$BRIDGE_URL/images/generations" \
  -H "Authorization: Bearer $BRIDGE_API_KEY" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg m "$MODEL" --arg p "$PROMPT" --arg s "$SIZE" \
        '{model:$m,prompt:$p,size:$s,n:1,response_format:"b64_json"}')" \
  | jq -r '.data[0].b64_json' \
  | base64 -d > "$TMP"

mv "$TMP" "$OUT"
trap - EXIT
echo "wrote $OUT"
