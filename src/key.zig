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
//!
//! What this file will never hold: a key map. Which key means quit, which
//! chord opens a pane, and how long to wait before settling a lone `ESC` are
//! all decisions above this layer. It says which key was pressed and with
//! what held, and stops there.

const std = @import("std");
const corpus = @import("corpus.zig");
const mouse = @import("mouse.zig");
const query = @import("query.zig");
const replies = @import("reply.zig");
const seq = @import("seq.zig");
const win32 = @import("win32.zig");

/// Which way round the terminal's palette is, as mode 2031 reports it.
/// Aliased from `query`, where the question that asks for it lives.
const ColorScheme = query.ColorScheme;

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
    ///
    /// The first one arrives on being asked, before anything has resized,
    /// so a program that turns the mode on has already asked its size.
    resize: Resize,
    /// The terminal's palette became light or dark, and it said so on the
    /// input stream (`CSI ? 997 ; 1 n` or `; 2 n`).
    ///
    /// A terminal asked for `colorScheme`, mode 2031, sends these unprompted
    /// whenever the palette changes; the same sequence is the answer to
    /// `queryColorScheme`, so a program that asked once and then asked to be
    /// told sees both here and needs to tell neither apart.
    color_scheme: ColorScheme,
    /// The mouse moved, or a button went down or came up: an SGR report
    /// (mode 1006, or 1016 in pixels when `KeyParser.mouse_pixels` says
    /// so), an rxvt one (1015) or a legacy X10 one.
    mouse: mouse.MouseEvent,
    /// The terminal's answer to a question: a mode's state, its colours, a
    /// size, a graphics acknowledgement, its identity, a capability. See
    /// `Reply`. Where it carries bytes it borrows them from the parser's
    /// buffer, on the same terms as `unhandled`; the rest is a value.
    reply: replies.Reply,
    /// A complete sequence the parser framed and cannot read: nothing this
    /// package asks for is answered this way, and neither is any key.
    ///
    /// Borrowed from the parser's buffer, and valid only until the next call
    /// to `Events.next`, `KeyParser.feed` or `KeyParser.flush`. Copy it if it
    /// has to outlive that.
    unhandled: []const u8,
    /// A run of printable text: what was pasted, or what a fast typist or an
    /// input method produced between one sequence and the next.
    ///
    /// Valid UTF-8, never empty, and never one codepoint — a single
    /// printable codepoint is a keypress and arrives as `key`, because that
    /// is what it is. Two or more in a row are text, and handing back the
    /// slice is the difference between a megabyte of pasted text costing one
    /// event and costing a million: a `KeyEvent` is forty-odd bytes built
    /// per character, against a slice that copies nothing.
    ///
    /// A run is cut wherever the bytes run out, so the same paste may arrive
    /// as several runs and a program that cares about the whole of it must
    /// join them. It carries no modifiers: text that arrived with a modifier
    /// held is a keypress, not text.
    ///
    /// Borrowed from the parser's buffer on the same terms as `unhandled`.
    text: []const u8,
    /// A sequence longer than the caller's buffer arrived, and this many
    /// bytes of it were dropped.
    ///
    /// The parser holds one sequence at a time, so a sequence that does not
    /// fit cannot be handed back whole. What it can do is say so, and pick
    /// the stream up at the end of that sequence rather than in the middle
    /// of it — the bytes inside an OSC 52 reply are base64, and read as
    /// input they are keypresses the user did not type.
    ///
    /// It is reported once, when the end of the sequence has gone by, and
    /// the count is every byte of it. A stream that stops before that end
    /// reports on `KeyParser.flush` instead.
    ///
    /// The cure is a bigger buffer: `KeyParser.min_buffer` covers keys, and
    /// a program that asks the terminal questions has to cover the answers.
    overflow: usize,
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
    /// terminal sends for a key, with room to spare — and only for those.
    ///
    /// The same parser frames the replies that arrive on the same stream,
    /// and an OSC, DCS or APC reply is as long as whatever it carries: a
    /// clipboard reply is as long as what was copied, a capability reply as
    /// long as the capability. A sequence longer than the buffer cannot be
    /// handed back, and is refused by name — `Event.overflow`, saying how
    /// many bytes went — rather than being let through as the keypresses
    /// its bytes look like. Size the buffer for the questions the program
    /// asks.
    pub const min_buffer = 64;

    /// What a sequence too long for the buffer is still waiting for, while
    /// the rest of it is skipped past.
    const Skipping = enum {
        /// A control string: `OSC`, `DCS`, `SOS`, `PM` or `APC`. It ends at
        /// `BEL`, or at the `ESC` that either opens its `ST` or begins the
        /// next sequence.
        string,
        /// Anything else, which ends at its final byte.
        sequence,
    };

    /// The caller's buffer. Bytes between `start` and `end` are what has
    /// arrived and not yet been read.
    buffer: []u8,
    /// Where the unread bytes begin.
    start: usize = 0,
    /// Where the unread bytes end.
    end: usize = 0,
    /// Report the key coming up as well as going down, in win32 input mode.
    ///
    /// Mode 9001 reports both halves of every keystroke, which is twice what
    /// a program that only wants what was typed asks for, so the up half is
    /// dropped unless this is set. It changes nothing about the other
    /// protocols: a kitty release arrives only when the terminal was asked
    /// for event types, and is always reported.
    report_key_up: bool = false,
    /// Whether SGR mouse reports are in pixels, which is mode 1016 and not
    /// something the report itself says: the encoding is the same as 1006.
    /// A program that asked for `Mouse.Encoding.sgr_pixels` sets this, and
    /// the parser marks each `MouseEvent` it reads as `pixels`.
    mouse_pixels: bool = false,
    /// A key still owed repeats, and how many. One win32 sequence can stand
    /// for several keypresses.
    repeating: ?KeyEvent = null,
    /// How many more times `repeating` is still to be reported.
    repeat_left: u16 = 0,
    /// Where a console character that takes more than one sequence is held
    /// while the rest of it arrives: the halves of a surrogate pair, and the
    /// keypad digits of an Alt composition. Win32 input mode only; every
    /// other protocol spells a character in one sequence.
    console: win32.ConsoleState = .{},
    /// The tail of a sequence too long for the buffer, still being skipped.
    skipping: ?Skipping = null,
    /// How many bytes of that sequence have been dropped so far.
    dropped: usize = 0,

    /// A parser over `buffer`, which must be at least `min_buffer` bytes.
    pub fn init(buffer: []u8) KeyParser {
        std.debug.assert(buffer.len >= min_buffer);
        return .{ .buffer = buffer };
    }

    /// Hands `bytes` to the parser and returns the events they complete.
    ///
    /// Run the returned iterator to null before the next call, or keep its
    /// `Events.remainder` and pass that slice to the next `feed`. The iterator
    /// is what moves bytes out of `bytes` and into the parser; the natural
    /// read loop drains it:
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
        // A sequence too long for the buffer whose end never arrived. The
        // bytes are already gone; what is owed is the count.
        if (p.skipping != null) {
            p.skipping = null;
            const dropped = p.dropped;
            p.dropped = 0;
            return .{ .overflow = dropped };
        }
        if (held.len == 0 or held[0] != seq.esc) return null;
        if (held.len == 1) return .{ .key = .{ .key = .escape } };
        if (held.len == 2 and (held[1] == '[' or held[1] == 'O')) {
            return .{ .key = .{ .key = .{ .char = held[1] }, .mods = .{ .alt = true } } };
        }
        return null;
    }

    /// A framed sequence read as the mouse report or the reply it is, when
    /// it is one; anything else as it came.
    fn read(p: *const KeyParser, event: Event) Event {
        const bytes = switch (event) {
            .unhandled => |b| b,
            else => return event,
        };
        if (mouse.parseMouse(bytes)) |m| {
            var ev = m;
            ev.pixels = p.mouse_pixels;
            return .{ .mouse = ev };
        }
        if (mouse.parseMouseX10(bytes)) |m| return .{ .mouse = m };
        if (mouse.parseMouseRxvt(bytes)) |m| return .{ .mouse = m };
        if (replies.Reply.parse(bytes)) |r| return .{ .reply = r };
        return event;
    }

    /// Throws away whatever is pending. What a program calls after it has
    /// been suspended, or after the terminal has been reset underneath it,
    /// because the bytes from before are no longer part of anything.
    pub fn reset(p: *KeyParser) void {
        p.start = 0;
        p.end = 0;
        p.repeating = null;
        p.repeat_left = 0;
        p.console.reset();
        p.skipping = null;
        p.dropped = 0;
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

    /// The part of the slice passed to `feed` that has not entered the parser.
    ///
    /// This makes stopping an iterator early recoverable. Bytes already
    /// copied into the parser remain there; pass this slice to the next
    /// `feed` before any newer input and iteration resumes in stream order.
    /// The slice borrows from the original input and has the same lifetime.
    pub fn remainder(it: *const Events) []const u8 {
        return it.fresh;
    }

    /// The next event, or null when what is left is a partial sequence — or
    /// nothing.
    ///
    /// Null does not mean the parser is empty: see `KeyParser.pending`.
    pub fn next(it: *Events) ?Event {
        const p = it.parser;

        // A repeat owed from a win32 sequence comes before any new bytes, so
        // that a held key arrives in the order it was typed.
        if (p.repeating) |held| {
            p.repeat_left -= 1;
            if (p.repeat_left == 0) p.repeating = null;
            var again = held;
            again.kind = .repeat;
            return .{ .key = again };
        }

        while (true) {
            // The tail of a sequence that did not fit comes before anything
            // else: the stream is picked up at its end, not in its middle.
            if (p.skipping != null) return it.skipOverflow();

            // Topping up here rather than in `feed` is what lets one feed of
            // many kilobytes drain through a buffer of a few dozen bytes.
            // Only when the buffer has run dry, though: a top-up moves the
            // unread bytes to the front, so one per event costs the whole
            // buffer per keypress and costs more the larger the buffer is.
            // The other place it is done is on `.incomplete`, which is the
            // only other time more bytes can change the answer.
            if (p.start == p.end and it.fresh.len != 0) _ = it.fill();

            if (p.start == p.end) return null;

            switch (decode(p.buffer[p.start..p.end], p.report_key_up, &p.console)) {
                .ready => |done| {
                    p.start += done.len;
                    if (done.repeat > 1) switch (done.event) {
                        .key => |ev| {
                            p.repeating = ev;
                            p.repeat_left = done.repeat - 1;
                        },
                        else => {},
                    };
                    return p.read(done.event);
                },
                .skip => |n| {
                    p.start += n;
                    continue;
                },
                .incomplete => {
                    // The start of a sequence and not the whole of it. More
                    // of this feed may finish it; nothing else can.
                    if (it.fresh.len != 0 and it.fill() != 0) continue;

                    // A full buffer that is still the start of something is
                    // a sequence longer than the caller sized for. Nothing
                    // more can arrive to complete it, so what is here goes
                    // and the rest of it is skipped to its end -- which is
                    // the only place this parser drops bytes, and the one
                    // thing it reports rather than decodes.
                    if (p.end - p.start == p.buffer.len) {
                        p.skipping = overflowKind(p.buffer[p.start..p.end]);
                        p.dropped = p.buffer.len;
                        p.start = 0;
                        p.end = 0;
                        continue;
                    }
                    return null;
                },
            }
        }
    }

    /// Skips what is left of a sequence too long for the buffer, and reports
    /// it once its end has gone by.
    ///
    /// Null means the feed ran out first: the parser stays in this state and
    /// the next feed goes on skipping, so the sequence is left behind at its
    /// own end however many reads it spans.
    fn skipOverflow(it: *Events) ?Event {
        const p = it.parser;
        const kind = p.skipping.?;
        outer: while (true) {
            while (p.start < p.end) {
                const b = p.buffer[p.start];
                switch (kind) {
                    .string => {
                        if (b == seq.bel) {
                            p.start += 1;
                            p.dropped += 1;
                            break :outer;
                        }
                        if (b == seq.esc) {
                            // `ST` ends the string; a bare `ESC` is the next
                            // sequence and is left where it is.
                            if (p.end - p.start < 2) break;
                            if (p.buffer[p.start + 1] == '\\') {
                                p.start += 2;
                                p.dropped += 2;
                            }
                            break :outer;
                        }
                    },
                    .sequence => if (b >= 0x40 and b <= 0x7e) {
                        p.start += 1;
                        p.dropped += 1;
                        break :outer;
                    },
                }
                p.start += 1;
                p.dropped += 1;
            }
            if (it.fresh.len == 0) return null;
            _ = it.fill();
        }

        p.skipping = null;
        const dropped = p.dropped;
        p.dropped = 0;
        return .{ .overflow = dropped };
    }

    /// Moves as much of the unread input into the parser's buffer as will
    /// fit, and says how many bytes that was.
    ///
    /// Zero means the buffer is full of a sequence that is not finished,
    /// which is the one case the parser cannot resolve by waiting.
    fn fill(it: *Events) usize {
        const p = it.parser;
        p.compact();
        const take = @min(p.buffer.len - p.end, it.fresh.len);
        @memcpy(p.buffer[p.end..][0..take], it.fresh[0..take]);
        p.end += take;
        it.fresh = it.fresh[take..];
        return take;
    }
};

