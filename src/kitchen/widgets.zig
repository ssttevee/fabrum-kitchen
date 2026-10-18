//! The Kitchen's widgets, after Gio's material ones. They are view helpers
//! rather than components: they keep no state, take the element key to
//! use, and fire whatever `app.Action` the caller binds. Under a provided
//! `theme.Disabled` they draw greyed out and fire nothing.
//!
//! What fabrum can't draw yet is approximated, and marked where it is.
const std = @import("std");

const fabrum = @import("fabrum");
const app = fabrum.app;
const Color = fabrum.Color;

const theme = @import("theme.zig");

pub const ButtonOptions = struct {
    /// Null makes the button inert, as in Gio, where an unhandled button
    /// still presses.
    on_click: ?app.Action,
    background: Color = theme.primary,
};

/// The action of a widget at this point of the view: none when disabled.
fn live(ui: *const app.Ui, action: ?app.Action) ?app.Action {
    return if (theme.enabled(ui)) action else null;
}

/// The fill of a widget's surface for its hover and press state.
fn surface(ui: *const app.Ui, key: anytype, color: Color) Color {
    if (!theme.enabled(ui)) return theme.disabled_fill;
    if (ui.pressed(key)) return theme.pressed(color);
    if (ui.hovered(key)) return theme.hovered(color);
    return color;
}

/// A contained button with a text label: `material.Button`.
pub fn button(ui: *app.Ui, key: anytype, label: []const u8, options: ButtonOptions) !void {
    try ui.open(key, .{
        .layout = .{ .padding = .init(12, 12, 10, 10), .child_alignment = .center },
        .background_color = surface(ui, key, options.background),
        .corner_radius = .uniform(4),
        .on_click = live(ui, options.on_click),
    });
    defer ui.close();
    try ui.text(label, theme.font(.body, theme.contrast));
}

/// A round button showing only an icon: `material.IconButton`.
pub fn iconButton(ui: *app.Ui, key: anytype, icon: theme.Icon, on_click: ?app.Action) !void {
    try ui.open(key, .{
        .layout = .{ .padding = .all(12) },
        .background_color = surface(ui, key, theme.primary),
        .corner_radius = .uniform(24),
        .on_click = live(ui, on_click),
    });
    defer ui.close();
    try theme.icon(ui, icon, theme.contrast, 24);
}

/// A button with an icon before its label.
pub fn iconTextButton(ui: *app.Ui, key: anytype, icon: theme.Icon, label: []const u8, on_click: ?app.Action) !void {
    try ui.open(key, .{
        .layout = .{ .padding = .all(12), .child_gap = 10, .child_alignment = .center },
        .background_color = surface(ui, key, theme.primary),
        .corner_radius = .uniform(4),
        .on_click = live(ui, on_click),
    });
    defer ui.close();
    try theme.icon(ui, icon, theme.contrast, 24);
    try ui.text(label, theme.font(.body, theme.contrast));
}

/// Clickable text with no surface until hovered: `material.Clickable`
/// around a label.
pub fn flatButton(ui: *app.Ui, key: anytype, label: []const u8, on_click: ?app.Action) !void {
    const enabled = theme.enabled(ui);
    const overlay: Color = if (!enabled) .transparent else if (ui.pressed(key)) .rgba(0, 0, 0, 48) else if (ui.hovered(key)) .rgba(0, 0, 0, 24) else .transparent;
    try ui.open(key, .{
        .layout = .{ .padding = .all(12), .child_alignment = .center },
        .background_color = overlay,
        .corner_radius = .uniform(4),
        .on_click = live(ui, on_click),
    });
    defer ui.close();
    try ui.text(label, theme.font(.body, if (enabled) theme.foreground else theme.foreground.withAlpha(150)));
}

/// A thin bar filled to `progress`, from 0 to 1: `material.ProgressBar`.
pub fn progressBar(ui: *app.Ui, progress: f32) !void {
    const color = if (theme.enabled(ui)) theme.primary else theme.disabled_fill;
    try ui.open(null, .{
        .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(4) } },
        .background_color = color.withAlpha(96),
        .corner_radius = .uniform(2),
    });
    defer ui.close();
    try ui.open(null, .{
        .layout = .{ .sizing = .{ .width = .percent(std.math.clamp(progress, 0, 1)), .height = .grow(.{}) } },
        .background_color = color,
        .corner_radius = .uniform(2),
    });
    ui.close();
}

