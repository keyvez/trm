const std = @import("std");
const terminal_types = @import("terminal_types.zig");
const config_mod = @import("config.zig");
const grid_mod = @import("grid.zig");
const plugin_mod = @import("plugin.zig");
const renderer_mod = @import("renderer.zig");
const text_tap_mod = @import("text_tap.zig");
const input_mod = @import("input.zig");
const plugin_registry = @import("plugin_registry.zig");
const llm_mod = @import("llm.zig");

// ---------------------------------------------------------------------------
// C-compatible structs for FFI
// ---------------------------------------------------------------------------

/// Re-export CCell from terminal_types for C API consumers.
pub const CCell = terminal_types.CCell;

/// Pane info returned to Swift.
pub const CPaneInfo = extern struct {
    pane_id: u32,
    rows: u32,
    cols: u32,
    cursor_row: u32,
    cursor_col: u32,
    title: [128]u8,
    title_len: u32,
    flags: u8, // bit0=dirty, 1=has_error, 2=is_exited, 3=is_focused
    _pad: [3]u8,
};

/// Pixel-level layout for a single pane.
pub const CPaneLayout = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    title_height: f32,
};

// ---------------------------------------------------------------------------
// CApp — wraps the Zig application state for C callers
// ---------------------------------------------------------------------------

const CApp = struct {
    allocator: std.mem.Allocator,
    config: config_mod.Config,
    grid: grid_mod.GridManager,
    renderer: renderer_mod.Renderer,
    pane_map: std.AutoHashMap(u32, plugin_mod.PanePlugin),
    grid_order: std.array_list.Managed(u32), // visual layout order of pane IDs
    next_pane_id: u32 = 0,
    text_tap: text_tap_mod.TextTapServer,

    focused_pane_id: u32 = 0,
    broadcast_mode: bool = false,

    // LLM state
    llm_status: u8 = 0, // 0=idle, 1=thinking, 2=done, 3=failed
    llm_response_buf: [4096]u8 = undefined,
    llm_response_len: usize = 0,
    llm_action_descs: [16][256]u8 = undefined,
    llm_action_desc_lens: [16]usize = .{0} ** 16,
    llm_action_count: u32 = 0,

    // Context usage tracking (from Claude Code hooks via Text Tap)
    context_used_tokens: u64 = 0,
    context_total_tokens: u64 = 0,
    context_percentage: u8 = 0,
    context_session_id_buf: [128]u8 = undefined,
    context_session_id_len: usize = 0,
    context_is_pre_compact: bool = false,
    context_last_update_time: i64 = 0,
    has_context_usage: bool = false,

    // Notification queue (from text tap notify actions)
    notification_title_buf: [256]u8 = undefined,
    notification_title_len: usize = 0,
    notification_body_buf: [512]u8 = undefined,
    notification_body_len: usize = 0,
    has_notification: bool = false,

    // Overlay mapping: fg pane ID → bg pane ID
    overlay_map: std.AutoHashMap(u32, u32) = undefined,
    overlay_bg_focused: std.AutoHashMap(u32, bool) = undefined,

    // Watermark per pane (keyed by pane ID)
    watermarks: std.AutoHashMap(u32, [128]u8) = undefined,
    watermark_lens: std.AutoHashMap(u32, usize) = undefined,

    // Persistent font family string (null-terminated for C)
    font_family_buf: [256]u8 = undefined,
    font_family_len: usize = 0,

    // Pending send commands from text tap, to be drained by Swift.
    // Each entry is (pane_id, text). We buffer up to 8 commands.
    send_queue_panes: [8]u32 = .{0} ** 8,
    send_queue_texts: [8][1024]u8 = undefined,
    send_queue_lens: [8]u32 = .{0} ** 8,
    send_queue_count: u32 = 0,

    fn init(allocator: std.mem.Allocator) !*CApp {
        return initInternal(allocator, true);
    }

    fn initConfigOnly(allocator: std.mem.Allocator) !*CApp {
        return initInternal(allocator, false);
    }

    fn initInternal(allocator: std.mem.Allocator, start_services: bool) !*CApp {
        const self = try allocator.create(CApp);

        const cfg = config_mod.loadConfig();
        const session: ?*const config_mod.SessionConfig = null;

        const num_rows = cfg.effectiveRows(session);
        const num_cols = cfg.effectiveCols(session);
        var grd = try grid_mod.GridManager.init(allocator, num_rows, num_cols);

        const total_panes = grd.totalPanes();
        var pane_map = std.AutoHashMap(u32, plugin_mod.PanePlugin).init(allocator);
        var grid_order = std.array_list.Managed(u32).init(allocator);

        const pane_cfgs = cfg.effectivePanes(session);

        var next_id: u32 = 0;
        for (0..total_panes) |i| {
            const pc: ?*const config_mod.PaneConfig = if (i < pane_cfgs.len) &pane_cfgs[i] else null;
            const ptype_str = if (pc) |c| c.pane_type else "terminal";

            // Use registry to validate, then delegate to createPlugin
            const p = if (plugin_registry.hasType(ptype_str))
                try plugin_mod.createPlugin(allocator, i, pc)
            else
                try plugin_mod.createPlugin(allocator, i, null); // fallback to terminal

            const id = next_id;
            next_id += 1;
            try pane_map.put(id, p);
            try grid_order.append(id);
        }

        const rend = renderer_mod.Renderer.init(allocator, &cfg);

        var tap = text_tap_mod.TextTapServer.init(allocator, cfg.text_tap.socket_path);
        tap.setPaneCount(total_panes);
        if (start_services and cfg.text_tap.enabled) tap.start() catch {};

        self.* = .{
            .allocator = allocator,
            .config = cfg,
            .grid = grd,
            .renderer = rend,
            .pane_map = pane_map,
            .grid_order = grid_order,
            .next_pane_id = next_id,
            .text_tap = tap,
            .overlay_map = std.AutoHashMap(u32, u32).init(allocator),
            .overlay_bg_focused = std.AutoHashMap(u32, bool).init(allocator),
            .watermarks = std.AutoHashMap(u32, [128]u8).init(allocator),
            .watermark_lens = std.AutoHashMap(u32, usize).init(allocator),
        };

        // Cache font family as null-terminated string
        const family = cfg.font.family;
        const len = @min(family.len, self.font_family_buf.len - 1);
        @memcpy(self.font_family_buf[0..len], family[0..len]);
        self.font_family_buf[len] = 0;
        self.font_family_len = len;

        return self;
    }

    fn deinit(self: *CApp) void {
        var it = self.pane_map.valueIterator();
        while (it.next()) |p| p.deinit();
        self.pane_map.deinit();
        self.grid_order.deinit();
        self.grid.deinit();
        self.renderer.deinit();
        self.text_tap.stop();
        self.text_tap.deinit();
        self.overlay_map.deinit();
        self.overlay_bg_focused.deinit();
        self.watermarks.deinit();
        self.watermark_lens.deinit();
        const alloc = self.allocator;
        alloc.destroy(self);
    }

    /// Allocate a new unique pane ID.
    fn allocPaneId(self: *CApp) u32 {
        const id = self.next_pane_id;
        self.next_pane_id += 1;
        return id;
    }

    /// Look up a plugin by stable pane ID.
    fn getPlugin(self: *CApp, pane_id: u32) ?*plugin_mod.PanePlugin {
        return self.pane_map.getPtr(pane_id);
    }

    /// Convert a grid slot index to a pane ID.
    fn gridSlotToId(self: *CApp, grid_idx: usize) ?u32 {
        if (grid_idx >= self.grid_order.items.len) return null;
        return self.grid_order.items[grid_idx];
    }

    /// Convert a pane ID to a grid slot index (linear scan).
    fn paneIdToGridSlot(self: *CApp, pane_id: u32) ?usize {
        for (self.grid_order.items, 0..) |id, i| {
            if (id == pane_id) return i;
        }
        return null;
    }

    /// Get the number of panes in the grid.
    fn paneCount(self: *CApp) usize {
        return self.grid_order.items.len;
    }
};

