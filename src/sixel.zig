//! Sixel pictures, on the writing side: pixels into the `DCS ... q` string
//! DEC terminals drew images with, and xterm, foot, WezTerm, Windows
//! Terminal, mlterm and iTerm2 still do.
//!
//! A sixel is a column of six pixels, one character each: the picture is
//! written six rows at a time, a band, and within a band one colour at a
//! time, each colour a row of characters that says which of the six pixels
//! in every column are that colour. `#n` picks a colour register, `$` goes
//! back to the start of the band, `-` goes down to the next, and `!n`
//! repeats the character after it.
//!
//! The palette is the caller's: up to 256 registers, written as RGB. The
//! pixels are indices into it, or RGBA drawn in the nearest of its colours
//! -- choosing a good palette for a photograph is image processing, and
//! the caller's choice, not a terminal's.
//!
//! The image is written a band at a time and a band 256 columns at a time,
//! from a fixed block of stack, so a picture of any size needs no buffer of
//! its own size; a band wider than that is written a block at a time, each
//! colour skipping to its block with a repeat.
//!
//! Read against the VT330/VT340 programmer reference, chapter 14.

const std = @import("std");
const corpus = @import("corpus.zig");
const seq = @import("seq.zig");
const style = @import("style.zig");

const Writer = std.Io.Writer;
const Rgb = style.Rgb;

/// The pixels of a sixel image.
pub const SixelPixels = union(enum) {
    /// One byte a pixel, left to right and top to bottom: the palette
    /// register the pixel is drawn in.
    indexed: []const u8,
    /// Four bytes a pixel, red, green, blue and alpha, left to right and
    /// top to bottom. Each is drawn in the palette colour nearest it; a
    /// pixel with alpha below 128 is not drawn.
    rgba: []const u8,
};

/// What the terminal does with the pixels an image does not draw, the
/// second parameter of DECSIXEL.
pub const SixelBackground = enum(u8) {
    /// `P2 = 0`: they are drawn in the background colour, register zero on
    /// most terminals.
    fill = 0,
    /// `P2 = 1`: they keep what was under them.
    transparent = 1,
};

/// One sixel image.
pub const Sixel = struct {
    /// Width in pixels.
    width: u32,
    /// Height in pixels.
    height: u32,
    /// The pixels, `width * height` of them.
    pixels: SixelPixels,
    /// The colour registers, at most 256, written in order from register
    /// zero.
    palette: []const Rgb,
    /// An index that is not drawn, for indexed pixels: the transparent
    /// colour of a GIF.
    transparent: ?u8 = null,
    /// `P1`, the pixel aspect ratio by DEC's numbering: 0, 1, 5 and 6 are
    /// 2:1, 2 is 5:1, 3 and 4 are 3:1, 7 to 9 are 1:1. The raster
    /// attributes this writer sends set the ratio to 1:1 on every terminal
    /// that reads them, which is every terminal still drawing sixels.
    aspect: u4 = 0,
    /// `P2`.
    background: SixelBackground = .transparent,
    /// `P3`, the horizontal grid size, which terminals ignore.
    grid: u16 = 0,
};

/// The most colour registers one image may define.
pub const sixel_palette_max = 256;

/// Writes `image` as one sixel string: `DCS P1 ; P2 ; P3 q`, the raster
/// attributes `" 1 ; 1 ; width ; height`, the colour registers, the bands,
/// and `ST`.
///
/// The cursor ends on the last band, not below it: no `-` follows the last
/// band. A palette of more than `sixel_palette_max` entries, pixels fewer
/// than `width * height`, or RGBA pixels with an empty palette is a caller
/// bug, checked in safe builds.
pub fn sixel(w: *Writer, image: Sixel) Writer.Error!void {
    return spellSixel(w, image);
}

/// How many bytes `sixel` writes for `image`, by running the same code into
/// a counter.
pub fn cost(image: Sixel) usize {
    return seq.count(spellSixel, .{image});
}

/// Columns of a band read into the stack at a time.
const block_columns = 256;

