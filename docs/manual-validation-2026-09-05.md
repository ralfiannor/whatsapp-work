# Manual validation handoff — 2026-09-05

Status: **PENDING — the owner will run the manual validation in a separate
session**. The decision was recorded in continuation session
`01a06ee0-ec7e-7303-8682-ef45aad46793`. No manual result is counted as PASS
before it is actually run.

## Start here

1. Read the [development status](development-status-2026-09-05.md) and use
   the Release build identified below.
2. Record environment versions, build hashes, and evidence locations. If
   the build changes, record the new hash; never mix results across builds.
3. Run the functional checklist and the
   [performance capture](performance.md#exact-manual-capture-handoff).
   Fill results into this document.
4. Store traces/CSVs in a local capture folder. Do not put message content,
   numbers/JIDs, tokens, or QR material into any shared report.
5. Once results exist, continue tasks with this document as the reference.
   The pre-visual-change baseline is still required; postponing the testing
   is not approval to skip that gate.

## Handoff build identity

- App: `apps/macos/build/DerivedData-release/Build/Products/Release/WhatsApp Work.app`
  (also installed at `/Applications/WhatsApp Work.app`)
- App executable: `Contents/MacOS/WhatsAppWork`
- App executable SHA-256: `645311c594dc015fab73d89f0fcf32975e18e45b3ac08d170d3ac5392d4d0d86`
- Sidecar: `Contents/MacOS/whatsapp-core`
- Sidecar SHA-256: `f338c4e3906922d31dd427a9e70fccc5fec57faa10439188637e0d767eec5225`
- App and sidecar are universal `x86_64`/`arm64`; Release uses the hardened
  runtime and passes `codesign --verify --deep --strict`.

Update 2026-09-05 (intermittent chat-click fix): `AppState.openChatRow` +
row-tap wiring in ChatListView. App executable hash changed from
`5b7d5062…` to `645311c5…`; sidecar hash unchanged (no Go changes). Swift
suite 165/165. Manual checklist results recorded against the old hash do
not apply to this build.

Update 2026-09-05 (history paging on scroll-up fix): macOS `List` never
fires the top-sentinel `onAppear` when the viewport reaches the top
(verified live on an instrumented build — zero logs across the chain), so
older message pages were never requested. Fix: new `TopPagingMonitor`
trigger (NSViewRepresentable observing NSClipView offset; a false→true
"at top" transition fires one fetch), decision merged in
`AutomaticTopPagingDecision` (the policy that now also serves
unread-heavy chats — the old nil-row-boundary pause made a
68/258-unread group unable to load history via scroll at all); the
"Load Earlier" button stays. The dead sentinel was removed. TDD: +6
policy tests (`InteractionPoliciesTests`), suite 170/170. Live Debug-build
verification: a quiet 6,353-message chat chained pages Aug 25→24→23; an
active 68-unread group loaded page 2 (18.5x rows) without a chain-run.
New app executable hash `3a8ab68c…709b6e`; sidecar unchanged at
`f338c4e3…` (no Go changes).

Update 2026-09-06 (DM + chaining fix): the owner report "groups work, DMs
don't" reproduced — DMs never reached offset ≤2pt (DM layout has no nick
column), and after one page loaded, the offset stayed pinned at the top so
no bounds-change fired the next page ("only reaches Sep 3" + hanging
spinner). Fix: `TopPagingThreshold` = 25% of viewport height (preload
before hitting the top, +2 tests) and deterministic re-anchoring by the
probe — `NSClipView.scroll(to:)` to the equivalent offset as document
height grows, replacing the unreliable `proxy.scrollTo`. Suite 172/172.
Live verification: a 5,195-message DM chained pages Sep 3→2→1 via wheel
and keyboard; groups still worked. New app executable hash
`563c0e4a…8ba14a`; sidecar still `f338c4e3…`.

