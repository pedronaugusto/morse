//! Asking the terminal a question, and reading the answer.
//!
//! Every parser here takes the whole sequence and nothing more, returns null
//! for anything it does not recognise, and never an error: a terminal's input
//! is not a place to distinguish twenty kinds of malformed.

const std = @import("std");
const corpus = @import("corpus.zig");
const seq = @import("seq.zig");

const Writer = std.Io.Writer;

/// Asks whether a DEC private mode is set, DECRQM: `CSI ? mode $ p`.
///
/// The answer arrives on the terminal's input as a sequence `parseModeReply`
/// reads. A terminal too old for DECRQM answers nothing, so a program must
/// not block waiting for one.
pub fn queryMode(w: *Writer, mode: u16) Writer.Error!void {
    try w.writeAll(seq.csi ++ "?");
    try w.print("{d}", .{mode});
    try w.writeAll("$p");
}

/// What a terminal says about a mode it was asked about.
pub const ModeState = enum(u8) {
    /// The terminal does not implement this mode at all.
    not_recognized = 0,
    /// Set, and can be reset.
    set = 1,
    /// Reset, and can be set.
    reset = 2,
    /// Set, and cannot be changed.
    permanently_set = 3,
    /// Reset, and cannot be changed.
    permanently_reset = 4,
};

/// A terminal's answer to `queryMode`.
pub const ModeReport = struct {
    /// The mode the terminal answered about — compare it against the mode
    /// asked, because replies can arrive out of order.
    mode: u16,
    /// What the terminal says about that mode.
    state: ModeState,
};

/// Reads a DECRPM reply to `queryMode`: `CSI ? mode ; state $ y`.
///
/// The private-mode form only. The ANSI form, `CSI mode ; state $ y` without
/// the `?`, answers a different question about a different set of modes and
/// is not recognised here.
///
/// Returns null for anything else, an unknown state value included. `bytes`
/// must be exactly the sequence, with nothing before or after it.
pub fn parseModeReply(bytes: []const u8) ?ModeReport {
    const prefix = seq.csi ++ "?";
    if (!std.mem.startsWith(u8, bytes, prefix)) return null;
    var rest = bytes[prefix.len..];

    const mode = seq.scanInt(u16, rest) orelse return null;
    rest = rest[mode.len..];
    if (rest.len == 0 or rest[0] != ';') return null;
    rest = rest[1..];

    const state = seq.scanInt(u8, rest) orelse return null;
    rest = rest[state.len..];
    if (!std.mem.eql(u8, rest, "$y")) return null;
    if (state.value > @intFromEnum(ModeState.permanently_reset)) return null;

    return .{ .mode = mode.value, .state = @enumFromInt(state.value) };
}

/// A cursor position, in cells, counting from one at the top-left.
pub const CursorPosition = struct {
    /// The row, where the topmost row is 1.
    row: u32,
    /// The column, where the leftmost column is 1.
    col: u32,
};

/// Reads a cursor position report, CPR: `CSI row ; col R`.
///
/// This is the plain report, the answer to `CSI 6 n`. The DEC extended form
/// `CSI ? row ; col R`, which carries a page number as well, is a different
/// sequence and is not recognised here. Returns null for anything else.
pub fn parseCursorPosition(bytes: []const u8) ?CursorPosition {
    if (!std.mem.startsWith(u8, bytes, seq.csi)) return null;
    var rest = bytes[seq.csi.len..];

    const row = seq.scanInt(u32, rest) orelse return null;
    rest = rest[row.len..];
    if (rest.len == 0 or rest[0] != ';') return null;
    rest = rest[1..];

    const col = seq.scanInt(u32, rest) orelse return null;
    rest = rest[col.len..];
    if (!std.mem.eql(u8, rest, "R")) return null;

    return .{ .row = row.value, .col = col.value };
}

test "queryMode asks with DECRQM" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try queryMode(&out.writer, 2026);
    try queryMode(&out.writer, 25);
    try std.testing.expectEqualStrings("\x1b[?2026$p\x1b[?25$p", out.written());
}

test "parseModeReply reads every documented state" {
    const cases = [_]struct { bytes: []const u8, state: ModeState }{
        .{ .bytes = "\x1b[?2026;0$y", .state = .not_recognized },
        .{ .bytes = "\x1b[?2026;1$y", .state = .set },
        .{ .bytes = "\x1b[?2026;2$y", .state = .reset },
        .{ .bytes = "\x1b[?2026;3$y", .state = .permanently_set },
        .{ .bytes = "\x1b[?2026;4$y", .state = .permanently_reset },
    };
    for (cases) |case| {
        const report = parseModeReply(case.bytes).?;
        try std.testing.expectEqual(@as(u16, 2026), report.mode);
        try std.testing.expectEqual(case.state, report.state);
    }
}