//=========================================================================
// Decoding one sequence off the front of a byte string.
//=========================================================================

/// Which terminator the tail of an over-long sequence is being skipped to.
///
/// Read off the two bytes that introduced it, which are still at the front of
/// the buffer when the overflow is noticed.
fn overflowKind(bytes: []const u8) KeyParser.Skipping {
    if (bytes.len < 2 or bytes[0] != seq.esc) return .sequence;
    return switch (bytes[1]) {
        ']', 'P', 'X', '^', '_' => .string,
        else => .sequence,
    };
}

/// What the decoder made of the bytes in front of it.
const Decoded = union(enum) {
    /// An event, how many bytes it used, and how many times it happened.
    ///
    /// `repeat` is one for every sequence but win32 input mode's, which
    /// carries a count because a console reports auto-repeat as one record
    /// rather than as many.
    ready: struct { event: Event, len: usize, repeat: u16 = 1 },
    /// The start of something; more bytes may complete it.
    incomplete,
    /// Not the start of anything. Drop this many bytes and look again.
    skip: usize,
};

fn ready(event: Event, len: usize) Decoded {
    return .{ .ready = .{ .event = event, .len = len } };
}

/// Reads one event off the front of `bytes`, which is never empty.
fn decode(bytes: []const u8, report_key_up: bool, console: *win32.ConsoleState) Decoded {
    std.debug.assert(bytes.len != 0);
    if (bytes[0] == seq.esc) return decodeEscape(bytes, report_key_up, console);
    return decodeRun(bytes);
}