Builds are reproducible artifacts, not permanent archives. If replaced or
lost, follow the build instructions in AGENTS.md, repeat the signature
verification, and record the new build identity.

## Automated evidence already available

- Final Swift Debug: **162 passed, 0 failed, 0 skipped**.
- Final Release build and signature: **PASS**.
- Go build/vet: **PASS**; 115 regular tests and 111 race tests: **PASS**
  at the latest Go revision, which did not change during Swift
  instrumentation.
- Storage 150k benchmark, decoder, eviction, rebuild, and merge numbers:
  full methods in [performance.md](performance.md).
- Final Swift xcresult:
  `apps/macos/build/DerivedData/Logs/Test/Test-WhatsAppWork-2026.09.05_08-42-48-+0700.xcresult`.
- Implementation/review detail: `.superpowers/sdd/2026-09-04-runtime-performance-hardening/`
  and `.superpowers/sdd/2026-09-04-irc-ux-accessibility/`.

The `.superpowers` folder is gitignored. Do not delete it before the
required evidence is archived; the repo still has no initial commit, so
those snapshots are the recovery record.

## Manual results from the 2026-09-05 session (build `645311c5…`)

The owner ran the app from `/Applications` (build containing the
intermittent chat-click fix: `AppState.openChatRow` + row-tap wiring) and
reported everything working — no chat click failed to open a transcript.
This is an informal owner report; the per-item F1–F10 matrix below and the
numeric performance baseline are still unfilled, so nothing is marked
PASS in the tables.

Task 0 baseline session (2026-09-05, afternoon): the agent ran the
performance capture — cold start ×3, chat switch ×22 clicks (20 valid
proxy intervals), typing 30 s (draft discarded, nothing sent; no dialogs
left over; chat list intact), idle `ps` 2×300 samples. Clicks were
performed by the agent via coordinates (no message scripting; the
no-bulk-send rule was respected). Two operational traps recorded in
[performance.md §capture log](performance.md): the `ps` `comm` column
must be last (truncation → false empty samples), and the xctrace CLI has
no combined CPU+signpost template (2 parallel recorders used). Result
numbers are in the baseline table below; headline finding: chat-switch
proxy p95 2.31 s (~23× budget) — the optimization target for the
following tasks.

## Test environment (fill when running)

| Field | Value |
|---|---|
| Date / test session | 2026-09-05, Task 0 baseline session (cold start, chat switch, typing, idle) |
| Mac model / CPU / RAM | MacBook Pro 2018 · Intel i5-8259U @ 2.30 GHz (`environment.txt` in the capture folder) |
| macOS / Xcode / Instruments | macOS 14.8.9 (23J631) · Xcode 16.2 (16C5032a) · xctrace 16.0 |
| App / sidecar executable hash | app `645311c5…d4d0d86` · sidecar `f338c4e3…eec5225` (same as the chat-click-fix build) |
| Window / screen size / scaling | 1287×703 pt on Retina 2560×1600 (Intel Iris Plus 655) |
| Density / font size / filter | 337 chats, All filter, default font size |
| Sync / connection / power state | Connected, account actively receiving live traffic; full re-sync finished before the 2nd idle pass |
| Trace / CSV evidence folder | `~/Desktop/WhatsAppWork-Task0-Baseline/` (artifact list in [performance.md §capture log](performance.md)) |

## Functional checklist

Fill results with PASS, FAIL, or NOT TESTED, with evidence or reasoning.
Message sending only through manual user action on self-chosen test
conversations; no bulk-send, no message scripting.

