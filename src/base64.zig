//! Padded standard base64, in the one shape this package needs it: encoded
//! straight into a writer, and decoded into a buffer the caller owns.
//!
//! Two sequences carry base64 payloads — the OSC 52 clipboard and the kitty
//! graphics transmit — and they carry a lot of it: a clipboard is as long as
//! whatever the user copied and an image is a megabyte. So the encoder writes
//! into the writer's own buffer, and the decoder writes into memory the
//! caller already had.
//!
//! Nothing here is re-exported by `morse.zig`. A caller who wants base64 has
//! it in the standard library; this exists so the two sequences above spell
//! it once between them.

const std = @import("std");

const Writer = std.Io.Writer;

/// The sixty-four characters, in their standard order.
pub const alphabet = std.base64.standard_alphabet_chars;

/// Sentinel for a byte that is not in the alphabet.
pub const invalid: u8 = 0xff;

/// The reverse of `alphabet`: a byte to its six bits, or `invalid`.
pub const index: [256]u8 = blk: {
    var table = [_]u8{invalid} ** 256;
    for (alphabet, 0..) |c, i| table[c] = i;
    break :blk table;
};

/// How many base64 characters `len` input bytes encode to, padding included.
pub fn encodedLen(len: usize) usize {
    return (len + 2) / 3 * 4;
}

/// Writes `bytes` as padded standard base64, with no buffer proportional to
/// the input and no allocator.
///
/// The characters are encoded straight into the writer's buffer, as many
/// whole groups as it has room for at a time, and the buffer is drained only
/// when it is full. A writer with a buffer too small for one group goes
/// through a block on the stack instead.
pub fn write(w: *Writer, bytes: []const u8) Writer.Error!void {
    var i: usize = 0;
    while (bytes.len - i >= 3) {
        const groups_left = (bytes.len - i) / 3;
        if (w.buffer.len < 4) {
            var block: [1024]u8 = undefined;
            const groups: usize = @min(groups_left, block.len / 4);
            encodeGroups(block[0 .. groups * 4], bytes[i..][0 .. groups * 3]);
            try w.writeAll(block[0 .. groups * 4]);
            i += groups * 3;
            continue;
        }
        const dest = try w.writableSliceGreedy(4);
        const groups: usize = @min(groups_left, dest.len / 4);
        encodeGroups(dest[0 .. groups * 4], bytes[i..][0 .. groups * 3]);
        w.advance(groups * 4);
        i += groups * 3;
    }
    if (i < bytes.len) {
        var group: [4]u8 = undefined;
        try w.writeAll(std.base64.standard.Encoder.encode(&group, bytes[i..]));
    }
}

/// Encodes `src`, whole groups of three bytes, into `dest`, four characters
/// for each. The standard library's encoder reads twelve bytes at a time.
fn encodeGroups(dest: []u8, src: []const u8) void {
    std.debug.assert(src.len % 3 == 0);
    std.debug.assert(dest.len == src.len / 3 * 4);
    _ = std.base64.standard.Encoder.encode(dest, src);
}

/// Whether `data` is padded standard base64 that decodes without loss: a
/// multiple of four bytes, alphabet characters followed by at most two `=`,
/// and no bits set in the final character that padding throws away.
///
/// The last of those is what lets `decode` promise it cannot fail on
/// content.
pub fn isValid(data: []const u8) bool {
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
            if (index[c] == invalid) return false;
        }
    }
    std.debug.assert(padding <= 2);
    return switch (padding) {
        0 => true,
        1 => index[data[data.len - 2]] & 0x03 == 0,
        2 => index[data[data.len - 3]] & 0x0f == 0,
        else => unreachable,
    };
}

/// The exact number of bytes `decode` writes for `data`.
///
/// Exact, not an upper bound, and it assumes `isValid(data)`.
pub fn decodedLen(data: []const u8) usize {
    std.debug.assert(isValid(data));
    std.debug.assert(data.len % 4 == 0);
    if (data.len == 0) return 0;
    var padding: usize = 0;
    if (data[data.len - 1] == '=') padding += 1;
    if (data[data.len - 2] == '=') padding += 1;
    return data.len / 4 * 3 - padding;
}

/// Decodes `data` into `out` and returns the prefix of `out` that was
/// written — always exactly `decodedLen(data)` bytes.
///
/// `out` stays the caller's; nothing is allocated. The only failure is an
/// `out` too small, which `decodedLen` lets a caller rule out in advance.
/// `isValid(data)` is a precondition.
pub fn decode(data: []const u8, out: []u8) error{NoSpaceLeft}![]u8 {
    const len = decodedLen(data);
    if (out.len < len) return error.NoSpaceLeft;

    var accumulator: u32 = 0;
    var bits: u8 = 0;
    var written: usize = 0;
    for (data) |c| {
        if (c == '=') break;
        accumulator = (accumulator << 6) | index[c];
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[written] = @truncate(accumulator >> @intCast(bits));
            written += 1;
        }
        std.debug.assert(bits < 8);
        std.debug.assert(written <= len);
    }
    std.debug.assert(written == len);
    return out[0..len];
}

