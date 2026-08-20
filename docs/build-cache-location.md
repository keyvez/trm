# Where the build caches live

The Mac mini's internal disk filled up (225 MB free of 228 GB) and a build
died mid-way with `ar: No space left on device`, taking `GhosttyKit.xcframework`
with it. The heavy, entirely regenerable parts of the build now live on the
external SSD at `/Volumes/BackseatDriver/trm-build`, reached through symlinks
so no build command had to change:

| link | target | size |
|------|--------|------|
| `.zig-cache` | `trm-build/zig-cache` | ~14 GB |
| `macos/build` | `trm-build/macos-build` | ~1.2 GB |
| `~/.cache/zig` | `trm-build/zig-global-cache` | ~515 MB |

## What deliberately stayed on the internal disk

`~/Library/Developer/Xcode/DerivedData/trm-*`. It was moved out there too, and
the Swift test suite then failed every run with:

    Test Suite 'System Failures' failed
    The test runner hung before establishing connection.

Same commit, same tests, 345 s of hanging. Pointing `-derivedDataPath` back at
the internal disk passed immediately, so this is the location, not the code.
XCTest launches the host app out of DerivedData and the runner has to connect
back to it; through a symlinked path on an external volume that handshake
never completes. Builds are fine there — running is not.

So: caches and intermediates outside, anything XCTest launches inside.

## If the drive is unplugged

Builds fail with missing-path errors rather than doing anything silly. Restore
by removing the dangling symlinks — everything under them is derived and
rebuilds:

    cd ~/dev/trm
    rm .zig-cache macos/build ~/.cache/zig
    zig build -Doptimize=ReleaseFast -Dxcframework-target=native
