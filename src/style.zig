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
pub const Rgb = struct {
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
pub const Color = union(enum) {
    /// The terminal's own colour for whichever side this is used on:
    /// foreground, background, or underline.
    default,
    /// One of the sixteen theme colours, written with its own short code.
    ansi: Ansi,
    /// An entry in the 256-colour palette: the sixteen theme colours at 0-15,
    /// a 6x6x6 colour cube at 16-231, and 24 greys at 232-255. Written
    /// `38;5;n`.
    palette: u8,
    /// A colour the terminal does not get to reinterpret, written
    /// `38;2;r;g;b`. A terminal without direct colour support approximates it
    /// from its palette, so this is never wrong to send, only sometimes
    /// rounded.
    rgb: Rgb,
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
pub const Style = struct {
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
};

/// One `CSI ... m` being built up, parameter by parameter.
///
/// The `CSI` is written with the first parameter rather than up front,
/// because a diff of two equal styles must write no bytes at all.
const Params = struct {
    w: *Writer,
    /// Whether a parameter has been written, which is also whether the `CSI`
    /// has been.
    any: bool = false,

    /// Opens the sequence on the first parameter and separates every one
    /// after it.
    fn open(p: *Params) Writer.Error!void {
        if (p.any) return p.w.writeByte(';');
        try p.w.writeAll(seq.csi);
        p.any = true;
    }

    /// Writes one plain numeric parameter.
    fn code(p: *Params, value: u8) Writer.Error!void {
        try p.open();
        try p.w.print("{d}", .{value});
    }

    /// Writes one parameter that has fields of its own.
    fn compound(p: *Params, comptime fmt: []const u8, args: anytype) Writer.Error!void {
        try p.open();
        try p.w.print(fmt, args);
    }

    /// Ends the sequence, or writes nothing when no parameter was produced.
    ///
    /// Nothing, rather than `CSI m`: a terminal reads an empty parameter list
    /// as `0`, so the tidy-looking empty sequence would reset the very
    /// attributes the diff found no reason to touch.
    fn finish(p: *Params) Writer.Error!void {
        if (p.any) try p.w.writeByte('m');
    }
};

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
    p: *Params,
    color: Color,
    default_code: u8,
    base: u8,
    bright_base: u8,
    extended: u8,
) Writer.Error!void {
    switch (color) {
        .default => try p.code(default_code),
        .ansi => |a| {
            const index = @intFromEnum(a);
            try p.code(if (index < 8) base + index else bright_base + (index - 8));
        },
        .palette => |n| try p.compound("{d};5;{d}", .{ extended, n }),
        .rgb => |c| try p.compound("{d};2;{d};{d};{d}", .{ extended, c.r, c.g, c.b }),
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
fn writeUnderlineColor(p: *Params, color: Color) Writer.Error!void {
    switch (color) {
        .default => try p.code(59),
        .ansi => |a| try p.compound("58:5:{d}", .{@intFromEnum(a)}),
        .palette => |n| try p.compound("58:5:{d}", .{n}),
        .rgb => |c| try p.compound("58:2::{d}:{d}:{d}", .{ c.r, c.g, c.b }),
    }
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
pub fn diffStyle(w: *Writer, from: Style, to: Style) Writer.Error!void {
    var params: Params = .{ .w = w };

    // The off codes come first so that SGR 22, which turns off bold and dim
    // together, cannot undo an on code written in the same sequence.
    const off_bold_dim = (from.bold and !to.bold) or (from.dim and !to.dim);
    if (off_bold_dim) try params.code(22);
    if (from.italic and !to.italic) try params.code(23);
    if (from.underline != .none and to.underline == .none) try params.code(24);
    if (from.blink and !to.blink) try params.code(25);
    if (from.reverse and !to.reverse) try params.code(27);
    if (from.hidden and !to.hidden) try params.code(28);
    if (from.strikethrough and !to.strikethrough) try params.code(29);

    // Hence the `or off_bold_dim`: turning one of the pair off has just
    // turned the other off too, so the survivor is stated again.
    if (to.bold and (!from.bold or off_bold_dim)) try params.code(1);
    if (to.dim and (!from.dim or off_bold_dim)) try params.code(2);
    if (to.italic and !from.italic) try params.code(3);
    if (to.underline != from.underline and to.underline != .none) {
        if (to.underline == .single) {
            // Bare `4`, not `4:1`. The plain underline predates the
            // sub-parameter form by decades and terminals that have never
            // heard of `4:1` still draw it.
            try params.code(4);
        } else {
            try params.compound("4:{d}", .{@intFromEnum(to.underline)});
        }
    }
    if (to.blink and !from.blink) try params.code(5);
    if (to.reverse and !from.reverse) try params.code(7);
    if (to.hidden and !from.hidden) try params.code(8);
    if (to.strikethrough and !from.strikethrough) try params.code(9);

    if (!std.meta.eql(from.fg, to.fg)) try writeFgBg(&params, to.fg, 39, 30, 90, 38);
    if (!std.meta.eql(from.bg, to.bg)) try writeFgBg(&params, to.bg, 49, 40, 100, 48);
    if (!std.meta.eql(from.underline_color, to.underline_color)) {
        try writeUnderlineColor(&params, to.underline_color);
    }

    try params.finish();
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
        try setStyle(&fg.writer, .{ .fg = .{ .ansi = case.color } });
        try std.testing.expectEqualStrings(case.fg, fg.written());

        var bg: Writer.Allocating = .init(std.testing.allocator);
        defer bg.deinit();
        try setStyle(&bg.writer, .{ .bg = .{ .ansi = case.color } });
        try std.testing.expectEqualStrings(case.bg, bg.written());
    }
}

test "a palette colour writes the indexed form on all three sides" {
    const cases = [_]struct { style: Style, bytes: []const u8 }{
        .{ .style = .{ .fg = .{ .palette = 0 } }, .bytes = "\x1b[38;5;0m" },
        .{ .style = .{ .fg = .{ .palette = 196 } }, .bytes = "\x1b[38;5;196m" },
        .{ .style = .{ .fg = .{ .palette = 255 } }, .bytes = "\x1b[38;5;255m" },
        .{ .style = .{ .bg = .{ .palette = 17 } }, .bytes = "\x1b[48;5;17m" },
        .{ .style = .{ .bg = .{ .palette = 255 } }, .bytes = "\x1b[48;5;255m" },
        // The underline colour has no short codes, so its sixteen are written
        // as palette entries like any other index.
        .{ .style = .{ .underline_color = .{ .palette = 3 } }, .bytes = "\x1b[58:5:3m" },
        .{ .style = .{ .underline_color = .{ .palette = 231 } }, .bytes = "\x1b[58:5:231m" },
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
    try setStyle(&named.writer, .{ .underline_color = .{ .ansi = .bright_magenta } });
    try std.testing.expectEqualStrings("\x1b[58:5:13m", named.written());

    var indexed: Writer.Allocating = .init(std.testing.allocator);
    defer indexed.deinit();
    try setStyle(&indexed.writer, .{ .underline_color = .{ .palette = 13 } });
    try std.testing.expectEqualStrings(named.written(), indexed.written());
}

test "a direct colour writes semicolons for fg and bg and colons for the underline" {
    const cases = [_]struct { style: Style, bytes: []const u8 }{
        .{ .style = .{ .fg = .{ .rgb = .{ .r = 0, .g = 0, .b = 0 } } }, .bytes = "\x1b[38;2;0;0;0m" },
        .{ .style = .{ .fg = .{ .rgb = .{ .r = 255, .g = 128, .b = 1 } } }, .bytes = "\x1b[38;2;255;128;1m" },
        .{ .style = .{ .bg = .{ .rgb = .{ .r = 17, .g = 34, .b = 51 } } }, .bytes = "\x1b[48;2;17;34;51m" },
        .{ .style = .{ .bg = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } } }, .bytes = "\x1b[48;2;255;255;255m" },
        .{
            .style = .{ .underline_color = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } } },
            .bytes = "\x1b[58:2::255:0:0m",
        },
        .{
            .style = .{ .underline_color = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } } },
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
        .fg = .{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
        .bg = .{ .palette = 200 },
        .underline_color = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
        .bold = true,
        .italic = true,
        .underline = .curly,
    });
    try std.testing.expectEqualStrings(
        "\x1b[1;3;4:3;38;2;10;20;30;48;5;200;58:2::1:2:3m",
        out.written(),
    );
}

