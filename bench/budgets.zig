//! Wall-clock measurements for morse: `zig build bench` builds this in
//! ReleaseFast under zig-out/bench and runs it, on a quiet machine.
//!
//! Each row is a measurement with the bytes that go with it, printed as
//! `morse`, the row, the value, its unit and the ceiling it is held to,
//! separated by tabs. The ceilings are wide, set for a Debug build, and
//! catch a change that costs many times what it did, not one that costs a
//! few percent; a row above its ceiling fails the run by name. The unit
//! suite checks the same byte counts and buffer bounds without a clock
//! (`src/testing/work_test.zig`).
//!
//! `--smoke` runs every point once at its smallest size and holds nothing
//! to a ceiling: `zig build test` runs it that way, to check the program
//! still works, and its numbers mean nothing.

const std = @import("std");
const morse = @import("morse");

const Writer = std.Io.Writer;

/// What one run is: the full measurement, or every point once.
const Run = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *Writer,
    smoke: bool,
    /// Rows above their ceilings, counted so every row still prints.
    over: usize = 0,

    /// `full` iterations in a measurement, one in a smoke run.
    fn iterations(run: *const Run, full: usize) usize {
        return if (run.smoke) 1 else full;
    }

    /// The monotonic clock. The package itself calls no operating system
    /// API; a measurement needs a clock.
    fn nowNanos(run: *const Run) i96 {
        return std.Io.Clock.now(.awake, run.io).toNanoseconds();
    }

    /// How long `body` takes per iteration, in nanoseconds.
    ///
    /// A warm-up pass first, then the measured one, and the result is a
    /// mean rather than a minimum: a mean is what a renderer actually pays.
    fn nanosPer(run: *const Run, full: usize, context: anytype, comptime body: fn (@TypeOf(context)) anyerror!void) !f64 {
        const n = run.iterations(full);
        for (0..n / 8 + 1) |_| try body(context);

        const start = run.nowNanos();
        for (0..n) |_| try body(context);
        const elapsed = run.nowNanos() - start;
        return @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(n));
    }

    /// The least of three runs of `nanosPer`.
    ///
    /// For a measurement compared against another measurement rather than
    /// against a ceiling, the least-disturbed run is the one that says which
    /// of the two is faster; a mean on a machine shared with other work says
    /// which of them the scheduler happened to interrupt.
    fn bestNanosPer(run: *const Run, full: usize, context: anytype, comptime body: fn (@TypeOf(context)) anyerror!void) !f64 {
        var best: f64 = std.math.floatMax(f64);
        for (0..3) |_| best = @min(best, try run.nanosPer(full, context, body));
        return best;
    }

    /// One row, held to its ceiling unless this is a smoke run.
    fn row(run: *Run, name: []const u8, value: f64, unit: []const u8, ceiling: f64) !void {
        try run.out.print("morse\t{s}\t{d:.6}\t{s}\t{d:.2}\n", .{ name, value, unit, ceiling });
        if (!run.smoke and value >= ceiling) {
            try run.out.print("over the ceiling: {s}\n", .{name});
            run.over += 1;
        }
    }

    /// A row with no ceiling: a figure that explains another.
    fn figure(run: *Run, name: []const u8, value: anytype, unit: []const u8) !void {
        if (@TypeOf(value) == f64)
            try run.out.print("morse\t{s}\t{d:.6}\t{s}\t-\n", .{ name, value, unit })
        else
            try run.out.print("morse\t{s}\t{d}\t{s}\t-\n", .{ name, value, unit });
    }
};

/// A fact about the bytes a measurement relies on. The run stops on the
/// first one that does not hold, naming it: a timing of the wrong bytes
/// times nothing.
fn expect(ok: bool, what: []const u8) !void {
    if (ok) return;
    std.log.err("does not hold: {s}", .{what});
    return error.ExpectationFailed;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const smoke = switch (args.len) {
        1 => false,
        2 => if (std.mem.eql(u8, args[1], "--smoke")) true else return error.UnknownArgument,
        else => return error.UnknownArgument,
    };

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    defer stdout.interface.flush() catch {};
    var run: Run = .{ .io = init.io, .gpa = init.gpa, .out = &stdout.interface, .smoke = smoke };

    try styleDiff(&run);
    try cursorMove(&run);
    try encoderAgainstFormatter(&run);
    try transmit(&run);
    try mixedInputDecode(&run);
    try parserGrid(&run);

    if (run.over != 0) {
        try run.out.flush();
        return error.OverCeiling;
    }
}

