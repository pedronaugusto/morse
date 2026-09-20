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
//! The one exception to both rules is `KeyParser`, which has to remember
//! half a sequence between reads and does it in a buffer the caller owns and
//! can see. It is also the only thing here that decides where a sequence ends
//! — which is what makes it the layer everything else on the input side hangs
//! off, since a reply and a keypress arrive down the same pipe.
//!
//! `morse` does not read the terminal, does not size the screen, does not
//! manage the termios state, and holds no capability database. It turns
//! intent into bytes and bytes back into intent.

const clipboard = @import("clipboard.zig");
const cursor = @import("cursor.zig");
const device = @import("device.zig");
const graphics = @import("graphics.zig");
const key = @import("key.zig");
const mode = @import("mode.zig");
const mouse_events = @import("mouse.zig");
const multicursor = @import("multicursor.zig");
const notifications = @import("notify.zig");
const osc = @import("osc.zig");
const probing = @import("probe.zig");
const query = @import("query.zig");
const status = @import("status.zig");
const style = @import("style.zig");
const tcap = @import("tcap.zig");
const win32 = @import("win32.zig");

//=========================================================================
// Titles and hyperlinks.
//=========================================================================

/// Sets the window title: `OSC 2 ; text BEL`.
pub const title = osc.title;
/// Sets the icon name, the short label shown where a title will not fit.
pub const iconName = osc.iconName;
/// Pushes the window title onto the terminal's title stack.
pub const titlePush = osc.titlePush;
/// Pops the window title off the terminal's title stack.
pub const titlePop = osc.titlePop;
/// Tells the terminal which directory is current (OSC 7).
pub const workingDirectory = osc.workingDirectory;
/// Opens an OSC 8 hyperlink, optionally with a `key=value` parameter list.
pub const hyperlinkStart = osc.hyperlinkStart;
/// Closes the hyperlink opened by `hyperlinkStart`.
pub const hyperlinkEnd = osc.hyperlinkEnd;
/// Writes one piece of text as a hyperlink.
pub const hyperlink = osc.hyperlink;

//=========================================================================
// Text sizing, OSC 66.
//=========================================================================

/// Where fractionally scaled text sits in its block, vertically.
pub const VerticalAlign = osc.VerticalAlign;
/// The same horizontally.
pub const HorizontalAlign = osc.HorizontalAlign;
/// How big a piece of text is drawn, and in how many cells.
pub const TextSize = osc.TextSize;
/// Draws text at a size, and says how many cells it takes (OSC 66).
pub const textSize = osc.textSize;
/// The most text one OSC 66 sequence may carry.
pub const text_size_max = osc.text_size_max;

//=========================================================================
// Semantic prompt marks, OSC 133.
//=========================================================================

/// Marks the start of a prompt.
pub const promptStart = status.promptStart;
/// Marks the end of the prompt and the start of what the user typed.
pub const promptEnd = status.promptEnd;
/// Marks the start of a command's output.
pub const commandStart = status.commandStart;
/// Marks the end of a command's output, with the status it exited on.
pub const commandEnd = status.commandEnd;

//=========================================================================
// Progress, OSC 9 ; 4.
//=========================================================================

