//! The OSC sequences that label a piece of the screen: the window title
//! (OSC 2), the icon name (OSC 1), the working directory (OSC 7), the
//! hyperlink (OSC 8) and the size text is drawn at (OSC 66).
//!
//! Caller text is refused, never mangled: C0 controls and DEL return
//! `error.ControlInText` before anything is written. Ordinary text goes
//! through byte for byte. `printable` strips controls only when asked.

const std = @import("std");
const aegis = @import("aegis");
const corpus = @import("shakedown").corpus;
const framing = @import("framing.zig");
const seq = @import("seq.zig");
const strings = @import("strings.zig");

const Writer = std.Io.Writer;

/// Sets the window title: `OSC 2 ; text BEL`.
///
/// `BEL` rather than the `ST` the rest of this package writes: OSC 2 is old
/// enough that some terminals accept nothing else there, and every terminal
/// that takes `ST` also takes `BEL`.
///
/// C0 controls and DEL in `text` return `error.ControlInText` before
/// anything is written. Ordinary text, including UTF-8, is unchanged.
pub fn title(w: *Writer, text: []const u8) strings.TextError!void {
    try strings.writeChecked(&.{ false, true, false }, w, .{ seq.osc ++ "2;", text, &.{seq.bel} });
}

/// Sets the icon name: `OSC 1 ; text BEL`.
///
/// The icon name is the short label a window manager shows where there is no
/// room for a title -- a taskbar entry, a minimised window, a tab. Terminals
/// that have no such concept ignore it, and several set the title from it
/// instead, so a program that sets both should set them to the same thing or
/// set only the title.
///
/// Like `title`, refuses C0 controls and DEL before writing any bytes.
pub fn iconName(w: *Writer, text: []const u8) strings.TextError!void {
    try strings.writeChecked(&.{ false, true, false }, w, .{ seq.osc ++ "1;", text, &.{seq.bel} });
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
/// C0 controls and DEL are refused before writing. The URI must
/// be percent-encoded already, and a directory whose name contains a space or
/// a `%` is exactly the case where an unencoded one goes wrong.
///
/// A shell is the usual writer of this; a program that changes directory on
/// the user's behalf is the other one.
pub fn workingDirectory(w: *Writer, uri: []const u8) strings.TextError!void {
    try strings.writeChecked(&.{ false, true, false }, w, .{ seq.osc ++ "7;", uri, seq.st });
}

/// Opens a hyperlink: every cell written until the matching `hyperlinkEnd`
/// carries `uri`, which the terminal opens on click.
///
/// `params` is the optional `key=value:key=value` list the OSC 8 spec places
/// before the URI; `id=<name>` is the one terminals act on, joining runs that
/// share an id into a single link for hover and click. Pass null for none.
/// C0 controls and DEL in either field are refused before writing.
/// Percent-encode the URI as the spec requires; params must use its grammar,
/// which has no `;`, or `parseHyperlink` reads them back cut at it.
pub fn hyperlinkStart(w: *Writer, uri: []const u8, params: ?[]const u8) strings.TextError!void {
    try strings.writeChecked(&hyperlink_start_checked, w, hyperlinkStartParts(uri, params));
}

/// The bytes of `hyperlinkStart`, once its fields are known to be clean, into
/// a `*Writer` or a `*seq.Count`: the parts the writer copies.
fn spellHyperlinkStart(w: anytype, uri: []const u8, params: ?[]const u8) !void {
    var parts = hyperlinkStartParts(uri, params);
    try w.writeVecAll(&parts);
}

/// The pieces of `hyperlinkStart` in order, handed to a writer together so
/// they are copied in one go; `hyperlink_start_checked` marks the caller's.
fn hyperlinkStartParts(uri: []const u8, params: ?[]const u8) [5][]const u8 {
    return .{ seq.osc ++ "8;", params orelse "", ";", uri, seq.st };
}
const hyperlink_start_checked = [5]bool{ false, true, false, true, false };

/// The pieces of `hyperlink`: its start, the text, its end.
fn hyperlinkParts(text: []const u8, uri: []const u8) [7][]const u8 {
    return hyperlinkStartParts(uri, null) ++ [_][]const u8{ text, hyperlink_end };
}
const hyperlink_checked = hyperlink_start_checked ++ [_]bool{ true, false };

const hyperlink_end = seq.osc ++ "8;;" ++ seq.st;

/// Closes the hyperlink opened by `hyperlinkStart`: `OSC 8 ; ; ST`. Cells
/// written after this one carry no link.
pub fn hyperlinkEnd(w: *Writer) Writer.Error!void {
    try spellHyperlinkEnd(w);
}

/// The bytes of `hyperlinkEnd`, into a `*Writer` or a `*seq.Count`.
fn spellHyperlinkEnd(w: anytype) !void {
    try w.writeAll(hyperlink_end);
}

/// Writes `text` as a hyperlink to `uri`: `hyperlinkStart`, the text, then
/// `hyperlinkEnd`. C0 controls and DEL in either field are refused before
/// writing. Text keeps the attributes set before the call.
pub fn hyperlink(w: *Writer, text: []const u8, uri: []const u8) strings.TextError!void {
    try strings.writeChecked(&hyperlink_checked, w, hyperlinkParts(text, uri));
}

/// The bytes of `hyperlink`, into a `*Writer` or a `*seq.Count`: the parts
/// the writer copies.
fn spellHyperlink(w: anytype, text: []const u8, uri: []const u8) !void {
    var parts = hyperlinkParts(text, uri);
    try w.writeVecAll(&parts);
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
/// with C0 controls and DEL refused before writing. It must be valid UTF-8
/// no longer than `text_size_max` bytes; those two limits are not checked.
///
/// Read against the protocol text of 2026-09-18.
pub fn textSize(w: *Writer, size: TextSize, text: []const u8) strings.TextError!void {
    try strings.checkText(text);
    try spellTextSize(w, size, text);
}

/// The bytes of `textSize`, once the text is known to be clean, into a
/// `*Writer` or a `*seq.Count`.
fn spellTextSize(w: anytype, size: TextSize, text: []const u8) !void {
    try w.writeAll(seq.osc ++ "66;");

    var any = false;
    if (size.scale > 1) try writeSizeKey(w, &any, 's', size.scale);
    if (size.width != 0) try writeSizeKey(w, &any, 'w', size.width);
    if (size.numerator != 0) try writeSizeKey(w, &any, 'n', size.numerator);
    if (size.denominator != 0) try writeSizeKey(w, &any, 'd', size.denominator);
    if (size.vertical != .top) try writeSizeKey(w, &any, 'v', @backingInt(size.vertical));
    if (size.horizontal != .left) try writeSizeKey(w, &any, 'h', @backingInt(size.horizontal));

    try w.writeByte(';');
    try w.writeAll(text);
    try w.writeAll(seq.st);
}

/// Writes one metadata key, with the `:` that separates it from the one
/// before.
fn writeSizeKey(w: anytype, any: *bool, name: u8, value: u8) !void {
    if (any.*) try w.writeByte(':');
    any.* = true;
    try w.writeByte(name);
    try w.writeByte('=');
    try seq.writeInt(w, value);
}

/// How many bytes the hyperlink and text-size writers write, given the same
/// arguments less the writer, without writing them.
///
/// Each runs the body its writer spells with into a `seq.Count`, so a count
/// is exactly the length of what the writer writes when it writes at all:
/// the text is counted, not checked, and a writer that refuses text with a
/// control in it writes nothing.
pub const cost = struct {
    /// `hyperlinkStart`: the URI, the params and seven bytes of framing.
    pub fn hyperlinkStart(uri: []const u8, params: ?[]const u8) usize {
        return seq.count(spellHyperlinkStart, .{ uri, params });
    }

    /// `hyperlinkEnd`.
    pub fn hyperlinkEnd() usize {
        return seq.count(spellHyperlinkEnd, .{});
    }

    /// `hyperlink`.
    pub fn hyperlink(text: []const u8, uri: []const u8) usize {
        return seq.count(spellHyperlink, .{ text, uri });
    }

    /// `textSize`.
    pub fn textSize(size: TextSize, text: []const u8) usize {
        return seq.count(spellTextSize, .{ size, text });
    }
};

//=========================================================================
// Reading OSC 8 and OSC 66 back.
//
// The inverses of the writers above, for a program that reads what a
// terminal is sent: an emulator, a recorder, a test that checks a renderer's
// output. Each takes the body `parseControlString` frames, the bytes between
// `ESC ]` and the terminator, and borrows from it.
//=========================================================================

/// One OSC 8 read back: `8 ; params ; uri`.
pub const Hyperlink = struct {
    /// The `key=value:key=value` list before the URI, as bytes; empty when
    /// there is none. `hyperlinkStart` with null params writes it empty.
    params: []const u8,
    /// The URI. Empty is the end of a link, which is what `hyperlinkEnd`
    /// writes.
    uri: []const u8,
};

/// Reads the body of an OSC 8, or null when it is not one.
///
/// The params end at the first `;` after the `8`, which the spec does not
/// allow in them, and the URI is everything after it, `;` included. Neither
/// field is checked further: a link is acted on as given or not at all, and
/// that is the reader's choice.
pub fn parseHyperlink(body: []const u8) ?Hyperlink {
    const prefix = "8;";
    if (!std.mem.startsWith(u8, body, prefix)) return null;
    const rest = body[prefix.len..];
    const split = std.mem.findScalar(u8, rest, ';') orelse return null;
    return .{ .params = rest[0..split], .uri = rest[split + 1 ..] };
}

/// One OSC 66 read back: `66 ; metadata ; text`.
pub const SizedText = struct {
    /// The size the metadata spells, every key it leaves out at its default.
    size: TextSize,
    /// The text, exactly as it was written, `;` included.
    text: []const u8,
};

/// Reads the body of an OSC 66, or null when it is not one.
///
/// The metadata is a `:`-separated list of `key=value` pairs, each key one
/// lowercase letter and each value a run of decimal digits, no key twice. A
/// key this package does not write is read and ignored, so a key the
/// protocol adds later does not lose the text. A key it does write with a
/// value out of the range `TextSize` holds makes the whole sequence null,
/// as does any metadata outside that grammar: a reader has no size to draw
/// it at. `numerator` above `denominator` is read as written, as
/// `textSize` writes it.
pub fn parseTextSize(body: []const u8) ?SizedText {
    const prefix = "66;";
    if (!std.mem.startsWith(u8, body, prefix)) return null;
    const rest = body[prefix.len..];
    const split = std.mem.findScalar(u8, rest, ';') orelse return null;
    const metadata = rest[0..split];

    var size: TextSize = .{};
    var seen: u32 = 0;
    var pairs = std.mem.splitScalar(u8, metadata, ':');
    while (metadata.len != 0) {
        const pair = pairs.next() orelse break;
        if (pair.len < 3 or pair[1] != '=') return null;
        if (pair[0] < 'a' or pair[0] > 'z') return null;
        const bit = @as(u32, 1) << @intCast(pair[0] - 'a');
        if (seen & bit != 0) return null;
        seen |= bit;
        for (pair[2..]) |b| {
            if (b < '0' or b > '9') return null;
        }
        // Digits only, so the one error left is a value past a byte.
        const value = std.fmt.parseInt(u8, pair[2..], 10) catch return null;
        switch (pair[0]) {
            's' => size.scale = aegis.int.cast(u3, value) catch return null,
            'w' => size.width = aegis.int.cast(u3, value) catch return null,
            'n' => size.numerator = aegis.int.cast(u4, value) catch return null,
            'd' => size.denominator = aegis.int.cast(u4, value) catch return null,
            'v' => size.vertical = std.enums.fromInt(VerticalAlign, value) orelse return null,
            'h' => size.horizontal = std.enums.fromInt(HorizontalAlign, value) orelse return null,
            else => {},
        }
    }
    return .{ .size = size, .text = rest[split + 1 ..] };
}

/// Frames `bytes` as one whole OSC and reads it as an OSC 66: the round
/// trips below go through the framing a reader uses.
fn readTextSize(bytes: []const u8) ?SizedText {
    const string = framing.parseControlString(bytes) orelse return null;
    if (string.introducer != ']' or !string.terminated or string.len != framing.ByteCount.fromRaw(bytes.len)) return null;
    return parseTextSize(string.body);
}

/// The same for an OSC 8.
fn readHyperlink(bytes: []const u8) ?Hyperlink {
    const string = framing.parseControlString(bytes) orelse return null;
    if (string.introducer != ']' or !string.terminated or string.len != framing.ByteCount.fromRaw(bytes.len)) return null;
    return parseHyperlink(string.body);
}

test "a default size writes an empty metadata field" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try textSize(&out.writer, .{}, "hi");
    try std.testing.expectEqualStrings("\x1b]66;;hi\x1b\\", out.written());

    const read = readTextSize(out.written()).?;
    try std.testing.expectEqual(TextSize{}, read.size);
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
        const read = readTextSize(out.written()).?;
        try std.testing.expectEqual(case.size, read.size);
        try std.testing.expectEqualStrings(case.text, read.text);
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

    try std.testing.expectEqual(TextSize{
        .scale = 7,
        .width = 3,
        .numerator = 5,
        .denominator = 15,
        .vertical = .center,
        .horizontal = .right,
    }, readTextSize(out.written()).?.size);
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
                var want = size;
                // Zero and one are both the base size, written as neither.
                if (want.scale == 0) want.scale = 1;
                try std.testing.expectEqual(want, read.size);
                try std.testing.expectEqual(scale > 1, std.mem.find(u8, out.written(), "s=") != null);
                try std.testing.expectEqual(width != 0, std.mem.find(u8, out.written(), "w=") != null);
                try std.testing.expectEqual(vertical != .top, std.mem.find(u8, out.written(), "v=") != null);
            }
            if (width == 7) break;
        }
        if (scale == 7) break;
    }
}

