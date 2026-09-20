//! The Windows console keyboard, in the two shapes it reaches a program.
//!
//! A console gives a program keys twice over. A terminal that has been put
//! into win32 input mode (DEC private mode 9001) sends every key as
//! `CSI Vk ; Sc ; Uc ; Kd ; Cs ; Rc _`, which is ordinary input on the
//! ordinary byte stream and is decoded by `KeyParser` like everything else.
//! A program that reads the console directly instead gets `INPUT_RECORD`
//! structures, which are not bytes at all.
//!
//! Both carry the same fields, so both are read through one table here: a
//! virtual-key code, a UTF-16 code unit, and the control-key state.
//!
//! Nothing in this file calls or imports an operating system API. The record
//! types are declared here, field for field, so that the translation compiles
//! and is tested on every platform; a caller reads the real records with
//! whichever API it likes and copies the fields across.
//!
//! What this file will never hold: a console handle. It opens nothing, reads
//! nothing and sets no console mode; `win32Input` writes the sequence that
//! asks for the other shape, and the rest is the caller's.

const std = @import("std");
const corpus = @import("corpus.zig");
const key = @import("key.zig");
const mouse = @import("mouse.zig");

const Key = key.Key;
const KeyEvent = key.KeyEvent;
const Modifiers = key.Modifiers;
const MouseEvent = mouse.MouseEvent;
const Resize = key.Resize;

//=========================================================================
// The control-key state.
//=========================================================================

/// The bits of `dwControlKeyState`, which both shapes carry unchanged.
pub const ControlKeyState = struct {
    /// The right alt key is down. AltGr sets this and both control bits.
    pub const right_alt: u32 = 0x0001;
    /// The left alt key is down.
    pub const left_alt: u32 = 0x0002;
    /// The right control key is down.
    pub const right_ctrl: u32 = 0x0004;
    /// The left control key is down.
    pub const left_ctrl: u32 = 0x0008;
    /// Either shift key is down. The console does not say which.
    pub const shift: u32 = 0x0010;
    /// Num lock is on.
    pub const num_lock: u32 = 0x0020;
    /// Scroll lock is on.
    pub const scroll_lock: u32 = 0x0040;
    /// Caps lock is on.
    pub const caps_lock: u32 = 0x0080;
    /// The key is one of the duplicated navigation or keypad keys.
    pub const enhanced: u32 = 0x0100;
};

/// The modifiers a `dwControlKeyState` stands for.
///
/// Left and right collapse into one flag each, because that is what
/// `Modifiers` says and what every other protocol here reports. The lock
/// states come across as the lock fields, which is where the kitty protocol
/// puts them too. Nothing in this encoding can say super, hyper or meta: the
/// Windows key reaches a console as a key of its own, never as a state.
pub fn modifiers(state: u32) Modifiers {
    return .{
        .shift = state & ControlKeyState.shift != 0,
        .alt = state & (ControlKeyState.left_alt | ControlKeyState.right_alt) != 0,
        .ctrl = state & (ControlKeyState.left_ctrl | ControlKeyState.right_ctrl) != 0,
        .caps_lock = state & ControlKeyState.caps_lock != 0,
        .num_lock = state & ControlKeyState.num_lock != 0,
    };
}

//=========================================================================
// The virtual-key table.
//=========================================================================

/// The key a virtual-key code names, or null when it names none.
///
/// Only the keys that have a name in `Key`. The letters, digits and
/// punctuation are deliberately absent: what those keys produced is in the
/// character field, which the layout has already been applied to, and a table
/// here would be a second opinion about a US keyboard.
pub fn keyFromVirtualKey(vk: u16) ?Key {
    return switch (vk) {
        0x08 => .backspace,
        0x09 => .tab,
        0x0c => .kp_begin, // VK_CLEAR, which is keypad 5 with num lock off
        0x0d => .enter,
        0x13 => .pause,
        0x14 => .caps_lock,
        0x1b => .escape,
        0x20 => .{ .char = ' ' },
        0x21 => .page_up,
        0x22 => .page_down,
        0x23 => .end,
        0x24 => .home,
        0x25 => .left,
        0x26 => .up,
        0x27 => .right,
        0x28 => .down,
        0x2c => .print_screen,
        0x2d => .insert,
        0x2e => .delete,
        0x5b => .left_super,
        0x5c => .right_super,
        0x5d => .menu,
        0x60 => .kp_0,
        0x61 => .kp_1,
        0x62 => .kp_2,
        0x63 => .kp_3,
        0x64 => .kp_4,
        0x65 => .kp_5,
        0x66 => .kp_6,
        0x67 => .kp_7,
        0x68 => .kp_8,
        0x69 => .kp_9,
        0x6a => .kp_multiply,
        0x6b => .kp_add,
        0x6c => .kp_separator,
        0x6d => .kp_subtract,
        0x6e => .kp_decimal,
        0x6f => .kp_divide,
        // VK_F1 through VK_F24, which is further than any other protocol here
        // reaches and still fits the `f` field.
        0x70...0x87 => .{ .f = @intCast(vk - 0x70 + 1) },
        0x90 => .num_lock,
        0x91 => .scroll_lock,
        // The sided modifier keys. `VK_SHIFT`, `VK_CONTROL` and `VK_MENU` are
        // the unsided codes a console sends when it cannot tell, and they
        // come out as the left key, which is the one a keyboard has.
        0x10, 0xa0 => .left_shift,
        0x11, 0xa2 => .left_ctrl,
        0x12, 0xa4 => .left_alt,
        0xa1 => .right_shift,
        0xa3 => .right_ctrl,
        0xa5 => .right_alt,
        0xad => .mute_volume,
        0xae => .lower_volume,
        0xaf => .raise_volume,
        0xb0 => .media_track_next,
        0xb1 => .media_track_previous,
        0xb2 => .media_stop,
        0xb3 => .media_play_pause,
        else => null,
    };
}

