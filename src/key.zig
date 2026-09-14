//! Keyboard input: the bytes a terminal sends when a key goes down, turned
//! back into the key.
//!
//! This is the one place in `morse` that holds state between calls, and it
//! holds it in a buffer the caller owns. It has to: a key arrives as up to a
//! few dozen bytes and a read can end anywhere, so something has to remember
//! half a sequence until the rest of it arrives. `KeyParser` is that
//! something, and nothing else in the package needs it.
//!
//! Four keyboard protocols reach a program through the same byte stream and
//! `KeyParser` reads all of them:
//!
//! - the kitty keyboard protocol, at every flag level — `CSI u` with the
//!   codepoint, the alternate keys, the event type and the associated text;
//! - the legacy xterm and VT sequences — `CSI` and `SS3` arrows, the
//!   `CSI n ~` function keys, and modifiers as a `;2` to `;8` parameter;
//! - xterm's `modifyOtherKeys`, which spells a modified key as
//!   `CSI 27 ; modifiers ; codepoint ~`;
//! - and plain text, which is just UTF-8 with the C0 controls standing for
//!   the keys they have always stood for.
//!
//! Bracketed paste and focus reporting arrive on the same stream, so they are
//! events here too rather than a second parser over the same bytes.
//!
//! What the parser cannot decode it still frames. A mouse report, a reply to
//! a query, an OSC the terminal sent back: each comes out as `Event.unhandled`
//! holding the whole sequence, for the caller to hand to `parseMouse`,
//! `parseModeReply`, `parseColorReply` or whichever parser reads it. Framing
//! the stream once, in one place, is the point.

const std = @import("std");
const corpus = @import("corpus.zig");
const seq = @import("seq.zig");

//=========================================================================
// What a key is.
//=========================================================================

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
/// Only `press` arrives from a terminal that was not asked for event types;
/// `kittyKeyboardPush` with `report_event_types` is what turns the other two
/// on, and nothing else can produce them.
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
};

/// How big the terminal became, as an in-band resize report gives it.
///
/// The pixel fields are the size of the text area, not of the window: a
/// terminal with a border reports the inside of it. Both are zero on a
/// terminal that does not know its own pixel size, which is every terminal
/// that is not drawing the glyphs itself -- a multiplexer, most obviously --
/// so a program that divides by them must check first.
pub const Resize = struct {
    /// Rows of text.
    rows: u32,
    /// Columns of text.
    cols: u32,
    /// The height of the text area in pixels, or zero when unknown.
    ypixels: u32 = 0,
    /// The width of the text area in pixels, or zero when unknown.
    xpixels: u32 = 0,
};

/// One thing that arrived on the terminal's input.
pub const Event = union(enum) {
    /// A key went down, repeated, or came up.
    key: KeyEvent,
    /// A bracketed paste began (`CSI 200 ~`). What follows until `paste_end`
    /// was pasted rather than typed.
    paste_start,
    /// A bracketed paste ended (`CSI 201 ~`).
    paste_end,
    /// The window took focus (`CSI I`).
    focus_in,
    /// The window lost focus (`CSI O`).
    focus_out,
    /// The terminal resized, and said so on the input stream rather than
    /// through a signal (`CSI 48 ; ... t`, DEC mode 2048).
    ///
    /// Only a terminal asked for `inBandResize` sends these. It is the one
    /// way a program learns its own size without asking the operating
    /// system, which is what makes it work unchanged down a pipe, inside a
    /// multiplexer, and on a machine whose terminal is somewhere else.
    resize: Resize,
    /// A complete sequence the parser framed but does not read as input: a
    /// mouse report, a reply to a query, an OSC or DCS the terminal sent
    /// back. Hand it to the parser that does read it.
    ///
    /// Borrowed from the parser's buffer, and valid only until the next call
    /// to `Events.next`, `KeyParser.feed` or `KeyParser.flush`. Copy it if it
    /// has to outlive that.
    unhandled: []const u8,
};

//=========================================================================
// The parser.
//=========================================================================

/// A byte stream turned into events, over a buffer the caller owns.
///
/// The buffer holds only what has arrived and not yet been read as a
/// sequence, so `min_buffer` bytes is enough for keys alone. A program that
/// also asks the terminal for the clipboard wants kilobytes, because an
/// OSC 52 reply is as long as what was copied and it arrives on this same
/// stream: a sequence longer than the buffer is the one thing this parser
/// drops.
///
/// The parser reads the input; it does not read the terminal. When a key
/// event arrives is the caller's problem, and so is the timeout the lone
/// `ESC` needs — see `flush`.
pub const KeyParser = struct {
    /// The smallest buffer this parser accepts. Enough for every sequence a
    /// terminal sends for a key, with room to spare.
    pub const min_buffer = 64;

    /// The caller's buffer. Bytes between `start` and `end` are what has
    /// arrived and not yet been read.
    buffer: []u8,
    /// Where the unread bytes begin.
    start: usize = 0,
    /// Where the unread bytes end.
    end: usize = 0,

    /// A parser over `buffer`, which must be at least `min_buffer` bytes.
    pub fn init(buffer: []u8) KeyParser {
        std.debug.assert(buffer.len >= min_buffer);
        return .{ .buffer = buffer };
    }

    /// Hands `bytes` to the parser and returns the events they complete.
    ///
    /// **Run the returned iterator to null before the next call.** It is what
    /// moves bytes out of `bytes` and into the parser, so an iterator
    /// abandoned early leaves the rest of that read unparsed and the next
    /// `feed` replaces it. The natural read loop does the right thing:
    ///
    /// ```zig
    /// var events = parser.feed(buf[0..n]);
    /// while (events.next()) |event| { ... }
    /// ```
    pub fn feed(p: *KeyParser, bytes: []const u8) Events {
        return .{ .parser = p, .fresh = bytes };
    }

    /// The bytes held back because they are the start of a sequence and the
    /// rest of it has not arrived.
    ///
    /// Empty whenever the last iterator was run to null and the input ended
    /// on a sequence boundary. A caller timing the lone `ESC` watches this:
    /// a single `0x1b` here, unchanged since the last read, is a user who
    /// pressed Escape.
    ///
    /// Borrowed from the parser's buffer, on the same terms as
    /// `Event.unhandled`.
    pub fn pending(p: *const KeyParser) []const u8 {
        return p.buffer[p.start..p.end];
    }

    /// Decides what a pending sequence was, on the caller's timeout, and
    /// empties the buffer either way.
    ///
    /// A lone `ESC` is the ambiguity every terminal program has: the byte is
    /// both the Escape key and the first byte of every sequence, and nothing
    /// in the stream says which. This parser never guesses — it holds the
    /// byte and reports nothing — so a program that wants Escape must call
    /// this when the input has been quiet for long enough. How long is
    /// policy, not protocol; a few tens of milliseconds is what terminal
    /// programs use, and a terminal asked for
    /// `KittyFlags.disambiguate_escape_codes` removes the need entirely by
    /// spelling Escape as `CSI 27 u`.
    ///
    /// Returns the Escape key for a pending lone `ESC`, and `alt` with `[`
    /// or `O` for a pending two-byte `ESC [` or `ESC O`, which are the other
    /// two byte strings that are both a key and the start of a sequence.
    /// Anything longer is a sequence the terminal began and did not finish:
    /// it is discarded and this returns null.
    pub fn flush(p: *KeyParser) ?Event {
        const held = p.pending();
        defer {
            p.start = 0;
            p.end = 0;
        }
        if (held.len == 0 or held[0] != seq.esc) return null;
        if (held.len == 1) return .{ .key = .{ .key = .escape } };
        if (held.len == 2 and (held[1] == '[' or held[1] == 'O')) {
            return .{ .key = .{ .key = .{ .char = held[1] }, .mods = .{ .alt = true } } };
        }
        return null;
    }

    /// Throws away whatever is pending. What a program calls after it has
    /// been suspended, or after the terminal has been reset underneath it,
    /// because the bytes from before are no longer part of anything.
    pub fn reset(p: *KeyParser) void {
        p.start = 0;
        p.end = 0;
    }

    /// Moves the unread bytes to the front, making room at the end.
    fn compact(p: *KeyParser) void {
        if (p.start == 0) return;
        std.mem.copyForwards(u8, p.buffer, p.buffer[p.start..p.end]);
        p.end -= p.start;
        p.start = 0;
    }
};

