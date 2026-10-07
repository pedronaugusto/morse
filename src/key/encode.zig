//! Keys back into the bytes a terminal sends for them: the other direction
//! of `KeyParser`, for a program that stands where a terminal stands -- a
//! multiplexer forwarding keys to the program inside it, a host driving a
//! child on a pseudo-terminal, a test typing at a program.
//!
//! What a key becomes depends on what the program reading it asked the
//! terminal for, so `encodeKey` takes that state as a `KeyEncoding`: the
//! kitty keyboard flags in effect, xterm's `modifyOtherKeys`, and the DEC
//! modes that change the cursor and keypad keys. With no kitty flag set the
//! key is written the legacy way, with any set it is written as the kitty
//! keyboard protocol says.
//!
//! The kitty half follows kitty's own encoder (`kitty/key_encoding.c`), whose
//! key event is this package's `KeyEvent` field for field: the key, the
//! shifted key, the base layout key, the text, the modifiers and the kind.
//! The legacy half follows xterm's PC-style function keys, `modifyOtherKeys`
//! and the fixterms `CSI u` form for control and a printable key, as
//! ghostty spells them; the conformance step checks both against ghostty's
//! encoder byte for byte, and names where the two references differ and
//! which one is followed.
//!
//! With every kitty flag set, `KeyParser` reads what this writes back as
//! the event it was written from, for every key the parser itself reads,
//! less three things the protocol has no room for: a shifted form without
//! shift held, which kitty reports only with shift; alternates on a key
//! that is not a codepoint; and a typed private-use codepoint the protocol
//! gives to a named key, which reads back as that key. With fewer flags, or
//! none, less can be said -- legacy encoding has no release, no lock states,
//! no keypad keys in numeric mode, and one byte for several keys -- and a
//! key is written as the key it cannot be told from, which reads back and
//! is written again the same way.
//!
//! What this file will never hold: the terminal's state. Which flags are
//! pushed, whether the cursor keys are in application mode, and which key
//! was pressed are the caller's; this turns the key into bytes for the
//! state it is given, and keeps nothing between calls.

const std = @import("std");
const utf8 = @import("../utf8.zig");
const key_types = @import("event.zig");
const mode = @import("../mode.zig");
const seq = @import("../seq.zig");

const Writer = std.Io.Writer;
const Key = key_types.Key;
const KeyEvent = key_types.KeyEvent;
const Modifiers = key_types.Modifiers;
const KittyFlags = mode.KittyFlags;

/// What the program reading the keys has asked the terminal for: everything
/// the bytes of a key depend on besides the key.
pub const KeyEncoding = struct {
    /// The kitty keyboard flags in effect, the top of the screen's stack.
    /// Any flag set writes keys in the kitty protocol; none writes them the
    /// legacy way and the fields below apply.
    kitty: KittyFlags = .{},
    /// xterm's `modifyOtherKeys` at level 2 (`CSI > 4 ; 2 m`): every
    /// modified key that has no sequence of its own is written as
    /// `CSI 27 ; modifiers ; codepoint ~`. Level 1 changes nothing a legacy
    /// key writes here, as in ghostty.
    modify_other_keys: bool = false,
    /// DECCKM, mode 1: the unmodified arrows, home and end as `SS3` rather
    /// than `CSI`.
    cursor_keys_application: bool = false,
    /// DECKPAM (`ESC =`), or mode 66: the keypad's digits and operators as
    /// `SS3` sequences rather than the characters they type.
    keypad_application: bool = false,
    /// DECBKM, mode 67: backspace sends `BS` and control and backspace
    /// sends `DEL`, the other way round from the default.
    backarrow_sends_bs: bool = false,
};

/// Writes the bytes a terminal in the state `enc` sends for `ev`.
///
/// Some keys write nothing: a release or a modifier key the flags do not
/// ask to hear about, and a key the legacy encoding has no spelling for --
/// the media keys, the locks, print screen, pause and F26 upward. Alt is
/// always an `ESC` in front of the key; the eighth-bit form is not written.
///
/// The text the event carries is what the key typed and is written as it
/// stands. A `.char` key with no text and no modifier types its own
/// codepoint; with shift and no text it types `shifted`, or the capital of
/// an ASCII letter.
pub fn encodeKey(w: *Writer, ev: KeyEvent, enc: KeyEncoding) Writer.Error!void {
    return spellKey(w, ev, enc);
}

/// How many bytes `encodeKey` writes for `ev` in the state `enc`.
pub fn cost(ev: KeyEvent, enc: KeyEncoding) usize {
    return seq.count(spellKey, .{ ev, enc });
}

/// The bytes of `encodeKey`, into a `*Writer` or a `*seq.Count`.
fn spellKey(w: anytype, ev: KeyEvent, enc: KeyEncoding) !void {
    if (enc.kitty.bits() != 0) return kitty(w, ev, enc);
    return legacy(w, ev, enc);
}

//=========================================================================
// The kitty keyboard protocol.
//=========================================================================

/// Caps lock and num lock, which kitty counts as modifiers but not as
/// modifiers that make enter, tab and backspace a sequence.
const lock_bits: u8 = (Modifiers{ .caps_lock = true, .num_lock = true }).bits();

