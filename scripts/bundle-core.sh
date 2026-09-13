#!/usr/bin/env bash
# Bundle the universal Go core into a built WhatsAppWork.app.
# Run after scripts/build-core.sh and a Release build (or before Debug runs):
#   ./scripts/bundle-core.sh <path-to-built-app>
set -euo pipefail
APP=${1:?usage: bundle-core.sh <WhatsAppWork.app>}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/dist/whatsapp-core"

[ -d "$APP" ] || { echo "no app at $APP (build first)" >&2; exit 1; }
[ -x "$CORE" ] || { echo "no $CORE (run scripts/build-core.sh)" >&2; exit 1; }

install -m 0755 "$CORE" "$APP/Contents/MacOS/whatsapp-core"
echo "bundled: $APP/Contents/MacOS/whatsapp-core"
lipo -info "$APP/Contents/MacOS/whatsapp-core"
