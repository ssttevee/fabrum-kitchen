//! Drives the GUI from `KITCHEN_SCRIPT` in debug builds, to check screens
//! without a person at the Mac.
//!
//! Steps are separated by `;`. Native elements are named by their key in
//! the root component (`line`, `click me`, ...). Most steps work in process
//! and send no events at all, so they work while the Mac is locked:
//!
//! - `click=<text>`, `hover=<text>`: a press and release, or a move, at the
//!   middle of the drawn text, fed straight to the runtime;
//! - `press=<key>`: a native control's own `performClick:`;
//! - `type=<key>:<text>`: focuses a native field and types into its field
//!   editor with `insertText:`, as keyboard text input does;
//! - `mark=<key>:<text>`, `commit=<key>:<text>`: an IME composition, with
//!   `setMarkedText:` and `insertText:`;
//! - `return=<key>`: Return in a native field, through its field editor;
//! - `slide=<key>:<value>`: moves a native slider and sends its action;
//! - `tab`, `backtab`: Tab and Shift-Tab through AppKit's own key-view
//!   routing, from wherever focus is;
//! - `space`: Space on the canvas, which clicks a focused drawn element;
//! - `menu=<menu>/<item>`: chooses a menu bar item;
//! - `answer=<index>`: answers the alert being shown;
//! - `choose=<path>`, `choose=`: answers the file chooser being shown with
//!   a path, or cancels it;
//! - `privateclipboard`: makes the clipboard a private pasteboard, so
//!   copying and pasting never touch the user's; `clipboard` prints it;
//! - `close`: the window's close button;
//! - `resize=<width>x<height>`: resizes the window's content;
//! - `dump`: prints the theme, the focus, the native views and the drawn
//!   texts;
//! - `hit=<x>,<y>`: prints the view AppKit's own hit-testing gives a click
//!   at that point of the content, without clicking;
//! - `wait=<ms>`: a pause;
//! - `snapshot=<path>`: the window's content drawn into a PNG, at the
//!   screen's scale; `snapshot2x=<path>` at two pixels per point;
//! - `quit`: quits as the menu item would.
//!
//! Two send AppKit events through the app's own window, which nothing
//! outside it sees, but which need an unlocked session:
//!
//! - `nsclick=<text>`: a mouse click at the middle of the drawn text;
//! - `key=tab`, `key=backtab`, `key=space`: the key, as the keyboard sends
//!   it.
//!
//! Nothing is ever posted to the system's event stream, and the real
//! pointer never moves. For example:
//!
//! ```sh
//! KITCHEN_SCRIPT='type=line:Hello;tab;dump;snapshot=/tmp/a.png;quit' zig build run
//! ```
const std = @import("std");
const Io = std.Io;

const fabrum = @import("fabrum");
const app = fabrum.app;
const appkit = app.platform.appkit;
const automation = appkit.automation;

