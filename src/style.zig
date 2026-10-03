//! Character attributes and colour: SGR, `CSI ... m`.
//!
//! Every other sequence in this package means the same thing whenever it is
//! written. SGR does not. It is the one place morse writes bytes whose effect
//! depends on what came before, because `CSI 1 m` turns bold on and leaves
//! every other attribute exactly as it was. A terminal has one current style
//! and SGR edits it; there is no sequence that says "this style and nothing
//! else" short of resetting first, which costs a parameter and a repaint of
//! attributes that were already right.
//!
//! `diffStyle` is why this file exists. It takes the style the terminal is
//! already in and the one it should be in, and writes the shortest sequence
//! that gets from one to the other — nothing at all when they are equal,
//! which is the common case when drawing a run of cells. `setStyle` is the
//! same call from a terminal known to be at its default, and `resetStyle` is
//! what puts it back there.
//!
//! morse holds no state, so `from` is the caller's to remember: it is the
//! style of whatever it wrote last, and getting it wrong shows on screen.
//!
//! What this file will never hold: a colour downgraded to fit a terminal.
//! Mapping a direct colour onto the palette, or the palette onto eight
//! colours, is a decision about how a program should look on a terminal it
//! has guessed the abilities of, and morse guesses nothing. Write the colour;
//! `queryCapability` with `Co` asks how many the terminal has.

const std = @import("std");
const seq = @import("seq.zig");

const Writer = std.Io.Writer;

/// The sixteen palette entries, numbered as SGR numbers them.
///
/// These name slots, not colours. The user's terminal theme decides what each
/// slot looks like, so `.red` is whatever this terminal calls red — which on
/// a good many themes is not red. That is the point of using them: a program
/// drawn in these colours belongs in the terminal it is running in. A program
/// that needs one particular colour wants `Color.rgb` instead.
pub const Ansi = enum(u8) {
    /// Palette entry 0. Usually the darkest colour a theme defines, and
    /// rarely pure black.
    black = 0,
    /// Palette entry 1.
    red = 1,
    /// Palette entry 2.
    green = 2,
    /// Palette entry 3.
    yellow = 3,
    /// Palette entry 4.
    blue = 4,
    /// Palette entry 5.
    magenta = 5,
    /// Palette entry 6.
    cyan = 6,
    /// Palette entry 7. Usually the theme's ordinary text colour, and rarely
    /// pure white.
    white = 7,
    /// Palette entry 8. The high-intensity half of the palette, which
    /// hardware with only eight colours reached by setting bold on `black`
    /// and which SGR now gives codes of its own — `90`, not `1;30`, so
    /// asking for this colour does not also ask for a bold font.
    bright_black = 8,
    /// Palette entry 9.
    bright_red = 9,
    /// Palette entry 10.
    bright_green = 10,
    /// Palette entry 11.
    bright_yellow = 11,
    /// Palette entry 12.
    bright_blue = 12,
    /// Palette entry 13.
    bright_magenta = 13,
    /// Palette entry 14.
    bright_cyan = 14,
    /// Palette entry 15.
    bright_white = 15,
};

/// A colour given directly, eight bits a channel, in the order SGR writes
/// them.
pub const Rgb = extern struct {
    /// Red, 0 to 255.
    r: u8,
    /// Green, 0 to 255.
    g: u8,
    /// Blue, 0 to 255.
    b: u8,
};

/// A colour, in the forms SGR can spell.
///
/// `.ansi` and a `.palette` index below 16 name the same sixteen slots and
/// write different bytes. `.ansi` writes the short codes, which predate the
/// 256-colour palette and which every terminal understands; `.palette` writes
/// `38;5;n`, which a terminal without 256-colour support drops on the floor.
/// For those sixteen, `.ansi` is the form to send.
///
/// An `extern struct` with a tag and three channel bytes, rather than the
/// tagged union the shape asks for, because `Style` holds three of these and
/// a renderer holds a `Style` inside its cell. Zig gives an auto-layout union
/// no guaranteed representation and will not put one in an `extern struct`,
/// so a union here would stop a cell being `extern` and stop a row of cells
/// being compared with `memcmp` -- which is the comparison a renderer makes
/// most. Four bytes and no padding, the same size the union was.
///
/// Write one with `Color.default`, `Color.ansi`, `Color.palette` or
/// `Color.rgb`, which in a typed position spell themselves `.default`,
/// `.ansi(.red)`, `.palette(196)` and `.rgb(255, 128, 0)`. Read one by
/// switching on `kind` and taking `index`, `toAnsi` or `toRgb`.
///
/// Every one of those zeroes the channels its kind does not use, so a colour
/// has one spelling and `eql` and a byte comparison give the same answer --
/// which is the point of the layout: a renderer comparing rows of cells with
/// `memcmp` and a renderer comparing styles field by field must not disagree
/// about which cells changed. They run at comptime, so a table of colours is
/// written with them like anything else. The fields are the storage; a value
/// built out of them by hand is the caller's to keep canonical.
pub const Color = extern struct {
    /// Which of the four forms a colour is in.
    pub const Kind = enum(u8) {
        /// The terminal's own colour for whichever side this is used on:
        /// foreground, background, or underline.
        default = 0,
        /// One of the sixteen theme colours, written with its own short
        /// code. `r` holds the `Ansi` slot.
        ansi = 1,
        /// An entry in the 256-colour palette: the sixteen theme colours at
        /// 0-15, a 6x6x6 colour cube at 16-231, and 24 greys at 232-255.
        /// Written `38;5;n`; `r` holds the index.
        palette = 2,
        /// A colour the terminal does not get to reinterpret, written
        /// `38;2;r;g;b`. A terminal without direct colour support
        /// approximates it from its palette, so this is never wrong to send,
        /// only sometimes rounded.
        rgb = 3,
    };

    /// Which form this is.
    kind: Kind = .default,
    /// Red for `.rgb`; the slot or index for `.ansi` and `.palette`; zero
    /// for `.default`.
    r: u8 = 0,
    /// Green for `.rgb`, zero otherwise.
    g: u8 = 0,
    /// Blue for `.rgb`, zero otherwise.
    b: u8 = 0,

    /// The terminal's own colour. All three of `Style{}`'s colours are this.
    pub const default: Color = .{};

    /// One of the sixteen theme colours.
    pub fn ansi(which: Ansi) Color {
        return .{ .kind = .ansi, .r = @intFromEnum(which) };
    }

    /// One entry of the 256-colour palette.
    pub fn palette(entry: u8) Color {
        return .{ .kind = .palette, .r = entry };
    }

    /// A colour given directly, three channels.
    pub fn rgb(red: u8, green: u8, blue: u8) Color {
        return .{ .kind = .rgb, .r = red, .g = green, .b = blue };
    }

    /// The same, from an `Rgb` -- which is what `Rgb16.to8` gives back, so
    /// this is how a colour the terminal reported becomes one to draw with.
    pub fn fromRgb(color: Rgb) Color {
        return .{ .kind = .rgb, .r = color.r, .g = color.g, .b = color.b };
    }

    /// The slot or index of an `.ansi` or `.palette` colour, and zero for
    /// the other two.
    pub fn index(color: Color) u8 {
        return color.r;
    }

    /// The theme slot of an `.ansi` colour. Meaningful only when `kind` is
    /// `.ansi`.
    pub fn toAnsi(color: Color) Ansi {
        return @enumFromInt(color.r);
    }

    /// The three channels of an `.rgb` colour. Meaningful only when `kind`
    /// is `.rgb`.
    pub fn toRgb(color: Color) Rgb {
        return .{ .r = color.r, .g = color.g, .b = color.b };
    }

    /// Whether two colours are the same colour.
    ///
    /// The four bytes, compared as four bytes. Every constructor zeroes the
    /// channels its kind does not use, so this is exactly the comparison a
    /// renderer makes over a row of cells with `memcmp`: one relation, not
    /// two that can disagree on the very type whose layout exists for the
    /// byte one.
    pub fn eql(a: Color, b: Color) bool {
        return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
    }
};

/// Whether a cell's glyphs are raised, lowered, or neither: SGR 73, 74 and
/// 75.
///
/// One field rather than two flags, because the codes are mutually
/// exclusive: 74 replaces 73 rather than joining it, and 75 turns off
/// whichever is on. Terminals that implement the text sizing protocol draw
/// these; the rest ignore all three codes and draw the glyphs at their usual
/// height, which is the right failure.
pub const Script = enum(u8) {
    /// On the baseline, at the usual size.
    none = 0,
    /// Raised and smaller, SGR 73.
    superscript = 73,
    /// Lowered and smaller, SGR 74.
    subscript = 74,
};

