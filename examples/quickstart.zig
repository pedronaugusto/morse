//! Write a heading and decode input split across reads.
const std = @import("std");
const morse = @import("morse");

pub fn main() !void {
    // --- README:usage ---
    var output: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);
    const heading: morse.Style = .{ .bold = true, .fg = .ansi(.cyan) };
    const body: morse.Style = .{ .fg = .ansi(.cyan) };

    try morse.cursorTo(&writer, 1, 1);
    try morse.setStyle(&writer, heading);
    try writer.writeAll("morse");
    try morse.diffStyle(&writer, heading, body);
    try writer.writeAll(" terminal sequences");
    try morse.resetStyle(&writer);

    var input: [128]u8 = undefined;
    var parser: morse.KeyParser = .init(&input);
    var events = parser.feed("\x1b[97;");
    if (events.next() != null) return error.IncompleteKey;

    events = parser.feed("5u\x1b[<0;40;12M");
    const key = (events.next() orelse return error.MissingKey).key;
    const mouse = (events.next() orelse return error.MissingMouse).mouse;
    // --- README:usage ---

    try std.testing.expectEqualStrings(
        "\x1b[1;1H\x1b[1;36mmorse\x1b[22m terminal sequences\x1b[0m",
        writer.buffered(),
    );
    try std.testing.expectEqual(morse.Key{ .char = 'a' }, key.key);
    try std.testing.expect(key.mods.ctrl);
    try std.testing.expectEqual(@as(u32, 40), mouse.x);
    try std.testing.expectEqual(@as(u32, 12), mouse.y);
    try std.testing.expect(events.next() == null);
}
