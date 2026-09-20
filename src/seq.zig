//! The introducers and terminators every sequence in this package is built
//! from, and the two scanners its parsers share.
//!
//! Nothing here is re-exported by `morse.zig`: a caller who wants to write a
//! sequence this package does not name is better served by `setMode` or by
//! writing the bytes directly than by a half-typed byte vocabulary.

const std = @import("std");

/// `ESC` (0x1b), the first byte of every sequence this package writes.
pub const esc: u8 = 0x1b;

/// `BEL` (0x07), the legacy string terminator xterm accepts at the end of an
/// OSC sequence, and the one `title` writes because some terminals accept
/// nothing else there.
pub const bel: u8 = 0x07;

/// `ST`, the string terminator, spelled `ESC \`. The form this package writes
/// everywhere it has a choice, and the one its parsers prefer.
pub const st = "\x1b\\";

/// `CSI`, the control sequence introducer, spelled `ESC [`.
pub const csi = "\x1b[";

/// `OSC`, the operating system command introducer, spelled `ESC ]`.
pub const osc = "\x1b]";

/// `DCS`, the device control string introducer, spelled `ESC P`. This package
/// writes one DCS -- the XTGETTCAP query -- and reads two, that query's reply
/// and the XTVERSION one.
pub const dcs = "\x1bP";

/// `APC`, the application program command introducer, spelled `ESC _`. The
/// kitty graphics protocol is the only thing this package spells with it, on
/// both sides of the wire.
pub const apc = "\x1b_";

/// Writes `value` in decimal, without the formatter.
///
/// Every sequence here is digits and punctuation, and the digits are the
/// whole of the arithmetic: a renderer writing a frame calls this a few
/// thousand times. It fills a stack buffer from the back and writes the run
/// once, which is one pass, one call and no comptime format machinery.
///
/// `u64` so that every unsigned type in the package coerces to it. The
/// buffer is twenty digits, which is the widest a `u64` spells.
pub fn writeInt(w: *std.Io.Writer, value: u64) std.Io.Writer.Error!void {
    var buffer: [20]u8 = undefined;
    var i: usize = buffer.len;
    var rest = value;
    while (true) {
        i -= 1;
        buffer[i] = '0' + @as(u8, @intCast(rest % 10));
        rest /= 10;
        if (rest == 0) break;
    }
    try w.writeAll(buffer[i..]);
}

/// Writes `value` in decimal with a leading `-` when it is negative.
///
/// The negation goes through `i64` because `-minInt(i32)` does not fit in an
/// `i32`, and the z-index of a graphics placement is a full `i32`.
pub fn writeSigned(w: *std.Io.Writer, value: i32) std.Io.Writer.Error!void {
    if (value < 0) {
        try w.writeByte('-');
        return writeInt(w, @intCast(-@as(i64, value)));
    }
    return writeInt(w, @intCast(value));
}

/// Writes exactly `digits` lowercase hexadecimal digits of `value`.
///
/// Two digits for a byte of an XTGETTCAP name, four for a channel of an OSC
/// colour: the two spellings of hex in the package, in one place.
pub fn writeHex(w: *std.Io.Writer, value: u64, comptime digits: usize) std.Io.Writer.Error!void {
    var buffer: [digits]u8 = undefined;
    var i: usize = digits;
    var rest = value;
    while (i != 0) {
        i -= 1;
        buffer[i] = "0123456789abcdef"[@as(usize, @intCast(rest & 0xf))];
        rest >>= 4;
    }
    try w.writeAll(&buffer);
}

/// A decimal number read off the front of a byte string, and how many bytes
/// it took.
pub fn Scan(comptime T: type) type {
    return struct {
        /// The value the digits spelled.
        value: T,
        /// How many bytes were consumed. Always at least one.
        len: usize,
    };
}

/// Reads a run of ASCII digits from the front of `bytes` as a `T`.
///
/// Returns null when `bytes` does not start with a digit, and null rather
/// than a wrapped value when the digits do not fit in `T` — a reply carrying
/// a forty-digit number is not a number this package hands back.
pub fn scanInt(comptime T: type, bytes: []const u8) ?Scan(T) {
    var value: T = 0;
    var len: usize = 0;
    while (len < bytes.len and bytes[len] >= '0' and bytes[len] <= '9') : (len += 1) {
        value = std.math.mul(T, value, 10) catch return null;
        value = std.math.add(T, value, @as(T, bytes[len] - '0')) catch return null;
    }
    if (len == 0) return null;
    return .{ .value = value, .len = len };
}

/// Reads a parameter that the terminal was allowed to leave out.
///
/// ECMA-48 says an omitted parameter takes its default value, and terminals
/// use that: a real DA1 reply is `CSI ? 62 ; 52 ; c`, three parameters with
/// the last of them omitted, and a parser that insists on digits there
/// refuses the common reply every startup probe asks for. Strictness is right
/// for a writer, which chooses what it sends, and wrong for a parser of
/// somebody else's output.
///
/// Returns a zero-length scan carrying `default` when there are no digits,
/// and null only when there are digits that do not fit in `T` — a reply
/// carrying a forty-digit number is still not a number this package hands
/// back. The separators stay compulsory: an empty parameter is a parameter,
/// and a missing `;` is a reply of a different shape.
pub fn scanParam(comptime T: type, bytes: []const u8, default: T) ?Scan(T) {
    if (bytes.len != 0 and bytes[0] >= '0' and bytes[0] <= '9') return scanInt(T, bytes);
    return .{ .value = default, .len = 0 };
}

