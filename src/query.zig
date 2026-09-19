//! Asking the terminal a question, and reading the answer.
//!
//! Every parser here takes the whole sequence and nothing more, returns null
//! for anything it does not recognise, and never an error: a terminal's input
//! is not a place to distinguish twenty kinds of malformed.
//!
//! What this file will never hold: the waiting, the timeout, or the pairing.
//! A question is written and an answer is read; that the two belong together,
//! and that silence is also an answer, is the caller's to arrange.

const std = @import("std");
const corpus = @import("corpus.zig");
const seq = @import("seq.zig");

const Writer = std.Io.Writer;

/// Asks whether a DEC private mode is set, DECRQM: `CSI ? mode $ p`.
///
/// The answer arrives on the terminal's input as a sequence `parseModeReply`
/// reads. A terminal too old for DECRQM answers nothing, so a program must
/// not block waiting for one.
///
/// The rule that survives contact with real terminals is coarse: `set`,
/// `reset` and `permanently_set` mean the mode is there, and
/// `not_recognized`, `permanently_reset` and silence mean it is not.
/// Terminals disagree about which of those they send for the same mode —
/// one answers `reset` for everything it does not implement, another
/// `permanently_reset` for everything, and several implement no DECRQM at
/// all while implementing the modes — so a program that branches on any
/// finer distinction than those two groups is branching on a coin toss.
pub fn queryMode(w: *Writer, mode: u16) Writer.Error!void {
    try w.writeAll(seq.csi ++ "?");
    try seq.writeInt(w, mode);
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
/// An omitted parameter is its default, zero — so `CSI ? 2026 ; $ y` is a
/// terminal saying it does not recognise mode 2026, which is what a zero
/// there means whether the digit is written or left out.
///
/// Returns null for anything else, an unknown state value included. `bytes`
/// must be exactly the sequence, with nothing before or after it.
pub fn parseModeReply(bytes: []const u8) ?ModeReport {
    const prefix = seq.csi ++ "?";
    if (!std.mem.startsWith(u8, bytes, prefix)) return null;
    var rest = bytes[prefix.len..];

    const mode = seq.scanParam(u16, rest, 0) orelse return null;
    rest = rest[mode.len..];
    if (rest.len == 0 or rest[0] != ';') return null;
    rest = rest[1..];

    const state = seq.scanParam(u8, rest, 0) orelse return null;
    rest = rest[state.len..];
    if (!std.mem.eql(u8, rest, "$y")) return null;
    if (state.value > @intFromEnum(ModeState.permanently_reset)) return null;

    return .{ .mode = mode.value, .state = @enumFromInt(state.value) };
}

/// Asks where the cursor is, CPR: `CSI 6 n`.
///
/// The answer arrives on the terminal's input as a sequence
/// `parseCursorPosition` reads. Every terminal answers this one, which is
/// what makes it the query to pair with one that may go unanswered — and
/// what makes it the way a program that has lost track of the cursor finds
/// it again.
pub fn requestCursorPosition(w: *Writer) Writer.Error!void {
    try w.writeAll(seq.csi ++ "6n");
}

/// A cursor position, in cells, counting from one at the top-left.
pub const CursorPosition = extern struct {
    /// The row, where the topmost row is 1.
    row: u32,
    /// The column, where the leftmost column is 1.
    col: u32,
};

/// Reads a cursor position report, CPR: `CSI row ; col R`.
///
/// This is the plain report, the answer to `CSI 6 n`. The DEC extended form
/// carries a page number as well and is marked private; it is a different
/// sequence, read by `parseExtendedCursorPosition`, and is not recognised
/// here. An omitted parameter is its default, and CPR's default is one, not
/// zero: `CSI ; R` is the top-left cell. Returns null for anything else.
pub fn parseCursorPosition(bytes: []const u8) ?CursorPosition {
    if (!std.mem.startsWith(u8, bytes, seq.csi)) return null;
    var rest = bytes[seq.csi.len..];

    const row = seq.scanParam(u32, rest, 1) orelse return null;
    rest = rest[row.len..];
    if (rest.len == 0 or rest[0] != ';') return null;
    rest = rest[1..];

    const col = seq.scanParam(u32, rest, 1) orelse return null;
    rest = rest[col.len..];
    if (!std.mem.eql(u8, rest, "R")) return null;

    return .{ .row = row.value, .col = col.value };
}

/// Asks where the cursor is and which page it is on, DECXCPR: `CSI ? 6 n`.
///
/// `requestCursorPosition` with the private marker, and the marker is carried
/// through into the answer: the report comes back as `CSI ? row ; col ; page R`
/// and is read by `parseExtendedCursorPosition`, which is what tells it from
/// the plain one. Terminals that do not implement DECXCPR variously answer
/// the plain report or nothing at all, so a program asking this must be
/// prepared for either and must not block on the extended form.
pub fn requestExtendedCursorPosition(w: *Writer) Writer.Error!void {
    try w.writeAll(seq.csi ++ "?6n");
}

/// A cursor position with the page it is on, as DECXCPR reports it.
pub const ExtendedCursorPosition = extern struct {
    /// The row, where the topmost row is 1.
    row: u32,
    /// The column, where the leftmost column is 1.
    col: u32,
    /// The page, counting from 1. Pages are a VT feature that terminal
    /// emulators do not have, so the answer is 1 on every terminal a program
    /// is likely to meet; it is reported rather than dropped because the
    /// sequence carries it and a parser that discarded a field could not say
    /// it had read the whole report.
    page: u32,
};

/// Reads a DEC extended cursor position report, DECXCPR:
/// `CSI ? row ; col ; page R`.
///
/// The answer to `requestExtendedCursorPosition`, and all three fields are
/// required: a report with two is the plain CPR with a private marker, which
/// is not a sequence any terminal sends. The plain report is
/// `parseCursorPosition`'s, and each of the two returns null for the other's
/// form, so a program that asked both questions can tell the answers apart.
///
/// An omitted parameter is its default, which here is one, as it is for the
/// plain report. Returns null for anything else. `bytes` must be exactly the
/// sequence, with nothing before or after it.
pub fn parseExtendedCursorPosition(bytes: []const u8) ?ExtendedCursorPosition {
    const prefix = seq.csi ++ "?";
    if (!std.mem.startsWith(u8, bytes, prefix)) return null;
    var rest = bytes[prefix.len..];

    const row = seq.scanParam(u32, rest, 1) orelse return null;
    rest = rest[row.len..];
    if (rest.len == 0 or rest[0] != ';') return null;
    rest = rest[1..];

    const col = seq.scanParam(u32, rest, 1) orelse return null;
    rest = rest[col.len..];
    if (rest.len == 0 or rest[0] != ';') return null;
    rest = rest[1..];

    const page = seq.scanParam(u32, rest, 1) orelse return null;
    rest = rest[page.len..];
    if (!std.mem.eql(u8, rest, "R")) return null;

    return .{ .row = row.value, .col = col.value, .page = page.value };
}

//=========================================================================
// The colour scheme, modes 2031 and 996/997.
//=========================================================================

/// Which way round the terminal's palette is.
///
/// Not a colour: it is the terminal's own word for whether the user is
/// looking at light text on a dark background or the other way about. A
/// program that reads the background with `queryColor` learns the same thing
/// less reliably, because a terminal's background may be an image, a
/// translucent pane, or a colour whose brightness sits in the middle.
pub const ColorScheme = enum(u8) {
    /// Light text on a dark background.
    dark = 1,
    /// Dark text on a light background.
    light = 2,
};

/// Asks which way round the terminal's palette is: `CSI ? 996 n`.
///
/// The answer arrives on the input stream as `CSI ? 997 ; 1 n` or
/// `CSI ? 997 ; 2 n`, which `KeyParser` decodes into `Event.color_scheme`
/// and `parseColorSchemeReply` reads on its own. A terminal that does not
/// implement it answers nothing, so pair it with `queryDeviceAttributes`.
///
/// `colorScheme`, mode 2031, is the standing form of the same question: it
/// makes the terminal send that report again whenever the palette changes.
///
/// Read against the specification text of 2026-08-15.
pub fn queryColorScheme(w: *Writer) Writer.Error!void {
    try w.writeAll(seq.csi ++ "?996n");
}

/// Reads a colour scheme report: `CSI ? 997 ; 1 n` for dark and
/// `CSI ? 997 ; 2 n` for light.
///
/// The same sequence answers `queryColorScheme` and arrives unasked from a
/// terminal in mode 2031 — there is nothing in the bytes that tells the two
/// apart, and nothing that needs to.
///
/// Returns null for anything else, a third scheme value included. `bytes`
/// must be exactly the sequence.
pub fn parseColorSchemeReply(bytes: []const u8) ?ColorScheme {
    const prefix = seq.csi ++ "?997;";
    if (!std.mem.startsWith(u8, bytes, prefix)) return null;
    var rest = bytes[prefix.len..];

    const value = seq.scanParam(u8, rest, 0) orelse return null;
    rest = rest[value.len..];
    if (!std.mem.eql(u8, rest, "n")) return null;

    return switch (value.value) {
        @intFromEnum(ColorScheme.dark) => .dark,
        @intFromEnum(ColorScheme.light) => .light,
        else => null,
    };
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

test "parseModeReply reads an omitted parameter as its default" {
    const no_mode = parseModeReply("\x1b[?;1$y").?;
    try std.testing.expectEqual(@as(u16, 0), no_mode.mode);
    try std.testing.expectEqual(ModeState.set, no_mode.state);

    const no_state = parseModeReply("\x1b[?2026;$y").?;
    try std.testing.expectEqual(@as(u16, 2026), no_state.mode);
    try std.testing.expectEqual(ModeState.not_recognized, no_state.state);
}

test "parseModeReply survives a number long enough to overflow" {
    try std.testing.expect(parseModeReply("\x1b[?99999999999999999999;1$y") == null);
    try std.testing.expect(parseModeReply("\x1b[?1;99999999999999999999$y") == null);
}

test "requestCursorPosition asks with CPR" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try requestCursorPosition(&out.writer);
    try std.testing.expectEqualStrings("\x1b[6n", out.written());
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

test "parseCursorPosition reads an omitted parameter as one, not zero" {
    // CPR counts from one, so one is what an omitted parameter means.
    try std.testing.expectEqual(CursorPosition{ .row = 1, .col = 40 }, parseCursorPosition("\x1b[;40R").?);
    try std.testing.expectEqual(CursorPosition{ .row = 12, .col = 1 }, parseCursorPosition("\x1b[12;R").?);
    try std.testing.expectEqual(CursorPosition{ .row = 1, .col = 1 }, parseCursorPosition("\x1b[;R").?);
}

test "requestExtendedCursorPosition asks with DECXCPR" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try requestExtendedCursorPosition(&out.writer);
    try std.testing.expectEqualStrings("\x1b[?6n", out.written());
}

test "the two cursor position queries differ only by the private marker" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try requestCursorPosition(&out.writer);
    try requestExtendedCursorPosition(&out.writer);
    try std.testing.expectEqualStrings("\x1b[6n\x1b[?6n", out.written());
}

