//! The OSC sequences that label a piece of the screen: the window title
//! (OSC 2), the icon name (OSC 1), the working directory (OSC 7), the
//! hyperlink (OSC 8) and the size text is drawn at (OSC 66).
//!
//! Each of them wraps text the terminal reads rather than draws, and each
//! writes that text through byte for byte. This file will never escape,
//! percent-encode or truncate what it is given: a title that stops early
//! because it held a control byte is a bug the caller can see and fix, and a
//! title silently edited by the library is not.

const std = @import("std");
const corpus = @import("corpus.zig");
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

/// Sets the icon name: `OSC 1 ; text BEL`.
///
/// The icon name is the short label a window manager shows where there is no
/// room for a title -- a taskbar entry, a minimised window, a tab. Terminals
/// that have no such concept ignore it, and several set the title from it
/// instead, so a program that sets both should set them to the same thing or
/// set only the title.
///
/// `BEL` and byte-for-byte, for the same reasons as `title`.
pub fn iconName(w: *Writer, text: []const u8) Writer.Error!void {
    try w.writeAll(seq.osc ++ "1;");
    try w.writeAll(text);
    try w.writeByte(seq.bel);
}

/// Pushes the window title onto the terminal's title stack:
/// `CSI 22 ; 2 t`.
///
/// The same bargain `kittyKeyboardPush` makes, for the same reason: a program
/// that sets a title is editing state it did not create and cannot read back,
/// so the way to leave the terminal as it was found is to push on entry and
/// `titlePop` on every exit path. There is no sequence that asks what the
/// title is, which is what makes the stack the only way.
///
/// The stack is the terminal's and its depth is the terminal's business. A
/// terminal that does not implement window operations ignores this, and then
/// ignores the matching pop, so the pair is safe to write unconditionally but
/// is not a guarantee.
pub fn titlePush(w: *Writer) Writer.Error!void {
    try w.writeAll(seq.csi ++ "22;2t");
}

/// Pops the window title off the terminal's title stack: `CSI 23 ; 2 t`.
/// Undoes exactly one `titlePush`.
pub fn titlePop(w: *Writer) Writer.Error!void {
    try w.writeAll(seq.csi ++ "23;2t");
}

