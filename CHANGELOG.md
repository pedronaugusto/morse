# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-09-14

### Added

- **The extended cursor position report, DECXCPR.**
  `requestExtendedCursorPosition` writes `CSI ? 6 n`, and
  `parseExtendedCursorPosition` reads the `CSI ? row ; col ; page R` answer
  into an `ExtendedCursorPosition`. It is the plain CPR with a private
  marker, and the marker is carried through into the report, so a program
  that asked both questions can tell the two answers apart — which is why
  this is a second parser rather than a wider first one. A terminal emulator
  has one page and answers 1; the field is reported rather than dropped,
  because a parser that discarded it could not claim to have read the whole
  report.
- **`Mouse.rxvt`**, mode 1015, beside the other six mouse modes `mouse`
  switches. `parseMouseRxvt` has read that encoding since 0.2.0, and nothing
  here could ask for it or, more to the point, say `l` for it: a terminal left
  in mode 1015 by something earlier kept sending rxvt reports through every
  `mouse` and `mouseOff` call a program made. Both now write one more
  sequence, `CSI ? 1015 h` or `CSI ? 1015 l`, in mode-number order with the
  rest.
- **The pointer's shape, OSC 22.** `pointerShape` tells the terminal what to
  draw under the mouse — the hand over a hyperlink, the resize arrows over a
  split bar — and `pointerShapeReset` puts it back. The terminal owns the
  pointer and knows nothing about what the program drew beneath it, so there
  is no other way to say. `PointerShape` names the shapes as CSS names them,
  which is the vocabulary kitty introduced for this sequence and the
  terminals after it took up; xterm's OSC 22 names the X cursor font instead,
  and nothing is acknowledged either way, so a program writes the right shape
  and accepts that some terminals leave the pointer alone.

### Changed

- `Mouse` gained a field, so it is one bit wider. It is a `packed struct`,
  and code that bit-casts one rather than naming its fields has to be told.

## [0.2.0] - 2026-09-14

Everything a program needs below a TUI framework, on both sides of the wire.

### Added

- **Keyboard input.** `KeyParser` turns a byte stream into `Event`s over a
  buffer the caller owns: the kitty keyboard protocol at every flag level
  (`CSI u` with alternate keys, event types and associated text), the legacy
  xterm and VT sequences (`CSI` and `SS3` arrows, the `CSI n ~` function and
  editing keys, modifiers as `;2` through `;8`), xterm's `modifyOtherKeys`,
  bracketed paste as `paste_start` and `paste_end`, focus in and out, and
  plain UTF-8. `feed` keeps a partial sequence across calls; a lone `ESC` is
  held rather than guessed at, `pending` shows it, and `flush` settles it on
  the caller's timeout. Whatever the parser frames but does not decode — a
  mouse report, a reply to a query — comes back whole as `Event.unhandled`.
  With `Key`, `Modifiers`, `Kind`, `KeyEvent` and `Events`.
- **Styles and colour.** `Style` (bold, dim, italic, five underline styles,
  blink, reverse, hidden, strikethrough), `Color` (default, the sixteen
  `Ansi` entries, the 256-colour palette, and `Rgb`) for foreground,
  background and underline, with `setStyle`, `resetStyle`, and `diffStyle`
  writing only what changed in one `CSI ... m`.
- **Cursor and screen.** `cursorTo`, `cursorUp`, `cursorDown`, `cursorRight`,
  `cursorLeft`, `cursorNextLine`, `cursorPrevLine`, `cursorColumn`,
  `cursorSave` and `cursorRestore` (DECSC and DECRC), `clearLine` and
  `clearScreen` with their variants, `scrollRegion` (DECSTBM) and
  `scrollRegionReset`, `scrollUp`, `scrollDown`, `insertLines` and
  `deleteLines`.
- **More questions, and their answers.** `queryDeviceAttributes` (DA1) with
  `parseDeviceAttributes`, `querySecondaryDeviceAttributes` (DA2) with
  `parseSecondaryDeviceAttributes`, `queryVersion` (XTVERSION) with
  `parseVersion`, `parseKittyKeyboardReply` for the flags query,
  `queryColor` / `setColor` / `resetColor` for OSC 10, 11 and 12 with
  `parseColorReply` reading the `rgb:` form at any channel width, and
  `parseGraphicsResponse` for the kitty graphics `APC G` reply — a parser
  only, since this package writes no graphics commands.
