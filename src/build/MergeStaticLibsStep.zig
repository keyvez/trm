//! A custom build step that merges multiple static libraries (.a) into one.
//!
//! Unlike LibtoolStep (which wraps Apple's `libtool -static`), this step:
//!   1. Extracts all .o members from each input archive using `ar -x`.
//!   2. Binary-patches Mach-O arm64 objects that carry the wrong
//!      LC_BUILD_VERSION platform (Zig 0.15.2 emits platform=7/iOS-simulator
//!      instead of platform=1/macOS for arm64 macOS targets).
//!   3. Combines all objects into a single archive using `ar cr`.
//!
//! This avoids two bugs in Apple's libtool in Xcode 26.x:
//!   * libtool silently drops objects that are not 8-byte aligned.
//!   * libtool deduplicates objects by basename, so only the first
//!     occurrence of e.g. "ftbase.o" is kept.
const MergeStaticLibsStep = @This();

const std = @import("std");
const Step = std.Build.Step;
const LazyPath = std.Build.LazyPath;

pub const Options = struct {
    /// Human-readable label used in build output.
    name: []const u8,
    /// Output filename (basename only; placed in a cache directory).
    out_name: []const u8,
    /// Input static library files to merge.
    sources: []const LazyPath,
};

step: Step,
options: Options,
output: LazyPath,
generated_file: std.Build.GeneratedFile,

pub fn create(b: *std.Build, opts: Options) *MergeStaticLibsStep {
    const self = b.allocator.create(MergeStaticLibsStep) catch @panic("OOM");

    // Copy sources slice so we own it.
    const sources = b.allocator.dupe(LazyPath, opts.sources) catch @panic("OOM");

    self.* = .{
        .step = Step.init(.{
            .id = .custom,
            .name = b.fmt("merge-static-libs {s}", .{opts.name}),
            .owner = b,
            .makeFn = make,
        }),
        .options = .{
            .name = opts.name,
            .out_name = opts.out_name,
            .sources = sources,
        },
        .generated_file = .{ .step = &self.step },
        .output = undefined,
    };
    self.output = .{ .generated = .{ .file = &self.generated_file } };

    // Mark every source as a dependency.
    for (sources) |src| src.addStepDependencies(&self.step);

    return self;
}

fn make(step: *Step, options: Step.MakeOptions) !void {
    _ = options;

    const self: *MergeStaticLibsStep = @fieldParentPtr("step", step);
    const b = step.owner;
    const arena = b.allocator;

    // ── Resolve absolute cache root path ─────────────────────────────────
    // b.cache_root.path may be null (when .zig-cache is relative), so we
    // resolve via the Dir handle to get a guaranteed absolute path.
    var cache_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_root_abs = try b.cache_root.handle.realpath(".", &cache_root_buf);

    // ── Build a unique cache path from a hash of the input paths ──────────
    var hasher = std.hash.Wyhash.init(0);
    for (self.options.sources) |src| {
        hasher.update(src.getPath2(b, step));
    }
    const digest = hasher.final();
    const cache_sub = b.fmt("o/merge_{x:0>16}", .{digest});
    const out_dir_abs = b.fmt("{s}/{s}", .{ cache_root_abs, cache_sub });
    std.fs.makeDirAbsolute(out_dir_abs) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // ── Work directory for extracted objects ───────────────────────────────
    const work_dir_abs = b.fmt("{s}/objs", .{out_dir_abs});
    // Clean and recreate each time so stale objects don't accumulate.
    // First chmod everything to 0o755/0o644 so deleteTree can remove read-only
    // files left over from a previous run (ar -x preserves archive modes).
    _ = std.process.Child.run(.{
        .allocator = arena,
        .argv = &.{ "chmod", "-Rf", "u+rwX", work_dir_abs },
    }) catch {};
    std.fs.deleteTreeAbsolute(work_dir_abs) catch {};
    try std.fs.makeDirAbsolute(work_dir_abs);

    // ── Extract objects from every input archive ───────────────────────────
    var obj_index: u32 = 0;

    for (self.options.sources) |src| {
        // getPath2 may return a relative path (relative to build root when
        // cache_root.path is null). Resolve to absolute so `ar -x` works
        // regardless of the child process' working directory.
        const lib_path_raw = src.getPath2(b, step);
        const lib_path = if (std.fs.path.isAbsolute(lib_path_raw))
            lib_path_raw
        else
            try b.build_root.join(arena, &.{lib_path_raw});

        // Use a per-library subdirectory to avoid basename collisions.
        // We name it by the source index so it's deterministic.
        const sub_name = b.fmt("{d}", .{obj_index});
        const sub_dir_path = b.fmt("{s}/{s}", .{ work_dir_abs, sub_name });
        try std.fs.makeDirAbsolute(sub_dir_path);
        obj_index += 1;

        // ar -x extracts all members into the CWD.
        const result = try std.process.Child.run(.{
            .allocator = arena,
            .argv = &.{ "ar", "-x", lib_path },
            .cwd = sub_dir_path,
        });
        defer arena.free(result.stdout);
        defer arena.free(result.stderr);
        if (result.term != .Exited or result.term.Exited != 0) {
            std.log.err("ar -x failed for {s}: {s}", .{ lib_path, result.stderr });
            return error.ArExtractFailed;
        }

        // ar -x on macOS may extract objects with 0o000 permissions (it
        // preserves the archive member mode, and zig cache archives are
        // read-only).  Use capital X to set +x on directories only,
        // then set files to 0o644.
        _ = try std.process.Child.run(.{
            .allocator = arena,
            .argv = &.{ "chmod", "-R", "u+rwX,go+rX", sub_dir_path },
        });

        // Patch LC_BUILD_VERSION in every .o we just extracted.
        var dir = try std.fs.openDirAbsolute(sub_dir_path, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".o")) continue;
            const obj_path = b.fmt("{s}/{s}", .{ sub_dir_path, entry.name });
            patchPlatform(obj_path) catch |err| {
                std.log.warn("platform patch skipped for {s}: {any}", .{ entry.name, err });
            };
        }
    }

    // ── Collect all patched .o paths ───────────────────────────────────────
    var all_objs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer all_objs.deinit(arena);

    var work_dir = try std.fs.openDirAbsolute(work_dir_abs, .{ .iterate = true });
    defer work_dir.close();
    var sub_it = work_dir.iterate();
    while (try sub_it.next()) |sub_entry| {
        if (sub_entry.kind != .directory) continue;
        var sub_dir = try work_dir.openDir(sub_entry.name, .{ .iterate = true });
        defer sub_dir.close();
        const sub_abs = b.fmt("{s}/{s}", .{ work_dir_abs, sub_entry.name });
        var obj_it = sub_dir.iterate();
        while (try obj_it.next()) |obj_entry| {
            if (obj_entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, obj_entry.name, ".o")) continue;
            try all_objs.append(arena, b.fmt("{s}/{s}", .{ sub_abs, obj_entry.name }));
        }
    }

    // ── Write the combined archive with `ar cr` ────────────────────────────
    const out_path = b.fmt("{s}/{s}", .{ out_dir_abs, self.options.out_name });

    // Delete existing archive so `ar cr` starts fresh.
    std.fs.deleteFileAbsolute(out_path) catch {};

    if (all_objs.items.len == 0) {
        // Create an empty archive.
        const empty_result = try std.process.Child.run(.{
            .allocator = arena,
            .argv = &.{ "ar", "cr", out_path },
        });
        defer arena.free(empty_result.stdout);
        defer arena.free(empty_result.stderr);
    } else {
        // `ar cr <output> <obj1> <obj2> ...`
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(arena);
        try argv.appendSlice(arena, &.{ "ar", "cr", out_path });
        try argv.appendSlice(arena, all_objs.items);

        const ar_result = try std.process.Child.run(.{
            .allocator = arena,
            .argv = argv.items,
        });
        defer arena.free(ar_result.stdout);
        defer arena.free(ar_result.stderr);
        if (ar_result.term != .Exited or ar_result.term.Exited != 0) {
            std.log.err("ar cr failed: {s}", .{ar_result.stderr});
            return error.ArCreateFailed;
        }
    }

    self.generated_file.path = out_path;
}

