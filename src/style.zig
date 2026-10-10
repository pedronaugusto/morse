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
//! `Color.fit` and `Style.fit` turn a colour into the nearest one a terminal
//! with fewer colours can show: direct colour onto the 256-colour palette,
//! either onto the sixteen theme slots, or any of them onto no colour at all.
//! The conversion is morse's and the decision is not. How many colours a
//! terminal takes is the caller's to find out -- `queryCapability` with `Tc`,
//! `RGB` or `Co` asks, and the environment guesses -- and the caller passes
//! the answer in as a `Color.Profile`. Nothing here asks, reads the
//! environment, or picks a profile on its own.

const std = @import("std");
const aegis = @import("aegis");
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
        return .{ .kind = .ansi, .r = @backingInt(which) };
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
        return @fromBackingInt(@intCast(color.r));
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
        const a_bits: u32 = @bitCast(std.mem.asBytes(&a).*);
        const b_bits: u32 = @bitCast(std.mem.asBytes(&b).*);
        return a_bits == b_bits;
    }

    /// How many colours a terminal shows, which is what `fit` is told.
    /// Ordered poorest first, each one the richest `Kind` it can show.
    pub const Profile = enum(u8) {
        /// No colour at all: every colour becomes `.default`. What
        /// `NO_COLOR` asks for; bold, underline and the other attributes
        /// are not colour and stay.
        none = 0,
        /// The sixteen theme slots, written with their short codes.
        ansi = 1,
        /// The 256-colour palette.
        palette = 2,
        /// Direct colour, `38;2;r;g;b`: every colour as given.
        rgb = 3,
    };

    /// What the sixteen theme slots look like, in slot order: what `fit`
    /// matches a colour against when it has to pick a slot.
    pub const Slots = [16]Rgb;

    /// xterm's own sixteen, which `fit` matches against when the caller does
    /// not know the terminal's. A terminal's theme is the user's and is
    /// rarely these; a caller that asked (`queryPaletteColor`) passes what
    /// the terminal said instead.
    pub const xterm_slots: Slots = .{
        .{ .r = 0x00, .g = 0x00, .b = 0x00 }, .{ .r = 0xcd, .g = 0x00, .b = 0x00 },
        .{ .r = 0x00, .g = 0xcd, .b = 0x00 }, .{ .r = 0xcd, .g = 0xcd, .b = 0x00 },
        .{ .r = 0x00, .g = 0x00, .b = 0xee }, .{ .r = 0xcd, .g = 0x00, .b = 0xcd },
        .{ .r = 0x00, .g = 0xcd, .b = 0xcd }, .{ .r = 0xe5, .g = 0xe5, .b = 0xe5 },
        .{ .r = 0x7f, .g = 0x7f, .b = 0x7f }, .{ .r = 0xff, .g = 0x00, .b = 0x00 },
        .{ .r = 0x00, .g = 0xff, .b = 0x00 }, .{ .r = 0xff, .g = 0xff, .b = 0x00 },
        .{ .r = 0x5c, .g = 0x5c, .b = 0xff }, .{ .r = 0xff, .g = 0x00, .b = 0xff },
        .{ .r = 0x00, .g = 0xff, .b = 0xff }, .{ .r = 0xff, .g = 0xff, .b = 0xff },
    };

    /// The nearest colour a terminal of `profile` shows, in the form it
    /// takes. `slots` is what its sixteen theme slots look like, or null for
    /// `xterm_slots`.
    ///
    /// - `.rgb` changes nothing.
    /// - `.palette` turns direct colour into the nearest entry of the cube
    ///   and the grey ramp, 16-255. Never into one of the sixteen slots:
    ///   they are the user's theme, and a colour the program chose exactly
    ///   should not turn into one that changes when the theme does.
    /// - `.ansi` turns direct colour and the palette above 15 into the
    ///   nearest slot, and a palette index below 16 into the slot it names,
    ///   written with the short code a 16-colour terminal understands.
    /// - `.none` turns every colour into `.default`.
    ///
    /// `.default` stays `.default` in every profile, and a colour already in
    /// a form the profile shows comes back unchanged -- so a program that
    /// picks its own colours for a poorer terminal gets exactly those.
    ///
    /// "Nearest" is the low-cost perceptual distance from
    /// <https://www.compuphase.com/cmetric.htm>, the "redmean" weighting of
    /// the three channels, squared and in integers: the metric and the
    /// lowest-index tie-break anstyle-lossy uses, and the suite holds this
    /// to an exhaustive search under it. termenv picks the cube entry a
    /// channel at a time and compares it with one grey; this considers the
    /// whole ramp, and is never farther.
    pub fn fit(color: Color, profile: Profile, slots: ?*const Slots) Color {
        switch (profile) {
            .rgb => return color,
            .none => return .default,
            .palette => return switch (color.kind) {
                .rgb => .palette(nearestEntry(color.toRgb())),
                else => color,
            },
            .ansi => return switch (color.kind) {
                .default, .ansi => color,
                .palette => .ansi(@fromBackingInt(@intCast(if (color.index() < 16)
                    color.index()
                else if (slots) |s|
                    nearestSlot(paletteRgb(color.index()).?, s)
                else
                    xterm_entry_slots[color.index() - 16]))),
                .rgb => .ansi(@fromBackingInt(@intCast(nearestSlot(color.toRgb(), slots orelse &xterm_slots)))),
            },
        }
    }
};

