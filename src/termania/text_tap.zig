const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const llm = @import("llm.zig");

// ---------------------------------------------------------------------------
// Text Tap Server — Unix socket API for external tool integration.
//
// Protocol: Newline-delimited JSON over a Unix domain socket.
// Follows the same architecture as the Rust version.
// ---------------------------------------------------------------------------

/// Command from a tap client.
pub const TapCommand = union(enum) {
    /// Legacy: send raw input to a target.
    send: struct {
        target: TapTarget,
        input: []const u8,
    },
    /// Full TermaniaAction.
    action: llm.TermaniaAction,
};

pub const TapTarget = union(enum) {
    pane: usize,
    all: void,
};

/// cmux-compatible API method identifiers.
pub const CmuxMethod = enum(u8) {
    system_ping = 0,
    system_capabilities = 1,
    system_identify = 2,
    surface_list = 3,
    surface_send_text = 4,
    surface_send_key = 5,
    surface_split = 6,
    surface_focus = 7,
    workspace_list = 8,
    workspace_current = 9,
    notification_create = 10,

    pub fn fromString(s: []const u8) ?CmuxMethod {
        if (std.mem.eql(u8, s, "system.ping")) return .system_ping;
        if (std.mem.eql(u8, s, "system.capabilities")) return .system_capabilities;
        if (std.mem.eql(u8, s, "system.identify")) return .system_identify;
        if (std.mem.eql(u8, s, "surface.list")) return .surface_list;
        if (std.mem.eql(u8, s, "surface.send_text")) return .surface_send_text;
        if (std.mem.eql(u8, s, "surface.send_key")) return .surface_send_key;
        if (std.mem.eql(u8, s, "surface.split")) return .surface_split;
        if (std.mem.eql(u8, s, "surface.focus")) return .surface_focus;
        if (std.mem.eql(u8, s, "workspace.list")) return .workspace_list;
        if (std.mem.eql(u8, s, "workspace.current")) return .workspace_current;
        if (std.mem.eql(u8, s, "notification.create")) return .notification_create;
        return null;
    }
};

/// A pending cmux query waiting for Swift to respond.
pub const CmuxPendingQuery = struct {
    client_fd: posix.socket_t,
    request_id: [64]u8 = undefined,
    request_id_len: usize = 0,
    method: CmuxMethod,
};

/// A cmux response queued by Swift, ready to send to the client.
pub const CmuxResponse = struct {
    client_fd: posix.socket_t,
    data: []const u8, // heap-allocated JSON response with trailing newline
};

/// A connected tap client.
pub const ClientConnection = struct {
    fd: posix.socket_t,
    subscribed: bool = false,
    read_buf: [4096]u8 = undefined,
    read_pos: usize = 0,
    /// True while discarding the tail of a line that overflowed read_buf.
    /// Cleared when the line's terminating newline is consumed.
    discarding_line: bool = false,
    /// Optional app name provided with the subscribe command (heap-allocated).
    app_name: ?[]const u8 = null,
    /// The pane this client marked as connected (via mark_connected), or null.
    connected_pane: ?u32 = null,
};

