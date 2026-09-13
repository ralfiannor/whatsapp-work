# Performance Budget & Measurement Plan

Performance is a product requirement, not an afterthought. Budgets below are **targets to verify**;
each metric has a defined measurement method. Results are recorded in this file per milestone under
"Measured". Numbers that don't hold get a written explanation and a revised, measured target — not a
silent miss.

Environment of record: MacBook Pro 2018 (Intel), macOS 14, AC power, no other load.

## Budgets

| Metric | Target | Method |
|---|---|---|
| Core ready (sidecar → READY line) | < 200 ms | `log stream`/signpost: process exec → stdout READY. `launch_time` metric in `/healthz` later. |
| App cold start → first useful frame | < 1.0 s | Instruments App Launch template and its validated presentation evidence. The chat-list run-loop signpost is correlation only. (Realistic on Intel: SwiftUI init alone is 300–600 ms; budget includes sidecar spawn overlap — core starts before first frame.) |
| Idle CPU (both processes) | ≤ 1% avg over 5 min, no wakeups > 5/s sustained | Activity Monitor sample + `powermetrics` 5-min capture; Go side: `go tool pprof` goroutine/wakeup audit. No polling anywhere; WS heartbeat is 1 frame/25 s. |
| Idle memory (RSS, both) | core < 60 MB · app < 90 MB · combined < 150 MB | `footprint`/Activity Monitor after 10 min idle post-sync. Knobs: `GOMEMLIMIT=64MiB`, SQLite `cache_size=-16000`, no decoded images cached. |
| Working-set memory | < 250 MB combined | Footprint during 30 min of active chat use with images. |
| Chat switch | < 100 ms p95 perceived | Instruments presentation evidence: chat select → first compositor-presented frame containing the selected page. The signpost records fetch/merge plus a queued SwiftUI view-update proxy separately. |
| Local search (FTS, 150k msgs) | < 100 ms p95 | `go test -bench` with synthetic 150k-message fixture (`storage` bench); later UI-side signpost. |
| Message render (incoming → visible) | < 50 ms | Instruments presentation evidence from incoming event to first compositor-presented frame containing the row. The row `onAppear` signpost is a scheduling proxy. |
| Typing latency | imperceptible (< 16 ms/frame) | Composer state isolated from transcript; Instruments Time Profiler while typing. |
| Scrolling | no dropped frames sustained | Instruments Core Animation FPS trace on 10k-message transcript. |

## Instrumentation

- **Go core**: request-duration logs at debug level; `/healthz` counters (ingest count/errors,
  dropped events); `runtime/metrics` RSS sampled on demand. pprof endpoints behind `--pprof` flag
  (off by default, never in production builds).
- **SQLite**: `EXPLAIN QUERY PLAN` review for every repo query (part of code review checklist);
  occasional `.eqp on` + `timer on` profiling sessions in `sqlite3` CLI against a copy of real data.
- **Swift**: signposts (`os_signpost`) around app lifecycle, chat switch, page fetch,
  state/view-update scheduling proxies, row `onAppear` proxies, and sync refresh.
  Animation Hitches/Core Animation and App Launch remain authoritative for
  compositor-presented frames.
- **Fixtures**: `storage` tests generate 150k-message synthetic DB for benches — reproducible
  (`-bench . -benchtime`), no real data needed.

## Tracking list (fill per milestone)

```text
startup time            : M1 core numbers below ✓ · M2 app verdict
RSS memory idle/work     : M1 core idle below ✓ · M2 combined
CPU idle                 : M2
chat switching latency   : M1 storage share below ✓ · M2 UI verdict
search latency           : M1 ✓ (bench, below)
message render time      : M2
db query latency         : M1 ✓ (bench, below)
```

## Measured — 2026-09-04 pre-UX hardening

Status: **LIVE BASELINE NOT MEASURED**. The signed instrumented Release app is
prepared at
`apps/macos/build/DerivedData-release/Build/Products/Release/WhatsApp Work.app`,
but this session did not have the logged-in user activity required for an
honest interactive baseline. Appearance and spacing work remains gated on the
manual capture below.

The `UI Performance` signpost category exposes these data-safe intervals:
`AppState Init to Loaded Chat-List Run-Loop Proxy`,
`Chat Switch to Selected Page View-Update Proxy`,
`Incoming Insert to Row onAppear Proxy`, `Send Insert to Row onAppear Proxy`,
`Message Page Fetch Decode Merge`, and `Sync Refresh`. It also emits the point
event `Loaded Chat-List Run-Loop Proxy`. Signposts contain only fixed names,
opaque interval IDs, and completed/cancelled/failed outcomes; they contain no
message text, JIDs, account identifiers, QR material, or bearer tokens.

