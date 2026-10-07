//! Terminal output with the control sequences taken out: the text a
//! program wrote, for a log, a search index, a test that compares what was
//! printed rather than how.
//!
//! What goes is everything an `ESC` introduces -- control sequences,
//! control strings (`OSC`, `DCS`, `SOS`, `PM`, `APC`) and the short escapes
//! -- framed by the same code as `parseCsi` and `parseControlString`, and
//! the C1 controls, U+0080 to U+009F, whether spelled as UTF-8 or as a
//! lone byte that is not UTF-8. A UTF-8 terminal reads neither form of C1
//! as the start of a sequence, so what follows one is text here too. The C0
//! controls stay: a newline, a tab and a carriage return are part of what
//! was printed, and `printable` removes them when they are not wanted.
//!
//! Output arrives in reads, and a sequence can be cut anywhere: `Stripper`
//! keeps where it is inside one between calls, so an image of a megabyte
//! in an `APC` costs a few bytes of state and none of buffer. `strip` is
//! the one-call form for a string already whole.

const std = @import("std");
const utf8 = @import("utf8.zig");
const framing = @import("framing.zig");
const seq = @import("seq.zig");
const corpus = @import("testing/corpus.zig");

const Writer = std.Io.Writer;

/// Strips control sequences from output that arrives a piece at a time.
///
/// A value with no storage of its own: the most it holds across calls is
/// the start of a codepoint the last piece cut in half.
pub const Stripper = struct {
    /// Where the last piece ended: in text, or inside a sequence.
    state: State = .text,
    /// The bytes of a codepoint the last piece ended inside.
    held: [3]u8 = undefined,
    /// How many of `held` there are.
    held_len: u2 = 0,

    const State = enum {
        /// Between sequences.
        text,
        /// Just past an `ESC`.
        escape,
        /// In a control sequence's parameter bytes.
        csi_parameter,
        /// In a control sequence's intermediate bytes.
        csi_intermediate,
        /// In a control string.
        string,
        /// In a control string, just past an `ESC`.
        string_escape,
        /// In a short escape's intermediate bytes.
        intermediate,
    };

    /// Writes the text of `bytes` to `w`, leaving out every sequence and C1
    /// control. A sequence or codepoint the end of `bytes` cuts is finished
    /// by the next call.
    pub fn feed(s: *Stripper, w: *Writer, bytes: []const u8) Writer.Error!void {
        s.assertValid();
        defer s.assertValid();
        var i: usize = 0;
        // A codepoint the last piece cut: complete it first.
        if (s.held_len != 0) {
            var joined: [4]u8 = undefined;
            const held = s.held[0..s.held_len];
            @memcpy(joined[0..held.len], held);
            const need = std.unicode.utf8ByteSequenceLength(held[0]) catch unreachable; // unreachable: held is written only from a prefix accepted by codepoint
            std.debug.assert(held.len < need);
            const take = @min(need - held.len, bytes.len);
            @memcpy(joined[held.len..][0..take], bytes[0..take]);
            const have = held.len + take;
            switch (codepoint(joined[0..have])) {
                .partial => {
                    @memcpy(s.held[0..have], joined[0..have]);
                    s.held_len = @intCast(have);
                    return;
                },
                .text => |n| {
                    try w.writeAll(joined[0..n]);
                    i = n - held.len;
                },
                .control => |n| i = n - held.len,
                .invalid => {
                    // Not UTF-8 after all: each held byte goes through as a
                    // byte that is not UTF-8 does, and the piece is read
                    // from its start.
                    for (held) |b| if (b >= 0xa0) try w.writeByte(b);
                },
            }
            s.held_len = 0;
        }

        while (i < bytes.len) {
            switch (s.state) {
                .text => i = try s.text(w, bytes, i),
                .escape => i = s.introduced(bytes, i),
                .csi_parameter => switch (bytes[i]) {
                    0x30...0x3f => i += 1,
                    0x20...0x2f => {
                        s.state = .csi_intermediate;
                        i += 1;
                    },
                    0x40...0x7e => {
                        s.state = .text;
                        i += 1;
                    },
                    // Abandoned: the byte is read again as what it begins.
                    else => s.state = .text,
                },
                .csi_intermediate => switch (bytes[i]) {
                    0x20...0x2f => i += 1,
                    0x40...0x7e => {
                        s.state = .text;
                        i += 1;
                    },
                    else => s.state = .text,
                },
                .string => {
                    const at = std.mem.findAny(u8, bytes[i..], &.{ seq.bel, seq.esc }) orelse return;
                    i += at + 1;
                    s.state = if (bytes[i - 1] == seq.bel) .text else .string_escape;
                },
                .string_escape => {
                    if (bytes[i] == '\\') {
                        s.state = .text;
                        i += 1;
                    } else {
                        // An `ESC` that is not `ST` ends the string unfinished
                        // and begins the next sequence.
                        s.state = .escape;
                    }
                },
                .intermediate => switch (bytes[i]) {
                    0x20...0x2f => i += 1,
                    0x30...0x7e => {
                        s.state = .text;
                        i += 1;
                    },
                    else => s.state = .text,
                },
            }
        }
    }

    fn assertValid(s: *const Stripper) void {
        std.debug.assert(s.held_len <= s.held.len);
        if (s.held_len != 0) {
            std.debug.assert(s.state == .text);
            std.debug.assert(codepoint(s.held[0..s.held_len]) == .partial);
        }
    }

    /// Ends the output. A sequence still open is dropped, as a terminal
    /// drops one; a codepoint cut short is written as the bytes it was.
    pub fn finish(s: *Stripper, w: *Writer) Writer.Error!void {
        s.assertValid();
        defer s.assertValid();
        const held = s.held;
        const len = s.held_len;
        s.* = .{};
        try w.writeAll(held[0..len]);
    }

    /// Text from `bytes[start..]` up to the next sequence, written; returns
    /// where reading goes on.
    fn text(s: *Stripper, w: *Writer, bytes: []const u8, start: usize) Writer.Error!usize {
        var i = start;
        while (i < bytes.len) {
            const run = plainRun(bytes[i..]);
            if (run != 0) {
                try w.writeAll(bytes[i..][0..run]);
                i += run;
                continue;
            }
            const b = bytes[i];
            if (b == seq.esc) {
                const rest = bytes[i..];
                if (rest.len >= 2) switch (rest[1]) {
                    '[' => if (framing.parseCsi(rest)) |c| {
                        i += c.len;
                        continue;
                    },
                    ']', 'P', 'X', '^', '_' => if (framing.parseControlString(rest)) |c| {
                        i += c.len;
                        continue;
                    },
                    else => {},
                };
                // Not whole in this piece, or not one the framers frame.
                s.state = .escape;
                return i + 1;
            }
            // Past ASCII: one codepoint.
            switch (codepoint(bytes[i..])) {
                .text => |n| {
                    try w.writeAll(bytes[i..][0..n]);
                    i += n;
                },
                .control => |n| i += n,
                .invalid => {
                    // A byte that is not UTF-8 goes through as it is,
                    // unless it is a C1 control in its eight-bit form.
                    if (b >= 0xa0) try w.writeByte(b);
                    i += 1;
                },
                .partial => {
                    const held = bytes[i..];
                    @memcpy(s.held[0..held.len], held);
                    s.held_len = @intCast(held.len);
                    return bytes.len;
                },
            }
        }
        return i;
    }

    /// Reads the byte after an `ESC`: what it introduces, from `bytes[i]`.
    fn introduced(s: *Stripper, bytes: []const u8, i: usize) usize {
        const b = bytes[i];
        if (b == '[') {
            s.state = .csi_parameter;
        } else if (b == ']' or b == 'P' or b == 'X' or b == '^' or b == '_') {
            s.state = .string;
        } else if (b >= 0x20 and b <= 0x2f) {
            s.state = .intermediate;
        } else if (b >= 0x30 and b <= 0x7e) {
            // A two-byte escape: `ESC 7`, `ESC c`, `ESC =`, `ESC O`.
            s.state = .text;
        } else {
            // An `ESC` that introduces nothing; the byte is read again.
            s.state = .text;
            return i;
        }
        return i + 1;
    }
};