/// Text Tap server state.
pub const TextTapServer = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    pane_count: usize = 0,
    running: bool = false,

    /// Millisecond timestamp of the last poll(), used by pollThrottled().
    last_poll_ms: i64 = 0,
    /// Listener socket file descriptor.
    listener_fd: ?posix.socket_t = null,
    /// Connected clients.
    clients: std.array_list.Managed(ClientConnection),
    /// Pending commands from tap clients.
    pending_commands: std.array_list.Managed(TapCommand),
    /// Bitset of panes targeted by send/send_command actions.
    /// Bit N is set if pane index N was targeted. NOT auto-cleared.
    active_send_panes: u64 = 0,
    /// Set of stable pane IDs targeted by send_command actions.
    active_pane_ids: std.AutoHashMap(u32, void) = undefined,
    /// Pending cmux queries for Swift to process.
    cmux_pending: std.array_list.Managed(CmuxPendingQuery),
    /// Queued cmux responses from Swift, ready to write to clients.
    cmux_responses: std.array_list.Managed(CmuxResponse),

    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8) TextTapServer {
        return .{
            .allocator = allocator,
            .socket_path = socket_path,
            .pending_commands = std.array_list.Managed(TapCommand).init(allocator),
            .clients = std.array_list.Managed(ClientConnection).init(allocator),
            .active_pane_ids = std.AutoHashMap(u32, void).init(allocator),
            .cmux_pending = std.array_list.Managed(CmuxPendingQuery).init(allocator),
            .cmux_responses = std.array_list.Managed(CmuxResponse).init(allocator),
        };
    }

    pub fn deinit(self: *TextTapServer) void {
        if (self.running) self.stop();
        for (self.cmux_responses.items) |r| self.allocator.free(r.data);
        self.cmux_responses.deinit();
        self.cmux_pending.deinit();
        // Commands queued after the last drain still own their strings.
        for (self.pending_commands.items) |cmd| {
            switch (cmd) {
                .send => |s| self.allocator.free(s.input),
                .action => |a| llm.freeAction(self.allocator, a),
            }
        }
        self.pending_commands.deinit();
        self.clients.deinit();
        self.active_pane_ids.deinit();
    }

    pub fn setPaneCount(self: *TextTapServer, count: usize) void {
        self.pane_count = count;
    }

    /// Drain pending commands.
    pub fn drainCommands(self: *TextTapServer) []const TapCommand {
        const items = self.pending_commands.toOwnedSlice() catch return &.{};
        return items;
    }

    /// Start the server: create Unix socket, bind, listen, set non-blocking.
    pub fn start(self: *TextTapServer) !void {
        if (self.running) return;

        // Remove any stale socket file.
        removeSocketFile(self.socket_path);

        // Create Unix domain socket (NONBLOCK/CLOEXEC not supported as socket
        // type flags on macOS — set them separately via fcntl).
        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);

        // Set non-blocking and close-on-exec via raw fcntl.
        {
            const F_GETFL = 3;
            const F_SETFL = 4;
            const F_SETFD = 2;
            const O_NONBLOCK = 0x0004; // macOS
            const FD_CLOEXEC = 1;
            const flags = posix.fcntl(fd, F_GETFL, 0) catch 0;
            _ = posix.fcntl(fd, F_SETFL, flags | O_NONBLOCK) catch {};
            _ = posix.fcntl(fd, F_SETFD, FD_CLOEXEC) catch {};
        }

        // Bind to the socket path.
        var addr = std.net.Address.initUnix(self.socket_path) catch return error.NameTooLong;
        try posix.bind(fd, &addr.any, addr.getOsSockLen());

        // Listen with a small backlog.
        try posix.listen(fd, 8);

        self.listener_fd = fd;
        self.running = true;
    }

    /// Stop the server: close all client connections, close listener, remove socket file.
    pub fn stop(self: *TextTapServer) void {
        if (!self.running) return;

        // Close all client connections.
        for (self.clients.items) |client| {
            posix.close(client.fd);
            if (client.app_name) |name| self.allocator.free(name);
        }
        self.clients.clearRetainingCapacity();

        // Close listener socket.
        if (self.listener_fd) |fd| {
            posix.close(fd);
            self.listener_fd = null;
        }

        // Remove socket file.
        removeSocketFile(self.socket_path);

        self.running = false;
    }

    /// Throttled poll for the C-API accessor functions (is_active, app_name,
    /// client_count, ...). The Swift UI calls those per pane per render pass,
    /// and each unthrottled poll costs accept/read syscalls per client. The
    /// main event loop's termania_poll still calls poll() directly each tick,
    /// so this only bounds the extra accessor-driven polls.
    pub fn pollThrottled(self: *TextTapServer) void {
        const now = std.time.milliTimestamp();
        if (now - self.last_poll_ms < poll_throttle_ms) return;
        self.poll();
    }

    const poll_throttle_ms: i64 = 100;

    /// Non-blocking poll: accept new connections and read from existing clients.
    /// Should be called from the main event loop each tick.
    pub fn poll(self: *TextTapServer) void {
        if (!self.running) return;
        self.last_poll_ms = std.time.milliTimestamp();

        // Accept new connections (non-blocking).
        self.acceptNewClients();

        // Read from existing clients (iterate in reverse for safe removal).
        self.readFromClients();

        // Flush any queued cmux responses to their clients.
        self.sendCmuxResponses();
    }

    /// Accept all pending connections on the listener socket.
    fn acceptNewClients(self: *TextTapServer) void {
        const listener = self.listener_fd orelse return;

        while (true) {
            const result = posix.accept(listener, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC) catch |err| {
                switch (err) {
                    error.WouldBlock => return, // No more pending connections.
                    else => return, // Unexpected error, stop accepting.
                }
            };
            self.clients.append(.{ .fd = result }) catch {
                posix.close(result);
            };
        }
    }

    /// Check if a client fd has pending cmux queries or responses.
    fn hasPendingCmux(self: *TextTapServer, fd: posix.socket_t) bool {
        for (self.cmux_pending.items) |q| {
            if (q.client_fd == fd) return true;
        }
        for (self.cmux_responses.items) |r| {
            if (r.client_fd == fd) return true;
        }
        return false;
    }

    /// Read available data from all connected clients and process commands.
    fn readFromClients(self: *TextTapServer) void {
        var i: usize = self.clients.items.len;
        while (i > 0) {
            i -= 1;
            const alive = self.readFromClient(i);
            if (!alive) {
                // Don't close/remove if this client has pending cmux queries.
                // The fd must stay open so Swift can respond asynchronously.
                if (self.hasPendingCmux(self.clients.items[i].fd)) continue;
                const client = self.clients.orderedRemove(i);
                posix.close(client.fd);
                if (client.app_name) |name| self.allocator.free(name);
                // Clear the pane this client had marked as connected.
                if (client.connected_pane) |pane| {
                    _ = self.active_pane_ids.remove(pane);
                    if (pane < 64) self.active_send_panes &= ~(@as(u64, 1) << @intCast(pane));
                }
            }
        }

        // Safety net: if all clients have disconnected, clear all active
        // state so stale pills/indicators don't linger.
        if (self.clients.items.len == 0) {
            self.active_send_panes = 0;
            self.active_pane_ids.clearRetainingCapacity();
        }
    }

    /// Read from a single client. Returns false if the client should be removed.
    fn readFromClient(self: *TextTapServer, idx: usize) bool {
        const client = &self.clients.items[idx];
        const remaining = client.read_buf[client.read_pos..];
        if (remaining.len == 0) {
            // Buffer is full with no newline — the line is too large for the
            // protocol. Discard what's buffered and keep discarding until the
            // line's terminating newline, so the NEXT message re-aligns
            // instead of the tail being parsed as a fresh (corrupt) message.
            client.read_pos = 0;
            client.discarding_line = true;
            self.respond(idx, "{\"error\": \"message too large\"}\n");
            return true;
        }

        const n = posix.read(client.fd, remaining) catch |err| {
            switch (err) {
                error.WouldBlock => return true, // No data available.
                else => return false, // Error, disconnect client.
            }
        };

        if (n == 0) return false; // Client disconnected (EOF).

        client.read_pos += n;

        // Process complete lines (newline-delimited JSON).
        self.processClientBuffer(idx);

        return true;
    }

    /// Process newline-delimited messages in a client's buffer.
    fn processClientBuffer(self: *TextTapServer, idx: usize) void {
        const client = &self.clients.items[idx];
        var offset: usize = 0;

        // Skip the remainder of an oversized line that is being discarded.
        if (client.discarding_line) {
            const buffered = client.read_buf[0..client.read_pos];
            if (std.mem.indexOf(u8, buffered, "\n")) |nl| {
                client.discarding_line = false;
                offset = nl + 1;
            } else {
                // Terminator not seen yet; drop everything and keep waiting.
                client.read_pos = 0;
                return;
            }
        }

        while (offset < client.read_pos) {
            // Find the next newline.
            const slice = client.read_buf[offset..client.read_pos];
            const nl = std.mem.indexOf(u8, slice, "\n") orelse break;
            const line = slice[0..nl];

            if (line.len > 0) {
                self.handleClientMessage(idx, line);
            }

            offset += nl + 1;
        }

        // Compact: move unconsumed data to the beginning.
        if (offset > 0) {
            const leftover = client.read_pos - offset;
            if (leftover > 0) {
                std.mem.copyForwards(u8, &client.read_buf, client.read_buf[offset..client.read_pos]);
            }
            client.read_pos = leftover;
        }
    }

    /// Handle a single JSON message from a client.
    fn handleClientMessage(self: *TextTapServer, idx: usize, msg: []const u8) void {
        const trimmed = std.mem.trim(u8, msg, " \t\r");
        if (trimmed.len == 0) return;

        // Detect cmux protocol: messages with "method" key.
        if (extractQuotedValueStatic(trimmed, "method")) |_| {
            self.handleCmuxMessage(idx, trimmed);
            return;
        }

        // Extract the "type" field.
        const msg_type = extractQuotedValueStatic(trimmed, "type") orelse return;

        if (std.mem.eql(u8, msg_type, "subscribe")) {
            self.clients.items[idx].subscribed = true;
            // Parse optional "app" field for the connection pill label.
            if (extractQuotedValue(self.allocator, trimmed, "app") catch null) |name| {
                if (self.clients.items[idx].app_name) |old| self.allocator.free(old);
                self.clients.items[idx].app_name = name;
            }
            self.respond(idx, "{\"status\": \"subscribed\"}\n");
        } else if (std.mem.eql(u8, msg_type, "unsubscribe")) {
            self.clients.items[idx].subscribed = false;
            self.respond(idx, "{\"status\": \"unsubscribed\"}\n");
        } else if (std.mem.eql(u8, msg_type, "list_panes")) {
            var buf: [128]u8 = undefined;
            const response = std.fmt.bufPrint(&buf, "{{\"pane_count\": {d}}}\n", .{self.pane_count}) catch return;
            self.respond(idx, response);
        } else if (std.mem.eql(u8, msg_type, "read_pane")) {
            const pane = extractNumberAfter(trimmed, "pane") orelse {
                self.respond(idx, "{\"error\": \"missing pane\"}\n");
                return;
            };
            // Enqueue a read_pane as an action — the main loop will
            // gather visible text and call broadcast. For now, acknowledge.
            var buf: [128]u8 = undefined;
            const response = std.fmt.bufPrint(&buf, "{{\"status\": \"read_pane_queued\", \"pane\": {d}}}\n", .{pane}) catch return;
            self.respond(idx, response);
        } else if (std.mem.eql(u8, msg_type, "send")) {
            const pane = extractNumberAfter(trimmed, "pane") orelse return;
            const text = extractQuotedValue(self.allocator, trimmed, "text") catch return orelse return;
            self.pending_commands.append(.{
                .send = .{
                    .target = .{ .pane = pane },
                    .input = text,
                },
            }) catch {
                self.allocator.free(text);
                return;
            };
            if (pane < 64) self.active_send_panes |= @as(u64, 1) << @intCast(pane);
            self.respond(idx, "{\"status\": \"queued\"}\n");
        } else if (std.mem.eql(u8, msg_type, "send_all")) {
            const text = extractQuotedValue(self.allocator, trimmed, "text") catch return orelse return;
            self.pending_commands.append(.{
                .send = .{
                    .target = .{ .all = {} },
                    .input = text,
                },
            }) catch {
                self.allocator.free(text);
                return;
            };
            self.respond(idx, "{\"status\": \"queued\"}\n");
        } else if (std.mem.eql(u8, msg_type, "mark_connected")) {
            const pane = extractNumberAfter(trimmed, "pane") orelse {
                self.respond(idx, "{\"error\": \"missing pane\"}\n");
                return;
            };
            std.log.info("text_tap: mark_connected pane={d} client_idx={d}", .{ pane, idx });
            // Clear previous connected pane if the client is reconnecting
            // to a different pane, so the old pane's indicator disappears.
            if (self.clients.items[idx].connected_pane) |old_pane| {
                if (old_pane != @as(u32, @intCast(pane))) {
                    _ = self.active_pane_ids.remove(old_pane);
                    if (old_pane < 64) self.active_send_panes &= ~(@as(u64, 1) << @intCast(old_pane));
                }
            }
            if (pane < 64) self.active_send_panes |= @as(u64, 1) << @intCast(pane);
            self.active_pane_ids.put(@intCast(pane), {}) catch {};
            self.clients.items[idx].connected_pane = @intCast(pane);
            // Parse optional "app" field for the connection pill label.
            if (extractQuotedValue(self.allocator, trimmed, "app") catch null) |name| {
                if (self.clients.items[idx].app_name) |old| self.allocator.free(old);
                self.clients.items[idx].app_name = name;
                std.log.info("text_tap: mark_connected app_name={s}", .{name});
            }
            self.respond(idx, "{\"status\": \"connected\"}\n");
        } else if (std.mem.eql(u8, msg_type, "mark_disconnected")) {
            const pane = extractNumberAfter(trimmed, "pane") orelse {
                self.respond(idx, "{\"error\": \"missing pane\"}\n");
                return;
            };
            _ = self.active_pane_ids.remove(@intCast(pane));
            if (pane < 64) self.active_send_panes &= ~(@as(u64, 1) << @intCast(pane));
            self.clients.items[idx].connected_pane = null;
            self.respond(idx, "{\"status\": \"disconnected\"}\n");
        } else if (std.mem.eql(u8, msg_type, "action")) {
            self.handleActionMessage(idx, trimmed);
        } else if (std.mem.eql(u8, msg_type, "context_update")) {
            self.handleContextUpdateMessage(idx, trimmed);
        } else {
            self.respond(idx, "{\"error\": \"unknown command\"}\n");
        }
    }

    /// Handle an "action" type message by parsing the sub-action.
    fn handleActionMessage(self: *TextTapServer, idx: usize, msg: []const u8) void {
        const action_type = extractQuotedValueStatic(msg, "action") orelse {
            self.respond(idx, "{\"error\": \"missing action field\"}\n");
            return;
        };

        if (std.mem.eql(u8, action_type, "send_command")) {
            const pane = extractNumberAfter(msg, "pane") orelse return;
            const command = extractQuotedValue(self.allocator, msg, "command") catch return orelse return;
            self.pending_commands.append(.{
                .action = .{ .send_command = .{ .pane = pane, .command = command } },
            }) catch {
                self.allocator.free(command);
                return;
            };
            if (pane < 64) self.active_send_panes |= @as(u64, 1) << @intCast(pane);
            self.respond(idx, "{\"status\": \"queued\"}\n");
        } else if (std.mem.eql(u8, action_type, "send_to_all")) {
            const command = extractQuotedValue(self.allocator, msg, "command") catch return orelse return;
            self.pending_commands.append(.{
                .action = .{ .send_to_all = .{ .command = command } },
            }) catch {
                self.allocator.free(command);
                return;
            };
            self.respond(idx, "{\"status\": \"queued\"}\n");
        } else if (std.mem.eql(u8, action_type, "message")) {
            const text = extractQuotedValue(self.allocator, msg, "text") catch return orelse return;
            self.pending_commands.append(.{
                .action = .{ .message = .{ .text = text } },
            }) catch {
                self.allocator.free(text);
                return;
            };
            self.respond(idx, "{\"status\": \"queued\"}\n");
        } else if (std.mem.eql(u8, action_type, "notify")) {
            const title = extractQuotedValue(self.allocator, msg, "title") catch return orelse return;
            const body = extractQuotedValue(self.allocator, msg, "body") catch return orelse {
                self.allocator.free(title);
                return;
            };
            // An explicit "pane" wins; otherwise fall back to the pane this
            // client marked itself connected to. One-shot clients (hook
            // scripts piping through `nc`) never mark_connected, so without
            // an explicit pane the notification can't be attributed here.
            const pane: ?usize = extractNumberAfter(msg, "pane") orelse
                if (self.clients.items[idx].connected_pane) |cp| @as(usize, cp) else null;
            self.pending_commands.append(.{
                .action = .{ .notify = .{ .title = title, .body = body, .pane = pane } },
            }) catch {
                self.allocator.free(title);
                self.allocator.free(body);
                return;
            };
            self.respond(idx, "{\"status\": \"queued\"}\n");
        } else if (std.mem.eql(u8, action_type, "open_browser")) {
            const url = extractQuotedValue(self.allocator, msg, "url") catch return orelse return;
            const pane = extractNumberAfter(msg, "pane");
            self.pending_commands.append(.{
                .action = .{ .open_browser = .{ .url = url, .pane = pane } },
            }) catch {
                self.allocator.free(url);
                return;
            };
            self.respond(idx, "{\"status\": \"queued\"}\n");
        } else if (std.mem.eql(u8, action_type, "browser_eval")) {
            const script = extractQuotedValue(self.allocator, msg, "script") catch return orelse return;
            const pane = extractNumberAfter(msg, "pane");
            self.pending_commands.append(.{
                .action = .{ .browser_eval = .{ .script = script, .pane = pane } },
            }) catch {
                self.allocator.free(script);
                return;
            };
            self.respond(idx, "{\"status\": \"queued\"}\n");
        } else if (std.mem.eql(u8, action_type, "browser_snapshot")) {
            const pane = extractNumberAfter(msg, "pane");
            self.pending_commands.append(.{
                .action = .{ .browser_snapshot = .{ .pane = pane } },
            }) catch return;
            self.respond(idx, "{\"status\": \"queued\"}\n");
        } else if (std.mem.eql(u8, action_type, "browser_click")) {
            const selector = extractQuotedValue(self.allocator, msg, "selector") catch return orelse return;
            const pane = extractNumberAfter(msg, "pane");
            self.pending_commands.append(.{
                .action = .{ .browser_click = .{ .selector = selector, .pane = pane } },
            }) catch {
                self.allocator.free(selector);
                return;
            };
            self.respond(idx, "{\"status\": \"queued\"}\n");
        } else if (std.mem.eql(u8, action_type, "browser_fill")) {
            const selector = extractQuotedValue(self.allocator, msg, "selector") catch return orelse return;
            const text = extractQuotedValue(self.allocator, msg, "text") catch return orelse {
                self.allocator.free(selector);
                return;
            };
            const pane = extractNumberAfter(msg, "pane");
            self.pending_commands.append(.{
                .action = .{ .browser_fill = .{ .selector = selector, .text = text, .pane = pane } },
            }) catch {
                self.allocator.free(selector);
                self.allocator.free(text);
                return;
            };
            self.respond(idx, "{\"status\": \"queued\"}\n");
        } else if (std.mem.eql(u8, action_type, "browser_navigate")) {
            const url = extractQuotedValue(self.allocator, msg, "url") catch return orelse return;
            const pane = extractNumberAfter(msg, "pane");
            self.pending_commands.append(.{
                .action = .{ .browser_navigate = .{ .url = url, .pane = pane } },
            }) catch {
                self.allocator.free(url);
                return;
            };
            self.respond(idx, "{\"status\": \"queued\"}\n");
        } else {
            self.respond(idx, "{\"error\": \"unknown action\"}\n");
        }
    }

    /// Handle a "context_update" message from a Claude Code hook script.
    /// Expected format: {"type":"context_update","payload":{...Claude Code hook JSON...}}
    /// The payload should contain context_window.used, context_window.total,
    /// context_window.used_percentage, session_id, and hook_type fields.
    fn handleContextUpdateMessage(self: *TextTapServer, idx: usize, msg: []const u8) void {
        // Parse the full message as JSON to extract the payload.
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, msg, .{
            .ignore_unknown_fields = true,
        }) catch {
            self.respond(idx, "{\"error\": \"invalid context_update JSON\"}\n");
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            self.respond(idx, "{\"error\": \"context_update must be object\"}\n");
            return;
        }

        const payload_val = root.object.get("payload") orelse {
            self.respond(idx, "{\"error\": \"missing payload\"}\n");
            return;
        };
        if (payload_val != .object) {
            self.respond(idx, "{\"error\": \"payload must be object\"}\n");
            return;
        }
        const payload = payload_val.object;

        // Extract context_window fields
        var used: u64 = 0;
        var total: u64 = 0;
        var percentage: u8 = 0;

        if (payload.get("context_window")) |cw_val| {
            if (cw_val == .object) {
                const cw = cw_val.object;
                if (cw.get("used")) |v| {
                    if (v == .integer and v.integer >= 0) used = @intCast(v.integer);
                }
                if (cw.get("total")) |v| {
                    if (v == .integer and v.integer >= 0) total = @intCast(v.integer);
                }
                if (cw.get("used_percentage")) |v| {
                    if (v == .integer) {
                        const pct = if (v.integer > 100) @as(u8, 100) else if (v.integer < 0) @as(u8, 0) else @as(u8, @intCast(v.integer));
                        percentage = pct;
                    }
                }
            }
        }

        // Extract session_id
        const session_id = if (payload.get("session_id")) |v|
            (if (v == .string) v.string else "")
        else
            "";

        // Extract hook_type to detect PreCompact
        const hook_type = if (payload.get("hook_type")) |v|
            (if (v == .string) v.string else "")
        else
            "";
        const is_pre_compact = std.mem.eql(u8, hook_type, "PreCompact");

        // Dupe session_id for the action
        const sid = self.allocator.dupe(u8, session_id) catch {
            self.respond(idx, "{\"error\": \"alloc failed\"}\n");
            return;
        };

        self.pending_commands.append(.{
            .action = .{ .context_usage = .{
                .used_tokens = used,
                .total_tokens = total,
                .percentage = percentage,
                .session_id = sid,
                .is_pre_compact = is_pre_compact,
            } },
        }) catch {
            self.allocator.free(sid);
            self.respond(idx, "{\"error\": \"queue failed\"}\n");
            return;
        };

        self.respond(idx, "{\"status\": \"queued\"}\n");
    }

    /// Write a JSON response to a specific client.
    pub fn respond(self: *TextTapServer, idx: usize, data: []const u8) void {
        if (idx >= self.clients.items.len) return;
        const fd = self.clients.items[idx].fd;
        _ = posix.write(fd, data) catch {};
    }

    /// Broadcast a message to all subscribed clients.
    pub fn broadcast(self: *TextTapServer, data: []const u8) void {
        for (self.clients.items) |client| {
            if (client.subscribed) {
                _ = posix.write(client.fd, data) catch {};
            }
        }
    }

    /// Broadcast pane content to all subscribed clients as JSON.
    pub fn broadcastPaneContent(self: *TextTapServer, pane: usize, content: []const u8) void {
        const escaped = jsonEscapeString(self.allocator, content) catch return;
        defer self.allocator.free(escaped);

        // Build: {"type": "pane_output", "pane": N, "content": "..."}\n
        const msg = std.fmt.allocPrint(
            self.allocator,
            "{{\"type\": \"pane_output\", \"pane\": {d}, \"content\": {s}}}\n",
            .{ pane, escaped },
        ) catch return;
        defer self.allocator.free(msg);

        self.broadcast(msg);
    }

    /// Return whether any clients are subscribed.
    pub fn hasSubscribers(self: *TextTapServer) bool {
        for (self.clients.items) |client| {
            if (client.subscribed) return true;
        }
        return false;
    }

    /// Return the number of connected clients.
    pub fn clientCount(self: *TextTapServer) usize {
        return self.clients.items.len;
    }

    /// Return a bitset of pane indices targeted by send commands.
    pub fn getActiveSendPanes(self: *TextTapServer) u64 {
        return self.active_send_panes;
    }

    /// Return a bitset of pane indices that have connected (subscribed) clients.
    /// Since clients are not pane-specific, this returns the active_send_panes
    /// bitset when any client is subscribed, or 0 otherwise.
    pub fn getConnectedPanes(self: *TextTapServer) u64 {
        if (self.hasSubscribers()) return self.active_send_panes;
        return 0;
    }

    /// Check if a specific pane (by stable ID) is targeted by a Text Tap client.
    pub fn isPaneActive(self: *TextTapServer, pane_id: u32) bool {
        return self.active_pane_ids.contains(pane_id);
    }

    /// Return the app name of the first connected client that provided one.
    /// The returned slice is owned by the server and valid until the client
    /// disconnects or the server is stopped.
    pub fn connectedAppName(self: *TextTapServer) ?[]const u8 {
        for (self.clients.items) |client| {
            if (client.app_name) |name| {
                if (name.len > 0) return name;
            }
        }
        return null;
    }

    /// Return the app name of the client connected to a specific pane.
    /// Looks up the client whose `connected_pane` matches the given pane ID.
    pub fn appNameForPane(self: *TextTapServer, pane_id: u32) ?[]const u8 {
        for (self.clients.items) |client| {
            if (client.connected_pane) |cp| {
                if (cp == pane_id) {
                    if (client.app_name) |name| {
                        if (name.len > 0) return name;
                    }
                    return null;
                }
            }
        }
        return null;
    }

    /// Handle a cmux-format message: {"id":"...","method":"...","params":{...}}
    fn handleCmuxMessage(self: *TextTapServer, idx: usize, msg: []const u8) void {
        const request_id = extractQuotedValueStatic(msg, "id") orelse {
            self.respond(idx, "{\"error\":\"missing id\"}\n");
            return;
        };
        const method_str = extractQuotedValueStatic(msg, "method") orelse {
            self.respond(idx, "{\"error\":\"missing method\"}\n");
            return;
        };

        const method = CmuxMethod.fromString(method_str) orelse {
            // Unknown method — send error response with the request id.
            var buf: [256]u8 = undefined;
            const resp = std.fmt.bufPrint(&buf, "{{\"id\":\"{s}\",\"ok\":false,\"error\":\"unknown method: {s}\"}}\n", .{ request_id, method_str }) catch return;
            self.respond(idx, resp);
            return;
        };

        switch (method) {
            // Phase 1: Zig-only, immediate response
            .system_ping => {
                var buf: [128]u8 = undefined;
                const resp = std.fmt.bufPrint(&buf, "{{\"id\":\"{s}\",\"ok\":true,\"result\":{{\"pong\":true}}}}\n", .{request_id}) catch return;
                self.respond(idx, resp);
            },
            .system_capabilities => {
                var buf: [512]u8 = undefined;
                const resp = std.fmt.bufPrint(&buf,
                    "{{\"id\":\"{s}\",\"ok\":true,\"result\":{{\"methods\":[" ++
                    "\"system.ping\",\"system.capabilities\",\"system.identify\"," ++
                    "\"surface.list\",\"surface.send_text\",\"surface.send_key\"," ++
                    "\"surface.split\",\"surface.focus\"," ++
                    "\"workspace.list\",\"workspace.current\"," ++
                    "\"notification.create\"" ++
                    "]}}}}\n", .{request_id}) catch return;
                self.respond(idx, resp);
            },
            .surface_send_text => {
                self.handleCmuxSendText(idx, request_id, msg);
            },
            .surface_send_key => {
                self.handleCmuxSendKey(idx, request_id, msg);
            },
            .notification_create => {
                self.handleCmuxNotify(idx, request_id, msg);
            },

            .surface_focus => {
                self.handleCmuxSurfaceFocus(idx, request_id, msg);
            },

            // Phase 2 & 3: Need Swift data — queue as pending
            .system_identify,
            .surface_list,
            .surface_split,
            .workspace_list,
            .workspace_current,
            => {
                var query = CmuxPendingQuery{
                    .client_fd = self.clients.items[idx].fd,
                    .method = method,
                };
                const id_len = @min(request_id.len, query.request_id.len);
                @memcpy(query.request_id[0..id_len], request_id[0..id_len]);
                query.request_id_len = id_len;
                self.cmux_pending.append(query) catch {
                    var buf: [128]u8 = undefined;
                    const resp = std.fmt.bufPrint(&buf, "{{\"id\":\"{s}\",\"ok\":false,\"error\":\"queue full\"}}\n", .{request_id}) catch return;
                    self.respond(idx, resp);
                };
            },
        }
    }

    /// Handle surface.send_text — maps to existing send action.
    fn handleCmuxSendText(self: *TextTapServer, idx: usize, request_id: []const u8, msg: []const u8) void {
        // Parse "surface_id" from params to get pane target, or "text" directly from params.
        const text = extractQuotedValue(self.allocator, msg, "text") catch return orelse {
            var buf: [128]u8 = undefined;
            const resp = std.fmt.bufPrint(&buf, "{{\"id\":\"{s}\",\"ok\":false,\"error\":\"missing text param\"}}\n", .{request_id}) catch return;
            self.respond(idx, resp);
            return;
        };

        // Try to extract pane from surface_id like "surface-3"
        const surface_id = extractQuotedValueStatic(msg, "surface_id");
        const pane: usize = if (surface_id) |sid| blk: {
            if (std.mem.startsWith(u8, sid, "surface-")) {
                break :blk std.fmt.parseInt(usize, sid["surface-".len..], 10) catch 0;
            }
            break :blk 0;
        } else blk: {
            break :blk extractNumberAfter(msg, "pane") orelse 0;
        };

        self.pending_commands.append(.{
            .send = .{
                .target = .{ .pane = pane },
                .input = text,
            },
        }) catch {
            self.allocator.free(text);
            return;
        };
        if (pane < 64) self.active_send_panes |= @as(u64, 1) << @intCast(pane);

        var buf: [128]u8 = undefined;
        const resp = std.fmt.bufPrint(&buf, "{{\"id\":\"{s}\",\"ok\":true,\"result\":{{}}}}\n", .{request_id}) catch return;
        self.respond(idx, resp);
    }

    /// Handle surface.focus — focus a specific pane by surface_id.
    fn handleCmuxSurfaceFocus(self: *TextTapServer, idx: usize, request_id: []const u8, msg: []const u8) void {
        const surface_id = extractQuotedValueStatic(msg, "surface_id") orelse {
            var buf: [128]u8 = undefined;
            const resp = std.fmt.bufPrint(&buf, "{{\"id\":\"{s}\",\"ok\":false,\"error\":\"missing surface_id\"}}\n", .{request_id}) catch return;
            self.respond(idx, resp);
            return;
        };

        const pane: usize = if (std.mem.startsWith(u8, surface_id, "surface-"))
            std.fmt.parseInt(usize, surface_id["surface-".len..], 10) catch 0
        else
            0;

        self.pending_commands.append(.{
            .action = .{ .focus_pane = .{ .pane = pane } },
        }) catch return;

        var buf: [128]u8 = undefined;
        const resp = std.fmt.bufPrint(&buf, "{{\"id\":\"{s}\",\"ok\":true,\"result\":{{}}}}\n", .{request_id}) catch return;
        self.respond(idx, resp);
    }

    /// Handle surface.send_key — send escape sequences for named keys.
    fn handleCmuxSendKey(self: *TextTapServer, idx: usize, request_id: []const u8, msg: []const u8) void {
        const key_name = extractQuotedValueStatic(msg, "key") orelse {
            var buf: [128]u8 = undefined;
            const resp = std.fmt.bufPrint(&buf, "{{\"id\":\"{s}\",\"ok\":false,\"error\":\"missing key param\"}}\n", .{request_id}) catch return;
            self.respond(idx, resp);
            return;
        };

        // Map key names to escape sequences
        const seq: []const u8 = if (std.mem.eql(u8, key_name, "Enter") or std.mem.eql(u8, key_name, "Return"))
            "\r"
        else if (std.mem.eql(u8, key_name, "Tab"))
            "\t"
        else if (std.mem.eql(u8, key_name, "Escape"))
            "\x1b"
        else if (std.mem.eql(u8, key_name, "Backspace"))
            "\x7f"
        else if (std.mem.eql(u8, key_name, "Up"))
            "\x1b[A"
        else if (std.mem.eql(u8, key_name, "Down"))
            "\x1b[B"
        else if (std.mem.eql(u8, key_name, "Right"))
            "\x1b[C"
        else if (std.mem.eql(u8, key_name, "Left"))
            "\x1b[D"
        else if (std.mem.eql(u8, key_name, "Home"))
            "\x1b[H"
        else if (std.mem.eql(u8, key_name, "End"))
            "\x1b[F"
        else if (std.mem.eql(u8, key_name, "Delete"))
            "\x1b[3~"
        else if (std.mem.eql(u8, key_name, "PageUp"))
            "\x1b[5~"
        else if (std.mem.eql(u8, key_name, "PageDown"))
            "\x1b[6~"
        else {
            var buf2: [128]u8 = undefined;
            const resp = std.fmt.bufPrint(&buf2, "{{\"id\":\"{s}\",\"ok\":false,\"error\":\"unknown key: {s}\"}}\n", .{ request_id, key_name }) catch return;
            self.respond(idx, resp);
            return;
        };

        const text = self.allocator.dupe(u8, seq) catch return;

        const surface_id = extractQuotedValueStatic(msg, "surface_id");
        const pane: usize = if (surface_id) |sid| blk: {
            if (std.mem.startsWith(u8, sid, "surface-")) {
                break :blk std.fmt.parseInt(usize, sid["surface-".len..], 10) catch 0;
            }
            break :blk 0;
        } else blk: {
            break :blk extractNumberAfter(msg, "pane") orelse 0;
        };

        self.pending_commands.append(.{
            .send = .{
                .target = .{ .pane = pane },
                .input = text,
            },
        }) catch {
            self.allocator.free(text);
            return;
        };
        if (pane < 64) self.active_send_panes |= @as(u64, 1) << @intCast(pane);

        var buf: [128]u8 = undefined;
        const resp = std.fmt.bufPrint(&buf, "{{\"id\":\"{s}\",\"ok\":true,\"result\":{{}}}}\n", .{request_id}) catch return;
        self.respond(idx, resp);
    }

    /// Handle notification.create — maps to existing notify action.
    fn handleCmuxNotify(self: *TextTapServer, idx: usize, request_id: []const u8, msg: []const u8) void {
        const title = extractQuotedValue(self.allocator, msg, "title") catch return orelse {
            var buf: [128]u8 = undefined;
            const resp = std.fmt.bufPrint(&buf, "{{\"id\":\"{s}\",\"ok\":false,\"error\":\"missing title\"}}\n", .{request_id}) catch return;
            self.respond(idx, resp);
            return;
        };
        const body = extractQuotedValue(self.allocator, msg, "body") catch return orelse {
            self.allocator.free(title);
            var buf: [128]u8 = undefined;
            const resp = std.fmt.bufPrint(&buf, "{{\"id\":\"{s}\",\"ok\":false,\"error\":\"missing body\"}}\n", .{request_id}) catch return;
            self.respond(idx, resp);
            return;
        };

        self.pending_commands.append(.{
            .action = .{ .notify = .{ .title = title, .body = body } },
        }) catch {
            self.allocator.free(title);
            self.allocator.free(body);
            return;
        };

        var buf: [128]u8 = undefined;
        const resp = std.fmt.bufPrint(&buf, "{{\"id\":\"{s}\",\"ok\":true,\"result\":{{}}}}\n", .{request_id}) catch return;
        self.respond(idx, resp);
    }

    /// Drain pending cmux queries for Swift to process.
    /// Returns the pending queries and clears the list.
    pub fn drainCmuxQueries(self: *TextTapServer) []const CmuxPendingQuery {
        return self.cmux_pending.toOwnedSlice() catch return &.{};
    }

    /// Queue a cmux response from Swift. The data must be a heap-allocated
    /// JSON string with trailing newline.
    pub fn queueCmuxResponse(self: *TextTapServer, client_fd: posix.socket_t, data: []const u8) void {
        self.cmux_responses.append(.{
            .client_fd = client_fd,
            .data = data,
        }) catch {
            self.allocator.free(data);
        };
    }

    /// Write all queued cmux responses to their respective clients.
    fn sendCmuxResponses(self: *TextTapServer) void {
        const responses = self.cmux_responses.toOwnedSlice() catch return;
        defer self.allocator.free(responses);
        for (responses) |r| {
            _ = posix.write(r.client_fd, r.data) catch {};
            self.allocator.free(r.data);
        }
    }
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Remove a Unix socket file if it exists.
fn removeSocketFile(path: []const u8) void {
    std.fs.cwd().deleteFile(path) catch {};
}

