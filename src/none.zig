//! The Kitchen on fabrum's `none` platform: no window and no toolkit. This
//! program is the host, as a VNC proxy, a game overlay or an e-reader's
//! toolkit would be. It drives the runtime through the host contract
//! (`fabrum.app.platform.none`), in two modes:
//!
//! - **overlay**: premultiplied RGBA over a background image, as a proxy
//!   draws over the remote screen or an overlay over a game's frame. It
//!   plays a script of pointer moves, clicks, drags, wheel scrolls and
//!   keys with their text, as a VNC client would send them, and says which
//!   the app took and which it let through to what is under it;
//! - **e-ink** (`--eink`): an opaque `gray8` panel, with the capabilities
//!   of an e-reader (touch, no hover, no animation, 16 grays, a system
//!   keyboard) and services that stand in for its toolkit's (the keyboard
//!   answers a text entry). Typing arrives as committed text, as the
//!   system keyboard delivers it, and each step reports the refresh the
//!   runtime asks for (`interactive`, `content`, `page`), which an InkView
//!   host would map to its A2, partial and full updates.
//!
//! In both it runs frames on its own clock, takes the changed regions,
//! redraws only those with a portable renderer, and composites or copies
//! only those. Every step it also redraws everything from scratch and
//! checks the results are the same, which checks the damage end to end.
//!
//! It writes PNGs of some steps to `/tmp/kitchen-snapshots/p2/` (or
//! `--out DIR`): the composited frame, the overlay alone, and the frame
//! with the damage outlined; the e-ink frames as `eink-*`. `--bench` times
//! full and partial redraws.
//!
//! It links no OS UI library, so it cross-compiles:
//! `zig build -Dtarget=x86_64-linux-musl`, `-Dtarget=x86_64-windows-gnu`,
//! or `-Dtarget=arm-linux-gnueabi.2.38 -Dcpu=cortex_a7` for a PocketBook
//! B288.
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

/// How the host shows the Kitchen.
const Mode = enum {
    /// RGBA over a background, with the page left out so clicks between
    /// widgets go through.
    overlay,
    /// An opaque gray panel, with the page.
    eink,

    fn pixelFormat(self: Mode) layout.PixelFormat {
        return switch (self) {
            .overlay => .rgba8_premultiplied,
            .eink => .gray8,
        };
    }

    fn capabilities(self: Mode) app.Capabilities {
        return switch (self) {
            .overlay => .{},
            .eink => .{ .pointer = .touch, .hover = false, .animation = .none, .color = .gray16, .keyboard = .on_screen },
        };
    }

    fn props(self: Mode) Hybrid.Props {
        return .{ .page = self == .eink };
    }
};

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
        /// Text typed: keys with their text in the overlay, committed text
        /// from the system keyboard on e-ink.
        type: []const u8,
        /// A press, moves in steps, and a release.
        drag: struct { from: Target, to: Target, steps: u8 = 4 },
        /// The wheel over an element.
        scroll: struct { at: Target, delta: Vec2 },
    };

    /// Where the pointer goes: an element of the screen, found in the last
    /// frame's layout as a VNC client would see it on screen.
    const Target = union(enum) {
        /// The middle of the text.
        text: []const u8,
        /// The middle of the element with this key.
        element: []const u8,
        /// The middle of a drawn text field's box.
        field: []const u8,
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
    .{ .name = "focus-line", .action = .{ .click = .{ .field = "line" } }, .snapshot = true },
    .{ .name = "type-line", .action = .{ .type = "Hi there" }, .snapshot = true },
    .{ .name = "enter", .action = .{ .key = .enter }, .snapshot = true },
    .{ .name = "tab", .action = .{ .key = .tab } },
    .{ .name = "space", .action = .{ .key = .space }, .snapshot = true },
    .{ .name = "focus-notes", .action = .{ .click = .{ .field = "notes" } } },
    .{ .name = "type-notes", .action = .{ .type = "Notes typed on none, wrapping into the area as they go, and scrolling it." }, .snapshot = true },
    .{ .name = "drag-slider", .action = .{ .drag = .{ .from = .{ .slider = 0.25 }, .to = .{ .slider = 0.6 } } }, .snapshot = true },
    .{ .name = "scroll-page", .action = .{ .scroll = .{ .at = .{ .element = "strip" }, .delta = .init(0, 300) } }, .snapshot = true },
    .{ .name = "scroll-back", .action = .{ .scroll = .{ .at = .{ .text = "Rating" }, .delta = .init(0, -300) } } },
    .{ .name = "click-through", .action = .{ .click = .{ .point = .init(780, 30) } } },
    .{ .name = "open-dialog", .action = .{ .click = .{ .text = "Open dialog" } }, .snapshot = true },
    .{ .name = "close-dialog", .action = .{ .click = .{ .text = "Close" } }, .snapshot = true },
};

