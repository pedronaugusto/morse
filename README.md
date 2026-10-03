# morse

morse writes terminal control sequences and decodes terminal input in Zig. Typed writers
and parsers cover screen commands, keys, mouse reports and query replies, including
input split across reads.

## Install

Requires Zig 0.16.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/morse`, then obtain the `morse` module through
`b.dependency` and add it to your executable's imports. Forward your target and optimize
settings.

## Usage

[examples/quickstart.zig](examples/quickstart.zig)

<!-- BEGIN GENERATED ci/readme_usage.sh -->
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

The library uses only `std` and allocates no storage of its own. The conformance step
alone fetches a lazy, pinned Ghostty emulator dependency to check terminal behaviour;
consumer builds do not fetch it. Writers take a `*std.Io.Writer` and leave flushing to
the caller. Parsers borrow their input; `KeyParser` retains incomplete sequences in a
caller-owned buffer. Drain each `Events` iterator before feeding more bytes, and consume
borrowed event data before the next iterator step, feed or flush.
Key events own their text; retained sequence bytes keep split input intact and borrowed
replies independent of the read buffer.

`Style` describes SGR attributes and colours. `setStyle` writes from the terminal's
default state; `diffStyle` writes the changes between two known styles. Cursor and erase
commands use typed parameters. `cost` counts what the style, cursor, erase, repeat, mode,
hyperlink and text-size writers would write, through the code that writes it.
`applySgr` reads a style change back into a `Style`, `parseHyperlink` and
`parseTextSize` read the bodies of OSC 8 and OSC 66, and `parseCsi` and
`parseControlString` frame sequences, for a program that reads what was written.
Text-bearing control sequences reject C0 controls and DEL before writing; `printable`
explicitly strips them into a supplied buffer.

`KeyParser` frames legacy and kitty keys, win32 input sequences, paste, focus, resize,
mouse reports and replies in one stream. An unknown framed sequence becomes
`Event.unhandled`. A lone ESC stays undecided until more input or `flush`, and
`undecided` says when it is; the application decides when to settle it. Whole-sequence parsers return null for
unrecognized or malformed input.

`ConsoleDecoder` accepts Windows console records without reading a console handle. It
maintains keyboard and mouse state, including held Ctrl records and UTF-16 surrogate
pairs. Release events are available when the input protocol reports them.

Graphics commands cover kitty image transmission, placement and deletion. Clipboard and
capability replies borrow their encoded payloads and decode into supplied buffers.
`Probe` writes startup questions; `probeAnswered` routes replies to those questions. The
caller supplies deadlines because a terminal need not answer.

## Scope

- It does not open or read a terminal, set raw mode or install signal handlers.
- It does not hold a screen grid, lay out text or measure grapheme widths.
- It does not provide widgets or an event loop.
- It does not track image placement or assign image identifiers.
- It does not maintain a terminal capability database.

<!-- performance: quiet pass -->

## Testing

Local build scripts clear `.zig-cache/{o,h,z,tmp}` above the measured cap in `ci/cache.sh`; run `sh ci/cache.sh` before direct Zig builds (only a rebuild is lost).

`zig build test` runs the unit suite and both examples in Debug by default. Tests check
writer bytes, malformed input, split framing, console records and parser round trips.
`zig build examples` runs the examples separately; `zig build check` compiles the tests
and examples without running them. CI also runs `ci/check-readme.sh`.

[CI](.github/workflows/ci.yml) runs tests and examples in Debug and ReleaseSafe on
`ubuntu-latest`, `macos-latest` and `windows-latest`, plus ReleaseFast on Ubuntu.
ReleaseSmall is compile-only on Ubuntu. Source jobs check formatting, cast reasons and
the clock policy. There is no ThreadSanitizer job.

Compile-only jobs cover `x86_64-linux-gnu`, `aarch64-linux-gnu`, `x86_64-windows-gnu`,
`aarch64-windows-gnu`, `x86_64-macos` and `aarch64-macos`. Separate Ubuntu and macOS
jobs run `zig build conformance`.

## Licence

MIT. See [LICENSE](LICENSE).