test "parseModeReply returns null on anything it does not recognise" {
    const rejected = [_][]const u8{
        "", // nothing at all
        "\x1b[?2026;1$", // truncated
        "\x1b[?2026;1", // no final byte
        "\x1b[?2026;", // no state
        "\x1b[?2026", // no separator
        "\x1b[?;1$y", // no mode
        "\x1b[2026;1$y", // not a private mode
        "\x1b]?2026;1$y", // OSC, not CSI
        "\x1b[?2026;1$p", // the request's final byte
        "\x1b[?2026;1$yy", // trailing rubbish
        "\x1b[?2026;5$y", // no such state
        "\x1b[?2026;9$y", // no such state
        "\x1b[?65536;1$y", // a mode too large for its field
        "\x1b[?2026;300$y", // a state too large for its field
    };
    for (rejected) |bytes| {
        try std.testing.expect(parseModeReply(bytes) == null);
    }
}

test "parseModeReply survives a number long enough to overflow" {
    try std.testing.expect(parseModeReply("\x1b[?99999999999999999999;1$y") == null);
    try std.testing.expect(parseModeReply("\x1b[?1;99999999999999999999$y") == null);
}

test "parseCursorPosition reads a report" {
    const position = parseCursorPosition("\x1b[12;40R").?;
    try std.testing.expectEqual(@as(u32, 12), position.row);
    try std.testing.expectEqual(@as(u32, 40), position.col);
}

test "parseCursorPosition reads the top-left cell and a very large one" {
    try std.testing.expectEqual(CursorPosition{ .row = 1, .col = 1 }, parseCursorPosition("\x1b[1;1R").?);
    try std.testing.expectEqual(
        CursorPosition{ .row = 4294967295, .col = 4294967295 },
        parseCursorPosition("\x1b[4294967295;4294967295R").?,
    );
}

test "parseCursorPosition returns null on anything it does not recognise" {
    const rejected = [_][]const u8{
        "", // nothing at all
        "\x1b[12;40", // no final byte
        "\x1b[12;", // no column
        "\x1b[12R", // no separator
        "\x1b[;40R", // no row
        "\x1b[12;40n", // the request's final byte
        "\x1b[?12;40R", // the DEC extended report, a different sequence
        "\x1b]12;40R", // OSC, not CSI
        "\x1b[12;40RR", // trailing rubbish
        " \x1b[12;40R", // leading rubbish
        "\x1b[12;40;1R", // a field too many
        "\x1b[4294967296;1R", // a row too large for its field
        "\x1b[1;4294967296R", // a column too large for its field
    };
    for (rejected) |bytes| {
        try std.testing.expect(parseCursorPosition(bytes) == null);
    }
}

test "fuzz parseModeReply" {
    // The property: no input panics or overflows, and every reply that parses
    // renders back to a reply that parses to the same report. A terminal
    // writes these; the round trip is against that renderer.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [64]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];

            const report = parseModeReply(bytes) orelse return;

            var output: [64]u8 = undefined;
            var w: Writer = .fixed(&output);
            try w.print("\x1b[?{d};{d}$y", .{ report.mode, @intFromEnum(report.state) });
            try std.testing.expectEqual(report, parseModeReply(w.buffered()).?);
        }
    }.one, .{ .corpus = &.{
        corpus.seed("\x1b[?2026;1$y"),
        corpus.seed("\x1b[?0;0$y"),
        corpus.seed("\x1b[?65535;4$y"),
        corpus.seed("\x1b[?2026;5$y"),
        corpus.seed("\x1b[?65536;1$y"),
        corpus.seed("\x1b[?2026;1$p"),
        corpus.seed("\x1b[2026;1$y"),
        corpus.seed("\x1b[?2026;1$yy"),
    } });
}

test "fuzz parseCursorPosition" {
    // The property: no input panics or overflows, and every report that parses
    // renders back to a report that parses to the same position.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [64]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];

            const position = parseCursorPosition(bytes) orelse return;

            var output: [64]u8 = undefined;
            var w: Writer = .fixed(&output);
            try w.print("\x1b[{d};{d}R", .{ position.row, position.col });
            try std.testing.expectEqual(position, parseCursorPosition(w.buffered()).?);
        }
    }.one, .{ .corpus = &.{
        corpus.seed("\x1b[12;40R"),
        corpus.seed("\x1b[1;1R"),
        corpus.seed("\x1b[4294967295;4294967295R"),
        corpus.seed("\x1b[4294967296;1R"),
        corpus.seed("\x1b[0000000012;0000000040R"),
        corpus.seed("\x1b[?12;40R"),
        corpus.seed("\x1b[12;40;1R"),
        corpus.seed("\x1b[12;40"),
    } });
}