/// Whether `key` is a modifier key, which kitty reports only to a program
/// that asked for every key: the shifts, controls, alts, supers, hypers and
/// metas, the two ISO level shifts, and the three locks.
fn isModifierKey(key: Key) bool {
    return switch (key) {
        .caps_lock, .scroll_lock, .num_lock => true,
        .left_shift, .left_ctrl, .left_alt, .left_super, .left_hyper, .left_meta => true,
        .right_shift, .right_ctrl, .right_alt, .right_super, .right_hyper, .right_meta => true,
        .iso_level3_shift, .iso_level5_shift => true,
        else => false,
    };
}

/// Whether `text` starts with a C0 control or DEL, or is empty: kitty's
/// test for text that is not text.
fn startsWithControl(text: []const u8) bool {
    if (text.len == 0) return true;
    return text[0] < 0x20 or text[0] == 0x7f;
}

/// The key a keypad key stands for when the flags do not separate the
/// keypad from the rest of the keyboard.
fn keypadAsNormal(key: Key) Key {
    return switch (key) {
        .kp_enter => .enter,
        .kp_home => .home,
        .kp_end => .end,
        .kp_insert => .insert,
        .kp_delete => .delete,
        .kp_page_up => .page_up,
        .kp_page_down => .page_down,
        .kp_up => .up,
        .kp_down => .down,
        .kp_left => .left,
        .kp_right => .right,
        .kp_0, .kp_1, .kp_2, .kp_3, .kp_4, .kp_5, .kp_6, .kp_7, .kp_8, .kp_9 => .{
            .char = '0' + @as(u21, @backingInt(std.meta.activeTag(key)) - @backingInt(std.meta.Tag(Key).kp_0)),
        },
        .kp_decimal => .{ .char = '.' },
        .kp_divide => .{ .char = '/' },
        .kp_multiply => .{ .char = '*' },
        .kp_subtract => .{ .char = '-' },
        .kp_add => .{ .char = '+' },
        .kp_equal => .{ .char = '=' },
        else => key,
    };
}

/// The kitty encoding of `ev`, ported from kitty's `encode_glfw_key_event`.
fn kitty(w: anytype, ev: KeyEvent, enc: KeyEncoding) !void {
    const flags = enc.kitty;
    // Kitty calls the eighth flag "report text": every key as an escape
    // code, text included.
    const all = flags.report_all_keys_as_escape_codes;
    if (!all and isModifierKey(ev.key)) return;

    const text = ev.text();
    const has_text = !startsWithControl(text);
    var key = ev.key;
    if (!flags.disambiguate_escape_codes and !all) key = keypadAsNormal(key);
    if (!all and has_text and ev.kind != .release) return w.writeAll(text);
    if (!flags.report_event_types and ev.kind == .release) return;

    switch (key) {
        .char => |cp| return kittyChar(w, ev, cp, enc),
        else => return kittyFunctional(w, ev, key, enc),
    }
}

/// One sequence's fields, as kitty's `serialize` writes them.
const Fields = struct {
    key: u21,
    shifted: ?u21 = null,
    base: ?u21 = null,
    alternates: bool = false,
    mods: u8,
    actions: bool,
    kind: key_types.Kind,
    text: ?[]const u8,
};

/// Writes `CSI key:shifted:base ; mods:kind ; text final`, each part only
/// when it says something.
fn serialize(w: anytype, f: Fields, final: u8) !void {
    const second = f.mods != 0 or f.actions;
    const third = f.text != null;
    try w.writeAll(seq.csi);
    // Kitty leaves out a key of 1, which only the functional keys with a
    // final of their own use; a codepoint key is always written.
    if (f.key != 1 or final == 'u' or f.alternates or second or third) try seq.writeInt(w, f.key);
    if (f.alternates) {
        try w.writeByte(':');
        if (f.shifted) |s| try seq.writeInt(w, s);
        if (f.base) |b| {
            try w.writeByte(':');
            try seq.writeInt(w, b);
        }
    }
    if (second or third) {
        try w.writeByte(';');
        if (second) try seq.writeInt(w, @as(u16, f.mods) + 1);
        if (f.actions) {
            try w.writeByte(':');
            try seq.writeInt(w, @as(u8, switch (f.kind) {
                .press => 1,
                .repeat => 2,
                .release => 3,
            }));
        }
    }
    if (f.text) |text| {
        var i: usize = 0;
        var first = true;
        while (i < text.len) {
            const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            const cp = if (i + n <= text.len) utf8.decode(text[i..][0..n]) catch null else null;
            i += if (cp == null) 1 else n;
            const value = cp orelse continue;
            try w.writeByte(if (first) ';' else ':');
            first = false;
            try seq.writeInt(w, value);
        }
    }
    try w.writeByte(final);
}

/// A key that stands for a codepoint, in the kitty protocol: kitty's
/// `encode_key` for everything that is not a functional key.
fn kittyChar(w: anytype, ev: KeyEvent, cp: u21, enc: KeyEncoding) !void {
    const flags = enc.kitty;
    const all = flags.report_all_keys_as_escape_codes;
    const mods = ev.mods.bits();
    const actions = flags.report_event_types and ev.kind != .press;
    const shift = ev.mods.shift;
    // Kitty knows a key's shifted form whether or not shift is held, and
    // reports it only when shift is.
    const alternates = flags.report_alternate_keys and
        ((ev.shifted != null and shift) or ev.base != null);
    const text: ?[]const u8 = if (flags.report_associated_text and ev.text_len != 0) ev.text() else null;

    if (!actions and !alternates and text == null) {
        if (mods == 0) {
            if (!all) return writeCodepoint(w, cp);
            return serialize(w, .{ .key = cp, .mods = 0, .actions = false, .kind = ev.kind, .text = null }, 'u');
        }
        if (!flags.disambiguate_escape_codes and !all) {
            if (isLegacyAscii(cp) or (ev.shifted != null and isLegacyAscii(ev.shifted.?))) {
                if (try printableAsciiLegacy(w, cp, ev.shifted, mods)) return;
            }
            const ctrl: u8 = (Modifiers{ .ctrl = true }).bits();
            const alt: u8 = (Modifiers{ .alt = true }).bits();
            if (mods == ctrl or mods == alt or mods == ctrl | alt) {
                if (ev.base) |base| if (!isLegacyAscii(cp) and isLegacyAscii(base)) {
                    if (try printableAsciiLegacy(w, base, null, mods)) return;
                };
            }
        }
    }

    return serialize(w, .{
        .key = cp,
        .shifted = if (alternates and shift) ev.shifted else null,
        .base = if (alternates) ev.base else null,
        .alternates = alternates,
        .mods = mods,
        .actions = actions,
        .kind = ev.kind,
        .text = text,
    }, 'u');
}

