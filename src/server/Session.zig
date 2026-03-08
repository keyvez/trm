//! Per-session state in the trm-server daemon.
//!
//! Each session owns a PTY master fd and child process. When the GUI
//! is attached, PTY output is streamed directly. When detached, output
//! is buffered in a ring buffer for replay on reconnect.
const Session = @This();

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");

const log = std.log.scoped(.server_session);

// Inline PTY types and helpers (to avoid importing pty.zig which has a deep dependency chain).
// This daemon is macOS-only so we use direct system calls instead of @cImport.

const winsize = extern struct {
    ws_row: u16 = 100,
    ws_col: u16 = 80,
    ws_xpixel: u16 = 800,
    ws_ypixel: u16 = 600,
};

// macOS ioctl constants
const TIOCSCTTY: c_ulong = 536900705;
const TIOCSWINSZ: c_ulong = 2148037735;

// Declare C functions we need
extern "c" fn openpty(
    amaster: *posix.fd_t,
    aslave: *posix.fd_t,
    name: ?[*]u8,
    termp: ?*anyopaque,
    winp: ?*anyopaque,
) c_int;
extern "c" fn setsid() std.c.pid_t;
extern "c" fn ioctl(fd: posix.fd_t, request: c_ulong, ...) c_int;
extern "c" fn tcgetattr(fd: posix.fd_t, termios_p: *std.c.termios) c_int;
extern "c" fn tcsetattr(fd: posix.fd_t, optional_actions: c_int, termios_p: *const std.c.termios) c_int;

const TCSANOW: c_int = 0;

const PtyFds = struct {
    master: posix.fd_t,
    slave: posix.fd_t,
};

fn openPtyFds(size: winsize) !PtyFds {
    var sizeCopy = size;
    var master_fd: posix.fd_t = undefined;
    var slave_fd: posix.fd_t = undefined;
    if (openpty(
        &master_fd,
        &slave_fd,
        null,
        null,
        @ptrCast(&sizeCopy),
    ) < 0)
        return error.OpenptyFailed;
    errdefer {
        _ = posix.system.close(master_fd);
        _ = posix.system.close(slave_fd);
    }

    // Set CLOEXEC on master fd
    cloexec: {
        const flags = posix.fcntl(master_fd, posix.F.GETFD, 0) catch break :cloexec;
        _ = posix.fcntl(master_fd, posix.F.SETFD, flags | posix.FD_CLOEXEC) catch break :cloexec;
    }

    // Enable UTF-8 mode
    var attrs: std.c.termios = undefined;
    if (tcgetattr(master_fd, &attrs) != 0)
        return error.OpenptyFailed;
    attrs.iflag.IUTF8 = true;
    if (tcsetattr(master_fd, TCSANOW, &attrs) != 0)
        return error.OpenptyFailed;

    return .{ .master = master_fd, .slave = slave_fd };
}

fn setPtySize(master_fd: posix.fd_t, size: winsize) !void {
    if (ioctl(master_fd, TIOCSWINSZ, @intFromPtr(&size)) < 0)
        return error.IoctlFailed;
}

fn doChildPreExec(pty_fds: PtyFds) !void {
    // Reset signals
    var sa: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.ABRT, &sa, null);
    posix.sigaction(posix.SIG.ALRM, &sa, null);
    posix.sigaction(posix.SIG.BUS, &sa, null);
    posix.sigaction(posix.SIG.CHLD, &sa, null);
    posix.sigaction(posix.SIG.FPE, &sa, null);
    posix.sigaction(posix.SIG.HUP, &sa, null);
    posix.sigaction(posix.SIG.ILL, &sa, null);
    posix.sigaction(posix.SIG.INT, &sa, null);
    posix.sigaction(posix.SIG.PIPE, &sa, null);
    posix.sigaction(posix.SIG.SEGV, &sa, null);
    posix.sigaction(posix.SIG.TRAP, &sa, null);
    posix.sigaction(posix.SIG.TERM, &sa, null);
    posix.sigaction(posix.SIG.QUIT, &sa, null);

    // Create a new process group
    if (setsid() < 0) return error.ProcessGroupFailed;

    // Set controlling terminal
    switch (posix.errno(ioctl(pty_fds.slave, TIOCSCTTY, @as(c_ulong, 0)))) {
        .SUCCESS => {},
        else => return error.SetControllingTerminalFailed,
    }

    // Dup slave fd onto stdin, stdout, stderr
    const slave = pty_fds.slave;
    posix.dup2(slave, 0) catch return error.SetControllingTerminalFailed;
    posix.dup2(slave, 1) catch return error.SetControllingTerminalFailed;
    posix.dup2(slave, 2) catch return error.SetControllingTerminalFailed;

    // Close original slave fd (if it's not 0, 1, or 2)
    if (slave > 2) posix.close(slave);

    // Close master fd in child
    posix.close(pty_fds.master);
}

