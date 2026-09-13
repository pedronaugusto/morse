//! OSC 52: reading and writing the terminal's selections, including the
//! system clipboard of the machine a terminal is running on — which is what
//! makes it worth the trouble over a remote session.
//!
//! The payload is base64. The encoder here streams it three input bytes at a
//! time straight into the writer, so no buffer is sized to the data and no
//! allocator is involved; the decoder writes into a buffer the caller owns.

const std = @import("std");
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
    try writeBase64(w, bytes);
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
        std.debug.assert(reply.data.len % 4 == 0);
        if (reply.data.len == 0) return 0;
        var padding: usize = 0;
        if (reply.data[reply.data.len - 1] == '=') padding += 1;
        if (reply.data[reply.data.len - 2] == '=') padding += 1;
        return reply.data.len / 4 * 3 - padding;
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
    if (!isBase64(data)) return null;
    return .{ .target = Clipboard.fromChar(selections[0]).?, .data = data };
}

/// Decodes `reply`'s payload into `out` and returns the prefix of `out` that
/// was written — always exactly `reply.decodedLen()` bytes.
///
/// `out` stays the caller's; nothing is allocated. The only failure is an
/// `out` too small, which `reply.decodedLen()` lets a caller rule out before
/// calling.
pub fn decodeClipboard(reply: ClipboardReply, out: []u8) error{NoSpaceLeft}![]u8 {
    const len = reply.decodedLen();
    if (out.len < len) return error.NoSpaceLeft;

    var accumulator: u32 = 0;
    var bits: u8 = 0;
    var written: usize = 0;
    for (reply.data) |c| {
        if (c == '=') break;
        accumulator = (accumulator << 6) | base64_index[c];
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[written] = @truncate(accumulator >> @intCast(bits));
            written += 1;
        }
    }
    std.debug.assert(written == len);
    return out[0..len];
}

const base64_alphabet = std.base64.standard_alphabet_chars;

/// Sentinel for a byte that is not in the base64 alphabet.
const base64_invalid: u8 = 0xff;

const base64_index: [256]u8 = blk: {
    var table = [_]u8{base64_invalid} ** 256;
    for (base64_alphabet, 0..) |c, i| table[c] = i;
    break :blk table;
};

/// Writes `bytes` as padded standard base64, three input bytes at a time,
/// with no buffer proportional to the input and no allocator.
fn writeBase64(w: *Writer, bytes: []const u8) Writer.Error!void {
    var group: [4]u8 = undefined;
    var i: usize = 0;
    while (i + 3 <= bytes.len) : (i += 3) {
        const in = bytes[i..][0..3];
        group[0] = base64_alphabet[in[0] >> 2];
        group[1] = base64_alphabet[(in[0] & 0x03) << 4 | in[1] >> 4];
        group[2] = base64_alphabet[(in[1] & 0x0f) << 2 | in[2] >> 6];
        group[3] = base64_alphabet[in[2] & 0x3f];
        try w.writeAll(&group);
    }
    switch (bytes.len - i) {
        0 => {},
        1 => {
            group[0] = base64_alphabet[bytes[i] >> 2];
            group[1] = base64_alphabet[(bytes[i] & 0x03) << 4];
            group[2] = '=';
            group[3] = '=';
            try w.writeAll(&group);
        },
        2 => {
            group[0] = base64_alphabet[bytes[i] >> 2];
            group[1] = base64_alphabet[(bytes[i] & 0x03) << 4 | bytes[i + 1] >> 4];
            group[2] = base64_alphabet[(bytes[i + 1] & 0x0f) << 2];
            group[3] = '=';
            try w.writeAll(&group);
        },
        else => unreachable,
    }
}

/// Whether `data` is padded standard base64 that decodes without loss: a
/// multiple of four bytes, alphabet characters followed by at most two `=`,
/// and no bits set in the final character that padding throws away.
///
/// The last of those is what lets `decodeClipboard` promise it cannot fail on
/// content.
fn isBase64(data: []const u8) bool {
    if (data.len % 4 != 0) return false;
    if (data.len == 0) return true;

    var padding: usize = 0;
    for (data, 0..) |c, i| {
        if (c == '=') {
            // Padding is only ever the last byte or the last two.
            if (i + 2 < data.len) return false;
            padding += 1;
        } else {
            if (padding != 0) return false;
            if (base64_index[c] == base64_invalid) return false;
        }
    }
    return switch (padding) {
        0 => true,
        1 => base64_index[data[data.len - 2]] & 0x03 == 0,
        2 => base64_index[data[data.len - 3]] & 0x0f == 0,
        else => unreachable,
    };
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
