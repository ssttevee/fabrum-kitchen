const std = @import("std");

/// fabrum's `platform` option; see `fabrum.app.platform.Option`.
const Platform = enum { native, gtk, qt, headless };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const platform = b.option(Platform, "platform", "fabrum's toolkit: native (the default: AppKit on macOS), or headless for the interface's tests alone");

    // Passed on only when given: fabrum's own default is `native`.
    const fabrum_dep = if (platform) |p|
        b.dependency("fabrum", .{ .target = target, .optimize = optimize, .platform = p })
    else
        b.dependency("fabrum", .{ .target = target, .optimize = optimize });
    const fabrum_mod = fabrum_dep.module("fabrum");

    const test_step = b.step("test", "Run tests");

    // The interface and its update logic run without a window, against
    // fabrum's heuristic text measurement and headless native widgets, on
    // any OS.
    const ui_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kitchen.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "fabrum", .module = fabrum_mod }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(ui_tests).step);

    // The GUI runs on AppKit and draws with Quartz, so it only exists on
    // macOS with the native platform.
    if (target.result.os.tag == .macos and (platform orelse .native) == .native) {
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
    const quartz_mod = quartz_dep.module("fabrum-renderer-quartz");
    // The renderer asks for fabrum without the arguments given to ours
    // above, and Zig makes one instance of a dependency per set of
    // arguments as passed: two fabrum modules in one program fail with
    // "file exists in modules 'lib' and 'lib0'". So the renderer gets ours.
    quartz_mod.addImport("fabrum", fabrum_mod);

    const gui_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fabrum", .module = fabrum_mod },
            .{ .name = "fabrum-renderer-quartz", .module = quartz_mod },
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