/// The bytes of `sixel`, into a `*Writer` or a `*seq.Count`.
fn spellSixel(w: anytype, image: Sixel) !void {
    std.debug.assert(image.palette.len <= sixel_palette_max);
    const pixel_count = @as(usize, image.width) * image.height;
    switch (image.pixels) {
        .indexed => |p| std.debug.assert(p.len >= pixel_count),
        .rgba => |p| std.debug.assert(p.len >= pixel_count * 4 and (pixel_count == 0 or image.palette.len != 0)),
    }

    try w.writeAll(seq.dcs);
    try seq.writeInt(w, image.aspect);
    try w.writeByte(';');
    try seq.writeInt(w, @intFromEnum(image.background));
    try w.writeByte(';');
    try seq.writeInt(w, image.grid);
    try w.writeAll("q\"1;1;");
    try seq.writeInt(w, image.width);
    try w.writeByte(';');
    try seq.writeInt(w, image.height);

    for (image.palette, 0..) |c, i| {
        try w.writeByte('#');
        try seq.writeInt(w, i);
        try w.writeAll(";2;");
        try seq.writeInt(w, percent(c.r));
        try w.writeByte(';');
        try seq.writeInt(w, percent(c.g));
        try w.writeByte(';');
        try seq.writeInt(w, percent(c.b));
    }

    var nearest: Nearest = .{ .palette = image.palette };
    var y: u32 = 0;
    while (y < image.height) : (y += 6) {
        if (y != 0) try w.writeByte('-');
        const rows: u32 = @min(6, image.height - y);
        var band_started = false;
        var x0: u32 = 0;
        while (x0 < image.width) : (x0 += block_columns) {
            const columns: u32 = @min(block_columns, image.width - x0);
            var block: Block = undefined;
            block.read(image, &nearest, y, rows, x0, columns);
            try block.write(w, x0, columns, &band_started);
        }
    }
    try w.writeAll(seq.st);
}

/// A colour channel as the percentage sixel colours are spelled in.
fn percent(channel: u8) u8 {
    return @intCast((@as(u16, channel) * 100 + 127) / 255);
}

/// Six rows of up to `block_columns` pixels, as registers, and which
/// registers they use.
const Block = struct {
    /// The register of each pixel; `undrawn` for one not drawn.
    cells: [6][block_columns]u16,
    /// Which registers the block uses.
    used: std.StaticBitSet(sixel_palette_max),

    const undrawn: u16 = 0xffff;

    fn read(b: *Block, image: Sixel, nearest: *Nearest, y: u32, rows: u32, x0: u32, columns: u32) void {
        b.used = .initEmpty();
        for (0..6) |r| {
            if (r >= rows) {
                @memset(&b.cells[r], undrawn);
                continue;
            }
            const row_start = (@as(usize, y) + r) * image.width + x0;
            for (0..columns) |x| {
                const at = row_start + x;
                const cell: u16 = switch (image.pixels) {
                    .indexed => |p| if (image.transparent != null and p[at] == image.transparent.?) undrawn else p[at],
                    .rgba => |p| if (p[at * 4 + 3] < 128) undrawn else nearest.find(p[at * 4], p[at * 4 + 1], p[at * 4 + 2]),
                };
                b.cells[r][x] = cell;
                if (cell != undrawn) b.used.set(cell);
            }
            @memset(b.cells[r][columns..], undrawn);
        }
    }

    /// Writes each register the block uses as one row of sixels, from
    /// column `x0` of the band.
    fn write(b: *const Block, w: anytype, x0: u32, columns: u32, band_started: *bool) !void {
        var it = b.used.iterator(.{});
        while (it.next()) |register| {
            if (band_started.*) try w.writeByte('$');
            band_started.* = true;
            try w.writeByte('#');
            try seq.writeInt(w, register);
            var run: Run = .{};
            // Back to the block's first column, as blank sixels.
            if (x0 != 0) try run.put(w, '?', x0);
            var last_drawn: u32 = 0;
            var chars: [block_columns]u8 = undefined;
            for (0..columns) |x| {
                var bits: u8 = 0;
                for (0..6) |r| {
                    if (b.cells[r][x] == register) bits |= @as(u8, 1) << @intCast(r);
                }
                chars[x] = '?' + bits;
                if (bits != 0) last_drawn = @intCast(x + 1);
            }
            // Blank sixels after the last drawn one are left out.
            for (chars[0..last_drawn]) |c| try run.put(w, c, 1);
            try run.flush(w);
        }
    }
};