The first interval starts in `AppState.init`, after the OS has started the
process. Its endpoint is a queued main-run-loop callback after the loaded chat
list reaches SwiftUI. The chat-switch endpoint is likewise a queued view-update
callback after the accepted selected page reaches `MessageList`, while the row
endpoints are SwiftUI `onAppear` callbacks. These are useful pipeline proxies;
none proves that Core Animation presented a frame. Keep proxy distributions
separate from actual cold-start and visible-latency results. Obtain those
budget results from the App Launch, Animation Hitches, or Core Animation trace's
validated presentation evidence.

| Live metric | Required sample | p50 | p95 | Status |
|---|---:|---:|---:|---|
| Process start → first presented chat-list frame | cold launches | NOT MEASURED | NOT MEASURED | App Launch presentation evidence pending |
| AppState init → loaded chat-list run-loop proxy | cold launches | NOT MEASURED | NOT MEASURED | signpost correlation pending; not cold start |
| Chat switch → selected-page view-update proxy | ≥20 completed intervals | 1230 ms (n=20) | 2310 ms | MEASURED 2026-09-05 proxy-only; far over the 100 ms budget — see capture log below; presentation evidence still pending |
| Chat switch → selected page presented | ≥20 validated frames | NOT MEASURED | NOT MEASURED | Instruments presentation evidence pending |
| Incoming insert → row `onAppear` proxy | ≥20 completed intervals | NOT MEASURED | NOT MEASURED | 2 incidental samples only (live traffic); needs a user-driven session |
| Incoming event → row presented | ≥20 validated frames | NOT MEASURED | NOT MEASURED | Instruments presentation evidence pending |
| Send insert → row `onAppear` proxy | ≥20 completed intervals | NOT MEASURED | NOT MEASURED | user-driven sends pending; do not automate |
| Send action → optimistic row presented | ≥20 validated frames | NOT MEASURED | NOT MEASURED | Instruments presentation evidence pending; do not automate |
| Message page fetch/decode/merge | capture with switch/scroll workload | 352 ms (n=28) | 1633 ms | MEASURED 2026-09-05 with chat-switch workload |
| Coalesced sync refresh | capture through post-sync idle | NOT MEASURED | NOT MEASURED | logged-in sync pending |
| Typing in busy 200-row transcript | 30 seconds | NOT MEASURED | NOT MEASURED | `04-typing.trace` captured 2026-09-05 (30 s draft, discarded); hitch/CPU summary pending Instruments inspection |
| 10k-message chat scrolling | sustained manual scroll | NOT MEASURED | NOT MEASURED | Animation Hitches/Core Animation pending |
| Connected post-sync idle CPU/RSS | 5 minutes | see capture log | see capture log | MEASURED 2026-09-05, settled 5-min pass: app avg 4.8% / 62.6 MB, core avg 4.3% / 58.1 MB — CPU over the ≤1% budget (live account traffic; wakeups need pprof/powermetrics follow-up), RSS within budget |

### Exact manual capture handoff

Owner decision (2026-09-05): manual testing will run in a separate session.
Use [the validation handoff](manual-validation-2026-09-05.md) for build identity,
checklists, and result recording. All live cells remain NOT MEASURED until captured.

Use the Release app above on the 2018-class Intel target, on AC power, with a
fixed window size, filter, transcript density, text size, and representative
chat set. Create a capture folder outside the repository, for example
`~/Desktop/WhatsAppWork-Task0-Baseline`, and preserve every `.trace` plus the
derived CSV there.

1. Quit WhatsApp Work. In Instruments, choose **App Launch**, set the target
   to the Release app, and record cold launches. Read true cold start from App
   Launch's process-start and validated first-presentation evidence. Use
   `Loaded Chat-List Run-Loop Proxy` only to correlate the SwiftUI pipeline;
   never use that event as the presented-frame endpoint. Save the complete
   recording as `01-app-launch.trace`.
2. Open **Time Profiler**, add **Points of Interest** and **Animation Hitches**
   (or Core Animation on the installed Instruments version), attach to the same
   Release app, and record at least 20 normal chat selections. Export every
   completed `Chat Switch to Selected Page View-Update Proxy` duration and save
   the trace as `02-chat-switch.trace`. Separately inspect and record the first
   compositor-presented frame containing each accepted selected page. Keep the
   proxy and presented-frame distributions in different columns. Retain
   cancelled/failed proxy intervals in the raw export, exclude them from
   latency percentiles, and report their counts.