/// Extract a quoted value without allocating (returns a slice into the input).
/// Only works for simple values without escape sequences.
fn extractQuotedValueStatic(s: []const u8, key: []const u8) ?[]const u8 {
    var pattern_buf: [64]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\"", .{key}) catch return null;

    const pos = std.mem.indexOf(u8, s, pattern) orelse return null;
    const after = s[pos + pattern.len ..];

    const colon_pos = std.mem.indexOf(u8, after, ":") orelse return null;
    const value_str = std.mem.trimLeft(u8, after[colon_pos + 1 ..], " \t");
    if (value_str.len == 0 or value_str[0] != '"') return null;

    // Find closing quote (no escape handling — for simple type/action values).
    var i: usize = 1;
    while (i < value_str.len) : (i += 1) {
        if (value_str[i] == '"') {
            return value_str[1..i];
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// JSON utility functions (shared with text tap protocol)
// ---------------------------------------------------------------------------

/// JSON string escaping.
pub fn jsonEscapeString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    try buf.append('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try buf.appendSlice("\\\""),
            '\\' => try buf.appendSlice("\\\\"),
            '\n' => try buf.appendSlice("\\n"),
            '\r' => try buf.appendSlice("\\r"),
            '\t' => try buf.appendSlice("\\t"),
            else => {
                if (ch < 0x20) {
                    var hex_buf: [6]u8 = undefined;
                    const hex = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{ch}) catch "\\u0000";
                    try buf.appendSlice(hex);
                } else {
                    try buf.append(ch);
                }
            },
        }
    }
    try buf.append('"');
    return buf.toOwnedSlice();
}

