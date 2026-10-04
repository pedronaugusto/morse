//! Keys and their text, shared by stream and console decoders.
const std = @import("std");

/// A key, either the codepoint it stands for or the name it goes by.
///
/// `char` carries the key itself, not the character it produced: the terminal
/// reports the unshifted, current-layout codepoint, so `shift` and `a` is
/// `.{ .char = 'a' }` with `Modifiers.shift` set, and the `A` that reached the
/// screen is in `KeyEvent.shifted` or `KeyEvent.text` when the terminal said.
pub const Key = union(enum) {
    /// A key that stands for a Unicode codepoint — a letter, a digit, a
    /// symbol, or space.
    char: u21,
    /// A function key, numbered from 1. Terminals report up to F35; the
    /// legacy sequences stop at F20.
    f: u8,

    /// The Escape key. Reported only when the parser can tell it from the
    /// start of a sequence — see `KeyParser.flush`.
    escape,
    /// Return, whether the terminal spelled it `CR` or `LF`.
    enter,
    /// Tab. Shift and tab arrives as this key with `Modifiers.shift`, whether
    /// the terminal spelled it `CSI Z` or `CSI 9 ; 2 u`.
    tab,
    /// Backspace, which terminals send as `DEL` rather than `BS`.
    backspace,
    /// Insert.
    insert,
    /// Delete, the key that removes the character to the right.
    delete,

    /// The left arrow.
    left,
    /// The right arrow.
    right,
    /// The up arrow.
    up,
    /// The down arrow.
    down,
    /// Page up, sometimes labelled Prior.
    page_up,
    /// Page down, sometimes labelled Next.
    page_down,
    /// Home.
    home,
    /// End.
    end,

    /// Caps lock, reported as a key only by terminals told to report every
    /// key; otherwise it is only a modifier.
    caps_lock,
    /// Scroll lock.
    scroll_lock,
    /// Num lock.
    num_lock,
    /// Print screen, which most window systems intercept before a terminal
    /// ever sees it.
    print_screen,
    /// Pause, or Break.
    pause,
    /// The menu key, which opens a context menu.
    menu,

    /// Keypad 0.
    kp_0,
    /// Keypad 1.
    kp_1,
    /// Keypad 2.
    kp_2,
    /// Keypad 3.
    kp_3,
    /// Keypad 4.
    kp_4,
    /// Keypad 5.
    kp_5,
    /// Keypad 6.
    kp_6,
    /// Keypad 7.
    kp_7,
    /// Keypad 8.
    kp_8,
    /// Keypad 9.
    kp_9,
    /// The keypad decimal point, which is a comma on some layouts.
    kp_decimal,
    /// Keypad divide.
    kp_divide,
    /// Keypad multiply.
    kp_multiply,
    /// Keypad subtract.
    kp_subtract,
    /// Keypad add.
    kp_add,
    /// Keypad enter, which is a different key from `enter` only when the
    /// terminal is in a protocol that can say so.
    kp_enter,
    /// Keypad equals, present on Mac keypads.
    kp_equal,
    /// The keypad separator, a thousands separator on some layouts.
    kp_separator,
    /// Keypad left, what keypad 4 sends with num lock off.
    kp_left,
    /// Keypad right, what keypad 6 sends with num lock off.
    kp_right,
    /// Keypad up, what keypad 8 sends with num lock off.
    kp_up,
    /// Keypad down, what keypad 2 sends with num lock off.
    kp_down,
    /// Keypad page up, what keypad 9 sends with num lock off.
    kp_page_up,
    /// Keypad page down, what keypad 3 sends with num lock off.
    kp_page_down,
    /// Keypad home, what keypad 7 sends with num lock off.
    kp_home,
    /// Keypad end, what keypad 1 sends with num lock off.
    kp_end,
    /// Keypad insert, what keypad 0 sends with num lock off.
    kp_insert,
    /// Keypad delete, what the keypad decimal point sends with num lock off.
    kp_delete,
    /// Keypad 5 with num lock off, which points at nothing and is therefore
    /// called Begin.
    kp_begin,

    /// Play.
    media_play,
    /// Pause.
    media_pause,
    /// The single key that is play when stopped and pause when playing.
    media_play_pause,
    /// Reverse.
    media_reverse,
    /// Stop.
    media_stop,
    /// Fast forward.
    media_fast_forward,
    /// Rewind.
    media_rewind,
    /// Next track.
    media_track_next,
    /// Previous track.
    media_track_previous,
    /// Record.
    media_record,
    /// Volume down.
    lower_volume,
    /// Volume up.
    raise_volume,
    /// Mute.
    mute_volume,

    /// The left shift key itself, not shift as a modifier.
    left_shift,
    /// The left control key itself.
    left_ctrl,
    /// The left alt key itself.
    left_alt,
    /// The left super key itself — Windows, Command, or whatever the keyboard
    /// calls it.
    left_super,
    /// The left hyper key itself, which X11 layouts can define.
    left_hyper,
    /// The left meta key itself.
    left_meta,
    /// The right shift key itself.
    right_shift,
    /// The right control key itself.
    right_ctrl,
    /// The right alt key itself, which is AltGr on many layouts.
    right_alt,
    /// The right super key itself.
    right_super,
    /// The right hyper key itself.
    right_hyper,
    /// The right meta key itself.
    right_meta,
    /// The ISO level 3 shift, which is what AltGr is when a layout defines it
    /// as a level rather than as alt.
    iso_level3_shift,
    /// The ISO level 5 shift.
    iso_level5_shift,
};

