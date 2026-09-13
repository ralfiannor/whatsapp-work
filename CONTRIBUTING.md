# Contributing

Thanks for considering it. This is a small, opinionated codebase —
read [AGENTS.md](AGENTS.md) first; it is the working agreement for humans
and agents alike and encodes decisions that are easy to get wrong.

## Ground rules

- **No automation, no bulk send, ever.** This is an unofficial client with
  an account-ban posture (docs/architecture.md §R1). Anything that sends
  without a human pressing a key will be rejected.
- **Privacy is an invariant.** Nothing that logs message content, tokens,
  or QR material. Your patch must not weaken the loopback-only IPC
  (Host allow-list + constant-time bearer compare).
- **Performance is a product requirement** (docs/performance.md). A change
  to a hot path ships with a before/after number (bench, EXPLAIN QUERY
  PLAN, or `ps` sampling). Claims without numbers get reverted.

## Prerequisites

- macOS 14.5+, Xcode 16.2, [xcodegen](https://github.com/yonaskolb/XcodeGen)
- Go 1.26+

## Build & verify

```bash
./scripts/build-core.sh                    # universal Go sidecar → dist/
cd apps/macos && xcodegen generate         # Xcode project is generated, not committed
xcodebuild -scheme WhatsAppWork -configuration Debug \
  -derivedDataPath build/DerivedData build
```

```bash
cd core
go build ./... && go vet ./...
go test ./...
go test -race ./internal/app ./internal/whatsapp ./internal/storage ./internal/ipc
WW_BENCH_N=150000 go test ./internal/storage -run XXX -bench . -benchmem
```

A change is not done until: Go tests + race green, the app builds, and —
for hot paths — a measurement.

## Code pointers

- Dependency direction is enforced by review: `storage` → `core` only;
  `whatsapp` is the ONLY package importing whatsmeow; `app` sits behind the
  narrow `WAClient` port; `ipc` → `app`.
- Wrap errors with context; match sentinels with `errors.Is`, never strings.
- SQLite: one writer + reader pool, keyset pagination, no `SELECT *`,
  migrations are append-only.
- Swift: `AppState` is the single `@MainActor` observable; no AppKit text
  views per transcript row; merge (never overwrite) after awaits.

See AGENTS.md for the full list, including the known sharp edges
(identity duality, sidecar lifecycle contract, media byte caps).

## Commits & PRs

Conventional commits, small and self-contained. Performance changes cite
numbers (before/after, method) in the description. Don't rewrite working
code for style, and don't introduce frameworks, Redis/Postgres/Electron,
or "temporary" full rescans.

## Reporting bugs

Open an issue with: macOS version, app build (`/healthz` reports the
version), what you expected, and what happened. Never paste message
content or contact numbers you are not comfortable making public —
JIDs and phone numbers redacted to a fictional pattern are plenty.