/// Tells the terminal which directory the program considers current:
/// `OSC 7 ; uri ST`.
///
/// `uri` is a `file://` URL whose host is the machine the program is running
/// on and whose path is the directory -- `file://hostname/home/user/src`.
/// The hostname is the load-bearing part: it is how a terminal knows not to
/// open a new tab in a path that only exists at the far end of an ssh
/// session.
///
/// Written through byte for byte, like every other string here. The URI must
/// be percent-encoded already, and a directory whose name contains a space or
/// a `%` is exactly the case where an unencoded one goes wrong.
///
/// A shell is the usual writer of this; a program that changes directory on
/// the user's behalf is the other one.
pub fn workingDirectory(w: *Writer, uri: []const u8) Writer.Error!void {
    try w.writeAll(seq.osc ++ "7;");
    try w.writeAll(uri);
    try w.writeAll(seq.st);
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

/// Where fractionally scaled text sits inside the cells it was given,
/// vertically. Only meaningful when the fraction is a real one — when
/// `TextSize.numerator` is below `TextSize.denominator`.
pub const VerticalAlign = enum(u8) {
    /// Against the top of the block, and the protocol's default.
    top = 0,
    /// Against the bottom, which is where a subscript goes.
    bottom = 1,
    /// Halfway down.
    center = 2,
};

/// The same horizontally.
pub const HorizontalAlign = enum(u8) {
    /// Against the left of the block, and the protocol's default.
    left = 0,
    /// Against the right.
    right = 1,
    /// Halfway across.
    center = 2,
};

/// How big a piece of text is drawn, and in how many cells.
///
/// The block the text lands in is `scale * width` cells across and `scale`
/// cells down. `numerator` and `denominator` shrink the glyphs inside that
/// block without changing it, which is what a superscript is: half-sized
/// glyphs at the top of a normal cell.
pub const TextSize = struct {
    /// The `s` key, 1 to 7: how many cells tall the text is drawn. 0 and 1
    /// both mean the base size and neither is written.
    scale: u3 = 1,
    /// The `w` key, 0 to 7: how many cells wide, before `scale` multiplies
    /// it. Zero — the default — lets the terminal split the text into cells
    /// the way it would without this protocol.
    ///
    /// Stating it is the point of the protocol for a program that is not
    /// scaling anything: `w=2` on an emoji and `w=1` on each ASCII character
    /// is how a program and a terminal stop disagreeing about how wide a
    /// string is, which is the disagreement that breaks a drawn interface.
    width: u3 = 0,
    /// The `n` key, 0 to 15: the top of the fraction the glyphs are scaled
    /// by inside their block.
    numerator: u4 = 0,
    /// The `d` key, 0 to 15: the bottom of it. Must be greater than
    /// `numerator` when it is not zero.
    denominator: u4 = 0,
    /// The `v` key.
    vertical: VerticalAlign = .top,
    /// The `h` key.
    horizontal: HorizontalAlign = .left,
};

/// The most text one OSC 66 sequence may carry. Longer text is split into
/// several sequences by the caller.
pub const text_size_max: usize = 4096;

/// Draws `text` at a size: `OSC 66 ; metadata ; text ST`.
///
/// The metadata is the colon-separated `key=value` list `size` spells, with
/// every key at its default left out — so `textSize(w, .{}, "hi")` writes an
/// empty metadata field, which is the protocol's way of saying "as normal".
///
/// There is no reply. Nothing in the protocol acknowledges this sequence and
/// no query asks whether the terminal implements it, so a program writes it
/// and accepts that a terminal without it draws the text at one size — which
/// is why the protocol is built so that doing exactly that still reads
/// correctly.
///
/// `text` goes through byte for byte, like every other string in this file,
/// and must be valid UTF-8 no longer than `text_size_max` bytes. Neither is
/// checked here.
///
/// Read against the protocol text of 2026-09-18.
pub fn textSize(w: *Writer, size: TextSize, text: []const u8) Writer.Error!void {
    try w.writeAll(seq.osc ++ "66;");

    var any = false;
    if (size.scale > 1) try writeSizeKey(w, &any, 's', size.scale);
    if (size.width != 0) try writeSizeKey(w, &any, 'w', size.width);
    if (size.numerator != 0) try writeSizeKey(w, &any, 'n', size.numerator);
    if (size.denominator != 0) try writeSizeKey(w, &any, 'd', size.denominator);
    if (size.vertical != .top) try writeSizeKey(w, &any, 'v', @intFromEnum(size.vertical));
    if (size.horizontal != .left) try writeSizeKey(w, &any, 'h', @intFromEnum(size.horizontal));

    try w.writeByte(';');
    try w.writeAll(text);
    try w.writeAll(seq.st);
}

/// Writes one metadata key, with the `:` that separates it from the one
/// before.
fn writeSizeKey(w: *Writer, any: *bool, name: u8, value: u8) Writer.Error!void {
    if (any.*) try w.writeByte(':');
    any.* = true;
    try w.writeByte(name);
    try w.writeByte('=');
    try seq.writeInt(w, value);
}

//=========================================================================
// Reading an OSC 66 back.
//
// Test support, as in `graphics.zig`: there is no reply to this sequence and
// a program never reads one, so this is here only so the round trip proves
// the grammar rather than repeating the writer's own bytes.
//=========================================================================

/// One OSC 66 sequence, read back.
const SizedText = struct {
    /// The colon-separated `key=value` list, still as bytes.
    metadata: []const u8,
    /// The text, exactly as it was written.
    text: []const u8,

    /// The value of one key, or null when the sequence has no such key.
    fn get(s: SizedText, name: u8) ?[]const u8 {
        var rest = s.metadata;
        while (rest.len != 0) {
            const end = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
            const pair = rest[0..end];
            if (pair[0] == name) return pair[2..];
            rest = if (end == rest.len) rest[end..] else rest[end + 1 ..];
        }
        return null;
    }

    /// How many keys the list holds.
    fn count(s: SizedText) usize {
        if (s.metadata.len == 0) return 0;
        var n: usize = 1;
        for (s.metadata) |b| {
            if (b == ':') n += 1;
        }
        return n;
    }
};

/// Reads `OSC 66 ; metadata ; text ST`, or null.
///
/// Every key must be one ASCII letter with a run of digits after it, no
/// letter may appear twice, and the text may hold anything but the
/// terminator.
fn readTextSize(bytes: []const u8) ?SizedText {
    const prefix = seq.osc ++ "66;";
    if (!std.mem.startsWith(u8, bytes, prefix)) return null;
    const body = seq.stripStringTerminator(bytes[prefix.len..]) orelse return null;

    const separator = std.mem.indexOfScalar(u8, body, ';') orelse return null;
    const metadata = body[0..separator];
    if (!validMetadata(metadata)) return null;
    return .{ .metadata = metadata, .text = body[separator + 1 ..] };
}

/// Whether `metadata` is a well-formed, repetition-free `key=value` list.
fn validMetadata(metadata: []const u8) bool {
    if (metadata.len == 0) return true;
    var seen: u32 = 0;
    var rest = metadata;
    while (true) {
        const end = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
        const pair = rest[0..end];
        if (pair.len < 3 or pair[1] != '=') return false;
        if (pair[0] < 'a' or pair[0] > 'z') return false;

        const bit = @as(u32, 1) << @intCast(pair[0] - 'a');
        if (seen & bit != 0) return false;
        seen |= bit;

        for (pair[2..]) |b| {
            if (b < '0' or b > '9') return false;
        }

        if (end == rest.len) return true;
        rest = rest[end + 1 ..];
        if (rest.len == 0) return false;
    }
}

test "a default size writes an empty metadata field" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try textSize(&out.writer, .{}, "hi");
    try std.testing.expectEqualStrings("\x1b]66;;hi\x1b\\", out.written());

    const read = readTextSize(out.written()).?;
    try std.testing.expectEqual(@as(usize, 0), read.count());
    try std.testing.expectEqualStrings("hi", read.text);
}

