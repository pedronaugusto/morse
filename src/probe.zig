//! The questions a program asks a terminal on startup, written in one call
//! and collected in one waiting window.
//!
//! Every question in `morse` already has a writer and every answer a parser.
//! What is missing between them is the order, so the slowest and most likely
//! to be forwarded questions go first inside one waiting window:
//!
//! - the cursor position first, because a terminal that does not consume the
//!   whole of a sequence it did not recognise bleeds the rest of it onto its
//!   own output, and a report that comes back first drags that bleed out in
//!   front of everything else;
//! - the OSC colour queries next, because a multiplexer passes those through
//!   to whatever it is running inside and the answer takes the long way
//!   round;
//! - the identifying questions after them, in the order they cost;
//! - the secondary device attributes late, because they identify nothing on
//!   their own;
//! - and the primary device attributes **last**, because nearly every
//!   terminal answers those. DA1 proves that the input path works, but it is
//!   not a completion sentinel: a multiplexer can answer it locally while an
//!   earlier OSC query is still making a round trip to the outer terminal.
//!   Keep the overall timeout armed, or finish after an explicit quiescence
//!   period that is restarted by each reply. Only then is silence a no.
//!
//! `matches` is the other half. Replies arrive on the input stream among the
//! keys, `KeyParser` frames them and hands each back as `Event.unhandled`,
//! and this says which question a given one answers — without a table of
//! sequence shapes in the caller, and without asking a parser to guess.
//!
//! What this file will never hold: the waiting. No timeout, no read, no
//! record of what a terminal answered last time, and no conclusion drawn
//! from silence. It writes the questions in the right order and reads which
//! answer is which; deciding that the waiting window is over is the caller's,
//! because only the caller owns its timeout or quiescence timer.

const std = @import("std");
const corpus = @import("corpus.zig");
const device = @import("device.zig");
const graphics = @import("graphics.zig");
const key = @import("key.zig");
const mode = @import("mode.zig");
const multicursor = @import("multicursor.zig");
const query = @import("query.zig");
const tcap = @import("tcap.zig");

const Writer = std.Io.Writer;

