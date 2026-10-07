//! The writers fed to a terminal, and the terminal's own replies fed back.
//!
//! The rest of the suite pins every writer to its exact bytes, which proves
//! `morse` writes what the specifications say. It cannot prove a terminal
//! agrees. This step hands each writer's output to a terminal emulator built
//! from source and asks the emulator what it did: where the cursor is, which
//! modes DECRQM now reports, what the current style is, what the screen
//! holds, what is in its image storage. Then it runs the other way, and the
//! emulator's replies go through the parsers in this package.
//!
//! The emulator is a lazy dependency of this step alone, pinned to one
//! commit. `zig build test` fetches nothing, and the module a consumer
//! imports still has no dependencies.
//!
//! Where the emulator does not implement something `morse` writes, the test
//! says which and skips, rather than asserting nothing and calling it a
//! pass.

const std = @import("std");
const morse = @import("morse");
const vt = @import("vt");

const alloc = std.testing.allocator;

const Terminal = vt.Terminal;
const Stream = vt.TerminalStream;
const Handler = Stream.Handler;

//=========================================================================
// Counting.
//
// Every assertion goes through one of these, so the last test can say how
// many claims this file actually made.
//=========================================================================

var checks: usize = 0;

fn check(ok: bool) !void {
    checks += 1;
    try std.testing.expect(ok);
}

fn checkEqual(expected: anytype, actual: @TypeOf(expected)) !void {
    checks += 1;
    try std.testing.expectEqual(expected, actual);
}

fn checkString(expected: []const u8, actual: []const u8) !void {
    checks += 1;
    try std.testing.expectEqualStrings(expected, actual);
}

//=========================================================================
// The emulator, wired up.
//
// A terminal, a stream over it, and a writer for `morse` to write into.
// The effects a query needs are all installed: without `write_pty` the
// emulator answers nothing at all, which would make every reply test pass
// by reading an empty buffer.
//=========================================================================

/// The return type of one of the emulator's effect callbacks. The types are
/// not exported by name, and naming them through the field is steadier than
/// reaching into the emulator's own file layout.
fn EffectResult(comptime name: []const u8) type {
    const function = @typeInfo(@typeInfo(@FieldType(Handler.Effects, name)).optional.child).pointer.child;
    return @typeInfo(function).@"fn".return_type.?;
}

/// Everything the emulator wrote back since the last `reset`.
var replies_buffer: [16384]u8 = undefined;
var replies_end: usize = 0;

fn writePty(_: *Handler, data: []const u8) void {
    @memcpy(replies_buffer[replies_end..][0..data.len], data);
    replies_end += data.len;
}

fn deviceAttributes(_: *Handler) EffectResult("device_attributes") {
    return .{};
}

fn xtversion(_: *Handler) EffectResult("xtversion") {
    return "conformance 1.2.3";
}

fn colorSchemeEffect(_: *Handler) EffectResult("color_scheme") {
    return .dark;
}

fn sizeEffect(_: *Handler) EffectResult("size") {
    return .{ .rows = 24, .columns = 80, .cell_width = 9, .cell_height = 18 };
}

/// The last clipboard write, the last notification and the last progress
/// report the emulator passed out to its embedder. These three leave no mark
/// on the screen, so the callback is the only place their arrival shows.
var clipboard_location: ?vt.clipboard.Location = null;
var clipboard_text: [256]u8 = undefined;
var clipboard_len: usize = 0;

fn clipboardWrite(_: *Handler, write: vt.clipboard.Write) void {
    clipboard_location = write.location;
    clipboard_len = 0;
    for (write.contents) |content| {
        @memcpy(clipboard_text[clipboard_len..][0..content.data.len], content.data);
        clipboard_len += content.data.len;
    }
}

var notification_title: [128]u8 = undefined;
var notification_title_len: usize = 0;
var notification_body: [128]u8 = undefined;
var notification_body_len: usize = 0;
var notifications: usize = 0;

fn desktopNotification(
    _: *Handler,
    notification: vt.TerminalStream.Action.ShowDesktopNotification,
) void {
    @memcpy(notification_title[0..notification.title.len], notification.title);
    notification_title_len = notification.title.len;
    @memcpy(notification_body[0..notification.body.len], notification.body);
    notification_body_len = notification.body.len;
    notifications += 1;
}

var progress_report: ?vt.osc.Command.ProgressReport = null;

fn progressReport(_: *Handler, report: vt.osc.Command.ProgressReport) void {
    progress_report = report;
}

const Vt = struct {
    term: Terminal,
    stream: Stream,
    buffer: [16384]u8,
    writer: std.Io.Writer,

    fn init(self: *Vt, cols: u16, rows: u16) !void {
        self.term = try .init(std.testing.io, alloc, .{
            .cols = cols,
            .rows = rows,
            // A terminal with a theme, because a terminal with no colours
            // set answers none of the colour queries.
            .colors = .{
                .background = .init(.{ .r = 0x1c, .g = 0x1c, .b = 0x1c }),
                .foreground = .init(.{ .r = 0xd0, .g = 0xd0, .b = 0xd0 }),
                .cursor = .init(.{ .r = 0xff, .g = 0xa0, .b = 0x00 }),
                .palette = .default,
            },
        });
        var handler: Handler = .init(&self.term);
        handler.effects.write_pty = &writePty;
        handler.effects.device_attributes = &deviceAttributes;
        handler.effects.xtversion = &xtversion;
        handler.effects.color_scheme = &colorSchemeEffect;
        handler.effects.size = &sizeEffect;
        handler.effects.clipboard_write = &clipboardWrite;
        handler.effects.desktop_notification = &desktopNotification;
        handler.effects.progress_report = &progressReport;
        handler.terminfo_name = "conformance";
        self.stream = .init(.{ .allocator = alloc, .handler = handler });
        self.writer = .fixed(&self.buffer);
        replies_end = 0;
    }

    fn deinit(self: *Vt) void {
        self.stream.deinit();
        self.term.deinit(alloc);
    }

    /// The writer `morse` writes into.
    fn w(self: *Vt) *std.Io.Writer {
        return &self.writer;
    }

    /// Hands everything written since the last feed to the emulator.
    fn feed(self: *Vt) void {
        self.stream.nextSlice(self.writer.buffered());
        self.writer = .fixed(&self.buffer);
    }

    /// Text straight through, as a program's own output rather than a
    /// sequence.
    fn print(self: *Vt, text: []const u8) void {
        self.stream.nextSlice(text);
    }

    fn cursor(self: *Vt) *vt.Cursor {
        return &self.term.screens.active.cursor;
    }

    /// Everything the emulator has written back, and a fresh start.
    fn replies(_: *Vt) []const u8 {
        return replies_buffer[0..replies_end];
    }

    fn resetReplies(_: *Vt) void {
        replies_end = 0;
    }

    /// The whole screen as text, for the erase and scroll assertions.
    fn screen(self: *Vt) ![]const u8 {
        return self.term.plainString(alloc);
    }
};

//=========================================================================
// The cursor.
//=========================================================================

test "the cursor lands where each movement said" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    // Both count from one, and the emulator counts from zero.
    try morse.cursorTo(v.w(), 5, 9);
    v.feed();
    try checkEqual(@as(usize, 8), v.cursor().x);
    try checkEqual(@as(usize, 4), v.cursor().y);

    try morse.cursorUp(v.w(), 2);
    v.feed();
    try checkEqual(@as(usize, 2), v.cursor().y);

    try morse.cursorDown(v.w(), 3);
    v.feed();
    try checkEqual(@as(usize, 5), v.cursor().y);

    try morse.cursorRight(v.w(), 4);
    v.feed();
    try checkEqual(@as(usize, 12), v.cursor().x);

    try morse.cursorLeft(v.w(), 5);
    v.feed();
    try checkEqual(@as(usize, 7), v.cursor().x);

    // Next and previous line both go to the first column.
    try morse.cursorNextLine(v.w(), 2);
    v.feed();
    try checkEqual(@as(usize, 0), v.cursor().x);
    try checkEqual(@as(usize, 7), v.cursor().y);

    try morse.cursorPrevLine(v.w(), 3);
    v.feed();
    try checkEqual(@as(usize, 0), v.cursor().x);
    try checkEqual(@as(usize, 4), v.cursor().y);

    try morse.cursorColumn(v.w(), 20);
    v.feed();
    try checkEqual(@as(usize, 19), v.cursor().x);
    try checkEqual(@as(usize, 4), v.cursor().y);

    try morse.cursorRow(v.w(), 9);
    v.feed();
    try checkEqual(@as(usize, 19), v.cursor().x);
    try checkEqual(@as(usize, 8), v.cursor().y);

    // Save, move away, come back.
    try morse.cursorSave(v.w());
    try morse.cursorTo(v.w(), 1, 1);
    v.feed();
    try checkEqual(@as(usize, 0), v.cursor().x);
    try checkEqual(@as(usize, 0), v.cursor().y);
    try morse.cursorRestore(v.w());
    v.feed();
    try checkEqual(@as(usize, 19), v.cursor().x);
    try checkEqual(@as(usize, 8), v.cursor().y);
}

