const std = @import("std");

// ---------------------------------------------------------------------------
// PTY stub for trm.
//
// In termania's Zig rewrite, this was a real PTY implementation using
// posix.openpty/forkpty. In trm, the terminal plugin will eventually
// delegate to Ghostty's Surface which handles PTY internally.
// This stub provides the interface that plugin.zig expects.
// ---------------------------------------------------------------------------

pub const Pty = struct {
    fd: std.posix.fd_t = -1,
    child_pid_val: ?u32 = null,
    alive: bool = false,

    /// Spawn a new PTY process. Stub — returns null in trm since
    /// Ghostty handles PTY lifecycle through its Surface.
    pub fn spawn(cols: u16, rows: u16, shell: ?[]const u8, cwd: ?[]const u8) !Pty {
        _ = cols;
        _ = rows;
        _ = shell;
        _ = cwd;
        // In trm, terminal panes use Ghostty surfaces which manage their own PTYs.
        // This stub returns a non-functional Pty.
        return .{};
    }

    pub fn read(self: Pty, buf: []u8) ?usize {
        _ = self;
        _ = buf;
        return null;
    }

    pub fn write(self: Pty, data: []const u8) !usize {
        _ = self;
        return data.len;
    }

    pub fn doResize(self: Pty, cols: u16, rows: u16) void {
        _ = self;
        _ = cols;
        _ = rows;
    }

    pub fn isAlive(self: Pty) bool {
        return self.alive;
    }

    pub fn childPid(self: Pty) ?u32 {
        return self.child_pid_val;
    }

    pub fn close_pty(self: *Pty) void {
        self.alive = false;
    }
};