/// Which questions a startup probe asks, and the writer that asks them.
///
/// Every field is on by default, because the cost of a question a program
/// does not need is a few bytes in one write and an answer it ignores, and
/// the cost of leaving one out is a round trip later. Turn one off when the
/// answer would be acted on by nothing, or when the question is known to
/// misbehave where the program runs — the graphics query is an `APC`, and a
/// console host that does not recognise it echoes it onto its own output.
pub const Probe = struct {
    /// One question a probe asks, named for what it wants to know.
    ///
    /// The order of the fields is the order they are written in, and that
    /// order is not decoration: see the file comment.
    pub const Question = enum {
        /// Where the cursor is (CPR). First, to drag out any bleed.
        cursor_position,
        /// The terminal's default foreground (OSC 10).
        foreground_color,
        /// The terminal's default background (OSC 11).
        background_color,
        /// The cursor's colour (OSC 12).
        cursor_color,
        /// Whether the palette is light or dark (`CSI ? 996 n`).
        color_scheme,
        /// Whether synchronised output is implemented (mode 2026).
        sync_output,
        /// Whether text is measured by grapheme cluster (mode 2027).
        unicode_core,
        /// Whether resizes are reported in band (mode 2048).
        in_band_resize,
        /// Whether a mouse report can count pixels (mode 1016).
        mouse_pixels,
        /// Which kitty keyboard flags are in effect.
        kitty_keyboard,
        /// What `modifyOtherKeys` is set to.
        modify_other_keys,
        /// Whether the graphics protocol is implemented at all.
        graphics,
        /// What the terminal can do with extra cursors.
        extra_cursors,
        /// Whether it takes 24-bit colour: the `Tc` and `RGB` capabilities
        /// (XTGETTCAP), each asked on its own because a terminal that knows
        /// one need not know the other.
        truecolor,
        /// What the terminal calls itself (XTVERSION).
        version,
        /// How many rows and columns the text area has.
        text_area_cells,
        /// How many pixels one cell is.
        cell_pixels,
        /// Which terminal family and version (DA2).
        secondary_device_attributes,
        /// What the terminal claims to implement (DA1). Last, and commonly
        /// answered even when the other questions are not.
        device_attributes,
    };

    /// Ask where the cursor is.
    cursor_position: bool = true,
    /// Ask for the default foreground.
    foreground_color: bool = true,
    /// Ask for the default background.
    background_color: bool = true,
    /// Ask for the cursor's colour.
    cursor_color: bool = true,
    /// Ask which way round the palette is.
    color_scheme: bool = true,
    /// Ask whether synchronised output is implemented.
    sync_output: bool = true,
    /// Ask whether the terminal measures by grapheme cluster.
    unicode_core: bool = true,
    /// Ask whether resizes are reported in band.
    in_band_resize: bool = true,
    /// Ask whether a mouse report can count pixels.
    mouse_pixels: bool = true,
    /// Ask which kitty keyboard flags are in effect.
    kitty_keyboard: bool = true,
    /// Ask what `modifyOtherKeys` is set to.
    modify_other_keys: bool = true,
    /// Ask whether the graphics protocol is there. An `APC`, which a console
    /// host that does not know it will echo rather than swallow.
    graphics: bool = true,
    /// Ask what the terminal can do with extra cursors.
    extra_cursors: bool = true,
    /// Ask whether the terminal takes 24-bit colour.
    truecolor: bool = true,
    /// Ask what the terminal calls itself.
    version: bool = true,
    /// Ask how big the text area is, in cells.
    text_area_cells: bool = true,
    /// Ask how big one cell is, in pixels.
    cell_pixels: bool = true,
    /// Ask which terminal family and version.
    secondary_device_attributes: bool = true,

    /// The image id the one-pixel graphics query carries.
    ///
    /// It is echoed back in the answer, so it is how that answer is told
    /// from a response to some other graphics command. There is no default:
    /// the program picks one it will never send a picture under, because an
    /// id it also uses for a picture makes the picture's answers read as the
    /// probe's.
    graphics_id: u32,

    /// Writes every question this probe asks, slow forwarded questions first
    /// and DA1 last.
    ///
    /// One call, one write, one waiting window. The primary device attributes
    /// are written whatever the fields say because their reply establishes
    /// that the input path works. It does not end the window: a multiplexer
    /// may answer DA1 before an earlier forwarded query comes back.
    pub fn write(p: Probe, w: *Writer) Writer.Error!void {
        if (p.cursor_position) try query.requestCursorPosition(w);

        if (p.foreground_color) try device.queryColor(w, .foreground);
        if (p.background_color) try device.queryColor(w, .background);
        if (p.cursor_color) try device.queryColor(w, .cursor);
        if (p.color_scheme) try query.queryColorScheme(w);

        if (p.sync_output) try query.queryMode(w, mode.syncOutput.number);
        if (p.unicode_core) try query.queryMode(w, mode.unicodeCore.number);
        if (p.in_band_resize) try query.queryMode(w, mode.inBandResize.number);
        if (p.mouse_pixels) try query.queryMode(w, mode.Mouse.Encoding.sgr_pixels.number());

        if (p.kitty_keyboard) try mode.kittyKeyboardQuery(w);
        if (p.modify_other_keys) try mode.queryModifyKeys(w, .other_keys);
        if (p.graphics) try graphics.queryGraphics(w, p.graphics_id);
        if (p.extra_cursors) try multicursor.queryExtraCursorSupport(w);
        if (p.truecolor) {
            try tcap.queryCapability(w, "Tc");
            try tcap.queryCapability(w, "RGB");
        }

        if (p.version) try device.queryVersion(w);
        if (p.text_area_cells) try device.queryWindowSize(w, .text_area_cells);
        if (p.cell_pixels) try device.queryWindowSize(w, .cell_pixels);

        if (p.secondary_device_attributes) try device.querySecondaryDeviceAttributes(w);
        try device.queryDeviceAttributes(w);
    }

    /// Whether this probe asks `question`.
    ///
    /// `.device_attributes` is always asked to exercise the input path.
    pub fn asks(p: Probe, question: Question) bool {
        return switch (question) {
            .cursor_position => p.cursor_position,
            .foreground_color => p.foreground_color,
            .background_color => p.background_color,
            .cursor_color => p.cursor_color,
            .color_scheme => p.color_scheme,
            .sync_output => p.sync_output,
            .unicode_core => p.unicode_core,
            .in_band_resize => p.in_band_resize,
            .mouse_pixels => p.mouse_pixels,
            .kitty_keyboard => p.kitty_keyboard,
            .modify_other_keys => p.modify_other_keys,
            .graphics => p.graphics,
            .extra_cursors => p.extra_cursors,
            .truecolor => p.truecolor,
            .version => p.version,
            .text_area_cells => p.text_area_cells,
            .cell_pixels => p.cell_pixels,
            .secondary_device_attributes => p.secondary_device_attributes,
            .device_attributes => true,
        };
    }
};

