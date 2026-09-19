//! The multiple cursors protocol: cursors the terminal draws besides the one
//! it already has.
//!
//! An editor showing the same edit happening in eight places has always drawn
//! seven of those cursors itself, out of a reverse-video cell or a block
//! glyph. Those are not cursors: they do not blink with the real one, they do
//! not take the user's cursor colour, and they do not animate. This protocol
//! asks the terminal for real ones, at cells or over rectangles, and asks it
//! what it is drawing now.
//!
//! Every sequence here is `CSI >` something and the two bytes `SP q` — the
//! same trailer DECSCUSR uses, which is why `cursorShape` in `mode.zig` is
//! its nearest neighbour and why the private `>` is what tells the two apart.
//!
//! Read against the protocol text of 2026-01-08.
//!
//! What this file will never hold: a model of where the extra cursors are. A
//! terminal is asked and answers; which cells an editor wants cursors in, and
//! what to do when the screen scrolls out from under them, is the editor's.
//! The replies here are read out of `Event.unhandled`, like every other reply
//! in this package, because a program that asked a question is the one that
//! knows the answer is coming.

const std = @import("std");
const corpus = @import("corpus.zig");
const seq = @import("seq.zig");
const style = @import("style.zig");

const Writer = std.Io.Writer;

/// A colour given directly, as `setStyle` takes one.
const Rgb = style.Rgb;

/// The two bytes that end every sequence in this protocol: `SP q`.
const trailer = " q";

/// The three bytes that begin every one: `CSI >`.
const introducer = seq.csi ++ ">";

//=========================================================================
// What a program says.
//=========================================================================

/// The shape an extra cursor takes, in the numbering this protocol uses.
///
/// Not `CursorShape`: DECSCUSR numbers its shapes differently, pairs each
/// with a blinking variant, and has nothing to say about a cursor that is not
/// there. Here `.none` is how a cursor is taken away, and the blink is always
/// the main cursor's.
pub const ExtraCursorShape = enum(u8) {
    /// No cursor. Setting this on a cell is how a cursor is removed.
    none = 0,
    /// A block.
    block = 1,
    /// A vertical bar.
    beam = 2,
    /// An underline.
    underline = 3,
    /// Whatever the main cursor is currently shaped like, which is what an
    /// editor usually wants: the extra cursors then follow the user's
    /// configuration and the mode the editor is in.
    main = 29,
};

/// A cell, counting from one at the top-left. The wire order is `row:col`,
/// which is why the protocol calls them `y` and `x`.
pub const CursorCell = struct {
    /// The row, where the topmost row is 1.
    row: u32,
    /// The column, where the leftmost column is 1.
    col: u32,
};

/// A rectangle of cells, both corners included, counting from one.
pub const CursorRect = struct {
    /// The topmost row.
    top: u32,
    /// The leftmost column.
    left: u32,
    /// The bottommost row.
    bottom: u32,
    /// The rightmost column.
    right: u32,
};

/// Where a shape is being set, as the co-ordinate type spells it.
pub const CursorSpan = union(enum) {
    /// Type 0: wherever the main cursor is, with no co-ordinates.
    main_cursor,
    /// Type 2: a list of cells.
    cells: []const CursorCell,
    /// Type 4: a list of rectangles. An empty list is the whole screen,
    /// which is how every extra cursor is cleared at once.
    rects: []const CursorRect,
};

/// Which half of the extra cursors' colour pair is being set.
///
/// There is one pair for all of them, not one per cursor: the protocol says
/// so, for the terminal's sake.
pub const CursorColorTarget = enum(u8) {
    /// The colour of the text in the cell the cursor is on. Mimics SGR 30.
    text = 30,
    /// The colour of the cursor itself. Mimics SGR 40.
    cursor = 40,
};

/// A colour for the extra cursors, in the forms this protocol spells.
pub const CursorColor = union(enum) {
    /// Space 0: the main cursor's own colour, whatever that is. If the main
    /// cursor is drawn in reverse video, so are these — with the main
    /// cursor's colours, not the colours of the cells they sit on.
    unset,
    /// Space 1: reverse video. On `.cursor` it means the cursor takes the
    /// cell's foreground and the glyph takes its background, and the `.text`
    /// colour is then ignored entirely.
    special,
    /// Space 2: a colour given directly.
    rgb: Rgb,
    /// Space 5: an entry of the palette.
    indexed: u8,
};

//=========================================================================
// Writing.
//=========================================================================

