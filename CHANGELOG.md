# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking

- **`fromInputRecord` is gone; `ConsoleDecoder` replaces it.** Pairing the
  halves of a character needs memory, and a function has none. A caller
  keeps one decoder and calls `next` with each record:
  `var records: morse.ConsoleDecoder = .{ .report_key_up = false };` then
  `records.next(record)`. It returns the same three events on the same
  terms, plus null while a character is still half-arrived.

- **`Event` gained two variants**, `text` and `overflow`. A switch over it
  that listed every case has to be told.

- **A run of printable text no longer arrives as one `KeyEvent` per
  character.** Two or more printable codepoints in a row are one
  `Event.text` holding the run; one on its own is still `Event.key`.

### Added

- **A `comptime` block pins `Style`'s layout** — no padding, an alignment of
  one, and `Color` four bytes aligned to one — so a field of a wider type
  added anywhere but the front fails the build instead of opening a hole for
  a byte comparison to read. 0.4.0's entry claimed this; it landed one
  commit after that release, and the entry there now says so.

- **The Windows console keyboard reaches what it could not.** A character
  outside the basic plane arrives as two records carrying the halves of a
  UTF-16 surrogate pair, and both halves used to come back as nothing; they
  are now paired, in both shapes — `ConsoleState` is the one `?u16` it takes,
  and `KeyParser` keeps one for mode 9001. A character composed by holding
  Alt and typing digits on the keypad rides the Alt key **coming up**, which
  the key-up filter dropped and mode 9001 skipped; the digits are now held
  and the character is reported as a press, which is what it is. And AltGr
  sets the right-Alt bit and a control bit together, which is
  indistinguishable from control and alt except that it also produced a
  character — so a record with right Alt, a control bit and a character of
  its own is reported as the character, with neither modifier.

- **A second framer, and a differential test against it.** The parser is
  recursive descent; the framer beside it in the suite is the same grammar
  as a state machine, written from the specifications rather than from the
  code, and the two must frame any stream into the same sequences — the
  same starts, the same lengths, the same order. A fixed-seed sweep of
  20,000 generated streams runs on every build, and a fuzz target searches
  past it; the generator builds streams out of real sequence shapes, whole
  and truncated, and raw bytes, because two framers differ on the shapes
  somebody designed rather than on noise. 200,000 streams and 2.7 million
  framed sequences agree.

- **`Probe`: the startup questions in one write and one round trip.** Every
  question here already had a writer and every answer a parser; what was
  missing was the order, and the order is the whole of what makes one
  timeout safe instead of seventeen. `Probe.write` asks seventeen questions
  in 129 bytes — the cursor position first, because a terminal that does not
  consume a sequence it did not recognise bleeds the rest of it onto its own
  output and a report that comes back first drags that out in front; the OSC
  colour queries next, because a multiplexer forwards those and the answer
  takes the long way round; DA2 late, because it identifies nothing alone;
  DA1 last, because every terminal answers it. The DA1 reply is the
  sentinel: arm one timeout, disarm it there, and every question that
  answered nothing before it has answered no. `probeMatches(reply,
  question)` routes the answers — a reply answers at most one of them, which
  the suite checks over every question and every real reply. Each field
  turns one question off; DA1 is written whatever they say.

- **`kittyKeyboardSet`**, `CSI = flags ; mode u`: the flags in effect
  changed without the stack. It is the only way to change them that does not
  push, and the stack is per screen, finite — a push onto a full one throws
  the oldest entry away — and unwound only by `kittyKeyboardPop`, which
  clears every flag when it is popped past empty. Push once on entry, pop
  once on exit, and use this in between. `KittyFlagChange` is the three
  modes: `.replace`, `.add`, `.remove`. The doc comments on push and pop now
  say the three things about the stack that decide how to use it.

