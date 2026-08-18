//! Builds the vendored zmx session-persistence tool (vendor/zmx) against
//! trm's in-tree ghostty-vt module instead of the upstream ghostty package
//! zmx normally fetches. The binary is bundled into trm.app as an auxiliary
//! executable and provides detachable per-pane terminal sessions.
const GhosttyZmx = @This();

const std = @import("std");
const Config = @import("Config.zig");
const GhosttyZig = @import("GhosttyZig.zig");

exe: *std.Build.Step.Compile,
install_step: *std.Build.Step.InstallArtifact,
test_run: *std.Build.Step.Run,

pub fn init(b: *std.Build, cfg: *const Config, mod: *const GhosttyZig) !GhosttyZmx {
    // zmx reads `version` and `ghostty_version` from build_options.
    // See vendor/zmx/UPSTREAM for the vendored commit.
    const options = b.addOptions();
    options.addOption([]const u8, "version", "0.6.0-trm");
    options.addOption([]const u8, "ghostty_version", "in-tree (trm fork)");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("vendor/zmx/src/main.zig"),
        .target = cfg.target,
        .optimize = cfg.optimize,
    });
    exe_mod.addOptions("build_options", options);
    exe_mod.addImport("ghostty-vt", mod.vt);

    const exe = b.addExecutable(.{
        .name = "zmx",
        // Match upstream zmx: self-hosted backend has miscompiles on 0.15.
        .use_llvm = true,
        .root_module = exe_mod,
    });
    exe.linkLibC();

    const install_step = b.addInstallArtifact(exe, .{});

    // Unit tests, mirroring upstream zmx's test step but against the
    // in-tree ghostty-vt. src/test.zig imports every zmx module.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("vendor/zmx/src/test.zig"),
        .target = cfg.target,
        .optimize = cfg.optimize,
    });
    test_mod.addOptions("build_options", options);
    test_mod.addImport("ghostty-vt", mod.vt);
    const test_exe = b.addTest(.{
        .root_module = test_mod,
        .use_llvm = true,
    });
    test_exe.linkLibC();
    const test_run = b.addRunArtifact(test_exe);

    return .{ .exe = exe, .install_step = install_step, .test_run = test_run };
}

/// Make `step` (typically the top-level test step) run the zmx unit tests.
pub fn addTestStepDependencies(self: *const GhosttyZmx, step: *std.Build.Step) void {
    step.dependOn(&self.test_run.step);
}

/// Add the zmx exe to the install target.
pub fn install(self: *const GhosttyZmx) void {
    const b = self.install_step.step.owner;
    b.getInstallStep().dependOn(&self.install_step.step);
}
