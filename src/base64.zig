//! Padded standard base64, in the one shape this package needs it: encoded
//! straight into a writer, and decoded into a buffer the caller owns.
//!
//! Two sequences carry base64 payloads — the OSC 52 clipboard and the kitty
//! graphics transmit — and they carry a lot of it: a clipboard is as long as
//! whatever the user copied and an image is a megabyte. So the encoder never
//! holds more than four output bytes at once, and the decoder writes into
//! memory the caller already had.
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

/// Writes `bytes` as padded standard base64, three input bytes at a time,
/// with no buffer proportional to the input and no allocator.
pub fn write(w: *Writer, bytes: []const u8) Writer.Error!void {
    var group: [4]u8 = undefined;
    var i: usize = 0;
    while (i + 3 <= bytes.len) : (i += 3) {
        const in = bytes[i..][0..3];
        group[0] = alphabet[in[0] >> 2];
        group[1] = alphabet[(in[0] & 0x03) << 4 | in[1] >> 4];
        group[2] = alphabet[(in[1] & 0x0f) << 2 | in[2] >> 6];
        group[3] = alphabet[in[2] & 0x3f];
        try w.writeAll(&group);
    }
    switch (bytes.len - i) {
        0 => {},
        1 => {
            group[0] = alphabet[bytes[i] >> 2];
            group[1] = alphabet[(bytes[i] & 0x03) << 4];
            group[2] = '=';
            group[3] = '=';
            try w.writeAll(&group);
        },
        2 => {
            group[0] = alphabet[bytes[i] >> 2];
            group[1] = alphabet[(bytes[i] & 0x03) << 4 | bytes[i + 1] >> 4];
            group[2] = alphabet[(bytes[i + 1] & 0x0f) << 2];
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
