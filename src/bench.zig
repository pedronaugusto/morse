//! What the hot paths cost, measured, with a budget beside each number.
//!
//! A renderer calls `diffStyle` and `cursorTo` once per changed run and
//! `transmitImage` once per frame that carries a picture, so the cost of
//! those three is the cost of drawing; `KeyParser.feed` is the whole of the
//! input side. The numbers below are printed when the suite runs, and each
//! is asserted against a ceiling, so a change that makes one of them
//! algorithmically worse — an allocation, a second pass, a formatter in a
//! loop — fails the build rather than being noticed a release later.
//!
//! Two kinds of budget, because they fail differently:
//!
//! - **Bytes.** Exact, deterministic, the same on every machine and in every
//!   optimize mode. These are the real guard: a writer that starts spending
//!   an extra byte a call is a renderer spending an extra kilobyte a frame.
//! - **Time.** Wide, because this runs in four optimize modes on three
//!   operating systems on machines shared with other work. The ceilings are
//!   far above what any of them measures, and are there to catch a
//!   regression of a factor of ten, not of a factor of two.
//!
//! This file will never hold a comparison against another package, a
//! micro-benchmark of the standard library, or a tuning knob. It measures
//! what `morse` does and says whether it still fits.

const std = @import("std");
const base64 = @import("base64.zig");
const cursor = @import("cursor.zig");
const graphics = @import("graphics.zig");
const key = @import("key.zig");
const seq = @import("seq.zig");
const style = @import("style.zig");

const Writer = std.Io.Writer;

/// The monotonic clock, through the instance the test runner provides. The
/// package itself calls no operating system API; this file is the suite, and
/// a measurement needs a clock.
fn nowNanos() i96 {
    return std.Io.Clock.now(.awake, std.testing.io).toNanoseconds();
}

/// How long `body` takes per iteration, in nanoseconds.
///
/// A warm-up pass first, then the measured one, and the result is a mean
/// rather than a minimum: a mean is what a renderer actually pays.
fn nanosPer(iterations: usize, context: anytype, comptime body: fn (@TypeOf(context)) anyerror!void) !f64 {
    for (0..iterations / 8 + 1) |_| try body(context);

    const start = nowNanos();
    for (0..iterations) |_| try body(context);
    const elapsed = nowNanos() - start;
    return @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
}

/// Prints one measurement in the shape every line here takes.
fn report(name: []const u8, value: f64, unit: []const u8, budget: f64) void {
    std.debug.print("bench: {s:<34} {d:>10.2} {s} (budget {d:.2})\n", .{ name, value, unit, budget });
}

