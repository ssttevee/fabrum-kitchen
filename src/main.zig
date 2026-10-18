//! The Kitchen's macOS GUI: the interface in `kitchen.zig`, run by
//! fabrum.app in the AppKit shell and drawn with the Quartz renderer.
//!
//! `--disable` disables every widget, as Gio's Kitchen's `-disable` does.
//!
//! Debug builds read `KITCHEN_SCRIPT`, steps to run once the window is up,
//! for checking screens without touching the real pointer or keyboard, so
//! they work while the Mac is locked; see `script.zig`.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const fabrum = @import("fabrum");
const app = fabrum.app;
const Quartz = @import("fabrum-renderer-quartz");
// TEMPORARY: `fabrum.app.platform.macos` once the shell moves into fabrum.
const shell = @import("fabrum-platform").macos;

const kitchen = @import("kitchen.zig");
const Kitchen = kitchen.Kitchen;
const Icons = @import("icons.zig");
const Script = @import("script.zig");

pub const Runtime = app.Runtime(.{ .Text = Quartz.content.Text });

pub const Gui = struct {
    runtime: Runtime,
    renderer: Quartz,
    icons: Icons,
    /// Provided to the interface as a root value.
    icons_interface: kitchen.theme.Icons,
    props: Kitchen.Props,

    fn draw(ctx: *anyopaque, cg: *shell.CGContext, width: f64, height: f64) callconv(.c) void {
        const self: *Gui = @ptrCast(@alignCast(ctx));
        var commands = self.runtime.frame(Kitchen, self.props, .init(@floatCast(width), @floatCast(height))) catch |err| {
            std.log.err("frame failed: {t}", .{err});
            return;
        };
        const quartz_cg: *Quartz.CGContext = @ptrCast(cg);
        quartz_cg.flipCanvas(height);
        self.renderer.render(&commands, quartz_cg) catch |err| std.log.err("render failed: {t}", .{err});
        self.afterInput();
    }

    pub fn mouse(ctx: *anyopaque, x: f64, y: f64, buttons: c_uint, scroll_x: f64, scroll_y: f64) callconv(.c) void {
        const self: *Gui = @ptrCast(@alignCast(ctx));
        var pressed: app.MouseEvent.Buttons = .empty;
        if (buttons & 1 != 0) pressed.set(app.MouseEvent.primary);
        self.runtime.mouse(.{
            .position = .init(@floatCast(x), @floatCast(y)),
            .pressed = pressed,
            .scroll_delta = .init(@floatCast(scroll_x), @floatCast(scroll_y)),
        }) catch |err| std.log.err("input failed: {t}", .{err});
        self.afterInput();
    }

    fn afterInput(self: *Gui) void {
        shell.setCursor(self.runtime.cursor());
        if (self.runtime.needsFrame()) shell.requestRedraw();
    }

    fn willTerminate(_: *anyopaque) callconv(.c) void {}
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var props: Kitchen.Props = .{};
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--disable")) {
            props.disabled = true;
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return error.InvalidArgument;
        }
    }

    var gui: Gui = .{
        .runtime = undefined,
        .renderer = try .init(gpa),
        .icons = try .init(gpa),
        .icons_interface = undefined,
        .props = props,
    };
    gui.icons_interface = gui.icons.interface();
    gui.runtime = try .init(gpa, .{
        .io = io,
        .text_context = gui.renderer.text_context,
        .platform = shell.platform,
        .provide = &.{.of(&gui.icons_interface)},
    });

    var script: Script = .{ .gui = &gui, .io = io };
    var script_group: Io.Group = .init;
    if (builtin.mode == .debug) {
        if (init.environ_map.get("KITCHEN_SCRIPT")) |steps| {
            script.steps = std.mem.tokenizeScalar(u8, steps, ';');
            try script_group.concurrent(io, Script.run, .{&script});
        }
    }

    shell.run(.{
        .title = "Kitchen",
        .width = kitchen.window_size.x,
        .height = kitchen.window_size.y,
    }, .{
        .ctx = &gui,
        .draw = Gui.draw,
        .mouse = Gui.mouse,
        .will_terminate = Gui.willTerminate,
    });
}

test {
    _ = kitchen;
    _ = Icons;
    _ = Script;
}
