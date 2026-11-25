#!/usr/bin/env bash
# End-to-end test against a real Remote Browser instance. It launches one browser, runs every
# command on it, and terminates it.
#
# Usage: remotebrowser login URL, then tests/e2e.sh URL [path/to/remotebrowser]
#
# The URL is required so the test never runs on the wrong server by accident.

set -euo pipefail

if [[ $# -lt 1 || $1 == -* ]]; then
  echo "usage: $0 URL [path/to/remotebrowser]" >&2
  exit 2
fi
URL=$1
RB=${2:-zig-out/bin/remotebrowser}

rb() {
  "$RB" --url "$URL" "$@"
}

ID=
cleanup() {
  if [[ -n $ID ]]; then rb delete "$ID" >/dev/null 2>&1 || true; fi
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
expect_exit "status finds a login to $URL" 0 rb status
expect_exit "usage error" 2 rb get
expect_exit "unknown browser" 1 rb get Bnonexistent

ID=$(rb create --name "remotebrowser-cli-e2e" --description "CLI end-to-end test" --wait)
expect "create --wait prints the id" "B" "$ID"
expect "list has the browser" "$ID" "$(rb list)"
expect "get shows it running" "status:      running" "$(rb get "$ID")"
expect "get --json" "\"browser_id\": \"$ID\"" "$(rb get "$ID" --json)"
expect "connect prints the CDP URL" "/api/v1/browsers/$ID/cdp" "$(rb connect "$ID")"
expect "config get" "proxy: -" "$(rb config get "$ID")"
expect "config set --proxy hides the password" "socks5://user:****@proxy.example:1080" \
  "$(rb config set "$ID" --proxy socks5://user:secret@proxy.example:1080)"
expect "config set --no-proxy" "\"proxy\": null" "$(rb config set "$ID" --no-proxy --json)"
expect "suspend" "$ID suspended" "$(rb suspend "$ID")"
expect "resume" "$ID running" "$(rb resume "$ID")"
expect_exit "resume a running browser is a conflict" 1 rb resume "$ID"
expect "delete" "$ID terminated" "$(rb delete "$ID")"
ID=

echo "all end-to-end tests passed"
