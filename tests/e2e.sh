#!/usr/bin/env bash
# End-to-end test against a real Remote Browser instance. It launches one browser, runs every
# command on it, and terminates it.
#
# Usage: REMOTEBROWSER_URL=... REMOTEBROWSER_API_KEY=... tests/e2e.sh [path/to/remotebrowser]

set -euo pipefail

RB=${1:-zig-out/bin/remotebrowser}
: "${REMOTEBROWSER_URL:?REMOTEBROWSER_URL is required}"
: "${REMOTEBROWSER_API_KEY:?REMOTEBROWSER_API_KEY is required}"

ID=
cleanup() {
  if [[ -n $ID ]]; then "$RB" delete "$ID" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect() { # expect <description> <expected> <actual>
  [[ $3 == *"$2"* ]] || fail "$1: expected '$2' in: $3"
  echo "ok - $1"
}

expect_exit() { # expect_exit <description> <code> <command>...
  local description=$1 expected=$2 code=0
  shift 2
  "$@" >/dev/null 2>&1 || code=$?
  [[ $code == "$expected" ]] || fail "$description: exit code $code, expected $expected"
  echo "ok - $description"
}

expect "version" "." "$("$RB" --version)"
expect "status uses the API key" "credentials: REMOTEBROWSER_API_KEY" "$("$RB" status)"
expect_exit "usage error" 2 "$RB" get
expect_exit "unknown browser" 1 "$RB" get Bnonexistent

ID=$("$RB" create --name "remotebrowser-cli-e2e" --description "CLI end-to-end test" --wait)
expect "create --wait prints the id" "B" "$ID"
expect "list has the browser" "$ID" "$("$RB" list)"
expect "get shows it running" "status:      running" "$("$RB" get "$ID")"
expect "get --json" "\"browser_id\": \"$ID\"" "$("$RB" get "$ID" --json)"
expect "connect prints the CDP URL" "/api/v1/browsers/$ID/cdp" "$("$RB" connect "$ID")"
expect "config get" "proxy: -" "$("$RB" config get "$ID")"
expect "config set --proxy hides the password" "socks5://user:****@proxy.example:1080" \
  "$("$RB" config set "$ID" --proxy socks5://user:secret@proxy.example:1080)"
expect "config set --no-proxy" "\"proxy\": null" "$("$RB" config set "$ID" --no-proxy --json)"
expect "suspend" "$ID suspended" "$("$RB" suspend "$ID")"
expect "resume" "$ID running" "$("$RB" resume "$ID")"
expect_exit "resume a running browser is a conflict" 1 "$RB" resume "$ID"
expect "delete" "$ID terminated" "$("$RB" delete "$ID")"
ID=

echo "all end-to-end tests passed"
