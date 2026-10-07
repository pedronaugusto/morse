//! Wall-clock measurements for morse: `zig build bench`, on a quiet machine.
//!
//! Each test is a speed ceiling with the byte counts that go with it. The
//! ceilings are wide, set for a Debug build, and catch a change that costs
//! many times what it did, not one that costs a few percent. The unit suite
//! checks the same byte counts and buffer bounds without a clock
//! (`src/testing/work_test.zig`); CI compiles this file and never runs it.

const std = @import("std");
const morse = @import("morse");

const Writer = std.Io.Writer;

/// The monotonic clock, through the instance the test runner provides. The
/// package itself calls no operating system API; a measurement needs a clock.
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

/// The least of three runs of `nanosPer`.
///
/// For a measurement that is compared against another measurement rather
/// than against a ceiling, the least-disturbed run is the one that says
/// which of the two is faster; a mean on a machine shared with other work
/// says which of them the scheduler happened to interrupt.
fn bestNanosPer(iterations: usize, context: anytype, comptime body: fn (@TypeOf(context)) anyerror!void) !f64 {
    var best: f64 = std.math.floatMax(f64);
    for (0..3) |_| best = @min(best, try nanosPer(iterations, context, body));
    return best;
}

/// Writes a line of the bench's output to stderr, where the test runner
/// passes it through.
fn note(comptime format: []const u8, args: anytype) !void {
    var buffer: [256]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(std.testing.io, &buffer);
    try stderr.interface.print(format, args);
    try stderr.interface.flush();
}

/// Writes one measurement in the shape every line here takes: name, value,
/// unit and the ceiling it is held to, separated by tabs.
fn report(name: []const u8, value: f64, unit: []const u8, budget: f64) !void {
    try note("measurement\t{s}\t{d:.6}\t{s}\t{d:.2}\n", .{ name, value, unit, budget });
}

test "bench: a style diff is five bytes and a few dozen nanoseconds" {
    // The frame this stands for: a syntax-highlighted line, where the style
    // changes at every token and almost nothing about it changes at once.
    const from: morse.Style = .{ .bold = true, .fg = .ansi(.cyan) };
    const to: morse.Style = .{ .fg = .ansi(.cyan) };

    var buffer: [64]u8 = undefined;
    var out: Writer = .fixed(&buffer);
    try morse.diffStyle(&out, from, to);

    // Five bytes: `CSI 22 m`. A full `setStyle` of `to` would be seven, and
    // a reset and a repaint would be twelve.
    try std.testing.expectEqualStrings("\x1b[22m", out.buffered());
    try std.testing.expectEqual(@as(usize, 5), out.buffered().len);

    // And nothing at all when the two are equal, which is the case a
    // renderer hits most.
    var same: Writer = .fixed(&buffer);
    try morse.diffStyle(&same, to, to);
    try std.testing.expectEqual(@as(usize, 0), same.buffered().len);

    const Case = struct {
        buffer: []u8,
        // The two styles again, as declarations, because a nested function
        // cannot reach a local of the test it sits in.
        const lit: morse.Style = .{ .bold = true, .fg = .ansi(.cyan) };
        const plain: morse.Style = .{ .fg = .ansi(.cyan) };
        fn one(c: @This()) !void {
            var w: Writer = .fixed(c.buffer);
            try morse.diffStyle(&w, lit, plain);
            try morse.diffStyle(&w, plain, lit);
            std.mem.doNotOptimizeAway(w.buffered().len);
        }
    };
    const ns = try nanosPer(200_000, Case{ .buffer = &buffer }, Case.one);
    try report("diffStyle, two calls", ns, "ns", 4000);
    try std.testing.expect(ns < 4000);
}

