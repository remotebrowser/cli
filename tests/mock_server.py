#!/usr/bin/env python3
"""A fake Remote Browser server for running tests/e2e.sh in CI without a real server.

It approves every login by itself after one "authorization_pending" poll, so no one has to type
the code. It only behaves the way we wrote it, so it cannot catch changes in the real API.

Usage: python3 tests/mock_server.py [--port 8765]
"""

import argparse
import itertools
import json
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, urlunsplit

TOKEN = "test-token"
DEVICE_CODE = "test-device-code"
USER_CODE = "TEST-CODE"

lock = threading.Lock()
ids = itertools.count(1)
browsers = {}
polls = 0
revoked = False


def mask_proxy(proxy):
  """The real server hides the proxy password, and e2e.sh checks that."""
  if not proxy:
    return proxy
  parts = urlsplit(proxy)
  if parts.password is None:
    return proxy
  host = parts.hostname + (f":{parts.port}" if parts.port else "")
  return urlunsplit(parts._replace(netloc=f"{parts.username}:****@{host}"))


class Handler(BaseHTTPRequestHandler):
  # The CLI keeps the connection open between requests.
  protocol_version = "HTTP/1.1"

  def send_json(self, status, value=None):
    body = b"" if value is None else json.dumps(value).encode()
    self.send_response(status)
    if value is not None:
      self.send_header("Content-Type", "application/json")
    self.send_header("Content-Length", str(len(body)))
    self.end_headers()
    self.wfile.write(body)

  def error(self, status, message):
    self.send_json(status, {"error": message})

  def read_body(self):
    length = int(self.headers.get("Content-Length") or 0)
    raw = self.rfile.read(length) if length else b""
    return json.loads(raw) if raw else {}

  def authorized(self):
    if self.headers.get("Authorization") == f"Bearer {TOKEN}" and not revoked:
      return True
    self.error(401, "Invalid or expired token.")
    return False

  def do_GET(self):
    self.route("GET")

  def do_POST(self):
    self.route("POST")

  def do_PATCH(self):
    self.route("PATCH")

  def do_DELETE(self):
    self.route("DELETE")

  def route(self, method):
    global polls, revoked
    try:
      body = self.read_body()
    except ValueError:
      return self.error(400, "The body is not valid JSON.")
    path = self.path.split("?")[0]
    with lock:
      if (method, path) == ("POST", "/api/v1/auth/device"):
        polls = 0
        url = f"http://{self.headers.get('Host')}/activate"
        return self.send_json(200, {
          "device_code": DEVICE_CODE,
          "user_code": USER_CODE,
          "verification_uri": url,
          "verification_uri_complete": f"{url}?code={USER_CODE}",
          "expires_in": 60,
          "interval": 1,
        })
      if (method, path) == ("POST", "/api/v1/auth/token"):
        if body.get("device_code") != DEVICE_CODE:
          return self.error(400, "invalid_grant")
        polls += 1
        if polls == 1:
          return self.error(400, "authorization_pending")
        revoked = False
        return self.send_json(200, {"access_token": TOKEN, "token_type": "Bearer", "expires_in": 30 * 86400})
      if (method, path) == ("POST", "/api/v1/auth/revoke"):
        if not self.authorized():
          return None
        revoked = True
        return self.send_json(204)

      if not path.startswith("/api/v1/browsers"):
        return self.error(404, "Not found.")
      if not self.authorized():
        return None
      if (method, path) == ("GET", "/api/v1/browsers"):
        return self.send_json(200, [b["browser_id"] for b in browsers.values() if b["status"] != "terminated"])
      if (method, path) == ("POST", "/api/v1/browsers"):
        browser_id = f"B{next(ids):04d}"
        browsers[browser_id] = {
          "browser_id": browser_id,
          "status": "starting",
          "name": body.get("name") or browser_id,
          "description": body.get("description") or "",
          "os": body.get("os") or "debian-13",
          "browser": body.get("browser") or "chromium",
          "creation_timestamp": int(time.time() * 1000),
          "proxy": body.get("proxy"),
        }
        return self.send_json(201, public(browsers[browser_id]))

      match = re.fullmatch(r"/api/v1/browsers/([^/]+)(/suspend|/resume|/config)?", path)
      browser = browsers.get(match.group(1)) if match else None
      if browser is None or browser["status"] == "terminated":
        return self.error(404, "Browser not found.")
      action = match.group(2)
      if (method, action) == ("GET", None):
        # It starts on the first check, so `create --wait` polls once.
        if browser["status"] == "starting":
          browser["status"] = "running"
        return self.send_json(200, public(browser))
      if (method, action) == ("DELETE", None):
        browser["status"] = "terminated"
        return self.send_json(200, public(browser))
      if (method, action) == ("POST", "/suspend"):
        if browser["status"] != "running":
          return self.error(409, "Only a running browser can be suspended.")
        browser["status"] = "suspended"
        return self.send_json(200, public(browser))
      if (method, action) == ("POST", "/resume"):
        if browser["status"] != "suspended":
          return self.error(409, "Only a suspended browser can be resumed.")
        browser["status"] = "running"
        return self.send_json(200, public(browser))
      if action == "/config" and method in ("GET", "PATCH"):
        if method == "PATCH":
          if "proxy" not in body:
            return self.error(400, "Nothing to change.")
          browser["proxy"] = body["proxy"]
        return self.send_json(200, {"browser_id": browser["browser_id"], "proxy": mask_proxy(browser["proxy"])})
      return self.error(405, "Method not allowed.")


def public(browser):
  return {k: v for k, v in browser.items() if k != "proxy"}


def main():
  parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
  parser.add_argument("--port", type=int, default=8765)
  args = parser.parse_args()
  server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
  print(f"listening on http://127.0.0.1:{server.server_port}", file=sys.stderr, flush=True)
  server.serve_forever()


if __name__ == "__main__":
  main()