- **The XTMODKEYS writers and their reply.** `modifyKeys` sets one of the
  seven key-modifying resources, `modifyKeysReset` puts them all back as the
  terminal had them, `queryModifyKeys` asks what one is set to, and
  `parseModifyKeysReply` reads the answer. `KeyParser` has decoded
  `modifyOtherKeys` — `CSI 27 ; modifiers ; codepoint ~` — since 0.2.0 and
  nothing here could ask a terminal for it; the resource is zero by default,
  so asking is the whole of how those reports are turned on. A null value
  writes the resource back to what the terminal started with, which is not
  the same as writing zero.

- **A run of printable text is one event.** `Event.text` hands the run back
  as a slice of the parser's buffer, the way `Event.unhandled` hands back a
  sequence, so a paste costs one event and no copying rather than a
  forty-four-byte `KeyEvent` built per character. A single printable
  codepoint is still a keypress and still arrives as `Event.key`, because
  that is what it is. A megabyte of pasted text through a 16 KB buffer read
  in one go measures 1,830 MB/s against 118.6 for a `KeyEvent` per
  codepoint, and 0.4 before the top-up change below.

- **A sequence longer than the buffer is reported rather than let through.**
  `Event.overflow` carries how many bytes went, and the parser skips to the
  end of that sequence before reading anything else — so what comes next is
  the next sequence, not the middle of the one that did not fit. Before
  this, a 412-byte OSC 52 reply against a 64-byte buffer became 347
  keypresses: the parser cleared its buffer and started reading base64 as
  input. `KeyParser.flush` reports an over-long sequence whose end never
  arrived, and `KeyParser.min_buffer` now says plainly that it covers keys
  and that the replies a program asks for are its own to size for.

### Changed

- **`diffStyle` writes the shorter of the difference and a reset.** The
  difference is short when little changed and long when much did: coming
  back from an everything-on style costs
  `CSI 22;23;24;25;27;28;29;55;75;39;49;59m`, thirty-eight bytes, where
  `CSI 0 m` costs four and leaves the terminal in exactly the same style. A
  leading `0` costs two bytes and buys every off code at once, so the two
  spellings are priced with `Writer.Discarding` — the same code that writes
  the bytes, so there is no second encoder to keep in step — and the shorter
  one goes out. Over a nine-style matrix, all eighty-one pairs, 1,703 bytes
  become 1,312, a fifth off, with the reset shorter on 51 pairs and by up to
  34 bytes; over a 200x60 frame of eight runs a row it is 10,978 against
  8,515. Pricing costs a pass: a call that turns nothing off skips it, since
  a reset would then have to restate everything the difference left alone,
  and the rest measure 35 ns against 14 in ReleaseFast. `src/bench.zig`
  budgets the matrix and the frame rather than the old worst case.

- **`Color.eql` is the byte comparison.** Every constructor already zeroes
  the channels its kind does not use, so a colour has one spelling and the
  two relations cannot disagree — which is what the `extern` layout is for:
  a renderer comparing rows of cells with `memcmp` and a renderer comparing
  styles field by field must find the same cells changed. Before this, `eql`
  ignored the unused channels and a test asserted that the two answers
  differed; that test is replaced by one asserting they agree, over every
  colour the constructors can make. A colour written out field by field with
  a stray byte in a channel its kind does not use is now unequal to the
  colour it means, and the doc says so.

- **Every reply parser reads an omitted parameter as its default.** ECMA-48
  says a parameter left out takes its default value, and terminals use that:
  a real DA1 reply is `CSI ? 62 ; 52 ; c`, three parameters with the last
  omitted, and refusing it refused the one reply that ends every startup
  probe. `parseDeviceAttributes`, `parseSecondaryDeviceAttributes`,
  `parseModeReply`, `parseKittyKeyboardReply`, `parseWindowSize`,
  `parseColorSchemeReply` and `parseExtraCursorSupport` default to zero;
  `parseCursorPosition` and `parseExtendedCursorPosition` default to one,
  which is what a cursor report counts from. The separators stay
  compulsory — an empty parameter is a parameter, and a missing `;` is a
  reply of a different shape — and digits that do not fit in the field are
  still a reject rather than a default. The suite carries the DA1, DA2 and
  XTVERSION replies real terminals send, collected off the wire.