test "bench: a cursor move is the digits and nothing else" {
    var buffer: [32]u8 = undefined;

    var out: Writer = .fixed(&buffer);
    try morse.cursorTo(&out, 1, 1);
    try std.testing.expectEqualStrings("\x1b[1;1H", out.buffered());

    var far: Writer = .fixed(&buffer);
    try morse.cursorTo(&far, 200, 300);
    try std.testing.expectEqualStrings("\x1b[200;300H", far.buffered());
    try std.testing.expectEqual(@as(usize, 10), far.buffered().len);

    const Case = struct {
        buffer: []u8,
        fn one(c: @This()) !void {
            var w: Writer = .fixed(c.buffer);
            try morse.cursorTo(&w, 200, 300);
            std.mem.doNotOptimizeAway(w.buffered().len);
        }
    };
    const ns = try nanosPer(200_000, Case{ .buffer = &buffer }, Case.one);
    try report("cursorTo", ns, "ns", 2000);
    try std.testing.expect(ns < 2000);
}

test "bench: the hand integer encoder against the formatter" {
    // Why the writers spell their numbers with a hand encoder rather than
    // `w.print("{d}")`: here through `cursorTo`, against the formatter
    // writing the same sequence. The numbers come out of memory the
    // compiler cannot fold, or ReleaseFast would measure two constants
    // instead of two encoders.
    //
    // Measured on the encoder alone, on the machine this was written on:
    // 2.24x in Debug, 1.31x in ReleaseSmall, and 0.92x and 0.94x in
    // ReleaseSafe and ReleaseFast -- slower in the optimizing modes,
    // because the optimiser inlines the formatter's own fast path. Debug
    // and ReleaseSmall are where the suite and most development run, and a
    // writer with no comptime format machinery in it is a smaller one; that
    // is the whole of the case for it.
    var buffer: [32]u8 = undefined;
    var numbers = [_]u32{ 4294967295, 7, 1, 65535, 200, 300, 1, 128 };
    std.mem.doNotOptimizeAway(&numbers);

    var check: [32]u8 = undefined;
    var mine_out: Writer = .fixed(&buffer);
    try morse.cursorTo(&mine_out, numbers[0], numbers[3]);
    var theirs_out: Writer = .fixed(&check);
    try theirs_out.print("\x1b[{d};{d}H", .{ numbers[0], numbers[3] });
    try std.testing.expectEqualStrings(theirs_out.buffered(), mine_out.buffered());

    const Mine = struct {
        buffer: []u8,
        numbers: []const u32,
        fn one(c: @This()) !void {
            var w: Writer = .fixed(c.buffer);
            var i: usize = 0;
            while (i < c.numbers.len) : (i += 2) {
                try morse.cursorTo(&w, c.numbers[i], c.numbers[i + 1]);
                w.end = 0;
            }
            std.mem.doNotOptimizeAway(w.end);
        }
    };
    const Theirs = struct {
        buffer: []u8,
        numbers: []const u32,
        fn one(c: @This()) !void {
            var w: Writer = .fixed(c.buffer);
            var i: usize = 0;
            while (i < c.numbers.len) : (i += 2) {
                try w.print("\x1b[{d};{d}H", .{ c.numbers[i], c.numbers[i + 1] });
                w.end = 0;
            }
            std.mem.doNotOptimizeAway(w.end);
        }
    };

    const mine = try bestNanosPer(100_000, Mine{ .buffer = &buffer, .numbers = &numbers }, Mine.one);
    const theirs = try bestNanosPer(100_000, Theirs{ .buffer = &buffer, .numbers = &numbers }, Theirs.one);
    try report("cursorTo, four moves", mine, "ns", 8000);
    try report("the formatter, the same four", theirs, "ns", 8000);
    try note("bench: {s:<34} {d:>10.2}x\n", .{ "cursorTo against the formatter", theirs / mine });

    try std.testing.expect(mine < 8000);
    // The budget above is the assertion. The ratio is printed and not
    // asserted: two timing loops measured against each other are at the
    // mercy of whichever core the scheduler hands them, and repeated runs
    // on one machine spanned 0.72x to 10.34x in Debug alone, with x86-64
    // Windows reading 0.65x in ReleaseFast. A threshold on that number
    // reports the machine, not this package. What the encoder owes is
    // checked in src/seq.zig, which spells every value the sequences carry
    // and agrees with the formatter on every value to ten thousand.
}

