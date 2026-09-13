# zosc

[![CI](https://github.com/pedronaugusto/zosc/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/zosc/actions/workflows/ci.yml)

Terminal control sequences as typed writers and parsers, in pure Zig. No
dependencies, no C, no allocations.

Every terminal program ends up writing the same dozen escape sequences by
hand, with the numbers spelled out in string literals, the key decoder
guessing at a lone `ESC`, and the mouse report parsed with a loop that
overflows on a long number. zosc is those sequences with names, the flags as
`packed struct`s, the styles as a diff, and everything that arrives on the
input as a parser that returns `null` instead of garbage.

It is the whole layer below a TUI framework: everything that is bytes in and
bytes out, and nothing above it.

- **Writers take a `*std.Io.Writer`** and write one sequence. They do not
  flush and they do not allocate — batching is yours, because a repaint is
  many sequences and one write. OSC 52's base64 is produced three input bytes
  at a time straight into the writer, so copying a megabyte to the clipboard
  needs no buffer and no allocator.
- **Parsers take `[]const u8` and return `?T`**, never an error. A terminal's
  input is untrusted and often truncated, and there is nothing a caller can do
  with a taxonomy of malformed. Truncated, mistyped and arithmetically
  impossible inputs all return `null`; no number in a reply can overflow the
  field it is parsed into.
- **One parser frames the input.** Keys, mouse reports and replies to queries
  all arrive down the same pipe, so `KeyParser` decides where each sequence
  ends, decodes the keys, and hands back everything else whole for the parser
  that reads it.
- **No state, with one exception you can see.** zosc holds nothing between
  calls except in `KeyParser`, which has to remember half a sequence between
  reads and does it in a buffer you hand it and can inspect.
- **No terminfo.** See below.

## Usage

The block below is not written here: it is a region of
[`examples/usage.zig`](examples/usage.zig), which `zig build examples` builds
and RUNS, extracted by `ci/readme_usage.sh` and compared by CI. A snippet in a
README is a claim about how the library is used, and this one is a claim
something executes.

<!-- BEGIN GENERATED ci/readme_usage.sh -->
```zig
const std = @import("std");
const zosc = @import("zosc");

// Any `*std.Io.Writer` will do -- a buffered writer over stdout is the
// real one. Nothing below allocates or flushes: batching is yours.
var buffer: [1024]u8 = undefined;
var out: std.Io.Writer = .fixed(&buffer);
const w = &out;

// Take the screen: alternate buffer, no cursor, synchronised repaints.
try zosc.altScreen.set(w, true);
try zosc.cursorVisible.set(w, false);
try zosc.syncOutput.set(w, true);

// Ask for mouse press and wheel reports in SGR form -- and, by saying so
// in one call, for no report per cell the pointer crosses.
try zosc.mouse(w, .{ .press = true, .sgr = true });

// Keys in the kitty protocol, pushed so exiting restores what was there,
// and pasted text bracketed so it can be told from typing.
try zosc.kittyKeyboardPush(w, .{
    .disambiguate_escape_codes = true,
    .report_event_types = true,
    .report_associated_text = true,
});
try zosc.bracketedPaste.set(w, true);

// A frame: clear, go to the top-left, write a heading in a style. The
// second style call writes only what changed -- four bytes rather than a
// reset and a repaint of attributes that were already right.
const heading: zosc.Style = .{ .bold = true, .fg = .{ .ansi = .cyan } };
const body: zosc.Style = .{ .fg = .{ .ansi = .cyan } };
try zosc.clearScreen(w, .all);
try zosc.cursorTo(w, 1, 1);
try zosc.setStyle(w, heading);
try w.writeAll("zosc");
try zosc.diffStyle(w, heading, body);
try w.writeAll(" -- terminal control sequences");
try zosc.resetStyle(w);

// A title, a clickable link, and a desktop notification.
try zosc.title(w, "zosc");
try zosc.hyperlink(w, "ziglang.org", "https://ziglang.org");
try zosc.notify(w, "Build finished", "0 errors");

// Put text on the clipboard of whichever machine the terminal runs on,
// base64 encoded on the fly -- no allocation, no buffer sized to the text.
try zosc.clipboardWrite(w, .clipboard, "copied by zosc");

// Ask the terminal what it is. None of these is guaranteed an answer, so
// none of them may be waited on without a timeout of your own.
try zosc.queryMode(w, zosc.syncOutput.number);
try zosc.queryDeviceAttributes(w);
try zosc.queryColor(w, .background);

// Input is one byte stream carrying keys, mouse reports and replies all
// at once, so one parser frames it. The buffer is yours, nothing here
// allocates, and a sequence split across two reads is held until the rest
// of it arrives.
var input: [1024]u8 = undefined;
var keys: zosc.KeyParser = .init(&input);

// Control and a in the kitty protocol, then an SGR mouse click.
var events = keys.feed("\x1b[97;5u\x1b[<0;40;12M");
while (events.next()) |event| switch (event) {
    // A key, and whatever text the terminal said it produced.
    .key => |key| std.debug.print("key:        {s}{t} {s}\n", .{
        if (key.mods.ctrl) "ctrl+" else "",
        key.key,
        key.text(),
    }),
    // Anything framed but not a key: a mouse report, a reply, an OSC.
    .unhandled => |bytes| if (zosc.parseMouse(bytes)) |click| std.debug.print(
        "click:      {s} at {d},{d}\n",
        .{ @tagName(click.button), click.x, click.y },
    ),
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
const mode = zosc.parseModeReply("\x1b[?2026;1$y").?;
const position = zosc.parseCursorPosition("\x1b[12;40R").?;
const background = zosc.parseColorReply("\x1b]11;rgb:1c1c/1c1c/1c1c\x1b\\").?;

// A pixel report (mode 1016) is byte-identical to a cell report, so the
// program that asked for pixels is the one that says so.
var pixel = zosc.parseMouse("\x1b[<0;321;97M").?;
pixel.pixels = true;
const cell = zosc.toCells(pixel, 8, 16);

// On the way out, in reverse.
try zosc.bracketedPaste.set(w, false);
try zosc.kittyKeyboardPop(w);
try zosc.mouseOff(w);
try zosc.syncOutput.set(w, false);
try zosc.cursorVisible.set(w, true);
try zosc.altScreen.set(w, false);
```
<!-- END GENERATED -->

Add it as a dependency and import the module:

```zig
const zosc_dep = b.dependency("zosc", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zosc", zosc_dep.module("zosc"));
```

## The surface

**Keyboard input.** `KeyParser`, `Events`, `Event`, `KeyEvent`, `Key`,
`Modifiers`, `Kind`.

**Styles and colour.** `Style`, `Color`, `Ansi`, `Rgb`, `Underline`,
`setStyle`, `diffStyle`, `resetStyle`.

**Cursor and screen.** `cursorTo`, `cursorUp`, `cursorDown`, `cursorRight`,
`cursorLeft`, `cursorNextLine`, `cursorPrevLine`, `cursorColumn`,
`cursorSave`, `cursorRestore`, `ClearLine` / `clearLine`, `ClearScreen` /
`clearScreen`, `scrollRegion`, `scrollRegionReset`, `scrollUp`, `scrollDown`,
`insertLines`, `deleteLines`.

**Titles and links.** `title`, `hyperlinkStart`, `hyperlinkEnd`, `hyperlink`.

**Clipboard (OSC 52).** `Clipboard`, `clipboardWrite`, `clipboardRequest`,
`ClipboardReply`, `parseClipboardReply`, `decodeClipboard`.

**Notifications.** `notify` (OSC 777), `notify9` (OSC 9).

**Modes.** `altScreen`, `bracketedPaste`, `syncOutput`, `focusEvents`,
`cursorVisible`, `unicodeCore` — each a type with `set(w, on)` and a `number`
— plus `setMode` for any mode zosc does not name, and `Mouse` / `mouse` /
`mouseOff`.

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
`GraphicsResponse` / `parseGraphicsResponse`.

**Mouse reports.** `Button`, `MouseEvent`, `encodeMouse`, `parseMouse`,
`toCells`.

## Design

### There is no terminfo here, and that is the design

zosc carries no capability database, consults none, and has no compile-time
knowledge of terminal names. It writes the sequences directly.

terminfo exists because in 1980 terminals genuinely disagreed: a VT52, an
ADM-3A and a Televideo cleared the screen with three unrelated byte strings,
and a program that wanted to run on all three had to look the answer up. That
is no longer the world. Every terminal anyone runs today — xterm, the
libvte family, Alacritty, kitty, WezTerm, foot, Ghostty, Windows Terminal,
iTerm2, tmux and screen in front of any of them — implements the same ANSI and
DEC sequences for everything in this package, because they all aim at xterm
compatibility and they are all tested against the same programs. The variation
that remains is not *which bytes clear the screen*; it is *whether a feature
exists at all*, and that is a different question with a better answer.

So zosc's answer to variation is to ask the terminal, not a file about the
terminal:

- `queryMode` (DECRQM) asks whether a mode is really implemented, and the
  terminal itself answers — which is the only source that cannot be out of
  date, wrong about the emulator the user actually launched, or shadowed by a
  `TERM` set to `xterm-256color` because something in the chain refused to
  pass anything else through.
- `kittyKeyboardQuery`, `queryDeviceAttributes`, `queryVersion` and
  `queryColor` ask the rest.
- A terminal that does not implement a query answers nothing at all, which is
  itself an answer as long as you pair it with one that is always answered —
  `queryDeviceAttributes` is the usual companion, since a DA1 reply arriving
  alone says the other question went unanswered rather than that the terminal
  is slow.

What a program does with silence is policy, and policy is the caller's. zosc
does not decide a timeout, does not cache, and does not fall back.

The practical effect is that this package has no dependency on ncurses, no
build step that parses a compiled terminfo entry, nothing to install on the
target machine, and the same behaviour cross-compiled to a machine whose
terminfo database the build host has never seen.

### Styles are written as a diff, not as a reset

SGR is the one place a sequence's effect depends on what came before: `CSI 1 m`
turns bold on and leaves everything else alone, and there is no sequence
meaning "this style and nothing else" short of resetting first. The naive
answer — reset, then write the whole style, for every run of cells — costs a
parameter and a repaint of attributes that were already right, on every colour
change on the screen.

`diffStyle(w, from, to)` writes the shortest sequence that gets from one to
the other, and nothing at all when they are equal, which is the common case.
It is one `CSI ... m`: the off codes first, then the on codes, then the
colours. The off codes go first because SGR 22 turns off bold and dim
together — there is no code for only one of them — so turning bold off while
dim stays on has to write `22;2`, and writing the `2` first would lose it.

zosc holds no state, so `from` is yours to remember. It is the style of
whatever you wrote last, and getting it wrong shows on screen.

### A lone ESC is the caller's ambiguity to resolve

`0x1b` is both the Escape key and the first byte of every sequence in this
document. Nothing in the byte stream distinguishes them, so every terminal
program resolves it the same way: wait a few milliseconds, and if nothing
follows, it was the key.

`KeyParser` will not guess. A trailing `ESC` is held, `pending()` shows it,
and `flush()` is what a caller whose own timeout has expired calls to settle
it — returning the Escape key, or alt with `[` or `O` for the two other byte
strings that are simultaneously a key and the start of a sequence. The
timeout is the caller's because its length is a judgement about the user's
link, not about the protocol, and because a program on a fast local terminal
and one on a satellite link want different numbers.

The better answer is to remove the ambiguity: a terminal asked for
`KittyFlags.disambiguate_escape_codes` spells Escape as `CSI 27 u` and the
question stops arising. `kittyKeyboardPush` is how you ask, and `flush` is
what you still need for the terminals that say no.

### The mouse modes are one call, not six

Mouse reporting is six independent DEC private modes, and a program that turns
on what it wants without turning off what it does not is one that gets a
report per cell the pointer crosses because something earlier set mode 1003.
`mouse` takes the whole set and writes an `h` or an `l` for each flag, in
ascending mode number:

```zig
try zosc.mouse(w, .{ .press = true, .sgr = true });
```

is press and wheel reports, in SGR coordinates, and nothing else — regardless
of what was on before. `mouseOff` is `mouse(w, .{})`. The cost of that reach
is that `Mouse.focus` is mode 1004, the same mode as `focusEvents`: a `mouse`
call that leaves it false turns focus reporting off, so a program that wants
both says so in one call.

### Pixels are a caller's claim, not a wire fact

Mode 1006 (cells) and mode 1016 (pixels) produce byte-identical reports. Only
the program that asked knows which it is getting, so `parseMouse` always
reports cells and leaves `MouseEvent.pixels` false; a program using mode 1016
sets that field on what it parsed and calls `toCells` with its cell size.
Both coordinate systems count from 1, so the first `cell_w` pixels are column
1 and pixel `cell_w + 1` opens column 2 — which is the edge case the tests
pin down.

### One parser frames the input, and hands back what it cannot read

Keys, mouse reports, cursor position reports, clipboard contents and colour
answers all arrive on the same file descriptor, interleaved, split across
reads wherever the kernel happened to split them. Framing that stream once is
the only way to do it correctly, so `KeyParser` does it once:

```zig
var events = parser.feed(buf[0..n]);
while (events.next()) |event| switch (event) {
    .key => |key| ...,
    .paste_start, .paste_end => ...,
    .focus_in, .focus_out => ...,
    .unhandled => |bytes| if (zosc.parseMouse(bytes)) |click| ...,
};
```

`Event.unhandled` is the important one. It is a complete sequence the parser
framed and deliberately did not decode — a mouse report, a reply to a query,
an OSC the terminal sent back — handed over whole for `parseMouse`,
`parseModeReply`, `parseColorReply` or whichever parser reads it. The parser
knows where every sequence ends, which is a different and much smaller job
than knowing what every sequence means, and separating the two is what keeps
an unrecognised reply from resynchronising the stream a byte at a time.

The iterator is what moves bytes into the parser, so run it to null before the
next `feed` — the read loop above does. The buffer is yours: `KeyParser.init`
takes it, `min_buffer` is enough for keys alone, and a program that asks the
terminal for the clipboard wants kilobytes, because an OSC 52 reply is as long
as whatever was copied and it arrives here.

### A parsed reply borrows

`parseClipboardReply` returns the base64 payload as a sub-slice of the bytes
it was given: nothing is copied and nothing is owned. `decodeClipboard` writes
into a buffer the caller sizes from `reply.decodedLen()`, which is exact
rather than an upper bound because the parser has already established the
payload is well-formed base64 — including that the bits padding discards are
zero. Decoding therefore cannot fail on content; the only error is a buffer
too small.

## What zosc does not do

Everything above the bytes is not here, deliberately:

- **No I/O.** zosc never touches a file descriptor, never reads a reply, and
  never puts a terminal into raw mode. `termios` and `SetConsoleMode` are the
  caller's, and so is every timeout.
- **No screen model.** No cells, no damage tracking, no layout, no diffing of
  a frame, no width tables, no grapheme segmentation. `diffStyle` diffs two
  styles; nothing here diffs two screens. zosc writes what you ask for, where
  you say.
- **No widgets and no event loop.** No windows, no focus stack, no redraw
  scheduling. Those are a framework, and a framework built on this package is
  a different package.
- **No terminal capability database.** See the design note above: zosc asks
  the terminal rather than a file about the terminal, and what a program does
  with silence is its own policy.
- **No graphics protocol.** `parseGraphicsResponse` reads the terminal's
  answer to a kitty graphics command, because that answer arrives on the input
  stream and has to be told apart from a keypress. Writing the command is not
  here: transmitting an image is a protocol of its own, with chunking,
  formats, compression and placement rules, and it is not a sequence this
  package can usefully name.
- **No legacy mouse encodings.** X10 and UTF-8 mouse modes cap coordinates at
  column 223 and are ambiguous about release. SGR exists for that reason and
  is what zosc reads.
- **No guessing at text a terminal did not report.** `KeyEvent.text` is what
  the terminal said the key produced — from the bytes themselves for plain
  input, and from the protocol's associated-text field when you asked for it.
  A terminal reporting `CSI 97 u` has not said what `a` produced on that
  layout with those modifiers, and a parser inventing an answer would be wrong
  exactly where it matters: dead keys, input methods, and shifted keys whose
  shifted form is not the uppercase of the unshifted one.
- **No escaping of your strings.** A title, a URI or a notification body
  containing `ESC`, `BEL` or `;` is written through as given. Silently
  editing a caller's text is worse than a title that stops early, and which
  edit is right depends on what the text is.

## Testing

`zig build test` runs the suite and the examples. Every writer is pinned to
its exact bytes, not to a shape:

```zig
try title(&out.writer, "hello");
try std.testing.expectEqualStrings("\x1b]2;hello\x07", out.written());
```

Beyond that: base64 at every tail length and against the standard library's
encoder for all 256 byte values; a clipboard round trip at every length from
0 to 193; every mouse event this package can represent encoded and parsed
back; and a table of malformed inputs per parser — truncated, wrong
terminator, wrong introducer, trailing rubbish, a field too many, and numbers
too large for the field they are read into.

Beyond that again: every SGR diff pinned to its exact parameters and their
exact order; every key sequence this package decodes, in every spelling a
terminal uses for it, including a sequence delivered one byte per read; and a
table of malformed inputs per parser — truncated, wrong terminator, wrong
introducer, trailing rubbish, a field too many, and numbers too large for the
field they are read into.

Every parser that reads untrusted bytes has a `std.testing.fuzz` test
asserting it never panics and never overflows, and that whatever it does
accept survives a round trip back through the writer: `parseMouse`,
`parseClipboardReply` with `decodeClipboard`, `parseModeReply`,
`parseCursorPosition`, `parseDeviceAttributes`,
`parseSecondaryDeviceAttributes`, `parseVersion`, `parseKittyKeyboardReply`,
`parseColorReply` and `parseGraphicsResponse`. `KeyParser` is fuzzed too, fed
in two pieces so the split lands anywhere a real read could have landed, and
asserting the properties a stream parser has to have: every event's text is
valid UTF-8, every `unhandled` slice lies inside the buffer it was given, the
parser always makes progress, and `flush` always empties it. `zig build test`
runs each one over its seed corpus in a few microseconds; `zig build test
--fuzz` is what turns the same properties into a search.

Tests run under `std.testing.allocator`, so a leak or an invalid free fails
the test rather than the process. CI runs them in Debug, ReleaseSafe,
ReleaseFast and ReleaseSmall, on Linux, macOS and Windows;
[`ci/linux.sh`](ci/linux.sh) runs the Linux half in Docker from a machine that
is not Linux, because "it passed on my Mac" is not a claim about a package
whose users are mostly not on one.

## Requirements

Zig 0.16.0. No other dependencies.

## Licence

MIT. See [LICENSE](LICENSE).