/// The key a console key event stands for, with `mods` updated for a control
/// the character field folded a modifier into.
///
/// The character field wins when it holds one, because the layout has already
/// been applied to it: `shift` and `a` arrives as `A`, exactly as it would in
/// a byte stream, and comes out the same key the plain-text path gives. The
/// virtual key is what names a key that produced no character at all — an
/// arrow, a function key, shift held on its own.
///
/// A control code in the character field means the console folded control
/// into it. The virtual key names the key when it can; failing that, a letter
/// or digit virtual key is that letter, so control and `A` is `a` with
/// `Modifiers.ctrl`; failing that, the control code is read the way the
/// legacy path reads the same byte.
///
/// Returns null for a key that stands for nothing — no character, no name.
/// The surrogate halves never reach here: `ConsoleState.key` pairs them
/// first, because neither half is a codepoint on its own.
fn keyFromFields(vk: u16, uc: u16, mods: *Modifiers) ?Key {
    if (uc >= 0x20 and uc != 0x7f) return .{ .char = uc };
    if (keyFromVirtualKey(vk)) |named| return named;
    if (vk >= '0' and vk <= '9') return .{ .char = @intCast(vk) };
    if (vk >= 'A' and vk <= 'Z') return .{ .char = @as(u21, @intCast(vk)) + ('a' - 'A') };
    if (uc != 0) return key.asciiKey(@intCast(uc), mods);
    return null;
}

/// The high half of a UTF-16 surrogate pair.
fn isHighSurrogate(unit: u16) bool {
    return unit >= 0xd800 and unit <= 0xdbff;
}

/// The low half of a UTF-16 surrogate pair.
fn isLowSurrogate(unit: u16) bool {
    return unit >= 0xdc00 and unit <= 0xdfff;
}

/// A virtual key that is one of the Alt keys.
fn isAltKey(vk: u16) bool {
    return vk == 0x12 or vk == 0xa4 or vk == 0xa5;
}

/// What one console key record turned out to be.
pub const ConsoleKey = union(enum) {
    /// A key.
    key: KeyEvent,
    /// The record was understood and produced no key yet: half a surrogate
    /// pair waiting for the other half, or a keypad digit being composed
    /// into a character with Alt held.
    held,
    /// Not a key this package can name.
    unknown,
};

/// What a console keyboard has to remember between records.
///
/// One field, and it is there because a console sends a character outside
/// the basic multilingual plane as two records, each carrying half a UTF-16
/// surrogate pair. Neither half is a codepoint, so neither is a key; held
/// together they are one.
///
/// `KeyParser` keeps one of these for the sequences mode 9001 sends, and
/// `ConsoleDecoder` keeps one for the records a program reads itself. Both
/// shapes carry the same fields and both need the same memory.
pub const ConsoleState = struct {
    /// The high half of a surrogate pair, waiting for its low half. Dropped
    /// the moment anything else arrives, because a pair that is not
    /// consecutive is not a pair.
    high_surrogate: ?u16 = null,
    /// Whether the pending high half arrived as a character composed on an
    /// Alt key-up record and must therefore become a press when completed.
    high_surrogate_is_alt_composed: bool = false,

    /// Forgets a half-arrived character. What a program calls when the
    /// console has been reset underneath it.
    pub fn reset(st: *ConsoleState) void {
        st.high_surrogate = null;
        st.high_surrogate_is_alt_composed = false;
    }

    /// One key event, from either shape, as a `KeyEvent`.
    ///
    /// `down` chooses `Kind.press` or `Kind.release`. The text is set from
    /// the character field on the same terms as the rest of the package:
    /// what the terminal said the key produced, and nothing when a modifier
    /// other than shift means the key produced a control code rather than
    /// text.
    ///
    /// Three things a console does that no other keyboard protocol does are
    /// handled here. A character outside the basic plane arrives as two
    /// records and is paired. A character composed by holding Alt and typing
    /// digits on the keypad arrives on the Alt key **coming up**, with the
    /// keypad digits themselves carrying nothing, so those are held and the
    /// character is reported as a press. And AltGr sets the right-Alt bit
    /// and a control bit together, which is indistinguishable from control
    /// and alt except that it also produced a character — so a record with
    /// right Alt, a control bit and a character of its own is reported as
    /// the character, with neither modifier.
    pub fn decode(st: *ConsoleState, vk: u16, uc: u16, control_key_state: u32, down: bool) ConsoleKey {
        const alt_down = control_key_state &
            (ControlKeyState.left_alt | ControlKeyState.right_alt) != 0;
        const ctrl_down = control_key_state &
            (ControlKeyState.left_ctrl | ControlKeyState.right_ctrl) != 0;

        // The composed character, on the way up. It has to be read before
        // the key-up half is dropped, which is the reason it was missed:
        // nothing else a program wants arrives on a key release.
        if (!down and isAltKey(vk) and uc != 0 and !isHighSurrogate(uc) and !isLowSurrogate(uc)) {
            st.high_surrogate = null;
            st.high_surrogate_is_alt_composed = false;
            var ev: KeyEvent = .{ .key = .{ .char = uc }, .kind = .press };
            var utf8: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(@intCast(uc), &utf8) catch 0;
            if (n != 0) key.setText(&ev, utf8[0..n]);
            return .{ .key = ev };
        }

        // A keypad digit with Alt held and nothing else is one digit of that
        // composition, not a keypress of its own. Alt and nothing else:
        // control or shift alongside it makes a chord, which is reported.
        const shift_down = control_key_state & ControlKeyState.shift != 0;
        if (down and alt_down and !ctrl_down and !shift_down and
            vk >= 0x60 and vk <= 0x69 and uc == 0)
        {
            return .held;
        }

        var unit = uc;
        if (isHighSurrogate(unit)) {
            st.high_surrogate = unit;
            st.high_surrogate_is_alt_composed = !down and isAltKey(vk);
            return .held;
        }
        if (isLowSurrogate(unit)) {
            const high = st.high_surrogate orelse {
                st.high_surrogate_is_alt_composed = false;
                return .held;
            };
            const alt_composed = st.high_surrogate_is_alt_composed;
            st.high_surrogate = null;
            st.high_surrogate_is_alt_composed = false;
            const cp = 0x10000 +
                ((@as(u21, high) - 0xd800) << 10) +
                (@as(u21, unit) - 0xdc00);
            var ev: KeyEvent = .{
                .key = .{ .char = cp },
                .mods = if (alt_composed) .{} else modifiers(control_key_state),
                .kind = if (alt_composed or down) .press else .release,
            };
            var utf8: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &utf8) catch 0;
            if (n != 0) key.setText(&ev, utf8[0..n]);
            return .{ .key = ev };
        }
        // Anything that is not a low surrogate ends a pair that never
        // finished.
        st.high_surrogate = null;
        st.high_surrogate_is_alt_composed = false;

        var mods = modifiers(control_key_state);

        // AltGr, which the console cannot spell any other way. The codepoint
        // is what tells it from control and alt: a chord produces no
        // character, and a layout's third level does.
        if (control_key_state & ControlKeyState.right_alt != 0 and ctrl_down and
            unit >= 0x20 and unit != 0x7f)
        {
            mods.alt = false;
            mods.ctrl = false;
        }

        const which = keyFromFields(vk, unit, &mods) orelse return .unknown;
        unit = uc;

        var ev: KeyEvent = .{
            .key = which,
            .mods = mods,
            .kind = if (down) .press else .release,
        };
        if (unit >= 0x20 and unit != 0x7f) {
            var utf8: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(@intCast(unit), &utf8) catch 0;
            if (n != 0) key.setText(&ev, utf8[0..n]);
        }
        return .{ .key = ev };
    }
};