/// Whether `reply` is an answer to `question`.
///
/// `reply` is one whole sequence, which on the input stream is what
/// `KeyParser` hands back as `Event.unhandled`. A caller walks the questions
/// it asked, asks this of each, and hands the reply to the parser that reads
/// it — which is the parser named in the doc comment for that question.
///
/// This tells replies apart; it does not read them. Two questions about
/// different modes answer in the same shape and are separated by the mode
/// number, and every other pair is separated by the final byte, so a reply
/// answers at most one question. A reply that answers none — a mouse report,
/// an unasked colour scheme report, a reply to something the program asked
/// outside the probe — matches nothing, which is the right answer and not an
/// error.
pub fn matches(reply: []const u8, question: Probe.Question) bool {
    return switch (question) {
        .cursor_position => query.parseCursorPosition(reply) != null,
        .foreground_color => colorReplyFor(reply, .foreground),
        .background_color => colorReplyFor(reply, .background),
        .cursor_color => colorReplyFor(reply, .cursor),
        .color_scheme => query.parseColorSchemeReply(reply) != null,
        .sync_output => modeReplyFor(reply, mode.syncOutput.number),
        .unicode_core => modeReplyFor(reply, mode.unicodeCore.number),
        .in_band_resize => modeReplyFor(reply, mode.inBandResize.number),
        .mouse_pixels => modeReplyFor(reply, mode.Mouse.Encoding.sgr_pixels.number()),
        .kitty_keyboard => device.parseKittyKeyboardReply(reply) != null,
        .modify_other_keys => if (device.parseModifyKeysReply(reply)) |r|
            r.resource == .other_keys
        else
            false,
        .graphics => graphics.parseGraphicsResponse(reply) != null,
        .extra_cursors => multicursor.parseExtraCursorSupport(reply) != null,
        .truecolor => if (tcap.parseCapabilityReply(reply)) |c| namesTruecolor(c) else false,
        .version => device.parseVersion(reply) != null,
        .text_area_cells => windowSizeFor(reply, .text_area_cells),
        .cell_pixels => windowSizeFor(reply, .cell_pixels),
        .secondary_device_attributes => device.parseSecondaryDeviceAttributes(reply) != null,
        .device_attributes => device.parseDeviceAttributes(reply) != null,
    };
}

