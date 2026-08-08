# trm — Project Conventions

## Build & Test

```bash
# Build (debug)
zig build

# Build (release)
zig build -Doptimize=ReleaseFast

# Run Zig tests
zig build test

# Build macOS app
cd macos && xcodebuild -scheme trm -configuration Debug build
```

## Install CLI

```bash
# After building, install the `trm` command:
./scripts/install-cli.sh
```

## Rules

- Every feature change must be added to the marketing site (`website/templates/index.html` or relevant docs).
- Every feature change must be added to the CHANGELOG.
- Zig code lives in `src/termania/`. Swift code in `macos/Sources/`.
- C API boundary: Zig exports in `src/termania/capi.zig`, declarations in `include/ghostty.h`, Swift wrappers in `macos/Sources/Ghostty/Trm.swift`.
- Text Tap protocol: newline-delimited JSON over Unix socket. Actions go through `TermaniaAction` union.
- Session persistence: panes run under `zmx attach` (vendored `vendor/zmx`, built by `src/build/GhosttyZmx.zig` against the in-tree ghostty-vt, bundled as an auxiliary executable). Session names persist as `zmx_session` in session TOML. Record any vendored-source patch in `vendor/zmx/UPSTREAM`.
- Extensions: manifests in `~/Library/Application Support/trm/extensions/<name>/extension.toml`; schema + stdio protocol documented in `docs/extensions.md` and mirrored in `ExtensionBuilder.systemPrompt` — keep those two in sync when changing `ExtensionManifest` or `PluginMessageCodec`.
- Use `zig build test` to run unit tests before committing Zig changes.