/// The events one `feed` completes, in the order they arrived.
pub const Events = struct {
    /// The parser these events come out of, and whose buffer they borrow.
    parser: *KeyParser,
    /// What is left of the bytes handed to `feed`.
    fresh: []const u8,

    /// The next event, or null when what is left is a partial sequence — or
    /// nothing.
    ///
    /// Null does not mean the parser is empty: see `KeyParser.pending`.
    pub fn next(it: *Events) ?Event {
        const p = it.parser;
        while (true) {
            // Topping up here rather than in `feed` is what lets one feed of
            // many kilobytes drain through a buffer of a few dozen bytes.
            // Room is made only when there is something to put in it, so a
            // quiet drain does not memmove the buffer once per keystroke.
            if (it.fresh.len != 0 and p.end == p.buffer.len) p.compact();
            const room = p.buffer.len - p.end;
            const take = @min(room, it.fresh.len);
            @memcpy(p.buffer[p.end..][0..take], it.fresh[0..take]);
            p.end += take;
            it.fresh = it.fresh[take..];

            if (p.start == p.end) return null;

            switch (decode(p.buffer[p.start..p.end])) {
                .ready => |done| {
                    p.start += done.len;
                    return done.event;
                },
                .skip => |n| {
                    p.start += n;
                    continue;
                },
                .incomplete => {
                    // A full buffer that is still the start of something is a
                    // sequence longer than the caller sized for. Nothing more
                    // can arrive to complete it, so it goes; this is the only
                    // place bytes are dropped.
                    if (p.end - p.start == p.buffer.len) {
                        p.start = 0;
                        p.end = 0;
                        continue;
                    }
                    return null;
                },
            }
        }
    }
};

//=========================================================================
// Decoding one sequence off the front of a byte string.
//=========================================================================

/// What the decoder made of the bytes in front of it.
const Decoded = union(enum) {
    /// An event, and how many bytes it used.
    ready: struct { event: Event, len: usize },
    /// The start of something; more bytes may complete it.
    incomplete,
    /// Not the start of anything. Drop this many bytes and look again.
    skip: usize,
};

fn ready(event: Event, len: usize) Decoded {
    return .{ .ready = .{ .event = event, .len = len } };
}

/// Reads one event off the front of `bytes`, which is never empty.
fn decode(bytes: []const u8) Decoded {
    std.debug.assert(bytes.len != 0);
    if (bytes[0] == seq.esc) return decodeEscape(bytes);
    return decodePlain(bytes, .{}, 0);
}

/// Reads a key that is not introduced by `ESC`: a C0 control, or UTF-8 text.
///
/// `prefix` is how many bytes came before `bytes` in the sequence being
/// decoded, so that the `ESC`-prefixed alt form can reuse this and still
/// report the right length.
fn decodePlain(bytes: []const u8, mods: Modifiers, prefix: usize) Decoded {
    const b = bytes[0];
    var m = mods;
    const key: Key = switch (b) {
        // Control and space is the terminal's name for a zero byte.
        0x00 => blk: {
            m.ctrl = true;
            break :blk .{ .char = ' ' };
        },
        0x01...0x07, 0x0b, 0x0c, 0x0e...0x1a => blk: {
            m.ctrl = true;
            break :blk .{ .char = 'a' + @as(u21, b) - 1 };
        },
        // A terminal sends DEL for backspace, so BS is the modified one.
        0x08 => blk: {
            m.ctrl = true;
            break :blk .backspace;
        },
        0x09 => .tab,
        // Both, because which one Return sends depends on the line
        // discipline and neither is distinguishable from control and J or M.
        0x0a, 0x0d => .enter,
        0x1b => .escape,
        0x1c => blk: {
            m.ctrl = true;
            break :blk .{ .char = '\\' };
        },
        0x1d => blk: {
            m.ctrl = true;
            break :blk .{ .char = ']' };
        },
        0x1e => blk: {
            m.ctrl = true;
            break :blk .{ .char = '^' };
        },
        0x1f => blk: {
            m.ctrl = true;
            break :blk .{ .char = '_' };
        },
        0x7f => .backspace,
        0x20...0x7e => .{ .char = b },
        else => return decodeUtf8(bytes, m, prefix),
    };

    var ev: KeyEvent = .{ .key = key, .mods = m };
    setText(&ev, bytes[0..1]);
    return ready(.{ .key = ev }, prefix + 1);
}

/// Reads one UTF-8 codepoint as a key.
fn decodeUtf8(bytes: []const u8, mods: Modifiers, prefix: usize) Decoded {
    const n = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return .{ .skip = prefix + 1 };
    if (bytes.len < n) return .incomplete;
    const cp = std.unicode.utf8Decode(bytes[0..n]) catch return .{ .skip = prefix + 1 };

    var ev: KeyEvent = .{ .key = .{ .char = cp }, .mods = mods };
    setText(&ev, bytes[0..n]);
    return ready(.{ .key = ev }, prefix + n);
}

/// Records the bytes a key produced, when it produced any.
///
/// A key held with anything but shift produced a control code rather than
/// text, and a control code is not what the user meant to type.
fn setText(ev: *KeyEvent, bytes: []const u8) void {
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

/// Reads a sequence introduced by `ESC`, which is every sequence there is —
/// and also alt, which terminals spell by putting an `ESC` in front of the
/// key's own bytes.
fn decodeEscape(bytes: []const u8) Decoded {
    // A lone ESC is both the Escape key and the start of everything else.
    // Nothing in the stream resolves that, so it waits; see KeyParser.flush.
    if (bytes.len == 1) return .incomplete;

    return switch (bytes[1]) {
        '[' => decodeCsi(bytes),
        'O' => decodeSs3(bytes),
        // OSC, DCS, SOS, PM and APC: a string with a terminator, framed here
        // and read by whichever parser the caller hands it to.
        ']', 'P', 'X', '^', '_' => decodeString(bytes),
        // Two escapes running. The first is a key, because reading it as alt
        // would swallow the second one's sequence.
        seq.esc => ready(.{ .key = .{ .key = .escape } }, 1),
        // ESC, an intermediate, a final: a character set designation and its
        // kin. Framed, not read.
        0x20...0x2f => decodeShortEscape(bytes),
        else => decodePlain(bytes[1..], .{ .alt = true }, 1),
    };
}

/// Frames `ESC`, one or more intermediates, and a final byte.
fn decodeShortEscape(bytes: []const u8) Decoded {
    var i: usize = 1;
    while (i < bytes.len and bytes[i] >= 0x20 and bytes[i] <= 0x2f) : (i += 1) {}
    if (i >= bytes.len) return .incomplete;
    if (bytes[i] < 0x30 or bytes[i] > 0x7e) return .{ .skip = 1 };
    return ready(.{ .unhandled = bytes[0 .. i + 1] }, i + 1);
}

/// Frames a control string: `OSC`, `DCS`, `SOS`, `PM` or `APC` up to its
/// terminator.
///
/// `ST` is the terminator the standard names and `BEL` the one xterm has
/// always accepted, so both end a string here. An `ESC` that is not the start
/// of an `ST` abandons the string, which is how a terminal that was
/// interrupted mid-reply does not eat the sequence that follows.
fn decodeString(bytes: []const u8) Decoded {
    var i: usize = 2;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == seq.bel) return ready(.{ .unhandled = bytes[0 .. i + 1] }, i + 1);
        if (bytes[i] != seq.esc) continue;
        if (i + 1 >= bytes.len) return .incomplete;
        if (bytes[i + 1] == '\\') return ready(.{ .unhandled = bytes[0 .. i + 2] }, i + 2);
        // Abandoned: give back what there is and start again at the ESC.
        return ready(.{ .unhandled = bytes[0..i] }, i);
    }
    return .incomplete;
}