test "a cursor report says where the emulator put the cursor" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    try morse.cursorTo(v.w(), 12, 40);
    try morse.requestCursorPosition(v.w());
    v.feed();

    const position = morse.parseCursorPosition(v.replies()).?;
    try checkEqual(@as(u32, 12), position.row);
    try checkEqual(@as(u32, 40), position.col);
}

//=========================================================================
// Modes, as DECRQM reports them.
//=========================================================================

/// Asks the emulator about a mode and reads the answer with this package's
/// own parser, so both halves are under test.
fn modeState(v: *Vt, number: u16) !morse.ModeState {
    v.resetReplies();
    try morse.queryMode(v.w(), number);
    v.feed();
    const report = morse.parseModeReply(v.replies()) orelse return error.NoModeReply;
    try checkEqual(number, report.mode);
    return report.state;
}

test "every named mode is set and reset as DECRQM sees it" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    inline for (.{
        morse.altScreen,
        morse.bracketedPaste,
        morse.syncOutput,
        morse.focusEvents,
        morse.cursorVisible,
        morse.unicodeCore,
        morse.inBandResize,
        morse.autoWrap,
        morse.colorScheme,
    }) |mode| {
        try mode.set(v.w(), true);
        v.feed();
        try checkEqual(morse.ModeState.set, try modeState(&v, mode.number));

        try mode.set(v.w(), false);
        v.feed();
        try checkEqual(morse.ModeState.reset, try modeState(&v, mode.number));
    }
}

/// The emulator's mouse, whole: the motion it reports, the encoding it
/// spells reports in, and which of the eight mouse modes DECRQM would call
/// set. The first two are one setting each; the modes are a flag each, the
/// way a terminal that keeps them independently holds them.
const MouseState = struct {
    event: @FieldType(@FieldType(Terminal, "flags"), "mouse_event"),
    format: @FieldType(@FieldType(Terminal, "flags"), "mouse_format"),
    modes: [8]bool,
};

/// The eight modes of the two settings: the motions, then the encodings.
const mouse_modes = [_]vt.Mode{
    .mouse_event_x10,
    .mouse_event_normal,
    .mouse_event_button,
    .mouse_event_any,
    .mouse_format_utf8,
    .mouse_format_sgr,
    .mouse_format_urxvt,
    .mouse_format_sgr_pixels,
};

fn mouseState(v: *Vt) MouseState {
    var modes: [8]bool = undefined;
    for (mouse_modes, &modes) |mode, *on| on.* = v.term.modes.get(mode);
    return .{
        .event = v.term.flags.mouse_event,
        .format = v.term.flags.mouse_format,
        .modes = modes,
    };
}

/// What the emulator should hold after `mouse(w, m)`: that motion, that
/// encoding, and those two modes alone.
fn mouseExpected(m: morse.Mouse) MouseState {
    var modes: [8]bool = @splat(false);
    for (mouse_modes, &modes) |mode, *on| {
        const number = @intFromEnum(mode);
        on.* = number == m.motion.number() or number == m.encoding.number();
    }
    return .{
        .event = switch (m.motion) {
            .press => .normal,
            .drag => .button,
            .any => .any,
        },
        .format = switch (m.encoding) {
            .sgr => .sgr,
            .sgr_pixels => .sgr_pixels,
            .rxvt => .urxvt,
        },
        .modes = modes,
    };
}

const mouse_off: MouseState = .{ .event = .none, .format = .x10, .modes = @splat(false) };

/// Leaves the emulator in the state `subset` of the eight modes turned on in
/// order would: some other program's leftovers.
fn mouseLeftovers(v: *Vt, subset: usize) !void {
    try morse.mouseOff(v.w());
    for (mouse_modes, 0..) |mode, i| {
        if (subset & (@as(usize, 1) << @intCast(i)) != 0) try morse.setMode(v.w(), @intFromEnum(mode), true);
    }
    v.feed();
}

/// Every mouse a program can ask for.
fn everyMouse() [9]morse.Mouse {
    var all: [9]morse.Mouse = undefined;
    var n: usize = 0;
    for (std.enums.values(morse.Mouse.Motion)) |motion| {
        for (std.enums.values(morse.Mouse.Encoding)) |encoding| {
            all[n] = .{ .motion = motion, .encoding = encoding };
            n += 1;
        }
    }
    return all;
}

test "the mouse modes DECRQM sees are the one motion and the one encoding asked for" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    const numbers = [_]u16{ 9, 1000, 1002, 1003, 1005, 1006, 1015, 1016 };

    // Everything on first, as a careless program might leave it.
    for (numbers) |number| try morse.setMode(v.w(), number, true);
    v.feed();

    try morse.mouse(v.w(), .{ .motion = .press });
    v.feed();
    for (numbers) |number| {
        const expected: morse.ModeState = if (number == 1000 or number == 1006) .set else .reset;
        try checkEqual(expected, try modeState(&v, number));
    }

    try morse.mouseOff(v.w());
    v.feed();
    for (numbers) |number| {
        try checkEqual(morse.ModeState.reset, try modeState(&v, number));
    }
}

test "the mouse is what was asked for, whatever any program left on" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    // Every subset of the eight modes, switched on in order, is every state
    // the two settings can be in and every set of flags besides.
    for (0..256) |subset| {
        for (everyMouse()) |m| {
            try mouseLeftovers(&v, subset);
            try morse.mouse(v.w(), m);
            v.feed();
            try checkEqual(mouseExpected(m), mouseState(&v));
        }
        try mouseLeftovers(&v, subset);
        try morse.mouseOff(v.w());
        v.feed();
        try checkEqual(mouse_off, mouseState(&v));
    }
}

test "every change of motion and of encoding lands, one call after another" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    // From every mouse to every other, and to off and back, in a run: the
    // way a program that changes its mind per view calls it.
    for (everyMouse()) |from| {
        for (everyMouse()) |to| {
            try morse.mouse(v.w(), from);
            v.feed();
            try checkEqual(mouseExpected(from), mouseState(&v));
            try morse.mouse(v.w(), to);
            v.feed();
            try checkEqual(mouseExpected(to), mouseState(&v));
        }
        try morse.mouseOff(v.w());
        v.feed();
        try checkEqual(mouse_off, mouseState(&v));
    }
}

test "focus reports are their own mode and the mouse leaves them alone" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    try morse.focusEvents.set(v.w(), true);
    try morse.mouse(v.w(), .{ .motion = .any, .encoding = .rxvt });
    try morse.mouseOff(v.w());
    v.feed();
    try checkEqual(morse.ModeState.set, try modeState(&v, morse.focusEvents.number));

    try morse.focusEvents.set(v.w(), false);
    try morse.mouse(v.w(), .{ .motion = .drag });
    v.feed();
    try checkEqual(morse.ModeState.reset, try modeState(&v, morse.focusEvents.number));
}

test "the win32 input mode is one this emulator does not implement" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    // Mode 9001 is a console protocol, and an emulator that never runs on a
    // console has nothing to implement. DECRQM saying `not_recognized` is
    // the answer `queryMode`'s doc comment tells a caller to read as a no,
    // and reading it here is the point rather than a gap.
    try morse.win32Input.set(v.w(), true);
    v.feed();
    try checkEqual(morse.ModeState.not_recognized, try modeState(&v, morse.win32Input.number));
}

test "the synchronised output bracket opens and closes" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    try checkEqual(morse.ModeState.reset, try modeState(&v, morse.syncOutput.number));

    try morse.syncOutput.set(v.w(), true);
    v.feed();
    try checkEqual(morse.ModeState.set, try modeState(&v, morse.syncOutput.number));

    // A frame's worth of drawing inside the bracket, then the other half.
    try morse.cursorTo(v.w(), 1, 1);
    v.feed();
    v.print("inside");
    try morse.syncOutput.set(v.w(), false);
    v.feed();
    try checkEqual(morse.ModeState.reset, try modeState(&v, morse.syncOutput.number));

    const text = try v.screen();
    defer alloc.free(text);
    try check(std.mem.startsWith(u8, text, "inside"));
}

//=========================================================================
// Styles.
//=========================================================================

fn expectedColor(color: morse.Color) vt.Style.Color {
    return switch (color.kind) {
        .default => .none,
        .ansi, .palette => .{ .palette = color.index() },
        .rgb => .{ .rgb = .{ .r = color.r, .g = color.g, .b = color.b } },
    };
}

/// The same style, spelled the way the emulator spells it. `script` has no
/// counterpart; see the skip below.
fn expectedStyle(style: morse.Style) vt.Style {
    return .{
        .fg_color = expectedColor(style.fg),
        .bg_color = expectedColor(style.bg),
        .underline_color = expectedColor(style.underline_color),
        .flags = .{
            .bold = style.bold,
            .faint = style.dim,
            .italic = style.italic,
            .blink = style.blink,
            .inverse = style.reverse,
            .invisible = style.hidden,
            .strikethrough = style.strikethrough,
            .overline = style.overline,
            .underline = @enumFromInt(@intFromEnum(style.underline)),
        },
    };
}

