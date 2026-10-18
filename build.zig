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
}