// ---------------------------------------------------------------------------
// Note: Cell conversion is now handled inside GhosttyTerminal.getCells()
// which writes CCell structs directly. No separate cellToCCell needed.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Exported C API functions
// ---------------------------------------------------------------------------

/// Create the Termania application. Returns an opaque pointer.
/// config_path: optional null-terminated path to a config file. If null,
/// uses the default search order (TRM_CWD, cwd, ~/.config/trm).
export fn termania_create_with_config(config_path: ?[*:0]const u8) ?*anyopaque {
    if (config_path) |p| {
        config_mod.setConfigPath(std.mem.sliceTo(p, 0));
    } else {
        config_mod.clearConfigPath();
    }
    const allocator = std.heap.c_allocator;
    const app = CApp.init(allocator) catch return null;
    return @ptrCast(app);
}

/// Create the Termania application with default config. Returns an opaque pointer.
export fn termania_create() ?*anyopaque {
    return termania_create_with_config(null);
}

/// Create a lightweight Termania instance for config reading only.
/// Does NOT start the text tap server or other services, so it won't
/// interfere with the primary running instance's socket.
export fn termania_create_config_only(config_path: ?[*:0]const u8) ?*anyopaque {
    if (config_path) |p| {
        config_mod.setConfigPath(std.mem.sliceTo(p, 0));
    } else {
        config_mod.clearConfigPath();
    }
    const allocator = std.heap.c_allocator;
    const app = CApp.initConfigOnly(allocator) catch return null;
    return @ptrCast(app);
}

/// Destroy the Termania application and free all resources.
export fn termania_destroy(handle: ?*anyopaque) void {
    if (handle) |h| {
        const app: *CApp = @ptrCast(@alignCast(h));
        app.deinit();
    }
}

/// Poll all panes for new output. Returns the number of dirty panes.
export fn termania_poll(handle: ?*anyopaque) u32 {
    const app = getApp(handle) orelse return 0;
    var dirty: u32 = 0;
    var val_it = app.pane_map.valueIterator();
    while (val_it.next()) |p| {
        if (p.poll()) dirty += 1;
    }

    // Poll text tap socket for new connections and incoming data.
    app.text_tap.poll();

    // Process text tap commands
    const cmds = app.text_tap.drainCommands();
    defer app.allocator.free(cmds);
    for (cmds) |cmd| {
        switch (cmd) {
            .send => |s| {
                // Buffer send commands for Swift to drain via termania_drain_send.
                // Swift routes them to the correct ghostty surface PTY.
                if (app.send_queue_count < 8) {
                    const qi = app.send_queue_count;
                    switch (s.target) {
                        .pane => |pane_id| {
                            app.send_queue_panes[qi] = @intCast(pane_id);
                        },
                        .all => {
                            app.send_queue_panes[qi] = 0xFFFFFFFF; // sentinel for "all"
                        },
                    }
                    const tlen = @min(s.input.len, app.send_queue_texts[qi].len);
                    @memcpy(app.send_queue_texts[qi][0..tlen], s.input[0..tlen]);
                    app.send_queue_lens[qi] = @intCast(tlen);
                    app.send_queue_count += 1;
                }
                app.allocator.free(s.input);
            },
            .action => |action| {
                switch (action) {
                    .notify => |n| {
                        const tlen = @min(n.title.len, app.notification_title_buf.len);
                        @memcpy(app.notification_title_buf[0..tlen], n.title[0..tlen]);
                        app.notification_title_len = tlen;
                        const blen = @min(n.body.len, app.notification_body_buf.len);
                        @memcpy(app.notification_body_buf[0..blen], n.body[0..blen]);
                        app.notification_body_len = blen;
                        app.has_notification = true;
                    },
                    .message => |m| {
                        // Surface message actions as notifications
                        const title = "trm";
                        const tlen = @min(title.len, app.notification_title_buf.len);
                        @memcpy(app.notification_title_buf[0..tlen], title[0..tlen]);
                        app.notification_title_len = tlen;
                        const blen = @min(m.text.len, app.notification_body_buf.len);
                        @memcpy(app.notification_body_buf[0..blen], m.text[0..blen]);
                        app.notification_body_len = blen;
                        app.has_notification = true;
                    },
                    .context_usage => |cu| {
                        app.context_used_tokens = cu.used_tokens;
                        app.context_total_tokens = cu.total_tokens;
                        app.context_percentage = cu.percentage;
                        app.context_is_pre_compact = cu.is_pre_compact;

                        const sid_len = @min(cu.session_id.len, app.context_session_id_buf.len);
                        @memcpy(app.context_session_id_buf[0..sid_len], cu.session_id[0..sid_len]);
                        app.context_session_id_len = sid_len;

                        app.context_last_update_time = std.time.timestamp();
                        app.has_context_usage = true;
                    },
                    else => {},
                }
            },
        }
    }

    return dirty;
}