fn checkStyle(v: *Vt, style: morse.Style) !void {
    checks += 1;
    const actual = v.cursor().style;
    if (!actual.eql(expectedStyle(style))) {
        std.log.info(
            "style mismatch\n  wanted {any}\n  got    {any}\n",
            .{ expectedStyle(style), actual },
        );
        return error.TestExpectedEqual;
    }
}

/// Every attribute, and every colour form on every one of the three colours.
const styles = [_]morse.Style{
    .{},
    .{ .bold = true },
    .{ .dim = true },
    .{ .bold = true, .dim = true },
    .{ .italic = true },
    .{ .blink = true },
    .{ .reverse = true },
    .{ .hidden = true },
    .{ .strikethrough = true },
    .{ .overline = true },
    .{ .underline = .single },
    .{ .underline = .double },
    .{ .underline = .curly },
    .{ .underline = .dotted },
    .{ .underline = .dashed },
    .{ .fg = .ansi(.red) },
    .{ .fg = .ansi(.bright_cyan) },
    .{ .bg = .ansi(.black) },
    .{ .bg = .ansi(.bright_white) },
    .{ .fg = .palette(196) },
    .{ .bg = .palette(17) },
    .{ .fg = .rgb(255, 128, 0) },
    .{ .bg = .rgb(1, 2, 3) },
    .{ .underline = .curly, .underline_color = .palette(9) },
    .{ .underline = .single, .underline_color = .rgb(200, 100, 50) },
    .{
        .bold = true,
        .dim = true,
        .italic = true,
        .blink = true,
        .reverse = true,
        .hidden = true,
        .strikethrough = true,
        .overline = true,
        .underline = .double,
        .fg = .rgb(10, 20, 30),
        .bg = .palette(240),
        .underline_color = .ansi(.green),
    },
};

test "setStyle leaves the emulator in exactly that style" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    for (styles) |style| {
        try morse.setStyle(v.w(), style);
        v.feed();
        try checkStyle(&v, style);
        try morse.resetStyle(v.w());
        v.feed();
        try checkStyle(&v, .{});
    }
}

test "diffStyle gets from any style to any other" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    for (styles) |from| {
        for (styles) |to| {
            try morse.resetStyle(v.w());
            try morse.setStyle(v.w(), from);
            v.feed();
            try morse.diffStyle(v.w(), from, to);
            v.feed();
            try checkStyle(&v, to);
        }
    }
}

test "superscript and subscript are not implemented by this emulator" {
    // SGR 73, 74 and 75 reach the emulator's own SGR parser as an unknown
    // attribute, which it drops: there is no field on its style for a
    // raised or lowered glyph. `Style.script` is therefore written here and
    // unobservable, and the byte-exact tests in `src/style.zig` are the
    // whole of what can be claimed for it.
    return error.SkipZigTest;
}

//=========================================================================
// Erasing, inserting, deleting and scrolling a known screen.
//=========================================================================

/// Five rows of five columns, filled with a letter each, as the ground the
/// assertions below stand on.
fn fillScreen(v: *Vt) !void {
    for (0..5) |row| {
        try morse.cursorTo(v.w(), @intCast(row + 1), 1);
        v.feed();
        v.print(switch (row) {
            0 => "AAAAA",
            1 => "BBBBB",
            2 => "CCCCC",
            3 => "DDDDD",
            else => "EEEEE",
        });
    }
}

fn checkScreen(v: *Vt, expected: []const u8) !void {
    const text = try v.screen();
    defer alloc.free(text);
    try checkString(expected, text);
}

test "clearScreen erases what it says it erases" {
    var v: Vt = undefined;
    try v.init(5, 5);
    defer v.deinit();

    try fillScreen(&v);
    try morse.cursorTo(v.w(), 3, 3);
    try morse.clearScreen(v.w(), .to_end);
    v.feed();
    try checkScreen(&v, "AAAAA\nBBBBB\nCC");

    try fillScreen(&v);
    try morse.cursorTo(v.w(), 3, 3);
    try morse.clearScreen(v.w(), .to_start);
    v.feed();
    try checkScreen(&v, "\n\n   CC\nDDDDD\nEEEEE");

    try fillScreen(&v);
    try morse.clearScreen(v.w(), .all);
    v.feed();
    try checkScreen(&v, "");
}

test "clearLine erases what it says it erases" {
    var v: Vt = undefined;
    try v.init(5, 5);
    defer v.deinit();

    try fillScreen(&v);
    try morse.cursorTo(v.w(), 2, 3);
    try morse.clearLine(v.w(), .to_end);
    v.feed();
    try checkScreen(&v, "AAAAA\nBB\nCCCCC\nDDDDD\nEEEEE");

    try fillScreen(&v);
    try morse.cursorTo(v.w(), 2, 3);
    try morse.clearLine(v.w(), .to_start);
    v.feed();
    try checkScreen(&v, "AAAAA\n   BB\nCCCCC\nDDDDD\nEEEEE");

    try fillScreen(&v);
    try morse.cursorTo(v.w(), 2, 3);
    try morse.clearLine(v.w(), .all);
    v.feed();
    try checkScreen(&v, "AAAAA\n\nCCCCC\nDDDDD\nEEEEE");
}

test "insert and delete move the cells the sequences name" {
    var v: Vt = undefined;
    try v.init(5, 5);
    defer v.deinit();

    try fillScreen(&v);
    try morse.cursorTo(v.w(), 2, 1);
    try morse.insertLines(v.w(), 1);
    v.feed();
    try checkScreen(&v, "AAAAA\n\nBBBBB\nCCCCC\nDDDDD");

    try fillScreen(&v);
    try morse.cursorTo(v.w(), 2, 1);
    try morse.deleteLines(v.w(), 2);
    v.feed();
    try checkScreen(&v, "AAAAA\nDDDDD\nEEEEE");

    try fillScreen(&v);
    try morse.cursorTo(v.w(), 3, 2);
    try morse.insertChars(v.w(), 2);
    v.feed();
    try checkScreen(&v, "AAAAA\nBBBBB\nC  CC\nDDDDD\nEEEEE");

    try fillScreen(&v);
    try morse.cursorTo(v.w(), 3, 2);
    try morse.deleteChars(v.w(), 2);
    v.feed();
    try checkScreen(&v, "AAAAA\nBBBBB\nCCC\nDDDDD\nEEEEE");

    try fillScreen(&v);
    try morse.cursorTo(v.w(), 3, 2);
    try morse.eraseChars(v.w(), 3);
    v.feed();
    try checkScreen(&v, "AAAAA\nBBBBB\nC   C\nDDDDD\nEEEEE");
}

test "the scroll region bounds the scrolling sequences" {
    var v: Vt = undefined;
    try v.init(5, 5);
    defer v.deinit();

    try fillScreen(&v);
    try morse.scrollRegion(v.w(), 2, 4);
    v.feed();
    try checkEqual(@as(usize, 1), v.term.scrolling_region.top);
    try checkEqual(@as(usize, 3), v.term.scrolling_region.bottom);

    try morse.scrollUp(v.w(), 1);
    v.feed();
    try checkScreen(&v, "AAAAA\nCCCCC\nDDDDD\n\nEEEEE");

    try morse.scrollDown(v.w(), 1);
    v.feed();
    try checkScreen(&v, "AAAAA\n\nCCCCC\nDDDDD\nEEEEE");

    try morse.scrollRegionReset(v.w());
    v.feed();
    try checkEqual(@as(usize, 0), v.term.scrolling_region.top);
    try checkEqual(@as(usize, 4), v.term.scrolling_region.bottom);
}

test "repeatChar draws the run the count asks for" {
    var v: Vt = undefined;
    try v.init(10, 2);
    defer v.deinit();

    v.print("-");
    try morse.repeatChar(v.w(), 4);
    v.feed();
    try checkScreen(&v, "-----");
}

test "a count of zero leaves the screen and the cursor where they were" {
    var v: Vt = undefined;
    try v.init(5, 5);
    defer v.deinit();

    // Sent as `CSI 0 final`, every one of these would act once.
    const counts = [_]*const fn (*std.Io.Writer, u32) std.Io.Writer.Error!void{
        morse.cursorUp,       morse.cursorDown,     morse.cursorRight, morse.cursorLeft,
        morse.cursorNextLine, morse.cursorPrevLine, morse.scrollUp,    morse.scrollDown,
        morse.insertLines,    morse.deleteLines,    morse.insertChars, morse.deleteChars,
        morse.eraseChars,     morse.repeatChar,
    };
    for (counts) |write| {
        try fillScreen(&v);
        try morse.cursorTo(v.w(), 3, 3);
        v.feed();
        v.print("x");
        try write(v.w(), 0);
        v.feed();
        try checkEqual(@as(usize, 3), v.cursor().x);
        try checkEqual(@as(usize, 2), v.cursor().y);
        try checkScreen(&v, "AAAAA\nBBBBB\nCCxCC\nDDDDD\nEEEEE");
    }

    // A position of zero is the first row or column.
    try morse.cursorTo(v.w(), 0, 0);
    v.feed();
    try checkEqual(@as(usize, 0), v.cursor().x);
    try checkEqual(@as(usize, 0), v.cursor().y);
    try morse.cursorTo(v.w(), 3, 3);
    try morse.cursorColumn(v.w(), 0);
    try morse.cursorRow(v.w(), 0);
    v.feed();
    try checkEqual(@as(usize, 0), v.cursor().x);
    try checkEqual(@as(usize, 0), v.cursor().y);
}

