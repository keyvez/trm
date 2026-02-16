// ---------------------------------------------------------------------------
// termania.zig — Module root for Termania features in trm.
//
// This re-exports the Termania subsystems (grid layout, plugin system,
// LLM integration, text-tap API, etc.) that extend Ghostty's terminal
// emulation with multi-pane grid management and plugin architecture.
// ---------------------------------------------------------------------------

pub const grid = @import("termania/grid.zig");
pub const plugin = @import("termania/plugin.zig");
pub const config = @import("termania/config.zig");
pub const input = @import("termania/input.zig");
pub const llm = @import("termania/llm.zig");
pub const text_tap = @import("termania/text_tap.zig");
pub const process_info = @import("termania/process_info.zig");
pub const renderer = @import("termania/renderer.zig");
pub const capi = @import("termania/capi.zig");
pub const terminal_types = @import("termania/terminal_types.zig");
pub const pty = @import("termania/pty.zig");
pub const plugin_registry = @import("termania/plugin_registry.zig");
