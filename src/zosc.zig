//! Terminal control sequences as typed writers and parsers.
//!
//! Every writer takes a `*std.Io.Writer`, writes one sequence, and returns
//! without flushing: batching is the caller's, because a repaint is many
//! sequences and one write. No writer allocates, and none keeps state, so a
//! program's terminal state stays where the program can see it.
//!
//! Every parser takes a whole sequence as `[]const u8` and returns null for
//! anything it does not recognise — never an error. A terminal's input is
//! untrusted and often truncated, and there is nothing a caller can do with a
//! taxonomy of malformed. What a parser returns borrows from the bytes it was
//! given, and is valid for exactly as long as they are.
//!
//! `zosc` does not read the terminal, does not size the screen, does not
//! manage the termios state, and does not decide when a sequence has ended.
//! It turns intent into bytes and bytes back into intent.

const clipboard = @import("clipboard.zig");
const cursor = @import("cursor.zig");
const mode = @import("mode.zig");
const mouse_events = @import("mouse.zig");
const notifications = @import("notify.zig");
const osc = @import("osc.zig");
const query = @import("query.zig");

//=========================================================================
// Titles and hyperlinks.
//=========================================================================

/// Sets the window title: `OSC 2 ; text BEL`.
pub const title = osc.title;
/// Opens an OSC 8 hyperlink, optionally with a `key=value` parameter list.
pub const hyperlinkStart = osc.hyperlinkStart;
/// Closes the hyperlink opened by `hyperlinkStart`.
pub const hyperlinkEnd = osc.hyperlinkEnd;
/// Writes one piece of text as a hyperlink.
pub const hyperlink = osc.hyperlink;

//=========================================================================
// Clipboard, OSC 52.
//=========================================================================

/// The selection an OSC 52 sequence addresses.
pub const Clipboard = clipboard.Clipboard;
/// Puts bytes on a selection, base64 encoded as it is written.
pub const clipboardWrite = clipboard.clipboardWrite;
/// Asks the terminal for the contents of a selection.
pub const clipboardRequest = clipboard.clipboardRequest;
/// A terminal's answer to `clipboardRequest`, still in base64.
pub const ClipboardReply = clipboard.ClipboardReply;
/// Reads a reply to `clipboardRequest`, or null.
pub const parseClipboardReply = clipboard.parseClipboardReply;
/// Decodes a reply's payload into a caller-owned buffer.
pub const decodeClipboard = clipboard.decodeClipboard;

//=========================================================================
// Notifications.
//=========================================================================

/// Posts a desktop notification with a title and a body (OSC 777).
pub const notify = notifications.notify;
/// Posts a desktop notification with only a body (OSC 9).
pub const notify9 = notifications.notify9;

//=========================================================================
// Modes.
//=========================================================================

/// Turns any DEC private mode on or off, named here or not.
pub const setMode = mode.setMode;
/// The alternate screen buffer (mode 1049).
pub const altScreen = mode.altScreen;
/// Bracketed paste (mode 2004).
pub const bracketedPaste = mode.bracketedPaste;
/// Synchronised output (mode 2026).
pub const syncOutput = mode.syncOutput;
/// Focus in and out reporting (mode 1004).
pub const focusEvents = mode.focusEvents;
/// Cursor visibility, DECTCEM (mode 25).
pub const cursorVisible = mode.cursorVisible;
/// Which mouse reports a program wants.
pub const Mouse = mode.Mouse;
/// Sets every mouse mode at once, each flag its own `h` or `l`.
pub const mouse = mode.mouse;
/// Turns off every mouse mode `mouse` can turn on.
pub const mouseOff = mode.mouseOff;

//=========================================================================
// Keyboard and cursor.
//=========================================================================

