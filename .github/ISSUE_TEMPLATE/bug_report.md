---
name: Bug report
about: Something does not work as documented
labels: bug
---

**What happened**

A clear description of the misbehavior. If it involves a specific message or
chat, REDACT contact names/numbers to a fictional pattern (e.g.
`254799000111@…`) — never paste real JIDs, phone numbers, or message content
you are not comfortable making public.

**What you expected**

**Steps to reproduce**

1.

**Environment**

- macOS version:
- App build (visible in the About path, or `curl /healthz` output's `version` if you run the sidecar standalone):
- Architecture: Intel / Apple Silicon
- Linked-account size (rough number of chats/messages helps reproduce perf issues):

**Logs**

`core.log` lives under `~/Library/Application Support/WhatsAppWork/` — it is
sanitized by design (no message content, tokens, or QR material). Attach the
lines around the problem's timestamp.
