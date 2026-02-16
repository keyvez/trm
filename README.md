<!-- LOGO -->
<h1>
<p align="center">
  <img src="https://raw.githubusercontent.com/keyvez/trm/main/website/static/images/icon.png" alt="trm" width="128">
  <br>trm
</h1>
  <p align="center">
    AI-native terminal emulator built on Ghostty.
    <br />
    <a href="#about">About</a>
    ·
    <a href="#features">Features</a>
    ·
    <a href="CONTRIBUTING.md">Contributing</a>
    ·
    <a href="HACKING.md">Developing</a>
  </p>
</p>

## About

trm is an AI-native terminal emulator built on top of
[Ghostty](https://github.com/ghostty-org/ghostty)'s GPU renderer. It adds
a multi-pane grid layout, AI command palette, live terminal summaries, a
plugin system, and pane overlaying — while keeping Ghostty's speed, standards
compliance, and native platform experience.

## Features

| Feature | Description |
|---------|-------------|
| **AI Command Palette** | Ask AI to run commands, explain errors, or control your terminal. Three modes: AI, Search, and raw Command. |
| **Live AI Summaries** | Each pane gets a live LLM-generated summary of its terminal output, updated automatically. |
| **Multi-Pane Grid** | Jagged grid layout where each row can have different column counts. Broadcast input, navigate with keyboard, jump with Cmd+1-9. |
| **Pane Overlaying** | Stack panes in layers — run a terminal over a web page, overlay notes on a log viewer. Toggle focus between foreground and background. |
| **Plugin System** | 10 built-in plugin types: Terminal, WebView, Notes, File Browser, Git Status, Process Monitor, Log Viewer, Markdown Preview, System Info, Screen Capture. |
| **Smart Text Selection** | Ctrl+click to select a URL or path in one click, even across wrapped lines. Ctrl+drag to extend across line breaks. |
| **Pane Watermarks** | Tag each pane with a large faint label — environment names, server tags, or project identifiers. Set via config or dynamically via AI. |
| **Text Tap API** | Unix socket API for external control. Subscribe to output, send input, execute actions via JSON. |
| **GPU Rendering** | Ghostty's Metal/OpenGL renderer with background images, custom shaders, and 120fps. |

## Quick Start

```bash
git clone https://github.com/keyvez/trm.git
cd trm
zig build -Doptimize=ReleaseFast
```

Create a config at `~/.config/trm/trm.toml`:

```toml
title = "My Project"
rows = 2
cols = 2

[[panes]]
title = "Editor"
cwd = "~/projects/myapp"
watermark = "EDIT"

[[panes]]
title = "Server"
initial_commands = ["npm run dev"]

[[panes]]
title = "Tests"
initial_commands = ["zig build test"]

[[panes]]
type = "webview"
title = "Docs"
url = "http://localhost:3000"
```

Then launch:

```bash
trm
# Or specify a config file
trm --config path/to/config.toml
```

## Contributing and Developing

If you have any ideas, issues, etc. regarding trm, or would like to
contribute through pull requests, please check out our
["Contributing"](CONTRIBUTING.md) document. Those who would like
to get involved with development should also read the
["Developing"](HACKING.md) document for more technical details.

## Acknowledgments

trm is built on top of [Ghostty](https://github.com/ghostty-org/ghostty),
a fast, native, feature-rich terminal emulator by Mitchell Hashimoto.
Ghostty provides the core terminal emulation, GPU rendering, and platform
integration that trm extends.