/// Which question an event from `KeyParser` answers, or null for one that
/// answers none: a key, a mouse report, a reply to something asked outside
/// the probe.
///
/// The same routing as `matches`, read off the typed event rather than the
/// bytes, so a program that reads its input as events asks this and never
/// parses a reply twice. Whether a graphics answer is the probe's is the
/// program's to check against `Probe.graphics_id`.
pub fn answered(event: key.Event) ?Probe.Question {
    return switch (event) {
        .color_scheme => .color_scheme,
        .reply => |r| switch (r) {
            .cursor_position => .cursor_position,
            .color => |c| switch (c.target) {
                .foreground => .foreground_color,
                .background => .background_color,
                .cursor => .cursor_color,
            },
            .mode => |m| if (m.mode == mode.syncOutput.number)
                .sync_output
            else if (m.mode == mode.unicodeCore.number)
                .unicode_core
            else if (m.mode == mode.inBandResize.number)
                .in_band_resize
            else if (m.mode == mode.Mouse.Encoding.sgr_pixels.number())
                .mouse_pixels
            else
                null,
            .kitty_keyboard => .kitty_keyboard,
            .modify_keys => |m| if (m.resource == .other_keys) .modify_other_keys else null,
            .graphics => .graphics,
            .extra_cursor_support => .extra_cursors,
            .capability => |c| if (namesTruecolor(c)) .truecolor else null,
            .version => .version,
            .window_size => |w| switch (w.what) {
                .text_area_cells => .text_area_cells,
                .cell_pixels => .cell_pixels,
                else => null,
            },
            .secondary_device_attributes => .secondary_device_attributes,
            .device_attributes => .device_attributes,
            else => null,
        },
        else => null,
    };
}

/// Whether a capability reply is about `Tc` or `RGB`, known or not: a
/// refusal answers the question too.
fn namesTruecolor(reply: tcap.CapabilityReply) bool {
    var it = reply.iterator();
    while (it.next()) |capability| {
        var name: [8]u8 = undefined;
        const n = capability.decodeName(&name) catch continue;
        if (std.mem.eql(u8, n, "Tc") or std.mem.eql(u8, n, "RGB")) return true;
    }
    return false;
}

/// Whether `reply` is a colour report about `target`.
fn colorReplyFor(reply: []const u8, target: device.ColorTarget) bool {
    const report = device.parseColorReply(reply) orelse return false;
    return report.target == target;
}

/// Whether `reply` is a DECRPM report about `number`.
fn modeReplyFor(reply: []const u8, number: u16) bool {
    const report = query.parseModeReply(reply) orelse return false;
    return report.mode == number;
}

/// Whether `reply` is a window size report about `what`.
fn windowSizeFor(reply: []const u8, what: device.WindowSize.What) bool {
    const report = device.parseWindowSize(reply) orelse return false;
    return report.what == what;
}

/// Every question, in the order `Probe.write` writes them.
const every_question = std.enums.values(Probe.Question);

test "a whole probe is one write, with DA1 last" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const probe: Probe = .{ .graphics_id = 31 };
    try probe.write(&out.writer);
    const bytes = out.written();

    // Pinned exactly, because the point of the thing is that it is one
    // write of a known size rather than nineteen round trips.
    try std.testing.expectEqualStrings(
        "\x1b[6n" ++
            "\x1b]10;?\x1b\\\x1b]11;?\x1b\\\x1b]12;?\x1b\\" ++
            "\x1b[?996n" ++
            "\x1b[?2026$p\x1b[?2027$p\x1b[?2048$p\x1b[?1016$p" ++
            "\x1b[?u" ++
            "\x1b[?4m" ++
            "\x1b_Ga=q,i=31,f=24,s=1,v=1;AAAA\x1b\\" ++
            "\x1b[> q" ++
            "\x1bP+q5463\x1b\\\x1bP+q524742\x1b\\" ++
            "\x1b[>0q" ++
            "\x1b[18t\x1b[16t" ++
            "\x1b[>c" ++
            "\x1b[c",
        bytes,
    );
    try std.testing.expectEqual(@as(usize, 160), bytes.len);
    try std.testing.expectEqual(@as(usize, 19), every_question.len);

    // DA1 is last in the write, though a multiplexer need not reply in order.
    try std.testing.expect(std.mem.endsWith(u8, bytes, "\x1b[c"));
    try std.testing.expectEqual(
        @as(usize, bytes.len - 3),
        std.mem.lastIndexOf(u8, bytes, "\x1b[c").?,
    );

    // The cursor position report is asked for first, ahead of everything
    // that a terminal might bleed.
    try std.testing.expect(std.mem.startsWith(u8, bytes, "\x1b[6n"));
}

