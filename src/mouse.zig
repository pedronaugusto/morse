//! Mouse reports in SGR form: mode 1006, which counts in cells, and mode
//! 1016, which counts in pixels.
//!
//! The two modes produce byte-identical reports — only the units differ — so
//! `parseMouse` cannot tell them apart and always reports cells. A program
//! knows which mode it asked for; see `MouseEvent.pixels` and `toCells`.
//!
//! The original X10 encoding is read too, by `parseMouseX10`, but is never
//! asked for -- `mouse` always offers SGR. It is here because a terminal put
//! into mode 1000, 1002 or 1003 *without* mode 1006 reports in it, and a
//! sequence that cannot be read still has to be framed: three arbitrary bytes
//! mistaken for three keypresses is a worse failure than a report this
//! package declines to interpret. Its own limits are why SGR exists -- it
//! caps coordinates at 223 and does not say which button was released.
//!
//! The UTF-8 encoding (mode 1005) is not read. It is the same report with the
//! coordinates spelled as codepoints rather than bytes, which makes its length
//! depend on a mode the input stream does not carry -- so it cannot even be
//! framed without knowing what was asked for. It was superseded by SGR before
//! it was widely implemented.

const std = @import("std");
const corpus = @import("corpus.zig");
const seq = @import("seq.zig");

const Writer = std.Io.Writer;

/// A mouse button, numbered as the SGR protocol numbers it.
///
/// The wheel is four buttons rather than an axis, because that is what the
/// protocol reports: a wheel notch arrives as a press of `wheel_up` and no
/// matching release.
pub const Button = enum(u8) {
    /// The left button, or the only button.
    left = 0,
    /// The middle button, often the wheel pressed down.
    middle = 1,
    /// The right button.
    right = 2,
    /// No button: what a release reports, and what motion with nothing held
    /// reports.
    none = 3,
    /// A wheel notch away from the user.
    wheel_up = 64,
    /// A wheel notch towards the user.
    wheel_down = 65,
    /// A horizontal wheel or tilt notch to the left.
    wheel_left = 66,
    /// A horizontal wheel or tilt notch to the right.
    wheel_right = 67,
    /// Button 8, usually "back" on a mouse with side buttons.
    button_8 = 128,
    /// Button 9, usually "forward".
    button_9 = 129,
    /// Button 10.
    button_10 = 130,
    /// Button 11.
    button_11 = 131,
};

/// One mouse report.
///
/// `x` and `y` count from 1 at the top-left, in cells unless `pixels` is set.
pub const MouseEvent = struct {
    /// Which button the report is about.
    button: Button,
    /// The column, or the pixel offset from the left edge when `pixels`.
    x: u32,
    /// The row, or the pixel offset from the top edge when `pixels`.
    y: u32,
    /// True for a press, false for a release. A wheel notch is a press.
    press: bool,
    /// The pointer moved while this button was held, or while none was.
    motion: bool = false,
    /// Shift was held.
    shift: bool = false,
    /// Alt (meta) was held.
    alt: bool = false,
    /// Control was held.
    ctrl: bool = false,
    /// `x` and `y` are pixels, not cells — mode 1016 rather than 1006.
    ///
    /// Nothing on the wire distinguishes the two, so `parseMouse` always
    /// leaves this false and `encodeMouse` ignores it. A program that asked
    /// for mode 1016 sets it on what it parses, then calls `toCells`.
    pixels: bool = false,
};

/// Writes `ev` as an SGR mouse report: `CSI < b ; x ; y M` for a press and
/// `... m` for a release.
///
/// `ev.pixels` is not encoded, because the wire format does not carry it.
/// This is what a terminal emulator writes; a program reading a terminal
/// wants `parseMouse`.
pub fn encodeMouse(w: *Writer, ev: MouseEvent) Writer.Error!void {
    var code: u8 = @intFromEnum(ev.button);
    if (ev.shift) code |= 4;
    if (ev.alt) code |= 8;
    if (ev.ctrl) code |= 16;
    if (ev.motion) code |= 32;

    try w.writeAll(seq.csi ++ "<");
    try w.print("{d};{d};{d}", .{ code, ev.x, ev.y });
    try w.writeByte(if (ev.press) 'M' else 'm');
}

