const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fabrum_dep = b.dependency("fabrum", .{ .target = target, .optimize = optimize });
    const fabrum_mod = fabrum_dep.module("fabrum");

    const test_step = b.step("test", "Run tests");

    // The interface and its update logic run without a window, against
    // fabrum's heuristic text measurement, on any OS.
    const ui_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kitchen.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "fabrum", .module = fabrum_mod }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(ui_tests).step);

    // The GUI renders with Quartz, so it only exists on macOS.
    if (target.result.os.tag == .macos) {
        addGui(b, target, optimize, fabrum_mod, test_step);
    }
}

/// The `kitchen` executable, its `run` step and its tests.
fn addGui(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    fabrum_mod: *std.Build.Module,
    test_step: *std.Build.Step,
) void {
    const quartz_dep = b.dependency("fabrum_renderer_quartz", .{ .target = target, .optimize = optimize });

    // TEMPORARY: the platform shell, laid out as `fabrum.app.platform`
    // will be. Once it moves into fabrum, fabrum's build adds its sources
    // and frameworks to the `fabrum` module and this module goes away.
    const platform_mod = b.createModule(.{
        .root_source_file = b.path("src/platform.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fabrum", .module = fabrum_mod }},
    });
    addMacosPlatform(b, platform_mod);

    const gui_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fabrum", .module = fabrum_mod },
            .{ .name = "fabrum-platform", .module = platform_mod },
            .{ .name = "fabrum-renderer-quartz", .module = quartz_dep.module("fabrum-renderer-quartz") },
        },
    });

    const gui = b.addExecutable(.{ .name = "kitchen", .root_module = gui_mod });
    b.installArtifact(gui);

    const run_step = b.step("run", "Build and run the Kitchen");
    const run_gui = b.addRunArtifact(gui);
    run_gui.step.dependOn(b.getInstallStep());
    run_gui.addPassthruArgs();
    run_step.dependOn(&run_gui.step);

    const gui_tests = b.addTest(.{ .root_module = gui_mod });
    test_step.dependOn(&b.addRunArtifact(gui_tests).step);
}

/// Adds the AppKit half of the macOS shell and the frameworks it needs:
/// what fabrum's build will do for the `fabrum` module when its
/// `platform` option is on.
fn addMacosPlatform(b: *std.Build, module: *std.Build.Module) void {
    module.addCSourceFiles(.{
        .root = b.path("src/platform/macos"),
        .files = &.{"shell.m"},
        .language = .objective_c,
        .flags = &.{"-fobjc-arc"},
    });
    module.linkFramework("AppKit", .{});
}