/// A style diff is five bytes and a few dozen nanoseconds.
fn styleDiff(run: *Run) !void {
    // The frame this stands for: a syntax-highlighted line, where the style
    // changes at every token and almost nothing about it changes at once.
    const Case = struct {
        buffer: []u8,
        const lit: morse.Style = .{ .bold = true, .fg = .ansi(.cyan) };
        const plain: morse.Style = .{ .fg = .ansi(.cyan) };
        fn one(c: @This()) !void {
            var w: Writer = .fixed(c.buffer);
            try morse.diffStyle(&w, lit, plain);
            try morse.diffStyle(&w, plain, lit);
            std.mem.doNotOptimizeAway(w.buffered().len);
        }
    };

    var buffer: [64]u8 = undefined;
    var out: Writer = .fixed(&buffer);
    try morse.diffStyle(&out, Case.lit, Case.plain);
    // Five bytes: `CSI 22 m`. A full `setStyle` of `plain` would be seven,
    // and a reset and a repaint would be twelve.
    try expect(std.mem.eql(u8, "\x1b[22m", out.buffered()), "a style diff that drops bold is CSI 22 m");

    // And nothing at all when the two are equal, which is the case a
    // renderer hits most.
    var same: Writer = .fixed(&buffer);
    try morse.diffStyle(&same, Case.plain, Case.plain);
    try expect(same.buffered().len == 0, "equal styles write nothing");

    const ns = try run.nanosPer(200_000, Case{ .buffer = &buffer }, Case.one);
    try run.row("diffStyle, two calls", ns, "ns", 4000);
}

/// A cursor move is the digits and nothing else.
fn cursorMove(run: *Run) !void {
    const Case = struct {
        buffer: []u8,
        fn one(c: @This()) !void {
            var w: Writer = .fixed(c.buffer);
            try morse.cursorTo(&w, 200, 300);
            std.mem.doNotOptimizeAway(w.buffered().len);
        }
    };

    var buffer: [32]u8 = undefined;
    var out: Writer = .fixed(&buffer);
    try morse.cursorTo(&out, 1, 1);
    try expect(std.mem.eql(u8, "\x1b[1;1H", out.buffered()), "cursorTo(1, 1) is CSI 1;1 H");
    var far: Writer = .fixed(&buffer);
    try morse.cursorTo(&far, 200, 300);
    try expect(std.mem.eql(u8, "\x1b[200;300H", far.buffered()), "cursorTo(200, 300) is CSI 200;300 H");

    const ns = try run.nanosPer(200_000, Case{ .buffer = &buffer }, Case.one);
    try run.row("cursorTo", ns, "ns", 2000);
}

/// The hand integer encoder against the formatter.
///
/// Why the writers spell their numbers with a hand encoder rather than
/// `w.print("{d}")`: here through `cursorTo`, against the formatter writing
/// the same sequence. The numbers come out of memory the compiler cannot
/// fold, or ReleaseFast would measure two constants instead of two encoders.
///
/// Measured on the encoder alone, on the machine this was written on: 2.24x
/// in Debug, 1.31x in ReleaseSmall, and 0.92x and 0.94x in ReleaseSafe and
/// ReleaseFast -- slower in the optimizing modes, because the optimiser
/// inlines the formatter's own fast path. Debug and ReleaseSmall are where
/// the suite and most development run, and a writer with no comptime format
/// machinery in it is a smaller one; that is the whole of the case for it.
///
/// The ratio is a figure, not held to anything: two timing loops measured
/// against each other are at the mercy of whichever core the scheduler
/// hands them, and repeated runs on one machine spanned 0.72x to 10.34x in
/// Debug alone. What the encoder owes is checked in src/seq.zig, which
/// spells every value the sequences carry and agrees with the formatter on
/// every value to ten thousand.
fn encoderAgainstFormatter(run: *Run) !void {
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

    var buffer: [32]u8 = undefined;
    var numbers = [_]u32{ 4294967295, 7, 1, 65535, 200, 300, 1, 128 };
    std.mem.doNotOptimizeAway(&numbers);

    var check: [32]u8 = undefined;
    var mine_out: Writer = .fixed(&buffer);
    try morse.cursorTo(&mine_out, numbers[0], numbers[3]);
    var theirs_out: Writer = .fixed(&check);
    try theirs_out.print("\x1b[{d};{d}H", .{ numbers[0], numbers[3] });
    try expect(std.mem.eql(u8, theirs_out.buffered(), mine_out.buffered()), "cursorTo spells its numbers as the formatter does");

    const mine = try run.bestNanosPer(100_000, Mine{ .buffer = &buffer, .numbers = &numbers }, Mine.one);
    const theirs = try run.bestNanosPer(100_000, Theirs{ .buffer = &buffer, .numbers = &numbers }, Theirs.one);
    try run.row("cursorTo, four moves", mine, "ns", 8000);
    try run.figure("the formatter, the same four", theirs, "ns");
    try run.figure("cursorTo against the formatter", theirs / mine, "x");
}

