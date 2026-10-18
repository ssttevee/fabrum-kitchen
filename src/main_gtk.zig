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
            if (std.mem.startsWith(u8, step, "wait=")) {
                const ms = std.fmt.parseInt(u32, step["wait=".len..], 10) catch 0;
                try self.io.sleep(.fromMilliseconds(ms), .awake);
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

    fn arg(step: []const u8, name: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, step, name) or step.len <= name.len or step[name.len] != '=') return null;
        return step[name.len + 1 ..];
    }

    fn perform(self: *Script, step: []const u8) !void {
        if (arg(step, "click")) |label| return self.pointAt(label, true);
        if (arg(step, "hover")) |label| return self.pointAt(label, false);
        if (arg(step, "press")) |key| return automation.click(try self.handle(key));
        if (arg(step, "type")) |a| {
            const split = try keyed(a);
            return automation.typeText(try self.handle(split.key), split.value);
        }
        if (arg(step, "return")) |key| return automation.newline(try self.handle(key));
        if (arg(step, "slide")) |a| {
            const split = try keyed(a);
            return automation.slide(try self.handle(split.key), try std.fmt.parseFloat(f64, split.value));
        }
        if (arg(step, "select")) |a| {
            const split = try keyed(a);
            return automation.select(try self.handle(split.key), try std.fmt.parseInt(usize, split.value, 10));
        }
        if (arg(step, "step")) |a| {
            const split = try keyed(a);
            return automation.step(try self.handle(split.key), try std.fmt.parseInt(i32, split.value, 10));
        }
        if (arg(step, "scroll")) |a| {
            const split = try keyed(a);
            return automation.scrollTo(try self.handle(split.key), .init(0, try std.fmt.parseFloat(f32, split.value)));
        }
        if (std.mem.eql(u8, step, "tab")) return automation.tab(true);
        if (std.mem.eql(u8, step, "backtab")) return automation.tab(false);
        if (std.mem.eql(u8, step, "space")) return HybridApp.activate(self.gui);
        if (arg(step, "menu")) |a| {
            const slash = std.mem.indexOfScalar(u8, a, '/') orelse return error.BadStep;
            var menu: [64:0]u8 = undefined;
            var item: [64:0]u8 = undefined;
            return automation.chooseMenu(try std.fmt.bufPrintSentinel(&menu, "{s}", .{a[0..slash]}, 0), try std.fmt.bufPrintSentinel(&item, "{s}", .{a[slash + 1 ..]}, 0));
        }
        if (arg(step, "answer")) |index| return automation.answerAlert(try std.fmt.parseInt(usize, index, 10));
        if (arg(step, "answermenu")) |id| return automation.answerPopup(if (id.len == 0) null else try std.fmt.parseInt(usize, id, 10));
        if (arg(step, "choose")) |path| {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            return automation.answerFileChooser(if (path.len == 0) null else try std.fmt.bufPrintSentinel(&buffer, "{s}", .{path}, 0));
        }
        if (arg(step, "resize")) |size| {
            const x = std.mem.indexOfScalar(u8, size, 'x') orelse return error.BadStep;
            return automation.resize(try std.fmt.parseFloat(f64, size[0..x]), try std.fmt.parseFloat(f64, size[x + 1 ..]));
        }
        if (arg(step, "hit")) |at| {
            const comma = std.mem.indexOfScalar(u8, at, ',') orelse return error.BadStep;
            var buffer: [256]u8 = undefined;
            std.debug.print("hit {s}: {s}\n", .{ at, automation.describeHit(try std.fmt.parseFloat(f64, at[0..comma]), try std.fmt.parseFloat(f64, at[comma + 1 ..]), &buffer) });
            return;
        }
        if (std.mem.eql(u8, step, "dump")) return self.dump();
        if (arg(step, "snapshot")) |path| return snapshot(path, null);
        if (arg(step, "snapshot2x")) |path| return snapshot(path, 2);
        if (std.mem.eql(u8, step, "quit")) return automation.runOnMain(quitLater, null);
        return error.UnknownStep;
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

fn keyed(a: []const u8) error{BadStep}!struct { key: []const u8, value: []const u8 } {
    const colon = std.mem.indexOfScalar(u8, a, ':') orelse return error.BadStep;
    return .{ .key = a[0..colon], .value = a[colon + 1 ..] };
}

fn snapshot(path: []const u8, scale: ?f64) !void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    try automation.snapshot(try std.fmt.bufPrintSentinel(&buffer, "{s}", .{path}, 0), scale);
}

fn quitLater(_: ?*anyopaque) callconv(.c) void {
    automation.quit();
}

test {
    _ = kitchen;
}
