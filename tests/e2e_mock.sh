#!/usr/bin/env bash
# Runs tests/e2e.sh against tests/mock_server.py, with a full login and logout. CI uses it, because
# a real server needs a person to approve the login.
#
# Usage: tests/e2e_mock.sh [path/to/remotebrowser]

set -euo pipefail

RB=${1:-zig-out/bin/remotebrowser}
DIR=$(cd "$(dirname "$0")" && pwd)
PORT=${MOCK_PORT:-8765}
URL=http://127.0.0.1:$PORT

# Keep the logins of this computer out of the test.
REMOTEBROWSER_CONFIG_DIR=$(mktemp -d)
export REMOTEBROWSER_CONFIG_DIR

python3 -I "$DIR/mock_server.py" --port "$PORT" &
MOCK=$!
trap 'kill $MOCK 2>/dev/null || true; rm -rf "$REMOTEBROWSER_CONFIG_DIR"' EXIT

for _ in $(seq 50); do
  if (echo >"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then break; fi
  sleep 0.1
done

"$RB" login --no-browser "$URL"
echo "ok - login"
"$DIR/e2e.sh" "$URL" "$RB"
"$RB" logout "$URL"
if "$RB" status --url "$URL" >/dev/null 2>&1; then
  echo "FAIL: status still finds a login after logout" >&2
  exit 1
fi
echo "ok - logout"
