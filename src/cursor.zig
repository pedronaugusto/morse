//! Moving the cursor and clearing parts of the screen: the CSI sequences a
//! full-screen program writes on every frame.
//!
//! These are the bytes, not a screen model. morse does not know where the
//! cursor is, does not track what is on screen, and does not clamp a row or a
//! column to a terminal size it has not been told.
//!
//! Two consequences run through everything below. A count is written as given:
//! a terminal reads `0` as `1` for the movement sequences, so a caller whose
//! count is computed must skip the call rather than rely on that. And a
//! movement is clamped by the terminal at the edge of the screen or of the
//! scroll region, silently — there is no reply and no error, so a program that
//! has lost track of where the cursor is cannot find out by moving it.
//! `cursorTo` is how such a program recovers.
//!
//! What this file will never hold: an idea of where the cursor is. Every
//! sequence here is written and forgotten, because the terminal is the only
//! thing that knows the answer and `requestCursorPosition` is how to ask it.
//! No screen model, no damage tracking, no clamping of its own.

const std = @import("std");
const seq = @import("seq.zig");

const Writer = std.Io.Writer;

/// Writes `CSI n final`, the shape every one-argument sequence here takes.
fn csi1(w: *Writer, n: u32, final: u8) Writer.Error!void {
    try w.writeAll(seq.csi);
    try seq.writeInt(w, n);
    try w.writeByte(final);
}

/// Writes `CSI a ; b final`, the shape every two-argument sequence here takes.
fn csi2(w: *Writer, a: u32, b: u32, final: u8) Writer.Error!void {
    try w.writeAll(seq.csi);
    try seq.writeInt(w, a);
    try w.writeByte(';');
    try seq.writeInt(w, b);
    try w.writeByte(final);
}

/// Repeats the last character written, `count` more times: `CSI count b`,
/// REP.
///
/// A run of the same glyph is the one thing a terminal can be told to draw
/// in fewer bytes than the glyphs themselves take: eighty spaces is a space
/// and `CSI 79 b`, which is six bytes instead of eighty. A renderer clearing
/// a row, drawing a rule, or filling a gauge writes runs like that
/// constantly.
///
/// It repeats the last *graphic* character, so it must follow one
/// immediately: a cursor move, a style change or anything else in between
/// makes what it repeats undefined. Terminals that do not implement it
/// ignore it, which draws a shorter run rather than a wrong one, so a
/// program that cannot verify support is safer writing the glyphs.
pub fn repeatChar(w: *Writer, count: u32) Writer.Error!void {
    try csi1(w, count, 'b');
}

/// Moves the cursor to `row` and `col`, counting from 1 at the top-left:
/// `CSI row ; col H`.
///
/// An absolute move depends on nothing that came before it, which is why this
/// is the sequence a program writes when it no longer trusts its idea of where
/// the cursor is. Coordinates past the edge are clamped by the terminal
/// without a word, so an answer to where the cursor then sits has to be asked
/// for rather than assumed.
pub fn cursorTo(w: *Writer, row: u32, col: u32) Writer.Error!void {
    try csi2(w, row, col, 'H');
}

/// Moves the cursor up `n` rows in the same column: `CSI n A`. Stops at the
/// top of the screen, or at the top of the scroll region when the cursor is
/// inside one.
pub fn cursorUp(w: *Writer, n: u32) Writer.Error!void {
    try csi1(w, n, 'A');
}

/// Moves the cursor down `n` rows in the same column: `CSI n B`. Stops at the
/// bottom of the screen, or of the scroll region; it does not scroll.
pub fn cursorDown(w: *Writer, n: u32) Writer.Error!void {
    try csi1(w, n, 'B');
}

/// Moves the cursor `n` columns to the right in the same row: `CSI n C`. Stops
/// at the last column; it does not wrap to the next row.
pub fn cursorRight(w: *Writer, n: u32) Writer.Error!void {
    try csi1(w, n, 'C');
}

/// Moves the cursor `n` columns to the left in the same row: `CSI n D`. Stops
/// at column 1; it does not wrap to the previous row.
pub fn cursorLeft(w: *Writer, n: u32) Writer.Error!void {
    try csi1(w, n, 'D');
}

/// Moves the cursor down `n` rows and to column 1: `CSI n E`. The column part
/// is what separates this from `cursorDown`, and what makes it the sequence
/// for walking down a list of rows each written from its start.
pub fn cursorNextLine(w: *Writer, n: u32) Writer.Error!void {
    try csi1(w, n, 'E');
}