//=========================================================================
// Titles, working directory and hyperlinks.
//=========================================================================

/// An OSC sequence with its introducer and its terminator taken off, which
/// is what the emulator's own OSC parser is fed.
fn payload(sequence: []const u8) []const u8 {
    const body = sequence[2..];
    return if (body[body.len - 1] == 0x07)
        body[0 .. body.len - 1]
    else
        body[0 .. body.len - 2];
}

test "a title reaches the emulator's title" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    try morse.title(v.w(), "morse conformance");
    v.feed();
    try checkString("morse conformance", v.term.getTitle().?);

    try morse.workingDirectory(v.w(), "file:///tmp");
    v.feed();
    try checkString("file:///tmp", v.term.getPwd().?);
}

test "the icon name is parsed and then dropped by this emulator" {
    // OSC 1 reaches the emulator's OSC parser, which reads the name out of
    // it; the terminal it feeds keeps no icon name to set, so the sequence
    // stops there. The parse is what can be asserted, and it is.
    var parser: vt.osc.Parser = .init(null);
    defer parser.deinit();

    var buffer: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try morse.iconName(&out, "morse");

    // The parser is fed the payload alone: no introducer, no terminator.
    for (payload(out.buffered())) |byte| parser.next(byte);
    const command = parser.end(0x1b).?;
    try check(command.* == .change_window_icon);
    try checkString("morse", command.change_window_icon);
}

test "a hyperlink lands on the cells with its uri and its id" {
    var v: Vt = undefined;
    try v.init(20, 2);
    defer v.deinit();

    try morse.hyperlinkStart(v.w(), "https://example.com", "id=seven");
    v.feed();
    v.print("link");
    try morse.hyperlinkEnd(v.w());
    v.feed();
    v.print("bare");

    const screen = v.term.screens.active;
    for (0..4) |x| {
        const list_cell = screen.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        try check(list_cell.cell.hyperlink);
        const page = list_cell.node.page();
        const id = page.lookupHyperlink(list_cell.cell).?;
        const entry = page.hyperlink_set.get(page.memory, id);
        try checkString("https://example.com", entry.uri.slice(page.memory));
        try checkString("seven", entry.id.explicit.slice(page.memory));
    }

    // And the cells after `hyperlinkEnd` carry none.
    for (4..8) |x| {
        const list_cell = screen.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        try check(!list_cell.cell.hyperlink);
    }
}

//=========================================================================
// The keyboard protocol stack.
//=========================================================================

fn currentFlags(v: *Vt) morse.KittyFlags {
    return .fromBits(v.term.screens.active.kitty_keyboard.current().int());
}

test "the keyboard flags are pushed, set and popped" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    try checkEqual(morse.KittyFlags{}, currentFlags(&v));

    const pushed: morse.KittyFlags = .{
        .disambiguate_escape_codes = true,
        .report_event_types = true,
        .report_associated_text = true,
    };
    try morse.kittyKeyboardPush(v.w(), pushed);
    v.feed();
    try checkEqual(pushed, currentFlags(&v));

    // Replace, add, remove -- the three the protocol has.
    try morse.kittyKeyboardSet(v.w(), .{ .report_alternate_keys = true }, .replace);
    v.feed();
    try checkEqual(morse.KittyFlags{ .report_alternate_keys = true }, currentFlags(&v));

    try morse.kittyKeyboardSet(v.w(), .{ .report_all_keys_as_escape_codes = true }, .add);
    v.feed();
    try checkEqual(morse.KittyFlags{
        .report_alternate_keys = true,
        .report_all_keys_as_escape_codes = true,
    }, currentFlags(&v));

    try morse.kittyKeyboardSet(v.w(), .{ .report_alternate_keys = true }, .remove);
    v.feed();
    try checkEqual(morse.KittyFlags{ .report_all_keys_as_escape_codes = true }, currentFlags(&v));

    // The query, read by this package's parser.
    v.resetReplies();
    try morse.kittyKeyboardQuery(v.w());
    v.feed();
    try checkEqual(
        morse.KittyFlags{ .report_all_keys_as_escape_codes = true },
        morse.parseKittyKeyboardReply(v.replies()).?,
    );

    // And back to where the push found it.
    try morse.kittyKeyboardPop(v.w());
    v.feed();
    try checkEqual(morse.KittyFlags{}, currentFlags(&v));
}

//=========================================================================
// Graphics.
//=========================================================================

test "an image is transmitted, placed and taken away" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    // Two by two, four bytes a pixel.
    const pixels: [16]u8 = @splat(0xff);
    try morse.transmitImage(v.w(), .{
        .image = .{ .id = 7 },
        .format = .rgba,
        .width = 2,
        .height = 2,
        .quiet = .silent,
    }, &pixels);
    v.feed();

    const images = &v.term.screens.active.kitty_images;
    const image = images.imageById(7).?;
    try checkEqual(@as(u32, 7), image.id);
    try checkEqual(@as(u32, 2), image.width);
    try checkEqual(@as(u32, 2), image.height);

    try morse.cursorTo(v.w(), 4, 1);
    try morse.placeImage(v.w(), .{
        .image = .{ .id = 7 },
        .placement = .{ .id = 1, .columns = 8, .rows = 4, .z = -1, .keep_cursor = true },
        .quiet = .silent,
    });
    v.feed();
    try checkEqual(@as(usize, 1), images.placements.count());

    // `keep_cursor` means the cursor did not move for the picture.
    try checkEqual(@as(usize, 0), v.cursor().x);
    try checkEqual(@as(usize, 3), v.cursor().y);

    var placements = images.placements.iterator();
    const placement = placements.next().?;
    try checkEqual(@as(u32, 7), placement.key_ptr.image_id);
    try checkEqual(@as(i32, -1), placement.value_ptr.z);

    // The placement goes, the pixels stay.
    try morse.deleteImage(v.w(), .{
        .target = .{ .image = .{ .id = 7, .placement = 1 } },
        .quiet = .silent,
    });
    v.feed();
    try checkEqual(@as(usize, 0), images.placements.count());
    try check(images.imageById(7) != null);

    // And now the pixels too.
    try morse.deleteImage(v.w(), .{
        .target = .{ .image = .{ .id = 7 } },
        .free = true,
        .quiet = .silent,
    });
    v.feed();
    try check(images.imageById(7) == null);
}

test "a graphics command that asks for an answer gets one" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    const pixels: [4]u8 = @splat(0xff);
    v.resetReplies();
    try morse.transmitImage(v.w(), .{
        .image = .{ .id = 31 },
        .format = .rgba,
        .width = 1,
        .height = 1,
        .quiet = .answers,
    }, &pixels);
    v.feed();

    const response = morse.parseGraphicsResponse(v.replies()).?;
    try checkEqual(@as(?u32, 31), response.id);
    try check(response.ok());
}

test "the graphics query is answered" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    v.resetReplies();
    try morse.queryGraphics(v.w(), 31);
    v.feed();

    const response = morse.parseGraphicsResponse(v.replies()).?;
    try checkEqual(@as(?u32, 31), response.id);
    try check(response.ok());
}