// ── Mach-O platform patching ────────────────────────────────────────────────
//
// Zig 0.15.2 emits LC_BUILD_VERSION with platform=7 (iOS Simulator) and
// minos=17.0 for arm64 macOS targets.  The correct values are platform=1
// (macOS) and minos=13.0 (our minimum macOS deployment target).
//
// The raw 16-byte sequence for the bad LC_BUILD_VERSION command is:
//   32 00 00 00  18 00 00 00  07 00 00 00  00 00 11 00
//   ^^^^^^^^^^^^  ^^^^^^^^^^^^  ^^^^^^^^^^^^  ^^^^^^^^^^^^
//   cmd=0x32      cmdsize=24    platform=7    minos=17.0
//
// We replace it with:
//   32 00 00 00  18 00 00 00  01 00 00 00  00 00 0d 00
//                             platform=1    minos=13.0
//
// Both sequences are 16 bytes and we replace ALL occurrences in the file.
// This is safe because the pattern is unique: the only 16-byte sequence
// starting with cmd=0x32 (LC_BUILD_VERSION), cmdsize=24, platform=7.

const bad_lc: [16]u8 = .{
    0x32, 0x00, 0x00, 0x00, // cmd  = LC_BUILD_VERSION (0x32)
    0x18, 0x00, 0x00, 0x00, // size = 24
    0x07, 0x00, 0x00, 0x00, // platform = 7 (iOS Simulator)
    0x00, 0x00, 0x11, 0x00, // minos = 17.0 (0x110000)
};
const good_lc: [16]u8 = .{
    0x32, 0x00, 0x00, 0x00, // cmd  = LC_BUILD_VERSION (0x32)
    0x18, 0x00, 0x00, 0x00, // size = 24
    0x01, 0x00, 0x00, 0x00, // platform = 1 (macOS)
    0x00, 0x00, 0x0d, 0x00, // minos = 13.0 (0x0d0000)
};

fn patchPlatform(path: []const u8) !void {
    const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_write });
    defer file.close();

    const size = try file.getEndPos();
    if (size < bad_lc.len) return;

    const data = try file.readToEndAlloc(std.heap.page_allocator, 64 * 1024 * 1024);
    defer std.heap.page_allocator.free(data);

    var patched = false;
    var i: usize = 0;
    while (i + bad_lc.len <= data.len) : (i += 1) {
        if (std.mem.eql(u8, data[i .. i + bad_lc.len], &bad_lc)) {
            @memcpy(data[i .. i + good_lc.len], &good_lc);
            patched = true;
            i += bad_lc.len - 1; // skip past this match
        }
    }

    if (patched) {
        try file.seekTo(0);
        try file.writeAll(data);
    }
}