/// What a program is telling the terminal about how far along it is.
pub const Progress = status.Progress;
/// Tells the terminal how far along the program is.
pub const progress = status.progress;

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
/// Measuring text by grapheme cluster rather than codepoint (mode 2027).
pub const unicodeCore = mode.unicodeCore;
/// Resize reports on the input stream rather than by signal (mode 2048).
pub const inBandResize = mode.inBandResize;
/// Windows console keys as sequences rather than as bytes (mode 9001).
pub const win32Input = mode.win32Input;
/// Auto-wrap at the last column, DECAWM (mode 7).
pub const autoWrap = mode.autoWrap;
/// Unasked reports when the terminal's palette turns light or dark
/// (mode 2031).
pub const colorScheme = mode.colorScheme;
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
/// What `kittyKeyboardSet` does with the flags it is given.
pub const KittyFlagChange = mode.KittyFlagChange;
/// Changes the keyboard flags without touching the terminal's stack.
pub const kittyKeyboardSet = mode.kittyKeyboardSet;
/// One of the resources that decide whether a modified key is spelled as a
/// sequence, XTMODKEYS.
pub const ModifyKeys = mode.ModifyKeys;
/// Sets one of those resources, or puts it back as the terminal had it.
pub const modifyKeys = mode.modifyKeys;
/// Puts every one of those resources back as the terminal had it.
pub const modifyKeysReset = mode.modifyKeysReset;
/// Asks what one of those resources is set to.
pub const queryModifyKeys = mode.queryModifyKeys;
/// What a terminal says about one of those resources.
pub const ModifyKeysReport = device.ModifyKeysReport;
/// Reads a reply to `queryModifyKeys`, or null.
pub const parseModifyKeysReply = device.parseModifyKeysReply;
/// A cursor shape, in the numbering DECSCUSR uses.
pub const CursorShape = mode.CursorShape;
/// Sets the cursor shape, DECSCUSR.
pub const cursorShape = mode.cursorShape;
/// The shape the mouse pointer takes, named as CSS names it.
pub const PointerShape = mode.PointerShape;
/// Sets the pointer's shape (OSC 22).
pub const pointerShape = mode.pointerShape;
/// Puts the pointer back to the terminal's default shape.
pub const pointerShapeReset = mode.pointerShapeReset;

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
/// Asks where the cursor is and which page it is on, DECXCPR.
pub const requestExtendedCursorPosition = query.requestExtendedCursorPosition;
/// A cursor position with the page it is on, counting from one.
pub const ExtendedCursorPosition = query.ExtendedCursorPosition;
/// Reads a DEC extended cursor position report, or null.
pub const parseExtendedCursorPosition = query.parseExtendedCursorPosition;
/// Which way round the terminal's palette is.
pub const ColorScheme = query.ColorScheme;
/// Asks which way round the terminal's palette is (`CSI ? 996 n`).
pub const queryColorScheme = query.queryColorScheme;
/// Reads a colour scheme report, or null.
pub const parseColorSchemeReply = query.parseColorSchemeReply;

//=========================================================================
// The startup probe.
//=========================================================================

/// The questions a program asks a terminal on startup, written in one call
/// with slow forwarded queries first and DA1 last.
pub const Probe = probing.Probe;
/// Whether a reply answers a particular question.
pub const probeMatches = probing.matches;

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
/// Reads the original X10 mouse report, or null.
pub const parseMouseX10 = mouse_events.parseMouseX10;
/// Reads the rxvt mouse report (mode 1015), or null.
pub const parseMouseRxvt = mouse_events.parseMouseRxvt;
/// The largest coordinate an X10 mouse report can carry.
pub const mouse_x10_max = mouse_events.x10_max;
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
/// Moves the cursor to a row in the column it is on.
pub const cursorRow = cursor.cursorRow;
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
/// Opens blank cells at the cursor, pushing the rest of the row right.
pub const insertChars = cursor.insertChars;
/// Removes cells at the cursor, pulling the rest of the row left.
pub const deleteChars = cursor.deleteChars;
/// Erases cells from the cursor rightwards, without moving anything.
pub const eraseChars = cursor.eraseChars;
/// Repeats the last character written, REP.
pub const repeatChar = cursor.repeatChar;

//=========================================================================
// Styles and colour, SGR.
//=========================================================================

/// The sixteen palette entries a terminal theme defines.
pub const Ansi = style.Ansi;
/// A colour given directly, eight bits a channel.
pub const Rgb = style.Rgb;
/// A colour, in the forms SGR can spell.
pub const Color = style.Color;
/// Which underline a cell carries.
pub const Underline = style.Underline;
/// Whether a cell's glyphs are raised, lowered, or on the baseline.
pub const Script = style.Script;
/// Everything SGR can say about a cell, in one value.
pub const Style = style.Style;
/// Clears every attribute and both colours.
pub const resetStyle = style.resetStyle;
/// Writes a style, from a terminal at its default.
pub const setStyle = style.setStyle;
/// Writes only what differs between two styles.
pub const diffStyle = style.diffStyle;

//=========================================================================
// Keyboard input.
//=========================================================================

/// A key, either the codepoint it stands for or the name it goes by.
pub const Key = key.Key;
/// Which modifiers were held.
pub const Modifiers = key.Modifiers;
/// Press, repeat or release.
pub const Kind = key.Kind;
/// One keypress, as a value that borrows nothing.
pub const KeyEvent = key.KeyEvent;
/// One thing that arrived on the terminal's input.
pub const Event = key.Event;
/// How big the terminal became, as an in-band resize report gives it.
pub const Resize = key.Resize;
/// A byte stream turned into events, over a buffer the caller owns.
pub const KeyParser = key.KeyParser;
/// The events one `KeyParser.feed` completes.
pub const Events = key.Events;

//=========================================================================
// The Windows console keyboard.
//=========================================================================