/// A functional key in the kitty protocol: kitty's `encode_function_key`.
fn kittyFunctional(w: anytype, ev: KeyEvent, key: Key, enc: KeyEncoding) !void {
    const flags = enc.kitty;
    const all = flags.report_all_keys_as_escape_codes;
    const disambiguate = flags.disambiguate_escape_codes;
    const legacy_mode = !flags.report_event_types and !disambiguate and !all;
    const mods = ev.mods.bits();
    const release = ev.kind == .release;

    if (enc.cursor_keys_application and legacy_mode and mods == 0) {
        switch (key) {
            .up, .down, .right, .left, .kp_begin, .end, .home => return ss3(w, cursorFinal(key)),
            else => {},
        }
    }
    if (mods == 0) {
        if (!disambiguate and !all and key == .escape) return w.writeByte(seq.esc);
        if (legacy_mode) switch (key) {
            .f => |n| if (n >= 1 and n <= 4) return ss3(w, "PQRS"[n - 1]),
            else => {},
        };
    } else if (legacy_mode) {
        if (try legacyFunctionalWithModifiers(w, key, ev.mods)) return;
    }
    if (mods & ~lock_bits == 0 and !all) {
        switch (key) {
            .enter => return if (!release) w.writeByte('\r'),
            .backspace => return if (!release) w.writeByte(0x7f),
            .tab => return if (!release) w.writeByte('\t'),
            else => {},
        }
    }

    var code: u21 = undefined;
    var final: u8 = 'u';
    switch (key) {
        .escape => code = 27,
        .enter => code = 13,
        .tab => code = 9,
        .backspace => code = 127,
        .insert => {
            code = 2;
            final = '~';
        },
        .delete => {
            code = 3;
            final = '~';
        },
        .page_up => {
            code = 5;
            final = '~';
        },
        .page_down => {
            code = 6;
            final = '~';
        },
        .left, .right, .up, .down, .home, .end, .kp_begin => {
            code = 1;
            final = cursorFinal(key);
        },
        .f => |n| switch (n) {
            1 => {
                code = 1;
                final = 'P';
            },
            2 => {
                code = 1;
                final = 'Q';
            },
            4 => {
                code = 1;
                final = 'S';
            },
            3, 5...12 => {
                code = tildeNumber(n).?;
                final = '~';
            },
            else => code = key_types.protocolCode(key) orelse return,
        },
        .menu => if (legacy_mode) {
            code = 29;
            final = '~';
        } else {
            code = key_types.protocolCode(key).?;
        },
        else => code = key_types.protocolCode(key) orelse return,
    }
    return serialize(w, .{
        .key = code,
        .mods = mods,
        .actions = flags.report_event_types and ev.kind != .press,
        .kind = ev.kind,
        .text = if (flags.report_associated_text and ev.text_len != 0) ev.text() else null,
    }, final);
}

/// Enter, escape, backspace and tab with modifiers, when the flags leave
/// functional keys in their legacy form. False for any other key.
fn legacyFunctionalWithModifiers(w: anytype, key: Key, mods: Modifiers) !bool {
    switch (key) {
        .enter, .escape, .backspace => {
            if (mods.alt) try w.writeByte(seq.esc);
            try w.writeByte(switch (key) {
                .enter => '\r',
                .escape => seq.esc,
                else => if (mods.ctrl) 0x08 else 0x7f,
            });
        },
        .tab => if (mods.shift) {
            if (mods.alt) try w.writeByte(seq.esc);
            try w.writeAll(seq.csi ++ "Z");
        } else {
            if (mods.alt) try w.writeByte(seq.esc);
            try w.writeByte('\t');
        },
        else => return false,
    }
    return true;
}

