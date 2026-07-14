#!/usr/bin/env bash
# Build both apps into one Products folder so Fastq can auto-launch Fastq Terminal.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/DevProducts"
mkdir -p "$OUT"

echo "Building Fastq Terminal…"
# Don't override CONFIGURATION_BUILD_DIR — SPM packages (SwiftTerm) break with that.
xcodebuild -project "$ROOT/FastqTerminal.xcodeproj" -scheme FastqTerminal \
  -configuration Debug -derivedDataPath "$ROOT/build/DerivedDataTerminal" \
  -destination 'platform=macOS' build
rm -rf "$OUT/Fastq Terminal.app"
cp -R "$ROOT/build/DerivedDataTerminal/Build/Products/Debug/Fastq Terminal.app" "$OUT/"

echo "Building Fastq launcher…"
xcodebuild -project "$ROOT/Fastq.xcodeproj" -scheme Fastq \
  -configuration Debug -derivedDataPath "$ROOT/build/DerivedData" \
  CONFIGURATION_BUILD_DIR="$OUT" build

echo ""
echo "Done. Launch with:"
echo "  open \"$OUT/Fastq.app\""
echo "Fastq will start Fastq Terminal automatically when you run an agent."
