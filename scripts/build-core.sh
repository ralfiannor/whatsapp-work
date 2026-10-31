#!/usr/bin/env bash
# Build the Go core for the platforms WhatsApp Work targets.
#
# Pure Go (CGO_ENABLED=0) — the same binary runs natively on Intel and Apple
# Silicon Macs. Outputs into dist/:
#   whatsapp-core-darwin-amd64   Intel (MacBook Pro 2018 etc.)
#   whatsapp-core-darwin-arm64   Apple Silicon
#   whatsapp-core                universal (lipo of both)
set -euo pipefail
cd "$(dirname "$0")/../core"

OUT=${1:-../dist}
mkdir -p "$OUT"

# The core reports the app's version (READY line, /healthz, -version); one
# source of truth: MARKETING_VERSION in apps/macos/project.yml.
VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"$/\1/p' ../apps/macos/project.yml)"
[ -n "$VERSION" ] || { echo "build-core: MARKETING_VERSION not found in project.yml" >&2; exit 1; }
FLAGS=(-trimpath -ldflags "-s -w -X main.version=$VERSION")

echo "== darwin/amd64 (Intel) =="
CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build "${FLAGS[@]}" \
  -o "$OUT/whatsapp-core-darwin-amd64" ./cmd/whatsapp-core

echo "== darwin/arm64 (Apple Silicon) =="
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build "${FLAGS[@]}" \
  -o "$OUT/whatsapp-core-darwin-arm64" ./cmd/whatsapp-core

echo "== universal =="
lipo -create -output "$OUT/whatsapp-core" \
  "$OUT/whatsapp-core-darwin-amd64" "$OUT/whatsapp-core-darwin-arm64"
lipo -info "$OUT/whatsapp-core"

ls -lh "$OUT" | awk 'NR>1 {print "  " $5 "\t" $9}'
echo "Build OK ($VERSION) → $OUT"
