#!/usr/bin/env bash
# End-to-end CLI smoke test for whatsapp-core.
#
#   ./scripts/smoke.sh                 # unauthenticated checks + QR fetch
#   CONNECT=1 ./scripts/smoke.sh       # additionally wait for QR scan +
#                                      #   history sync, then exercise chats/
#                                      #   messages/search (needs your phone)
#
# Requires: curl, python3. Uses a throwaway data dir under /tmp.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${WW_CORE_BIN:-$ROOT/dist/whatsapp-core}"
[ -x "$BIN" ] || BIN="$(cd "$ROOT/core" && go build -o /tmp/ww-smoke-core ./cmd/whatsapp-core && echo /tmp/ww-smoke-core)"

DATA=$(mktemp -d /tmp/ww-smoke.XXXXXX)
CORE_PID=""
cleanup() {
  [ -n "$CORE_PID" ] && kill "$CORE_PID" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$DATA"
}
trap cleanup EXIT

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }
note() { echo "-- $*"; }

# --- launch + READY handshake ---
note "starting core"
"$BIN" --data-dir "$DATA" >"$DATA/out.log" 2>"$DATA/err.log" &
CORE_PID=$!
READY=""
for _ in $(seq 1 100); do
  READY=$(grep -m1 '"event":"ready"' "$DATA/out.log" || true)
  [ -n "$READY" ] && break
  kill -0 "$CORE_PID" 2>/dev/null || break
  sleep 0.1
done
[ -n "$READY" ] || { cat "$DATA/err.log" >&2; fail "no READY line"; }
read -r PORT TOKEN <<<"$(echo "$READY" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["port"], d["token"])')"
API="http://127.0.0.1:$PORT"
AUTH="Authorization: Bearer $TOKEN"
note "ready on :$PORT"

api() { curl -sf -H "$AUTH" "$@"; }

# --- auth must be enforced ---
code=$(curl -s -o /dev/null -w '%{http_code}' "$API/healthz")
[ "$code" = "401" ] || fail "unauthenticated /healthz = $code, want 401"
note "401 without token: ok"

# --- healthz / session ---
api "$API/healthz" | python3 -m json.tool >/dev/null || fail "healthz"
note "healthz: ok"
state=$(api "$API/session" | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])')
note "initial state: $state"

# --- single-instance lock ---
"$BIN" --data-dir "$DATA" >/dev/null 2>&1 && fail "second instance exited 0" || rc=$?
[ "${rc:-0}" = "2" ] || fail "second instance exit=$rc, want 2 (lock held)"
note "single-instance lock (exit 2): ok"

# --- QR login ---
api -X POST -d '{"mode":"qr"}' "$API/session/link" >/dev/null || fail "session/link"
note "link started"

qr=""
for i in $(seq 1 40); do
  qr=$(api "$API/session" | python3 -c 'import json,sys
d = json.load(sys.stdin)
q = d.get("qr") or {}
print(q.get("code", ""))' 2>/dev/null || true)
  [ -n "$qr" ] && break
  sleep 0.5
done
[ -n "$qr" ] || fail "no QR code arrived (network blocked?)"
note "QR obtained from WhatsApp servers: ok (scan: WhatsApp → Settings → Linked Devices)"

if [ "${CONNECT:-0}" != "1" ]; then
  note "CONNECT=1 not set — stopping here. PASS"
  exit 0
fi

# --- wait for pairing + history sync (requires scanning the QR) ---
note "waiting for scan + connection (scan the QR above)…"
for i in $(seq 1 240); do
  s=$(api "$API/session" | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])')
  [ "$s" = "connected" ] && break
  sleep 1
done
[ "$s" = "connected" ] || fail "never connected (state=$s)"

note "waiting for sync to settle…"
sleep 10
api "$API/chats?limit=5" | python3 -m json.tool | head -20
CHATS=$(api "$API/chats?limit=1" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["chats"]))')
note "chats visible: $CHATS"

FIRST=$(api "$API/chats?limit=1" | python3 -c 'import json,sys
c = json.load(sys.stdin)["chats"]
print(c[0]["jid"] if c else "")')
if [ -n "$FIRST" ]; then
  api "$API/chats/$FIRST/messages?limit=3" | python3 -m json.tool | head -15
  note "search:"
  api "$API/search?q=the&limit=3" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("hits:", len(d["messages"]))'
fi

note "PASS"