- **`KeyParser` tops up its buffer when the buffer empties, not once per
  event.** A top-up moves whatever is unread to the front of the buffer, so
  one per event cost the whole buffer per keypress — and the bigger the
  buffer a caller sized, the slower the parser ran, which is backwards and
  is exactly where the README's advice to size for an OSC 52 reply leads. A
  megabyte of text through a 16 KB buffer read in one go measured 0.4 MB/s
  before and 118.6 MB/s after; the grid of buffer and read sizes reads flat
  now, where it ran from 0.4 MB/s to 140. `src/bench.zig` measures that
  whole grid rather than the one corner of it where the cost could not
  show.

### Fixed

- **`zig build test --fuzz` compiles and runs.** The fuzz targets have
  carried seed corpora and real invariants since 0.2.0 and had never run as
  fuzzers: under `-ffuzz` the shipped test runner hands `@errorReturnTrace()`
  to a function taking the other `StackTrace`, which is a type error at every
  fuzz call site. The test module turns error tracing off, which costs
  nothing a fuzz run wants — the input is the report — and the thirty-one
  targets now search, one corpus each.

- **Three doc comments said things the field does not do.** `unicodeCore`
  said a terminal answering `not_recognized` to mode 2027 measures by
  codepoint; at least one answers that deliberately and clusters by grapheme
  regardless, so the answer is not a capability test and there is none.
  `inBandResize` did not say that the report arrives on being enabled, nor
  that `permanently_reset` is a no as much as `not_recognized` is.
  `queryMode` now gives the only rule that survives contact with real
  terminals: three of the five states mean the mode is there, the other two
  and silence mean it is not, and anything finer is a coin toss.

- **A sequence lying across the end of the buffer is no longer dropped.**
  The drop that exists for a sequence longer than the buffer fired whenever
  the buffer was merely full and the sequence at its head unfinished, which
  the per-event top-up arranged constantly. Ordinary input lost about a
  quarter of its events, and lost them silently.

## [0.4.0] - 2026-09-19

Four protocols on the writing side, the numbers to show what they cost, and
a layout a renderer can put in a cell.

### Breaking

Every one of these is a name or a shape that changed. Nothing depends on this
package yet, so they are fixed now rather than carried.

- **`Color` is an `extern struct`, not a tagged union.** It is a `kind` tag
  and three channel bytes — four bytes, exactly what the union was — because
  `Style` holds three of them and a renderer holds a `Style` in every cell,
  and Zig will not put an auto-layout union inside an `extern struct`. A
  union there would stop a cell being `extern`, which would stop a row of
  cells being compared with `memcmp`, which is the comparison a renderer
  makes most.

  Writing one is shorter than it was, not longer:

  | before | now |
  | --- | --- |
  | `.default` | `.default` |
  | `.{ .ansi = .red }` | `.ansi(.red)` |
  | `.{ .palette = 196 }` | `.palette(196)` |
  | `.{ .rgb = .{ .r = 255, .g = 128, .b = 0 } }` | `.rgb(255, 128, 0)` |

  Reading one changed: `switch (color)` becomes `switch (color.kind)`, and
  the payload comes out through `index()`, `toAnsi()` or `toRgb()`.
  `Color.fromRgb` builds one from what `Rgb16.to8` gives back, and
  `Color.eql` compares two the way the protocol does — the channels of
  anything but an `.rgb` colour are not part of its meaning, so a hand-built
  `.{ .kind = .default, .r = 9 }` is still the default colour and `diffStyle`
  writes nothing for it.

- **`Style` is an `extern struct`**, 22 bytes, aligned to one, with no
  padding. A cell holding one is `extern`; a row of those compares in one
  call. (The `comptime` block that pins those three numbers is not in this
  release; it landed after it, and is in Unreleased above.)