/// Reads a run of printable text off the front of `bytes`, or one key when
/// what is there is a single codepoint, a control code, or neither.
///
/// The run stops at the first byte that is not printable text -- a control
/// code, `DEL`, an `ESC`, a byte that is not valid UTF-8 -- and at a
/// codepoint the bytes do not hold the whole of, which is left for the read
/// that completes it.
fn decodeRun(bytes: []const u8) Decoded {
    var len: usize = 0;
    var codepoints: usize = 0;
    while (len < bytes.len) {
        const b = bytes[len];
        if (b < 0x20 or b == 0x7f) break;
        if (b < 0x80) {
            len += 1;
            codepoints += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(b) catch break;
        if (len + n > bytes.len) break;
        _ = std.unicode.utf8Decode(bytes[len..][0..n]) catch break;
        len += n;
        codepoints += 1;
    }
    // One codepoint is a keypress, and so is anything that is not text at
    // all: `decodePlain` reads the control codes and reports the bytes a
    // key produced, which a run does not do.
    if (codepoints < 2) return decodePlain(bytes, .{}, 0);
    return ready(.{ .text = bytes[0..len] }, len);
}

/// Reads a key that is not introduced by `ESC`: a C0 control, or UTF-8 text.
///
/// `prefix` is how many bytes came before `bytes` in the sequence being
/// decoded, so that the `ESC`-prefixed alt form can reuse this and still
/// report the right length.
fn decodePlain(bytes: []const u8, mods: Modifiers, prefix: usize) Decoded {
    const b = bytes[0];
    if (b > 0x7f) return decodeUtf8(bytes, mods, prefix);

    var m = mods;
    const which = asciiKey(b, &m);
    var ev: KeyEvent = .{ .key = which, .mods = m };
    setText(&ev, bytes[0..1]);
    return ready(.{ .key = ev }, prefix + 1);
}

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

/// Reads a sequence introduced by `ESC`, which is every sequence there is —
/// and also alt, which terminals spell by putting an `ESC` in front of the
/// key's own bytes.
fn decodeEscape(bytes: []const u8, report_key_up: bool, console: *win32.ConsoleState) Decoded {
    // A lone ESC is both the Escape key and the start of everything else.
    // Nothing in the stream resolves that, so it waits; see KeyParser.flush.
    if (bytes.len == 1) return .incomplete;

    return switch (bytes[1]) {
        '[' => decodeCsi(bytes, report_key_up, console),
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

    // Unlike CSI, where the modifiers are the second parameter, an SS3 that
    // carries modifiers at all carries them as its only one.
    const params = scanParams(bytes[2..i]) orelse return ready(.{ .unhandled = whole }, len);
    if (rxvtCursorKey(final)) |key| {
        if (params.count != 0) return ready(.{ .unhandled = whole }, len);
        return ready(.{ .key = .{ .key = key, .mods = .{ .ctrl = true } } }, len);
    }

    const key = ss3Key(final) orelse return ready(.{ .unhandled = whole }, len);
    var ev: KeyEvent = .{ .key = key };
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

/// The arrow named by the lowercase cursor finals rxvt uses for modifiers.
fn rxvtCursorKey(final: u8) ?Key {
    return switch (final) {
        'a' => .up,
        'b' => .down,
        'c' => .right,
        'd' => .left,
        else => null,
    };
}

/// Frames a `CSI` sequence and, when it is one, reads the key out of it.
///
/// Framing and reading are separate on purpose: a sequence with a private
/// marker, an intermediate byte, or more parameters than this parser holds is
/// still a sequence whose length is known, so it comes back whole as
/// `Event.unhandled` rather than being resynchronised byte by byte.
fn decodeCsi(bytes: []const u8, report_key_up: bool, console: *win32.ConsoleState) Decoded {
    // The Linux virtual console spells F1 through F5 with a second `[` in
    // front of the final. Treat that byte as an intermediate here even
    // though it lies in the standard final-byte range.
    if (bytes.len > 2 and bytes[2] == '[') {
        if (bytes.len == 3) return .incomplete;
        const final = bytes[3];
        if (final < 0x40 or final > 0x7e) return .{ .skip = 1 };
        const whole = bytes[0..4];
        const number = switch (final) {
            'A'...'E' => final - 'A' + 1,
            else => return ready(.{ .unhandled = whole }, whole.len),
        };
        return ready(.{ .key = .{ .key = .{ .f = number } } }, whole.len);
    }

    var i: usize = 2;

    // A private marker, if there is one: `<` for a mouse report, `?` for a
    // DEC private reply, `>` for a secondary attributes reply. None of them
    // is ever a key.
    var marker: u8 = 0;
    if (i < bytes.len and bytes[i] >= '<' and bytes[i] <= '?') {
        marker = bytes[i];
        i += 1;
    }
    const private = marker != 0;

    const param_start = i;
    while (i < bytes.len and bytes[i] >= 0x30 and bytes[i] <= 0x3f) : (i += 1) {}
    const param_end = i;

    // rxvt uses `$` as a final byte after a numbered key, although `$` is an
    // intermediate in the standard CSI grammar. Private sequences still use
    // it as that intermediate, including the mode replies parsed below.
    if (!private and param_end > param_start and i < bytes.len and bytes[i] == '$') {
        const len = i + 1;
        const whole = bytes[0..len];
        const params = scanParams(bytes[param_start..param_end]) orelse
            return ready(.{ .unhandled = whole }, len);
        const event = rxvtNumberedEvent('$', params) orelse
            return ready(.{ .unhandled = whole }, len);
        return ready(event, len);
    }

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

    // One private reply is an event rather than an answer to fetch: the
    // colour scheme report, which a terminal in mode 2031 sends unasked.
    // Everything else wearing a private marker is a reply to a question
    // somebody asked, and goes back whole for the parser that asked it.
    if (marker == '?' and final == 'n' and intermediate_end == param_end) {
        if (scanParams(bytes[param_start..param_end])) |params| {
            if (colorSchemeEvent(params)) |event| return ready(event, len);
        }
    }

    if (private or intermediate_end != param_end) return ready(.{ .unhandled = whole }, len);

    const params = scanParams(bytes[param_start..param_end]) orelse
        return ready(.{ .unhandled = whole }, len);

    // Win32 input mode carries its own repeat count and its own key-up half,
    // neither of which any other sequence has, so it is decoded here rather
    // than through `csiEvent`.
    if (final == '_') {
        const report = win32Event(params, console) orelse
            return ready(.{ .unhandled = whole }, len);
        const key_report = switch (report) {
            .report => |r| r,
            // Half a character: read, consumed, and not an event yet.
            .held => return .{ .skip = len },
        };
        if (key_report.event.kind == .release and !report_key_up) return .{ .skip = len };
        return .{ .ready = .{
            .event = .{ .key = key_report.event },
            .len = len,
            .repeat = key_report.repeat,
        } };
    }

    const event = csiEvent(final, params) orelse return ready(.{ .unhandled = whole }, len);
    return ready(event, len);
}

/// One key out of a win32 input mode sequence, and how many times it happened.
const Win32Report = union(enum) {
    /// A key, and how many times it happened.
    report: struct { event: KeyEvent, repeat: u16 },
    /// The sequence was read and produced no key: half a character, or a
    /// keypad digit being composed with Alt. It is consumed either way.
    held,
};

/// Reads `CSI Vk ; Sc ; Uc ; Kd ; Cs ; Rc _`, the win32 input mode encoding
/// of one console key record.
///
/// `console` is where a character that takes more than one record is held:
/// the halves of a surrogate pair, and the keypad digits of an Alt
/// composition. See `win32.ConsoleState`.
///
/// Every field is optional and every one has a documented default: zero for
/// the virtual key, the scan code, the character and the key-down flag, zero
/// for the control-key state, and one for the repeat count. A field too large
/// for the record's own type is not a record this package hands back, so the
/// sequence comes out whole instead.
fn win32Event(params: Params, console: *win32.ConsoleState) ?Win32Report {
    if (params.count > 6) return null;

    const vk = std.math.cast(u16, params.get(0, 0) orelse 0) orelse return null;
    // The scan code names a position rather than a key, so it is read only to
    // be checked and then discarded.
    _ = std.math.cast(u16, params.get(1, 0) orelse 0) orelse return null;
    const uc = std.math.cast(u16, params.get(2, 0) orelse 0) orelse return null;
    const down = (params.get(3, 0) orelse 0) != 0;
    const state = params.get(4, 0) orelse 0;
    const repeat = std.math.cast(u16, params.get(5, 0) orelse 1) orelse return null;

    const ev = switch (console.decode(vk, uc, state, down)) {
        .key => |ev| ev,
        .held => return .held,
        .unknown => return null,
    };
    return .{ .report = .{ .event = ev, .repeat = @max(repeat, 1) } };
}

/// The event a parameterised `CSI` with no private marker stands for, or null
/// when it stands for none.
fn csiEvent(final: u8, params: Params) ?Event {
    switch (final) {
        'u' => return kittyEvent(params),
        '~' => return tildeEvent(params),
        '^', '@' => return rxvtNumberedEvent(final, params),
        'a', 'b', 'c', 'd' => {
            if (params.count != 0) return null;
            return .{ .key = .{
                .key = rxvtCursorKey(final).?,
                .mods = .{ .shift = true },
            } };
        },
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

/// Reads rxvt's numbered-key modifier finals: shift, control, and both.
fn rxvtNumberedEvent(final: u8, params: Params) ?Event {
    if (params.count != 1 or params.get(0, 1) != null) return null;
    const key = tildeKey(params.get(0, 0) orelse return null) orelse return null;
    const mods: Modifiers = switch (final) {
        '$' => .{ .shift = true },
        '^' => .{ .ctrl = true },
        '@' => .{ .shift = true, .ctrl = true },
        else => return null,
    };
    return .{ .key = .{ .key = key, .mods = mods } };
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

/// Reads a colour scheme report: `CSI ? 997 ; scheme n`.
///
/// Exactly two parameters, no sub-parameters, and a scheme the protocol
/// names — anything else is somebody's reply and is handed back whole.
fn colorSchemeEvent(params: Params) ?Event {
    if (params.count != 2) return null;
    if (params.get(0, 1) != null or params.get(1, 1) != null) return null;
    if (params.get(0, 0) != 997) return null;
    return switch (params.get(1, 0) orelse return null) {
        @intFromEnum(ColorScheme.dark) => .{ .color_scheme = .dark },
        @intFromEnum(ColorScheme.light) => .{ .color_scheme = .light },
        else => null,
    };
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
///
/// The parser dies with the call, so an event that borrows its buffer --
/// `unhandled`, `text` -- is dangling by the time this returns. Tests for
/// those use `expectUnhandled` and `expectRun` instead.
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

/// Asserts that `bytes` is framed whole and read as a reply of `tag`.
fn expectReply(bytes: []const u8, tag: std.meta.Tag(replies.Reply)) !void {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);
    var events = parser.feed(bytes);
    const first = events.next() orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(tag, std.meta.activeTag(first.reply));
    try std.testing.expectEqual(@as(?Event, null), events.next());
    try std.testing.expectEqual(@as(usize, 0), parser.pending().len);
}

/// The one mouse report `bytes` is framed and read as.
fn oneMouse(bytes: []const u8) !mouse.MouseEvent {
    var buffer: [8]Event = undefined;
    const events = collect(bytes, &buffer);
    if (events.len != 1) return error.TestExpectedEqual;
    return events[0].mouse;
}

test "a printable byte is a character, and carries itself as text" {
    const ev = oneKey("a").?;
    try std.testing.expectEqual(Key{ .char = 'a' }, ev.key);
    try std.testing.expectEqual(Modifiers{}, ev.mods);
    try std.testing.expectEqual(Kind.press, ev.kind);
    try std.testing.expectEqualStrings("a", ev.text());
}

/// Asserts that `bytes` decodes to one text run holding exactly `run`.
///
/// Checked while the parser still holds it, for the reason `expectUnhandled`
/// is written the same way: a run borrows the parser's buffer, and only
/// until the next call.
fn expectRun(bytes: []const u8, run: []const u8) !void {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);
    var events = parser.feed(bytes);
    const first = events.next() orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(run, first.text);
}

test "a run of text is one event, and one codepoint is a key" {
    try expectRun("hi!", "hi!");

    var buffer: [8]Event = undefined;
    const alone = collect("h", &buffer);
    try std.testing.expectEqual(@as(usize, 1), alone.len);
    try std.testing.expectEqual(Key{ .char = 'h' }, alone[0].key.key);
}

test "a run stops at the first thing that is not text" {
    var storage: [KeyParser.min_buffer]u8 = undefined;

    var controlled: KeyParser = .init(&storage);
    var control_events = controlled.feed("hi\x01");
    try std.testing.expectEqualStrings("hi", control_events.next().?.text);
    const ctrl_a = control_events.next().?.key;
    try std.testing.expectEqual(Key{ .char = 'a' }, ctrl_a.key);
    try std.testing.expect(ctrl_a.mods.ctrl);

    var introduced: KeyParser = .init(&storage);
    var sequence_events = introduced.feed("hi\x1b[A");
    try std.testing.expectEqualStrings("hi", sequence_events.next().?.text);
    try std.testing.expectEqual(Key.up, sequence_events.next().?.key.key);

    var deleted: KeyParser = .init(&storage);
    var delete_events = deleted.feed("hi\x7f");
    try std.testing.expectEqualStrings("hi", delete_events.next().?.text);
    try std.testing.expectEqual(Key.backspace, delete_events.next().?.key.key);
}

test "a run is UTF-8, and never cuts a codepoint in half" {
    try expectRun("a\u{e9}\u{4e2d}\u{1f642}", "a\u{e9}\u{4e2d}\u{1f642}");

    // A codepoint split across two reads is held, and the run that follows
    // is the whole of it.
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);
    var first = parser.feed("ab\xf0\x9f");
    try std.testing.expectEqualStrings("ab", first.next().?.text);
    try std.testing.expectEqual(@as(?Event, null), first.next());

    var second = parser.feed("\x99\x82cd");
    try std.testing.expectEqualStrings("\u{1f642}cd", second.next().?.text);
    try std.testing.expectEqual(@as(?Event, null), second.next());
}

test "a run borrows from the parser's buffer, not from the caller's bytes" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);

    var events = parser.feed("hello");
    const run = events.next().?.text;
    try std.testing.expect(@intFromPtr(run.ptr) >= @intFromPtr(&storage));
    try std.testing.expect(
        @intFromPtr(run.ptr) + run.len <= @intFromPtr(&storage) + storage.len,
    );
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

test "the Linux console function keys decode from their double bracket form" {
    const cases = [_][]const u8{
        "\x1b[[A",
        "\x1b[[B",
        "\x1b[[C",
        "\x1b[[D",
        "\x1b[[E",
    };
    for (cases, 1..) |bytes, number| {
        const ev = oneKey(bytes).?;
        try std.testing.expectEqual(Key{ .f = @intCast(number) }, ev.key);
        try std.testing.expectEqual(Modifiers{}, ev.mods);
        try std.testing.expectEqualStrings("", ev.text());
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

test "rxvt modifier finals decode numbered editing keys" {
    const cases = [_]struct { bytes: []const u8, key: Key, mods: Modifiers }{
        .{ .bytes = "\x1b[2$", .key = .insert, .mods = .{ .shift = true } },
        .{ .bytes = "\x1b[5^", .key = .page_up, .mods = .{ .ctrl = true } },
        .{
            .bytes = "\x1b[3@",
            .key = .delete,
            .mods = .{ .shift = true, .ctrl = true },
        },
    };
    for (cases) |case| {
        const ev = oneKey(case.bytes).?;
        try std.testing.expectEqual(case.key, ev.key);
        try std.testing.expectEqual(case.mods, ev.mods);
    }
}

test "rxvt modifier finals decode numbered function keys" {
    const cases = [_]struct { bytes: []const u8, key: Key, mods: Modifiers }{
        .{ .bytes = "\x1b[23$", .key = .{ .f = 11 }, .mods = .{ .shift = true } },
        .{ .bytes = "\x1b[11^", .key = .{ .f = 1 }, .mods = .{ .ctrl = true } },
        .{
            .bytes = "\x1b[23@",
            .key = .{ .f = 11 },
            .mods = .{ .shift = true, .ctrl = true },
        },
    };
    for (cases) |case| {
        const ev = oneKey(case.bytes).?;
        try std.testing.expectEqual(case.key, ev.key);
        try std.testing.expectEqual(case.mods, ev.mods);
    }
}

test "rxvt lowercase cursor finals decode shift and control arrows" {
    const cases = [_]struct { bytes: []const u8, key: Key, mods: Modifiers }{
        .{ .bytes = "\x1b[a", .key = .up, .mods = .{ .shift = true } },
        .{ .bytes = "\x1b[b", .key = .down, .mods = .{ .shift = true } },
        .{ .bytes = "\x1b[c", .key = .right, .mods = .{ .shift = true } },
        .{ .bytes = "\x1b[d", .key = .left, .mods = .{ .shift = true } },
        .{ .bytes = "\x1bOa", .key = .up, .mods = .{ .ctrl = true } },
        .{ .bytes = "\x1bOb", .key = .down, .mods = .{ .ctrl = true } },
        .{ .bytes = "\x1bOc", .key = .right, .mods = .{ .ctrl = true } },
        .{ .bytes = "\x1bOd", .key = .left, .mods = .{ .ctrl = true } },
    };
    for (cases) |case| {
        const ev = oneKey(case.bytes).?;
        try std.testing.expectEqual(case.key, ev.key);
        try std.testing.expectEqual(case.mods, ev.mods);
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

test "a paste is a start, the text as one run, and an end" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);
    var events = parser.feed("\x1b[200~hi there\x1b[201~");

    try std.testing.expectEqual(Event.paste_start, events.next().?);
    try std.testing.expectEqualStrings("hi there", events.next().?.text);
    try std.testing.expectEqual(Event.paste_end, events.next().?);
    try std.testing.expectEqual(@as(?Event, null), events.next());
}

test "a reply is framed whole and read as the answer it is" {
    const cases = [_]struct { bytes: []const u8, tag: std.meta.Tag(replies.Reply) }{
        .{ .bytes = "\x1b[?2026;1$y", .tag = .mode },
        .{ .bytes = "\x1b[12;40R", .tag = .cursor_position },
        .{ .bytes = "\x1b[?12;40;1R", .tag = .extended_cursor_position },
        .{ .bytes = "\x1b[?1u", .tag = .kitty_keyboard },
        .{ .bytes = "\x1b[?62;1;6c", .tag = .device_attributes },
        .{ .bytes = "\x1b[>0;276;0c", .tag = .secondary_device_attributes },
        .{ .bytes = "\x1b]52;c;aGk=\x1b\\", .tag = .clipboard },
        .{ .bytes = "\x1b]11;rgb:0000/0000/0000\x1b\\", .tag = .color },
        .{ .bytes = "\x1bP>|xterm(390)\x1b\\", .tag = .version },
        .{ .bytes = "\x1bP1+r436f=323536\x1b\\", .tag = .capability },
        .{ .bytes = "\x1bP0+r436f\x1b\\", .tag = .capability },
        .{ .bytes = "\x1b_Gi=31;OK\x1b\\", .tag = .graphics },
    };
    for (cases) |case| try expectReply(case.bytes, case.tag);
}

test "a mouse report is framed whole and read" {
    const sgr = try oneMouse("\x1b[<0;40;12M");
    try std.testing.expectEqual(@as(u32, 40), sgr.x);
    try std.testing.expectEqual(@as(u32, 12), sgr.y);
    try std.testing.expect(sgr.press and !sgr.pixels);
    // Both fields carry their value plus 32.
    const rxvt = try oneMouse("\x1b[32;72;44M");
    try std.testing.expectEqual(@as(u32, 40), rxvt.x);
    try std.testing.expectEqual(@as(u32, 12), rxvt.y);
}

test "a report in pixels is marked so when the parser is told" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);
    parser.mouse_pixels = true;
    var events = parser.feed("\x1b[<0;400;120M");
    const m = events.next().?.mouse;
    try std.testing.expect(m.pixels);
    try std.testing.expectEqual(@as(u32, 400), m.x);
}

test "a sequence that is neither a key nor an answer comes back whole" {
    const cases = [_][]const u8{
        "\x1b]2;title\x07", // an OSC ended by BEL
        "\x1b(B", // a character set designation
        "\x1b[2M", // delete lines, which no terminal sends as input
    };
    for (cases) |bytes| try expectUnhandled(bytes);
}

test "an rxvt mouse report is framed whole, and the key behind it survives" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);

    // Every byte of it is a parameter or a final, so the framing needs
    // nothing the sequence does not already say -- unlike the X10 form, whose
    // three fields are counted rather than read.
    var events = parser.feed("\x1b[32;72;44Ma");
    try std.testing.expectEqual(@as(u32, 40), events.next().?.mouse.x);
    try std.testing.expectEqual(Key{ .char = 'a' }, events.next().?.key.key);
    try std.testing.expectEqual(@as(?Event, null), events.next());
}

test "an XTGETTCAP reply is framed whole, and the key behind it survives" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);

    // The payload is hex precisely so that a capability whose value is an
    // escape sequence cannot end the reply carrying it. The framing has to
    // hold for the whole of it, or the bytes after it arrive as keypresses.
    var events = parser.feed("\x1bP1+r6b656e64=1b4f46\x1b\\a");
    const reply = events.next().?.reply.capability;
    try std.testing.expect(reply.known);
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
    try std.testing.expect(events.next().?.reply.capability.known);
    try std.testing.expectEqual(@as(?Event, null), events.next());
}