/// Which modifiers were held, in the bit order the kitty keyboard protocol
/// numbers them: `shift` is bit 1.
///
/// A terminal spells these as the bitmask plus one, so a parameter of `5` is
/// bits `4`, which is `ctrl`. That offset lives in the parser, not here.
pub const Modifiers = packed struct(u8) {
    /// Shift (bit 1).
    shift: bool = false,
    /// Alt, which is also Option and Meta on some keyboards (bit 2).
    alt: bool = false,
    /// Control (bit 4).
    ctrl: bool = false,
    /// Super — Windows or Command (bit 8).
    super: bool = false,
    /// Hyper (bit 16).
    hyper: bool = false,
    /// Meta, as distinct from alt, on the keyboards that have both (bit 32).
    meta: bool = false,
    /// Caps lock was on (bit 64). A lock state, not a key being held, and
    /// only reported by terminals asked for every key.
    caps_lock: bool = false,
    /// Num lock was on (bit 128). A lock state, as `caps_lock` is.
    num_lock: bool = false,

    /// The integer the protocol spells these modifiers with, before the
    /// protocol's plus-one.
    pub fn bits(mods: Modifiers) u8 {
        return @bitCast(mods);
    }

    /// The modifiers a protocol bitmask stands for, after the protocol's
    /// plus-one has been taken off.
    pub fn fromBits(value: u8) Modifiers {
        return @bitCast(value);
    }

    /// Whether any modifier at all was held. The lock states count.
    pub fn any(mods: Modifiers) bool {
        return mods.bits() != 0;
    }
};

/// What happened to the key.
///
/// Kitty reports repeats and releases when `KittyFlags.report_event_types`
/// is enabled. Win32 input mode also carries repeats and releases;
/// `KeyParser.report_key_up` decides whether its releases are returned.
/// Plain text and the legacy keyboard sequences report presses.
pub const Kind = enum {
    /// The key went down.
    press,
    /// The key was held and the keyboard repeated it.
    repeat,
    /// The key came up.
    release,
};