/// Sets `shape` on every cell the spans name: `CSI > shape ; ... SP q`.
///
/// The spans are written in the order given and the terminal applies them in
/// that order, so one call can put the same shape at three cells and over a
/// rectangle. Cells outside the screen are ignored by the terminal rather
/// than being an error.
///
/// An empty span list writes a sequence that names no cells, which is legal
/// and does nothing.
pub fn extraCursors(w: *Writer, shape: ExtraCursorShape, spans: []const CursorSpan) Writer.Error!void {
    try w.writeAll(introducer);
    try seq.writeInt(w, @intFromEnum(shape));
    for (spans) |span| {
        try w.writeByte(';');
        switch (span) {
            .main_cursor => try w.writeByte('0'),
            .cells => |cells| {
                try w.writeByte('2');
                for (cells) |cell| {
                    try w.writeByte(':');
                    try seq.writeInt(w, cell.row);
                    try w.writeByte(':');
                    try seq.writeInt(w, cell.col);
                }
            },
            .rects => |rects| {
                try w.writeByte('4');
                for (rects) |rect| {
                    try w.writeByte(':');
                    try seq.writeInt(w, rect.top);
                    try w.writeByte(':');
                    try seq.writeInt(w, rect.left);
                    try w.writeByte(':');
                    try seq.writeInt(w, rect.bottom);
                    try w.writeByte(':');
                    try seq.writeInt(w, rect.right);
                }
            },
        }
    }
    try w.writeAll(trailer);
}

/// Takes every extra cursor off the screen: `CSI > 0 ; 4 SP q`.
///
/// The shape `.none` over a rectangle with no co-ordinates, which is the
/// whole screen. What a program runs on the way out, and after any redraw
/// that has moved what the cursors were marking.
pub fn extraCursorsClear(w: *Writer) Writer.Error!void {
    try extraCursors(w, .none, &.{.{ .rects = &.{} }});
}

/// Sets one half of the extra cursors' colour pair:
/// `CSI > which ; space : ... SP q`.
pub fn extraCursorColor(
    w: *Writer,
    which: CursorColorTarget,
    color: CursorColor,
) Writer.Error!void {
    try w.writeAll(introducer);
    try seq.writeInt(w, @intFromEnum(which));
    try w.writeByte(';');
    switch (color) {
        .unset => try w.writeByte('0'),
        .special => try w.writeByte('1'),
        .rgb => |c| {
            try w.writeAll("2:");
            try seq.writeInt(w, c.r);
            try w.writeByte(':');
            try seq.writeInt(w, c.g);
            try w.writeByte(':');
            try seq.writeInt(w, c.b);
        },
        .indexed => |n| {
            try w.writeAll("5:");
            try seq.writeInt(w, n);
        },
    }
    try w.writeAll(trailer);
}

/// Asks whether the terminal implements this protocol at all:
/// `CSI > SP q`.
///
/// A terminal that does answers with the list of shapes and operations it
/// supports, read by `parseExtraCursorSupport`. One that does not answers
/// nothing, so send `queryDeviceAttributes` straight after and take the DA1
/// answer arriving alone as the no.
pub fn queryExtraCursorSupport(w: *Writer) Writer.Error!void {
    try w.writeAll(introducer ++ trailer);
}

/// Asks what extra cursors are set now: `CSI > 100 SP q`.
///
/// The answer is one sequence listing every shape and where it is, read by
/// `parseExtraCursors`.
pub fn queryExtraCursors(w: *Writer) Writer.Error!void {
    try w.writeAll(introducer ++ "100" ++ trailer);
}

/// Asks what colour pair the extra cursors are drawn in:
/// `CSI > 101 SP q`, answered by `parseExtraCursorColors`.
pub fn queryExtraCursorColors(w: *Writer) Writer.Error!void {
    try w.writeAll(introducer ++ "101" ++ trailer);
}

//=========================================================================
// Reading the answers.
//=========================================================================

/// What a terminal says it can do with extra cursors.
///
/// Every field is one of the numbers the reply may list. A reply listing
/// none of them — and, equally, no reply at all — means the protocol is not
/// there.
pub const ExtraCursorSupport = struct {
    /// Shape 1.
    block: bool = false,
    /// Shape 2.
    beam: bool = false,
    /// Shape 3.
    underline: bool = false,
    /// Shape 29: following the main cursor's shape.
    main: bool = false,
    /// Operation 30: setting the colour of the text under the cursors.
    text_color: bool = false,
    /// Operation 40: setting the colour of the cursors.
    cursor_color: bool = false,
    /// Operation 100: answering `queryExtraCursors`.
    query_cursors: bool = false,
    /// Operation 101: answering `queryExtraCursorColors`.
    query_colors: bool = false,

    /// Whether the terminal claimed anything at all.
    pub fn any(s: ExtraCursorSupport) bool {
        return s.block or s.beam or s.underline or s.main or
            s.text_color or s.cursor_color or s.query_cursors or s.query_colors;
    }
};

