//! The Kitchen on fabrum's GTK 4 platform (`-Dplatform=gtk`): the hybrid
//! screen (`kitchen.Hybrid`) with GTK's own controls laid out by fabrum,
//! and drawn content in canvas layers drawn by Cairo.
//!
//! Debug builds read `KITCHEN_SCRIPT`, steps to run once the window is up,
//! in process (nothing reaches the system's event stream): `click=<text>`,
//! `hover=<text>`, `press=<key>`, `type=<key>:<text>`, `return=<key>`,
//! `slide=<key>:<value>`, `select=<key>:<index>`, `step=<key>:<n>`,
//! `scroll=<key>:<y>`, `tab`, `backtab`, `space`, `menu=<menu>/<item>`,
//! `answer=<index>`, `answermenu=<id>`, `choose=<path>`, `resize=<w>x<h>`,
//! `hit=<x>,<y>`, `dump`, `wait=<ms>`, `snapshot=<path>`, `snapshot2x=<path>`
//! and `quit`; see `script.zig` for their meaning on AppKit.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const fabrum = @import("fabrum");
const app = fabrum.app;
const gtk = app.platform.gtk;
const automation = gtk.automation;

const kitchen = @import("kitchen.zig");
const Step = @import("script.zig").Step;
const cut = @import("script.zig").cut;

pub const HybridApp = gtk.App(kitchen.Hybrid);

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const gui = try gpa.create(HybridApp);
    try gui.init(gpa, io, .{}, .{ .title = "Kitchen", .width = kitchen.window_size.x, .height = kitchen.window_size.y }, .{});
    if (builtin.mode == .debug) {
        if (init.environ_map.get("KITCHEN_SCRIPT")) |steps| {
            const script = try gpa.create(Script);
            script.* = .{ .gui = gui, .io = io, .steps = std.mem.tokenizeScalar(u8, steps, ';') };
            const group = try gpa.create(Io.Group);
            group.* = .init;
            try group.concurrent(io, Script.run, .{script});
        }
    }
    gui.run();
}