test "bench: a style diff is four bytes and a few dozen nanoseconds" {
    // The frame this stands for: a syntax-highlighted line, where the style
    // changes at every token and almost nothing about it changes at once.
    const from: style.Style = .{ .bold = true, .fg = .ansi(.cyan) };
    const to: style.Style = .{ .fg = .ansi(.cyan) };

    var buffer: [64]u8 = undefined;
    var out: Writer = .fixed(&buffer);
    try style.diffStyle(&out, from, to);

    // Four bytes: `CSI 22 m`. A full `setStyle` of `to` would be six, and a
    // reset and a repaint would be eleven.
    try std.testing.expectEqualStrings("\x1b[22m", out.buffered());
    try std.testing.expectEqual(@as(usize, 5), out.buffered().len);

    // And nothing at all when the two are equal, which is the case a
    // renderer hits most.
    var same: Writer = .fixed(&buffer);
    try style.diffStyle(&same, to, to);
    try std.testing.expectEqual(@as(usize, 0), same.buffered().len);

    const Case = struct {
        buffer: []u8,
        // The two styles again, as declarations, because a nested function
        // cannot reach a local of the test it sits in.
        const lit: style.Style = .{ .bold = true, .fg = .ansi(.cyan) };
        const plain: style.Style = .{ .fg = .ansi(.cyan) };
        fn one(c: @This()) !void {
            var w: Writer = .fixed(c.buffer);
            try style.diffStyle(&w, lit, plain);
            try style.diffStyle(&w, plain, lit);
            std.mem.doNotOptimizeAway(w.buffered().len);
        }
    };
    const ns = try nanosPer(200_000, Case{ .buffer = &buffer }, Case.one);
    report("diffStyle, two calls", ns, "ns", 4000);
    try std.testing.expect(ns < 4000);
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

test "bench: a style diff is the shorter of the difference and a reset" {
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
    std.debug.print("bench: {s:<34} {d:>10} bytes (budget {d})\n", .{ "style matrix, 81 pairs", total, 1312 });
    try std.testing.expectEqual(@as(usize, 1312), total);
    try std.testing.expectEqual(@as(usize, 60), worst);
}

test "bench: a frame of style changes pays the same fifth" {
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
    std.debug.print("bench: {s:<34} {d:>10} bytes (budget {d})\n", .{ "style, 200x60 frame", total, 8515 });
    try std.testing.expectEqual(@as(usize, 8515), total);
}

test "bench: a cursor move is the digits and nothing else" {
    var buffer: [32]u8 = undefined;

    var out: Writer = .fixed(&buffer);
    try cursor.cursorTo(&out, 1, 1);
    try std.testing.expectEqualStrings("\x1b[1;1H", out.buffered());

    var far: Writer = .fixed(&buffer);
    try cursor.cursorTo(&far, 200, 300);
    try std.testing.expectEqualStrings("\x1b[200;300H", far.buffered());
    try std.testing.expectEqual(@as(usize, 10), far.buffered().len);

    const Case = struct {
        buffer: []u8,
        fn one(c: @This()) !void {
            var w: Writer = .fixed(c.buffer);
            try cursor.cursorTo(&w, 200, 300);
            std.mem.doNotOptimizeAway(w.buffered().len);
        }
    };
    const ns = try nanosPer(200_000, Case{ .buffer = &buffer }, Case.one);
    report("cursorTo", ns, "ns", 2000);
    try std.testing.expect(ns < 2000);
}

test "bench: the hand integer encoder against the formatter" {
    // Why `seq.writeInt` exists rather than `w.print("{d}")`. The numbers
    // come out of memory the compiler cannot fold, or ReleaseFast would
    // measure two constants instead of two encoders.
    //
    // Measured on the machine this was written on: 2.24x in Debug, 1.31x in
    // ReleaseSmall, and 0.92x and 0.94x in ReleaseSafe and ReleaseFast --
    // slower there, because the optimiser inlines the formatter's own fast
    // path. Debug and ReleaseSmall are where the suite and most development
    // run, and a writer with no comptime format machinery in it is a
    // smaller one; that is the whole of the case for it.
    var buffer: [32]u8 = undefined;
    var numbers = [_]u64{ 4294967295, 7, 1, 65535, 200, 300, 0, 128 };
    std.mem.doNotOptimizeAway(&numbers);

    const Mine = struct {
        buffer: []u8,
        numbers: []const u64,
        fn one(c: @This()) !void {
            var w: Writer = .fixed(c.buffer);
            for (c.numbers) |n| {
                try seq.writeInt(&w, n);
                w.end = 0;
            }
            std.mem.doNotOptimizeAway(w.end);
        }
    };
    const Theirs = struct {
        buffer: []u8,
        numbers: []const u64,
        fn one(c: @This()) !void {
            var w: Writer = .fixed(c.buffer);
            for (c.numbers) |n| {
                try w.print("{d}", .{n});
                w.end = 0;
            }
            std.mem.doNotOptimizeAway(w.end);
        }
    };

    const context = .{ .buffer = &buffer, .numbers = &numbers };
    const mine = try nanosPer(100_000, Mine{ .buffer = context.buffer, .numbers = context.numbers }, Mine.one);
    const theirs = try nanosPer(100_000, Theirs{ .buffer = context.buffer, .numbers = context.numbers }, Theirs.one);
    report("writeInt, eight numbers", mine, "ns", 8000);
    report("the formatter, the same eight", theirs, "ns", 8000);
    std.debug.print("bench: {s:<34} {d:>10.2}x\n", .{ "writeInt against the formatter", theirs / mine });

    try std.testing.expect(mine < 8000);
    // Not slower by more than half again, in any optimize mode. The margin
    // is that wide because the optimizing modes measure 0.92x and 0.94x
    // before any noise, and because the formatter is not this package's
    // code; a change that made the hand encoder genuinely worse shows up as
    // a ratio well under one in Debug, where the gap is widest.
    try std.testing.expect(mine <= theirs * 1.5);
}

test "bench: a megabyte of pixels costs a quarter of a percent in framing" {
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
    report("transmit 1 MB, framing overhead", ratio, "%", 0.25);
    std.debug.print("bench: {s:<34} {d:>10} bytes\n", .{ "transmit 1 MB, total", written });
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

    const Case = struct {
        pixels: []const u8,
        sink: []u8,
        fn one(c: @This()) !void {
            var w: Writer = .fixed(c.sink);
            try graphics.transmitImage(&w, .{
                .image = .{ .id = 1 },
                .width = 512,
                .height = 512,
            }, c.pixels);
            std.mem.doNotOptimizeAway(w.buffered().len);
        }
    };
    const sink = try std.testing.allocator.alloc(u8, written + 64);
    defer std.testing.allocator.free(sink);

    const ns = try nanosPer(16, Case{ .pixels = pixels, .sink = sink }, Case.one);
    const mb_per_s = @as(f64, megabyte) / ns * 1000;
    report("transmit 1 MB", ns / 1_000_000, "ms", 400);
    std.debug.print("bench: {s:<34} {d:>10.1} MB/s\n", .{ "transmit throughput", mb_per_s });
    try std.testing.expect(ns / 1_000_000 < 400);
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

test "bench: a megabyte of mixed input, framed and decoded" {
    const megabyte = 1024 * 1024;
    const input = try mixedInput(std.testing.allocator, megabyte);
    defer std.testing.allocator.free(input);

    var storage: [key.KeyParser.min_buffer]u8 = undefined;
    var parser: key.KeyParser = .init(&storage);

    const start = nowNanos();
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
    const elapsed = nowNanos() - start;

    const ns_per_byte = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(input.len));
    const mb_per_s = @as(f64, @floatFromInt(input.len)) /
        @as(f64, @floatFromInt(elapsed)) * 1000;

    report("KeyParser, per byte", ns_per_byte, "ns", 200);
    std.debug.print("bench: {s:<34} {d:>10.1} MB/s\n", .{ "KeyParser throughput", mb_per_s });
    std.debug.print("bench: {s:<34} {d:>10} of {d}\n", .{ "KeyParser events", keys, events });

    // The stream is real input, so it must decode to real events rather than
    // to a megabyte of `unhandled`.
    try std.testing.expect(events > 100_000);
    try std.testing.expect(keys > events / 4);
    try std.testing.expect(ns_per_byte < 200);

    // Nothing is left half-read: the input ends on a sequence boundary.
    try std.testing.expectEqual(@as(usize, 0), parser.pending().len);
}

/// A block of printable text, the shape a paste or a fast typist arrives in.
fn plainInput(allocator: std.mem.Allocator, size: usize) ![]u8 {
    const bytes = try allocator.alloc(u8, size);
    for (bytes, 0..) |*b, i| b.* = ' ' + @as(u8, @intCast(i % 95));
    return bytes;
}

test "bench: what the parser costs does not depend on the caller's buffer" {
    // The grid the per-event top-up used to fall off: the cost of a top-up
    // is the whole of the unread buffer, so doing one per event made a
    // large buffer slower than a small one and a large read slower than a
    // small one -- exactly backwards, and exactly what the README's advice
    // to size for an OSC 52 reply steers a caller into.
    const block = 128 * 1024;
    // The best of three per cell, not the mean. What this grid catches is a
    // tilt -- one cell orders of magnitude worse than its neighbours -- and
    // a tilt is in every run, where a machine shared with other work puts
    // noise in some of them.
    const rounds = 3;
    const mixed = try mixedInput(std.testing.allocator, block);
    defer std.testing.allocator.free(mixed);
    const text = try plainInput(std.testing.allocator, block);
    defer std.testing.allocator.free(text);

    const streams = [_]struct { name: []const u8, bytes: []const u8 }{
        .{ .name = "text", .bytes = text },
        .{ .name = "mixed", .bytes = mixed },
    };
    const buffers = [_]usize{ 64, 1024, 16 * 1024 };
    const reads = [_]usize{ 64, 977, 8192, block };

    var storage: [16 * 1024]u8 = undefined;
    var worst: f64 = 0;
    for (streams) |stream| {
        for (buffers) |size| {
            var line: [4]f64 = @splat(0);
            for (reads, 0..) |read, i| {
                var best: f64 = std.math.floatMax(f64);
                for (0..rounds) |_| {
                    var parser: key.KeyParser = .init(storage[0..size]);
                    const start = nowNanos();
                    var offset: usize = 0;
                    while (offset < stream.bytes.len) {
                        const end = @min(offset + read, stream.bytes.len);
                        var batch = parser.feed(stream.bytes[offset..end]);
                        while (batch.next()) |_| {}
                        offset = end;
                    }
                    const elapsed = nowNanos() - start;
                    best = @min(best, @as(f64, @floatFromInt(elapsed)) /
                        @as(f64, @floatFromInt(stream.bytes.len)));
                }
                line[i] = 1000 / best;
                worst = @max(worst, best);
            }
            std.debug.print(
                "bench: KeyParser {s:<6} {d:>5} B buffer  {d:>7.1} {d:>7.1} {d:>7.1} {d:>7.1} MB/s\n",
                .{ stream.name, size, line[0], line[1], line[2], line[3] },
            );
        }
    }

    // One ceiling for every cell of the grid, because the defect this
    // catches is a whole grid tilting rather than one number moving. Wide:
    // the slowest cell here measures under 40 ns a byte in Debug, and the
    // tilt it is here to catch measured 2,272.
    report("KeyParser, worst of the grid", worst, "ns", 400);
    try std.testing.expect(worst < 400);
}

test "bench: nothing here needed an allocator" {
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
