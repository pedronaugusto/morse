//! The switches a full-screen program throws: DEC private modes, the mouse
//! reporting modes, the kitty keyboard protocol stack, and the shape of the
//! cursor and of the pointer.
//!
//! What this file will never hold: a record of which modes are on. A mode is
//! terminal state, not program state, and the terminal is the thing to ask —
//! `queryMode` does. Nothing here reads a reply either; the parsers live in
//! `device.zig` and `query.zig`, as `parseKittyKeyboardReply` does for the
//! flags `kittyKeyboardPush` writes. The multiple cursors protocol is its own
//! file, `multicursor.zig`, because it has questions and answers of its own.

const std = @import("std");
const seq = @import("seq.zig");

const Writer = std.Io.Writer;

/// Turns any DEC private mode on or off: `CSI ? mode h` or `CSI ? mode l`.
///
/// The named modes below are this function with the number filled in; reach
/// for this one for a mode `morse` does not name.
pub fn setMode(w: *Writer, mode: u16, on: bool) Writer.Error!void {
    try w.writeAll(seq.csi ++ "?");
    try seq.writeInt(w, mode);
    try w.writeByte(if (on) 'h' else 'l');
}

/// One DEC private mode, named and reduced to a single `set` call.
fn PrivateMode(comptime mode_number: u16) type {
    return struct {
        /// The DEC private mode number, ready to hand to `queryMode`.
        pub const number: u16 = mode_number;

        /// Turns the mode on when `on`, and off otherwise.
        pub fn set(w: *Writer, on: bool) Writer.Error!void {
            try setMode(w, mode_number, on);
        }
    };
}

/// The alternate screen buffer, with cursor save and scrollback preserved
/// (mode 1049). On is the full-screen buffer; off restores what the shell
/// had on screen. A program that turns this on must turn it off on every
/// exit path, signals included, or it leaves the user's terminal blank.
pub const altScreen = PrivateMode(1049);

/// Bracketed paste (mode 2004). On, pasted text arrives wrapped in
/// `CSI 200 ~` and `CSI 201 ~`, so a program can tell a paste from typing and
/// refuse to execute it.
pub const bracketedPaste = PrivateMode(2004);

/// Synchronised output (mode 2026). On, the terminal holds the frame it is
/// showing until this is turned off, so a multi-sequence repaint lands in one
/// piece rather than tearing. Unsupported terminals ignore both halves,
/// which is why it is safe to use unconditionally.
///
/// It is a bracket around one frame, not a mode a program sets on entry:
/// `set(w, true)` immediately before the repaint and `set(w, false)`
/// immediately after, every frame. Held on across a whole session it stops
/// the terminal drawing anything; held on across a read it deadlocks a
/// program waiting for a reply it cannot see.
///
/// It does not nest. A second `set(w, true)` inside the bracket is not a
/// second level, and the first `set(w, false)` ends the frame however many
/// were written, so a program that brackets a frame and also brackets a piece
/// of it ends the frame early.
///
/// And it must go out alone. `set` writes exactly `CSI ? 2026 h` or
/// `CSI ? 2026 l` and never joins another mode in one sequence, because at
/// least one terminal matches those eight bytes exactly rather than parsing
/// the parameter list -- so `CSI ? 2026 ; 25 h` would turn nothing on there.
/// Nothing in this file batches modes; `mouse` writes one sequence per mode
/// for the same reason.
pub const syncOutput = PrivateMode(2026);

/// Focus reporting (mode 1004). On, the terminal sends `CSI I` when the
/// window takes focus and `CSI O` when it loses it.
pub const focusEvents = PrivateMode(1004);

/// Cursor visibility, DECTCEM (mode 25). Off hides the block; a program that
/// draws its own cursor turns it off for the duration.
pub const cursorVisible = PrivateMode(25);

/// The Unicode core mode (2027). On, the terminal measures text by grapheme
/// cluster rather than by codepoint, so an emoji with a skin tone modifier
/// occupies the cells it is drawn in rather than the cells each of its
/// codepoints would occupy alone.
///
/// Worth querying rather than setting blind: a program that lays text out
/// itself has to measure it the same way the terminal does, and the two
/// answers differ for exactly the text users complain about. `queryMode`
/// with this number asks.
///
/// What the answer does not tell you is how the terminal measures. At least
/// one terminal answers `not_recognized` to this mode deliberately, because
/// it clusters by grapheme always and has no mode to set — so a `0` here is
/// a terminal that will not be switched, not a terminal measuring by
/// codepoint. The mode is worth setting for the terminals that have it and
/// worth asking about for the record; it is not a capability test, and
/// there is no capability test.
pub const unicodeCore = PrivateMode(2027);

/// In-band resize reporting (mode 2048). On, the terminal sends
/// `CSI 48 ; rows ; cols ; ypixels ; xpixels t` whenever it changes size, and
/// `KeyParser` hands it back as `Event.resize`.
///
/// The point of it is that the answer arrives on the same file descriptor as
/// everything else. A program that learns its size this way needs no signal
/// handler, no `ioctl`, and no file descriptor it can call one on -- so it
/// works unchanged inside a multiplexer, down a pipe, and against a terminal
/// on another machine, all of which are cases where asking the operating
/// system asks the wrong computer.
///
/// The report arrives on being enabled, before anything has resized: a
/// program that turns this on has asked the terminal for its size and will
/// be told, so it need not also ask.
///
/// Newer than the rest of this file and not yet universal, so pair it with
/// `queryMode` or keep whatever size the program already had. A `queryMode`
/// answer of `not_recognized` **or** `permanently_reset` is a terminal
/// without it: the specification gives both as the no, and terminals send
/// both.
pub const inBandResize = PrivateMode(2048);