/// Reads an SGR mouse report: `CSI < b ; x ; y M` or `... m`.
///
/// Returns null for anything else — the older X10 encoding included — and
/// never an error. `bytes` must be exactly the sequence. The returned event
/// always has `pixels` false: see `MouseEvent.pixels`.
pub fn parseMouse(bytes: []const u8) ?MouseEvent {
    const prefix = seq.csi ++ "<";
    if (!std.mem.startsWith(u8, bytes, prefix)) return null;
    var rest = bytes[prefix.len..];

    const code = seq.scanInt(u8, rest) orelse return null;
    rest = rest[code.len..];
    if (rest.len == 0 or rest[0] != ';') return null;
    rest = rest[1..];

    const x = seq.scanInt(u32, rest) orelse return null;
    rest = rest[x.len..];
    if (rest.len == 0 or rest[0] != ';') return null;
    rest = rest[1..];

    const y = seq.scanInt(u32, rest) orelse return null;
    rest = rest[y.len..];
    if (rest.len != 1) return null;
    const press = switch (rest[0]) {
        'M' => true,
        'm' => false,
        else => return null,
    };

    // Bits 0-1 name the button; bit 6 shifts the numbering to the wheel and
    // bit 7 to the extra buttons. Both at once names nothing.
    const button = switch (code.value & 0b1100_0011) {
        0 => Button.left,
        1 => Button.middle,
        2 => Button.right,
        3 => Button.none,
        64 => Button.wheel_up,
        65 => Button.wheel_down,
        66 => Button.wheel_left,
        67 => Button.wheel_right,
        128 => Button.button_8,
        129 => Button.button_9,
        130 => Button.button_10,
        131 => Button.button_11,
        else => return null,
    };

    return .{
        .button = button,
        .x = x.value,
        .y = y.value,
        .press = press,
        .motion = code.value & 32 != 0,
        .shift = code.value & 4 != 0,
        .alt = code.value & 8 != 0,
        .ctrl = code.value & 16 != 0,
    };
}

/// The byte an X10 mouse report biases its fields by, so that every byte of
/// the report is printable and none of them is a control code.
const x10_bias = 32;

/// The most an X10 field can say once the bias is taken off: 255 - 32. The
/// cap that made SGR necessary, and the reason a program on a terminal wider
/// than 223 columns must ask for mode 1006.
pub const x10_max = 255 - x10_bias;

/// Reads the original X10 mouse report: `CSI M b x y`, where each of the
/// three bytes carries its value plus 32.
///
/// This is what a terminal in mode 1000, 1002 or 1003 sends when mode 1006
/// was not also asked for. `mouse` always asks for 1006, so a program that
/// sets its modes through this package never sees one; it is read because a
/// terminal left in that state by something earlier still sends them, and
/// `KeyParser` frames them either way.
///
/// Two things the encoding cannot say, both of which `parseMouse` can. A
/// release names no button -- every release is `Button.none`, so a program
/// cannot tell which button came up. And a coordinate above `x10_max` does
/// not fit in a byte: terminals variously clamp it, wrap it, or send a byte
/// below the bias, so a report from beyond column 223 is wrong rather than
/// missing. Returns null for a field below the bias; everything else is
/// reported as sent.
///
/// Returns null for anything that is not exactly this sequence, and never an
/// error. `bytes` must be exactly the sequence. The returned event always has
/// `pixels` false: the X10 encoding has no pixel form.
pub fn parseMouseX10(bytes: []const u8) ?MouseEvent {
    const prefix = seq.csi ++ "M";
    if (!std.mem.startsWith(u8, bytes, prefix)) return null;
    const fields = bytes[prefix.len..];
    if (fields.len != 3) return null;
    for (fields) |b| {
        if (b < x10_bias) return null;
    }

    const code = fields[0] - x10_bias;

    // The same button bits as the SGR form, and the same "both at once names
    // nothing" rule -- only the transport differs.
    const button = switch (code & 0b1100_0011) {
        0 => Button.left,
        1 => Button.middle,
        2 => Button.right,
        3 => Button.none,
        64 => Button.wheel_up,
        65 => Button.wheel_down,
        66 => Button.wheel_left,
        67 => Button.wheel_right,
        128 => Button.button_8,
        129 => Button.button_9,
        130 => Button.button_10,
        131 => Button.button_11,
        else => return null,
    };

    return .{
        .button = button,
        .x = fields[1] - x10_bias,
        .y = fields[2] - x10_bias,
        // Button 3 is the release, and it is the only one this encoding has.
        // A wheel notch is a press, as it is in the SGR form.
        .press = button != .none,
        .motion = code & 32 != 0,
        .shift = code & 4 != 0,
        .alt = code & 8 != 0,
        .ctrl = code & 16 != 0,
    };
}