/// How far apart two colours look, in the units `Color.fit` compares: the
/// "redmean" approximation from <https://www.compuphase.com/cmetric.htm>,
/// without the square root. The weights of red and blue move with how red
/// the pair is, which is most of what a plain RGB distance gets wrong.
fn distance(a: Rgb, b: Rgb) u32 {
    const red_sum = @as(i32, a.r) + b.r;
    const dr = @as(i32, a.r) - b.r;
    const dg = @as(i32, a.g) - b.g;
    const db = @as(i32, a.b) - b.b;
    return @intCast((1024 + red_sum) * dr * dr + 1024 * dg * dg + (1534 - red_sum) * db * db);
}

/// The six levels of a cube channel.
const cube_levels = [6]u8{ 0, 95, 135, 175, 215, 255 };

/// The cube level nearest `v`, the lower one when two are as near.
fn cubeLevel(v: u8) u8 {
    if (v < 48) return 0;
    if (v <= 115) return 1;
    if (v <= 155) return 2;
    if (v <= 195) return 3;
    if (v <= 235) return 4;
    return 5;
}

/// The palette entry, 16-255, nearest `color`; the lowest index of several
/// as near.
///
/// The green term of the distance has a fixed weight and the blue term's
/// weight depends only on the two reds, so for any one red level of the cube
/// the nearest green and blue levels are the nearest a channel at a time.
/// That leaves six cube entries to compare, not 216, and then the 24 greys.
fn nearestEntry(color: Rgb) u8 {
    const g = cubeLevel(color.g);
    const b = cubeLevel(color.b);
    var best: u8 = 0;
    var best_distance: u32 = std.math.maxInt(u32);
    for (cube_levels, 0..) |level, r| {
        const d = distance(color, .{ .r = level, .g = cube_levels[g], .b = cube_levels[b] });
        if (d < best_distance) {
            best_distance = d;
            best = @intCast(16 + 36 * r + 6 * g + b);
        }
    }
    // Against a grey `v` the distance is a quadratic in `v` that opens
    // upward -- the cubic terms of red and blue cancel -- so the nearest
    // grey is on one side or the other of its lowest point, and three greys
    // around it are all that need comparing, in index order.
    const r: i64 = color.r;
    const gc: i64 = color.g;
    const bc: i64 = color.b;
    const a = 3582 - 2 * r + 2 * bc;
    const minus_b = 2048 * r + r * r + 2048 * gc + 3068 * bc - 2 * r * bc + bc * bc;
    // The lowest point is at minus_b / (2a); the grey below it is
    // (point - 8) / 10, floored.
    const below = @divFloor(minus_b - 16 * a, 20 * a);
    const first: usize = @intCast(std.math.clamp(below - 1, 0, 21));
    for (first..first + 3) |i| {
        const level: u8 = @intCast(8 + 10 * i);
        const d = distance(color, .{ .r = level, .g = level, .b = level });
        if (d < best_distance) {
            best_distance = d;
            best = @intCast(232 + i);
        }
    }
    return best;
}

/// The slot nearest `color`; the lowest of several as near.
fn nearestSlot(color: Rgb, slots: *const Color.Slots) u8 {
    var best: u8 = 0;
    var best_distance: u32 = std.math.maxInt(u32);
    for (slots, 0..) |slot, i| {
        const d = distance(color, slot);
        if (d < best_distance) {
            best_distance = d;
            best = @intCast(i);
        }
    }
    return best;
}

/// The xterm slot nearest each palette entry above 15, worked out once.
const xterm_entry_slots: [240]u8 = blk: {
    @setEvalBranchQuota(100_000);
    var table: [240]u8 = undefined;
    for (&table, 16..) |*slot, i| slot.* = nearestSlot(paletteRgb(i).?, &Color.xterm_slots);
    break :blk table;
};

/// The colour entry `index` of the 256-colour palette is above the sixteen
/// theme slots, as terminals define it: the 6x6x6 cube at 16-231, its six
/// levels 0, 95, 135, 175, 215 and 255 a channel with red the slowest to
/// change, and the twenty-four greys at 232-255, from 8 in steps of 10.
///
/// Null for 0-15, which are the theme's slots: what they look like is the
/// user's choice, and the terminal says what it chose when asked
/// (`queryPaletteColor`). A program may redefine the upper entries too, and
/// almost none does; this is the palette a terminal starts with.
pub fn paletteRgb(index: u8) ?Rgb {
    if (index < 16) return null;
    if (index >= 232) {
        const level: u8 = 8 + 10 * (index - 232);
        return .{ .r = level, .g = level, .b = level };
    }
    const cube = index - 16;
    const levels = [6]u8{ 0, 95, 135, 175, 215, 255 };
    return .{ .r = levels[cube / 36], .g = levels[cube / 6 % 6], .b = levels[cube % 6] };
}

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

    /// The style with its three colours fitted to `profile`, as
    /// `Color.fit` fits one. Everything that is not a colour stays, so under
    /// `.none` bold is still bold and an underline still underlines.
    pub fn fit(style: Style, profile: Color.Profile, slots: ?*const Color.Slots) Style {
        var out = style;
        out.fg = style.fg.fit(profile, slots);
        out.bg = style.bg.fit(profile, slots);
        out.underline_color = style.underline_color.fit(profile, slots);
        return out;
    }
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
    for (@typeInfo(Style).@"struct".field_types) |T| total += @sizeOf(T);
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
    try w.writeAll(reset_sequence);
}

