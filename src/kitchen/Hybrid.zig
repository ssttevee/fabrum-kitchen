//! The Kitchen's first screen in the hybrid model: the platform's own
//! controls, laid out by fabrum, next to drawn content.
//!
//! - Buttons, the progress bar, the checkbox, the switch, the slider and
//!   the two editors are native (`app.widgets`); "Flat", the heading, the
//!   labels and the radio buttons are drawn, in a canvas strip.
//! - "Open dialog" opens a drawn dialog over the native line editor, which
//!   a canvas layer above the native views draws; it is modal, so focus and
//!   Tab stay inside it.
//! - Tab goes through native fields and drawn radio buttons in one order.
//! - The line editor is controlled: typing updates the model; Enter moves
//!   its text to the heading and clears it; "Uppercase" makes the model
//!   change what was typed, which is written back without breaking typing.
//! - The menu bar has Kitchen > Say Hello (Cmd-K), which shows a native
//!   alert; its answer comes back as a message.
//!
//! On a platform without native controls, such as `none`, `app.widgets`
//! draws them, and the same screen is entirely drawn (`kitchen-none`).
//!
//! `Kitchen.zig` is the same screen drawn entirely by fabrum, for
//! comparison (`kitchen --drawn`).
const std = @import("std");
const Allocator = std.mem.Allocator;

const fabrum = @import("fabrum");
const app = fabrum.app;
const widgets = app.widgets;
const menus = app.menus;
const dialogs = app.dialogs;
const Color = fabrum.Color;

const Hybrid = @This();

pub const Choice = enum { r1, r2, r3 };

pub const State = struct {
    /// The big text at the top; "Hello, fabrum" until the line editor
    /// sets it.
    heading: std.ArrayList(u8) = .empty,
    /// Whether the second button reads "Green"; "Click me!" flips it.
    green: bool = true,
    progress: f64 = 0.3,
    transform: bool = false,
    switched: bool = false,
    slider: f64 = 0.3,
    /// The line editor's text, controlled.
    line: std.ArrayList(u8) = .empty,
    /// Makes the model store the line in capitals.
    uppercase: bool = false,
    notes: std.ArrayList(u8) = .empty,
    choice: ?Choice = null,
    rating: f64 = 3,
    dialog: bool = false,
    /// Whether the alert is up.
    greeting: bool = false,
    greetings: usize = 0,
    /// The button the alert was last answered with.
    answer: ?usize = null,

    pub fn deinit(self: *State, gpa: Allocator) void {
        self.heading.deinit(gpa);
        self.line.deinit(gpa);
        self.notes.deinit(gpa);
    }
};

pub const Msg = union(enum) {
    toggle_green,
    ignore,
    transform: bool,
    switched: bool,
    slide: f64,
    line: []const u8,
    submit_line,
    uppercase: bool,
    notes: []const u8,
    choose: Choice,
    rate: f64,
    open_dialog,
    close_dialog,
    say_hello,
    answered: usize,
};

pub const Props = struct {
    /// Whether the page has the window's background. An overlay leaves it
    /// out, so what is under it shows between the widgets, and clicks
    /// there go through to it.
    page: bool = true,
};

pub fn update(state: *State, msg: Msg, ctx: *app.Update(Hybrid)) void {
    const gpa = ctx.gpa;
    switch (msg) {
        .toggle_green => state.green = !state.green,
        .ignore => {},
        .transform => |on| state.transform = on,
        .switched => |on| state.switched = on,
        .slide => |value| {
            state.slider = value;
            state.progress = value;
        },
        // text messages borrow the field's text: copy it
        .line => |text| {
            replace(&state.line, gpa, text);
            if (state.uppercase) upper(state.line.items);
        },
        .submit_line => {
            replace(&state.heading, gpa, state.line.items);
            state.line.clearRetainingCapacity();
        },
        .uppercase => |on| {
            state.uppercase = on;
            if (on) upper(state.line.items);
        },
        .notes => |text| replace(&state.notes, gpa, text),
        .choose => |choice| state.choice = choice,
        .rate => |value| state.rating = value,
        .open_dialog => state.dialog = true,
        .close_dialog => state.dialog = false,
        .say_hello => {
            state.greetings += 1;
            state.greeting = true;
        },
        .answered => |index| {
            state.answer = index;
            state.greeting = false;
        },
    }
}

