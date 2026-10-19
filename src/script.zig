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
//! - `select=<key>:<index>`: chooses an item of a native dropdown or radio
//!   group; `step=<key>:<n>`: steps a native stepper `n` up (or down);
//! - `answermenu=<id>`, `answermenu=`: chooses an item of the popup menu
//!   being shown (`Update.menu`), or dismisses it;
//! - `scroll=<key>:<y>`: scrolls a native scroll view so that `y` of its
//!   content is at its top, as far as it goes;
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
                    const key, const text = try cut(arg, ':');
                    automation.typeText(try self.handle(key), text);
                },
                .mark => |arg| {
                    const key, const text = try cut(arg, ':');
                    automation.mark(try self.handle(key), text);
                },
                .commit => |arg| {
                    const key, const text = try cut(arg, ':');
                    automation.commit(try self.handle(key), text);
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
                .answermenu => |id| try automation.answerPopup(if (id.len == 0) null else try std.fmt.parseInt(usize, id, 10)),
                .scroll => |arg| {
                    const key, const y = try cut(arg, ':');
                    automation.scrollTo(try self.handle(key), .init(0, try std.fmt.parseFloat(f32, y)));
                },
                .tab => automation.tab(true),
                .backtab => automation.tab(false),
                .space => App.activate(self.gui),
                .key => |name| switch (std.meta.stringToEnum(enum { tab, backtab, space }, name) orelse return error.UnknownKey) {
                    .tab => automation.windowKey(48, "\t", false),
                    .backtab => automation.windowKey(48, "\t", true),
                    .space => automation.windowKey(49, " ", false),
                },
                .menu => |arg| {
                    const menu_name, const item_name = try cut(arg, '/');
                    var menu: [64:0]u8 = undefined;
                    var item: [64:0]u8 = undefined;
                    try automation.chooseMenu(
                        try std.fmt.bufPrintSentinel(&menu, "{s}", .{menu_name}, 0),
                        try std.fmt.bufPrintSentinel(&item, "{s}", .{item_name}, 0),
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
                    const w, const h = try cut(size, 'x');
                    automation.resize(try std.fmt.parseFloat(f64, w), try std.fmt.parseFloat(f64, h));
                },
                .dump => self.dump(),
                .hit => |at| {
                    const x, const y = try cut(at, ',');
                    var buffer: [256]u8 = undefined;
                    std.debug.print("hit {s}: {s}\n", .{ at, automation.describeHit(
                        try std.fmt.parseFloat(f64, x),
                        try std.fmt.parseFloat(f64, y),
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
            const damage = self.gui.backend.canvas_damage.stats;
            std.debug.print("canvas layers presented {d}, of which unchanged and not redrawn {d}\n", .{ damage.presented, damage.skipped });
            const records = self.gui.runtime.reconciler().records;
            for (records.keys(), records.values()) |id, record| {
                std.debug.print("native {x} {t}", .{ id, record.spec });
                if (record.frame) |f| std.debug.print(" frame=({d},{d} {d}x{d})", .{ f.x, f.y, f.w, f.h });
                if (record.spec.isTextInput()) {
                    std.debug.print(" text=\"{s}\" composing={}", .{
                        automation.fieldText(record.handle, &buffer),
                        self.gui.backend.backend().composing(record.handle),
                    });
                } else switch (record.shown) {
                    .toggle => |on| std.debug.print(" on={}", .{on}),
                    .number => |n| std.debug.print(" value={d}", .{n}),
                    .selection => |i| std.debug.print(" selected={?d}", .{i}),
                    else => {},
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

        const native_keys = .{ "page", "icon text", "click me", "green", "progress", "transform", "switch", "switched", "busy", "slider", "line", "uppercase", "notes", "fruit", "count", "size", "para", "query", "secret", "rating", "open file", "copy heading", "paste notes", "ask", "menu" };
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
                        .text_field, .text_area, .search_field, .secure_field => try w.print("text={s} composing={}", .{
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

/// A step of the script, parsed by name: the names are the fields, and
/// those with an argument take what follows `=`. The GTK Kitchen plays the
/// steps it has an equivalent for.
pub const Step = union(enum) {
    click: []const u8,
    hover: []const u8,
    nsclick: []const u8,
    press: []const u8,
    type: []const u8,
    mark: []const u8,
    commit: []const u8,
    @"return": []const u8,
    slide: []const u8,
    select: []const u8,
    step: []const u8,
    answermenu: []const u8,
    scroll: []const u8,
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

    pub fn parse(step: []const u8) error{UnknownStep}!Step {
        inline for (@typeInfo(Step).@"union".field_names) |field| {
            if (comptime @FieldType(Step, field) == void) {
                if (std.mem.eql(u8, step, field)) return @field(Step, field);
            }
        }
        const name, const arg = std.mem.cutScalar(u8, step, '=') orelse return error.UnknownStep;
        inline for (@typeInfo(Step).@"union".field_names) |field| {
            if (comptime @FieldType(Step, field) == []const u8) {
                if (std.mem.eql(u8, name, field)) return @unionInit(Step, field, arg);
            }
        }
        return error.UnknownStep;
    }
};

/// A step's argument split at the first `separator`: `<key>:<value>`,
/// `<menu>/<item>`, `<width>x<height>`.
pub fn cut(arg: []const u8, separator: u8) error{BadStep}!struct { []const u8, []const u8 } {
    return std.mem.cutScalar(u8, arg, separator) orelse error.BadStep;
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
    const key, const text = try cut((try Step.parse("type=line:a:b")).type, ':');
    try std.testing.expectEqualStrings("line", key);
    try std.testing.expectEqualStrings("a:b", text);
    try std.testing.expectError(error.BadStep, cut("800", 'x'));
    try std.testing.expectError(error.UnknownStep, Step.parse("fly=away"));
}
