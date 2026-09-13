//! Desktop notifications, in the two forms terminals implement.
//!
//! Neither is standardised and neither is acknowledged: a terminal that does
//! not implement one ignores it, and a program cannot tell the difference
//! between a notification shown and a notification dropped.

const std = @import("std");
const seq = @import("seq.zig");

const Writer = std.Io.Writer;

/// Posts a notification with a title and a body:
/// `OSC 777 ; notify ; title ; body ST`.
///
/// Neither field may contain `;`, `ESC` or `BEL`; a terminal that meets one
/// splits or truncates the notification there. This function writes both
/// through unchanged rather than deciding how to mangle them.
pub fn notify(w: *Writer, title: []const u8, body: []const u8) Writer.Error!void {
    try w.writeAll(seq.osc ++ "777;notify;");
    try w.writeAll(title);
    try w.writeByte(';');
    try w.writeAll(body);
    try w.writeAll(seq.st);
}

/// Posts a notification with no title: `OSC 9 ; body ST`.
///
/// The older and simpler of the two forms, and the one some terminals
/// implement instead of OSC 777.
pub fn notify9(w: *Writer, body: []const u8) Writer.Error!void {
    try w.writeAll(seq.osc ++ "9;");
    try w.writeAll(body);
    try w.writeAll(seq.st);
}

test "notify writes OSC 777 with both fields" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try notify(&out.writer, "Build finished", "0 errors, 0 warnings");
    try std.testing.expectEqualStrings(
        "\x1b]777;notify;Build finished;0 errors, 0 warnings\x1b\\",
        out.written(),
    );
}

test "notify keeps both separators when the fields are empty" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try notify(&out.writer, "", "");
    try std.testing.expectEqualStrings("\x1b]777;notify;;\x1b\\", out.written());
}

test "notify9 writes OSC 9 with only a body" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try notify9(&out.writer, "done");
    try std.testing.expectEqualStrings("\x1b]9;done\x1b\\", out.written());
}