/// Extract a number value after a given key in JSON-like text.
pub fn extractNumberAfter(s: []const u8, key: []const u8) ?usize {
    // Build search pattern: "key"
    var pattern_buf: [64]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\"", .{key}) catch return null;

    const pos = std.mem.indexOf(u8, s, pattern) orelse return null;
    const after = s[pos + pattern.len ..];

    // Find colon
    const colon_pos = std.mem.indexOf(u8, after, ":") orelse return null;
    const value_str = std.mem.trimLeft(u8, after[colon_pos + 1 ..], " \t");

    // Parse digits
    var end: usize = 0;
    while (end < value_str.len and value_str[end] >= '0' and value_str[end] <= '9') : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseInt(usize, value_str[0..end], 10) catch null;
}

/// Extract a quoted string value after a given key in JSON-like text.
pub fn extractQuotedValue(allocator: std.mem.Allocator, s: []const u8, key: []const u8) !?[]u8 {
    var pattern_buf: [64]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\"", .{key}) catch return null;

    const pos = std.mem.indexOf(u8, s, pattern) orelse return null;
    const after = s[pos + pattern.len ..];

    const colon_pos = std.mem.indexOf(u8, after, ":") orelse return null;
    const value_str = std.mem.trimLeft(u8, after[colon_pos + 1 ..], " \t");
    if (value_str.len == 0 or value_str[0] != '"') return null;

    var result = std.array_list.Managed(u8).init(allocator);
    var i: usize = 1;
    while (i < value_str.len) : (i += 1) {
        if (value_str[i] == '\\' and i + 1 < value_str.len) {
            i += 1;
            switch (value_str[i]) {
                'n' => try result.append('\n'),
                'r' => try result.append('\r'),
                't' => try result.append('\t'),
                '"' => try result.append('"'),
                '\\' => try result.append('\\'),
                else => {
                    try result.append('\\');
                    try result.append(value_str[i]);
                },
            }
        } else if (value_str[i] == '"') {
            const owned = result.toOwnedSlice() catch {
                result.deinit();
                return null;
            };
            return owned;
        } else {
            try result.append(value_str[i]);
        }
    }

    result.deinit();
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "json escape simple" {
    const result = try jsonEscapeString(testing.allocator, "hello");
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u8, "\"hello\"", result);
}