test "a mouse report and the key after it both come out, and so does an unread sequence" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);
    var events = parser.feed("\x1b[<0;40;12Ma\x1b]2;t\x07b");
    try std.testing.expectEqual(@as(u32, 40), events.next().?.mouse.x);
    try std.testing.expectEqual(Key{ .char = 'a' }, events.next().?.key.key);
    try std.testing.expectEqualStrings("\x1b]2;t\x07", events.next().?.unhandled);
    try std.testing.expectEqual(Key{ .char = 'b' }, events.next().?.key.key);
    try std.testing.expectEqual(@as(?Event, null), events.next());
}

test "a mouse report and the key after it both come out" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);
    var events = parser.feed("\x1b[<0;40;12Ma");
    try std.testing.expectEqual(@as(u32, 12), events.next().?.mouse.y);
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

test "a sequence lying across the end of the buffer is completed, not dropped" {
    // The buffer fills, its tail is half a sequence, and the rest of that
    // sequence is still in the bytes the caller handed over. Topping up on
    // `.incomplete` is what finishes it; without that the half that fitted
    // is dropped and the half that follows decodes as whatever it looks
    // like on its own.
    const cycle = "\x1b[48;24;80;384;640t" ++ "abcdefg";
    const rounds = 40;
    var input: [cycle.len * rounds]u8 = undefined;
    for (0..rounds) |i| @memcpy(input[i * cycle.len ..][0..cycle.len], cycle);

    for ([_]usize{ 1, 7, 64, 129, input.len }) |read| {
        var storage: [KeyParser.min_buffer]u8 = undefined;
        var parser: KeyParser = .init(&storage);

        var sizes: usize = 0;
        var offset: usize = 0;
        while (offset < input.len) {
            const end = @min(offset + read, input.len);
            var events = parser.feed(input[offset..end]);
            while (events.next()) |event| {
                if (event == .resize) {
                    sizes += 1;
                    try std.testing.expectEqual(@as(u32, 24), event.resize.rows);
                }
            }
            offset = end;
        }
        try std.testing.expectEqual(@as(usize, rounds), sizes);
        try std.testing.expectEqual(@as(usize, 0), parser.pending().len);
    }
}

test "a feed longer than the buffer drains through it" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);

    // Cut into runs wherever the buffer ends, and every byte accounted for.
    var input: [1000]u8 = @splat('x');
    var events = parser.feed(&input);
    var seen: usize = 0;
    while (events.next()) |event| {
        for (event.text) |b| try std.testing.expectEqual(@as(u8, 'x'), b);
        seen += event.text.len;
    }
    try std.testing.expectEqual(@as(usize, input.len), seen);
    try std.testing.expectEqual(@as(usize, 0), parser.pending().len);
}

test "an abandoned iterator exposes the unread tail for a later feed" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);

    const input = "a" ** KeyParser.min_buffer ++ "b";
    var first = parser.feed(input);
    const run = first.next().?.text;
    try std.testing.expectEqual(@as(usize, KeyParser.min_buffer), run.len);

    const unread = first.remainder();
    try std.testing.expectEqualStrings("b", unread);

    var resumed = parser.feed(unread);
    try std.testing.expectEqual(Key{ .char = 'b' }, resumed.next().?.key.key);
    try std.testing.expectEqual(@as(?Event, null), resumed.next());
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

test "a sequence longer than the buffer is reported, and the stream resumes at its end" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);

    // A CSI whose parameters do not fit anywhere, and its final byte well
    // past the end of the buffer.
    var long: [KeyParser.min_buffer * 3]u8 = @splat('1');
    long[0] = seq.esc;
    long[1] = '[';
    long[long.len - 1] = 'm';

    var events = parser.feed(&long);
    try std.testing.expectEqual(@as(usize, long.len), events.next().?.overflow);
    try std.testing.expectEqual(@as(?Event, null), events.next());
    try std.testing.expectEqual(@as(usize, 0), parser.pending().len);

    var after = parser.feed("a");
    try std.testing.expectEqual(Key{ .char = 'a' }, after.next().?.key.key);
}

test "an over-long reply is one overflow, not three hundred keypresses" {
    // The case this exists for. An OSC 52 reply is as long as whatever was
    // copied, and its payload is base64 -- so a parser that cleared its
    // buffer and started again in the middle of one handed the caller a few
    // hundred keys the user never typed.
    const head = seq.osc ++ "52;c;";
    const tail = seq.st;
    var reply: [412]u8 = @splat('A');
    @memcpy(reply[0..head.len], head);
    @memcpy(reply[reply.len - tail.len ..], tail);

    for ([_]usize{ 1, 13, 64, 200, reply.len }) |read| {
        var storage: [KeyParser.min_buffer]u8 = undefined;
        var parser: KeyParser = .init(&storage);

        var overflows: usize = 0;
        var others: usize = 0;
        var offset: usize = 0;
        while (offset < reply.len) {
            const end = @min(offset + read, reply.len);
            var events = parser.feed(reply[offset..end]);
            while (events.next()) |event| switch (event) {
                .overflow => |n| {
                    overflows += 1;
                    try std.testing.expectEqual(@as(usize, reply.len), n);
                },
                else => others += 1,
            };
            offset = end;
        }
        try std.testing.expectEqual(@as(usize, 1), overflows);
        try std.testing.expectEqual(@as(usize, 0), others);

        // And the key behind it is the next thing out.
        var after = parser.feed("a");
        try std.testing.expectEqual(Key{ .char = 'a' }, after.next().?.key.key);
    }
}

test "a reply that fits needs no overflow at all" {
    // The same reply against a buffer sized for it: one sequence, whole.
    const head = seq.osc ++ "52;c;";
    var reply: [412]u8 = @splat('A');
    @memcpy(reply[0..head.len], head);
    @memcpy(reply[reply.len - seq.st.len ..], seq.st);

    var storage: [1024]u8 = undefined;
    var parser: KeyParser = .init(&storage);
    var events = parser.feed(&reply);
    try std.testing.expectEqualStrings(&reply, events.next().?.unhandled);
    try std.testing.expectEqual(@as(?Event, null), events.next());
}

test "an over-long sequence whose end never arrives is reported by flush" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);

    var long: [KeyParser.min_buffer * 2]u8 = @splat('x');
    long[0] = seq.esc;
    long[1] = ']';

    var events = parser.feed(&long);
    try std.testing.expectEqual(@as(?Event, null), events.next());
    try std.testing.expectEqual(@as(usize, long.len), parser.flush().?.overflow);
    try std.testing.expectEqual(@as(?Event, null), parser.flush());
}

test "an over-long control string ends at the ESC that starts the next one" {
    // An abandoned string does not swallow what follows it, whether or not
    // it fitted in the buffer.
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);

    var input: [KeyParser.min_buffer * 2 + 3]u8 = @splat('x');
    input[0] = seq.esc;
    input[1] = ']';
    input[input.len - 3] = seq.esc;
    input[input.len - 2] = '[';
    input[input.len - 1] = 'A';

    var events = parser.feed(&input);
    try std.testing.expectEqual(@as(usize, input.len - 3), events.next().?.overflow);
    try std.testing.expectEqual(Key.up, events.next().?.key.key);
    try std.testing.expectEqual(@as(?Event, null), events.next());
}