/// Converts a pixel report (mode 1016) into cells, given the size of one cell
/// in pixels.
///
/// Both coordinate systems count from 1: pixel 1 is the leftmost pixel and
/// cell 1 the leftmost cell, so a pixel at `x` falls in column
/// `(x - 1) / cell_w + 1`. The first `cell_w` pixels are therefore column 1
/// and pixel `cell_w + 1` opens column 2.
///
/// An event that is already in cells is returned unchanged. The result has
/// `pixels` false, so converting twice is harmless. `cell_w` and `cell_h`
/// must be non-zero.
pub fn toCells(ev: MouseEvent, cell_w: u32, cell_h: u32) MouseEvent {
    std.debug.assert(cell_w != 0);
    std.debug.assert(cell_h != 0);
    if (!ev.pixels) return ev;

    var cells = ev;
    // Saturating, so a terminal reporting pixel 0 lands in column 1 rather
    // than underflowing.
    cells.x = (ev.x -| 1) / cell_w + 1;
    cells.y = (ev.y -| 1) / cell_h + 1;
    cells.pixels = false;
    return cells;
}

test "encodeMouse writes a left press" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try encodeMouse(&out.writer, .{ .button = .left, .x = 10, .y = 5, .press = true });
    try std.testing.expectEqualStrings("\x1b[<0;10;5M", out.written());
}

test "encodeMouse writes a release with a lowercase final byte" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try encodeMouse(&out.writer, .{ .button = .left, .x = 10, .y = 5, .press = false });
    try std.testing.expectEqualStrings("\x1b[<0;10;5m", out.written());
}

test "encodeMouse folds modifiers and motion into the button code" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    // 2 (right) + 4 (shift) + 8 (alt) + 16 (ctrl) + 32 (motion) = 62.
    try encodeMouse(&out.writer, .{
        .button = .right,
        .x = 1,
        .y = 1,
        .press = true,
        .motion = true,
        .shift = true,
        .alt = true,
        .ctrl = true,
    });
    try std.testing.expectEqualStrings("\x1b[<62;1;1M", out.written());
}

test "encodeMouse writes a wheel notch and an extra button" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try encodeMouse(&out.writer, .{ .button = .wheel_up, .x = 3, .y = 4, .press = true });
    try encodeMouse(&out.writer, .{ .button = .button_8, .x = 3, .y = 4, .press = true });
    try std.testing.expectEqualStrings("\x1b[<64;3;4M\x1b[<128;3;4M", out.written());
}

test "encodeMouse ignores pixels, which the wire format does not carry" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try encodeMouse(&out.writer, .{ .button = .left, .x = 800, .y = 600, .press = true, .pixels = true });
    try std.testing.expectEqualStrings("\x1b[<0;800;600M", out.written());
}

test "parseMouse reads a left press" {
    try std.testing.expectEqual(
        MouseEvent{ .button = .left, .x = 10, .y = 5, .press = true },
        parseMouse("\x1b[<0;10;5M").?,
    );
}

test "parseMouse splits modifiers, motion and button out of the code" {
    const ev = parseMouse("\x1b[<62;7;9m").?;
    try std.testing.expectEqual(Button.right, ev.button);
    try std.testing.expectEqual(@as(u32, 7), ev.x);
    try std.testing.expectEqual(@as(u32, 9), ev.y);
    try std.testing.expect(!ev.press);
    try std.testing.expect(ev.motion);
    try std.testing.expect(ev.shift);
    try std.testing.expect(ev.alt);
    try std.testing.expect(ev.ctrl);
    try std.testing.expect(!ev.pixels);
}

test "parseMouse reads a drag, which is motion with a button held" {
    // 0 (left) + 32 (motion) = 32.
    const ev = parseMouse("\x1b[<32;20;10M").?;
    try std.testing.expectEqual(Button.left, ev.button);
    try std.testing.expect(ev.motion);
    try std.testing.expect(ev.press);
}