/// How many bytes of `bytes` are printable ASCII, C0 controls and DEL --
/// none of them an `ESC` -- from the front.
fn plainRun(bytes: []const u8) usize {
    var i: usize = 0;
    if (std.simd.suggestVectorLength(u8)) |n| {
        const block_type = @Vector(n, u8);
        const esc: block_type = @splat(seq.esc);
        const high: block_type = @splat(0x80);
        while (i + n <= bytes.len) : (i += n) {
            const block: block_type = bytes[i..][0..n].*;
            const stop = (block == esc) | (block >= high);
            if (@reduce(.Or, stop)) break;
        }
    }
    while (i < bytes.len and bytes[i] != seq.esc and bytes[i] < 0x80) i += 1;
    return i;
}

/// What the codepoint at the front of `bytes` is, which starts at or past
/// 0x80.
const Codepoint = union(enum) {
    /// Text this many bytes long.
    text: usize,
    /// A C1 control, U+0080 to U+009F, this many bytes long.
    control: usize,
    /// Not UTF-8 at its first byte.
    invalid,
    /// UTF-8 so far, and cut short.
    partial,
};

fn codepoint(bytes: []const u8) Codepoint {
    const n = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return .invalid;
    if (n == 1) return .{ .text = 1 };
    if (bytes.len < n) {
        // Only cut short if what is there is a valid start.
        for (bytes[1..]) |b| if (b & 0xc0 != 0x80) return .invalid;
        return .partial;
    }
    const cp = utf8.decode(bytes[0..n]) catch return .invalid;
    if (cp >= 0x80 and cp <= 0x9f) return .{ .control = n };
    return .{ .text = n };
}