| ID | Scenario and expected result | Result | Evidence / notes |
|---|---|---|---|
| F1 | Select part of transcript text then Cmd-C; the paste is exactly the selection. Repeat copy/cut in the composer. | NOT TESTED | |
| F2 | Pasting text into composer/search still works; pasting an image/file into the composer prepares an attachment. | NOT TESTED | |
| F3 | J/K and arrows only preview; Enter, click, or focusing transcript/composer marks read as the explicit action. | NOT TESTED | |
| F4 | Reply/draft of A still belongs to A after switching to B and back; sending from A does not use B's context. | NOT TESTED | |
| F5 | Upload media in A, switch B then A without editing: successfully deletes the sent caption. Replacement draft/attachment is not deleted. | NOT TESTED | |
| F6 | A failed send keeps its text and Retry after browsing >10 chats; a successful retry does not duplicate the message. Complex echo-order cases are already covered by automated tests. | NOT TESTED | |
| F7 | Unread spanning more than one page shows an honest marker; Load Earlier fetches one page, not the whole history automatically. | NOT TESTED | |
| F8 | Fast A-B-A navigation, reconnects, and failed fetches must not lose cached context/member data or hang the UI. | NOT TESTED | |
| F9 | QR/idle must not block sleep; the power assertion runs only during sync and is capped at 10 minutes. | NOT TESTED | |
| F10 | An attachment near 19 MiB does no file reading on the Main Thread; the 20 MiB limit is still enforced. | NOT TESTED | |

## Performance baseline and acceptance limits

Use the steps, sample counts, signpost names, and p50/p95 method from the
[capture instructions](performance.md#exact-manual-capture-handoff). The
run-loop/view-update/onAppear signposts are **proxies**, not proof of
presented frames; record their distributions separately from Instruments
presentation evidence.

| Measurement | Result / sample count | Evidence | Verdict |
|---|---|---|---|
| Cold start to first frame | NOT MEASURED — 3 traces recorded, presentation analysis pending | `01a/01b/01c-app-launch.trace` | PENDING (needs Instruments inspection) |
| Chat switch: proxy and presented-frame p50/p95 separately | proxy n=20: p50 1230 ms / p95 2310 ms; presented-frame NOT MEASURED | `02-chat-switch.trace` + `02-chat-switch-signposts.trace` → `07-signpost-durations.csv` | PROXY FAIL vs 100 ms budget (Task 0 baseline data — precisely the optimization target); presented-frame PENDING |
| Incoming / optimistic send: proxy and presented-frame separately | incoming n=2 (incidental, not valid); send n=0 (not automated, per the rules) | `02-chat-switch-signposts.trace` | PENDING a user-driven session |
| Typing 30 s / 10k-message chat scroll | typing 30 s recorded (draft discarded, not sent); 10k scroll NOT MEASURED (no verified 10k chat yet) | `04-typing.trace` | typing PENDING analysis; scroll NOT MEASURED |
| Idle CPU/RSS 5 min, app/core/combined | settled pass: app 4.78% avg / 62.6 MB · core 4.28% avg / 58.1 MB · combined 120.6 MB | `06-idle-ps-pass2.txt` (+ pass-1 `06-idle-ps.txt` containing the re-sync burst) | RSS PASS (core<60, app<90, combined<150); CPU MEASURED-OVER the ≤1% budget with a live-traffic caveat — needs a `powermetrics` re-measure |
| Healthy-WS fallback HTTP request count | NOT MEASURED | | PENDING |
| Attachment Main Thread trace | NOT MEASURED | | PENDING |

Full budgets live in [performance.md](performance.md#budgets). Missing
data is not a PASS; do not replace live metrics with unit tests or
microbenchmarks.

## Next work

Appearance preferences, the adaptive member panel, search/Inbox feedback,
and accessibility improvements are not implemented in this continuation.
VoiceOver/visual acceptance for those features runs after their
implementation, then the same baseline scenarios are repeated for
comparison. Plan:
`docs/superpowers/plans/2026-09-04-irc-ux-accessibility.md`.

## Bug report format

- Checklist ID, date, build hash, and environment.
- Short reproduction steps; expected vs actual.
- Frequency and the connection/sync conditions.
- Location of the sanitized traces/logs.
- Follow-up status and re-verification.