/// `CSI 0 m`, which `resetStyle` writes and `cost.resetStyle` counts.
const reset_sequence = seq.csi ++ "0m";

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
/// the difference, which touches least. `cost.diffStyle` says how many bytes
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

/// How many bytes the style writers write, given the same arguments less
/// the writer, without writing them.
pub const cost = struct {
    /// How many bytes `diffStyle(w, from, to)` writes: zero when the two
    /// styles are equal, otherwise the length of the one `CSI ... m` it
    /// would send, `CSI` and `m` included.
    ///
    /// Exact, not an estimate. It counts through the same encoder
    /// `diffStyle` spells with and makes the same choice between the
    /// difference and the reset spelling, so for every pair the two agree,
    /// and a change to how a style is spelled moves both. That is what a
    /// renderer weighing a style change against some other way of drawing
    /// the same cells wants: the length of the move it would actually make,
    /// from the code that would make it.
    pub fn diffStyle(from: Style, to: Style) usize {
        // Equal styles are the case a renderer asks about most, and a byte
        // comparison answers it without walking the fields. `Style` has no
        // padding, so equal bytes are equal styles and the diff is empty.
        if (std.mem.eql(u8, std.mem.asBytes(&from), std.mem.asBytes(&to))) return 0;
        var difference: Price = .{};
        const turned_off = spell(&difference, from, to, false);
        return shorterReset(from, to, difference.len, turned_off) orelse difference.len;
    }

    /// `setStyle`, which is `diffStyle` from the default style.
    pub fn setStyle(style: Style) usize {
        return cost.diffStyle(.{}, style);
    }

    /// `resetStyle`.
    pub fn resetStyle() usize {
        return reset_sequence.len;
    }
};

/// Applies the parameters of one `CSI ... m` to `style`, the way a terminal
/// does: the bytes between the `CSI` and the `m`, read as `diffStyle` writes
/// them and as terminals take them.
///
/// The inverse of `diffStyle`. Whatever `diffStyle(w, from, to)` writes,
/// applied here to `from`, gives `to` -- with one exception that is in the
/// bytes, not the reading: SGR 58 spells an `.ansi` underline colour and a
/// `.palette` one of the same index alike, so that colour comes back as
/// `.palette`. The suite holds the two to that over random pairs of styles.
///
/// Read beyond what this package writes, as a terminal reads it: parameters
/// are separated by `;` and a parameter's sub-parameters by `:`, an empty
/// parameter is `0`, and an empty list is `0` too, so `CSI m` resets.
/// Extended colours are read in both spellings, `38;5;n` and `38:5:n`,
/// `38;2;r;g;b`, `38:2:r:g:b` and `38:2::r:g:b`, for all three of `38`, `48`
/// and `58`; an extended colour cut short or out of range changes nothing
/// and takes the fields it had. A code this package does not know is passed
/// over.
pub fn applySgr(style: *Style, params: []const u8) void {
    var fields = std.mem.splitScalar(u8, params, ';');
    while (fields.next()) |field| {
        var subs = std.mem.splitScalar(u8, field, ':');
        const code = sgrNumber(subs.first()) orelse continue;
        switch (code) {
            38, 48, 58 => {
                const color = if (subs.peek() != null) colonColor(&subs) else semicolonColor(&fields);
                if (color) |c| switch (code) {
                    38 => style.fg = c,
                    48 => style.bg = c,
                    else => style.underline_color = c,
                };
            },
            4 => style.underline = if (subs.next()) |sub| underlineOf(sub) else .single,
            else => applyCode(style, code),
        }
    }
}