/// Default output buffer size (1MB).
pub const default_buffer_size = 1024 * 1024;

/// Grace period (in ms) to keep an exited session before cleanup.
pub const exit_grace_period_ms = 5 * 60 * 1000;

id: protocol.SessionId,
master_fd: posix.fd_t,
child_pid: ?posix.pid_t,
size: winsize,

/// Ring buffer for output replay on reconnect.
output_buffer: OutputRingBuffer,

/// Whether a GUI client is currently attached.
attached: bool,

/// File descriptor of the attached GUI client's connection, if any.
attached_fd: ?posix.fd_t,

/// Current working directory (updated via OSC 7 if supported).
cwd: ?[]u8,

/// The command that was used to start this session.
command: ?[]u8,

/// Whether the child process has exited.
child_exited: bool,

/// Exit code of the child process (valid only if child_exited is true).
exit_code: u32,

/// Time when child exited (for grace period cleanup).
exit_time: ?std.time.Instant,

/// Allocator for session-owned memory.
alloc: Allocator,

/// Read thread for PTY output.
read_thread: ?std.Thread,

/// Pipe to signal read thread to quit.
/// [0] = read end (read thread), [1] = write end (main thread).
quit_pipe: [2]posix.fd_t,

/// Whether the session has been deinitialized.
deinited: bool,

/// A simple ring buffer for storing output bytes.
pub const OutputRingBuffer = struct {
    buf: []u8,
    /// Write position (next byte to write).
    write_pos: usize,
    /// Number of valid bytes in the buffer.
    len: usize,

    pub fn init(alloc: Allocator, size: usize) !OutputRingBuffer {
        return .{
            .buf = try alloc.alloc(u8, size),
            .write_pos = 0,
            .len = 0,
        };
    }

    pub fn deinit(self: *OutputRingBuffer, alloc: Allocator) void {
        alloc.free(self.buf);
        self.* = undefined;
    }

    /// Write data into the ring buffer. Overwrites oldest data if full.
    pub fn write(self: *OutputRingBuffer, data: []const u8) void {
        if (data.len == 0) return;

        if (data.len >= self.buf.len) {
            // Data is larger than buffer; keep only the tail
            const offset = data.len - self.buf.len;
            @memcpy(self.buf, data[offset..][0..self.buf.len]);
            self.write_pos = 0;
            self.len = self.buf.len;
            return;
        }

        const first_chunk = @min(data.len, self.buf.len - self.write_pos);
        @memcpy(self.buf[self.write_pos..][0..first_chunk], data[0..first_chunk]);

        if (first_chunk < data.len) {
            const second_chunk = data.len - first_chunk;
            @memcpy(self.buf[0..second_chunk], data[first_chunk..]);
            self.write_pos = second_chunk;
        } else {
            self.write_pos += first_chunk;
            if (self.write_pos == self.buf.len) self.write_pos = 0;
        }

        self.len = @min(self.len + data.len, self.buf.len);
    }

    /// Read all valid data from the ring buffer in order.
    /// Returns two slices (the buffer may wrap around).
    pub fn readAll(self: *const OutputRingBuffer) struct { []const u8, []const u8 } {
        if (self.len == 0) return .{ &.{}, &.{} };

        if (self.len < self.buf.len) {
            // Buffer hasn't wrapped fully
            const start = if (self.write_pos >= self.len)
                self.write_pos - self.len
            else
                self.buf.len - (self.len - self.write_pos);

            if (start + self.len <= self.buf.len) {
                return .{ self.buf[start..][0..self.len], &.{} };
            } else {
                const first = self.buf[start..];
                const second = self.buf[0..self.write_pos];
                return .{ first, second };
            }
        } else {
            // Buffer is full
            if (self.write_pos == 0) {
                return .{ self.buf, &.{} };
            } else {
                return .{ self.buf[self.write_pos..], self.buf[0..self.write_pos] };
            }
        }
    }

    /// Clear the buffer.
    pub fn clear(self: *OutputRingBuffer) void {
        self.write_pos = 0;
        self.len = 0;
    }
};