test "parseExtendedCursorPosition reads a report and its page" {
    const position = parseExtendedCursorPosition("\x1b[?12;40;1R").?;
    try std.testing.expectEqual(@as(u32, 12), position.row);
    try std.testing.expectEqual(@as(u32, 40), position.col);
    try std.testing.expectEqual(@as(u32, 1), position.page);
}

test "parseExtendedCursorPosition reads the top-left cell and a very large one" {
    try std.testing.expectEqual(
        ExtendedCursorPosition{ .row = 1, .col = 1, .page = 1 },
        parseExtendedCursorPosition("\x1b[?1;1;1R").?,
    );
    try std.testing.expectEqual(
        ExtendedCursorPosition{ .row = 4294967295, .col = 4294967295, .page = 4294967295 },
        parseExtendedCursorPosition("\x1b[?4294967295;4294967295;4294967295R").?,
    );
}

test "parseExtendedCursorPosition returns null on anything it does not recognise" {
    const rejected = [_][]const u8{
        "", // nothing at all
        "\x1b[?12;40;1", // no final byte
        "\x1b[?12;40;", // no page
        "\x1b[?12;40R", // the plain report, wearing a private marker
        "\x1b[?12;40;1n", // the request's final byte
        "\x1b]?12;40;1R", // OSC, not CSI
        "\x1b[?12;40;1RR", // trailing rubbish
        " \x1b[?12;40;1R", // leading rubbish
        "\x1b[?12;40;1;1R", // a field too many
        "\x1b[?4294967296;1;1R", // a row too large for its field
        "\x1b[?1;4294967296;1R", // a column too large for its field
        "\x1b[?1;1;4294967296R", // a page too large for its field
    };
    for (rejected) |bytes| {
        try std.testing.expect(parseExtendedCursorPosition(bytes) == null);
    }
}

