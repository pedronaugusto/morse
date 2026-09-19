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

test "the mouse modes go on and off together" {
    var v: Vt = undefined;
    try v.init(80, 24);
    defer v.deinit();

    const numbers = [_]u16{ 1000, 1002, 1003, 1004, 1006, 1015, 1016 };

    try morse.mouse(v.w(), .{
        .press = true,
        .drag = true,
        .any_motion = true,
        .sgr = true,
        .sgr_pixels = true,
        .rxvt = true,
        .focus = true,
    });
    v.feed();
    for (numbers) |number| {
        try checkEqual(morse.ModeState.set, try modeState(&v, number));
    }

    // One call that names two modes leaves the other five off, which is the
    // whole reason `mouse` writes all seven.
    try morse.mouse(v.w(), .{ .press = true, .sgr = true });
    v.feed();
    for (numbers) |number| {
        const expected: morse.ModeState = if (number == 1000 or number == 1006)
            .set
        else
            .reset;
        try checkEqual(expected, try modeState(&v, number));
    }

    try morse.mouseOff(v.w());
    v.feed();
    for (numbers) |number| {
        try checkEqual(morse.ModeState.reset, try modeState(&v, number));
    }
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
        std.debug.print(
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
    const pixels = [_]u8{0xff} ** 16;
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

    const pixels = [_]u8{0xff} ** 4;
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
    const white = [_]u8{0xff} ** 16;
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
    const red = [_]u8{ 0xff, 0x00, 0x00, 0xff } ** 4;
    try morse.transmitFrame(v.w(), .{
        .image = .{ .id = 9 },
        .format = .rgba,
        .width = 2,
        .height = 2,
        .gap = 48,
        .quiet = .silent,
    }, &red);
    v.feed();

    const blue = [_]u8{ 0x00, 0x00, 0xff, 0xff } ** 4;
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

    const pixels = [_]u8{0xff} ** 16;
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
    const frame = [_]u8{0x40} ** (morse.graphics_chunk_bytes + 4);
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
    try (morse.Probe{}).write(v.w());
    v.feed();

    // The answers come back as one byte stream carrying replies of four
    // shapes, so they are framed the way a program frames them: by the
    // parser that frames its keys.
    var input: [4096]u8 = undefined;
    var keys: morse.KeyParser = .init(&input);
    var events = keys.feed(v.replies());

    var answered: std.EnumSet(morse.Probe.Question) = .initEmpty();
    while (events.next()) |event| switch (event) {
        .unhandled => |bytes| {
            // A reply answers at most one question.
            var matched: usize = 0;
            for (std.enums.values(morse.Probe.Question)) |question| {
                if (morse.probeMatches(bytes, question)) {
                    matched += 1;
                    answered.insert(question);
                }
            }
            try check(matched <= 1);
        },
        .color_scheme => answered.insert(.color_scheme),
        else => {},
    };

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
        .kitty_keyboard,
        .graphics,
        .version,
        .text_area_cells,
        .cell_pixels,
        .secondary_device_attributes,
        .device_attributes,
    }) |question| {
        checks += 1;
        if (!answered.contains(question)) {
            std.debug.print("probe: no answer for {t}\n", .{question});
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
// The count.
//=========================================================================

test "how many claims this file made" {
    std.debug.print("conformance: {d} assertions against the emulator\n", .{checks});
}