//=========================================================================
// Console input records.
//=========================================================================

/// A `KEY_EVENT_RECORD`, field for field.
///
/// Declared here rather than imported so that this translation compiles and
/// is tested everywhere. A caller reads the real record with the API of its
/// choice and copies the fields across; the names are the record's own.
pub const ConsoleKeyRecord = struct {
    /// `bKeyDown`. False is the key coming up.
    key_down: bool = false,
    /// `wRepeatCount`. How many times the key press this record stands for
    /// happened; auto-repeat is what makes it more than one.
    repeat_count: u16 = 1,
    /// `wVirtualKeyCode`.
    virtual_key_code: u16 = 0,
    /// `wVirtualScanCode`. Carried for completeness; nothing here reads it,
    /// because it names a position on a keyboard rather than a key.
    virtual_scan_code: u16 = 0,
    /// `uChar.UnicodeChar`, one UTF-16 code unit.
    unicode_char: u16 = 0,
    /// `dwControlKeyState`.
    control_key_state: u32 = 0,
};

/// A `MOUSE_EVENT_RECORD`, field for field.
pub const ConsoleMouseRecord = struct {
    /// `dwMousePosition.X`, a column counted from zero.
    x: u16 = 0,
    /// `dwMousePosition.Y`, a row counted from zero.
    y: u16 = 0,
    /// `dwButtonState`. The low word is which buttons are down; the high word
    /// is a signed wheel distance when `event_flags` says the wheel moved.
    button_state: u32 = 0,
    /// `dwControlKeyState`, the same bits a key record carries.
    control_key_state: u32 = 0,
    /// `dwEventFlags`.
    event_flags: u32 = 0,

    /// `dwButtonState`: the leftmost button.
    pub const button_1: u32 = 0x0001;
    /// `dwButtonState`: the rightmost button.
    pub const button_2: u32 = 0x0002;
    /// `dwButtonState`: the second button from the left, usually the middle.
    pub const button_3: u32 = 0x0004;
    /// `dwButtonState`: the third button from the left.
    pub const button_4: u32 = 0x0008;
    /// `dwButtonState`: the fourth button from the left.
    pub const button_5: u32 = 0x0010;

    /// `dwEventFlags`: the pointer moved.
    pub const moved: u32 = 0x0001;
    /// `dwEventFlags`: the second click of a double click.
    pub const double_click: u32 = 0x0002;
    /// `dwEventFlags`: the vertical wheel turned.
    pub const wheeled: u32 = 0x0004;
    /// `dwEventFlags`: the horizontal wheel turned.
    pub const hwheeled: u32 = 0x0008;
};

/// A `WINDOW_BUFFER_SIZE_RECORD`: the new size of the screen buffer, in
/// characters.
pub const ConsoleSizeRecord = struct {
    /// `dwSize.X`.
    cols: u16 = 0,
    /// `dwSize.Y`.
    rows: u16 = 0,
};