test "json escape quotes" {
    const result = try jsonEscapeString(testing.allocator, "say \"hi\"");
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u8, "\"say \\\"hi\\\"\"", result);
}

test "json escape newlines" {
    const result = try jsonEscapeString(testing.allocator, "a\nb");
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u8, "\"a\\nb\"", result);
}

test "json escape backslash" {
    const result = try jsonEscapeString(testing.allocator, "a\\b");
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u8, "\"a\\\\b\"", result);
}

test "json escape tab" {
    const result = try jsonEscapeString(testing.allocator, "a\tb");
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u8, "\"a\\tb\"", result);
}

test "extract number after" {
    try testing.expectEqual(@as(?usize, 3), extractNumberAfter("{\"subscribe\": 3}", "subscribe"));
    try testing.expectEqual(@as(?usize, 0), extractNumberAfter("{\"subscribe\": 0}", "subscribe"));
    try testing.expectEqual(@as(?usize, 42), extractNumberAfter("{\"send\": 42, \"input\": \"x\"}", "send"));
}

test "extract number after missing" {
    try testing.expect(extractNumberAfter("{\"list\": true}", "subscribe") == null);
}

test "extract quoted value" {
    const result = try extractQuotedValue(testing.allocator, "{\"send\": 0, \"input\": \"hello world\"}", "input");
    defer if (result) |r| testing.allocator.free(r);
    try testing.expect(result != null);
    try testing.expectEqualSlices(u8, "hello world", result.?);
}

