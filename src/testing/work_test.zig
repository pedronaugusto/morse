//! Exact byte counts and bounded work for the paths a renderer uses.
//!
//! These checks need no clock. Timing loops and their ceilings live on the
//! bench branch, separately from the unit suite.

const std = @import("std");
const base64 = @import("../base64.zig");
const cursor = @import("../cursor.zig");
const graphics = @import("../graphics.zig");
const key = @import("../key.zig");
const seq = @import("../seq.zig");
const style = @import("../style.zig");

const Writer = std.Io.Writer;

test "work: a style diff is five bytes and an equal style writes nothing" {
    // The frame this stands for: a syntax-highlighted line, where the style
    // changes at every token and almost nothing about it changes at once.
    const from: style.Style = .{ .bold = true, .fg = .ansi(.cyan) };
    const to: style.Style = .{ .fg = .ansi(.cyan) };

    var buffer: [64]u8 = undefined;
    var out: Writer = .fixed(&buffer);
    try style.diffStyle(&out, from, to);

    // Five bytes: `CSI 22 m`. A full `setStyle` of `to` would be seven, and
    // a reset and a repaint would be twelve.
    try std.testing.expectEqualStrings("\x1b[22m", out.buffered());
    try std.testing.expectEqual(@as(usize, 5), out.buffered().len);

    // And nothing at all when the two are equal, which is the case a
    // renderer hits most.
    var same: Writer = .fixed(&buffer);
    try style.diffStyle(&same, to, to);
    try std.testing.expectEqual(@as(usize, 0), same.buffered().len);
}

/// Nine styles a renderer really moves between: the default, single
/// attributes, an underline with a colour of its own, each of the three
/// colour forms, a combination, and everything at once.
const style_matrix = [_]style.Style{
    .{},
    .{ .bold = true },
    .{ .dim = true, .italic = true },
    .{ .underline = .curly, .underline_color = .rgb(255, 0, 0) },
    .{ .fg = .ansi(.cyan) },
    .{ .fg = .palette(33), .bg = .ansi(.black) },
    .{ .fg = .rgb(200, 100, 50), .bg = .rgb(10, 20, 30) },
    .{ .bold = true, .reverse = true, .strikethrough = true, .fg = .ansi(.bright_white) },
    .{
        .bold = true,
        .dim = true,
        .italic = true,
        .underline = .dashed,
        .blink = true,
        .reverse = true,
        .hidden = true,
        .strikethrough = true,
        .overline = true,
        .script = .superscript,
        .fg = .rgb(1, 2, 3),
        .bg = .rgb(4, 5, 6),
        .underline_color = .rgb(7, 8, 9),
    },
};

test "work: a style diff is the shorter of the difference and a reset" {
    // Every attribute and all three colours changing at once. The
    // difference is thirty-eight bytes of off codes; `CSI 0 m` is four and
    // leaves the terminal in the same style, so four is what goes out.
    var buffer: [128]u8 = undefined;
    var out: Writer = .fixed(&buffer);
    try style.diffStyle(&out, style_matrix[style_matrix.len - 1], .{});
    try std.testing.expectEqualStrings("\x1b[0m", out.buffered());

    // The budget is the matrix rather than one corner of it, because what
    // this costs is a whole grid of pairs and the worst of them is no
    // longer the number that matters. Exact, and the same in every optimize
    // mode: 1,703 bytes of difference against 1,312 of shorter-of-two, a
    // fifth off, with the longest single pair 60 bytes.
    var total: usize = 0;
    var worst: usize = 0;
    for (style_matrix) |from| {
        for (style_matrix) |to| {
            var w: Writer = .fixed(&buffer);
            try style.diffStyle(&w, from, to);
            const written = w.buffered();
            total += written.len;
            worst = @max(worst, written.len);
            // Whichever spelling won, it is one sequence.
            try std.testing.expect(std.mem.count(u8, written, "\x1b[") <= 1);
        }
    }
    try std.testing.expectEqual(@as(usize, 1312), total);
    try std.testing.expectEqual(@as(usize, 60), worst);
}

