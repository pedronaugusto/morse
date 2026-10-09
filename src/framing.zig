//! Where a control sequence or a control string in a byte stream ends, and
//! what its parts are.
//!
//! The reading half of what every writer in this package spells: a program
//! that reads a terminal's output back -- an emulator checking a renderer, a
//! recorder, a multiplexer -- frames `CSI ... final` and `OSC ... ST` here
//! rather than restating the grammar. `KeyParser` frames its control strings
//! with the same code.
//!
//! Both framers are streaming: they say when the bytes do not yet hold the
//! whole of a sequence, so a caller that read half of one keeps it and asks
//! again when more arrives. Neither allocates or copies; what they return
//! borrows the bytes they were given.

const std = @import("std");
const aegis = @import("aegis");

/// A framed byte count, distinct from a parameter or element index.
pub const ByteCount = aegis.units.Bytes(usize);
const seq = @import("seq.zig");

/// One control sequence, `CSI [marker] parameters [intermediates] final`,
/// framed.
pub const Csi = struct {
    /// The private marker, `<`, `=`, `>` or `?`, written straight after the
    /// `CSI`; zero for none.
    marker: u8,
    /// The parameter bytes: digits, `;` between parameters and `:` between
    /// the sub-parameters of one. Borrowed.
    params: []const u8,
    /// The intermediate bytes, 0x20 to 0x2f, between the parameters and the
    /// final byte: the space of `CSI 2 SP q`. Borrowed.
    intermediates: []const u8,
    /// The final byte, 0x40 to 0x7e, which says what the sequence is.
    ///
    /// Zero for a sequence abandoned by a byte that cannot stand in one,
    /// which is how a terminal interrupted part way through a sequence goes
    /// on to the next thing: the sequence ends in front of that byte, and the
    /// byte is read again as whatever it begins.
    final: u8,
    /// How many bytes the sequence took, from the `ESC` through the final
    /// byte, or up to the byte that abandoned it.
    len: ByteCount,

    /// The parameter at `index`, counting from zero, as a number: the field
    /// between the `index`th and the next `;`, up to any `:` in it.
    ///
    /// Null when there is no such field, when it is empty -- which ECMA-48
    /// says means the sequence's own default, so the caller supplies it --
    /// and when it is not a number that fits in a `u32`.
    pub fn param(c: Csi, index: usize) ?u32 {
        var fields = std.mem.splitScalar(u8, c.params, ';');
        var at: usize = 0;
        while (fields.next()) |field| : (at += 1) {
            if (at != index) continue;
            const head = std.mem.sliceTo(field, ':');
            const scanned = seq.scanInt(u32, head) orelse return null;
            return if (scanned.len == head.len) scanned.value else null;
        }
        return null;
    }
};

/// Frames the control sequence at the front of `bytes`.
///
/// `bytes` starts with the `CSI`, `ESC [`, and may run on past the sequence;
/// `Csi.len` says where it ended. Null when `bytes` does not start with a
/// `CSI`, or does not yet hold the byte that ends it.
// aegis: measured hot loop validated at its boundary: indices stay within bytes; the result exports a byte count.
pub fn parseCsi(bytes: []const u8) ?Csi {
    if (bytes.len < 2 or bytes[0] != seq.esc or bytes[1] != '[') return null;
    var i: usize = 2;
    var marker: u8 = 0;
    if (i < bytes.len and bytes[i] >= '<' and bytes[i] <= '?') {
        marker = bytes[i];
        i += 1;
    }
    const params_start = i;
    while (i < bytes.len and bytes[i] >= 0x30 and bytes[i] <= 0x3f) : (i += 1) {}
    const params_end = i;
    while (i < bytes.len and bytes[i] >= 0x20 and bytes[i] <= 0x2f) : (i += 1) {}
    if (i >= bytes.len) return null;
    const final = bytes[i];
    const whole = final >= 0x40 and final <= 0x7e;
    return .{
        .marker = marker,
        .params = bytes[params_start..params_end],
        .intermediates = bytes[params_end..i],
        .final = if (whole) final else 0,
        .len = ByteCount.fromRaw(if (whole) i + 1 else i),
    };
}

/// One control string -- `OSC`, `DCS`, `SOS`, `PM` or `APC` and what it
/// carries up to its terminator -- framed.
pub const ControlString = struct {
    /// The byte after the `ESC` that says which: `]` for OSC, `P` for DCS,
    /// `X` for SOS, `^` for PM, `_` for APC.
    introducer: u8,
    /// What the string carries, between the introducer and the terminator.
    /// Borrowed.
    body: []const u8,
    /// How many bytes the string took, from the `ESC` through its
    /// terminator, or up to the `ESC` that abandoned it.
    len: ByteCount,
    /// Whether a terminator ended it. False for a string abandoned by an
    /// `ESC` that does not begin an `ST`: that `ESC` is the next sequence
    /// beginning, so the string ends in front of it, unfinished, and what it
    /// carried is not to be acted on.
    terminated: bool,
};

