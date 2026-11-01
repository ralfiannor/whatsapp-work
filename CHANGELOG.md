# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
The IPC contract may break until 1.0 — `/healthz` reports the running version.

## [Unreleased]

### Fixed

- wa.me "Continue to Chat" links open the chat in the existing window.
  Each link used to open a second window, which also set up the app's
  connection watchers and update checks a second time.
- A `+` in a wa.me link's `text=` prefill becomes a space
  (`text=hello+world` → "hello world"); `%2B` stays a literal plus.

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

## [0.3.0] - 2026-10-31

### Added

- Local notes: a Notes row pinned at the top of the chat list opens a
  list of Markdown notes (headings, lists, checklists, quotes, code,
  tables, inline styles) with edit and preview modes (`⌘5`, `⌥⌘N`,
  `⇧⌘P`). Notes are stored only on this Mac in
  `Application Support/WhatsAppWork/Notes/notes.json` (folder `0700`,
  file `0600`), written by the app alone. The core never receives them
  and logout does not delete them.

### Changed

- Go dependencies updated, including whatsmeow (2026-10-30) and
  modernc.org/sqlite 1.61.0.
- CI builds and tests the core (vet, tests, race) and the app (build and
  unit tests) on every pull request and push to `main`. Releases are
  still signed and published by hand.

### Fixed

- Group messages that fail to decrypt (for example "no sender key
  state") no longer vanish. They show as "Waiting for this message"
  (or "View once message (open it on your phone)"), the core asks your
  phone for a copy when the sender does not re-send within 5 s, and the
  row upgrades in place when the real message arrives.
- The core reports the app's version (READY line, `/healthz`,
  `-version`). In 0.2.0 it still said 0.1.0, because the version was
  hardcoded. `scripts/build-core.sh` now stamps it from `project.yml`,
  and `release.sh` refuses to sign a build whose bundled core disagrees.

## [0.2.0] - 2026-10-31

**Install this release by hand once** if you run 0.1.0, which has no
updater. From 0.2.0 on, the app updates itself.

### Added

- In-app updates from GitHub Releases. The app checks at launch, every
  12 h, or via WhatsApp Work ▸ Check for Updates…. It installs a newer
  release only if its DMG verifies against the maintainer's Ed25519
  release key. The install happens at quit or on "Restart", as an atomic
  bundle swap. `scripts/release.sh` builds, packages and signs a
  release; see docs/releasing.md.
- Send several images or files in one go. You can multi-select, paste,
  or drop them on the chat or the composer. Files go out one at a time
  (never in parallel, at most 30), and the draft is the first file's
  caption. The batch stops at the first failure, and unsent files stay
  staged.
- wa.me and api.whatsapp.com links open in the app with their text
  prefilled, including links clicked inside a transcript (Account ▸ Set
  as wa.me Link Handler).
- Delete your own messages for everyone, with a confirmation step.
- Optional DM read-receipt suppression: chats are marked read locally
  without telling the sender.
- Resolved @mentions are coloured in the composer, so what you see is
  what is sent.
- A Save button in the image preview.

### Changed

- Enter sends; ⌘/⌥ Enter inserts a newline. The composer grows with its
  text, and ⌘A selects all of it.
- ⌘K search:
  - fixed-height results;
  - an esc button for mouse users;
  - distinct "failed", "no results" and hint states;
  - the ↑/↓ selection stays in view.
- Log Out (which wipes local history) now asks first.
- Keyboard:
  - the snooze panel's H/T/W keys and the reaction panel's 1–4 keys work
    as displayed;
  - "Later today" (which meant one hour) is now "In 1 hour".
- Accessibility:
  - icon-only buttons are labelled;
  - chat and inbox rows read as one element with their state;
  - informative text has higher contrast;
  - scroll animations respect Reduce Motion.

### Fixed

- Scrolling up through history no longer gets stuck, and the reading
  position holds while an older page loads.
- Failures that used to be silent are now shown:
  - a core that failed or was stopped from outside the app gets a
    banner with Restart;
  - an inbox that fails to load shows Try Again;
  - reactions and star / work-group toggles report errors.
- Mentions: multi-word labels arrived corrupted on receivers, and token
  digits now match the wire form.
- The unread badge clears when a chat opens via the list selection.
- A wa.me prefill now reaches a composer that is already open.
- Running the unit tests no longer starts a real core, which used to
  stop the core of a running copy of the app.

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

[Unreleased]: https://github.com/ralfiannor/whatsapp-work/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/ralfiannor/whatsapp-work/releases/tag/v0.3.0
[0.2.0]: https://github.com/ralfiannor/whatsapp-work/releases/tag/v0.2.0
[0.1.0]: https://github.com/ralfiannor/whatsapp-work/releases/tag/v0.1.0