test "parseTextSize returns null on anything it does not recognise" {
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
        "\x1b]66;s=8;x\x1b\\", // a scale past seven
        "\x1b]66;w=8;x\x1b\\", // a width past seven
        "\x1b]66;n=16;x\x1b\\", // a numerator past fifteen
        "\x1b]66;d=99;x\x1b\\", // a denominator past fifteen
        "\x1b]66;v=3;x\x1b\\", // no such vertical alignment
        "\x1b]66;h=3;x\x1b\\", // no such horizontal alignment
        "\x1b]66;s=256;x\x1b\\", // a value past a byte
        "\x1b]66;s=99999999999999999999;x\x1b\\", // a value past any integer
        ":s=2;x", // not an OSC 66 body
    };
    for (rejected) |bytes| try std.testing.expect(readTextSize(bytes) == null);
    for ([_][]const u8{ "", "66", "66;", "6;;x", "66;s=2", " 66;;x" }) |body| {
        try std.testing.expect(parseTextSize(body) == null);
    }
}

test "parseTextSize reads a key it does not write and ignores it" {
    const read = parseTextSize("66;s=2:x=40:w=1;a;b").?;
    try std.testing.expectEqual(TextSize{ .scale = 2, .width = 1 }, read.size);
    try std.testing.expectEqualStrings("a;b", read.text);
    try std.testing.expectEqual(@as(u3, 0), parseTextSize("66;s=0;a").?.size.scale);
    try std.testing.expectEqual(@as(u3, 2), parseTextSize("66;s=0002;a").?.size.scale);
}