/// Create a new session with a PTY and child process.
pub fn init(
    alloc: Allocator,
    cols: u16,
    rows: u16,
    width_px: u16,
    height_px: u16,
    cwd: ?[]const u8,
    cmd: ?[]const u8,
    env_data: ?[]const u8,
    env_count: u16,
) !*Session {
    const session = try alloc.create(Session);
    errdefer alloc.destroy(session);

    // Generate session ID
    const id = protocol.generateSessionId();

    // Open PTY
    const pty_fds = try openPtyFds(.{
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = width_px,
        .ws_ypixel = height_px,
    });
    errdefer posix.close(pty_fds.master);

    // Create output buffer
    var output_buffer = try OutputRingBuffer.init(alloc, default_buffer_size);
    errdefer output_buffer.deinit(alloc);

    // Duplicate cwd and cmd strings
    const cwd_copy: ?[]u8 = if (cwd) |s| try alloc.dupe(u8, s) else null;
    errdefer if (cwd_copy) |s| alloc.free(s);

    const cmd_copy: ?[]u8 = if (cmd) |s| try alloc.dupe(u8, s) else null;
    errdefer if (cmd_copy) |s| alloc.free(s);

    // Build environment — start with the daemon's own environment so the
    // child inherits PATH, HOME, TERM, etc.  Then overlay any env vars
    // sent by the GUI via the protocol.
    var env = try std.process.getEnvMap(alloc);
    errdefer env.deinit();

    // Overlay env from protocol data (GUI overrides)
    if (env_data) |data| {
        var offset: usize = 0;
        for (0..env_count) |_| {
            if (offset + 2 > data.len) break;
            const key_len = std.mem.readInt(u16, data[offset..][0..2], .big);
            offset += 2;
            if (offset + key_len > data.len) break;
            const key = data[offset..][0..key_len];
            offset += key_len;

            if (offset + 2 > data.len) break;
            const val_len = std.mem.readInt(u16, data[offset..][0..2], .big);
            offset += 2;
            if (offset + val_len > data.len) break;
            const val = data[offset..][0..val_len];
            offset += val_len;

            try env.put(key, val);
        }
    }

    // Ensure TERM is set
    if (env.get("TERM") == null) {
        try env.put("TERM", "xterm-256color");
    }

    // Determine shell — use SHELL env var or /bin/zsh.
    const user_shell: [:0]const u8 = if (env.get("SHELL")) |s|
        try alloc.dupeZ(u8, s)
    else
        try alloc.dupeZ(u8, "/bin/zsh");
    defer alloc.free(user_shell);

    // When a custom command is given (e.g. "bash -c '...'"), run it through
    // the user's shell with -c so the full command string is interpreted correctly.
    // Otherwise, just start an interactive shell.
    const cmd_duped: ?[:0]const u8 = if (cmd) |s| try alloc.dupeZ(u8, s) else null;
    defer if (cmd_duped) |c| alloc.free(c);

    const shell_cmd = user_shell;

    // Build argv and envp BEFORE fork — allocating after fork is unsafe.
    const minus_c: [:0]const u8 = "-c";
    var argv_buf: [4:null]?[*:0]const u8 = .{ shell_cmd, null, null, null };
    if (cmd_duped) |c| {
        argv_buf[1] = minus_c;
        argv_buf[2] = c;
    }

    var env_list: std.ArrayListUnmanaged(?[*:0]const u8) = .{};
    defer env_list.deinit(alloc);
    {
        var env_it = env.hash_map.iterator();
        while (env_it.next()) |entry| {
            const env_str = try std.fmt.allocPrintSentinel(alloc, "{s}={s}", .{
                entry.key_ptr.*,
                entry.value_ptr.*,
            }, 0);
            try env_list.append(alloc, env_str);
        }
        try env_list.append(alloc, null);
    }
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(env_list.items.ptr);

    // Fork the child process
    const fork_result = try posix.fork();
    if (fork_result == 0) {
        // === CHILD PROCESS ===
        // Set up the PTY slave as controlling terminal
        doChildPreExec(pty_fds) catch {
            posix.exit(1);
        };

        // Set working directory
        if (cwd) |dir| {
            std.posix.chdir(dir) catch {};
        }

        // Exec — noreturn on success, returns error on failure.
        const err = posix.execvpeZ(shell_cmd, &argv_buf, envp);
        switch (err) {
            else => posix.exit(1),
        }
    }

    // === PARENT PROCESS ===
    const pid = fork_result;

    // Close slave fd - child owns it now
    posix.close(pty_fds.slave);

    // Create quit pipe for read thread
    const quit_pipe = try posix.pipe2(.{ .CLOEXEC = true });

    session.* = .{
        .id = id,
        .master_fd = pty_fds.master,
        .child_pid = pid,
        .size = .{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = width_px,
            .ws_ypixel = height_px,
        },
        .output_buffer = output_buffer,
        .attached = false,
        .attached_fd = null,
        .cwd = cwd_copy,
        .command = cmd_copy,
        .child_exited = false,
        .exit_code = 0,
        .exit_time = null,
        .alloc = alloc,
        .read_thread = null,
        .quit_pipe = quit_pipe,
        .deinited = false,
    };

    return session;
}

