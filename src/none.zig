//! The Kitchen on fabrum's `none` platform: no window and no toolkit. This
//! program is the host, as a VNC proxy or a game overlay would be. It
//! drives the runtime through the host contract (`fabrum.app.platform.none`):
//!
//! - it plays a script of pointer moves, clicks and keys, as a VNC client
//!   would send them, and says which the app took and which it let through
//!   to what is under it;
//! - it runs frames on its own clock, and takes the changed regions;
//! - it redraws only those regions of the overlay, premultiplied RGBA, with
//!   a portable renderer;
//! - it composites only those regions of the overlay over a background
//!   image, as a proxy would over the remote screen, or an overlay over a
//!   game's frame.
//!
//! Every step it also redraws and composites everything from scratch and
//! checks the results are the same, which checks the damage end to end.
//!
//! It writes PNGs of some steps to `/tmp/kitchen-snapshots/none/` (or
//! `--out DIR`): the composited frame, the overlay alone, and the frame
//! with the damage outlined. `--bench` times full and partial redraws.
//!
//! It links no OS UI library, so it cross-compiles:
//! `zig build -Dtarget=x86_64-linux-musl` or `-Dtarget=x86_64-windows-gnu`.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const fabrum = @import("fabrum");
const app = fabrum.app;
const layout = fabrum.layout;
const Vec2 = fabrum.Vec2;
const Rect = fabrum.Rect;
const Renderer = @import("renderer");
/// Which renderer the build chose: `-Drenderer`.
const renderer_name = @import("kitchen_options").renderer;

const kitchen = @import("kitchen.zig");
const Hybrid = kitchen.Hybrid;
const png = @import("png.zig");

const Runtime = app.Runtime(.{ .Text = Renderer.Text });

const width: u32 = @intFromFloat(kitchen.window_size.x);
const height: u32 = @intFromFloat(kitchen.window_size.y);
const viewport = kitchen.window_size;

/// The look of the drawn widgets: macOS's light colors, translucent where
/// the page would be, though the overlay leaves the page out.
const theme: app.native.Theme = .{ .window_background = .rgba(236, 236, 236, 200) };

/// What happens at one step of the script.
const Step = struct {
    name: []const u8,
    action: Action,
    /// Whether to write PNGs of the step.
    snapshot: bool = false,

    const Action = union(enum) {
        /// Nothing: the first frame.
        start,
        /// The pointer moves to an element, with no button held.
        hover: Target,
        /// A click on an element: press and release.
        click: Target,
        /// A key press and release.
        key: app.KeyEvent.Key,
    };

    /// Where the pointer goes: an element of the screen, found in the last
    /// frame's layout as a VNC client would see it on screen.
    const Target = union(enum) {
        /// The middle of the text.
        text: []const u8,
        /// The middle of the element with this key.
        element: []const u8,
        /// A fraction of the way along the drawn slider.
        slider: f32,
        /// A point of the viewport.
        point: Vec2,
    };
};

const script = [_]Step{
    .{ .name = "initial", .action = .start, .snapshot = true },
    .{ .name = "hover-green", .action = .{ .hover = .{ .element = "green" } } },
    .{ .name = "click-me", .action = .{ .click = .{ .text = "Click me!" } }, .snapshot = true },
    .{ .name = "checkbox", .action = .{ .click = .{ .element = "transform" } } },
    .{ .name = "switch", .action = .{ .click = .{ .element = "switch" } }, .snapshot = true },
    .{ .name = "slider", .action = .{ .click = .{ .slider = 0.75 } }, .snapshot = true },
    .{ .name = "focus-line", .action = .{ .click = .{ .element = "line" } }, .snapshot = true },
    .{ .name = "tab", .action = .{ .key = .tab } },
    .{ .name = "space", .action = .{ .key = .space }, .snapshot = true },
    .{ .name = "click-through", .action = .{ .click = .{ .point = .init(780, 30) } } },
    .{ .name = "open-dialog", .action = .{ .click = .{ .text = "Open dialog" } }, .snapshot = true },
    .{ .name = "close-dialog", .action = .{ .click = .{ .text = "Close" } }, .snapshot = true },
};