/// A run of one sixel character, written as `!n c` when that is shorter.
const Run = struct {
    char: u8 = 0,
    count: u32 = 0,

    fn put(r: *Run, w: anytype, c: u8, n: u32) !void {
        if (r.count != 0 and c != r.char) try r.flush(w);
        r.char = c;
        r.count += n;
    }

    fn flush(r: *Run, w: anytype) !void {
        if (r.count == 0) return;
        if (r.count > 3) {
            try w.writeByte('!');
            try seq.writeInt(w, r.count);
            try w.writeByte(r.char);
        } else {
            var i: u32 = 0;
            while (i < r.count) : (i += 1) try w.writeByte(r.char);
        }
        r.count = 0;
    }
};

/// The palette register nearest a colour, with the last answers kept.
const Nearest = struct {
    palette: []const Rgb,
    /// Recent answers by colour, `rgb << 8 | register`, with bit 32 set on
    /// an entry that holds one.
    cache: [256]u64 = @splat(0),

    fn find(n: *Nearest, r: u8, g: u8, b: u8) u16 {
        const key: u64 = (@as(u64, r) << 16) | (@as(u64, g) << 8) | b;
        const slot = &n.cache[@as(u8, @truncate((key *% 0x9e3779b1) >> 24))];
        if (slot.* >> 32 == 1 and (slot.* >> 8) & 0xffffff == key) return @intCast(slot.* & 0xff);
        var best: u16 = 0;
        var best_distance: u32 = std.math.maxInt(u32);
        for (n.palette, 0..) |c, i| {
            const dr = @as(i32, r) - c.r;
            const dg = @as(i32, g) - c.g;
            const db = @as(i32, b) - c.b;
            const distance: u32 = @intCast(dr * dr + dg * dg + db * db);
            if (distance < best_distance) {
                best_distance = distance;
                best = @intCast(i);
                if (distance == 0) break;
            }
        }
        slot.* = (@as(u64, 1) << 32) | (key << 8) | best;
        return best;
    }
};

//=========================================================================
// XTSMGRAPHICS: how many colours an image may use, and how big it may be.
//=========================================================================

/// What `querySixelGraphics` asks about, XTSMGRAPHICS's first parameter.
pub const SixelGraphicsItem = enum(u8) {
    /// How many colour registers an image may define: one value.
    color_registers = 1,
    /// The largest image the terminal draws, in pixels: a width and a
    /// height.
    geometry = 2,
};

/// Which value `querySixelGraphics` asks for, XTSMGRAPHICS's action.
pub const SixelGraphicsQuery = enum(u8) {
    /// The value in effect.
    current = 1,
    /// The most it could be set to.
    maximum = 4,
};

/// Asks how many colour registers a sixel image may use, or how big it may
/// be: `CSI ? item ; action ; 0 S`, xterm's XTSMGRAPHICS.
///
/// The answer is `parseSixelGraphics`'s. A terminal without sixels, or
/// without the question, says nothing.
pub fn querySixelGraphics(w: *Writer, item: SixelGraphicsItem, which: SixelGraphicsQuery) Writer.Error!void {
    try w.writeAll(seq.csi ++ "?");
    try seq.writeInt(w, @intFromEnum(item));
    try w.writeByte(';');
    try seq.writeInt(w, @intFromEnum(which));
    try w.writeAll(";0S");
}

/// A terminal's answer to `querySixelGraphics`.
pub const SixelGraphicsReport = struct {
    /// What the answer is about.
    item: SixelGraphicsItem,
    /// Whether the terminal could answer.
    status: Status,
    /// The number of registers, or the width in pixels. Zero when the
    /// terminal sent none.
    value: u32 = 0,
    /// The height in pixels, for `.geometry`. Zero otherwise.
    height: u32 = 0,

    /// XTSMGRAPHICS's status, the reply's second parameter.
    pub const Status = enum(u8) {
        /// The value follows.
        success = 0,
        /// The terminal does not know the item.
        unknown_item = 1,
        /// The terminal does not know the action.
        unknown_action = 2,
        /// The terminal knows both and could not answer.
        failure = 3,
    };

    /// Whether the report carries a value.
    pub fn ok(r: SixelGraphicsReport) bool {
        return r.status == .success;
    }
};

