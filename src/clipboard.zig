//! OSC 52: reading and writing the terminal's selections, including the
//! system clipboard of the machine a terminal is running on — which is what
//! makes it worth the trouble over a remote session.
//!
//! The payload is base64, spelled by `base64.zig`, which streams it three
//! input bytes at a time straight into the writer: no buffer is sized to the
//! data and no allocator is involved. The decoder writes into a buffer the
//! caller owns and sizes from `ClipboardReply.decodedLen`.
//!
//! What this file holds is the OSC 52 grammar and the twelve selections it
//! addresses. It will never hold a selection cache, a paste policy, or a
//! guess at what the terminal did with the request: OSC 52 is write-only on
//! most terminals and silent on the rest, and there is nothing here that can
//! tell the difference.

const std = @import("std");
const base64 = @import("base64.zig");
const corpus = @import("corpus.zig");
const seq = @import("seq.zig");

const Writer = std.Io.Writer;

/// The selection an OSC 52 sequence addresses.
///
/// Each spells itself as one byte on the wire, as xterm documents. A terminal
/// that does not implement a selection ignores sequences naming it, so asking
/// for `.primary` on a platform without X11 is harmless rather than an error.
pub const Clipboard = enum {
    /// The system clipboard (`c`) — the one a paste command reads. The only
    /// selection many terminals implement, and the right default.
    clipboard,
    /// The X11 primary selection (`p`), pasted with the middle mouse button.
    primary,
    /// The X11 secondary selection (`q`).
    secondary,
    /// Whichever selection the terminal is configured to treat as the
    /// current one (`s`).
    select,
    /// Cut buffer 0 (`0`), the first of xterm's eight numbered cut buffers.
    cut_buffer_0,
    /// Cut buffer 1 (`1`).
    cut_buffer_1,
    /// Cut buffer 2 (`2`).
    cut_buffer_2,
    /// Cut buffer 3 (`3`).
    cut_buffer_3,
    /// Cut buffer 4 (`4`).
    cut_buffer_4,
    /// Cut buffer 5 (`5`).
    cut_buffer_5,
    /// Cut buffer 6 (`6`).
    cut_buffer_6,
    /// Cut buffer 7 (`7`).
    cut_buffer_7,

    /// The byte this selection is spelled with on the wire.
    pub fn char(target: Clipboard) u8 {
        return switch (target) {
            .clipboard => 'c',
            .primary => 'p',
            .secondary => 'q',
            .select => 's',
            .cut_buffer_0 => '0',
            .cut_buffer_1 => '1',
            .cut_buffer_2 => '2',
            .cut_buffer_3 => '3',
            .cut_buffer_4 => '4',
            .cut_buffer_5 => '5',
            .cut_buffer_6 => '6',
            .cut_buffer_7 => '7',
        };
    }

    /// The selection a wire byte names, or null if it names none.
    pub fn fromChar(c: u8) ?Clipboard {
        return switch (c) {
            'c' => .clipboard,
            'p' => .primary,
            'q' => .secondary,
            's' => .select,
            '0' => .cut_buffer_0,
            '1' => .cut_buffer_1,
            '2' => .cut_buffer_2,
            '3' => .cut_buffer_3,
            '4' => .cut_buffer_4,
            '5' => .cut_buffer_5,
            '6' => .cut_buffer_6,
            '7' => .cut_buffer_7,
            else => null,
        };
    }
};

/// Puts `bytes` on `target`: `OSC 52 ; target ; <base64 of bytes> ST`.
///
/// The base64 is written in three-byte groups as it goes, so this allocates
/// nothing and needs no scratch buffer however long `bytes` is. Terminals cap
/// what they will accept — a few kilobytes is typical — and drop a longer
/// sequence without saying so, which no writer here can detect.
pub fn clipboardWrite(w: *Writer, target: Clipboard, bytes: []const u8) Writer.Error!void {
    try w.writeAll(seq.osc ++ "52;");
    try w.writeByte(target.char());
    try w.writeByte(';');
    try base64.write(w, bytes);
    try w.writeAll(seq.st);
}