test "an animation is built out of frames, played, and composed" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    // The image the frames belong to: two by two, RGBA, all white.
    const white: [16]u8 = @splat(0xff);
    try morse.transmitImage(v.w(), .{
        .image = .{ .id = 9 },
        .format = .rgba,
        .width = 2,
        .height = 2,
        .quiet = .silent,
    }, &white);
    v.feed();

    const images = &v.term.screens.active.kitty_images;
    try check(images.imageById(9) != null);
    // The root frame is the image's own pixels, so an image with no frame
    // command behind it has no animation at all.
    try check(images.imageById(9).?.animation == null);

    // Two frames on top of it, each a full-size rectangle with a gap.
    const red = [_]u8{
        0xff, 0x00, 0x00, 0xff,
        0xff, 0x00, 0x00, 0xff,
        0xff, 0x00, 0x00, 0xff,
        0xff, 0x00, 0x00, 0xff,
    };
    try morse.transmitFrame(v.w(), .{
        .image = .{ .id = 9 },
        .format = .rgba,
        .width = 2,
        .height = 2,
        .gap = 48,
        .quiet = .silent,
    }, &red);
    v.feed();

    const blue = [_]u8{
        0x00, 0x00, 0xff, 0xff,
        0x00, 0x00, 0xff, 0xff,
        0x00, 0x00, 0xff, 0xff,
        0x00, 0x00, 0xff, 0xff,
    };
    try morse.transmitFrame(v.w(), .{
        .image = .{ .id = 9 },
        .format = .rgba,
        .width = 2,
        .height = 2,
        .base = 2,
        .compose = .overwrite,
        .gap = 30,
        .quiet = .silent,
    }, &blue);
    v.feed();

    const animation = images.imageById(9).?.animation.?;
    try checkEqual(@as(u32, 3), animation.frameCount());
    try checkEqual(@as(u32, 48), animation.gapAt(1));
    try checkEqual(@as(u32, 30), animation.gapAt(2));

    // The root frame is made gapless, and `a=a` is the only way it is ever
    // given a gap.
    try checkEqual(@as(u32, 0), animation.gapAt(0));
    try morse.animateImage(v.w(), .{ .image = .{ .id = 9 }, .frame = 1, .gap = 40 });
    v.feed();
    try checkEqual(@as(u32, 40), animation.gapAt(0));

    // Naming a frame is the whole of a client-driven animation.
    try morse.animateImage(v.w(), .{ .image = .{ .id = 9 }, .current = 3 });
    v.feed();
    try checkEqual(@as(u32, 2), animation.current_index);

    // And the three playback states, with a loop count.
    try morse.animateImage(v.w(), .{ .image = .{ .id = 9 }, .state = .loading });
    v.feed();
    try check(animation.state == .loading);

    try morse.animateImage(v.w(), .{ .image = .{ .id = 9 }, .state = .running, .loops = 4 });
    v.feed();
    try check(animation.state == .running);
    try checkEqual(@as(u32, 3), animation.max_loops);

    try morse.animateImage(v.w(), .{ .image = .{ .id = 9 }, .state = .stopped });
    v.feed();
    try check(animation.state == .stopped);

    // A composition moves pixels the terminal already has: the top-left
    // pixel of the red frame onto the top-left pixel of the blue one.
    const before = images.imageById(9).?.frameData(3).?[0..4].*;
    try checkEqual([4]u8{ 0x00, 0x00, 0xff, 0xff }, before);

    try morse.composeFrames(v.w(), .{
        .image = .{ .id = 9 },
        .source = 2,
        .destination = 3,
        .width = 1,
        .height = 1,
        .compose = .overwrite,
        .quiet = .silent,
    });
    v.feed();

    const after = images.imageById(9).?.frameData(3).?[0..4].*;
    try checkEqual([4]u8{ 0xff, 0x00, 0x00, 0xff }, after);

    // And the one animation command the delete writer already reached:
    // `d=f` takes a frame away and leaves the image standing.
    try morse.deleteImage(v.w(), .{
        .target = .{ .frames = .{ .id = 9 } },
        .quiet = .silent,
    });
    v.feed();
    try check(images.imageById(9) != null);
    try checkEqual(@as(u32, 2), images.imageById(9).?.animation.?.frameCount());
}

test "a frame command is answered, and a chunked one is answered once" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    const pixels: [16]u8 = @splat(0xff);
    try morse.transmitImage(v.w(), .{
        .image = .{ .id = 11 },
        .format = .rgba,
        .width = 2,
        .height = 2,
        .quiet = .silent,
    }, &pixels);
    v.feed();

    // A frame large enough to need two sequences, which is where the
    // protocol asks for `a=f` on the continuation chunk as well.
    const frame: [morse.graphics_chunk_bytes + 4]u8 = @splat(0x40);
    v.resetReplies();
    try morse.transmitFrame(&v.writer, .{
        .image = .{ .id = 11 },
        .format = .rgba,
        .width = 2,
        .height = 2,
    }, &frame);
    v.feed();

    const response = morse.parseGraphicsResponse(v.replies()).?;
    try checkEqual(@as(?u32, 11), response.id);
    try check(response.ok());
    try checkEqual(@as(u32, 2), v.term.screens.active.kitty_images.imageById(11).?.animation.?.frameCount());
}

//=========================================================================
// What this emulator does not implement.
//=========================================================================

test "text sizing is parsed but not drawn by this emulator" {
    // The emulator reads OSC 66 into its own command type and then drops
    // it: there is no scaled text on its screen to assert against. The
    // parse is what is left, and it agrees field for field.
    var parser: vt.osc.Parser = .init(null);
    defer parser.deinit();

    var buffer: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try morse.textSize(&out, .{
        .scale = 2,
        .width = 4,
        .numerator = 1,
        .denominator = 2,
        .vertical = .center,
        .horizontal = .right,
    }, "morse");

    for (payload(out.buffered())) |byte| parser.next(byte);
    const command = parser.end(0x1b).?;
    try check(command.* == .kitty_text_sizing);
    const sizing = command.kitty_text_sizing;
    try checkEqual(@as(u3, 2), sizing.scale);
    try checkEqual(@as(u3, 4), sizing.width);
    try checkEqual(@as(u4, 1), sizing.numerator);
    try checkEqual(@as(u4, 2), sizing.denominator);
    try checkString("morse", sizing.text);
}

test "multiple cursors are not implemented by this emulator" {
    // `CSI > ... SP q` and its three queries reach nothing here: the
    // emulator has no extra cursors and answers none of the questions. The
    // byte-exact tests and the reply parsers in `src/multicursor.zig` are
    // the whole of what can be claimed for the protocol.
    return error.SkipZigTest;
}

//=========================================================================
// The other direction: replies, read by this package's parsers.
//=========================================================================

test "the device attributes replies parse" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    v.resetReplies();
    try morse.queryDeviceAttributes(v.w());
    v.feed();
    const primary = morse.parseDeviceAttributes(v.replies()).?;
    try check(primary.class > 0);

    v.resetReplies();
    try morse.querySecondaryDeviceAttributes(v.w());
    v.feed();
    const secondary = morse.parseSecondaryDeviceAttributes(v.replies()).?;
    try check(secondary.terminal_type > 0);
}

test "the version reply parses" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    v.resetReplies();
    try morse.queryVersion(v.w());
    v.feed();
    try checkString("conformance 1.2.3", morse.parseVersion(v.replies()).?);
}

test "the colour replies parse" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    // The three the terminal was built with, read back.
    const configured = [_]struct { morse.ColorTarget, morse.Rgb16 }{
        .{ .foreground, .{ .r = 0xd0d0, .g = 0xd0d0, .b = 0xd0d0 } },
        .{ .background, .{ .r = 0x1c1c, .g = 0x1c1c, .b = 0x1c1c } },
        .{ .cursor, .{ .r = 0xffff, .g = 0xa0a0, .b = 0x0000 } },
    };
    for (configured) |pair| {
        v.resetReplies();
        try morse.queryColor(v.w(), pair[0]);
        v.feed();
        const report = morse.parseColorReply(v.replies()).?;
        try checkEqual(pair[0], report.target);
        try checkEqual(pair[1].r, report.color.r);
        try checkEqual(pair[1].g, report.color.g);
        try checkEqual(pair[1].b, report.color.b);
    }

    // And one set by `setColor`, read back the same way.
    v.resetReplies();
    try morse.setColor(v.w(), .background, .{ .r = 0x2020, .g = 0x3030, .b = 0x4040 });
    try morse.queryColor(v.w(), .background);
    v.feed();
    const changed = morse.parseColorReply(v.replies()).?;
    try checkEqual(@as(u16, 0x2020), changed.color.r);
    try checkEqual(@as(u16, 0x3030), changed.color.g);
    try checkEqual(@as(u16, 0x4040), changed.color.b);

    v.resetReplies();
    try morse.resetColor(v.w(), .background);
    try morse.queryColor(v.w(), .background);
    v.feed();
    const restored = morse.parseColorReply(v.replies()).?;
    try checkEqual(@as(u16, 0x1c1c), restored.color.r);

    // A palette entry set and then read back is the round trip that says
    // the writer and the parser agree with the terminal in between. The
    // channels are doubled bytes because this terminal keeps eight bits a
    // channel and reports them twice, which is what `Rgb16.to8` is for.
    v.resetReplies();
    try morse.setPaletteColor(v.w(), 9, .{ .r = 0x1212, .g = 0x5656, .b = 0x9a9a });
    try morse.queryPaletteColor(v.w(), 9);
    v.feed();
    const palette = morse.parsePaletteReply(v.replies()).?;
    try checkEqual(@as(u8, 9), palette.index);
    try checkEqual(@as(u16, 0x1212), palette.color.r);
    try checkEqual(@as(u16, 0x5656), palette.color.g);
    try checkEqual(@as(u16, 0x9a9a), palette.color.b);
    const eight = palette.color.to8();
    try checkEqual(@as(u8, 0x12), eight.r);
    try checkEqual(@as(u8, 0x56), eight.g);
    try checkEqual(@as(u8, 0x9a), eight.b);
}