/// Every SGR code that is one attribute or one named colour on its own.
fn applyCode(style: *Style, code: u32) void {
    switch (code) {
        0 => style.* = .{},
        1 => style.bold = true,
        2 => style.dim = true,
        3 => style.italic = true,
        5 => style.blink = true,
        7 => style.reverse = true,
        8 => style.hidden = true,
        9 => style.strikethrough = true,
        22 => {
            style.bold = false;
            style.dim = false;
        },
        23 => style.italic = false,
        24 => style.underline = .none,
        25 => style.blink = false,
        27 => style.reverse = false,
        28 => style.hidden = false,
        29 => style.strikethrough = false,
        30...37 => style.fg = .ansi(@fromBackingInt(@intCast(code - 30))),
        39 => style.fg = .default,
        40...47 => style.bg = .ansi(@fromBackingInt(@intCast(code - 40))),
        49 => style.bg = .default,
        53 => style.overline = true,
        55 => style.overline = false,
        59 => style.underline_color = .default,
        73 => style.script = .superscript,
        74 => style.script = .subscript,
        75 => style.script = .none,
        90...97 => style.fg = .ansi(@fromBackingInt(@intCast(code - 90 + 8))),
        100...107 => style.bg = .ansi(@fromBackingInt(@intCast(code - 100 + 8))),
        else => {},
    }
}

/// A parameter as SGR reads it: digits, or nothing, which is zero. Null for
/// anything else, and for a number too large to be a code.
fn sgrNumber(field: []const u8) ?u32 {
    if (field.len == 0) return 0;
    const scanned = seq.scanInt(u32, field) orelse return null;
    return if (scanned.len == field.len) scanned.value else null;
}

/// The same, for a value that has to fit in a byte: a channel or an index.
fn sgrByte(field: []const u8) ?u8 {
    return aegis.int.cast(u8, sgrNumber(field) orelse return null) catch null;
}

/// The underline a `4:n` names. A style past the five SGR numbers is drawn
/// by terminals as the plain one, so it reads as that.
fn underlineOf(sub: []const u8) Underline {
    const n = sgrNumber(sub) orelse return .single;
    return if (n <= 5) @fromBackingInt(@intCast(n)) else .single;
}

/// The colon spelling of an extended colour, from the sub-parameters after
/// the `38`, `48` or `58`: `5:n`, `2:r:g:b`, or `2::r:g:b` with the colour
/// space left empty.
fn colonColor(subs: *std.mem.SplitIterator(u8, .scalar)) ?Color {
    switch (sgrNumber(subs.next() orelse return null) orelse return null) {
        5 => return .palette(sgrByte(subs.next() orelse return null) orelse return null),
        2 => {
            var channels: [4][]const u8 = undefined;
            var count: usize = 0;
            while (subs.next()) |sub| : (count += 1) {
                if (count == channels.len) return null;
                channels[count] = sub;
            }
            // Four fields are the colour space and the three channels; three
            // are the channels alone.
            const rgb = switch (count) {
                3 => channels[0..3],
                4 => channels[1..4],
                else => return null,
            };
            return .rgb(
                sgrByte(rgb[0]) orelse return null,
                sgrByte(rgb[1]) orelse return null,
                sgrByte(rgb[2]) orelse return null,
            );
        },
        else => return null,
    }
}

/// The semicolon spelling, from the parameters after the `38`, `48` or `58`:
/// `5;n` or `2;r;g;b`. Takes the fields it reads, as terminals do.
fn semicolonColor(fields: *std.mem.SplitIterator(u8, .scalar)) ?Color {
    switch (sgrNumber(fields.next() orelse return null) orelse return null) {
        5 => return .palette(sgrByte(fields.next() orelse return null) orelse return null),
        2 => {
            const r = sgrByte(fields.next() orelse return null);
            const g = sgrByte(fields.next() orelse return null);
            const b = sgrByte(fields.next() orelse return null);
            return .rgb(r orelse return null, g orelse return null, b orelse return null);
        },
        else => return null,
    }
}