/// Reads the answer to `queryExtraCursorSupport`:
/// `CSI > 1 ; 2 ; 3 ; 29 ; 30 ; 40 ; 100 ; 101 SP q`, or any subset of it.
///
/// Numbers the protocol has not defined are read past rather than refused,
/// since it will define more. An empty list parses, and says the terminal
/// implements nothing.
///
/// Note that `CSI > 100 SP q` is both a support reply listing only operation
/// 100 and an empty answer to `queryExtraCursors`; nothing in the bytes tells
/// them apart, and a program knows which question it asked.
///
/// Returns null for anything else. `bytes` must be exactly the sequence.
pub fn parseExtraCursorSupport(bytes: []const u8) ?ExtraCursorSupport {
    const body = stripSequence(bytes) orelse return null;

    var support: ExtraCursorSupport = .{};
    if (body.len == 0) return support;

    var rest = body;
    while (true) {
        const end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
        const scan = seq.scanInt(u32, rest[0..end]) orelse return null;
        if (scan.len != end) return null;
        switch (scan.value) {
            1 => support.block = true,
            2 => support.beam = true,
            3 => support.underline = true,
            29 => support.main = true,
            30 => support.text_color = true,
            40 => support.cursor_color = true,
            100 => support.query_cursors = true,
            101 => support.query_colors = true,
            else => {},
        }
        if (end == rest.len) return support;
        rest = rest[end + 1 ..];
        if (rest.len == 0) return null;
    }
}

/// One extra cursor the terminal says is set: a shape, and one place.
pub const ExtraCursorAt = struct {
    /// The shape at that place.
    shape: ExtraCursorShape,
    /// Where it is.
    where: Where,

    /// The three things a co-ordinate type can name.
    pub const Where = union(enum) {
        /// Type 0: wherever the main cursor is.
        main_cursor,
        /// Type 2: one cell.
        cell: CursorCell,
        /// Type 4: one rectangle.
        rect: CursorRect,
    };
};

/// A terminal's answer to `queryExtraCursors`, still as bytes.
///
/// The reply carries an unbounded list and `morse` allocates nothing, so what
/// comes back is a cursor over the bytes rather than an array. It borrows
/// from them and is valid for exactly as long as they are.
pub const ExtraCursorReport = struct {
    /// The blocks, with the leading `100` removed.
    blocks: []const u8,

    /// Every cursor the reply names, one at a time.
    pub fn iterator(report: ExtraCursorReport) ExtraCursors {
        return .{ .rest = report.blocks };
    }
};

/// The cursors one reply names, flattened: a block naming four cells yields
/// four of these.
pub const ExtraCursors = struct {
    /// The blocks not yet read.
    rest: []const u8,
    /// The block being read, with its shape and type removed.
    numbers: []const u8 = "",
    /// The shape of the block being read.
    shape: ExtraCursorShape = .none,
    /// How many numbers one place in the block takes: 0, 2 or 4.
    stride: u8 = 0,

    /// The next cursor, or null when there are none left.
    ///
    /// Co-ordinates that do not make up a whole place are dropped, which is
    /// what the protocol requires of a terminal reading the same list.
    pub fn next(it: *ExtraCursors) ?ExtraCursorAt {
        while (true) {
            // A block with nothing left in it is finished, whatever its
            // stride was: move to the next one, or say there is none. This
            // is the only place `rest` shrinks, so the loop terminates.
            if (it.numbers.len == 0) {
                if (!it.advance()) return null;
                if (it.stride == 0) return .{ .shape = it.shape, .where = .main_cursor };
                continue;
            }

            var values: [4]u32 = undefined;
            var taken: u8 = 0;
            while (taken < it.stride) : (taken += 1) {
                values[taken] = it.take() orelse break;
            }
            if (taken != it.stride) {
                it.numbers = "";
                continue;
            }
            return .{ .shape = it.shape, .where = switch (it.stride) {
                2 => .{ .cell = .{ .row = values[0], .col = values[1] } },
                else => .{ .rect = .{
                    .top = values[0],
                    .left = values[1],
                    .bottom = values[2],
                    .right = values[3],
                } },
            } };
        }
    }

    /// Moves to the next block, or reports that there is none.
    fn advance(it: *ExtraCursors) bool {
        if (it.rest.len == 0) return false;
        const end = std.mem.indexOfScalar(u8, it.rest, ';') orelse it.rest.len;
        var block = it.rest[0..end];
        it.rest = if (end == it.rest.len) it.rest[end..] else it.rest[end + 1 ..];

        // `parseExtraCursors` has already checked the shape and the type, so
        // both scans here are reads rather than validation.
        const shape = seq.scanInt(u8, block).?;
        it.shape = @enumFromInt(shape.value);
        block = block[shape.len + 1 ..];
        const kind = seq.scanInt(u8, block).?;
        it.stride = switch (kind.value) {
            0 => 0,
            2 => 2,
            else => 4,
        };
        it.numbers = block[kind.len..];
        return true;
    }

    /// The next number of the block, or null when it has run out.
    fn take(it: *ExtraCursors) ?u32 {
        if (it.numbers.len == 0 or it.numbers[0] != ':') return null;
        const scan = seq.scanInt(u32, it.numbers[1..]) orelse return null;
        it.numbers = it.numbers[1 + scan.len ..];
        return scan.value;
    }
};