/// Which underline a cell carries, numbered as the SGR 4 sub-parameter
/// numbers them.
///
/// Everything but `.none` and `.single` needs a terminal that implements the
/// sub-parameter form; the rest draw a plain underline or none at all.
pub const Underline = enum(u8) {
    /// No underline.
    none = 0,
    /// One straight line.
    single = 1,
    /// Two straight lines.
    double = 2,
    /// A wavy line, which editors and shells use to mark an error.
    curly = 3,
    /// A line of dots.
    dotted = 4,
    /// A line of dashes.
    dashed = 5,
};

/// Everything SGR can say about a cell, in one value.
///
/// The defaults are what a terminal is in after `resetStyle`, which is what
/// makes `Style{}` the right `from` for a program that has just reset.
///
/// `extern`, and deliberately: a renderer keeps one of these in every cell,
/// and a cell that is `extern` is a row that can be compared with `memcmp`
/// and a screen that can be diffed a row at a time rather than a field at a
/// time. The `comptime` block below pins the two things that makes true --
/// no padding and an alignment of one -- so a field added in the wrong place
/// fails the build instead of quietly making that comparison read the holes.
pub const Style = extern struct {
    /// The colour of the glyphs.
    fg: Color = .default,
    /// The colour of the cell behind them.
    bg: Color = .default,
    /// The colour of the underline, independent of `fg`. Only terminals
    /// implementing SGR 58 honour it; the rest underline in `fg` and ignore
    /// this, so it is always safe to set and never safe to depend on.
    underline_color: Color = .default,
    /// Heavier glyphs — or, on terminals with no bold font, the brighter half
    /// of the palette.
    ///
    /// `bold` and `dim` share one off code, SGR 22, because there is no code
    /// that turns off only one of them. That is why `diffStyle` re-states
    /// `dim` in the same sequence that turns `bold` off, and the reverse.
    bold: bool = false,
    /// Fainter glyphs. Shares its off code with `bold`; see there.
    dim: bool = false,
    /// Slanted glyphs, or reverse video on terminals with no italic font.
    italic: bool = false,
    /// Which underline the cell carries, if any.
    underline: Underline = .none,
    /// Blinking glyphs. Most terminals ship with blink disabled and many
    /// offer no way to enable it, so a program may set this and must not
    /// expect anyone to see it move.
    blink: bool = false,
    /// Foreground and background swapped by the terminal at draw time, so it
    /// inverts whatever `fg` and `bg` are, the defaults included.
    reverse: bool = false,
    /// Conceal: the cell keeps its width and draws nothing. Several terminals
    /// ignore it outright, and the text is still there to be selected and
    /// copied, so this hides nothing from anyone.
    hidden: bool = false,
    /// A line through the middle of the glyphs.
    strikethrough: bool = false,
    /// A line above the glyphs, SGR 53. The counterpart to `underline` and,
    /// unlike it, a plain on-off with no styles -- SGR has no sub-parameter
    /// form for the overline and no code for its colour. Terminals that do
    /// not implement it ignore both codes.
    overline: bool = false,
    /// Whether the glyphs are raised, lowered, or on the baseline.
    script: Script = .none,
};

/// The longest `CSI ... m` either spelling of a style change can produce:
/// `CSI`, the twelve off codes or a `0`, every on code, three colours in
/// their widest forms, and the `m`.
///
/// Sizes the buffer `diffStyle` spells into, which takes the difference
/// before it is known to win. The suite pins the longest difference and the
/// longest reset under this with room to spare for the three-byte copy
/// `Spelling` makes of every number.
const max_sequence = 96;

/// One parameter value's decimal digits, so a colour channel or a palette
/// index is copied out of a table rather than divided out a digit at a time.
const Decimal = struct {
    /// The digits, left-aligned. Bytes past `len` are zero and never reach
    /// the output: whatever follows a number overwrites them.
    digits: [3]u8,
    /// How many of them are the number: 1 to 3.
    len: u8,
};

/// Every value a parameter of this file can take, 0 to 255, spelled.
const decimal: [256]Decimal = blk: {
    var table: [256]Decimal = undefined;
    for (&table, 0..) |*entry, value| {
        entry.* = if (value < 10)
            .{ .digits = .{ '0' + value, 0, 0 }, .len = 1 }
        else if (value < 100)
            .{ .digits = .{ '0' + value / 10, '0' + value % 10, 0 }, .len = 2 }
        else
            .{ .digits = .{ '0' + value / 100, '0' + value / 10 % 10, '0' + value % 10 }, .len = 3 };
    }
    break :blk table;
};

/// Where a spelling goes when only its length is wanted: every byte is
/// counted and none is written.
///
/// `diffStyle` prices the reset spelling through this, with the same body
/// that spells it into a `Spelling` -- so the count is of exactly the bytes
/// that would be written, and there is no second encoder to keep in step
/// with the first.
const Price = struct {
    len: usize = 0,

    fn bytes(p: *Price, comptime text: []const u8) void {
        p.len += text.len;
    }

    fn number(p: *Price, value: u8) void {
        p.len += decimal[value].len;
    }
};

/// Where a spelling is written: a buffer on the stack, handed to the
/// caller's writer in one piece once it has won.
const Spelling = struct {
    buffer: [max_sequence]u8 = undefined,
    len: usize = 0,

    fn bytes(s: *Spelling, comptime text: []const u8) void {
        s.buffer[s.len..][0..text.len].* = text[0..text.len].*;
        s.len += text.len;
    }

    /// All three bytes of the table entry, then the length advanced by the
    /// digits only. A number is always followed by at least the `m`, so the
    /// spare bytes land inside the sequence and are overwritten there.
    fn number(s: *Spelling, value: u8) void {
        const entry = decimal[value];
        s.buffer[s.len..][0..3].* = entry.digits;
        s.len += entry.len;
    }

    fn written(s: *const Spelling) []const u8 {
        return s.buffer[0..s.len];
    }
};

/// One `CSI ... m` being built up, parameter by parameter, into a `Price` or
/// a `Spelling`.
///
/// The `CSI` is written with the first parameter rather than up front,
/// because a diff of two equal styles must write no bytes at all.
fn Params(comptime Out: type) type {
    return struct {
        const Self = @This();

        out: *Out,
        /// Whether a parameter has been written, which is also whether the
        /// `CSI` has been.
        any: bool = false,
        /// Whether a code that turns something off has been written. Read by
        /// `diffStyle`, which needs it to know whether the other spelling is
        /// worth pricing, and set here rather than worked out again from the
        /// fields so the two cannot drift apart.
        turned_off: bool = false,

        /// Opens the sequence on the first parameter and separates every one
        /// after it.
        fn open(p: *Self) void {
            if (p.any) return p.out.bytes(";");
            p.out.bytes(seq.csi);
            p.any = true;
        }

        /// Writes one plain numeric parameter.
        fn code(p: *Self, value: u8) void {
            p.open();
            p.out.number(value);
        }

        /// The same, for a code that turns something off.
        fn offCode(p: *Self, value: u8) void {
            p.turned_off = true;
            p.code(value);
        }

        /// Opens a parameter that has fields of its own and writes its first
        /// piece; the caller writes the rest with `number`, `field` and
        /// `subfield`.
        fn compound(p: *Self, comptime text: []const u8) void {
            p.open();
            p.out.bytes(text);
        }

        /// Writes a bare number, the piece after a compound's opening.
        fn number(p: *Self, value: u8) void {
            p.out.number(value);
        }

        /// Writes `;` and a number, the tail every compound parameter is made of.
        fn field(p: *Self, value: u8) void {
            p.out.bytes(";");
            p.out.number(value);
        }

        /// Writes `:` and a number, the same for the colon-separated forms.
        fn subfield(p: *Self, value: u8) void {
            p.out.bytes(":");
            p.out.number(value);
        }

        /// Ends the sequence, or writes nothing when no parameter was produced.
        ///
        /// Nothing, rather than `CSI m`: a terminal reads an empty parameter
        /// list as `0`, so the tidy-looking empty sequence would reset the
        /// very attributes the diff found no reason to touch.
        fn finish(p: *Self) void {
            if (p.any) p.out.bytes("m");
        }
    };
}

