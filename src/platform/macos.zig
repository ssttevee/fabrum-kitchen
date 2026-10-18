//! The macOS platform: an AppKit window that draws through a `Host` and
//! feeds it the mouse, plus the cursor, frame requests and debug hooks.
//!
//! TEMPORARY: moves to fabrum as `fabrum.app.platform.macos` in Phase B;
//! see `../platform.zig`. The only line that changes is the `app` import.
//!
//! It knows nothing about the app or the renderer: the host is handed a
//! Core Graphics context to draw into, as an opaque pointer, and casts it
//! to whatever its renderer takes.
const std = @import("std");

// In fabrum: `const app = @import("../../app.zig");`
const app = @import("fabrum").app;

/// A Core Graphics context (`CGContextRef`). Renderers that draw with Core
/// Graphics take it by casting, as in `@as(*Quartz.CGContext, @ptrCast(cg))`.
pub const CGContext = opaque {};

pub const Options = struct {
    title: [:0]const u8,
    width: f64 = 800,
    height: f64 = 600,
    min_width: f64 = 320,
    min_height: f64 = 240,
    /// A dark window frame, for apps with a dark interface.
    dark: bool = false,
};

/// What the shell calls back into. Every call is on the main thread.
pub const Host = extern struct {
    ctx: *anyopaque,
    /// Draws a frame of `width` by `height` points into `cg`, whose origin
    /// is the bottom left.
    draw: *const fn (ctx: *anyopaque, cg: *CGContext, width: f64, height: f64) callconv(.c) void,
    /// The pointer, from the top left of the window's content in points.
    /// Bit 0 of `buttons` is the primary button.
    mouse: *const fn (ctx: *anyopaque, x: f64, y: f64, buttons: c_uint, scroll_x: f64, scroll_y: f64) callconv(.c) void,
    /// Called once before the process exits.
    will_terminate: *const fn (ctx: *anyopaque) callconv(.c) void,
};

const COptions = extern struct {
    title: [*:0]const u8,
    width: f64,
    height: f64,
    min_width: f64,
    min_height: f64,
    dark: c_int,
};

extern fn fabrum_shell_run(options: COptions, host: Host) callconv(.c) noreturn;
extern fn fabrum_shell_request_frame() callconv(.c) void;
extern fn fabrum_shell_set_cursor(cursor: c_int) callconv(.c) void;
extern fn fabrum_shell_quit() callconv(.c) void;
extern fn fabrum_shell_snapshot(path: [*:0]const u8, scale: f64) callconv(.c) bool;
extern fn fabrum_shell_synthesize_click(x: f64, y: f64) callconv(.c) void;
extern fn fabrum_shell_run_on_main(callback: *const fn (ctx: ?*anyopaque) callconv(.c) void, ctx: ?*anyopaque) callconv(.c) void;

/// Opens the window and runs the app until it quits.
pub fn run(options: Options, host: Host) noreturn {
    fabrum_shell_run(.{
        .title = options.title,
        .width = options.width,
        .height = options.height,
        .min_width = options.min_width,
        .min_height = options.min_height,
        .dark = @intFromBool(options.dark),
    }, host);
}

/// The `fabrum.app.Platform` of this shell: frames are requested by marking
/// the view as needing display on the main thread.
pub const platform: app.Platform = .{ .ptr = undefined, .vtable = &.{ .requestFrame = requestFrame } };

fn requestFrame(_: *anyopaque) void {
    fabrum_shell_request_frame();
}

/// Asks for a frame from any thread.
pub fn requestRedraw() void {
    fabrum_shell_request_frame();
}

pub fn setCursor(cursor: app.Cursor) void {
    fabrum_shell_set_cursor(switch (cursor) {
        .default => 0,
        .pointer => 1,
    });
}

/// Runs `callback(ctx)` on the main thread after the current event, from
/// any thread.
pub fn runOnMain(callback: *const fn (ctx: ?*anyopaque) callconv(.c) void, ctx: ?*anyopaque) void {
    fabrum_shell_run_on_main(callback, ctx);
}

/// Quits as the Quit menu item does. Main thread only.
pub fn quit() void {
    fabrum_shell_quit();
}

/// Clicks at `x`, `y` (points from the top left of the content) by sending
/// AppKit mouse events through the window, as a user's click would arrive.
/// Nothing reaches the system's event stream and the real pointer doesn't
/// move. For tests. Main thread only.
pub fn synthesizeClick(x: f64, y: f64) void {
    fabrum_shell_synthesize_click(x, y);
}

/// Draws the window's content and saves it as a PNG at `path`, at `scale`
/// pixels per point, or at the screen's scale if null. Draws the view
/// itself rather than reading the screen, so it works while the screen is
/// locked. Main thread only.
pub fn snapshot(path: [:0]const u8, scale: ?f64) error{SnapshotFailed}!void {
    if (!fabrum_shell_snapshot(path, scale orelse 0)) return error.SnapshotFailed;
}
