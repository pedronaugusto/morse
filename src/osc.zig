//! The OSC sequences that label things: the window title (OSC 2) and the
//! hyperlink (OSC 8).

const std = @import("std");
const seq = @import("seq.zig");

const Writer = std.Io.Writer;

/// Sets the window title: `OSC 2 ; text BEL`.
///
/// `BEL` rather than the `ST` the rest of this package writes: OSC 2 is old
/// enough that some terminals accept nothing else there, and every terminal
/// that takes `ST` also takes `BEL`.
///
/// `text` is written through byte for byte. A terminal ends the string at the
/// first `ESC`, `BEL` or other C0 control, so a caller whose text may contain
/// one must strip it first; this function does not, because silently editing
/// a title is worse than a title that stops early.
pub fn title(w: *Writer, text: []const u8) Writer.Error!void {
    try w.writeAll(seq.osc ++ "2;");
    try w.writeAll(text);
    try w.writeByte(seq.bel);
}

/// Opens a hyperlink: every cell written until the matching `hyperlinkEnd`
/// carries `uri`, which the terminal opens on click.
///
/// `params` is the optional `key=value:key=value` list the OSC 8 spec places
/// before the URI; `id=<name>` is the one terminals act on, joining runs that
/// share an id into a single link for hover and click. Pass null for none.
/// Neither `uri` nor `params` may contain `;`, `ESC` or `BEL`, and this
/// function does not check: percent-encode the URI as the spec requires.
pub fn hyperlinkStart(w: *Writer, uri: []const u8, params: ?[]const u8) Writer.Error!void {
    try w.writeAll(seq.osc ++ "8;");
    if (params) |p| try w.writeAll(p);
    try w.writeByte(';');
    try w.writeAll(uri);
    try w.writeAll(seq.st);
}

/// Closes the hyperlink opened by `hyperlinkStart`: `OSC 8 ; ; ST`. Cells
/// written after this one carry no link.
pub fn hyperlinkEnd(w: *Writer) Writer.Error!void {
    try w.writeAll(seq.osc ++ "8;;" ++ seq.st);
}

/// Writes `text` as a hyperlink to `uri`: `hyperlinkStart`, the text, then
/// `hyperlinkEnd`. `text` is written unchanged, so it may carry attributes
/// set before the call.
pub fn hyperlink(w: *Writer, text: []const u8, uri: []const u8) Writer.Error!void {
    try hyperlinkStart(w, uri, null);
    try w.writeAll(text);
    try hyperlinkEnd(w);
}

test "title is OSC 2 terminated by BEL" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try title(&out.writer, "hello");
    try std.testing.expectEqualStrings("\x1b]2;hello\x07", out.written());
}

test "title accepts an empty string" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try title(&out.writer, "");
    try std.testing.expectEqualStrings("\x1b]2;\x07", out.written());
}

test "hyperlinkStart writes an empty params field when there are none" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try hyperlinkStart(&out.writer, "https://ziglang.org", null);
    try std.testing.expectEqualStrings("\x1b]8;;https://ziglang.org\x1b\\", out.written());
}

test "hyperlinkStart carries params before the URI" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try hyperlinkStart(&out.writer, "file:///tmp/log", "id=log");
    try std.testing.expectEqualStrings("\x1b]8;id=log;file:///tmp/log\x1b\\", out.written());
}

test "hyperlinkEnd closes with an empty URI" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try hyperlinkEnd(&out.writer);
    try std.testing.expectEqualStrings("\x1b]8;;\x1b\\", out.written());
}

test "hyperlink wraps text in a start and an end" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try hyperlink(&out.writer, "Zig", "https://ziglang.org");
    try std.testing.expectEqualStrings(
        "\x1b]8;;https://ziglang.org\x1b\\Zig\x1b]8;;\x1b\\",
        out.written(),
    );
}

test "a writer with no room left reports the failure" {
    var buffer: [4]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try std.testing.expectError(error.WriteFailed, title(&w, "too long for four bytes"));
}