/// The five flags of the kitty keyboard protocol.
pub const KittyFlags = mode.KittyFlags;
/// Pushes keyboard flags onto the terminal's mode stack.
pub const kittyKeyboardPush = mode.kittyKeyboardPush;
/// Pops one entry off the terminal's keyboard mode stack.
pub const kittyKeyboardPop = mode.kittyKeyboardPop;
/// Asks which keyboard flags are in effect.
pub const kittyKeyboardQuery = mode.kittyKeyboardQuery;
/// A cursor shape, in the numbering DECSCUSR uses.
pub const CursorShape = mode.CursorShape;
/// Sets the cursor shape, DECSCUSR.
pub const cursorShape = mode.cursorShape;

//=========================================================================
// Queries and replies.
//=========================================================================

/// Asks whether a DEC private mode is set, DECRQM.
pub const queryMode = query.queryMode;
/// Asks where the cursor is, CPR.
pub const requestCursorPosition = query.requestCursorPosition;
/// What a terminal says about a mode it was asked about.
pub const ModeState = query.ModeState;
/// A terminal's answer to `queryMode`.
pub const ModeReport = query.ModeReport;
/// Reads a DECRPM reply, or null.
pub const parseModeReply = query.parseModeReply;
/// A cursor position in cells, counting from one.
pub const CursorPosition = query.CursorPosition;
/// Reads a cursor position report, or null.
pub const parseCursorPosition = query.parseCursorPosition;

//=========================================================================
// Mouse reports.
//=========================================================================

/// A mouse button, numbered as the SGR protocol numbers it.
pub const Button = mouse_events.Button;
/// One mouse report.
pub const MouseEvent = mouse_events.MouseEvent;
/// Writes a mouse report in SGR form.
pub const encodeMouse = mouse_events.encodeMouse;
/// Reads an SGR mouse report, or null.
pub const parseMouse = mouse_events.parseMouse;
/// Converts a pixel report into cells.
pub const toCells = mouse_events.toCells;

//=========================================================================
// Cursor and screen.
//=========================================================================

/// Moves the cursor to a row and a column, counting from one.
pub const cursorTo = cursor.cursorTo;
/// Moves the cursor up, stopping at the top of the screen or the region.
pub const cursorUp = cursor.cursorUp;
/// Moves the cursor down, stopping at the bottom; it does not scroll.
pub const cursorDown = cursor.cursorDown;
/// Moves the cursor right, stopping at the last column.
pub const cursorRight = cursor.cursorRight;
/// Moves the cursor left, stopping at column one.
pub const cursorLeft = cursor.cursorLeft;
/// Moves the cursor down and to column one.
pub const cursorNextLine = cursor.cursorNextLine;
/// Moves the cursor up and to column one.
pub const cursorPrevLine = cursor.cursorPrevLine;
/// Moves the cursor to a column in the row it is on.
pub const cursorColumn = cursor.cursorColumn;
/// Saves the cursor's position and attributes, DECSC.
pub const cursorSave = cursor.cursorSave;
/// Restores what `cursorSave` saved, DECRC.
pub const cursorRestore = cursor.cursorRestore;
/// How much of the cursor's row `clearLine` erases.
pub const ClearLine = cursor.ClearLine;
/// Erases part or all of the cursor's row.
pub const clearLine = cursor.clearLine;
/// How much of the screen `clearScreen` erases.
pub const ClearScreen = cursor.ClearScreen;
/// Erases part or all of the screen, or the scrollback.
pub const clearScreen = cursor.clearScreen;
/// Sets the rows scrolling is confined to, DECSTBM.
pub const scrollRegion = cursor.scrollRegion;
/// Puts the whole screen back as the scroll region.
pub const scrollRegionReset = cursor.scrollRegionReset;
/// Scrolls the region up, bringing blank rows in at the bottom.
pub const scrollUp = cursor.scrollUp;
/// Scrolls the region down, bringing blank rows in at the top.
pub const scrollDown = cursor.scrollDown;
/// Opens blank rows at the cursor, pushing the rest of the region down.
pub const insertLines = cursor.insertLines;
/// Removes rows at the cursor, pulling the rest of the region up.
pub const deleteLines = cursor.deleteLines;