3. In that trace or `03-message-visibility.trace`, collect at least 20
   user-driven incoming messages and 20 user-driven sends. Export proxy p50/p95
   separately for `Incoming Insert to Row onAppear Proxy` and
   `Send Insert to Row onAppear Proxy`. Separately inspect and record the first
   compositor-presented frame containing each new row for the actual visibility
   metrics. Never script or bulk-send WhatsApp messages.
4. Record 30 seconds of ordinary typing without sending in a busy transcript
   that currently renders about 200 rows; discard the draft. Record sustained
   manual scrolling in an existing 10k-message chat with Animation Hitches
   (or Core Animation on the installed Instruments version). Save
   `04-typing.trace` and `05-scroll.trace`, including hitch/frame summaries.
5. After sync settles, sample both processes once per second for five minutes:

   ```sh
   for i in $(seq 1 300); do
     date '+%s'
     ps -axo pid,pcpu,rss,comm | awk '/WhatsAppWork|whatsapp-core/ && !/awk/'
     sleep 1
   done > "$HOME/Desktop/WhatsAppWork-Task0-Baseline/06-idle-ps.txt"
   ```

   `comm` must be the **last** `-o` column. With `pid,comm,%cpu,rss` BSD ps
   truncates the middle `comm` column to ~16 chars ("/Applications/Wh"), the
   awk pattern never matches, and the loop silently records 300 empty samples
   — this actually happened on 2026-09-05 (first idle pass invalidated).
   Report average CPU and RSS for each process and combined RSS; retain the
   raw 300-sample file.
6. Export the completed proxy interval durations to
   `07-signpost-durations.csv` and the separately validated presentation timings
   to `08-presented-frame-durations.csv`. Sort each metric independently, report
   p50 as the median and p95 as the nearest-rank value at `ceil(0.95 × n)`, and
   never substitute a proxy duration for a presented-frame result. Record the
   app path, app executable hash, macOS/Xcode/Instruments versions, display
   setup, sample counts, and all raw artifact paths beside the table above.

Automated tests validate interval uniqueness, idempotent completion,
cancellation, and bounded chat/row bookkeeping. They do not substitute for
the live measurements in this section.

### Task 0 baseline capture log — 2026-09-05

Captured on the 2018-class Intel target (macOS 14.8.9, Xcode 16.2, xctrace 16.0,
i5-8259U, Intel Iris Plus 655) against Release build `645311c5…` installed at
`/Applications/WhatsApp Work.app`. Artifacts in `~/Desktop/WhatsAppWork-Task0-Baseline/`.
Method deviations from the ideal handoff, recorded honestly:

- Chat selection was driven by an agent via accessibility-safe coordinate clicks
  (not script-driven message traffic; no automation of sends). Two xctrace
  recorders attached simultaneously (Time Profiler + Logging for os_signpost)
  because no CLI template combines CPU sampling with Points of Interest.
- A first chat-switch attempt yielded only 19 completed proxy intervals
  (archived as `02-chat-switch-attempt1-19switches.trace`); it was redone.
- Presented-frame validation (08) and the 10k-message scroll capture were NOT
  done — both need interactive Instruments inspection / a verified 10k chat.
  Proxy numbers below are pipeline proxies, not perception results.

| Metric | n | p50 | p95 | min | max | Note |
|---|---:|---:|---:|---:|---:|---|
| Chat Switch to Selected Page View-Update Proxy | 20 | 1230 ms | 2310 ms | 1050 ms | 3141 ms | proxy; ~12× over the 100 ms perceived budget — the primary Task-0 finding and optimization target |
| Message Page Fetch Decode Merge | 28 | 352 ms | 1633 ms | 212 ms | 2221 ms | captured with the switch workload |
| Incoming Insert to Row onAppear Proxy | 2 | 307 ms | 319 ms | 295 ms | 319 ms | incidental live traffic only — not a valid sample |
| Send Insert to Row onAppear Proxy | 0 | — | — | — | — | requires user-driven sends |

Idle CPU/RSS (300 samples, 1/s, after full re-sync settled; pass 2; pass 1
included the post-login full re-sync burst — core peaked 142% CPU, app 68%):

- app: CPU avg 4.78% · p50 0.0% · p95 30.7% · max 66.2%; RSS avg 62.6 MB (max 63.3)
- core: CPU avg 4.28% · p50 0.0% · p95 3.0% · max 142.1% (one spike); RSS avg 58.1 MB (max 91.0)
- combined RSS avg 120.6 MB. App woke in 105/300 samples, core 57/300.