fn replace(list: *std.ArrayList(u8), gpa: Allocator, text: []const u8) void {
    list.clearRetainingCapacity();
    // out of memory leaves the field's old text, which the next frame
    // writes back
    list.appendSlice(gpa, text) catch {};
}

fn upper(text: []u8) void {
    for (text) |*c| c.* = std.ascii.toUpper(c.*);
}

pub fn view(ui: *app.Ui, state: *const State, props: Props) !void {
    const on = ui.messages(Hybrid);
    const theme = ui.use(app.native.Theme);

    try ui.open(null, .{
        .layout = .{ .sizing = .grow(.{}), .axis = .y },
        .background_color = if (props.page) theme.window_background else .transparent,
    });
    defer ui.close();

    {
        try item(ui);
        defer ui.close();
        try ui.text(if (state.heading.items.len > 0) state.heading.items else "Hello, fabrum", font(theme, 40, theme.text));
    }
    {
        try row(ui);
        defer ui.close();
        try widgets.button(ui, "icon text", .{ .label = "Icon", .on_click = on.bind(.ignore) });
        try widgets.button(ui, "click me", .{ .label = "Click me!", .on_click = on.bind(.toggle_green) });
        try widgets.button(ui, "green", .{ .label = if (state.green) "Green" else "Blue", .on_click = on.bind(.ignore), .default = true });
        try flatButton(ui, "flat", "Flat", on.bind(.ignore));
    }
    {
        try item(ui);
        defer ui.close();
        try widgets.progressBar(ui, "progress", .{ .value = state.progress });
    }
    {
        try row(ui);
        defer ui.close();
        try widgets.checkbox(ui, "transform", .{ .label = "Transform", .checked = state.transform, .on_change = on.handler(.transform) });
        try widgets.toggle(ui, "switch", .{ .on = state.switched, .on_change = on.handler(.switched) });
        try ui.text("Example Switch", font(theme, theme.font_size, theme.text));
        try widgets.button(ui, "switched", .{ .label = if (state.switched) "enabled" else "disabled", .on_click = on.bind(.ignore), .enabled = state.switched });
    }
    {
        try row(ui);
        defer ui.close();
        try ui.text("Slider", font(theme, theme.font_size, theme.text));
        try widgets.slider(ui, "slider", .{ .value = state.slider, .on_change = on.handler(.slide) });
        try ui.print(font(theme, theme.font_size, theme.text), "{d:.2}", .{state.slider});
    }
    {
        try row(ui);
        defer ui.close();
        try ui.text("Line editor", font(theme, theme.font_size, theme.text));
        try widgets.textField(ui, "line", .{
            .text = state.line.items,
            .placeholder = "Hint",
            .on_change = on.handler(.line),
            .on_submit = on.bind(.submit_line),
        });
        try widgets.checkbox(ui, "uppercase", .{ .label = "Uppercase", .checked = state.uppercase, .on_change = on.handler(.uppercase) });
    }
    try canvasStrip(ui, state, theme);
    {
        try row(ui);
        defer ui.close();
        try ui.text("Notes", font(theme, theme.font_size, theme.text));
        try widgets.textField(ui, "notes", .{ .text = state.notes.items, .placeholder = "Anything", .on_change = on.handler(.notes) });
    }
    {
        try row(ui);
        defer ui.close();
        try ui.text("Rating", font(theme, theme.font_size, theme.text));
        // a widget only AppKit has, and the common one elsewhere, or where
        // the controls are drawn
        if (comptime app.platform.kind == .appkit) {
            if (ui.hasNativeWidgets()) {
                try app.platform.appkit.widgets.levelIndicator(ui, "rating", .{ .value = state.rating, .on_change = on.handler(.rate) });
            } else {
                try widgets.slider(ui, "rating", .{ .value = state.rating, .max = 5, .on_change = on.handler(.rate) });
            }
        } else {
            try widgets.slider(ui, "rating", .{ .value = state.rating, .max = 5, .on_change = on.handler(.rate) });
        }
        try ui.print(font(theme, theme.font_size, theme.secondary_text), "{d:.0} of 5; greeted {d} times, last answer {?d}", .{ state.rating, state.greetings, state.answer });
    }

    try menus.item(ui, "say hello", .{ .menu = "Kitchen", .title = "Say Hello", .key = "k", .on_select = on.bind(.say_hello) });
    if (state.greeting) try dialogs.alert(ui, "hello", .{
        .title = "Hello from fabrum",
        .message = "A native alert, declared by a view and answered with a message.",
        .buttons = &.{ "OK", "Again" },
        .on_response = on.handler(.answered),
    });

    if (state.dialog) try dialog(ui, theme);
}

