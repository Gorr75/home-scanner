#!/bin/sh
# Xcode Cloud runs this before the RoomScan scheme builds.
# The iOS app needs a LiDAR device to scan; these tests cover the model and JSON export.
set -eu
cd "$(dirname "$0")/.."

if command -v swift >/dev/null 2>&1; then
  swift test --package-path RoomScanCore
else
  echo "swift is not on PATH; using xcrun swift"
  xcrun swift test --package-path RoomScanCore
fi