test "extract quoted value with escapes" {
    const result = try extractQuotedValue(testing.allocator, "{\"input\": \"line1\\nline2\"}", "input");
    defer if (result) |r| testing.allocator.free(r);
    try testing.expect(result != null);
    try testing.expectEqualSlices(u8, "line1\nline2", result.?);
}

test "extract quoted value missing" {
    const result = try extractQuotedValue(testing.allocator, "{\"send\": 0}", "input");
    try testing.expect(result == null);
}

test "text tap server creation" {
    var server = TextTapServer.init(testing.allocator, "/tmp/test_termania.sock");
    defer server.deinit();
    const cmds = server.drainCommands();
    defer testing.allocator.free(cmds);
    try testing.expectEqual(@as(usize, 0), cmds.len);
}

test "set pane count" {
    var server = TextTapServer.init(testing.allocator, "/tmp/test_termania2.sock");
    defer server.deinit();
    server.setPaneCount(5);
    try testing.expectEqual(@as(usize, 5), server.pane_count);
}

test "server start and stop" {
    const path = "/tmp/test_termania_start_stop.sock";
    var server = TextTapServer.init(testing.allocator, path);
    defer server.deinit();

    try server.start();
    try testing.expect(server.running);
    try testing.expect(server.listener_fd != null);

    // Socket file should exist.
    const stat = std.fs.cwd().statFile(path);
    try testing.expect(stat != error.FileNotFound);

    server.stop();
    try testing.expect(!server.running);
    try testing.expect(server.listener_fd == null);
}

test "server double start is no-op" {
    const path = "/tmp/test_termania_double.sock";
    var server = TextTapServer.init(testing.allocator, path);
    defer server.deinit();

    try server.start();
    const fd1 = server.listener_fd.?;
    try server.start(); // Should be a no-op.
    try testing.expectEqual(fd1, server.listener_fd.?);

    server.stop();
}

test "server poll with no clients" {
    const path = "/tmp/test_termania_poll_empty.sock";
    var server = TextTapServer.init(testing.allocator, path);
    defer server.deinit();

    try server.start();
    // Polling with no clients should not crash.
    server.poll();
    try testing.expectEqual(@as(usize, 0), server.clientCount());
    server.stop();
}

test "server accept client and read subscribe" {
    const path = "/tmp/test_termania_accept.sock";
    var server = TextTapServer.init(testing.allocator, path);
    defer server.deinit();

    try server.start();

    // Connect a client.
    var addr = try std.net.Address.initUnix(path);
    const client_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(client_fd);
    try posix.connect(client_fd, &addr.any, addr.getOsSockLen());

    // Poll to accept.
    server.poll();
    try testing.expectEqual(@as(usize, 1), server.clientCount());

    // Send a subscribe command.
    _ = try posix.write(client_fd, "{\"type\": \"subscribe\"}\n");

    // Give a tiny moment for data to arrive, then poll.
    std.Thread.sleep(1_000_000); // 1ms
    server.poll();

    // Client should be subscribed.
    try testing.expect(server.clients.items[0].subscribed);
    try testing.expect(server.hasSubscribers());

    server.stop();
}