test "reset forgets a sequence that was being skipped past" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);

    var long: [KeyParser.min_buffer * 2]u8 = @splat('x');
    long[0] = seq.esc;
    long[1] = ']';

    var events = parser.feed(&long);
    try std.testing.expectEqual(@as(?Event, null), events.next());
    parser.reset();
    try std.testing.expectEqual(@as(?Event, null), parser.flush());

    var again = parser.feed("a");
    try std.testing.expectEqual(Key{ .char = 'a' }, again.next().?.key.key);
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
                        .text => |run| {
                            // The same, and valid UTF-8 of more than one
                            // codepoint -- one is a key, not a run.
                            try std.testing.expect(run.len >= 2);
                            try std.testing.expect(run.len <= storage.len);
                            try std.testing.expect(std.unicode.utf8ValidateSlice(run));
                            try std.testing.expect(@intFromPtr(run.ptr) >= @intFromPtr(&storage));
                            try std.testing.expect(
                                @intFromPtr(run.ptr) + run.len <= @intFromPtr(&storage) + storage.len,
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
        corpus.seed("\x1b[[A"),
        corpus.seed("\x1b[[B"),
        corpus.seed("\x1b[[C"),
        corpus.seed("\x1b[[D"),
        corpus.seed("\x1b[[E"),
        corpus.seed("\x1b[2$"),
        corpus.seed("\x1b[5^"),
        corpus.seed("\x1b[3@"),
        corpus.seed("\x1b[a\x1bOa"),
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
        corpus.seed("\x1b[200~a much longer pasted run\x1b[201~"),
        corpus.seed("text\x01text\x7ftext"),
        corpus.seed("\u{4e2d}\u{6587}\u{1f642}ab"),
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

//=========================================================================
// A second framer, for the differential fuzz target.
//
// The parser above is recursive descent: it looks at a byte, calls the
// function that reads what that byte introduces, and that function decides
// where the sequence ends. What follows is the same grammar as a state
// machine -- a state per byte class, one pass, no calls -- written from the
// specifications rather than from the code above. Two implementations that
// do not share a line are two chances to be right, and a disagreement about
// where a sequence ends is a bug in one of them.
//
// It frames only what `ESC` introduces. Everything else in the stream is a
// codepoint or a control code, neither of which can contain an `ESC`, so the
// two framers cannot disagree about where the next sequence begins without
// disagreeing about one of these.
//=========================================================================

/// One escape-introduced sequence: where it began and how long it was.
const Frame = struct { start: usize, len: usize };

/// Every sequence `decode` frames out of `bytes`, in order.
fn frameWithParser(bytes: []const u8, out: []Frame) []Frame {
    var console: win32.ConsoleState = .{};
    var frames: usize = 0;
    var i: usize = 0;
    while (i < bytes.len and frames < out.len) {
        const introduced = bytes[i] == seq.esc;
        const used = switch (decode(bytes[i..], false, &console)) {
            .ready => |done| done.len,
            .skip => |n| n,
            .incomplete => break,
        };
        if (introduced) {
            out[frames] = .{ .start = i, .len = used };
            frames += 1;
        }
        i += used;
    }
    return out[0..frames];
}

/// The same, by the state machine below.
fn frameWithGrammar(bytes: []const u8, out: []Frame) []Frame {
    var frames: usize = 0;
    var i: usize = 0;
    while (i < bytes.len and frames < out.len) {
        if (bytes[i] != seq.esc) {
            // Neither framer can look past a codepoint the bytes do not
            // hold the whole of: what follows it might complete it, so a
            // streaming framer waits there and frames nothing after it.
            if (bytes[i] >= 0x80) {
                if (std.unicode.utf8ByteSequenceLength(bytes[i])) |n| {
                    if (i + n > bytes.len) break;
                } else |_| {}
            }
            i += 1;
            continue;
        }
        const used = frameEscape(bytes[i..]) orelse break;
        out[frames] = .{ .start = i, .len = used };
        frames += 1;
        i += used;
    }
    return out[0..frames];
}

/// Where the sequence beginning at `bytes[0]`, which is an `ESC`, ends, or
/// null when the bytes do not hold the whole of it.
///
/// A length of one is a byte that introduces nothing: an `ESC` before a
/// second `ESC`, or one whose sequence has a byte in it the grammar does not
/// allow there. Either way one byte goes and the machine starts again.
fn frameEscape(bytes: []const u8) ?usize {
    std.debug.assert(bytes.len != 0 and bytes[0] == seq.esc);

    const State = enum {
        /// Just past the `ESC`, deciding what it introduces.
        introducer,
        /// Just past a `CSI`, where a private marker may stand.
        csi_marker,
        /// In a `CSI`'s parameter bytes.
        csi_parameter,
        /// In a `CSI`'s intermediate bytes, and then its final.
        csi_intermediate,
        /// Past the extra `[` of a Linux virtual-console function key.
        linux_console_final,
        /// In an `SS3`'s parameter bytes, and then its final.
        ss3,
        /// In a control string.
        string,
        /// In a control string, one byte past an `ESC`.
        string_escape,
        /// In the intermediate bytes of a short escape, and then its final.
        short_escape,
    };

    var state: State = .introducer;
    var marked = false;
    var parameterised = false;
    var intermediate = false;
    var i: usize = 1;

    while (i < bytes.len) {
        const b = bytes[i];
        switch (state) {
            .introducer => {
                // Two escapes running: the first is a key on its own.
                if (b == seq.esc) return 1;
                i += 1;
                if (b == '[') {
                    state = .csi_marker;
                } else if (b == 'O') {
                    state = .ss3;
                } else if (b == ']' or b == 'P' or b == 'X' or b == '^' or b == '_') {
                    state = .string;
                } else if (b >= 0x20 and b <= 0x2f) {
                    state = .short_escape;
                } else if (b < 0x80) {
                    // `ESC` and a key, which is how alt is spelled.
                    return 2;
                } else {
                    const n = std.unicode.utf8ByteSequenceLength(b) catch return 2;
                    if (1 + n > bytes.len) return null;
                    _ = std.unicode.utf8Decode(bytes[1..][0..n]) catch return 2;
                    return 1 + n;
                }
            },
            .csi_marker => {
                if (b == '[') {
                    i += 1;
                    state = .linux_console_final;
                    continue;
                }
                if (b >= '<' and b <= '?') {
                    marked = true;
                    i += 1;
                }
                state = .csi_parameter;
            },
            .csi_parameter => {
                if (b >= 0x30 and b <= 0x3f) {
                    parameterised = true;
                    i += 1;
                } else if (b == '$' and !marked and parameterised) {
                    return i + 1;
                } else {
                    state = .csi_intermediate;
                }
            },
            .csi_intermediate => {
                if (b >= 0x20 and b <= 0x2f) {
                    intermediate = true;
                    i += 1;
                    continue;
                }
                if (b < 0x40 or b > 0x7e) return 1;
                // `CSI M` with nothing in front of the `M` is the older
                // mouse report, whose three bytes are arbitrary and are part
                // of the sequence. Its length is the only one in the whole
                // grammar that the final byte does not give.
                if (b == 'M' and !marked and !parameterised and !intermediate) {
                    if (i + 1 + x10_mouse_fields > bytes.len) return null;
                    return i + 1 + x10_mouse_fields;
                }
                return i + 1;
            },
            .linux_console_final => {
                if (b < 0x40 or b > 0x7e) return 1;
                return i + 1;
            },
            .ss3 => {
                if (b >= 0x30 and b <= 0x3f) {
                    i += 1;
                    continue;
                }
                if (b < 0x40 or b > 0x7e) return 1;
                return i + 1;
            },
            .string => {
                if (b == seq.bel) return i + 1;
                i += 1;
                if (b == seq.esc) state = .string_escape;
            },
            .string_escape => {
                // `ST` closes the string; a bare `ESC` is the next sequence
                // beginning, and the string ends in front of it.
                if (b == '\\') return i + 1;
                return i - 1;
            },
            .short_escape => {
                if (b >= 0x20 and b <= 0x2f) {
                    i += 1;
                    continue;
                }
                if (b < 0x30 or b > 0x7e) return 1;
                return i + 1;
            },
        }
    }
    return null;
}

/// The pieces the differential generator builds a stream out of: complete
/// sequences, sequences cut off anywhere they can be cut off, and text.
///
/// Raw bytes find the shapes nobody thought of; these find the shapes
/// everybody did, which is where two framers actually differ.
const framing_pieces = [_][]const u8{
    "\x1b[A",
    "\x1b[[A",
    "\x1b[2$",
    "\x1b[5^",
    "\x1b[3@",
    "\x1b[a",
    "\x1bOa",
    "\x1b[1;5C",
    "\x1b[97:65:97;2:3;65u",
    "\x1b[<0;40;12M",
    "\x1b[M\x20\x21\x21",
    "\x1b[M",
    "\x1b[M\x1b",
    "\x1b[200~",
    "\x1b[?2026;1$y",
    "\x1b[0;0;0;1;0;1_",
    "\x1b[>c",
    "\x1b[?u",
    "\x1b[\x7f",
    "\x1b[1;2;3;4;5;6;7;8;9A",
    "\x1bOP",
    "\x1bO",
    "\x1bO\x01",
    "\x1b]52;c;aGk=\x1b\\",
    "\x1b]11;rgb:1c1c/1c1c/1c1c\x07",
    "\x1b]x",
    "\x1bP+q436f\x1b\\",
    "\x1b_Gi=31;OK\x1b\\",
    "\x1b(B",
    "\x1b(",
    "\x1b\x1b",
    "\x1b",
    "\x1b[",
    "\x1ba",
    "\x1b\xf0\x9f\x99\x82",
    "a",
    "hello",
    "\xc3\xa9",
    "\xf0\x9f\x99\x82",
    "\x7f",
    "\r",
};

test "the two framers agree on the sequences in a stream" {
    // A worked example before the fuzzer: every shape that has ever framed
    // differently, in one stream.
    const bytes = "\x1b[A" ++ "hi" ++ "\x1b[M\x20\x1b\x21" ++ "\x1bOP" ++
        "\x1b]52;c;aGk=\x1b\\" ++ "\x1b]x\x1b[B" ++ "\x1b\x1b[C" ++
        "\x1b(B" ++ "\x1b[\x7f" ++ "\x1b\xf0\x9f\x99\x82";

    var mine: [32]Frame = undefined;
    var theirs: [32]Frame = undefined;
    const parsed = frameWithParser(bytes, &mine);
    const grammar = frameWithGrammar(bytes, &theirs);

    try std.testing.expect(parsed.len >= 9);
    try std.testing.expectEqualSlices(Frame, grammar, parsed);

    // And the frames cover the escapes and nothing else: each one starts on
    // an `ESC` and none overlaps the next.
    var at: usize = 0;
    for (parsed) |frame| {
        try std.testing.expect(frame.start >= at);
        try std.testing.expect(frame.len != 0);
        try std.testing.expectEqual(@as(u8, seq.esc), bytes[frame.start]);
        at = frame.start + frame.len;
    }
}

test "rxvt finals do not change the framing of dollar intermediates" {
    const bytes = "\x1b[2$" ++ "\x1b[5^" ++ "\x1b[3@" ++
        "\x1b[a" ++ "\x1bOa" ++ "\x1b[?2026;1$y";
    try std.testing.expectEqual(@as(usize, 6), try checkFraming(bytes));
}

/// Builds one stream out of `chosen`: the high bit of each byte picks a raw
/// byte or a piece of grammar, and the rest picks which piece.
///
/// A stream that is neither only noise nor only well-formed, which is the
/// stream a terminal really sends.
fn buildStream(chosen: []const u8, out: []u8) []u8 {
    var len: usize = 0;
    for (chosen) |pick| {
        if (pick & 0x80 != 0) {
            if (len == out.len) break;
            out[len] = pick & 0x7f;
            len += 1;
            continue;
        }
        const piece = framing_pieces[pick % framing_pieces.len];
        if (len + piece.len > out.len) break;
        @memcpy(out[len..][0..piece.len], piece);
        len += piece.len;
    }
    return out[0..len];
}

/// Frames `bytes` both ways and fails if the two disagree, returning how
/// many sequences they agreed on.
fn checkFraming(bytes: []const u8) !usize {
    var mine: [512]Frame = undefined;
    var theirs: [512]Frame = undefined;
    const parsed = frameWithParser(bytes, &mine);
    const grammar = frameWithGrammar(bytes, &theirs);
    try std.testing.expectEqualSlices(Frame, grammar, parsed);
    return parsed.len;
}

test "the two framers agree over a sweep of generated streams" {
    // The fuzz target below searches; this one always runs, from a fixed
    // seed, so a disagreement fails the ordinary build rather than waiting
    // for somebody to start a fuzzer.
    var prng: std.Random.DefaultPrng = .init(0xf00dface);
    const rand = prng.random();

    var frames: usize = 0;
    for (0..20_000) |_| {
        var picks: [64]u8 = undefined;
        const n = rand.intRangeAtMost(usize, 0, picks.len);
        rand.bytes(picks[0..n]);

        var stream: [512]u8 = undefined;
        frames += try checkFraming(buildStream(picks[0..n], &stream));

        // And the same bytes as themselves, so the sweep covers the stream
        // nobody designed as well as the one somebody did.
        frames += try checkFraming(picks[0..n]);
    }
    // The generator really is producing sequences rather than noise.
    try std.testing.expect(frames > 100_000);
}

test "fuzz the framing against a second framer" {
    // The property: the recursive-descent parser and the state machine
    // written from the grammar frame the same stream into the same
    // sequences -- the same starts and the same lengths, in the same order.
    // A disagreement is a bug in one of them, and the test does not say
    // which, which is the point: neither is the oracle.
    try std.testing.fuzz({}, struct {
        fn one_(_: void, smith: *std.testing.Smith) anyerror!void {
            var picks: [128]u8 = undefined;
            const chosen = picks[0..smith.sliceWithHash(&picks, 0)];

            var input: [512]u8 = undefined;
            _ = try checkFraming(buildStream(chosen, &input));
            // And the bytes as they came, which the generator would never
            // have put together.
            _ = try checkFraming(chosen);
        }
    }.one_, .{ .corpus = &.{
        corpus.seed("\x00\x01\x02\x03\x04\x05\x06\x07"),
        corpus.seed("\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f"),
        corpus.seed("\x10\x11\x12\x13\x14\x15\x16\x17"),
        corpus.seed("\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f"),
        corpus.seed("\x20\x21\x22"),
        corpus.seed("\x04\x05\x06\xff\xfe\x1b\x1c"),
        corpus.seed("\x19\x1a\x19\x1a\x19\x1a"),
        corpus.seed("\x11\x91\x92\x11\x93"),
        corpus.seed("\x13\x14\x15\x16\x17\x18"),
    } });
}

test "an X10 mouse report is framed whole, not split into keypresses" {
    // The regression this framing exists for: without it the three biased
    // bytes are handed to the key decoder as space, A and A.
    const m = try oneMouse("\x1b[M\x20\x41\x41");
    try std.testing.expectEqual(@as(u32, 0x41 - 32), m.x);
}

test "an X10 mouse report does not swallow what follows it" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);
    var events = parser.feed("\x1b[M\x20\x41\x41hi");

    try std.testing.expectEqual(@as(u32, 0x41 - 32), events.next().?.mouse.y);
    try std.testing.expectEqualStrings("hi", events.next().?.text);
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
        try std.testing.expectEqual(@as(u32, 0x41 - 32), second.next().?.mouse.x);
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

test "a window report that is not the in-band resize is read as a size" {
    // Every other CSI t with a size is a reply to something the program
    // asked for, and comes out as that answer.
    try expectReply("\x1b[8;24;80t", .window_size);
    try expectReply("\x1b[6;16;8t", .window_size);
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

//=========================================================================
// Win32 input mode, DEC private mode 9001.
//=========================================================================

/// Every key win32 input mode names by its virtual key, with the sequence a
/// terminal writes for it and the key it stands for.
const win32_named = [_]struct { bytes: []const u8, vk: u16, key: Key }{
    .{ .bytes = "\x1b[8;0;0;1;0;1_", .vk = 8, .key = Key.backspace },
    .{ .bytes = "\x1b[9;0;0;1;0;1_", .vk = 9, .key = Key.tab },
    .{ .bytes = "\x1b[12;0;0;1;0;1_", .vk = 12, .key = Key.kp_begin },
    .{ .bytes = "\x1b[13;0;0;1;0;1_", .vk = 13, .key = Key.enter },
    .{ .bytes = "\x1b[16;0;0;1;0;1_", .vk = 16, .key = Key.left_shift },
    .{ .bytes = "\x1b[17;0;0;1;0;1_", .vk = 17, .key = Key.left_ctrl },
    .{ .bytes = "\x1b[18;0;0;1;0;1_", .vk = 18, .key = Key.left_alt },
    .{ .bytes = "\x1b[19;0;0;1;0;1_", .vk = 19, .key = Key.pause },
    .{ .bytes = "\x1b[20;0;0;1;0;1_", .vk = 20, .key = Key.caps_lock },
    .{ .bytes = "\x1b[27;0;0;1;0;1_", .vk = 27, .key = Key.escape },
    .{ .bytes = "\x1b[32;0;0;1;0;1_", .vk = 32, .key = Key{ .char = ' ' } },
    .{ .bytes = "\x1b[33;0;0;1;0;1_", .vk = 33, .key = Key.page_up },
    .{ .bytes = "\x1b[34;0;0;1;0;1_", .vk = 34, .key = Key.page_down },
    .{ .bytes = "\x1b[35;0;0;1;0;1_", .vk = 35, .key = Key.end },
    .{ .bytes = "\x1b[36;0;0;1;0;1_", .vk = 36, .key = Key.home },
    .{ .bytes = "\x1b[37;0;0;1;0;1_", .vk = 37, .key = Key.left },
    .{ .bytes = "\x1b[38;0;0;1;0;1_", .vk = 38, .key = Key.up },
    .{ .bytes = "\x1b[39;0;0;1;0;1_", .vk = 39, .key = Key.right },
    .{ .bytes = "\x1b[40;0;0;1;0;1_", .vk = 40, .key = Key.down },
    .{ .bytes = "\x1b[44;0;0;1;0;1_", .vk = 44, .key = Key.print_screen },
    .{ .bytes = "\x1b[45;0;0;1;0;1_", .vk = 45, .key = Key.insert },
    .{ .bytes = "\x1b[46;0;0;1;0;1_", .vk = 46, .key = Key.delete },
    .{ .bytes = "\x1b[91;0;0;1;0;1_", .vk = 91, .key = Key.left_super },
    .{ .bytes = "\x1b[92;0;0;1;0;1_", .vk = 92, .key = Key.right_super },
    .{ .bytes = "\x1b[93;0;0;1;0;1_", .vk = 93, .key = Key.menu },
    .{ .bytes = "\x1b[96;0;0;1;0;1_", .vk = 96, .key = Key.kp_0 },
    .{ .bytes = "\x1b[97;0;0;1;0;1_", .vk = 97, .key = Key.kp_1 },
    .{ .bytes = "\x1b[98;0;0;1;0;1_", .vk = 98, .key = Key.kp_2 },
    .{ .bytes = "\x1b[99;0;0;1;0;1_", .vk = 99, .key = Key.kp_3 },
    .{ .bytes = "\x1b[100;0;0;1;0;1_", .vk = 100, .key = Key.kp_4 },
    .{ .bytes = "\x1b[101;0;0;1;0;1_", .vk = 101, .key = Key.kp_5 },
    .{ .bytes = "\x1b[102;0;0;1;0;1_", .vk = 102, .key = Key.kp_6 },
    .{ .bytes = "\x1b[103;0;0;1;0;1_", .vk = 103, .key = Key.kp_7 },
    .{ .bytes = "\x1b[104;0;0;1;0;1_", .vk = 104, .key = Key.kp_8 },
    .{ .bytes = "\x1b[105;0;0;1;0;1_", .vk = 105, .key = Key.kp_9 },
    .{ .bytes = "\x1b[106;0;0;1;0;1_", .vk = 106, .key = Key.kp_multiply },
    .{ .bytes = "\x1b[107;0;0;1;0;1_", .vk = 107, .key = Key.kp_add },
    .{ .bytes = "\x1b[108;0;0;1;0;1_", .vk = 108, .key = Key.kp_separator },
    .{ .bytes = "\x1b[109;0;0;1;0;1_", .vk = 109, .key = Key.kp_subtract },
    .{ .bytes = "\x1b[110;0;0;1;0;1_", .vk = 110, .key = Key.kp_decimal },
    .{ .bytes = "\x1b[111;0;0;1;0;1_", .vk = 111, .key = Key.kp_divide },
    .{ .bytes = "\x1b[112;0;0;1;0;1_", .vk = 112, .key = Key{ .f = 1 } },
    .{ .bytes = "\x1b[113;0;0;1;0;1_", .vk = 113, .key = Key{ .f = 2 } },
    .{ .bytes = "\x1b[114;0;0;1;0;1_", .vk = 114, .key = Key{ .f = 3 } },
    .{ .bytes = "\x1b[115;0;0;1;0;1_", .vk = 115, .key = Key{ .f = 4 } },
    .{ .bytes = "\x1b[116;0;0;1;0;1_", .vk = 116, .key = Key{ .f = 5 } },
    .{ .bytes = "\x1b[117;0;0;1;0;1_", .vk = 117, .key = Key{ .f = 6 } },
    .{ .bytes = "\x1b[118;0;0;1;0;1_", .vk = 118, .key = Key{ .f = 7 } },
    .{ .bytes = "\x1b[119;0;0;1;0;1_", .vk = 119, .key = Key{ .f = 8 } },
    .{ .bytes = "\x1b[120;0;0;1;0;1_", .vk = 120, .key = Key{ .f = 9 } },
    .{ .bytes = "\x1b[121;0;0;1;0;1_", .vk = 121, .key = Key{ .f = 10 } },
    .{ .bytes = "\x1b[122;0;0;1;0;1_", .vk = 122, .key = Key{ .f = 11 } },
    .{ .bytes = "\x1b[123;0;0;1;0;1_", .vk = 123, .key = Key{ .f = 12 } },
    .{ .bytes = "\x1b[124;0;0;1;0;1_", .vk = 124, .key = Key{ .f = 13 } },
    .{ .bytes = "\x1b[125;0;0;1;0;1_", .vk = 125, .key = Key{ .f = 14 } },
    .{ .bytes = "\x1b[126;0;0;1;0;1_", .vk = 126, .key = Key{ .f = 15 } },
    .{ .bytes = "\x1b[127;0;0;1;0;1_", .vk = 127, .key = Key{ .f = 16 } },
    .{ .bytes = "\x1b[128;0;0;1;0;1_", .vk = 128, .key = Key{ .f = 17 } },
    .{ .bytes = "\x1b[129;0;0;1;0;1_", .vk = 129, .key = Key{ .f = 18 } },
    .{ .bytes = "\x1b[130;0;0;1;0;1_", .vk = 130, .key = Key{ .f = 19 } },
    .{ .bytes = "\x1b[131;0;0;1;0;1_", .vk = 131, .key = Key{ .f = 20 } },
    .{ .bytes = "\x1b[132;0;0;1;0;1_", .vk = 132, .key = Key{ .f = 21 } },
    .{ .bytes = "\x1b[133;0;0;1;0;1_", .vk = 133, .key = Key{ .f = 22 } },
    .{ .bytes = "\x1b[134;0;0;1;0;1_", .vk = 134, .key = Key{ .f = 23 } },
    .{ .bytes = "\x1b[135;0;0;1;0;1_", .vk = 135, .key = Key{ .f = 24 } },
    .{ .bytes = "\x1b[144;0;0;1;0;1_", .vk = 144, .key = Key.num_lock },
    .{ .bytes = "\x1b[145;0;0;1;0;1_", .vk = 145, .key = Key.scroll_lock },
    .{ .bytes = "\x1b[160;0;0;1;0;1_", .vk = 160, .key = Key.left_shift },
    .{ .bytes = "\x1b[161;0;0;1;0;1_", .vk = 161, .key = Key.right_shift },
    .{ .bytes = "\x1b[162;0;0;1;0;1_", .vk = 162, .key = Key.left_ctrl },
    .{ .bytes = "\x1b[163;0;0;1;0;1_", .vk = 163, .key = Key.right_ctrl },
    .{ .bytes = "\x1b[164;0;0;1;0;1_", .vk = 164, .key = Key.left_alt },
    .{ .bytes = "\x1b[165;0;0;1;0;1_", .vk = 165, .key = Key.right_alt },
    .{ .bytes = "\x1b[173;0;0;1;0;1_", .vk = 173, .key = Key.mute_volume },
    .{ .bytes = "\x1b[174;0;0;1;0;1_", .vk = 174, .key = Key.lower_volume },
    .{ .bytes = "\x1b[175;0;0;1;0;1_", .vk = 175, .key = Key.raise_volume },
    .{ .bytes = "\x1b[176;0;0;1;0;1_", .vk = 176, .key = Key.media_track_next },
    .{ .bytes = "\x1b[177;0;0;1;0;1_", .vk = 177, .key = Key.media_track_previous },
    .{ .bytes = "\x1b[178;0;0;1;0;1_", .vk = 178, .key = Key.media_stop },
    .{ .bytes = "\x1b[179;0;0;1;0;1_", .vk = 179, .key = Key.media_play_pause },
};

test "win32 input mode names every key its virtual keys can name" {
    for (win32_named) |case| {
        const ev = oneKey(case.bytes) orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(case.key, ev.key);
        try std.testing.expectEqual(Modifiers{}, ev.mods);
        try std.testing.expectEqual(Kind.press, ev.kind);
        try std.testing.expectEqualStrings("", ev.text());
    }
}

test "win32 input mode carries every modifier combination the encoding has" {
    // The three modifiers a `dwControlKeyState` can hold, and the eight
    // combinations of them. There is no bit for super, hyper or meta: the
    // Windows key reaches a console as a key, never as a state.
    const shift = 0x0010;
    const alt = 0x0002;
    const ctrl = 0x0008;

    var buffer: [64]u8 = undefined;
    for (win32_named) |case| {
        for (0..8) |combination| {
            var state: u32 = 0;
            if (combination & 1 != 0) state |= shift;
            if (combination & 2 != 0) state |= alt;
            if (combination & 4 != 0) state |= ctrl;

            // A keypad digit with Alt and nothing else is a digit of an
            // Alt composition, and is held back rather than reported; see
            // `win32.ConsoleState`.
            const composing = state == alt and case.vk >= 0x60 and case.vk <= 0x69;
            if (composing) continue;

            const bytes = try std.fmt.bufPrint(
                &buffer,
                "\x1b[{d};0;0;1;{d};1_",
                .{ case.vk, state },
            );
            const ev = oneKey(bytes) orelse return error.TestExpectedEqual;
            try std.testing.expectEqual(case.key, ev.key);
            try std.testing.expectEqual(combination & 1 != 0, ev.mods.shift);
            try std.testing.expectEqual(combination & 2 != 0, ev.mods.alt);
            try std.testing.expectEqual(combination & 4 != 0, ev.mods.ctrl);
            try std.testing.expect(!ev.mods.super and !ev.mods.hyper and !ev.mods.meta);
        }
    }
}

test "win32 input mode reads the right alt and right control bits too" {
    // AltGr is the one that matters: a console reports it as right alt and
    // left control at once.
    const altgr = oneKey("\x1b[65;0;0;1;9;1_").?;
    try std.testing.expect(altgr.mods.alt and altgr.mods.ctrl);

    const right_ctrl = oneKey("\x1b[37;0;0;1;4;1_").?;
    try std.testing.expect(right_ctrl.mods.ctrl and !right_ctrl.mods.alt);

    const right_alt = oneKey("\x1b[37;0;0;1;1;1_").?;
    try std.testing.expect(right_alt.mods.alt and !right_alt.mods.ctrl);
}

test "win32 input mode reports the lock states as lock states" {
    const caps = oneKey("\x1b[37;0;0;1;128;1_").?;
    try std.testing.expect(caps.mods.caps_lock and !caps.mods.shift);

    const num = oneKey("\x1b[37;0;0;1;32;1_").?;
    try std.testing.expect(num.mods.num_lock);

    // Scroll lock has a bit in the state and no field in `Modifiers`, so it
    // is read and dropped rather than turned into something else.
    const scroll = oneKey("\x1b[37;0;0;1;64;1_").?;
    try std.testing.expectEqual(Modifiers{}, scroll.mods);
}

test "win32 input mode takes the character when the key produced one" {
    const lower = oneKey("\x1b[65;30;97;1;0;1_").?;
    try std.testing.expectEqual(Key{ .char = 'a' }, lower.key);
    try std.testing.expectEqualStrings("a", lower.text());

    // Shift has already been applied to the character, as it has in a byte
    // stream, so the key is the capital and the text is too.
    const upper = oneKey("\x1b[65;30;65;1;16;1_").?;
    try std.testing.expectEqual(Key{ .char = 'A' }, upper.key);
    try std.testing.expect(upper.mods.shift);
    try std.testing.expectEqualStrings("A", upper.text());

    // A character outside ASCII arrives as its code unit and comes out as
    // UTF-8, which is what every other path here produces.
    const pound = oneKey("\x1b[0;0;163;1;0;1_").?;
    try std.testing.expectEqual(Key{ .char = 0xa3 }, pound.key);
    try std.testing.expectEqualStrings("\u{a3}", pound.text());
}

test "win32 input mode folds a control code back into the key that made it" {
    // Control and A is the letter with `Modifiers.ctrl`, which is what the
    // legacy path and the kitty path both report.
    const ctrl_a = oneKey("\x1b[65;30;1;1;8;1_").?;
    try std.testing.expectEqual(Key{ .char = 'a' }, ctrl_a.key);
    try std.testing.expect(ctrl_a.mods.ctrl);
    try std.testing.expectEqualStrings("", ctrl_a.text());

    // Backspace sends a control code as its character, and is still the key.
    const back = oneKey("\x1b[8;14;8;1;0;1_").?;
    try std.testing.expectEqual(Key.backspace, back.key);
    try std.testing.expect(!back.mods.ctrl);

    // Control and backspace sends DEL, and is still backspace.
    const ctrl_back = oneKey("\x1b[8;14;127;1;8;1_").?;
    try std.testing.expectEqual(Key.backspace, ctrl_back.key);
    try std.testing.expect(ctrl_back.mods.ctrl);

    // Enter, escape and tab agree with themselves whichever field names them.
    try std.testing.expectEqual(Key.enter, oneKey("\x1b[13;28;13;1;0;1_").?.key);
    try std.testing.expectEqual(Key.escape, oneKey("\x1b[27;1;27;1;0;1_").?.key);
    try std.testing.expectEqual(Key.tab, oneKey("\x1b[9;15;9;1;0;1_").?.key);

    // A key with no name whose character is a control code is read as that
    // control code, exactly as the byte would be.
    const ctrl_bracket = oneKey("\x1b[219;26;27;1;8;1_").?;
    try std.testing.expectEqual(Key.escape, ctrl_bracket.key);
}

test "win32 input mode uses the documented default for every missing field" {
    // Vk alone: everything else defaults, and `Kd` defaults to a key coming
    // up, which is dropped unless the caller asked for it.
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var quiet: KeyParser = .init(&storage);
    var none = quiet.feed("\x1b[37_");
    try std.testing.expectEqual(@as(?Event, null), none.next());

    var loud: KeyParser = .init(&storage);
    loud.report_key_up = true;
    var events = loud.feed("\x1b[37_");
    const ev = events.next().?.key;
    try std.testing.expectEqual(Key.left, ev.key);
    try std.testing.expectEqual(Kind.release, ev.kind);
    try std.testing.expectEqual(Modifiers{}, ev.mods);

    // Empty fields are the same as absent ones.
    const typed = oneKey("\x1b[;;97;1_").?;
    try std.testing.expectEqual(Key{ .char = 'a' }, typed.key);
    try std.testing.expectEqual(Kind.press, typed.kind);
}

test "win32 input mode drops the key coming up unless it is asked for" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var quiet: KeyParser = .init(&storage);

    // A whole keystroke: down then up. Only the down is reported, and the key
    // after it still arrives.
    var events = quiet.feed("\x1b[65;30;97;1;0;1_\x1b[65;30;97;0;0;1_b");
    try std.testing.expectEqual(Key{ .char = 'a' }, events.next().?.key.key);
    try std.testing.expectEqual(Key{ .char = 'b' }, events.next().?.key.key);
    try std.testing.expectEqual(@as(?Event, null), events.next());

    var loud: KeyParser = .init(&storage);
    loud.report_key_up = true;
    var both = loud.feed("\x1b[65;30;97;1;0;1_\x1b[65;30;97;0;0;1_");
    try std.testing.expectEqual(Kind.press, both.next().?.key.kind);
    try std.testing.expectEqual(Kind.release, both.next().?.key.kind);
    try std.testing.expectEqual(@as(?Event, null), both.next());
}

test "win32 input mode expands a repeat count into that many keys" {
    var buffer: [8]Event = undefined;
    const events = collect("\x1b[65;30;97;1;0;3_", &buffer);
    try std.testing.expectEqual(@as(usize, 3), events.len);

    // The first is the press and the rest are repeats, which is what the
    // kitty protocol calls the same thing.
    try std.testing.expectEqual(Kind.press, events[0].key.kind);
    try std.testing.expectEqual(Kind.repeat, events[1].key.kind);
    try std.testing.expectEqual(Kind.repeat, events[2].key.kind);
    for (events) |event| {
        try std.testing.expectEqual(Key{ .char = 'a' }, event.key.key);
        try std.testing.expectEqualStrings("a", event.key.text());
    }

    // A count of one, and an absent count, are one key.
    try std.testing.expectEqual(@as(usize, 1), collect("\x1b[65;30;97;1;0;1_", &buffer).len);
    try std.testing.expectEqual(@as(usize, 1), collect("\x1b[65;30;97;1;0_", &buffer).len);
    try std.testing.expectEqual(@as(usize, 1), collect("\x1b[65;30;97;1;0;0_", &buffer).len);
}

test "a repeated key and the key after it arrive in the order they were typed" {
    var buffer: [8]Event = undefined;
    const events = collect("\x1b[65;30;97;1;0;2_b", &buffer);
    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqual(Key{ .char = 'a' }, events[0].key.key);
    try std.testing.expectEqual(Key{ .char = 'a' }, events[1].key.key);
    try std.testing.expectEqual(Key{ .char = 'b' }, events[2].key.key);
}

test "reset throws away the repeats a win32 sequence still owed" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);

    var events = parser.feed("\x1b[65;30;97;1;0;9_");
    try std.testing.expectEqual(Key{ .char = 'a' }, events.next().?.key.key);
    parser.reset();

    var after = parser.feed("b");
    try std.testing.expectEqual(Key{ .char = 'b' }, after.next().?.key.key);
    try std.testing.expectEqual(@as(?Event, null), after.next());
}