test "textSize writes the protocol's own examples" {
    const cases = [_]struct { size: TextSize, text: []const u8, bytes: []const u8 }{
        .{ .size = .{ .scale = 2 }, .text = "Double sized text", .bytes = "\x1b]66;s=2;Double sized text\x1b\\" },
        .{ .size = .{ .scale = 3 }, .text = "Triple sized text", .bytes = "\x1b]66;s=3;Triple sized text\x1b\\" },
        .{ .size = .{ .numerator = 1, .denominator = 2 }, .text = "Half sized text", .bytes = "\x1b]66;n=1:d=2;Half sized text\x1b\\" },
        .{ .size = .{ .numerator = 1, .denominator = 2, .width = 1 }, .text = "lf", .bytes = "\x1b]66;w=1:n=1:d=2;lf\x1b\\" },
        .{ .size = .{ .width = 2 }, .text = "\u{1F408}", .bytes = "\x1b]66;w=2;\u{1F408}\x1b\\" },
    };
    for (cases) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try textSize(&out.writer, case.size, case.text);
        try std.testing.expectEqualStrings(case.bytes, out.written());
        try std.testing.expectEqualStrings(case.text, readTextSize(out.written()).?.text);
    }
}

test "a subscript is a fraction aligned at the bottom" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try textSize(&out.writer, .{ .numerator = 1, .denominator = 2, .vertical = .bottom }, "2");
    try std.testing.expectEqualStrings("\x1b]66;n=1:d=2:v=1;2\x1b\\", out.written());
}

test "every key is written in the order the protocol tabulates them" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try textSize(&out.writer, .{
        .scale = 7,
        .width = 3,
        .numerator = 5,
        .denominator = 15,
        .vertical = .center,
        .horizontal = .right,
    }, "x");
    try std.testing.expectEqualStrings("\x1b]66;s=7:w=3:n=5:d=15:v=2:h=1;x\x1b\\", out.written());

    const read = readTextSize(out.written()).?;
    try std.testing.expectEqual(@as(usize, 6), read.count());
    try std.testing.expectEqualStrings("7", read.get('s').?);
    try std.testing.expectEqualStrings("3", read.get('w').?);
    try std.testing.expectEqualStrings("5", read.get('n').?);
    try std.testing.expectEqualStrings("15", read.get('d').?);
    try std.testing.expectEqualStrings("2", read.get('v').?);
    try std.testing.expectEqualStrings("1", read.get('h').?);
}

test "a scale of zero and a scale of one both mean the base size" {
    for ([_]u3{ 0, 1 }) |scale| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try textSize(&out.writer, .{ .scale = scale }, "x");
        try std.testing.expectEqualStrings("\x1b]66;;x\x1b\\", out.written());
    }
}

test "textSize writes an empty text as an empty text" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try textSize(&out.writer, .{ .scale = 2 }, "");
    try std.testing.expectEqualStrings("\x1b]66;s=2;\x1b\\", out.written());
}