/// Reads `SS3`: `ESC O` and one final byte, with the modifier parameter some
/// terminals put between them.
fn decodeSs3(bytes: []const u8) Decoded {
    var i: usize = 2;
    while (i < bytes.len and bytes[i] >= 0x30 and bytes[i] <= 0x3f) : (i += 1) {}
    if (i >= bytes.len) return .incomplete;
    const final = bytes[i];
    if (final < 0x40 or final > 0x7e) return .{ .skip = 1 };
    const len = i + 1;
    const whole = bytes[0..len];

    const key = ss3Key(final) orelse return ready(.{ .unhandled = whole }, len);
    var ev: KeyEvent = .{ .key = key };

    // Unlike CSI, where the modifiers are the second parameter, an SS3 that
    // carries modifiers at all carries them as its only one.
    const params = scanParams(bytes[2..i]) orelse return ready(.{ .unhandled = whole }, len);
    if (!applyModifiers(&ev, params, 0)) return ready(.{ .unhandled = whole }, len);

    return ready(.{ .key = ev }, len);
}

/// The key an `SS3` final byte names.
fn ss3Key(final: u8) ?Key {
    return switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'E' => .kp_begin,
        'F' => .end,
        'H' => .home,
        'P' => .{ .f = 1 },
        'Q' => .{ .f = 2 },
        // Unlike CSI, where R is the cursor position report, SS3 R is free.
        'R' => .{ .f = 3 },
        'S' => .{ .f = 4 },
        'M' => .kp_enter,
        'X' => .kp_equal,
        'j' => .kp_multiply,
        'k' => .kp_add,
        'l' => .kp_separator,
        'm' => .kp_subtract,
        'n' => .kp_decimal,
        'o' => .kp_divide,
        'p' => .kp_0,
        'q' => .kp_1,
        'r' => .kp_2,
        's' => .kp_3,
        't' => .kp_4,
        'u' => .kp_5,
        'v' => .kp_6,
        'w' => .kp_7,
        'x' => .kp_8,
        'y' => .kp_9,
        else => null,
    };
}

/// Frames a `CSI` sequence and, when it is one, reads the key out of it.
///
/// Framing and reading are separate on purpose: a sequence with a private
/// marker, an intermediate byte, or more parameters than this parser holds is
/// still a sequence whose length is known, so it comes back whole as
/// `Event.unhandled` rather than being resynchronised byte by byte.
fn decodeCsi(bytes: []const u8) Decoded {
    var i: usize = 2;

    // A private marker, if there is one: `<` for a mouse report, `?` for a
    // DEC private reply, `>` for a secondary attributes reply. None of them
    // is ever a key.
    var private = false;
    if (i < bytes.len and bytes[i] >= '<' and bytes[i] <= '?') {
        private = true;
        i += 1;
    }

    const param_start = i;
    while (i < bytes.len and bytes[i] >= 0x30 and bytes[i] <= 0x3f) : (i += 1) {}
    const param_end = i;
    while (i < bytes.len and bytes[i] >= 0x20 and bytes[i] <= 0x2f) : (i += 1) {}
    const intermediate_end = i;

    if (i >= bytes.len) return .incomplete;
    const final = bytes[i];
    if (final < 0x40 or final > 0x7e) return .{ .skip = 1 };

    // `CSI M` with no parameters is an X10 mouse report, whose three
    // coordinate bytes are arbitrary and are part of the sequence. Framing
    // them here is what keeps a terminal left in mode 1000 without mode 1006
    // from delivering three of them as three keypresses. Nothing else in the
    // input stream has a length the final byte alone does not give.
    if (!private and final == 'M' and param_start == param_end and intermediate_end == param_end) {
        const report_len = i + 1 + x10_mouse_fields;
        if (bytes.len < report_len) return .incomplete;
        return ready(.{ .unhandled = bytes[0..report_len] }, report_len);
    }

    const len = i + 1;
    const whole = bytes[0..len];
    if (private or intermediate_end != param_end) return ready(.{ .unhandled = whole }, len);

    const params = scanParams(bytes[param_start..param_end]) orelse
        return ready(.{ .unhandled = whole }, len);
    const event = csiEvent(final, params) orelse return ready(.{ .unhandled = whole }, len);
    return ready(event, len);
}

/// The event a parameterised `CSI` with no private marker stands for, or null
/// when it stands for none.
fn csiEvent(final: u8, params: Params) ?Event {
    switch (final) {
        'u' => return kittyEvent(params),
        '~' => return tildeEvent(params),
        'A', 'B', 'C', 'D', 'E', 'F', 'H', 'P', 'Q', 'S' => {
            const key = ss3Key(final).?;
            var ev: KeyEvent = .{ .key = key };
            if (!applyModifiers(&ev, params, 1)) return null;
            return .{ .key = ev };
        },
        // Backtab, which is shift and tab spelled without a parameter.
        'Z' => {
            var ev: KeyEvent = .{ .key = .tab };
            if (!applyModifiers(&ev, params, 1)) return null;
            ev.mods.shift = true;
            return .{ .key = ev };
        },
        'I' => return if (params.count == 0) .focus_in else null,
        'O' => return if (params.count == 0) .focus_out else null,
        't' => return resizeEvent(params),
        // R is the cursor position report. A terminal that wants to send F3
        // with modifiers sends `CSI 13 ; mods ~` instead, for this reason.
        else => return null,
    }
}

/// Reads a `CSI number ~` sequence: the numbered function and editing keys,
/// the bracketed paste markers, and xterm's `modifyOtherKeys`.
fn tildeEvent(params: Params) ?Event {
    const n = params.get(0, 0) orelse return null;
    switch (n) {
        200 => return if (params.count == 1) .paste_start else null,
        201 => return if (params.count == 1) .paste_end else null,
        // modifyOtherKeys: CSI 27 ; modifiers ; codepoint ~, which is how
        // xterm reports a key whose modified form has no control code.
        27 => {
            const cp = params.get(2, 0) orelse return null;
            const key = protocolKey(cp) orelse return null;
            var ev: KeyEvent = .{ .key = key };
            if (!applyModifiers(&ev, params, 1)) return null;
            return .{ .key = ev };
        },
        else => {
            const key = tildeKey(n) orelse return null;
            var ev: KeyEvent = .{ .key = key };
            if (!applyModifiers(&ev, params, 1)) return null;
            if (!fillText(&ev, params, 2)) return null;
            return .{ .key = ev };
        },
    }
}

/// Reads an in-band resize report: `CSI 48 ; rows ; cols ; ypixels ; xpixels t`.
///
/// `CSI ... t` is the window manipulation family, and every other member of
/// it is a request a program sends or a reply to one it asked for -- read by
/// `parseWindowSize`, not here. Only the leading 48 is a report the terminal
/// sends unprompted, so only that one is a key-stream event; the rest come
/// back as `Event.unhandled` for the parser that asked.
///
/// The two pixel parameters are optional, because a terminal that does not
/// know its pixel size omits them rather than sending zeroes.
fn resizeEvent(params: Params) ?Event {
    if (params.get(0, 0) != 48) return null;
    if (params.count < 3 or params.count > 5) return null;

    const rows = params.get(1, 0) orelse return null;
    const cols = params.get(2, 0) orelse return null;

    var resize: Resize = .{ .rows = rows, .cols = cols };
    if (params.count > 3) resize.ypixels = params.get(3, 0) orelse return null;
    if (params.count > 4) resize.xpixels = params.get(4, 0) orelse return null;
    return .{ .resize = resize };
}

