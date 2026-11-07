//! Buffered CPU timings for kitchen's measurement build.
const std = @import("std");
const fabrum = @import("fabrum");
const Timings = if (!@hasDecl(fabrum.app, "phase_timings_enabled"))
    @compileError("measurement requires fabrum phase timings; use --fork /path/to/current/fabrum")
else if (!fabrum.app.phase_timings_enabled)
    @compileError("measurement requires -Dphase_timings=true")
else
    fabrum.app.PhaseTimings;
const Self = @This();

pub const Row = struct {
    step: []const u8,
    frames: usize,
    commands: usize,
    regions: usize,
    damage_pixels: usize,
    width: u32,
    height: u32,
    total_ns: u64,
    frame_ns: u64,
    views_ns: u64,
    layout_ns: u64,
    commands_ns: u64,
    reconcile_ns: u64,
    damage_ns: u64,
    render_ns: u64,
    composite_ns: u64,
    resize_ns: u64,
    input_ns: u64,
};

rows: std.ArrayList(Row) = .empty,
step: []const u8 = "initial",
resize_ns: u64 = 0,
input_ns: u64 = 0,

pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
    self.rows.deinit(gpa);
}

pub fn delta(before: Timings, after: Timings, phase: Timings.Phase) u64 {
    return after.get(phase).total_ns - before.get(phase).total_ns;
}

pub fn elapsed(io: std.Io, started: std.Io.Timestamp) u64 {
    return @intCast(@max(started.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds(), 0));
}

pub fn write(self: *const Self, out: *std.Io.Writer) !void {
    try out.writeAll("TRACE");
    inline for (@typeInfo(Row).@"struct".field_names) |name| {
        try out.print(",{s}", .{name});
    }
    try out.writeAll("\n");
    for (self.rows.items) |row| {
        try out.print("TRACE,{s}", .{row.step});
        inline for (@typeInfo(Row).@"struct".field_names[1..]) |name| {
            try out.print(",{d}", .{@field(row, name)});
        }
        try out.writeAll("\n");
    }
}
