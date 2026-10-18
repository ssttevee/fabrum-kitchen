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
    for ([_][]const u8{ "page", "icon text", "click me", "green", "progress", "transform", "switch", "switched", "slider", "line", "uppercase", "notes", "fruit", "count", "size", "para", "query", "secret", "rating", "ask", "menu", "say hello" }) |key| {
        _ = try h.expectWidget(r.native(key));
    }
    // the notes are a native text area, and the label wraps within the page
    try testing.expect((try h.expectWidget(r.native("notes"))).spec == .text_area);
    const para = try h.expectWidget(r.native("para"));
    try testing.expect(para.frame.?.w <= window_size.x - 32);
    try testing.expect(para.frame.?.h >= 32);
    // the progress bar is native, at the model's 0.3
    try testing.expectEqual(@as(?f64, 0.3), (try h.expectWidget(r.native("progress"))).spec.progress.value);
    // the page is a scroll view filling the window, and fabrum laid out the
    // native views in its content, which is taller than the window
    const page = try h.expectWidget(r.native("page"));
    try testing.expectEqual(fabrum.Rect.init(0, 0, window_size.x, window_size.y), page.frame.?);
    try testing.expect(page.content_size.?.y > window_size.y);
    for (h.tree.all()) |w| if (w.frame) |frame| {
        if (w.handle == page.handle) continue;
        try testing.expectEqual(page.handle, w.parent.?);
        try testing.expect(frame.x >= 0 and frame.x + frame.w <= page.content_size.?.x);
        try testing.expect(frame.y >= 0 and frame.y + frame.h <= page.content_size.?.y);
    };
}

test "the page scrolls natively, and what scrolled into view is clicked where it is shown" {
    var h = try hybrid();
    defer h.deinit();
    try h.frame();
    const r = h.root();
    const page = r.native("page");
    const last = Hybrid.PickKey{ .pick = Hybrid.row_count - 1 };
    const before = (try h.expectWidget(r.native(last))).frame.?;
    try testing.expect(before.y > window_size.y);

    try h.scrollNative(page, .init(0, 1e6));
    const scrolled = (try h.expectWidget(page)).scroll;
    try testing.expectEqual((try h.expectWidget(page)).content_size.?.y - window_size.y, scrolled.y);
    // the last row's button is in the window now, and hasn't moved in the page
    try testing.expectEqual(before, (try h.expectWidget(r.native(last))).frame.?);
    const shown = h.findElement(r.element(last)).?.bbox;
    try testing.expect(shown.y >= 0 and shown.y + shown.h <= window_size.y);
    try h.clickNative(r.native(last));
    try testing.expectEqual(@as(?u8, Hybrid.row_count - 1), h.state().picked);
    // and a drawn row, clicked where it is shown
    try h.click("Row 20");
    try testing.expectEqual(@as(?u8, 20), h.state().selected);
    // drawn in the page's own canvas layer
    const scene = h.runtime.scene();
    try testing.expectEqual(@as(usize, 1), scene.containers.len);
    const layer = scene.layers[scene.containers[0].slots[0].canvas];
    try testing.expectEqual(fabrum.Vec2.init(0, -scrolled.y), layer.offset);
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
    // the host's canvas, and the page's, in its scroll view
    try testing.expectEqual(@as(usize, 2), h.runtime.scene().layers.len);

    try h.clickNative(h.root().native("line"));
    try h.typeText(h.root().native("line"), "typing");
    try h.expectFocused(h.root().element("line"));
    try h.click("Open dialog");
    // the modal dialog took focus from the field it covers
    try h.expectFocused(h.root().element("close dialog"));
    try h.tab();
    try h.expectFocused(h.root().element("close dialog"));
    const scene = h.runtime.scene();
    // a third, at the top of the host, over the page and the field in it
    try testing.expectEqual(@as(usize, 3), scene.layers.len);
    try testing.expectEqual(app.native.Scene.Slot{ .canvas = 2 }, scene.slots[scene.slots.len - 1]);
    const line = h.findElement(h.root().element("line")).?.bbox;
    try testing.expect(scene.layers[2].hits(.init(line.x + line.w / 2, line.y + line.h / 2)));

    try h.click("Close");
    try testing.expect(!h.state().dialog);
    try testing.expectEqual(@as(usize, 2), h.runtime.scene().layers.len);
}