/// Writes a foreground or background colour as one parameter.
///
/// `default_code`, `base` and `bright_base` are 39, 30 and 90 for the
/// foreground and 49, 40 and 100 for the background; `extended` is 38 or 48.
///
/// The extended forms join their fields with `;`, which looks inconsistent
/// beside the underline colour's `:` in `writeUnderlineColor`. It is not:
/// `38;5;n` and `38;2;r;g;b` are the forms every terminal that implements
/// 256-colour and direct colour accepts, while the colon spelling of the same
/// two is understood by few enough that writing it would lose the colour on
/// most terminals.
fn writeFgBg(
    p: anytype,
    color: Color,
    default_code: u8,
    base: u8,
    bright_base: u8,
    extended: u8,
) void {
    switch (color.kind) {
        .default => p.offCode(default_code),
        .ansi => {
            const slot = color.index();
            p.code(if (slot < 8) base + slot else bright_base + (slot - 8));
        },
        .palette => {
            p.code(extended);
            p.field(5);
            p.field(color.index());
        },
        .rgb => {
            p.code(extended);
            p.field(2);
            p.field(color.r);
            p.field(color.g);
            p.field(color.b);
        },
    }
}

/// Writes the underline colour, SGR 58, as one parameter.
///
/// Colons rather than the semicolons `writeFgBg` writes, and deliberately:
/// SGR 58 is recent enough that the terminals implementing it at all document
/// the colon form, and some parse only that. The empty field between `2` and
/// the channels is the colour space id the standard reserves there; no
/// terminal reads it, so it is left empty rather than invented.
///
/// `.ansi` and `.palette` write the same bytes here, because SGR 58 has no
/// short codes for the sixteen — the palette index is its only spelling for
/// them.
fn writeUnderlineColor(p: anytype, color: Color) void {
    switch (color.kind) {
        .default => p.offCode(59),
        .ansi, .palette => {
            p.compound("58:5:");
            p.number(color.index());
        },
        .rgb => {
            p.compound("58:2::");
            p.number(color.r);
            p.subfield(color.g);
            p.subfield(color.b);
        },
    }
}

comptime {
    // What a renderer may rely on: `Style` is `extern`, so its layout is the
    // one written above and stays put; it has no padding, so two of them
    // compare byte for byte with no indeterminate bytes in between; and it
    // aligns to one, so it drops into a cell at any offset. A row of cells
    // carrying one therefore compares with `memcmp`.
    //
    // Pinned rather than assumed: a field of a type wider than a byte, added
    // anywhere but the front, would open a hole and quietly make that
    // comparison read it.
    var total: usize = 0;
    for (@typeInfo(Style).@"struct".fields) |field| total += @sizeOf(field.type);
    std.debug.assert(total == @sizeOf(Style));
    std.debug.assert(@alignOf(Style) == 1);
    std.debug.assert(@sizeOf(Color) == 4);
    std.debug.assert(@alignOf(Color) == 1);
}

/// Resets every attribute and both colours: `CSI 0 m`.
///
/// After this the terminal is in `Style{}`, which is the `from` a program can
/// then hand to `diffStyle` without having tracked anything.
pub fn resetStyle(w: *Writer) Writer.Error!void {
    try w.writeAll(seq.csi ++ "0m");
}

/// Writes the style, assuming the terminal is at its default. Exactly
/// `diffStyle(w, .{}, style)`, so a default style writes nothing at all.
pub fn setStyle(w: *Writer, style: Style) Writer.Error!void {
    try diffStyle(w, .{}, style);
}

/// Writes the shortest SGR sequence that turns `from` into `to`, and nothing
/// at all when they are equal.
///
/// One sequence, whatever changed: the off codes first, then the on codes,
/// then the colours in the order foreground, background, underline. The
/// caller guarantees the terminal is really in `from` — this writes the
/// difference, not the destination, so a wrong `from` leaves attributes on
/// screen that no later call will think to clear.
///
/// There are two ways to spell the same move and this writes the shorter of
/// them. The difference is short when little changed; when much changed, a
/// leading `0` costs two bytes and buys every off code at once, so coming
/// back from an everything-on style is `CSI 0 m`, four bytes, where the
/// difference is thirty-eight. Both spellings leave the terminal in `to`.
/// The difference is spelled once, into a buffer on the stack; the reset is
/// priced by counting, through the same code that spells, so there is no
/// second encoder to keep in step, and spelled only when it wins. Ties go to
/// the difference, which touches least. `diffStyleLen` says how many bytes
/// this writes without writing them.
pub fn diffStyle(w: *Writer, from: Style, to: Style) Writer.Error!void {
    var spelling: Spelling = .{};
    const turned_off = spell(&spelling, from, to, false);
    if (shorterReset(from, to, spelling.len, turned_off) != null) {
        spelling.len = 0;
        _ = spell(&spelling, from, to, true);
    }
    try w.writeAll(spelling.written());
}

/// How many bytes `diffStyle(w, from, to)` writes, without writing them:
/// zero when the two styles are equal, otherwise the length of the one
/// `CSI ... m` it would send, `CSI` and `m` included.
///
/// Exact, not an estimate. It counts through the same encoder `diffStyle`
/// spells with and makes the same choice between the difference and the
/// reset spelling, so for every pair the two agree, and a change to how a
/// style is spelled moves both. That is what a renderer weighing a style
/// change against some other way of drawing the same cells wants: the price
/// of the move it would actually make, from the code that would make it.
///
/// `diffStyleLen(.{}, style)` is what `setStyle` writes.
pub fn diffStyleLen(from: Style, to: Style) usize {
    // Equal styles are the case a renderer asks about most, and a byte
    // comparison answers it without walking the fields. `Style` has no
    // padding, so equal bytes are equal styles and the diff is empty.
    if (std.mem.eql(u8, std.mem.asBytes(&from), std.mem.asBytes(&to))) return 0;
    var difference: Price = .{};
    const turned_off = spell(&difference, from, to, false);
    return shorterReset(from, to, difference.len, turned_off) orelse difference.len;
}

/// The length of the reset spelling of `from` to `to` when it is strictly
/// shorter than a difference of `difference` bytes, and null when the
/// difference is what goes out. The one place `diffStyle` and `diffStyleLen`
/// choose between the two spellings, so they cannot choose differently.
///
/// `turned_off` is what `spell` said of the difference. Nothing changed, which
/// is the case a renderer meets most: no bytes, and nothing to price. Nothing
/// was turned off, so the reset spelling would have to write every attribute
/// `to` carries -- a superset of the difference -- and pay for the `0`
/// besides. It cannot win, so it is not priced. Ties go to the difference.
fn shorterReset(from: Style, to: Style, difference: usize, turned_off: bool) ?usize {
    if (difference == 0 or !turned_off) return null;
    var whole: Price = .{};
    _ = spell(&whole, from, to, true);
    return if (whole.len < difference) whole.len else null;
}

/// Spells one `CSI ... m` into `out`, a `*Price` or a `*Spelling`, either as
/// the difference from `from` or as `0` and then the whole of `to`.
///
/// One body, because the two spellings differ only in where they start: a
/// reset puts the terminal in the default style, so the codes that follow
/// are the difference from that.
///
/// Says whether it wrote a code that turns something off, which is what
/// `diffStyle` needs to know before it is worth pricing the other spelling.
fn spell(out: anytype, from: Style, to: Style, reset: bool) bool {
    var params: Params(@TypeOf(out.*)) = .{ .out = out };
    if (reset) params.code(0);
    const base: Style = if (reset) .{} else from;

    // The off codes come first so that SGR 22, which turns off bold and dim
    // together, cannot undo an on code written in the same sequence.
    const off_bold_dim = (base.bold and !to.bold) or (base.dim and !to.dim);
    if (off_bold_dim) params.offCode(22);
    if (base.italic and !to.italic) params.offCode(23);
    if (base.underline != .none and to.underline == .none) params.offCode(24);
    if (base.blink and !to.blink) params.offCode(25);
    if (base.reverse and !to.reverse) params.offCode(27);
    if (base.hidden and !to.hidden) params.offCode(28);
    if (base.strikethrough and !to.strikethrough) params.offCode(29);
    if (base.overline and !to.overline) params.offCode(55);
    if (base.script != to.script and to.script == .none) params.offCode(75);

    // Hence the `or off_bold_dim`: turning one of the pair off has just
    // turned the other off too, so the survivor is stated again.
    if (to.bold and (!base.bold or off_bold_dim)) params.code(1);
    if (to.dim and (!base.dim or off_bold_dim)) params.code(2);
    if (to.italic and !base.italic) params.code(3);
    if (to.underline != base.underline and to.underline != .none) {
        if (to.underline == .single) {
            // Bare `4`, not `4:1`. The plain underline predates the
            // sub-parameter form by decades and terminals that have never
            // heard of `4:1` still draw it.
            params.code(4);
        } else {
            params.compound("4:");
            params.number(@intFromEnum(to.underline));
        }
    }
    if (to.blink and !base.blink) params.code(5);
    if (to.reverse and !base.reverse) params.code(7);
    if (to.hidden and !base.hidden) params.code(8);
    if (to.strikethrough and !base.strikethrough) params.code(9);
    if (to.overline and !base.overline) params.code(53);
    if (to.script != base.script and to.script != .none) {
        params.code(@intFromEnum(to.script));
    }

    if (!base.fg.eql(to.fg)) writeFgBg(&params, to.fg, 39, 30, 90, 38);
    if (!base.bg.eql(to.bg)) writeFgBg(&params, to.bg, 49, 40, 100, 48);
    if (!base.underline_color.eql(to.underline_color)) {
        writeUnderlineColor(&params, to.underline_color);
    }

    params.finish();
    return params.turned_off;
}