test "the colour scheme reply parses" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    v.resetReplies();
    try morse.queryColorScheme(v.w());
    v.feed();
    try checkEqual(morse.ColorScheme.dark, morse.parseColorSchemeReply(v.replies()).?);
}

test "the window size replies parse" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    v.resetReplies();
    try morse.queryWindowSize(v.w(), .cell_pixels);
    v.feed();
    const cell = morse.parseWindowSize(v.replies()).?;
    try checkEqual(morse.WindowSize.What.cell_pixels, cell.what);
    try checkEqual(@as(u32, 18), cell.height);
    try checkEqual(@as(u32, 9), cell.width);

    v.resetReplies();
    try morse.queryWindowSize(v.w(), .text_area_cells);
    v.feed();
    const cells = morse.parseWindowSize(v.replies()).?;
    try checkEqual(morse.WindowSize.What.text_area_cells, cells.what);
    try checkEqual(@as(u32, 24), cells.height);
    try checkEqual(@as(u32, 80), cells.width);

    v.resetReplies();
    try morse.queryWindowSize(v.w(), .text_area_pixels);
    v.feed();
    const pixels = morse.parseWindowSize(v.replies()).?;
    try checkEqual(morse.WindowSize.What.text_area_pixels, pixels.what);
}

test "a capability reply parses" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    v.resetReplies();
    try morse.queryCapability(v.w(), "TN");
    v.feed();

    const reply = morse.parseCapabilityReply(v.replies()).?;
    try check(reply.known);
    var entries = reply.iterator();
    const entry = entries.next().?;
    var name: [8]u8 = undefined;
    try checkString("TN", try entry.decodeName(&name));
    var value: [64]u8 = undefined;
    try checkString("conformance", try entry.decodeValue(&value));
}

test "the startup probe is one write and a stream of answers" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    v.resetReplies();
    try (morse.Probe{ .graphics_id = 31 }).write(v.w());
    v.feed();

    // The answers come back as one byte stream carrying replies of four
    // shapes, so they are framed and read the way a program reads them: by
    // the parser that frames its keys, as typed replies.
    var input: [4096]u8 = undefined;
    var keys: morse.KeyParser = .init(&input);
    var events = keys.feed(v.replies());

    var answered: std.EnumSet(morse.Probe.Question) = .initEmpty();
    while (events.next()) |event| {
        // Every answer the emulator sent is read as an answer: nothing it
        // says back to the probe is left as bytes for the program.
        try check(event != .unhandled);
        if (morse.probeAnswered(event)) |question| answered.insert(question);
    }

    // DA1 is the sentinel the whole order is built around: if it did not
    // come back, nothing about the rest of this is safe to read.
    try check(answered.contains(.device_attributes));

    // What this emulator answers. The questions it leaves unanswered are
    // answered by silence, which is the case `Probe` exists to make safe.
    for ([_]morse.Probe.Question{
        .cursor_position,
        .foreground_color,
        .background_color,
        .cursor_color,
        .color_scheme,
        .sync_output,
        .unicode_core,
        .in_band_resize,
        // Not a mode it has, which it says: a sixel question answered.
        .sixel_cursor_right,
        .kitty_keyboard,
        .graphics,
        .truecolor,
        .color_count,
        .version,
        .text_area_cells,
        .cell_pixels,
        .secondary_device_attributes,
        .device_attributes,
    }) |question| {
        checks += 1;
        if (!answered.contains(question)) {
            std.log.info("probe: no answer for {t}\n", .{question});
            return error.TestExpectedEqual;
        }
    }
}

//=========================================================================
// The rest of the writers.
//=========================================================================

test "the cursor shape is the one the sequence named" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    const cases = [_]struct { morse.CursorShape, vt.CursorStyle, bool }{
        .{ .block_blink, .block, true },
        .{ .block, .block, false },
        .{ .underline_blink, .underline, true },
        .{ .underline, .underline, false },
        .{ .bar_blink, .bar, true },
        .{ .bar, .bar, false },
        // Back to whatever the terminal was configured with, which here is
        // a steady block.
        .{ .default, .block, false },
    };

    for (cases) |case| {
        try morse.cursorShape(v.w(), case[0]);
        v.feed();
        try checkEqual(case[1], v.cursor().cursor_style);
        try checkEqual(case[2], v.term.modes.get(.cursor_blinking));
    }
}

test "the pointer shape reaches the emulator by name" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    const cases = [_]struct { morse.PointerShape, vt.MouseShape }{
        .{ .default, .default },
        .{ .text, .text },
        .{ .pointer, .pointer },
        .{ .help, .help },
        .{ .wait, .wait },
        .{ .progress, .progress },
        .{ .crosshair, .crosshair },
        .{ .cell, .cell },
        .{ .move, .move },
        .{ .grab, .grab },
        .{ .grabbing, .grabbing },
        // The three whose protocol name is not their Zig name.
        .{ .not_allowed, .not_allowed },
        .{ .col_resize, .col_resize },
        .{ .row_resize, .row_resize },
    };

    for (cases) |case| {
        try morse.pointerShape(v.w(), case[0]);
        v.feed();
        try checkEqual(case[1], v.term.mouse_shape);
    }
}

test "a clipboard payload arrives as the bytes that went in" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    // Every base64 tail length, and bytes outside ASCII, because the
    // encoder writes three source bytes at a time and the last group is
    // where a padded encoder goes wrong.
    for ([_][]const u8{
        "a",
        "ab",
        "abc",
        "abcd",
        "copied by morse \u{2500}\u{2501}\u{00e9}",
    }) |text| {
        clipboard_location = null;
        clipboard_len = 0;
        try morse.clipboardWrite(v.w(), .clipboard, text);
        v.feed();
        try checkEqual(vt.clipboard.Location.standard, clipboard_location.?);
        try checkString(text, clipboard_text[0..clipboard_len]);
    }
}

test "a notification arrives with its title and its body" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    notifications = 0;
    try morse.notify(v.w(), "Build finished", "0 errors");
    v.feed();
    try checkEqual(@as(usize, 1), notifications);
    try checkString("Build finished", notification_title[0..notification_title_len]);
    try checkString("0 errors", notification_body[0..notification_body_len]);

    // The older form carries a body and no title.
    try morse.notify9(v.w(), "just a body");
    v.feed();
    try checkEqual(@as(usize, 2), notifications);
    try checkString("just a body", notification_body[0..notification_body_len]);
}

test "a progress report arrives in each of its states" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    const State = vt.osc.Command.ProgressReport.State;
    const cases = [_]struct { morse.Progress, State, ?u8 }{
        .{ .{ .percent = 40 }, .set, 40 },
        .{ .{ .failed = 80 }, .@"error", 80 },
        // The two states that carry no percentage are written with a zero
        // and read back as none, which is the shape the protocol gives them.
        .{ .indeterminate, .indeterminate, null },
        .{ .{ .warning = 55 }, .pause, 55 },
        .{ .none, .remove, null },
    };

    for (cases) |case| {
        progress_report = null;
        try morse.progress(v.w(), case[0]);
        v.feed();
        const report = progress_report.?;
        try checkEqual(case[1], report.state);
        try checkEqual(case[2], report.progress);
    }
}

test "the prompt marks reach the row they mark" {
    var v: Vt = undefined;
    try v.init(20, 4);
    defer v.deinit();

    try morse.promptStart(v.w());
    v.feed();
    v.print("$ ");
    try checkEqual(vt.Cell.SemanticContent.prompt, v.cursor().semantic_content);

    try morse.promptEnd(v.w());
    v.feed();
    v.print("ls");
    try checkEqual(vt.Cell.SemanticContent.input, v.cursor().semantic_content);

    try morse.commandStart(v.w());
    v.feed();
    v.print("a b");
    try checkEqual(vt.Cell.SemanticContent.output, v.cursor().semantic_content);

    // And the end mark, with the status the command exited on.
    try morse.commandEnd(v.w(), 1);
    v.feed();
}

test "the alternate screen is a second screen" {
    var v: Vt = undefined;
    try v.init(10, 3);
    defer v.deinit();

    v.print("primary");
    try morse.altScreen.set(v.w(), true);
    v.feed();
    try checkScreen(&v, "");

    // Mode 1049 saves the cursor rather than moving it, so a program that
    // takes the screen puts the cursor where it wants it.
    try morse.cursorTo(v.w(), 1, 1);
    v.feed();
    v.print("alternate");
    try checkScreen(&v, "alternate");

    try morse.altScreen.set(v.w(), false);
    v.feed();
    try checkScreen(&v, "primary");
}

test "a mode morse does not name still goes through setMode" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    // Mode 1007, alternate scroll, which this package has no name for.
    try morse.setMode(v.w(), 1007, false);
    v.feed();
    try checkEqual(morse.ModeState.reset, try modeState(&v, 1007));

    try morse.setMode(v.w(), 1007, true);
    v.feed();
    try checkEqual(morse.ModeState.set, try modeState(&v, 1007));
}