pub fn Script(comptime App: type) type {
    return struct {
        gui: *App,
        io: Io,
        steps: std.mem.TokenIterator(u8, .scalar),
        /// The step handed to the main thread, and a signal that it ran.
        step: []const u8 = "",
        done: Io.Event = .unset,

        const Self = @This();
        const Root = App.Root;
        const Text = App.Runtime.Text;

        pub fn run(self: *Self) Io.Cancelable!void {
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
                automation.runOnMain(onMain, self);
                try self.done.wait(self.io);
                // give the frame it caused time to draw
                try self.io.sleep(.fromMilliseconds(200), .awake);
            }
        }

        fn onMain(ctx: ?*anyopaque) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            defer self.done.set(self.io);
            self.perform(self.step) catch |err| std.log.err("script step \"{s}\" failed: {t}", .{ self.step, err });
        }

        fn perform(self: *Self, step: []const u8) !void {
            switch (try Step.parse(step)) {
                .click => |label| try self.pointAt(label, true),
                .hover => |label| try self.pointAt(label, false),
                .nsclick => |label| {
                    const middle = try self.find(label);
                    automation.windowClick(middle.x, middle.y);
                },
                .press => |key| automation.click(try self.handle(key)),
                .type => |arg| {
                    const split = try keyed(arg);
                    automation.typeText(try self.handle(split.key), split.value);
                },
                .mark => |arg| {
                    const split = try keyed(arg);
                    automation.mark(try self.handle(split.key), split.value);
                },
                .commit => |arg| {
                    const split = try keyed(arg);
                    automation.commit(try self.handle(split.key), split.value);
                },
                .@"return" => |key| automation.newline(try self.handle(key)),
                .slide => |arg| {
                    const split = try keyed(arg);
                    automation.slide(try self.handle(split.key), try std.fmt.parseFloat(f64, split.value));
                },
                .tab => automation.tab(true),
                .backtab => automation.tab(false),
                .space => App.activate(self.gui),
                .key => |name| {
                    if (std.mem.eql(u8, name, "tab")) {
                        automation.windowKey(48, "\t", false);
                    } else if (std.mem.eql(u8, name, "backtab")) {
                        automation.windowKey(48, "\t", true);
                    } else if (std.mem.eql(u8, name, "space")) {
                        automation.windowKey(49, " ", false);
                    } else return error.UnknownKey;
                },
                .menu => |arg| {
                    const slash = std.mem.indexOfScalar(u8, arg, '/') orelse return error.BadStep;
                    var menu: [64:0]u8 = undefined;
                    var item: [64:0]u8 = undefined;
                    try automation.chooseMenu(
                        try std.fmt.bufPrintSentinel(&menu, "{s}", .{arg[0..slash]}, 0),
                        try std.fmt.bufPrintSentinel(&item, "{s}", .{arg[slash + 1 ..]}, 0),
                    );
                },
                .answer => |index| automation.answerAlert(try std.fmt.parseInt(usize, index, 10)),
                .choose => |path| {
                    var buffer: [std.fs.max_path_bytes]u8 = undefined;
                    try automation.answerFileChooser(if (path.len == 0) null else try std.fmt.bufPrintSentinel(&buffer, "{s}", .{path}, 0));
                },
                .privateclipboard => automation.usePrivateClipboard(),
                .clipboard => {
                    var buffer: [256]u8 = undefined;
                    std.debug.print("clipboard: \"{s}\"\n", .{automation.clipboardText(&buffer)});
                },
                .close => automation.runOnMain(closeLater, null),
                .resize => |size| {
                    const x = std.mem.indexOfScalar(u8, size, 'x') orelse return error.BadStep;
                    automation.resize(try std.fmt.parseFloat(f64, size[0..x]), try std.fmt.parseFloat(f64, size[x + 1 ..]));
                },
                .dump => self.dump(),
                .hit => |at| {
                    const comma = std.mem.indexOfScalar(u8, at, ',') orelse return error.BadStep;
                    var buffer: [256]u8 = undefined;
                    std.debug.print("hit {s}: {s}\n", .{ at, automation.describeHit(
                        try std.fmt.parseFloat(f64, at[0..comma]),
                        try std.fmt.parseFloat(f64, at[comma + 1 ..]),
                        &buffer,
                    ) });
                },
                .snapshot => |path| try snapshot(path, null),
                .snapshot2x => |path| try snapshot(path, 2),
                // quitting from inside this callback would stop the script waiting on it
                .quit => automation.runOnMain(quitLater, null),
            }
        }

        /// The AppKit object for the root's native element `key`.
        fn handle(self: *Self, key: []const u8) error{NoSuchNativeElement}!app.native.Handle {
            return self.gui.handleOf(app.testing.rootInstance(Root).native(key)) orelse {
                std.log.err("no native element \"{s}\"", .{key});
                return error.NoSuchNativeElement;
            };
        }

        /// The middle of the drawn text `label` in the last frame.
        fn find(self: *Self, label: []const u8) error{NoSuchText}!fabrum.Vec2 {
            const unit = app.testing.findText(Text, self.gui.runtime.context(), label) orelse return error.NoSuchText;
            return app.testing.center(unit);
        }

        fn pointAt(self: *Self, label: []const u8, press: bool) !void {
            const middle = try self.find(label);
            App.mouse(self.gui, middle.x, middle.y, 0, 0, 0);
            if (press) {
                App.mouse(self.gui, middle.x, middle.y, 1, 0, 0);
                App.mouse(self.gui, middle.x, middle.y, 0, 0, 0);
            }
        }

        /// Prints what a person would check: where focus is, each native
        /// view's frame and value, the canvas layers, and the drawn text.
        fn dump(self: *Self) void {
            var buffer: [256]u8 = undefined;
            std.debug.print("-- dump: window {d}, viewport {d}x{d}\n", .{ automation.windowNumber(), self.gui.viewport.x, self.gui.viewport.y });
            const theme = self.gui.backend.backend().theme();
            std.debug.print("theme: accent #{x:0>2}{x:0>2}{x:0>2}, font {d}, control height {d}, full keyboard access {}, dark {}\n", .{
                theme.accent.r, theme.accent.g, theme.accent.b, theme.font_size, theme.control_height, theme.full_keyboard_access, theme.dark,
            });
            std.debug.print("focus: AppKit {s}; fabrum {?}\n", .{ automation.describeFocus(&buffer), self.gui.runtime.focused() });
            const records = self.gui.runtime.reconciler().records;
            for (records.keys(), records.values()) |id, record| {
                std.debug.print("native {x} {t}", .{ id, record.spec });
                if (record.frame) |f| std.debug.print(" frame=({d},{d} {d}x{d})", .{ f.x, f.y, f.w, f.h });
                switch (record.spec) {
                    .text_field => std.debug.print(" text=\"{s}\" composing={}", .{
                        automation.fieldText(record.handle, &buffer),
                        self.gui.backend.backend().composing(record.handle),
                    }),
                    else => switch (record.shown) {
                        .toggle => |on| std.debug.print(" on={}", .{on}),
                        .number => |n| std.debug.print(" value={d}", .{n}),
                        else => {},
                    },
                }
                std.debug.print("\n", .{});
            }
            const scene = self.gui.runtime.scene();
            std.debug.print("scene: {d} slots, {d} canvas layers:", .{ scene.slots.len, scene.layers.len });
            for (scene.slots) |slot| std.debug.print(" {s}", .{if (slot == .canvas) "canvas" else "native"});
            for (scene.layers, 0..) |layer, index| {
                var counts = std.EnumArray(std.meta.Tag(fabrum.layout.RenderCommand.Data), usize).initFill(0);
                for (layer.commands) |command| counts.getPtr(command.data).* += 1;
                std.debug.print("\nlayer {d}:", .{index});
                var it = counts.iterator();
                while (it.next()) |entry| if (entry.value.* > 0) std.debug.print(" {t}={d}", .{ entry.key, entry.value.* });
            }
            std.debug.print("\ntexts:", .{});
            var it: app.testing.TextIterator(Text) = .init(self.gui.runtime.context());
            while (it.next()) |found| std.debug.print(" \"{s}\"", .{found.content.text});
            std.debug.print("\n", .{});
        }
    };
}