/// Drain one pending send command from the text tap queue.
/// Returns 1 if a command was available, 0 otherwise.
/// pane_out: receives the target pane index (0xFFFFFFFF = all panes).
/// text_buf/text_max: buffer to receive the text to send.
/// text_len_out: receives the actual text length.
export fn termania_drain_send(
    handle: ?*anyopaque,
    pane_out: ?*u32,
    text_buf: ?[*]u8,
    text_max: u32,
    text_len_out: ?*u32,
) u8 {
    const app = getApp(handle) orelse return 0;
    if (app.send_queue_count == 0) return 0;

    const p_out = pane_out orelse return 0;
    const t_out = text_buf orelse return 0;
    const tl_out = text_len_out orelse return 0;

    // Pop the first entry
    p_out.* = app.send_queue_panes[0];
    const tlen = @min(@as(usize, app.send_queue_lens[0]), @as(usize, text_max));
    @memcpy(t_out[0..tlen], app.send_queue_texts[0][0..tlen]);
    tl_out.* = @intCast(tlen);

    // Shift remaining entries down
    app.send_queue_count -= 1;
    const remaining = app.send_queue_count;
    if (remaining > 0) {
        for (0..remaining) |i| {
            app.send_queue_panes[i] = app.send_queue_panes[i + 1];
            app.send_queue_texts[i] = app.send_queue_texts[i + 1];
            app.send_queue_lens[i] = app.send_queue_lens[i + 1];
        }
    }

    return 1;
}

/// Poll for a pending notification. Returns 1 if a notification is available
/// and copies the title/body into the provided buffers. Clears the notification.
export fn termania_poll_notification(
    handle: ?*anyopaque,
    title_buf: ?[*]u8,
    title_max: u32,
    body_buf: ?[*]u8,
    body_max: u32,
) u8 {
    const app = getApp(handle) orelse return 0;
    if (!app.has_notification) return 0;

    const t_out = title_buf orelse return 0;
    const b_out = body_buf orelse return 0;

    const tlen = @min(app.notification_title_len, @as(usize, title_max));
    @memcpy(t_out[0..tlen], app.notification_title_buf[0..tlen]);
    if (tlen < title_max) t_out[tlen] = 0;

    const blen = @min(app.notification_body_len, @as(usize, body_max));
    @memcpy(b_out[0..blen], app.notification_body_buf[0..blen]);
    if (blen < body_max) b_out[blen] = 0;

    app.has_notification = false;
    return 1;
}

/// Allocate a globally unique pane ID. Each call returns a fresh ID that will
/// not collide with any previously allocated ID (including IDs assigned during
/// initial grid creation). Use this from Swift to ensure unique pane IDs across
/// all windows (main terminal, quick terminal, etc.).
export fn termania_alloc_pane_id(handle: ?*anyopaque) u32 {
    const app = getApp(handle) orelse return 0;
    return app.allocPaneId();
}

/// Get the number of panes.
export fn termania_pane_count(handle: ?*anyopaque) u32 {
    const app = getApp(handle) orelse return 0;
    return @intCast(app.paneCount());
}

/// Get info for a specific pane by stable pane ID. Returns 1 on success, 0 on failure.
export fn termania_pane_info(handle: ?*anyopaque, pane_id: u32, info: ?*CPaneInfo) u8 {
    const app = getApp(handle) orelse return 0;
    const out = info orelse return 0;
    const p = app.pane_map.get(pane_id) orelse return 0;
    const rd = p.renderData();

    out.pane_id = pane_id;

    switch (rd) {
        .terminal_data => |td| {
            out.rows = @intCast(td.rows);
            out.cols = @intCast(td.cols);
            out.cursor_row = @intCast(@min(td.cursor_row, std.math.maxInt(u32) - 1));
            out.cursor_col = @intCast(@min(td.cursor_col, std.math.maxInt(u32) - 1));
        },
        else => {
            out.rows = 0;
            out.cols = 0;
            out.cursor_row = 0;
            out.cursor_col = 0;
        },
    }

    // Title
    const title = p.title();
    const tlen = @min(title.len, out.title.len);
    @memcpy(out.title[0..tlen], title[0..tlen]);
    out.title_len = @intCast(tlen);

    // Flags
    var flags: u8 = 0;
    if (p.isDirty()) flags |= 0x01;
    if (p.hasError()) flags |= 0x02;
    if (p.isExited()) flags |= 0x04;
    if (pane_id == app.focused_pane_id) flags |= 0x08;
    out.flags = flags;
    out._pad = .{ 0, 0, 0 };

    return 1;
}

/// Copy cells from a pane into the provided buffer.
/// Returns the number of cells written.
export fn termania_pane_cells(handle: ?*anyopaque, pane_id: u32, buf: ?[*]CCell, max: u32) u32 {
    const app = getApp(handle) orelse return 0;
    const out = buf orelse return 0;
    const p = app.pane_map.get(pane_id) orelse return 0;
    const rd = p.renderData();

    switch (rd) {
        .terminal_data => |td| {
            const n = @min(td.cells.len, @as(usize, max));
            @memcpy(out[0..n], td.cells[0..n]);
            return @intCast(n);
        },
        .custom_cells => |cc| {
            const n = @min(cc.cells.len, @as(usize, max));
            @memcpy(out[0..n], cc.cells[0..n]);
            return @intCast(n);
        },
        else => return 0,
    }
}

/// Pixel-level layout for a single pane, with stable pane ID.
pub const CPaneLayoutWithId = extern struct {
    pane_id: u32,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    title_height: f32,
};

/// Compute pane layouts for the given window dimensions.
/// Returns the number of layouts written.
export fn termania_pane_layouts(
    handle: ?*anyopaque,
    window_w: u32,
    window_h: u32,
    scale: f32,
    buf: ?[*]CPaneLayout,
    max: u32,
) u32 {
    const app = getApp(handle) orelse return 0;
    const out = buf orelse return 0;

    const layouts = app.grid.computeLayout(
        app.allocator,
        window_w,
        window_h,
        &app.config,
        scale,
    ) catch return 0;
    defer app.allocator.free(layouts);

    const n = @min(layouts.len, @as(usize, max));
    for (0..n) |i| {
        out[i] = .{
            .x = layouts[i].x,
            .y = layouts[i].y,
            .width = layouts[i].width,
            .height = layouts[i].height,
            .title_height = layouts[i].title_height,
        };
    }
    return @intCast(n);
}