/// Reads an XTSMGRAPHICS answer: `CSI ? item ; status ; values S`, one
/// value for the registers and a width and height for the geometry.
///
/// A refusal may carry no value, or a zero, and reads with its status. An
/// item this package does not ask about, a status outside the four, or
/// more values than the item has, is null. `bytes` must be exactly the
/// sequence, with nothing before or after it.
pub fn parseSixelGraphics(bytes: []const u8) ?SixelGraphicsReport {
    if (!std.mem.startsWith(u8, bytes, seq.csi ++ "?")) return null;
    var rest = bytes[seq.csi.len + 1 ..];

    const item_scan = seq.scanInt(u8, rest) orelse return null;
    rest = rest[item_scan.len..];
    const item: SixelGraphicsItem = switch (item_scan.value) {
        1 => .color_registers,
        2 => .geometry,
        else => return null,
    };
    if (rest.len == 0 or rest[0] != ';') return null;
    rest = rest[1..];

    const status_scan = seq.scanInt(u8, rest) orelse return null;
    rest = rest[status_scan.len..];
    if (status_scan.value > 3) return null;
    var report: SixelGraphicsReport = .{ .item = item, .status = @enumFromInt(status_scan.value) };

    const most: usize = if (item == .geometry) 2 else 1;
    var values: [2]u32 = .{ 0, 0 };
    var count: usize = 0;
    while (rest.len != 0 and rest[0] == ';') {
        if (count == most) return null;
        rest = rest[1..];
        const value = seq.scanParam(u32, rest, 0) orelse return null;
        rest = rest[value.len..];
        values[count] = value.value;
        count += 1;
    }
    if (!std.mem.eql(u8, rest, "S")) return null;
    report.value = values[0];
    report.height = values[1];
    return report;
}

//=========================================================================
// Tests.
//=========================================================================

const testing = std.testing;

fn written(buffer: []u8, image: Sixel) ![]const u8 {
    var w: Writer = .fixed(buffer);
    try sixel(&w, image);
    try testing.expectEqual(w.buffered().len, cost(image));
    return w.buffered();
}

/// Draws a sixel string onto a grid of registers, `undrawn` where nothing
/// was drawn: a reader of the format written independently of the writer,
/// for the tests to hold it to.
fn draw(bytes: []const u8, width: u32, height: u32, grid: []u16, palette: []Rgb) !void {
    @memset(grid, Block.undrawn);
    if (!std.mem.startsWith(u8, bytes, "\x1bP") or !std.mem.endsWith(u8, bytes, "\x1b\\")) return error.NotSixel;
    var i = (std.mem.indexOfScalar(u8, bytes, 'q') orelse return error.NotSixel) + 1;
    const end = bytes.len - 2;
    var x: u32 = 0;
    var band: u32 = 0;
    var register: u16 = 0;
    while (i < end) {
        const c = bytes[i];
        switch (c) {
            '"' => {
                i += 1;
                while (i < end and (std.ascii.isDigit(bytes[i]) or bytes[i] == ';')) i += 1;
            },
            '#' => {
                i += 1;
                var fields: [5]u32 = undefined;
                var n: usize = 0;
                while (n < fields.len) {
                    const scan = seq.scanInt(u32, bytes[i..end]) orelse break;
                    fields[n] = scan.value;
                    n += 1;
                    i += scan.len;
                    if (i < end and bytes[i] == ';') i += 1 else break;
                }
                register = @intCast(fields[0]);
                if (n == 5) palette[register] = .{ .r = @intCast(fields[2]), .g = @intCast(fields[3]), .b = @intCast(fields[4]) };
            },
            '$' => {
                x = 0;
                i += 1;
            },
            '-' => {
                x = 0;
                band += 1;
                i += 1;
            },
            '!', '?'...'~' => {
                var count: u32 = 1;
                if (c == '!') {
                    const scan = seq.scanInt(u32, bytes[i + 1 .. end]) orelse return error.BadRepeat;
                    count = scan.value;
                    i += 1 + scan.len;
                }
                const bits = bytes[i] - '?';
                i += 1;
                var k: u32 = 0;
                while (k < count) : (k += 1) {
                    for (0..6) |r| if (bits & (@as(u8, 1) << @intCast(r)) != 0) {
                        const py = band * 6 + @as(u32, @intCast(r));
                        if (py >= height or x >= width) return error.OutOfBounds;
                        grid[py * width + x] = register;
                    };
                    x += 1;
                }
            },
            else => return error.UnexpectedByte,
        }
    }
}

test "a small image is the header, the registers, and one band" {
    const palette = [_]Rgb{ .{ .r = 0, .g = 0, .b = 0 }, .{ .r = 255, .g = 128, .b = 0 } };
    // Two columns, three rows: the left column register 1, the right 0.
    const pixels = [_]u8{ 1, 0, 1, 0, 1, 0 };
    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "\x1bP0;1;0q\"1;1;2;3#0;2;0;0;0#1;2;100;50;0#0?F$#1F\x1b\\",
        try written(&buffer, .{ .width = 2, .height = 3, .pixels = .{ .indexed = &pixels }, .palette = &palette }),
    );
}