const Options = struct {
    out: []const u8 = "/tmp/kitchen-snapshots/p2",
    bench: bool = false,
    quiet: bool = false,
    modes: []const Mode = &.{ .overlay, .eink },
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
        } else if (std.mem.eql(u8, arg, "--eink")) {
            options.modes = &.{.eink};
        } else if (std.mem.eql(u8, arg, "--overlay")) {
            options.modes = &.{.overlay};
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return error.InvalidArgument;
        }
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout.interface;
    try Io.Dir.cwd().createDirPath(io, options.out);

    for (options.modes) |mode| {
        var host: Host = undefined;
        try host.init(gpa, io, mode);
        defer host.deinit();

        try out.print("kitchen-none ({t}): {s} renderer, {d}x{d} {t}, writing to {s}\n", .{ mode, renderer_name, width, height, mode.pixelFormat(), options.out });
        try out.print("{s:<16} {s:>5} {s:>7} {s:>9} {s:>8} {s:>9} {s:>9}  {s:<11} {s}\n", .{ "step", "taken", "regions", "pixels", "frame", "render", "composite", "refresh", "next frame" });
        for (script, 0..) |step, n| {
            const report = try host.play(step);
            try out.print("{s:<16} {s:>5} {d:>7} {d:>9} {d:>6}us {d:>7}us {d:>7}us  {s:<11} {s}\n", .{
                step.name,
                if (report.taken) |t| (if (t) "yes" else "no") else "-",
                report.regions,
                report.pixels,
                report.frame_us,
                report.render_us,
                report.composite_us,
                if (report.regions > 0) @tagName(report.refresh) else "-",
                if (report.next_frame) |due| (if (due.nanoseconds <= host.now.nanoseconds) "now" else "scheduled") else "when input comes",
            });
            try host.check();
            if (step.snapshot) try host.snapshot(options.out, n + 1, step.name);
        }
        try out.print("every step: the redrawn damage matched a full redraw\n\n", .{});

        if (options.bench) try host.bench(out);
    }
    try out.flush();
}