/// Win32 input mode (mode 9001). On, a terminal on Windows sends every key as
/// `CSI Vk ; Sc ; Uc ; Kd ; Cs ; Rc _` -- the fields of a console key record,
/// in a sequence -- instead of as the byte string the key would otherwise
/// produce, and `KeyParser` decodes it.
///
/// It is what the legacy console cannot say any other way: which physical key
/// was pressed, whether it was going down or coming up, and the modifier
/// state at the time. The keys it disambiguates are the ones that otherwise
/// collide -- control and `[` against Escape, the keypad against the arrows.
///
/// A terminal that does not implement it ignores this, so a program asks for
/// it unconditionally and reads whichever form arrives. `KeyParser` drops the
/// key-up half unless `report_key_up` is set.
pub const win32Input = PrivateMode(9001);

/// Colour scheme reports (mode 2031). On, the terminal sends
/// `CSI ? 997 ; 1 n` when its palette becomes dark and `CSI ? 997 ; 2 n`
/// when it becomes light, unasked, and `KeyParser` hands it back as
/// `Event.color_scheme`.
///
/// It fires whenever the palette changed, not only when the desktop theme
/// did: a user switching terminal profile is the same event. A program that
/// picked its colours from the background it found on startup has no other
/// way to hear that the background is no longer that. `queryColorScheme`
/// asks the same question once.
///
/// Read against the specification text of 2026-08-15.
pub const colorScheme = PrivateMode(2031);

/// Auto-wrap, DECAWM (mode 7). On -- which is the default -- a glyph written
/// in the last column moves the cursor to the start of the next row.
///
/// A full-screen program that paints the bottom-right cell wants this off:
/// with it on, writing that cell scrolls the whole screen up by one row, and
/// there is no sequence that undoes the scroll. Off, the cursor stays put and
/// the glyph lands where it was asked for.
pub const autoWrap = PrivateMode(7);

/// Which mouse reports a program wants: what the pointer reports, and how
/// the report is spelled.
///
/// This is the shape a terminal keeps it in. A terminal holds one motion
/// setting and one encoding setting, not a switch per DEC private mode:
/// turning on 1002 replaces 1000 rather than joining it, and turning off any
/// mode of a setting puts the whole setting back to its default. So the
/// mouse is one motion and one encoding, and there is no value of this type
/// a terminal cannot be in.
///
/// Mouse reports off altogether is not a value of this type but the other
/// call, `mouseOff`: the one state where neither setting means anything.
pub const Mouse = packed struct(u32) {
    /// What the pointer reports.
    motion: Motion,
    /// How each report is spelled. SGR unless there is a reason.
    encoding: Encoding = .sgr,

    /// What the pointer reports, each a superset of the one before. The
    /// values are the DEC private modes that ask for them.
    pub const Motion = enum(u16) {
        /// Button presses and releases, wheel included (mode 1000).
        press = 1000,
        /// That, and motion while a button is held (mode 1002): a drag.
        drag = 1002,
        /// That, and motion with no button held (mode 1003). The noisiest
        /// setting there is: a report per cell the pointer crosses.
        any = 1003,

        /// The DEC private mode that asks for this motion, ready to hand to
        /// `queryMode`.
        pub fn number(m: Motion) u16 {
            return @intFromEnum(m);
        }
    };

    /// How a report is spelled, each one `parseMouse` or `parseMouseRxvt`
    /// reads at any column. The values are the DEC private modes that ask
    /// for them.
    ///
    /// Two encodings a terminal has are not here, and `mouse` turns both off.
    /// The X10 form -- no mode at all, the default a terminal falls back to
    /// -- caps a coordinate at 223 and names no button on a release, and the
    /// UTF-8 form (mode 1005) cannot be framed without knowing it was asked
    /// for.
    pub const Encoding = enum(u16) {
        /// SGR (mode 1006): `CSI < b ; x ; y M`, a release as `m` naming its
        /// button, coordinates in cells with no cap. What `parseMouse` reads.
        sgr = 1006,
        /// The SGR report counting pixels rather than cells (mode 1016).
        /// Byte-identical to `sgr` on the wire, so the program that asked
        /// for it sets `MouseEvent.pixels` and calls `toCells`.
        sgr_pixels = 1016,
        /// The rxvt form (mode 1015): the X10 report spelled in decimal,
        /// uncapped, but a release still names no button. What
        /// `parseMouseRxvt` reads; SGR is the one to ask for.
        rxvt = 1015,

        /// The DEC private mode that asks for this encoding, ready to hand to
        /// `queryMode`.
        pub fn number(e: Encoding) u16 {
            return @intFromEnum(e);
        }
    };
};

