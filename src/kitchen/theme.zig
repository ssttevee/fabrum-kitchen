//! The Kitchen's look, after Gio's material theme: colors, type, icons and
//! the disabled state, as contexts and plain values.
const std = @import("std");
const Allocator = std.mem.Allocator;

const fabrum = @import("fabrum");
const app = fabrum.app;
const layout = fabrum.layout;
const Color = fabrum.Color;

pub const background = Color.white;
pub const foreground = Color.black;
/// Material indigo, Gio's default `ContrastBg`.
pub const primary = Color.rgb(63, 81, 181);
pub const contrast = Color.white;
pub const green = Color.rgb(158, 157, 36);
pub const outline = Color.rgb(117, 117, 117);
pub const disabled_fill = Color.rgb(189, 189, 189);
pub const disabled_text = Color.rgb(140, 140, 140);

pub const Text = enum { h3, body };

/// A text style for one of the type sizes.
pub fn font(kind: Text, color: Color) layout.text.Style {
    const size: f32 = switch (kind) {
        .h3 => 48,
        .body => 16,
    };
    return .{ .font_size = size, .color = color, .wrap_mode = .none };
}

/// `color` lightened, as for an element under the pointer.
pub fn hovered(color: Color) Color {
    return mix(color, .white, 0.15);
}

/// `color` darkened, as for an element held down.
pub fn pressed(color: Color) Color {
    return mix(color, .black, 0.12);
}

fn mix(a: Color, b: Color, t: f32) Color {
    const channel = struct {
        fn of(x: u8, y: u8, f: f32) u8 {
            return @intFromFloat(@round(@as(f32, @floatFromInt(x)) * (1 - f) + @as(f32, @floatFromInt(y)) * f));
        }
    }.of;
    return .rgba(channel(a.r, b.r, t), channel(a.g, b.g, t), channel(a.b, b.b, t), a.a);
}

/// Provided over a subtree to disable every widget in it, as Gio's
/// `gtx.Disabled()` does: widgets draw greyed out and drop their actions.
pub const Disabled = struct {
    /// A value to provide, which lives as long as the program.
    pub const on: Disabled = .{};
};

/// Whether widgets at this point of the view are enabled.
pub fn enabled(ui: *const app.Ui) bool {
    return ui.tryUse(Disabled) == null;
}

pub const Icon = enum { add, check };

/// Makes icon content for views, which the renderer draws. Provided as a
/// root value; content is allocated in the frame arena.
pub const Icons = struct {
    ctx: *anyopaque,
    make: *const fn (ctx: *anyopaque, arena: Allocator, icon: Icon, color: Color) Allocator.Error!*layout.Content,

    pub fn content(self: Icons, arena: Allocator, which: Icon, color: Color) Allocator.Error!*layout.Content {
        return self.make(self.ctx, arena, which, color);
    }
};

/// A square box of `size` showing `icon` in `color`, from the provided
/// `Icons`.
pub fn icon(ui: *app.Ui, which: Icon, color: Color, size: f32) !void {
    try ui.open(null, .{ .layout = .{ .sizing = .fixed(size), .child_alignment = .center } });
    defer ui.close();
    ui.content(try ui.use(Icons).content(ui.arena(), which, color));
}