/// Reads a kitty `CSI u` sequence, at every flag level the protocol defines.
///
/// The shape is `CSI key : shifted : base ; modifiers : event ; text u`, and
/// every field after the first is optional, so the same function reads a
/// terminal reporting only disambiguated escape codes and one reporting
/// alternate keys, event types and associated text all at once.
fn kittyEvent(params: Params) ?Event {
    const cp = params.get(0, 0) orelse return null;
    const key = protocolKey(cp) orelse return null;

    var ev: KeyEvent = .{ .key = key };
    if (params.get(0, 1)) |shifted| ev.shifted = codepoint(shifted) orelse return null;
    if (params.get(0, 2)) |base| ev.base = codepoint(base) orelse return null;
    if (!applyModifiers(&ev, params, 1)) return null;
    if (!fillText(&ev, params, 2)) return null;
    return .{ .key = ev };
}

/// A codepoint a terminal can legally have sent, or null.
fn codepoint(value: u32) ?u21 {
    if (value > 0x10ffff) return null;
    if (value >= 0xd800 and value <= 0xdfff) return null;
    return @intCast(value);
}

/// The key a `CSI n ~` number names.
///
/// Two numbers for home and two for end, because the VT220 and the PC
/// keyboards disagreed and terminals have sent both ever since.
fn tildeKey(n: u32) ?Key {
    return switch (n) {
        1, 7 => .home,
        2 => .insert,
        3 => .delete,
        4, 8 => .end,
        5 => .page_up,
        6 => .page_down,
        11...15 => .{ .f = @intCast(n - 10) },
        // 16 is missing from the table, as it always has been.
        17...21 => .{ .f = @intCast(n - 11) },
        23...26 => .{ .f = @intCast(n - 12) },
        // 27 is modifyOtherKeys and 30 is missing.
        28, 29 => .{ .f = @intCast(n - 13) },
        31...34 => .{ .f = @intCast(n - 14) },
        else => null,
    };
}

/// The key a codepoint in a `CSI u` or `modifyOtherKeys` sequence names.
///
/// Most codepoints are the key itself. The rest are either a C0 control the
/// protocol kept for the key it has always meant, or one of the private-use
/// codepoints the kitty protocol assigns to keys Unicode has no character
/// for. A private-use codepoint in that assigned block that this package does
/// not know is not a key it will invent a meaning for: it returns null and
/// the sequence comes back as `Event.unhandled`.
fn protocolKey(cp: u32) ?Key {
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

/// Fills in the modifiers and the event kind from parameter `index`.
///
/// Returns false for a value the protocol does not define, which makes the
/// whole sequence one this parser does not claim to have read.
fn applyModifiers(ev: *KeyEvent, params: Params, index: usize) bool {
    if (params.get(index, 0)) |value| {
        // The protocol spells the bitmask plus one, so that an unmodified key
        // can leave the parameter out and a present one is never zero.
        if (value > 256) return false;
        if (value != 0) ev.mods = Modifiers.fromBits(@intCast(value - 1));
    }
    if (params.get(index, 1)) |value| {
        ev.kind = switch (value) {
            1 => .press,
            2 => .repeat,
            3 => .release,
            else => return false,
        };
    }
    return true;
}

/// Fills in the text from parameter `index`, whose sub-parameters are the
/// codepoints the key produced.
///
/// Text past `KeyEvent.text_capacity` is dropped at a codepoint boundary
/// rather than cutting one in half, so `KeyEvent.text` is always valid UTF-8.
fn fillText(ev: *KeyEvent, params: Params, index: usize) bool {
    if (index >= params.count) return true;
    var j: usize = 0;
    while (j < params.subs[index]) : (j += 1) {
        const value = params.get(index, j) orelse continue;
        const cp = codepoint(value) orelse return false;
        var scratch: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &scratch) catch return false;
        if (@as(usize, ev.text_len) + n > KeyEvent.text_capacity) break;
        @memcpy(ev.text_buffer[ev.text_len..][0..n], scratch[0..n]);
        ev.text_len += @intCast(n);
    }
    return true;
}

//=========================================================================
// CSI parameters.
//=========================================================================

/// How many bytes follow `CSI M` in an X10 mouse report: a button and two
/// coordinates, each biased by 32 so that none of them is a control code.
///
/// They are framed but not decoded here -- `parseMouseX10` reads them -- and
/// framing them is not optional: they are arbitrary bytes, so a parser that
/// stopped at the `M` would hand the next three to the key decoder.
const x10_mouse_fields = 3;

/// The most parameters a sequence may carry and still be one this parser
/// reads. Three is all any keyboard protocol uses.
const max_params = 8;

/// The most sub-parameters one parameter may carry. Three is all the key
/// field uses, and four is all the text field can spell within
/// `KeyEvent.text_capacity`.
const max_subparams = 4;

/// The numbers between `CSI` and the final byte, split on `;` and then on
/// `:`, with a missing number kept as null rather than as a zero — because
/// `CSI ; 5 A` and `CSI 0 ; 5 A` are not the same sequence.
const Params = struct {
    values: [max_params][max_subparams]?u32 = @splat(@splat(null)),
    subs: [max_params]u8 = @splat(0),
    count: u8 = 0,

    /// Sub-parameter `j` of parameter `i`, or null when either is absent.
    fn get(p: Params, i: usize, j: usize) ?u32 {
        if (i >= p.count) return null;
        if (j >= p.subs[i]) return null;
        return p.values[i][j];
    }
};

/// Splits a parameter string, or returns null when it does not fit — too many
/// parameters, too many sub-parameters, a number too large for a `u32`, or a
/// byte that is neither a digit nor a separator.
fn scanParams(bytes: []const u8) ?Params {
    var params: Params = .{};
    if (bytes.len == 0) return params;

    var i: usize = 0;
    var j: usize = 0;
    params.count = 1;
    params.subs[0] = 1;

    var rest = bytes;
    while (rest.len != 0) {
        switch (rest[0]) {
            ';' => {
                i += 1;
                if (i >= max_params) return null;
                j = 0;
                params.count = @intCast(i + 1);
                params.subs[i] = 1;
                rest = rest[1..];
            },
            ':' => {
                j += 1;
                if (j >= max_subparams) return null;
                params.subs[i] = @intCast(j + 1);
                rest = rest[1..];
            },
            '0'...'9' => {
                const scan = seq.scanInt(u32, rest) orelse return null;
                params.values[i][j] = scan.value;
                rest = rest[scan.len..];
            },
            else => return null,
        }
    }
    return params;
}

//=========================================================================
// Tests.
//=========================================================================

/// Everything `bytes` decodes to in one feed, for a test that does not care
/// about how the reads were split.
fn collect(bytes: []const u8, out: []Event) []Event {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);
    var events = parser.feed(bytes);
    var n: usize = 0;
    while (events.next()) |event| : (n += 1) out[n] = event;
    return out[0..n];
}

/// The one event `bytes` decodes to, or null when it decodes to none or to
/// more than one.
fn one(bytes: []const u8) ?Event {
    var buffer: [8]Event = undefined;
    const events = collect(bytes, &buffer);
    if (events.len != 1) return null;
    return events[0];
}

/// The one key `bytes` decodes to.
fn oneKey(bytes: []const u8) ?KeyEvent {
    const event = one(bytes) orelse return null;
    return switch (event) {
        .key => |ev| ev,
        else => null,
    };
}

/// Asserts that `bytes` is framed whole and handed back undecoded.
///
/// Checked while the parser still holds it, because an unhandled event
/// borrows the parser's buffer and only until the next call -- which is the
/// contract, and worth a test helper that keeps to it.
fn expectUnhandled(bytes: []const u8) !void {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);
    var events = parser.feed(bytes);
    const first = events.next() orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(bytes, first.unhandled);
    try std.testing.expectEqual(@as(?Event, null), events.next());
}

test "a printable byte is a character, and carries itself as text" {
    const ev = oneKey("a").?;
    try std.testing.expectEqual(Key{ .char = 'a' }, ev.key);
    try std.testing.expectEqual(Modifiers{}, ev.mods);
    try std.testing.expectEqual(Kind.press, ev.kind);
    try std.testing.expectEqualStrings("a", ev.text());
}

