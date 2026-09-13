//! Seed inputs for the fuzz tests.
//!
//! Test support only: nothing here is re-exported by `morse.zig`, and nothing
//! outside a `test` block references it, so it is never compiled into a
//! consuming program.

const std = @import("std");

/// Wraps a sequence as one corpus entry for `std.testing.Smith.sliceWithHash`,
/// which reads a little-endian `u32` length before the bytes themselves.
///
/// Without the prefix a corpus entry is read as a length and then truncated,
/// which is a silently useless seed rather than a failure — hence this rather
/// than a literal in each list.
pub fn seed(comptime bytes: []const u8) []const u8 {
    const prefix = [4]u8{
        @truncate(bytes.len),
        @truncate(bytes.len >> 8),
        @truncate(bytes.len >> 16),
        @truncate(bytes.len >> 24),
    };
    return prefix ++ bytes;
}

test "a seeded entry is its length and then itself" {
    try std.testing.expectEqualStrings("\x03\x00\x00\x00abc", seed("abc"));
    try std.testing.expectEqualStrings("\x00\x00\x00\x00", seed(""));
}