/// One keypress.
///
/// A value, not a view: nothing here borrows, so an event can be stored,
/// compared and passed on long after the bytes it came from are gone.
pub const KeyEvent = struct {
    /// The most bytes of text one event carries. Four codepoints, which is
    /// more than any key produces in practice and the most the protocol's
    /// sub-parameters can spell.
    pub const text_capacity = 16;

    /// Which key.
    key: Key,
    /// Which modifiers were held.
    mods: Modifiers = .{},
    /// Press, repeat or release.
    kind: Kind = .press,
    /// Storage for `text`. Zeroed rather than undefined so that two events
    /// carrying the same text compare equal.
    text_buffer: [text_capacity]u8 = @splat(0),
    /// How many bytes of `text_buffer` are text.
    text_len: u8 = 0,
    /// The codepoint this key produces with shift held, when the terminal was
    /// asked for alternate keys and this key has one. Null otherwise.
    shifted: ?u21 = null,
    /// The codepoint this key has in the keyboard's base layout, when the
    /// terminal was asked for alternate keys. What a program binding to
    /// physical positions rather than to letters uses, so that a shortcut on
    /// a Dvorak layout stays where the fingers are.
    base: ?u21 = null,

    /// The text this keypress produced, as UTF-8, or an empty slice.
    ///
    /// Set from the bytes themselves when the key arrived as plain input, and
    /// from the protocol's associated-text parameter when the terminal was
    /// asked for it with `report_associated_text`. It is deliberately **not**
    /// guessed from `key`: a terminal reporting `CSI 97 u` for `a` has not
    /// said what `a` produced on that layout with those modifiers, and a
    /// parser inventing an answer would be wrong exactly where it matters —
    /// dead keys, input methods, and a shifted key whose shifted form is not
    /// the uppercase of its unshifted one.
    pub fn text(ev: *const KeyEvent) []const u8 {
        return ev.text_buffer[0..ev.text_len];
    }

    /// The keypress that types `cluster` with `mods` held: the `.char` of
    /// its first codepoint, carrying the cluster as its text.
    ///
    /// For a program that holds text and wants it as keys: a burst of typed
    /// text read cluster by cluster, a script of keystrokes. The text is
    /// set as the parser sets it, so a key held with anything but shift, a
    /// control code, a cluster longer than `text_capacity` or bytes that are
    /// not UTF-8 type no text, and the key is all there is. U+FFFD stands for
    /// a cluster that does not begin with a codepoint, the empty one
    /// included.
    pub fn typed(cluster: []const u8, mods: Modifiers) KeyEvent {
        const cp = firstCodepoint(cluster) orelse 0xfffd;
        var ev: KeyEvent = .{ .key = .{ .char = cp }, .mods = mods };
        if (std.unicode.utf8ValidateSlice(cluster)) setText(&ev, cluster);
        return ev;
    }

    /// Whether this is `on` with `mods`, however the terminal encoded it.
    /// Compares the key, then its single codepoint of typed text, then the
    /// alternate shifted codepoint. Caps lock and num lock are ignored on
    /// both sides. Shift implicit in typed text or an alternate codepoint
    /// need not be present in `mods`; every other modifier must agree.
    /// A cluster of more than one codepoint names no key. `kind` is left to
    /// the caller, so presses, repeats and releases match alike.
    pub fn matches(ev: KeyEvent, on: Key, mods: Modifiers) bool {
        const produced = ev.text();
        if (produced.len > 0 and (std.unicode.utf8CountCodepoints(produced) catch 2) != 1) return false;
        const have = unlocked(ev.mods);
        const want = unlocked(mods);
        if (std.meta.eql(ev.key, on) and have == want) return true;
        const cp = switch (on) {
            .char => |c| c,
            else => return false,
        };
        if (produced.len > 0) {
            const wanted_cp: u21 = if (cp < 128 and want.shift) std.ascii.toUpper(@intCast(cp)) else cp;
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(wanted_cp, &buf) catch return false;
            if (std.mem.eql(u8, produced, buf[0..n]) and unshifted(have) == unshifted(want)) return true;
        }
        if (ev.shifted) |sc| if (have.shift and sc == cp and unshifted(have) == unshifted(want)) return true;
        return false;
    }

    fn unlocked(mods: Modifiers) Modifiers {
        var out = mods;
        out.caps_lock = false;
        out.num_lock = false;
        return out;
    }

    fn unshifted(mods: Modifiers) Modifiers {
        var out = mods;
        out.shift = false;
        return out;
    }
};