- **Terminfo capabilities over the wire, XTGETTCAP.** `queryCapability` and
  `queryCapabilities` ask the terminal itself for a named capability — `Co`
  for the colour count, `kend` for the bytes the End key sends — writing
  `DCS + q ST` with the names in hex. `parseCapabilityReply` reads the
  `DCS 1 + r name=value ST` answer and the `DCS 0 + r name ST` refusal,
  checks every field is an even run of hex digits, and returns a
  `CapabilityReply` whose `Capabilities` iterator yields each `Capability`
  with both halves still encoded; `decodeName` and `decodeValue` write them
  into a buffer the caller sizes from `nameLen` and `valueLen`. `KeyParser`
  frames the reply whole, as it does every other reply.
- **The palette, OSC 4 and 104.** `queryPaletteColor` asks what the user's
  theme actually put at a numbered entry — which nothing but the terminal
  knows — `setPaletteColor` changes one, and `resetPaletteColor` and
  `resetPalette` put one or all of them back. `parsePaletteReply` reads the
  answer into a `PaletteReport`, in the same `rgb:` form at any channel width
  that `parseColorReply` reads, and each of the two parsers returns null for
  the other's sequence. `palette_size` is the 256 entries OSC 4 addresses.
- **Semantic prompt marks, OSC 133.** `promptStart`, `promptEnd`,
  `commandStart` and `commandEnd` say where a prompt ended and a command's
  output began, and what the command exited on. Nothing in a stream of
  characters says which of them the user typed, so a terminal cannot scroll
  by command, fold one, or mark a failure in the margin unless the program
  tells it. `commandEnd` takes an optional exit code, because a program that
  does not have one should not claim a zero.
- **Progress, OSC 9;4.** `progress` tells the terminal what fraction of the
  work is done, so it can draw it in the tab or on the taskbar: `Progress` is
  `percent`, `failed`, `warning`, `indeterminate` and `none`, with a value
  above 100 written as 100 because the protocol defines none. Only the
  program knows how far along it is, and there is no other way for it to say.
- **The rxvt mouse report** (mode 1015), read by `parseMouseRxvt` and framed
  by `KeyParser`. It is the X10 report with its three fields spelled in
  decimal, so it carries a column past the 223 the biased byte caps at; a
  terminal left in mode 1015 by something earlier sends it, and the three
  mouse parsers each return null for the other two forms.
- **Win32 input mode**, DEC private mode 9001, as `win32Input` and as a
  `KeyParser` decoder. A terminal on Windows in that mode sends every key as
  `CSI Vk ; Sc ; Uc ; Kd ; Cs ; Rc _` — the fields of a console key record —
  with all six optional and each with its documented default. The repeat
  count becomes that many events, the control-key state becomes `Modifiers`,
  and the key coming up is dropped unless `KeyParser.report_key_up` is set,
  so a caller sees the same `Key` values the kitty and legacy paths produce.
- **Console input records**, translated by `fromInputRecord` through the same
  virtual-key table. `ConsoleKeyRecord`, `ConsoleMouseRecord` and
  `ConsoleSizeRecord` declare the fields of `KEY_EVENT_RECORD`,
  `MOUSE_EVENT_RECORD` and `WINDOW_BUFFER_SIZE_RECORD`, so the translation
  compiles and is tested on every platform and nothing here imports an
  operating system API: a program reads the records with whichever API it
  likes and hands the fields over. A key record becomes a `KeyEvent`, a mouse
  record a `MouseEvent` counted from one, a size record a `Resize`, and
  everything else null.
- **Modes.** `unicodeCore` (2027), the mode that decides whether the terminal
  measures text by grapheme cluster or by codepoint.
- **`requestCursorPosition`**, which was missing beside `parseCursorPosition`.
- **`ci/linux.sh`** and `ci/linux.Dockerfile`, which run the suite on Linux in
  Docker from a machine that is not Linux.

- **How big the terminal is, asked over the wire.** `queryWindowSize` with
  `SizeQuery` writes the XTWINOPS requests for the text area in pixels or in
  characters, the screen in characters, and one character cell in pixels;
  `parseWindowSize` reads the replies into a `WindowSize`. The cell-size reply
  is what `toCells` needs and what nothing else reports. `resizeTextArea` asks
  the terminal to change size. This is the size question asked of the terminal
  rather than of the operating system, which is the only form of it that
  survives a multiplexer, a pipe, or a terminal on another machine.
