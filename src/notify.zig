//! Desktop notifications, in the two forms terminals implement.
//!
//! Neither is standardised and neither is acknowledged: a terminal that does
//! not implement one ignores it, and a program cannot tell the difference
//! between a notification shown and a notification dropped.
//!
//! Caller text is refused, never mangled: C0 controls and DEL return
//! `error.ControlInText` before anything is written.
//!
//! What this file will never hold: a queue, an id, or a way to take a
//! notification back. Neither form carries one.

const std = @import("std");
const seq = @import("seq.zig");
const strings = @import("strings.zig");

const Writer = std.Io.Writer;

/// Posts a notification with a title and a body:
/// `OSC 777 ; notify ; title ; body ST`.
///
/// C0 controls and DEL in either field are refused before writing.
/// Ordinary text is unchanged; neither field should contain the `;` separator.
pub fn notify(w: *Writer, title: []const u8, body: []const u8) strings.Error!void {
    try strings.checkText(body);
    try strings.checkText(title);
    try w.writeAll(seq.osc ++ "777;notify;");
    try w.writeAll(title);
    try w.writeByte(';');
    try w.writeAll(body);
    try w.writeAll(seq.st);
}

/// Posts a notification with no title: `OSC 9 ; body ST`.
///
/// The older and simpler of the two forms, and the one some terminals
/// implement instead of OSC 777. C0 controls and DEL in `body` are refused
/// before writing; ordinary text is unchanged.
pub fn notify9(w: *Writer, body: []const u8) strings.Error!void {
    try strings.checkText(body);
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

test "notifications refuse controls in every field before writing and preserve UTF-8" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    for (0..128) |n| {
        if (n >= 32 and n != 127) continue;
        const bad = [_]u8{ 'a', @intCast(n), 'b' };
        try std.testing.expectError(error.ControlInText, notify(&out.writer, &bad, "ok"));
        try std.testing.expectError(error.ControlInText, notify(&out.writer, "ok", &bad));
        try std.testing.expectError(error.ControlInText, notify9(&out.writer, &bad));
        try std.testing.expectEqual(@as(usize, 0), out.written().len);
    }
    try notify(&out.writer, "café", "🐈");
    try notify9(&out.writer, "café 🐈");
    try std.testing.expectEqualStrings("\x1b]777;notify;café;🐈\x1b\\\x1b]9;café 🐈\x1b\\", out.written());
}