const Script = struct {
    gui: *HybridApp,
    io: Io,
    steps: std.mem.TokenIterator(u8, .scalar),
    step: []const u8 = "",
    done: Io.Event = .unset,

    const Root = kitchen.Hybrid;
    const Text = HybridApp.Runtime.Text;

    fn run(self: *Script) Io.Cancelable!void {
        try self.io.sleep(.fromMilliseconds(1200), .awake);
        while (self.steps.next()) |step| {
            if (std.mem.cutPrefix(u8, step, "wait=")) |ms| {
                try self.io.sleep(.fromMilliseconds(std.fmt.parseInt(u32, ms, 10) catch |err| {
                    std.log.err("script step \"{s}\" failed: {t}", .{ step, err });
                    continue;
                }), .awake);
                continue;
            }
            self.step = step;
            self.done.reset();
            automation.runOnMain(onMain, self);
            try self.done.wait(self.io);
            try self.io.sleep(.fromMilliseconds(250), .awake);
        }
    }

    fn onMain(ctx: ?*anyopaque) callconv(.c) void {
        const self: *Script = @ptrCast(@alignCast(ctx.?));
        defer self.done.set(self.io);
        self.perform(self.step) catch |err| std.log.err("script step \"{s}\" failed: {t}", .{ self.step, err });
    }

    fn perform(self: *Script, step: []const u8) !void {
        switch (try Step.parse(step)) {
            .click => |label| try self.pointAt(label, true),
            .hover => |label| try self.pointAt(label, false),
            .press => |key| automation.click(try self.handle(key)),
            .type => |arg| {
                const key, const text = try cut(arg, ':');
                automation.typeText(try self.handle(key), text);
            },
            .@"return" => |key| automation.newline(try self.handle(key)),
            .slide => |arg| {
                const key, const value = try cut(arg, ':');
                automation.slide(try self.handle(key), try std.fmt.parseFloat(f64, value));
            },
            .select => |arg| {
                const key, const index = try cut(arg, ':');
                automation.select(try self.handle(key), try std.fmt.parseInt(usize, index, 10));
            },
            .step => |arg| {
                const key, const n = try cut(arg, ':');
                automation.step(try self.handle(key), try std.fmt.parseInt(i32, n, 10));
            },
            .scroll => |arg| {
                const key, const y = try cut(arg, ':');
                automation.scrollTo(try self.handle(key), .init(0, try std.fmt.parseFloat(f32, y)));
            },
            .tab => automation.tab(true),
            .backtab => automation.tab(false),
            .space => HybridApp.activate(self.gui),
            .menu => |arg| {
                const menu_name, const item_name = try cut(arg, '/');
                var menu: [64:0]u8 = undefined;
                var item: [64:0]u8 = undefined;
                try automation.chooseMenu(try std.fmt.bufPrintSentinel(&menu, "{s}", .{menu_name}, 0), try std.fmt.bufPrintSentinel(&item, "{s}", .{item_name}, 0));
            },
            .answer => |index| automation.answerAlert(try std.fmt.parseInt(usize, index, 10)),
            .answermenu => |id| try automation.answerPopup(if (id.len == 0) null else try std.fmt.parseInt(usize, id, 10)),
            .choose => |path| {
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                try automation.answerFileChooser(if (path.len == 0) null else try std.fmt.bufPrintSentinel(&buffer, "{s}", .{path}, 0));
            },
            .resize => |size| {
                const w, const h = try cut(size, 'x');
                automation.resize(try std.fmt.parseFloat(f64, w), try std.fmt.parseFloat(f64, h));
            },
            .hit => |at| {
                const x, const y = try cut(at, ',');
                var buffer: [256]u8 = undefined;
                std.debug.print("hit {s}: {s}\n", .{ at, automation.describeHit(try std.fmt.parseFloat(f64, x), try std.fmt.parseFloat(f64, y), &buffer) });
            },
            .dump => self.dump(),
            .snapshot => |path| try snapshot(path, null),
            .snapshot2x => |path| try snapshot(path, 2),
            .quit => automation.runOnMain(quitLater, null),
            // AppKit's own: events through its window, the IME, the pasteboard
            .nsclick, .mark, .commit, .key, .privateclipboard, .clipboard, .close => return error.UnsupportedStep,
        }
    }

    fn handle(self: *Script, key: []const u8) error{NoSuchNativeElement}!app.native.Handle {
        return self.gui.handleOf(app.testing.rootInstance(Root).native(key)) orelse {
            std.log.err("no native element \"{s}\"", .{key});
            return error.NoSuchNativeElement;
        };
    }

    fn pointAt(self: *Script, label: []const u8, press: bool) !void {
        const unit = app.testing.findText(Text, self.gui.runtime.context(), label) orelse return error.NoSuchText;
        const middle = app.testing.center(unit);
        HybridApp.mouse(self.gui, middle.x, middle.y, 0, 0, 0);
        if (press) {
            HybridApp.mouse(self.gui, middle.x, middle.y, 1, 0, 0);
            HybridApp.mouse(self.gui, middle.x, middle.y, 0, 0, 0);
        }
    }

    fn dump(self: *Script) void {
        var buffer: [256]u8 = undefined;
        std.debug.print("-- dump: viewport {d}x{d}\n", .{ self.gui.viewport.x, self.gui.viewport.y });
        const theme = self.gui.backend.backend().theme();
        std.debug.print("theme: accent #{x:0>2}{x:0>2}{x:0>2}, font {d}, control height {d}, full keyboard access {}, dark {}\n", .{
            theme.accent.r, theme.accent.g, theme.accent.b, theme.font_size, theme.control_height, theme.full_keyboard_access, theme.dark,
        });
        std.debug.print("focus: GTK {s}; fabrum {?}\n", .{ automation.describeFocus(&buffer), self.gui.runtime.focused() });
        const damage = self.gui.backend.canvas_damage.stats;
        std.debug.print("canvas layers presented {d}, of which unchanged and not redrawn {d}\n", .{ damage.presented, damage.skipped });
        const records = self.gui.runtime.reconciler().records;
        for (records.keys(), records.values()) |id, record| {
            std.debug.print("native {x} {t}", .{ id, record.spec });
            if (record.frame) |f| std.debug.print(" frame=({d},{d} {d}x{d})", .{ f.x, f.y, f.w, f.h });
            if (record.spec.isTextInput()) {
                std.debug.print(" text=\"{s}\" composing={}", .{ automation.fieldText(record.handle, &buffer), self.gui.backend.backend().composing(record.handle) });
            } else switch (record.shown) {
                .toggle => |on| std.debug.print(" on={}", .{on}),
                .number => |n| std.debug.print(" value={d}", .{n}),
                .selection => |i| std.debug.print(" selected={?d}", .{i}),
                else => {},
            }
            std.debug.print("\n", .{});
        }
        const scene = self.gui.runtime.scene();
        std.debug.print("scene: {d} slots, {d} canvas layers, {d} containers\n", .{ scene.slots.len, scene.layers.len, scene.containers.len });
        std.debug.print("texts:", .{});
        var it: app.testing.TextIterator(Text) = .init(self.gui.runtime.context());
        while (it.next()) |found| std.debug.print(" \"{s}\"", .{found.content.text});
        std.debug.print("\n", .{});
    }
};

fn snapshot(path: []const u8, scale: ?f64) !void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    try automation.snapshot(try std.fmt.bufPrintSentinel(&buffer, "{s}", .{path}, 0), scale);
}

fn quitLater(_: ?*anyopaque) callconv(.c) void {
    automation.quit();
}

test {
    _ = kitchen;
    _ = @import("script.zig");
}