const Options = struct {
    out: []const u8 = "/tmp/kitchen-snapshots/none",
    bench: bool = false,
    quiet: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var options: Options = .{};
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--out") and i + 1 < args.len) {
            i += 1;
            options.out = args[i];
        } else if (std.mem.eql(u8, arg, "--bench")) {
            options.bench = true;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            options.quiet = true;
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return error.InvalidArgument;
        }
    }

    var host: Host = undefined;
    try host.init(gpa, io);
    defer host.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout.interface;
    try out.print("kitchen-none: {s} renderer, {d}x{d}, writing to {s}\n", .{ renderer_name, width, height, options.out });
    try Io.Dir.cwd().createDirPath(io, options.out);

    try out.print("{s:<16} {s:>5} {s:>7} {s:>9} {s:>8} {s:>9} {s:>9}  {s}\n", .{ "step", "taken", "regions", "pixels", "frame", "render", "composite", "next frame" });
    for (script, 0..) |step, n| {
        const report = try host.play(step);
        try out.print("{s:<16} {s:>5} {d:>7} {d:>9} {d:>6}us {d:>7}us {d:>7}us  {s}\n", .{
            step.name,
            if (report.taken) |t| (if (t) "yes" else "no") else "-",
            report.regions,
            report.pixels,
            report.frame_us,
            report.render_us,
            report.composite_us,
            if (report.next_frame) |_| "now" else "when input comes",
        });
        try host.check();
        if (step.snapshot) try host.snapshot(options.out, n + 1, step.name);
    }
    try out.print("every step: the redrawn damage matched a full redraw\n", .{});

    if (options.bench) try host.bench(out);
    try out.flush();
}

