//! Terminal workloads measured through shakedown.bench. Input generation,
//! allocation and byte checks happen before measurement; callbacks reuse them.
const std = @import("std");
const morse = @import("morse");
const bench = @import("shakedown").bench;
const provenance = @import("preflight_bench_options");
const Writer = std.Io.Writer;
pub const WorkloadError = Writer.Error || error{PartialInput};

pub const OptionsError = error{ UnknownArgument, MissingRow, DuplicateArgument };
pub fn options(args: []const []const u8) OptionsError!bench.Options {
    var result: bench.Options = .{};
    var i: usize = 1;
    var row_seen = false;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--smoke")) {
            if (result.smoke) return error.DuplicateArgument;
            result.smoke = true;
        } else if (std.mem.eql(u8, args[i], "--row")) {
            if (row_seen) return error.DuplicateArgument;
            row_seen = true;
            i += 1;
            if (i == args.len or std.mem.startsWith(u8, args[i], "--")) return error.MissingRow;
            result.prefix = args[i];
        } else return error.UnknownArgument;
    }
    return result;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const selected = try options(args);
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    try measure(init.gpa, init.io, &output.interface, selected, .{
        .commit = provenance.commit,
        .cpu = provenance.cpu,
        .os = provenance.os,
    });
    try output.interface.flush();
}

pub fn measure(gpa: std.mem.Allocator, io: std.Io, out: *Writer, selected: bench.Options, metadata: bench.Metadata) !void {
    var context = try Context.init(gpa, selected.smoke);
    defer context.deinit(gpa);
    try context.check();
    std.mem.doNotOptimizeAway(&context.numbers);
    try bench.run(WorkloadError, gpa, io, out, &context, &.{
        .{ .name = "diffStyle, two calls", .unit = "two calls", .initial = 200_000, .run = Context.styleDiff },
        .{ .name = "cursorTo", .unit = "move", .initial = 200_000, .run = Context.cursorMove },
        .{ .name = "cursorTo, four moves", .unit = "four moves", .initial = 100_000, .run = Context.encoder },
        .{ .name = "the formatter, the same four", .unit = "four moves", .initial = 100_000, .run = Context.formatter },
        .{ .name = "transmit 1 MB", .unit = "image", .initial = 16, .run = Context.transmit },
        .{ .name = "KeyParser, per byte", .unit = "byte", .initial = context.mixed.len, .smoke = context.mixed.len, .run = Context.decode },
    }, metadata, selected);

    // Keep the original two streams, three buffers and four read sizes.
    const streams = [_]struct { name: []const u8, bytes: []const u8 }{
        .{ .name = "text", .bytes = context.text },
        .{ .name = "mixed", .bytes = context.grid_mixed },
    };
    for (streams) |stream| {
        context.stream = stream.bytes;
        for ([_]usize{ 64, 1024, 16 * 1024 }) |size| {
            context.buffer_size = size;
            for ([_]usize{ 64, 977, 8192, 128 * 1024 }) |read| {
                context.read_size = read;
                var name_buffer: [128]u8 = undefined;
                const name = try std.mem.print(&name_buffer, "KeyParser {s}, buffer {d}, read {d}", .{ stream.name, size, read });
                try bench.run(WorkloadError, gpa, io, out, &context, &.{.{ .name = name, .unit = "byte", .initial = stream.bytes.len, .smoke = stream.bytes.len, .run = Context.grid }}, metadata, selected);
            }
        }
    }
}