/// The printable ASCII keys the legacy forms have a spelling for.
fn isLegacyAscii(cp: u21) bool {
    return switch (cp) {
        'a'...'z', '0'...'9', ' ' => true,
        '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '`', '~', '-', '_', '=', '+' => true,
        '[', '{', ']', '}', '\\', '|', ';', ':', '\'', '"', ',', '<', '.', '>', '/', '?' => true,
        else => false,
    };
}

/// Kitty's `encode_printable_ascii_key_legacy`: an ASCII key with shift,
/// alt, control or both of the last two, as the legacy forms spell it.
/// False for a combination they have no spelling for.
fn printableAsciiLegacy(w: anytype, cp: u21, shifted: ?u21, all_mods: u8) !bool {
    const shift: u8 = 1;
    const alt: u8 = 2;
    const ctrl: u8 = 4;
    var mods = all_mods;
    var wide = cp;
    if (mods & shift != 0) {
        if (shifted) |s| if (s != cp and (mods & ctrl == 0 or cp < 'a' or cp > 'z')) {
            wide = s;
            mods &= ~shift;
        };
    }
    if (wide >= 0x80) return false;
    const key: u8 = @intCast(wide);
    if (all_mods == shift) {
        try w.writeByte(key);
    } else if (mods == alt) {
        try w.writeAll(&.{ seq.esc, key });
    } else if (mods == ctrl) {
        try w.writeByte(kittyCtrl(key));
    } else if (mods == ctrl | alt) {
        try w.writeAll(&.{ seq.esc, kittyCtrl(key) });
    } else if (key == ' ' and mods == ctrl | shift) {
        try w.writeByte(kittyCtrl(key));
    } else if (key == ' ' and mods == alt | shift) {
        try w.writeAll(&.{ seq.esc, key });
    } else return false;
    return true;
}

/// The byte control and `key` sends, as kitty maps it: `ctrled_key`.
fn kittyCtrl(key: u8) u8 {
    return switch (key) {
        ' ', '2', '@' => 0,
        '/', '7', '_' => 31,
        '3', '[' => 27,
        '4', '\\' => 28,
        '5', ']' => 29,
        '6', '^', '~' => 30,
        '8', '?' => 127,
        'a'...'z' => key - 'a' + 1,
        else => key,
    };
}

//=========================================================================
// The legacy encodings.
//=========================================================================

/// The modifiers a legacy sequence can carry: everything but the locks,
/// which no legacy terminal reports.
fn held(mods: Modifiers) Modifiers {
    var out = mods;
    out.caps_lock = false;
    out.num_lock = false;
    return out;
}

/// The legacy encoding of `ev`: xterm's PC-style function keys and
/// `modifyOtherKeys`, the C0 controls, and the fixterms `CSI u` form for
/// control with a printable key, as ghostty writes them.
fn legacy(w: anytype, ev: KeyEvent, enc: KeyEncoding) !void {
    if (ev.kind == .release) return;
    const mods = held(ev.mods);
    switch (ev.key) {
        .char => |cp| return legacyChar(w, ev, cp, mods, enc),
        else => {},
    }

    const param: u16 = @as(u16, mods.bits()) + 1;
    const any = mods.any();
    switch (ev.key) {
        .up, .down, .right, .left, .home, .end, .kp_begin, .kp_up, .kp_down, .kp_right, .kp_left, .kp_home, .kp_end => {
            const final = cursorFinal(switch (ev.key) {
                .kp_up => .up,
                .kp_down => .down,
                .kp_right => .right,
                .kp_left => .left,
                .kp_home => .home,
                .kp_end => .end,
                else => ev.key,
            });
            if (any) return csiOne(w, param, final);
            if (enc.cursor_keys_application) return ss3(w, final);
            return w.writeAll(&.{ seq.esc, '[', final });
        },
        .insert, .kp_insert => return tilde(w, 2, param, any),
        .delete, .kp_delete => return tilde(w, 3, param, any),
        .page_up, .kp_page_up => return tilde(w, 5, param, any),
        .page_down, .kp_page_down => return tilde(w, 6, param, any),
        .menu => return tilde(w, 29, param, any),
        .f => |n| switch (n) {
            1, 2, 4 => {
                const final = "PQ?S"[n - 1];
                if (any) return csiOne(w, param, final);
                return ss3(w, final);
            },
            3 => {
                if (any) return tilde(w, 13, param, true);
                return ss3(w, 'R');
            },
            else => {
                const number = tildeNumber(n) orelse return;
                return tilde(w, number, param, any);
            },
        },
        .kp_0, .kp_1, .kp_2, .kp_3, .kp_4, .kp_5, .kp_6, .kp_7, .kp_8, .kp_9 => {
            const digit: u8 = @intCast(@backingInt(std.meta.activeTag(ev.key)) - @backingInt(std.meta.Tag(Key).kp_0));
            return keypad(w, enc, param, any, 'p' + digit, '0' + digit);
        },
        .kp_decimal => return keypad(w, enc, param, any, 'n', '.'),
        .kp_divide => return keypad(w, enc, param, any, 'o', '/'),
        .kp_multiply => return keypad(w, enc, param, any, 'j', '*'),
        .kp_subtract => return keypad(w, enc, param, any, 'm', '-'),
        .kp_add => return keypad(w, enc, param, any, 'k', '+'),
        .kp_enter => return keypad(w, enc, param, any, 'M', '\r'),
        .kp_equal => return keypad(w, enc, param, any, 'X', '='),
        .kp_separator => return keypad(w, enc, param, any, 'l', ','),
        .enter => {
            if (!any) return w.writeByte('\r');
            if (mods.bits() == (Modifiers{ .alt = true }).bits() and !enc.modify_other_keys) return w.writeAll("\x1b\r");
            return modifyOther(w, param, 13);
        },
        .tab => {
            if (!any) return w.writeByte('\t');
            if (!enc.modify_other_keys) {
                if (mods.bits() == (Modifiers{ .shift = true }).bits()) return w.writeAll(seq.csi ++ "Z");
                if (mods.bits() == (Modifiers{ .alt = true }).bits()) return w.writeAll("\x1b\t");
            }
            return modifyOther(w, param, 9);
        },
        .escape => {
            if (!any) return w.writeByte(seq.esc);
            if (mods.bits() == (Modifiers{ .alt = true }).bits() and !enc.modify_other_keys) return w.writeAll("\x1b\x1b");
            return modifyOther(w, param, 27);
        },
        .backspace => {
            const ctrl_only = mods.bits() == (Modifiers{ .ctrl = true }).bits();
            if (!any or ctrl_only) {
                const bs = ctrl_only != enc.backarrow_sends_bs;
                return w.writeByte(if (bs) 0x08 else 0x7f);
            }
            if (enc.modify_other_keys) return modifyOther(w, param, 127);
            if (mods.alt) try w.writeByte(seq.esc);
            return w.writeByte(if (mods.ctrl) 0x08 else 0x7f);
        },
        // The locks, print screen, pause, the media keys and the modifier
        // keys have no legacy spelling.
        else => return,
    }
}

/// The final byte the cursor keys share between `CSI` and `SS3`.
fn cursorFinal(key: Key) u8 {
    return switch (key) {
        .up => 'A',
        .down => 'B',
        .right => 'C',
        .left => 'D',
        .kp_begin => 'E',
        .end => 'F',
        .home => 'H',
        else => unreachable,
    };
}

/// The `CSI n ~` number of a function key from F3 to F25, the numbering the
/// VT220 started and ghostty carries past F20; null past that.
fn tildeNumber(n: u8) ?u16 {
    return switch (n) {
        3 => 13,
        5 => 15,
        6...10 => 11 + @as(u16, n),
        11...14 => 12 + @as(u16, n),
        15, 16 => 13 + @as(u16, n),
        17...20 => 14 + @as(u16, n),
        21...25 => 21 + @as(u16, n),
        else => null,
    };
}

fn ss3(w: anytype, final: u8) !void {
    try w.writeAll(&.{ seq.esc, 'O', final });
}

/// `CSI 1 ; param final`.
fn csiOne(w: anytype, param: u16, final: u8) !void {
    try w.writeAll(seq.csi ++ "1;");
    try seq.writeInt(w, param);
    try w.writeByte(final);
}

/// `CSI number ~`, or `CSI number ; param ~` with modifiers.
fn tilde(w: anytype, number: u16, param: u16, any: bool) !void {
    try w.writeAll(seq.csi);
    try seq.writeInt(w, number);
    if (any) {
        try w.writeByte(';');
        try seq.writeInt(w, param);
    }
    try w.writeByte('~');
}

/// `CSI 27 ; param ; code ~`, xterm's `modifyOtherKeys` form.
fn modifyOther(w: anytype, param: u16, code: u21) !void {
    try w.writeAll(seq.csi ++ "27;");
    try seq.writeInt(w, param);
    try w.writeByte(';');
    try seq.writeInt(w, code);
    try w.writeByte('~');
}

/// A keypad key that types `normal`, or sends `SS3 final` in application
/// mode -- with the modifier parameter in between when one is held.
fn keypad(w: anytype, enc: KeyEncoding, param: u16, any: bool, final: u8, normal: u8) !void {
    if (!enc.keypad_application) return w.writeByte(normal);
    try w.writeAll(&.{ seq.esc, 'O' });
    if (any) try seq.writeInt(w, param);
    try w.writeByte(final);
}

/// Writes `cp` as UTF-8.
fn writeCodepoint(w: anytype, cp: u21) !void {
    var buffer: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buffer) catch return;
    try w.writeAll(buffer[0..n]);
}

/// The single codepoint `text` holds, or null when it holds none or more.
fn soleCodepoint(text: []const u8) ?u21 {
    if (text.len == 0) return null;
    const n = std.unicode.utf8ByteSequenceLength(text[0]) catch return null;
    if (n != text.len) return null;
    return utf8.decode(text) catch null;
}

/// A key that stands for a codepoint, the legacy way.
fn legacyChar(w: anytype, ev: KeyEvent, cp: u21, mods: Modifiers, enc: KeyEncoding) !void {
    const text = ev.text();
    // What the key typed with shift as held: its text when that is one
    // codepoint, else its shifted form, else the key -- or the capital of an
    // ASCII letter, which is what shift does to one on every layout.
    const typed: u21 = soleCodepoint(text) orelse blk: {
        if (text.len != 0) break :blk cp;
        if (!mods.shift) break :blk cp;
        if (ev.shifted) |s| break :blk s;
        if (cp >= 'a' and cp <= 'z') break :blk cp - 0x20;
        break :blk cp;
    };
    const several = text.len != 0 and soleCodepoint(text) == null;

    if (enc.modify_other_keys and !several and mods.any()) {
        var others = mods;
        others.shift = false;
        const should = (typed >= 0x40 and typed <= 0x7f) or others.any() or typed == ' ';
        if (should) return modifyOther(w, @as(u16, mods.bits()) + 1, typed);
    }

    if (mods.ctrl and !several) {
        if (ctrlByte(typed, cp, ev.base, mods)) |byte| {
            if (mods.alt) try w.writeByte(seq.esc);
            return w.writeByte(byte);
        }
        // The fixterms form, with kitty's lower case for a shifted letter,
        // and shift left out when it is what made the character.
        var char = typed;
        var with = mods;
        if (char >= 'A' and char <= 'Z' and with.shift) char += 0x20;
        const unshifted = if (cp < 0x80) std.ascii.toLower(@intCast(cp)) else cp;
        if (unshifted != char) with.shift = false;
        try w.writeAll(seq.csi);
        try seq.writeInt(w, char);
        try w.writeByte(';');
        try seq.writeInt(w, @as(u16, with.bits()) + 1);
        return w.writeByte('u');
    }

    if (mods.alt) try w.writeByte(seq.esc);
    if (text.len != 0) return w.writeAll(text);
    return writeCodepoint(w, typed);
}

/// The C0 byte control with a key sends, or null when control with that
/// key is not one: ghostty's `ctrlSeq`, which takes kitty's table and
/// leaves `i`, `m` and `[` to the `CSI u` form so they stay apart from tab,
/// enter and escape.
fn ctrlByte(typed: u21, cp: u21, base: ?u21, mods: Modifiers) ?u8 {
    var unset = mods;
    unset.alt = false;
    const ctrl_only: Modifiers = .{ .ctrl = true };

    var char: u8 = if (typed < 0x80) @intCast(typed) else blk: {
        // A key on another layout is control and the key at its position,
        // when nothing but control is held.
        const at = base orelse return null;
        if (at >= 0x80 or unset.bits() != ctrl_only.bits()) return null;
        break :blk @intCast(at);
    };
    if (unset.shift and (char < 'A' or char > 'Z') and char != '@') unset.shift = false;
    if (char >= 'A' and char <= 'Z' and cp < 0x80) char = @intCast(cp);
    if (unset.bits() != ctrl_only.bits()) return null;

    return switch (char) {
        'i', 'm', '[' => null,
        ' ', '2', '@' => 0,
        '/', '7', '_' => 31,
        '0' => '0',
        '1' => '1',
        '9' => '9',
        '3' => 27,
        '4', '\\' => 28,
        '5', ']' => 29,
        '6', '^', '~' => 30,
        '8', '?' => 127,
        'a'...'h', 'j'...'l', 'n'...'z' => char - 'a' + 1,
        else => null,
    };
}

//=========================================================================
// Tests.
//=========================================================================

const testing = std.testing;

/// What `encodeKey` writes for `ev` in `enc`, checked against `cost`.
fn encoded(buffer: []u8, ev: KeyEvent, enc: KeyEncoding) ![]const u8 {
    var w: Writer = .fixed(buffer);
    try encodeKey(&w, ev, enc);
    try testing.expectEqual(w.buffered().len, cost(ev, enc));
    return w.buffered();
}

fn expectKey(expected: []const u8, ev: KeyEvent, enc: KeyEncoding) !void {
    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings(expected, try encoded(&buffer, ev, enc));
}

fn charKey(cp: u21, mods: Modifiers) KeyEvent {
    return .{ .key = .{ .char = cp }, .mods = mods };
}

fn texted(cp: u21, mods: Modifiers, text: []const u8) KeyEvent {
    var ev = charKey(cp, mods);
    @memcpy(ev.text_buffer[0..text.len], text);
    ev.text_len = @intCast(text.len);
    return ev;
}

fn kittyFlags(bits: u5) KeyEncoding {
    return .{ .kitty = .fromBits(bits) };
}

const shift_held: Modifiers = .{ .shift = true };
const alt_held: Modifiers = .{ .alt = true };
const ctrl_held: Modifiers = .{ .ctrl = true };

// Kitty's own expectations for its flags, from kitty_tests/keys.py.

test "disambiguate writes escape and modified keys as CSI u, text and enter as before" {
    const enc = kittyFlags(0b1);
    try expectKey("a", texted('a', .{}, "a"), enc);
    try expectKey("\x1b[27u", .{ .key = .escape }, enc);
    try expectKey("\r", .{ .key = .enter }, enc);
    try expectKey("\x1b[13;2u", .{ .key = .enter, .mods = shift_held }, enc);
    try expectKey("\t", .{ .key = .tab }, enc);
    try expectKey("\x7f", .{ .key = .backspace }, enc);
    try expectKey("\x1b[9;2u", .{ .key = .tab, .mods = shift_held }, enc);
    try expectKey("\x1b[97;5u", charKey('a', ctrl_held), enc);
    try expectKey("\x1b[97;3u", charKey('a', alt_held), enc);
    try expectKey("\x1b[97;6u", charKey('a', .{ .ctrl = true, .shift = true }), enc);
    try expectKey("\x1b[97;4u", charKey('a', .{ .alt = true, .shift = true }), enc);
    try expectKey("\x1b[32;5u", charKey(' ', ctrl_held), enc);
    try expectKey("\x1b[57421u", .{ .key = .kp_page_up }, enc);
    try expectKey("\x1b[57421;5u", .{ .key = .kp_page_up, .mods = ctrl_held }, enc);
    try expectKey("\x1b[57399u", .{ .key = .kp_0 }, enc);
    try expectKey("\x1b[A", .{ .key = .up }, enc);
    try expectKey("\x1b[1;5A", .{ .key = .up, .mods = ctrl_held }, enc);
}

test "event types add repeat and release, and keep enter, tab and backspace releases quiet" {
    var enc = kittyFlags(0b10);
    try expectKey("a", texted('a', .{}, "a"), enc);
    try expectKey("\x1b[97;1:2u", .{ .key = .{ .char = 'a' }, .kind = .repeat }, enc);
    try expectKey("\x1b[97;1:3u", .{ .key = .{ .char = 'a' }, .kind = .release }, enc);
    try expectKey("\x1b[97;2:3u", .{ .key = .{ .char = 'a' }, .kind = .release, .mods = shift_held }, enc);
    enc = kittyFlags(0b11);
    try expectKey("\x7f", .{ .key = .backspace }, enc);
    try expectKey("", .{ .key = .backspace, .kind = .release }, enc);
    const locked: Modifiers = .{ .num_lock = true, .caps_lock = true };
    try expectKey("\r", .{ .key = .enter, .mods = locked }, enc);
    try expectKey("", .{ .key = .enter, .mods = locked, .kind = .release }, enc);
}

test "alternate keys report the shifted key with shift and the base layout key always" {
    const enc = kittyFlags(0b100);
    try expectKey("a", charKey('a', .{}), enc);
    var ev = charKey('a', .{});
    ev.shifted = 'A';
    try expectKey("a", ev, enc);
    ev.mods = shift_held;
    try expectKey("\x1b[97:65;2u", ev, enc);
    ev = charKey('a', .{});
    ev.base = 'A';
    try expectKey("\x1b[97::65u", ev, enc);
    ev = charKey('a', shift_held);
    ev.shifted = 'A';
    ev.base = 'b';
    try expectKey("\x1b[97:65:98;2u", ev, enc);
}

test "report all keys writes every key as a sequence, modifiers included" {
    const enc = kittyFlags(0b1000);
    try expectKey("\x1b[97u", charKey('a', .{}), enc);
    try expectKey("\x1b[97u", .{ .key = .{ .char = 'a' }, .kind = .repeat }, enc);
    try expectKey("\x1b[97;5u", charKey('a', ctrl_held), enc);
    try expectKey("\x1b[A", .{ .key = .up }, enc);
    try expectKey("\x1b[57441u", .{ .key = .left_shift }, enc);
    try expectKey("\x1b[13u", .{ .key = .enter }, enc);
    try expectKey("\x1b[13;5u", .{ .key = .enter, .mods = ctrl_held }, enc);
    try expectKey("\x1b[9u", .{ .key = .tab }, enc);
    try expectKey("\x1b[127u", .{ .key = .backspace }, enc);
    // Without it, modifier keys say nothing.
    try expectKey("", .{ .key = .left_shift }, kittyFlags(0b1));
    try expectKey("", .{ .key = .caps_lock }, kittyFlags(0b1));
}

test "associated text rides along as codepoints" {
    const enc = kittyFlags(0b11000);
    try expectKey("\x1b[97;;97u", texted('a', .{}, "a"), enc);
    try expectKey("\x1b[97;2;65u", texted('a', shift_held, "A"), enc);
    try expectKey("\x1b[97;2;65:66u", texted('a', shift_held, "AB"), enc);
}

test "the functional keys take kitty's numbers and finals" {
    const enc = kittyFlags(0b1);
    try expectKey("\x1b[P", .{ .key = .{ .f = 1 } }, enc);
    try expectKey("\x1b[13~", .{ .key = .{ .f = 3 } }, enc);
    try expectKey("\x1b[15;3~", .{ .key = .{ .f = 5 }, .mods = alt_held }, enc);
    try expectKey("\x1b[24~", .{ .key = .{ .f = 12 } }, enc);
    try expectKey("\x1b[57376u", .{ .key = .{ .f = 13 } }, enc);
    try expectKey("\x1b[57398u", .{ .key = .{ .f = 35 } }, enc);
    try expectKey("\x1b[2~", .{ .key = .insert }, enc);
    try expectKey("\x1b[3;5~", .{ .key = .delete, .mods = ctrl_held }, enc);
    try expectKey("\x1b[E", .{ .key = .kp_begin }, enc);
    try expectKey("\x1b[57363u", .{ .key = .menu }, enc);
    try expectKey("\x1b[57428u", .{ .key = .media_play }, enc);
    try expectKey("\x1b[1;1:3A", .{ .key = .up, .kind = .release }, kittyFlags(0b11));
}

// The legacy encodings, as ghostty writes them; the conformance step checks
// the same against ghostty's encoder byte for byte.

test "legacy cursor keys follow DECCKM unmodified and carry modifiers as CSI 1 ; m" {
    try expectKey("\x1b[A", .{ .key = .up }, .{});
    try expectKey("\x1bOA", .{ .key = .up }, .{ .cursor_keys_application = true });
    try expectKey("\x1b[1;5A", .{ .key = .up, .mods = ctrl_held }, .{ .cursor_keys_application = true });
    try expectKey("\x1b[H", .{ .key = .home }, .{});
    try expectKey("\x1b[1;2F", .{ .key = .end, .mods = shift_held }, .{});
    try expectKey("\x1b[E", .{ .key = .kp_begin }, .{});
    // Locks are not modifiers a legacy terminal reports.
    try expectKey("\x1b[D", .{ .key = .left, .mods = .{ .caps_lock = true } }, .{});
}

test "legacy function keys use SS3 below F5 and CSI n ~ above" {
    try expectKey("\x1bOP", .{ .key = .{ .f = 1 } }, .{});
    try expectKey("\x1b[1;5P", .{ .key = .{ .f = 1 }, .mods = ctrl_held }, .{});
    try expectKey("\x1bOR", .{ .key = .{ .f = 3 } }, .{});
    try expectKey("\x1b[13;2~", .{ .key = .{ .f = 3 }, .mods = shift_held }, .{});
    try expectKey("\x1b[15~", .{ .key = .{ .f = 5 } }, .{});
    try expectKey("\x1b[24;3~", .{ .key = .{ .f = 12 }, .mods = alt_held }, .{});
    try expectKey("\x1b[25~", .{ .key = .{ .f = 13 } }, .{});
    try expectKey("\x1b[34~", .{ .key = .{ .f = 20 } }, .{});
    try expectKey("\x1b[42~", .{ .key = .{ .f = 21 } }, .{});
    try expectKey("\x1b[46;5~", .{ .key = .{ .f = 25 }, .mods = ctrl_held }, .{});
    try expectKey("", .{ .key = .{ .f = 26 } }, .{});
    try expectKey("\x1b[29~", .{ .key = .menu }, .{});
    try expectKey("\x1b[5;5~", .{ .key = .page_up, .mods = ctrl_held }, .{});
}

test "legacy keypad keys type their characters unless the keypad is in application mode" {
    try expectKey("7", .{ .key = .kp_7 }, .{});
    try expectKey("\r", .{ .key = .kp_enter }, .{});
    try expectKey("\x1bOw", .{ .key = .kp_7 }, .{ .keypad_application = true });
    try expectKey("\x1bO5k", .{ .key = .kp_add, .mods = ctrl_held }, .{ .keypad_application = true });
    try expectKey("\x1bOM", .{ .key = .kp_enter }, .{ .keypad_application = true });
    try expectKey("\x1b[A", .{ .key = .kp_up }, .{});
}

test "legacy enter, tab, escape and backspace" {
    try expectKey("\r", .{ .key = .enter }, .{});
    try expectKey("\x1b\r", .{ .key = .enter, .mods = alt_held }, .{});
    try expectKey("\x1b[27;2;13~", .{ .key = .enter, .mods = shift_held }, .{});
    try expectKey("\x1b[27;5;13~", .{ .key = .enter, .mods = ctrl_held }, .{});
    try expectKey("\x1b[Z", .{ .key = .tab, .mods = shift_held }, .{});
    try expectKey("\x1b[27;2;9~", .{ .key = .tab, .mods = shift_held }, .{ .modify_other_keys = true });
    try expectKey("\x1b\t", .{ .key = .tab, .mods = alt_held }, .{});
    try expectKey("\x1b[27;5;9~", .{ .key = .tab, .mods = ctrl_held }, .{});
    try expectKey("\x1b", .{ .key = .escape }, .{});
    try expectKey("\x1b\x1b", .{ .key = .escape, .mods = alt_held }, .{});
    try expectKey("\x1b[27;3;27~", .{ .key = .escape, .mods = alt_held }, .{ .modify_other_keys = true });
    try expectKey("\x7f", .{ .key = .backspace }, .{});
    try expectKey("\x08", .{ .key = .backspace, .mods = ctrl_held }, .{});
    try expectKey("\x08", .{ .key = .backspace }, .{ .backarrow_sends_bs = true });
    try expectKey("\x7f", .{ .key = .backspace, .mods = ctrl_held }, .{ .backarrow_sends_bs = true });
    try expectKey("\x1b\x7f", .{ .key = .backspace, .mods = alt_held }, .{});
    try expectKey("\x1b[27;3;127~", .{ .key = .backspace, .mods = alt_held }, .{ .modify_other_keys = true });
}

test "legacy printable keys: text, control codes, alt_held as ESC and the CSI u form" {
    try expectKey("a", texted('a', .{}, "a"), .{});
    try expectKey("A", texted('a', shift_held, "A"), .{});
    try expectKey("a", charKey('a', .{}), .{});
    try expectKey("A", charKey('a', shift_held), .{});
    try expectKey("\x01", charKey('a', ctrl_held), .{});
    try expectKey("\x1b\x01", charKey('a', .{ .ctrl = true, .alt = true }), .{});
    try expectKey("\x1ba", charKey('a', alt_held), .{});
    try expectKey("\x00", charKey(' ', ctrl_held), .{});
    try expectKey("\x1c", charKey('\\', ctrl_held), .{});
    // Control and i, m and [ would be tab, enter and escape; they keep
    // their own identity as CSI u.
    try expectKey("\x1b[105;5u", charKey('i', ctrl_held), .{});
    try expectKey("\x1b[109;5u", charKey('m', ctrl_held), .{});
    try expectKey("\x1b[91;5u", charKey('[', ctrl_held), .{});
    try expectKey("\x1b[97;6u", charKey('a', .{ .ctrl = true, .shift = true }), .{});
    // Shift that made the character is not reported beside it.
    var bang = charKey('1', .{ .ctrl = true, .shift = true });
    bang.shifted = '!';
    try expectKey("\x1b[33;5u", bang, .{});
    // A key on another layout is control and the key in its place.
    var cyrillic = charKey(0x441, ctrl_held);
    cyrillic.base = 'c';
    try expectKey("\x03", cyrillic, .{});
    try expectKey("\x1b\u{e9}", charKey(0xe9, alt_held), .{});
}

test "modifyOtherKeys writes every modified key it can as CSI 27 ; m ; code ~" {
    const enc: KeyEncoding = .{ .modify_other_keys = true };
    try expectKey("\x1b[27;5;97~", charKey('a', ctrl_held), enc);
    try expectKey("\x1b[27;2;65~", texted('a', shift_held, "A"), enc);
    try expectKey("\x1b[27;2;32~", texted(' ', shift_held, " "), enc);
    try expectKey("!", texted('1', shift_held, "!"), enc);
    try expectKey("\x1b[27;3;97~", charKey('a', alt_held), enc);
    try expectKey("a", texted('a', .{}, "a"), enc);
}

test "a release is legacy silence, and a repeat is a press" {
    try expectKey("", .{ .key = .{ .char = 'a' }, .kind = .release }, .{});
    try expectKey("a", .{ .key = .{ .char = 'a' }, .kind = .repeat }, .{});
}