/// Every DEC private mode of the motion setting: X10 press-only reporting
/// (9), then 1000, 1002 and 1003. Mode 9 is no `Mouse.Motion` -- it reports a
/// press and nothing else -- but a terminal can be left in it.
const motion_modes = [_]u16{ 9, 1000, 1002, 1003 };

/// Every DEC private mode of the encoding setting: UTF-8 (1005), SGR (1006),
/// rxvt (1015) and SGR pixels (1016).
const encoding_modes = [_]u16{ 1005, 1006, 1015, 1016 };

/// Puts the terminal's mouse in exactly the state `m` names, whatever it was
/// in before.
///
/// Every other mode of each setting goes off first, then the motion and the
/// encoding go on, one `h` each. That is right under both of the ways
/// terminals keep these modes. Most keep one setting each, where any `l`
/// resets the setting and the last `h` is what counts: the offs leave the
/// defaults and the two `h`s replace them. A few keep a flag per mode, where
/// only the offs can clear a mode something earlier left on: after them the
/// two named here are the only flags set. Either way nothing can come after
/// an `h` and undo it, which is what goes wrong when the `h`s and `l`s are
/// written in mode-number order.
///
/// So a program never has to know what was on before, and never asks for
/// press reports without also saying which motion it does not want: a call
/// is the whole mouse.
///
/// Focus reporting is not the mouse and is not touched here: `focusEvents`
/// switches it.
pub fn mouse(w: *Writer, m: Mouse) Writer.Error!void {
    for (motion_modes) |mode| if (mode != m.motion.number()) try setMode(w, mode, false);
    for (encoding_modes) |mode| if (mode != m.encoding.number()) try setMode(w, mode, false);
    try setMode(w, m.motion.number(), true);
    try setMode(w, m.encoding.number(), true);
}

/// Turns mouse reporting off: every mode of the motion setting and of the
/// encoding setting, so the terminal is left reporting nothing and spelling
/// it the default way, whoever turned what on. What a program writes on the
/// way out when it does not know what it turned on; one that does can turn
/// off the motion and the encoding it asked for and nothing else.
pub fn mouseOff(w: *Writer) Writer.Error!void {
    for (motion_modes) |mode| try setMode(w, mode, false);
    for (encoding_modes) |mode| try setMode(w, mode, false);
}

/// The five flags of the kitty keyboard protocol, in the bit order the
/// protocol numbers them: `disambiguate_escape_codes` is bit 1.
pub const KittyFlags = packed struct(u5) {
    /// Report every key as a sequence that cannot be confused with another,
    /// so `Esc` is distinguishable from the start of a sequence (bit 1).
    disambiguate_escape_codes: bool = false,
    /// Report key repeat and key release, not only press (bit 2).
    report_event_types: bool = false,
    /// Report the shifted key and the key at its physical position beside the
    /// logical one (bit 4).
    report_alternate_keys: bool = false,
    /// Report every key as an escape sequence, plain text keys included, so
    /// no keypress arrives as a bare character (bit 8).
    report_all_keys_as_escape_codes: bool = false,
    /// Include the text a key would have produced along with the report
    /// (bit 16).
    report_associated_text: bool = false,

    /// The integer the protocol spells these flags with.
    pub fn bits(flags: KittyFlags) u5 {
        return @bitCast(flags);
    }

    /// The flags a protocol integer stands for.
    pub fn fromBits(value: u5) KittyFlags {
        return @bitCast(value);
    }
};

/// Pushes `flags` onto the terminal's keyboard mode stack: `CSI > flags u`.
///
/// The stack is what makes this safe to use in a program that shells out:
/// push on entry, `kittyKeyboardPop` on exit, and whatever the outer program
/// had set comes back. Terminals without the protocol ignore the sequence.
///
/// The stack belongs to the screen, not to the terminal: the main screen and
/// the alternate screen have one each, so a program that pushes before
/// `altScreen` and pops after it has pushed and popped on different stacks.
/// Push inside the screen the flags are for. It is also finite, and a push
/// onto a full stack throws the oldest entry away rather than failing, so a
/// program that pushes in a loop silently loses the entry it meant to come
/// back to — `kittyKeyboardSet` is the way to change flags without growing
/// the stack at all.
pub fn kittyKeyboardPush(w: *Writer, flags: KittyFlags) Writer.Error!void {
    try w.writeAll(seq.csi ++ ">");
    try seq.writeInt(w, flags.bits());
    try w.writeByte('u');
}

/// Pops one entry off the terminal's keyboard mode stack: `CSI < u`. Undoes
/// exactly one `kittyKeyboardPush`.
///
/// Popping an empty stack is not an error and not a no-op: it clears every
/// flag. A program that pops more than it pushed leaves the terminal with no
/// flags rather than with what it found.
pub fn kittyKeyboardPop(w: *Writer) Writer.Error!void {
    try w.writeAll(seq.csi ++ "<u");
}

/// What `kittyKeyboardSet` does with the flags it is given.
pub const KittyFlagChange = enum(u8) {
    /// The flags in effect become exactly these.
    replace = 1,
    /// The flags named here go on; the rest stay as they are.
    add = 2,
    /// The flags named here go off; the rest stay as they are.
    remove = 3,
};