/// A `KEY_EVENT_RECORD`, declared here rather than imported.
pub const ConsoleKeyRecord = win32.ConsoleKeyRecord;
/// A `MOUSE_EVENT_RECORD`, declared here rather than imported.
pub const ConsoleMouseRecord = win32.ConsoleMouseRecord;
/// A `WINDOW_BUFFER_SIZE_RECORD`, declared here rather than imported.
pub const ConsoleSizeRecord = win32.ConsoleSizeRecord;
/// One `INPUT_RECORD`, as the union its event type selects.
pub const ConsoleRecord = win32.ConsoleRecord;
/// What a console record turned out to be.
pub const ConsoleEvent = win32.ConsoleEvent;
/// Console input records turned into keys, mouse reports and resizes.
pub const ConsoleDecoder = win32.ConsoleDecoder;
/// What a console keyboard has to remember between records.
pub const ConsoleState = win32.ConsoleState;
/// What one console key record turned out to be.
pub const ConsoleKey = win32.ConsoleKey;
/// The bits of a console `dwControlKeyState`.
pub const ControlKeyState = win32.ControlKeyState;

//=========================================================================
// Asking the terminal what it is.
//=========================================================================

/// Asks what the terminal is and what it implements, DA1.
pub const queryDeviceAttributes = device.queryDeviceAttributes;
/// A terminal's answer to `queryDeviceAttributes`.
pub const DeviceAttributes = device.DeviceAttributes;
/// Reads a DA1 reply, or null.
pub const parseDeviceAttributes = device.parseDeviceAttributes;
/// Asks for the terminal's identity and version, DA2.
pub const querySecondaryDeviceAttributes = device.querySecondaryDeviceAttributes;
/// A terminal's answer to `querySecondaryDeviceAttributes`.
pub const SecondaryDeviceAttributes = device.SecondaryDeviceAttributes;
/// Reads a DA2 reply, or null.
pub const parseSecondaryDeviceAttributes = device.parseSecondaryDeviceAttributes;
/// Asks the terminal to name itself in words, XTVERSION.
pub const queryVersion = device.queryVersion;
/// Reads an XTVERSION reply, or null.
pub const parseVersion = device.parseVersion;
/// Reads the reply to `kittyKeyboardQuery`, or null.
pub const parseKittyKeyboardReply = device.parseKittyKeyboardReply;
/// A terminal colour that is not part of the palette.
pub const ColorTarget = device.ColorTarget;
/// A colour with sixteen bits per channel, as OSC 10 and 11 carry it.
pub const Rgb16 = device.Rgb16;
/// Asks the terminal for one of its colours.
pub const queryColor = device.queryColor;
/// Sets one of the terminal's colours.
pub const setColor = device.setColor;
/// Puts one of the terminal's colours back to the user's.
pub const resetColor = device.resetColor;
/// What a terminal says about one of its colours.
pub const ColorReport = device.ColorReport;
/// Reads a reply to `queryColor`, or null.
pub const parseColorReply = device.parseColorReply;
/// How many entries the palette OSC 4 addresses has.
pub const palette_size = device.palette_size;
/// Asks the terminal for one palette entry (OSC 4).
pub const queryPaletteColor = device.queryPaletteColor;
/// Sets one palette entry.
pub const setPaletteColor = device.setPaletteColor;
/// Puts one palette entry back to the user's (OSC 104).
pub const resetPaletteColor = device.resetPaletteColor;
/// Puts every palette entry back to the user's.
pub const resetPalette = device.resetPalette;
/// What a terminal says about one palette entry.
pub const PaletteReport = device.PaletteReport;
/// Reads a reply to `queryPaletteColor`, or null.
pub const parsePaletteReply = device.parsePaletteReply;
/// Which size a program is asking the terminal for.
pub const SizeQuery = device.SizeQuery;
/// Asks the terminal how big something is, XTWINOPS.
pub const queryWindowSize = device.queryWindowSize;
/// Asks the terminal to resize its text area.
pub const resizeTextArea = device.resizeTextArea;
/// What a terminal says about one of its sizes.
pub const WindowSize = device.WindowSize;
/// Reads a window size report, or null.
pub const parseWindowSize = device.parseWindowSize;
/// Asks the terminal for one terminfo capability by name, XTGETTCAP.
pub const queryCapability = tcap.queryCapability;
/// Asks for several capabilities in one sequence.
pub const queryCapabilities = tcap.queryCapabilities;
/// One capability out of a reply, both halves still in hex.
pub const Capability = tcap.Capability;
/// A terminal's answer to `queryCapability`.
pub const CapabilityReply = tcap.CapabilityReply;
/// The capabilities one reply carries, one at a time.
pub const Capabilities = tcap.Capabilities;
/// Reads an XTGETTCAP reply, or null.
pub const parseCapabilityReply = tcap.parseCapabilityReply;