test "resetStyle writes the one parameter that clears everything" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try resetStyle(&out.writer);
    try std.testing.expectEqualStrings("\x1b[0m", out.written());
}

test "setStyle of a default style writes nothing at all" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try setStyle(&out.writer, .{});
    try std.testing.expectEqualStrings("", out.written());
}

test "each attribute alone writes its own code" {
    const cases = [_]struct { style: Style, bytes: []const u8 }{
        .{ .style = .{ .bold = true }, .bytes = "\x1b[1m" },
        .{ .style = .{ .dim = true }, .bytes = "\x1b[2m" },
        .{ .style = .{ .italic = true }, .bytes = "\x1b[3m" },
        .{ .style = .{ .blink = true }, .bytes = "\x1b[5m" },
        .{ .style = .{ .reverse = true }, .bytes = "\x1b[7m" },
        .{ .style = .{ .hidden = true }, .bytes = "\x1b[8m" },
        .{ .style = .{ .strikethrough = true }, .bytes = "\x1b[9m" },
    };
    for (cases) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();

        try setStyle(&out.writer, case.style);
        try std.testing.expectEqualStrings(case.bytes, out.written());
    }
}

test "each underline writes its sub-parameter, except the plain one" {
    const cases = [_]struct { underline: Underline, bytes: []const u8 }{
        .{ .underline = .single, .bytes = "\x1b[4m" },
        .{ .underline = .double, .bytes = "\x1b[4:2m" },
        .{ .underline = .curly, .bytes = "\x1b[4:3m" },
        .{ .underline = .dotted, .bytes = "\x1b[4:4m" },
        .{ .underline = .dashed, .bytes = "\x1b[4:5m" },
    };
    for (cases) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();

        try setStyle(&out.writer, .{ .underline = case.underline });
        try std.testing.expectEqualStrings(case.bytes, out.written());
    }
}

test "no underline at all writes nothing, being the default" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try setStyle(&out.writer, .{ .underline = .none });
    try std.testing.expectEqualStrings("", out.written());
}

test "every ansi colour writes its own foreground and background code" {
    const cases = [_]struct { color: Ansi, fg: []const u8, bg: []const u8 }{
        .{ .color = .black, .fg = "\x1b[30m", .bg = "\x1b[40m" },
        .{ .color = .red, .fg = "\x1b[31m", .bg = "\x1b[41m" },
        .{ .color = .green, .fg = "\x1b[32m", .bg = "\x1b[42m" },
        .{ .color = .yellow, .fg = "\x1b[33m", .bg = "\x1b[43m" },
        .{ .color = .blue, .fg = "\x1b[34m", .bg = "\x1b[44m" },
        .{ .color = .magenta, .fg = "\x1b[35m", .bg = "\x1b[45m" },
        .{ .color = .cyan, .fg = "\x1b[36m", .bg = "\x1b[46m" },
        .{ .color = .white, .fg = "\x1b[37m", .bg = "\x1b[47m" },
        .{ .color = .bright_black, .fg = "\x1b[90m", .bg = "\x1b[100m" },
        .{ .color = .bright_red, .fg = "\x1b[91m", .bg = "\x1b[101m" },
        .{ .color = .bright_green, .fg = "\x1b[92m", .bg = "\x1b[102m" },
        .{ .color = .bright_yellow, .fg = "\x1b[93m", .bg = "\x1b[103m" },
        .{ .color = .bright_blue, .fg = "\x1b[94m", .bg = "\x1b[104m" },
        .{ .color = .bright_magenta, .fg = "\x1b[95m", .bg = "\x1b[105m" },
        .{ .color = .bright_cyan, .fg = "\x1b[96m", .bg = "\x1b[106m" },
        .{ .color = .bright_white, .fg = "\x1b[97m", .bg = "\x1b[107m" },
    };
    for (cases) |case| {
        var fg: Writer.Allocating = .init(std.testing.allocator);
        defer fg.deinit();
        try setStyle(&fg.writer, .{ .fg = .ansi(case.color) });
        try std.testing.expectEqualStrings(case.fg, fg.written());

        var bg: Writer.Allocating = .init(std.testing.allocator);
        defer bg.deinit();
        try setStyle(&bg.writer, .{ .bg = .ansi(case.color) });
        try std.testing.expectEqualStrings(case.bg, bg.written());
    }
}

test "a palette colour writes the indexed form on all three sides" {
    const cases = [_]struct { style: Style, bytes: []const u8 }{
        .{ .style = .{ .fg = .palette(0) }, .bytes = "\x1b[38;5;0m" },
        .{ .style = .{ .fg = .palette(196) }, .bytes = "\x1b[38;5;196m" },
        .{ .style = .{ .fg = .palette(255) }, .bytes = "\x1b[38;5;255m" },
        .{ .style = .{ .bg = .palette(17) }, .bytes = "\x1b[48;5;17m" },
        .{ .style = .{ .bg = .palette(255) }, .bytes = "\x1b[48;5;255m" },
        // The underline colour has no short codes, so its sixteen are written
        // as palette entries like any other index.
        .{ .style = .{ .underline_color = .palette(3) }, .bytes = "\x1b[58:5:3m" },
        .{ .style = .{ .underline_color = .palette(231) }, .bytes = "\x1b[58:5:231m" },
    };
    for (cases) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();

        try setStyle(&out.writer, case.style);
        try std.testing.expectEqualStrings(case.bytes, out.written());
    }
}

test "an ansi underline colour writes the same bytes as its palette entry" {
    var named: Writer.Allocating = .init(std.testing.allocator);
    defer named.deinit();
    try setStyle(&named.writer, .{ .underline_color = .ansi(.bright_magenta) });
    try std.testing.expectEqualStrings("\x1b[58:5:13m", named.written());

    var indexed: Writer.Allocating = .init(std.testing.allocator);
    defer indexed.deinit();
    try setStyle(&indexed.writer, .{ .underline_color = .palette(13) });
    try std.testing.expectEqualStrings(named.written(), indexed.written());
}

test "a direct colour writes semicolons for fg and bg and colons for the underline" {
    const cases = [_]struct { style: Style, bytes: []const u8 }{
        .{ .style = .{ .fg = .rgb(0, 0, 0) }, .bytes = "\x1b[38;2;0;0;0m" },
        .{ .style = .{ .fg = .rgb(255, 128, 1) }, .bytes = "\x1b[38;2;255;128;1m" },
        .{ .style = .{ .bg = .rgb(17, 34, 51) }, .bytes = "\x1b[48;2;17;34;51m" },
        .{ .style = .{ .bg = .rgb(255, 255, 255) }, .bytes = "\x1b[48;2;255;255;255m" },
        .{
            .style = .{ .underline_color = .rgb(255, 0, 0) },
            .bytes = "\x1b[58:2::255:0:0m",
        },
        .{
            .style = .{ .underline_color = .rgb(1, 2, 3) },
            .bytes = "\x1b[58:2::1:2:3m",
        },
    };
    for (cases) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();

        try setStyle(&out.writer, case.style);
        try std.testing.expectEqualStrings(case.bytes, out.written());
    }
}