- **In-band resize**, mode 2048 as `inBandResize`, with the terminal's report
  decoded as `Event.resize` carrying a `Resize`. A program learns its own size
  with no signal handler and no file descriptor to call `ioctl` on.
- **The X10 mouse report**, read by `parseMouseX10` and — more importantly —
  framed by `KeyParser`. A terminal in mode 1000 without mode 1006 sends
  these, and its three coordinate bytes are arbitrary, so a parser that
  stopped at the `M` handed them to the key decoder as three keypresses. It
  no longer does. `mouse_x10_max` is the 223-column cap that made SGR
  necessary.
- **The title stack**, `titlePush` and `titlePop` (`CSI 22 ; 2 t` and
  `CSI 23 ; 2 t`). No sequence reads a window title back, so pushing on entry
  and popping on exit is the only way to leave one as it was found.
- **`workingDirectory`** (OSC 7), which tells the terminal the current
  directory and the host it is on.
- **`autoWrap`**, DECAWM (mode 7), which a program painting the bottom-right
  cell turns off so that painting it does not scroll the screen.
- **`Style.overline`**, SGR 53 and 55, diffed like every other attribute.
- **The character-level edits**: `insertChars` (ICH), `deleteChars` (DCH),
  `eraseChars` (ECH) and `cursorRow` (VPA) — the row's counterparts to the
  line-level sequences already here.

### Fixed

- `KeyParser` framed an X10 mouse report as the three bytes `CSI M` and
  delivered the report's button and coordinates as three separate keypresses.
  The report is now framed by its length, so the key stream survives a
  terminal that was left in mode 1000 by something earlier.

### Changed

- Renamed from `zosc`: the package and module are `morse`; the import in a
  consumer's build.zig changes with it.
- The README says why there is no terminfo here, and what morse does instead.
- "What morse does not do" no longer claims morse reads no legacy mouse
  encoding — it reads X10 — and now says why 8-bit C1 introducers are not
  read on the input side.

## [0.1.0] - 2026-09-13

First release. Requires Zig 0.16.0.

### Added

- **Titles and hyperlinks.** `title` (OSC 2), `hyperlinkStart`,
  `hyperlinkEnd` and `hyperlink` (OSC 8, with the optional `key=value`
  parameter list).
- **Clipboard, OSC 52.** `clipboardWrite` encodes base64 three input bytes at
  a time straight into the writer, so it allocates nothing and needs no
  buffer proportional to the payload. `clipboardRequest`,
  `parseClipboardReply` and `decodeClipboard` read a reply back into a
  caller-owned buffer, with `ClipboardReply.decodedLen` giving the exact size
  in advance. `Clipboard` names the twelve selections OSC 52 addresses.
- **Notifications.** `notify` (OSC 777) and `notify9` (OSC 9).
- **Modes.** `altScreen` (1049), `bracketedPaste` (2004), `syncOutput`
  (2026), `focusEvents` (1004) and `cursorVisible` (25), each with `set(w,
  on)` and a `number`; `setMode` for any private mode not named here; and
  `Mouse` / `mouse` / `mouseOff`, which switch the six mouse reporting modes
  as one set so a program can ask for press and wheel reports without motion.
- **Kitty keyboard protocol.** `KittyFlags` as a `packed struct(u5)` of the
  five documented bits, with `kittyKeyboardPush`, `kittyKeyboardPop` and
  `kittyKeyboardQuery`.
- **Cursor shape.** `CursorShape` and `cursorShape`, DECSCUSR.
- **Queries and replies.** `queryMode` (DECRQM) with `parseModeReply`, and
  `parseCursorPosition` for the plain CPR report.
- **Mouse reports.** `encodeMouse` and `parseMouse` for SGR 1006 and pixel
  1016 reports, `Button` and `MouseEvent`, and `toCells` for converting a
  pixel report to cells.

[Unreleased]: https://github.com/pedronaugusto/morse/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/pedronaugusto/morse/releases/tag/v0.3.0
[0.2.0]: https://github.com/pedronaugusto/morse/releases/tag/v0.2.0
[0.1.0]: https://github.com/pedronaugusto/morse/releases/tag/v0.1.0