/// Reads the answer to `queryExtraCursors`:
/// `CSI > 100 ; shape : type : co-ordinates ; ... SP q`.
///
/// The whole reply is checked here — every shape named, every type one the
/// protocol defines, every number one that fits — so the iterator that walks
/// it afterwards cannot fail. A reply with no blocks at all is a terminal
/// saying no extra cursors are set.
///
/// Returns null for anything else. `bytes` must be exactly the sequence.
pub fn parseExtraCursors(bytes: []const u8) ?ExtraCursorReport {
    const body = stripSequence(bytes) orelse return null;

    const first = std.mem.indexOfScalar(u8, body, ';') orelse body.len;
    if (!std.mem.eql(u8, body[0..first], "100")) return null;
    if (first == body.len) return .{ .blocks = body[body.len..] };

    const blocks = body[first + 1 ..];
    var rest = blocks;
    while (true) {
        const end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
        if (!validBlock(rest[0..end])) return null;
        if (end == rest.len) break;
        rest = rest[end + 1 ..];
        if (rest.len == 0) return null;
    }
    return .{ .blocks = blocks };
}

/// Whether one `shape : type : co-ordinates` block is well formed.
fn validBlock(block: []const u8) bool {
    const shape = seq.scanInt(u8, block) orelse return false;
    switch (shape.value) {
        0, 1, 2, 3, 29 => {},
        else => return false,
    }
    var rest = block[shape.len..];
    if (rest.len == 0 or rest[0] != ':') return false;
    rest = rest[1..];

    const kind = seq.scanInt(u8, rest) orelse return false;
    switch (kind.value) {
        0, 2, 4 => {},
        else => return false,
    }
    rest = rest[kind.len..];
    if (kind.value == 0) return rest.len == 0;

    while (rest.len != 0) {
        if (rest[0] != ':') return false;
        const number = seq.scanInt(u32, rest[1..]) orelse return false;
        rest = rest[1 + number.len ..];
    }
    return true;
}

/// A terminal's answer to `queryExtraCursorColors`: the pair, both halves.
pub const ExtraCursorColors = struct {
    /// The colour of the text under the extra cursors.
    text: CursorColor,
    /// The colour of the extra cursors themselves.
    cursor: CursorColor,
};

/// Reads the answer to `queryExtraCursorColors`:
/// `CSI > 101 ; 30 : space : ... ; 40 : space : ... SP q`.
///
/// Both halves are required and in that order, which is the only form the
/// protocol defines. Returns null for anything else.
pub fn parseExtraCursorColors(bytes: []const u8) ?ExtraCursorColors {
    const body = stripSequence(bytes) orelse return null;
    if (!std.mem.startsWith(u8, body, "101;")) return null;

    const rest = body[4..];
    const separator = std.mem.indexOfScalar(u8, rest, ';') orelse return null;
    const text = scanColor(rest[0..separator], 30) orelse return null;
    const cursor = scanColor(rest[separator + 1 ..], 40) orelse return null;
    return .{ .text = text, .cursor = cursor };
}

/// Reads one `which : space : parameters` half of a colour reply.
fn scanColor(block: []const u8, which: u8) ?CursorColor {
    const target = seq.scanInt(u8, block) orelse return null;
    if (target.value != which) return null;
    var rest = block[target.len..];
    if (rest.len == 0 or rest[0] != ':') return null;
    rest = rest[1..];

    const space = seq.scanInt(u8, rest) orelse return null;
    rest = rest[space.len..];

    switch (space.value) {
        0 => return if (rest.len == 0) .unset else null,
        1 => return if (rest.len == 0) .special else null,
        2 => {
            const r = scanChannel(&rest) orelse return null;
            const g = scanChannel(&rest) orelse return null;
            const b = scanChannel(&rest) orelse return null;
            if (rest.len != 0) return null;
            return .{ .rgb = .{ .r = r, .g = g, .b = b } };
        },
        5 => {
            const n = scanChannel(&rest) orelse return null;
            if (rest.len != 0) return null;
            return .{ .indexed = n };
        },
        else => return null,
    }
}

/// Reads `: n` off the front of a colour's parameter list, where `n` is a
/// number that fits in a channel.
fn scanChannel(rest: *[]const u8) ?u8 {
    if (rest.len == 0 or rest.*[0] != ':') return null;
    const scan = seq.scanInt(u8, rest.*[1..]) orelse return null;
    rest.* = rest.*[1 + scan.len ..];
    return scan.value;
}

/// Removes `CSI >` and the `SP q` trailer, leaving the parameters.
///
/// One place, because all three replies wear the same clothes and a parser
/// that spelled the introducer itself would be a fourth spelling of it.
fn stripSequence(bytes: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, bytes, introducer)) return null;
    const rest = bytes[introducer.len..];
    if (!std.mem.endsWith(u8, rest, trailer)) return null;
    return rest[0 .. rest.len - trailer.len];
}