test "server list_panes command" {
    const path = "/tmp/test_termania_list.sock";
    var server = TextTapServer.init(testing.allocator, path);
    defer server.deinit();
    server.setPaneCount(3);

    try server.start();

    var addr = try std.net.Address.initUnix(path);
    const client_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(client_fd);
    try posix.connect(client_fd, &addr.any, addr.getOsSockLen());

    server.poll(); // Accept.

    _ = try posix.write(client_fd, "{\"type\": \"list_panes\"}\n");
    std.Thread.sleep(1_000_000);
    server.poll(); // Read + respond.

    // Read the response.
    var buf: [256]u8 = undefined;
    std.Thread.sleep(1_000_000);
    const n = posix.read(client_fd, &buf) catch 0;
    if (n > 0) {
        const response = buf[0..n];
        try testing.expect(std.mem.indexOf(u8, response, "\"pane_count\": 3") != null);
    }

    server.stop();
}

test "server send command queued" {
    const path = "/tmp/test_termania_send.sock";
    var server = TextTapServer.init(testing.allocator, path);
    defer server.deinit();

    try server.start();

    var addr = try std.net.Address.initUnix(path);
    const client_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(client_fd);
    try posix.connect(client_fd, &addr.any, addr.getOsSockLen());

    server.poll(); // Accept.

    _ = try posix.write(client_fd, "{\"type\": \"send\", \"pane\": 0, \"text\": \"ls -la\"}\n");
    std.Thread.sleep(1_000_000);
    server.poll(); // Read + process.

    const cmds = server.drainCommands();
    defer {
        for (cmds) |cmd| {
            switch (cmd) {
                .send => |send_cmd| testing.allocator.free(send_cmd.input),
                else => {},
            }
        }
        testing.allocator.free(cmds);
    }
    try testing.expectEqual(@as(usize, 1), cmds.len);

    switch (cmds[0]) {
        .send => |send_cmd| {
            try testing.expectEqualSlices(u8, "ls -la", send_cmd.input);
            switch (send_cmd.target) {
                .pane => |p| try testing.expectEqual(@as(usize, 0), p),
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }

    server.stop();
}

/// Send one notify action over a fresh client and return the parsed pane.
/// `pre` is an optional message sent before the notify (e.g. mark_connected).
fn testNotifyPane(path: []const u8, pre: ?[]const u8, notify_msg: []const u8) !?usize {
    var server = TextTapServer.init(testing.allocator, path);
    defer server.deinit();

    try server.start();

    var addr = try std.net.Address.initUnix(path);
    const client_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(client_fd);
    try posix.connect(client_fd, &addr.any, addr.getOsSockLen());

    server.poll(); // Accept.

    if (pre) |p| {
        _ = try posix.write(client_fd, p);
        std.Thread.sleep(1_000_000);
        server.poll();
    }

    _ = try posix.write(client_fd, notify_msg);
    std.Thread.sleep(1_000_000);
    server.poll(); // Read + process.

    const cmds = server.drainCommands();
    defer {
        for (cmds) |cmd| {
            switch (cmd) {
                .action => |a| llm.freeAction(testing.allocator, a),
                .send => |s| testing.allocator.free(s.input),
            }
        }
        testing.allocator.free(cmds);
    }

    server.stop();

    try testing.expectEqual(@as(usize, 1), cmds.len);
    switch (cmds[0]) {
        .action => |a| switch (a) {
            .notify => |n| {
                try testing.expectEqualSlices(u8, "Claude Code", n.title);
                return n.pane;
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "notify uses explicit pane field" {
    // Hook scripts pass $TRM_PANE_ID so the right pane is credited even when
    // several one-shot clients are connected.
    const pane = try testNotifyPane(
        "/tmp/test_termania_notify_explicit.sock",
        null,
        "{\"type\":\"action\",\"action\":\"notify\",\"title\":\"Claude Code\",\"body\":\"done\",\"pane\":7}\n",
    );
    try testing.expectEqual(@as(?usize, 7), pane);
}

test "notify falls back to the client's connected pane" {
    const pane = try testNotifyPane(
        "/tmp/test_termania_notify_connected.sock",
        "{\"type\":\"mark_connected\",\"pane\":4}\n",
        "{\"type\":\"action\",\"action\":\"notify\",\"title\":\"Claude Code\",\"body\":\"done\"}\n",
    );
    try testing.expectEqual(@as(?usize, 4), pane);
}

test "notify without pane or connection is unattributed" {
    // A one-shot `nc` client never marks itself connected, so there is nothing
    // to attribute here — the pane must stay null rather than guessing.
    const pane = try testNotifyPane(
        "/tmp/test_termania_notify_none.sock",
        null,
        "{\"type\":\"action\",\"action\":\"notify\",\"title\":\"Claude Code\",\"body\":\"done\"}\n",
    );
    try testing.expectEqual(@as(?usize, null), pane);
}

test "notify explicit pane wins over connected pane" {
    const pane = try testNotifyPane(
        "/tmp/test_termania_notify_both.sock",
        "{\"type\":\"mark_connected\",\"pane\":4}\n",
        "{\"type\":\"action\",\"action\":\"notify\",\"title\":\"Claude Code\",\"body\":\"done\",\"pane\":9}\n",
    );
    try testing.expectEqual(@as(?usize, 9), pane);
}

test "server unsubscribe" {
    const path = "/tmp/test_termania_unsub.sock";
    var server = TextTapServer.init(testing.allocator, path);
    defer server.deinit();

    try server.start();

    var addr = try std.net.Address.initUnix(path);
    const client_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(client_fd);
    try posix.connect(client_fd, &addr.any, addr.getOsSockLen());

    server.poll();

    // Subscribe.
    _ = try posix.write(client_fd, "{\"type\": \"subscribe\"}\n");
    std.Thread.sleep(1_000_000);
    server.poll();
    try testing.expect(server.clients.items[0].subscribed);

    // Drain the subscribe response.
    var drain_buf: [256]u8 = undefined;
    _ = posix.read(client_fd, &drain_buf) catch 0;

    // Unsubscribe.
    _ = try posix.write(client_fd, "{\"type\": \"unsubscribe\"}\n");
    std.Thread.sleep(1_000_000);
    server.poll();
    try testing.expect(!server.clients.items[0].subscribed);
    try testing.expect(!server.hasSubscribers());

    server.stop();
}

test "server broadcast to subscribed clients" {
    const path = "/tmp/test_termania_bcast.sock";
    var server = TextTapServer.init(testing.allocator, path);
    defer server.deinit();

    try server.start();

    var addr = try std.net.Address.initUnix(path);

    // Connect client 1 (subscribed).
    const c1_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(c1_fd);
    try posix.connect(c1_fd, &addr.any, addr.getOsSockLen());

    // Connect client 2 (not subscribed).
    const c2_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(c2_fd);
    try posix.connect(c2_fd, &addr.any, addr.getOsSockLen());

    server.poll(); // Accept both.
    try testing.expectEqual(@as(usize, 2), server.clientCount());

    // Subscribe client 1.
    _ = try posix.write(c1_fd, "{\"type\": \"subscribe\"}\n");
    std.Thread.sleep(1_000_000);
    server.poll();

    // Drain subscribe ack.
    var drain_buf: [256]u8 = undefined;
    _ = posix.read(c1_fd, &drain_buf) catch 0;

    // Broadcast.
    server.broadcast("{\"test\": \"data\"}\n");

    std.Thread.sleep(1_000_000);

    // Client 1 should have received it.
    var buf1: [256]u8 = undefined;
    const n1 = posix.read(c1_fd, &buf1) catch 0;
    try testing.expect(n1 > 0);
    try testing.expect(std.mem.indexOf(u8, buf1[0..n1], "\"test\"") != null);

    // Client 2 (not subscribed) should have nothing.
    // Set c2 to non-blocking to check. Must use the O_NONBLOCK file-status
    // flag (0x0004 on macOS, same as start() uses) — SOCK.NONBLOCK is a
    // socket-type flag whose value means something else to F_SETFL, so the
    // old code left the fd blocking and this read hung the test run forever.
    const O_NONBLOCK: usize = 0x0004;
    const flags = posix.fcntl(c2_fd, posix.F.GETFL, 0) catch 0;
    _ = posix.fcntl(c2_fd, posix.F.SETFL, flags | O_NONBLOCK) catch {};
    var buf2: [256]u8 = undefined;
    const n2 = posix.read(c2_fd, &buf2) catch |err| blk: {
        if (err == error.WouldBlock) break :blk @as(usize, 0);
        break :blk @as(usize, 0);
    };
    try testing.expectEqual(@as(usize, 0), n2);

    server.stop();
}

test "server client disconnect detection" {
    const path = "/tmp/test_termania_disc.sock";
    var server = TextTapServer.init(testing.allocator, path);
    defer server.deinit();

    try server.start();

    var addr = try std.net.Address.initUnix(path);
    const client_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    try posix.connect(client_fd, &addr.any, addr.getOsSockLen());

    server.poll();
    try testing.expectEqual(@as(usize, 1), server.clientCount());

    // Close the client.
    posix.close(client_fd);
    std.Thread.sleep(1_000_000);

    // Poll should detect disconnect and remove.
    server.poll();
    try testing.expectEqual(@as(usize, 0), server.clientCount());

    server.stop();
}

test "server send_all command queued" {
    const path = "/tmp/test_termania_sendall.sock";
    var server = TextTapServer.init(testing.allocator, path);
    defer server.deinit();

    try server.start();

    var addr = try std.net.Address.initUnix(path);
    const client_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(client_fd);
    try posix.connect(client_fd, &addr.any, addr.getOsSockLen());

    server.poll();

    _ = try posix.write(client_fd, "{\"type\": \"send_all\", \"text\": \"hello\"}\n");
    std.Thread.sleep(1_000_000);
    server.poll();

    const cmds = server.drainCommands();
    defer {
        for (cmds) |cmd| {
            switch (cmd) {
                .send => |send_cmd| testing.allocator.free(send_cmd.input),
                else => {},
            }
        }
        testing.allocator.free(cmds);
    }
    try testing.expectEqual(@as(usize, 1), cmds.len);

    switch (cmds[0]) {
        .send => |send_cmd| {
            try testing.expectEqualSlices(u8, "hello", send_cmd.input);
            switch (send_cmd.target) {
                .all => {},
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }

    server.stop();
}

test "extract quoted value static" {
    const result = extractQuotedValueStatic("{\"type\": \"subscribe\"}", "type");
    try testing.expect(result != null);
    try testing.expectEqualSlices(u8, "subscribe", result.?);
}

test "extract quoted value static missing" {
    const result = extractQuotedValueStatic("{\"type\": \"subscribe\"}", "action");
    try testing.expect(result == null);
}

test "broadcastPaneContent formats correctly" {
    const path = "/tmp/test_termania_bpc.sock";
    var server = TextTapServer.init(testing.allocator, path);
    defer server.deinit();

    try server.start();

    var addr = try std.net.Address.initUnix(path);
    const client_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(client_fd);
    try posix.connect(client_fd, &addr.any, addr.getOsSockLen());

    server.poll();

    // Subscribe.
    _ = try posix.write(client_fd, "{\"type\": \"subscribe\"}\n");
    std.Thread.sleep(1_000_000);
    server.poll();

    // Drain subscribe response.
    var drain_buf: [256]u8 = undefined;
    _ = posix.read(client_fd, &drain_buf) catch 0;

    // Broadcast pane content.
    server.broadcastPaneContent(0, "hello world");

    std.Thread.sleep(1_000_000);

    var buf: [512]u8 = undefined;
    const n = posix.read(client_fd, &buf) catch 0;
    if (n > 0) {
        const response = buf[0..n];
        try testing.expect(std.mem.indexOf(u8, response, "pane_output") != null);
        try testing.expect(std.mem.indexOf(u8, response, "hello world") != null);
    }

    server.stop();
}

test "cmux system.ping" {
    const path = "/tmp/test_termania_cmux_ping.sock";
    var server = TextTapServer.init(testing.allocator, path);
    defer server.deinit();

    try server.start();

    var addr = try std.net.Address.initUnix(path);
    const client_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(client_fd);
    try posix.connect(client_fd, &addr.any, addr.getOsSockLen());

    server.poll();

    _ = try posix.write(client_fd, "{\"id\":\"r1\",\"method\":\"system.ping\",\"params\":{}}\n");
    std.Thread.sleep(1_000_000);
    server.poll();

    var buf: [256]u8 = undefined;
    std.Thread.sleep(1_000_000);
    const n = posix.read(client_fd, &buf) catch 0;
    if (n > 0) {
        const response = buf[0..n];
        try testing.expect(std.mem.indexOf(u8, response, "\"pong\":true") != null);
        try testing.expect(std.mem.indexOf(u8, response, "\"id\":\"r1\"") != null);
    }

    server.stop();
}

test "cmux system.capabilities" {
    const path = "/tmp/test_termania_cmux_caps.sock";
    var server = TextTapServer.init(testing.allocator, path);
    defer server.deinit();

    try server.start();

    var addr = try std.net.Address.initUnix(path);
    const client_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(client_fd);
    try posix.connect(client_fd, &addr.any, addr.getOsSockLen());

    server.poll();

    _ = try posix.write(client_fd, "{\"id\":\"r2\",\"method\":\"system.capabilities\",\"params\":{}}\n");
    std.Thread.sleep(1_000_000);
    server.poll();

    var buf: [512]u8 = undefined;
    std.Thread.sleep(1_000_000);
    const n = posix.read(client_fd, &buf) catch 0;
    if (n > 0) {
        const response = buf[0..n];
        try testing.expect(std.mem.indexOf(u8, response, "\"methods\"") != null);
        try testing.expect(std.mem.indexOf(u8, response, "system.ping") != null);
    }

    server.stop();
}

test "cmux surface.send_text queues command" {
    const path = "/tmp/test_termania_cmux_send.sock";
    var server = TextTapServer.init(testing.allocator, path);
    defer server.deinit();

    try server.start();

    var addr = try std.net.Address.initUnix(path);
    const client_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(client_fd);
    try posix.connect(client_fd, &addr.any, addr.getOsSockLen());

    server.poll();

    _ = try posix.write(client_fd, "{\"id\":\"r3\",\"method\":\"surface.send_text\",\"params\":{\"surface_id\":\"surface-0\",\"text\":\"hello\"}}\n");
    std.Thread.sleep(1_000_000);
    server.poll();

    const cmds = server.drainCommands();
    defer {
        for (cmds) |cmd| {
            switch (cmd) {
                .send => |send_cmd| testing.allocator.free(send_cmd.input),
                else => {},
            }
        }
        testing.allocator.free(cmds);
    }
    try testing.expectEqual(@as(usize, 1), cmds.len);

    server.stop();
}

test "cmux surface.list queues pending query" {
    const path = "/tmp/test_termania_cmux_list.sock";
    var server = TextTapServer.init(testing.allocator, path);
    defer server.deinit();

    try server.start();

    var addr = try std.net.Address.initUnix(path);
    const client_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(client_fd);
    try posix.connect(client_fd, &addr.any, addr.getOsSockLen());

    server.poll();

    _ = try posix.write(client_fd, "{\"id\":\"r4\",\"method\":\"surface.list\",\"params\":{}}\n");
    std.Thread.sleep(1_000_000);
    server.poll();

    const queries = server.drainCmuxQueries();
    defer testing.allocator.free(queries);
    try testing.expectEqual(@as(usize, 1), queries.len);
    try testing.expectEqual(CmuxMethod.surface_list, queries[0].method);

    server.stop();
}

test "cmux unknown method returns error" {
    const path = "/tmp/test_termania_cmux_unknown.sock";
    var server = TextTapServer.init(testing.allocator, path);
    defer server.deinit();

    try server.start();

    var addr = try std.net.Address.initUnix(path);
    const client_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(client_fd);
    try posix.connect(client_fd, &addr.any, addr.getOsSockLen());

    server.poll();

    _ = try posix.write(client_fd, "{\"id\":\"r5\",\"method\":\"bogus.method\",\"params\":{}}\n");
    std.Thread.sleep(1_000_000);
    server.poll();

    var buf: [256]u8 = undefined;
    std.Thread.sleep(1_000_000);
    const n = posix.read(client_fd, &buf) catch 0;
    if (n > 0) {
        const response = buf[0..n];
        try testing.expect(std.mem.indexOf(u8, response, "\"ok\":false") != null);
    }

    server.stop();
}