test "bench: a megabyte of pixels costs a quarter of a percent in framing" {
    const megabyte = 1024 * 1024;
    const pixels = try std.testing.allocator.alloc(u8, megabyte);
    defer std.testing.allocator.free(pixels);
    for (pixels, 0..) |*b, i| b.* = @truncate(i *% 131 +% 17);

    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try morse.transmitImage(&out.writer, .{
        .image = .{ .id = 1 },
        .width = 512,
        .height = 512,
    }, pixels);

    const written = out.written().len;
    const payload = std.base64.standard.Encoder.calcSize(megabyte);
    const overhead = written - payload;

    // Every chunk but the last is exactly the protocol's maximum, so the
    // number of sequences is fixed and so is the framing around them.
    const chunks = (megabyte + morse.graphics_chunk_bytes - 1) / morse.graphics_chunk_bytes;
    try std.testing.expectEqual(@as(usize, 342), chunks);

    const ratio = @as(f64, @floatFromInt(overhead)) * 100 / @as(f64, @floatFromInt(payload));
    try report("transmit 1 MB, framing overhead", ratio, "%", 0.25);
    try note("bench: {s:<34} {d:>10} bytes\n", .{ "transmit 1 MB, total", written });
    try std.testing.expect(ratio < 0.25);

    // The whole of it is the payload plus `APC G`, the keys, the `;` and the
    // `ST` on each sequence — no padding, no repeated header.
    const first_keys = "i=1,s=512,v=512,m=1".len;
    const chunk_keys = "m=1".len;
    const framing = "\x1b_".len + 1 + 1 + "\x1b\\".len;
    try std.testing.expectEqual(
        payload + chunks * (framing + chunk_keys) + (first_keys - chunk_keys),
        written,
    );

    const Case = struct {
        pixels: []const u8,
        sink: []u8,
        fn one(c: @This()) !void {
            var w: Writer = .fixed(c.sink);
            try morse.transmitImage(&w, .{
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
    try report("transmit 1 MB", ns / 1_000_000, "ms", 400);
    try note("bench: {s:<34} {d:>10.1} MB/s\n", .{ "transmit throughput", mb_per_s });
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

    var storage: [morse.KeyParser.min_buffer]u8 = undefined;
    var parser: morse.KeyParser = .init(&storage);

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

    try report("KeyParser, per byte", ns_per_byte, "ns", 200);
    try note("bench: {s:<34} {d:>10.1} MB/s\n", .{ "KeyParser throughput", mb_per_s });
    try note("bench: {s:<34} {d:>10} of {d}\n", .{ "KeyParser events", keys, events });

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
                    var parser: morse.KeyParser = .init(storage[0..size]);
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
                var name_buf: [128]u8 = undefined;
                const name = try std.mem.print(&name_buf, "KeyParser {s}, buffer {d}, read {d}", .{ stream.name, size, read });
                try report(name, best, "ns/byte", 400);
                line[i] = 1000 / best;
                worst = @max(worst, best);
            }
            try note(
                "bench: KeyParser {s:<6} {d:>5} B buffer  {d:>7.1} {d:>7.1} {d:>7.1} {d:>7.1} MB/s\n",
                .{ stream.name, size, line[0], line[1], line[2], line[3] },
            );
        }
    }

    // One ceiling for every cell of the grid, because the defect this
    // catches is a whole grid tilting rather than one number moving. Wide:
    // the slowest cell here measures under 40 ns a byte in Debug, and the
    // tilt it is here to catch measured 2,272.
    try report("KeyParser, worst of the grid", worst, "ns", 400);
    try std.testing.expect(worst < 400);
}