test "a win32 sequence split across feeds is one key when it is whole" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);

    const whole = "\x1b[65;30;97;1;0;1_";
    for (whole[0 .. whole.len - 1]) |byte| {
        var partial = parser.feed(&[_]u8{byte});
        try std.testing.expectEqual(@as(?Event, null), partial.next());
    }
    var events = parser.feed(whole[whole.len - 1 ..]);
    try std.testing.expectEqual(Key{ .char = 'a' }, events.next().?.key.key);
    try std.testing.expectEqual(@as(?Event, null), events.next());
}

test "a win32 sequence this parser cannot read comes back whole" {
    const rejected = [_][]const u8{
        "\x1b[_", // every field defaulted, which names no key
        "\x1b[0;0;0;1;0;1_", // the same, spelled out
        "\x1b[65536;0;0;1;0;1_", // a virtual key too large for its field
        "\x1b[0;65536;0;1;0;1_", // a scan code too large for its field
        "\x1b[0;0;65536;1;0;1_", // a character too large for its field
        "\x1b[65;0;97;1;0;65536_", // a repeat count too large for its field
        "\x1b[65;0;97;1;0;1;1_", // a field too many
    };
    for (rejected) |bytes| try expectUnhandled(bytes);
}

test "win32 input mode pairs the halves of a character outside the basic plane" {
    // A console sends an astral character as two records, each carrying half
    // a UTF-16 surrogate pair. Neither half is a codepoint; together they
    // are one key.
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);

    var first = parser.feed("\x1b[0;0;55357;1;0;1_");
    try std.testing.expectEqual(@as(?Event, null), first.next());

    var second = parser.feed("\x1b[0;0;56898;1;0;1_");
    const ev = second.next().?.key;
    try std.testing.expectEqual(Key{ .char = 0x1f642 }, ev.key);
    try std.testing.expectEqualStrings("\u{1f642}", ev.text());
    try std.testing.expectEqual(@as(?Event, null), second.next());
}