/// Changes the keyboard flags in effect without touching the stack:
/// `CSI = flags ; how u`.
///
/// The only way to change flags that does not grow a stack, which is why a
/// program that adjusts them more than once wants this and not
/// `kittyKeyboardPush`: the stack is per screen, finite, and unwound only by
/// `kittyKeyboardPop`. Push once on entry and pop once on exit, and use this
/// for everything in between.
///
/// Terminals without the protocol ignore the sequence, and nothing is
/// acknowledged; `kittyKeyboardQuery` asks what is in effect afterwards.
pub fn kittyKeyboardSet(w: *Writer, flags: KittyFlags, how: KittyFlagChange) Writer.Error!void {
    try w.writeAll(seq.csi ++ "=");
    try seq.writeInt(w, flags.bits());
    try w.writeByte(';');
    try seq.writeInt(w, @intFromEnum(how));
    try w.writeByte('u');
}

/// Asks which keyboard flags are currently in effect: `CSI ? u`.
///
/// A terminal that implements the protocol answers `CSI ? flags u`; one that
/// does not answers nothing at all, which is how a program detects support —
/// pair it with DA1 to exercise the input path, then wait for the caller's
/// timeout or explicit quiescence period.
pub fn kittyKeyboardQuery(w: *Writer) Writer.Error!void {
    try w.writeAll(seq.csi ++ "?u");
}

/// One of the resources a terminal keeps for deciding whether to spell a
/// modified key as an escape sequence, numbered as XTMODKEYS numbers them.
///
/// `other_keys` is the one that matters: it is what makes a terminal report
/// control and `i` as something other than a tab, by sending
/// `CSI 27 ; modifiers ; codepoint ~` — which `KeyParser` decodes. The
/// resource is 0 by default, so a program that wants those reports has to
/// ask for them.
pub const ModifyKeys = enum(u8) {
    /// The keyboard as a whole.
    keyboard = 0,
    /// The arrow keys and Home and End.
    cursor_keys = 1,
    /// The function keys.
    function_keys = 2,
    /// The keypad.
    keypad_keys = 3,
    /// Every other key, including the letters and digits: the resource that
    /// turns on `CSI 27 ; modifiers ; codepoint ~`.
    other_keys = 4,
    /// The modifier keys themselves.
    modifier_keys = 6,
    /// The keys with a meaning of their own -- Backspace, Delete, Escape.
    special_keys = 7,
};

/// Sets one of the key-modifying resources: `CSI > resource ; value m`.
///
/// A null `value` writes `CSI > resource m`, which puts that resource back
/// to whatever the terminal started with rather than to zero: there is no
/// other way to say "as I found it", because nothing reports what that was
/// until `queryModifyKeys` is asked.
///
/// For `other_keys` the values are 0, off; 1, report a modified key as a
/// sequence unless it already has a control code; and 2, report every
/// modified key that way. Level 2 is the one a program wanting every chord
/// asks for, and it makes the terminal report control and `c` as a sequence
/// too -- which is a keypress a shell expects to arrive as a byte, so a
/// program that sets it must put it back.
///
/// A terminal that does not implement XTMODKEYS ignores this and answers
/// nothing, which is indistinguishable from one that took it; pair
/// `queryModifyKeys` with DA1 to exercise the input path, and let the caller's
/// timeout or explicit quiescence period decide whether it went unanswered.
pub fn modifyKeys(w: *Writer, resource: ModifyKeys, value: ?u8) Writer.Error!void {
    try w.writeAll(seq.csi ++ ">");
    try seq.writeInt(w, @intFromEnum(resource));
    if (value) |level| {
        try w.writeByte(';');
        try seq.writeInt(w, level);
    }
    try w.writeByte('m');
}

/// Puts every key-modifying resource back to what the terminal started with:
/// `CSI > m`, with no parameters at all.
pub fn modifyKeysReset(w: *Writer) Writer.Error!void {
    try w.writeAll(seq.csi ++ ">m");
}

/// Asks what one of the key-modifying resources is set to: `CSI ? resource m`.
///
/// The answer arrives on the terminal's input as `CSI > resource ; value m`,
/// which `parseModifyKeysReply` reads -- the same shape `modifyKeys` writes,
/// so a program can keep the reply and send it back to restore the state it
/// found.
pub fn queryModifyKeys(w: *Writer, resource: ModifyKeys) Writer.Error!void {
    try w.writeAll(seq.csi ++ "?");
    try seq.writeInt(w, @intFromEnum(resource));
    try w.writeByte('m');
}

/// A cursor shape, in the numbering DECSCUSR uses.
pub const CursorShape = enum(u8) {
    /// Whatever the user configured the terminal to use.
    default = 0,
    /// A blinking block.
    block_blink = 1,
    /// A steady block.
    block = 2,
    /// A blinking underline.
    underline_blink = 3,
    /// A steady underline.
    underline = 4,
    /// A blinking vertical bar.
    bar_blink = 5,
    /// A steady vertical bar.
    bar = 6,
};

/// Sets the cursor shape, DECSCUSR: `CSI shape SP q`.
///
/// The shape is terminal state, not program state: a program that changes it
/// should set `.default` again on the way out.
pub fn cursorShape(w: *Writer, shape: CursorShape) Writer.Error!void {
    try w.writeAll(seq.csi);
    try seq.writeInt(w, @intFromEnum(shape));
    try w.writeAll(" q");
}

