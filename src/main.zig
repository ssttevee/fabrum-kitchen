//! The Kitchen's macOS GUI: the interface in `kitchen.zig`, run by
//! fabrum.app on its AppKit platform and drawn with the Quartz renderer.
//!
//! It shows the hybrid screen (`kitchen.Hybrid`): AppKit's own controls
//! laid out by fabrum, with drawn content between and over them.
//!
//! - `--drawn` shows the same screen drawn entirely by fabrum
//!   (`kitchen.Kitchen`), for comparison;
//! - `--disable` disables every widget of the drawn screen, as Gio's
//!   Kitchen's `-disable` does.
//!
//! Debug builds read `KITCHEN_SCRIPT`, steps to run once the window is up,
//! for checking screens without touching the real pointer or keyboard, so
//! most of them work while the Mac is locked; see `script.zig`.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const fabrum = @import("fabrum");
const appkit = fabrum.app.platform.appkit;
const Quartz = @import("fabrum-renderer-quartz");

const kitchen = @import("kitchen.zig");
const Icons = @import("icons.zig");
const Script = @import("script.zig").Script;

pub const HybridApp = appkit.App(kitchen.Hybrid, Quartz);
pub const DrawnApp = appkit.App(kitchen.Kitchen, Quartz);

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var drawn = false;
    var props: kitchen.Kitchen.Props = .{};
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--disable")) {
            props.disabled = true;
        } else if (std.mem.eql(u8, arg, "--drawn")) {
            drawn = true;
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return error.InvalidArgument;
        }
    }

    // they live as long as the process, as `run` never returns
    var icons: Icons = try .init(gpa);
    const icons_interface = icons.interface();
    const window: appkit.Options = .{
        .title = "Kitchen",
        .width = kitchen.window_size.x,
        .height = kitchen.window_size.y,
    };
    const provide: []const fabrum.app.RootValue = &.{.of(&icons_interface)};

    if (drawn) {
        const gui = try gpa.create(DrawnApp);
        try gui.init(gpa, io, props, window, .{ .provide = provide });
        try runScript(DrawnApp, gui, init);
        gui.run();
    } else {
        const gui = try gpa.create(HybridApp);
        try gui.init(gpa, io, .{}, window, .{ .provide = provide });
        try runScript(HybridApp, gui, init);
        gui.run();
    }
}

/// Starts `KITCHEN_SCRIPT` on its own thread, in debug builds.
fn runScript(comptime App: type, gui: *App, init: std.process.Init) !void {
    if (builtin.mode != .debug) return;
    const steps = init.environ_map.get("KITCHEN_SCRIPT") orelse return;
    const script = try init.gpa.create(Script(App));
    script.* = .{ .gui = gui, .io = init.io, .steps = std.mem.tokenizeScalar(u8, steps, ';') };
    const group = try init.gpa.create(Io.Group);
    group.* = .init;
    try group.concurrent(init.io, Script(App).run, .{script});
}

test {
    _ = kitchen;
    _ = Icons;
    _ = @import("script.zig");
}
