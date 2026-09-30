//! Text carried inside terminal control strings.
const std = @import("std");

/// A string writer can fail to write, or refuse unsafe caller text.
pub const Error = std.Io.Writer.Error || error{ControlInText};

/// Refuses C0 controls (0x00–0x1f) and DEL (0x7f). No text is edited.
pub fn checkText(text: []const u8) error{ControlInText}!void {
    for (text) |b| if (b < 0x20 or b == 0x7f) return error.ControlInText;
}

/// Explicitly strips C0 controls and DEL into `out`, preserving every other
/// byte, including UTF-8. The returned slice borrows `out`; no allocation.
/// `NoSpaceLeft` is returned before changing `out` when it cannot fit.
/// `out` may be the same buffer as `text`, for stripping in place.
pub fn printable(out: []u8, text: []const u8) error{NoSpaceLeft}![]u8 {
    var needed: usize = 0;
    for (text) |b| if (b >= 0x20 and b != 0x7f) {
        needed += 1;
    };
    if (out.len < needed) return error.NoSpaceLeft;
    var n: usize = 0;
    for (text) |b| {
        if (b < 0x20 or b == 0x7f) continue;
        out[n] = b;
        n += 1;
    }
    return out[0..n];
}

test "printable strips controls explicitly and preserves UTF-8, including in place" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("café 🐈", try printable(&buf, "\x00café\x1b 🐈\x07\x7f"));
    var inplace = "a\x1bb\x07c".*;
    try std.testing.expectEqualStrings("abc", try printable(&inplace, &inplace));
    var short = [_]u8{99};
    try std.testing.expectError(error.NoSpaceLeft, printable(&short, "ab"));
    try std.testing.expectEqual(@as(u8, 99), short[0]);
}