/// Start the read thread that reads from PTY and forwards/buffers output.
pub fn startReadThread(self: *Session) !void {
    self.read_thread = try std.Thread.spawn(.{}, readThreadMain, .{self});
}

/// The read thread main loop. Reads from PTY master fd and either
/// forwards to attached client or buffers for later replay.
fn readThreadMain(self: *Session) void {
    const fd = self.master_fd;
    const quit_fd = self.quit_pipe[0];
    defer posix.close(quit_fd);

    // Set master fd to non-blocking
    if (posix.fcntl(fd, posix.F.GETFL, 0)) |flags| {
        _ = posix.fcntl(
            fd,
            posix.F.SETFL,
            flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })),
        ) catch {};
    } else |_| {}

    var pollfds: [2]posix.pollfd = .{
        .{ .fd = fd, .events = posix.POLL.IN, .revents = undefined },
        .{ .fd = quit_fd, .events = posix.POLL.IN, .revents = undefined },
    };

    var buf: [4096]u8 = undefined;
    while (true) {
        // Try to read as much as possible before polling
        while (true) {
            const n = posix.read(fd, &buf) catch |err| {
                switch (err) {
                    error.NotOpenForReading, error.InputOutput => {
                        // PTY closed — child probably exited
                        self.handleChildExit();
                        return;
                    },
                    error.WouldBlock => break,
                    else => {
                        log.err("session read error: {}", .{err});
                        return;
                    },
                }
            };
            if (n == 0) {
                self.handleChildExit();
                return;
            }

            self.processOutput(buf[0..n]);
        }

        // Wait for data or quit signal
        _ = posix.poll(&pollfds, -1) catch |err| {
            log.warn("poll failed in session read thread: {}", .{err});
            return;
        };

        if (pollfds[1].revents & posix.POLL.IN != 0) {
            return;
        }

        if (pollfds[0].revents & posix.POLL.HUP != 0) {
            self.handleChildExit();
            return;
        }
    }
}