test "win32 input mode drops a surrogate half that never found its other" {
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);

    // A high half, then an ordinary key: the half goes, the key arrives.
    var events = parser.feed("\x1b[0;0;55357;1;0;1_\x1b[65;0;97;1;0;1_");
    try std.testing.expectEqual(Key{ .char = 'a' }, events.next().?.key.key);
    try std.testing.expectEqual(@as(?Event, null), events.next());

    // A low half with nothing in front of it is not a key either.
    var alone = parser.feed("\x1b[0;0;56898;1;0;1_\x1b[65;0;97;1;0;1_");
    try std.testing.expectEqual(Key{ .char = 'a' }, alone.next().?.key.key);
    try std.testing.expectEqual(@as(?Event, null), alone.next());
}

test "win32 input mode reads the character composed with Alt and the keypad" {
    // The keypad digits carry nothing and are held; the character arrives on
    // the Alt key coming up, and is a press, because what happened is that
    // the user typed a character.
    var storage: [KeyParser.min_buffer]u8 = undefined;
    var parser: KeyParser = .init(&storage);

    const alt = 0x0002;
    var buffer: [128]u8 = undefined;
    const digits = try std.fmt.bufPrint(
        &buffer,
        "\x1b[18;0;0;1;{d};1_\x1b[97;0;0;1;{d};1_\x1b[103;0;0;1;{d};1_",
        .{ alt, alt, alt },
    );
    var held = parser.feed(digits);
    // The Alt key going down is a keypress like any other; the two keypad
    // digits after it are not.
    try std.testing.expectEqual(Key.left_alt, held.next().?.key.key);
    try std.testing.expectEqual(@as(?Event, null), held.next());

    // `VK_MENU` coming up, carrying the composed character.
    var composed = parser.feed("\x1b[18;0;233;0;0;1_");
    const ev = composed.next().?.key;
    try std.testing.expectEqual(Key{ .char = 0xe9 }, ev.key);
    try std.testing.expectEqual(Kind.press, ev.kind);
    try std.testing.expectEqualStrings("\u{e9}", ev.text());
    try std.testing.expect(!ev.mods.alt);
    try std.testing.expectEqual(@as(?Event, null), composed.next());
}

