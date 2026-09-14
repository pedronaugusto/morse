//! The switches a full-screen program throws: DEC private modes, the mouse
//! reporting modes, the kitty keyboard protocol stack, and the cursor shape.

const std = @import("std");
const seq = @import("seq.zig");

const Writer = std.Io.Writer;

/// Turns any DEC private mode on or off: `CSI ? mode h` or `CSI ? mode l`.
///
/// The named modes below are this function with the number filled in; reach
/// for this one for a mode `morse` does not name.
pub fn setMode(w: *Writer, mode: u16, on: bool) Writer.Error!void {
    try w.writeAll(seq.csi ++ "?");
    try w.print("{d}", .{mode});
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
/// answers differ for exactly the text users complain about. `queryMode` with
/// this number is how to find out which one is in effect, and a terminal that
/// answers `not_recognized` is one measuring by codepoint.
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
/// Newer than the rest of this file and not yet universal, so pair it with
/// `queryMode` or keep whatever size the program already had.
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

/// Auto-wrap, DECAWM (mode 7). On -- which is the default -- a glyph written
/// in the last column moves the cursor to the start of the next row.
///
/// A full-screen program that paints the bottom-right cell wants this off:
/// with it on, writing that cell scrolls the whole screen up by one row, and
/// there is no sequence that undoes the scroll. Off, the cursor stays put and
/// the glyph lands where it was asked for.
pub const autoWrap = PrivateMode(7);

/// Which mouse reports a program wants. Every field is one DEC private mode,
/// switched independently by `mouse`.
pub const Mouse = packed struct {
    /// Button press and release reports (mode 1000), wheel included.
    press: bool = false,
    /// Motion reports while a button is held (mode 1002) — drag.
    drag: bool = false,
    /// Motion reports whether or not a button is held (mode 1003). The
    /// noisiest mode there is: a report per cell the pointer crosses.
    any_motion: bool = false,
    /// SGR extended coordinates (mode 1006), which `parseMouse` reads. Any
    /// program wanting coordinates past column 223 needs this.
    sgr: bool = false,
    /// SGR coordinates in pixels rather than cells (mode 1016). Same report
    /// shape as `sgr`; `toCells` converts what comes back.
    sgr_pixels: bool = false,
    /// The rxvt encoding (mode 1015), which `parseMouseRxvt` reads. The X10
    /// report with its three fields spelled in decimal, so it carries a
    /// column past the 223 the biased byte caps at — but a release in it
    /// still names no button, which is why `sgr` is the one to ask for. A
    /// terminal offered both sends SGR.
    rxvt: bool = false,
    /// Focus in and out reports (mode 1004), the same mode as `focusEvents`.
    focus: bool = false,
};

/// Sets every mouse mode at once: each field of `modes` gets its own `h` or
/// `l`, in ascending mode number, so what is asked for goes on and everything
/// else goes off.
///
/// That is the point of taking the whole set rather than one flag: a program
/// wanting press and wheel reports without a report per pointer cell says
/// `.{ .press = true, .sgr = true }` and is not left with mode 1003 still on
/// from some earlier call.
///
/// The same reach is why `Mouse.focus` is here: mode 1004 is also
/// `focusEvents`, and a call that leaves `focus` false turns it off. A program
/// that wants focus reports must say so here, not only through `focusEvents`.
///
/// It is why `Mouse.rxvt` is here too. A program has little reason to ask for
/// mode 1015, but a terminal left in it by something earlier keeps sending
/// rxvt reports until it is told to stop, and a call that could not say `l`
/// for 1015 could not stop it.
pub fn mouse(w: *Writer, modes: Mouse) Writer.Error!void {
    try setMode(w, 1000, modes.press);
    try setMode(w, 1002, modes.drag);
    try setMode(w, 1003, modes.any_motion);
    try setMode(w, 1004, modes.focus);
    try setMode(w, 1006, modes.sgr);
    try setMode(w, 1015, modes.rxvt);
    try setMode(w, 1016, modes.sgr_pixels);
}

/// Turns off every mouse mode `mouse` can turn on. What a program runs on the
/// way out.
pub fn mouseOff(w: *Writer) Writer.Error!void {
    try mouse(w, .{});
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
pub fn kittyKeyboardPush(w: *Writer, flags: KittyFlags) Writer.Error!void {
    try w.writeAll(seq.csi ++ ">");
    try w.print("{d}", .{flags.bits()});
    try w.writeByte('u');
}

/// Pops one entry off the terminal's keyboard mode stack: `CSI < u`. Undoes
/// exactly one `kittyKeyboardPush`.
pub fn kittyKeyboardPop(w: *Writer) Writer.Error!void {
    try w.writeAll(seq.csi ++ "<u");
}

/// Asks which keyboard flags are currently in effect: `CSI ? u`.
///
/// A terminal that implements the protocol answers `CSI ? flags u`; one that
/// does not answers nothing at all, which is how a program detects support —
/// pair it with a query that every terminal answers and see which comes back.
pub fn kittyKeyboardQuery(w: *Writer) Writer.Error!void {
    try w.writeAll(seq.csi ++ "?u");
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
    try w.print("{d}", .{@intFromEnum(shape)});
    try w.writeAll(" q");
}

test "a named mode writes h and l" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try altScreen.set(&out.writer, true);
    try altScreen.set(&out.writer, false);
    try std.testing.expectEqualStrings("\x1b[?1049h\x1b[?1049l", out.written());
}

test "every named mode carries the number it documents" {
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
    try std.testing.expectEqualStrings(
        "\x1b[?2004h\x1b[?2026h\x1b[?1004h\x1b[?25l\x1b[?2027h",
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

test "mouse gives each flag its own h or l" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try mouse(&out.writer, .{ .press = true, .sgr = true });
    try std.testing.expectEqualStrings(
        "\x1b[?1000h\x1b[?1002l\x1b[?1003l\x1b[?1004l\x1b[?1006h\x1b[?1015l\x1b[?1016l",
        out.written(),
    );
}

test "mouseOff turns every mouse mode off" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try mouseOff(&out.writer);
    try std.testing.expectEqualStrings(
        "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1004l\x1b[?1006l\x1b[?1015l\x1b[?1016l",
        out.written(),
    );
}

test "every mouse flag on turns on every mode" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try mouse(&out.writer, .{
        .press = true,
        .drag = true,
        .any_motion = true,
        .sgr = true,
        .sgr_pixels = true,
        .rxvt = true,
        .focus = true,
    });
    try std.testing.expectEqualStrings(
        "\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1004h\x1b[?1006h\x1b[?1015h\x1b[?1016h",
        out.written(),
    );
}

test "mouse can ask for the rxvt encoding, and turns it off otherwise" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    // Mode 1015 on its own: what a program reading `parseMouseRxvt` asks for,
    // and the state a terminal has to be put back out of.
    try mouse(&out.writer, .{ .press = true, .rxvt = true });
    try std.testing.expectEqualStrings(
        "\x1b[?1000h\x1b[?1002l\x1b[?1003l\x1b[?1004l\x1b[?1006l\x1b[?1015h\x1b[?1016l",
        out.written(),
    );
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