test "parseMouse reads every button this package names" {
    const cases = [_]struct { code: []const u8, button: Button }{
        .{ .code = "0", .button = .left },
        .{ .code = "1", .button = .middle },
        .{ .code = "2", .button = .right },
        .{ .code = "3", .button = .none },
        .{ .code = "64", .button = .wheel_up },
        .{ .code = "65", .button = .wheel_down },
        .{ .code = "66", .button = .wheel_left },
        .{ .code = "67", .button = .wheel_right },
        .{ .code = "128", .button = .button_8 },
        .{ .code = "129", .button = .button_9 },
        .{ .code = "130", .button = .button_10 },
        .{ .code = "131", .button = .button_11 },
    };
    var buffer: [32]u8 = undefined;
    for (cases) |case| {
        const bytes = try std.fmt.bufPrint(&buffer, "\x1b[<{s};1;1M", .{case.code});
        try std.testing.expectEqual(case.button, parseMouse(bytes).?.button);
    }
}

test "parseMouse returns null on anything it does not recognise" {
    const rejected = [_][]const u8{
        "", // nothing at all
        "\x1b[<0;10;5", // no final byte
        "\x1b[<0;10;", // no row
        "\x1b[<0;10", // a field short
        "\x1b[<0", // two fields short
        "\x1b[<", // no fields at all
        "\x1b[<;10;5M", // no button code
        "\x1b[0;10;5M", // X10-style, no `<`
        "\x1b]<0;10;5M", // OSC, not CSI
        "\x1b[<0;10;5X", // not a press or a release
        "\x1b[<0;10;5MM", // trailing rubbish
        "\x1b[<0;10;5;1M", // a field too many
        "\x1b[<192;1;1M", // wheel and extra bits at once, which names nothing
        "\x1b[<256;1;1M", // a code too large for its field
        "\x1b[<0;4294967296;1M", // a column too large for its field
        "\x1b[<0;1;4294967296M", // a row too large for its field
    };
    for (rejected) |bytes| {
        try std.testing.expect(parseMouse(bytes) == null);
    }
}

test "every event this package can encode parses back to itself" {
    var out: Writer.Allocating = .init(std.testing.allocator);

    defer out.deinit();
    for (std.meta.tags(Button)) |button| {
        for ([_]bool{ false, true }) |press| {
            for (0..16) |modifiers| {
                const ev = MouseEvent{
                    .button = button,
                    .x = 1 + @as(u32, @intCast(modifiers)) * 100,
                    .y = 4294967295 - @as(u32, @intCast(modifiers)),
                    .press = press,
                    .motion = modifiers & 1 != 0,
                    .shift = modifiers & 2 != 0,
                    .alt = modifiers & 4 != 0,
                    .ctrl = modifiers & 8 != 0,
                };
                out.clearRetainingCapacity();
                try encodeMouse(&out.writer, ev);
                try std.testing.expectEqual(ev, parseMouse(out.written()).?);
            }
        }
    }
}

test "a pixel event round trips once the caller says it is one" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const sent = MouseEvent{ .button = .left, .x = 801, .y = 601, .press = true, .pixels = true };
    try encodeMouse(&out.writer, sent);

    // The wire carries no unit, so the parse comes back in cells; a program
    // that asked for mode 1016 knows better and says so.
    var parsed = parseMouse(out.written()).?;
    try std.testing.expect(!parsed.pixels);
    parsed.pixels = true;
    try std.testing.expectEqual(sent, parsed);
}

test "toCells maps the first cell, its last pixel, and the next cell" {
    const at = struct {
        fn ev(x: u32, y: u32) MouseEvent {
            return .{ .button = .left, .x = x, .y = y, .press = true, .pixels = true };
        }
    }.ev;

    const first = toCells(at(1, 1), 8, 16);
    try std.testing.expectEqual(@as(u32, 1), first.x);
    try std.testing.expectEqual(@as(u32, 1), first.y);
    try std.testing.expect(!first.pixels);

    const last_of_first = toCells(at(8, 16), 8, 16);
    try std.testing.expectEqual(@as(u32, 1), last_of_first.x);
    try std.testing.expectEqual(@as(u32, 1), last_of_first.y);

    const second = toCells(at(9, 17), 8, 16);
    try std.testing.expectEqual(@as(u32, 2), second.x);
    try std.testing.expectEqual(@as(u32, 2), second.y);
}

test "toCells keeps everything about the event except the coordinates" {
    const ev = MouseEvent{
        .button = .wheel_down,
        .x = 100,
        .y = 200,
        .press = true,
        .motion = true,
        .shift = true,
        .alt = true,
        .ctrl = true,
        .pixels = true,
    };
    // Pixel 100 is the last of the tenth 10-pixel column; pixel 200 is the
    // ninth of the thirteenth 16-pixel row.
    try std.testing.expectEqual(MouseEvent{
        .button = .wheel_down,
        .x = 10,
        .y = 13,
        .press = true,
        .motion = true,
        .shift = true,
        .alt = true,
        .ctrl = true,
        .pixels = false,
    }, toCells(ev, 10, 16));
}