/// What the host keeps: the runtime, the renderer, and its buffers.
const Host = struct {
    gpa: Allocator,
    io: Io,
    renderer: Renderer,
    runtime: Runtime,
    /// The time frames run at: a fake clock, a frame apart per step, so
    /// snapshots are the same every run.
    now: Io.Timestamp = .zero,
    /// The overlay, premultiplied RGBA, redrawn where damaged.
    overlay: []align(4) u8,
    /// The background: a stand-in for the remote screen or the game.
    background: []u8,
    /// The overlay composited over the background, where damaged.
    composited: []u8,
    /// The same, redrawn and composited whole, to check against.
    full_overlay: []align(4) u8,
    full_composited: []u8,
    /// The last step's regions, for outlining.
    damage: std.ArrayList(Rect) = .empty,

    fn init(self: *Host, gpa: Allocator, io: Io) !void {
        self.* = .{
            .gpa = gpa,
            .io = io,
            .renderer = try .init(gpa),
            .runtime = undefined,
            .overlay = try gpa.alignedAlloc(u8, .@"4", pixel_count * 4),
            .background = try gpa.alloc(u8, pixel_count * 4),
            .composited = try gpa.alloc(u8, pixel_count * 4),
            .full_overlay = try gpa.alignedAlloc(u8, .@"4", pixel_count * 4),
            .full_composited = try gpa.alloc(u8, pixel_count * 4),
        };
        try self.renderer.loadFont("Go", @embedFile("fonts/Go-Regular.ttf"));
        self.runtime = try .init(gpa, .{ .io = io, .text_context = self.renderer.text_context, .theme = theme });
        paintBackground(self.background);
    }

    fn deinit(self: *Host) void {
        self.runtime.deinit();
        self.renderer.deinit();
        self.damage.deinit(self.gpa);
        self.gpa.free(self.overlay);
        self.gpa.free(self.background);
        self.gpa.free(self.composited);
        self.gpa.free(self.full_overlay);
        self.gpa.free(self.full_composited);
    }

    fn pixels(buffer: []align(4) u8) layout.Surface.Pixels {
        return .packed_(buffer, width, height, .rgba8_premultiplied);
    }

    const Report = struct {
        taken: ?bool = null,
        regions: usize = 0,
        pixels: usize = 0,
        frame_us: u64 = 0,
        render_us: u64 = 0,
        composite_us: u64 = 0,
        next_frame: ?Io.Timestamp = null,
    };

    /// Plays one step as a host does: input in, a frame, the damage, then
    /// drawing and compositing just that.
    fn play(self: *Host, step: Step) !Report {
        var report: Report = .{};
        switch (step.action) {
            .start => {},
            .hover => |target| report.taken = try self.runtime.mouse(.{ .position = try self.locate(target) }),
            .click => |target| {
                const point = try self.locate(target);
                var down: app.MouseEvent.Buttons = .empty;
                down.set(app.MouseEvent.primary);
                const pressed = try self.runtime.mouse(.{ .position = point, .pressed = down });
                const released = try self.runtime.mouse(.{ .position = point });
                report.taken = pressed or released;
            },
            .key => |key| {
                report.taken = try self.runtime.key(.{ .key = key });
                _ = try self.runtime.key(.{ .key = key, .phase = .release });
            },
        }

        // frames while one is due now (a modal dialog taking focus asks for
        // a second); the host's clock moves on a frame each
        var frames: usize = 0;
        while (self.runtime.nextFrame()) |due| {
            if (due.nanoseconds > self.now.nanoseconds or frames == 4) break;
            var timer = Timer.start(self.io);
            _ = try self.runtime.frame(Hybrid, .{ .page = false }, viewport, self.now);
            report.frame_us += timer.lap();
            frames += 1;
            self.now = self.now.addDuration(.fromMilliseconds(16));
        }
        if (frames > 0) {
            var timer = Timer.start(self.io);
            // what changed over those frames, since the last step drew
            const regions = try self.runtime.damage();
            self.damage.clearRetainingCapacity();
            try self.damage.appendSlice(self.gpa, regions);
            report.regions = regions.len;
            for (regions) |r| report.pixels += @intFromFloat(r.w * r.h);

            if (regions.len > 0) {
                try layout.draw(&self.renderer, self.runtime.commands(), .pixels, pixels(self.overlay), regions);
                report.render_us = timer.lap();
                for (regions) |r| composite(self.composited, self.overlay, self.background, r);
                report.composite_us = timer.lap();
            }
        }
        report.next_frame = self.runtime.nextFrame();
        return report;
    }

    /// Redraws and composites everything, and fails unless that is what
    /// redrawing only the damage gave.
    fn check(self: *Host) !void {
        try layout.draw(&self.renderer, self.runtime.commands(), .pixels, pixels(self.full_overlay), null);
        composite(self.full_composited, self.full_overlay, self.background, .init(0, 0, viewport.x, viewport.y));
        if (!std.mem.eql(u8, self.overlay, self.full_overlay) or !std.mem.eql(u8, self.composited, self.full_composited)) {
            std.log.err("redrawing the damage gave different pixels from redrawing everything", .{});
            return error.DamageMissed;
        }
    }

    /// Where `target` is in the last frame.
    fn locate(self: *Host, target: Step.Target) !Vec2 {
        const ctx = self.runtime.context();
        const root = app.testing.rootInstance(Hybrid);
        return switch (target) {
            .point => |p| p,
            .text => |t| app.testing.center(app.testing.findText(Runtime.Text, ctx, t) orelse return error.NoSuchText),
            .element => |key| app.testing.center(ctx.getUnitById(root.element(key)) orelse return error.NoSuchElement),
            .slider => |fraction| blk: {
                const box = (ctx.getUnitById(root.child(app.drawn.Slider, "slider").element("slider")) orelse return error.NoSuchElement).bbox;
                break :blk .init(box.x + 8 + (box.w - 16) * fraction, box.y + box.h / 2);
            },
        };
    }

    /// Writes the step's composited frame, overlay and damage as PNGs.
    fn snapshot(self: *Host, dir: []const u8, number: usize, name: []const u8) !void {
        const straight = try self.gpa.alloc(u8, pixel_count * 4);
        defer self.gpa.free(straight);

        unpremultiply(straight, self.overlay);
        try self.write(dir, number, name, "-overlay", straight);
        try self.write(dir, number, name, "", self.composited);

        @memcpy(straight, self.composited);
        for (self.damage.items) |r| outline(straight, r);
        try self.write(dir, number, name, "-damage", straight);
    }

    fn write(self: *Host, dir: []const u8, number: usize, name: []const u8, suffix: []const u8, rgba: []const u8) !void {
        var path_buffer: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/{d:0>2}-{s}{s}.png", .{ dir, number, name, suffix });
        const encoded = try png.encode(self.gpa, rgba, width, height, width * 4);
        defer self.gpa.free(encoded);
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = encoded });
    }

    /// Times full redraws, and redraws of the damage a hover makes.
    fn bench(self: *Host, out: *Io.Writer) !void {
        const rounds = 50;
        var full: [rounds]u64 = undefined;
        for (&full) |*t| {
            var timer = Timer.start(self.io);
            try layout.draw(&self.renderer, self.runtime.commands(), .pixels, pixels(self.full_overlay), null);
            t.* = timer.lap();
        }

        // hovering on and off a button, each a frame with its damage
        const button = try self.locate(.{ .element = "green" });
        var partial: [rounds]u64 = undefined;
        var area: usize = 0;
        for (&partial, 0..) |*t, n| {
            _ = try self.runtime.mouse(.{ .position = if (n % 2 == 0) button else .init(780, 30) });
            _ = try self.runtime.frame(Hybrid, .{ .page = false }, viewport, self.now);
            const regions = try self.runtime.damage();
            area = 0;
            for (regions) |r| area += @intFromFloat(r.w * r.h);
            var timer = Timer.start(self.io);
            try layout.draw(&self.renderer, self.runtime.commands(), .pixels, pixels(self.overlay), regions);
            t.* = timer.lap();
        }

        var frame_times: [rounds]u64 = undefined;
        for (&frame_times) |*t| {
            var timer = Timer.start(self.io);
            _ = try self.runtime.frame(Hybrid, .{ .page = false }, viewport, self.now);
            t.* = timer.lap();
        }

        try out.print("\nbench ({s}, median of {d}):\n", .{ renderer_name, rounds });
        try out.print("  layout and views, one frame:      {d:>7}us\n", .{median(&frame_times)});
        try out.print("  render the whole {d}x{d} overlay: {d:>7}us\n", .{ width, height, median(&full) });
        try out.print("  render a hover's damage ({d} px):  {d:>7}us\n", .{ area, median(&partial) });
    }
};