/// How big the terminal became, as an in-band resize report gives it.
///
/// The pixel fields are the size of the text area, not of the window: a
/// terminal with a border reports the inside of it. Both are zero on a
/// terminal that does not know its own pixel size, which is every terminal
/// that is not drawing the glyphs itself -- a multiplexer, most obviously --
/// so a program that divides by them must check first.
pub const Resize = extern struct {
    /// Rows of text.
    rows: u32,
    /// Columns of text.
    cols: u32,
    /// The height of the text area in pixels, or zero when unknown.
    ypixels: u32 = 0,
    /// The width of the text area in pixels, or zero when unknown.
    xpixels: u32 = 0,
};

/// The key an ASCII byte stands for, with `mods` gaining the control the
/// terminal folded into it.
///
/// Shared with the Windows console paths, which carry the same control codes
/// in a field rather than in the stream, so that one byte means one key
/// however it arrived.
pub fn asciiKey(b: u8, mods: *Modifiers) Key {
    return switch (b) {
        // Control and space is the terminal's name for a zero byte.
        0x00 => blk: {
            mods.ctrl = true;
            break :blk .{ .char = ' ' };
        },
        0x01...0x07, 0x0b, 0x0c, 0x0e...0x1a => blk: {
            mods.ctrl = true;
            break :blk .{ .char = 'a' + @as(u21, b) - 1 };
        },
        // A terminal sends DEL for backspace, so BS is the modified one.
        0x08 => blk: {
            mods.ctrl = true;
            break :blk .backspace;
        },
        0x09 => .tab,
        // Both, because which one Return sends depends on the line
        // discipline and neither is distinguishable from control and J or M.
        0x0a, 0x0d => .enter,
        0x1b => .escape,
        0x1c => blk: {
            mods.ctrl = true;
            break :blk .{ .char = '\\' };
        },
        0x1d => blk: {
            mods.ctrl = true;
            break :blk .{ .char = ']' };
        },
        0x1e => blk: {
            mods.ctrl = true;
            break :blk .{ .char = '^' };
        },
        0x1f => blk: {
            mods.ctrl = true;
            break :blk .{ .char = '_' };
        },
        0x7f => .backspace,
        else => .{ .char = b },
    };
}

/// A codepoint a terminal can legally have sent, or null.
pub fn codepoint(value: u32) ?u21 {
    if (value > 0x10ffff) return null;
    if (value >= 0xd800 and value <= 0xdfff) return null;
    return @intCast(value);
}

