# zosc

[![CI](https://github.com/pedronaugusto/zosc/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/zosc/actions/workflows/ci.yml)

Terminal control sequences as typed writers and parsers, in pure Zig. No
dependencies, no C, no allocations.

Every terminal program ends up writing the same dozen escape sequences by
hand, with the numbers spelled out in string literals and the mouse report
parsed with a loop that overflows on a long number. zosc is those sequences
with names, the flags as `packed struct`s, and the replies as parsers that
return `null` instead of garbage.

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
- **No state.** zosc holds nothing between calls, so a program's terminal
  state stays somewhere the program can see it.

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
var buffer: [512]u8 = undefined;
var out: std.Io.Writer = .fixed(&buffer);
const w = &out;

// Take the screen: alternate buffer, no cursor, synchronised repaints.
try zosc.altScreen.set(w, true);
try zosc.cursorVisible.set(w, false);
try zosc.syncOutput.set(w, true);

// Ask for mouse press and wheel reports in SGR form -- and, by saying so
// in one call, for no report per cell the pointer crosses.
try zosc.mouse(w, .{ .press = true, .sgr = true });

// Keys in the kitty protocol, pushed so exiting restores what was there.
try zosc.kittyKeyboardPush(w, .{
    .disambiguate_escape_codes = true,
    .report_event_types = true,
});

// A title, a clickable link, and a desktop notification.
try zosc.title(w, "zosc");
try zosc.hyperlink(w, "ziglang.org", "https://ziglang.org");
try zosc.notify(w, "Build finished", "0 errors");

// Put text on the clipboard of whichever machine the terminal runs on,
// base64 encoded on the fly -- no allocation, no buffer sized to the text.
try zosc.clipboardWrite(w, .clipboard, "copied by zosc");

// Ask whether synchronised output is really supported.
try zosc.queryMode(w, zosc.syncOutput.number);

// Replies arrive as bytes on the terminal's input. Every parser takes a
// whole sequence and returns null for anything it does not recognise.
const mode = zosc.parseModeReply("\x1b[?2026;1$y").?;
const position = zosc.parseCursorPosition("\x1b[12;40R").?;
const click = zosc.parseMouse("\x1b[<0;40;12M").?;

// A pixel report (mode 1016) is byte-identical to a cell report, so the
// program that asked for pixels is the one that says so.
var pixel = zosc.parseMouse("\x1b[<0;321;97M").?;
pixel.pixels = true;
const cell = zosc.toCells(pixel, 8, 16);

// On the way out, in reverse.
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

**Titles and links.** `title`, `hyperlinkStart`, `hyperlinkEnd`, `hyperlink`.

**Clipboard (OSC 52).** `Clipboard`, `clipboardWrite`, `clipboardRequest`,
`ClipboardReply`, `parseClipboardReply`, `decodeClipboard`.

**Notifications.** `notify` (OSC 777), `notify9` (OSC 9).

**Modes.** `altScreen`, `bracketedPaste`, `syncOutput`, `focusEvents`,
`cursorVisible` — each a type with `set(w, on)` and a `number` — plus
`setMode` for any mode zosc does not name, and `Mouse` / `mouse` / `mouseOff`.

**Keyboard and cursor.** `KittyFlags`, `kittyKeyboardPush`,
`kittyKeyboardPop`, `kittyKeyboardQuery`, `CursorShape`, `cursorShape`.

**Queries and replies.** `queryMode`, `ModeState`, `ModeReport`,
`parseModeReply`, `CursorPosition`, `parseCursorPosition`.

**Mouse reports.** `Button`, `MouseEvent`, `encodeMouse`, `parseMouse`,
`toCells`.

## Design

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

### A parsed reply borrows

`parseClipboardReply` returns the base64 payload as a sub-slice of the bytes
it was given: nothing is copied and nothing is owned. `decodeClipboard` writes
into a buffer the caller sizes from `reply.decodedLen()`, which is exact
rather than an upper bound because the parser has already established the
payload is well-formed base64 — including that the bits padding discards are
zero. Decoding therefore cannot fail on content; the only error is a buffer
too small.

## What zosc does not do

Roughly half of a terminal library is not here, deliberately:

- **No I/O.** zosc never touches a file descriptor, never reads a reply, and
  never puts a terminal into raw mode. `termios` and `SetConsoleMode` are the
  caller's.
- **No stream framing.** Parsers take one whole sequence. Deciding where a
  sequence ends in a byte stream — and what to do about a partial read — is a
  state machine over the caller's input buffer, and it belongs with the
  caller's input buffer.
- **No screen model.** No cells, no damage tracking, no layout, no diffing, no
  width tables. zosc writes what you ask for.
- **No terminal capability database.** There is no terminfo here and no
  feature detection. `queryMode` and `kittyKeyboardQuery` ask; what a program
  does with silence is its own policy.
- **No key decoding.** `kittyKeyboardPush` turns the protocol on; parsing the
  key reports it produces is out of scope for 0.1.0.
- **No SGR attributes or colour.** Those are a different shape of problem —
  palettes, capability negotiation, colour spaces — and pretending otherwise
  would make this package the thin end of a terminal toolkit.
- **No legacy mouse encodings.** X10 and UTF-8 mouse modes cap coordinates at
  column 223 and are ambiguous about release. SGR exists for that reason and
  is what zosc reads.
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

Every parser that reads untrusted bytes — `parseMouse`, `parseClipboardReply`
with `decodeClipboard`, `parseModeReply`, `parseCursorPosition` — also has a
`std.testing.fuzz` test asserting it never panics and never overflows, and
that whatever it does accept survives a round trip back through the writer.
`zig build test` runs each one over its seed corpus in a few microseconds;
`zig build test --fuzz` is what turns the same property into a search.

Tests run under `std.testing.allocator`, so a leak or an invalid free fails
the test rather than the process. CI runs them in Debug, ReleaseSafe,
ReleaseFast and ReleaseSmall, on Linux, macOS and Windows.

## Requirements

Zig 0.16.0. No other dependencies.

## Licence

MIT. See [LICENSE](LICENSE).