/// Compute pane layouts with stable pane IDs for the given window dimensions.
/// Returns the number of layouts written. Each layout includes the pane_id.
export fn termania_pane_layouts_with_ids(
    handle: ?*anyopaque,
    window_w: u32,
    window_h: u32,
    scale: f32,
    buf: ?[*]CPaneLayoutWithId,
    max: u32,
) u32 {
    const app = getApp(handle) orelse return 0;
    const out = buf orelse return 0;

    const layouts = app.grid.computeLayout(
        app.allocator,
        window_w,
        window_h,
        &app.config,
        scale,
    ) catch return 0;
    defer app.allocator.free(layouts);

    const n = @min(layouts.len, @min(app.grid_order.items.len, @as(usize, max)));
    for (0..n) |i| {
        out[i] = .{
            .pane_id = app.grid_order.items[i],
            .x = layouts[i].x,
            .y = layouts[i].y,
            .width = layouts[i].width,
            .height = layouts[i].height,
            .title_height = layouts[i].title_height,
        };
    }
    return @intCast(n);
}

/// Send a key event to the focused pane.
export fn termania_send_key(handle: ?*anyopaque, key_code: u8, mods: u8) void {
    const app = getApp(handle) orelse return;
    const focused_plugin = app.getPlugin(app.focused_pane_id) orelse return;

    // Decode modifiers: bit0=ctrl, 1=alt, 2=shift, 3=super
    const modifiers = input_mod.Modifiers{
        .ctrl = (mods & 0x01) != 0,
        .alt = (mods & 0x02) != 0,
        .shift = (mods & 0x04) != 0,
        .super = (mods & 0x08) != 0,
    };

    // Convert u8 key_code to KeyCode enum
    const key: input_mod.KeyCode = std.meta.intToEnum(input_mod.KeyCode, key_code) catch return;

    const event = input_mod.KeyEvent{ .key = key, .mods = modifiers };

    // Check for app-level keybindings first
    if (input_mod.handleAppKeybinding(event)) |action| {
        handleAction(app, action);
        return;
    }

    // Encode to PTY bytes
    var buf: [input_mod.max_key_bytes]u8 = undefined;
    const n = input_mod.keyEventToBytes(event, &buf);
    if (n > 0) {
        focused_plugin.writeInput(buf[0..n]);
    }
}

/// Send raw UTF-8 text to the focused pane (for text input / paste).
export fn termania_send_text(handle: ?*anyopaque, text: ?[*]const u8, len: u32) void {
    const app = getApp(handle) orelse return;
    const data = text orelse return;

    const slice = data[0..@as(usize, len)];

    if (app.broadcast_mode) {
        var val_it = app.pane_map.valueIterator();
        while (val_it.next()) |p| {
            p.writeInput(slice);
        }
    } else {
        const focused_plugin = app.getPlugin(app.focused_pane_id) orelse return;
        focused_plugin.writeInput(slice);
    }
}

/// Notify the app of a window resize.
/// cell_w and cell_h are in physical pixels (points * scale).
export fn termania_resize(handle: ?*anyopaque, window_w: u32, window_h: u32, scale: f32, cell_w: f32, cell_h: f32) void {
    const app = getApp(handle) orelse return;

    app.renderer.handleResize(window_w, window_h);

    // Use the cell dimensions provided by the frontend (in physical pixels)
    const cw = if (cell_w > 0) cell_w else app.config.font.size * scale * 0.6;
    const ch = if (cell_h > 0) cell_h else app.config.font.size * scale * app.config.font.line_height;

    // Compute layouts and resize each pane
    const layouts = app.grid.computeLayout(
        app.allocator,
        window_w,
        window_h,
        &app.config,
        scale,
    ) catch return;
    defer app.allocator.free(layouts);

    for (layouts, 0..) |layout, i| {
        if (i < app.grid_order.items.len) {
            const id = app.grid_order.items[i];
            if (app.getPlugin(id)) |p| {
                const content_h = layout.height - layout.title_height;
                p.doResize(layout.width, content_h, cw, ch);
            }
        }
    }
}

/// Perform an application action (new pane, close, navigate, etc.).
export fn termania_action(handle: ?*anyopaque, action_u8: u8) void {
    const app = getApp(handle) orelse return;
    const action: input_mod.AppAction = std.meta.intToEnum(input_mod.AppAction, action_u8) catch return;
    handleAction(app, action);
}

/// Resolve a cell color to a packed 0xRRGGBBAA value.
export fn termania_resolve_color(handle: ?*anyopaque, color_type: u8, r: u8, g: u8, b: u8, is_fg: u8) u32 {
    const app = getApp(handle) orelse return 0xFF000000;

    const color: terminal_types.CellColor = switch (color_type) {
        0 => .default,
        1 => .{ .ansi = r },
        2 => .{ .indexed = r },
        3 => .{ .rgb = .{ .r = r, .g = g, .b = b } },
        else => .default,
    };

    const rgba = app.renderer.resolveColor(color, is_fg != 0);
    return packColor(rgba);
}

/// Get the default background color as packed 0xRRGGBBAA.
export fn termania_bg_color(handle: ?*anyopaque) u32 {
    const app = getApp(handle) orelse return 0x010409FF;
    return packColor(app.renderer.bg_color);
}

/// Get the default foreground color as packed 0xRRGGBBAA.
export fn termania_fg_color(handle: ?*anyopaque) u32 {
    const app = getApp(handle) orelse return 0xE6EDF3FF;
    return packColor(app.renderer.fg_color);
}

/// Get the cursor color as packed 0xRRGGBBAA.
export fn termania_cursor_color(handle: ?*anyopaque) u32 {
    const app = getApp(handle) orelse return 0xF0F6FCFF;
    return packColor(app.renderer.cursor_color);
}

/// Get the cell width in points (logical pixels).
export fn termania_cell_width(handle: ?*anyopaque) f32 {
    const app = getApp(handle) orelse return 8.4;
    return app.config.font.size * 0.6;
}

/// Get the cell height in points.
export fn termania_cell_height(handle: ?*anyopaque) f32 {
    const app = getApp(handle) orelse return 16.8;
    return app.config.font.size * app.config.font.line_height;
}

/// Get the font size in points.
export fn termania_font_size(handle: ?*anyopaque) f32 {
    const app = getApp(handle) orelse return 14.0;
    return app.config.font.size;
}

/// Get the font family as a null-terminated C string.
export fn termania_font_family(handle: ?*anyopaque) [*:0]const u8 {
    const app = getApp(handle) orelse return "JetBrains Mono";
    return @ptrCast(app.font_family_buf[0..app.font_family_len :0]);
}

/// Get the focused pane ID.
export fn termania_focused_pane(handle: ?*anyopaque) u32 {
    const app = getApp(handle) orelse return 0;
    return app.focused_pane_id;
}

