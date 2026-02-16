+++
title = "Installation"
description = "How to install trm on macOS by building from source."
weight = 1
+++

## Requirements

- **macOS** (trm uses macOS-native APIs for WebView, Notes, and Screen Capture plugins)
- **Zig 0.13+** (latest stable release)
- **GPU** with Metal support (required by the Ghostty renderer)

## Build from Source

Clone the repository and build with release optimizations:

```sh
git clone https://github.com/anthropics/trm.git
cd trm
zig build -Doptimize=ReleaseFast
```

The binary will be at `zig-out/bin/trm`. You can copy it to a location in your `PATH`:

```sh
cp zig-out/bin/trm /usr/local/bin/
```

## Dependencies

trm is built on [Ghostty](https://ghostty.org)'s terminal core and renderer. All dependencies are managed through Zig's build system. Key components include:

| Component | Purpose |
|-----------|---------|
| Ghostty core | Terminal emulation, VT parser, GPU rendering |
| Metal / OpenGL | GPU-accelerated rendering backends |
| libghostty | C API bridge for macOS integration |
| AppKit / WebKit | macOS native views (WKWebView, NSTextView) |

No system libraries need to be installed separately; the macOS SDK provides everything else.

## Verify Installation

```sh
trm --version
```

This prints the version number and exits.

## First Launch

Simply run `trm` with no arguments to start with a single terminal pane using the default configuration:

```sh
trm
```

trm automatically creates a default config file at `~/.config/trm/config.toml` on first run.

To launch with a specific session file:

```sh
trm --config path/to/session.toml
```

See the [Configuration](/docs/configuration/) guide for details on customizing your setup.

## Uninstall

Remove the binary:

```sh
rm /usr/local/bin/trm
```

To also remove configuration files:

```sh
rm -rf ~/.config/trm
```