test "work: a frame of style changes pays the same fifth" {
    // 200 columns by 60 rows, eight runs a row and a reset at the end of
    // each: 10,978 bytes of difference against 8,515.
    var buffer: [128]u8 = undefined;
    var total: usize = 0;
    var pen: style.Style = .{};
    var i: usize = 0;
    for (0..60) |_| {
        for (0..8) |_| {
            const to = style_matrix[i % style_matrix.len];
            i += 1;
            var w: Writer = .fixed(&buffer);
            try style.diffStyle(&w, pen, to);
            total += w.buffered().len;
            pen = to;
        }
        var w: Writer = .fixed(&buffer);
        try style.diffStyle(&w, pen, .{});
        total += w.buffered().len;
        pen = .{};
    }
    try std.testing.expectEqual(@as(usize, 8515), total);
}

test "work: a cursor move is the digits and nothing else" {
    var buffer: [32]u8 = undefined;

    var out: Writer = .fixed(&buffer);
    try cursor.cursorTo(&out, 1, 1);
    try std.testing.expectEqualStrings("\x1b[1;1H", out.buffered());

    var far: Writer = .fixed(&buffer);
    try cursor.cursorTo(&far, 200, 300);
    try std.testing.expectEqualStrings("\x1b[200;300H", far.buffered());
    try std.testing.expectEqual(@as(usize, 10), far.buffered().len);
}

test "work: a megabyte of pixels costs a quarter of a percent in framing" {
    const megabyte = 1024 * 1024;
    const pixels = try std.testing.allocator.alloc(u8, megabyte);
    defer std.testing.allocator.free(pixels);
    for (pixels, 0..) |*b, i| b.* = @truncate(i *% 131 +% 17);

    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try graphics.transmitImage(&out.writer, .{
        .image = .{ .id = 1 },
        .width = 512,
        .height = 512,
    }, pixels);

    const written = out.written().len;
    const payload = base64.encodedLen(megabyte);
    const overhead = written - payload;

    // Every chunk but the last is exactly the protocol's maximum, so the
    // number of sequences is fixed and so is the framing around them.
    const chunks = (megabyte + graphics.chunk_bytes - 1) / graphics.chunk_bytes;
    try std.testing.expectEqual(@as(usize, 342), chunks);

    const ratio = @as(f64, @floatFromInt(overhead)) * 100 / @as(f64, @floatFromInt(payload));
    try std.testing.expect(ratio < 0.25);

    // The whole of it is the payload plus `APC G`, the keys, the `;` and the
    // `ST` on each sequence — no padding, no repeated header.
    const first_keys = "i=1,s=512,v=512,m=1".len;
    const chunk_keys = "m=1".len;
    const framing = seq.apc.len + 1 + 1 + seq.st.len;
    try std.testing.expectEqual(
        payload + chunks * (framing + chunk_keys) + (first_keys - chunk_keys),
        written,
    );
}

/// A megabyte of the input a full-screen program really reads: keys in the
/// kitty protocol and in the legacy spellings, mouse reports, paste markers,
/// plain UTF-8, and the replies that arrive in among them.
fn mixedInput(allocator: std.mem.Allocator, size: usize) ![]u8 {
    const pieces = [_][]const u8{
        "\x1b[97;5u",
        "a",
        "\x1b[A",
        "\x1b[1;5C",
        "\x1b[<0;40;12M",
        "\x1b[M\x20\x21\x21",
        "\x1b[200~",
        "pasted",
        "\x1b[201~",
        "\u{00e9}",
        "\u{4e2d}",
        "\x1b[?2026;1$y",
        "\x1b[?997;1n",
        "\x1b[48;24;80;384;640t",
        "\x1b[15~",
        "\x1bOP",
        "\x1b[27;5;97~",
        "\x1b]52;c;aGk=\x1b\\",
        "\r",
        "\x7f",
    };

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var i: usize = 0;
    while (list.items.len < size) : (i += 1) {
        try list.appendSlice(allocator, pieces[i % pieces.len]);
    }
    return list.toOwnedSlice(allocator);
}