test "parseExtendedCursorPosition reads an omitted parameter as one" {
    try std.testing.expectEqual(
        ExtendedCursorPosition{ .row = 12, .col = 1, .page = 1 },
        parseExtendedCursorPosition("\x1b[?12;;1R").?,
    );
    try std.testing.expectEqual(
        ExtendedCursorPosition{ .row = 1, .col = 40, .page = 1 },
        parseExtendedCursorPosition("\x1b[?;40;1R").?,
    );
    try std.testing.expectEqual(
        ExtendedCursorPosition{ .row = 1, .col = 1, .page = 1 },
        parseExtendedCursorPosition("\x1b[?;;R").?,
    );
}

test "each cursor position parser refuses the other's report" {
    try std.testing.expect(parseCursorPosition("\x1b[?12;40;1R") == null);
    try std.testing.expect(parseExtendedCursorPosition("\x1b[12;40R") == null);
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

test "fuzz parseExtendedCursorPosition" {
    // The property: no input panics or overflows, and every report that
    // parses renders back to a report that parses to the same position --
    // the page included, which is the field that tells this report from the
    // plain one.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [64]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];

            const position = parseExtendedCursorPosition(bytes) orelse return;
            // Whatever this reads, the plain parser must not also read.
            try std.testing.expect(parseCursorPosition(bytes) == null);

            var output: [64]u8 = undefined;
            var w: Writer = .fixed(&output);
            try w.print("\x1b[?{d};{d};{d}R", .{ position.row, position.col, position.page });
            try std.testing.expectEqual(position, parseExtendedCursorPosition(w.buffered()).?);
        }
    }.one, .{ .corpus = &.{
        corpus.seed("\x1b[?12;40;1R"),
        corpus.seed("\x1b[?1;1;1R"),
        corpus.seed("\x1b[?4294967295;4294967295;4294967295R"),
        corpus.seed("\x1b[?4294967296;1;1R"),
        corpus.seed("\x1b[?0000000012;0000000040;0000000001R"),
        corpus.seed("\x1b[12;40R"),
        corpus.seed("\x1b[?12;40R"),
        corpus.seed("\x1b[?12;40;1;1R"),
        corpus.seed("\x1b[?12;40;1"),
    } });
}