/// Services an e-reader's toolkit would give: a system keyboard that
/// answers a text entry (here, with the text it was given, as a user
/// pressing OK at once), and a dialog that is answered with its first
/// button. Stands in for InkView's `OpenKeyboard` and `Dialog`.
const EinkServices = struct {
    text_entries: usize = 0,

    fn services(self: *EinkServices) app.platform.Services {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: app.platform.Services.VTable = .{
        .editText = editText,
        .confirm = confirm,
    };

    fn editText(ptr: *anyopaque, request: *const app.platform.TextRequest, reply: app.platform.Reply) app.platform.Services.Error!void {
        const self: *EinkServices = @ptrCast(@alignCast(ptr));
        self.text_entries += 1;
        try reply.send(request.initial);
    }

    fn confirm(_: *anyopaque, _: *const app.platform.ConfirmRequest, reply: app.platform.IndexReply) app.platform.Services.Error!void {
        try reply.send(0);
    }
};

/// What the host keeps: the runtime, the renderer, and its buffers.
const Host = struct {
    gpa: Allocator,
    io: Io,
    mode: Mode,
    renderer: Renderer,
    runtime: Runtime,
    services: EinkServices = .{},
    /// The time frames run at: a fake clock, a frame apart per step, so
    /// snapshots are the same every run.
    now: Io.Timestamp = .zero,
    /// The overlay, premultiplied RGBA, or the gray panel, redrawn where
    /// damaged.
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

    fn init(self: *Host, gpa: Allocator, io: Io, mode: Mode) !void {
        const bytes = mode.pixelFormat().bytesPerPixel();
        var renderer: Renderer = try .init(gpa);
        errdefer renderer.deinit();
        try renderer.loadFont("Go", @embedFile("fonts/Go-Regular.ttf"));
        const overlay = try gpa.alignedAlloc(u8, .@"4", pixel_count * bytes);
        errdefer gpa.free(overlay);
        const background = try gpa.alloc(u8, pixel_count * 4);
        errdefer gpa.free(background);
        const composited = try gpa.alloc(u8, pixel_count * 4);
        errdefer gpa.free(composited);
        const full_overlay = try gpa.alignedAlloc(u8, .@"4", pixel_count * bytes);
        errdefer gpa.free(full_overlay);
        const full_composited = try gpa.alloc(u8, pixel_count * 4);
        errdefer gpa.free(full_composited);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .mode = mode,
            .renderer = renderer,
            .runtime = undefined,
            .overlay = overlay,
            .background = background,
            .composited = composited,
            .full_overlay = full_overlay,
            .full_composited = full_composited,
        };
        // the services point into the host, so the runtime is made in place
        self.runtime = try .init(gpa, .{
            .io = io,
            .text_context = self.renderer.text_context,
            .theme = theme,
            .capabilities = mode.capabilities(),
            .services = if (mode == .eink) self.services.services() else null,
        });
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

    fn pixels(self: *const Host, buffer: []align(4) u8) layout.Surface.Pixels {
        return .packed_(buffer, width, height, self.mode.pixelFormat());
    }

    const Report = struct {
        taken: ?bool = null,
        regions: usize = 0,
        pixels: usize = 0,
        frame_us: u64 = 0,
        render_us: u64 = 0,
        composite_us: u64 = 0,
        refresh: app.Refresh = .content,
        next_frame: ?Io.Timestamp = null,
    };

    fn primary() app.MouseEvent.Buttons {
        var down: app.MouseEvent.Buttons = .empty;
        down.set(app.MouseEvent.primary);
        return down;
    }

    /// Plays one step as a host does: input in, a frame, the damage, then
    /// drawing and compositing just that.
    fn play(self: *Host, step: Step) !Report {
        var report: Report = .{};
        switch (step.action) {
            .start => {},
            .hover => |target| report.taken = try self.runtime.mouse(.{ .position = try self.locate(target) }),
            .click => |target| {
                const point = try self.locate(target);
                const pressed = try self.runtime.mouse(.{ .position = point, .pressed = primary() });
                const released = try self.runtime.mouse(.{ .position = point });
                report.taken = pressed or released;
            },
            .key => |key| {
                report.taken = try self.runtime.key(.{ .key = key });
                _ = try self.runtime.key(.{ .key = key, .phase = .release });
            },
            .type => |text| {
                var taken = true;
                switch (self.mode) {
                    // keys with their text, as a VNC client's keysyms give
                    .overlay => {
                        var it = (try std.unicode.Utf8View.init(text)).iterator();
                        while (it.nextCodepointSlice()) |slice| {
                            const cp = try std.unicode.utf8Decode(slice);
                            const key: app.KeyEvent.Key = if (cp == ' ') .space else if (cp < 128) .{ .char = std.ascii.toLower(@intCast(cp)) } else .unknown;
                            const event: app.KeyEvent = .{ .key = key, .text = slice, .modifiers = .{ .shift = cp < 128 and std.ascii.isUpper(@intCast(cp)) } };
                            if (!try self.runtime.key(event)) taken = false;
                            _ = try self.runtime.key(.{ .key = key, .phase = .release, .modifiers = event.modifiers });
                            try self.frames(&report);
                        }
                    },
                    // the system keyboard's whole text, committed at once
                    .eink => taken = try self.runtime.textInput(.{ .commit = text }),
                }
                report.taken = taken;
            },
            .drag => |drag| {
                const from = try self.locate(drag.from);
                const to = try self.locate(drag.to);
                var taken = try self.runtime.mouse(.{ .position = from, .pressed = primary() });
                try self.frames(&report);
                const n: f32 = @floatFromInt(drag.steps);
                for (1..drag.steps + 1) |i| {
                    const t: f32 = @as(f32, @floatFromInt(i)) / n;
                    const at: Vec2 = .init(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t);
                    if (!try self.runtime.mouse(.{ .position = at, .pressed = primary() })) taken = false;
                    try self.frames(&report);
                }
                _ = try self.runtime.mouse(.{ .position = to });
                report.taken = taken;
            },
            .scroll => |scroll| report.taken = try self.runtime.mouse(.{ .position = try self.locate(scroll.at), .scroll_delta = scroll.delta }),
        }
        try self.frames(&report);
        report.next_frame = self.runtime.nextFrame();
        return report;
    }

    /// Runs the frames due now, then draws what changed over them.
    fn frames(self: *Host, report: *Report) !void {
        // frames while one is due now (a modal dialog taking focus asks for
        // a second); the host's clock moves on a frame each
        var count: usize = 0;
        while (self.runtime.nextFrame()) |due| {
            if (due.nanoseconds > self.now.nanoseconds or count == 4) break;
            var timer = Timer.start(self.io);
            _ = try self.runtime.frame(Hybrid, self.mode.props(), viewport, self.now);
            report.frame_us += timer.lap();
            count += 1;
            self.now = self.now.addDuration(.fromMilliseconds(16));
        }
        if (count > 0) {
            var timer = Timer.start(self.io);
            // what changed over those frames, since the last draw
            const regions = try self.runtime.damage();
            const refresh = self.runtime.refresh();
            if (report.regions == 0) self.damage.clearRetainingCapacity();
            try self.damage.appendSlice(self.gpa, regions);
            report.regions += regions.len;
            for (regions) |r| report.pixels += @intFromFloat(r.w * r.h);
            if (regions.len > 0) report.refresh = report.refresh.strongest(refresh);

            if (regions.len > 0) {
                try layout.draw(&self.renderer, self.runtime.commands(), .pixels, self.pixels(self.overlay), regions);
                report.render_us += timer.lap();
                for (regions) |r| self.composite(self.composited, self.overlay, r);
                report.composite_us += timer.lap();
            }
        }
    }

    /// Redraws and composites everything, and fails unless that is what
    /// redrawing only the damage gave.
    fn check(self: *Host) !void {
        try layout.draw(&self.renderer, self.runtime.commands(), .pixels, self.pixels(self.full_overlay), null);
        self.composite(self.full_composited, self.full_overlay, .init(0, 0, viewport.x, viewport.y));
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
            .field => |key| app.testing.center(ctx.getUnitById(root.child(app.drawn.TextBox, key).element("field")) orelse return error.NoSuchElement),
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

        switch (self.mode) {
            .overlay => {
                unpremultiply(straight, self.overlay);
                try self.write(dir, number, name, "-overlay", straight);
                try self.write(dir, number, name, "", self.composited);
            },
            .eink => try self.write(dir, number, name, "", self.composited),
        }

        @memcpy(straight, self.composited);
        for (self.damage.items) |r| outline(straight, r);
        try self.write(dir, number, name, "-damage", straight);
    }

    fn write(self: *Host, dir: []const u8, number: usize, name: []const u8, suffix: []const u8, rgba: []const u8) !void {
        var path_buffer: [512]u8 = undefined;
        const prefix: []const u8 = if (self.mode == .eink) "eink-" else "";
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}{d:0>2}-{s}{s}.png", .{ dir, prefix, number, name, suffix });
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
            try layout.draw(&self.renderer, self.runtime.commands(), .pixels, self.pixels(self.full_overlay), null);
            t.* = timer.lap();
        }

        // hovering on and off a button, each a frame with its damage
        const button = try self.locate(.{ .element = "green" });
        var partial: [rounds]u64 = undefined;
        var area: usize = 0;
        for (&partial, 0..) |*t, n| {
            _ = try self.runtime.mouse(.{ .position = if (n % 2 == 0) button else .init(780, 30) });
            _ = try self.runtime.frame(Hybrid, self.mode.props(), viewport, self.now);
            const regions = try self.runtime.damage();
            area = 0;
            for (regions) |r| area += @intFromFloat(r.w * r.h);
            var timer = Timer.start(self.io);
            try layout.draw(&self.renderer, self.runtime.commands(), .pixels, self.pixels(self.overlay), regions);
            t.* = timer.lap();
        }

        var frame_times: [rounds]u64 = undefined;
        for (&frame_times) |*t| {
            var timer = Timer.start(self.io);
            _ = try self.runtime.frame(Hybrid, self.mode.props(), viewport, self.now);
            t.* = timer.lap();
        }

        try out.print("\nbench ({s}, {t}, median of {d}):\n", .{ renderer_name, self.mode, rounds });
        try out.print("  layout and views, one frame:      {d:>7}us\n", .{median(&frame_times)});
        try out.print("  render the whole {d}x{d} frame:   {d:>7}us\n", .{ width, height, median(&full) });
        try out.print("  render a hover's damage ({d} px):  {d:>7}us\n", .{ area, median(&partial) });
    }

    /// Composites the premultiplied `overlay` over the opaque background
    /// into `out` within `region` (`out = overlay + background * (1 -
    /// alpha)`), or expands the gray panel to RGB.
    fn composite(self: *const Host, out: []u8, overlay: []const u8, region: Rect) void {
        const span = Span.of(region);
        if (span.isEmpty()) return;
        switch (self.mode) {
            inline else => |mode| self.compositeAs(mode, out, overlay, span),
        }
    }

    /// `composite` for one mode, so there is no branch per pixel.
    fn compositeAs(self: *const Host, comptime mode: Mode, out: []u8, overlay: []const u8, span: Span) void {
        for (span.y0..span.y1) |y| for (span.x0..span.x1) |x| {
            const i = (y * width + x) * 4;
            switch (mode) {
                .overlay => {
                    const a: u32 = overlay[i + 3];
                    for (0..3) |c| out[i + c] = @intCast(@as(u32, overlay[i + c]) + (@as(u32, self.background[i + c]) * (255 - a) + 127) / 255);
                    out[i + 3] = 255;
                },
                .eink => {
                    const g = overlay[y * width + x];
                    out[i..][0..4].* = .{ g, g, g, 255 };
                },
            }
        };
    }
};