/// Asks the terminal for the contents of `target`: `OSC 52 ; target ; ? ST`.
///
/// The answer arrives on the terminal's input as a sequence
/// `parseClipboardReply` reads. Many terminals refuse to answer this by
/// default, because it lets any program that can write to the terminal read
/// what the user last copied; a program must be prepared for no reply at all.
pub fn clipboardRequest(w: *Writer, target: Clipboard) Writer.Error!void {
    try w.writeAll(seq.osc ++ "52;");
    try w.writeByte(target.char());
    try w.writeAll(";?" ++ seq.st);
}

/// A terminal's answer to `clipboardRequest`, still in base64.
pub const ClipboardReply = struct {
    /// The selection the terminal answered for. When the reply names several
    /// selections, this is the first.
    target: Clipboard,
    /// The base64 payload, verified well-formed by `parseClipboardReply`.
    ///
    /// A sub-slice of the bytes handed to that function, borrowed rather than
    /// owned: it is valid for exactly as long as they are.
    ///
    /// `decodedLen` and `decodeClipboard` take that verification as a
    /// precondition, so a `ClipboardReply` built by hand must hold padded
    /// standard base64 and nothing else.
    data: []const u8,

    /// The exact number of bytes `decodeClipboard` will write.
    ///
    /// Exact, not an upper bound: `parseClipboardReply` has already
    /// established that `data` is well-formed base64.
    pub fn decodedLen(reply: ClipboardReply) usize {
        return base64.decodedLen(reply.data);
    }
};

/// Reads a reply to `clipboardRequest`: `OSC 52 ; target ; <base64> ST`, or
/// the same sequence terminated by `BEL`.
///
/// Returns null for anything else, malformed base64 included, and never an
/// error. `bytes` must be the whole sequence and nothing more, so a caller
/// splitting an input stream has already decided where the sequence ends.
/// The returned `data` borrows from `bytes`.
pub fn parseClipboardReply(bytes: []const u8) ?ClipboardReply {
    const prefix = seq.osc ++ "52;";
    if (!std.mem.startsWith(u8, bytes, prefix)) return null;
    const body = seq.stripStringTerminator(bytes[prefix.len..]) orelse return null;

    // The spec allows the selection field to name more than one selection, so
    // it is a run of selection bytes rather than a single one.
    const separator = std.mem.indexOfScalar(u8, body, ';') orelse return null;
    const selections = body[0..separator];
    if (selections.len == 0) return null;
    for (selections) |c| {
        if (Clipboard.fromChar(c) == null) return null;
    }

    const data = body[separator + 1 ..];
    if (!base64.isValid(data)) return null;
    return .{ .target = Clipboard.fromChar(selections[0]).?, .data = data };
}

/// Decodes `reply`'s payload into `out` and returns the prefix of `out` that
/// was written — always exactly `reply.decodedLen()` bytes.
///
/// `out` stays the caller's; nothing is allocated. The only failure is an
/// `out` too small, which `reply.decodedLen()` lets a caller rule out before
/// calling.
pub fn decodeClipboard(reply: ClipboardReply, out: []u8) error{NoSpaceLeft}![]u8 {
    return base64.decode(reply.data, out);
}

test "clipboardWrite encodes a two-byte payload" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try clipboardWrite(&out.writer, .clipboard, "hi");
    try std.testing.expectEqualStrings("\x1b]52;c;aGk=\x1b\\", out.written());
}

test "clipboardWrite pads every length of tail" {
    const cases = [_]struct { plain: []const u8, encoded: []const u8 }{
        .{ .plain = "", .encoded = "" },
        .{ .plain = "f", .encoded = "Zg==" },
        .{ .plain = "fo", .encoded = "Zm8=" },
        .{ .plain = "foo", .encoded = "Zm9v" },
        .{ .plain = "foob", .encoded = "Zm9vYg==" },
        .{ .plain = "fooba", .encoded = "Zm9vYmE=" },
        .{ .plain = "foobar", .encoded = "Zm9vYmFy" },
    };
    for (cases) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();

        try clipboardWrite(&out.writer, .clipboard, case.plain);
        const written = out.written();
        try std.testing.expectEqualStrings("\x1b]52;c;", written[0..7]);
        try std.testing.expectEqualStrings(case.encoded, written[7 .. written.len - 2]);
        try std.testing.expectEqualStrings("\x1b\\", written[written.len - 2 ..]);
    }
}

