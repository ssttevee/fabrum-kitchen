//! The root component: Gio's Kitchen, a page of every kind of widget.
//!
//! This first screen has what fabrum can do on every platform. Still to
//! come here, some of it already built for drawn widgets on the `none`
//! platform (see `docs/input-design.md` and `none.zig`):
//!
//! - the heading as selectable text, changed by the line editor;
//! - the multi-line editor, at most 200 points tall, that scrolls inside;
//! - the bordered, italic line editor that sets the heading on Enter;
//! - the gradient strip;
//! - the progress bar and circle moving on their own, and the spinner
//!   turning;
//! - "Transform" rotating the whole page;
//! - the slider and its value;
//! - the page itself scrolling.
const std = @import("std");

const fabrum = @import("fabrum");
const app = fabrum.app;

const theme = @import("theme.zig");
const widgets = @import("widgets.zig");

const Kitchen = @This();

pub const Choice = enum { r1, r2, r3 };

pub const State = struct {
    /// The big text at the top. Set by the line editor, once there is one.
    heading: []const u8 = "Hello, fabrum",
    /// Whether the second button is green; "Click me!" flips it.
    green: bool = true,
    /// Of the progress bar and circle, from 0 to 1. Gio's ticks up by a
    /// tenth every second; this one stands still until fabrum has timers.
    progress: f32 = 0.3,
    /// "Transform": would rotate the page.
    transform: bool = false,
    /// The switch enables the button next to it and shows the spinner.
    switched: bool = false,
    /// The chosen radio button, if any.
    choice: ?Choice = null,
};

pub const Msg = union(enum) {
    toggle_green,
    toggle_transform,
    toggle_switch,
    choose: Choice,
    /// From buttons that only show that they can be pressed, as in Gio.
    ignore,
};

pub const Props = struct {
    /// Disables every widget, as Gio's `-disable` flag does.
    disabled: bool = false,
};

pub fn update(state: *State, msg: Msg, _: *app.Update(Kitchen)) void {
    switch (msg) {
        .toggle_green => state.green = !state.green,
        .toggle_transform => state.transform = !state.transform,
        .toggle_switch => state.switched = !state.switched,
        .choose => |choice| state.choice = choice,
        .ignore => {},
    }
}

pub fn view(ui: *app.Ui, state: *const State, props: Props) !void {
    const on = ui.messages(Kitchen);

    try ui.open(null, .{
        .layout = .{ .sizing = .grow(.{}), .axis = .y },
        .background_color = theme.background,
    });
    defer ui.close();
    if (props.disabled) try ui.provide(theme.Disabled, &theme.Disabled.on);

    {
        try item(ui);
        defer ui.close();
        try ui.text(state.heading, theme.font(.h3, theme.foreground));
    }
    {
        try row(ui);
        defer ui.close();
        try widgets.iconButton(ui, "icon", .add, on.bind(.ignore));
        try widgets.iconTextButton(ui, "icon text", .add, "Icon", on.bind(.ignore));
        try widgets.button(ui, "click me", "Click me!", .{ .on_click = on.bind(.toggle_green) });
        try widgets.button(ui, "green", if (state.green) "Green" else "Blue", .{
            .on_click = on.bind(.ignore),
            .background = if (state.green) theme.green else theme.primary,
        });
        try widgets.flatButton(ui, "flat", "Flat", on.bind(.ignore));
        try widgets.ring(ui, "progress circle", 40);
    }
    {
        try item(ui);
        defer ui.close();
        try widgets.progressBar(ui, state.progress);
    }
    {
        try row(ui);
        defer ui.close();
        try widgets.checkbox(ui, "transform", "Transform", state.transform, on.bind(.toggle_transform));
        try widgets.toggle(ui, "switch", "Example Switch", state.switched, on.bind(.toggle_switch));
        {
            // the switch disables just this button
            try ui.open(null, .{});
            defer ui.close();
            if (!state.switched) try ui.provide(theme.Disabled, &theme.Disabled.on);
            try widgets.button(ui, "switched", if (state.switched) "enabled" else "disabled", .{ .on_click = on.bind(.ignore) });
        }
        if (state.switched) try widgets.ring(ui, "spinner", 24);
    }
    {
        try row(ui);
        defer ui.close();
        inline for (.{ .r1, .r2, .r3 }, .{ "RadioButton1", "RadioButton2", "RadioButton3" }) |choice, label| {
            try widgets.radio(ui, choice, label, state.choice == @as(Choice, choice), on.bind(.{ .choose = choice }));
        }
    }
}

/// Opens one item of the page, with Gio's 16-point inset. Close it.
fn item(ui: *app.Ui) !void {
    try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .padding = .all(16) } });
}

/// Opens an item that lays its widgets out in a row. Close it.
fn row(ui: *app.Ui) !void {
    try ui.open(null, .{ .layout = .{
        .sizing = .{ .width = .grow(.{}) },
        .padding = .all(16),
        .child_gap = 16,
        .child_alignment = .center_left,
    } });
}