test "toCells leaves a cell event alone and is idempotent" {
    const cells = MouseEvent{ .button = .left, .x = 40, .y = 12, .press = true };
    try std.testing.expectEqual(cells, toCells(cells, 8, 16));

    const converted = toCells(.{ .button = .left, .x = 41, .y = 33, .press = true, .pixels = true }, 8, 16);
    try std.testing.expectEqual(converted, toCells(converted, 8, 16));
}

test "toCells saturates rather than underflowing at pixel zero" {
    const ev = toCells(.{ .button = .left, .x = 0, .y = 0, .press = true, .pixels = true }, 8, 16);
    try std.testing.expectEqual(@as(u32, 1), ev.x);
    try std.testing.expectEqual(@as(u32, 1), ev.y);
}

test "toCells handles a one-pixel cell and the largest coordinate" {
    const ev = toCells(.{
        .button = .left,
        .x = 4294967295,
        .y = 4294967295,
        .press = true,
        .pixels = true,
    }, 1, 1);
    try std.testing.expectEqual(@as(u32, 4294967295), ev.x);
    try std.testing.expectEqual(@as(u32, 4294967295), ev.y);
}

test "fuzz parseMouse" {
    // The property: no input panics or overflows, and every input that parses
    // re-encodes to something that parses back to the same event. That is the
    // encoder and the parser agreeing on inputs no test author enumerated.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [64]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];

            const ev = parseMouse(bytes) orelse return;
            try std.testing.expect(!ev.pixels);

            var output: [64]u8 = undefined;
            var w: Writer = .fixed(&output);
            try encodeMouse(&w, ev);
            try std.testing.expectEqual(ev, parseMouse(w.buffered()).?);

            // And the conversion the parser's caller reaches for next.
            var pixel = ev;
            pixel.pixels = true;
            const cells = toCells(pixel, 8, 16);
            try std.testing.expect(cells.x >= 1 and cells.x <= ev.x);
            try std.testing.expect(cells.y >= 1 and cells.y <= ev.y);
        }
    }.one, .{ .corpus = &.{
        corpus.seed("\x1b[<0;10;5M"),
        corpus.seed("\x1b[<62;7;9m"),
        corpus.seed("\x1b[<64;1;1M"),
        corpus.seed("\x1b[<131;4294967295;4294967295m"),
        corpus.seed("\x1b[<192;1;1M"),
        corpus.seed("\x1b[<0;99999999999;5M"),
        corpus.seed("\x1b[<0;10;5"),
        corpus.seed("\x1b[0;10;5M"),
    } });
}

test "parseMouseX10 reads a press, its coordinates and its modifiers" {
    // 32 is the bias, so a field byte of 0x21 is 1.
    const ev = parseMouseX10("\x1b[M\x20\x21\x22").?;
    try std.testing.expectEqual(Button.left, ev.button);
    try std.testing.expectEqual(@as(u32, 1), ev.x);
    try std.testing.expectEqual(@as(u32, 2), ev.y);
    try std.testing.expect(ev.press);
    try std.testing.expect(!ev.motion and !ev.shift and !ev.alt and !ev.ctrl);
    try std.testing.expect(!ev.pixels);
}

test "parseMouseX10 reads every button the encoding can name" {
    const cases = [_]struct { code: u8, button: Button, press: bool }{
        .{ .code = 0, .button = .left, .press = true },
        .{ .code = 1, .button = .middle, .press = true },
        .{ .code = 2, .button = .right, .press = true },
        // Button 3 is the release, and it names no button -- the limit of
        // this encoding and the reason SGR exists.
        .{ .code = 3, .button = .none, .press = false },
        .{ .code = 64, .button = .wheel_up, .press = true },
        .{ .code = 65, .button = .wheel_down, .press = true },
        .{ .code = 66, .button = .wheel_left, .press = true },
        .{ .code = 67, .button = .wheel_right, .press = true },
        .{ .code = 128, .button = .button_8, .press = true },
        .{ .code = 131, .button = .button_11, .press = true },
    };
    for (cases) |case| {
        const bytes = [_]u8{ 0x1b, '[', 'M', case.code + 32, 33, 33 };
        const ev = parseMouseX10(&bytes).?;
        try std.testing.expectEqual(case.button, ev.button);
        try std.testing.expectEqual(case.press, ev.press);
    }
}