test "parseHyperlink reads params before the first semicolon and the URI after it" {
    const cases = [_]struct { body: []const u8, params: []const u8, uri: []const u8 }{
        .{ .body = "8;;https://ziglang.org", .params = "", .uri = "https://ziglang.org" },
        .{ .body = "8;id=log;file:///tmp/log", .params = "id=log", .uri = "file:///tmp/log" },
        .{ .body = "8;;", .params = "", .uri = "" },
        .{ .body = "8;id=a:x=b;https://h/a;b?c=d", .params = "id=a:x=b", .uri = "https://h/a;b?c=d" },
    };
    for (cases) |case| {
        const read = parseHyperlink(case.body).?;
        try std.testing.expectEqualStrings(case.params, read.params);
        try std.testing.expectEqualStrings(case.uri, read.uri);
    }
    for ([_][]const u8{ "", "8", "8;", "8;id=x", "88;;u", "66;;x", "2;title", " 8;;u" }) |body| {
        try std.testing.expect(parseHyperlink(body) == null);
    }
}

test "every hyperlink and sized text the writers write reads back as written" {
    var prng: std.Random.DefaultPrng = .init(0x05c8_66);
    const random = prng.random();
    var buffers: [3][48]u8 = undefined;
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    for (0..20_000) |_| {
        // Every byte a writer accepts: no C0 control and no DEL. A params
        // list holds no `;`, which is what ends it.
        var fields: [3][]const u8 = undefined;
        for (&buffers, &fields, 0..) |*buffer, *field, n| {
            field.* = buffer[0..random.uintLessThan(usize, buffer.len + 1)];
            for (@constCast(field.*)) |*b| {
                b.* = while (true) {
                    const c = random.intRangeAtMost(u8, 0x20, 0xff);
                    if (c == 0x7f or (n == 1 and c == ';')) continue;
                    break c;
                };
            }
        }
        const text, const params, const uri = fields;
        const size: TextSize = .{
            .scale = random.int(u3),
            .width = random.int(u3),
            .numerator = random.int(u4),
            .denominator = random.int(u4),
            .vertical = @fromBackingInt(@intCast(random.uintLessThan(u8, 3))),
            .horizontal = @fromBackingInt(@intCast(random.uintLessThan(u8, 3))),
        };

        out.clearRetainingCapacity();
        try textSize(&out.writer, size, text);
        const sized = readTextSize(out.written()).?;
        var want = size;
        if (want.scale == 0) want.scale = 1;
        try std.testing.expectEqual(want, sized.size);
        try std.testing.expectEqualStrings(text, sized.text);

        out.clearRetainingCapacity();
        const given: ?[]const u8 = if (params.len == 0 and random.boolean()) null else params;
        try hyperlinkStart(&out.writer, uri, given);
        const link = readHyperlink(out.written()).?;
        try std.testing.expectEqualStrings(params, link.params);
        try std.testing.expectEqualStrings(uri, link.uri);

        out.clearRetainingCapacity();
        try hyperlinkEnd(&out.writer);
        const end = readHyperlink(out.written()).?;
        try std.testing.expectEqualStrings("", end.params);
        try std.testing.expectEqualStrings("", end.uri);
    }
}

