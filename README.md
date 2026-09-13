# WhatsApp Work

Fast, native, keyboard-first **work inbox powered by WhatsApp** — for people
who live in WhatsApp for work and are tired of heavy Electron clients.

Native macOS app (Swift/SwiftUI). Go sidecar with
[whatsmeow](https://github.com/tulir/whatsmeow) as a linked device.
SQLite + FTS5 local storage: instant search, keyset pagination,
offline-first. No Electron, no WebView, no Chromium.

> [!WARNING]
> **Unofficial client.** whatsmeow is not endorsed by Meta. Using unofficial
> clients violates WhatsApp's Terms of Service and carries a real risk of
> account bans. Use a number you accept that risk for. No automation or bulk
> sending is built, on purpose. See [docs/architecture.md](docs/architecture.md) §R1.
>
> WhatsApp is a trademark of Meta Platforms, Inc. This project is not
> affiliated with, endorsed by, or connected to Meta or WhatsApp.

## Features

- **QR linked-device login** — scan once, reconnects automatically
- **Full local history** — initial sync lands in SQLite (hundreds of
  thousands of messages); everything works offline-first
- **Instant search (⌘K)** — SQLite FTS5 over all messages + chats + contacts
- **@mentions, done right** — type `@` for live member autocomplete, tap a
  nick to mention, incoming mentions resolve to real names and highlight
- **mIRC-style groups** — weechat-like transcript with a sortable member
  panel (hideable), per-nick stable colors, click any nick for a full
  profile (photo, phone + LID, role)
- **Optimistic sending** — bubbles appear instantly (`…` → `✓` → `✓✓`),
  failed sends retry in place
- **Work inbox (⌘4)** — mentions, direct messages and work-group traffic
  grouped as a local work queue: items leave only when you mark them done or
  snooze them (reading a chat keeps them); Focus Mode silences everything
  except work-marked chats
- **Media on demand** — nothing downloads eagerly; images and stickers
  render as downsampled previews from a bounded LRU cache (500 MB disk)
- **Light** — idle ≈ 0% CPU, sidecar ~38 MB RSS on a 500k-message account
  ([measured](docs/performance-audit-2026-08.md))

## Requirements

- macOS 14.5+
- Xcode 16.2 + [xcodegen](https://github.com/yonaskolb/XcodeGen)
- Go 1.26+

## Build & run

```bash
git clone <repo> && cd whatsapp-work
./scripts/build-core.sh                  # universal Go sidecar → dist/
cd apps/macos
xcodegen generate                        # once, and after project.yml edits
xcodebuild -scheme WhatsAppWork -configuration Debug \
  -derivedDataPath build/DerivedData build
open "build/DerivedData/Build/Products/Debug/WhatsApp Work.app"
```

The post-build phase bundles and signs `dist/whatsapp-core` into the app.
First launch: scan the QR with WhatsApp → Settings → Linked Devices.

Run the core standalone (CLI smoke test, no app):

```bash
cd core
go run ./cmd/whatsapp-core --data-dir ./data
# → READY {"port":…,"token":…} on stdout; QR in the terminal after POST /session/link
./scripts/smoke.sh          # full scripted smoke (CONNECT=1 for a logged-in run)
```

## Keyboard map

| Key | Action |
|---|---|
| `⌘K` | Search (messages, chats, contacts) |
| `⌘V` | Paste image from clipboard into the composer (attach + caption) |
| `⌘J` | Jump to next unread chat |
| `⌘1`/`⌘2`/`⌘3` | Filter: all / unread / mentions |
| `⌘4` | Work inbox |
| `⌘⇧F` | Focus Mode toggle |
| `↩` / `⇥` | Accept first mention suggestion / send |

## Architecture

```text
SwiftUI macOS app
        │  HTTP + WebSocket over 127.0.0.1 (random port, bearer token via
        │  stdout READY handshake — never on disk)
        ▼
Go sidecar ── whatsmeow ──▶ WhatsApp (linked device)
        ├── SQLite (app.db: WAL, keyset pagination, FTS5 via triggers)
        ├── SQLite (session.db: whatsmeow store, isolated credentials)
        └── media: on-demand downloads, bounded LRU disk cache
```

Deep dives: [architecture](docs/architecture.md) ·
[IPC protocol](docs/protocol.md) ·
[schema](docs/schema.md) ·
[performance budgets & audit](docs/performance.md)

## Development

```bash
cd core
make test          # go test ./...
make race          # -race
WW_BENCH_N=150000 make bench   # 150k-fixture benchmarks

./scripts/make-icon.sh [src.png]   # regenerate the app icon
```

Working agreements, invariants and gotchas live in
[AGENTS.md](AGENTS.md) — read it before your first PR.

## Status & roadmap

Early (0.x), daily-driven on a real account. The IPC contract may break
until 1.0 — `/healthz` reports the version. Full milestone detail:
[docs/roadmap.md](docs/roadmap.md) · audit:
[docs/feature-audit-2026-08-30.md](docs/feature-audit-2026-08-30.md).

### Working today

- **Login & sync** — QR linked-device login, full history sync into SQLite
  (keyset pagination, FTS5, idempotent ingest), automatic reconnect,
  logout with local wipe
- **Messaging** — live send / reply / react with receipts, optimistic
  sends with in-place retry, live reaction updates, edits / revokes /
  forwarded markers
- **Mentions** — `@` autocomplete composition, incoming mention
  resolution + highlight, unread-mentions filter (⌘3)
- **Groups** — participant sync, member panel with admin marks and
  click-to-mention, profiles, renames
- **Search (⌘K)** — FTS5 across messages + chat/contact names, deep-link
  open with anchor scroll
- **Work inbox (⌘4)** — conversation digests, per-message and per-chat
  Done / Snooze (absolute wake time), realtime `inbox.changed` updates,
  starred work contacts, work groups, Focus Mode (⌘⇧F)
- **Media** — on-demand downloads, downsampled previews, bounded LRU
  disk cache (500 MB default), retry, open-external
- **Notifications** — native macOS notifications, click-through opens the
  conversation, Focus-aware, Dock unread badge
- **Performance** — single-pass WS decode, keyset queries everywhere,
  sidecar ~38 MB RSS on a 500k-message account
  ([measured](docs/performance-audit-2026-08.md))

### Next up

- Appearance preferences (themes, typography) and adaptive member panel
- Accessibility pass (VoiceOver, contrast) + the pending manual
  validation checklist
- UI performance baseline on a live account (Instruments: cold start,
  chat switch, scroll) — the gate before further visual changes
- Mute / pin / archive wiring (columns exist, no UI yet)
- Signed & notarized release builds (currently ad-hoc)

### Later (v0.2 track)

- Per-chat notification rules, media cache management UI, inbox-zero
  refinements, audio waveform thumbnails

### Non-goals

Calls, video, screen share, Status, Channels, Communities, payments,
Meta AI, any AI features, cloning the WhatsApp Desktop/Web UI — and, on
principle, no automation or bulk sending.

## Contributing

PRs welcome: small, self-contained, conventional commits. Performance
changes must cite before/after numbers. Start with
[AGENTS.md](AGENTS.md) and the docs in `docs/`. By participating you
agree to uphold the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE) © Rizal Alfiannor. WhatsApp is a trademark of Meta
Platforms, Inc.; this project is not affiliated with Meta.