test "a run of text is one event per codepoint" {
    var buffer: [8]Event = undefined;
    const events = collect("hi!", &buffer);
    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqual(Key{ .char = 'h' }, events[0].key.key);
    try std.testing.expectEqual(Key{ .char = 'i' }, events[1].key.key);
    try std.testing.expectEqual(Key{ .char = '!' }, events[2].key.key);
}

test "text outside ASCII decodes as one codepoint and keeps its bytes" {
    const ev = oneKey("é").?;
    try std.testing.expectEqual(Key{ .char = 0xe9 }, ev.key);
    try std.testing.expectEqualStrings("é", ev.text());

    const emoji = oneKey("🙂").?;
    try std.testing.expectEqual(Key{ .char = 0x1f642 }, emoji.key);
    try std.testing.expectEqualStrings("🙂", emoji.text());
}

test "the C0 controls are the keys they have always been" {
    const cases = [_]struct { bytes: []const u8, key: Key, ctrl: bool }{
        .{ .bytes = "\x00", .key = .{ .char = ' ' }, .ctrl = true },
        .{ .bytes = "\x01", .key = .{ .char = 'a' }, .ctrl = true },
        .{ .bytes = "\x1a", .key = .{ .char = 'z' }, .ctrl = true },
        .{ .bytes = "\x08", .key = .backspace, .ctrl = true },
        .{ .bytes = "\x09", .key = .tab, .ctrl = false },
        .{ .bytes = "\x0a", .key = .enter, .ctrl = false },
        .{ .bytes = "\x0d", .key = .enter, .ctrl = false },
        .{ .bytes = "\x1c", .key = .{ .char = '\\' }, .ctrl = true },
        .{ .bytes = "\x1d", .key = .{ .char = ']' }, .ctrl = true },
        .{ .bytes = "\x1e", .key = .{ .char = '^' }, .ctrl = true },
        .{ .bytes = "\x1f", .key = .{ .char = '_' }, .ctrl = true },
        .{ .bytes = "\x7f", .key = .backspace, .ctrl = false },
    };
    for (cases) |case| {
        const ev = oneKey(case.bytes).?;
        try std.testing.expectEqual(case.key, ev.key);
        try std.testing.expectEqual(case.ctrl, ev.mods.ctrl);
        // A control code is not text the user meant to type.
        try std.testing.expectEqualStrings("", ev.text());
    }
}

test "an escape in front of a key is alt, and carries no text" {
    const ev = oneKey("\x1ba").?;
    try std.testing.expectEqual(Key{ .char = 'a' }, ev.key);
    try std.testing.expect(ev.mods.alt);
    try std.testing.expectEqualStrings("", ev.text());

    const both = oneKey("\x1b\x01").?;
    try std.testing.expectEqual(Key{ .char = 'a' }, both.key);
    try std.testing.expect(both.mods.alt and both.mods.ctrl);
}

test "two escapes running are an Escape key and then whatever follows" {
    var buffer: [8]Event = undefined;
    const events = collect("\x1b\x1b[A", &buffer);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqual(Key.escape, events[0].key.key);
    try std.testing.expectEqual(Key.up, events[1].key.key);
}

test "the legacy arrows decode in both their spellings" {
    const cases = [_]struct { bytes: []const u8, key: Key }{
        .{ .bytes = "\x1b[A", .key = .up },
        .{ .bytes = "\x1b[B", .key = .down },
        .{ .bytes = "\x1b[C", .key = .right },
        .{ .bytes = "\x1b[D", .key = .left },
        .{ .bytes = "\x1b[E", .key = .kp_begin },
        .{ .bytes = "\x1b[F", .key = .end },
        .{ .bytes = "\x1b[H", .key = .home },
        .{ .bytes = "\x1bOA", .key = .up },
        .{ .bytes = "\x1bOB", .key = .down },
        .{ .bytes = "\x1bOC", .key = .right },
        .{ .bytes = "\x1bOD", .key = .left },
        .{ .bytes = "\x1bOH", .key = .home },
        .{ .bytes = "\x1bOF", .key = .end },
    };
    for (cases) |case| {
        const ev = oneKey(case.bytes).?;
        try std.testing.expectEqual(case.key, ev.key);
        try std.testing.expectEqual(Modifiers{}, ev.mods);
    }
}

test "SS3 covers the four low function keys and the keypad" {
    const cases = [_]struct { bytes: []const u8, key: Key }{
        .{ .bytes = "\x1bOP", .key = .{ .f = 1 } },
        .{ .bytes = "\x1bOQ", .key = .{ .f = 2 } },
        .{ .bytes = "\x1bOR", .key = .{ .f = 3 } },
        .{ .bytes = "\x1bOS", .key = .{ .f = 4 } },
        .{ .bytes = "\x1bOM", .key = .kp_enter },
        .{ .bytes = "\x1bOX", .key = .kp_equal },
        .{ .bytes = "\x1bOj", .key = .kp_multiply },
        .{ .bytes = "\x1bOk", .key = .kp_add },
        .{ .bytes = "\x1bOl", .key = .kp_separator },
        .{ .bytes = "\x1bOm", .key = .kp_subtract },
        .{ .bytes = "\x1bOn", .key = .kp_decimal },
        .{ .bytes = "\x1bOo", .key = .kp_divide },
        .{ .bytes = "\x1bOp", .key = .kp_0 },
        .{ .bytes = "\x1bOy", .key = .kp_9 },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.key, oneKey(case.bytes).?.key);
    }
}

test "an SS3 with a parameter carries modifiers in it" {
    const ev = oneKey("\x1bO5A").?;
    try std.testing.expectEqual(Key.up, ev.key);
    try std.testing.expect(ev.mods.ctrl);
}

test "the numbered keys decode from their CSI tilde form" {
    const cases = [_]struct { bytes: []const u8, key: Key }{
        .{ .bytes = "\x1b[1~", .key = .home },
        .{ .bytes = "\x1b[2~", .key = .insert },
        .{ .bytes = "\x1b[3~", .key = .delete },
        .{ .bytes = "\x1b[4~", .key = .end },
        .{ .bytes = "\x1b[5~", .key = .page_up },
        .{ .bytes = "\x1b[6~", .key = .page_down },
        .{ .bytes = "\x1b[7~", .key = .home },
        .{ .bytes = "\x1b[8~", .key = .end },
        .{ .bytes = "\x1b[11~", .key = .{ .f = 1 } },
        .{ .bytes = "\x1b[15~", .key = .{ .f = 5 } },
        .{ .bytes = "\x1b[17~", .key = .{ .f = 6 } },
        .{ .bytes = "\x1b[21~", .key = .{ .f = 10 } },
        .{ .bytes = "\x1b[23~", .key = .{ .f = 11 } },
        .{ .bytes = "\x1b[26~", .key = .{ .f = 14 } },
        .{ .bytes = "\x1b[28~", .key = .{ .f = 15 } },
        .{ .bytes = "\x1b[29~", .key = .{ .f = 16 } },
        .{ .bytes = "\x1b[31~", .key = .{ .f = 17 } },
        .{ .bytes = "\x1b[34~", .key = .{ .f = 20 } },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.key, oneKey(case.bytes).?.key);
    }
}

test "the gaps in the numbered table are not keys" {
    const gaps = [_][]const u8{ "\x1b[0~", "\x1b[9~", "\x1b[10~", "\x1b[16~", "\x1b[22~", "\x1b[30~", "\x1b[35~" };
    for (gaps) |bytes| try expectUnhandled(bytes);
}

