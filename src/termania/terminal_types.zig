const std = @import("std");

// ---------------------------------------------------------------------------
// Terminal types shim for trm.
//
// These types were originally defined in termania's terminal.zig and
// ghostty_terminal.zig. In trm, the TerminalPlugin will eventually wrap
// a Ghostty Surface, but these types are needed for the plugin vtable,
// renderer color resolution, and C API to compile.
// ---------------------------------------------------------------------------

/// Terminal cell color — matches the tagged union from termania's terminal.zig.
/// Used by the renderer for color resolution and by the C API for color queries.
pub const CellColor = union(enum) {
    /// Use the default foreground or background color.
    default,
    /// ANSI color index (0-15).
    ansi: u8,
    /// 256-color palette index (0-255).
    indexed: u8,
    /// Direct RGB color.
    rgb: RGBColor,
};

pub const RGBColor = struct {
    r: u8,
    g: u8,
    b: u8,
};

/// C-compatible cell struct for FFI with Swift/Metal frontend.
/// This is the cell format that plugins produce for rendering.
/// 16 bytes, packed for efficient GPU upload.
pub const CCell = extern struct {
    /// Unicode codepoint.
    ch: u32 = 0,
    /// Foreground color components.
    fg_r: u8 = 0,
    fg_g: u8 = 0,
    fg_b: u8 = 0,
    /// Foreground color type: 0=default, 1=ansi, 2=indexed, 3=rgb.
    fg_type: u8 = 0,
    /// Background color components.
    bg_r: u8 = 0,
    bg_g: u8 = 0,
    bg_b: u8 = 0,
    /// Background color type: 0=default, 1=ansi, 2=indexed, 3=rgb.
    bg_type: u8 = 0,
    /// Flags: bit0=bold, bit1=italic, bit2=underline, bit3=inverse.
    flags: u8 = 0,
    /// Padding for alignment.
    _pad: [3]u8 = .{ 0, 0, 0 },
};

/// Stub GhosttyTerminal — will be replaced with a Ghostty Surface wrapper
/// in Phase 3. For now provides the interface that TerminalPlugin needs.
pub const GhosttyTerminal = struct {
    allocator: std.mem.Allocator,
    cols: usize,
    rows: usize,
    title_buf: [128]u8 = undefined,
    title_len: usize = 0,
    dirty: bool = true,
    has_error_flag: bool = false,
    scroll_offset: usize = 0,
    cursor_row: usize = 0,
    cursor_col: usize = 0,

    pub fn init(allocator: std.mem.Allocator, cols: usize, rows: usize, title: []const u8) !*GhosttyTerminal {
        const self = try allocator.create(GhosttyTerminal);
        self.* = .{
            .allocator = allocator,
            .cols = cols,
            .rows = rows,
        };
        const len = @min(title.len, self.title_buf.len);
        @memcpy(self.title_buf[0..len], title[0..len]);
        self.title_len = len;
        return self;
    }

    pub fn deinit(self: *GhosttyTerminal) void {
        self.allocator.destroy(self);
    }

    pub fn getTitle(self: *const GhosttyTerminal) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    pub fn setTitle(self: *GhosttyTerminal, title: []const u8) void {
        const len = @min(title.len, self.title_buf.len);
        @memcpy(self.title_buf[0..len], title[0..len]);
        self.title_len = len;
    }

    pub fn processOutput(self: *GhosttyTerminal, data: []const u8) void {
        _ = data;
        self.dirty = true;
    }

    pub fn detectErrors(self: *GhosttyTerminal, data: []const u8) void {
        _ = data;
        _ = self;
    }

    pub fn resize(self: *GhosttyTerminal, cols: usize, rows: usize) void {
        self.cols = cols;
        self.rows = rows;
        self.dirty = true;
    }

    pub fn getCells(self: *GhosttyTerminal, buf: []CCell) usize {
        const n = @min(self.cols * self.rows, buf.len);
        for (0..n) |i| {
            buf[i] = .{ .ch = ' ' };
        }
        return n;
    }

    pub fn cursorPosition(self: *const GhosttyTerminal) struct { row: usize, col: usize } {
        return .{ .row = self.cursor_row, .col = self.cursor_col };
    }

    pub fn isScrolled(self: *const GhosttyTerminal) bool {
        return self.scroll_offset > 0;
    }

    pub fn scrollToBottom(self: *GhosttyTerminal) void {
        self.scroll_offset = 0;
    }

    pub fn scrollViewUp(self: *GhosttyTerminal, lines: usize) void {
        self.scroll_offset += lines;
    }

    pub fn scrollViewDown(self: *GhosttyTerminal, lines: usize) void {
        if (lines > self.scroll_offset) {
            self.scroll_offset = 0;
        } else {
            self.scroll_offset -= lines;
        }
    }

    pub fn visibleText(self: *const GhosttyTerminal, buf: []u8) usize {
        _ = self;
        if (buf.len > 0) buf[0] = 0;
        return 0;
    }

    pub fn hasError(self: *const GhosttyTerminal) bool {
        return self.has_error_flag;
    }

    pub fn isDirty(self: *const GhosttyTerminal) bool {
        return self.dirty;
    }

    pub fn clearDirty(self: *GhosttyTerminal) void {
        self.dirty = false;
    }
};