//=========================================================================
// The kitty graphics protocol.
//=========================================================================

/// What a terminal says about a kitty graphics command.
pub const GraphicsResponse = graphics.GraphicsResponse;
/// Reads a kitty graphics response, or null.
pub const parseGraphicsResponse = graphics.parseGraphicsResponse;
/// The shape of the pixels being sent: RGB, RGBA or PNG.
pub const GraphicsFormat = graphics.GraphicsFormat;
/// Where the terminal reads the pixels from: the escape code, a file, a
/// temporary file, or a shared memory object.
pub const GraphicsMedium = graphics.GraphicsMedium;
/// How much the terminal may say back about a graphics command.
pub const GraphicsQuiet = graphics.GraphicsQuiet;
/// Which image a graphics command is about: an id, a number, or neither.
pub const GraphicsImage = graphics.GraphicsImage;
/// A rectangle of a source image, in pixels.
pub const GraphicsRect = graphics.GraphicsRect;
/// What a transmit does with the image once it has it.
pub const GraphicsAction = graphics.GraphicsAction;
/// Where a placement goes and how much of the image it shows.
pub const Placement = graphics.Placement;
/// One image on its way to the terminal.
pub const Transmit = graphics.Transmit;
/// A command that shows an image already sent.
pub const Place = graphics.Place;
/// What a delete command names.
pub const DeleteTarget = graphics.DeleteTarget;
/// A command that takes images or placements off the screen.
pub const Delete = graphics.Delete;
/// Sends an image, chunked by the protocol's rule.
pub const transmitImage = graphics.transmitImage;
/// Shows an image the terminal already has.
pub const placeImage = graphics.placeImage;
/// Takes images or placements off the screen.
pub const deleteImage = graphics.deleteImage;
/// Asks whether the terminal implements the graphics protocol at all.
pub const queryGraphics = graphics.queryGraphics;
/// How arriving pixels land on the pixels already there.
pub const GraphicsCompose = graphics.GraphicsCompose;
/// A colour with an alpha channel, as a frame's background key spells it.
pub const GraphicsColor = graphics.GraphicsColor;
/// Whether the terminal is playing an animation.
pub const AnimationState = graphics.AnimationState;
/// One animation frame on its way to the terminal.
pub const Frame = graphics.Frame;
/// A command that plays, stops or steps an image's animation.
pub const Animate = graphics.Animate;
/// A command that copies a rectangle from one frame of an image onto
/// another.
pub const Compose = graphics.Compose;
/// Sends one animation frame, chunked by the protocol's rule.
pub const transmitFrame = graphics.transmitFrame;
/// Plays, stops or steps an image's animation.
pub const animateImage = graphics.animateImage;
/// Copies a rectangle from one frame of an image onto another.
pub const composeFrames = graphics.composeFrames;
/// The image bytes one transmit sequence carries.
pub const graphics_chunk_bytes = graphics.chunk_bytes;
/// The most base64 one transmit sequence may carry.
pub const graphics_chunk_base64_max = graphics.chunk_base64_max;
/// One row of a Unicode placeholder grid.
pub const Placeholder = graphics.Placeholder;
/// Writes one row of a Unicode placeholder, colours included.
pub const placeholderRow = graphics.placeholderRow;
/// Writes one placeholder cell and its diacritics.
pub const placeholderCell = graphics.placeholderCell;
/// The character that stands in for an image cell, U+10EEEE.
pub const graphics_placeholder = graphics.placeholder;
/// How many rows or columns a placeholder grid can address.
pub const graphics_placeholder_max = graphics.placeholder_max;

//=========================================================================
// The multiple cursors protocol.
//=========================================================================

