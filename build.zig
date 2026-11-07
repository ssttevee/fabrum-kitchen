const std = @import("std");

/// fabrum's `platform` option; see `fabrum.app.platform.Option`. Only the
/// platforms fabrum has.
const Platform = enum { native, gtk, none };

/// The portable renderers `kitchen-none` can draw with.
const RendererChoice = enum { z2d, thorvg };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const platform = b.option(Platform, "platform", "fabrum's platform for the GUI and the interface's tests: native (the default: AppKit on macOS), gtk (GTK 4, through pkg-config) or none (drawn widgets)");
    const renderer = b.option(RendererChoice, "renderer", "What kitchen-none draws with: z2d (the default; pure Zig) or thorvg") orelse .z2d;

    const phase_timings = b.option(bool, "phase_timings", "Compile fabrum CPU phase timing support (needed by measure/test-measure)") orelse false;
    const fabrum_dep = fabrumDependency(b, target, optimize, platform, phase_timings);
    const fabrum_mod = fabrum_dep.module("fabrum");

    const test_step = b.step("test", "Run tests");

    // The interface and its update logic run without a window, against
    // fabrum's heuristic text measurement and its fake native widget tree
    // (or drawn widgets), on any OS.
    const ui_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kitchen.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "fabrum", .module = fabrum_mod }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(ui_tests).step);

    // The GUI runs on AppKit, whose canvas fabrum draws with Quartz, so it
    // only exists on macOS with the native platform.
    if (target.result.os.tag == .macos and (platform orelse .native) == .native) {
        addGui(b, target, optimize, fabrum_mod, test_step);
    }
    // The GUI on GTK 4, wherever GTK is: `kitchen-gtk`.
    if (platform == .gtk) {
        addGtk(b, target, optimize, fabrum_mod, test_step);
    }

    addNone(b, target, optimize, renderer, phase_timings, test_step);
}

fn fabrumDependency(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, platform: ?Platform, phase_timings: bool) *std.Build.Dependency {
    return if (platform) |p|
        b.dependency("fabrum", .{ .target = target, .optimize = optimize, .platform = p, .phase_timings = phase_timings })
    else
        b.dependency("fabrum", .{ .target = target, .optimize = optimize, .phase_timings = phase_timings });
}

/// The `kitchen` executable, its `run` step and its tests.
fn addGui(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    fabrum_mod: *std.Build.Module,
    test_step: *std.Build.Step,
) void {
    const gui_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fabrum", .module = fabrum_mod }},
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

/// The `kitchen-gtk` executable, its `run-gtk` step and its tests.
fn addGtk(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    fabrum_mod: *std.Build.Module,
    test_step: *std.Build.Step,
) void {
    const gtk_mod = b.createModule(.{
        .root_source_file = b.path("src/main_gtk.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fabrum", .module = fabrum_mod }},
    });
    const gui = b.addExecutable(.{ .name = "kitchen-gtk", .root_module = gtk_mod });
    b.installArtifact(gui);

    const run_step = b.step("run-gtk", "Build and run the Kitchen on GTK 4");
    const run_gui = b.addRunArtifact(gui);
    run_gui.step.dependOn(b.getInstallStep());
    run_gui.addPassthruArgs();
    run_step.dependOn(&run_gui.step);

    const gui_tests = b.addTest(.{ .root_module = gtk_mod });
    test_step.dependOn(&b.addRunArtifact(gui_tests).step);
}

/// `kitchen-none`: the Kitchen hosted by its own code on fabrum's `none`
/// platform, drawn into pixels by a portable renderer. It always uses a
/// fabrum built for `none`, whatever `-Dplatform` says, and builds for any
/// target.
fn addNone(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    choice: RendererChoice,
    phase_timings: bool,
    test_step: *std.Build.Step,
) void {
    const fabrum_none = fabrumDependency(b, target, optimize, .none, phase_timings).module("fabrum");
    // the renderer packages don't depend on fabrum: they take the app's
    const renderer_mod = switch (choice) {
        .z2d => (b.lazyDependency("fabrum_renderer_z2d", .{ .target = target, .optimize = optimize }) orelse return).module("fabrum-renderer-z2d"),
        .thorvg => (b.lazyDependency("fabrum_renderer_thorvg", .{ .target = target, .optimize = optimize }) orelse return).module("fabrum-renderer-thorvg"),
    };
    renderer_mod.addImport("fabrum", fabrum_none);

    const options = b.addOptions();
    options.addOption([]const u8, "renderer", @tagName(choice));
    options.addOption(bool, "measure", false);

    const none_mod = b.createModule(.{
        .root_source_file = b.path("src/none.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fabrum", .module = fabrum_none },
            .{ .name = "renderer", .module = renderer_mod },
        },
    });
    none_mod.addOptions("kitchen_options", options);

    const exe = b.addExecutable(.{ .name = "kitchen-none", .root_module = none_mod });
    b.installArtifact(exe);

    const run_step = b.step("run-none", "Build kitchen-none, play its script as an overlay and as an e-ink panel, and write PNGs to /tmp/kitchen-snapshots/p2");
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    run_step.dependOn(&run.step);

    const measure_options = b.addOptions();
    measure_options.addOption([]const u8, "renderer", @tagName(choice));
    measure_options.addOption(bool, "measure", true);
    const measure_mod = b.createModule(.{
        .root_source_file = b.path("src/none.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fabrum", .module = fabrum_none },
            .{ .name = "renderer", .module = renderer_mod },
        },
    });
    measure_mod.addOptions("kitchen_options", measure_options);
    const measured = b.addExecutable(.{ .name = "kitchen-measure", .root_module = measure_mod });
    const run_measure = b.addRunArtifact(measured);
    run_measure.addPassthruArgs();
    b.step("measure", "Run matched CPU phase measurements and animation/resize workloads").dependOn(&run_measure.step);
    const measured_tests = b.addTest(.{ .root_module = measure_mod });
    b.step("test-measure", "Test the measurement host (requires fabrum phase timings)").dependOn(&b.addRunArtifact(measured_tests).step);

    const none_tests = b.addTest(.{ .root_module = none_mod });
    test_step.dependOn(&b.addRunArtifact(none_tests).step);
}