Idle CPU is above the ≤1% budget. Caveats: the account was receiving live
traffic during the capture, and the ZCode agent host was running on the same
machine (per-process %CPU is unaffected by other load, but the app was
frontmost with animations possible). Follow-up needed: `powermetrics` wakeup
audit and a traffic-quiet re-measure before calling this a hard FAIL.

Artifacts: `01a/01b/01c-app-launch.trace` (cold start ×3), `02-chat-switch.trace`
+ `02-chat-switch-signposts.trace` (attempt 2), `04-typing.trace` (30 s draft,
discarded, never sent), `06-idle-ps.txt` (pass 1) + `06-idle-ps-pass2.txt`,
`07-signpost-durations.csv`, `signpost-intervals-raw.xml` (+ attempt-1 archives).


## Measured — M1, core only

Machine of record: **MacBook Pro 2018, Intel i7, macOS 14.8, darwin/amd64** (the
actual low-end target hardware). Release binary (`CGO_ENABLED=0`, `-trimpath`,
`-ldflags "-s -w"`, 18 MB).

| Metric | Result | Budget | Verdict |
|---|---|---|---|
| Startup exec → READY | 563 ms first launch (incl. one-time migration) · 28–31 ms warm | < 200 ms | ✅ warm; first-launch migration is one-time |
| Idle RSS (sidecar, logged out) | 16.2 MB | core < 60 MB | ✅ huge headroom |
| History ingest (150k-row fixture) | 4,607 rows/s → ~33 s one-time full sync | — | ⚠️ acceptable for v0.1; M4 optimization candidate (prepared statements per chunk; ~3 statements/row now: message insert + FTS trigger + preview update) |
| Chat page 1 (50 msgs of 150k) | 0.56–0.91 ms | < 100 ms total | ✅ storage share < 1% |
| FTS search, realistic selectivity (~1% of 150k match, 2 terms) | 4.8 ms | < 100 ms | ✅ |
| FTS search, adversarial (100% of 150k match) | 396 ms | — | documented worst case; rank-sort over every match. Real queries are selective; revisit if real-world p95 > budget |
| Chat list page | 0.13–0.16 ms | — | ✅ |

Benchmarks: `cd core && WW_BENCH_N=150000 go test ./internal/storage -run XXX -bench . -benchmem`.

## Intel + Apple Silicon support

The core is pure Go (`CGO_ENABLED=0`): no cgo, no arch-specific code paths. The
build matrix (`scripts/build-core.sh`) produces `darwin/amd64` (Intel, the 2018
MacBook Pro target), `darwin/arm64`, and a `lipo` universal binary for bundling
into WhatsAppWork.app. All numbers above are from the Intel build running on
Intel hardware.

## Known risks to the budget

- Combined 150 MB idle is the tightest number (two runtimes). If it doesn't hold: cut SQLite page
  cache, trim whatsmeow buffers, and revise with measurements — the fallback claim is per-process
  budgets (core 60 / app 90) with a documented combined number.
- Cold start < 1 s total is achievable only if sidecar spawn overlaps SwiftUI first render; the
  design (spawn in app init, non-blocking login states) already assumes this.
- Intel HD-class GPUs punish large SwiftUI view trees; R7 mitigations in docs/architecture.md.

## Interaction correctness — 2026-09-04

This is source and automated-build evidence, not a logged-in-account manual
session. Consequently, no unexercised clipboard or read behavior is recorded
as passing below.

### Automated gate

From `apps/macos`:

```text
rtk xcodegen generate
Created project at .../apps/macos/WhatsAppWork.xcodeproj

rtk xcodebuild -scheme WhatsAppWork -configuration Debug \
  -derivedDataPath build/DerivedData-full test
** TEST SUCCEEDED **

xcresult summary: totalTestCount: 33; passedTests: 33; failedTests: 0;
skippedTests: 0; result: Passed

rtk xcodebuild -scheme WhatsAppWork -configuration Debug \
  -derivedDataPath build/DerivedData build
** BUILD SUCCEEDED **

rtk xcodebuild -scheme WhatsAppWork -configuration Release \
  -derivedDataPath build/DerivedData-release build
** BUILD SUCCEEDED **

rtk codesign --verify --strict --deep --verbose=4 \
  'build/DerivedData/Build/Products/Debug/WhatsApp Work.app'
valid on disk; satisfies its Designated Requirement

rtk codesign --verify --strict --deep --verbose=4 \
  'build/DerivedData-release/Build/Products/Release/WhatsApp Work.app'
valid on disk; satisfies its Designated Requirement
```