/// One `INPUT_RECORD`, as the union its `EventType` selects.
pub const ConsoleRecord = union(enum) {
    /// `KEY_EVENT`.
    key: ConsoleKeyRecord,
    /// `MOUSE_EVENT`.
    mouse: ConsoleMouseRecord,
    /// `WINDOW_BUFFER_SIZE_EVENT`.
    window_buffer_size: ConsoleSizeRecord,
    /// `MENU_EVENT` and `FOCUS_EVENT`, which Windows documents as internal
    /// and a program is told to ignore.
    other,
};

/// What a console record turned out to be.
///
/// Three of the things `morse` already models. It is not `key.Event`, because
/// a console reports the mouse as a record rather than as a sequence the key
/// parser has to hand back undecoded.
pub const ConsoleEvent = union(enum) {
    /// A key went down or came up.
    key: KeyEvent,
    /// The mouse moved, or a button or wheel did.
    mouse: MouseEvent,
    /// The screen buffer changed size.
    resize: Resize,
};

/// Console input records turned into events, one at a time.
///
/// It keeps the little state a console keyboard needs — see `ConsoleState` —
/// which is why it is a value and not a function: a character outside the
/// basic plane and a character composed with Alt and the keypad each arrive
/// as more than one record, and nothing can pair them without remembering
/// the first.
///
/// No allocation, no call into an operating system, and no console handle.
/// Read the records with `ReadConsoleInputW` or whatever wrapper you prefer,
/// copy each one into a `ConsoleRecord`, and hand it to `next`.
pub const ConsoleDecoder = struct {
    /// What a half-arrived character is held in.
    state: ConsoleState = .{},
    /// The buttons held after the last mouse record, so a record can name
    /// the button that changed while another remains down.
    mouse_buttons: u16 = 0,
    /// Report the key coming up as well as going down. The console reports
    /// both, and a program that wants only what was typed wants only the
    /// downs.
    ///
    /// The character composed with Alt and the keypad is reported either
    /// way: it rides a key-up record, but what it is is a keypress, so it
    /// comes out as one.
    report_key_up: bool = false,

    /// Forgets half-arrived keyboard and mouse state. What a program calls
    /// after the console has been reset underneath it.
    pub fn reset(d: *ConsoleDecoder) void {
        d.state.reset();
        d.mouse_buttons = 0;
    }

    /// The event one record stands for, or null.
    ///
    /// Null for a record that stands for nothing a program acts on: a menu
    /// or focus record, a key event that names no key, half of a character
    /// still waiting for the rest of itself, and the key coming up unless
    /// `report_key_up` is set.
    ///
    /// `repeat_count` is not expanded here. One record can stand for several
    /// keypresses, and the field is on the record for a caller to read.
    pub fn next(d: *ConsoleDecoder, record: ConsoleRecord) ?ConsoleEvent {
        switch (record) {
            .key => |r| {
                const ev = switch (d.state.decode(
                    r.virtual_key_code,
                    r.unicode_char,
                    r.control_key_state,
                    r.key_down,
                )) {
                    .key => |ev| ev,
                    .held, .unknown => return null,
                };
                if (ev.kind == .release and !d.report_key_up) return null;
                return .{ .key = ev };
            },
            .mouse => |r| {
                const ev = mouseEvent(r, d.mouse_buttons);
                d.mouse_buttons = @truncate(r.button_state);
                return .{ .mouse = ev };
            },
            .window_buffer_size => |r| return .{ .resize = .{
                .rows = r.rows,
                .cols = r.cols,
            } },
            .other => return null,
        }
    }
};

/// The mouse report a `MOUSE_EVENT_RECORD` stands for.
///
/// Coordinates come across counted from one, which is where every other mouse
/// report in this package counts from; a console counts from zero. Cells, not
/// pixels: a console has no pixels.
fn mouseEvent(r: ConsoleMouseRecord, previous_buttons: u16) MouseEvent {
    // The wheel distance is a signed count in the high word, positive away
    // from the user and to the right.
    const distance: i16 = @bitCast(@as(u16, @truncate(r.button_state >> 16)));
    const mods = modifiers(r.control_key_state);

    var ev: MouseEvent = .{
        .button = .none,
        .x = @as(u32, r.x) + 1,
        .y = @as(u32, r.y) + 1,
        .press = false,
        .motion = r.event_flags & ConsoleMouseRecord.moved != 0,
        .shift = mods.shift,
        .alt = mods.alt,
        .ctrl = mods.ctrl,
    };

    if (r.event_flags & ConsoleMouseRecord.wheeled != 0) {
        ev.button = if (distance < 0) .wheel_down else .wheel_up;
        ev.press = true;
        return ev;
    }
    if (r.event_flags & ConsoleMouseRecord.hwheeled != 0) {
        ev.button = if (distance < 0) .wheel_left else .wheel_right;
        ev.press = true;
        return ev;
    }

    const buttons: u16 = @truncate(r.button_state);
    const changed = buttons ^ previous_buttons;
    // A button record names the bit that changed, not merely the lowest bit
    // still down. Motion and double-click records describe the buttons that
    // are held instead.
    const reported = if (r.event_flags == 0 and changed != 0) changed else buttons;
    if (reported & ConsoleMouseRecord.button_1 != 0) {
        ev.button = .left;
    } else if (reported & ConsoleMouseRecord.button_3 != 0) {
        ev.button = .middle;
    } else if (reported & ConsoleMouseRecord.button_2 != 0) {
        ev.button = .right;
    } else if (reported & ConsoleMouseRecord.button_4 != 0) {
        ev.button = .button_8;
    } else if (reported & ConsoleMouseRecord.button_5 != 0) {
        ev.button = .button_9;
    }
    ev.press = reported & buttons != 0;
    return ev;
}