test "every legacy modifier parameter decodes to its modifiers" {
    // The parameter is the bitmask plus one, which is why 2 is shift alone
    // and 8 is control and alt and shift together.
    const cases = [_]struct { param: []const u8, mods: Modifiers }{
        .{ .param = "2", .mods = .{ .shift = true } },
        .{ .param = "3", .mods = .{ .alt = true } },
        .{ .param = "4", .mods = .{ .shift = true, .alt = true } },
        .{ .param = "5", .mods = .{ .ctrl = true } },
        .{ .param = "6", .mods = .{ .shift = true, .ctrl = true } },
        .{ .param = "7", .mods = .{ .alt = true, .ctrl = true } },
        .{ .param = "8", .mods = .{ .shift = true, .alt = true, .ctrl = true } },
        .{ .param = "9", .mods = .{ .super = true } },
        .{ .param = "129", .mods = .{ .num_lock = true } },
    };
    var buffer: [32]u8 = undefined;
    for (cases) |case| {
        const arrow = try std.fmt.bufPrint(&buffer, "\x1b[1;{s}A", .{case.param});
        try std.testing.expectEqual(case.mods, oneKey(arrow).?.mods);
    }
    for (cases) |case| {
        const del = try std.fmt.bufPrint(&buffer, "\x1b[3;{s}~", .{case.param});
        const ev = oneKey(del).?;
        try std.testing.expectEqual(Key.delete, ev.key);
        try std.testing.expectEqual(case.mods, ev.mods);
    }
}

test "backtab is shift and tab however it is spelled" {
    try std.testing.expectEqual(Key.tab, oneKey("\x1b[Z").?.key);
    try std.testing.expect(oneKey("\x1b[Z").?.mods.shift);

    const kitty = oneKey("\x1b[9;2u").?;
    try std.testing.expectEqual(Key.tab, kitty.key);
    try std.testing.expect(kitty.mods.shift);
}

test "modifyOtherKeys reports a key as a codepoint and a modifier" {
    // Control and tab, which has no control code of its own.
    const tab = oneKey("\x1b[27;5;9~").?;
    try std.testing.expectEqual(Key.tab, tab.key);
    try std.testing.expect(tab.mods.ctrl);

    const escape = oneKey("\x1b[27;3;27~").?;
    try std.testing.expectEqual(Key.escape, escape.key);
    try std.testing.expect(escape.mods.alt);

    const letter = oneKey("\x1b[27;6;97~").?;
    try std.testing.expectEqual(Key{ .char = 'a' }, letter.key);
    try std.testing.expect(letter.mods.shift and letter.mods.ctrl);
}

test "a kitty sequence at the first flag level is a codepoint and nothing else" {
    const ev = oneKey("\x1b[97u").?;
    try std.testing.expectEqual(Key{ .char = 'a' }, ev.key);
    try std.testing.expectEqual(Modifiers{}, ev.mods);
    try std.testing.expectEqual(Kind.press, ev.kind);
    try std.testing.expectEqual(@as(?u21, null), ev.shifted);
    // The terminal did not say what the key produced, so neither does this.
    try std.testing.expectEqualStrings("", ev.text());
}

test "kitty spells escape, enter, tab and backspace as their control codes" {
    try std.testing.expectEqual(Key.escape, oneKey("\x1b[27u").?.key);
    try std.testing.expectEqual(Key.enter, oneKey("\x1b[13u").?.key);
    try std.testing.expectEqual(Key.tab, oneKey("\x1b[9u").?.key);
    try std.testing.expectEqual(Key.backspace, oneKey("\x1b[127u").?.key);
}

test "kitty event types decode to press, repeat and release" {
    const cases = [_]struct { bytes: []const u8, kind: Kind }{
        .{ .bytes = "\x1b[97;1:1u", .kind = .press },
        .{ .bytes = "\x1b[97;1:2u", .kind = .repeat },
        .{ .bytes = "\x1b[97;1:3u", .kind = .release },
        // No event type at all still means a press.
        .{ .bytes = "\x1b[97;1u", .kind = .press },
        .{ .bytes = "\x1b[97u", .kind = .press },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.kind, oneKey(case.bytes).?.kind);
    }
    // A release with modifiers, which is the form a terminal actually sends.
    const ev = oneKey("\x1b[97;5:3u").?;
    try std.testing.expectEqual(Kind.release, ev.kind);
    try std.testing.expect(ev.mods.ctrl);
}

test "kitty alternate keys arrive beside the key itself" {
    // Shift and A: the key is a, the shifted form is A, the base layout key
    // is a. The text is what the terminal says it produced.
    const ev = oneKey("\x1b[97:65:97;2;65u").?;
    try std.testing.expectEqual(Key{ .char = 'a' }, ev.key);
    try std.testing.expectEqual(@as(?u21, 'A'), ev.shifted);
    try std.testing.expectEqual(@as(?u21, 'a'), ev.base);
    try std.testing.expect(ev.mods.shift);
    try std.testing.expectEqualStrings("A", ev.text());
}

test "kitty associated text carries every codepoint it names" {
    try std.testing.expectEqualStrings("a", oneKey("\x1b[97;;97u").?.text());
    try std.testing.expectEqualStrings("ab", oneKey("\x1b[97;;97:98u").?.text());
    // Outside ASCII, so the text is longer than the number of codepoints.
    try std.testing.expectEqualStrings("é", oneKey("\x1b[233;;233u").?.text());
    try std.testing.expectEqualStrings("🙂", oneKey("\x1b[97;;128578u").?.text());
}

test "kitty text longer than the capacity stops at a codepoint boundary" {
    // Four four-byte codepoints is exactly the capacity.
    const full = oneKey("\x1b[97;;128578:128578:128578:128578u").?;
    try std.testing.expectEqual(@as(u8, 16), full.text_len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(full.text()));
}

test "every kitty functional codepoint this package names decodes" {
    const cases = [_]struct { cp: u32, key: Key }{
        .{ .cp = 57358, .key = .caps_lock },
        .{ .cp = 57363, .key = .menu },
        .{ .cp = 57376, .key = .{ .f = 13 } },
        .{ .cp = 57398, .key = .{ .f = 35 } },
        .{ .cp = 57399, .key = .kp_0 },
        .{ .cp = 57408, .key = .kp_9 },
        .{ .cp = 57414, .key = .kp_enter },
        .{ .cp = 57427, .key = .kp_begin },
        .{ .cp = 57428, .key = .media_play },
        .{ .cp = 57440, .key = .mute_volume },
        .{ .cp = 57441, .key = .left_shift },
        .{ .cp = 57452, .key = .right_meta },
        .{ .cp = 57454, .key = .iso_level5_shift },
    };
    var buffer: [32]u8 = undefined;
    for (cases) |case| {
        const bytes = try std.fmt.bufPrint(&buffer, "\x1b[{d}u", .{case.cp});
        try std.testing.expectEqual(case.key, oneKey(bytes).?.key);
    }
}

test "an unassigned codepoint in the protocol's own block is not invented" {
    try expectUnhandled("\x1b[57344u");
}

test "bracketed paste and focus arrive as their own events" {
    try std.testing.expectEqual(Event.paste_start, one("\x1b[200~").?);
    try std.testing.expectEqual(Event.paste_end, one("\x1b[201~").?);
    try std.testing.expectEqual(Event.focus_in, one("\x1b[I").?);
    try std.testing.expectEqual(Event.focus_out, one("\x1b[O").?);
}

test "a paste is a start, the text as ordinary keys, and an end" {
    var buffer: [16]Event = undefined;
    const events = collect("\x1b[200~hi\x1b[201~", &buffer);
    try std.testing.expectEqual(@as(usize, 4), events.len);
    try std.testing.expectEqual(Event.paste_start, events[0]);
    try std.testing.expectEqualStrings("h", events[1].key.text());
    try std.testing.expectEqualStrings("i", events[2].key.text());
    try std.testing.expectEqual(Event.paste_end, events[3]);
}