/// The shape the mouse pointer takes over the terminal's window, spelled as
/// CSS spells its pointer shapes.
///
/// That vocabulary is the one kitty introduced for OSC 22 and the terminals
/// after it adopted; xterm's OSC 22 names a cursor out of the X cursor font
/// instead, so a name written to xterm matches nothing there and the pointer
/// stays as it was. Nothing is acknowledged and there is no reply to read, so
/// a program cannot find out which of the two happened: write the shape that
/// is right for what is under the pointer and expect some terminals to ignore
/// it.
pub const PointerShape = enum {
    /// The ordinary arrow.
    default,
    /// The I-beam, over text the user can select.
    text,
    /// The hand, over something that acts when clicked — a hyperlink.
    pointer,
    /// The arrow with a question mark.
    help,
    /// The busy pointer, over a program that is not taking input.
    wait,
    /// The arrow with the busy pointer beside it: working, still taking
    /// input.
    progress,
    /// The crosshair, over something positioned rather than pointed at.
    crosshair,
    /// The cell pointer, over a grid a rectangle can be dragged out of.
    cell,
    /// The four-way arrow, over something the drag moves.
    move,
    /// The open hand, over something that can be picked up.
    grab,
    /// The closed hand, while it is being dragged.
    grabbing,
    /// The barred circle, over a target that will refuse the drop.
    not_allowed,
    /// The horizontal resize arrows, over a vertical split bar.
    col_resize,
    /// The vertical resize arrows, over a horizontal split bar.
    row_resize,

    /// The name this shape travels under.
    ///
    /// The tag for every shape whose name is one word, and the hyphenated
    /// spelling for the three that Zig cannot spell as an identifier.
    pub fn name(shape: PointerShape) []const u8 {
        return switch (shape) {
            .not_allowed => "not-allowed",
            .col_resize => "col-resize",
            .row_resize => "row-resize",
            else => @tagName(shape),
        };
    }
};

/// Sets the pointer's shape: `OSC 22 ; name ST`.
///
/// The terminal owns the pointer and knows nothing about what the program
/// drew under it, so a program that draws a hyperlink and wants the hand over
/// it, or a split bar and wants the resize arrows, has no other way to say
/// so.
///
/// Like the cursor's shape, this is terminal state and outlives the program
/// that set it: `pointerShapeReset` belongs on the way out.
pub fn pointerShape(w: *Writer, shape: PointerShape) Writer.Error!void {
    try w.writeAll(seq.osc ++ "22;");
    try w.writeAll(shape.name());
    try w.writeAll(seq.st);
}

/// Puts the pointer back to whatever the terminal draws by default:
/// `OSC 22 ; ST`, the same sequence with an empty name.
///
/// Back to the terminal's default, not to whatever this program found on
/// entry — there is no sequence that reads a pointer shape back, so there is
/// nothing to restore it to.
pub fn pointerShapeReset(w: *Writer) Writer.Error!void {
    try w.writeAll(seq.osc ++ "22;" ++ seq.st);
}

test "a named mode writes h and l" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try altScreen.set(&out.writer, true);
    try altScreen.set(&out.writer, false);
    try std.testing.expectEqualStrings("\x1b[?1049h\x1b[?1049l", out.written());
}

test "every named mode carries the number it documents" {
    try std.testing.expectEqual(@as(u16, 2031), colorScheme.number);
    try std.testing.expectEqual(@as(u16, 2048), inBandResize.number);
    try std.testing.expectEqual(@as(u16, 9001), win32Input.number);
    try std.testing.expectEqual(@as(u16, 7), autoWrap.number);
    try std.testing.expectEqual(@as(u16, 1049), altScreen.number);
    try std.testing.expectEqual(@as(u16, 2004), bracketedPaste.number);
    try std.testing.expectEqual(@as(u16, 2026), syncOutput.number);
    try std.testing.expectEqual(@as(u16, 1004), focusEvents.number);
    try std.testing.expectEqual(@as(u16, 25), cursorVisible.number);
    try std.testing.expectEqual(@as(u16, 2027), unicodeCore.number);
}

test "the named modes write the sequences they document" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try bracketedPaste.set(&out.writer, true);
    try syncOutput.set(&out.writer, true);
    try focusEvents.set(&out.writer, true);
    try cursorVisible.set(&out.writer, false);
    try unicodeCore.set(&out.writer, true);
    try colorScheme.set(&out.writer, true);
    try colorScheme.set(&out.writer, false);
    try std.testing.expectEqualStrings(
        "\x1b[?2004h\x1b[?2026h\x1b[?1004h\x1b[?25l\x1b[?2027h\x1b[?2031h\x1b[?2031l",
        out.written(),
    );
}

test "setMode reaches a mode morse does not name" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try setMode(&out.writer, 7, true);
    try setMode(&out.writer, 65534, false);
    try std.testing.expectEqualStrings("\x1b[?7h\x1b[?65534l", out.written());
}

test "mouse turns every other mode off, then one motion and one encoding on" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try mouse(&out.writer, .{ .motion = .press });
    try std.testing.expectEqualStrings(
        "\x1b[?9l\x1b[?1002l\x1b[?1003l" ++ // the other motions
            "\x1b[?1005l\x1b[?1015l\x1b[?1016l" ++ // the other encodings
            "\x1b[?1000h\x1b[?1006h",
        out.written(),
    );
}