/// One record through a decoder of its own, for a test about a single
/// record. A character that takes two records needs a decoder that lives
/// across both, and those tests make one.
fn oneRecord(record: ConsoleRecord, key_up: bool) ?ConsoleEvent {
    var decoder: ConsoleDecoder = .{ .report_key_up = key_up };
    return decoder.next(record);
}

test "a key record comes through as the key it names" {
    const record: ConsoleRecord = .{ .key = .{
        .key_down = true,
        .virtual_key_code = 0x25,
        .virtual_scan_code = 0x4b,
    } };
    const event = oneRecord(record, false).?;
    try std.testing.expectEqual(Key.left, event.key.key);
    try std.testing.expectEqual(key.Kind.press, event.key.kind);
    try std.testing.expectEqual(Modifiers{}, event.key.mods);
    try std.testing.expectEqualStrings("", event.key.text());
}

test "a key record carries the character the layout produced" {
    const lower = oneRecord(.{ .key = .{
        .key_down = true,
        .virtual_key_code = 'A',
        .unicode_char = 'a',
    } }, false).?;
    try std.testing.expectEqual(Key{ .char = 'a' }, lower.key.key);
    try std.testing.expectEqualStrings("a", lower.key.text());

    const upper = oneRecord(.{ .key = .{
        .key_down = true,
        .virtual_key_code = 'A',
        .unicode_char = 'A',
        .control_key_state = ControlKeyState.shift,
    } }, false).?;
    try std.testing.expectEqual(Key{ .char = 'A' }, upper.key.key);
    try std.testing.expect(upper.key.mods.shift);
    try std.testing.expectEqualStrings("A", upper.key.text());

    // Control and A: the console folds the modifier into the character, and
    // the key comes back as the letter with the modifier beside it.
    const control = oneRecord(.{ .key = .{
        .key_down = true,
        .virtual_key_code = 'A',
        .unicode_char = 1,
        .control_key_state = ControlKeyState.left_ctrl,
    } }, false).?;
    try std.testing.expectEqual(Key{ .char = 'a' }, control.key.key);
    try std.testing.expect(control.key.mods.ctrl);
    try std.testing.expectEqualStrings("", control.key.text());
}

test "a key record coming up is dropped unless it is asked for" {
    const up: ConsoleRecord = .{ .key = .{
        .key_down = false,
        .virtual_key_code = 0x25,
    } };
    try std.testing.expectEqual(@as(?ConsoleEvent, null), oneRecord(up, false));

    const seen = oneRecord(up, true).?;
    try std.testing.expectEqual(Key.left, seen.key.key);
    try std.testing.expectEqual(key.Kind.release, seen.key.kind);
}

test "a key record that names no key at all is null" {
    // A record with no virtual key and no character: what a console sends
    // when a modifier is released on some keyboards.
    try std.testing.expectEqual(@as(?ConsoleEvent, null), oneRecord(.{ .key = .{
        .key_down = true,
    } }, false));

    // Half a surrogate pair is not a codepoint, and pairing is the caller's.
    try std.testing.expectEqual(@as(?ConsoleEvent, null), oneRecord(.{ .key = .{
        .key_down = true,
        .unicode_char = 0xd83d,
    } }, false));
    try std.testing.expectEqual(@as(?ConsoleEvent, null), oneRecord(.{ .key = .{
        .key_down = true,
        .unicode_char = 0xde00,
    } }, false));
}

test "a record keeps its repeat count for the caller to read" {
    const record: ConsoleKeyRecord = .{
        .key_down = true,
        .virtual_key_code = 'A',
        .unicode_char = 'a',
        .repeat_count = 4,
    };
    // The translation is per record, so the count is left where it was.
    const event = oneRecord(.{ .key = record }, false).?;
    try std.testing.expectEqual(Key{ .char = 'a' }, event.key.key);
    try std.testing.expectEqual(@as(u16, 4), record.repeat_count);
}

test "the control-key state becomes the modifiers, in every combination" {
    const bits = [_]u32{
        ControlKeyState.shift,
        ControlKeyState.left_alt,
        ControlKeyState.left_ctrl,
    };
    for (0..8) |combination| {
        var state: u32 = 0;
        for (bits, 0..) |bit, i| {
            if (combination & (@as(usize, 1) << @intCast(i)) != 0) state |= bit;
        }
        const mods = modifiers(state);
        try std.testing.expectEqual(combination & 1 != 0, mods.shift);
        try std.testing.expectEqual(combination & 2 != 0, mods.alt);
        try std.testing.expectEqual(combination & 4 != 0, mods.ctrl);
        try std.testing.expect(!mods.super and !mods.hyper and !mods.meta);
    }
}

test "the sided modifier bits collapse, and the locks come through" {
    try std.testing.expect(modifiers(ControlKeyState.right_alt).alt);
    try std.testing.expect(modifiers(ControlKeyState.right_ctrl).ctrl);
    try std.testing.expect(modifiers(ControlKeyState.caps_lock).caps_lock);
    try std.testing.expect(modifiers(ControlKeyState.num_lock).num_lock);

    // Scroll lock and the enhanced-key bit have no field, and inventing one
    // would be a modifier the program never sees from any other terminal.
    try std.testing.expectEqual(Modifiers{}, modifiers(ControlKeyState.scroll_lock));
    try std.testing.expectEqual(Modifiers{}, modifiers(ControlKeyState.enhanced));
}