/// Moves the cursor up `n` rows and to column 1: `CSI n F`. The mirror of
/// `cursorNextLine`, and likewise a column move as well as a row move.
pub fn cursorPrevLine(w: *Writer, n: u32) Writer.Error!void {
    try csi1(w, n, 'F');
}

/// Moves the cursor to column `col` in the row it is already on, counting from
/// 1 at the left: `CSI col G`.
///
/// Absolute in the column and relative in nothing, so a program that knows
/// which row it is writing can put a field at a fixed column without knowing
/// how wide what it just wrote turned out to be.
pub fn cursorColumn(w: *Writer, col: u32) Writer.Error!void {
    try csi1(w, col, 'G');
}

/// Moves the cursor to row `row` in the column it is already on, VPA:
/// `CSI row d`.
///
/// The vertical mirror of `cursorColumn`, and what a program that is walking
/// down a fixed column writes so that it does not have to know how far the
/// cursor moved sideways.
pub fn cursorRow(w: *Writer, row: u32) Writer.Error!void {
    try csi1(w, row, 'd');
}

/// Saves the cursor, DECSC: `ESC 7`.
///
/// Two bytes, not a CSI sequence. What is saved is the cursor's position and
/// its current attributes and character set, so a restore also puts back the
/// colour and the flags in effect at the time.
///
/// The terminal keeps exactly one saved cursor, so these do not nest: a second
/// save overwrites the first and the outer restore comes back to the inner
/// position. `altScreen` (mode 1049) saves and restores a cursor of its own,
/// which is a different one and does not interact with this.
pub fn cursorSave(w: *Writer) Writer.Error!void {
    try w.writeByte(seq.esc);
    try w.writeByte('7');
}

/// Restores the cursor saved by `cursorSave`, DECRC: `ESC 8`. Restores the
/// attributes and character set along with the position. With nothing saved, a
/// terminal moves the cursor to the top-left.
pub fn cursorRestore(w: *Writer) Writer.Error!void {
    try w.writeByte(seq.esc);
    try w.writeByte('8');
}

/// How much of the cursor's row `clearLine` erases. The values are the
/// parameter `CSI K` takes.
pub const ClearLine = enum(u8) {
    /// From the cursor to the end of the row, the cell under the cursor
    /// included.
    to_end = 0,
    /// From the start of the row to the cursor, the cell under the cursor
    /// included.
    to_start = 1,
    /// The whole row, on both sides of the cursor.
    all = 2,
};

/// Erases part of the cursor's row, EL: `CSI what K`. The cursor does not
/// move, so the next thing written lands where it would have without the
/// clear.
pub fn clearLine(w: *Writer, what: ClearLine) Writer.Error!void {
    try csi1(w, @intFromEnum(what), 'K');
}

/// How much of the screen `clearScreen` erases. The values are the parameter
/// `CSI J` takes.
pub const ClearScreen = enum(u8) {
    /// From the cursor to the bottom-right of the screen, the cell under the
    /// cursor included.
    to_end = 0,
    /// From the top-left of the screen to the cursor.
    to_start = 1,
    /// Everything on screen. The scrollback is left alone.
    all = 2,
    /// The saved scrollback, and nothing on screen. An xterm extension a
    /// terminal is free to ignore, so a program cannot take it as done.
    scrollback = 3,
};

/// Erases part of the screen, ED: `CSI what J`.
///
/// `clearScreen(.all)` does not move the cursor, which is why the usual pair
/// is `clearScreen(.all)` followed by `cursorTo(1, 1)`: clearing alone leaves
/// the next write wherever the last one ended.
pub fn clearScreen(w: *Writer, what: ClearScreen) Writer.Error!void {
    try csi1(w, @intFromEnum(what), 'J');
}

/// Sets the scrolling region to rows `top` through `bottom`, DECSTBM:
/// `CSI top ; bottom r`.
///
/// Rows count from 1 and both ends are inside the region. `bottom` must be
/// greater than `top`, or the terminal ignores the sequence and the region
/// stays whatever it was. Setting the region also moves the cursor to the
/// top-left of it, so a program that cares where the cursor is puts it there
/// afterwards rather than before.
///
/// Everything that scrolls — writing past the last row, `scrollUp`,
/// `insertLines` — then happens inside the region, and the rows outside it
/// stay put. That is what makes a fixed header or status row cheap.
pub fn scrollRegion(w: *Writer, top: u32, bottom: u32) Writer.Error!void {
    try csi2(w, top, bottom, 'r');
}