/// Writes where the hybrid screen's elements are to a file, ten times a
/// second, for drivers that click them with real input
/// (`KITCHEN_LAYOUT_FILE`). Lines are tab-separated, in points from the top
/// left of the window's content:
///
/// - `window <number> <width> <height>`: the window's number and the
///   content's size;
/// - `focus <AppKit's first responder> <fabrum's focus>`;
/// - `element <key> <x> <y> <w> <h>`: a drawn element, or a native
///   element's box;
/// - `native <key> <x> <y> <w> <h> <value>`: a native view's frame, in its
///   parent's coordinates (the page's content, for those in it), and what
///   it shows; for the page, its scroll offset and content size;
/// - `text <x> <y> <w> <h> <text>`: drawn text.
///
/// The file is replaced whole, so readers never see half of it.
pub fn LayoutFile(comptime App: type) type {
    return struct {
        gui: *App,
        io: Io,
        gpa: std.mem.Allocator,
        path: []const u8,

        const Self = @This();
        const Root = App.Root;
        const Text = App.Runtime.Text;
        const Hybrid = @import("kitchen.zig").Hybrid;

        const native_keys = .{ "page", "icon text", "click me", "green", "progress", "transform", "switch", "switched", "slider", "line", "uppercase", "notes", "rating" };
        const drawn_keys = .{ "flat", "strip", "open dialog", "close dialog", "backdrop", "dialog" };

        pub fn run(self: *Self) Io.Cancelable!void {
            while (true) {
                try self.io.sleep(.fromMilliseconds(100), .awake);
                automation.runOnMain(onMain, self);
            }
        }

        fn onMain(ctx: ?*anyopaque) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.write() catch |err| std.log.err("writing the layout file failed: {t}", .{err});
        }

        fn write(self: *Self) !void {
            var out: Io.Writer.Allocating = .init(self.gpa);
            defer out.deinit();
            const w = &out.writer;
            var buffer: [256]u8 = undefined;
            try w.print("window\t{d}\t{d}\t{d}\n", .{ automation.windowNumber(), self.gui.viewport.x, self.gui.viewport.y });
            try w.print("focus\t{s}\t{?}\n", .{ automation.describeFocus(&buffer), self.gui.runtime.focused() });
            const context = self.gui.runtime.context();
            const root = app.testing.rootInstance(Root);
            if (Root == Hybrid) {
                inline for (drawn_keys ++ native_keys) |key| try element(w, context, key, root.element(key));
                inline for (.{ Hybrid.Choice.r1, Hybrid.Choice.r2, Hybrid.Choice.r3 }) |choice| try element(w, context, @tagName(choice), root.element(choice));
                const records = self.gui.runtime.reconciler().records;
                for (0..Hybrid.row_count) |i| {
                    const index: u8 = @intCast(i);
                    var name: [16]u8 = undefined;
                    try element(w, context, try std.fmt.bufPrint(&name, "row {d}", .{i}), root.element(Hybrid.RowKey{ .row = index }));
                    const pick: Hybrid.PickKey = .{ .pick = index };
                    try element(w, context, try std.fmt.bufPrint(&name, "pick {d}", .{i}), root.element(pick));
                    if (records.getPtr(root.native(pick))) |record| if (record.frame) |f| {
                        try w.print("native\tpick {d}\t{d}\t{d}\t{d}\t{d}\ttitle={s}\n", .{ i, f.x, f.y, f.w, f.h, record.spec.button.title });
                    };
                }
                inline for (native_keys) |key| if (records.getPtr(root.native(key))) |record| {
                    const f = record.frame orelse fabrum.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
                    try w.print("native\t{s}\t{d}\t{d}\t{d}\t{d}\t", .{ key, f.x, f.y, f.w, f.h });
                    switch (record.spec) {
                        .text_field => try w.print("text={s} composing={}", .{
                            automation.fieldText(record.handle, &buffer),
                            self.gui.backend.backend().composing(record.handle),
                        }),
                        .button => |b| try w.print("title={s} enabled={}", .{ b.title, b.enabled }),
                        .scroll_view => try w.print("scroll={d},{d} content={d}x{d}", .{
                            record.scroll.x,                    record.scroll.y,
                            if (record.content) |c| c.x else 0, if (record.content) |c| c.y else 0,
                        }),
                        else => switch (record.shown) {
                            .toggle => |on| try w.print("on={}", .{on}),
                            .number => |n| try w.print("value={d}", .{n}),
                            else => {},
                        },
                    }
                    try w.writeAll("\n");
                };
            }
            var it: app.testing.TextIterator(Text) = .init(context);
            while (it.next()) |found| {
                const b = found.unit.bbox;
                try w.print("text\t{d}\t{d}\t{d}\t{d}\t{s}\n", .{ b.x, b.y, b.w, b.h, found.content.text });
            }
            var tmp: [std.fs.max_path_bytes]u8 = undefined;
            const tmp_path = try std.fmt.bufPrint(&tmp, "{s}.tmp", .{self.path});
            try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = tmp_path, .data = out.written() });
            try Io.Dir.rename(.cwd(), tmp_path, .cwd(), self.path, self.io);
        }

        fn element(w: *Io.Writer, context: anytype, key: []const u8, id: fabrum.layout.Unit.Id) !void {
            const unit = context.getUnitById(id) orelse return;
            const b = unit.bbox;
            try w.print("element\t{s}\t{d}\t{d}\t{d}\t{d}\n", .{ key, b.x, b.y, b.w, b.h });
        }
    };
}