//=========================================================================
// Tests.
//=========================================================================

test "the protocol's own quickstart writes the protocol's own bytes" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try extraCursors(&out.writer, .main, &.{.{ .cells = &.{.{ .row = 4, .col = 5 }} }});
    try std.testing.expectEqualStrings("\x1b[>29;2:4:5 q", out.written());

    var line: Writer.Allocating = .init(std.testing.allocator);
    defer line.deinit();
    try extraCursors(&line.writer, .block, &.{.{ .cells = &.{.{ .row = 7, .col = 1 }} }});
    try extraCursors(&line.writer, .beam, &.{.{ .cells = &.{.{ .row = 7, .col = 3 }} }});
    try extraCursors(&line.writer, .underline, &.{
        .{ .cells = &.{ .{ .row = 7, .col = 5 }, .{ .row = 7, .col = 7 } } },
    });
    try std.testing.expectEqualStrings(
        "\x1b[>1;2:7:1 q\x1b[>2;2:7:3 q\x1b[>3;2:7:5:7:7 q",
        line.written(),
    );
}

test "every shape writes its own number" {
    const cases = [_]struct { shape: ExtraCursorShape, bytes: []const u8 }{
        .{ .shape = .none, .bytes = "\x1b[>0;0 q" },
        .{ .shape = .block, .bytes = "\x1b[>1;0 q" },
        .{ .shape = .beam, .bytes = "\x1b[>2;0 q" },
        .{ .shape = .underline, .bytes = "\x1b[>3;0 q" },
        .{ .shape = .main, .bytes = "\x1b[>29;0 q" },
    };
    for (cases) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try extraCursors(&out.writer, case.shape, &.{.main_cursor});
        try std.testing.expectEqualStrings(case.bytes, out.written());
    }
}

test "a rectangle and a cell list can share one sequence" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try extraCursors(&out.writer, .block, &.{
        .{ .cells = &.{.{ .row = 3, .col = 2 }} },
        .{ .rects = &.{.{ .top = 6, .left = 5, .bottom = 8, .right = 7 }} },
    });
    try std.testing.expectEqualStrings("\x1b[>1;2:3:2;4:6:5:8:7 q", out.written());
}

test "a span with no co-ordinates at all is the whole screen" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try extraCursorsClear(&out.writer);
    try std.testing.expectEqualStrings("\x1b[>0;4 q", out.written());
}

test "no spans at all writes a sequence that names nothing" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try extraCursors(&out.writer, .block, &.{});
    try std.testing.expectEqualStrings("\x1b[>1 q", out.written());
}

test "every colour space writes its own parameters" {
    const cases = [_]struct { color: CursorColor, bytes: []const u8 }{
        .{ .color = .unset, .bytes = "\x1b[>40;0 q" },
        .{ .color = .special, .bytes = "\x1b[>40;1 q" },
        .{ .color = .{ .rgb = .{ .r = 255, .g = 0, .b = 128 } }, .bytes = "\x1b[>40;2:255:0:128 q" },
        .{ .color = .{ .indexed = 9 }, .bytes = "\x1b[>40;5:9 q" },
    };
    for (cases) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try extraCursorColor(&out.writer, .cursor, case.color);
        try std.testing.expectEqualStrings(case.bytes, out.written());
    }
}

test "the text colour is 30 and the cursor colour is 40" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try extraCursorColor(&out.writer, .text, .special);
    try extraCursorColor(&out.writer, .cursor, .{ .indexed = 4 });
    try std.testing.expectEqualStrings("\x1b[>30;1 q\x1b[>40;5:4 q", out.written());
}

test "each query writes its own number, and the support query none" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try queryExtraCursorSupport(&out.writer);
    try queryExtraCursors(&out.writer);
    try queryExtraCursorColors(&out.writer);
    try std.testing.expectEqualStrings("\x1b[> q\x1b[>100 q\x1b[>101 q", out.written());
}

test "parseExtraCursorSupport reads the reply the protocol documents" {
    const support = parseExtraCursorSupport("\x1b[>1;2;3;29;30;40;100;101 q").?;
    try std.testing.expect(support.block and support.beam and support.underline);
    try std.testing.expect(support.main and support.text_color and support.cursor_color);
    try std.testing.expect(support.query_cursors and support.query_colors);
    try std.testing.expect(support.any());
}

test "parseExtraCursorSupport reads a subset, and an empty list as nothing" {
    const some = parseExtraCursorSupport("\x1b[>1;29 q").?;
    try std.testing.expect(some.block and some.main);
    try std.testing.expect(!some.beam and !some.query_cursors);

    const none = parseExtraCursorSupport("\x1b[> q").?;
    try std.testing.expect(!none.any());
}

test "parseExtraCursorSupport reads past a number the protocol has not defined" {
    const support = parseExtraCursorSupport("\x1b[>1;7;102 q").?;
    try std.testing.expect(support.block);
    try std.testing.expect(!support.query_colors);
}

