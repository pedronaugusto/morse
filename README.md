# morse

morse writes terminal control sequences and decodes terminal input in Zig. Typed writers
and parsers cover screen commands, keys, mouse reports and query replies, including
input split across reads. The Zig 0.17 changes are work in progress and unreleased.

## Install

Requires Zig 0.17.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/morse`, then obtain the `morse` module through
`b.dependency` and add it to your executable's imports. Forward your target and optimize
settings.

## Usage

[examples/quickstart.zig](examples/quickstart.zig)

<!-- BEGIN GENERATED zig build docs -- usage -->
```zig
const std = @import("std");
const morse = @import("morse");

var output: [128]u8 = undefined;
var writer: std.Io.Writer = .fixed(&output);
const heading: morse.Style = .{ .bold = true, .fg = .ansi(.cyan) };
const body: morse.Style = .{ .fg = .ansi(.cyan) };

try morse.cursorTo(&writer, 1, 1);
try morse.setStyle(&writer, heading);
try writer.writeAll("morse");
try morse.diffStyle(&writer, heading, body);
try writer.writeAll(" terminal sequences");
try morse.resetStyle(&writer);

var input: [128]u8 = undefined;
var parser: morse.KeyParser = .init(&input);
var events = parser.feed("\x1b[97;");
if (events.next() != null) return error.IncompleteKey;