/// Only workload data and reusable output storage; measuring has no state here.
pub const Context = struct {
    pixels: []u8,
    sink: []u8,
    mixed: []u8,
    grid_mixed: []u8,
    text: []u8,
    command: morse.Transmit,
    numbers: [8]u32 = .{ 4294967295, 7, 1, 65535, 200, 300, 1, 128 },
    buffer: [64]u8 = undefined,
    storage: [16 * 1024]u8 = undefined,
    stream: []const u8 = &.{},
    buffer_size: usize = 0,
    read_size: usize = 0,

    const lit: morse.Style = .{ .bold = true, .fg = .ansi(.cyan) };
    const plain: morse.Style = .{ .fg = .ansi(.cyan) };

    pub fn init(gpa: std.mem.Allocator, smoke: bool) !Context {
        const side: u32 = if (smoke) 32 else 512;
        const pixels = try gpa.alloc(u8, side * side * 4);
        errdefer gpa.free(pixels);
        for (pixels, 0..) |*byte, i| byte.* = @truncate(i *% 131 +% 17);
        const command: morse.Transmit = .{ .image = .{ .id = morse.ImageId.fromRaw(1) }, .width = morse.Pixels.fromRaw(side), .height = morse.Pixels.fromRaw(side) };
        var output: Writer.Allocating = .init(gpa);
        defer output.deinit();
        try morse.transmitImage(&output.writer, command, pixels);
        const sink = try gpa.alloc(u8, output.written().len + 64);
        errdefer gpa.free(sink);
        const mixed = try mixedInput(gpa, if (smoke) 4 * 1024 else 1024 * 1024);
        errdefer gpa.free(mixed);
        const grid_mixed = try mixedInput(gpa, if (smoke) 4 * 1024 else 128 * 1024);
        errdefer gpa.free(grid_mixed);
        const text = try plainInput(gpa, if (smoke) 4 * 1024 else 128 * 1024);
        return .{ .pixels = pixels, .sink = sink, .mixed = mixed, .grid_mixed = grid_mixed, .text = text, .command = command };
    }

    pub fn deinit(context: *Context, gpa: std.mem.Allocator) void {
        gpa.free(context.text);
        gpa.free(context.grid_mixed);
        gpa.free(context.mixed);
        gpa.free(context.sink);
        gpa.free(context.pixels);
    }

    pub fn check(context: *Context) !void {
        var out: Writer = .fixed(&context.buffer);
        try morse.diffStyle(&out, lit, plain);
        try expect(std.mem.eql(u8, "\x1b[22m", out.buffered()));
        out.end = 0;
        try morse.diffStyle(&out, plain, plain);
        try expect(out.end == 0);
        try morse.cursorTo(&out, 1, 1);
        try expect(std.mem.eql(u8, "\x1b[1;1H", out.buffered()));
        out.end = 0;
        try morse.cursorTo(&out, 200, 300);
        try expect(std.mem.eql(u8, "\x1b[200;300H", out.buffered()));
        out.end = 0;
        try morse.cursorTo(&out, context.numbers[0], context.numbers[3]);
        var formatted: [64]u8 = undefined;
        var formatter_out: Writer = .fixed(&formatted);
        try formatter_out.print("\x1b[{d};{d}H", .{ context.numbers[0], context.numbers[3] });
        try expect(std.mem.eql(u8, out.buffered(), formatter_out.buffered()));
        var image: Writer = .fixed(context.sink);
        try morse.transmitImage(&image, context.command, context.pixels);
        const payload = std.base64.standard.Encoder.calcSize(context.pixels.len);
        const chunks = (context.pixels.len + morse.graphics_chunk_bytes - 1) / morse.graphics_chunk_bytes;
        var first_keys: [64]u8 = undefined;
        const first = try std.mem.print(&first_keys, "i=1,s={d},v={d},m=1", .{ context.command.width.raw(), context.command.height.raw() });
        const framing = "\x1b_".len + 1 + 1 + "\x1b\\".len;
        try expect(image.end == payload + chunks * (framing + "m=1".len) + (first.len - "m=1".len));
        // Full-size byte budgets and cross-buffer event equivalence stay in
        // src/testing/work_test.zig, independent of clocks and smoke sizing.
        const counts = context.decodeOne();
        try expect(counts.events > context.mixed.len / 10);
        try expect(counts.keys > counts.events / 4);
        try expect(counts.pending == 0);
    }

    pub fn styleDiff(context: *Context, units: u64) WorkloadError!void {
        for (0..units) |_| {
            var out: Writer = .fixed(&context.buffer);
            try morse.diffStyle(&out, lit, plain);
            try morse.diffStyle(&out, plain, lit);
            std.mem.doNotOptimizeAway(out.buffered().len);
        }
    }

    pub fn cursorMove(context: *Context, units: u64) WorkloadError!void {
        for (0..units) |_| {
            var out: Writer = .fixed(context.buffer[0..32]);
            try morse.cursorTo(&out, 200, 300);
            std.mem.doNotOptimizeAway(out.buffered().len);
        }
    }

    pub fn encoder(context: *Context, units: u64) WorkloadError!void {
        for (0..units) |_| {
            var out: Writer = .fixed(context.buffer[0..32]);
            var i: usize = 0;
            while (i < context.numbers.len) : (i += 2) {
                try morse.cursorTo(&out, context.numbers[i], context.numbers[i + 1]);
                out.end = 0;
            }
            std.mem.doNotOptimizeAway(out.end);
        }
    }

    pub fn formatter(context: *Context, units: u64) WorkloadError!void {
        for (0..units) |_| {
            var out: Writer = .fixed(context.buffer[0..32]);
            var i: usize = 0;
            while (i < context.numbers.len) : (i += 2) {
                try out.print("\x1b[{d};{d}H", .{ context.numbers[i], context.numbers[i + 1] });
                out.end = 0;
            }
            std.mem.doNotOptimizeAway(out.end);
        }
    }

    pub fn transmit(context: *Context, units: u64) WorkloadError!void {
        for (0..units) |_| {
            var out: Writer = .fixed(context.sink);
            try morse.transmitImage(&out, context.command, context.pixels);
            std.mem.doNotOptimizeAway(out.buffered().len);
        }
    }

    pub fn decode(context: *Context, units: u64) WorkloadError!void {
        if (units % context.mixed.len != 0) return error.PartialInput;
        for (0..units / context.mixed.len) |_| std.mem.doNotOptimizeAway(context.decodeOne());
    }

    fn decodeOne(context: *Context) struct { events: usize, keys: usize, pending: usize } {
        var parser: morse.KeyParser = .init(context.storage[0..morse.KeyParser.min_buffer]);
        var events: usize = 0;
        var keys: usize = 0;
        var offset: usize = 0;
        while (offset < context.mixed.len) {
            const end = @min(offset + 977, context.mixed.len);
            var batch = parser.feed(context.mixed[offset..end]);
            while (batch.next()) |event| {
                events += 1;
                if (event == .key) keys += 1;
            }
            offset = end;
        }
        return .{ .events = events, .keys = keys, .pending = parser.pending().len };
    }

    pub fn grid(context: *Context, units: u64) WorkloadError!void {
        if (units % context.stream.len != 0) return error.PartialInput;
        for (0..units / context.stream.len) |_| {
            var parser: morse.KeyParser = .init(context.storage[0..context.buffer_size]);
            var offset: usize = 0;
            while (offset < context.stream.len) {
                const end = @min(offset + context.read_size, context.stream.len);
                var batch = parser.feed(context.stream[offset..end]);
                while (batch.next()) |_| {}
                offset = end;
            }
            std.mem.doNotOptimizeAway(parser.pending().len);
        }
    }
};