test "parseExtraCursorSupport returns null on anything it does not recognise" {
    const rejected = [_][]const u8{
        "", // nothing at all
        "\x1b[>1;2;3", // no trailer
        "\x1b[>1;2;3q", // no space before the q
        "\x1b[>1;2; q", // a separator with nothing after it
        "\x1b[>;1 q", // a separator with nothing before it
        "\x1b[1;2 q", // no private marker
        "\x1b]>1;2 q", // OSC, not CSI
        "\x1b[>1:2 q", // sub-parameters, which this reply has none of
        "\x1b[>4294967296 q", // a number too large for its field
    };
    for (rejected) |bytes| try std.testing.expect(parseExtraCursorSupport(bytes) == null);
}

test "parseExtraCursors reads an empty answer as no cursors at all" {
    var cursors = parseExtraCursors("\x1b[>100 q").?.iterator();
    try std.testing.expect(cursors.next() == null);
}

test "parseExtraCursors flattens a block naming several cells" {
    var cursors = parseExtraCursors("\x1b[>100;1:2:7:1:7:3 q").?.iterator();

    const first = cursors.next().?;
    try std.testing.expectEqual(ExtraCursorShape.block, first.shape);
    try std.testing.expectEqual(CursorCell{ .row = 7, .col = 1 }, first.where.cell);

    const second = cursors.next().?;
    try std.testing.expectEqual(ExtraCursorShape.block, second.shape);
    try std.testing.expectEqual(CursorCell{ .row = 7, .col = 3 }, second.where.cell);

    try std.testing.expect(cursors.next() == null);
}

test "parseExtraCursors reads every co-ordinate type" {
    var cursors = parseExtraCursors("\x1b[>100;29:0;2:2:4:5;3:4:1:1:2:2 q").?.iterator();

    const main = cursors.next().?;
    try std.testing.expectEqual(ExtraCursorShape.main, main.shape);
    try std.testing.expectEqual(ExtraCursorAt.Where.main_cursor, main.where);

    const cell = cursors.next().?;
    try std.testing.expectEqual(ExtraCursorShape.beam, cell.shape);
    try std.testing.expectEqual(CursorCell{ .row = 4, .col = 5 }, cell.where.cell);

    const rect = cursors.next().?;
    try std.testing.expectEqual(ExtraCursorShape.underline, rect.shape);
    try std.testing.expectEqual(
        CursorRect{ .top = 1, .left = 1, .bottom = 2, .right = 2 },
        rect.where.rect,
    );

    try std.testing.expect(cursors.next() == null);
}

test "parseExtraCursors drops co-ordinates that do not make a whole place" {
    // An odd co-ordinate for a cell list, and three for a rectangle: both
    // tails are ignored, as the protocol requires of a terminal.
    var cells = parseExtraCursors("\x1b[>100;1:2:7:1:9 q").?.iterator();
    try std.testing.expectEqual(CursorCell{ .row = 7, .col = 1 }, cells.next().?.where.cell);
    try std.testing.expect(cells.next() == null);

    var rects = parseExtraCursors("\x1b[>100;1:4:1:1:2:2:3:3:3 q").?.iterator();
    try std.testing.expectEqual(
        CursorRect{ .top = 1, .left = 1, .bottom = 2, .right = 2 },
        rects.next().?.where.rect,
    );
    try std.testing.expect(rects.next() == null);
}

test "parseExtraCursors returns null on anything it does not recognise" {
    const rejected = [_][]const u8{
        "", // nothing at all
        "\x1b[>100;1:2:3:4", // no trailer
        "\x1b[>101 q", // the colour reply
        "\x1b[>1;2:3:4 q", // a support reply, or a request
        "\x1b[>100;1:2:3:4; q", // a block with nothing in it
        "\x1b[>100;9:2:3:4 q", // no such shape
        "\x1b[>100;1:3:3:4 q", // no such co-ordinate type
        "\x1b[>100;1:0:3 q", // the main cursor takes no co-ordinates
        "\x1b[>100;1 q", // a block with no co-ordinate type
        "\x1b[>100;:2:3:4 q", // a block with no shape
        "\x1b[>100;1:2:4294967296 q", // a number too large for its field
    };
    for (rejected) |bytes| try std.testing.expect(parseExtraCursors(bytes) == null);
}