The test result bundle for the Debug test run is
`build/DerivedData-full/Logs/Test/Test-WhatsAppWork-2026.09.04_19-50-59-+0700.xcresult`.
This Xcode version reports the count through its result-bundle summary rather
than printing an `Executed ... tests` console line; the exact reported result
is 33 tests executed/passed with 0 failures. A stale unsigned embedded test
bundle in the reused Debug derived-data directory initially interrupted the
bundle-signing phase; a scoped `xcodebuild ... clean` removed only that build
output before the successful focused, full-suite, Debug, and Release gates.

Direct read-only artifact inspection confirmed that both output apps contain
an executable universal `whatsapp-core` sidecar:

```text
rtk proxy zsh -c 'for core in "build/DerivedData/Build/Products/Debug/WhatsApp Work.app/Contents/MacOS/whatsapp-core" "build/DerivedData-release/Build/Products/Release/WhatsApp Work.app/Contents/MacOS/whatsapp-core"; do if test -x "$core"; then print "EXECUTABLE: $core"; else print "NOT EXECUTABLE: $core"; exit 1; fi; file "$core"; lipo -info "$core"; done'
EXECUTABLE: build/DerivedData/Build/Products/Debug/WhatsApp Work.app/Contents/MacOS/whatsapp-core
build/DerivedData/Build/Products/Debug/WhatsApp Work.app/Contents/MacOS/whatsapp-core: Mach-O universal binary with 2 architectures: [x86_64:Mach-O 64-bit executable x86_64] [arm64]
build/DerivedData/Build/Products/Debug/WhatsApp Work.app/Contents/MacOS/whatsapp-core (for architecture x86_64): Mach-O 64-bit executable x86_64
build/DerivedData/Build/Products/Debug/WhatsApp Work.app/Contents/MacOS/whatsapp-core (for architecture arm64): Mach-O 64-bit executable arm64
Architectures in the fat file: build/DerivedData/Build/Products/Debug/WhatsApp Work.app/Contents/MacOS/whatsapp-core are: x86_64 arm64
EXECUTABLE: build/DerivedData-release/Build/Products/Release/WhatsApp Work.app/Contents/MacOS/whatsapp-core
build/DerivedData-release/Build/Products/Release/WhatsApp Work.app/Contents/MacOS/whatsapp-core: Mach-O universal binary with 2 architectures: [x86_64:Mach-O 64-bit executable x86_64] [arm64]
build/DerivedData-release/Build/Products/Release/WhatsApp Work.app/Contents/MacOS/whatsapp-core (for architecture x86_64): Mach-O 64-bit executable x86_64
build/DerivedData-release/Build/Products/Release/WhatsApp Work.app/Contents/MacOS/whatsapp-core (for architecture arm64): Mach-O 64-bit executable arm64
Architectures in the fat file: build/DerivedData-release/Build/Products/Release/WhatsApp Work.app/Contents/MacOS/whatsapp-core are: x86_64 arm64
```

Each build also emitted Xcode's warning that the `Bundle Go Core` run-script
phase declares no output files and therefore runs every build. The artifact
inspection above verifies the bundled sidecar for these Debug and Release
outputs; both builds also succeeded. The warning is retained for the planned
runtime lifecycle work in Task 8; it was not changed by this interaction gate.

### Source-structure check

Verified by source inspection: the transcript uses `List(selection:)` in
`TranscriptView.MessageList`, and each message line uses SwiftUI
`Text(attributed).textSelection(.enabled)` in `IRCLineText`. There is no
per-row AppKit text-view implementation or fallback path.

### Clipboard acceptance matrix

| Check | Result | Evidence / reason |
|---|---|---|
| Selected transcript text: Command-C copies the exact selection | NOT VERIFIED | Requires a logged-in live app session; not exercised in this gate. |
| Composer selection: Command-C copies selected draft text | NOT VERIFIED | Requires a logged-in live app session; not exercised in this gate. |
| Composer with text clipboard: Command-V pastes text | NOT VERIFIED | Requires a logged-in live app session; not exercised in this gate. |
| Focused composer with clipboard image or Finder file: Command-V stages attachment and focuses caption | NOT VERIFIED | Requires a logged-in live app session; not exercised in this gate. |
| Search field with text clipboard: Command-V pastes text | NOT VERIFIED | Requires a logged-in live app session; not exercised in this gate. |

### Focused interaction/read checks