/// The whole pixels of `region` that are in the viewport: `x0 <= x < x1`,
/// `y0 <= y < y1`.
const Span = struct {
    x0: usize,
    y0: usize,
    x1: usize,
    y1: usize,

    fn of(region: Rect) Span {
        return .{
            .x0 = @intFromFloat(std.math.clamp(region.x, 0, viewport.x)),
            .y0 = @intFromFloat(std.math.clamp(region.y, 0, viewport.y)),
            .x1 = @intFromFloat(std.math.clamp(region.x + region.w, 0, viewport.x)),
            .y1 = @intFromFloat(std.math.clamp(region.y + region.h, 0, viewport.y)),
        };
    }

    fn isEmpty(self: Span) bool {
        return self.x1 <= self.x0 or self.y1 <= self.y0;
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
    const span = Span.of(region);
    if (span.isEmpty()) return;
    for (span.y0..span.y1) |y| for (span.x0..span.x1) |x| {
        if (x - span.x0 >= 2 and span.x1 - x > 2 and y - span.y0 >= 2 and span.y1 - y > 2) continue;
        rgba[(y * width + x) * 4 ..][0..4].* = .{ 230, 30, 30, 255 };
    };
}

test {
    _ = png;
}

test "the script plays through in both modes, and redrawing the damage always matches a full redraw" {
    for ([_]Mode{ .overlay, .eink }) |mode| {
        var host: Host = undefined;
        try host.init(std.testing.allocator, std.testing.io, mode);
        defer host.deinit();
        var taken: [script.len]?bool = undefined;
        var refreshes: [script.len]app.Refresh = undefined;
        for (script, &taken, &refreshes) |step, *t, *r| {
            const report = try host.play(step);
            t.* = report.taken;
            r.* = report.refresh;
            try host.check();
        }
        // on the overlay, clicks between widgets go through; on the e-ink
        // page everything is the app's
        for (script, taken) |step, t| {
            if (step.action == .start) continue;
            const through = mode == .overlay and std.mem.eql(u8, step.name, "click-through");
            try std.testing.expectEqual(!through, t.?);
        }
        // drags and scrolls ask for a fast refresh, the rest for a quality one
        for (script, refreshes) |step, r| {
            const interactive = step.action == .drag or step.action == .scroll;
            if (step.action == .start) continue;
            try std.testing.expectEqual(if (interactive) app.Refresh.interactive else .content, r);
        }
        const state = host.runtime.rootState(Hybrid).?;
        try std.testing.expect(!state.green);
        try std.testing.expect(state.transform and state.switched);
        try std.testing.expectApproxEqAbs(0.6, state.slider, 0.02);
        try std.testing.expectEqual(Hybrid.Choice.r1, state.choice.?);
        try std.testing.expectEqualStrings("Hi there", state.heading.items);
        try std.testing.expect(std.mem.startsWith(u8, state.notes.items, "Notes typed"));
        try std.testing.expect(!state.dialog);
        try std.testing.expectEqual(0, host.runtime.scrollInfo(app.testing.rootInstance(Hybrid).element("page")).?.offset.y);
        if (mode == .eink) try std.testing.expectEqual(2, host.services.text_entries);
    }
}
