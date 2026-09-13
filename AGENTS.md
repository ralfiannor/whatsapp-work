# AGENTS.md

Working agreement for humans and AI agents contributing to WhatsApp Work.
Read this before touching the code. It encodes decisions that are easy to
get wrong and expensive to rediscover.

## What this is

Native macOS work-inbox client for WhatsApp: SwiftUI app (`apps/macos`) +
Go sidecar (`core/`, whatsmeow linked-device protocol) + SQLite/FTS5.
Loopback HTTP+WS IPC with a bearer token handed over via stdout handshake.
Performance is a product requirement — see `docs/performance.md` and
`docs/performance-audit-2026-08.md` for budgets and measured numbers.

Unofficial client. No automation, no bulk send, ever (account-ban posture,
`docs/architecture.md` §R1).

## Open source

This repository is public open source (MIT, see `LICENSE`). Community
rules apply to every commit:

- **English only** in code, docs, commit messages, issues, and PRs.
- **No personal data in committed files**: real JIDs, phone numbers,
  contact/chat display names, message content, tokens, or QR material.
  Tests use fictional fixtures (`254700000001@s.whatsapp.net`,
  `6285000000001@s.whatsapp.net`, "Sample AC Service"). When pulling a
  repro from a live account, redact first — labels like "the Hansip bug"
  are fine, a real person's chat name is not.
- `CONTRIBUTING.md` and `SECURITY.md` apply to humans and agents alike;
  the no-automation rule (§R1) and the no-content-logging rule are
  non-negotiable.
- Docs are written for outside readers: no internal session references,
  private machine paths, or unredacted capture logs.

## Layout

```
apps/macos/   SwiftUI app (xcodegen project.yml → WhatsAppWork.xcodeproj)
core/         Go module "github.com/ralfiannor/whatsapp-work" (cmd/whatsapp-core + internal/)
scripts/      build-core.sh · make-icon.sh (+ icongen.swift) · smoke.sh
dist/         build output (gitignored)
docs/         architecture · protocol · schema · performance · audit
```

## Build, test, verify

```bash
./scripts/build-core.sh                    # universal sidecar → dist/
cd apps/macos && xcodegen generate         # after project.yml edits
xcodebuild -scheme WhatsAppWork -configuration Debug \
  -derivedDataPath build/DerivedData build # bundles + adhoc-signs the sidecar

cd core
go build ./... && go vet ./...
go test ./...
go test -race ./internal/app ./internal/whatsapp ./internal/storage ./internal/ipc
WW_BENCH_N=150000 go test ./internal/storage -run XXX -bench . -benchmem
```

A change is not done until: Go tests + race green, app builds, and — for
anything touching a hot path — a before/after measurement (bench, EXPLAIN
QUERY PLAN, or `ps` sampling). Claims without numbers get reverted.

## Go rules

**Dependency direction (enforced by review):** `core` imports nothing
internal. `storage` → `core` only. `whatsapp` is the ONLY package that
imports whatsmeow — normalize to `core` types at the boundary. `app` →
core/events/storage via the narrow `WAClient` port. `ipc` → `app`.