/// Makes the whole screen the scrolling region again: `CSI r`, DECSTBM with no
/// parameters. What a program that set a region runs before it gives the
/// screen back.
pub fn scrollRegionReset(w: *Writer) Writer.Error!void {
    try w.writeAll(seq.csi ++ "r");
}

/// Scrolls the contents of the scrolling region up by `n` rows: `CSI n S`. The
/// top `n` rows of the region leave and `n` blank rows come in at the bottom.
/// The cursor does not move.
pub fn scrollUp(w: *Writer, n: u32) Writer.Error!void {
    try csi1(w, n, 'S');
}

/// Scrolls the contents of the scrolling region down by `n` rows: `CSI n T`.
/// The bottom `n` rows of the region leave and `n` blank rows come in at the
/// top. The cursor does not move.
pub fn scrollDown(w: *Writer, n: u32) Writer.Error!void {
    try csi1(w, n, 'T');
}

/// Inserts `n` blank rows at the cursor's row, IL: `CSI n L`.
///
/// The rows below it shift down inside the scrolling region and whatever falls
/// off the bottom of the region is lost; rows outside the region are untouched.
/// Shifting rows the terminal already has costs one short sequence, which is
/// why this beats repainting everything below the insertion point.
pub fn insertLines(w: *Writer, n: u32) Writer.Error!void {
    try csi1(w, n, 'L');
}

/// Inserts `n` blank cells at the cursor, ICH: `CSI n @`.
///
/// The cells to the right shift along the row and whatever falls off the end
/// of it is lost. The row's own counterpart to `insertLines`, and cheap for
/// the same reason: shifting cells the terminal already has beats repainting
/// the rest of the row.
pub fn insertChars(w: *Writer, n: u32) Writer.Error!void {
    try csi1(w, n, '@');
}

/// Deletes `n` cells at the cursor, DCH: `CSI n P`.
///
/// The cells to the right shift back and `n` blanks come in at the end of the
/// row. The counterpart to `insertChars`.
pub fn deleteChars(w: *Writer, n: u32) Writer.Error!void {
    try csi1(w, n, 'P');
}

/// Erases `n` cells from the cursor rightwards, ECH: `CSI n X`.
///
/// Erases in place: nothing shifts, the cursor does not move, and the cells
/// keep the current background colour. Unlike `clearLine` it takes a count,
/// so it is what clears a field of known width without touching the rest of
/// the row.
pub fn eraseChars(w: *Writer, n: u32) Writer.Error!void {
    try csi1(w, n, 'X');
}

/// Deletes `n` rows starting at the cursor's row, DL: `CSI n M`.
///
/// The rows below shift up inside the scrolling region and `n` blank rows come
/// in at the bottom of it. The counterpart to `insertLines`, and cheap for the
/// same reason.
pub fn deleteLines(w: *Writer, n: u32) Writer.Error!void {
    try csi1(w, n, 'M');
}

test "cursorTo counts rows and columns from 1 at the top-left" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try cursorTo(&out.writer, 1, 1);
    try cursorTo(&out.writer, 24, 80);
    try std.testing.expectEqualStrings("\x1b[1;1H\x1b[24;80H", out.written());
}

test "every relative movement writes the final byte it documents" {
    const cases = [_]struct { write: *const fn (*Writer, u32) Writer.Error!void, bytes: []const u8 }{
        .{ .write = cursorUp, .bytes = "\x1b[3A" },
        .{ .write = cursorDown, .bytes = "\x1b[3B" },
        .{ .write = cursorRight, .bytes = "\x1b[3C" },
        .{ .write = cursorLeft, .bytes = "\x1b[3D" },
        .{ .write = cursorNextLine, .bytes = "\x1b[3E" },
        .{ .write = cursorPrevLine, .bytes = "\x1b[3F" },
        .{ .write = cursorColumn, .bytes = "\x1b[3G" },
    };
    for (cases) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();

        try case.write(&out.writer, 3);
        try std.testing.expectEqualStrings(case.bytes, out.written());
    }
}

