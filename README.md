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
var buffer: [1024]u8 = undefined;
var out: std.Io.Writer = .fixed(&buffer);
const w = &out;

// Take the screen: alternate buffer, no cursor, synchronised repaints.
try morse.altScreen.set(w, true);
try morse.cursorVisible.set(w, false);
try morse.syncOutput.set(w, true);

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

// On Windows, keys as sequences rather than as bytes: mode 9001 says
// which physical key it was and whether it went down or came up, and
// `KeyParser` reads it into the same `Key` as everything else.
try morse.win32Input.set(w, true);

// A frame: clear, go to the top-left, write a heading in a style. The
// second style call writes only what changed -- four bytes rather than a
// reset and a repaint of attributes that were already right.
const heading: morse.Style = .{ .bold = true, .fg = .{ .ansi = .cyan } };
const body: morse.Style = .{ .fg = .{ .ansi = .cyan } };
try morse.clearScreen(w, .all);
try morse.cursorTo(w, 1, 1);
try morse.setStyle(w, heading);
try w.writeAll("morse");
try morse.diffStyle(w, heading, body);
try w.writeAll(" -- terminal control sequences");
try morse.resetStyle(w);

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

// Input is one byte stream carrying keys, mouse reports and replies all
// at once, so one parser frames it. The buffer is yours, nothing here
// allocates, and a sequence split across two reads is held until the rest
// of it arrives.
var input: [1024]u8 = undefined;
var keys: morse.KeyParser = .init(&input);

// Control and a in the kitty protocol, then an SGR mouse click.
var events = keys.feed("\x1b[97;5u\x1b[<0;40;12M\x1b[48;24;80;384;640t");
while (events.next()) |event| switch (event) {
    // A key, and whatever text the terminal said it produced.
    .key => |key| std.debug.print("key:        {s}{t} {s}\n", .{
        if (key.mods.ctrl) "ctrl+" else "",
        key.key,
        key.text(),
    }),
    // Anything framed but not a key: a mouse report, a reply, an OSC.
    .unhandled => |bytes| if (morse.parseMouse(bytes)) |click| std.debug.print(
        "click:      {s} at {d},{d}\n",
        .{ @tagName(click.button), click.x, click.y },
    ),
    // A terminal asked for in-band resize says so here rather than
    // through a signal.
    .resize => |size| std.debug.print("resize:     {d}x{d}\n", .{ size.cols, size.rows }),
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

// On the way out, in reverse.
try morse.win32Input.set(w, false);
try morse.inBandResize.set(w, false);
try morse.bracketedPaste.set(w, false);
try morse.kittyKeyboardPop(w);
try morse.mouseOff(w);
try morse.syncOutput.set(w, false);
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

**Styles and colour.** `Style`, `Color`, `Ansi`, `Rgb`, `Underline`,
`setStyle`, `diffStyle`, `resetStyle`.

**Cursor and screen.** `cursorTo`, `cursorUp`, `cursorDown`, `cursorRight`,
`cursorLeft`, `cursorNextLine`, `cursorPrevLine`, `cursorColumn`, `cursorRow`,
`cursorSave`, `cursorRestore`, `ClearLine` / `clearLine`, `ClearScreen` /
`clearScreen`, `scrollRegion`, `scrollRegionReset`, `scrollUp`, `scrollDown`,
`insertLines`, `deleteLines`, `insertChars`, `deleteChars`, `eraseChars`.

**Titles and links.** `title`, `titlePush`, `titlePop`, `workingDirectory`
(OSC 7), `hyperlinkStart`, `hyperlinkEnd`, `hyperlink`.

**Clipboard (OSC 52).** `Clipboard`, `clipboardWrite`, `clipboardRequest`,
`ClipboardReply`, `parseClipboardReply`, `decodeClipboard`.

**Notifications, progress and prompt marks.** `notify` (OSC 777), `notify9`
(OSC 9), `Progress` / `progress` (OSC 9;4), `promptStart`, `promptEnd`,
`commandStart`, `commandEnd` (OSC 133).

**Modes.** `altScreen`, `bracketedPaste`, `syncOutput`, `focusEvents`,
`cursorVisible`, `unicodeCore`, `inBandResize`, `autoWrap`, `win32Input` —
each a type with
`set(w, on)` and a `number` — plus `setMode` for any mode morse does not name,
and `Mouse` / `mouse` / `mouseOff`.

**Keyboard protocol and cursor shape.** `KittyFlags`, `kittyKeyboardPush`,
`kittyKeyboardPop`, `kittyKeyboardQuery`, `parseKittyKeyboardReply`,
`CursorShape`, `cursorShape`.

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
`queryWindowSize` / `resizeTextArea` / `WindowSize` / `parseWindowSize`.

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
from the bytes you passed in. `KeyEvent.text` likewise holds only what the
terminal said the key produced, and is empty for a report like `CSI 97 u`,
which names a key without saying what it typed.

**One parser frames the input, and holds the only state here.** `KeyParser`
decides where each sequence ends, decodes the keys, and hands everything else
back whole as `Event.unhandled` for `parseMouse`, `parseColorReply` or
whichever parser reads it, so an unrecognised reply never resynchronises the
stream a byte at a time. You own the buffer: `min_buffer` covers keys, but an
OSC 52 reply is as long as whatever was copied.

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

**Styles are written as a diff.** `diffStyle(w, from, to)` writes the shortest
`CSI ... m` between two styles, and nothing when they are equal. Off codes go
first, then on codes, then colours: SGR 22 turns off bold and dim together, so
turning bold off while dim stays on has to write `22;2`. You keep `from`.

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
- **No graphics protocol writing.** `parseGraphicsResponse` reads the reply,
  which arrives interleaved with keys; sending an image does not.
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
trip back through the writer. `KeyParser` is fuzzed fed in two pieces, so the
split lands anywhere a real read could have. `zig build test --fuzz` keeps searching;
[`ci/linux.sh`](ci/linux.sh) runs the Linux half in Docker from a machine that
is not Linux.

## Requirements

Zig 0.16.0.

## Licence

MIT. See [LICENSE](LICENSE).