fn expect(ok: bool) error{ExpectationFailed}!void {
    if (!ok) return error.ExpectationFailed;
}

/// Whole pieces of mixed terminal input, including replies between key events.
fn mixedInput(allocator: std.mem.Allocator, size: usize) ![]u8 {
    const pieces = [_][]const u8{
        "\x1b[97;5u",   "a",                      "\x1b[A",    "\x1b[1;5C", "\x1b[<0;40;12M", "\x1b[M\x20\x21\x21",
        "\x1b[200~",    "pasted",                 "\x1b[201~", "\u{00e9}",  "\u{4e2d}",       "\x1b[?2026;1$y",
        "\x1b[?997;1n", "\x1b[48;24;80;384;640t", "\x1b[15~",  "\x1bOP",    "\x1b[27;5;97~",  "\x1b]52;c;aGk=\x1b\\",
        "\r",           "\x7f",
    };
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var i: usize = 0;
    while (list.items.len < size) : (i += 1) try list.appendSlice(allocator, pieces[i % pieces.len]);
    return list.toOwnedSlice(allocator);
}

fn plainInput(allocator: std.mem.Allocator, size: usize) ![]u8 {
    const bytes = try allocator.alloc(u8, size);
    for (bytes, 0..) |*byte, i| {
        // safe: i % 95 is an ASCII offset that fits u8.
        byte.* = ' ' + @as(u8, @intCast(i % 95));
    }
    return bytes;
}
