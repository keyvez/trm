const std = @import("std");
const testing = std.testing;
const plugin_mod = @import("plugin.zig");
const config_mod = @import("config.zig");

const PanePlugin = plugin_mod.PanePlugin;
const PaneType = plugin_mod.PaneType;

/// An entry in the plugin registry describing a built-in pane type.
pub const PluginEntry = struct {
    /// Internal name used in config files (e.g. "terminal", "webview").
    name: []const u8,
    /// Human-readable display name (e.g. "Terminal", "Web View").
    display_name: []const u8,
    /// The PaneType enum value.
    pane_type: PaneType,
};

/// All 10 built-in plugin types, registered at comptime.
pub const builtins = [_]PluginEntry{
    .{ .name = "terminal", .display_name = "Terminal", .pane_type = .terminal_pane },
    .{ .name = "webview", .display_name = "Web View", .pane_type = .webview },
    .{ .name = "notes", .display_name = "Notes", .pane_type = .notes },
    .{ .name = "screen_capture", .display_name = "Screen Capture", .pane_type = .screen_capture },
    .{ .name = "file_browser", .display_name = "File Browser", .pane_type = .file_browser },
    .{ .name = "process_monitor", .display_name = "Process Monitor", .pane_type = .process_monitor },
    .{ .name = "log_viewer", .display_name = "Log Viewer", .pane_type = .log_viewer },
    .{ .name = "markdown_preview", .display_name = "Markdown Preview", .pane_type = .markdown_preview },
    .{ .name = "system_info", .display_name = "System Info", .pane_type = .system_info },
    .{ .name = "git_status", .display_name = "Git Status", .pane_type = .git_status },
};

/// Create a PanePlugin by its string name using the registry.
/// Falls back to `plugin_mod.createPlugin` which handles terminal vs stub dispatch.
pub fn createByName(
    allocator: std.mem.Allocator,
    name: []const u8,
    index: usize,
    pane_config: ?*const config_mod.PaneConfig,
) !PanePlugin {
    // Validate that the name is known
    const ptype = PaneType.fromString(name) orelse return error.UnknownPluginType;
    _ = ptype;

    // Delegate to the existing createPlugin which already handles
    // terminal vs stub dispatch based on pane_config.pane_type.
    return plugin_mod.createPlugin(allocator, index, pane_config);
}

/// Return the number of registered plugin types.
pub fn typeCount() u32 {
    return builtins.len;
}

/// Return the internal name of the plugin type at the given index.
pub fn typeName(idx: u32) ?[]const u8 {
    if (idx >= builtins.len) return null;
    return builtins[idx].name;
}

/// Return the display name of the plugin type at the given index.
pub fn typeDisplayName(idx: u32) ?[]const u8 {
    if (idx >= builtins.len) return null;
    return builtins[idx].display_name;
}

/// Check if a plugin type name is registered.
pub fn hasType(name: []const u8) bool {
    inline for (builtins) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "registry has 10 builtins" {
    try testing.expectEqual(@as(u32, 10), typeCount());
}

test "registry type names" {
    try testing.expectEqualSlices(u8, "terminal", typeName(0).?);
    try testing.expectEqualSlices(u8, "git_status", typeName(9).?);
    try testing.expect(typeName(10) == null);
}

test "registry display names" {
    try testing.expectEqualSlices(u8, "Terminal", typeDisplayName(0).?);
    try testing.expectEqualSlices(u8, "Git Status", typeDisplayName(9).?);
}

test "registry hasType" {
    try testing.expect(hasType("terminal"));
    try testing.expect(hasType("webview"));
    try testing.expect(!hasType("unknown"));
}