test "the DECSIXEL parameters are the caller's" {
    const palette = [_]Rgb{.{ .r = 255, .g = 255, .b = 255 }};
    var buffer: [128]u8 = undefined;
    const bytes = try written(&buffer, .{
        .width = 1,
        .height = 1,
        .pixels = .{ .indexed = &.{0} },
        .palette = &palette,
        .aspect = 9,
        .background = .fill,
        .grid = 3,
    });
    try testing.expect(std.mem.startsWith(u8, bytes, "\x1bP9;0;3q\"1;1;1;1#0;2;100;100;100#0@"));
}

test "runs of one sixel are written as repeats, and blank tails are left out" {
    const palette = [_]Rgb{.{ .r = 0, .g = 0, .b = 0 }};
    var pixels: [20]u8 = @splat(0);
    var buffer: [128]u8 = undefined;
    // Twenty columns of one row: one repeat.
    try testing.expect(std.mem.endsWith(u8, try written(&buffer, .{ .width = 20, .height = 1, .pixels = .{ .indexed = &pixels }, .palette = &palette, .transparent = 1 }), "#0!20@\x1b\\"));
    // Three is shorter spelled out.
    pixels[3] = 1;
    try testing.expect(std.mem.endsWith(u8, try written(&buffer, .{ .width = 4, .height = 1, .pixels = .{ .indexed = pixels[0..4] }, .palette = &palette, .transparent = 1 }), "#0@@@\x1b\\"));
}

test "bands are six rows, and the last band is not followed by a newline" {
    const palette = [_]Rgb{.{ .r = 0, .g = 0, .b = 0 }};
    const pixels: [13]u8 = @splat(0);
    var buffer: [128]u8 = undefined;
    try testing.expect(std.mem.endsWith(u8, try written(&buffer, .{ .width = 1, .height = 13, .pixels = .{ .indexed = &pixels }, .palette = &palette }), "#0~-#0~-#0@\x1b\\"));
}

test "an RGBA pixel is drawn in the nearest register, and a transparent one not at all" {
    const palette = [_]Rgb{ .{ .r = 0, .g = 0, .b = 0 }, .{ .r = 250, .g = 250, .b = 250 }, .{ .r = 200, .g = 0, .b = 0 } };
    const pixels = [_]u8{
        10,  10,  10,  255,
        240, 255, 255, 200,
        180, 30,  20,  128,
        255, 0,   0,   127,
    };
    var buffer: [256]u8 = undefined;
    const bytes = try written(&buffer, .{ .width = 4, .height = 1, .pixels = .{ .rgba = &pixels }, .palette = &palette });
    var grid: [4]u16 = undefined;
    var read_palette: [256]Rgb = undefined;
    try draw(bytes, 4, 1, &grid, &read_palette);
    try testing.expectEqualSlices(u16, &.{ 0, 1, 2, Block.undrawn }, &grid);
}

test "the image draws back as itself, of any size and in any palette" {
    var prng: std.Random.DefaultPrng = .init(7);
    const r = prng.random();
    var pixels: [600 * 13]u8 = undefined;
    var grid: [600 * 13]u16 = undefined;
    var palette: [256]Rgb = undefined;
    for (&palette) |*c| c.* = .{ .r = r.int(u8), .g = r.int(u8), .b = r.int(u8) };
    var buffer: [1 << 17]u8 = undefined;
    for ([_][2]u32{ .{ 1, 1 }, .{ 7, 5 }, .{ 255, 6 }, .{ 256, 7 }, .{ 257, 12 }, .{ 600, 13 }, .{ 0, 4 }, .{ 3, 0 } }) |size| {
        const n = size[0] * size[1];
        for ([_]u16{ 1, 2, 16, 256 }) |colours| {
            for (pixels[0..n]) |*p| p.* = @intCast(r.uintLessThan(u16, colours));
            const transparent: ?u8 = if (colours > 2) 1 else null;
            const bytes = try written(&buffer, .{
                .width = size[0],
                .height = size[1],
                .pixels = .{ .indexed = pixels[0..n] },
                .palette = palette[0..colours],
                .transparent = transparent,
            });
            var read_palette: [256]Rgb = undefined;
            try draw(bytes, size[0], size[1], grid[0..n], &read_palette);
            for (pixels[0..n], grid[0..n]) |want, got| {
                if (transparent != null and want == transparent.?) {
                    try testing.expectEqual(Block.undrawn, got);
                } else {
                    try testing.expectEqual(@as(u16, want), got);
                }
            }
            for (palette[0..colours], read_palette[0..colours]) |want, got| {
                try testing.expectEqual(Rgb{ .r = percent(want.r), .g = percent(want.g), .b = percent(want.b) }, got);
            }
        }
    }
}