test "the writer and the reader agree on the order of every co-ordinate" {
    // The set sequence and the reply spell the same places with different
    // punctuation -- `shape ; type : ...` going out, `shape : type : ...`
    // coming back -- so this is not a byte round trip. It is the round trip
    // that matters: what the writer put at a place is what the reader finds
    // there.
    const cells = [_]CursorCell{ .{ .row = 1, .col = 1 }, .{ .row = 40, .col = 120 } };
    const rects = [_]CursorRect{.{ .top = 2, .left = 3, .bottom = 4, .right = 5 }};
    const shapes = [_]ExtraCursorShape{ .none, .block, .beam, .underline, .main };
    const spans = [_]CursorSpan{ .main_cursor, .{ .cells = &cells }, .{ .rects = &rects } };

    for (shapes) |shape| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try extraCursors(&out.writer, shape, &spans);

        var reply: Writer.Allocating = .init(std.testing.allocator);
        defer reply.deinit();
        try reply.writer.writeAll(introducer ++ "100");
        for (spans) |span| try writeReplyBlock(&reply.writer, shape, span);
        try reply.writer.writeAll(trailer);

        var read = parseExtraCursors(reply.written()).?.iterator();
        const main = read.next().?;
        try std.testing.expectEqual(shape, main.shape);
        try std.testing.expectEqual(ExtraCursorAt.Where.main_cursor, main.where);
        for (cells) |cell| {
            const at = read.next().?;
            try std.testing.expectEqual(shape, at.shape);
            try std.testing.expectEqual(cell, at.where.cell);
        }
        for (rects) |rect| {
            const at = read.next().?;
            try std.testing.expectEqual(shape, at.shape);
            try std.testing.expectEqual(rect, at.where.rect);
        }
        try std.testing.expect(read.next() == null);

        // And the set sequence carries the same numbers in the same order.
        try std.testing.expect(std.mem.indexOf(u8, out.written(), ":1:1:40:120") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), ":2:3:4:5") != null);
    }
}

test "parseExtraCursorColors reads both halves of the pair" {
    const colors = parseExtraCursorColors("\x1b[>101;30:2:255:0:0;40:5:9 q").?;
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, colors.text.rgb);
    try std.testing.expectEqual(@as(u8, 9), colors.cursor.indexed);
}

test "parseExtraCursorColors reads the spaces that carry no parameters" {
    const colors = parseExtraCursorColors("\x1b[>101;30:0;40:1 q").?;
    try std.testing.expectEqual(CursorColor.unset, colors.text);
    try std.testing.expectEqual(CursorColor.special, colors.cursor);
}

test "every colour the writer can spell, the colour parser reads back" {
    const colors = [_]CursorColor{
        .unset,
        .special,
        .{ .rgb = .{ .r = 0, .g = 128, .b = 255 } },
        .{ .indexed = 255 },
    };
    for (colors) |text| {
        for (colors) |cursor| {
            var out: Writer.Allocating = .init(std.testing.allocator);
            defer out.deinit();
            try out.writer.writeAll(introducer ++ "101");
            try writeReplyColor(&out.writer, .text, text);
            try writeReplyColor(&out.writer, .cursor, cursor);
            try out.writer.writeAll(trailer);

            const read = parseExtraCursorColors(out.written()).?;
            try std.testing.expectEqualDeep(text, read.text);
            try std.testing.expectEqualDeep(cursor, read.cursor);
        }
    }
}

test "parseExtraCursorColors returns null on anything it does not recognise" {
    const rejected = [_][]const u8{
        "", // nothing at all
        "\x1b[>101;30:0;40:1", // no trailer
        "\x1b[>100;30:0;40:1 q", // the cursor reply
        "\x1b[>101;30:0 q", // only one half
        "\x1b[>101;40:0;30:1 q", // the halves the wrong way round
        "\x1b[>101;30:3;40:1 q", // no such colour space
        "\x1b[>101;30:2:1:2;40:1 q", // a channel short
        "\x1b[>101;30:2:1:2:3:4;40:1 q", // a channel too many
        "\x1b[>101;30:5;40:1 q", // an index with no number
        "\x1b[>101;30:0:1;40:1 q", // a parameter where there are none
        "\x1b[>101;30:2:256:0:0;40:1 q", // a channel too large for its field
    };
    for (rejected) |bytes| try std.testing.expect(parseExtraCursorColors(bytes) == null);
}

test "each of the three parsers refuses the other two replies" {
    const cursors = "\x1b[>100;1:2:3:4 q";
    const colors = "\x1b[>101;30:0;40:1 q";

    try std.testing.expect(parseExtraCursors(colors) == null);
    try std.testing.expect(parseExtraCursorColors(cursors) == null);
    try std.testing.expect(parseExtraCursors("\x1b[>1;2;3 q") == null);
    try std.testing.expect(parseExtraCursorColors("\x1b[>1;2;3 q") == null);
}

