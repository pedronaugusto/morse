//! Decode a complete UTF-8 sequence through the fixed-size standard APIs.
const std = @import("std");

pub const DecodeError = error{ Utf8ExpectedContinuation, Utf8OverlongEncoding, Utf8EncodesSurrogateHalf, Utf8CodepointTooLarge };

pub fn decode(bytes: []const u8) DecodeError!u21 {
    std.debug.assert(bytes.len >= 1);
    std.debug.assert(bytes.len <= 4);
    return switch (bytes.len) {
        1 => bytes[0],
        2 => std.unicode.utf8Decode2(bytes[0..2].*),
        3 => std.unicode.utf8Decode3(bytes[0..3].*),
        4 => std.unicode.utf8Decode4(bytes[0..4].*),
        else => unreachable,
    };
}