/// The drawn part of the page: a strip with radio buttons that join the
/// Tab order with the native fields, and a button that opens the dialog.
fn canvasStrip(ui: *app.Ui, state: *const State, theme: *const app.native.Theme) !void {
    const on = ui.messages(Hybrid);
    try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .padding = .all(16) } });
    defer ui.close();
    try ui.open("strip", .{
        .layout = .{ .sizing = .{ .width = .grow(.{}) }, .padding = .all(12), .child_gap = 16, .child_alignment = .center_left },
        .background_color = theme.accent.withAlpha(30),
        .corner_radius = .uniform(8),
        .border = .{ .color = theme.accent.withAlpha(90), .widths = .outside(1) },
    });
    defer ui.close();
    inline for (.{ .r1, .r2, .r3 }, .{ "RadioButton1", "RadioButton2", "RadioButton3" }) |choice, label| {
        try radio(ui, choice, label, state.choice == @as(Choice, choice), on.bind(.{ .choose = choice }), theme);
    }
    ui.spacer();
    try drawnButton(ui, "open dialog", "Open dialog", on.bind(.open_dialog), theme);
}

/// A drawn dialog over everything, native views included.
fn dialog(ui: *app.Ui, theme: *const app.native.Theme) !void {
    const on = ui.messages(Hybrid);
    try ui.open("backdrop", .{
        // high enough that the dialog sits over the line editor
        .layout = .{ .sizing = .grow(.{}), .child_alignment = .top_center, .padding = .init(0, 0, 170, 0) },
        .floating = .{ .mode = .root },
        .background_color = .rgba(0, 0, 0, 90),
        // clicks on the backdrop go nowhere, but don't reach what's under it
        .on_click = on.bind(.ignore),
        // nor does the keyboard: Tab stays in the dialog
        .modal = true,
    });
    defer ui.close();
    try ui.open("dialog", .{
        .layout = .{ .sizing = .{ .width = .fixed(420) }, .axis = .y, .padding = .all(24), .child_gap = 16 },
        .background_color = theme.control_background,
        .corner_radius = .uniform(12),
        .border = .{ .color = theme.separator, .widths = .outside(1) },
    });
    defer ui.close();
    try ui.text("A drawn dialog", font(theme, 20, theme.text));
    try ui.text("It covers the native line editor below it.", font(theme, theme.font_size, theme.secondary_text));
    try drawnButton(ui, "close dialog", "Close", on.bind(.close_dialog), theme);
}

fn font(theme: *const app.native.Theme, size: f32, color: Color) fabrum.layout.text.Style {
    _ = theme;
    return .{ .font_size = size, .color = color, .wrap_mode = .none };
}

