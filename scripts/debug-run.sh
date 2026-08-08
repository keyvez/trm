#!/bin/bash
set -e
cd "$(dirname "$0")/.."
rm -rf macos/GhosttyKit.xcframework
zig build -Dxcframework-target=native -Demit-macos-app=true
open macos/build/Debug/trm.app