/// Strips control sequences and C1 controls from `text` into `out`, in one
/// call, and returns the text left. `out` may be `text` itself; the result
/// is never longer than `text`, and `NoSpaceLeft` is returned, before
/// anything is written, when `out` is shorter than that. A sequence `text`
/// ends inside is dropped, and a codepoint it cuts short is kept.
pub fn strip(out: []u8, text: []const u8) error{NoSpaceLeft}![]u8 {
    if (out.len < text.len) return error.NoSpaceLeft;
    var into: InPlace = .{ .out = out };
    var s: Stripper = .{};
    s.feed(&into.writer, text) catch unreachable; // unreachable: stripping only removes bytes and out is at least text.len bytes
    s.finish(&into.writer) catch unreachable; // unreachable: the retained prefix is part of text and stripping cannot expand it
    std.debug.assert(into.end <= text.len);
    return out[0..into.end];
}

/// A writer into `out` that buffers nothing and moves rather than copies,
/// so `out` may be the text being stripped: what `strip` writes never runs
/// ahead of what it has read, and `@memmove` onto bytes already read is
/// sound where `@memcpy` is not.
const InPlace = struct {
    out: []u8,
    end: usize = 0,
    writer: Writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const into: *InPlace = @alignCast(@fieldParentPtr("writer", w)); // safe: this vtable is only ever installed in InPlace.writer
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| n += try into.put(bytes);
        for (0..splat) |_| n += try into.put(data[data.len - 1]);
        return n;
    }

    fn put(into: *InPlace, bytes: []const u8) Writer.Error!usize {
        if (into.out.len - into.end < bytes.len) return error.WriteFailed;
        @memmove(into.out[into.end..][0..bytes.len], bytes);
        into.end += bytes.len;
        return bytes.len;
    }
};

//=========================================================================
// Tests.
//=========================================================================

const testing = std.testing;