test "a combined style is one sequence in the documented order" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try setStyle(&out.writer, .{
        .fg = .rgb(10, 20, 30),
        .bg = .palette(200),
        .underline_color = .rgb(1, 2, 3),
        .bold = true,
        .italic = true,
        .underline = .curly,
    });
    try std.testing.expectEqualStrings(
        "\x1b[1;3;4:3;38;2;10;20;30;48;5;200;58:2::1:2:3m",
        out.written(),
    );
}

test "turning one of bold and dim off re-states the other" {
    // SGR 22 turns off both, so the survivor is stated again -- and a reset
    // spells the same move a byte shorter, which is what goes out.
    var dim: Writer.Allocating = .init(std.testing.allocator);
    defer dim.deinit();
    try diffStyle(&dim.writer, .{ .bold = true, .dim = true }, .{ .dim = true });
    try std.testing.expectEqualStrings("\x1b[0;2m", dim.written());

    var bold: Writer.Allocating = .init(std.testing.allocator);
    defer bold.deinit();
    try diffStyle(&bold.writer, .{ .bold = true, .dim = true }, .{ .bold = true });
    try std.testing.expectEqualStrings("\x1b[0;1m", bold.written());
}

test "the difference wins where it is the shorter of the two" {
    // Nothing here turns the pair off, so there is no SGR 22 to undo and no
    // `0` worth paying two bytes for.
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try diffStyle(&out.writer, .{ .bold = true, .dim = true }, .{ .bold = true, .dim = true, .italic = true });
    try std.testing.expectEqualStrings("\x1b[3m", out.written());

    out.clearRetainingCapacity();
    try diffStyle(&out.writer, .{ .bold = true, .fg = .ansi(.cyan) }, .{ .fg = .ansi(.cyan) });
    try std.testing.expectEqualStrings("\x1b[22m", out.written());
}

test "turning both bold and dim off is a reset, which is shorter" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try diffStyle(&out.writer, .{ .bold = true, .dim = true }, .{});
    try std.testing.expectEqualStrings("\x1b[0m", out.written());
}

test "bold arriving beside a dim that stays on leaves the dim alone" {
    // Nothing here turns the pair off, so there is no SGR 22 to undo and no
    // reason to state `dim` again.
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try diffStyle(&out.writer, .{ .dim = true, .italic = true }, .{ .dim = true, .bold = true });
    try std.testing.expectEqualStrings("\x1b[23;1m", out.written());
}

test "a colour change beside an off code keeps the passes in order" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try diffStyle(
        &out.writer,
        .{ .bold = true, .blink = true, .fg = .ansi(.red) },
        .{ .italic = true, .fg = .palette(33), .bg = .ansi(.bright_black) },
    );
    try std.testing.expectEqualStrings("\x1b[0;3;38;5;33;100m", out.written());
}

test "turning an underline off writes the underline off code, or a reset" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    // `CSI 24 m` and `CSI 0 m` leave the same terminal, and the second is a
    // byte shorter, so that is the one written.
    try diffStyle(&out.writer, .{ .underline = .curly }, .{});
    try std.testing.expectEqualStrings("\x1b[0m", out.written());

    // With something else still on, the off code is the shorter half.
    out.clearRetainingCapacity();
    try diffStyle(&out.writer, .{ .underline = .curly, .bold = true }, .{ .bold = true });
    try std.testing.expectEqualStrings("\x1b[24m", out.written());
}

test "changing one underline to another writes only the new one" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try diffStyle(&out.writer, .{ .underline = .curly }, .{ .underline = .dotted });
    try std.testing.expectEqualStrings("\x1b[4:4m", out.written());
}

test "a colour going back to default writes the default code for its side" {
    // The off code where it is the shorter half: something else stays on,
    // so a reset would have to state that again.
    const cases = [_]struct { from: Style, bytes: []const u8 }{
        .{ .from = .{ .fg = .ansi(.red), .bold = true }, .bytes = "\x1b[39m" },
        .{ .from = .{ .fg = .rgb(1, 2, 3), .bold = true }, .bytes = "\x1b[39m" },
        .{ .from = .{ .bg = .palette(200), .bold = true }, .bytes = "\x1b[49m" },
        .{ .from = .{ .underline_color = .rgb(9, 9, 9), .bold = true }, .bytes = "\x1b[59m" },
    };
    for (cases) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();

        try diffStyle(&out.writer, case.from, .{ .bold = true });
        try std.testing.expectEqualStrings(case.bytes, out.written());
    }
}

test "all three colours going back to default are one reset" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try diffStyle(&out.writer, .{
        .fg = .ansi(.red),
        .bg = .palette(200),
        .underline_color = .rgb(1, 2, 3),
    }, .{});
    try std.testing.expectEqualStrings("\x1b[0m", out.written());
}

test "the same sixteen colours in their two spellings are not the same colour" {
    // `.ansi` and `.palette` 1 are the same slot, so the diff must still write
    // the new spelling rather than treat the change as a no-op.
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try diffStyle(&out.writer, .{ .fg = .ansi(.red) }, .{ .fg = .palette(1) });
    try std.testing.expectEqualStrings("\x1b[38;5;1m", out.written());
}

test "what goes out is the shorter of the two spellings, on every pair" {
    // The early-out that skips pricing the reset spelling when nothing was
    // turned off has to be free: for every pair of these, what `diffStyle`
    // writes is exactly the shorter of the difference and the reset.
    const styles = [_]Style{
        .{},
        .{ .bold = true },
        .{ .dim = true },
        .{ .bold = true, .dim = true },
        .{ .italic = true },
        .{ .blink = true },
        .{ .reverse = true },
        .{ .hidden = true },
        .{ .strikethrough = true },
        .{ .overline = true },
        .{ .underline = .single },
        .{ .underline = .curly },
        .{ .underline = .dashed, .underline_color = .rgb(1, 2, 3) },
        .{ .script = .superscript },
        .{ .script = .subscript },
        .{ .fg = .ansi(.red) },
        .{ .fg = .palette(33) },
        .{ .fg = .rgb(1, 2, 3) },
        .{ .bg = .ansi(.blue) },
        .{ .bg = .rgb(4, 5, 6) },
        .{ .underline_color = .ansi(.green) },
        .{ .bold = true, .italic = true, .fg = .rgb(9, 9, 9), .bg = .palette(7) },
        .{ .dim = true, .underline = .dotted, .overline = true, .script = .subscript },
        .{
            .bold = true,
            .dim = true,
            .italic = true,
            .underline = .dashed,
            .blink = true,
            .reverse = true,
            .hidden = true,
            .strikethrough = true,
            .overline = true,
            .script = .superscript,
            .fg = .rgb(1, 2, 3),
            .bg = .rgb(4, 5, 6),
            .underline_color = .rgb(7, 8, 9),
        },
    };

    var buffer: [max_sequence]u8 = undefined;
    for (styles) |from| {
        for (styles) |to| {
            // Priced by the encoder `diffStyle` used to write with, which
            // formatted both spellings to count them.
            var delta: Writer.Discarding = .init(&.{});
            _ = try oracle.writeSgr(&delta.writer, from, to, false);
            var whole: Writer.Discarding = .init(&.{});
            _ = try oracle.writeSgr(&whole.writer, from, to, true);

            var w: Writer = .fixed(&buffer);
            try diffStyle(&w, from, to);
            try std.testing.expectEqual(
                @min(delta.fullCount(), whole.fullCount()),
                @as(u64, w.buffered().len),
            );
            // And whichever won, it is one sequence and it ends in `m`.
            if (w.buffered().len != 0) {
                try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, w.buffered(), "\x1b["));
                try std.testing.expectEqual(@as(u8, 'm'), w.buffered()[w.buffered().len - 1]);
            }
        }
    }
}

