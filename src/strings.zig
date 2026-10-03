//! Text carried inside terminal control strings.
const std = @import("std");

const Writer = std.Io.Writer;

/// A string writer can fail to write, or refuse unsafe caller text.
pub const Error = Writer.Error || error{ControlInText};

/// Refuses C0 controls (0x00–0x1f) and DEL (0x7f). No text is edited.
pub fn checkText(text: []const u8) error{ControlInText}!void {
    if (hasControl(text)) return error.ControlInText;
}

/// Writes `parts` in order, refusing C0 controls and DEL in each part
/// `checked` marks; nothing is written when one is refused.
///
/// When the writer's buffer has room for all of it, each part is copied in
/// once and a checked part is read for controls as it is copied, so the text
/// is read once; the bytes only become written when every checked part is
/// clean, and a refusal leaves the buffer's contents as they were. Without
/// that room the checked parts are read first and everything is then handed
/// to the writer together.
pub inline fn writeChecked(w: *Writer, comptime checked: []const bool, parts: [checked.len][]const u8) Error!void {
    var total: usize = 0;
    inline for (parts) |part| total += part.len;
    if (w.unusedCapacityLen() >= total) {
        const dest = w.unusedCapacitySlice();
        var at: usize = 0;
        var refused = false;
        inline for (parts, checked) |part, check| {
            if (check) {
                refused = copyControl(dest[at..][0..part.len], part) or refused;
            } else {
                @memcpy(dest[at..][0..part.len], part);
            }
            at += part.len;
        }
        if (refused) return error.ControlInText;
        w.advance(total);
        return;
    }
    inline for (parts, checked) |part, check| if (check) try checkText(part);
    var all = parts;
    try w.writeVecAll(&all);
}

/// Copies `text` into `dest`, which is as long, and says whether it held a
/// C0 control or DEL: `hasControl` with a store after each load.
fn copyControl(dest: []u8, text: []const u8) bool {
    return scan(true, dest, text);
}

/// Whether `text` holds a C0 control or DEL.
///
/// Text that reaches a writer is almost always clean, so the whole string is
/// read before the answer is asked for: a vector at a time, the compares of
/// every block folded into one set of lanes and reduced once at the end. The
/// last block overlaps the one before it rather than finishing a byte at a
/// time. Text shorter than one vector is read a byte at a time.
fn hasControl(text: []const u8) bool {
    return scan(false, &.{}, text);
}

fn isControl(b: u8) bool {
    return b < 0x20 or b == 0x7f;
}

/// `hasControl` over `text`, copying it into `dest` as it goes when `copy`.
fn scan(comptime copy: bool, dest: []u8, text: []const u8) bool {
    if (!@inComptime()) {
        if (std.simd.suggestVectorLength(u8)) |block_len| {
            if (text.len >= block_len) return scanBlocks(block_len, copy, dest, text);
        }
    }
    var any = false;
    for (text, 0..) |b, i| {
        if (copy) dest[i] = b;
        any = any or isControl(b);
    }
    return any;
}

/// `scan` over `text`, which is at least `block_len` long.
fn scanBlocks(comptime block_len: usize, comptime copy: bool, dest: []u8, text: []const u8) bool {
    const Block = @Vector(block_len, u8);
    const space: Block = @splat(0x20);
    const del: Block = @splat(0x7f);
    var any: @Vector(block_len, bool) = @splat(false);
    var i: usize = 0;
    while (i + block_len <= text.len) : (i += block_len) {
        const block: Block = text[i..][0..block_len].*;
        if (copy) dest[i..][0..block_len].* = block;
        any = any | (block < space) | (block == del);
    }
    if (i < text.len) {
        // The last block overlaps the one before it, and so does its store:
        // the overlapping bytes are written twice, with the same values.
        const last = text.len - block_len;
        const block: Block = text[last..][0..block_len].*;
        if (copy) dest[last..][0..block_len].* = block;
        any = any | (block < space) | (block == del);
    }
    return @reduce(.Or, any);
}

/// Explicitly strips C0 controls and DEL into `out`, preserving every other
/// byte, including UTF-8. The returned slice borrows `out`; no allocation.
/// `NoSpaceLeft` is returned before changing `out` when it cannot fit.
/// `out` may be the same buffer as `text`, for stripping in place.
pub fn printable(out: []u8, text: []const u8) error{NoSpaceLeft}![]u8 {
    var needed: usize = 0;
    for (text) |b| if (!isControl(b)) {
        needed += 1;
    };
    if (out.len < needed) return error.NoSpaceLeft;
    var n: usize = 0;
    for (text) |b| {
        if (isControl(b)) continue;
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

test "checkText refuses what the byte loop refuses, at every length and offset" {
    // Every length up to four vectors and a tail, with every awkward byte at
    // every offset, so the overlapping last block and the short scalar path
    // are both asked.
    var buf: [4 * 64 + 3]u8 = undefined;
    const block_len = std.simd.suggestVectorLength(u8) orelse 16;
    const longest = @min(4 * block_len + 3, buf.len);
    for (0..longest + 1) |len| {
        const bytes = buf[0..len];
        @memset(bytes, 'x');
        try checkText(bytes);
        for ([_]u8{ 0x00, 0x1b, 0x1f, ' ', '~', 0x7f, 0x80, 0xff }) |byte| {
            for (0..len) |at| {
                @memset(bytes, 'x');
                bytes[at] = byte;
                const refused = byte < 0x20 or byte == 0x7f;
                if (refused) {
                    try std.testing.expectError(error.ControlInText, checkText(bytes));
                } else {
                    try checkText(bytes);
                }
            }
        }
    }
}

test "writeChecked writes every part, or nothing when a checked part holds a control" {
    const block_len = std.simd.suggestVectorLength(u8) orelse 16;
    var text: [4 * 64 + 3]u8 = undefined;
    const longest = @min(4 * block_len + 3, text.len);
    var room: [2 * text.len]u8 = undefined;
    var tight: [8]u8 = undefined;
    for (0..longest + 1) |len| {
        @memset(text[0..len], 'x');
        for (0..len + 1) |at| {
            if (at < len) text[at] = 0x1b;
            const refused = at < len;
            // Room for all of it, so the copy checks; then a buffer too
            // small for it, so the check comes first.
            var roomy: Writer = .fixed(&room);
            try roomy.writeAll("ok");
            var small: Writer = .fixed(&tight);
            try small.writeAll("ok");
            inline for (.{ &roomy, &small }) |w| {
                const result = writeChecked(w, &.{ false, true, false }, .{ "<", text[0..len], ">" });
                if (refused) {
                    try std.testing.expectError(error.ControlInText, result);
                    try std.testing.expectEqualStrings("ok", w.buffered());
                } else if (w == &small and len + 4 > tight.len) {
                    try std.testing.expectError(error.WriteFailed, result);
                } else {
                    try result;
                    try std.testing.expectEqualStrings("ok<", w.buffered()[0..3]);
                    try std.testing.expectEqualStrings(text[0..len], w.buffered()[3..][0..len]);
                    try std.testing.expectEqualStrings(">", w.buffered()[3 + len ..]);
                }
            }
            if (at < len) text[at] = 'x';
        }
    }
}