fn expectStrip(expected: []const u8, text: []const u8) !void {
    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(expected, try strip(&buffer, text));
    // And the same, a byte at a time.
    var out: [256]u8 = undefined;
    var w: Writer = .fixed(&out);
    var s: Stripper = .{};
    for (text) |b| try s.feed(&w, &.{b});
    try s.finish(&w);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "styles, cursor moves and modes go, the text stays" {
    try expectStrip("bold plain", "\x1b[1mbold\x1b[0m plain");
    try expectStrip("ab", "a\x1b[38;2;255;128;0mb\x1b[?2026h");
    try expectStrip("x", "\x1b[12;40Hx\x1b[2J\x1b[>4;2m\x1b[ q");
}

test "control strings go whole, with either terminator" {
    try expectStrip("title", "\x1b]2;a title\x07title");
    try expectStrip("link", "\x1b]8;;https://ziglang.org\x1b\\link\x1b]8;;\x1b\\");
    try expectStrip("", "\x1b_Ga=T,f=32;AAAA\x1b\\\x1bP+q5463\x1b\\\x1b^pm\x1b\\\x1bXsos\x1b\\");
}

test "short escapes go, and an escape introducing nothing goes alone" {
    try expectStrip("ab", "\x1b7a\x1b8b");
    try expectStrip("text", "\x1b(Btext");
    try expectStrip("x", "\x1b=\x1b>\x1bcx");
    try expectStrip("A", "\x1bOA");
    // An ESC before a control: the ESC goes, the newline stays.
    try expectStrip("a\nb", "a\x1b\nb");
}

test "the C0 controls stay and the C1 controls go, in both spellings" {
    try expectStrip("a\r\n\tb\x07", "a\r\n\tb\x07");
    try expectStrip("ab", "a\u{9b}b");
    try expectStrip("ab", "a\x9bb");
    try expectStrip("a31mb", "a\x9b31mb");
    try expectStrip("\u{e9}\u{4e2d}\u{1f642}", "\u{e9}\u{4e2d}\u{1f642}");
    // Bytes that are not UTF-8 and not C1 go through as they are.
    try expectStrip("a\xffb\xc3", "a\xffb\xc3");
}

test "an abandoned sequence ends in front of the byte that abandoned it" {
    try expectStrip("\nx", "\x1b[12\nx");
    try expectStrip("x", "\x1b]0;tit\x1b[1mx");
    try expectStrip("x", "\x1b[1;2\x1b[mx");
}

test "a sequence still open at the end is dropped" {
    try expectStrip("a", "a\x1b[12");
    try expectStrip("a", "a\x1b]2;never ends");
    try expectStrip("a", "a\x1b");
}

test "a sequence cut anywhere strips the same as when it is whole" {
    const text = "x\x1b[1;31mred\x1b[0m \x1b]8;id=1;https://e.x\x1b\\\u{1f642}\x1b_Gq=2;AAAA\x07\u{9b}\x1b(0q\x1b7\xc3\xa9\x1b[?25l";
    var whole: [256]u8 = undefined;
    const expected = try strip(&whole, text);
    var cut: usize = 0;
    while (cut <= text.len) : (cut += 1) {
        var second: usize = cut;
        while (second <= text.len) : (second += 1) {
            var out: [256]u8 = undefined;
            var w: Writer = .fixed(&out);
            var s: Stripper = .{};
            try s.feed(&w, text[0..cut]);
            try s.feed(&w, text[cut..second]);
            try s.feed(&w, text[second..]);
            try s.finish(&w);
            try testing.expectEqualStrings(expected, w.buffered());
        }
    }
}

test "strip works in place and refuses a buffer shorter than the text" {
    var buffer = "\x1b[1mbold\x1b[0m".*;
    try testing.expectEqualStrings("bold", try strip(&buffer, &buffer));
    // A run of text longer than what was stripped before it lands on
    // itself, as do codepoints past ASCII and the bytes of one cut short.
    var long = "\x1b[1mhello world this is long text\x1b[0m".*;
    try testing.expectEqualStrings("hello world this is long text", try strip(&long, &long));
    var wide = "\x1b[1m\u{e9}t\u{e9} long enough to overlap\xc2\x85!\xe2\x82".*;
    try testing.expectEqualStrings("\u{e9}t\u{e9} long enough to overlap!\xe2\x82", try strip(&wide, &wide));
    var small: [3]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, strip(&small, "abcd"));
}

test "a long control string costs no buffer" {
    var out: [16]u8 = undefined;
    var w: Writer = .fixed(&out);
    var s: Stripper = .{};
    try s.feed(&w, "a\x1b_G;");
    var payload: [4096]u8 = @splat('A');
    var n: usize = 0;
    while (n < 256) : (n += 1) try s.feed(&w, &payload);
    try s.feed(&w, "\x1b\\b");
    try s.finish(&w);
    try testing.expectEqualStrings("ab", w.buffered());
}

test "fuzz Stripper" {
    // The properties: no input panics; the text never grows; it holds no
    // ESC; and any split of the input strips to what the whole of it does.
    try testing.fuzz({}, struct {
        fn one(_: void, smith: *testing.Smith) anyerror!void {
            var input: [256]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];
            var whole: [256]u8 = undefined;
            const expected = try strip(&whole, bytes);
            try testing.expect(expected.len <= bytes.len);
            try testing.expect(std.mem.findScalar(u8, expected, seq.esc) == null);
            const cut = if (bytes.len == 0) 0 else smith.value(u8) % (bytes.len + 1);
            var out: [256]u8 = undefined;
            var w: Writer = .fixed(&out);
            var s: Stripper = .{};
            try s.feed(&w, bytes[0..cut]);
            try s.feed(&w, bytes[cut..]);
            try s.finish(&w);
            try testing.expectEqualStrings(expected, w.buffered());
        }
    }.one, .{ .corpus = &.{
        corpus.seed("\x1b[1mbold\x1b[0m"),
        corpus.seed("\x1b]8;;u\x1b\\t\x1b]8;;\x1b\\"),
        corpus.seed("\u{9b}\xc2\x9b\x9b\xe2\x82"),
    } });
}