test "a mouse record counts from one, as every other report here does" {
    const press = oneRecord(.{ .mouse = .{
        .x = 0,
        .y = 0,
        .button_state = ConsoleMouseRecord.button_1,
    } }, false).?;
    try std.testing.expectEqual(mouse.Button.left, press.mouse.button);
    try std.testing.expectEqual(@as(u32, 1), press.mouse.x);
    try std.testing.expectEqual(@as(u32, 1), press.mouse.y);
    try std.testing.expect(press.mouse.press and !press.mouse.motion);
    try std.testing.expect(!press.mouse.pixels);

    const far = oneRecord(.{ .mouse = .{ .x = 65535, .y = 65535 } }, false).?;
    try std.testing.expectEqual(@as(u32, 65536), far.mouse.x);
    try std.testing.expectEqual(@as(u32, 65536), far.mouse.y);
}

test "a mouse record names the button that is down, and none on a release" {
    const cases = [_]struct { state: u32, button: mouse.Button }{
        .{ .state = ConsoleMouseRecord.button_1, .button = .left },
        .{ .state = ConsoleMouseRecord.button_2, .button = .right },
        .{ .state = ConsoleMouseRecord.button_3, .button = .middle },
        .{ .state = ConsoleMouseRecord.button_4, .button = .button_8 },
        .{ .state = ConsoleMouseRecord.button_5, .button = .button_9 },
    };
    for (cases) |case| {
        const event = oneRecord(.{ .mouse = .{ .button_state = case.state } }, false).?;
        try std.testing.expectEqual(case.button, event.mouse.button);
        try std.testing.expect(event.mouse.press);
    }

    // A decoder that did not see the press has no previous bit to name.
    const release = oneRecord(.{ .mouse = .{} }, false).?;
    try std.testing.expectEqual(mouse.Button.none, release.mouse.button);
    try std.testing.expect(!release.mouse.press);
}

test "mouse button transitions name the button that changed" {
    var decoder: ConsoleDecoder = .{};

    const left = decoder.next(.{ .mouse = .{
        .button_state = ConsoleMouseRecord.button_1,
    } }).?;
    try std.testing.expectEqual(mouse.Button.left, left.mouse.button);
    try std.testing.expect(left.mouse.press);

    const right = decoder.next(.{ .mouse = .{
        .button_state = ConsoleMouseRecord.button_1 | ConsoleMouseRecord.button_2,
    } }).?;
    try std.testing.expectEqual(mouse.Button.right, right.mouse.button);
    try std.testing.expect(right.mouse.press);

    const released = decoder.next(.{ .mouse = .{
        .button_state = ConsoleMouseRecord.button_1,
    } }).?;
    try std.testing.expectEqual(mouse.Button.right, released.mouse.button);
    try std.testing.expect(!released.mouse.press);
}

test "a mouse record says when the pointer moved" {
    const drag = oneRecord(.{ .mouse = .{
        .button_state = ConsoleMouseRecord.button_1,
        .event_flags = ConsoleMouseRecord.moved,
    } }, false).?;
    try std.testing.expect(drag.mouse.motion and drag.mouse.press);
    try std.testing.expectEqual(mouse.Button.left, drag.mouse.button);

    const hover = oneRecord(.{ .mouse = .{
        .event_flags = ConsoleMouseRecord.moved,
    } }, false).?;
    try std.testing.expect(hover.mouse.motion and !hover.mouse.press);
    try std.testing.expectEqual(mouse.Button.none, hover.mouse.button);
}

test "a mouse record turns the wheel distance into a direction" {
    // The distance is signed and lives in the high word: 120 away from the
    // user, -120 towards.
    const up = oneRecord(.{ .mouse = .{
        .button_state = 0x0078_0000,
        .event_flags = ConsoleMouseRecord.wheeled,
    } }, false).?;
    try std.testing.expectEqual(mouse.Button.wheel_up, up.mouse.button);
    try std.testing.expect(up.mouse.press);

    const down = oneRecord(.{ .mouse = .{
        .button_state = 0xff88_0000,
        .event_flags = ConsoleMouseRecord.wheeled,
    } }, false).?;
    try std.testing.expectEqual(mouse.Button.wheel_down, down.mouse.button);

    const right = oneRecord(.{ .mouse = .{
        .button_state = 0x0078_0000,
        .event_flags = ConsoleMouseRecord.hwheeled,
    } }, false).?;
    try std.testing.expectEqual(mouse.Button.wheel_right, right.mouse.button);

    const left = oneRecord(.{ .mouse = .{
        .button_state = 0xff88_0000,
        .event_flags = ConsoleMouseRecord.hwheeled,
    } }, false).?;
    try std.testing.expectEqual(mouse.Button.wheel_left, left.mouse.button);
}

test "a mouse record carries the modifiers that were held" {
    const event = oneRecord(.{ .mouse = .{
        .button_state = ConsoleMouseRecord.button_1,
        .control_key_state = ControlKeyState.shift | ControlKeyState.left_ctrl,
    } }, false).?;
    try std.testing.expect(event.mouse.shift and event.mouse.ctrl and !event.mouse.alt);
}

test "a window buffer size record is a resize in characters" {
    const event = oneRecord(.{ .window_buffer_size = .{
        .cols = 80,
        .rows = 24,
    } }, false).?;
    try std.testing.expectEqual(@as(u32, 24), event.resize.rows);
    try std.testing.expectEqual(@as(u32, 80), event.resize.cols);
    // A console has no pixels to report.
    try std.testing.expectEqual(@as(u32, 0), event.resize.xpixels);
    try std.testing.expectEqual(@as(u32, 0), event.resize.ypixels);
}