test "fuzz parseExtraCursors" {
    // The property: no input panics or overflows, the iterator terminates,
    // every cursor it yields has a shape the protocol names, and the same
    // bytes read the same way twice.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [96]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];

            const report = parseExtraCursors(bytes) orelse return;
            const start = @intFromPtr(bytes.ptr);
            try std.testing.expect(@intFromPtr(report.blocks.ptr) >= start);

            var seen: usize = 0;
            var cursors = report.iterator();
            while (cursors.next()) |at| : (seen += 1) {
                switch (at.shape) {
                    .none, .block, .beam, .underline, .main => {},
                }
                try std.testing.expect(seen <= bytes.len);
            }

            var again = parseExtraCursors(bytes).?.iterator();
            var twice: usize = 0;
            while (again.next()) |_| twice += 1;
            try std.testing.expectEqual(seen, twice);
        }
    }.one, .{ .corpus = &.{
        corpus.seed("\x1b[>100 q"),
        corpus.seed("\x1b[>100;1:2:7:1:7:3 q"),
        corpus.seed("\x1b[>100;29:0;2:2:4:5;3:4:1:1:2:2 q"),
        corpus.seed("\x1b[>100;1:2:7:1:9 q"),
        corpus.seed("\x1b[>100;9:2:3:4 q"),
        corpus.seed("\x1b[>100;1:2:4294967296 q"),
        corpus.seed("\x1b[>101;30:0;40:1 q"),
    } });
}

test "fuzz parseExtraCursorColors" {
    // The property: no input panics or overflows, and every reply that
    // parses renders back -- through the reply grammar, which is not the
    // writer's -- to a reply that parses to the same pair.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [64]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];

            const colors = parseExtraCursorColors(bytes) orelse return;

            var output: [96]u8 = undefined;
            var w: Writer = .fixed(&output);
            try w.writeAll(introducer ++ "101");
            try writeReplyColor(&w, .text, colors.text);
            try writeReplyColor(&w, .cursor, colors.cursor);
            try w.writeAll(trailer);

            const again = parseExtraCursorColors(w.buffered()).?;
            try std.testing.expectEqualDeep(colors, again);
        }
    }.one, .{ .corpus = &.{
        corpus.seed("\x1b[>101;30:0;40:1 q"),
        corpus.seed("\x1b[>101;30:2:255:0:0;40:5:9 q"),
        corpus.seed("\x1b[>101;30:3;40:1 q"),
        corpus.seed("\x1b[>101;30:2:256:0:0;40:1 q"),
        corpus.seed("\x1b[>100;1:2:3:4 q"),
    } });
}

test "fuzz parseExtraCursorSupport" {
    // The property: no input panics or overflows, and every reply that
    // parses reads the same way twice.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [64]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];

            const support = parseExtraCursorSupport(bytes) orelse return;
            try std.testing.expectEqualDeep(support, parseExtraCursorSupport(bytes).?);
        }
    }.one, .{ .corpus = &.{
        corpus.seed("\x1b[>1;2;3;29;30;40;100;101 q"),
        corpus.seed("\x1b[> q"),
        corpus.seed("\x1b[>1;7;102 q"),
        corpus.seed("\x1b[>1;2; q"),
        corpus.seed("\x1b[>4294967296 q"),
    } });
}

/// Test support: one `; shape : type : co-ordinates` block of the reply to
/// `queryExtraCursors`.
///
/// The terminal writes these, not this package, which is why it lives among
/// the tests: it is the renderer the parser's round trip is against, the same
/// arrangement `parseModeReply` and `parseCursorPosition` are tested under.
fn writeReplyBlock(w: *Writer, shape: ExtraCursorShape, span: CursorSpan) Writer.Error!void {
    try w.writeByte(';');
    try seq.writeInt(w, @intFromEnum(shape));
    switch (span) {
        .main_cursor => try w.writeAll(":0"),
        .cells => |cells| {
            try w.writeAll(":2");
            for (cells) |cell| {
                try w.writeByte(':');
                try seq.writeInt(w, cell.row);
                try w.writeByte(':');
                try seq.writeInt(w, cell.col);
            }
        },
        .rects => |rects| {
            try w.writeAll(":4");
            for (rects) |rect| {
                try w.writeByte(':');
                try seq.writeInt(w, rect.top);
                try w.writeByte(':');
                try seq.writeInt(w, rect.left);
                try w.writeByte(':');
                try seq.writeInt(w, rect.bottom);
                try w.writeByte(':');
                try seq.writeInt(w, rect.right);
            }
        },
    }
}

/// Test support: one `; which : space : parameters` half of the reply to
/// `queryExtraCursorColors`. The reply joins `which` to its space with a
/// colon where the set sequence uses a semicolon, which is why this is not
/// `extraCursorColor` with its introducer trimmed off.
fn writeReplyColor(w: *Writer, which: CursorColorTarget, color: CursorColor) Writer.Error!void {
    try w.writeByte(';');
    try seq.writeInt(w, @intFromEnum(which));
    switch (color) {
        .unset => try w.writeAll(":0"),
        .special => try w.writeAll(":1"),
        .rgb => |c| {
            try w.writeAll(":2:");
            try seq.writeInt(w, c.r);
            try w.writeByte(':');
            try seq.writeInt(w, c.g);
            try w.writeByte(':');
            try seq.writeInt(w, c.b);
        },
        .indexed => |n| {
            try w.writeAll(":5:");
            try seq.writeInt(w, n);
        },
    }
}
