//! The Kitchen interface: fabrum.app components and widgets, after Gio's
//! Kitchen demo (gio-example, `kitchen/kitchen.go`), in two versions of its
//! first screen:
//!
//! - `Hybrid`: the platform's own controls laid out by fabrum, with drawn
//!   content between and over them;
//! - `Kitchen`: everything drawn by fabrum.
//!
//! Nothing here touches the window or the renderer. The GUI in `main.zig`
//! provides `theme.Icons` as a root value; the tests below provide squares
//! instead and drive the interface through `fabrum.app.testing`, without a
//! window, against the headless platform's native widgets.
const std = @import("std");

const fabrum = @import("fabrum");
const app = fabrum.app;
const layout = fabrum.layout;

pub const theme = @import("kitchen/theme.zig");
pub const widgets = @import("kitchen/widgets.zig");
pub const Kitchen = @import("kitchen/Kitchen.zig");
pub const Hybrid = @import("kitchen/Hybrid.zig");

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
        "Hello, fabrum", "Icon",           "Click me!", "Green",        "Flat",
        "Transform",     "Example Switch", "disabled",  "RadioButton1", "RadioButton2",
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

// The hybrid screen

const HybridHarness = app.testing.Harness(.{}, Hybrid);

/// The hybrid screen with native widgets, in the fake native tree, however
/// fabrum is built.
fn hybrid() !HybridHarness {
    return .init(.{}, .{ .viewport = window_size, .widgets = .native });
}

/// The hybrid screen with its widgets drawn, as on the `none` platform.
fn drawnHybrid() !HybridHarness {
    return .init(.{}, .{ .viewport = window_size, .widgets = .drawn });
}

test "the hybrid screen shows native controls around drawn content" {
    var h = try hybrid();
    defer h.deinit();
    try h.frame();
    const r = h.root();

    try h.expectText("Hello, fabrum");
    try h.expectText("RadioButton1");
    for ([_][]const u8{ "icon text", "click me", "green", "progress", "transform", "switch", "switched", "slider", "line", "uppercase", "notes", "rating", "say hello" }) |key| {
        _ = try h.expectWidget(r.native(key));
    }
    // the progress bar is native, at the model's 0.3
    try testing.expectEqual(@as(?f64, 0.3), (try h.expectWidget(r.native("progress"))).spec.progress.value);
    // fabrum laid out the native views inside the window
    for (h.tree.all()) |w| if (w.frame) |frame| {
        try testing.expect(frame.x >= 0 and frame.x + frame.w <= window_size.x);
        try testing.expect(frame.y >= 0 and frame.y + frame.h <= window_size.y);
    };
}

test "native buttons, checkboxes, switches and sliders drive the model" {
    var h = try hybrid();
    defer h.deinit();
    try h.frame();
    const r = h.root();

    try h.clickNative(r.native("click me"));
    try testing.expectEqualStrings("Blue", (try h.expectWidget(r.native("green"))).spec.button.title);
    try testing.expect(!(try h.expectWidget(r.native("switched"))).spec.button.enabled);
    try h.clickNative(r.native("switch"));
    try testing.expect(h.state().switched);
    try testing.expect((try h.expectWidget(r.native("switched"))).spec.button.enabled);
    try h.clickNative(r.native("transform"));
    try testing.expect(h.state().transform);

    try h.slide(r.native("slider"), 0.75);
    try h.expectText("0.75");
    try testing.expectEqual(@as(?f64, 0.75), (try h.expectWidget(r.native("progress"))).spec.progress.value);
}

test "the line editor is controlled: Enter moves its text to the heading" {
    var h = try hybrid();
    defer h.deinit();
    try h.frame();
    const line = h.root().native("line");

    try h.typeText(line, "Hi there");
    try testing.expectEqualStrings("Hi there", h.state().line.items);
    try testing.expectEqual(@as(usize, 0), (try h.expectWidget(line)).writes);

    try h.submit(line);
    try h.expectText("Hi there");
    // the model cleared the field, which fabrum wrote into it
    try testing.expectEqualStrings("", (try h.expectWidget(line)).value.text);
    try testing.expectEqual(@as(usize, 1), (try h.expectWidget(line)).writes);
}

test "with Uppercase on, the model rewrites what is typed, and composing is left alone" {
    var h = try hybrid();
    defer h.deinit();
    try h.frame();
    const r = h.root();
    const line = r.native("line");

    try h.typeText(line, "ab");
    try h.clickNative(r.native("uppercase"));
    // turning it on changed the model, so the field was rewritten
    try testing.expectEqualStrings("AB", (try h.expectWidget(line)).value.text);
    try h.typeText(line, "c");
    try testing.expectEqualStrings("ABC", (try h.expectWidget(line)).value.text);

    // a composition isn't the model's, and isn't overwritten
    try h.compose(line, "ã");
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("ABCã", (try h.expectWidget(line)).text(&buffer));
    try h.commit(line, "é");
    try testing.expectEqualStrings("ABCé", h.state().line.items);
}