/// The shape an extra cursor takes.
pub const ExtraCursorShape = multicursor.ExtraCursorShape;
/// A cell an extra cursor sits on, counting from one.
pub const CursorCell = multicursor.CursorCell;
/// A rectangle of cells, both corners included.
pub const CursorRect = multicursor.CursorRect;
/// Where a shape is being set: the main cursor, cells, or rectangles.
pub const CursorSpan = multicursor.CursorSpan;
/// Which half of the extra cursors' colour pair is being set.
pub const CursorColorTarget = multicursor.CursorColorTarget;
/// A colour for the extra cursors.
pub const CursorColor = multicursor.CursorColor;
/// Sets a shape on every cell the spans name.
pub const extraCursors = multicursor.extraCursors;
/// Takes every extra cursor off the screen.
pub const extraCursorsClear = multicursor.extraCursorsClear;
/// Sets one half of the extra cursors' colour pair.
pub const extraCursorColor = multicursor.extraCursorColor;
/// Asks whether the terminal implements the protocol at all.
pub const queryExtraCursorSupport = multicursor.queryExtraCursorSupport;
/// Asks what extra cursors are set now.
pub const queryExtraCursors = multicursor.queryExtraCursors;
/// Asks what colour pair the extra cursors are drawn in.
pub const queryExtraCursorColors = multicursor.queryExtraCursorColors;
/// What a terminal says it can do with extra cursors.
pub const ExtraCursorSupport = multicursor.ExtraCursorSupport;
/// Reads a support reply, or null.
pub const parseExtraCursorSupport = multicursor.parseExtraCursorSupport;
/// One extra cursor the terminal says is set.
pub const ExtraCursorAt = multicursor.ExtraCursorAt;
/// A terminal's answer to `queryExtraCursors`.
pub const ExtraCursorReport = multicursor.ExtraCursorReport;
/// The cursors one reply names, one at a time.
pub const ExtraCursors = multicursor.ExtraCursors;
/// Reads a set-cursors reply, or null.
pub const parseExtraCursors = multicursor.parseExtraCursors;
/// The colour pair a terminal says the extra cursors are drawn in.
pub const ExtraCursorColors = multicursor.ExtraCursorColors;
/// Reads a cursor colour reply, or null.
pub const parseExtraCursorColors = multicursor.parseExtraCursorColors;