test "a sequence that is not a key comes back whole" {
    const cases = [_][]const u8{
        "\x1b[<0;40;12M", // a mouse report
        "\x1b[?2026;1$y", // a mode report
        "\x1b[12;40R", // a cursor position report
        "\x1b[?1u", // a kitty keyboard flags reply
        "\x1b[?62;1;6c", // primary device attributes
        "\x1b[>0;276;0c", // secondary device attributes
        "\x1b]52;c;aGk=\x1b\\", // a clipboard reply
        "\x1b]11;rgb:0000/0000/0000\x1b\\", // a background colour reply
        "\x1bP>|xterm(390)\x1b\\", // XTVERSION
        "\x1bP1+r436f=323536\x1b\\", // an XTGETTCAP reply
        "\x1bP0+r436f\x1b\\", // an XTGETTCAP refusal
        "\x1b_Gi=31;OK\x1b\\", // a kitty graphics response
        "\x1b]2;title\x07", // an OSC ended by BEL
        "\x1b(B", // a character set designation
    };
    for (cases) |bytes| try expectUnhandled(bytes);
}

test "an XTGETTCAP reply is framed whole, and the key behind it survives" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);

    // The payload is hex precisely so that a capability whose value is an
    // escape sequence cannot end the reply carrying it. The framing has to
    // hold for the whole of it, or the bytes after it arrive as keypresses.
    var events = parser.feed("\x1bP1+r6b656e64=1b4f46\x1b\\a");
    try std.testing.expectEqualStrings(
        "\x1bP1+r6b656e64=1b4f46\x1b\\",
        events.next().?.unhandled,
    );
    try std.testing.expectEqual(Key{ .char = 'a' }, events.next().?.key.key);
    try std.testing.expectEqual(@as(?Event, null), events.next());
}

test "an XTGETTCAP reply cut in half is held until the rest of it arrives" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);

    var held = parser.feed("\x1bP1+r436f=32");
    try std.testing.expectEqual(@as(?Event, null), held.next());
    try std.testing.expectEqual(@as(usize, 12), parser.pending().len);

    var events = parser.feed("3536\x1b\\");
    try std.testing.expectEqualStrings("\x1bP1+r436f=323536\x1b\\", events.next().?.unhandled);
    try std.testing.expectEqual(@as(?Event, null), events.next());
}

test "an unhandled sequence and the key after it both come out" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);
    var events = parser.feed("\x1b[<0;40;12Ma");
    try std.testing.expectEqualStrings("\x1b[<0;40;12M", events.next().?.unhandled);
    try std.testing.expectEqual(Key{ .char = 'a' }, events.next().?.key.key);
    try std.testing.expectEqual(@as(?Event, null), events.next());
}

test "a control string a terminal abandoned does not eat what follows" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);
    var events = parser.feed("\x1b]52;c;aGk=\x1b[A");
    try std.testing.expectEqualStrings("\x1b]52;c;aGk=", events.next().?.unhandled);
    try std.testing.expectEqual(Key.up, events.next().?.key.key);
    try std.testing.expectEqual(@as(?Event, null), events.next());
}

test "a sequence split across feeds is one event when it is whole" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);

    // Byte by byte, which is what a terminal on a slow link looks like.
    const whole = "\x1b[97:65:97;2:3;65u";
    for (whole[0 .. whole.len - 1]) |byte| {
        var events = parser.feed(&[_]u8{byte});
        try std.testing.expectEqual(@as(?Event, null), events.next());
        try std.testing.expect(parser.pending().len != 0);
    }

    var events = parser.feed(whole[whole.len - 1 ..]);
    const ev = events.next().?.key;
    try std.testing.expectEqual(Key{ .char = 'a' }, ev.key);
    try std.testing.expectEqual(@as(?u21, 'A'), ev.shifted);
    try std.testing.expectEqual(Kind.release, ev.kind);
    try std.testing.expectEqual(@as(?Event, null), events.next());
    try std.testing.expectEqual(@as(usize, 0), parser.pending().len);
}

test "a multi-byte codepoint split across feeds is one key" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);

    var first = parser.feed("\xf0\x9f");
    try std.testing.expectEqual(@as(?Event, null), first.next());
    var second = parser.feed("\x99\x82");
    try std.testing.expectEqual(Key{ .char = 0x1f642 }, second.next().?.key.key);
    try std.testing.expectEqual(@as(?Event, null), second.next());
}

test "a feed longer than the buffer drains through it" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);

    var input: [1000]u8 = @splat('x');
    var events = parser.feed(&input);
    var n: usize = 0;
    while (events.next()) |event| : (n += 1) {
        try std.testing.expectEqual(Key{ .char = 'x' }, event.key.key);
    }
    try std.testing.expectEqual(@as(usize, input.len), n);
}

test "a lone escape is held, never guessed at" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);

    var events = parser.feed("\x1b");
    try std.testing.expectEqual(@as(?Event, null), events.next());
    try std.testing.expectEqualStrings("\x1b", parser.pending());

    // The caller's timeout expired, so the caller decides.
    try std.testing.expectEqual(Key.escape, parser.flush().?.key.key);
    try std.testing.expectEqual(@as(usize, 0), parser.pending().len);
    try std.testing.expectEqual(@as(?Event, null), parser.flush());
}

test "flush resolves the two other sequences that are also keys" {
    var storage: [KeyParser.min_buffer]u8 = undefined;

    var bracket: KeyParser = .init(&storage);
    var first = bracket.feed("\x1b[");
    try std.testing.expectEqual(@as(?Event, null), first.next());
    const ev = bracket.flush().?.key;
    try std.testing.expectEqual(Key{ .char = '[' }, ev.key);
    try std.testing.expect(ev.mods.alt);

    var letter: KeyParser = .init(&storage);
    var second = letter.feed("\x1bO");
    try std.testing.expectEqual(@as(?Event, null), second.next());
    try std.testing.expectEqual(Key{ .char = 'O' }, letter.flush().?.key.key);
}

test "flush throws away a sequence the terminal began and did not finish" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);

    var events = parser.feed("\x1b[1;5");
    try std.testing.expectEqual(@as(?Event, null), events.next());
    try std.testing.expectEqual(@as(?Event, null), parser.flush());
    try std.testing.expectEqual(@as(usize, 0), parser.pending().len);
}

test "reset forgets a half-arrived sequence" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);

    var events = parser.feed("\x1b[1;");
    try std.testing.expectEqual(@as(?Event, null), events.next());
    parser.reset();
    try std.testing.expectEqual(@as(usize, 0), parser.pending().len);

    var again = parser.feed("a");
    try std.testing.expectEqual(Key{ .char = 'a' }, again.next().?.key.key);
}

test "a sequence longer than the buffer is dropped, and the stream recovers" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);

    // A CSI whose parameters do not fit anywhere. Nothing can complete it.
    var long: [KeyParser.min_buffer]u8 = @splat('1');
    long[0] = seq.esc;
    long[1] = '[';

    var events = parser.feed(&long);
    try std.testing.expectEqual(@as(?Event, null), events.next());

    var after = parser.feed("a");
    try std.testing.expectEqual(Key{ .char = 'a' }, after.next().?.key.key);
}

test "a malformed UTF-8 byte is dropped rather than becoming a key" {
    var buffer: [8]Event = undefined;

    // A continuation byte with nothing in front of it.
    const stray = collect("\x80a", &buffer);
    try std.testing.expectEqual(@as(usize, 1), stray.len);
    try std.testing.expectEqual(Key{ .char = 'a' }, stray[0].key.key);

    // A lead byte followed by something that is not a continuation.
    const broken = collect("\xc3(", &buffer);
    try std.testing.expectEqual(@as(usize, 1), broken.len);
    try std.testing.expectEqual(Key{ .char = '(' }, broken[0].key.key);
}

test "a sequence this parser cannot hold parameters for still comes back whole" {
    // Nine parameters, one more than the parser keeps.
    try expectUnhandled("\x1b[1;2;3;4;5;6;7;8;9A");
    // A number too large for the field it would be read into.
    try expectUnhandled("\x1b[99999999999u");
    // A codepoint past the end of Unicode.
    try expectUnhandled("\x1b[1114112u");
    // An event type the protocol does not define.
    try expectUnhandled("\x1b[97;1:9u");
}

