#!/usr/bin/env bash
# Reconcile broker state with data/jetstream.yaml — declarative
# management for OPTIONAL forensic capture streams (the ones pwriter
# deliberately doesn't own). For each entry in the YAML:
#
#   enabled: true   → ensure stream exists with the configured caps
#   enabled: false  → ensure stream does NOT exist (rm if present)
#
# This file is NOT for the workqueue streams pwriter manages — those
# are declared in pwriter's main.zig. Don't add events_market_trade
# / events_handoff_cell / events_inventory_change here.
#
# Usage:
#   ./scripts/apply_jetstream.sh         # reconcile per the YAML
#   ./scripts/apply_jetstream.sh --status  # show current vs desired
#
# Run after editing data/jetstream.yaml. Idempotent: re-running
# without changes is a no-op.

set -euo pipefail
cd "$(dirname "$0")/.."

YAML="${YAML:-data/jetstream.yaml}"
NATS_BOX="podman run --rm --network host docker.io/natsio/nats-box:latest"

# Tiny YAML parser for our specific shape (top-level keys, each with
# a fixed set of indented scalar fields). Good enough for the v0
# forensic-capture use case; rewrite in Zig (using ymlz, the project's
# already-vendored parser) when this file grows.
parse_entries() {
  awk '
    /^[a-z_][a-z0-9_]*:/ {
      if (name) print_entry()
      name = $1; sub(/:$/, "", name)
      enabled = ""; subject = ""; max_age_hours = ""; max_bytes_gb = ""; storage = ""
      next
    }
    /^[[:space:]]+enabled:/        { enabled = $2; next }
    /^[[:space:]]+subject:/        { sub(/^[[:space:]]+subject:[[:space:]]*/, ""); gsub(/^"|"$/, ""); subject = $0; next }
    /^[[:space:]]+max_age_hours:/  { max_age_hours = $2; next }
    /^[[:space:]]+max_bytes_gb:/   { max_bytes_gb = $2; next }
    /^[[:space:]]+storage:/        { storage = $2; next }
    END { if (name) print_entry() }
    function print_entry() {
      print name "|" enabled "|" subject "|" max_age_hours "|" max_bytes_gb "|" storage
    }
  ' "$YAML"
}

stream_exists() {
  $NATS_BOX nats stream info "$1" --json 2>/dev/null | grep -q '"name"' && return 0 || return 1
}

apply_one() {
  local name="$1" enabled="$2" subject="$3" age_hours="$4" bytes_gb="$5" storage="$6"

  if [ -z "$enabled" ] || [ "$enabled" = "false" ]; then
    if stream_exists "$name"; then
      echo "  $name: enabled=false, removing existing stream"
      $NATS_BOX nats stream rm "$name" -f >/dev/null 2>&1 || true
    else
      echo "  $name: enabled=false, no stream present (ok)"
    fi
    return 0
  fi

  # enabled=true → ensure stream exists with current config.
  local age_secs=$(( age_hours * 3600 ))
  local bytes=$(( bytes_gb * 1024 * 1024 * 1024 ))
  local subjects_json
  subjects_json=$(printf '"%s"' "$subject")

  # Always send STREAM.UPDATE — handles both create and re-apply
  # (when the YAML caps changed). 2.14 broker accepts UPDATE on a
  # missing stream by creating; if it doesn't, fall back to CREATE.
  local body
  body=$(cat <<JSON
{"name":"$name","subjects":[$subjects_json],"retention":"limits","storage":"$storage","max_age":$((age_secs * 1000000000)),"max_bytes":$bytes,"num_replicas":1,"discard":"old"}
JSON
)

  local resp
  if stream_exists "$name"; then
    echo "  $name: enabled=true, updating (age=${age_hours}h bytes=${bytes_gb}GB)"
    resp=$($NATS_BOX nats req "\$JS.API.STREAM.UPDATE.$name" "$body" 2>&1 | tail -1)
  else
    echo "  $name: enabled=true, creating (age=${age_hours}h bytes=${bytes_gb}GB)"
    resp=$($NATS_BOX nats req "\$JS.API.STREAM.CREATE.$name" "$body" 2>&1 | tail -1)
  fi

  if echo "$resp" | grep -q '"error":{'; then
    echo "    ERROR: $resp"
    return 1
  fi
}

if ! ss -lnt 2>/dev/null | grep -q :4222; then
  echo "ERROR: NATS broker not listening on :4222 (run 'make nats-up')"
  exit 1
fi

if [ ! -f "$YAML" ]; then
  echo "ERROR: $YAML not found"
  exit 1
fi

if [ "${1:-}" = "--status" ]; then
  echo ">>> declared in $YAML:"
  parse_entries | column -t -s '|' -N 'name,enabled,subject,age_h,bytes_g,storage'
  echo
  echo ">>> currently in broker (filtered to forensic_/audit_ prefix):"
  $NATS_BOX nats stream ls 2>&1 | grep -E '_forensic|^$'
  exit 0
fi

echo ">>> reconciling $YAML against broker"
fail=0
while IFS='|' read -r name enabled subject age_hours bytes_gb storage; do
  [ -z "$name" ] && continue
  apply_one "$name" "$enabled" "$subject" "$age_hours" "$bytes_gb" "$storage" || fail=1
done < <(parse_entries)

if [ "$fail" = "1" ]; then
  echo ">>> reconcile finished with errors"
  exit 1
fi
echo ">>> done"
