const std = @import("std");
const morse = @import("morse");

pub fn main() !void {
    var buffer: [16]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try morse.cursorTo(&writer, 1, 1);
}
