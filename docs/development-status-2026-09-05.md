# Development continuation — 2026-09-05

Resumed the approved performance/IRC UX hardening from task `01a06b99-4bbd-7a21-b5ca-ab98bc7b51bb` in the same checkout. Repository HEAD is still unborn; no commit or push was made. Source snapshots, review reports, and test results were retained.

## Completed and reviewed

- Recovered and verified single-pass WebSocket decoder: 180.72 → 72.83 ms / 10,000 frames; lower peak memory.
- Batched background media eviction with explicit shutdown-before-storage ordering: 40.33 → 10.26 ms / 100 victims.
- Incremental sidecar bundling/signing: unchanged Debug rebuild 2.28 → 1.68 s; clean/source/sidecar-change signatures verified.
- Closed five state regressions: multiple-failure crossed echo retry loss; failed-negative-row cache eviction; equal-timestamp REST/WS merge loss; whole-window older-page sort; stale caption after A→B→A media completion.
- Paired older-page merge on 10,000 rows: 7.15–7.70 → 2.43–2.46 ms. This measures array assembly, not UI frames.

## Verification evidence

Runtime Go build/vet, 115 regular tests, 111 race tests, 150k storage benchmark, universal sidecar and standard Debug/Release builds passed. State-recovery wave passed 152 Debug tests plus 6 selected Release tests and strict Debug/Release signatures. Detailed exact methods and limitations: [performance.md](performance.md).

## In progress / acceptance gates

UI instrumentation is implemented, reviewed, and verified: 162/162 final Swift tests passed and the final Release artifact passed strict deep signature verification. Scheduling/view-update/onAppear signposts are explicitly labelled proxies, separate from actual presented-frame evidence. Appearance, adaptive panel, search/Inbox feedback and accessibility tasks have not begun in this continuation. The approved plan requires a pre-appearance UI baseline; logged-in interactive traces are not available yet. No UI performance-budget pass is claimed.

Manual clipboard/read/VoiceOver checks, real healthy-idle request counts, attachment Main Thread trace, and live frame/CPU/RSS metrics remain unverified. No live messages were automated.

## Recovery records

- `.superpowers/sdd/2026-09-04-runtime-performance-hardening/progress.md` and reports retain all execution decisions and evidence.
- `.superpowers/sdd/2026-09-04-irc-ux-accessibility/progress.md` identifies the next step and baseline gate.
- Old reproducible Build/ModuleCache artifacts were pruned to resolve disk-full signing failures; source and retained test-result/snapshot evidence were preserved.

## Ready for the baseline

Release artifact: `apps/macos/build/DerivedData-release/Build/Products/Release/WhatsApp Work.app`.

[Manual capture instructions](performance.md#exact-manual-capture-handoff) cover the owner-run baseline. The next implementation tasks are appearance preferences, adaptive member panel, search/Inbox feedback, accessibility, and final UI comparison.

The approved UX plan states: “This baseline must exist before Task 1 changes appearance or spacing.” The current session has no recorded live interaction trace; capture is the next required input, not another design approval.

## Separate-session testing decision

The user confirmed that manual testing will run in a separate session. The [testing handoff document](manual-validation-2026-09-05.md) records the build identity, checklist, result format, automated evidence, and next work. Manual status remains PENDING/NOT MEASURED; no direct testing request is pending in this session. The pre-visual-change baseline gate still applies.