test "mouse writes the drag motion and the pixel encoding the same way" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try mouse(&out.writer, .{ .motion = .drag, .encoding = .sgr_pixels });
    try std.testing.expectEqualStrings(
        "\x1b[?9l\x1b[?1000l\x1b[?1003l" ++
            "\x1b[?1005l\x1b[?1006l\x1b[?1015l" ++
            "\x1b[?1002h\x1b[?1016h",
        out.written(),
    );
}

test "mouseOff turns off every mode of both settings" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try mouseOff(&out.writer);
    try std.testing.expectEqualStrings(
        "\x1b[?9l\x1b[?1000l\x1b[?1002l\x1b[?1003l" ++
            "\x1b[?1005l\x1b[?1006l\x1b[?1015l\x1b[?1016l",
        out.written(),
    );
}

test "the motions and encodings carry the modes they document" {
    try std.testing.expectEqual(@as(u16, 1000), Mouse.Motion.press.number());
    try std.testing.expectEqual(@as(u16, 1002), Mouse.Motion.drag.number());
    try std.testing.expectEqual(@as(u16, 1003), Mouse.Motion.any.number());
    try std.testing.expectEqual(@as(u16, 1006), Mouse.Encoding.sgr.number());
    try std.testing.expectEqual(@as(u16, 1016), Mouse.Encoding.sgr_pixels.number());
    try std.testing.expectEqual(@as(u16, 1015), Mouse.Encoding.rxvt.number());
    try std.testing.expectEqual(Mouse.Encoding.sgr, (Mouse{ .motion = .press }).encoding);
}

/// The two ways a terminal keeps the mouse modes, folded over the bytes
/// `mouse` and `mouseOff` write.
const MouseModel = struct {
    /// One setting each: the last `h` is the motion, and any `l` of a
    /// motion mode puts it back to none -- 0 here. The same for the encoding,
    /// where 0 is the X10 default.
    motion: u16 = 0,
    encoding: u16 = 0,
    /// A flag per mode, each switched by its own `h` and `l` alone, in the
    /// order of `motion_modes` then `encoding_modes`.
    flags: u8 = 0,

    fn flagOf(mode: u16) ?u3 {
        for (motion_modes ++ encoding_modes, 0..) |m, i| if (m == mode) return @intCast(i);
        return null;
    }

    fn isMotion(mode: u16) bool {
        return std.mem.indexOfScalar(u16, &motion_modes, mode) != null;
    }

    fn apply(model: *MouseModel, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len != 0) {
            try std.testing.expect(std.mem.startsWith(u8, rest, seq.csi ++ "?"));
            rest = rest[3..];
            const end = std.mem.indexOfAny(u8, rest, "hl").?;
            const mode = try std.fmt.parseInt(u16, rest[0..end], 10);
            const on = rest[end] == 'h';
            rest = rest[end + 1 ..];

            const bit = @as(u8, 1) << (flagOf(mode) orelse return error.NotAMouseMode);
            if (on) model.flags |= bit else model.flags &= ~bit;
            const setting = if (isMotion(mode)) &model.motion else &model.encoding;
            setting.* = if (on) mode else 0;
        }
    }
};

test "mouse leaves exactly what it names, from any state, under both ways of keeping the modes" {
    // Every state a terminal can have been left in: any subset of the eight
    // modes, turned on in order, which is every one-setting state as well.
    for (0..256) |subset| {
        for (std.enums.values(Mouse.Motion)) |motion| {
            for (std.enums.values(Mouse.Encoding)) |encoding| {
                var before: Writer.Allocating = .init(std.testing.allocator);
                defer before.deinit();
                for (motion_modes ++ encoding_modes, 0..) |mode, i| {
                    if (subset & (@as(usize, 1) << @intCast(i)) != 0) try setMode(&before.writer, mode, true);
                }
                var model: MouseModel = .{};
                try model.apply(before.written());

                var out: Writer.Allocating = .init(std.testing.allocator);
                defer out.deinit();
                try mouse(&out.writer, .{ .motion = motion, .encoding = encoding });
                try model.apply(out.written());

                try std.testing.expectEqual(motion.number(), model.motion);
                try std.testing.expectEqual(encoding.number(), model.encoding);
                const want = (@as(u8, 1) << MouseModel.flagOf(motion.number()).?) |
                    (@as(u8, 1) << MouseModel.flagOf(encoding.number()).?);
                try std.testing.expectEqual(want, model.flags);

                // And off from there is off both ways.
                var off: Writer.Allocating = .init(std.testing.allocator);
                defer off.deinit();
                try mouseOff(&off.writer);
                try model.apply(off.written());
                try std.testing.expectEqual(MouseModel{}, model);
            }
        }
    }
}

test "mouseOff turns the mouse off from any state" {
    for (0..256) |subset| {
        var before: Writer.Allocating = .init(std.testing.allocator);
        defer before.deinit();
        for (motion_modes ++ encoding_modes, 0..) |mode, i| {
            if (subset & (@as(usize, 1) << @intCast(i)) != 0) try setMode(&before.writer, mode, true);
        }
        try mouseOff(&before.writer);
        var model: MouseModel = .{};
        try model.apply(before.written());
        try std.testing.expectEqual(MouseModel{}, model);
    }
}

