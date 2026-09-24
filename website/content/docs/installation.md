+++
title = "Installation"
description = "How to install trm on macOS by building from source."
weight = 1
+++

## Requirements

- **macOS 13 or later.** trm is a native Mac app: the grid, the Command Center
  and the plugin panes are AppKit and SwiftUI.
- **Xcode 15+** with its command line tools, for the Swift half of the app.
- **Zig 0.15.2.** Newer Zig releases are not yet supported — with Homebrew,
  `brew install zig@0.15` and build with
  `/opt/homebrew/opt/zig@0.15/bin/zig`.
- **A GPU with Metal support**, required by the Ghostty renderer. Xcode must
  have its Metal toolchain installed; if a build fails with `cannot execute
  tool 'metal'`, run `xcodebuild -downloadComponent MetalToolchain` once.

## Build from Source

```sh
git clone https://github.com/keyvez/trm.git
cd trm
zig build -Doptimize=ReleaseFast -Dxcframework-target=native
```

`-Dxcframework-target=native` builds the framework for this Mac only, which is
what you want on an Apple Silicon machine; leave it off only if you are
building a universal bundle.

The result is an app bundle at `macos/build/ReleaseLocal/trm.app`. Install it:

```sh
./scripts/reinstall-trm.sh          # copies it to /Applications/trm.app
```

A debug build is `zig build` with no flags, and the Zig unit tests are
`zig build test`.

## Install the CLI

The `trm` command drives the running app over its
[Text Tap socket](/docs/text-tap-api/) — listing panes, sending text to an
agent, mirroring a session — and launches the app when called with no
arguments.

```sh
./scripts/install-cli.sh            # needs sudo; installs to /usr/local/bin
```

## Dependencies

trm is built on [Ghostty](https://ghostty.org)'s terminal core and renderer.
Everything is managed by Zig's build system, so no system libraries need to be
installed separately.

| Component | Purpose |
|-----------|---------|
| Ghostty core | Terminal emulation, VT parser, GPU rendering |
| Metal | GPU-accelerated rendering backend |
| libghostty | C API bridge for the macOS app |
| zmx | Session daemon, so a pane's shell outlives the window |
| AppKit / SwiftUI / WebKit | The Mac app itself |

## Verify the Install

```sh
trm version
```

This prints the version, the build number (the repo's commit count) and the
commit it was built from — the same three the About window shows.

## First Launch

Open `/Applications/trm.app`, or run `trm` with no arguments, to start with a
single terminal pane and the default configuration. A default config file is
created at `~/.config/trm/config.toml` on first run.

To launch with a specific session file:

```sh
trm --config path/to/session.toml
```

See the [Configuration](/docs/configuration/) guide for details on customizing
your setup.

## Uninstall

```sh
rm -rf /Applications/trm.app
sudo rm -f /usr/local/bin/trm /usr/local/bin/mirror-session.py
```

To also remove configuration, sessions and extensions:

```sh
rm -rf ~/.config/trm
rm -rf ~/Library/Application\ Support/trm
```