//=========================================================================
// Keys, against the emulator's own encoder.
//
// The emulator writes keys for the program inside it, which is what
// `encodeKey` does. Each key below is built as a terminal sees it -- the
// key, what it types, its shifted form, the key at its position on the
// base layout -- and handed to both encoders in every state the bytes
// depend on: the sixteen combinations of modifyOtherKeys, DECCKM, DECKPAM
// and DECBKM, and the sixteen sets of kitty flags that disambiguate.
//
// Where kitty's encoder and ghostty's disagree, morse follows kitty, and
// where ghostty has no spelling for a key morse writes one; each such
// difference is named below with its reason, and each must still occur, so
// the list cannot outlive the difference.
//=========================================================================

const GhosttyKey = vt.input.Key;

/// The emulator's key for a morse key, or null for one it does not have.
fn ghosttyNamed(k: morse.Key) ?GhosttyKey {
    return switch (k) {
        .escape => .escape,
        .enter => .enter,
        .tab => .tab,
        .backspace => .backspace,
        .insert => .insert,
        .delete => .delete,
        .left => .arrow_left,
        .right => .arrow_right,
        .up => .arrow_up,
        .down => .arrow_down,
        .page_up => .page_up,
        .page_down => .page_down,
        .home => .home,
        .end => .end,
        .caps_lock => .caps_lock,
        .scroll_lock => .scroll_lock,
        .num_lock => .num_lock,
        .print_screen => .print_screen,
        .pause => .pause,
        .menu => .context_menu,
        .kp_0 => .numpad_0,
        .kp_1 => .numpad_1,
        .kp_2 => .numpad_2,
        .kp_3 => .numpad_3,
        .kp_4 => .numpad_4,
        .kp_5 => .numpad_5,
        .kp_6 => .numpad_6,
        .kp_7 => .numpad_7,
        .kp_8 => .numpad_8,
        .kp_9 => .numpad_9,
        .kp_decimal => .numpad_decimal,
        .kp_divide => .numpad_divide,
        .kp_multiply => .numpad_multiply,
        .kp_subtract => .numpad_subtract,
        .kp_add => .numpad_add,
        .kp_enter => .numpad_enter,
        .kp_equal => .numpad_equal,
        .kp_separator => .numpad_separator,
        .kp_left => .numpad_left,
        .kp_right => .numpad_right,
        .kp_up => .numpad_up,
        .kp_down => .numpad_down,
        .kp_page_up => .numpad_page_up,
        .kp_page_down => .numpad_page_down,
        .kp_home => .numpad_home,
        .kp_end => .numpad_end,
        .kp_insert => .numpad_insert,
        .kp_delete => .numpad_delete,
        .kp_begin => .numpad_begin,
        .left_shift => .shift_left,
        .left_ctrl => .control_left,
        .left_alt => .alt_left,
        .left_super => .meta_left,
        .right_shift => .shift_right,
        .right_ctrl => .control_right,
        .right_alt => .alt_right,
        .right_super => .meta_right,
        .f => |n| if (n >= 1 and n <= 25) @enumFromInt(@intFromEnum(GhosttyKey.f1) + @as(c_int, n - 1)) else null,
        else => null,
    };
}

/// What shift types on a US layout, which is the layout both encoders are
/// told about here.
fn usShifted(c: u21) ?u21 {
    if (c >= 'a' and c <= 'z') return c - 0x20;
    const from = "`1234567890-=[]\\;',./";
    const to = "~!@#$%^&*()_+{}|:\"<>?";
    for (from, to) |f, t| if (c == f) return t;
    return null;
}

/// One key as a terminal sees it.
const KeyCase = struct {
    key: morse.Key,
    /// The key at the same position on the base layout, when it differs.
    base: ?u21 = null,
    mods: morse.Modifiers,
    kind: morse.Kind,
};

/// The two encoders' views of one key, built from the same facts.
const KeyPair = struct {
    ours: morse.KeyEvent,
    theirs: vt.input.KeyEvent,
    utf8: [4]u8 = undefined,
};

fn keyPair(case: KeyCase, pair: *KeyPair) void {
    var ours: morse.KeyEvent = .{ .key = case.key, .mods = case.mods, .kind = case.kind, .base = case.base };
    var theirs: vt.input.KeyEvent = .{
        .action = switch (case.kind) {
            .press => .press,
            .repeat => .repeat,
            .release => .release,
        },
        .mods = .{
            .shift = case.mods.shift,
            .ctrl = case.mods.ctrl,
            .alt = case.mods.alt,
            .super = case.mods.super,
            .caps_lock = case.mods.caps_lock,
            .num_lock = case.mods.num_lock,
        },
    };
    switch (case.key) {
        .char => |c| {
            // What the key types with shift as held: the text a terminal
            // reads off the layout, whatever else is held.
            const typed = if (case.mods.shift) usShifted(c) orelse c else c;
            const n = std.unicode.utf8Encode(typed, &pair.utf8) catch unreachable; // unreachable: the fixture key and its US shifted form are Unicode scalars
            theirs.utf8 = pair.utf8[0..n];
            theirs.unshifted_codepoint = c;
            theirs.consumed_mods = .{ .shift = case.mods.shift };
            const at = case.base orelse c;
            theirs.key = if (at < 0x80) GhosttyKey.fromASCII(@intCast(at)) orelse .unidentified else .unidentified;
            if (case.mods.shift and typed != c) ours.shifted = typed;
            // Text only where a key types it: not with a modifier that
            // makes it a command, and not on the way up.
            const m = case.mods;
            if (case.kind != .release and !m.ctrl and !m.alt and !m.super) {
                @memcpy(ours.text_buffer[0..n], pair.utf8[0..n]);
                ours.text_len = @intCast(n);
            }
        },
        else => theirs.key = ghosttyNamed(case.key).?,
    }
    pair.ours = ours;
    pair.theirs = theirs;
}

/// A difference between the two encoders that is a choice, and why.
const Difference = enum {
    /// Kitty reports the release of enter, tab and backspace held with a
    /// modifier, whose press was a sequence too; ghostty drops every
    /// release of the three unless every key is a sequence.
    release_of_modified_enter_tab_backspace,
    /// Ghostty reports the character a keypad key types as the key's base
    /// layout key; kitty reports no alternates on a functional key.
    keypad_base_layout_key,
    /// Kitty leaves out the event type of a press on the keys with a final
    /// of their own (`CSI A`); ghostty writes `:1`.
    press_event_on_special_key,
    /// Kitty writes the keypad's begin key as `CSI E`; ghostty as 57427.
    keypad_begin,
    /// Kitty treats scroll lock as a modifier key, reported only with every
    /// key as a sequence; ghostty reports it with disambiguation alone.
    scroll_lock,
    /// Ghostty has no kitty spelling for the menu key and writes nothing.
    menu,
    /// Ghostty writes nothing for backspace with control, alt and shift,
    /// which every other combination spells as its control code.
    backspace_all_three,
    /// The fixterms form keeps super beside control so it reads back;
    /// ghostty's has room for shift, alt and control only.
    super_in_fixterms,
    /// The keypad's equals and separator are written as the other keypad
    /// keys are in legacy mode; ghostty has no entry for them and writes
    /// nothing.
    keypad_equal_separator,
};

fn difference(case: KeyCase, enc: morse.KeyEncoding, ours: []const u8, theirs: []const u8) ?Difference {
    const kitty = enc.kitty.bits() != 0;
    if (kitty) {
        if (enc.kitty.report_alternate_keys and std.mem.indexOf(u8, theirs, "::") != null) switch (case.key) {
            .kp_0, .kp_1, .kp_2, .kp_3, .kp_4, .kp_5, .kp_6, .kp_7, .kp_8, .kp_9 => return .keypad_base_layout_key,
            .kp_decimal, .kp_divide, .kp_multiply, .kp_subtract, .kp_add, .kp_equal, .kp_separator => return .keypad_base_layout_key,
            else => {},
        };
        switch (case.key) {
            .enter, .tab, .backspace => if (case.kind == .release and !enc.kitty.report_all_keys_as_escape_codes and theirs.len == 0)
                return .release_of_modified_enter_tab_backspace
            else
                return null,
            .up, .down, .left, .right, .home, .end, .kp_up, .kp_down, .kp_left, .kp_right, .kp_home, .kp_end => {},
            .f => |n| if (n != 1 and n != 2 and n != 4) return null,
            .kp_begin => return .keypad_begin,
            .scroll_lock => return .scroll_lock,
            .menu => return .menu,
            else => return null,
        }
        if (enc.kitty.report_event_types and case.kind == .press) return .press_event_on_special_key;
        return null;
    }
    _ = ours;
    switch (case.key) {
        .backspace => if (case.mods.ctrl and case.mods.alt and case.mods.shift and !enc.modify_other_keys) return .backspace_all_three,
        .kp_equal, .kp_separator => if (theirs.len == 0) return .keypad_equal_separator,
        .char => if (case.mods.ctrl and case.mods.super) return .super_in_fixterms,
        else => {},
    }
    return null;
}