test "the order is the order the questions are declared in" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const probe: Probe = .{ .graphics_id = 31 };
    try probe.write(&out.writer);
    const bytes = out.written();

    // Each question's own writer, found in the batch, and each one after
    // the one before it.
    var at: usize = 0;
    for (every_question) |question| {
        var one: Writer.Allocating = .init(std.testing.allocator);
        defer one.deinit();
        try writeOne(&one.writer, question, probe.graphics_id);

        const found = std.mem.indexOfPos(u8, bytes, at, one.written()) orelse
            return error.TestExpectedEqual;
        at = found;
    }
}

/// The one question `question` asks, for a test that checks the order.
fn writeOne(w: *Writer, question: Probe.Question, graphics_id: u32) Writer.Error!void {
    switch (question) {
        .cursor_position => try query.requestCursorPosition(w),
        .foreground_color => try device.queryColor(w, .foreground),
        .background_color => try device.queryColor(w, .background),
        .cursor_color => try device.queryColor(w, .cursor),
        .color_scheme => try query.queryColorScheme(w),
        .sync_output => try query.queryMode(w, mode.syncOutput.number),
        .unicode_core => try query.queryMode(w, mode.unicodeCore.number),
        .in_band_resize => try query.queryMode(w, mode.inBandResize.number),
        .mouse_pixels => try query.queryMode(w, mode.Mouse.Encoding.sgr_pixels.number()),
        .kitty_keyboard => try mode.kittyKeyboardQuery(w),
        .modify_other_keys => try mode.queryModifyKeys(w, .other_keys),
        .graphics => try graphics.queryGraphics(w, graphics_id),
        .extra_cursors => try multicursor.queryExtraCursorSupport(w),
        .truecolor => {
            try tcap.queryCapability(w, "Tc");
            try tcap.queryCapability(w, "RGB");
        },
        .version => try device.queryVersion(w),
        .text_area_cells => try device.queryWindowSize(w, .text_area_cells),
        .cell_pixels => try device.queryWindowSize(w, .cell_pixels),
        .secondary_device_attributes => try device.querySecondaryDeviceAttributes(w),
        .device_attributes => try device.queryDeviceAttributes(w),
    }
}

test "a probe that asks nothing still asks for the device attributes" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const probe: Probe = .{
        .graphics_id = 31,
        .cursor_position = false,
        .foreground_color = false,
        .background_color = false,
        .cursor_color = false,
        .color_scheme = false,
        .sync_output = false,
        .unicode_core = false,
        .in_band_resize = false,
        .mouse_pixels = false,
        .kitty_keyboard = false,
        .modify_other_keys = false,
        .graphics = false,
        .extra_cursors = false,
        .truecolor = false,
        .version = false,
        .text_area_cells = false,
        .cell_pixels = false,
        .secondary_device_attributes = false,
    };
    try probe.write(&out.writer);
    try std.testing.expectEqualStrings("\x1b[c", out.written());

    for (every_question) |question| {
        try std.testing.expectEqual(question == .device_attributes, probe.asks(question));
    }
}

test "a field turned off leaves exactly that question out" {
    var whole: Writer.Allocating = .init(std.testing.allocator);
    defer whole.deinit();
    try (Probe{ .graphics_id = 31 }).write(&whole.writer);

    var without: Writer.Allocating = .init(std.testing.allocator);
    defer without.deinit();
    try (Probe{ .graphics_id = 31, .graphics = false }).write(&without.writer);

    var only: Writer.Allocating = .init(std.testing.allocator);
    defer only.deinit();
    try writeOne(&only.writer, .graphics, 31);

    try std.testing.expectEqual(
        whole.written().len - only.written().len,
        without.written().len,
    );
    try std.testing.expect(std.mem.indexOf(u8, without.written(), only.written()) == null);
}