/// The key a codepoint in a `CSI u` or `modifyOtherKeys` sequence names.
///
/// Most codepoints are the key itself. The rest are either a C0 control the
/// protocol kept for the key it has always meant, or one of the private-use
/// codepoints the kitty protocol assigns to keys Unicode has no character
/// for. A private-use codepoint in that assigned block that this package does
/// not know is not a key it will invent a meaning for: it returns null and
/// the sequence comes back as `Event.unhandled`.
pub fn protocolKey(cp: u32) ?Key {
    return switch (cp) {
        9 => .tab,
        13 => .enter,
        27 => .escape,
        127 => .backspace,

        57358 => .caps_lock,
        57359 => .scroll_lock,
        57360 => .num_lock,
        57361 => .print_screen,
        57362 => .pause,
        57363 => .menu,

        57376...57398 => .{ .f = @intCast(cp - 57376 + 13) },

        57399 => .kp_0,
        57400 => .kp_1,
        57401 => .kp_2,
        57402 => .kp_3,
        57403 => .kp_4,
        57404 => .kp_5,
        57405 => .kp_6,
        57406 => .kp_7,
        57407 => .kp_8,
        57408 => .kp_9,
        57409 => .kp_decimal,
        57410 => .kp_divide,
        57411 => .kp_multiply,
        57412 => .kp_subtract,
        57413 => .kp_add,
        57414 => .kp_enter,
        57415 => .kp_equal,
        57416 => .kp_separator,
        57417 => .kp_left,
        57418 => .kp_right,
        57419 => .kp_up,
        57420 => .kp_down,
        57421 => .kp_page_up,
        57422 => .kp_page_down,
        57423 => .kp_home,
        57424 => .kp_end,
        57425 => .kp_insert,
        57426 => .kp_delete,
        57427 => .kp_begin,

        57428 => .media_play,
        57429 => .media_pause,
        57430 => .media_play_pause,
        57431 => .media_reverse,
        57432 => .media_stop,
        57433 => .media_fast_forward,
        57434 => .media_rewind,
        57435 => .media_track_next,
        57436 => .media_track_previous,
        57437 => .media_record,
        57438 => .lower_volume,
        57439 => .raise_volume,
        57440 => .mute_volume,

        57441 => .left_shift,
        57442 => .left_ctrl,
        57443 => .left_alt,
        57444 => .left_super,
        57445 => .left_hyper,
        57446 => .left_meta,
        57447 => .right_shift,
        57448 => .right_ctrl,
        57449 => .right_alt,
        57450 => .right_super,
        57451 => .right_hyper,
        57452 => .right_meta,
        57453 => .iso_level3_shift,
        57454 => .iso_level5_shift,

        // The rest of the block the protocol reserves for functional keys.
        57344...57357, 57364...57375, 57455...57599 => null,

        else => if (codepoint(cp)) |value| Key{ .char = value } else null,
    };
}

/// The codepoint `protocolKey` reads as `key`, or null for a key the
/// protocol spells by number and final byte instead: the arrows, home,
/// end, page up and down, insert, delete and the first twelve function
/// keys.
///
/// The inverse of `protocolKey`, kept beside it so the two directions are
/// one table read both ways.
pub fn protocolCode(key: Key) ?u21 {
    return switch (key) {
        .char => |cp| cp,
        .tab => 9,
        .enter => 13,
        .escape => 27,
        .backspace => 127,
        .f => |n| if (n >= 13 and n <= 35) 57376 + @as(u21, n - 13) else null,
        .insert, .delete, .left, .right, .up, .down, .page_up, .page_down, .home, .end => null,
        else => blk: {
            // Every other named key has a codepoint in the protocol's block,
            // in the order `Key` declares them from caps lock on.
            const first = @intFromEnum(std.meta.Tag(Key).caps_lock);
            const at = @intFromEnum(std.meta.activeTag(key)) - first;
            break :blk named_codes[at];
        },
    };
}

/// The protocol's codepoints for the named keys from `caps_lock` to the
/// end of `Key`, in declaration order.
const named_codes = [_]u21{
    57358, 57359, 57360, 57361, 57362, 57363, // locks, print screen, pause, menu
    57399, 57400, 57401, 57402, 57403, 57404, 57405, 57406, 57407, 57408, // keypad digits
    57409, 57410, 57411, 57412, 57413, 57414, 57415, 57416, // keypad operators, enter, equal, separator
    57417, 57418, 57419, 57420, 57421, 57422, 57423, 57424, 57425, 57426, 57427, // keypad navigation
    57428, 57429, 57430, 57431, 57432, 57433, 57434, 57435, 57436, 57437, 57438, 57439, 57440, // media
    57441, 57442, 57443, 57444, 57445, 57446, 57447, 57448, 57449, 57450, 57451, 57452, 57453, 57454, // modifiers
};

comptime {
    const tags = @typeInfo(Key).@"union".fields;
    std.debug.assert(named_codes.len == tags.len - @intFromEnum(std.meta.Tag(Key).caps_lock));
}