test "Tab goes from the native line editor through the drawn strip to the notes" {
    var h = try hybrid();
    defer h.deinit();
    try h.frame();
    const r = h.root();

    try h.tab();
    try h.expectFocused(r.element("line"));
    for ([_]Hybrid.Choice{ .r1, .r2, .r3 }) |choice| {
        try h.tab();
        try h.expectFocused(r.element(choice));
    }
    try h.tab();
    try h.expectFocused(r.element("open dialog"));
    try h.tab();
    try h.expectFocused(r.element("notes"));
    try h.shiftTab();
    try h.shiftTab();
    try h.pressSpace();
    try testing.expectEqual(Hybrid.Choice.r3, h.state().choice.?);
}

test "the drawn dialog is a canvas layer above the native line editor" {
    var h = try hybrid();
    defer h.deinit();
    try h.frame();
    try testing.expectEqual(@as(usize, 1), h.runtime.scene().layers.len);

    try h.clickNative(h.root().native("line"));
    try h.typeText(h.root().native("line"), "typing");
    try h.expectFocused(h.root().element("line"));
    try h.click("Open dialog");
    // the modal dialog took focus from the field it covers
    try h.expectFocused(h.root().element("close dialog"));
    try h.tab();
    try h.expectFocused(h.root().element("close dialog"));
    const scene = h.runtime.scene();
    try testing.expectEqual(@as(usize, 2), scene.layers.len);
    try testing.expectEqual(app.native.Scene.Slot{ .canvas = 1 }, scene.slots[scene.slots.len - 1]);
    const line = (try h.expectWidget(h.root().native("line"))).frame.?;
    try testing.expect(scene.layers[1].hits(.init(line.x + line.w / 2, line.y + line.h / 2)));

    try h.click("Close");
    try testing.expect(!h.state().dialog);
    try testing.expectEqual(@as(usize, 1), h.runtime.scene().layers.len);
}

test "Say Hello shows a native alert whose answer comes back as a message" {
    var h = try hybrid();
    defer h.deinit();
    try h.frame();
    const r = h.root();

    try h.selectMenu(r.native("say hello"));
    const alert = try h.expectWidget(r.native("hello"));
    try testing.expectEqualStrings("Hello from fabrum", alert.spec.alert.title);
    try h.respond(r.native("hello"), 1);
    try testing.expectEqual(@as(?usize, 1), h.state().answer);
    try testing.expect(h.widget(r.native("hello")) == null);
    try h.expectText("3 of 5; greeted 1 times, last answer 1");
}

// The hybrid screen with drawn widgets, as the `none` platform shows it

test "without native controls, the hybrid screen draws them, and they drive the model" {
    var h = try drawnHybrid();
    defer h.deinit();
    try h.frame();
    const r = h.root();
    // nothing native, not even the menu
    try testing.expectEqual(@as(usize, 0), h.tree.all().len);
    try h.expectText("Click me!");

    try h.click("Click me!");
    try h.expectText("Blue");
    try h.clickElement(r.element("transform"));
    try testing.expect(h.state().transform);
    try h.clickElement(r.element("switch"));
    try testing.expect(h.state().switched);
    try h.expectText("enabled");

    // the slider jumps to where it is clicked, and the progress bar follows
    const slider = h.findElement(r.child(app.drawn.Slider, "slider").element("slider")).?.bbox;
    try h.clickAt(.init(slider.x + 8 + (slider.w - 16) * 0.75, slider.y + slider.h / 2));
    try h.expectText("0.75");
    try testing.expectApproxEqAbs(@as(f64, 0.75), h.state().progress, 0.001);
}

test "a drawn line editor takes focus when clicked, and Tab goes on to the radio buttons" {
    var h = try drawnHybrid();
    defer h.deinit();
    try h.frame();
    const r = h.root();

    try h.clickElement(r.element("line"));
    try h.expectFocused(r.element("line"));
    try testing.expect(try h.pressKey(.tab, .{}));
    try h.expectFocused(r.element(Hybrid.Choice.r1));
    try testing.expect(try h.pressKey(.space, .{}));
    try testing.expectEqual(Hybrid.Choice.r1, h.state().choice.?);
}

test "an overlay without the page lets clicks between widgets through" {
    var h: HybridHarness = try .init(.{ .page = false }, .{ .viewport = window_size, .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    // right of the heading: nothing of the app's
    const heading = h.findText("Hello, fabrum").?.bbox;
    try testing.expect(!try h.mouse(.{ .position = .init(window_size.x - 10, heading.y + heading.h / 2) }));
    try testing.expect(try h.mouse(.{ .position = app.testing.center(h.findText("Click me!").?) }));
}