test "matches routes every answer to the question that asked it" {
    const cases = [_]struct { reply: []const u8, question: Probe.Question }{
        .{ .reply = "\x1b[12;40R", .question = .cursor_position },
        .{ .reply = "\x1b]10;rgb:ffff/ffff/ffff\x1b\\", .question = .foreground_color },
        .{ .reply = "\x1b]11;rgb:1c1c/1c1c/1c1c\x1b\\", .question = .background_color },
        .{ .reply = "\x1b]12;rgb:0000/ffff/0000\x1b\\", .question = .cursor_color },
        .{ .reply = "\x1b[?997;1n", .question = .color_scheme },
        .{ .reply = "\x1b[?2026;1$y", .question = .sync_output },
        .{ .reply = "\x1b[?2027;4$y", .question = .unicode_core },
        .{ .reply = "\x1b[?2048;2$y", .question = .in_band_resize },
        .{ .reply = "\x1b[?1016;2$y", .question = .mouse_pixels },
        .{ .reply = "\x1b[?29u", .question = .kitty_keyboard },
        .{ .reply = "\x1b[>4;2m", .question = .modify_other_keys },
        .{ .reply = "\x1b_Gi=31;OK\x1b\\", .question = .graphics },
        .{ .reply = "\x1b[>1;2;3;29;30;40;100;101 q", .question = .extra_cursors },
        .{ .reply = "\x1bP0+r5463\x1b\\", .question = .truecolor },
        .{ .reply = "\x1bP>|name(390)\x1b\\", .question = .version },
        .{ .reply = "\x1b[8;24;80t", .question = .text_area_cells },
        .{ .reply = "\x1b[6;16;8t", .question = .cell_pixels },
        .{ .reply = "\x1b[>1;4000;48c", .question = .secondary_device_attributes },
        .{ .reply = "\x1b[?62;52;c", .question = .device_attributes },
    };

    // Every question has a reply here, and every reply answers exactly one
    // question -- which is what makes the routing a lookup rather than a
    // guess.
    try std.testing.expectEqual(every_question.len, cases.len);
    for (cases) |case| {
        for (every_question) |question| {
            try std.testing.expectEqual(question == case.question, matches(case.reply, question));
        }
    }
}

test "a reply to nothing the probe asked matches no question at all" {
    const strangers = [_][]const u8{
        "\x1b[<0;40;12M", // a mouse report
        "\x1b[M\x20\x21\x21", // the older one
        "\x1b]52;c;aGk=\x1b\\", // a clipboard reply
        "\x1bP1+r436f=323536\x1b\\", // a capability reply
        "\x1b[200~", // a paste marker
        "\x1b[?2004;1$y", // a mode this probe does not ask about
        "\x1b]4;9;rgb:ffff/0000/0000\x1b\\", // a palette entry
        "\x1b[?12;40;1R", // the extended cursor report, which it does not ask for
        "", // nothing at all
        "\x1b", // half of nothing
    };
    for (strangers) |reply| {
        for (every_question) |question| {
            try std.testing.expect(!matches(reply, question));
        }
    }
}