test "diffStyleLen is the length diffStyle writes" {
    const cases = [_]struct { from: Style, to: Style, len: usize }{
        // Equal styles: nothing written, nothing to pay.
        .{ .from = .{}, .to = .{}, .len = 0 },
        .{ .from = .{ .bold = true, .fg = .rgb(1, 2, 3) }, .to = .{ .bold = true, .fg = .rgb(1, 2, 3) }, .len = 0 },
        // `CSI 1 m`.
        .{ .from = .{}, .to = .{ .bold = true }, .len = 4 },
        // `CSI 38;2;255;128;1 m`.
        .{ .from = .{}, .to = .{ .fg = .rgb(255, 128, 1) }, .len = 17 },
        // The reset spelling wins: `CSI 0;2 m` rather than `CSI 22;2 m`.
        .{ .from = .{ .bold = true, .dim = true }, .to = .{ .dim = true }, .len = 6 },
        // The difference wins: `CSI 24 m` rather than `CSI 0;1 m`.
        .{ .from = .{ .underline = .curly, .bold = true }, .to = .{ .bold = true }, .len = 5 },
    };
    for (cases) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try diffStyle(&out.writer, case.from, case.to);
        try std.testing.expectEqual(case.len, out.written().len);
        try std.testing.expectEqual(case.len, diffStyleLen(case.from, case.to));
    }

    // On random pairs, and from and to the default, which is `setStyle` and
    // the way back.
    var prng: std.Random.DefaultPrng = .init(0xc057);
    const random = prng.random();
    var buffer: [max_sequence]u8 = undefined;
    for (0..20_000) |_| {
        const from = randomStyle(random);
        const to = randomStyle(random);
        for ([_][2]Style{ .{ from, to }, .{ .{}, to }, .{ from, .{} }, .{ to, to } }) |pair| {
            var w: Writer = .fixed(&buffer);
            try diffStyle(&w, pair[0], pair[1]);
            try std.testing.expectEqual(w.buffered().len, diffStyleLen(pair[0], pair[1]));
        }
    }
}

test "the longest sequence either spelling writes fits the spelling buffer" {
    // What `max_sequence` is sized against. Every attribute on at once from
    // a default terminal, three direct colours: the longest body there is.
    const widest: Style = .{
        .bold = true,
        .dim = true,
        .italic = true,
        .underline = .dashed,
        .blink = true,
        .reverse = true,
        .hidden = true,
        .strikethrough = true,
        .overline = true,
        .script = .superscript,
        .fg = .rgb(255, 255, 255),
        .bg = .rgb(255, 255, 255),
        .underline_color = .rgb(255, 255, 255),
    };
    var buffer: [max_sequence]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try setStyle(&w, widest);
    try std.testing.expect(w.buffered().len < max_sequence);

    // The winner is never longer than the reset spelling, and the reset
    // spelling of the widest style is its body and `0;`. `Spelling` copies
    // three bytes for every number, up to two past the digits, so that much
    // room is kept beyond it as well.
    var whole: Price = .{};
    _ = spell(&whole, .{ .bold = true }, widest, true);
    try std.testing.expectEqual(w.buffered().len + 2, whole.len);
    try std.testing.expect(whole.len + 2 <= max_sequence);

    // The difference is spelled before it is known to win, so the longest
    // of those has to fit too. Every attribute takes whichever of its on and
    // off codes is longer, bold goes off beside a dim that is stated again,
    // and all three colours change to their widest spelling: 84 bytes.
    const lit: Style = .{
        .bold = true,
        .italic = true,
        .blink = true,
        .reverse = true,
        .hidden = true,
        .strikethrough = true,
        .overline = true,
        .script = .subscript,
    };
    const longest: Style = .{
        .dim = true,
        .underline = .dashed,
        .fg = .rgb(255, 255, 255),
        .bg = .rgb(255, 255, 255),
        .underline_color = .rgb(255, 255, 255),
    };
    var difference: Price = .{};
    _ = spell(&difference, lit, longest, false);
    try std.testing.expectEqual(@as(usize, 84), difference.len);
    try std.testing.expect(difference.len + 2 <= max_sequence);
}

test "a style diffed against itself writes nothing" {
    const styles = [_]Style{
        .{},
        .{ .bold = true },
        .{ .dim = true },
        .{ .bold = true, .dim = true },
        .{ .italic = true, .strikethrough = true },
        .{ .underline = .single },
        .{ .underline = .curly },
        .{ .blink = true, .reverse = true, .hidden = true },
        .{ .fg = .ansi(.bright_cyan) },
        .{ .bg = .ansi(.black) },
        .{ .fg = .palette(231), .bg = .palette(16) },
        .{ .fg = .rgb(255, 0, 127) },
        .{ .underline_color = .rgb(0, 255, 0) },
        .{ .underline_color = .ansi(.yellow) },
        .{
            .fg = .rgb(1, 2, 3),
            .bg = .palette(8),
            .underline_color = .palette(9),
            .bold = true,
            .dim = true,
            .italic = true,
            .underline = .dashed,
            .blink = true,
            .reverse = true,
            .hidden = true,
            .strikethrough = true,
        },
    };
    for (styles) |style| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();

        try diffStyle(&out.writer, style, style);
        try std.testing.expectEqualStrings("", out.written());
    }
}

test "everything on and everything off again, in both directions" {
    const everything = Style{
        .fg = .ansi(.red),
        .bg = .ansi(.bright_blue),
        .underline_color = .ansi(.green),
        .bold = true,
        .dim = true,
        .italic = true,
        .underline = .dashed,
        .blink = true,
        .reverse = true,
        .hidden = true,
        .strikethrough = true,
        .overline = true,
    };

    var on: Writer.Allocating = .init(std.testing.allocator);
    defer on.deinit();
    try diffStyle(&on.writer, .{}, everything);
    try std.testing.expectEqualStrings("\x1b[1;2;3;4:5;5;7;8;9;53;31;104;58:5:2m", on.written());

    // And back again in four bytes rather than thirty-five, which is what
    // taking the shorter of the two spellings is worth at its widest.
    var off: Writer.Allocating = .init(std.testing.allocator);
    defer off.deinit();
    try diffStyle(&off.writer, everything, .{});
    try std.testing.expectEqualStrings("\x1b[0m", off.written());
}

test "setStyle is the diff from the default style" {
    const styles = [_]Style{
        .{ .bold = true, .underline = .double },
        .{ .fg = .palette(42), .reverse = true },
        .{ .underline_color = .rgb(7, 8, 9), .underline = .curly },
    };
    for (styles) |style| {
        var direct: Writer.Allocating = .init(std.testing.allocator);
        defer direct.deinit();
        try setStyle(&direct.writer, style);

        var diffed: Writer.Allocating = .init(std.testing.allocator);
        defer diffed.deinit();
        try diffStyle(&diffed.writer, .{}, style);

        try std.testing.expectEqualStrings(diffed.written(), direct.written());
    }
}

test "a writer with no room left reports the failure" {
    var buffer: [4]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try std.testing.expectError(error.WriteFailed, setStyle(&w, .{
        .fg = .rgb(255, 255, 255),
        .bold = true,
        .italic = true,
        .underline = .curly,
    }));
}

test "overline writes its own on and off codes" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try setStyle(&out.writer, .{ .overline = true });
    try std.testing.expectEqualStrings("\x1b[53m", out.written());

    out.clearRetainingCapacity();
    try diffStyle(&out.writer, .{ .overline = true, .bold = true }, .{ .bold = true });
    try std.testing.expectEqualStrings("\x1b[55m", out.written());
}

test "overline is independent of the underline" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    // The off pass first, then the on pass -- 55 turns the overline off and
    // cannot disturb the underline that arrives in the same sequence.
    try diffStyle(
        &out.writer,
        .{ .overline = true, .bold = true },
        .{ .underline = .single, .bold = true },
    );
    try std.testing.expectEqualStrings("\x1b[55;4m", out.written());

    out.clearRetainingCapacity();
    try diffStyle(&out.writer, .{ .underline = .curly, .bold = true }, .{ .overline = true, .bold = true });
    try std.testing.expectEqualStrings("\x1b[24;53m", out.written());
}

test "an overline that stays on writes nothing" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try diffStyle(
        &out.writer,
        .{ .overline = true, .bold = true },
        .{ .overline = true, .bold = true },
    );
    try std.testing.expectEqualStrings("", out.written());
}

test "a superscript and a subscript write their own codes" {
    const cases = [_]struct { style: Style, bytes: []const u8 }{
        .{ .style = .{ .script = .superscript }, .bytes = "\x1b[73m" },
        .{ .style = .{ .script = .subscript }, .bytes = "\x1b[74m" },
    };
    for (cases) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try setStyle(&out.writer, case.style);
        try std.testing.expectEqualStrings(case.bytes, out.written());
    }
}