test "fuzz parseTextSize and parseHyperlink" {
    // The property: no input panics, what it returns borrows from the bytes
    // it was given, and the same bytes read the same way twice. Neither
    // sequence has a reply, so the round trip is against the writers in the
    // test above rather than against a terminal.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [96]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];

            const start = @intFromPtr(bytes.ptr);
            if (parseHyperlink(bytes)) |link| {
                for ([_][]const u8{ link.params, link.uri }) |field| {
                    try std.testing.expect(@intFromPtr(field.ptr) >= start);
                    try std.testing.expect(@intFromPtr(field.ptr) + field.len <= start + bytes.len);
                }
                try std.testing.expectEqual(link, parseHyperlink(bytes).?);
            }
            const read = readTextSize(bytes) orelse return;
            try std.testing.expect(@intFromPtr(read.text.ptr) >= start);
            try std.testing.expect(@intFromPtr(read.text.ptr) + read.text.len <= start + bytes.len);
            try std.testing.expectEqual(read, readTextSize(bytes).?);
        }
    }.one, .{ .corpus = &.{
        corpus.entry("\x1b]66;;hi\x1b\\"),
        corpus.entry("\x1b]66;s=2;Double sized text\x1b\\"),
        corpus.entry("\x1b]66;w=1:n=1:d=2;lf\x1b\\"),
        corpus.entry("\x1b]66;s=7:w=3:n=5:d=15:v=2:h=1;x\x07"),
        corpus.entry("\x1b]66;s=2:s=3;x\x1b\\"),
        corpus.entry("\x1b]66;s=2\x1b\\"),
        corpus.entry("8;id=log;file:///tmp/log"),
        corpus.entry("8;;"),
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

test "OSC caller text refuses every control before writing and preserves UTF-8" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    for (0..128) |n| {
        if (n >= 32 and n != 127) continue;
        var bad = [_]u8{ 'a', @intCast(n), 'b' };
        try std.testing.expectError(error.ControlInText, title(&out.writer, &bad));
        try std.testing.expectError(error.ControlInText, iconName(&out.writer, &bad));
        try std.testing.expectError(error.ControlInText, workingDirectory(&out.writer, &bad));
        try std.testing.expectError(error.ControlInText, hyperlinkStart(&out.writer, &bad, null));
        try std.testing.expectError(error.ControlInText, hyperlinkStart(&out.writer, "uri", &bad));
        try std.testing.expectError(error.ControlInText, hyperlink(&out.writer, &bad, "uri"));
        try std.testing.expectError(error.ControlInText, hyperlink(&out.writer, "text", &bad));
        try std.testing.expectError(error.ControlInText, textSize(&out.writer, .{}, &bad));
        try std.testing.expectEqual(@as(usize, 0), out.written().len);
    }
    const good = "café 🐈";
    try title(&out.writer, good);
    try iconName(&out.writer, good);
    try workingDirectory(&out.writer, good);
    try hyperlinkStart(&out.writer, good, good);
    try hyperlink(&out.writer, good, good);
    try textSize(&out.writer, .{}, good);
    try std.testing.expectEqualStrings(
        "\x1b]2;" ++ good ++ "\x07" ++
            "\x1b]1;" ++ good ++ "\x07" ++
            "\x1b]7;" ++ good ++ "\x1b\\" ++
            "\x1b]8;" ++ good ++ ";" ++ good ++ "\x1b\\" ++
            "\x1b]8;;" ++ good ++ "\x1b\\" ++ good ++ "\x1b]8;;\x1b\\" ++
            "\x1b]66;;" ++ good ++ "\x1b\\",
        out.written(),
    );
}

test "every hyperlink and text-size cost is the length its writer writes" {
    var prng: std.Random.DefaultPrng = .init(0x05c66);
    const random = prng.random();
    var source: [64]u8 = undefined;
    for (&source) |*b| b.* = 'a' + random.uintLessThan(u8, 26);

    var buffer: [256]u8 = undefined;
    for (0..20_000) |_| {
        const uri = source[0..random.uintLessThan(usize, source.len)];
        const text = source[random.uintLessThan(usize, source.len)..];
        const params: ?[]const u8 = if (random.boolean()) null else source[0..random.uintLessThan(usize, 16)];
        const size: TextSize = .{
            .scale = random.int(u3),
            .width = random.int(u3),
            .numerator = random.int(u4),
            .denominator = random.int(u4),
            .vertical = @fromBackingInt(@intCast(random.uintLessThan(u8, 3))),
            .horizontal = @fromBackingInt(@intCast(random.uintLessThan(u8, 3))),
        };

        var w: Writer = .fixed(&buffer);
        try hyperlinkStart(&w, uri, params);
        try std.testing.expectEqual(w.buffered().len, cost.hyperlinkStart(uri, params));

        w = .fixed(&buffer);
        try hyperlinkEnd(&w);
        try std.testing.expectEqual(w.buffered().len, cost.hyperlinkEnd());

        w = .fixed(&buffer);
        try hyperlink(&w, text, uri);
        try std.testing.expectEqual(w.buffered().len, cost.hyperlink(text, uri));

        w = .fixed(&buffer);
        try textSize(&w, size, text);
        try std.testing.expectEqual(w.buffered().len, cost.textSize(size, text));
    }
}

test "every string this package writes frames whole, terminator and all" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try hyperlinkStart(&out.writer, "https://ziglang.org", "id=z");
    try textSize(&out.writer, .{ .scale = 2, .width = 1 }, "Z");
    try title(&out.writer, "a title");
    var rest = out.written();
    var framed: usize = 0;
    while (rest.len != 0) : (framed += 1) {
        const s = framing.parseControlString(rest).?;
        try std.testing.expect(s.terminated);
        rest = rest[s.len.raw()..];
    }
    try std.testing.expectEqual(@as(usize, 3), framed);
}