/// A ring standing for `material.ProgressCircle` and `material.Loader`.
///
/// Approximated: the renderer can't stroke arcs yet, so this is the whole
/// track, without the arc for the progress or the spinner's rotation.
pub fn ring(ui: *app.Ui, key: anytype, size: f32) !void {
    try ui.open(key, .{
        .layout = .{ .sizing = .fixed(size) },
        .corner_radius = .uniform(size / 2),
        .border = .{ .color = theme.primary.withAlpha(110), .widths = .outside(size / 8) },
    });
    ui.close();
}

/// A box that shows a check while `checked`, then its label:
/// `material.CheckBox`.
pub fn checkbox(ui: *app.Ui, key: anytype, label: []const u8, checked: bool, on_click: ?app.Action) !void {
    const enabled = theme.enabled(ui);
    const color = if (!enabled) theme.disabled_fill else if (ui.hovered(key)) theme.hovered(theme.primary) else theme.primary;
    try ui.open(key, .{
        .layout = .{ .padding = .all(4), .child_gap = 10, .child_alignment = .center_left },
        .on_click = live(ui, on_click),
    });
    defer ui.close();
    {
        try ui.open(null, .{
            .layout = .{ .sizing = .fixed(20), .child_alignment = .center },
            .background_color = if (checked) color else .transparent,
            .corner_radius = .uniform(3),
            .border = .{ .color = if (checked) color else theme.outline, .widths = .outside(2) },
        });
        defer ui.close();
        if (checked) try theme.icon(ui, .check, theme.contrast, 16);
    }
    try ui.text(label, theme.font(.body, if (enabled) theme.foreground else theme.disabled_text));
}

/// A sliding switch, then its label: `material.Switch`.
///
/// Gio's switch has no visible label, only a description for
/// accessibility; this one shows it, so it can be clicked by its text.
pub fn toggle(ui: *app.Ui, key: anytype, label: []const u8, on: bool, on_click: ?app.Action) !void {
    const enabled = theme.enabled(ui);
    const thumb: Color = if (!enabled) theme.disabled_fill else if (on) theme.primary else .rgb(245, 245, 245);
    const track: Color = if (!enabled) theme.disabled_fill.withAlpha(120) else if (on) theme.primary.withAlpha(128) else .rgb(158, 158, 158);
    try ui.open(key, .{
        .layout = .{ .padding = .all(4), .child_gap = 10, .child_alignment = .center_left },
        .on_click = live(ui, on_click),
    });
    defer ui.close();
    {
        try ui.open(null, .{ .layout = .{
            .sizing = .fixedXY(36, 20),
            .child_alignment = if (on) .center_right else .center_left,
        } });
        defer ui.close();
        // the track floats under the thumb, which is declared after it
        try ui.open(null, .{
            .layout = .{ .sizing = .fixedXY(36, 14) },
            .floating = .{ .mode = .parent, .unit_point = .center, .parent_point = .center },
            .background_color = track,
            .corner_radius = .uniform(7),
        });
        ui.close();
        try ui.open(null, .{
            .layout = .{ .sizing = .fixed(20) },
            .background_color = thumb,
            .corner_radius = .uniform(10),
            .border = .{ .color = if (on) .transparent else theme.outline.withAlpha(90), .widths = .outside(1) },
        });
        ui.close();
    }
    try ui.text(label, theme.font(.body, if (enabled) theme.foreground else theme.disabled_text));
}

/// A round mark, filled while `selected`, then its label:
/// `material.RadioButton`.
pub fn radio(ui: *app.Ui, key: anytype, label: []const u8, selected: bool, on_click: ?app.Action) !void {
    const enabled = theme.enabled(ui);
    const color = if (!enabled) theme.disabled_fill else if (selected or ui.hovered(key)) theme.primary else theme.outline;
    try ui.open(key, .{
        .layout = .{ .padding = .all(4), .child_gap = 10, .child_alignment = .center_left },
        .on_click = live(ui, on_click),
    });
    defer ui.close();
    {
        try ui.open(null, .{
            .layout = .{ .sizing = .fixed(20), .child_alignment = .center },
            .corner_radius = .uniform(10),
            .border = .{ .color = color, .widths = .outside(2) },
        });
        defer ui.close();
        if (selected) {
            try ui.open(null, .{ .layout = .{ .sizing = .fixed(10) }, .background_color = color, .corner_radius = .uniform(5) });
            ui.close();
        }
    }
    try ui.text(label, theme.font(.body, if (enabled) theme.foreground else theme.disabled_text));
}