events = parser.feed("5u\x1b[<0;40;12M");
const key = (events.next() orelse return error.MissingKey).key;
const mouse = (events.next() orelse return error.MissingMouse).mouse;
```
<!-- END GENERATED -->

## Design

The library uses `std` and aegis scalar types and allocates no storage of its own. The conformance build
under `conformance/` pins a Ghostty emulator in a manifest of its own to check terminal
behaviour; morse's manifest does not name it, so no build of a program on morse fetches
or compiles it. Writers take a `*std.Io.Writer` and leave flushing to the caller.
Parsers borrow their input; `KeyParser` retains incomplete sequences in a caller-owned
buffer. Drain each `Events` iterator before feeding more bytes, and consume borrowed
event data before the next iterator step, feed or flush.
Key events own their text; retained sequence bytes keep split input intact and borrowed
replies independent of the read buffer.

`Style` describes SGR attributes and colours. `setStyle` writes from the terminal's
default state; `diffStyle` writes the changes between two known styles. `Color.fit`
and `Style.fit` turn colours into the nearest a terminal with 256 colours, sixteen or
none can show; the caller says which it has. Cursor and erase
commands use typed parameters. `cost` counts what the style, cursor, erase, repeat, mode,
hyperlink, text-size, key, sixel and iTerm2 writers would write, through
the code that writes it.
`applySgr` reads a style change back into a `Style`, `parseHyperlink` and
`parseTextSize` read the bodies of OSC 8 and OSC 66, and `parseCsi` and
`parseControlString` frame sequences, for a program that reads what was written.
`strip` and `Stripper` take the sequences and C1 controls out of output on
the same framers, whole or a read at a time, keeping C0 controls.
Text-bearing control sequences reject C0 controls and DEL before writing; `printable`
explicitly strips them into a supplied buffer.

`KeyParser` frames legacy and kitty keys, win32 input sequences, paste, focus, resize,
mouse reports and replies in one stream. An unknown framed sequence becomes
`Event.unhandled`. A lone ESC stays undecided until more input or `flush`, and
`undecided` says when it is; the application decides when to settle it. Whole-sequence parsers return null for
unrecognized or malformed input.

`encodeKey` goes the other way, for a program that stands where a terminal
stands: it writes a `KeyEvent` as the bytes a terminal sends for it, given
the kitty flags, `modifyOtherKeys` and cursor, keypad and backspace modes
in a `KeyEncoding`. The kitty encoding follows kitty's encoder and the
legacy one xterm's as ghostty writes it; the conformance step compares
both with ghostty's encoder and names where kitty and ghostty differ. With
every kitty flag set, `KeyParser` reads back what `encodeKey` wrote as the
key it was written from.

`ConsoleDecoder` accepts Windows console records without reading a console handle. It
maintains keyboard and mouse state, including held Ctrl records and UTF-16 surrogate
pairs. Release events are available when the input protocol reports them.

Graphics commands cover kitty image transmission, placement and deletion.
`sixel` writes an image as a sixel string from palette indices or RGBA and
a caller's palette of up to 256 colours, a band at a time from a fixed block
of stack; `itermImage` and `itermImageMultipart` send a file as iTerm2's
`OSC 1337` inline image, whole or in pieces. Both are bytes only: choosing
a palette, decoding and scaling are the caller's. `querySixelGraphics`
asks how many colour registers a sixel image may use and how big it may be
(XTSMGRAPHICS), `parseSixelGraphics` reads the answer, and
`sixelCursorRight` is mode 8452, which leaves the cursor beside an image
rather than below it; `Probe` asks all three. Clipboard and
capability replies borrow their encoded payloads and decode into supplied buffers.
`Probe` writes startup questions, including the colour count `Co`; `probeAnswered` routes replies to those questions. The
caller supplies deadlines because a terminal need not answer.

## Scope

- It does not open or read a terminal, set raw mode or install signal handlers.
- It does not hold a screen grid, lay out text or measure grapheme widths.
- It does not provide widgets or an event loop.
- It does not track image placement or assign image identifiers.
- It does not decode or scale an image, or choose a palette for one.
- It does not maintain a terminal capability database.

<!-- performance: quiet pass -->

## Built with

- [Zig](https://ziglang.org) 0.17.0 and its standard library; nothing else is
  linked into the module.
- [shakedown](https://github.com/pedronaugusto/shakedown) supplies test support and benchmark measurement.
- [preflight](https://github.com/pedronaugusto/preflight) runs the source checks,
  the tests and CI.
- [Ghostty](https://github.com/ghostty-org/ghostty)'s `libghostty-vt` is the
  emulator the conformance build writes to, named only in `conformance/build.zig.zon`.

## Testing

Local build scripts clear `.zig-cache/{o,h,z,tmp}` above the measured cap through preflight; run `zig build cache` before direct Zig builds (only a rebuild is lost).

`zig build test` runs `zig build lint` first, then the unit suite and both examples, in
Debug by default; `-Dci-lint=false` leaves the lint step out. Tests check writer bytes,
malformed input, split framing, console records and parser round trips.
`zig build examples` runs the examples separately; `zig build check` compiles the tests
and examples without running them. `zig build check-consumer`, part of lint, builds a
project that depends on morse with no packages fetched.

`zig build bench` measures the workloads in `bench/` in ReleaseFast through
`shakedown.bench`, emitting JSON lines with samples, best, median, p99, throughput
and build provenance. `zig build bench-build` compiles them without running them.
Local `zig build test` smoke-runs every row once with small inputs; hosted CI
compiles the benchmarks and leaves timings to manual runs. Byte counts and buffer
bounds remain unit tests. Timing results have no pass/fail ceilings.

The executable accepts `--row <prefix>` and `--smoke`. Units name the work
performed: calls, moves, images or bytes; sample values are always nanoseconds per
unit. A smoke image is 32×32 RGBA; a measured image is 512×512. The parser grid
keeps two input streams, three buffer sizes and four read sizes.

`zig build bench-ab -- --base <commit> --program budgets --row <prefix> --pairs 5`
uses preflight's interleaved runner and shakedown's comparison. Both revisions must
already implement `bench-build` and JSONL row selection; revisions before this
migration use the old tab-separated output and cannot be compared by that command.

[CI](.github/workflows/ci.yml) runs in tiers. The fast tier runs the source checks and
the Debug suite on `ubuntu-latest`; the merge tier, on the candidate for `main`, adds
the Debug suite on `macos-latest` and `windows-latest`; the release tier, before a cut,
runs tests and examples in Debug and ReleaseSafe on all three, plus ReleaseFast on Ubuntu,
and compiles ReleaseSmall on Ubuntu. Source jobs check formatting, cast reasons and
the clock policy. There is no ThreadSanitizer job.

Compile-only jobs cover `x86_64-linux-gnu`, `aarch64-linux-gnu`, `x86_64-windows-gnu`,
`aarch64-windows-gnu`, `x86_64-macos` and `aarch64-macos`. Separate Ubuntu and macOS
jobs run the conformance build under `conformance/` (`zig build conformance` locally)
on pull requests and merge or release dispatches, not on pushes to `main`. The merge and release
tiers also run the Debug suite on Zig master on Ubuntu; it never blocks.

## Licence

MIT. See [LICENSE](LICENSE).