- **`CursorColor` has the same shape**, for the same reason and with the same
  spelling: `.unset`, `.special`, `.rgb(255, 0, 0)`, `.indexed(9)`, read by
  switching on `space`. Its tag values are the protocol's own `COLOR_SPACE`
  numbers, which is why they run 0, 1, 2, 5.

- **Every other record in the package is `extern`** so it can be stored
  wherever a cell or a log entry can: `Rgb`, `Rgb16`, `MouseEvent`, `Resize`,
  `CursorPosition`, `ExtendedCursorPosition`, `CursorCell`, `CursorRect`,
  `Placement` and `GraphicsRect`. No field name or type changed; only the
  layout is now the declared one.

- **`Event` gained a variant**, `color_scheme`. A switch over it that listed
  every case has to be told.

- **`Style` gained a field**, `script`, SGR 73/74/75.

- **`GraphicsResponse` and `parseGraphicsResponse` moved** from `device.zig`
  to `graphics.zig`, beside the commands that provoke them. The names
  `morse.GraphicsResponse` and `morse.parseGraphicsResponse` are unchanged;
  only the file is.

- **`win32.keyFromFields` is no longer public.** Nothing outside its own file
  ever called it.

### Added

- **The kitty graphics protocol, written as well as read.** `transmitImage`
  sends an image — direct, from a file, from a temporary file or from a
  shared memory object, as RGB, RGBA or PNG, deflated or not — and chunks it
  by the protocol's own rule: 3072 bytes of payload per sequence, which is
  exactly 4096 base64 characters, `m=1` on every sequence but the last, and
  no `m` key at all when the whole payload fitted in one. `placeImage` shows
  a transmitted image, with every display key the protocol has — the source
  rectangle, the offsets inside the first cell, the columns and rows, the
  z-index, whether the cursor moves, a virtual placement, and a parent to
  place against. `deleteImage` takes images or placements away, with all
  eleven targets in both spellings: the lowercase that keeps the pixels so
  the picture can come back without being sent again, and the uppercase that
  frees them. `queryGraphics` sends the one-pixel query that says whether the
  terminal implements any of this. `Quiet` is the `q` key — answers, failures
  only, or silence.

  The Unicode placeholder path is here too: `placeholderRow` writes a row of
  U+10EEEE cells with the image id in the foreground colour, the placement id
  in the underline colour, and the row, column and top byte of the id in the
  protocol's combining diacritics; `placeholderCell` writes one cell.
  Together with a virtual placement they put an image on screen through a
  program that knows nothing about graphics but passes text through.

  Animation is not here. `a=f`, `a=a` and `a=c` give `c`, `r`, `z`, `X` and
  `Y` meanings of their own, so the encoder would not be shared by them, only
  shadowed. Neither is the lifecycle above the bytes: which ids are free,
  what has been acknowledged, and what is on screen need state between
  frames, and nothing here keeps any.

- **The colour scheme.** `colorScheme`, mode 2031, asks the terminal to say
  so whenever its palette turns light or dark; `queryColorScheme` writes
  `CSI ? 996 n` to ask once. Either way the answer is `CSI ? 997 ; 1 n` or
  `CSI ? 997 ; 2 n`, which `KeyParser` decodes into a new `Event.color_scheme`
  and `parseColorSchemeReply` reads on its own. It is the one private report
  a terminal sends unasked, which is why it is an event rather than a reply
  to fetch. A program that picked its colours from the background it found on
  startup has had no way until now to hear that the background changed.

- **Text sizing, OSC 66.** `textSize` draws a piece of text at a scale, in a
  stated number of cells, optionally at a fraction of the cell size and
  aligned within it — headings, superscripts, subscripts. The `w` key is the
  half that matters even to a program scaling nothing: it tells the terminal
  how many cells the text occupies, which is the disagreement between program
  and terminal that breaks a drawn interface. Nothing answers this sequence
  and no query asks whether it is implemented; a terminal without it draws
  the text at one size, which still reads correctly.