test "a record that stands for nothing a program acts on is null" {
    try std.testing.expectEqual(@as(?ConsoleEvent, null), oneRecord(.other, false));
    try std.testing.expectEqual(@as(?ConsoleEvent, null), oneRecord(.other, true));
}

test "every virtual key this package names maps to one key and back" {
    // No two virtual keys that name different keys collide, and the unsided
    // codes land on the left-hand key.
    try std.testing.expectEqual(Key.left_shift, keyFromVirtualKey(0x10).?);
    try std.testing.expectEqual(Key.left_shift, keyFromVirtualKey(0xa0).?);
    try std.testing.expectEqual(Key.right_shift, keyFromVirtualKey(0xa1).?);
    try std.testing.expectEqual(Key{ .f = 1 }, keyFromVirtualKey(0x70).?);
    try std.testing.expectEqual(Key{ .f = 24 }, keyFromVirtualKey(0x87).?);
    try std.testing.expectEqual(Key.kp_0, keyFromVirtualKey(0x60).?);
    try std.testing.expectEqual(Key.kp_9, keyFromVirtualKey(0x69).?);

    // The letters and digits are deliberately absent: the character field
    // says what they produced.
    try std.testing.expectEqual(@as(?Key, null), keyFromVirtualKey('A'));
    try std.testing.expectEqual(@as(?Key, null), keyFromVirtualKey('0'));
    try std.testing.expectEqual(@as(?Key, null), keyFromVirtualKey(0));
    try std.testing.expectEqual(@as(?Key, null), keyFromVirtualKey(0xffff));
}

test "a record pairs the halves of a character outside the basic plane" {
    var decoder: ConsoleDecoder = .{};

    // The high half alone is not a codepoint and not a key.
    try std.testing.expectEqual(@as(?ConsoleEvent, null), decoder.next(.{ .key = .{
        .key_down = true,
        .unicode_char = 0xd83d,
    } }));

    const paired = decoder.next(.{ .key = .{
        .key_down = true,
        .unicode_char = 0xde42,
    } }).?;
    try std.testing.expectEqual(Key{ .char = 0x1f642 }, paired.key.key);
    try std.testing.expectEqualStrings("\u{1f642}", paired.key.text());

    // A half that never finds its other is dropped when anything else
    // arrives, rather than joining the next character.
    try std.testing.expectEqual(@as(?ConsoleEvent, null), decoder.next(.{ .key = .{
        .key_down = true,
        .unicode_char = 0xd83d,
    } }));
    const after = decoder.next(.{ .key = .{
        .key_down = true,
        .virtual_key_code = 'A',
        .unicode_char = 'a',
    } }).?;
    try std.testing.expectEqual(Key{ .char = 'a' }, after.key.key);

    // And a low half with nothing in front of it is nothing.
    try std.testing.expectEqual(@as(?ConsoleEvent, null), decoder.next(.{ .key = .{
        .key_down = true,
        .unicode_char = 0xde42,
    } }));

    // `reset` forgets a half-arrived character.
    try std.testing.expectEqual(@as(?ConsoleEvent, null), decoder.next(.{ .key = .{
        .key_down = true,
        .unicode_char = 0xd83d,
    } }));
    decoder.reset();
    try std.testing.expectEqual(@as(?ConsoleEvent, null), decoder.next(.{ .key = .{
        .key_down = true,
        .unicode_char = 0xde42,
    } }));
}

test "a record reads the character composed with Alt and the keypad" {
    var decoder: ConsoleDecoder = .{};

    // Alt down is a keypress; the keypad digits under it are not.
    const alt_down = decoder.next(.{ .key = .{
        .key_down = true,
        .virtual_key_code = 0x12,
        .control_key_state = ControlKeyState.left_alt,
    } }).?;
    try std.testing.expectEqual(Key.left_alt, alt_down.key.key);

    for ([_]u16{ 0x61, 0x67 }) |digit| {
        try std.testing.expectEqual(@as(?ConsoleEvent, null), decoder.next(.{ .key = .{
            .key_down = true,
            .virtual_key_code = digit,
            .control_key_state = ControlKeyState.left_alt,
        } }));
    }

    // The character rides the Alt key coming up, and it is a press.
    const composed = decoder.next(.{ .key = .{
        .key_down = false,
        .virtual_key_code = 0x12,
        .unicode_char = 0xe9,
    } }).?;
    try std.testing.expectEqual(Key{ .char = 0xe9 }, composed.key.key);
    try std.testing.expectEqual(key.Kind.press, composed.key.kind);
    try std.testing.expectEqualStrings("\u{e9}", composed.key.text());

    // A keypad digit with Alt and something else is a chord, and reported.
    const chord = decoder.next(.{ .key = .{
        .key_down = true,
        .virtual_key_code = 0x61,
        .control_key_state = ControlKeyState.left_alt | ControlKeyState.left_ctrl,
    } }).?;
    try std.testing.expectEqual(Key.kp_1, chord.key.key);
    try std.testing.expect(chord.key.mods.alt and chord.key.mods.ctrl);
}

test "an astral character composed with Alt is a press" {
    var decoder: ConsoleDecoder = .{};

    try std.testing.expectEqual(@as(?ConsoleEvent, null), decoder.next(.{ .key = .{
        .key_down = false,
        .virtual_key_code = 0x12,
        .unicode_char = 0xd83d,
    } }));

    const composed = decoder.next(.{ .key = .{
        .key_down = false,
        .virtual_key_code = 0x12,
        .unicode_char = 0xde42,
    } }).?;
    try std.testing.expectEqual(Key{ .char = 0x1f642 }, composed.key.key);
    try std.testing.expectEqual(key.Kind.press, composed.key.kind);
    try std.testing.expectEqualStrings("\u{1f642}", composed.key.text());
}