test "turning bold off while dim stays on re-states dim" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try diffStyle(&out.writer, .{ .bold = true, .dim = true }, .{ .dim = true });
    try std.testing.expectEqualStrings("\x1b[22;2m", out.written());
}

test "turning dim off while bold stays on re-states bold" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try diffStyle(&out.writer, .{ .bold = true, .dim = true }, .{ .bold = true });
    try std.testing.expectEqualStrings("\x1b[22;1m", out.written());
}

test "turning both bold and dim off writes the one code that does it" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try diffStyle(&out.writer, .{ .bold = true, .dim = true }, .{});
    try std.testing.expectEqualStrings("\x1b[22m", out.written());
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
        .{ .bold = true, .blink = true, .fg = .{ .ansi = .red } },
        .{ .italic = true, .fg = .{ .palette = 33 }, .bg = .{ .ansi = .bright_black } },
    );
    try std.testing.expectEqualStrings("\x1b[22;25;3;38;5;33;100m", out.written());
}

test "turning an underline off writes the underline off code" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try diffStyle(&out.writer, .{ .underline = .curly }, .{});
    try std.testing.expectEqualStrings("\x1b[24m", out.written());
}

test "changing one underline to another writes only the new one" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try diffStyle(&out.writer, .{ .underline = .curly }, .{ .underline = .dotted });
    try std.testing.expectEqualStrings("\x1b[4:4m", out.written());
}