| Check | Result | Evidence / reason |
|---|---|---|
| Transcript remains smooth while selecting text | NOT VERIFIED | No live 10k-message session or Instruments/FPS trace was run. |
| Rapid chat switches during text, reply, and media sends keep rows and composition state with their owning chat | NOT VERIFIED | Requires a logged-in account and live sends; not exercised. Automated policy tests cover ownership logic only. |
| J/K scan changes preview without marking a chat read | NOT VERIFIED | Requires observing unread state in a logged-in live app; not exercised. Automated policy tests cover the navigation-source rule only. |

No FPS, p95 latency, idle CPU, or idle-energy metric is claimed here. Those
remain subject to the signpost/Instruments measurement plan above.

## Runtime hardening — CoreEvent decode, 2026-09-05

Verdict: **RETAINED**. Replacing the JSONSerialization → payload re-encode →
JSONDecoder path with one typed `JSONDecoder` envelope reduced the median clock
time from **180.7193265 ms** to **72.831238 ms** per 10,000 frames
(**-59.6992533%**, faster). This is within the no-more-than-5%-slower gate.
Median peak physical memory fell from **44,742.656 kB** to **21,008.384 kB**
(**-53.0461848%**), so the memory guard also passes.

### Method and configuration

- Machine: MacBookPro15,2, Intel Core i5-8259U (4 physical / 8 logical cores),
  8 GiB RAM, macOS 14.8.9 (23J631), x86_64 test destination.
- Toolchain: Xcode 16.2 (16C5032a), Swift 5.10 project setting.
- Test: `CoreEventDecodeTests.testDecodePerformance10kFrames`, 20 XCTest
  samples; every sample decodes the same `connection.changed` frame 10,000
  times. Metrics are `XCTClockMetric` and `XCTMemoryMetric`.
- Both measurements used an identical clean Release build (`-O`) in
  `build/DerivedData-task6` with `ENABLE_TESTABILITY=YES` and
  `ENABLE_HARDENED_RUNTIME=NO`. Those two command-line overrides were scoped to
  the performance test: Release otherwise cannot import `@testable`, and the
  ad-hoc hosted test bundle is rejected by hardened-runtime library validation.
  The normal production Release build retains hardened runtime.
- Exact baseline invocation:

  ```text
  rtk xcodebuild -project WhatsAppWork.xcodeproj -scheme WhatsAppWork \
    -configuration Release -derivedDataPath build/DerivedData-task6 \
    -resultBundlePath build/CoreEventDecodeBaselineRelease2.xcresult \
    clean test -only-testing:WhatsAppWorkTests/CoreEventDecodeTests \
    ENABLE_TESTABILITY=YES ENABLE_HARDENED_RUNTIME=NO
  ```

- Exact candidate invocation (only the result-bundle path differs):

  ```text
  rtk xcodebuild -project WhatsAppWork.xcodeproj -scheme WhatsAppWork \
    -configuration Release -derivedDataPath build/DerivedData-task6 \
    -resultBundlePath build/CoreEventDecodeCandidateRelease.xcresult \
    clean test -only-testing:WhatsAppWorkTests/CoreEventDecodeTests \
    ENABLE_TESTABILITY=YES ENABLE_HARDENED_RUNTIME=NO
  ```

The compatibility run passed all five tests on both implementations: all 12
current event cases, optional/default payload behavior, unknown and malformed
frames, and the ping path (exactly one pong and one heartbeat, with no ordinary
event delivery). Build wall time was deliberately excluded from the comparison.

### Raw XCTest measurements

Values below are in XCTest sample order. Clock values are seconds for one
10,000-frame sample; both memory series are kB as reported by XCTest.