test "a record reads AltGr as the character, not as control and alt" {
    const altgr = oneRecord(.{ .key = .{
        .key_down = true,
        .virtual_key_code = 'Q',
        .unicode_char = '@',
        .control_key_state = ControlKeyState.right_alt | ControlKeyState.left_ctrl,
    } }, false).?;
    try std.testing.expectEqual(Key{ .char = '@' }, altgr.key.key);
    try std.testing.expect(!altgr.key.mods.alt and !altgr.key.mods.ctrl);
    try std.testing.expectEqualStrings("@", altgr.key.text());

    // Right alt and control with no character is the chord it looks like.
    const chord = oneRecord(.{ .key = .{
        .key_down = true,
        .virtual_key_code = 0x70,
        .control_key_state = ControlKeyState.right_alt | ControlKeyState.left_ctrl,
    } }, false).?;
    try std.testing.expectEqual(Key{ .f = 1 }, chord.key.key);
    try std.testing.expect(chord.key.mods.alt and chord.key.mods.ctrl);
}

test "fuzz ConsoleDecoder" {
    // The property: no field value panics or overflows, a key that comes back
    // carries valid UTF-8 and never a surrogate, a mouse report is inside the
    // coordinate space, and the same record translates the same way twice
    // through a decoder that has seen nothing else.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [16]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];
            if (bytes.len < 12) return;

            const a = std.mem.readInt(u16, bytes[0..2], .little);
            const b = std.mem.readInt(u16, bytes[2..4], .little);
            const c = std.mem.readInt(u16, bytes[4..6], .little);
            const d = std.mem.readInt(u16, bytes[6..8], .little);
            const state = std.mem.readInt(u32, bytes[8..12], .little);

            const records = [_]ConsoleRecord{
                .{ .key = .{
                    .key_down = a & 1 != 0,
                    .repeat_count = b,
                    .virtual_key_code = c,
                    .virtual_scan_code = d,
                    .unicode_char = a,
                    .control_key_state = state,
                } },
                .{ .mouse = .{
                    .x = a,
                    .y = b,
                    .button_state = state,
                    .control_key_state = state,
                    .event_flags = c,
                } },
                .{ .window_buffer_size = .{ .cols = a, .rows = b } },
                .other,
            };

            for (records) |record| for ([_]bool{ false, true }) |key_up| {
                const event = oneRecord(record, key_up) orelse continue;
                try std.testing.expectEqual(event, oneRecord(record, key_up).?);
                switch (event) {
                    .key => |ev| {
                        try std.testing.expect(std.unicode.utf8ValidateSlice(ev.text()));
                        switch (ev.key) {
                            .char => |cp| try std.testing.expect(
                                cp < 0xd800 or cp > 0xdfff,
                            ),
                            else => {},
                        }
                        if (!key_up) try std.testing.expect(ev.kind == .press);
                    },
                    .mouse => |ev| {
                        try std.testing.expect(ev.x >= 1 and ev.x <= 65536);
                        try std.testing.expect(ev.y >= 1 and ev.y <= 65536);
                        try std.testing.expect(!ev.pixels);
                    },
                    .resize => |size| {
                        try std.testing.expect(size.rows <= 65535);
                        try std.testing.expect(size.cols <= 65535);
                    },
                }
            };
        }
    }.one, .{ .corpus = &.{
        corpus.seed("\x01\x00\x01\x00\x25\x00\x4b\x00\x00\x00\x00\x00"),
        corpus.seed("\x61\x00\x03\x00\x41\x00\x1e\x00\x10\x00\x00\x00"),
        corpus.seed("\x00\xd8\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00"),
        corpus.seed("\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff"),
        corpus.seed("\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"),
    } });
}

test "fuzz a run of records through one decoder" {
    // The property: a decoder that keeps state across records never panics,
    // never overflows, and never hands back a surrogate half as a key --
    // whatever order the halves and the Alt compositions arrive in.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [64]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];

            var decoder: ConsoleDecoder = .{ .report_key_up = bytes.len % 2 == 0 };
            var rest = bytes;
            while (rest.len >= 8) : (rest = rest[8..]) {
                const record: ConsoleRecord = .{ .key = .{
                    .key_down = rest[0] & 1 != 0,
                    .virtual_key_code = std.mem.readInt(u16, rest[1..3], .little),
                    .unicode_char = std.mem.readInt(u16, rest[3..5], .little),
                    .control_key_state = std.mem.readInt(u16, rest[5..7], .little),
                } };
                const event = decoder.next(record) orelse continue;
                switch (event) {
                    .key => |ev| {
                        try std.testing.expect(std.unicode.utf8ValidateSlice(ev.text()));
                        switch (ev.key) {
                            .char => |cp| try std.testing.expect(cp < 0xd800 or cp > 0xdfff),
                            else => {},
                        }
                    },
                    else => {},
                }
            }
        }
    }.one, .{ .corpus = &.{
        corpus.seed("\x01\x00\x00\x00\xd8\x00\x00\x00\x01\x00\x00\x42\xde\x00\x00\x00"),
        corpus.seed("\x01\x12\x00\x00\x00\x02\x00\x00\x00\x12\x00\xe9\x00\x00\x00\x00"),
        corpus.seed("\x01\x51\x00\x40\x00\x09\x00\x00"),
        corpus.seed("\x00\x00\x00\x00\x00\x00\x00\x00"),
    } });
}