test "clipboardWrite agrees with the standard library encoder on every byte" {
    var plain: [256]u8 = undefined;
    for (&plain, 0..) |*byte, i| byte.* = @intCast(i);

    // Every length, so each of the three tail shapes is exercised against an
    // independent implementation rather than against a literal.
    var expected: [std.base64.standard.Encoder.calcSize(plain.len)]u8 = undefined;
    for (0..plain.len + 1) |len| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();

        try clipboardWrite(&out.writer, .primary, plain[0..len]);
        const written = out.written();
        try std.testing.expectEqualStrings("\x1b]52;p;", written[0..7]);
        try std.testing.expectEqualStrings(
            std.base64.standard.Encoder.encode(&expected, plain[0..len]),
            written[7 .. written.len - 2],
        );
    }
}

test "clipboardWrite streams past the writer's buffer without a scratch buffer" {
    // The payload is far larger than the writer's buffer, so the drain path
    // runs many times mid-encode.
    const plain = "0123456789abcdef" ** 512;
    var backing: [64]u8 = undefined;
    var counting: Writer.Discarding = .init(&backing);

    try clipboardWrite(&counting.writer, .clipboard, plain);
    const body = 7 + std.base64.standard.Encoder.calcSize(plain.len) + 2;
    try std.testing.expectEqual(@as(u64, body), counting.fullCount());
}

test "every selection spells itself and reads back" {
    for (std.meta.tags(Clipboard)) |target| {
        try std.testing.expectEqual(target, Clipboard.fromChar(target.char()).?);
    }
    try std.testing.expect(Clipboard.fromChar('z') == null);
    try std.testing.expect(Clipboard.fromChar('8') == null);
}

test "clipboardRequest asks with a question mark" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try clipboardRequest(&out.writer, .clipboard);
    try std.testing.expectEqualStrings("\x1b]52;c;?\x1b\\", out.written());
}

test "parseClipboardReply reads a reply and decodes it into a caller buffer" {
    const reply = parseClipboardReply("\x1b]52;c;aGk=\x1b\\").?;
    try std.testing.expectEqual(Clipboard.clipboard, reply.target);
    try std.testing.expectEqualStrings("aGk=", reply.data);
    try std.testing.expectEqual(@as(usize, 2), reply.decodedLen());

    var buffer: [8]u8 = undefined;
    try std.testing.expectEqualStrings("hi", try decodeClipboard(reply, &buffer));
}

test "parseClipboardReply accepts a BEL terminator and a multi-selection field" {
    const reply = parseClipboardReply("\x1b]52;pc;Zm9v\x07").?;
    try std.testing.expectEqual(Clipboard.primary, reply.target);
    try std.testing.expectEqualStrings("Zm9v", reply.data);

    var buffer: [8]u8 = undefined;
    try std.testing.expectEqualStrings("foo", try decodeClipboard(reply, &buffer));
}

test "parseClipboardReply accepts an empty selection payload" {
    const reply = parseClipboardReply("\x1b]52;c;\x1b\\").?;
    try std.testing.expectEqual(@as(usize, 0), reply.decodedLen());

    var buffer: [1]u8 = undefined;
    try std.testing.expectEqualStrings("", try decodeClipboard(reply, &buffer));
}