test "every size the keys can spell round trips through the grammar" {
    var scale: u3 = 0;
    while (true) : (scale += 1) {
        var width: u3 = 0;
        while (true) : (width += 1) {
            for ([_]VerticalAlign{ .top, .bottom, .center }) |vertical| {
                var out: Writer.Allocating = .init(std.testing.allocator);
                defer out.deinit();
                const size: TextSize = .{
                    .scale = scale,
                    .width = width,
                    .numerator = 1,
                    .denominator = 15,
                    .vertical = vertical,
                    .horizontal = .center,
                };
                try textSize(&out.writer, size, "ab");

                const read = readTextSize(out.written()).?;
                try std.testing.expectEqualStrings("ab", read.text);
                try std.testing.expectEqual(scale > 1, read.get('s') != null);
                try std.testing.expectEqual(width != 0, read.get('w') != null);
                try std.testing.expectEqualStrings("1", read.get('n').?);
                try std.testing.expectEqualStrings("15", read.get('d').?);
                try std.testing.expectEqual(
                    vertical != .top,
                    read.get('v') != null,
                );
            }
            if (width == 7) break;
        }
        if (scale == 7) break;
    }
}

test "readTextSize returns null on anything it does not recognise" {
    const rejected = [_][]const u8{
        "", // nothing at all
        "\x1b]66;s=2;x", // no terminator
        "\x1b]66;s=2\x1b\\", // no text field
        "\x1b]6;s=2;x\x1b\\", // a different OSC
        "\x1b[66;s=2;x\x1b\\", // CSI, not OSC
        "\x1b]66;s=;x\x1b\\", // a key with no value
        "\x1b]66;=2;x\x1b\\", // a value with no key
        "\x1b]66;ss=2;x\x1b\\", // a key of two letters
        "\x1b]66;s=2:;x\x1b\\", // a colon with nothing after it
        "\x1b]66;s=2:s=3;x\x1b\\", // the same key twice
        "\x1b]66;S=2;x\x1b\\", // a capital, which this protocol has none of
        "\x1b]66;s=2x;y\x1b\\", // digits with a letter after them
    };
    for (rejected) |bytes| try std.testing.expect(readTextSize(bytes) == null);
}

test "fuzz readTextSize" {
    // The property: no input panics, what it returns borrows from the bytes
    // it was given, and the same bytes read the same way twice. There is no
    // reply to this sequence, so the round trip is against the writer in the
    // test above rather than against a terminal.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [96]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];

            const read = readTextSize(bytes) orelse return;
            const start = @intFromPtr(bytes.ptr);
            try std.testing.expect(@intFromPtr(read.text.ptr) >= start);
            try std.testing.expect(@intFromPtr(read.text.ptr) + read.text.len <= start + bytes.len);

            const again = readTextSize(bytes).?;
            try std.testing.expectEqualStrings(read.metadata, again.metadata);
            try std.testing.expectEqualStrings(read.text, again.text);
            try std.testing.expectEqual(read.count(), again.count());
        }
    }.one, .{ .corpus = &.{
        corpus.seed("\x1b]66;;hi\x1b\\"),
        corpus.seed("\x1b]66;s=2;Double sized text\x1b\\"),
        corpus.seed("\x1b]66;w=1:n=1:d=2;lf\x1b\\"),
        corpus.seed("\x1b]66;s=7:w=3:n=5:d=15:v=2:h=1;x\x07"),
        corpus.seed("\x1b]66;s=2:s=3;x\x1b\\"),
        corpus.seed("\x1b]66;s=2\x1b\\"),
    } });
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

test "iconName is OSC 1 terminated by BEL" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try iconName(&out.writer, "morse");
    try iconName(&out.writer, "");
    try std.testing.expectEqualStrings("\x1b]1;morse\x07\x1b]1;\x07", out.written());
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

test "the title stack pushes and pops the window title" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try titlePush(&out.writer);
    try title(&out.writer, "morse");
    try titlePop(&out.writer);
    try std.testing.expectEqualStrings(
        "\x1b[22;2t\x1b]2;morse\x07\x1b[23;2t",
        out.written(),
    );
}

test "workingDirectory writes OSC 7 with the URI as given" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try workingDirectory(&out.writer, "file://host/home/user/src");
    try std.testing.expectEqualStrings(
        "\x1b]7;file://host/home/user/src\x1b\\",
        out.written(),
    );
}

test "workingDirectory accepts an empty URI" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try workingDirectory(&out.writer, "");
    try std.testing.expectEqualStrings("\x1b]7;\x1b\\", out.written());
}