test "save and restore are two-byte escapes rather than CSI" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try cursorSave(&out.writer);
    try cursorRestore(&out.writer);
    try std.testing.expectEqualStrings("\x1b7\x1b8", out.written());
}

test "every ClearLine value writes its parameter" {
    const cases = [_]struct { what: ClearLine, bytes: []const u8 }{
        .{ .what = .to_end, .bytes = "\x1b[0K" },
        .{ .what = .to_start, .bytes = "\x1b[1K" },
        .{ .what = .all, .bytes = "\x1b[2K" },
    };
    for (cases) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();

        try clearLine(&out.writer, case.what);
        try std.testing.expectEqualStrings(case.bytes, out.written());
    }
}

test "every ClearScreen value writes its parameter" {
    const cases = [_]struct { what: ClearScreen, bytes: []const u8 }{
        .{ .what = .to_end, .bytes = "\x1b[0J" },
        .{ .what = .to_start, .bytes = "\x1b[1J" },
        .{ .what = .all, .bytes = "\x1b[2J" },
        .{ .what = .scrollback, .bytes = "\x1b[3J" },
    };
    for (cases) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();

        try clearScreen(&out.writer, case.what);
        try std.testing.expectEqualStrings(case.bytes, out.written());
    }
}

test "the scrolling region is set with both rows and reset with neither" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try scrollRegion(&out.writer, 2, 23);
    try scrollRegionReset(&out.writer);
    try std.testing.expectEqualStrings("\x1b[2;23r\x1b[r", out.written());
}

test "scrolling and line editing write the final bytes they document" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try scrollUp(&out.writer, 1);
    try scrollDown(&out.writer, 2);
    try insertLines(&out.writer, 3);
    try deleteLines(&out.writer, 4);
    try std.testing.expectEqualStrings("\x1b[1S\x1b[2T\x1b[3L\x1b[4M", out.written());
}

test "a count is written as given, zero and the largest alike" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try cursorUp(&out.writer, 0);
    try cursorRight(&out.writer, 4294967295);
    try cursorTo(&out.writer, 0, 4294967295);
    try std.testing.expectEqualStrings(
        "\x1b[0A\x1b[4294967295C\x1b[0;4294967295H",
        out.written(),
    );
}

test "a frame composes with nothing between the sequences" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const w = &out.writer;

    try cursorSave(w);
    try scrollRegion(w, 2, 23);
    try cursorTo(w, 1, 1);
    try clearScreen(w, .all);
    try cursorDown(w, 3);
    try cursorColumn(w, 10);
    try clearLine(w, .to_end);
    try scrollRegionReset(w);
    try cursorRestore(w);
    try std.testing.expectEqualStrings(
        "\x1b7\x1b[2;23r\x1b[1;1H\x1b[2J\x1b[3B\x1b[10G\x1b[0K\x1b[r\x1b8",
        out.written(),
    );
}

test "a writer with no room left reports the failure" {
    var buffer: [4]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try std.testing.expectError(error.WriteFailed, cursorTo(&w, 24, 80));
}

test "cursorRow writes the vertical position absolute" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try cursorRow(&out.writer, 12);
    try std.testing.expectEqualStrings("\x1b[12d", out.written());
}

test "the character-level edits write their own finals" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try insertChars(&out.writer, 3);
    try deleteChars(&out.writer, 4);
    try eraseChars(&out.writer, 5);
    try std.testing.expectEqualStrings("\x1b[3@\x1b[4P\x1b[5X", out.written());
}

test "a count of zero is written as given, as everywhere else here" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try insertChars(&out.writer, 0);
    try eraseChars(&out.writer, 0);
    try cursorRow(&out.writer, 0);
    try std.testing.expectEqualStrings("\x1b[0@\x1b[0X\x1b[0d", out.written());
}

test "repeatChar writes REP with the count it was given" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try repeatChar(&out.writer, 1);
    try repeatChar(&out.writer, 79);
    try repeatChar(&out.writer, 4294967295);
    try std.testing.expectEqualStrings("\x1b[1b\x1b[79b\x1b[4294967295b", out.written());
}

test "a run written as REP is shorter than the glyphs it stands for" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    // What a renderer writes for eighty spaces: one space and a repeat.
    try out.writer.writeByte(' ');
    try repeatChar(&out.writer, 79);
    try std.testing.expectEqual(@as(usize, 6), out.written().len);
}
