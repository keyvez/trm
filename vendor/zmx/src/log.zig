const std = @import("std");

pub const LogSystem = struct {
    file: ?std.fs.File = null,
    mutex: std.Thread.Mutex = .{},
    current_size: u64 = 0,
    max_size: u64 = 5 * 1024 * 1024, // 5MB
    path: []const u8 = "",
    alloc: std.mem.Allocator = undefined,
    mode: u32 = 0o640,

    pub fn init(self: *LogSystem, alloc: std.mem.Allocator, path: []const u8, mode: u32) !void {
        self.alloc = alloc;
        self.path = try alloc.dupe(u8, path);
        self.mode = mode;

        const file = try openAppend(path, self.mode);

        self.current_size = try file.getEndPos();
        self.file = file;
    }

    pub fn deinit(self: *LogSystem) void {
        if (self.file) |f| f.close();
        if (self.path.len > 0) self.alloc.free(self.path);
    }

    pub fn log(
        self: *LogSystem,
        comptime level: std.log.Level,
        comptime scope: @Type(.enum_literal),
        comptime format: []const u8,
        args: anytype,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.file == null) {
            std.log.defaultLog(level, scope, format, args);
            return;
        }

        if (self.current_size >= self.max_size) {
            self.rotate() catch |err| {
                std.debug.print("Log rotation failed: {s}\n", .{@errorName(err)});
            };
        }

        const now = std.time.milliTimestamp();
        const prefix = "[{d}] [{s}] ({s}): ";
        const scope_name = @tagName(scope);
        const level_name = level.asText();

        const prefix_args = .{
            now,
            level_name,
            scope_name,
        };

        if (self.file) |f| {
            const prefix_len = std.fmt.count(prefix, prefix_args);
            const msg_len = std.fmt.count(format, args);
            const newline_len = 1;
            const total_len = prefix_len + msg_len + newline_len;
            self.current_size += total_len;

            var buf: [4096]u8 = undefined;
            var w = f.writerStreaming(&buf);
            w.interface.print(prefix ++ format ++ "\n", prefix_args ++ args) catch {};
            w.interface.flush() catch {};
        }
    }

    fn rotate(self: *LogSystem) !void {
        if (self.file) |f| {
            f.close();
            self.file = null;
        }

        const old_path = try std.fmt.allocPrint(self.alloc, "{s}.old", .{self.path});
        defer self.alloc.free(old_path);

        std.fs.renameAbsolute(self.path, old_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        self.file = try openAppend(self.path, self.mode);
        self.current_size = 0;
    }
};

/// Open (creating if needed) a log file in O_APPEND mode.
///
/// Every write must land at the file's *current* end, resolved by the kernel
/// at write time. Several processes share one log — every `zmx` client writes
/// to `<dir>/logs/zmx.log` — and each one used to open the file, seek to the
/// end it observed, and write there. Two clients starting at once therefore
/// wrote at the same offset, so one overwrote the other's line: the shared log
/// filled with torn entries and mismatched key/value pairs, which is exactly
/// the log you need intact when you are trying to explain why a session went
/// away. O_APPEND makes each write atomic with respect to the offset, so lines
/// from concurrent processes interleave whole instead of clobbering.
///
/// Zig's `File.OpenFlags`/`CreateFlags` expose no append bit, hence the raw
/// `posix.open`.
fn openAppend(path: []const u8, mode: u32) !std.fs.File {
    const flags: std.posix.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
    };
    const fd = try std.posix.open(path, flags, @intCast(mode));
    return .{ .handle = fd };
}