test "modifiers survive a round trip through their bits" {
    for (0..256) |value| {
        const bits: u8 = @intCast(value);
        try std.testing.expectEqual(bits, Modifiers.fromBits(bits).bits());
    }
    try std.testing.expect(!(Modifiers{}).any());
    try std.testing.expect((Modifiers{ .shift = true }).any());
}

test "a key event is a value, so two of the same compare equal" {
    const a = oneKey("\x1b[97;;97u").?;
    const b = oneKey("\x1b[97;;97u").?;
    try std.testing.expectEqual(a, b);
}

test "fuzz KeyParser" {
    // The property: no input panics, no arithmetic overflows, every event
    // borrows only from the buffer it was given, and the parser always makes
    // progress -- a feed that is run to null either empties the buffer or
    // leaves a partial sequence strictly shorter than the buffer.
    try std.testing.fuzz({}, struct {
        fn one_(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [256]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];

            var storage: [KeyParser.min_buffer]u8 = undefined;
            var parser: KeyParser = .init(&storage);

            // Fed in two pieces, so that the split lands anywhere a real read
            // could have landed.
            const cut = if (bytes.len == 0) 0 else bytes.len / 2;
            for ([_][]const u8{ bytes[0..cut], bytes[cut..] }) |chunk| {
                var events = parser.feed(chunk);
                while (events.next()) |event| {
                    switch (event) {
                        .key => |ev| {
                            try std.testing.expect(ev.text_len <= KeyEvent.text_capacity);
                            try std.testing.expect(std.unicode.utf8ValidateSlice(ev.text()));
                            if (ev.shifted) |cp| try std.testing.expect(cp <= 0x10ffff);
                            if (ev.base) |cp| try std.testing.expect(cp <= 0x10ffff);
                        },
                        .unhandled => |whole| {
                            // Whole, non-empty, and inside the parser's buffer.
                            try std.testing.expect(whole.len != 0);
                            try std.testing.expect(whole.len <= storage.len);
                            try std.testing.expect(@intFromPtr(whole.ptr) >= @intFromPtr(&storage));
                            try std.testing.expect(
                                @intFromPtr(whole.ptr) + whole.len <= @intFromPtr(&storage) + storage.len,
                            );
                        },
                        else => {},
                    }
                }
                try std.testing.expect(parser.pending().len < storage.len);
            }

            // Whatever is left resolves, and the parser is empty afterwards.
            _ = parser.flush();
            try std.testing.expectEqual(@as(usize, 0), parser.pending().len);
        }
    }.one_, .{ .corpus = &.{
        corpus.seed("\x1b[97:65:97;2:3;65u"),
        corpus.seed("\x1b[27u"),
        corpus.seed("\x1b[1;5A"),
        corpus.seed("\x1b[3;2~"),
        corpus.seed("\x1b[27;5;9~"),
        corpus.seed("\x1b[200~pasted\x1b[201~"),
        corpus.seed("\x1b[I\x1b[O"),
        corpus.seed("\x1bOP\x1bOy"),
        corpus.seed("\x1b[<0;40;12M"),
        corpus.seed("\x1b]52;c;aGk=\x1b\\"),
        corpus.seed("\x1b_Gi=31;OK\x1b\\"),
        corpus.seed("\x1b\x1b[A"),
        corpus.seed("\x1b"),
        corpus.seed("\x1b["),
        corpus.seed("\xf0\x9f\x99\x82"),
        corpus.seed("\x1b[1;2;3;4;5;6;7;8;9A"),
        corpus.seed("\x1b[99999999999u"),
        corpus.seed("hello world"),
    } });
}

test "fuzz the parameter scanner" {
    // The property: no parameter string panics or overflows, and what is read
    // back never claims more parameters than the parser holds.
    try std.testing.fuzz({}, struct {
        fn one_(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [64]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];

            const params = scanParams(bytes) orelse return;
            try std.testing.expect(params.count <= max_params);
            for (0..params.count) |i| {
                try std.testing.expect(params.subs[i] <= max_subparams);
                for (0..max_subparams) |j| _ = params.get(i, j);
            }
        }
    }.one_, .{ .corpus = &.{
        corpus.seed(""),
        corpus.seed("1"),
        corpus.seed("1;5"),
        corpus.seed("97:65:97;2:3;65"),
        corpus.seed(";5"),
        corpus.seed("1;2;3;4;5;6;7;8;9"),
        corpus.seed("1:2:3:4:5"),
        corpus.seed("99999999999"),
        corpus.seed("1;a"),
    } });
}

test "an X10 mouse report is framed whole, not split into keypresses" {
    // The regression this framing exists for: without it the three biased
    // bytes are handed to the key decoder as space, A and A.
    try expectUnhandled("\x1b[M\x20\x41\x41");
}

test "an X10 mouse report does not swallow what follows it" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);
    var events = parser.feed("\x1b[M\x20\x41\x41hi");

    try std.testing.expectEqualStrings("\x1b[M\x20\x41\x41", events.next().?.unhandled);
    try std.testing.expectEqual(Key{ .char = 'h' }, events.next().?.key.key);
    try std.testing.expectEqual(Key{ .char = 'i' }, events.next().?.key.key);
    try std.testing.expectEqual(@as(?Event, null), events.next());
}

test "an X10 mouse report whose fields look like an escape is still one sequence" {
    // A coordinate byte may be any value at all, ESC included, and framing
    // by length is the only thing that gets this right.
    try expectUnhandled("\x1b[M\x20\x1b\x5b");
}

test "an X10 mouse report split across reads is held until it is whole" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);

    const whole = "\x1b[M\x20\x41\x41";
    var split: usize = 1;
    while (split < whole.len) : (split += 1) {
        parser.reset();
        var first = parser.feed(whole[0..split]);
        try std.testing.expectEqual(@as(?Event, null), first.next());
        try std.testing.expectEqual(split, parser.pending().len);

        var second = parser.feed(whole[split..]);
        try std.testing.expectEqualStrings(whole, second.next().?.unhandled);
        try std.testing.expectEqual(@as(?Event, null), second.next());
    }
}

test "a CSI M carrying parameters is not an X10 report" {
    // With parameters it is delete-lines, which a terminal never sends as
    // input -- so it is framed by its final byte and handed back.
    try expectUnhandled("\x1b[2M");
}

test "an in-band resize report decodes to its size" {
    const event = one("\x1b[48;24;80;384;640t").?;
    try std.testing.expectEqual(@as(u32, 24), event.resize.rows);
    try std.testing.expectEqual(@as(u32, 80), event.resize.cols);
    try std.testing.expectEqual(@as(u32, 384), event.resize.ypixels);
    try std.testing.expectEqual(@as(u32, 640), event.resize.xpixels);
}

test "an in-band resize report without pixels leaves them zero" {
    const event = one("\x1b[48;24;80t").?;
    try std.testing.expectEqual(@as(u32, 24), event.resize.rows);
    try std.testing.expectEqual(@as(u32, 80), event.resize.cols);
    try std.testing.expectEqual(@as(u32, 0), event.resize.ypixels);
    try std.testing.expectEqual(@as(u32, 0), event.resize.xpixels);
}

test "a window report that is not the in-band resize is handed back whole" {
    // Every other CSI t is a reply to something the program asked for, so it
    // goes to parseWindowSize rather than coming out as an event here.
    try expectUnhandled("\x1b[8;24;80t");
    try expectUnhandled("\x1b[6;16;8t");
    try expectUnhandled("\x1b[t");
    // 48 with too few or too many fields is not a report this parser claims.
    try expectUnhandled("\x1b[48;24t");
    try expectUnhandled("\x1b[48;24;80;384;640;1t");
}

test "a resize report arrives among keys without disturbing them" {
    var buffer: [8]Event = undefined;
    const events = collect("a\x1b[48;24;80tb", &buffer);
    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqual(Key{ .char = 'a' }, events[0].key.key);
    try std.testing.expectEqual(@as(u32, 80), events[1].resize.cols);
    try std.testing.expectEqual(Key{ .char = 'b' }, events[2].key.key);
}