- **The multiple cursors protocol.** `extraCursors` asks the terminal to draw
  real cursors at cells or over rectangles, so an editor showing the same
  edit in eight places stops faking seven of them out of reverse-video cells
  that do not blink with the real one. `extraCursorsClear` takes them all
  away, `extraCursorColor` sets the pair of colours they share.
  `queryExtraCursorSupport`, `queryExtraCursors` and
  `queryExtraCursorColors` ask what the terminal can do, what is set, and
  what colour it is drawing them in; `parseExtraCursorSupport`,
  `parseExtraCursors` and `parseExtraCursorColors` read the three answers.
  The set-cursors reply carries an unbounded list, so it comes back as an
  iterator over the bytes rather than an array — `ExtraCursors` yields one
  `ExtraCursorAt` per place, flattening the blocks, and drops co-ordinates
  that do not make up a whole cell or rectangle, as the protocol requires of
  a terminal reading the same list.

- **`repeatChar`**, REP. A run of one glyph is the only thing a terminal can
  be told to draw in fewer bytes than the glyphs take: eighty spaces become a
  space and five more bytes. It must follow the glyph immediately, and a
  terminal that does not implement it draws a shorter run rather than a wrong
  one.

- **`iconName`**, OSC 1, the short label shown where a title will not fit.

- **`Style.script`**, SGR 73, 74 and 75: superscript and subscript, diffed
  like every other attribute. One field rather than two flags, because 74
  replaces 73 rather than joining it.

- **`src/bench.zig`**, which measures what the hot paths cost and asserts a
  budget beside each number, so a change that makes one of them
  algorithmically worse fails the build. The byte budgets are exact and the
  same everywhere; the time ceilings are wide, because the suite runs in four
  optimize modes on three operating systems. A megabyte of pixels costs 3,095
  bytes of framing, 0.22% of the payload, and the number is checked against
  the formula rather than against a recorded figure.

### Changed

- **Every number is written by hand rather than through the formatter.**
  `seq.writeInt`, `writeSigned` and `writeHex` fill a stack buffer from the
  back and write the run once. Measured on the machine this was written on,
  the hand encoder is 2.24x in Debug and 1.31x in ReleaseSmall, and **0.92x
  in ReleaseSafe and 0.94x in ReleaseFast — slower**, because the optimiser
  inlines the formatter's own fast path there. Debug and ReleaseSmall are
  where the suite and most development run, and a writer with no comptime
  format machinery in it is a smaller one; that is the whole of the case.
  The suite asserts it stays within half again of the formatter in any
  optimize mode, and that it agrees with the formatter on every value to ten
  thousand and at both ends of the range.

- **The base64 codec moved to `src/base64.zig`**, which the clipboard and the
  graphics transmit now share. It was spelled once and used once before; two
  users is one too many for a copy. No public name changed.

- **`syncOutput` says what it is.** Mode 2026 is a bracket around one frame,
  not a mode to set on entry; it does not nest; and each half goes out as its
  own eight-byte sequence, because at least one terminal matches those eight
  bytes rather than parsing the parameter list. The README block and the
  example now show it around the frame rather than beside `altScreen`, and
  the suite pins both halves and asserts that no writer here ever puts two
  modes in one sequence.

- Every module's doc comment now says what the file will never hold, beside
  what it does.

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

[Unreleased]: https://github.com/pedronaugusto/morse/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/pedronaugusto/morse/releases/tag/v0.4.0
[0.3.0]: https://github.com/pedronaugusto/morse/releases/tag/v0.3.0
[0.2.0]: https://github.com/pedronaugusto/morse/releases/tag/v0.2.0
[0.1.0]: https://github.com/pedronaugusto/morse/releases/tag/v0.1.0
