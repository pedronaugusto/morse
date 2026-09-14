# morse

[![CI](https://github.com/pedronaugusto/morse/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/morse/actions/workflows/ci.yml)

Terminal control sequences as typed writers and parsers, in pure Zig. No
dependencies, no C, no allocations.

Writers turn intent into bytes: the flags are `packed struct`s, the styles are
written as a diff, and the numbers are arguments rather than digits in a
string literal. Parsers turn the terminal's bytes back into values, and return
`null` instead of garbage. Keys, mouse reports and replies to queries all
arrive on the same file descriptor, so one parser frames that stream and hands
each piece to whichever reader wants it. This is the layer below a TUI
framework: bytes in and bytes out, and nothing above them.

## Usage

The block below is a region of [`examples/usage.zig`](examples/usage.zig),
which `zig build examples` builds and runs. `ci/readme_usage.sh` extracts it
and CI compares the two, so the snippet cannot drift from code that executes.

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

## The API

**Keyboard input.** `KeyParser`, `Events`, `Event`, `KeyEvent`, `Key`,
`Modifiers`, `Kind`, `Resize`.

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

**Notifications and progress.** `notify` (OSC 777), `notify9` (OSC 9),
`Progress` / `progress` (OSC 9;4).

**Semantic prompt marks (OSC 133).** `promptStart`, `promptEnd`,
`commandStart`, `commandEnd`.

**Modes.** `altScreen`, `bracketedPaste`, `syncOutput`, `focusEvents`,
`cursorVisible`, `unicodeCore`, `inBandResize`, `autoWrap` — each a type with
`set(w, on)` and a `number` — plus `setMode` for any mode morse does not name,
and `Mouse` / `mouse` / `mouseOff`.

**Keyboard protocol and cursor shape.** `KittyFlags`, `kittyKeyboardPush`,
`kittyKeyboardPop`, `kittyKeyboardQuery`, `parseKittyKeyboardReply`,
`CursorShape`, `cursorShape`.

**Asking the terminal what it is.** `queryMode` / `ModeState` / `ModeReport` /
`parseModeReply`, `requestCursorPosition` / `CursorPosition` /
`parseCursorPosition`, `queryDeviceAttributes` / `DeviceAttributes` /
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

**Writers take a `*std.Io.Writer` and write one sequence.** They do not flush
and they do not allocate: a repaint is many sequences and one write, so
batching is yours. OSC 52's base64 is encoded three input bytes at a time
straight into the writer, which is why copying a megabyte to the clipboard
needs no buffer sized to it.

**Parsers take `[]const u8` and return `?T`, never an error.** A terminal's
input is untrusted and often truncated, and there is nothing a caller can do
with a taxonomy of malformed. Truncated, mistyped and arithmetically
impossible inputs all return null, and no number in a reply can overflow the
field it is parsed into. What a parser returns borrows from the bytes it was
given and is valid for exactly as long as they are.

**One parser frames the input, and holds the only state here.** `KeyParser`
decides where each sequence ends, decodes the keys, and hands everything else
back whole as `Event.unhandled` for `parseMouse`, `parseColorReply`,
`parseCapabilityReply` or whichever parser reads it. Knowing where a sequence
ends is a much smaller job than knowing what every sequence means, and keeping
the two apart is what stops an unrecognised reply resynchronising the stream a
byte at a time. It has to remember half a sequence between reads, and does it
in a buffer you hand to `KeyParser.init` and can read back with `pending()`.
`min_buffer` is enough for keys alone; a program that asks for the clipboard
wants kilobytes, because an OSC 52 reply is as long as whatever was copied.
Nothing else in the package keeps anything between calls.

**No terminfo.** morse carries no capability database and has no compile-time
knowledge of terminal names; it writes the sequences directly. Every terminal
in use today implements the same ANSI and DEC sequences for everything in this
package, so what varies is not which bytes clear the screen but whether a
feature exists at all — and I ask the terminal that question rather than a
file about the terminal. `queryMode` (DECRQM) asks whether a mode is really
implemented; `queryDeviceAttributes`, `queryVersion`, `queryColor`,
`queryPaletteColor` and `queryCapability` (XTGETTCAP, a named terminfo
capability over the wire) ask the rest. A terminal that does not implement a
query answers nothing at all, which is itself an answer if you pair it with
one that is always answered — `queryDeviceAttributes` is the usual companion.
What a program does with silence is policy, and policy is yours: morse does
not decide a timeout, does not cache, and does not fall back. So there is
nothing to link against, no build step parsing a compiled terminfo entry,
nothing to install on the target machine, and the same behaviour
cross-compiled to a machine whose terminfo database the build host has never
seen.

**Styles are written as a diff.** SGR is the one place a sequence's effect
depends on what came before, and there is no sequence meaning "this style and
nothing else" short of resetting first. `diffStyle(w, from, to)` writes the
shortest `CSI ... m` that gets from one to the other, and nothing at all when
they are equal, which is the common case. Off codes go first, then on codes,
then colours: SGR 22 turns off bold and dim together, so turning bold off
while dim stays on has to write `22;2`, and writing the `2` first would lose
it. `from` is yours to remember, and getting it wrong shows on screen.

**A lone `ESC` is yours to resolve.** `0x1b` is both the Escape key and the
first byte of every sequence here, and nothing in the byte stream
distinguishes them. `KeyParser` will not guess: a trailing `ESC` is held,
`pending()` shows it, and `flush()` is what you call when your own timeout has
expired — returning the Escape key, or alt with `[` or `O` for the two other
byte strings that are simultaneously a key and the start of a sequence. How
long that timeout should be is a judgement about the user's link, not about
the protocol, which is why it is not mine to make. Better still, remove the
ambiguity: a terminal asked for `KittyFlags.disambiguate_escape_codes` spells
Escape as `CSI 27 u`, and `flush` is then only for the terminals that say no.

**The mouse modes are one call.** Mouse reporting is six independent DEC
private modes, and a program that turns on what it wants without turning off
what it does not gets a report per cell the pointer crosses, because something
earlier set mode 1003. `mouse` takes the whole set and writes an `h` or an `l`
for each flag in ascending mode number, so `mouse(w, .{ .press = true, .sgr =
true })` is press and wheel reports in SGR coordinates and nothing else,
whatever was on before; `mouseOff` is `mouse(w, .{})`. The cost of that reach
is that `Mouse.focus` is mode 1004, the same mode as `focusEvents`: a `mouse`
call leaving it false turns focus reporting off, so a program wanting both
says so in one call.

**Pixels are your claim, not a wire fact.** Mode 1006 (cells) and mode 1016
(pixels) produce byte-identical reports, and only the program that asked knows
which it is getting. `parseMouse` always reports cells and leaves
`MouseEvent.pixels` false; a program using mode 1016 sets that field on what
it parsed and calls `toCells` with its cell size. Both coordinate systems
count from 1, so the first `cell_w` pixels are column 1 and pixel `cell_w + 1`
opens column 2.

**A parsed reply borrows, and its decoder takes a buffer.**
`parseClipboardReply` returns the base64 payload as a sub-slice of the bytes
it was given, and `decodeClipboard` writes into a buffer you size from
`reply.decodedLen()` — exact rather than an upper bound, because the parser
has already established the payload is well-formed base64, padding bits
included. XTGETTCAP works the same way, with `Capability.decodeName` and
`decodeValue` sized from `nameLen` and `valueLen`. Content cannot fail to
decode; the only error is `error.NoSpaceLeft`.

## Limits

These are the things morse does not do.

- **No I/O.** morse never touches a file descriptor, never reads a reply, and
  never puts a terminal into raw mode. `termios` and `SetConsoleMode` are
  yours, and so is every timeout.
- **No screen model.** No cells, no damage tracking, no layout, no diffing of
  a frame, no width tables, no grapheme segmentation. `diffStyle` diffs two
  styles; nothing here diffs two screens.
- **No widgets and no event loop.** No windows, no focus stack, no redraw
  scheduling. A framework built on this package is a different package.
- **No terminal capability database.** See the design note above.
- **No graphics protocol.** `parseGraphicsResponse` reads the terminal's
  answer to a kitty graphics command, because that answer arrives on the input
  stream and has to be told apart from a keypress. Writing the command is not
  here: transmitting an image has its own chunking, formats, compression and
  placement rules.
- **Only SGR is asked for.** It is the mouse encoding without a 223-column cap
  and the only one that says which button came up. The X10 report (mode 1000)
  and the rxvt report (mode 1015) are read anyway, by `parseMouseX10` and
  `parseMouseRxvt`, and framed by `KeyParser`, because a terminal left in one
  of those modes still sends them. The UTF-8 encoding (mode 1005) is not read:
  its length depends on a mode the input stream does not carry, so it cannot
  even be framed.
- **No 8-bit C1 controls.** `0x9b` is not read as `CSI`, nor `0x9d` as `OSC`.
  On input those bytes are UTF-8 continuation bytes far more often than
  controls, and no terminal sends 8-bit C1 on input unless asked with `S8C1T`.
  A terminal emulator reading a program's output needs them; this package
  reads the other direction.
- **No Windows console input.** Console input records from `ReadConsoleInputW`
  and the win32-input-mode key encoding (mode 9001) are both keyboard input in
  a form morse does not decode yet. Pending.
- **No guessing at text a terminal did not report.** `KeyEvent.text` is what
  the terminal said the key produced: the bytes themselves for plain input,
  and the protocol's associated-text field when you asked for it. A terminal
  reporting `CSI 97 u` has not said what `a` produced on that layout with
  those modifiers, and inventing an answer would be wrong exactly where it
  matters — dead keys, input methods, and shifted keys whose shifted form is
  not the uppercase of the unshifted one.
- **No escaping of your strings.** A title, a URI or a notification body
  containing `ESC`, `BEL` or `;` is written through as given. Which edit would
  be right depends on what the text is, so morse makes none.

## Platforms

morse calls no operating system API and has no platform-specific code, so the
same source builds everywhere Zig does. The suite is what differs by host.

| Platform | What morse uses | Tested |
| --- | --- | --- |
| Linux | nothing platform-specific | `ubuntu-latest` in CI, four optimize modes; also in Docker with [`ci/linux.sh`](ci/linux.sh) |
| macOS | nothing platform-specific | `macos-latest` in CI, four optimize modes |
| Windows | nothing platform-specific | `windows-latest` in CI, four optimize modes |

Cross-compilation is checked by building the module for `x86_64-linux-gnu`,
`x86_64-windows-gnu` and `aarch64-windows-gnu`.

## Testing

`zig build test` runs the suite and the examples, under
`std.testing.allocator`, so a leak or an invalid free fails the test rather
than the process. Every writer is pinned to its exact bytes rather than to a
shape, and the exhaustive cases are there too: base64 at every tail length, a
clipboard round trip at every length from 0 to 193, every mouse event this
package can represent encoded and parsed back, and every key sequence in every
spelling a terminal uses for it, including one delivered a byte per read.

Every parser has a table of malformed inputs — truncated, wrong terminator,
wrong introducer, trailing rubbish, a field too many, numbers too large for
the field — and a `std.testing.fuzz` test asserting it never panics, never
overflows, and that whatever it accepts survives a round trip back through the
writer. `KeyParser` is fuzzed fed in two pieces, so the split lands anywhere a
real read could have landed, against the properties a stream parser needs:
text is valid UTF-8, every `unhandled` slice lies inside the caller's buffer,
the parser always makes progress, and `flush` always empties it. `zig build
test --fuzz` turns those properties into a search, and
[`ci/linux.sh`](ci/linux.sh) runs the Linux half in Docker from a machine that
is not Linux.

## Requirements

Zig 0.16.0. No other dependencies.

## Licence

MIT. See [LICENSE](LICENSE).