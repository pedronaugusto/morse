# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.1.0]: https://github.com/pedronaugusto/zosc/releases/tag/v0.1.0
