# macOS App (M2)

SwiftUI shell. Not started — blocked on full Xcode (this machine currently has Command Line Tools
only; `xcodebuild` unavailable).

Plan (docs/roadmap.md M2):

- Sidecar process manager per docs/architecture.md §6 (spawn → READY handshake → backoff restart →
  clean shutdown; healthz ping on wake).
- URLSession HTTP + URLSessionWebSocketTask client, bearer token from READY line.
- Views: Login(QR) · ChatList · Transcript(paginated) · Composer · Search(⌘K) · Settings.
- Project managed with XcodeGen (`project.yml`), Go binary bundled as
  `Contents/MacOS/whatsapp-core`, built by a pre-build script (`go build -trimpath -ldflags="-s -w"`).