```text
Legacy clock:
0.185559015, 0.185687897, 0.185485942, 0.181116402, 0.179282799,
0.174267288, 0.181551208, 0.189775497, 0.176906638, 0.188933756,
0.190727073, 0.180322251, 0.183904217, 0.171101148, 0.177151860,
0.174278247, 0.175211653, 0.184082531, 0.179457555, 0.172917244
Legacy clock median: 0.1807193265 s

Typed-envelope clock:
0.068364162, 0.068744629, 0.068354314, 0.066390750, 0.066235886,
0.067544264, 0.093447307, 0.079013521, 0.073152334, 0.087931354,
0.072510142, 0.088084943, 0.095615593, 0.078732872, 0.072034187,
0.067586029, 0.075563452, 0.081976976, 0.078586426, 0.067686326
Typed-envelope clock median: 0.072831238 s

Legacy peak physical:
53633.024, 52596.736, 55738.368, 45490.176, 41283.584,
41549.824, 49463.296, 41193.472, 36098.048, 47742.976,
43753.472, 46718.976, 44765.184, 43036.672, 42266.624,
44720.128, 44630.016, 48685.056, 44281.856, 47677.440
Legacy peak-physical median: 44742.656 kB

Typed-envelope peak physical:
20905.984, 20922.368, 20934.656, 20938.752, 20938.752,
20951.040, 20963.328, 20983.808, 20992.000, 21008.384,
21008.384, 21012.480, 21012.480, 21028.864, 21037.056,
21057.536, 21061.632, 21073.920, 21082.112, 21086.208
Typed-envelope peak-physical median: 21008.384 kB

Legacy physical delta:
4460.544, 1294.336, -12509.184, 4579.328, -4005.888,
266.240, -503.808, 131.072, 3309.568, -5124.096,
4382.720, -5419.008, 6414.336, -1708.032, -774.144,
2437.120, -102.400, -4296.704, 12361.728, -4997.120
Legacy physical-delta median: 14.336 kB

Typed-envelope physical delta:
0.000, 4.096, 4.096, 4.096, 0.000,
8.192, 4.096, 8.192, 0.000, 12.288,
0.000, 4.096, 0.000, 12.288, 0.000,
12.288, 0.000, 4.096, 4.096, 0.000
Typed-envelope physical-delta median: 4.096 kB
```

The physical-delta series is noisy (including negative legacy samples as the
test process releases pages), so the absolute peak-physical median is the
primary memory evidence. Neither memory metric increased.

Limitations: this is a deterministic decoder microbenchmark, not a network,
WebSocket scheduling, UI, energy, or logged-in workload. It uses one small
representative frame; payload-size sensitivity was not measured. Live-account
behavior remains **NOT VERIFIED**.


### Resumed verification, 2026-09-05

The saved baseline/candidate xcresults were re-exported and their medians
independently recomputed; all values above match. Source/tests match the saved
candidate snapshot. A fresh incremental Release run of the same five tests
passed with zero failures (`CoreEventDecodeResumeRelease.xcresult`, same
configuration and test overrides). Its supplementary medians were **63.2888455 ms**
per 10,000 frames, **20,897.792 kB** peak physical memory, and **0 kB** physical
delta. The original clean-build pair remains the retention gate. Exact command,
artifact paths and exported CSVs are in the Task 6 execution report at
`.superpowers/sdd/2026-09-04-runtime-performance-hardening/task-6-report.md`.

## Runtime performance gate — 2026-09-05

The final automated gate ran on the MacBookPro15,2 Intel host described above.
Live-account and Instruments-only values remain explicitly unmeasured; no
estimate or automated proxy is presented as an interactive measurement.

| Runtime metric | Before | After | Budget | Verdict |
|---|---:|---:|---:|---|
| Healthy-idle fallback requests / 5 min | NOT MEASURED | NOT MEASURED | 0 | NOT MEASURED — no logged-in request log |
| Connected idle CPU / RSS | NOT MEASURED | NOT MEASURED | ≤1% / app <90 MB | NOT MEASURED — no logged-in five-minute sample |
| Attachment main-thread read time, 19 MiB | NOT MEASURED | NOT MEASURED | 0 ms | NOT MEASURED — no live Instruments trace |
| Retained transcript chats after opening 25 | 25 | 10 | ≤10 plus pending | PASS — deterministic production-boundary `previewChat` measurement; live RSS NOT MEASURED |
| CoreEvent decode, 10k frames | 180.7193265 ms; 44,742.656 kB peak | 72.831238 ms; 21,008.384 kB peak | no >5% regression | PASS — clock -59.6992533%; peak memory -53.0461848% |
| Media eviction, 100 victims | 40.327295 ms/op; 4,917 allocs/op; per-row writes | 10.256282 ms/op; 955 allocs/op; 1 size query + 1 candidate query + 1 transaction | one size query + one transaction | PASS — median time -74.6%; allocations -80.6% |
| Incremental Debug rebuild | 2.28 s | 1.68 s | no regression | PASS — 0.60 s / 26.3% faster |

The incremental build times are `/usr/bin/time -p` wall times for the prescribed
second unchanged Debug build before and after declaring dependencies. Before,
`Bundle Go Core` ran and Xcode emitted the no-output warning. After, the phase
and warning were absent. A clean Debug build ran the phase and normal Xcode
CodeSign, and the following unchanged build skipped it. A real Swift source
edit and an actual rebuilt sidecar with changed version and binary hash each
re-ran the phase; deep strict app verification passed after each transition.
The source probes were restored byte-for-byte.

Final 150k-row storage benchmark results:

| Benchmark | Result | Recorded range / budget | Verdict |
|---|---:|---:|---|
| InsertMessagesBatch | 144.221207 ms/op; 3,467 rows/s | diagnostic | RECORDED |
| ListMessagesPage | 0.623630 ms/op | 0.56–0.91 ms | PASS |
| SearchFTS | 5.096405 ms/op | <100 ms | PASS |
| ChatsPage | 0.113612 ms/op | 0.13–0.16 ms | PASS — faster than recorded range |

The final automated matrix passed `go build`, `go vet`, 115 regular Go tests
across 9 packages, 111 race tests across the 5 required packages, the storage
benchmark suite, universal sidecar generation (`x86_64 arm64`), and 147 Debug
Swift tests with zero failures. The final Debug test host is ad-hoc signed
(`codesign` flags `0x2(adhoc)`); the standard Release app retains production
hardened runtime (`0x10002(adhoc,runtime)`). Both passed
`codesign --verify --deep --strict` and contain the restored `0.1.0-m0`
universal sidecar.

The first Release attempt failed while only 63 MiB remained on the volume:
copying the 35.6 MiB sidecar independently reproduced `No space left on device`,
while codesign surfaced only an internal-subsystem error. Removing one stale,
reproducible 457 MiB Xcode DerivedData directory restored sufficient space; the
focused retry then passed without a source or project change. No snapshot
workspace was removed. The live five-minute request/CPU/RSS checks, 19 MiB Main
Thread trace, interactive 25-chat RSS, network scheduling, and UI-energy behavior
remain **NOT MEASURED**.


## Shared-state recovery verification — 2026-09-05

The final Swift recovery wave preserves failed negative rows under transcript
LRU pressure until retry, reconciliation, or explicit cleanup removes them.
Protection is independent of HTTP-operation liveness; temporary overflow is
therefore intentional when more than ten chats contain unreconciled local rows.
The latest-page merge now uses the full `(timestamp, id)` boundary so a newer
same-second WebSocket row survives an in-flight REST response.

Older-page loading now reverses the descending REST page and merges it with the
canonical retained window in **O(page + window)** time. Fetched durable IDs own
overlapping rows, and negative local rows survive. A production `loadOlderMessages`
test uses a blocked URLProtocol response and a live AppState event callback to
verify REST ownership, an intervening WS row, and the pending row together.

The paired Release microbenchmark on the same MacBookPro15,2 Intel host compares
the previous production expression (ID set, filter, concatenate, full-window
`ordered`) with the exact new `MessageTimelineOrder.mergingOlderPage` helper
consumed by AppState. Both use identical fixtures, including equal-second tuples
and one additional negative row. Seven sample pairs alternate execution order;
each sample averages 100 merges for the 300-row window or 20 for the 10,000-row
window. The table reports medians in milliseconds per merge.

| Retained durable rows | Descending page rows | Old full-sort assembly | Linear merge | Reduction |
|---:|---:|---:|---:|---:|
| 300 | 50 | 0.186760 ms | 0.084204 ms | 54.9% |
| 300 | 200 | 0.283093 ms | 0.167785 ms | 40.7% |
| 10,000 | 50 | 7.701870 ms | 2.428422 ms | 68.5% |
| 10,000 | 200 | 7.147389 ms | 2.464065 ms | 65.5% |

Release benchmark tests use `ENABLE_TESTABILITY=YES ENABLE_HARDENED_RUNTIME=NO`
only to run XCTest against optimized code. The same pre-change algorithm was
also measured before replacing the production call: 0.110887/0.146629 ms for
300 rows and 6.628508/6.849781 ms for 10,000 rows (50/200-row pages respectively).
The paired same-run comparison above is the primary evidence; differing absolute
baseline times across runs show ordinary host/compiler/timing variability.
These figures measure array assembly, not interactive scroll latency, MainActor
scheduling, live-account memory, or Instruments results.

The candidate passed all **152 Debug Swift tests**, then all **6 selected Release
tests** after two additional attachment-clear assertions. The selected Release
run includes 24 distinct three/four-send mixed-failure/echo/ack cases, retry,
caption return-navigation ownership, and the real older-page boundary.
Standard Debug and Release builds then passed deep strict signature verification;
Release remains universal with production hardened-runtime flags
`0x10002(adhoc,runtime)`. Exact commands, raw samples, build/signature outcomes,
and the scoped correction report are recorded in
`.superpowers/sdd/2026-09-04-runtime-performance-hardening/final-fix-report.md`.
The unchanged Go/race/storage results above are reused; this wave modifies no Go
code. Earlier live-account measurement limitations remain unchanged.