/// Records the bytes a key produced, when it produced any.
///
/// A key held with anything but shift produced a control code rather than
/// text, and a control code is not what the user meant to type.
pub fn setText(ev: *KeyEvent, bytes: []const u8) void {
    switch (ev.key) {
        .char => |cp| if (cp >= 0x20 and cp != 0x7f) {
            const m = ev.mods;
            if (m.ctrl or m.alt or m.super or m.hyper or m.meta) return;
            if (bytes.len > KeyEvent.text_capacity) return;
            @memcpy(ev.text_buffer[0..bytes.len], bytes);
            ev.text_len = @intCast(bytes.len);
        },
        else => {},
    }
}

/// The codepoint `bytes` begin with, or null when they do not begin with
/// one.
fn firstCodepoint(bytes: []const u8) ?u21 {
    if (bytes.len == 0) return null;
    const n = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return null;
    if (bytes.len < n) return null;
    return std.unicode.utf8Decode(bytes[0..n]) catch null;
}

test "protocolCode and protocolKey are one table read both ways" {
    const tags = @typeInfo(Key).@"union".fields;
    inline for (tags) |field| {
        const key: Key = if (field.type == void) @unionInit(Key, field.name, {}) else switch (field.type) {
            u21 => @unionInit(Key, field.name, 'a'),
            u8 => @unionInit(Key, field.name, 20),
            else => unreachable,
        };
        if (protocolCode(key)) |code| try std.testing.expectEqual(key, protocolKey(code).?);
    }
    var n: u8 = 13;
    while (n <= 35) : (n += 1) try std.testing.expectEqual(Key{ .f = n }, protocolKey(protocolCode(.{ .f = n }).?).?);
    try std.testing.expectEqual(@as(?u21, null), protocolCode(.{ .f = 12 }));
    try std.testing.expectEqual(@as(?u21, null), protocolCode(.up));
}

test "typed is the key a cluster types, carrying the cluster as its text" {
    const flag = KeyEvent.typed("\u{1f1f5}\u{1f1f9}", .{});
    try std.testing.expectEqual(Key{ .char = 0x1f1f5 }, flag.key);
    try std.testing.expectEqualStrings("\u{1f1f5}\u{1f1f9}", flag.text());

    const shifted = KeyEvent.typed("A", .{ .shift = true });
    try std.testing.expectEqualStrings("A", shifted.text());
    try std.testing.expect(shifted.mods.shift);
    try std.testing.expect(shifted.matches(.{ .char = 'a' }, .{ .shift = true }));

    const held = KeyEvent.typed("c", .{ .ctrl = true });
    try std.testing.expectEqual(Key{ .char = 'c' }, held.key);
    try std.testing.expectEqualStrings("", held.text());
    try std.testing.expect(held.matches(.{ .char = 'c' }, .{ .ctrl = true }));
}

test "typed carries no text a parser would not" {
    const long = "e\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}";
    try std.testing.expect(long.len > KeyEvent.text_capacity);
    const too_long = KeyEvent.typed(long, .{});
    try std.testing.expectEqual(Key{ .char = 'e' }, too_long.key);
    try std.testing.expectEqualStrings("", too_long.text());

    try std.testing.expectEqualStrings("", KeyEvent.typed("\t", .{}).text());
    try std.testing.expectEqualStrings("", KeyEvent.typed("a\xff", .{}).text());
    try std.testing.expectEqual(Key{ .char = 0xfffd }, KeyEvent.typed("\xff", .{}).key);
    try std.testing.expectEqual(Key{ .char = 0xfffd }, KeyEvent.typed("", .{}).key);

    // The same event the parser reads off the same bytes.
    var parsed: KeyEvent = .{ .key = .{ .char = 0xe9 } };
    setText(&parsed, "\u{e9}");
    try std.testing.expectEqual(parsed, KeyEvent.typed("\u{e9}", .{}));
}