test "the script diff writes one code, and 75 only on the way back to none" {
    const cases = [_]struct { from: Script, to: Script, bytes: []const u8 }{
        .{ .from = .none, .to = .none, .bytes = "" },
        .{ .from = .none, .to = .superscript, .bytes = "\x1b[73m" },
        .{ .from = .none, .to = .subscript, .bytes = "\x1b[74m" },
        .{ .from = .superscript, .to = .subscript, .bytes = "\x1b[74m" },
        .{ .from = .subscript, .to = .superscript, .bytes = "\x1b[73m" },
        // A reset is a byte shorter than the off code when nothing else is
        // on, and the same style either way.
        .{ .from = .superscript, .to = .none, .bytes = "\x1b[0m" },
        .{ .from = .subscript, .to = .none, .bytes = "\x1b[0m" },
        .{ .from = .subscript, .to = .subscript, .bytes = "" },
    };
    for (cases) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try diffStyle(&out.writer, .{ .script = case.from }, .{ .script = case.to });
        try std.testing.expectEqualStrings(case.bytes, out.written());
    }
}

test "the script travels with every other attribute in one sequence" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try diffStyle(
        &out.writer,
        .{ .bold = true, .script = .subscript },
        .{ .italic = true, .script = .superscript },
    );
    try std.testing.expectEqualStrings("\x1b[0;3;73m", out.written());
}

test "a style has no padding, so two of them compare byte for byte" {
    // The comptime block above asserts it; this says what it buys, which is
    // that a renderer may compare styles -- and rows of cells holding them --
    // without walking the fields.
    const a: Style = .{ .bold = true, .fg = .ansi(.red) };
    var b: Style = undefined;
    @memset(std.mem.asBytes(&b), 0xaa);
    b = a;
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));

    const c: Style = .{ .bold = true, .fg = .ansi(.blue) };
    try std.testing.expect(!std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&c)));
    try std.testing.expectEqual(@as(usize, 1), @alignOf(Style));
}

test "a colour is four bytes in every form, and no form has padding" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Color));
    try std.testing.expectEqual(@as(usize, 1), @alignOf(Color));
    try std.testing.expectEqual(@as(usize, 22), @sizeOf(Style));
    try std.testing.expectEqual(@as(usize, 1), @alignOf(Style));

    // Three colours and ten one-byte fields, with nothing in between.
    var total: usize = 0;
    inline for (@typeInfo(Style).@"struct".fields) |field| total += @sizeOf(field.type);
    try std.testing.expectEqual(@sizeOf(Style), total);
}

test "every constructor writes the fields its kind uses and no others" {
    const cases = [_]struct { color: Color, kind: Color.Kind, bytes: [4]u8 }{
        .{ .color = .default, .kind = .default, .bytes = .{ 0, 0, 0, 0 } },
        .{ .color = .ansi(.red), .kind = .ansi, .bytes = .{ 1, 1, 0, 0 } },
        .{ .color = .ansi(.bright_white), .kind = .ansi, .bytes = .{ 1, 15, 0, 0 } },
        .{ .color = .palette(196), .kind = .palette, .bytes = .{ 2, 196, 0, 0 } },
        .{ .color = .rgb(255, 128, 1), .kind = .rgb, .bytes = .{ 3, 255, 128, 1 } },
        .{ .color = .fromRgb(.{ .r = 1, .g = 2, .b = 3 }), .kind = .rgb, .bytes = .{ 3, 1, 2, 3 } },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.kind, case.color.kind);
        try std.testing.expectEqualSlices(u8, &case.bytes, std.mem.asBytes(&case.color));
    }

    try std.testing.expectEqual(Ansi.red, Color.ansi(.red).toAnsi());
    try std.testing.expectEqual(@as(u8, 196), Color.palette(196).index());
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 128, .b = 1 }, Color.rgb(255, 128, 1).toRgb());
}

test "every Ansi slot round trips through a colour" {
    for (0..16) |i| {
        const slot: Ansi = @enumFromInt(i);
        const color: Color = .ansi(slot);
        try std.testing.expectEqual(slot, color.toAnsi());
        try std.testing.expectEqual(@as(u8, @intCast(i)), color.index());
    }
}

test "eql and a byte comparison agree on every colour a constructor makes" {
    // The relation the `extern` layout exists for. Every colour a
    // constructor produces is canonical -- the channels its kind does not
    // use are zero -- so comparing four bytes and comparing meaning are the
    // same comparison, on every pair.
    var colors: [1 + 16 + 256 + 12]Color = undefined;
    var n: usize = 0;
    colors[n] = .default;
    n += 1;
    for (0..16) |i| {
        colors[n] = .ansi(@enumFromInt(i));
        n += 1;
    }
    for (0..256) |i| {
        colors[n] = .palette(@intCast(i));
        n += 1;
    }
    for ([_][3]u8{
        .{ 0, 0, 0 },
        .{ 1, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, 0, 1 },
        .{ 255, 128, 1 },
        .{ 255, 255, 255 },
    }) |channels| {
        colors[n] = .rgb(channels[0], channels[1], channels[2]);
        n += 1;
        colors[n] = .fromRgb(.{ .r = channels[0], .g = channels[1], .b = channels[2] });
        n += 1;
    }

    for (colors[0..n]) |a| {
        for (colors[0..n]) |b| {
            const bytes = std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
            try std.testing.expectEqual(bytes, a.eql(b));
        }
    }
}

test "a colour a constructor made has no rubbish in the channels it does not use" {
    // Canonical on construction is what makes the two relations one: there
    // is no way to reach a `.default` carrying a stray green byte except by
    // writing the fields out by hand, which is the caller's to keep right.
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, std.mem.asBytes(&Color.default));
    try std.testing.expectEqualSlices(u8, &.{ 1, 9, 0, 0 }, std.mem.asBytes(&Color.ansi(.bright_red)));
    try std.testing.expectEqualSlices(u8, &.{ 2, 196, 0, 0 }, std.mem.asBytes(&Color.palette(196)));

    // And two colours of different kinds that share a first byte are not
    // equal.
    try std.testing.expect(!Color.ansi(.red).eql(Color.palette(1)));
    try std.testing.expect(Color.rgb(1, 2, 3).eql(Color.rgb(1, 2, 3)));
    try std.testing.expect(!Color.rgb(1, 2, 3).eql(Color.rgb(1, 2, 4)));
}

test "a row of cells holding a style compares with memcmp" {
    // The comparison a renderer makes on every frame, and what `extern`
    // bought: a cell with a style in it, in an array, compared in one call.
    const Cell = extern struct {
        codepoint: u32 = ' ',
        style: Style = .{},
        pad: [6]u8 = @splat(0),
    };
    comptime std.debug.assert(@sizeOf(Cell) == 32);

    var a: [80]Cell = @splat(.{});
    var b: [80]Cell = @splat(.{});
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&a), std.mem.sliceAsBytes(&b));

    b[40].style.fg = .ansi(.cyan);
    try std.testing.expect(!std.mem.eql(u8, std.mem.sliceAsBytes(&a), std.mem.sliceAsBytes(&b)));

    a[40].style.fg = .ansi(.cyan);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&a), std.mem.sliceAsBytes(&b));
}

