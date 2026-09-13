# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- **Modes.** `unicodeCore` (2027), the mode that decides whether the terminal
  measures text by grapheme cluster or by codepoint.
- **`requestCursorPosition`**, which was missing beside `parseCursorPosition`.
- **`ci/linux.sh`** and `ci/linux.Dockerfile`, which run the suite on Linux in
  Docker from a machine that is not Linux.

### Changed

- The README says why there is no terminfo here, and what zosc does instead.

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

[Unreleased]: https://github.com/pedronaugusto/zosc/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/pedronaugusto/zosc/releases/tag/v0.1.0