const Step = union(enum) {
    click: []const u8,
    hover: []const u8,
    nsclick: []const u8,
    press: []const u8,
    type: []const u8,
    mark: []const u8,
    commit: []const u8,
    @"return": []const u8,
    slide: []const u8,
    tab,
    backtab,
    space,
    key: []const u8,
    menu: []const u8,
    answer: []const u8,
    choose: []const u8,
    privateclipboard,
    clipboard,
    close,
    resize: []const u8,
    dump,
    hit: []const u8,
    snapshot: []const u8,
    snapshot2x: []const u8,
    quit,

    fn parse(step: []const u8) error{UnknownStep}!Step {
        inline for (@typeInfo(Step).@"union".field_names) |field| {
            if (comptime @FieldType(Step, field) == void) {
                if (std.mem.eql(u8, step, field)) return @field(Step, field);
            }
        }
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

/// `<key>:<value>`, split at the first colon.
fn keyed(arg: []const u8) error{BadStep}!struct { key: []const u8, value: []const u8 } {
    const colon = std.mem.indexOfScalar(u8, arg, ':') orelse return error.BadStep;
    return .{ .key = arg[0..colon], .value = arg[colon + 1 ..] };
}

fn snapshot(path: []const u8, scale: ?f64) !void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    try automation.snapshot(try std.fmt.bufPrintSentinel(&buffer, "{s}", .{path}, 0), scale);
}

fn quitLater(_: ?*anyopaque) callconv(.c) void {
    automation.quit();
}

fn closeLater(_: ?*anyopaque) callconv(.c) void {
    automation.close();
}

test "steps parse by name" {
    try std.testing.expectEqualStrings("Click me!", (try Step.parse("nsclick=Click me!")).nsclick);
    try std.testing.expectEqualStrings("/tmp/a=b.png", (try Step.parse("snapshot=/tmp/a=b.png")).snapshot);
    try std.testing.expectEqual(Step.quit, try Step.parse("quit"));
    try std.testing.expectEqual(Step.tab, try Step.parse("tab"));
    const typed = try keyed((try Step.parse("type=line:a:b")).type);
    try std.testing.expectEqualStrings("line", typed.key);
    try std.testing.expectEqualStrings("a:b", typed.value);
}