/// The length of the reset spelling of `from` to `to` when it is strictly
/// shorter than a difference of `difference` bytes, and null when the
/// difference is what goes out. The one place `diffStyle` and `cost.diffStyle`
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
            params.number(@backingInt(to.underline));
        }
    }
    if (to.blink and !base.blink) params.code(5);
    if (to.reverse and !base.reverse) params.code(7);
    if (to.hidden and !base.hidden) params.code(8);
    if (to.strikethrough and !base.strikethrough) params.code(9);
    if (to.overline and !base.overline) params.code(53);
    if (to.script != base.script and to.script != .none) {
        params.code(@backingInt(to.script));
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

test "cost.diffStyle is the length diffStyle writes" {
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
        try std.testing.expectEqual(case.len, cost.diffStyle(case.from, case.to));
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
            try std.testing.expectEqual(w.buffered().len, cost.diffStyle(pair[0], pair[1]));
        }
        var w: Writer = .fixed(&buffer);
        try setStyle(&w, to);
        try std.testing.expectEqual(w.buffered().len, cost.setStyle(to));
    }

    var w: Writer = .fixed(&buffer);
    try resetStyle(&w);
    try std.testing.expectEqual(w.buffered().len, cost.resetStyle());
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
    const everything: Style = .{
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
    inline for (@typeInfo(Style).@"struct".field_types) |T| total += @sizeOf(T);
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
        const slot: Ansi = @fromBackingInt(@intCast(i));
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
        colors[n] = .ansi(@fromBackingInt(@intCast(i)));
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

    // The comparison runs at comptime, like the constructors it compares.
    comptime std.debug.assert(Color.rgb(1, 2, 3).eql(Color.rgb(1, 2, 3)));
    comptime std.debug.assert(!Color.ansi(.red).eql(Color.palette(1)));
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

/// The selection code of two libraries that do what `Color.fit` does, ported
/// from their source as oracles: anstyle-lossy 1.1.4 (Rust) and termenv
/// (Go, `hexToANSI256Color`). Ported rather than run, so the suite needs
/// neither toolchain; each function names the code it follows.
const fit_oracle = struct {
    /// anstyle-lossy's `distance`, verbatim.
    fn lossyDistance(c1: Rgb, c2: Rgb) u32 {
        const r_sum = @as(i32, c1.r) + @as(i32, c2.r);
        const r_delta = @as(i32, c1.r) - @as(i32, c2.r);
        const g_delta = @as(i32, c1.g) - @as(i32, c2.g);
        const b_delta = @as(i32, c1.b) - @as(i32, c2.b);
        const r = (2 * 512 + r_sum) * r_delta * r_delta;
        const g = 4 * g_delta * g_delta * (1 << 8);
        const b = (2 * 767 - r_sum) * b_delta * b_delta;
        return @intCast(r + g + b);
    }

    /// anstyle-lossy's `XTERM_COLORS` above the placeholders, spelled out
    /// rather than taken from `paletteRgb`.
    fn xtermColor(index: u8) Rgb {
        if (index >= 232) {
            const v: u8 = 8 + 10 * (index - 232);
            return .{ .r = v, .g = v, .b = v };
        }
        const levels = [6]u8{ 0, 95, 135, 175, 215, 255 };
        const i = index - 16;
        return .{ .r = levels[i / 36], .g = levels[(i / 6) % 6], .b = levels[i % 6] };
    }

    /// anstyle-lossy's `find_xterm_match`: every entry from 16 up, the first
    /// strictly nearest kept.
    fn lossyXterm(color: Rgb) u8 {
        var best_index: u16 = 16;
        var best_distance = lossyDistance(color, xtermColor(16));
        var index: u16 = best_index + 1;
        while (index < 256) : (index += 1) {
            const d = lossyDistance(color, xtermColor(@intCast(index)));
            if (d < best_distance) {
                best_index = index;
                best_distance = d;
            }
        }
        return @intCast(best_index);
    }

    /// anstyle-lossy's `Palette::find_match`.
    fn lossyAnsi(color: Rgb, palette: *const Color.Slots) u8 {
        var best_index: usize = 0;
        var best_distance = lossyDistance(color, palette[0]);
        for (palette[1..], 1..) |entry, index| {
            const d = lossyDistance(color, entry);
            if (d < best_distance) {
                best_index = index;
                best_distance = d;
            }
        }
        return @intCast(best_index);
    }

    /// termenv's two candidates from `hexToANSI256Color`: the cube entry
    /// picked a channel at a time by `v2ci`, and the grey its `grayIdx`
    /// arithmetic names. termenv then keeps the nearer under HSLuv; the
    /// suite asks only that `fit` is never farther than either.
    fn termenvCandidates(color: Rgb) [2]u8 {
        const v2ci = struct {
            fn f(v: i32) i32 {
                if (v < 48) return 0;
                if (v < 115) return 1;
                return @divTrunc(v - 35, 40);
            }
        }.f;
        const r = v2ci(color.r);
        const g = v2ci(color.g);
        const b = v2ci(color.b);
        const ci = 36 * r + 6 * g + b;
        // termenv averages the cube indices, not the channels, so this is
        // always the darkest grey; ported as written.
        const average = @divTrunc(r + g + b, 3);
        const gray_idx: i32 = if (average > 238) 23 else @divTrunc(average - 3, 10);
        return .{ @intCast(16 + ci), @intCast(232 + gray_idx) };
    }

    /// anstyle-lossy's `palette::VGA`.
    const vga: Color.Slots = .{
        .{ .r = 0, .g = 0, .b = 0 },      .{ .r = 170, .g = 0, .b = 0 },
        .{ .r = 0, .g = 170, .b = 0 },    .{ .r = 170, .g = 85, .b = 0 },
        .{ .r = 0, .g = 0, .b = 170 },    .{ .r = 170, .g = 0, .b = 170 },
        .{ .r = 0, .g = 170, .b = 170 },  .{ .r = 170, .g = 170, .b = 170 },
        .{ .r = 85, .g = 85, .b = 85 },   .{ .r = 255, .g = 85, .b = 85 },
        .{ .r = 85, .g = 255, .b = 85 },  .{ .r = 255, .g = 255, .b = 85 },
        .{ .r = 85, .g = 85, .b = 255 },  .{ .r = 255, .g = 85, .b = 255 },
        .{ .r = 85, .g = 255, .b = 255 }, .{ .r = 255, .g = 255, .b = 255 },
    };

    /// A dark theme's slots (Catppuccin Mocha), the kind a terminal reports.
    const mocha: Color.Slots = .{
        .{ .r = 0x45, .g = 0x47, .b = 0x5a }, .{ .r = 0xf3, .g = 0x8b, .b = 0xa8 },
        .{ .r = 0xa6, .g = 0xe3, .b = 0xa1 }, .{ .r = 0xf9, .g = 0xe2, .b = 0xaf },
        .{ .r = 0x89, .g = 0xb4, .b = 0xfa }, .{ .r = 0xf5, .g = 0xc2, .b = 0xe7 },
        .{ .r = 0x94, .g = 0xe2, .b = 0xd5 }, .{ .r = 0xba, .g = 0xc2, .b = 0xde },
        .{ .r = 0x58, .g = 0x5b, .b = 0x70 }, .{ .r = 0xf3, .g = 0x8b, .b = 0xa8 },
        .{ .r = 0xa6, .g = 0xe3, .b = 0xa1 }, .{ .r = 0xf9, .g = 0xe2, .b = 0xaf },
        .{ .r = 0x89, .g = 0xb4, .b = 0xfa }, .{ .r = 0xf5, .g = 0xc2, .b = 0xe7 },
        .{ .r = 0x94, .g = 0xe2, .b = 0xd5 }, .{ .r = 0xa6, .g = 0xad, .b = 0xc8 },
    };

    /// The corpus: a 16-step grid of the cube of all colours, every grey and
    /// every pure ramp, each palette entry's own colour, and seeded random
    /// colours. Calls `check` on each.
    fn each(comptime check: anytype, context: anytype) !void {
        var r: u16 = 0;
        while (r < 256) : (r += 17) {
            var g: u16 = 0;
            while (g < 256) : (g += 17) {
                var b: u16 = 0;
                while (b < 256) : (b += 17) try check(context, .{ .r = @intCast(r), .g = @intCast(g), .b = @intCast(b) });
            }
        }
        for (0..256) |i| {
            const v: u8 = @intCast(i);
            try check(context, .{ .r = v, .g = v, .b = v });
            try check(context, .{ .r = v, .g = 0, .b = 0 });
            try check(context, .{ .r = 0, .g = v, .b = 0 });
            try check(context, .{ .r = 0, .g = 0, .b = v });
        }
        for (16..256) |i| try check(context, xtermColor(@intCast(i)));
        var prng: std.Random.DefaultPrng = .init(0x5eed_c0102);
        const random = prng.random();
        for (0..20_000) |_| try check(context, .{ .r = random.int(u8), .g = random.int(u8), .b = random.int(u8) });
    }
};

test "fit picks the palette entry and the slot anstyle-lossy picks, on the corpus" {
    const Check = struct {
        fn f(_: void, c: Rgb) anyerror!void {
            const color: Color = .fromRgb(c);
            try std.testing.expectEqual(fit_oracle.lossyXterm(c), color.fit(.palette, null).index());
            try std.testing.expectEqual(fit_oracle.lossyAnsi(c, &Color.xterm_slots), color.fit(.ansi, null).index());
            try std.testing.expectEqual(fit_oracle.lossyAnsi(c, &fit_oracle.vga), color.fit(.ansi, &fit_oracle.vga).index());
            try std.testing.expectEqual(fit_oracle.lossyAnsi(c, &fit_oracle.mocha), color.fit(.ansi, &fit_oracle.mocha).index());
        }
    };
    try fit_oracle.each(Check.f, {});

    // The palette above the slots onto the slots: anstyle-lossy's
    // `xterm_to_ansi`, the entry's colour matched like any other.
    for (16..256) |i| {
        const entry: Color = .palette(@intCast(i));
        const rgb = fit_oracle.xtermColor(@intCast(i));
        try std.testing.expectEqual(fit_oracle.lossyAnsi(rgb, &Color.xterm_slots), entry.fit(.ansi, null).index());
        try std.testing.expectEqual(fit_oracle.lossyAnsi(rgb, &fit_oracle.vga), entry.fit(.ansi, &fit_oracle.vga).index());
        // And each entry is the nearest entry to its own colour.
        try std.testing.expectEqual(@as(u8, @intCast(i)), Color.fromRgb(rgb).fit(.palette, null).index());
    }
}

test "fit is never farther than either entry termenv weighs, on the corpus" {
    const Check = struct {
        fn f(_: void, c: Rgb) anyerror!void {
            const ours = fit_oracle.lossyDistance(c, fit_oracle.xtermColor(Color.fromRgb(c).fit(.palette, null).index()));
            for (fit_oracle.termenvCandidates(c)) |theirs| {
                try std.testing.expect(ours <= fit_oracle.lossyDistance(c, fit_oracle.xtermColor(theirs)));
            }
        }
    };
    try fit_oracle.each(Check.f, {});
}

test "fit writes each colour in the form the profile shows" {
    const orange: Color = .rgb(255, 128, 0);
    try std.testing.expectEqual(orange, orange.fit(.rgb, null));
    try std.testing.expectEqual(Color.palette(208), orange.fit(.palette, null));
    try std.testing.expectEqual(Color.palette(244), Color.rgb(128, 128, 128).fit(.palette, null));
    try std.testing.expectEqual(Color.ansi(.blue), Color.rgb(0, 0, 0x80).fit(.ansi, null));
    try std.testing.expectEqual(Color.default, orange.fit(.none, null));

    // A palette index below 16 names a slot and takes its short code; one
    // above is matched like direct colour.
    try std.testing.expectEqual(Color.ansi(.bright_red), Color.palette(9).fit(.ansi, null));
    try std.testing.expectEqual(Color.ansi(.bright_red), Color.palette(196).fit(.ansi, null));

    // What the terminal said its slots look like decides the slot.
    try std.testing.expectEqual(Color.ansi(.red), Color.rgb(240, 140, 170).fit(.ansi, &fit_oracle.mocha));

    // A colour already in a form the profile shows comes back as it was,
    // which is how a program's own colours for a poorer terminal survive.
    for ([_]Color.Profile{ .ansi, .palette, .rgb }) |profile| {
        try std.testing.expectEqual(Color.default, Color.default.fit(profile, null));
        try std.testing.expectEqual(Color.ansi(.magenta), Color.ansi(.magenta).fit(profile, &fit_oracle.mocha));
    }
    try std.testing.expectEqual(Color.palette(5), Color.palette(5).fit(.palette, null));
    try std.testing.expectEqual(Color.palette(200), Color.palette(200).fit(.palette, null));
    try std.testing.expectEqual(Color.default, Color.ansi(.red).fit(.none, null));
    try std.testing.expectEqual(Color.default, Color.palette(200).fit(.none, null));
}

test "fitting twice is fitting once, and the result is canonical" {
    const Check = struct {
        fn f(_: void, c: Rgb) anyerror!void {
            for ([_]Color.Profile{ .none, .ansi, .palette, .rgb }) |profile| {
                const once = Color.fromRgb(c).fit(profile, &fit_oracle.mocha);
                try std.testing.expectEqual(once, once.fit(profile, &fit_oracle.mocha));
                try std.testing.expect(@backingInt(once.kind) <= @backingInt(profile));
                // The same four bytes a constructor would have made.
                const remade: Color = switch (once.kind) {
                    .default => .default,
                    .ansi => .ansi(once.toAnsi()),
                    .palette => .palette(once.index()),
                    .rgb => .fromRgb(once.toRgb()),
                };
                try std.testing.expect(once.eql(remade));
            }
        }
    };
    try fit_oracle.each(Check.f, {});
}

test "no colour keeps the attributes" {
    const style: Style = .{
        .fg = .rgb(255, 128, 0),
        .bg = .palette(17),
        .underline_color = .ansi(.red),
        .bold = true,
        .italic = true,
        .underline = .curly,
        .reverse = true,
        .strikethrough = true,
    };
    var expected = style;
    expected.fg = .default;
    expected.bg = .default;
    expected.underline_color = .default;
    try std.testing.expectEqual(expected, style.fit(.none, null));

    const sixteen = style.fit(.ansi, null);
    try std.testing.expectEqual(Color.ansi(.yellow), sixteen.fg);
    try std.testing.expectEqual(Color.ansi(.black), sixteen.bg);
    try std.testing.expectEqual(Color.ansi(.red), sixteen.underline_color);
    try std.testing.expect(sixteen.bold and sixteen.italic and sixteen.reverse);

    // And the fitted style writes the codes a 16-colour terminal reads.
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try setStyle(&w, (Style{ .fg = style.fg, .bg = style.bg }).fit(.ansi, null));
    try std.testing.expectEqualStrings("\x1b[33;40m", w.buffered());
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
        const turned_off = writeSgr(&delta.writer, from, to, false) catch unreachable; // unreachable: Discarding accepts and counts every byte without a failing drain
        const difference = delta.fullCount();
        std.debug.assert(difference <= max_sequence);
        if (difference == 0) return;
        if (!turned_off) {
            _ = try writeSgr(w, from, to, false);
            return;
        }
        var whole: Writer.Discarding = .init(&scratch);
        _ = writeSgr(&whole.writer, from, to, true) catch unreachable; // unreachable: Discarding accepts and counts every byte without a failing drain
        std.debug.assert(whole.fullCount() <= max_sequence);
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
                try seq.writeInt(w, @backingInt(to.underline));
            }
        }
        if (to.blink and !base.blink) try params.code(5);
        if (to.reverse and !base.reverse) try params.code(7);
        if (to.hidden and !base.hidden) try params.code(8);
        if (to.strikethrough and !base.strikethrough) try params.code(9);
        if (to.overline and !base.overline) try params.code(53);
        if (to.script != base.script and to.script != .none) {
            try params.code(@backingInt(to.script));
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
        1 => .ansi(@fromBackingInt(@intCast(random.uintLessThan(u8, 16)))),
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
        .underline = @fromBackingInt(@intCast(random.uintLessThan(u8, 6))),
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
    try std.testing.expectEqual(actual.buffered().len, cost.diffStyle(from, to));
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

/// A style with an `.ansi` underline colour as the `.palette` entry SGR 58
/// spells it as: the one difference the bytes cannot carry, so styles that
/// differ only there are the same style to anything reading them back.
fn asSpelled(style: Style) Style {
    var out = style;
    if (out.underline_color.kind == .ansi) out.underline_color = .palette(out.underline_color.index());
    return out;
}

/// Applies what `diffStyle(from, to)` writes to `from`: the parameters
/// between the `CSI` and the `m`, or nothing when it writes nothing.
fn readBack(from: Style, to: Style) !Style {
    var buffer: [max_sequence]u8 = undefined;
    var out: Writer = .fixed(&buffer);
    try diffStyle(&out, from, to);
    var got = from;
    const written = out.buffered();
    if (written.len == 0) return got;
    try std.testing.expect(std.mem.startsWith(u8, written, seq.csi) and std.mem.endsWith(u8, written, "m"));
    applySgr(&got, written[seq.csi.len .. written.len - 1]);
    return got;
}

test "applySgr undoes what diffStyle writes, on random pairs of styles" {
    var prng: std.Random.DefaultPrng = .init(0x5a5a);
    const random = prng.random();
    for (0..20_000) |_| {
        const from = randomStyle(random);
        const to = randomStyle(random);
        try std.testing.expectEqual(asSpelled(to), asSpelled(try readBack(from, to)));
        try std.testing.expectEqual(asSpelled(to), asSpelled(try readBack(.{}, to)));
        try std.testing.expectEqual(Style{}, try readBack(to, .{}));
    }
}

test "applySgr reads every script and overline move back" {
    const styles = [_]Style{
        .{},
        .{ .script = .superscript },
        .{ .script = .subscript },
        .{ .overline = true, .script = .subscript, .bold = true },
        .{ .overline = true },
    };
    for (styles) |from| for (styles) |to| {
        try std.testing.expectEqual(to, try readBack(from, to));
    };
}

test "applySgr reads both spellings of every extended colour on all three sides" {
    const cases = [_]struct { params: []const u8, want: Style }{
        .{ .params = "38;5;196", .want = .{ .fg = .palette(196) } },
        .{ .params = "38:5:196", .want = .{ .fg = .palette(196) } },
        .{ .params = "48;2;1;2;3", .want = .{ .bg = .rgb(1, 2, 3) } },
        .{ .params = "48:2:1:2:3", .want = .{ .bg = .rgb(1, 2, 3) } },
        .{ .params = "48:2::1:2:3", .want = .{ .bg = .rgb(1, 2, 3) } },
        .{ .params = "58:5:9", .want = .{ .underline_color = .palette(9) } },
        .{ .params = "58;2;9;8;7", .want = .{ .underline_color = .rgb(9, 8, 7) } },
        .{ .params = "58:2::9:8:7", .want = .{ .underline_color = .rgb(9, 8, 7) } },
        .{ .params = "31;38;5;2;1", .want = .{ .fg = .palette(2), .bold = true } },
    };
    for (cases) |case| {
        var got: Style = .{};
        applySgr(&got, case.params);
        try std.testing.expectEqual(case.want, got);
    }
}

test "applySgr reads an empty list and an empty parameter as a reset" {
    const on: Style = .{ .bold = true, .fg = .ansi(.red), .script = .superscript };
    var got = on;
    applySgr(&got, "");
    try std.testing.expectEqual(Style{}, got);
    got = on;
    applySgr(&got, "3;;9");
    try std.testing.expectEqual(Style{ .strikethrough = true }, got);
}

test "applySgr passes over what it does not know and what does not fit" {
    var got: Style = .{};
    applySgr(&got, "1;6;21;60;x;99999999999;38;5;300;3");
    try std.testing.expectEqual(Style{ .bold = true, .italic = true }, got);
    got = .{ .fg = .ansi(.green) };
    applySgr(&got, "38;2;1;2");
    try std.testing.expectEqual(Style{ .fg = .ansi(.green) }, got);
    got = .{};
    applySgr(&got, "4:9;48:7:1");
    try std.testing.expectEqual(Style{ .underline = .single }, got);
    applySgr(&got, "4:0");
    try std.testing.expectEqual(Style{}, got);
}

test "paletteRgb gives the cube and the grey ramp, and leaves the theme's slots alone" {
    for (0..16) |i| try std.testing.expectEqual(@as(?Rgb, null), paletteRgb(@intCast(i)));
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, paletteRgb(16).?);
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 95 }, paletteRgb(17).?);
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 95, .b = 0 }, paletteRgb(22).?);
    try std.testing.expectEqual(Rgb{ .r = 95, .g = 0, .b = 0 }, paletteRgb(52).?);
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, paletteRgb(196).?);
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 135, .b = 0 }, paletteRgb(208).?);
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, paletteRgb(231).?);
    try std.testing.expectEqual(Rgb{ .r = 8, .g = 8, .b = 8 }, paletteRgb(232).?);
    try std.testing.expectEqual(Rgb{ .r = 238, .g = 238, .b = 238 }, paletteRgb(255).?);
}