test "a probe routes a forwarded reply that arrives after DA1" {
    // The whole of it, end to end: the questions in one write, the answers
    // framed and read off one byte stream by the parser that frames the
    // keys, and each handed to the question that asked it. With a keypress
    // in among them, because that is how they really arrive.

    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try (Probe{ .graphics_id = 31 }).write(&out.writer);

    const replies = "\x1b[12;40R" ++
        "a" ++
        "\x1b[?2026;1$y" ++
        "\x1b[?29u" ++
        // A multiplexer can answer DA1 locally before this forwarded OSC
        // reply returns from the outer terminal.
        "\x1b[?62;52;c" ++
        "\x1b]11;rgb:1c1c/1c1c/1c1c\x1b\\";

    var storage: [256]u8 = undefined;
    var parser: key.KeyParser = .init(&storage);

    var seen: [@typeInfo(Probe.Question).@"enum".fields.len]bool = @splat(false);
    var keys: usize = 0;
    var input_path_works = false;

    var events = parser.feed(replies);
    while (events.next()) |event| {
        if (event == .key) keys += 1;
        const question = answered(event) orelse continue;
        seen[@intFromEnum(question)] = true;
        if (question == .device_attributes) input_path_works = true;
    }

    // DA1 established the input path, and the later OSC reply still belongs
    // to this probe. Only the caller's timeout or quiescence period ends it.
    try std.testing.expect(input_path_works);
    try std.testing.expectEqual(@as(usize, 1), keys);
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(bool, &seen, &.{true}));
    try std.testing.expect(seen[@intFromEnum(Probe.Question.cursor_position)]);
    try std.testing.expect(seen[@intFromEnum(Probe.Question.background_color)]);
    try std.testing.expect(seen[@intFromEnum(Probe.Question.sync_output)]);
    try std.testing.expect(!seen[@intFromEnum(Probe.Question.foreground_color)]);
    try std.testing.expect(!seen[@intFromEnum(Probe.Question.graphics)]);
}

test "the question an event answers is the question its bytes match" {
    // Every reply shape the probe asks for, and a few it does not: read as
    // an event, each answers the question its bytes match and no other.
    const samples = [_][]const u8{
        "\x1b[12;40R",              "\x1b]10;rgb:1/2/3\x1b\\", "\x1b]11;rgb:1c1c/1c1c/1c1c\x1b\\",
        "\x1b]12;rgb:ff/ff/ff\x07", "\x1b[?997;1n",            "\x1b[?2026;2$y",
        "\x1b[?2027;1$y",           "\x1b[?2048;2$y",          "\x1b[?29u",
        "\x1b[>4;2m",               "\x1b_Gi=31;OK\x1b\\",     "\x1b[>1;29 q",
        "\x1bP>|name(390)\x1b\\",   "\x1b[8;24;80t",           "\x1b[6;16;8t",
        "\x1b[>1;4000;48c",         "\x1b[?62;52;c",           "\x1b[<0;4;5M",
        "\x1b[?1049;1$y",           "\x1b[4;480;720t",
    };
    for (samples) |bytes| {
        var storage: [128]u8 = undefined;
        var parser: key.KeyParser = .init(&storage);
        var events = parser.feed(bytes);
        const event = events.next().?;
        const want: ?Probe.Question = for (every_question) |q| {
            if (matches(bytes, q)) break q;
        } else null;
        try std.testing.expectEqual(want, answered(event));
    }
}

test "fuzz matches" {
    // The property: arbitrary bytes never panic and never answer two
    // questions at once, whatever they happen to look like.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [64]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];

            var hits: usize = 0;
            for (every_question) |question| {
                if (matches(bytes, question)) hits += 1;
            }
            try std.testing.expect(hits <= 1);
        }
    }.one, .{ .corpus = &.{
        corpus.seed("\x1b[?62;52;c"),
        corpus.seed("\x1b[>1;4000;48c"),
        corpus.seed("\x1b[?2026;1$y"),
        corpus.seed("\x1b[?2027;0$y"),
        corpus.seed("\x1b[12;40R"),
        corpus.seed("\x1b]11;rgb:1c1c/1c1c/1c1c\x1b\\"),
        corpus.seed("\x1b[?29u"),
        corpus.seed("\x1b[>4;2m"),
        corpus.seed("\x1b_Gi=31;OK\x1b\\"),
        corpus.seed("\x1b[8;24;80t"),
        corpus.seed("\x1b[6;16;8t"),
        corpus.seed("\x1bP>|name(390)\x1b\\"),
        corpus.seed("\x1b[>1;29 q"),
        corpus.seed("\x1b[?997;1n"),
    } });
}