/// A megabyte of pixels costs a quarter of a percent in framing.
fn transmit(run: *Run) !void {
    // A 512 by 512 RGBA image, or 32 by 32 in a smoke run: still two
    // chunks, so the framing between chunks is in it.
    const side: u32 = if (run.smoke) 32 else 512;
    const size = side * side * 4;
    const pixels = try run.gpa.alloc(u8, size);
    defer run.gpa.free(pixels);
    for (pixels, 0..) |*b, i| b.* = @truncate(i *% 131 +% 17);

    const command: morse.Transmit = .{ .image = .{ .id = 1 }, .width = side, .height = side };
    var out: Writer.Allocating = .init(run.gpa);
    defer out.deinit();
    try morse.transmitImage(&out.writer, command, pixels);

    const written = out.written().len;
    const payload = std.base64.standard.Encoder.calcSize(size);
    const overhead = written - payload;

    // Every chunk but the last is exactly the protocol's maximum, so the
    // number of sequences is fixed and so is the framing around them: the
    // payload plus `APC G`, the keys, the `;` and the `ST` on each sequence,
    // with no padding and no repeated header.
    const chunks = (size + morse.graphics_chunk_bytes - 1) / morse.graphics_chunk_bytes;
    var first_keys: [64]u8 = undefined;
    const first = try std.mem.print(&first_keys, "i=1,s={d},v={d},m=1", .{ side, side });
    const chunk_keys = "m=1".len;
    const framing = "\x1b_".len + 1 + 1 + "\x1b\\".len;
    try expect(written == payload + chunks * (framing + chunk_keys) + (first.len - chunk_keys), "an image is its payload and the framing of each chunk");

    const ratio = @as(f64, @floatFromInt(overhead)) * 100 / @as(f64, @floatFromInt(payload));
    try run.row("transmit 1 MB, framing overhead", ratio, "%", 0.25);
    try run.figure("transmit 1 MB, total", written, "bytes");

    const Case = struct {
        command: morse.Transmit,
        pixels: []const u8,
        sink: []u8,
        fn one(c: @This()) !void {
            var w: Writer = .fixed(c.sink);
            try morse.transmitImage(&w, c.command, c.pixels);
            std.mem.doNotOptimizeAway(w.buffered().len);
        }
    };
    const sink = try run.gpa.alloc(u8, written + 64);
    defer run.gpa.free(sink);

    const ns = try run.nanosPer(16, Case{ .command = command, .pixels = pixels, .sink = sink }, Case.one);
    try run.row("transmit 1 MB", ns / 1_000_000, "ms", 400);
    try run.figure("transmit throughput", @as(f64, @floatFromInt(size)) / ns * 1000, "MB/s");
}

/// The input a full-screen program really reads: keys in the kitty protocol
/// and in the legacy spellings, mouse reports, paste markers, plain UTF-8,
/// and the replies that arrive in among them. It ends on a whole piece.
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