test "the encoder agrees with the standard library at every tail length" {
    const plain = "the quick brown fox jumps over the lazy dog";
    for (0..plain.len + 1) |len| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try write(&out.writer, plain[0..len]);

        var expected: [std.base64.standard.Encoder.calcSize(plain.len)]u8 = undefined;
        try std.testing.expectEqualStrings(
            std.base64.standard.Encoder.encode(&expected, plain[0..len]),
            out.written(),
        );
        try std.testing.expectEqual(encodedLen(len), out.written().len);
    }
}

/// A writer with a buffer of a chosen size that drains into a list, so the
/// encoder meets a full buffer at every offset.
const Collect = struct {
    writer: Writer,
    out: std.ArrayList(u8) = .empty,

    fn init(buffer: []u8) Collect {
        return .{ .writer = .{ .buffer = buffer, .vtable = &.{ .drain = drain } } };
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const c: *Collect = @alignCast(@fieldParentPtr("writer", w)); // safe: this drain is installed only on a Collect's writer
        c.out.appendSlice(std.testing.allocator, w.buffered()) catch return error.WriteFailed;
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            c.out.appendSlice(std.testing.allocator, bytes) catch return error.WriteFailed;
            n += bytes.len;
        }
        for (0..splat) |_| {
            c.out.appendSlice(std.testing.allocator, data[data.len - 1]) catch return error.WriteFailed;
            n += data[data.len - 1].len;
        }
        return n;
    }
};

test "the encoder writes the same through a buffer of any size, none included" {
    var plain: [3 * 1024 + 2]u8 = undefined;
    for (&plain, 0..) |*b, i| b.* = @truncate(i *% 151 +% 7);
    var expected: [encodedLen(plain.len)]u8 = undefined;
    for ([_]usize{ 0, 1, 3, 4, 5, 7, 64, 1000, 5000 }) |size| {
        for ([_]usize{ 0, 1, 2, 3, 4, 1023, 1024, 1025, plain.len }) |len| {
            var buffer: [5000]u8 = undefined;
            var sink: Collect = .init(buffer[0..size]);
            defer sink.out.deinit(std.testing.allocator);
            // Start mid-buffer, so the first room left is not a whole group.
            if (size > 1) try sink.writer.writeByte('>');
            try write(&sink.writer, plain[0..len]);
            try sink.writer.flush();
            const written = sink.out.items[@intFromBool(size > 1)..];
            try std.testing.expectEqualStrings(std.base64.standard.Encoder.encode(&expected, plain[0..len]), written);
        }
    }
}

test "everything the encoder writes round trips back through the decoder" {
    const plain = "the quick brown fox jumps over the lazy dog";
    for (0..plain.len + 1) |len| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try write(&out.writer, plain[0..len]);

        try std.testing.expect(isValid(out.written()));
        try std.testing.expectEqual(len, decodedLen(out.written()));

        var buffer: [64]u8 = undefined;
        try std.testing.expectEqualStrings(plain[0..len], try decode(out.written(), &buffer));
    }
}

test "isValid refuses everything that is not padded standard base64" {
    const rejected = [_][]const u8{
        "a", // not a multiple of four
        "ab", // not a multiple of four
        "abc", // not a multiple of four
        "ab=c", // padding before the end
        "a=bc", // padding before the end
        "a===", // three pad characters
        "ab-d", // outside the alphabet
        "ab d", // outside the alphabet
        "aB==", // bits the padding would throw away
        "aBC=", // bits the padding would throw away
    };
    for (rejected) |data| try std.testing.expect(!isValid(data));

    try std.testing.expect(isValid(""));
    try std.testing.expect(isValid("aGk="));
    try std.testing.expect(isValid("aGVsbG8="));
    try std.testing.expect(isValid("aGVsbG9v"));
}

test "decode reports a buffer too small and writes nothing" {
    var buffer: [1]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, decode("aGVsbG8=", &buffer));
}

test "a writer with no room left reports the failure" {
    var buffer: [2]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try std.testing.expectError(error.WriteFailed, write(&w, "hi"));
}

comptime {
    std.debug.assert(alphabet.len == 64);
    std.debug.assert(index.len == 256);
    for (alphabet, 0..) |char, i| std.debug.assert(index[char] == i);
}