test {
    _ = @import("base64.zig");
    _ = @import("bench.zig");
    _ = @import("clipboard.zig");
    _ = @import("cursor.zig");
    _ = @import("device.zig");
    _ = @import("graphics.zig");
    _ = @import("key.zig");
    _ = @import("mode.zig");
    _ = @import("mouse.zig");
    _ = @import("multicursor.zig");
    _ = @import("notify.zig");
    _ = @import("osc.zig");
    _ = @import("probe.zig");
    _ = @import("query.zig");
    _ = @import("seq.zig");
    _ = @import("status.zig");
    _ = @import("style.zig");
    _ = @import("tcap.zig");
    _ = @import("win32.zig");
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
    try promptStart(w);
    try promptEnd(w);
    try commandStart(w);
    try commandEnd(w, 0);
    try commandEnd(w, null);
    try progress(w, .{ .percent = 40 });
    try progress(w, .{ .failed = 40 });
    try progress(w, .indeterminate);
    try progress(w, .{ .warning = 40 });
    try progress(w, .none);
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
    try kittyKeyboardSet(w, .{ .report_all_keys_as_escape_codes = true }, .add);
    try modifyKeys(w, .other_keys, 2);
    try modifyKeys(w, .other_keys, null);
    try modifyKeysReset(w);
    try queryModifyKeys(w, .other_keys);
    try cursorShape(w, .bar);
    try pointerShape(w, .pointer);
    try pointerShapeReset(w);
    try unicodeCore.set(w, true);
    try queryMode(w, 2026);
    try requestCursorPosition(w);
    try requestExtendedCursorPosition(w);
    try encodeMouse(w, .{ .button = .left, .x = 1, .y = 1, .press = true });

    try titlePush(w);
    try titlePop(w);
    try workingDirectory(w, "file://host/tmp");
    try inBandResize.set(w, true);
    try win32Input.set(w, true);
    try autoWrap.set(w, false);
    try queryWindowSize(w, .text_area_cells);
    try resizeTextArea(w, 24, 80);

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
    try cursorRow(w, 1);
    try insertChars(w, 1);
    try deleteChars(w, 1);
    try eraseChars(w, 1);

    try resetStyle(w);
    try setStyle(w, .{ .bold = true, .fg = .ansi(.red) });
    try diffStyle(w, .{ .bold = true }, .{ .italic = true });

    try queryDeviceAttributes(w);
    try querySecondaryDeviceAttributes(w);
    try queryVersion(w);
    try queryColor(w, .background);
    try setColor(w, .foreground, .{ .r = 0, .g = 0, .b = 0 });
    try resetColor(w, .cursor);
    try queryPaletteColor(w, 1);
    try setPaletteColor(w, 1, .{ .r = 0, .g = 0, .b = 0 });
    try resetPaletteColor(w, 1);
    try resetPalette(w);
    try queryCapability(w, "Co");
    try queryCapabilities(w, &.{ "Co", "TN" });

    try iconName(w, "morse");
    try textSize(w, .{ .scale = 2 }, "big");
    try repeatChar(w, 3);
    try colorScheme.set(w, true);
    try queryColorScheme(w);

    try (Probe{}).write(w);
    try std.testing.expect(probeMatches("\x1b[?62;52;c", .device_attributes));
    try std.testing.expect(!probeMatches("\x1b[?62;52;c", .cursor_position));
    try std.testing.expect(Probe.Question.device_attributes == .device_attributes);

    try transmitImage(w, .{ .image = .{ .id = 1 }, .width = 1, .height = 1 }, "abc");
    try placeImage(w, .{ .image = .{ .id = 1 }, .placement = .{ .z = -1 } });
    try deleteImage(w, .{ .target = .{ .image = .{ .id = 1 } }, .free = true });
    try queryGraphics(w, 31);
    try transmitFrame(w, .{ .image = .{ .id = 1 }, .width = 1, .height = 1 }, "abc");
    try animateImage(w, .{ .image = .{ .id = 1 }, .state = .running });
    try composeFrames(w, .{ .image = .{ .id = 1 }, .source = 1, .destination = 2 });
    try placeholderRow(w, .{ .id = 1, .row = 0, .columns = 1 });
    try placeholderCell(w, 0, 0, 0);

    try extraCursors(w, .main, &.{.{ .cells = &.{.{ .row = 1, .col = 1 }} }});
    try extraCursorsClear(w);
    try extraCursorColor(w, .cursor, .indexed(4));
    try queryExtraCursorSupport(w);
    try queryExtraCursors(w);
    try queryExtraCursorColors(w);

    try std.testing.expectEqual(Clipboard.clipboard, parseClipboardReply("\x1b]52;c;aGk=\x1b\\").?.target);
    try std.testing.expectEqual(ModeState.set, parseModeReply("\x1b[?2026;1$y").?.state);
    try std.testing.expectEqual(@as(u32, 12), parseCursorPosition("\x1b[12;40R").?.row);
    try std.testing.expectEqual(
        @as(u32, 1),
        parseExtendedCursorPosition("\x1b[?12;40;1R").?.page,
    );
    try std.testing.expectEqual(Button.left, parseMouse("\x1b[<0;1;1M").?.button);
    try std.testing.expectEqual(Button.left, parseMouseX10("\x1b[M\x20\x21\x21").?.button);
    try std.testing.expectEqual(Button.left, parseMouseRxvt("\x1b[32;33;33M").?.button);
    try std.testing.expectEqual(@as(u32, 223), @as(u32, mouse_x10_max));
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

    try std.testing.expectEqual(@as(u16, 62), parseDeviceAttributes("\x1b[?62;22c").?.class);
    try std.testing.expectEqual(
        @as(u32, 4000),
        parseSecondaryDeviceAttributes("\x1b[>1;4000;29c").?.version,
    );
    try std.testing.expectEqualStrings("xterm(390)", parseVersion("\x1bP>|xterm(390)\x1b\\").?);
    try std.testing.expect(parseKittyKeyboardReply("\x1b[?1u").?.disambiguate_escape_codes);
    const modifiers_report: ModifyKeysReport = parseModifyKeysReply("\x1b[>4;2m").?;
    try std.testing.expectEqual(ModifyKeys.other_keys, modifiers_report.resource);
    try std.testing.expectEqual(@as(u8, 2), modifiers_report.value);
    try std.testing.expectEqual(KittyFlagChange.add, KittyFlagChange.add);
    try std.testing.expectEqual(ColorTarget.background, parseColorReply(
        "\x1b]11;rgb:0000/0000/0000\x1b\\",
    ).?.target);
    try std.testing.expect(parseGraphicsResponse("\x1b_Gi=31;OK\x1b\\").?.ok());
    const entry: PaletteReport = parsePaletteReply("\x1b]4;9;rgb:ffff/0000/0000\x1b\\").?;
    try std.testing.expectEqual(@as(u8, 9), entry.index);
    try std.testing.expectEqual(@as(u16, 0xffff), entry.color.r);
    try std.testing.expectEqual(@as(u16, 256), palette_size);
    try std.testing.expectEqual(
        WindowSize.What.text_area_cells,
        parseWindowSize("\x1b[8;24;80t").?.what,
    );
    try std.testing.expectEqual(SizeQuery.cell_pixels, SizeQuery.cell_pixels);

    const caps: CapabilityReply = parseCapabilityReply("\x1bP1+r436f=323536\x1b\\").?;
    var entries: Capabilities = caps.iterator();
    const cap: Capability = entries.next().?;
    var cap_text: [8]u8 = undefined;
    try std.testing.expect(caps.known);
    try std.testing.expectEqualStrings("Co", try cap.decodeName(&cap_text));
    try std.testing.expectEqualStrings("256", try cap.decodeValue(&cap_text));
    try std.testing.expectEqual(@as(usize, 2), cap.nameLen());
    try std.testing.expectEqual(@as(usize, 3), cap.valueLen());

    try std.testing.expectEqual(ColorScheme.dark, parseColorSchemeReply("\x1b[?997;1n").?);
    try std.testing.expect(parseExtraCursorSupport("\x1b[>1;29 q").?.block);
    const set_cursors: ExtraCursorReport = parseExtraCursors("\x1b[>100;1:2:7:1 q").?;
    var cursor_list: ExtraCursors = set_cursors.iterator();
    const at: ExtraCursorAt = cursor_list.next().?;
    try std.testing.expectEqual(ExtraCursorShape.block, at.shape);
    try std.testing.expectEqual(CursorCell{ .row = 7, .col = 1 }, at.where.cell);
    const pair: ExtraCursorColors = parseExtraCursorColors("\x1b[>101;30:0;40:1 q").?;
    try std.testing.expectEqual(CursorColor.unset, pair.text);
    try std.testing.expectEqual(CursorColor.Space.special, pair.cursor.space);

    const span: CursorSpan = .main_cursor;
    const box: CursorRect = .{ .top = 1, .left = 1, .bottom = 2, .right = 2 };
    const which: CursorColorTarget = .text;
    try std.testing.expect(span == .main_cursor and box.top == 1 and which == .text);

    const image: GraphicsImage = .{ .id = 1 };
    const area: GraphicsRect = .{ .width = 4, .height = 4 };
    const how: GraphicsAction = .store;
    const shown: Placement = .{ .z = -1 };
    const sending: Transmit = .{ .format = .png, .medium = .file, .quiet = .silent };
    const showing: Place = .{ .image = image, .placement = shown };
    const removing: Delete = .{ .target = .all };
    const gone: DeleteTarget = .at_cursor;
    const grid: Placeholder = .{ .id = 1, .row = 0, .columns = 1 };
    try std.testing.expect(image == .id and area.width == 4 and how == .store);
    try std.testing.expect(sending.format == .png and showing.placement.z == -1);
    try std.testing.expect(removing.target == .all and gone == .at_cursor);
    try std.testing.expect(grid.columns == 1 and graphics_placeholder == 0x10EEEE);
    try std.testing.expectEqual(@as(usize, 4096), graphics_chunk_base64_max);
    try std.testing.expectEqual(@as(usize, 3072), graphics_chunk_bytes);
    try std.testing.expectEqual(@as(u16, 297), graphics_placeholder_max);
    try std.testing.expectEqual(GraphicsFormat.rgba, GraphicsFormat.rgba);
    try std.testing.expectEqual(GraphicsMedium.direct, GraphicsMedium.direct);
    try std.testing.expectEqual(GraphicsQuiet.answers, GraphicsQuiet.answers);

    const frame: Frame = .{ .image = image, .edit = 2, .gap = 40 };
    const playing: Animate = .{ .image = image, .state = .running, .loops = 1 };
    const copying: Compose = .{ .image = image, .source = 1, .destination = 2 };
    const canvas: GraphicsColor = .{ .r = 0xff, .a = 0xff };
    try std.testing.expect(frame.edit == 2 and frame.gap == 40);
    try std.testing.expect(playing.state == AnimationState.running and playing.loops == 1);
    try std.testing.expect(copying.compose == GraphicsCompose.blend);
    try std.testing.expectEqual(@as(u32, 4278190335), canvas.rgba());

    const scaled: TextSize = .{ .scale = 2, .vertical = .center, .horizontal = .right };
    try std.testing.expect(scaled.vertical == VerticalAlign.center);
    try std.testing.expect(scaled.horizontal == HorizontalAlign.right);
    try std.testing.expectEqual(@as(usize, 4096), text_size_max);

    const raised: Script = .superscript;
    try std.testing.expect(raised == .superscript);

    const grew: Resize = .{ .rows = 24, .cols = 80 };
    try std.testing.expect(grew.rows == 24 and grew.xpixels == 0);

    var keys: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&keys);
    parser.report_key_up = false;
    var events: Events = parser.feed("\x1b[97;5u");
    const event: Event = events.next().?;
    try std.testing.expectEqual(Key{ .char = 'a' }, event.key.key);
    try std.testing.expectEqual(Kind.press, event.key.kind);
    try std.testing.expect(event.key.mods.ctrl);
    try std.testing.expectEqual(@as(usize, 0), parser.pending().len);

    const record: ConsoleRecord = .{ .key = .{
        .key_down = true,
        .virtual_key_code = 0x25,
        .control_key_state = ControlKeyState.shift,
    } };
    var records: ConsoleDecoder = .{};
    const console: ConsoleEvent = records.next(record).?;
    try std.testing.expectEqual(Key.left, console.key.key);
    try std.testing.expect(console.key.mods.shift);

    const moved: ConsoleMouseRecord = .{ .x = 3, .y = 4, .button_state = 1 };
    const sized: ConsoleSizeRecord = .{ .cols = 80, .rows = 24 };
    const wheel: ConsoleEvent = records.next(.{ .mouse = moved }).?;
    const grown: ConsoleEvent = records.next(.{ .window_buffer_size = sized }).?;
    try std.testing.expectEqual(@as(u32, 4), wheel.mouse.x);
    try std.testing.expectEqual(@as(u32, 24), grown.resize.rows);
    try std.testing.expectEqual(@as(?ConsoleEvent, null), records.next(.other));
    records.reset();

    var console_state: ConsoleState = .{};
    const half: ConsoleKey = console_state.decode(0, 0xd83d, 0, true);
    try std.testing.expect(half == .held);
    try std.testing.expectEqual(
        Key{ .char = 0x1f642 },
        console_state.decode(0, 0xde42, 0, true).key.key,
    );

    const erase: ClearLine = .all;
    const wipe: ClearScreen = .scrollback;
    try std.testing.expect(erase == .all and wipe == .scrollback);

    const colour: Color = .rgb(1, 2, 3);
    const named: Color = .ansi(.bright_blue);
    const cube: Color = .palette(196);
    const solid: Rgb = .{ .r = 255, .g = 0, .b = 0 };
    const line: Underline = .curly;
    const shade: Ansi = .bright_blue;
    const attrs: Style = .{ .overline = true };
    try std.testing.expect(colour.kind == .rgb and line == .curly and shade == .bright_blue);
    try std.testing.expectEqual(Rgb{ .r = 1, .g = 2, .b = 3 }, colour.toRgb());
    try std.testing.expectEqual(Ansi.bright_blue, named.toAnsi());
    try std.testing.expectEqual(@as(u8, 196), cube.index());
    try std.testing.expect(Color.default.kind == .default);
    try std.testing.expect(!attrs.bold and attrs.overline and solid.r == 255);

    const wide: Rgb16 = .{ .r = 0xffff, .g = 0, .b = 0 };
    const da: DeviceAttributes = .{ .class = 1 };
    const da2: SecondaryDeviceAttributes = .{ .terminal_type = 0, .version = 0 };
    const colours: ColorReport = .{ .target = .cursor, .color = wide };
    const acknowledged: GraphicsResponse = .{ .message = "OK" };
    try std.testing.expectEqual(@as(u8, 255), wide.to8().r);
    try std.testing.expect(da.class == 1 and da2.version == 0);
    try std.testing.expect(colours.target == .cursor and acknowledged.ok());

    const done: Progress = .{ .percent = 100 };
    try std.testing.expect(done == .percent and done.percent == 100);

    const pressed: KeyEvent = .{ .key = .escape };
    const mods: Modifiers = .{};
    try std.testing.expect(pressed.key == .escape and !mods.any());

    const shape: CursorShape = .block;
    const hand: PointerShape = .not_allowed;
    const flags: KittyFlags = .{};
    const modes: Mouse = .{};
    const report: ModeReport = .{ .mode = 1, .state = .set };
    const position: CursorPosition = .{ .row = 1, .col = 1 };
    const paged: ExtendedCursorPosition = .{ .row = 1, .col = 1, .page = 1 };
    const ev: MouseEvent = .{ .button = .left, .x = 1, .y = 1, .press = true };
    try std.testing.expect(shape == .block and flags.bits() == 0 and !modes.press);
    try std.testing.expectEqualStrings("not-allowed", hand.name());
    try std.testing.expect(report.mode == 1 and position.row == 1 and ev.x == 1);
    try std.testing.expect(paged.page == 1);
}