test "the shell: a file chooser, the clipboard, and asking before quitting with unsent text" {
    var h = try hybrid();
    defer h.deinit();
    try h.frame();
    const r = h.root();

    try h.clickNative(r.native("open file"));
    try testing.expectEqualStrings("Choose an image", h.tree.file_requests.items[0].message);
    try h.chooseFile("/tmp/raspios.img");
    try h.expectText("Opened: /tmp/raspios.img; asked null; chose null");

    try h.typeText(r.native("line"), "News");
    try h.submit(r.native("line"));
    try h.clickNative(r.native("copy heading"));
    try testing.expectEqualStrings("News", h.tree.clipboard.?);
    try h.clickNative(r.native("paste notes"));
    try testing.expectEqualStrings("News", (try h.expectWidget(r.native("notes"))).value.text);

    // nothing unsent: closing goes ahead
    try testing.expect(try h.requestClose(.quit));
    // unsent text: the app asks, and Cancel keeps it
    try h.typeText(r.native("line"), "draft");
    try testing.expect(!try h.requestClose(.quit));
    try h.respond(r.native("closing"), 1);
    try testing.expectEqual(@as(usize, 0), h.tree.quits);
    try testing.expect(!try h.requestClose(.window));
    try h.respond(r.native("closing"), 0);
    try testing.expectEqual(@as(usize, 1), h.tree.quits);
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

test "the wider set is native too: the dropdown, stepper and radio group drive the model" {
    var h = try hybrid();
    defer h.deinit();
    try h.frame();
    const r = h.root();

    try h.expectText("Apple \u{00d7} 2, any size");
    try h.selectNative(r.native("fruit"), 2);
    try h.stepNative(r.native("count"), 3);
    try h.selectNative(r.native("size"), 1);
    try h.expectText("Cherry \u{00d7} 5, Medium");
    try testing.expectEqual(@as(?usize, 1), (try h.expectWidget(r.native("size"))).value.selection);

    try h.typeText(r.native("query"), "fabrum");
    try h.submit(r.native("query"));
    try h.typeText(r.native("secret"), "hunter2");
    try h.expectText("searched 1 times; 7 secret bytes");

    // the spinner shows while the switch is on
    try testing.expect(h.widget(r.native("busy")) == null);
    try h.clickNative(r.native("switch"));
    try testing.expect((try h.expectWidget(r.native("busy"))).spec == .spinner);
}

test "Ask and Menu use the platform's dialog and popup menu, from update" {
    var h = try hybrid();
    defer h.deinit();
    try h.frame();
    const r = h.root();

    try h.clickNative(r.native("ask"));
    try testing.expectEqual(@as(usize, 1), h.tree.dialogs.items.len);
    try testing.expectEqualStrings("Really?", h.tree.dialogs.items[0].title);
    try testing.expectEqual(@as(usize, 3), h.tree.dialogs.items[0].buttons.len);
    try h.answerDialog(2);
    try h.expectText("Opened: nothing; asked 2; chose null");

    try h.clickNative(r.native("menu"));
    const menu = h.tree.menus.items[0];
    try testing.expectEqual(@as(usize, 8), menu.items.len);
    try testing.expectEqual(app.platform.MenuItem.Kind.header, menu.items[0].kind);
    try testing.expect(!menu.find("Durian").?.enabled);
    try testing.expectEqual(@as(u8, 1), menu.find("Cherry").?.depth);
    // under the button
    const button = (try h.expectWidget(r.native("menu"))).frame.?;
    try testing.expectApproxEqAbs(button.y + button.h, menu.at.y, 0.01);
    try h.chooseMenuItem(4);
    try h.expectText("Opened: nothing; asked 2; chose 4");
    // dismissed: null
    try h.clickNative(r.native("menu"));
    try h.chooseMenuItem(null);
    try h.expectText("Opened: nothing; asked 2; chose null");
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

/// The drawn text widgets are components: their field is an element of
/// the instance declared with the widget's key.
fn drawnField(h: *HybridHarness, key: []const u8) fabrum.layout.Unit.Id {
    return h.root().child(app.drawn.TextBox, key).element("field");
}

test "a drawn line editor takes focus when clicked, and Tab goes on to the radio buttons" {
    var h = try drawnHybrid();
    defer h.deinit();
    try h.frame();
    const r = h.root();

    try h.clickElement(drawnField(&h, "line"));
    try h.expectFocused(drawnField(&h, "line"));
    try testing.expect(try h.pressKey(.tab, .{}));
    try h.expectFocused(r.element(Hybrid.Choice.r1));
    try testing.expect(try h.pressKey(.space, .{}));
    try testing.expectEqual(Hybrid.Choice.r1, h.state().choice.?);
}

test "the drawn line editor is controlled too: typing, Uppercase rewriting it, and Enter setting the heading" {
    var h = try drawnHybrid();
    defer h.deinit();
    try h.frame();
    const r = h.root();
    const line = drawnField(&h, "line");

    try h.clickElement(line);
    try h.type_("Hi there");
    try testing.expectEqualStrings("Hi there", h.state().line.items);
    try h.expectText("Hi there");
    // the model rewrites what was typed, and the field shows it
    try h.clickElement(r.element("uppercase"));
    try testing.expectEqualStrings("HI THERE", h.state().line.items);
    try h.expectText("HI THERE");
    try h.clickElement(line);
    try h.type_("!");
    try testing.expectEqualStrings("HI THERE!", h.state().line.items);
    // moves, a selection and the clipboard
    try h.press(.home, .{});
    try h.press(.right, .{ .shift = true });
    try h.press(.right, .{ .shift = true });
    try h.command(.copy);
    try testing.expectEqualStrings("HI", h.clipboard().?);
    try h.press(.end, .{});
    try h.press(.enter, .{});
    try h.expectText("HI THERE!");
    try testing.expectEqualStrings("", h.state().line.items);
    try h.expectText("Hint");
}

test "the drawn notes area wraps, scrolls inside, and takes a paste" {
    var h = try drawnHybrid();
    defer h.deinit();
    try h.frame();
    const notes = drawnField(&h, "notes");
    try h.clickElement(notes);
    for (0..16) |_| try h.type_("Anything at all, said the cook. ");
    try testing.expect(std.mem.startsWith(u8, h.state().notes.items, "Anything at all"));
    const info = h.scrollInfo(notes).?;
    try testing.expect(info.content.y > info.box.y);
    try testing.expect(info.offset.y > 0);
    try h.tree.setClipboard("Pasted");
    try h.command(.paste);
    try testing.expect(std.mem.endsWith(u8, h.state().notes.items, "Pasted"));
}

test "the drawn slider drags" {
    var h = try drawnHybrid();
    defer h.deinit();
    try h.frame();
    const slider = h.findElement(h.root().child(app.drawn.Slider, "slider").element("slider")).?.bbox;
    const y = slider.y + slider.h / 2;
    const at = struct {
        fn x(box: fabrum.Rect, fraction: f32) f32 {
            return box.x + 8 + (box.w - 16) * fraction;
        }
    }.x;
    try h.drag(.init(at(slider, 0.3), y), .init(at(slider, 0.6), y), 5);
    try h.expectText("0.60");
    try testing.expectApproxEqAbs(@as(f64, 0.6), h.state().progress, 0.01);
}

test "the drawn page scrolls, by the wheel and by its scrollbar, and what scrolled into view is clicked" {
    var h = try drawnHybrid();
    defer h.deinit();
    try h.frame();
    const r = h.root();
    const page = r.element("page");
    const info = h.scrollInfo(page).?;
    try testing.expect(info.content.y > window_size.y);
    const before = h.findElement(r.element(Hybrid.RowKey{ .row = 20 })).?.bbox;
    try testing.expect(before.y > window_size.y);

    try testing.expect(try h.scroll("Hello, fabrum", .init(0, 1e6)));
    try testing.expectEqual(info.content.y - window_size.y, h.scrollInfo(page).?.offset.y);
    const shown = h.findElement(r.element(Hybrid.RowKey{ .row = 20 })).?.bbox;
    try testing.expect(shown.y >= 0 and shown.y + shown.h <= window_size.y);
    try h.click("Row 20");
    try testing.expectEqual(@as(?u8, 20), h.state().selected);
    try h.clickElement(r.element(Hybrid.PickKey{ .pick = 20 }));
    try testing.expectEqual(@as(?u8, 20), h.state().picked);

    // the thumb, dragged back to the top
    const thumb = h.findElement(r.element(app.ui_internal.ThumbKey{ .container = page.id, .axis = .y })).?.bbox;
    try h.drag(.init(thumb.x + 2, thumb.y + 2), .init(thumb.x + 2, 0), 6);
    try testing.expectEqual(0, h.scrollInfo(page).?.offset.y);
}

test "the wider set is drawn without native widgets, and the dialog and menu are drawn too" {
    var h: HybridHarness = try .init(.{}, .{ .viewport = window_size, .widgets = .drawn, .services = .basic });
    defer h.deinit();
    try h.frame();
    const r = h.root();
    try testing.expectEqual(@as(usize, 0), h.tree.all().len);

    // the dropdown opens the runtime's drawn menu
    try h.click("Apple");
    try h.click("Cherry");
    try h.click("+");
    try h.click("Large");
    try h.expectText("Cherry \u{00d7} 3, Large");
    // the label wraps within the page
    const para = h.findElement(r.element("para")).?.bbox;
    try testing.expect(para.w <= window_size.x - 32);
    try testing.expect(para.h >= 30);
    // the secure field shows bullets
    try h.clickElement(drawnField(&h, "secret"));
    try h.type_("abc");
    try h.expectNoText("abc");
    try h.expectText("searched 0 times; 3 secret bytes");

    // Ask: the drawn dialog, answered by its button; Menu: the drawn
    // popup, with its submenu's items shown indented
    try h.click("Ask\u{2026}");
    try h.expectText("A question asked from update, in the platform's own dialog.");
    try h.click("Maybe");
    try h.expectText("Opened: nothing; asked 2; chose null");
    try h.click("Menu");
    try h.expectText("Durian");
    try h.click("Date");
    try h.expectText("Opened: nothing; asked 2; chose 5");
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