/// Process output from PTY: forward to attached client and/or buffer.
fn processOutput(self: *Session, data: []const u8) void {
    // Always buffer (for replay on reconnect)
    self.output_buffer.write(data);

    // If attached, forward to client
    if (self.attached) {
        if (self.attached_fd) |client_fd| {
            // Serialize and send OUTPUT message
            var payload_buf: [16 + 4096]u8 = undefined;
            if (data.len + 16 <= payload_buf.len) {
                @memcpy(payload_buf[0..16], &self.id);
                @memcpy(payload_buf[16..][0..data.len], data);
                protocol.writeMessage(
                    client_fd,
                    @intFromEnum(protocol.ServerMsgType.output),
                    payload_buf[0 .. 16 + data.len],
                ) catch |err| {
                    log.warn("failed to send output to client: {}", .{err});
                    self.detach();
                };
            } else {
                // Data too large for stack buffer, allocate
                const payload = protocol.serializeOutput(
                    self.alloc,
                    self.id,
                    data,
                ) catch |err| {
                    log.warn("failed to allocate output payload: {}", .{err});
                    return;
                };
                defer self.alloc.free(payload);
                protocol.writeMessage(
                    client_fd,
                    @intFromEnum(protocol.ServerMsgType.output),
                    payload,
                ) catch |err| {
                    log.warn("failed to send output to client: {}", .{err});
                    self.detach();
                };
            }
        }
    }
}

/// Handle child process exit.
fn handleChildExit(self: *Session) void {
    if (self.child_exited) return;

    // Try to get exit code
    if (self.child_pid) |pid| {
        const result = posix.waitpid(pid, std.c.W.NOHANG);
        if (result.pid != 0) {
            if (posix.W.IFEXITED(result.status)) {
                self.exit_code = @intCast(posix.W.EXITSTATUS(result.status));
            } else if (posix.W.IFSIGNALED(result.status)) {
                self.exit_code = 128 + @as(u32, @intCast(posix.W.TERMSIG(result.status)));
            } else {
                self.exit_code = 1;
            }
        }
    }

    self.child_exited = true;
    self.exit_time = std.time.Instant.now() catch null;

    // Notify attached client
    if (self.attached) {
        if (self.attached_fd) |client_fd| {
            const payload = protocol.serializeSessionExited(self.id, self.exit_code);
            protocol.writeMessage(
                client_fd,
                @intFromEnum(protocol.ServerMsgType.session_exited),
                &payload,
            ) catch {};
        }
    }
}

/// Attach a GUI client to this session.
pub fn attach(self: *Session, client_fd: posix.fd_t) !void {
    self.attached = true;
    self.attached_fd = client_fd;

    // Send SESSION_ATTACHED with buffered output
    const slices = self.output_buffer.readAll();
    const buffered_len: u32 = @intCast(slices[0].len + slices[1].len);
    log.info("attach: sending buffered_len={d} (slice0={d}, slice1={d})", .{ buffered_len, slices[0].len, slices[1].len });
    const header = protocol.serializeSessionAttachedHeader(self.id, buffered_len);

    // Build full payload: header + buffered data
    const payload = try self.alloc.alloc(u8, header.len + buffered_len);
    defer self.alloc.free(payload);
    @memcpy(payload[0..header.len], &header);
    @memcpy(payload[header.len..][0..slices[0].len], slices[0]);
    @memcpy(payload[header.len + slices[0].len ..][0..slices[1].len], slices[1]);

    try protocol.writeMessage(
        client_fd,
        @intFromEnum(protocol.ServerMsgType.session_attached),
        payload,
    );

    // NOTE: We do NOT clear the buffer here. The ring buffer keeps the
    // last N bytes of all output, which allows future reconnections to
    // replay the terminal state even if the client was attached when
    // most of the output occurred.

    // If child already exited, notify immediately
    if (self.child_exited) {
        const exit_payload = protocol.serializeSessionExited(self.id, self.exit_code);
        protocol.writeMessage(
            client_fd,
            @intFromEnum(protocol.ServerMsgType.session_exited),
            &exit_payload,
        ) catch {};
    }
}