/// A drawn button in the accent color, focusable, with a focus ring.
fn drawnButton(ui: *app.Ui, key: anytype, label: []const u8, on_click: app.Action, theme: *const app.native.Theme) !void {
    const fill = if (ui.pressed(key)) mix(theme.accent, .black, 0.15) else if (ui.hovered(key)) mix(theme.accent, .white, 0.12) else theme.accent;
    // the ring goes around the fill, since borders are drawn inside the box
    try ui.open(key, .{
        .layout = .{ .padding = .all(3) },
        .corner_radius = .uniform(9),
        .border = .{ .color = if (ui.focused(key)) theme.focus_ring else .transparent, .widths = .outside(3) },
        .on_click = on_click,
        .focusable = true,
    });
    defer ui.close();
    try ui.open(null, .{ .layout = .{ .padding = .init(14, 14, 6, 6) }, .background_color = fill, .corner_radius = .uniform(6) });
    defer ui.close();
    try ui.text(label, font(theme, theme.font_size, .white));
}

/// Clickable text with an overlay on hover: drawn, next to native buttons.
fn flatButton(ui: *app.Ui, key: anytype, label: []const u8, on_click: app.Action) !void {
    const theme = ui.use(app.native.Theme);
    const overlay: Color = if (ui.pressed(key)) .rgba(0, 0, 0, 48) else if (ui.hovered(key)) .rgba(0, 0, 0, 24) else .transparent;
    try ui.open(key, .{
        .layout = .{ .padding = .init(12, 12, 4, 4), .child_alignment = .center },
        .background_color = overlay,
        .corner_radius = .uniform(4),
        .on_click = on_click,
    });
    defer ui.close();
    try ui.text(label, font(theme, theme.font_size, theme.text));
}

/// A drawn radio button that joins the Tab order.
fn radio(ui: *app.Ui, key: anytype, label: []const u8, selected: bool, on_click: app.Action, theme: *const app.native.Theme) !void {
    const color = if (selected or ui.hovered(key)) theme.accent else theme.secondary_text;
    try ui.open(key, .{
        .layout = .{ .padding = .all(4), .child_gap = 8, .child_alignment = .center_left },
        .corner_radius = .uniform(6),
        .border = .{ .color = if (ui.focused(key)) theme.focus_ring else .transparent, .widths = .outside(3) },
        .on_click = on_click,
        .focusable = true,
    });
    defer ui.close();
    {
        try ui.open(null, .{
            .layout = .{ .sizing = .fixed(16), .child_alignment = .center },
            .corner_radius = .uniform(8),
            .background_color = theme.control_background,
            .border = .{ .color = color, .widths = .outside(2) },
        });
        defer ui.close();
        if (selected) {
            try ui.open(null, .{ .layout = .{ .sizing = .fixed(8) }, .background_color = color, .corner_radius = .uniform(4) });
            ui.close();
        }
    }
    try ui.text(label, font(theme, theme.font_size, theme.text));
}

fn mix(a: Color, b: Color, t: f32) Color {
    const channel = struct {
        fn of(x: u8, y: u8, f: f32) u8 {
            return @intFromFloat(@round(@as(f32, @floatFromInt(x)) * (1 - f) + @as(f32, @floatFromInt(y)) * f));
        }
    }.of;
    return .rgba(channel(a.r, b.r, t), channel(a.g, b.g, t), channel(a.b, b.b, t), a.a);
}

/// Opens one item of the page, with Gio's 16-point inset. Close it.
fn item(ui: *app.Ui) !void {
    try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .padding = .init(16, 16, 8, 8) } });
}

/// Opens an item that lays its widgets out in a row. Close it.
fn row(ui: *app.Ui) !void {
    try ui.open(null, .{ .layout = .{
        .sizing = .{ .width = .grow(.{}) },
        .padding = .init(16, 16, 8, 8),
        .child_gap = 12,
        .child_alignment = .center_left,
    } });
}
