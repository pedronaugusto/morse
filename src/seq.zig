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

/// Removes the string terminator from the end of an OSC sequence: `ST`
/// (`ESC \`) or the legacy `BEL`.
///
/// Returns null when neither is there, so a reply cut short by a short read
/// is never mistaken for a complete one.
pub fn stripStringTerminator(bytes: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, bytes, st)) return bytes[0 .. bytes.len - st.len];
    if (bytes.len != 0 and bytes[bytes.len - 1] == bel) return bytes[0 .. bytes.len - 1];
    return null;
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

test "stripStringTerminator accepts ST and BEL and nothing else" {
    try std.testing.expectEqualStrings("body", stripStringTerminator("body\x1b\\").?);
    try std.testing.expectEqualStrings("body", stripStringTerminator("body\x07").?);
    try std.testing.expectEqualStrings("", stripStringTerminator("\x1b\\").?);
    try std.testing.expect(stripStringTerminator("body") == null);
    try std.testing.expect(stripStringTerminator("body\x1b") == null);
    try std.testing.expect(stripStringTerminator("") == null);
}