/// Detach the GUI client from this session.
pub fn detach(self: *Session) void {
    self.attached = false;
    self.attached_fd = null;
}

/// Write data to the PTY (from GUI client input).
pub fn writeToPty(self: *Session, data: []const u8) !void {
    if (self.child_exited) return;
    var written: usize = 0;
    while (written < data.len) {
        const n = posix.write(self.master_fd, data[written..]) catch |err| {
            return err;
        };
        written += n;
    }
}

/// Resize the PTY.
pub fn resize(self: *Session, cols: u16, rows: u16, width_px: u16, height_px: u16) !void {
    self.size = .{
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = width_px,
        .ws_ypixel = height_px,
    };
    try setPtySize(self.master_fd, self.size);
}

/// Check if this session should be cleaned up.
pub fn shouldCleanup(self: *const Session) bool {
    if (!self.child_exited) return false;
    if (self.attached) return false;

    const exit_time = self.exit_time orelse return true;
    const now = std.time.Instant.now() catch return false;
    const elapsed_ns = now.since(exit_time);
    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
    return elapsed_ms >= exit_grace_period_ms;
}

/// Stop the session: kill child, stop read thread, clean up.
pub fn deinit(self: *Session) void {
    if (self.deinited) return;
    self.deinited = true;

    // Signal read thread to quit
    _ = posix.write(self.quit_pipe[1], "x") catch {};
    posix.close(self.quit_pipe[1]);

    // Wait for read thread
    if (self.read_thread) |thread| {
        thread.join();
    }

    // Kill child process if still running
    if (!self.child_exited) {
        if (self.child_pid) |pid| {
            // Send SIGHUP then SIGKILL
            _ = std.c.kill(pid, std.posix.SIG.HUP);
            // Give it a moment, then force kill
            posix.nanosleep(0, 100 * std.time.ns_per_ms);
            _ = posix.waitpid(pid, std.c.W.NOHANG);
            _ = std.c.kill(pid, std.posix.SIG.KILL);
            _ = posix.waitpid(pid, 0);
        }
    }

    // Clean up PTY
    _ = posix.system.close(self.master_fd);

    // Free memory
    self.output_buffer.deinit(self.alloc);
    if (self.cwd) |s| self.alloc.free(s);
    if (self.command) |s| self.alloc.free(s);

    self.alloc.destroy(self);
}

test "output ring buffer basic" {
    const alloc = std.testing.allocator;
    var buf = try OutputRingBuffer.init(alloc, 8);
    defer buf.deinit(alloc);

    buf.write("hello");
    const slices = buf.readAll();
    try std.testing.expectEqualStrings("hello", slices[0]);
    try std.testing.expectEqualStrings("", slices[1]);
}

test "output ring buffer wrap" {
    const alloc = std.testing.allocator;
    var buf = try OutputRingBuffer.init(alloc, 8);
    defer buf.deinit(alloc);

    buf.write("12345678"); // Fill buffer exactly
    buf.write("ab"); // Overwrite first 2 bytes

    const slices = buf.readAll();
    // Should contain "345678ab" (oldest data from position 2)
    const combined = try std.fmt.allocPrint(alloc, "{s}{s}", .{ slices[0], slices[1] });
    defer alloc.free(combined);
    try std.testing.expectEqualStrings("345678ab", combined);
}

test "output ring buffer overflow" {
    const alloc = std.testing.allocator;
    var buf = try OutputRingBuffer.init(alloc, 4);
    defer buf.deinit(alloc);

    buf.write("abcdefgh"); // Twice the buffer size
    const slices = buf.readAll();
    const combined = try std.fmt.allocPrint(alloc, "{s}{s}", .{ slices[0], slices[1] });
    defer alloc.free(combined);
    try std.testing.expectEqualStrings("efgh", combined);
}