/// Frames the control string at the front of `bytes`.
///
/// `ST` is the terminator the standard names and `BEL` the one xterm has
/// always accepted, so both end a string here; this package writes `ST`
/// everywhere it has the choice. `bytes` starts with the `ESC` and may run
/// on past the string. Null when `bytes` does not start with one of the five
/// introducers, or does not yet hold the byte that ends it -- which includes
/// a final `ESC` whose next byte has not arrived.
// aegis: measured hot loop validated at its boundary: terminator lookahead checks bytes.len before indexing.
pub fn parseControlString(bytes: []const u8) ?ControlString {
    if (bytes.len < 2 or bytes[0] != seq.esc) return null;
    switch (bytes[1]) {
        ']', 'P', 'X', '^', '_' => {},
        else => return null,
    }
    var i: usize = 2;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == seq.bel) return .{
            .introducer = bytes[1],
            .body = bytes[2..i],
            .len = ByteCount.fromRaw(i + 1),
            .terminated = true,
        };
        if (bytes[i] != seq.esc) continue;
        if (i + 1 >= bytes.len) return null;
        const terminated = bytes[i + 1] == '\\';
        return .{
            .introducer = bytes[1],
            .body = bytes[2..i],
            .len = ByteCount.fromRaw(if (terminated) i + 2 else i),
            .terminated = terminated,
        };
    }
    return null;
}

const testing = std.testing;

test "a control sequence frames into its marker, parameters, intermediates and final" {
    const c = parseCsi("\x1b[?25;7hrest").?;
    try testing.expectEqual(@as(u8, '?'), c.marker);
    try testing.expectEqualStrings("25;7", c.params);
    try testing.expectEqualStrings("", c.intermediates);
    try testing.expectEqual(@as(u8, 'h'), c.final);
    try testing.expectEqual(@as(usize, 8), c.len.raw());

    const shape = parseCsi("\x1b[5 q").?;
    try testing.expectEqual(@as(u8, 0), shape.marker);
    try testing.expectEqualStrings(" ", shape.intermediates);
    try testing.expectEqual(@as(u8, 'q'), shape.final);
    try testing.expectEqual(@as(?u32, 5), shape.param(0));

    const bare = parseCsi("\x1b[m").?;
    try testing.expectEqualStrings("", bare.params);
    try testing.expectEqual(@as(usize, 3), bare.len.raw());
}

test "a control sequence not all here yet is not framed" {
    for ([_][]const u8{ "", "\x1b", "\x1b[", "\x1b[?", "\x1b[12;4", "\x1b[2 " }) |bytes| {
        try testing.expect(parseCsi(bytes) == null);
    }
    try testing.expect(parseCsi("\x1b]8;;\x1b\\") == null);
    try testing.expect(parseCsi("[1m") == null);
}

test "a byte that cannot end a control sequence abandons it in front of that byte" {
    const c = parseCsi("\x1b[12\x1b[1m").?;
    try testing.expectEqual(@as(u8, 0), c.final);
    try testing.expectEqual(@as(usize, 4), c.len.raw());
    try testing.expectEqualStrings("12", c.params);
}

test "a parameter is its field up to any sub-parameter, and missing or empty is null" {
    const c = parseCsi("\x1b[12;;4:3;x9;99999999999H").?;
    try testing.expectEqual(@as(?u32, 12), c.param(0));
    try testing.expectEqual(@as(?u32, null), c.param(1));
    try testing.expectEqual(@as(?u32, 4), c.param(2));
    try testing.expectEqual(@as(?u32, null), c.param(4));
    try testing.expectEqual(@as(?u32, null), c.param(5));
    try testing.expectEqual(@as(?u32, null), c.param(6));
}

test "a control string ends at ST or BEL, and an ESC that is not ST abandons it" {
    const st = parseControlString("\x1b]8;;https://x\x1b\\after").?;
    try testing.expectEqual(@as(u8, ']'), st.introducer);
    try testing.expectEqualStrings("8;;https://x", st.body);
    try testing.expectEqual(@as(usize, 16), st.len.raw());
    try testing.expect(st.terminated);

    const bel = parseControlString("\x1b_Gi=1;OK\x07").?;
    try testing.expectEqual(@as(u8, '_'), bel.introducer);
    try testing.expectEqualStrings("Gi=1;OK", bel.body);
    try testing.expectEqual(@as(usize, 10), bel.len.raw());
    try testing.expect(bel.terminated);

    const cut = parseControlString("\x1b]0;tit\x1b[A").?;
    try testing.expect(!cut.terminated);
    try testing.expectEqual(@as(usize, 7), cut.len.raw());
    try testing.expectEqualStrings("0;tit", cut.body);
}

test "a control string not all here yet is not framed" {
    for ([_][]const u8{ "", "\x1b", "\x1b]", "\x1b]8;;u", "\x1bP1+r\x1b", "\x1b[1m", "\x1bOA" }) |bytes| {
        try testing.expect(parseControlString(bytes) == null);
    }
}