test "win32 input mode reads AltGr as the character, not as control and alt" {
    // AltGr sets the right-Alt bit and a control bit together, which is what
    // control and alt look like. The character is what tells them apart: a
    // chord produces none, a layout's third level does.
    const right_alt = 0x0001;
    const left_ctrl = 0x0008;

    var buffer: [64]u8 = undefined;
    const altgr = try std.fmt.bufPrint(
        &buffer,
        "\x1b[81;0;64;1;{d};1_",
        .{right_alt | left_ctrl},
    );
    const ev = oneKey(altgr).?;
    try std.testing.expectEqual(Key{ .char = '@' }, ev.key);
    try std.testing.expect(!ev.mods.alt and !ev.mods.ctrl);
    try std.testing.expectEqualStrings("@", ev.text());

    // The same bits with no character are still control and alt.
    const chord = try std.fmt.bufPrint(
        &buffer,
        "\x1b[112;0;0;1;{d};1_",
        .{right_alt | left_ctrl},
    );
    const held = oneKey(chord).?;
    try std.testing.expectEqual(Key{ .f = 1 }, held.key);
    try std.testing.expect(held.mods.alt and held.mods.ctrl);

    // And left alt with control is control and alt however it is spelled.
    const left_alt = 0x0002;
    const both = try std.fmt.bufPrint(
        &buffer,
        "\x1b[81;0;64;1;{d};1_",
        .{left_alt | left_ctrl},
    );
    const plain = oneKey(both).?;
    try std.testing.expect(plain.mods.alt and plain.mods.ctrl);
}

test "a win32 sequence and a console record decode to the same key" {
    // The two shapes share one virtual-key table, and this is what says so:
    // the same fields, read from a sequence and from a record, are one key.
    var buffer: [64]u8 = undefined;
    for (win32_named) |case| {
        for ([_]u32{ 0, 0x10, 0x08, 0x02, 0x1a, 0x80 }) |state| {
            // A keypad digit with Alt alone held is a digit of a
            // composition in both shapes, and neither reports it.
            if (state == 0x02 and case.vk >= 0x60 and case.vk <= 0x69) continue;

            const bytes = try std.fmt.bufPrint(
                &buffer,
                "\x1b[{d};0;0;1;{d};1_",
                .{ case.vk, state },
            );
            const from_bytes = oneKey(bytes) orelse return error.TestExpectedEqual;
            var records: win32.ConsoleDecoder = .{};
            const from_record = records.next(.{ .key = .{
                .key_down = true,
                .virtual_key_code = case.vk,
                .control_key_state = state,
            } }) orelse records.flush() orelse return error.TestExpectedEqual;
            try std.testing.expectEqual(from_bytes, from_record.key);
        }
    }

    // And with a character in the field, where the layout has already been
    // applied and the text comes with it.
    const typed = oneKey("\x1b[65;30;97;1;0;1_").?;
    var typed_records: win32.ConsoleDecoder = .{};
    const recorded = typed_records.next(.{ .key = .{
        .key_down = true,
        .virtual_key_code = 'A',
        .virtual_scan_code = 30,
        .unicode_char = 'a',
    } }).?;
    try std.testing.expectEqual(typed, recorded.key);
}

test "fuzz the win32 input mode decoder" {
    // The property: arbitrary bytes shaped like this sequence never panic,
    // never read past the end, and never produce a key whose text is not
    // valid UTF-8 -- with the key-up half both dropped and reported, because
    // that flag is the one thing that changes which events come out.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [128]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];

            for ([_]bool{ false, true }) |key_up| {
                var storage: [KeyParser.min_buffer]u8 = undefined;
                var parser: KeyParser = .init(&storage);
                parser.report_key_up = key_up;

                var events = parser.feed(bytes);
                var seen: usize = 0;
                while (events.next()) |event| {
                    seen += 1;
                    // A repeat count is bounded by the field it came from, so
                    // one sequence cannot spin forever.
                    if (seen > 1024 * 1024) return error.TestUnexpectedResult;
                    switch (event) {
                        .key => |ev| {
                            try std.testing.expect(std.unicode.utf8ValidateSlice(ev.text()));
                            if (!key_up) try std.testing.expect(ev.kind != .release);
                        },
                        .unhandled => |slice| {
                            try std.testing.expect(slice.len <= storage.len);
                        },
                        else => {},
                    }
                }
                _ = parser.flush();
                try std.testing.expectEqual(@as(usize, 0), parser.pending().len);
            }
        }
    }.one, .{ .corpus = &.{
        corpus.seed("\x1b[65;30;97;1;0;1_"),
        corpus.seed("\x1b[65;30;97;0;0;1_"),
        corpus.seed("\x1b[65;30;97;1;0;3_"),
        corpus.seed("\x1b[37;0;0;1;16;1_"),
        corpus.seed("\x1b[112;0;0;1;8;1_"),
        corpus.seed("\x1b[;;;;;_"),
        corpus.seed("\x1b[_"),
        corpus.seed("\x1b[0;0;55357;1;0;1_"),
        corpus.seed("\x1b[65536;0;0;1;0;1_"),
        corpus.seed("\x1b[65;0;97;1;0;65535_"),
        corpus.seed("\x1b[65;0;97;1;0;1;1_"),
        corpus.seed("\x1b[65;30;97;1;0;2_b"),
    } });
}

test "a colour scheme report decodes to the scheme it names" {
    try std.testing.expectEqual(ColorScheme.dark, one("\x1b[?997;1n").?.color_scheme);
    try std.testing.expectEqual(ColorScheme.light, one("\x1b[?997;2n").?.color_scheme);
}

test "a colour scheme report arrives in among the keys" {
    var storage: [8]Event = undefined;
    const events = collect("a\x1b[?997;2nb", &storage);
    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqual(Key{ .char = 'a' }, events[0].key.key);
    try std.testing.expectEqual(ColorScheme.light, events[1].color_scheme);
    try std.testing.expectEqual(Key{ .char = 'b' }, events[2].key.key);
}

test "a private report that is not the colour scheme is handed back whole" {
    const rejected = [_][]const u8{
        "\x1b[?997;0n", // no such scheme
        "\x1b[?997;3n", // no such scheme
        "\x1b[?997n", // no scheme
        "\x1b[?997;1;1n", // a field too many
        "\x1b[?996;1n", // a different report
        "\x1b[?6n", // the DECXCPR request
        "\x1b[?997:1;1n", // sub-parameters, which this report has none of
    };
    for (rejected) |bytes| {
        // Checked while the parser still holds it: an unhandled event
        // borrows from the parser's buffer.
        var storage: [KeyParser.min_buffer]u8 = undefined;
        var parser: KeyParser = .init(&storage);
        var events = parser.feed(bytes);
        const event = events.next().?;
        try std.testing.expectEqualStrings(bytes, event.unhandled);
        try std.testing.expect(events.next() == null);
    }
}

test "the plain colour scheme parser and the event agree" {
    for ([_][]const u8{ "\x1b[?997;1n", "\x1b[?997;2n" }) |bytes| {
        try std.testing.expectEqual(
            query.parseColorSchemeReply(bytes).?,
            one(bytes).?.color_scheme,
        );
    }
}