test "every key is written as the emulator's encoder writes it, or the difference is named" {
    var keys: [160]KeyCase = undefined;
    var n_keys: usize = 0;
    for ("abcmz019`-=[]\\;',./ ") |c| {
        keys[n_keys] = .{ .key = .{ .char = c }, .mods = .{}, .kind = .press };
        n_keys += 1;
    }
    // A key on another layout, and a character with no key of its own.
    keys[n_keys] = .{ .key = .{ .char = 0x441 }, .base = 'c', .mods = .{}, .kind = .press };
    n_keys += 1;
    keys[n_keys] = .{ .key = .{ .char = 0xe9 }, .mods = .{}, .kind = .press };
    n_keys += 1;
    inline for (@typeInfo(morse.Key).@"union".fields) |field| {
        if (field.type == void) {
            const k = @unionInit(morse.Key, field.name, {});
            if (ghosttyNamed(k) != null) {
                keys[n_keys] = .{ .key = k, .mods = .{}, .kind = .press };
                n_keys += 1;
            }
        }
    }
    var f: u8 = 1;
    while (f <= 25) : (f += 1) {
        keys[n_keys] = .{ .key = .{ .f = f }, .mods = .{}, .kind = .press };
        n_keys += 1;
    }

    var counts = std.EnumArray(Difference, usize).initFill(0);
    var same: usize = 0;
    var unexplained: usize = 0;
    var seen: [1024]bool = @splat(false);
    for (keys[0..n_keys]) |base_case| {
        var mods_bits: u8 = 0;
        while (mods_bits < 64) : (mods_bits += 1) {
            // Shift, alt, control and super in every combination, then
            // with each lock.
            var mods: morse.Modifiers = .fromBits(mods_bits & 0b1111);
            mods.caps_lock = mods_bits & 0b010000 != 0;
            mods.num_lock = mods_bits & 0b100000 != 0;
            for ([_]morse.Kind{ .press, .repeat, .release }) |kind| {
                var case = base_case;
                case.mods = mods;
                case.kind = kind;
                // macOS ghostty types nothing for command and a key in the
                // legacy encoding, which is a platform's choice, not the
                // protocol's.
                const mac_command = @import("builtin").os.tag == .macos and mods.super and case.key == .char;

                var pair: KeyPair = .{ .ours = undefined, .theirs = undefined };
                keyPair(case, &pair);

                var state: u8 = 0;
                while (state < 32) : (state += 1) {
                    var enc: morse.KeyEncoding = .{};
                    var opts: vt.input.KeyEncodeOptions = .{ .alt_esc_prefix = true, .macos_option_as_alt = .true };
                    if (state < 16) {
                        if (mac_command) continue;
                        enc.modify_other_keys = state & 1 != 0;
                        enc.cursor_keys_application = state & 2 != 0;
                        enc.keypad_application = state & 4 != 0;
                        enc.backarrow_sends_bs = state & 8 != 0;
                        opts.modify_other_keys_state_2 = enc.modify_other_keys;
                        opts.cursor_key_application = enc.cursor_keys_application;
                        opts.keypad_key_application = enc.keypad_application;
                        opts.backarrow_key_mode = enc.backarrow_sends_bs;
                    } else {
                        const bits: u5 = @intCast(((state - 16) << 1) | 1);
                        enc.kitty = .fromBits(bits);
                        opts.kitty_flags = @bitCast(bits);
                    }

                    var ours_buffer: [128]u8 = undefined;
                    var ours: std.Io.Writer = .fixed(&ours_buffer);
                    try morse.encodeKey(&ours, pair.ours, enc);
                    var theirs_buffer: [128]u8 = undefined;
                    var theirs: std.Io.Writer = .fixed(&theirs_buffer);
                    try vt.input.encodeKey(&theirs, pair.theirs, opts);

                    if (std.mem.eql(u8, ours.buffered(), theirs.buffered())) {
                        same += 1;
                        continue;
                    }
                    const why = difference(case, enc, ours.buffered(), theirs.buffered()) orelse {
                        unexplained += 1;
                        const sig = @as(usize, @intFromEnum(std.meta.activeTag(case.key))) * 8 + @as(usize, @intFromEnum(case.kind)) * 2 + @intFromBool(state >= 16);
                        if (!seen[sig % seen.len]) {
                            seen[sig % seen.len] = true;
                            std.log.info("{s} {any} {any} mods={x} kitty={b} state={d}\n  morse   {any}\n  ghostty {any}\n", .{ @tagName(case.key), case.key, case.kind, case.mods.bits(), enc.kitty.bits(), state, ours.buffered(), theirs.buffered() });
                        }
                        continue;
                    };
                    counts.getPtr(why).* += 1;
                }
            }
        }
    }
    try checkEqual(@as(usize, 0), unexplained);
    // Every named difference still happens.
    var it = counts.iterator();
    while (it.next()) |entry| {
        // Command and a key is not compared on macOS, see above.
        const exempt = entry.key == .super_in_fixterms and @import("builtin").os.tag == .macos;
        if (entry.value.* == 0 and !exempt) std.log.info("difference {s} no longer occurs\n", .{@tagName(entry.key)});
        try check(entry.value.* != 0 or exempt);
    }
    std.log.info("keys: {d} encodings agree with the emulator's", .{same});
    it = counts.iterator();
    while (it.next()) |entry| std.log.info(", {d} {s}", .{ entry.value.*, @tagName(entry.key) });
    std.log.info("\n", .{});
}

//=========================================================================
// Stripping, against the emulator's parser.
//
// What `strip` leaves of a terminal's output is the text the emulator
// prints and the C0 controls it executes, for output a program writes:
// morse's own writers between runs of text, and sequences the emulator
// reads and morse does not write.
//=========================================================================

const StreamAction = vt.StreamAction;

/// The text the emulator prints, and the four C0 controls it executes that
/// a program writes into text, collected as bytes.
const Printed = struct {
    out: [8192]u8 = undefined,
    len: usize = 0,

    fn put(p: *Printed, cp: u21) void {
        std.debug.assert(p.len + 4 <= p.out.len);
        p.len += std.unicode.utf8Encode(cp, p.out[p.len..]) catch unreachable; // unreachable: the emulator emits Unicode scalar values
    }

    pub fn vt(p: *Printed, comptime action: StreamAction.Tag, value: StreamAction.Value(action)) void {
        switch (action) {
            .print => p.put(value.cp),
            .print_slice => for (value.cps) |cp| p.put(@intCast(cp)),
            .linefeed => p.put('\n'),
            .carriage_return => p.put('\r'),
            .horizontal_tab => p.put('\t'),
            .bell => p.put(0x07),
            else => {},
        }
    }
};

test "strip leaves what the emulator prints" {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;

    // morse's writers, between runs of text.
    try w.writeAll("plain ");
    try morse.setStyle(w, .{ .bold = true, .fg = .rgb(255, 128, 0), .underline = .curly, .underline_color = .ansi(.red) });
    try w.writeAll("styled\u{e9}\u{4e2d}");
    try morse.diffStyle(w, .{ .bold = true }, .{ .italic = true });
    try morse.cursorTo(w, 3, 7);
    try w.writeAll("\u{1f642}\r\n\t");
    try morse.title(w, "a title");
    try morse.hyperlink(w, "link text", "https://ziglang.org");
    try morse.textSize(w, .{ .scale = 2 }, "big");
    try morse.clipboardWrite(w, .clipboard, "copied");
    try morse.syncOutput.set(w, true);
    try morse.mouse(w, .{ .motion = .any });
    try morse.kittyKeyboardPush(w, .{ .disambiguate_escape_codes = true });
    try morse.transmitImage(w, .{ .image = .{ .id = 1 }, .format = .rgb, .width = 1, .height = 1 }, "\x00\x00\x00");
    try morse.cursorShape(w, .bar);
    try morse.queryCapability(w, "TN");
    try morse.repeatChar(w, 3);
    try morse.notify(w, "t", "b");
    try morse.promptStart(w);
    try w.writeAll("$ ");
    try morse.promptEnd(w);
    // Sequences morse does not write: charsets, DECSC and DECRC, keypad
    // modes, a reset, an SOS and a PM, and a C1 control spelled as UTF-8,
    // which the emulator ignores as xterm does.
    try w.writeAll("\x1b(0q\x1b(B\x1b7x\x1b8\x1b=\x1b>\x1bXsos\x1b\\\x1b^pm\x1b\\a\u{9b}31mb\x07end");

    var parsed: vt.Stream(*Printed) = .init(.{ .handler = undefined });
    var printed: Printed = .{};
    parsed.handler = &printed;
    parsed.nextSlice(out.written());

    var buffer: [8192]u8 = undefined;
    const stripped = try morse.strip(&buffer, out.written());
    try checkString(printed.out[0..printed.len], stripped);
}

//=========================================================================
// The count.
//=========================================================================

test "how many claims this file made" {
    try std.testing.expectEqual(@as(usize, 3841), checks);
    std.log.info("conformance: {d} assertions against the emulator\n", .{checks});
}
