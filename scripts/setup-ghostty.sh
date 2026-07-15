#!/usr/bin/env bash
# OPTIONAL — only for future GhosttyKit rendering. Not required to run Fastq.
# Daily use: ./scripts/run-dev.sh && open build.noindex/DevProducts/Fastq.app
# Build GhosttyKit.xcframework the same way cmux does.
# Prereq: brew install zig
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v zig >/dev/null; then
  echo "Install Zig first: brew install zig"
  exit 1
fi

if [ ! -d ghostty/.git ]; then
  echo "Cloning Ghostty (this is large)…"
  git clone --depth 1 https://github.com/ghostty-org/ghostty.git ghostty
fi

echo "Building GhosttyKit.xcframework…"
cd ghostty
zig build -Demit-xcframework=true -Demit-macos-app=false -Doptimize=ReleaseFast

echo "Done. Framework at: ghostty/macos/GhosttyKit.xcframework"
echo "Next: link GhosttyKit into FastqTerminal and swap PTY text view for Metal surface (cmux pattern)."