fn median(times: []u64) u64 {
    std.mem.sort(u64, times, {}, std.sort.asc(u64));
    return times[times.len / 2];
}

const Timer = struct {
    io: Io,
    last: Io.Timestamp,

    fn start(io: Io) Timer {
        return .{ .io = io, .last = Io.Clock.awake.now(io) };
    }

    /// Microseconds since the start or the last lap.
    fn lap(self: *Timer) u64 {
        const now = Io.Clock.awake.now(self.io);
        defer self.last = now;
        return @intCast(@max(self.last.durationTo(now).toMicroseconds(), 0));
    }
};

/// A stand-in for a remote screen or a game: soft diagonal bands of color,
/// and a grid, opaque.
fn paintBackground(rgba: []u8) void {
    for (0..height) |y| for (0..width) |x| {
        const p = rgba[(y * width + x) * 4 ..][0..4];
        const fx: f32 = @floatFromInt(x);
        const fy: f32 = @floatFromInt(y);
        const band = (@sin((fx + fy) / 90) + 1) / 2;
        const grid = x % 40 == 0 or y % 40 == 0;
        const r: f32 = 150 + 80 * band;
        const g: f32 = 190 + 40 * (1 - band);
        const b: f32 = 235 - 50 * band;
        const dim: f32 = if (grid) 0.85 else 1;
        p.* = .{ @intFromFloat(r * dim), @intFromFloat(g * dim), @intFromFloat(b * dim), 255 };
    };
}