/// Set the focused pane by stable pane ID.
export fn termania_set_focused_pane(handle: ?*anyopaque, pane_id: u32) void {
    const app = getApp(handle) orelse return;
    if (app.pane_map.get(pane_id) != null) {
        app.focused_pane_id = pane_id;
    }
}

/// Get title bar height in points.
export fn termania_title_bar_height(handle: ?*anyopaque) f32 {
    const app = getApp(handle) orelse return 24.0;
    return @floatFromInt(app.config.grid.title_bar_height);
}

/// Get border color as packed 0xRRGGBBAA.
export fn termania_border_color(handle: ?*anyopaque) u32 {
    const app = getApp(handle) orelse return 0x30363DFF;
    return packColor(app.renderer.border_color);
}

/// Get focused border color as packed 0xRRGGBBAA.
export fn termania_border_focused_color(handle: ?*anyopaque) u32 {
    const app = getApp(handle) orelse return 0x58A6FFFF;
    return packColor(app.renderer.border_focused_color);
}

/// Get title bar background color as packed 0xRRGGBBAA.
export fn termania_title_bg_color(handle: ?*anyopaque) u32 {
    const app = getApp(handle) orelse return 0x0D1117FF;
    return packColor(app.renderer.title_bg_color);
}

/// Get title bar foreground color as packed 0xRRGGBBAA.
export fn termania_title_fg_color(handle: ?*anyopaque) u32 {
    const app = getApp(handle) orelse return 0xE6EDF3FF;
    return packColor(app.renderer.title_fg_color);
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn getApp(handle: ?*anyopaque) ?*CApp {
    const h = handle orelse return null;
    return @ptrCast(@alignCast(h));
}

fn packColor(rgba: [4]f32) u32 {
    const r: u32 = @intFromFloat(std.math.clamp(rgba[0] * 255.0, 0, 255));
    const g: u32 = @intFromFloat(std.math.clamp(rgba[1] * 255.0, 0, 255));
    const b: u32 = @intFromFloat(std.math.clamp(rgba[2] * 255.0, 0, 255));
    const a: u32 = @intFromFloat(std.math.clamp(rgba[3] * 255.0, 0, 255));
    return (r << 24) | (g << 16) | (b << 8) | a;
}

fn handleAction(app: *CApp, action: input_mod.AppAction) void {
    switch (action) {
        .new_pane => {
            const grid_idx = app.grid_order.items.len;
            const id = app.allocPaneId();
            const p = plugin_mod.createPlugin(app.allocator, grid_idx, null) catch return;
            app.pane_map.put(id, p) catch return;
            app.grid_order.append(id) catch return;
            app.grid.addColToRow(app.grid.numRows() - 1);
            app.focused_pane_id = id;
        },
        .close_pane => {
            if (app.paneCount() <= 1) return;
            const id = app.focused_pane_id;

            // Find grid position before removal
            const grid_idx = app.paneIdToGridSlot(id) orelse return;
            if (app.grid.panePosition(grid_idx)) |pos| {
                _ = app.grid.removeColFromRow(pos.row);
            }

            // Remove from pane_map and grid_order
            if (app.pane_map.getPtr(id)) |p| {
                p.deinit();
                _ = app.pane_map.remove(id);
            }
            _ = app.grid_order.orderedRemove(grid_idx);

            // Pick next focus: prefer same grid slot, else last
            if (app.grid_order.items.len > 0) {
                const new_idx = if (grid_idx < app.grid_order.items.len) grid_idx else app.grid_order.items.len - 1;
                app.focused_pane_id = app.grid_order.items[new_idx];
            }
        },
        .navigate_up, .navigate_down, .navigate_left, .navigate_right => {
            // Simple focus cycling through grid_order
            if (app.paneCount() <= 1) return;
            const cur_slot = app.paneIdToGridSlot(app.focused_pane_id) orelse return;
            const count = app.grid_order.items.len;
            const new_slot = switch (action) {
                .navigate_right, .navigate_down => (cur_slot + 1) % count,
                .navigate_left, .navigate_up => if (cur_slot == 0) count - 1 else cur_slot - 1,
                else => cur_slot,
            };
            app.focused_pane_id = app.grid_order.items[new_slot];
        },
        .jump_to_pane_1 => setFocusedByGridSlot(app, 0),
        .jump_to_pane_2 => setFocusedByGridSlot(app, 1),
        .jump_to_pane_3 => setFocusedByGridSlot(app, 2),
        .jump_to_pane_4 => setFocusedByGridSlot(app, 3),
        .jump_to_pane_5 => setFocusedByGridSlot(app, 4),
        .jump_to_pane_6 => setFocusedByGridSlot(app, 5),
        .jump_to_pane_7 => setFocusedByGridSlot(app, 6),
        .jump_to_pane_8 => setFocusedByGridSlot(app, 7),
        .jump_to_pane_9 => setFocusedByGridSlot(app, 8),
        .broadcast_toggle => {
            app.broadcast_mode = !app.broadcast_mode;
        },
        else => {},
    }
}

fn setFocusedByGridSlot(app: *CApp, grid_idx: usize) void {
    if (app.gridSlotToId(grid_idx)) |id| {
        app.focused_pane_id = id;
    }
}

// ---------------------------------------------------------------------------
// Plugin Registry C API
// ---------------------------------------------------------------------------

/// Get the number of registered plugin types.
export fn termania_plugin_type_count(_: ?*anyopaque) u32 {
    return plugin_registry.typeCount();
}

/// Get the internal name of plugin type at index. Returns bytes written.
export fn termania_plugin_type_name(_: ?*anyopaque, idx: u32, buf: ?[*]u8, max: u32) u32 {
    const name = plugin_registry.typeName(idx) orelse return 0;
    const out = buf orelse return 0;
    const n = @min(name.len, @as(usize, max));
    @memcpy(out[0..n], name[0..n]);
    return @intCast(n);
}

/// Get the display name of plugin type at index. Returns bytes written.
export fn termania_plugin_type_display(_: ?*anyopaque, idx: u32, buf: ?[*]u8, max: u32) u32 {
    const display = plugin_registry.typeDisplayName(idx) orelse return 0;
    const out = buf orelse return 0;
    const n = @min(display.len, @as(usize, max));
    @memcpy(out[0..n], display[0..n]);
    return @intCast(n);
}

// ---------------------------------------------------------------------------
// LLM C API
// ---------------------------------------------------------------------------

/// Submit a prompt to the LLM. Returns 1 on success, 0 on failure.
export fn termania_llm_submit(handle: ?*anyopaque, prompt: ?[*]const u8, len: u32) u32 {
    const app = getApp(handle) orelse return 0;
    const data = prompt orelse return 0;
    _ = data[0..@as(usize, len)];

    // Set status to thinking
    app.llm_status = 1;

    // In this stub, we immediately set a placeholder response.
    // A real implementation would spawn an async HTTP request to the LLM API.
    const response = "LLM integration is configured but requires an API key. Set llm.api_key in your config.";
    const rlen = @min(response.len, app.llm_response_buf.len);
    @memcpy(app.llm_response_buf[0..rlen], response[0..rlen]);
    app.llm_response_len = rlen;
    app.llm_action_count = 0;
    app.llm_status = 2; // done

    return 1;
}

/// Get the LLM status: 0=idle, 1=thinking, 2=done, 3=failed.
export fn termania_llm_status(handle: ?*anyopaque) u8 {
    const app = getApp(handle) orelse return 0;
    return app.llm_status;
}

/// Get the LLM response text. Returns bytes written.
export fn termania_llm_response_text(handle: ?*anyopaque, buf: ?[*]u8, max: u32) u32 {
    const app = getApp(handle) orelse return 0;
    const out = buf orelse return 0;
    const n = @min(app.llm_response_len, @as(usize, max));
    @memcpy(out[0..n], app.llm_response_buf[0..n]);
    return @intCast(n);
}

/// Get the number of LLM actions in the current response.
export fn termania_llm_action_count(handle: ?*anyopaque) u32 {
    const app = getApp(handle) orelse return 0;
    return app.llm_action_count;
}

/// Get the description of an LLM action. Returns bytes written.
export fn termania_llm_action_desc(handle: ?*anyopaque, idx: u32, buf: ?[*]u8, max: u32) u32 {
    const app = getApp(handle) orelse return 0;
    const out = buf orelse return 0;
    if (idx >= app.llm_action_count) return 0;
    const desc_len = app.llm_action_desc_lens[idx];
    const n = @min(desc_len, @as(usize, max));
    @memcpy(out[0..n], app.llm_action_descs[idx][0..n]);
    return @intCast(n);
}

/// Execute the pending LLM actions.
export fn termania_llm_execute(handle: ?*anyopaque) void {
    const app = getApp(handle) orelse return;
    // Reset LLM state after execution
    app.llm_status = 0;
    app.llm_response_len = 0;
    app.llm_action_count = 0;
}

// ---------------------------------------------------------------------------
// Overlay C API
// ---------------------------------------------------------------------------

/// Add an overlay pane on top of the pane with the given ID. Returns 1 on success.
export fn termania_add_overlay(handle: ?*anyopaque, fg_pane_id: u32, ptype: ?[*]const u8, ptype_len: u32) u8 {
    const app = getApp(handle) orelse return 0;
    if (app.pane_map.get(fg_pane_id) == null) return 0;

    // Don't add overlay if one already exists
    if (app.overlay_map.get(fg_pane_id) != null) return 0;

    const requested_type = if (ptype) |p| p[0..@as(usize, ptype_len)] else "terminal";
    const type_str = if (plugin_registry.hasType(requested_type)) requested_type else "terminal";

    // Create a new background pane with a new stable ID
    const bg_id = app.allocPaneId();
    var pc = config_mod.PaneConfig{};
    pc.pane_type = type_str;
    const p = plugin_mod.createPlugin(app.allocator, app.paneCount(), &pc) catch return 0;
    app.pane_map.put(bg_id, p) catch return 0;
    // Overlay panes are NOT added to grid_order (they share the fg pane's slot)

    app.overlay_map.put(fg_pane_id, bg_id) catch return 0;
    app.overlay_bg_focused.put(fg_pane_id, false) catch return 0;

    return 1;
}

/// Remove the overlay from the pane with the given ID.
export fn termania_remove_overlay(handle: ?*anyopaque, fg_pane_id: u32) void {
    const app = getApp(handle) orelse return;
    if (app.overlay_map.fetchRemove(fg_pane_id)) |kv| {
        // Clean up the background pane
        if (app.pane_map.getPtr(kv.value)) |bg_p| {
            bg_p.deinit();
            _ = app.pane_map.remove(kv.value);
        }
    }
    _ = app.overlay_bg_focused.fetchRemove(fg_pane_id);
}

/// Swap overlay layers (bring background to front).
export fn termania_swap_overlay(handle: ?*anyopaque, fg_pane_id: u32) void {
    const app = getApp(handle) orelse return;
    const bg_id = app.overlay_map.get(fg_pane_id) orelse return;

    // Swap the pane plugins between fg and bg IDs
    const fg_p = app.pane_map.get(fg_pane_id) orelse return;
    const bg_p = app.pane_map.get(bg_id) orelse return;
    app.pane_map.put(fg_pane_id, bg_p) catch return;
    app.pane_map.put(bg_id, fg_p) catch return;
}

/// Toggle focus between foreground and background overlay pane.
export fn termania_toggle_overlay_focus(handle: ?*anyopaque, fg_pane_id: u32) void {
    const app = getApp(handle) orelse return;
    if (app.overlay_bg_focused.getPtr(fg_pane_id)) |focused| {
        focused.* = !focused.*;
    }
}

/// Check if a pane has an overlay. Returns 1 if yes.
export fn termania_has_overlay(handle: ?*anyopaque, fg_pane_id: u32) u8 {
    const app = getApp(handle) orelse return 0;
    return if (app.overlay_map.get(fg_pane_id) != null) 1 else 0;
}

// ---------------------------------------------------------------------------
// Watermark C API
// ---------------------------------------------------------------------------

/// Get the watermark text for a pane by stable pane ID. Returns bytes written.
export fn termania_pane_watermark(handle: ?*anyopaque, pane_id: u32, buf: ?[*]u8, max: u32) u32 {
    const app = getApp(handle) orelse return 0;
    const out = buf orelse return 0;

    const wm_len = app.watermark_lens.get(pane_id) orelse return 0;
    const wm_buf = app.watermarks.get(pane_id) orelse return 0;
    const n = @min(wm_len, @as(usize, max));
    @memcpy(out[0..n], wm_buf[0..n]);
    return @intCast(n);
}

/// Set the watermark text for a pane by stable pane ID.
export fn termania_set_watermark(handle: ?*anyopaque, pane_id: u32, text: ?[*]const u8, len: u32) void {
    const app = getApp(handle) orelse return;
    const data = text orelse return;
    const slen = @as(usize, len);

    var wm_buf: [128]u8 = undefined;
    const n = @min(slen, wm_buf.len);
    @memcpy(wm_buf[0..n], data[0..n]);

    app.watermarks.put(pane_id, wm_buf) catch return;
    app.watermark_lens.put(pane_id, n) catch return;
}

/// Swap two panes in the grid visual order by their stable pane IDs.
export fn termania_swap_pane_order(handle: ?*anyopaque, pane_a: u32, pane_b: u32) void {
    const app = getApp(handle) orelse return;
    var slot_a: ?usize = null;
    var slot_b: ?usize = null;
    for (app.grid_order.items, 0..) |id, i| {
        if (id == pane_a) slot_a = i;
        if (id == pane_b) slot_b = i;
    }
    if (slot_a) |a| {
        if (slot_b) |b| {
            const tmp = app.grid_order.items[a];
            app.grid_order.items[a] = app.grid_order.items[b];
            app.grid_order.items[b] = tmp;
        }
    }
}

// ---------------------------------------------------------------------------
// Session / Grid config accessors
// ---------------------------------------------------------------------------

/// Get the configured grid rows.
export fn termania_grid_rows(handle: ?*anyopaque) u32 {
    const app = getApp(handle) orelse return 1;
    return @intCast(app.config.effectiveRows(null));
}

/// Get the configured grid cols.
export fn termania_grid_cols(handle: ?*anyopaque) u32 {
    const app = getApp(handle) orelse return 1;
    return @intCast(app.config.effectiveCols(null));
}

/// Get the configured gap between panes (pixels).
export fn termania_grid_gap(handle: ?*anyopaque) u32 {
    const app = getApp(handle) orelse return 4;
    return app.config.grid.gap;
}

/// Get the configured outer padding (pixels).
export fn termania_grid_padding(handle: ?*anyopaque) u32 {
    const app = getApp(handle) orelse return 4;
    return app.config.grid.outer_padding;
}

/// Get the number of row_cols entries (0 if not set — use rows/cols instead).
export fn termania_grid_row_cols_count(handle: ?*anyopaque) u32 {
    const app = getApp(handle) orelse return 0;
    return @intCast(app.config.grid.row_cols_len);
}

/// Get the column count for a specific row (from row_cols).
export fn termania_grid_row_cols_at(handle: ?*anyopaque, index: u32) u32 {
    const app = getApp(handle) orelse return 0;
    const i: usize = @intCast(index);
    if (i >= app.config.grid.row_cols_len) return 0;
    return @intCast(app.config.grid.row_cols_buf[i]);
}

/// Check if session persistence is enabled in the termania config.
export fn termania_session_persistence(handle: ?*anyopaque) u8 {
    const app = getApp(handle) orelse return 0;
    return if (app.config.session_persistence) 1 else 0;
}

/// Get the number of configured panes (from TOML).
export fn termania_config_pane_count(handle: ?*anyopaque) u32 {
    const app = getApp(handle) orelse return 0;
    const panes = app.config.effectivePanes(null);
    return @intCast(panes.len);
}

/// Get pane config field as string.
/// field:
///   0=command, 1=cwd, 2=watermark, 3=title, 4=pane_type, 5=url, 6=file,
///   7=content, 8=target, 9=target_title, 10=path, 11=refresh_ms, 12=repo
export fn termania_config_pane_field(handle: ?*anyopaque, idx: u32, field: u8, buf: ?[*]u8, max: u32) u32 {
    const app = getApp(handle) orelse return 0;
    const out = buf orelse return 0;
    const panes = app.config.effectivePanes(null);
    if (idx >= panes.len) return 0;
    const pc = &panes[idx];

    if (field == 11) {
        const refresh = pc.refresh_ms orelse return 0;
        var tmp: [32]u8 = undefined;
        const str = std.fmt.bufPrint(&tmp, "{d}", .{refresh}) catch return 0;
        const n = @min(str.len, @as(usize, max));
        @memcpy(out[0..n], str[0..n]);
        return @intCast(n);
    }

    const value: ?[]const u8 = switch (field) {
        0 => pc.command,
        1 => pc.cwd,
        2 => pc.watermark,
        3 => pc.title,
        4 => pc.pane_type,
        5 => pc.url,
        6 => pc.file,
        7 => pc.content,
        8 => pc.target,
        9 => pc.target_title,
        10 => pc.path,
        12 => pc.repo,
        else => null,
    };

    const str = value orelse return 0;
    const n = @min(str.len, @as(usize, max));
    @memcpy(out[0..n], str[0..n]);
    return @intCast(n);
}

/// Get the number of initial_commands for a pane.
export fn termania_config_pane_initial_cmd_count(handle: ?*anyopaque, idx: u32) u32 {
    const app = getApp(handle) orelse return 0;
    const panes = app.config.effectivePanes(null);
    if (idx >= panes.len) return 0;
    const cmds = panes[idx].initial_commands orelse return 0;
    return @intCast(cmds.len);
}

/// Get an initial_command string for a pane by command index.
export fn termania_config_pane_initial_cmd(handle: ?*anyopaque, pane_idx: u32, cmd_idx: u32, buf: ?[*]u8, max: u32) u32 {
    const app = getApp(handle) orelse return 0;
    const out = buf orelse return 0;
    const panes = app.config.effectivePanes(null);
    if (pane_idx >= panes.len) return 0;
    const cmds = panes[pane_idx].initial_commands orelse return 0;
    if (cmd_idx >= cmds.len) return 0;
    const str = cmds[cmd_idx];
    const n = @min(str.len, @as(usize, max));
    @memcpy(out[0..n], str[0..n]);
    return @intCast(n);
}

/// Get the number of custom patterns for a pane.
export fn termania_config_pane_patterns_count(handle: ?*anyopaque, idx: u32) u32 {
    const app = getApp(handle) orelse return 0;
    const panes = app.config.effectivePanes(null);
    if (idx >= panes.len) return 0;
    const pats = panes[idx].patterns orelse return 0;
    return @intCast(pats.len);
}

/// Get a custom pattern string for a pane by pattern index.
export fn termania_config_pane_pattern(handle: ?*anyopaque, pane_idx: u32, pat_idx: u32, buf: ?[*]u8, max: u32) u32 {
    const app = getApp(handle) orelse return 0;
    const out = buf orelse return 0;
    const panes = app.config.effectivePanes(null);
    if (pane_idx >= panes.len) return 0;
    const pats = panes[pane_idx].patterns orelse return 0;
    if (pat_idx >= pats.len) return 0;
    const str = pats[pat_idx];
    const n = @min(str.len, @as(usize, max));
    @memcpy(out[0..n], str[0..n]);
    return @intCast(n);
}

// ---------------------------------------------------------------------------
// LLM Config accessors
// ---------------------------------------------------------------------------

/// Get the LLM provider string. Returns bytes written.
export fn termania_config_llm_provider(handle: ?*anyopaque, buf: ?[*]u8, max: u32) u32 {
    const app = getApp(handle) orelse return 0;
    const out = buf orelse return 0;
    const str = app.config.llm.provider;
    const n = @min(str.len, @as(usize, max));
    @memcpy(out[0..n], str[0..n]);
    return @intCast(n);
}

/// Get the LLM API key. Returns bytes written (0 if not set).
export fn termania_config_llm_api_key(handle: ?*anyopaque, buf: ?[*]u8, max: u32) u32 {
    const app = getApp(handle) orelse return 0;
    const out = buf orelse return 0;
    const str = app.config.llm.api_key orelse return 0;
    const n = @min(str.len, @as(usize, max));
    @memcpy(out[0..n], str[0..n]);
    return @intCast(n);
}

/// Get the LLM model name. Returns bytes written (0 if not set).
export fn termania_config_llm_model(handle: ?*anyopaque, buf: ?[*]u8, max: u32) u32 {
    const app = getApp(handle) orelse return 0;
    const out = buf orelse return 0;
    const str = app.config.llm.model orelse return 0;
    const n = @min(str.len, @as(usize, max));
    @memcpy(out[0..n], str[0..n]);
    return @intCast(n);
}

/// Get the LLM base URL. Returns bytes written (0 if not set).
export fn termania_config_llm_base_url(handle: ?*anyopaque, buf: ?[*]u8, max: u32) u32 {
    const app = getApp(handle) orelse return 0;
    const out = buf orelse return 0;
    const str = app.config.llm.base_url orelse return 0;
    const n = @min(str.len, @as(usize, max));
    @memcpy(out[0..n], str[0..n]);
    return @intCast(n);
}

/// Get the LLM max_tokens setting.
export fn termania_config_llm_max_tokens(handle: ?*anyopaque) u32 {
    const app = getApp(handle) orelse return 1024;
    return app.config.llm.max_tokens;
}

/// Get the LLM system prompt. Returns bytes written (0 if not set).
export fn termania_config_llm_system_prompt(handle: ?*anyopaque, buf: ?[*]u8, max: u32) u32 {
    const app = getApp(handle) orelse return 0;
    const out = buf orelse return 0;
    const str = app.config.llm.system_prompt orelse return 0;
    const n = @min(str.len, @as(usize, max));
    @memcpy(out[0..n], str[0..n]);
    return @intCast(n);
}

// ---------------------------------------------------------------------------
// Context Usage C API
// ---------------------------------------------------------------------------

/// Poll for context usage data. Returns 1 if data is available.
/// Writes used_tokens, total_tokens, percentage, and is_pre_compact flag.
export fn termania_context_usage(
    handle: ?*anyopaque,
    used_out: ?*u64,
    total_out: ?*u64,
    pct_out: ?*u8,
    pre_compact_out: ?*u8,
) u8 {
    const app = getApp(handle) orelse return 0;
    if (!app.has_context_usage) return 0;

    if (used_out) |p| p.* = app.context_used_tokens;
    if (total_out) |p| p.* = app.context_total_tokens;
    if (pct_out) |p| p.* = app.context_percentage;
    if (pre_compact_out) |p| p.* = if (app.context_is_pre_compact) 1 else 0;

    return 1;
}

/// Get the session ID associated with the current context usage data.
/// Returns the number of bytes written.
export fn termania_context_session_id(handle: ?*anyopaque, buf: ?[*]u8, max: u32) u32 {
    const app = getApp(handle) orelse return 0;
    const out = buf orelse return 0;
    if (!app.has_context_usage) return 0;

    const n = @min(app.context_session_id_len, @as(usize, max));
    @memcpy(out[0..n], app.context_session_id_buf[0..n]);
    return @intCast(n);
}

/// Get the timestamp of the last context usage update (Unix epoch seconds).
export fn termania_context_last_update(handle: ?*anyopaque) i64 {
    const app = getApp(handle) orelse return 0;
    return app.context_last_update_time;
}

/// Get the child PID of a pane (the shell process) by stable pane ID. Returns 0 if unavailable.
export fn termania_pane_child_pid(handle: ?*anyopaque, pane_id: u32) u32 {
    const app = getApp(handle) orelse return 0;
    const p = app.pane_map.get(pane_id) orelse return 0;
    return p.childPid() orelse 0;
}

/// Return a bitset of panes that have been targeted by Text Tap send commands.
/// Bit N is set if pane N received a send/send_command. Does NOT clear the bitset.
/// Also polls the text tap socket for new connections and incoming data so that
/// the bitset stays up to date even when termania_poll is not called.
/// DEPRECATED: Use termania_text_tap_is_active for stable pane ID queries.
export fn termania_text_tap_active_panes(handle: ?*anyopaque) u64 {
    const app = getApp(handle) orelse return 0;
    app.text_tap.poll();
    return app.text_tap.getActiveSendPanes() | app.text_tap.getConnectedPanes();
}

/// Check if a specific pane (by stable ID) is targeted by a Text Tap client.
/// Returns 1 if active, 0 otherwise. Also polls the text tap socket.
export fn termania_text_tap_is_active(handle: ?*anyopaque, pane_id: u32) u8 {
    const app = getApp(handle) orelse return 0;
    app.text_tap.poll();
    if (app.text_tap.isPaneActive(pane_id)) return 1;
    return 0;
}

/// Return the number of clients currently connected to the Text Tap socket.
/// Also polls the socket for new connections / disconnections.
export fn termania_text_tap_client_count(handle: ?*anyopaque) u32 {
    const app = getApp(handle) orelse return 0;
    app.text_tap.poll();
    return @intCast(app.text_tap.clientCount());
}

/// Get the pane ID at a specific grid slot position (visual order).
/// Returns the pane ID, or 0xFFFFFFFF if the slot is out of range.
export fn termania_grid_slot_pane_id(handle: ?*anyopaque, grid_idx: u32) u32 {
    const app = getApp(handle) orelse return 0xFFFFFFFF;
    return app.gridSlotToId(@intCast(grid_idx)) orelse 0xFFFFFFFF;
}