test "a colour going back to default writes the default code for its side" {
    const cases = [_]struct { from: Style, bytes: []const u8 }{
        .{ .from = .{ .fg = .{ .ansi = .red } }, .bytes = "\x1b[39m" },
        .{ .from = .{ .fg = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } } }, .bytes = "\x1b[39m" },
        .{ .from = .{ .bg = .{ .palette = 200 } }, .bytes = "\x1b[49m" },
        .{ .from = .{ .underline_color = .{ .rgb = .{ .r = 9, .g = 9, .b = 9 } } }, .bytes = "\x1b[59m" },
    };
    for (cases) |case| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();

        try diffStyle(&out.writer, case.from, .{});
        try std.testing.expectEqualStrings(case.bytes, out.written());
    }
}

test "all three colours going back to default land in one sequence" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try diffStyle(&out.writer, .{
        .fg = .{ .ansi = .red },
        .bg = .{ .palette = 200 },
        .underline_color = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
    }, .{});
    try std.testing.expectEqualStrings("\x1b[39;49;59m", out.written());
}

test "the same sixteen colours in their two spellings are not the same colour" {
    // `.ansi` and `.palette` 1 are the same slot, so the diff must still write
    // the new spelling rather than treat the change as a no-op.
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try diffStyle(&out.writer, .{ .fg = .{ .ansi = .red } }, .{ .fg = .{ .palette = 1 } });
    try std.testing.expectEqualStrings("\x1b[38;5;1m", out.written());
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
        .{ .fg = .{ .ansi = .bright_cyan } },
        .{ .bg = .{ .ansi = .black } },
        .{ .fg = .{ .palette = 231 }, .bg = .{ .palette = 16 } },
        .{ .fg = .{ .rgb = .{ .r = 255, .g = 0, .b = 127 } } },
        .{ .underline_color = .{ .rgb = .{ .r = 0, .g = 255, .b = 0 } } },
        .{ .underline_color = .{ .ansi = .yellow } },
        .{
            .fg = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
            .bg = .{ .palette = 8 },
            .underline_color = .{ .palette = 9 },
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
        .fg = .{ .ansi = .red },
        .bg = .{ .ansi = .bright_blue },
        .underline_color = .{ .ansi = .green },
        .bold = true,
        .dim = true,
        .italic = true,
        .underline = .dashed,
        .blink = true,
        .reverse = true,
        .hidden = true,
        .strikethrough = true,
    };

    var on: Writer.Allocating = .init(std.testing.allocator);
    defer on.deinit();
    try diffStyle(&on.writer, .{}, everything);
    try std.testing.expectEqualStrings("\x1b[1;2;3;4:5;5;7;8;9;31;104;58:5:2m", on.written());

    var off: Writer.Allocating = .init(std.testing.allocator);
    defer off.deinit();
    try diffStyle(&off.writer, everything, .{});
    try std.testing.expectEqualStrings("\x1b[22;23;24;25;27;28;29;39;49;59m", off.written());
}

test "setStyle is the diff from the default style" {
    const styles = [_]Style{
        .{ .bold = true, .underline = .double },
        .{ .fg = .{ .palette = 42 }, .reverse = true },
        .{ .underline_color = .{ .rgb = .{ .r = 7, .g = 8, .b = 9 } }, .underline = .curly },
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
        .fg = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } },
        .bold = true,
        .italic = true,
        .underline = .curly,
    }));
}
