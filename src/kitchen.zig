//! The Kitchen interface: fabrum.app components and widgets, after Gio's
//! Kitchen demo (gio-example, `kitchen/kitchen.go`).
//!
//! Nothing here touches the window or the renderer. The GUI in `main.zig`
//! provides `theme.Icons` as a root value; the tests below provide squares
//! instead and drive the interface through `fabrum.app.testing`, without a
//! window.
const std = @import("std");

const fabrum = @import("fabrum");
const app = fabrum.app;
const layout = fabrum.layout;

pub const theme = @import("kitchen/theme.zig");
pub const widgets = @import("kitchen/widgets.zig");
pub const Kitchen = @import("kitchen/Kitchen.zig");

/// The size of Gio's Kitchen window.
pub const window_size: fabrum.Vec2 = .init(800, 700);

const testing = std.testing;
const Harness = app.testing.Harness(.{}, Kitchen);

/// Icons as plain squares that fill their box.
const square_icons: theme.Icons = .{ .ctx = undefined, .make = struct {
    var square: layout.Content = .{ .vtable = &.{ .measure = measure } };

    fn make(_: *anyopaque, _: std.mem.Allocator, _: theme.Icon, _: fabrum.Color) std.mem.Allocator.Error!*layout.Content {
        return &square;
    }

    fn measure(_: *layout.Content, constraints: layout.Constraints) layout.Content.MeasureError!fabrum.Vec2 {
        const side = @min(constraints.max_width orelse 16, constraints.max_height orelse 16);
        return .init(side, side);
    }
}.make };

/// A harness for the Kitchen in Gio's window size. Run its first frame
/// once it is in place, since it must not move after that.
fn harness(props: Kitchen.Props) !Harness {
    return .init(props, .{ .viewport = window_size, .provide = &.{.of(&square_icons)} });
}

test "the first screen shows every widget fabrum can draw today" {
    var h = try harness(.{});
    defer h.deinit();
    try h.frame();

    for ([_][]const u8{
        "Hello, fabrum", "Icon",         "Click me!",    "Green",        "Flat",
        "Transform",     "Example Switch", "disabled",   "RadioButton1", "RadioButton2",
        "RadioButton3",
    }) |label| try h.expectText(label);
    // the spinner only shows while the switch is on
    try testing.expect(h.findElement(h.root().element("spinner")) == null);
    try testing.expect(h.findElement(h.root().element("progress circle")) != null);
}

test "everything fits the window without scrolling" {
    var h = try harness(.{});
    defer h.deinit();
    try h.frame();

    var it = h.texts();
    while (it.next()) |found| {
        const box = found.unit.bbox;
        try testing.expect(box.x >= 0 and box.x + box.w <= window_size.x);
        try testing.expect(box.y >= 0 and box.y + box.h <= window_size.y);
    }
}

test "Click me! flips the second button between green and blue" {
    var h = try harness(.{});
    defer h.deinit();
    try h.frame();

    try h.click("Click me!");
    try h.expectText("Blue");
    try h.expectNoText("Green");
    try h.click("Click me!");
    try h.expectText("Green");
}

test "the second button only presses" {
    var h = try harness(.{});
    defer h.deinit();
    try h.frame();

    try h.click("Green");
    try h.expectText("Green");
}

test "the checkbox toggles Transform" {
    var h = try harness(.{});
    defer h.deinit();
    try h.frame();

    try h.click("Transform");
    try testing.expect(h.state().transform);
    try h.click("Transform");
    try testing.expect(!h.state().transform);
}

test "the switch enables the button next to it and shows the spinner" {
    var h = try harness(.{});
    defer h.deinit();
    try h.frame();

    // disabled: no action, so no pointing hand
    try h.hover("disabled");
    try testing.expectEqual(app.Cursor.default, h.runtime.cursor());

    try h.click("Example Switch");
    try testing.expect(h.state().switched);
    try h.expectText("enabled");
    try h.expectNoText("disabled");
    try testing.expect(h.findElement(h.root().element("spinner")) != null);

    try h.hover("enabled");
    try testing.expectEqual(app.Cursor.pointer, h.runtime.cursor());
}

test "radio buttons choose one of three" {
    var h = try harness(.{});
    defer h.deinit();
    try h.frame();

    try testing.expectEqual(null, h.state().choice);
    try h.click("RadioButton2");
    try testing.expectEqual(Kitchen.Choice.r2, h.state().choice.?);
    try h.click("RadioButton3");
    try testing.expectEqual(Kitchen.Choice.r3, h.state().choice.?);
}

test "disabling the page disables every widget" {
    var h = try harness(.{ .disabled = true });
    defer h.deinit();
    try h.frame();

    try h.click("Click me!");
    try h.click("Transform");
    try h.click("Example Switch");
    try h.click("RadioButton1");
    try h.expectText("Green");
    try testing.expect(!h.state().transform);
    try testing.expect(!h.state().switched);
    try testing.expectEqual(null, h.state().choice);
    try h.hover("Flat");
    try testing.expectEqual(app.Cursor.default, h.runtime.cursor());
}