**Errors:** wrap with context (`fmt.Errorf("storage: ...: %w", err)`).
`storage.ErrNotFound` is a sentinel — match with `errors.Is`, never string
matching. (We shipped a string-matching bug against whatsmeow sentinels
once; don't repeat it — use `errors.Is(err, whatsmeow.Err...)`.)

**Tests:** external `_test` packages with an in-memory `fakeWA`
implementing `core.WAClient`. When the port changes, update both fakes
(`internal/app/app_test.go`, `internal/ipc/server_test.go`).

**Concurrency:** ingest runs on ONE goroutine (total order, persist before
fan-out). Timers that can outlive shutdown must check `runCtx.Err()`
before emitting (dispatcher channels close on shutdown). Shared flags use
atomics; the `namesPending`/`nameGen` pair shows the pattern for
"clear only if not re-armed mid-pass".

## SQLite rules

- WAL, `synchronous=NORMAL`, `busy_timeout=5000`. One writer connection +
  4-reader pool. Never open a connection per request.
- Pagination is keyset `(timestamp, id)` — no OFFSET, no `SELECT *`.
- Every hot query gets `EXPLAIN QUERY PLAN` before merge. A `SCAN messages`
in a request path is a bug. Full-scan diagnostics (COUNT/GROUP BY) are for
  the audit only, never a request path.
- Migrations are append-only entries in `internal/storage/migrations.go`,
  in one transaction, tracked in `schema_migrations`.
- Unread counters are denormalized but self-healing:
  `RecomputeUnreadCounters` runs at startup; live ingest maintains them
  between restarts. If you add a counter, add it to the recompute.
- FTS user input goes through `buildMatchQuery` (quoted terms) and LIKE
  patterns through `escapeLike`.

## Swift rules

- `AppState` is `@MainActor` and the single `ObservableObject`. Keep rows
  cheap: `Equatable` row views gate re-diffs; memoize expensive
  attributed strings (and version the cache key when the render pipeline
  changes — stale caches shipped two visual bugs already).
- **No AppKit text views per transcript row.** NSTextView per row stuttered
  scrolling on Intel; we rolled it back to SwiftUI `Text`. Accept the
  missing link-cursor; do not re-introduce without a scroll-perf
  measurement on the 2018-class machine.
- Image decode goes through `downsampledImage` in a detached task
  (`nonisolated`); decoded-image RAM is byte-budgeted (`mediaImages` +
  `mediaImageBytes` stay in sync on every path).
- Replace-after-await races: `open()`, `loadOlderMessages`, `refreshChats`
  must MERGE, not overwrite (WS events land during fetches). Filtered chat
  views (`unread`/`mentions`) are server-authoritative — never merge local
  extras back in.
- Optimistic sends: temp rows have negative ids; WS echo of an own message
  reconciles the matching temp row (chat + text); retry removes the failed
  row before re-sending.
- Identity: the app canonicalizes to phone-number JIDs. LID forms appear
  in LID-addressed groups — prefer `PhoneNumber` when whatsmeow provides
  it, resolve labels via `nickColorKey` (name-stable, not JID-stable) for
  coloring.

## Protocol / IPC rules

- WS events are hints; SQLite via REST is the source of truth. On
  reconnect (or seq gap) refetch `/chats` + the open chat. Events carry
  deltas, never full state snapshots.
- New endpoints go on the existing mux — the auth middleware (Host
  allow-list + constant-time bearer compare) wraps the whole thing.
  Nothing that logs message content, tokens, or QR material, ever.
- Don't add polling. Event-driven only; the 15 s poll no-ops while the WS
  stream is fresh and exists purely as a fallback.

## Known sharp edges

- `RequireFullSync = true` → every login re-syncs full history (dedup makes
  it idempotent). Sync `done` arrives on the final payload (progress 100)
  with a 3-minute quiet-period fallback in `app.syncQuietDone`.
- `emitContacts` is throttled to 10 min and stamped only on success;
  `PairSuccess` resets it.
- Sidecar lifecycle contract (§6 of architecture.md): READY line, flock,
  exit codes 0/2/3/4, `SidecarManager.stopBlocking()` on app quit.
- The media manager re-checks actual downloaded bytes against the cap —
  the proto's FileLength is attacker-supplied. Keep it that way.
- **Identity duality is pervasive.** Every jid-keyed write (contacts,
  reactions, mention lists, read receipts) can arrive under the PN or the
  LID form of the same human, while rendering layers canonicalize to PN.
  Mirror name/identity data onto both forms (`twinContacts`,
  `MirrorLIDContactNames`, the dual-form `events.PushName` emit) — a row
  stored under one form alone shows up as a raw phone number. Shipped as a
  real bug twice ("Hansip", 2026-09-02).
- **Absence of data in our DB is not evidence about the protocol.** Before
  concluding "the server never sends X / it's privacy, nothing we can do",
  instrument the LIVE path (watch a real event arrive, check whatsmeow's own
  stores first — it sees events before our code does). The "Hansip" name was
  declared unreachable twice; a single live DM test disproved it in minutes.
  When a user's report contradicts the theory, the report is data — test it,
  don't argue with it.

## Commit / PR expectations

- Conventional, small, self-contained. Perf changes cite numbers in the
  description (before/after, method).
- Don't rewrite working code for style. Don't introduce frameworks,
  Redis/Postgres/Electron, or "temporary" full rescans.
- If a behavior depends on whatsmeow internals, verify against the pinned
  version in `core/go.mod` module cache before relying on it.
