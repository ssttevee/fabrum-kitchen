//! Drives the GUI from `KITCHEN_SCRIPT` in debug builds, to check screens
//! without a person at the Mac, even while it is locked: nothing is posted
//! to the system's event stream and the real pointer never moves.
//!
//! Steps are separated by `;`:
//!
//! - `click=<label>`: a press and release at the middle of the text
//!   `<label>`, fed straight to the runtime as the shell would;
//! - `hover=<label>`: the pointer moved over the text `<label>`;
//! - `nsclick=<label>`: a click on the text `<label>` made of AppKit events
//!   sent through the app's own window, so it goes through the shell too;
//! - `wait=<ms>`: a pause;
//! - `snapshot=<path>`: the window's content saved as a PNG, at the
//!   screen's scale; `snapshot2x=<path>` at two pixels per point;
//! - `quit`: quits as the menu item would.
//!
//! For example:
//!
//! ```sh
//! KITCHEN_SCRIPT='snapshot=/tmp/a.png;nsclick=Click me!;snapshot=/tmp/b.png;quit' zig build run
//! ```
const std = @import("std");
const Io = std.Io;

const fabrum = @import("fabrum");
const app = fabrum.app;
const shell = @import("fabrum-platform").macos;

const Gui = @import("main.zig").Gui;
const Text = @import("main.zig").Runtime.Text;

const Script = @This();

gui: *Gui,
io: Io,
steps: std.mem.TokenIterator(u8, .scalar) = undefined,
/// The step handed to the main thread, and a signal that it ran.
step: []const u8 = "",
done: Io.Event = .unset,

pub fn run(self: *Script) Io.Cancelable!void {
    // let the window come up
    try self.io.sleep(.fromMilliseconds(800), .awake);
    while (self.steps.next()) |step| {
        if (std.mem.startsWith(u8, step, "wait=")) {
            const ms = std.fmt.parseInt(u32, step["wait=".len..], 10) catch 0;
            try self.io.sleep(.fromMilliseconds(ms), .awake);
            continue;
        }
        self.step = step;
        self.done.reset();
        shell.runOnMain(onMain, self);
        try self.done.wait(self.io);
        // give the frame it caused time to draw
        try self.io.sleep(.fromMilliseconds(150), .awake);
    }
}

fn onMain(ctx: ?*anyopaque) callconv(.c) void {
    const self: *Script = @ptrCast(@alignCast(ctx.?));
    defer self.done.set(self.io);
    perform(self.gui, self.step) catch |err| std.log.err("script step \"{s}\" failed: {t}", .{ self.step, err });
}

const Step = union(enum) {
    click: []const u8,
    hover: []const u8,
    nsclick: []const u8,
    snapshot: []const u8,
    snapshot2x: []const u8,
    quit,

    fn parse(step: []const u8) error{UnknownStep}!Step {
        if (std.mem.eql(u8, step, "quit")) return .quit;
        const eq = std.mem.indexOfScalar(u8, step, '=') orelse return error.UnknownStep;
        const name = step[0..eq];
        const arg = step[eq + 1 ..];
        inline for (@typeInfo(Step).@"union".field_names) |field| {
            if (comptime @FieldType(Step, field) == []const u8) {
                if (std.mem.eql(u8, name, field)) return @unionInit(Step, field, arg);
            }
        }
        return error.UnknownStep;
    }
};

fn perform(gui: *Gui, step: []const u8) !void {
    switch (try Step.parse(step)) {
        .click => |label| try pointAt(gui, label, true),
        .hover => |label| try pointAt(gui, label, false),
        .nsclick => |label| {
            const middle = try find(gui, label);
            shell.synthesizeClick(middle.x, middle.y);
        },
        .snapshot => |path| try snapshot(path, null),
        .snapshot2x => |path| try snapshot(path, 2),
        // quitting from inside this callback would stop the script waiting on it
        .quit => shell.runOnMain(quitLater, null),
    }
}

fn snapshot(path: []const u8, scale: ?f64) !void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    try shell.snapshot(try std.fmt.bufPrintSentinel(&buffer, "{s}", .{path}, 0), scale);
}

fn quitLater(_: ?*anyopaque) callconv(.c) void {
    shell.quit();
}

/// The middle of the text `label` in the last frame.
fn find(gui: *Gui, label: []const u8) error{NoSuchText}!fabrum.Vec2 {
    const unit = app.testing.findText(Text, gui.runtime.context(), label) orelse return error.NoSuchText;
    return app.testing.center(unit);
}

fn pointAt(gui: *Gui, label: []const u8, press: bool) !void {
    const middle = try find(gui, label);
    Gui.mouse(gui, middle.x, middle.y, 0, 0, 0);
    if (press) {
        Gui.mouse(gui, middle.x, middle.y, 1, 0, 0);
        Gui.mouse(gui, middle.x, middle.y, 0, 0, 0);
    }
}

test "steps parse by name" {
    try std.testing.expectEqualStrings("Click me!", (try Step.parse("nsclick=Click me!")).nsclick);
    try std.testing.expectEqualStrings("/tmp/a=b.png", (try Step.parse("snapshot=/tmp/a=b.png")).snapshot);
    try std.testing.expectEqual(Step.quit, try Step.parse("quit"));
    try std.testing.expectError(error.UnknownStep, Step.parse("quit=now"));
    try std.testing.expectError(error.UnknownStep, Step.parse("tap=Flat"));
}
