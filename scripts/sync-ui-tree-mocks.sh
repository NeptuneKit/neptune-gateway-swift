#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_ROOT="${NEPTUNE_UI_TREE_SOURCE_ROOT:-$ROOT/../neptune-inspector-h5/mocks/real}"
OUT_DIR="${NEPTUNE_UI_TREE_MOCK_OUT_DIR:-$ROOT/mocks/ui-tree}"
CLIENTS_FILE="${NEPTUNE_UI_TREE_CLIENTS_FILE:-$SOURCE_ROOT/clients.json}"

mkdir -p "$OUT_DIR"

default_app_id() {
  case "$1" in
    ios) echo "com.neptunekit.demo.ios" ;;
    android) echo "com.neptunekit.sdk.android.examples.simulator" ;;
    harmony) echo "io.github.neptune.sdk.harmony.demo" ;;
    *) echo "unknown.app" ;;
  esac
}

default_session_id() {
  case "$1" in
    harmony) echo "sim-session-alpha" ;;
    *) echo "simulator-session" ;;
  esac
}

default_device_id() {
  case "$1" in
    ios) echo "simulator-device-ios" ;;
    android) echo "simulator-device" ;;
    harmony) echo "sim-device-alpha" ;;
    *) echo "sim-device" ;;
  esac
}

lookup_client_field() {
  local platform="$1"
  local field="$2"
  if [[ -s "$CLIENTS_FILE" ]]; then
    jq -r --arg p "$platform" --arg f "$field" \
      '.items[]? | select(.platform == $p) | .[$f] // empty' \
      "$CLIENTS_FILE" | head -n1
  fi
}

platforms=(ios android harmony)
combined_file="$OUT_DIR/raw-ingest-requests.json"
printf '[\n' > "$combined_file"
index=0

for platform in "${platforms[@]}"; do
  inspector_file="$SOURCE_ROOT/${platform}-gateway-inspector.json"
  if [[ ! -s "$inspector_file" ]]; then
    echo "[sync-ui-tree-mocks] skip ${platform}: missing ${inspector_file}"
    continue
  fi

  if ! jq -e '.snapshotId and .capturedAt and .platform and (.payload | type == "object" or type == "array")' \
    "$inspector_file" >/dev/null 2>&1; then
    echo "[sync-ui-tree-mocks] skip ${platform}: invalid inspector payload"
    continue
  fi

  app_id="$(lookup_client_field "$platform" "appId")"
  session_id="$(lookup_client_field "$platform" "sessionId")"
  device_id="$(lookup_client_field "$platform" "deviceId")"

  app_id="${app_id:-$(default_app_id "$platform")}"
  session_id="${session_id:-$(default_session_id "$platform")}"
  device_id="${device_id:-$(default_device_id "$platform")}"

  cp "$inspector_file" "$OUT_DIR/${platform}-inspector.json"

  request_file="$OUT_DIR/${platform}-raw-ingest-request.json"
  jq --arg appId "$app_id" \
     --arg sessionId "$session_id" \
     --arg deviceId "$device_id" \
     '
     def prune_null:
       walk(
         if type == "object" then
           with_entries(select(.value != null))
         elif type == "array" then
           map(select(. != null))
         else
           .
         end
       );
     {
       platform: .platform,
       appId: $appId,
       sessionId: $sessionId,
       deviceId: $deviceId,
       snapshotId: .snapshotId,
       capturedAt: .capturedAt,
       payload: (.payload | prune_null)
     }' "$inspector_file" > "$request_file"

  if [[ "$index" -gt 0 ]]; then
    printf ',\n' >> "$combined_file"
  fi
  cat "$request_file" >> "$combined_file"
  index=$((index + 1))

  echo "[sync-ui-tree-mocks] wrote ${request_file}"
done

printf '\n]\n' >> "$combined_file"
echo "[sync-ui-tree-mocks] wrote ${combined_file}"