/// Removes the string terminator from the end of an OSC sequence: `ST`
/// (`ESC \`) or the legacy `BEL`.
///
/// Returns null when neither is there, so a reply cut short by a short read
/// is never mistaken for a complete one.
pub fn stripStringTerminator(bytes: []const u8) ?[]const u8 {
    const body = if (std.mem.endsWith(u8, bytes, st))
        bytes[0 .. bytes.len - st.len]
    else if (bytes.len != 0 and bytes[bytes.len - 1] == bel)
        bytes[0 .. bytes.len - 1]
    else
        return null;

    // Either byte ends or abandons a control string. Seeing one in the body
    // means the final terminator belongs to a later sequence.
    if (std.mem.indexOfScalar(u8, body, bel) != null) return null;
    if (std.mem.indexOfScalar(u8, body, esc) != null) return null;
    return body;
}

test "writeInt spells every value the sequences carry" {
    const cases = [_]struct { value: u64, bytes: []const u8 }{
        .{ .value = 0, .bytes = "0" },
        .{ .value = 1, .bytes = "1" },
        .{ .value = 9, .bytes = "9" },
        .{ .value = 10, .bytes = "10" },
        .{ .value = 255, .bytes = "255" },
        .{ .value = 65535, .bytes = "65535" },
        .{ .value = 4294967295, .bytes = "4294967295" },
        .{ .value = std.math.maxInt(u64), .bytes = "18446744073709551615" },
    };
    for (cases) |case| {
        var buffer: [24]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buffer);
        try writeInt(&w, case.value);
        try std.testing.expectEqualStrings(case.bytes, w.buffered());
    }
}

test "writeInt agrees with the formatter on every value to ten thousand" {
    var value: u64 = 0;
    while (value < 10_000) : (value += 1) {
        var mine: [24]u8 = undefined;
        var theirs: [24]u8 = undefined;
        var a: std.Io.Writer = .fixed(&mine);
        var b: std.Io.Writer = .fixed(&theirs);
        try writeInt(&a, value);
        try b.print("{d}", .{value});
        try std.testing.expectEqualStrings(b.buffered(), a.buffered());
    }
}

test "writeSigned writes the sign and the digits, the smallest i32 included" {
    const cases = [_]struct { value: i32, bytes: []const u8 }{
        .{ .value = 0, .bytes = "0" },
        .{ .value = 7, .bytes = "7" },
        .{ .value = -1, .bytes = "-1" },
        .{ .value = -1024, .bytes = "-1024" },
        .{ .value = std.math.maxInt(i32), .bytes = "2147483647" },
        .{ .value = std.math.minInt(i32), .bytes = "-2147483648" },
    };
    for (cases) |case| {
        var buffer: [16]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buffer);
        try writeSigned(&w, case.value);
        try std.testing.expectEqualStrings(case.bytes, w.buffered());
    }
}

test "writeHex pads to the width it was asked for" {
    var buffer: [8]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try writeHex(&w, 0x0a, 2);
    try writeHex(&w, 0xff, 2);
    try std.testing.expectEqualStrings("0aff", w.buffered());

    var wide: [8]u8 = undefined;
    var v: std.Io.Writer = .fixed(&wide);
    try writeHex(&v, 0x1c1c, 4);
    try std.testing.expectEqualStrings("1c1c", v.buffered());
}

test "writeInt refuses to fit where there is no room" {
    var buffer: [2]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.WriteFailed, writeInt(&w, 1000));
}

test "scanInt reads digits and reports how many it used" {
    const scan = scanInt(u32, "1234;5").?;
    try std.testing.expectEqual(@as(u32, 1234), scan.value);
    try std.testing.expectEqual(@as(usize, 4), scan.len);
}

test "scanInt refuses a value too large for its type" {
    try std.testing.expectEqual(@as(?Scan(u16), null), scanInt(u16, "65536"));
    try std.testing.expectEqual(@as(u16, 65535), scanInt(u16, "65535").?.value);
    try std.testing.expectEqual(@as(?Scan(u32), null), scanInt(u32, "99999999999999999999"));
}

test "scanInt refuses a string that does not start with a digit" {
    try std.testing.expectEqual(@as(?Scan(u32), null), scanInt(u32, ""));
    try std.testing.expectEqual(@as(?Scan(u32), null), scanInt(u32, ";1"));
    try std.testing.expectEqual(@as(?Scan(u32), null), scanInt(u32, "-1"));
}

test "scanParam takes the default where the terminal left the digits out" {
    const absent = scanParam(u16, ";1c", 0).?;
    try std.testing.expectEqual(@as(u16, 0), absent.value);
    try std.testing.expectEqual(@as(usize, 0), absent.len);

    const end = scanParam(u16, "", 1).?;
    try std.testing.expectEqual(@as(u16, 1), end.value);
    try std.testing.expectEqual(@as(usize, 0), end.len);

    const present = scanParam(u16, "62;", 0).?;
    try std.testing.expectEqual(@as(u16, 62), present.value);
    try std.testing.expectEqual(@as(usize, 2), present.len);

    // Digits that do not fit are still a reject, not a default.
    try std.testing.expectEqual(@as(?Scan(u16), null), scanParam(u16, "65536", 0));
}

test "stripStringTerminator accepts ST and BEL and nothing else" {
    try std.testing.expectEqualStrings("body", stripStringTerminator("body\x1b\\").?);
    try std.testing.expectEqualStrings("body", stripStringTerminator("body\x07").?);
    try std.testing.expectEqualStrings("", stripStringTerminator("\x1b\\").?);
    try std.testing.expect(stripStringTerminator("body") == null);
    try std.testing.expect(stripStringTerminator("body\x1b") == null);
    try std.testing.expect(stripStringTerminator("") == null);
    try std.testing.expect(stripStringTerminator("one\x07two\x1b\\") == null);
    try std.testing.expect(stripStringTerminator("one\x1b\\two\x1b\\") == null);
}