test "kitty flags are the bits the protocol numbers" {
    try std.testing.expectEqual(@as(u5, 0), (KittyFlags{}).bits());
    try std.testing.expectEqual(@as(u5, 1), (KittyFlags{ .disambiguate_escape_codes = true }).bits());
    try std.testing.expectEqual(@as(u5, 2), (KittyFlags{ .report_event_types = true }).bits());
    try std.testing.expectEqual(@as(u5, 4), (KittyFlags{ .report_alternate_keys = true }).bits());
    try std.testing.expectEqual(@as(u5, 8), (KittyFlags{ .report_all_keys_as_escape_codes = true }).bits());
    try std.testing.expectEqual(@as(u5, 16), (KittyFlags{ .report_associated_text = true }).bits());
}

test "kitty flags round trip through their integer" {
    for (0..32) |value| {
        const bits: u5 = @intCast(value);
        try std.testing.expectEqual(bits, KittyFlags.fromBits(bits).bits());
    }
}

test "the kitty keyboard stack writes push, pop and query" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try kittyKeyboardPush(&out.writer, .{ .disambiguate_escape_codes = true, .report_event_types = true });
    try kittyKeyboardQuery(&out.writer);
    try kittyKeyboardPop(&out.writer);
    try std.testing.expectEqualStrings("\x1b[>3u\x1b[?u\x1b[<u", out.written());
}

test "kittyKeyboardPush with no flags still writes a zero" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try kittyKeyboardPush(&out.writer, .{});
    try std.testing.expectEqualStrings("\x1b[>0u", out.written());
}

test "kittyKeyboardSet writes the flags and the way of applying them" {
    const cases = [_]struct { how: KittyFlagChange, bytes: []const u8 }{
        .{ .how = .replace, .bytes = "\x1b[=5;1u" },
        .{ .how = .add, .bytes = "\x1b[=5;2u" },
        .{ .how = .remove, .bytes = "\x1b[=5;3u" },
    };
    for (cases) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();

        try kittyKeyboardSet(&out.writer, .{
            .disambiguate_escape_codes = true,
            .report_alternate_keys = true,
        }, case.how);
        try std.testing.expectEqualStrings(case.bytes, out.written());
    }
}

test "kittyKeyboardSet with no flags still writes a zero" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try kittyKeyboardSet(&out.writer, .{}, .replace);
    try std.testing.expectEqualStrings("\x1b[=0;1u", out.written());
}

test "kittyKeyboardSet writes every flag combination the five bits can spell" {
    for (0..32) |value| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();

        const flags: KittyFlags = .fromBits(@intCast(value));
        try kittyKeyboardSet(&out.writer, flags, .add);

        var expected: [16]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&expected, "\x1b[={d};2u", .{value});
        try std.testing.expectEqualStrings(bytes, out.written());
    }
}

test "modifyKeys writes the resource and the value it is given" {
    const cases = [_]struct { resource: ModifyKeys, value: ?u8, bytes: []const u8 }{
        .{ .resource = .keyboard, .value = 0, .bytes = "\x1b[>0;0m" },
        .{ .resource = .cursor_keys, .value = 1, .bytes = "\x1b[>1;1m" },
        .{ .resource = .function_keys, .value = 2, .bytes = "\x1b[>2;2m" },
        .{ .resource = .keypad_keys, .value = 1, .bytes = "\x1b[>3;1m" },
        .{ .resource = .other_keys, .value = 2, .bytes = "\x1b[>4;2m" },
        .{ .resource = .modifier_keys, .value = 1, .bytes = "\x1b[>6;1m" },
        .{ .resource = .special_keys, .value = 1, .bytes = "\x1b[>7;1m" },
        // No value at all is the resource back to what the terminal started
        // with, which is a different thing from zero.
        .{ .resource = .other_keys, .value = null, .bytes = "\x1b[>4m" },
    };
    for (cases) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();

        try modifyKeys(&out.writer, case.resource, case.value);
        try std.testing.expectEqualStrings(case.bytes, out.written());
    }
}

test "modifyKeysReset names no resource at all" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try modifyKeysReset(&out.writer);
    try std.testing.expectEqualStrings("\x1b[>m", out.written());
}

test "queryModifyKeys asks with the private marker" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try queryModifyKeys(&out.writer, .other_keys);
    try queryModifyKeys(&out.writer, .keyboard);
    try std.testing.expectEqualStrings("\x1b[?4m\x1b[?0m", out.written());
}

test "every cursor shape writes its DECSCUSR number" {
    const cases = [_]struct { shape: CursorShape, bytes: []const u8 }{
        .{ .shape = .default, .bytes = "\x1b[0 q" },
        .{ .shape = .block_blink, .bytes = "\x1b[1 q" },
        .{ .shape = .block, .bytes = "\x1b[2 q" },
        .{ .shape = .underline_blink, .bytes = "\x1b[3 q" },
        .{ .shape = .underline, .bytes = "\x1b[4 q" },
        .{ .shape = .bar_blink, .bytes = "\x1b[5 q" },
        .{ .shape = .bar, .bytes = "\x1b[6 q" },
    };
    for (cases) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();

        try cursorShape(&out.writer, case.shape);
        try std.testing.expectEqualStrings(case.bytes, out.written());
    }
}

