# morse

[![CI](https://github.com/pedronaugusto/morse/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/morse/actions/workflows/ci.yml)

morse writes terminal control sequences and parses the bytes a terminal sends
back: keys, mouse reports, and the replies to questions a program asks. It is
what a full-screen program sits on, under anything that draws widgets.

## Usage

The block below is a region of [`examples/usage.zig`](examples/usage.zig),
which `zig build examples` builds and runs. CI compares the two.

<!-- BEGIN GENERATED ci/readme_usage.sh -->
```zig
const std = @import("std");
const morse = @import("morse");

// Any `*std.Io.Writer` will do -- a buffered writer over stdout is the
// real one. Nothing below allocates or flushes: batching is yours.
var buffer: [2048]u8 = undefined;
var out: std.Io.Writer = .fixed(&buffer);
const w = &out;

// Take the screen: alternate buffer, no cursor. Synchronised output is
// not here -- it is a bracket around each frame, further down.
try morse.altScreen.set(w, true);
try morse.cursorVisible.set(w, false);

// Ask for mouse press and wheel reports in SGR form -- and, by saying so
// in one call, for no report per cell the pointer crosses.
try morse.mouse(w, .{ .press = true, .sgr = true });

// Keys in the kitty protocol, pushed so exiting restores what was there,
// and pasted text bracketed so it can be told from typing.
try morse.kittyKeyboardPush(w, .{
    .disambiguate_escape_codes = true,
    .report_event_types = true,
    .report_associated_text = true,
});
try morse.bracketedPaste.set(w, true);
try morse.inBandResize.set(w, true);

// And ask to be told when the user's theme turns light or dark, so a
// program that chose its colours on startup hears that they no longer
// suit the background.
try morse.colorScheme.set(w, true);

// On Windows, keys as sequences rather than as bytes: mode 9001 says
// which physical key it was and whether it went down or came up, and
// `KeyParser` reads it into the same `Key` as everything else.
try morse.win32Input.set(w, true);

// A frame, bracketed by mode 2026 so the terminal shows all of it or
// none of it. The bracket is per frame, it does not nest, and each half
// is its own sequence -- never batched with another mode.
try morse.syncOutput.set(w, true);

// Clear, go to the top-left, write a heading in a style. The second style
// call writes only what changed -- four bytes rather than a reset and a
// repaint of attributes that were already right.
const heading: morse.Style = .{ .bold = true, .fg = .ansi(.cyan) };
const body: morse.Style = .{ .fg = .ansi(.cyan) };
try morse.clearScreen(w, .all);
try morse.cursorTo(w, 1, 1);
try morse.setStyle(w, heading);
try w.writeAll("morse");
try morse.diffStyle(w, heading, body);
try w.writeAll(" -- terminal control sequences");
try morse.resetStyle(w);

// A rule under it, written as one glyph and a repeat count rather than
// as thirty glyphs.
try morse.cursorTo(w, 2, 1);
try w.writeAll("\u{2500}");
try morse.repeatChar(w, 29);

// A heading drawn two cells tall, and a footnote marker drawn half size
// at the top of its cell. Terminals without the protocol draw both at
// the usual size, which still reads correctly.
try morse.cursorTo(w, 4, 1);
try morse.textSize(w, .{ .scale = 2 }, "morse");
try morse.textSize(w, .{ .numerator = 1, .denominator = 2 }, "1");

// An image, under the text. Send the pixels, then place them: the two are
// separate so the picture can be moved, replaced or taken away without
// sending it again. `q=2` because nothing here reads the reply.
const pixels = [_]u8{ 0xff, 0x00, 0x00, 0xff }; // one red pixel, RGBA
try morse.transmitImage(w, .{
    .image = .{ .id = 7 },
    .width = 1,
    .height = 1,
    .quiet = .silent,
}, &pixels);
try morse.cursorTo(w, 6, 1);
try morse.placeImage(w, .{
    .image = .{ .id = 7 },
    .placement = .{ .id = 1, .columns = 20, .rows = 6, .z = -1, .keep_cursor = true },
    .quiet = .silent,
});

// Cursors the terminal draws, at the three places an edit is happening.
try morse.extraCursors(w, .main, &.{.{ .cells = &.{
    .{ .row = 8, .col = 4 },
    .{ .row = 9, .col = 4 },
    .{ .row = 10, .col = 4 },
} }});

// The frame ends here.
try morse.syncOutput.set(w, false);

// A title, a clickable link, and a desktop notification.
try morse.title(w, "morse");
try morse.hyperlink(w, "ziglang.org", "https://ziglang.org");
try morse.notify(w, "Build finished", "0 errors");

// Put text on the clipboard of whichever machine the terminal runs on,
// base64 encoded on the fly -- no allocation, no buffer sized to the text.
try morse.clipboardWrite(w, .clipboard, "copied by morse");

// Ask the terminal what it is. None of these is guaranteed an answer, so
// none of them may be waited on without a timeout of your own.
try morse.queryMode(w, morse.syncOutput.number);
try morse.queryDeviceAttributes(w);
try morse.queryColor(w, .background);
try morse.queryCapability(w, "Co");
try morse.queryColorScheme(w);
try morse.queryGraphics(w, 31);

// Input is one byte stream carrying keys, mouse reports and replies all
// at once, so one parser frames it. The buffer is yours, nothing here
// allocates, and a sequence split across two reads is held until the rest
// of it arrives.
var input: [1024]u8 = undefined;
var keys: morse.KeyParser = .init(&input);

// Control and a in the kitty protocol, then an SGR mouse click.
var events = keys.feed("\x1b[97;5u\x1b[<0;40;12M\x1b[48;24;80;384;640t\x1b[?997;1n");
while (events.next()) |event| switch (event) {
    // A key, and whatever text the terminal said it produced.
    .key => |key| std.debug.print("key:        {s}{t} {s}\n", .{
        if (key.mods.ctrl) "ctrl+" else "",
        key.key,
        key.text(),
    }),
    // A run of printable text -- pasted, or typed faster than a read.
    // One event and a borrowed slice, not one `KeyEvent` per character.
    .text => |text| std.debug.print("text:       {s}\n", .{text}),
    // Anything framed but not a key: a mouse report, a reply, an OSC.
    .unhandled => |bytes| if (morse.parseMouse(bytes)) |click| std.debug.print(
        "click:      {s} at {d},{d}\n",
        .{ @tagName(click.button), click.x, click.y },
    ),
    // A terminal asked for in-band resize says so here rather than
    // through a signal.
    .resize => |size| std.debug.print("resize:     {d}x{d}\n", .{ size.cols, size.rows }),
    // A terminal in mode 2031 says so when the user's theme flips.
    .color_scheme => |scheme| std.debug.print("scheme:     {t}\n", .{scheme}),
    // A reply longer than the buffer: said, never turned into the keys
    // its bytes look like. Size the buffer for the answers you ask for.
    .overflow => |bytes| std.debug.print("dropped:    {d} bytes\n", .{bytes}),
    .paste_start, .paste_end, .focus_in, .focus_out => {},
};

// A lone ESC is both the Escape key and the first byte of every sequence.
// This parser never guesses: it holds the byte, and `flush` is what a
// caller whose own timeout has expired calls to settle it.
var held = keys.feed("\x1b");
std.debug.assert(held.next() == null);
std.debug.assert(keys.pending().len == 1);
const escape = keys.flush().?;

// A reply parses on its own too, for a program that framed it some other
// way. Every parser takes a whole sequence and returns null for anything
// it does not recognise.
const mode = morse.parseModeReply("\x1b[?2026;1$y").?;
const position = morse.parseCursorPosition("\x1b[12;40R").?;
const background = morse.parseColorReply("\x1b]11;rgb:1c1c/1c1c/1c1c\x1b\\").?;

// A capability the terminal answered for. Names and values travel as
// hex, because a value is often itself an escape sequence, and they are
// decoded into a buffer you size from the reply.
const caps = morse.parseCapabilityReply("\x1bP1+r436f=323536\x1b\\").?;
var entries = caps.iterator();
const colors = entries.next().?;
var capability: [8]u8 = undefined;
const color_count = try colors.decodeValue(&capability);

// A pixel report (mode 1016) is byte-identical to a cell report, so the
// program that asked for pixels is the one that says so.
var pixel = morse.parseMouse("\x1b[<0;321;97M").?;
pixel.pixels = true;
const cell = morse.toCells(pixel, 8, 16);

// On the way out, in reverse. The image and the extra cursors are taken
// away explicitly: they outlive the program that drew them.
try morse.extraCursorsClear(w);
try morse.deleteImage(w, .{
    .target = .{ .image = .{ .id = 7 } },
    .free = true,
    .quiet = .silent,
});
try morse.colorScheme.set(w, false);
try morse.win32Input.set(w, false);
try morse.inBandResize.set(w, false);
try morse.bracketedPaste.set(w, false);
try morse.kittyKeyboardPop(w);
try morse.mouseOff(w);
try morse.cursorVisible.set(w, true);
try morse.altScreen.set(w, false);
```
<!-- END GENERATED -->

## Install

```sh
zig fetch --save git+https://github.com/pedronaugusto/morse
```

```zig
const morse_dep = b.dependency("morse", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("morse", morse_dep.module("morse"));
```

No dependencies: nothing to link, and no C toolchain involved.

## The API

**Keyboard input.** `KeyParser`, `Events`, `Event`, `KeyEvent`, `Key`,
`Modifiers`, `Kind`, `Resize`.

**The Windows console.** `ConsoleRecord`, `ConsoleKeyRecord`,
`ConsoleMouseRecord`, `ConsoleSizeRecord`, `ConsoleEvent`, `ControlKeyState`,
`fromInputRecord`.

**Styles and colour.** `Style`, `Color` (with `Color.Kind`, `Color.default`,
`Color.ansi`, `Color.palette`, `Color.rgb`, `Color.fromRgb`, `index`,
`toAnsi`, `toRgb`, `eql`), `Ansi`, `Rgb`, `Underline`, `Script`, `setStyle`,
`diffStyle`, `resetStyle`.

**Cursor and screen.** `cursorTo`, `cursorUp`, `cursorDown`, `cursorRight`,
`cursorLeft`, `cursorNextLine`, `cursorPrevLine`, `cursorColumn`, `cursorRow`,
`cursorSave`, `cursorRestore`, `ClearLine` / `clearLine`, `ClearScreen` /
`clearScreen`, `scrollRegion`, `scrollRegionReset`, `scrollUp`, `scrollDown`,
`insertLines`, `deleteLines`, `insertChars`, `deleteChars`, `eraseChars`,
`repeatChar` (REP).

**Titles and links.** `title`, `iconName` (OSC 1), `titlePush`, `titlePop`,
`workingDirectory` (OSC 7), `hyperlinkStart`, `hyperlinkEnd`, `hyperlink`.

**Text sizing (OSC 66).** `TextSize`, `textSize`, `VerticalAlign`,
`HorizontalAlign`, `text_size_max`.

**Clipboard (OSC 52).** `Clipboard`, `clipboardWrite`, `clipboardRequest`,
`ClipboardReply`, `parseClipboardReply`, `decodeClipboard`.

**Notifications, progress and prompt marks.** `notify` (OSC 777), `notify9`
(OSC 9), `Progress` / `progress` (OSC 9;4), `promptStart`, `promptEnd`,
`commandStart`, `commandEnd` (OSC 133).

**Modes.** `altScreen`, `bracketedPaste`, `syncOutput`, `focusEvents`,
`cursorVisible`, `unicodeCore`, `inBandResize`, `autoWrap`, `win32Input`,
`colorScheme` — each a type with
`set(w, on)` and a `number` — plus `setMode` for any mode morse does not name,
and `Mouse` / `mouse` / `mouseOff`.

**Keyboard protocol, cursor and pointer.** `KittyFlags`, `kittyKeyboardPush`,
`kittyKeyboardPop`, `kittyKeyboardSet` / `KittyFlagChange`,
`kittyKeyboardQuery`, `parseKittyKeyboardReply`, `ModifyKeys` / `modifyKeys`
/ `modifyKeysReset` / `queryModifyKeys` / `ModifyKeysReport` /
`parseModifyKeysReply` (XTMODKEYS), `CursorShape`, `cursorShape`,
`PointerShape` / `pointerShape` / `pointerShapeReset` (OSC 22).

**Asking the terminal what it is.** `queryMode` / `ModeState` / `ModeReport` /
`parseModeReply`, `requestCursorPosition` / `CursorPosition` /
`parseCursorPosition`, `requestExtendedCursorPosition` /
`ExtendedCursorPosition` / `parseExtendedCursorPosition` (DECXCPR),
`queryDeviceAttributes` / `DeviceAttributes` /
`parseDeviceAttributes`, `querySecondaryDeviceAttributes` /
`SecondaryDeviceAttributes` / `parseSecondaryDeviceAttributes`,
`queryVersion` / `parseVersion`, `queryColor` / `setColor` / `resetColor` /
`ColorTarget` / `Rgb16` / `ColorReport` / `parseColorReply`,
`queryPaletteColor` / `setPaletteColor` / `resetPaletteColor` /
`resetPalette` / `PaletteReport` / `parsePaletteReply` / `palette_size`
(OSC 4 and 104), `queryCapability` / `queryCapabilities` / `CapabilityReply` /
`Capabilities` / `Capability` / `parseCapabilityReply` (XTGETTCAP),
`GraphicsResponse` / `parseGraphicsResponse`, `SizeQuery` /
`queryWindowSize` / `resizeTextArea` / `WindowSize` / `parseWindowSize`,
`queryColorScheme` / `ColorScheme` / `parseColorSchemeReply` (`CSI ? 996 n`
and its `CSI ? 997` answer).

**Graphics.** `transmitImage`, `placeImage`, `deleteImage`, `queryGraphics`,
with `Transmit`, `Place`, `Placement`, `Delete`, `DeleteTarget`,
`GraphicsFormat`, `GraphicsMedium`, `GraphicsQuiet`, `GraphicsImage`,
`GraphicsRect`, `GraphicsAction`, `graphics_chunk_bytes` and
`graphics_chunk_base64_max`; `placeholderRow`, `placeholderCell`,
`Placeholder`, `graphics_placeholder`, `graphics_placeholder_max` for the
Unicode placeholder path.

**Extra cursors.** `extraCursors`, `extraCursorsClear`, `extraCursorColor`,
`queryExtraCursorSupport`, `queryExtraCursors`, `queryExtraCursorColors`,
with `ExtraCursorShape`, `CursorCell`, `CursorRect`, `CursorSpan`,
`CursorColor`, `CursorColorTarget`, and the three replies —
`ExtraCursorSupport` / `parseExtraCursorSupport`, `ExtraCursorReport` /
`ExtraCursors` / `ExtraCursorAt` / `parseExtraCursors`, `ExtraCursorColors` /
`parseExtraCursorColors`.

**Mouse reports.** `Button`, `MouseEvent`, `encodeMouse`, `parseMouse`,
`parseMouseX10`, `parseMouseRxvt`, `mouse_x10_max`, `toCells`.

## Design

**Writers take a `*std.Io.Writer` and write one sequence.** Nothing in morse
allocates and no writer flushes, so you decide when to batch; OSC 52's base64 goes
into the writer three input bytes at a time, needing no buffer sized to the
payload. Titles, URIs and notification bodies go through byte for byte:
percent-encode them and strip the controls first.

**Parsers take `[]const u8` and return `?T`, never an error.** Truncated,
mistyped and arithmetically impossible inputs all return null, no number in a
reply can overflow the field it is parsed into, and what comes back borrows
from the bytes you passed in. A reply parser is liberal where the grammar is:
a parameter the terminal left out takes its default, so the trailing `;` in
`CSI ? 62 ; 52 ; c` is a third attribute of zero and not a reject. `KeyEvent.text` likewise holds only what the
terminal said the key produced, and is empty for a report like `CSI 97 u`,
which names a key without saying what it typed.

**One parser frames the input, and holds the only state here.** `KeyParser`
decides where each sequence ends, decodes the keys, and hands everything else
back whole as `Event.unhandled` for `parseMouse`, `parseColorReply` or
whichever parser reads it, so an unrecognised reply never resynchronises the
stream a byte at a time. A run of printable text — a paste, or typing faster
than a read — comes back as one `Event.text` borrowing the same buffer; a
single printable codepoint is a keypress and comes back as `Event.key`. You
own the buffer: `min_buffer` covers keys, but an
OSC 52 reply is as long as whatever was copied. A sequence longer than the
buffer is the one thing the parser cannot hand back, and it says so —
`Event.overflow` with the count of bytes it dropped, and the stream picked up
at the end of that sequence rather than in the middle of it, where a base64
payload reads as a few hundred keys nobody typed.

**The Windows console arrives in two shapes, and both come out as `Key`.** A
terminal in win32 input mode (`win32Input`, mode 9001) sends every key as
`CSI Vk ; Sc ; Uc ; Kd ; Cs ; Rc _`, which `KeyParser` decodes: the repeat
count becomes that many events, and the key coming up is dropped unless
`report_key_up` is set. Reading the console yourself instead, you copy each
record into a `ConsoleRecord` and hand it to `fromInputRecord`, which reads it
through the same virtual-key table and gives back a key, a mouse report or a
resize. Neither path calls an operating system API.

**A lone `ESC` is settled by you.** It is both the Escape key and the first
byte of every sequence, so `KeyParser` holds it, `pending()` shows it, and
`flush()` settles it once your own timeout expires.
`KittyFlags.disambiguate_escape_codes` removes the question.

**No terminfo: I ask the terminal.** `queryMode` (DECRQM) asks whether a mode
is really implemented; `queryDeviceAttributes`, `queryVersion`, `queryColor`,
`queryPaletteColor` and `queryCapability` (XTGETTCAP) ask the rest. Silence is
an answer if you pair the question with one always answered, usually
`queryDeviceAttributes`. What to do with it is yours: no timeout, no cache, no
fallback.

**`Style` is an `extern struct`, and so is every record in this package.**
A renderer keeps a style in every cell, and a cell that is `extern` is a row
that compares with `memcmp` and a screen that diffs a row at a time. That is
why `Color` is a tagged four-byte struct rather than the tagged union its
shape asks for: Zig gives an auto-layout union no guaranteed representation
and will not put one inside an `extern struct`. Write a colour with
`.default`, `.ansi(.red)`, `.palette(196)` or `.rgb(255, 128, 0)`, each of
which zeroes the channels its kind does not use, so `Color.eql` and a byte
comparison are the same comparison; read one by switching on `kind`. A `comptime` block pins `Style` at 22 bytes, aligned to
one, with no padding, so a field added in the wrong place fails the build
rather than quietly making that comparison read the holes. `MouseEvent`,
`Resize`, `CursorPosition`, `ExtendedCursorPosition`, `Rgb`, `Rgb16`,
`CursorCell`, `CursorRect`, `Placement` and `GraphicsRect` are `extern` for
the same reason.

**Styles are written as a diff.** `diffStyle(w, from, to)` writes the shortest
`CSI ... m` between two styles, and nothing when they are equal. Off codes go
first, then on codes, then colours: SGR 22 turns off bold and dim together, so
turning bold off while dim stays on has to state the dim again. There are two
ways to spell the same move and it writes the shorter — a leading `0` costs
two bytes and buys every off code at once, so coming back from an
everything-on style is `CSI 0 m` rather than thirty-eight bytes of off codes.
Both are priced with `Writer.Discarding`, which runs the code that writes the
bytes, so there is no second encoder to keep in step. You keep `from`.

**The mouse modes are one call.** `mouse` writes
an `h` or an `l` for each of the seven DEC private modes, so `mouse(w, .{ .press
= true, .sgr = true })` is press and wheel reports and nothing else, whatever
was on before. `Mouse.focus` is mode 1004, the same mode as `focusEvents`, so
a call leaving it false turns focus reporting off. `Mouse.rxvt` is mode 1015
and goes off the same way, because a terminal left in it keeps sending rxvt
reports until something says otherwise. SGR is the one to ask for;
`parseMouseX10` and `parseMouseRxvt` read what a terminal in mode 1000 or 1015
sends meanwhile. Modes 1006 and 1016 are byte-identical, so `parseMouse`
always reports cells and leaves `MouseEvent.pixels` false: set it yourself and
call `toCells` with your cell size. Both count from 1.

**An image is chunked by the protocol's rule, not by a buffer.**
`transmitImage` base64-encodes the pixels straight into the writer in the
3072-byte pieces that fill a 4096-character chunk exactly, writes `m=1` on
every sequence but the last, and writes no `m` at all when the whole payload
fitted in one. A megabyte of pixels costs 3,095 bytes of framing — 0.22% —
and no buffer of its own. Placement lifecycle, acknowledgements and z-layers
are not here: they need state between frames, and nothing in morse keeps any.

**Synchronised output is a bracket, not a setting.** Mode 2026 goes on
immediately before a frame and off immediately after it. It does not nest,
and `syncOutput.set` writes exactly eight bytes on its own, because at least
one terminal matches those eight rather than parsing the parameter list —
which is also why no writer here ever puts two modes in one sequence.

**A parsed reply borrows, and its decoder takes a buffer.** `decodeClipboard`
writes into a buffer you size from `reply.decodedLen()`, exact because the
parser has already established the payload is well-formed base64;
`Capability.decodeName` and `decodeValue` size from `nameLen` and `valueLen`.
`error.NoSpaceLeft` is the only error any of them returns.

## Scope

- **No I/O and no raw mode.** `termios`, `SetConsoleMode` and every timeout
  are the caller's.
- **No screen model.** No cells, no damage tracking, no layout, no width
  tables, no grapheme segmentation.
- **No widgets and no event loop.**
- **No placement model.** morse writes and reads every graphics command;
  which image ids are free, what is on screen, and when to swap one picture
  for another are a layer up.
- **No capability database.** morse asks the terminal instead; see Design.

## Platforms

| Platform | Tested |
| --- | --- |
| Linux | `ubuntu-latest` in CI, four optimize modes; also in Docker with [`ci/linux.sh`](ci/linux.sh) |
| macOS | `macos-latest` in CI, four optimize modes |
| Windows | `windows-latest` in CI, four optimize modes |

morse calls no operating system API, so the same source builds everywhere Zig
does; cross-compilation is checked for `x86_64-linux-gnu`,
`x86_64-windows-gnu` and `aarch64-windows-gnu`.

## Testing

`zig build test` runs the suite and the examples under `std.testing.allocator`,
so a leak or an invalid free fails the test rather than the process. Writers
are pinned to their exact bytes, and the round trips are exhaustive: every
base64 tail length, every clipboard length to 193, every mouse event this
package can represent, every key sequence in every spelling. Each parser has a
table of malformed inputs — truncated, wrong terminator, trailing rubbish, a
number too large for its field — and a `std.testing.fuzz` test asserting it
never panics, never overflows, and that whatever it accepts survives a round
trip back through the writer. Where morse writes a command nothing answers —
a graphics command, an OSC 66 — the suite carries a reader of that grammar so
the round trip is against the bytes rather than against the writer twice.
`src/bench.zig` measures what a renderer pays for a style diff, a cursor move,
a megabyte of pixels and a megabyte of input, and fails the build if any of
them grows past its budget. `KeyParser` is fuzzed fed in two pieces, so the
split lands anywhere a real read could have. `zig build test --fuzz` keeps searching;
[`ci/linux.sh`](ci/linux.sh) runs the Linux half in Docker from a machine that
is not Linux.

## Requirements

Zig 0.16.0.

## Licence

MIT. See [LICENSE](LICENSE).