test "a picture of any width is written from a fixed block of stack" {
    // A row wider than the block is written a block at a time; the second
    // block's colour skips to it with a repeat of blank sixels.
    const palette = [_]Rgb{ .{ .r = 0, .g = 0, .b = 0 }, .{ .r = 255, .g = 255, .b = 255 } };
    var pixels: [block_columns + 2]u8 = @splat(0);
    pixels[block_columns + 1] = 1;
    var buffer: [128]u8 = undefined;
    const bytes = try written(&buffer, .{ .width = pixels.len, .height = 1, .pixels = .{ .indexed = &pixels }, .palette = &palette });
    try testing.expect(std.mem.endsWith(u8, bytes, "#0!256@$#0!256?@$#1!257?@\x1b\\"));
}

test "querySixelGraphics asks for the registers and the geometry" {
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try querySixelGraphics(&w, .color_registers, .current);
    try querySixelGraphics(&w, .geometry, .maximum);
    try testing.expectEqualStrings("\x1b[?1;1;0S\x1b[?2;4;0S", w.buffered());
}

test "parseSixelGraphics reads xterm's answers and its refusals" {
    const registers = parseSixelGraphics("\x1b[?1;0;256S").?;
    try testing.expectEqual(SixelGraphicsItem.color_registers, registers.item);
    try testing.expect(registers.ok());
    try testing.expectEqual(@as(u32, 256), registers.value);

    const geometry = parseSixelGraphics("\x1b[?2;0;1000;1000S").?;
    try testing.expectEqual(SixelGraphicsItem.geometry, geometry.item);
    try testing.expectEqual(@as(u32, 1000), geometry.value);
    try testing.expectEqual(@as(u32, 1000), geometry.height);

    // A refusal, with and without a value.
    try testing.expectEqual(SixelGraphicsReport.Status.failure, parseSixelGraphics("\x1b[?2;3;0S").?.status);
    try testing.expectEqual(SixelGraphicsReport.Status.unknown_item, parseSixelGraphics("\x1b[?1;1S").?.status);
    try testing.expect(!parseSixelGraphics("\x1b[?1;1S").?.ok());

    for ([_][]const u8{
        "\x1b[?3;0;640;480S", // ReGIS, not asked about
        "\x1b[?1;4;256S", // no such status
        "\x1b[?1;0;256;1S", // a second value for the registers
        "\x1b[?2;0;1;2;3S", // a third for the geometry
        "\x1b[1;0;256S", // no private marker
        "\x1b[?1;0;256", // no final byte
        "\x1b[?1;0;256Sx", // something after it
        "\x1b[?2026;1$y", // a mode report
        "",
    }) |bytes| try testing.expect(parseSixelGraphics(bytes) == null);
}

test "fuzz parseSixelGraphics" {
    // The property: no input panics or overflows, and every report that
    // parses writes back, values and all, to a report that parses the same.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [64]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];

            const report = parseSixelGraphics(bytes) orelse return;

            var output: [64]u8 = undefined;
            var w: Writer = .fixed(&output);
            try w.print("\x1b[?{d};{d};{d}", .{ @intFromEnum(report.item), @intFromEnum(report.status), report.value });
            if (report.item == .geometry) try w.print(";{d}", .{report.height});
            try w.writeByte('S');
            try testing.expectEqual(report, parseSixelGraphics(w.buffered()).?);
        }
    }.one, .{ .corpus = &.{
        corpus.seed("\x1b[?1;0;256S"),
        corpus.seed("\x1b[?2;0;1000;1000S"),
        corpus.seed("\x1b[?2;3;0S"),
        corpus.seed("\x1b[?1;1S"),
        corpus.seed("\x1b[?2;0;4294967296;1S"),
        corpus.seed("\x1b[?1;0;256;1S"),
        corpus.seed("\x1b[?3;0;640;480S"),
    } });
}