test {
    _ = @import("clipboard.zig");
    _ = @import("cursor.zig");
    _ = @import("mode.zig");
    _ = @import("mouse.zig");
    _ = @import("notify.zig");
    _ = @import("osc.zig");
    _ = @import("query.zig");
    _ = @import("seq.zig");
}

test "the root module re-exports what the README promises" {
    const std = @import("std");

    // A name dropped from a module but left in the root is a compile error
    // here rather than a broken import in a consumer.
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const w = &out.writer;

    try title(w, "t");
    try hyperlinkStart(w, "u", "id=a");
    try hyperlinkEnd(w);
    try hyperlink(w, "t", "u");
    try clipboardWrite(w, .clipboard, "x");
    try clipboardRequest(w, .primary);
    try notify(w, "t", "b");
    try notify9(w, "b");
    try setMode(w, 1, true);
    try altScreen.set(w, true);
    try bracketedPaste.set(w, true);
    try syncOutput.set(w, true);
    try focusEvents.set(w, true);
    try cursorVisible.set(w, false);
    try mouse(w, .{ .press = true });
    try mouseOff(w);
    try kittyKeyboardPush(w, .{ .disambiguate_escape_codes = true });
    try kittyKeyboardPop(w);
    try kittyKeyboardQuery(w);
    try cursorShape(w, .bar);
    try queryMode(w, 2026);
    try requestCursorPosition(w);
    try encodeMouse(w, .{ .button = .left, .x = 1, .y = 1, .press = true });

    try cursorTo(w, 1, 1);
    try cursorUp(w, 1);
    try cursorDown(w, 1);
    try cursorRight(w, 1);
    try cursorLeft(w, 1);
    try cursorNextLine(w, 1);
    try cursorPrevLine(w, 1);
    try cursorColumn(w, 1);
    try cursorSave(w);
    try cursorRestore(w);
    try clearLine(w, .all);
    try clearScreen(w, .all);
    try scrollRegion(w, 1, 2);
    try scrollRegionReset(w);
    try scrollUp(w, 1);
    try scrollDown(w, 1);
    try insertLines(w, 1);
    try deleteLines(w, 1);

    try std.testing.expectEqual(Clipboard.clipboard, parseClipboardReply("\x1b]52;c;aGk=\x1b\\").?.target);
    try std.testing.expectEqual(ModeState.set, parseModeReply("\x1b[?2026;1$y").?.state);
    try std.testing.expectEqual(@as(u32, 12), parseCursorPosition("\x1b[12;40R").?.row);
    try std.testing.expectEqual(Button.left, parseMouse("\x1b[<0;1;1M").?.button);
    try std.testing.expectEqual(@as(u32, 1), toCells(.{
        .button = .left,
        .x = 4,
        .y = 4,
        .press = true,
        .pixels = true,
    }, 8, 16).x);

    var buffer: [8]u8 = undefined;
    const reply: ClipboardReply = parseClipboardReply("\x1b]52;c;aGk=\x1b\\").?;
    try std.testing.expectEqualStrings("hi", try decodeClipboard(reply, &buffer));

    const erase: ClearLine = .all;
    const wipe: ClearScreen = .scrollback;
    try std.testing.expect(erase == .all and wipe == .scrollback);

    const shape: CursorShape = .block;
    const flags: KittyFlags = .{};
    const modes: Mouse = .{};
    const report: ModeReport = .{ .mode = 1, .state = .set };
    const position: CursorPosition = .{ .row = 1, .col = 1 };
    const ev: MouseEvent = .{ .button = .left, .x = 1, .y = 1, .press = true };
    try std.testing.expect(shape == .block and flags.bits() == 0 and !modes.press);
    try std.testing.expect(report.mode == 1 and position.row == 1 and ev.x == 1);
}