test "work: a megabyte of mixed input, framed and decoded" {
    const megabyte = 1024 * 1024;
    const input = try mixedInput(std.testing.allocator, megabyte);
    defer std.testing.allocator.free(input);

    var storage: [key.KeyParser.min_buffer]u8 = undefined;
    var parser: key.KeyParser = .init(&storage);

    var events: usize = 0;
    var keys: usize = 0;

    // Fed in reads of an awkward size, so a sequence lands across a read
    // boundary as often as it does against a real terminal.
    var offset: usize = 0;
    while (offset < input.len) {
        const end = @min(offset + 977, input.len);
        var batch = parser.feed(input[offset..end]);
        while (batch.next()) |event| {
            events += 1;
            if (event == .key) keys += 1;
        }
        offset = end;
    }
    // The stream is real input, so it must decode to real events rather than
    // to a megabyte of `unhandled`.
    try std.testing.expect(events > 100_000);
    try std.testing.expect(keys > events / 4);

    // Nothing is left half-read: the input ends on a sequence boundary.
    try std.testing.expectEqual(@as(usize, 0), parser.pending().len);
}

/// A block of printable text, the shape a paste or a fast typist arrives in.
fn plainInput(allocator: std.mem.Allocator, size: usize) ![]u8 {
    const bytes = try allocator.alloc(u8, size);
    for (bytes, 0..) |*b, i| b.* = ' ' + @as(u8, @intCast(i % 95));
    return bytes;
}

/// Text runs count as their individual keys, so changing the read or buffer
/// size can change batching without changing what the input means.
fn inputCounts(input: []const u8, storage: []u8, read: usize) ![@typeInfo(key.Event).@"union".field_names.len]usize {
    var counts: [@typeInfo(key.Event).@"union".field_names.len]usize = @splat(0);
    var parser: key.KeyParser = .init(storage);
    var offset: usize = 0;
    while (offset < input.len) {
        const end = @min(offset + read, input.len);
        var batch = parser.feed(input[offset..end]);
        while (batch.next()) |event| {
            switch (event) {
                .text => |text| counts[@backingInt(std.meta.Tag(key.Event).key)] +=
                    try std.unicode.utf8CountCodepoints(text),
                .overflow, .unhandled => return error.UnexpectedEvent,
                else => counts[@backingInt(event)] += 1,
            }
            try std.testing.expect(parser.pending().len <= storage.len);
        }
        try std.testing.expectEqual(@as(usize, 0), batch.remainder().len);
        offset = end;
    }
    try std.testing.expectEqual(@as(usize, 0), parser.pending().len);
    return counts;
}

test "work: input counts and bounds hold across buffer and read sizes" {
    const block = 128 * 1024;
    const mixed = try mixedInput(std.testing.allocator, block);
    defer std.testing.allocator.free(mixed);
    const text = try plainInput(std.testing.allocator, block);
    defer std.testing.allocator.free(text);

    const buffers = [_]usize{ 64, 1024, 16 * 1024 };
    const reads = [_]usize{ 64, 977, 8192, block };
    var storage: [16 * 1024]u8 = undefined;
    for ([_][]const u8{ text, mixed }) |input| {
        const expected = try inputCounts(input, &storage, block);
        if (input.ptr == text.ptr) {
            try std.testing.expectEqual(block, expected[@backingInt(std.meta.Tag(key.Event).key)]);
        }
        for (buffers) |size| {
            for (reads) |read| {
                try std.testing.expectEqual(expected, try inputCounts(input, storage[0..size], read));
            }
        }
    }
}

test "work: nothing here needed an allocator" {
    // Every writer in the package takes a `*std.Io.Writer`, and a fixed one
    // cannot allocate. A buffer sized exactly to the bytes a call produces
    // is therefore both a byte budget and a proof that no growth happened.
    var exact: [4]u8 = undefined;
    var out: Writer = .fixed(&exact);
    try style.diffStyle(&out, .{ .bold = true }, .{});
    try std.testing.expectEqual(@as(usize, 4), out.buffered().len);

    var tight: [6]u8 = undefined;
    var moved: Writer = .fixed(&tight);
    try cursor.cursorTo(&moved, 1, 1);
    try std.testing.expectEqual(@as(usize, 6), moved.buffered().len);

    // And one byte less is a failure rather than a silent allocation.
    var short: [5]u8 = undefined;
    var cramped: Writer = .fixed(&short);
    try std.testing.expectError(error.WriteFailed, cursor.cursorTo(&cramped, 1, 1));
}