test "queryColorScheme asks which way round the palette is" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try queryColorScheme(&out.writer);
    try std.testing.expectEqualStrings("\x1b[?996n", out.written());
}

test "parseColorSchemeReply reads both schemes" {
    try std.testing.expectEqual(ColorScheme.dark, parseColorSchemeReply("\x1b[?997;1n").?);
    try std.testing.expectEqual(ColorScheme.light, parseColorSchemeReply("\x1b[?997;2n").?);
}

test "parseColorSchemeReply returns null on anything it does not recognise" {
    const rejected = [_][]const u8{
        "", // nothing at all
        "\x1b[?997;1", // no final byte
        "\x1b[?997;", // no scheme
        "\x1b[?997n", // no separator
        "\x1b[?996;1n", // the question, not the answer
        "\x1b[997;1n", // not a private report
        "\x1b]?997;1n", // OSC, not CSI
        "\x1b[?997;0n", // no such scheme
        "\x1b[?997;3n", // no such scheme
        "\x1b[?997;1nn", // trailing rubbish
        " \x1b[?997;1n", // leading rubbish
        "\x1b[?997;1;1n", // a field too many
        "\x1b[?997;256n", // a scheme too large for its field
    };
    for (rejected) |bytes| {
        try std.testing.expect(parseColorSchemeReply(bytes) == null);
    }
}

test "parseColorSchemeReply survives a number long enough to overflow" {
    try std.testing.expect(parseColorSchemeReply("\x1b[?997;99999999999999999999n") == null);
}

test "the colour scheme report is not a mode report and the reverse" {
    try std.testing.expect(parseModeReply("\x1b[?997;1n") == null);
    try std.testing.expect(parseColorSchemeReply("\x1b[?2031;1$y") == null);
}

test "fuzz parseColorSchemeReply" {
    // The property: no input panics or overflows, and every report that
    // parses renders back to a report that parses to the same scheme.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [64]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];

            const scheme = parseColorSchemeReply(bytes) orelse return;

            var output: [32]u8 = undefined;
            var w: Writer = .fixed(&output);
            try w.writeAll("\x1b[?997;");
            try seq.writeInt(&w, @intFromEnum(scheme));
            try w.writeByte('n');
            try std.testing.expectEqual(scheme, parseColorSchemeReply(w.buffered()).?);
        }
    }.one, .{ .corpus = &.{
        corpus.seed("\x1b[?997;1n"),
        corpus.seed("\x1b[?997;2n"),
        corpus.seed("\x1b[?997;0n"),
        corpus.seed("\x1b[?997;3n"),
        corpus.seed("\x1b[?996n"),
        corpus.seed("\x1b[?997;1nn"),
        corpus.seed("\x1b[?997;256n"),
    } });
}