test "every pointer shape writes its CSS name" {
    const cases = [_]struct { shape: PointerShape, bytes: []const u8 }{
        .{ .shape = .default, .bytes = "\x1b]22;default\x1b\\" },
        .{ .shape = .text, .bytes = "\x1b]22;text\x1b\\" },
        .{ .shape = .pointer, .bytes = "\x1b]22;pointer\x1b\\" },
        .{ .shape = .help, .bytes = "\x1b]22;help\x1b\\" },
        .{ .shape = .wait, .bytes = "\x1b]22;wait\x1b\\" },
        .{ .shape = .progress, .bytes = "\x1b]22;progress\x1b\\" },
        .{ .shape = .crosshair, .bytes = "\x1b]22;crosshair\x1b\\" },
        .{ .shape = .cell, .bytes = "\x1b]22;cell\x1b\\" },
        .{ .shape = .move, .bytes = "\x1b]22;move\x1b\\" },
        .{ .shape = .grab, .bytes = "\x1b]22;grab\x1b\\" },
        .{ .shape = .grabbing, .bytes = "\x1b]22;grabbing\x1b\\" },
        .{ .shape = .not_allowed, .bytes = "\x1b]22;not-allowed\x1b\\" },
        .{ .shape = .col_resize, .bytes = "\x1b]22;col-resize\x1b\\" },
        .{ .shape = .row_resize, .bytes = "\x1b]22;row-resize\x1b\\" },
    };
    for (cases) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();

        try pointerShape(&out.writer, case.shape);
        try std.testing.expectEqualStrings(case.bytes, out.written());
    }
}

test "every pointer shape has a name, and only the hyphenated ones differ" {
    // The table above is written out by hand, so the count here is what says
    // it is the whole enum: a shape added and not pinned fails this.
    var seen: usize = 0;
    for (std.enums.values(PointerShape)) |shape| {
        seen += 1;
        try std.testing.expect(shape.name().len != 0);
        // A hyphenated name is not the tag, and a one-word name is.
        const hyphenated = std.mem.indexOfScalar(u8, shape.name(), '-') != null;
        try std.testing.expectEqual(hyphenated, !std.mem.eql(u8, shape.name(), @tagName(shape)));
    }
    try std.testing.expectEqual(@as(usize, 14), seen);
}

test "pointerShapeReset writes the same sequence with an empty name" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try pointerShape(&out.writer, .pointer);
    try pointerShapeReset(&out.writer);
    try std.testing.expectEqualStrings("\x1b]22;pointer\x1b\\\x1b]22;\x1b\\", out.written());
}

test "in-band resize and auto-wrap write their mode numbers" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try inBandResize.set(&out.writer, true);
    try inBandResize.set(&out.writer, false);
    try autoWrap.set(&out.writer, false);
    try autoWrap.set(&out.writer, true);
    try std.testing.expectEqualStrings(
        "\x1b[?2048h\x1b[?2048l\x1b[?7l\x1b[?7h",
        out.written(),
    );
    try std.testing.expectEqual(@as(u16, 2048), inBandResize.number);
    try std.testing.expectEqual(@as(u16, 7), autoWrap.number);
}

test "the synchronised output bracket is exactly eight bytes each way" {
    // A terminal that matches these eight bytes rather than parsing them is
    // the reason `set` never joins another mode in one sequence. Pinned so
    // that a later change cannot shorten, lengthen or combine them.
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try syncOutput.set(&out.writer, true);
    try std.testing.expectEqualStrings("\x1b[?2026h", out.written());
    try std.testing.expectEqual(@as(usize, 8), out.written().len);

    var off: Writer.Allocating = .init(std.testing.allocator);
    defer off.deinit();

    try syncOutput.set(&off.writer, false);
    try std.testing.expectEqualStrings("\x1b[?2026l", off.written());
    try std.testing.expectEqual(@as(usize, 8), off.written().len);
}

test "a frame bracket is two sequences with the frame between them" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try syncOutput.set(&out.writer, true);
    try out.writer.writeAll("frame");
    try syncOutput.set(&out.writer, false);
    try std.testing.expectEqualStrings("\x1b[?2026hframe\x1b[?2026l", out.written());
}

test "no writer here puts two modes in one sequence" {
    // Every mode goes out on its own, whichever call asked for it.
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try mouse(&out.writer, .{ .motion = .press });
    try altScreen.set(&out.writer, true);
    try syncOutput.set(&out.writer, true);
    try setMode(&out.writer, 25, false);

    var rest = out.written();
    var count: usize = 0;
    while (std.mem.indexOf(u8, rest, seq.csi ++ "?")) |at| : (count += 1) {
        const body = rest[at + 3 ..];
        const end = std.mem.indexOfAny(u8, body, "hl").?;
        // One mode number and nothing else: no `;`, no second parameter.
        try std.testing.expect(std.mem.indexOfScalar(u8, body[0..end], ';') == null);
        rest = body[end + 1 ..];
    }
    try std.testing.expectEqual(@as(usize, 11), count);
}
