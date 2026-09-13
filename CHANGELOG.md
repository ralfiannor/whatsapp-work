# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
The IPC contract may break until 1.0 — `/healthz` reports the running version.

## [Unreleased]

### Planned

- Appearance preferences (themes, typography) and adaptive member panel.
- Accessibility pass (VoiceOver, contrast) and the pending manual
  validation checklist.
- UI performance baseline on a live account (Instruments: cold start,
  chat switch, scroll) — the gate before further visual changes.
- Mute / pin / archive wiring (columns exist, no UI yet).
- Signed & notarized builds (until then, releases are ad-hoc signed;
  see each release's install notes).
- Per-chat notification rules, media cache management UI, inbox-zero
  refinements, audio waveform thumbnails.

## [0.1.0] - 2026-09-13

First public release. Native macOS work-inbox client for WhatsApp:
SwiftUI app + Go sidecar (whatsmeow linked-device protocol) +
SQLite/FTS5, loopback HTTP+WS IPC with a bearer-token stdout handshake.

### Added

- **Login & sync** — QR linked-device login with rotation, full history
  sync into SQLite (keyset pagination, FTS5, idempotent ingest),
  automatic reconnect (including first-dial retry before the network is
  up), logout with local wipe.
- **Messaging** — live send / reply / react with delivery receipts,
  optimistic sends with in-place retry, live reaction updates, edit and
  revoke handling, forwarded markers.
- **Mentions** — `@` autocomplete composition, incoming mention
  resolution and highlight, unread-mentions filter (⌘3); mention wire
  form and echo reconciliation across PN/LID identity forms.
- **Groups** — participant sync, member panel with admin marks and
  click-to-mention, profiles, renames; mIRC-style transcript with
  per-nick stable colors.
- **Search (⌘K)** — FTS5 across messages + chat/contact names, deep-link
  open with anchor scroll.
- **Work inbox (⌘4)** — conversation digests, per-message and per-chat
  Done / Snooze (absolute wake time), realtime `inbox.changed` updates,
  starred work contacts, work groups, Focus Mode (⌘⇧F).
- **Media** — on-demand downloads with a byte-capped transport, bounded
  LRU disk cache (500 MB default), retry, open-external.
- **Notifications** — native macOS notifications with click-through,
  Focus-aware, Dock unread badge.
- **Chat list** — keyset pagination with load-more beyond the first
  199-chat page.

### Security

- Loopback-only IPC: Host allow-list (DNS-rebinding safe), constant-time
  bearer comparison, 5 s read-header timeout.
- Owner-only data directory: umask 077 sidecar-wide, databases and WAL
  sidecars pinned to 0600 and tightened at startup.
- Remote-input hardening: rune-safe length clamps on text, previews,
  mention lists and media IDs; sender-stamped timestamps clamped to a
  sane window; empty-user JIDs rejected; media downloads cut at the
  transport before buffering (FileLength is attacker-supplied).
- Nothing logs message content, tokens, or QR material; session
  credentials live only in `session.db`.

### Performance

- Single-pass WebSocket decoder, keyset queries everywhere, sidecar
  ~38 MB RSS on a 500k-message account (see
  [docs/performance-audit-2026-08.md](docs/performance-audit-2026-08.md)).
- Inbox query driven from the pending-state set with a partial index
  (0.8 ms with an empty queue at 20k-message scale, was a full-table
  scan); row-lookup on the ingest path at 29 µs (was 16.5 ms in large
  chats); LID-merge FTS sync via rowid subquery (161 µs, was a 537 ms
  FTS scan).

### Fixed (pre-release audits)

Three audit rounds before publication — correctness, protocol-contract
drift, SQL/performance, lifecycle state machines, adversarial input —
42+ findings, all fixed with regression tests. Highlights:

- JSON `null` arrays no longer drop whole API responses (search/chats/
  messages/contacts on empty results).
- PN/LID identity duality handled on every jid-keyed path: revokes,
  receipts, reactions, own-reaction toggles, mention echo
  reconciliation, chat folding with flag carry-over.
- QR exhaustion, first-dial failure, and outdated-client/temporary-ban
  device states no longer strand the login screen.
- Sidecar crash-restart and WS seq-gap both refetch the open transcript;
  logout failures surface instead of pretending success.
- Unread counters: revoke decrements are idempotent across history
  replays; out-of-order read receipts cannot hide newer unread traffic.

[Unreleased]: https://github.com/ralfiannor/whatsapp-work/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ralfiannor/whatsapp-work/releases/tag/v0.1.0