/// The encoder `diffStyle` used before it priced by counting: every
/// parameter formatted through a `Writer`, a `Writer.Discarding` to price
/// each spelling, and the winner formatted a third time. Kept as the oracle
/// the differential tests hold the counting encoder to, byte for byte.
const oracle = struct {
    const FormattedParams = struct {
        w: *Writer,
        any: bool = false,
        turned_off: bool = false,

        fn open(p: *FormattedParams) Writer.Error!void {
            if (p.any) return p.w.writeByte(';');
            try p.w.writeAll(seq.csi);
            p.any = true;
        }

        fn code(p: *FormattedParams, value: u8) Writer.Error!void {
            try p.open();
            try seq.writeInt(p.w, value);
        }

        fn offCode(p: *FormattedParams, value: u8) Writer.Error!void {
            p.turned_off = true;
            return p.code(value);
        }

        fn compound(p: *FormattedParams, bytes: []const u8) Writer.Error!void {
            try p.open();
            try p.w.writeAll(bytes);
        }

        fn field(p: *FormattedParams, value: u8) Writer.Error!void {
            try p.w.writeByte(';');
            try seq.writeInt(p.w, value);
        }

        fn subfield(p: *FormattedParams, value: u8) Writer.Error!void {
            try p.w.writeByte(':');
            try seq.writeInt(p.w, value);
        }

        fn finish(p: *FormattedParams) Writer.Error!void {
            if (p.any) try p.w.writeByte('m');
        }
    };

    fn formatFgBg(p: *FormattedParams, color: Color, default_code: u8, base: u8, bright_base: u8, extended: u8) Writer.Error!void {
        switch (color.kind) {
            .default => try p.offCode(default_code),
            .ansi => {
                const slot = color.index();
                try p.code(if (slot < 8) base + slot else bright_base + (slot - 8));
            },
            .palette => {
                try p.code(extended);
                try p.w.writeAll(";5;");
                try seq.writeInt(p.w, color.index());
            },
            .rgb => {
                try p.code(extended);
                try p.w.writeAll(";2;");
                try seq.writeInt(p.w, color.r);
                try p.field(color.g);
                try p.field(color.b);
            },
        }
    }

    fn formatUnderlineColor(p: *FormattedParams, color: Color) Writer.Error!void {
        switch (color.kind) {
            .default => try p.offCode(59),
            .ansi, .palette => {
                try p.compound("58:5:");
                try seq.writeInt(p.w, color.index());
            },
            .rgb => {
                try p.compound("58:2::");
                try seq.writeInt(p.w, color.r);
                try p.subfield(color.g);
                try p.subfield(color.b);
            },
        }
    }

    fn diff(w: *Writer, from: Style, to: Style) Writer.Error!void {
        var scratch: [max_sequence]u8 = undefined;
        var delta: Writer.Discarding = .init(&scratch);
        const turned_off = writeSgr(&delta.writer, from, to, false) catch unreachable;
        const difference = delta.fullCount();
        if (difference == 0) return;
        if (!turned_off) {
            _ = try writeSgr(w, from, to, false);
            return;
        }
        var whole: Writer.Discarding = .init(&scratch);
        _ = writeSgr(&whole.writer, from, to, true) catch unreachable;
        _ = try writeSgr(w, from, to, whole.fullCount() < difference);
    }

    fn writeSgr(w: *Writer, from: Style, to: Style, reset: bool) Writer.Error!bool {
        var params: FormattedParams = .{ .w = w };
        if (reset) try params.code(0);
        const base: Style = if (reset) .{} else from;

        const off_bold_dim = (base.bold and !to.bold) or (base.dim and !to.dim);
        if (off_bold_dim) try params.offCode(22);
        if (base.italic and !to.italic) try params.offCode(23);
        if (base.underline != .none and to.underline == .none) try params.offCode(24);
        if (base.blink and !to.blink) try params.offCode(25);
        if (base.reverse and !to.reverse) try params.offCode(27);
        if (base.hidden and !to.hidden) try params.offCode(28);
        if (base.strikethrough and !to.strikethrough) try params.offCode(29);
        if (base.overline and !to.overline) try params.offCode(55);
        if (base.script != to.script and to.script == .none) try params.offCode(75);

        if (to.bold and (!base.bold or off_bold_dim)) try params.code(1);
        if (to.dim and (!base.dim or off_bold_dim)) try params.code(2);
        if (to.italic and !base.italic) try params.code(3);
        if (to.underline != base.underline and to.underline != .none) {
            if (to.underline == .single) {
                try params.code(4);
            } else {
                try params.compound("4:");
                try seq.writeInt(w, @intFromEnum(to.underline));
            }
        }
        if (to.blink and !base.blink) try params.code(5);
        if (to.reverse and !base.reverse) try params.code(7);
        if (to.hidden and !base.hidden) try params.code(8);
        if (to.strikethrough and !base.strikethrough) try params.code(9);
        if (to.overline and !base.overline) try params.code(53);
        if (to.script != base.script and to.script != .none) {
            try params.code(@intFromEnum(to.script));
        }

        if (!base.fg.eql(to.fg)) try formatFgBg(&params, to.fg, 39, 30, 90, 38);
        if (!base.bg.eql(to.bg)) try formatFgBg(&params, to.bg, 49, 40, 100, 48);
        if (!base.underline_color.eql(to.underline_color)) {
            try formatUnderlineColor(&params, to.underline_color);
        }

        try params.finish();
        return params.turned_off;
    }
};

/// A colour of any form, its channels drawn from the whole byte range.
fn randomColor(random: std.Random) Color {
    return switch (random.uintLessThan(u8, 4)) {
        0 => .default,
        1 => .ansi(@enumFromInt(random.uintLessThan(u8, 16))),
        2 => .palette(random.int(u8)),
        else => .rgb(random.int(u8), random.int(u8), random.int(u8)),
    };
}

/// A style with every field drawn independently, so pairs of them turn
/// things on, off, and both at once.
fn randomStyle(random: std.Random) Style {
    return .{
        .fg = randomColor(random),
        .bg = randomColor(random),
        .underline_color = randomColor(random),
        .bold = random.boolean(),
        .dim = random.boolean(),
        .italic = random.boolean(),
        .underline = @enumFromInt(random.uintLessThan(u8, 6)),
        .blink = random.boolean(),
        .reverse = random.boolean(),
        .hidden = random.boolean(),
        .strikethrough = random.boolean(),
        .overline = random.boolean(),
        .script = switch (random.uintLessThan(u8, 3)) {
            0 => .none,
            1 => .superscript,
            else => .subscript,
        },
    };
}

/// Holds one pair to the oracle: the same bytes out, each spelling priced at
/// what the oracle's formatting of it counts, and what went out the shorter
/// of the two.
fn expectSameAsOracle(from: Style, to: Style) !void {
    var expected_buffer: [max_sequence]u8 = undefined;
    var expected: Writer = .fixed(&expected_buffer);
    try oracle.diff(&expected, from, to);

    var actual_buffer: [max_sequence]u8 = undefined;
    var actual: Writer = .fixed(&actual_buffer);
    try diffStyle(&actual, from, to);
    try std.testing.expectEqualStrings(expected.buffered(), actual.buffered());

    for ([_]bool{ false, true }) |reset| {
        var formatted: Writer.Discarding = .init(&.{});
        const oracle_off = try oracle.writeSgr(&formatted.writer, from, to, reset);
        var counted: Price = .{};
        const counted_off = spell(&counted, from, to, reset);
        try std.testing.expectEqual(formatted.fullCount(), @as(u64, counted.len));
        try std.testing.expectEqual(oracle_off, counted_off);

        var spelled: Spelling = .{};
        _ = spell(&spelled, from, to, reset);
        var written_buffer: [2 * max_sequence]u8 = undefined;
        var written: Writer = .fixed(&written_buffer);
        _ = try oracle.writeSgr(&written, from, to, reset);
        try std.testing.expectEqualStrings(written.buffered(), spelled.written());
    }

    var delta: Writer.Discarding = .init(&.{});
    _ = try oracle.writeSgr(&delta.writer, from, to, false);
    var whole: Writer.Discarding = .init(&.{});
    _ = try oracle.writeSgr(&whole.writer, from, to, true);
    const shortest = if (delta.fullCount() == 0) 0 else @min(delta.fullCount(), whole.fullCount());
    try std.testing.expectEqual(shortest, @as(u64, actual.buffered().len));

    // And the price is what went out, to the byte.
    try std.testing.expectEqual(actual.buffered().len, diffStyleLen(from, to));
}

test "the counting encoder writes what the formatting one did, on random pairs" {
    var prng: std.Random.DefaultPrng = .init(0x5e1ec7ed);
    const random = prng.random();
    for (0..20_000) |_| {
        const from = randomStyle(random);
        const to = randomStyle(random);
        try expectSameAsOracle(from, to);
        try expectSameAsOracle(.{}, to);
        try expectSameAsOracle(from, .{});
        try expectSameAsOracle(to, to);
    }
}

test "the counting encoder spells every byte value on every side as the formatting one did" {
    // Every entry of the decimal table, as a palette index and as each
    // channel of a direct colour, on all three sides, from the default and
    // from a style that makes the reset spelling worth pricing.
    const lit: Style = .{ .bold = true, .italic = true, .fg = .ansi(.red) };
    for (0..256) |i| {
        const v: u8 = @intCast(i);
        const colors = [_]Color{
            .palette(v),
            .rgb(v, 0, 0),
            .rgb(0, v, 0),
            .rgb(0, 0, v),
            .rgb(v, v, v),
            .rgb(v, 255 - v, v / 2),
        };
        for (colors) |c| {
            for ([_]Style{ .{ .fg = c }, .{ .bg = c }, .{ .underline_color = c } }) |to| {
                try expectSameAsOracle(.{}, to);
                try expectSameAsOracle(lit, to);
                try expectSameAsOracle(to, lit);
            }
        }
    }
}
