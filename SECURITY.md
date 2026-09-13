# Security policy

## Reporting a vulnerability

Use GitHub's **private vulnerability reporting** (Security tab →
"Report a vulnerability"). Please do not open a public issue for
anything exploitable. Include reproduction steps and, where relevant,
which component is affected (Swift shell, Go sidecar, IPC, storage).

## Trust model

- The app is a **local, single-user client**. There is no server side
  run by this project: the Go sidecar listens on 127.0.0.1 only, on a
  random port, with a bearer token handed to the app via a stdout
  handshake — never written to disk.
- Message history and whatsmeow session credentials live in SQLite under
  the user's `~/Library/Application Support/WhatsAppWork/`. They are not
  encrypted at rest by this app; device-level FileVault is the boundary.
  The data directory, databases, WAL sidecars, and media cache are created
  owner-only (0700/0600) and tightened on startup, so other local
  accounts cannot read them — but anyone with disk access has the data.

## Invariants reviewers should hold

- IPC auth middleware (Host allow-list + constant-time bearer compare)
  wraps every endpoint; new endpoints go on the existing mux.
- Nothing logs message content, bearer tokens, or QR material.
- Downloaded media is re-checked against the byte cap using actual
  received bytes — the protobuf's FileLength is attacker-supplied.
- FTS user input goes through quoted-term building; LIKE patterns are
  escaped.
- No automation or bulk sending exists in the client, and contributions
  adding any will be rejected (docs/architecture.md §R1).

## Scope

In scope: this repository's code and its build scripts. Out of scope:
vulnerabilities in WhatsApp's servers, in whatsmeow itself (report those
upstream), and phishing/spam delivered over WhatsApp.