/// Composites the premultiplied `overlay` over the opaque `background`
/// into `out`, within `region`: `out = overlay + background * (1 - alpha)`.
fn composite(out: []u8, overlay: []const u8, background: []const u8, region: Rect) void {
    const x0: usize = @intFromFloat(@max(region.x, 0));
    const y0: usize = @intFromFloat(@max(region.y, 0));
    const x1: usize = @intFromFloat(@min(region.x + region.w, viewport.x));
    const y1: usize = @intFromFloat(@min(region.y + region.h, viewport.y));
    for (y0..y1) |y| for (x0..x1) |x| {
        const i = (y * width + x) * 4;
        const a: u32 = overlay[i + 3];
        for (0..3) |c| out[i + c] = @intCast(@as(u32, overlay[i + c]) + (@as(u32, background[i + c]) * (255 - a) + 127) / 255);
        out[i + 3] = 255;
    };
}

/// Straight alpha from premultiplied, for PNG.
fn unpremultiply(out: []u8, premultiplied: []const u8) void {
    for (0..pixel_count) |n| {
        const p = premultiplied[n * 4 ..][0..4];
        const a: u32 = p[3];
        out[n * 4 ..][0..4].* = if (a == 0) .{ 0, 0, 0, 0 } else .{
            @intCast(@min(255, (@as(u32, p[0]) * 255 + a / 2) / a)),
            @intCast(@min(255, (@as(u32, p[1]) * 255 + a / 2) / a)),
            @intCast(@min(255, (@as(u32, p[2]) * 255 + a / 2) / a)),
            p[3],
        };
    }
}

const pixel_count = width * height;

/// Outlines `region` in red, two pixels wide.
fn outline(rgba: []u8, region: Rect) void {
    const x0: usize = @intFromFloat(@max(region.x, 0));
    const y0: usize = @intFromFloat(@max(region.y, 0));
    const x1: usize = @intFromFloat(@min(region.x + region.w, viewport.x));
    const y1: usize = @intFromFloat(@min(region.y + region.h, viewport.y));
    if (x1 <= x0 or y1 <= y0) return;
    for (y0..y1) |y| for (x0..x1) |x| {
        if (x - x0 >= 2 and x1 - x > 2 and y - y0 >= 2 and y1 - y > 2) continue;
        rgba[(y * width + x) * 4 ..][0..4].* = .{ 230, 30, 30, 255 };
    };
}

test "the script plays through, and redrawing the damage always matches a full redraw" {
    var host: Host = undefined;
    try host.init(std.testing.allocator, std.testing.io);
    defer host.deinit();
    var taken: [script.len]?bool = undefined;
    for (script, &taken) |step, *t| {
        t.* = (try host.play(step)).taken;
        try host.check();
    }
    // clicks between widgets went through; the others were the app's
    for (script, taken) |step, t| {
        if (step.action == .start) continue;
        try std.testing.expectEqual(!std.mem.eql(u8, step.name, "click-through"), t.?);
    }
    const state = host.runtime.rootState(Hybrid).?;
    try std.testing.expect(!state.green);
    try std.testing.expect(state.transform and state.switched);
    try std.testing.expectApproxEqAbs(0.75, state.slider, 0.01);
    try std.testing.expectEqual(Hybrid.Choice.r1, state.choice.?);
    try std.testing.expect(!state.dialog);
}
