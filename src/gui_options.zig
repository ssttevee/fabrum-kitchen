//! Shared windowed Kitchen options. Disabling selects the drawn screen,
//! whose widgets implement the disabled state on both AppKit and GTK.
const std = @import("std");

const Options = @This();

drawn: bool = false,
disabled: bool = false,

pub fn parse(args: []const []const u8) error{InvalidArgument}!Options {
    var options: Options = .{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--drawn")) {
            options.drawn = true;
        } else if (std.mem.eql(u8, arg, "--disable")) {
            options.drawn = true;
            options.disabled = true;
        } else {
            return error.InvalidArgument;
        }
    }
    return options;
}

test "GUI flags choose the drawn screen and its disabled state" {
    try std.testing.expectEqual(Options{}, try parse(&.{}));
    try std.testing.expectEqual(Options{ .drawn = true }, try parse(&.{"--drawn"}));
    try std.testing.expectEqual(Options{ .drawn = true, .disabled = true }, try parse(&.{"--disable"}));
    try std.testing.expectEqual(try parse(&.{ "--disable", "--drawn" }), try parse(&.{ "--drawn", "--disable" }));
    try std.testing.expectError(error.InvalidArgument, parse(&.{"--unknown"}));
}