/// A megabyte of mixed input, framed and decoded.
fn mixedInputDecode(run: *Run) !void {
    const size: usize = if (run.smoke) 4 * 1024 else 1024 * 1024;
    const input = try mixedInput(run.gpa, size);
    defer run.gpa.free(input);

    var storage: [morse.KeyParser.min_buffer]u8 = undefined;
    var parser: morse.KeyParser = .init(&storage);

    const start = run.nowNanos();
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
    const elapsed = run.nowNanos() - start;

    // The stream is real input, so it must decode to real events rather
    // than to a megabyte of `unhandled`, and nothing is left half-read.
    try expect(events > input.len / 10, "mixed input decodes to an event every ten bytes or fewer");
    try expect(keys > events / 4, "a quarter of the events are keys");
    try expect(parser.pending().len == 0, "the parser holds nothing once the input ends on a sequence");

    const ns_per_byte = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(input.len));
    try run.row("KeyParser, per byte", ns_per_byte, "ns", 200);
    try run.figure("KeyParser throughput", @as(f64, @floatFromInt(input.len)) / @as(f64, @floatFromInt(elapsed)) * 1000, "MB/s");
    try run.figure("KeyParser events", events, "events");
    try run.figure("KeyParser keys", keys, "events");
}

/// A block of printable text, the shape a paste or a fast typist arrives in.
fn plainInput(allocator: std.mem.Allocator, size: usize) ![]u8 {
    const bytes = try allocator.alloc(u8, size);
    for (bytes, 0..) |*b, i| b.* = ' ' + @as(u8, @intCast(i % 95));
    return bytes;
}

/// What the parser costs does not depend on the caller's buffer.
///
/// The grid the per-event top-up used to fall off: the cost of a top-up is
/// the whole of the unread buffer, so doing one per event made a large
/// buffer slower than a small one and a large read slower than a small one
/// -- exactly backwards, and exactly what the README's advice to size for an
/// OSC 52 reply steers a caller into.
fn parserGrid(run: *Run) !void {
    const block: usize = if (run.smoke) 4 * 1024 else 128 * 1024;
    // The best of three per cell, not the mean. What this grid catches is a
    // tilt -- one cell orders of magnitude worse than its neighbours -- and
    // a tilt is in every run, where a machine shared with other work puts
    // noise in some of them.
    const rounds: usize = if (run.smoke) 1 else 3;
    const mixed = try mixedInput(run.gpa, block);
    defer run.gpa.free(mixed);
    const text = try plainInput(run.gpa, block);
    defer run.gpa.free(text);

    const streams = [_]struct { name: []const u8, bytes: []const u8 }{
        .{ .name = "text", .bytes = text },
        .{ .name = "mixed", .bytes = mixed },
    };
    const buffers = [_]usize{ 64, 1024, 16 * 1024 };
    const reads = [_]usize{ 64, 977, 8192, 128 * 1024 };

    var storage: [16 * 1024]u8 = undefined;
    var worst: f64 = 0;
    for (streams) |stream| {
        for (buffers) |size| {
            for (reads) |read| {
                var best: f64 = std.math.floatMax(f64);
                for (0..rounds) |_| {
                    var parser: morse.KeyParser = .init(storage[0..size]);
                    const start = run.nowNanos();
                    var offset: usize = 0;
                    while (offset < stream.bytes.len) {
                        const end = @min(offset + read, stream.bytes.len);
                        var batch = parser.feed(stream.bytes[offset..end]);
                        while (batch.next()) |_| {}
                        offset = end;
                    }
                    const elapsed = run.nowNanos() - start;
                    best = @min(best, @as(f64, @floatFromInt(elapsed)) /
                        @as(f64, @floatFromInt(stream.bytes.len)));
                }
                var name_buf: [128]u8 = undefined;
                const name = try std.mem.print(&name_buf, "KeyParser {s}, buffer {d}, read {d}", .{ stream.name, size, read });
                try run.row(name, best, "ns/byte", 400);
                worst = @max(worst, best);
            }
        }
    }

    // One ceiling for every cell of the grid, because the defect this
    // catches is a whole grid tilting rather than one number moving. Wide:
    // the slowest cell measures under 40 ns a byte in Debug, and the tilt it
    // is here to catch measured 2,272.
    try run.row("KeyParser, worst of the grid", worst, "ns/byte", 400);
}