test "parseMouseX10 reads the modifier and motion bits" {
    const shift = parseMouseX10("\x1b[M\x24\x21\x21").?;
    try std.testing.expect(shift.shift and !shift.alt and !shift.ctrl);

    const alt = parseMouseX10("\x1b[M\x28\x21\x21").?;
    try std.testing.expect(alt.alt and !alt.shift and !alt.ctrl);

    const ctrl = parseMouseX10("\x1b[M\x30\x21\x21").?;
    try std.testing.expect(ctrl.ctrl and !ctrl.shift and !ctrl.alt);

    const drag = parseMouseX10("\x1b[M\x40\x21\x21").?;
    try std.testing.expect(drag.motion and drag.button == .left);
}

test "parseMouseX10 reads the first cell and the last one it can spell" {
    const first = parseMouseX10("\x1b[M\x20\x21\x21").?;
    try std.testing.expectEqual(@as(u32, 1), first.x);
    try std.testing.expectEqual(@as(u32, 1), first.y);

    const last = parseMouseX10(&[_]u8{ 0x1b, '[', 'M', 32, 255, 255 }).?;
    try std.testing.expectEqual(@as(u32, x10_max), last.x);
    try std.testing.expectEqual(@as(u32, x10_max), last.y);
    try std.testing.expectEqual(@as(u32, 223), @as(u32, x10_max));
}

test "parseMouseX10 returns null on anything it does not recognise" {
    const rejected = [_][]const u8{
        "", // nothing at all
        "\x1b[M", // no fields
        "\x1b[M\x20\x21", // one field short
        "\x1b[M\x20\x21\x21\x21", // one field too many
        "\x1b[m\x20\x21\x21", // the SGR release final, not this one
        "\x1b[<0;1;1M", // an SGR report
        "\x1bM\x20\x21\x21", // no CSI
        "\x1b[M\x1f\x21\x21", // a button byte below the bias
        "\x1b[M\x20\x1f\x21", // a column byte below the bias
        "\x1b[M\x20\x21\x00", // a row byte below the bias
        "\x1b[M\xe0\x21\x21", // wheel and extra-button bits at once
    };
    for (rejected) |bytes| {
        try std.testing.expect(parseMouseX10(bytes) == null);
    }
}

test "parseMouseX10 reads a button whose code needs the high bit" {
    // 0xc0 is 160 once the bias is off, which masks to button 8 -- the bit
    // pattern that looks illegal and is not.
    const ev = parseMouseX10("\x1b[M\xc0\x21\x21").?;
    try std.testing.expectEqual(Button.button_8, ev.button);
    try std.testing.expect(ev.motion);
}

test "parseMouse and parseMouseX10 each refuse the other's form" {
    try std.testing.expect(parseMouse("\x1b[M\x20\x21\x21") == null);
    try std.testing.expect(parseMouseX10("\x1b[<0;1;1M") == null);
}

test "fuzz parseMouseX10" {
    // The property: no input panics or overflows, and every report that
    // parses re-encodes to the same three biased bytes and parses back to an
    // identical event. The encoder is inline because this package writes no
    // X10 reports -- it only reads them.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [64]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];

            const ev = parseMouseX10(bytes) orelse return;
            try std.testing.expect(ev.x <= x10_max and ev.y <= x10_max);
            try std.testing.expect(!ev.pixels);

            var code: u8 = @intFromEnum(ev.button);
            if (ev.shift) code |= 4;
            if (ev.alt) code |= 8;
            if (ev.ctrl) code |= 16;
            if (ev.motion) code |= 32;

            const round = [_]u8{
                0x1b,
                '[',
                'M',
                code +% x10_bias,
                @intCast(ev.x + x10_bias),
                @intCast(ev.y + x10_bias),
            };
            try std.testing.expectEqual(ev, parseMouseX10(&round).?);
        }
    }.one, .{ .corpus = &.{
        corpus.seed("\x1b[M\x20\x21\x21"),
        corpus.seed("\x1b[M\x23\x21\x21"),
        corpus.seed("\x1b[M\x60\x21\x21"),
        corpus.seed("\x1b[M\xa0\xff\xff"),
        corpus.seed("\x1b[M\x20\x20\x20"),
        corpus.seed("\x1b[M\x1f\x21\x21"),
        corpus.seed("\x1b[M\x20\x21"),
        corpus.seed("\x1b[<0;1;1M"),
    } });
}