test "parseClipboardReply returns null on anything it does not recognise" {
    const rejected = [_][]const u8{
        "", // nothing at all
        "\x1b]52;c;aGk=", // no terminator
        "\x1b]52;c;aGk=\x1b", // terminator cut in half
        "\x1b]52;c;aGk=\x1b]", // wrong terminator
        "\x1b]5;c;aGk=\x1b\\", // a different OSC
        "\x1b[52;c;aGk=\x1b\\", // CSI, not OSC
        "\x1b]52;c;?\x1b\\", // the request, not a reply
        "\x1b]52;z;aGk=\x1b\\", // no such selection
        "\x1b]52;;aGk=\x1b\\", // empty selection field
        "\x1b]52;caGk=\x1b\\", // no separator
        "\x1b]52;c;aGk\x1b\\", // length not a multiple of four
        "\x1b]52;c;a*k=\x1b\\", // not an alphabet character
        "\x1b]52;c;a=k=\x1b\\", // padding in the middle
        "\x1b]52;c;====\x1b\\", // padding only
        "\x1b]52;c;aB==\x1b\\", // bits padding would discard
        "\x1b]52;c;aGl=\x1b\\", // bits padding would discard
    };
    for (rejected) |bytes| {
        try std.testing.expect(parseClipboardReply(bytes) == null);
    }
}

test "decodeClipboard refuses a buffer that is too small" {
    const reply = parseClipboardReply("\x1b]52;c;Zm9vYmFy\x1b\\").?;
    try std.testing.expectEqual(@as(usize, 6), reply.decodedLen());

    var small: [5]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, decodeClipboard(reply, &small));

    var exact: [6]u8 = undefined;
    try std.testing.expectEqualStrings("foobar", try decodeClipboard(reply, &exact));
}

test "a clipboard round trip preserves every byte" {
    var plain: [193]u8 = undefined;
    for (&plain, 0..) |*byte, i| byte.* = @truncate(i *% 7 +% 3);

    for (0..plain.len + 1) |len| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();

        try clipboardWrite(&out.writer, .select, plain[0..len]);
        const reply = parseClipboardReply(out.written()).?;
        try std.testing.expectEqual(Clipboard.select, reply.target);
        try std.testing.expectEqual(len, reply.decodedLen());

        var decoded: [plain.len]u8 = undefined;
        try std.testing.expectEqualSlices(u8, plain[0..len], try decodeClipboard(reply, &decoded));
    }
}

test "fuzz parseClipboardReply and decodeClipboard" {
    // The property: no input panics or overflows; a payload the parser accepts
    // decodes into exactly `decodedLen` bytes; and re-encoding those bytes
    // reproduces a reply that decodes to the same bytes again. The parser's
    // promise -- that what it returns is base64 `decodeClipboard` cannot fail
    // on -- is the one worth holding to an adversary.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [64]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];

            const reply = parseClipboardReply(bytes) orelse return;
            try std.testing.expect(reply.data.len % 4 == 0);

            const len = reply.decodedLen();
            try std.testing.expect(len <= reply.data.len / 4 * 3);

            var decoded: [48]u8 = undefined;
            const plain = try decodeClipboard(reply, &decoded);
            try std.testing.expectEqual(len, plain.len);

            var output: [128]u8 = undefined;
            var w: Writer = .fixed(&output);
            try clipboardWrite(&w, reply.target, plain);

            const again = parseClipboardReply(w.buffered()).?;
            try std.testing.expectEqual(reply.target, again.target);
            try std.testing.expectEqualStrings(reply.data, again.data);

            var redecoded: [48]u8 = undefined;
            try std.testing.expectEqualSlices(u8, plain, try decodeClipboard(again, &redecoded));
        }
    }.one, .{ .corpus = &.{
        corpus.seed("\x1b]52;c;aGk=\x1b\\"),
        corpus.seed("\x1b]52;p;Zm9vYmFy\x07"),
        corpus.seed("\x1b]52;pc;\x1b\\"),
        corpus.seed("\x1b]52;7;Zg==\x1b\\"),
        corpus.seed("\x1b]52;c;?\x1b\\"),
        corpus.seed("\x1b]52;c;aB==\x1b\\"),
        corpus.seed("\x1b]52;c;a=k=\x1b\\"),
        corpus.seed("\x1b]52;z;aGk=\x1b\\"),
        corpus.seed("\x1b]52;c;aGk="),
    } });
}
