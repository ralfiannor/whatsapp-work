# Implementation Roadmap

Incremental, each milestone buildable and testable. MVP list numbers (v0.1 brief §MVP) map to
milestones. Exit criteria = "done means done" gates.

## M0 — Foundation (this change)

Go core skeleton, proven storage, IPC contract, adapter shape.

- Repo layout, docs (architecture, protocol, schema, performance, roadmap).
- `storage`: migrations, chats/messages repos, keyset pagination, FTS5 search, idempotent ingest,
  unread counters. Unit-tested.
- `events`: dispatcher with drop-on-slow policy. Unit-tested.
- `whatsapp` adapter: whatsmeow isolation, event normalization (text, reply, mention, media meta,
  revoke, unsupported). Unit-tested against constructed protos — no network needed.
- `app`: ingest pipeline, login FSM (QR), services (chats/messages/send/react/read/search).
- `ipc`: 127.0.0.1 HTTP + WS, bearer token, READY handshake, `/healthz` stats. Unit-tested.
- `cmd/whatsapp-core`: flags, flock single-instance, signals, clean shutdown, QR to terminal.

Exit: `go build`, `go vet`, `go test -race ./...` green; sidecar runs standalone and prints READY.

## M1 — Live protocol milestone (can replace WhatsApp Web reading)

Brief MVP items 2,3,4,5,6,7,8,9,10,11,12,18,19,21.

Status: **daily-driven on a real account** (full sync completes, live
traffic ingested); the formal manual-validation checklist remains pending
(`manual-validation-2026-09-05.md`).

- [x] Real QR login against WhatsApp; connection state machine end-to-end (QR
      fetch verified against WhatsApp servers by scripts/smoke.sh).
- [x] History sync → chats + messages bulk ingest (chunked tx via
      EventHistoryBatch, progress events; measured 4.6k rows/s on Intel — see
      docs/performance.md).
- [x] Live receive/send/reply/react; receipts (delivered/read/failed) on outgoing;
      read_self receipts advance the local read position.
- [x] Unread counts + mention detection end-to-end; contacts from history sync
      (+ push names) with direct-chat name backfill; group renames via GroupInfo.
- [x] Group metadata + participants sync.
- [x] Logout with local wipe.
- [x] Smoke-test script (scripts/smoke.sh) with optional full login; performance
      benches run with numbers recorded in docs/performance.md.
- [x] Real-account run: full sync completes on a daily-driver account
      (formal checklist capture still pending, see above).

Exit: full conversation usable via curl; sync of a real account completes; no data-loss races
(duplicate/race tests).

## M2 — SwiftUI shell

Brief MVP items 1,16,20(partial),17(basic).

Status: **first build running** — Xcode 16.2 installed, XcodeGen project builds,
app launches, spawns the sidecar (READY handshake, crash-restart contract),
renders the live login QR end-to-end.

- [x] XcodeGen `project.yml` + post-build phase that bundles and adhoc-signs
      the universal Go core into the .app (codesign-safe incl. Debug dylib).
- [x] Sidecar process manager per architecture §6 (spawn/READY/backoff/
      shutdown, newline-buffered stdout parsing, core.log capture, power
      assertion during sync).
- [x] HTTP+WS client with bearer token; event application patches state
      incrementally (no full refresh per message); poll fallback while WS
      soaks.
- [x] Login screen (live QR via CIFilter), chat list, transcript with
      pagination + load-older, composer (⌘↩ send), connection banner,
      native notifications, Dock unread badge, logout (wipes local data).
- [ ] Soak: verify WS long-session stability, sleep/wake, sidecar kill -9.
- [x] Reply/reaction UI targets, ⌘K search overlay, media bubbles
      (auth-header image loading; reactions fixed to update live —
      feature-audit P1-1).
- [ ] Settings screen (typography menu + member panel toggle exist and
      persist; a proper settings surface is still missing).
- [ ] Instruments pass: cold start, chat switch, scroll (docs/performance.md).

Exit: daily-driver reading + replying possible on a real Mac; budgets M2 rows filled.

## M3 — Media

Brief MVP items 13,14,15.

Status: **server-side complete** (UI rendering is M2 work).

- [x] On-demand download with `media.state` machine (`internal/media`):
      single-flight per item, ≤2 concurrent downloads, atomic 0600 file writes.
- [x] LRU cache eviction to `--media-cache-mb` (default 500 MB), reconciled at
      startup; evicted rows degrade to `not_downloaded` and re-fetch on demand.
- [x] `POST /media/{id}/download` + `GET /media/{id}/file` + `media.updated`
      events (docs/protocol.md). Proto rehydration via whatsmeow `DownloadAny`.
- [x] Missing-file detection (re-fetch), retryable `failed` state, `ClearAll`
      on logout (cache files never outlive the session wipe).
- [ ] Thumbnails: decided to downsample on the macOS side (ImageIO) — no
      server decode; revisit if scroll perf demands it.
- [ ] Audio metadata (waveform) — later polish.

## M4 — Polish + performance verdict

- Search UX (chats/contacts/messages sections, ⏎ jump to context).
- Reliability drills: network flap, sleep/wake, sidecar kill -9 mid-sync, QR expiry.
- Full performance measurement vs budget; revise budgets with evidence if needed.
- Signed/notarized build pipeline (or documented ad-hoc for personal use).

Exit: v0.1 tagged. "Prove the core client is lightweight, reliable, enjoyable."

## M5 — v0.2 Work Productivity

Status: **largely shipped** — work inbox with conversation digests, work
groups, starred contacts, Done/Snooze (message- and chat-level, absolute
wake time), Mentions filter/view, Focus Mode, ⌘-first navigation.

Remaining: per-chat notification rules, media cache management UI,
inbox-zero flow refinements.

## Non-goals (unchanged)

Calls, video, screen share, Status, Channels, Communities UI, editors, payments, Meta AI, any AI
features, cloning WhatsApp Desktop/Web UI.
