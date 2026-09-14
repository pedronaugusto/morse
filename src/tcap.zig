//! XTGETTCAP: asking the terminal for a terminfo capability by name.
//!
//! The missing member of the ask-the-terminal family. `queryMode` asks
//! whether a mode is implemented and `queryDeviceAttributes` asks what the
//! terminal is; this asks for the value of a named capability -- `Co` for the
//! colour count, `TN` for the terminal's own name, `kend` for the bytes the
//! End key sends -- from the terminal that is actually on the far end of the
//! pipe rather than from a database on this machine that may describe a
//! different one.
//!
//! Names and values travel as hexadecimal, two digits a byte, because a
//! capability's value is itself full of the control bytes that would end the
//! sequence carrying it. Nothing here allocates, so the decoders write into a
//! buffer the caller sizes and owns.
//!
//! Terminals disagree about which names they answer to: the two-letter
//! termcap names and the longer terminfo names are both in use, and a
//! terminal that knows neither answers `DCS 0 + r ... ST` or says nothing at
//! all. Ask for what you need, pair it with a query that is always answered,
//! and treat silence as a no.

const std = @import("std");
const corpus = @import("corpus.zig");
const seq = @import("seq.zig");

const Writer = std.Io.Writer;

/// Asks the terminal for one capability: `DCS + q <name in hex> ST`.
///
/// `name` is the capability's name as text -- `"Co"`, `"TN"`, `"kend"` --
/// and is hex encoded here, so a caller never spells the digits itself. It is
/// written through byte for byte otherwise: a name containing something that
/// is not a capability name produces a query the terminal refuses, which is
/// the same answer it gives for a name it does not know.
///
/// The answer arrives on the terminal's input as a sequence
/// `parseCapabilityReply` reads. Terminals without XTGETTCAP answer nothing.
pub fn queryCapability(w: *Writer, name: []const u8) Writer.Error!void {
    try w.writeAll(seq.dcs ++ "+q");
    try writeHex(w, name);
    try w.writeAll(seq.st);
}

/// Asks for several capabilities in one sequence, the names separated by `;`.
///
/// One round trip rather than several, which matters because each of them
/// costs a timeout on a terminal that does not answer. A terminal that knows
/// some of the names and not the others answers the ones it knows and refuses
/// the rest, in replies that may arrive separately -- so match each reply's
/// names against what was asked rather than assuming an order.
///
/// An empty list writes a query naming nothing, which is a question with no
/// useful answer rather than an error.
pub fn queryCapabilities(w: *Writer, names: []const []const u8) Writer.Error!void {
    try w.writeAll(seq.dcs ++ "+q");
    for (names, 0..) |name, i| {
        if (i != 0) try w.writeByte(';');
        try writeHex(w, name);
    }
    try w.writeAll(seq.st);
}

/// Writes `bytes` as lowercase hexadecimal, two digits a byte.
fn writeHex(w: *Writer, bytes: []const u8) Writer.Error!void {
    for (bytes) |b| try w.print("{x:0>2}", .{b});
}

/// One capability out of a reply, with both halves still in hexadecimal.
///
/// Both slices borrow from the bytes `parseCapabilityReply` was given and are
/// valid for exactly as long as they are. They are left encoded because
/// decoding needs somewhere to put the result, and this package does not
/// decide where that is: `decodeName` and `decodeValue` write into a buffer
/// the caller sizes from `nameLen` and `valueLen`.
pub const Capability = struct {
    /// The capability's name, in hex. Never empty.
    name: []const u8,
    /// The capability's value, in hex, or null when the reply carried no `=`
    /// at all -- which is how a terminal spells both a capability that is a
    /// flag and a name it is refusing.
    value: ?[]const u8,

    /// The exact number of bytes `decodeName` will write.
    pub fn nameLen(cap: Capability) usize {
        return cap.name.len / 2;
    }

    /// The exact number of bytes `decodeValue` will write. Zero for a
    /// capability with no value at all.
    pub fn valueLen(cap: Capability) usize {
        const value = cap.value orelse return 0;
        return value.len / 2;
    }

    /// Decodes the name into `out` and returns the prefix of `out` written --
    /// always exactly `nameLen()` bytes.
    ///
    /// `out` stays the caller's; nothing is allocated. The only failure is an
    /// `out` too small.
    pub fn decodeName(cap: Capability, out: []u8) error{NoSpaceLeft}![]u8 {
        return decodeHex(cap.name, out);
    }

    /// Decodes the value into `out`, as `decodeName` does the name. A
    /// capability whose `value` is null decodes to an empty slice, so check
    /// that field first if the difference matters.
    pub fn decodeValue(cap: Capability, out: []u8) error{NoSpaceLeft}![]u8 {
        const value: []const u8 = cap.value orelse "";
        return decodeHex(value, out);
    }
};

/// A terminal's answer to `queryCapability`.
pub const CapabilityReply = struct {
    /// True when the terminal answered `1`: it knows the capabilities the
    /// reply names. False for the `0` form, which is a refusal and carries
    /// the names asked for and no values.
    known: bool,
    /// The `name=value` list, still hex, borrowed from the bytes the reply
    /// was parsed from. Walk it with `iterator`.
    entries: []const u8,

    /// The capabilities this reply carries, in the order the terminal sent
    /// them.
    pub fn iterator(reply: CapabilityReply) Capabilities {
        return .{ .rest = reply.entries };
    }
};

/// The capabilities in one reply, one at a time.
///
/// Every entry was checked by `parseCapabilityReply`, so iterating cannot
/// fail and `next` returns a `Capability` rather than an optional one of
/// those inside an optional.
pub const Capabilities = struct {
    /// What is left of the reply's entry list.
    rest: []const u8,

    /// The next capability, or null at the end of the reply.
    pub fn next(it: *Capabilities) ?Capability {
        if (it.rest.len == 0) return null;
        const end = std.mem.indexOfScalar(u8, it.rest, ';') orelse it.rest.len;
        const entry = it.rest[0..end];
        it.rest = if (end == it.rest.len) it.rest[end..] else it.rest[end + 1 ..];
        // Checked at parse time, which is what lets this be infallible.
        return parseEntry(entry).?;
    }
};

/// Reads an XTGETTCAP reply: `DCS 1 + r <name>=<value> ST` for a terminal
/// that knows the capability, `DCS 0 + r <name> ST` for one that does not.
///
/// Several capabilities may share a reply, separated by `;`. Every name and
/// every value is checked to be an even run of hex digits here, so walking
/// the result with `CapabilityReply.iterator` and decoding what it yields
/// cannot fail on content.
///
/// A reply carrying no entries at all is valid and comes back with an empty
/// list, because that is what a terminal refusing a query for nothing sends.
/// Returns null for anything else, a reply cut short of its terminator
/// included. `bytes` must be exactly the sequence, with nothing before or
/// after it.
pub fn parseCapabilityReply(bytes: []const u8) ?CapabilityReply {
    if (!std.mem.startsWith(u8, bytes, seq.dcs)) return null;
    var rest = bytes[seq.dcs.len..];

    if (rest.len == 0) return null;
    const known = switch (rest[0]) {
        '0' => false,
        '1' => true,
        else => return null,
    };
    rest = rest[1..];

    if (!std.mem.startsWith(u8, rest, "+r")) return null;
    rest = rest[2..];

    const entries = seq.stripStringTerminator(rest) orelse return null;

    // Every entry is checked now so that the iterator cannot fail later. The
    // walk is the same one `Capabilities.next` makes, and an empty entry --
    // a stray `;`, at either end of the list or in the middle -- is a reject
    // rather than a silently skipped one.
    var scan = entries;
    while (scan.len != 0) {
        const end = std.mem.indexOfScalar(u8, scan, ';') orelse scan.len;
        _ = parseEntry(scan[0..end]) orelse return null;
        if (end == scan.len) break;
        scan = scan[end + 1 ..];
        // A separator with nothing behind it ends nothing: the list is
        // malformed, and accepting it would make the iterator's "empty means
        // done" and the reply's entry count disagree.
        if (scan.len == 0) return null;
    }

    return .{ .known = known, .entries = entries };
}

/// Reads one `name=value` entry, or `name` on its own, checking both halves
/// are hex. Returns null for an empty name, odd-length hex, or a byte that is
/// not a hex digit.
fn parseEntry(entry: []const u8) ?Capability {
    const split = std.mem.indexOfScalar(u8, entry, '=');
    const name = if (split) |i| entry[0..i] else entry;
    if (name.len == 0 or !isHex(name)) return null;
    if (split) |i| {
        const value = entry[i + 1 ..];
        if (!isHex(value)) return null;
        return .{ .name = name, .value = value };
    }
    return .{ .name = name, .value = null };
}

/// Whether `text` is an even-length run of hex digits, in either case. An
/// empty string is, which is what makes `name=` a capability with an empty
/// value rather than a malformed entry.
fn isHex(text: []const u8) bool {
    if (text.len % 2 != 0) return false;
    for (text) |c| {
        _ = std.fmt.charToDigit(c, 16) catch return false;
    }
    return true;
}

/// Decodes an even-length run of hex digits into `out`.
///
/// The precondition -- even length, hex digits only -- is what
/// `parseCapabilityReply` establishes, so this cannot fail on content and the
/// only error is an `out` too small. A `Capability` built by hand rather than
/// parsed must hold the same thing.
fn decodeHex(hex: []const u8, out: []u8) error{NoSpaceLeft}![]u8 {
    std.debug.assert(hex.len % 2 == 0);
    const len = hex.len / 2;
    if (out.len < len) return error.NoSpaceLeft;
    for (0..len) |i| {
        const high = std.fmt.charToDigit(hex[i * 2], 16) catch unreachable;
        const low = std.fmt.charToDigit(hex[i * 2 + 1], 16) catch unreachable;
        out[i] = @as(u8, high) * 16 + low;
    }
    return out[0..len];
}

/// Whether `inner` points into `outer`.
///
/// Test support: what the fuzz test checks in place of a round trip for the
/// halves a reply hands back without copying.
fn borrows(outer: []const u8, inner: []const u8) bool {
    const start = @intFromPtr(outer.ptr);
    const at = @intFromPtr(inner.ptr);
    return at >= start and at + inner.len <= start + outer.len;
}

test "queryCapability spells the name in hex" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    // 'C' is 0x43 and 'o' is 0x6f.
    try queryCapability(&out.writer, "Co");
    try std.testing.expectEqualStrings("\x1bP+q436f\x1b\\", out.written());
}

test "queryCapability writes two lowercase digits for every byte" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    // A byte below 16 is the one a single-digit encoder gets wrong.
    try queryCapability(&out.writer, "\x00\x0f\xff");
    try std.testing.expectEqualStrings("\x1bP+q000fff\x1b\\", out.written());
}

test "queryCapabilities separates the names with a semicolon" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try queryCapabilities(&out.writer, &.{ "Co", "TN" });
    try std.testing.expectEqualStrings("\x1bP+q436f;544e\x1b\\", out.written());
}

test "queryCapabilities writes one name without a separator, and none for none" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try queryCapabilities(&out.writer, &.{"Co"});
    try queryCapabilities(&out.writer, &.{});
    try std.testing.expectEqualStrings("\x1bP+q436f\x1b\\\x1bP+q\x1b\\", out.written());
}

test "queryCapability accepts an empty name" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try queryCapability(&out.writer, "");
    try std.testing.expectEqualStrings("\x1bP+q\x1b\\", out.written());
}

test "parseCapabilityReply reads a name and a value the terminal knows" {
    // Co=256.
    const reply = parseCapabilityReply("\x1bP1+r436f=323536\x1b\\").?;
    try std.testing.expect(reply.known);

    var it = reply.iterator();
    const cap = it.next().?;
    try std.testing.expectEqual(@as(usize, 2), cap.nameLen());
    try std.testing.expectEqual(@as(usize, 3), cap.valueLen());

    var name: [8]u8 = undefined;
    var value: [8]u8 = undefined;
    try std.testing.expectEqualStrings("Co", try cap.decodeName(&name));
    try std.testing.expectEqualStrings("256", try cap.decodeValue(&value));
    try std.testing.expectEqual(@as(?Capability, null), it.next());
}

test "parseCapabilityReply reads a value full of the bytes that would end it" {
    // kend=ESC O F, which is why the encoding is hex in the first place.
    const reply = parseCapabilityReply("\x1bP1+r6b656e64=1b4f46\x1b\\").?;
    var it = reply.iterator();
    const cap = it.next().?;

    var name: [8]u8 = undefined;
    var value: [8]u8 = undefined;
    try std.testing.expectEqualStrings("kend", try cap.decodeName(&name));
    try std.testing.expectEqualStrings("\x1bOF", try cap.decodeValue(&value));
}

test "parseCapabilityReply reads several capabilities out of one reply" {
    const reply = parseCapabilityReply("\x1bP1+r436f=323536;544e=7874657270\x1b\\").?;
    var it = reply.iterator();

    var name: [8]u8 = undefined;
    var value: [8]u8 = undefined;
    const first = it.next().?;
    try std.testing.expectEqualStrings("Co", try first.decodeName(&name));
    try std.testing.expectEqualStrings("256", try first.decodeValue(&value));

    const second = it.next().?;
    try std.testing.expectEqualStrings("TN", try second.decodeName(&name));
    try std.testing.expectEqualStrings("xterp", try second.decodeValue(&value));
    try std.testing.expectEqual(@as(?Capability, null), it.next());
}

test "parseCapabilityReply reads a refusal, which carries no value" {
    const reply = parseCapabilityReply("\x1bP0+r6e6f7065\x1b\\").?;
    try std.testing.expect(!reply.known);

    var it = reply.iterator();
    const cap = it.next().?;
    try std.testing.expectEqual(@as(?[]const u8, null), cap.value);
    try std.testing.expectEqual(@as(usize, 0), cap.valueLen());

    var name: [8]u8 = undefined;
    var value: [8]u8 = undefined;
    try std.testing.expectEqualStrings("nope", try cap.decodeName(&name));
    try std.testing.expectEqualStrings("", try cap.decodeValue(&value));
}

test "parseCapabilityReply tells an empty value from no value at all" {
    const empty = parseCapabilityReply("\x1bP1+r436f=\x1b\\").?;
    var with = empty.iterator();
    try std.testing.expectEqualStrings("", with.next().?.value.?);

    const flag = parseCapabilityReply("\x1bP1+r436f\x1b\\").?;
    var without = flag.iterator();
    try std.testing.expectEqual(@as(?[]const u8, null), without.next().?.value);
}

test "parseCapabilityReply reads a reply carrying nothing at all" {
    const reply = parseCapabilityReply("\x1bP0+r\x1b\\").?;
    try std.testing.expect(!reply.known);
    var it = reply.iterator();
    try std.testing.expectEqual(@as(?Capability, null), it.next());
}

test "parseCapabilityReply accepts BEL where a terminal uses it instead of ST" {
    const reply = parseCapabilityReply("\x1bP1+r436f=323536\x07").?;
    var it = reply.iterator();
    var value: [8]u8 = undefined;
    try std.testing.expectEqualStrings("256", try it.next().?.decodeValue(&value));
}

test "parseCapabilityReply reads hex in either case" {
    const reply = parseCapabilityReply("\x1bP1+r4B454E44=1B4F46\x1b\\").?;
    var it = reply.iterator();
    const cap = it.next().?;

    var name: [8]u8 = undefined;
    var value: [8]u8 = undefined;
    try std.testing.expectEqualStrings("KEND", try cap.decodeName(&name));
    try std.testing.expectEqualStrings("\x1bOF", try cap.decodeValue(&value));
}

test "parseCapabilityReply borrows both halves from the bytes it was given" {
    const bytes = "\x1bP1+r436f=323536\x1b\\";
    const reply = parseCapabilityReply(bytes).?;
    try std.testing.expect(borrows(bytes, reply.entries));

    var it = reply.iterator();
    const cap = it.next().?;
    try std.testing.expect(borrows(bytes, cap.name));
    try std.testing.expect(borrows(bytes, cap.value.?));
}

test "parseCapabilityReply returns null on anything it does not recognise" {
    const rejected = [_][]const u8{
        "", // nothing at all
        "\x1bP", // the introducer alone
        "\x1bP1+r436f=323536", // no terminator
        "\x1bP1+r436f=323536\x1b", // half a terminator
        "\x1b[1+r436f\x1b\\", // CSI, not DCS
        "\x1bP2+r436f\x1b\\", // neither 0 nor 1
        "\x1bP+r436f\x1b\\", // no status at all
        "\x1bP1r436f\x1b\\", // no `+`
        "\x1bP1+q436f\x1b\\", // the query's final byte, not the reply's
        "\x1bP1+r43\x2b6f\x1b\\", // a `+` where a hex digit belongs
        "\x1bP1+r436\x1b\\", // an odd number of digits in a name
        "\x1bP1+r436f=32353\x1b\\", // an odd number of digits in a value
        "\x1bP1+r436g\x1b\\", // a digit that is not hex
        "\x1bP1+r=323536\x1b\\", // a value with no name
        "\x1bP1+r436f=32=36\x1b\\", // two values for one name
        "\x1bP1+r436f;\x1b\\", // a trailing separator and no entry after it
        "\x1bP1+r;436f\x1b\\", // a leading separator
        "\x1bP1+r436f;;544e\x1b\\", // an empty entry between two good ones
        "\x1bP1+r436f=323536\x1b\\x", // trailing rubbish
    };
    for (rejected) |bytes| {
        try std.testing.expect(parseCapabilityReply(bytes) == null);
    }
}

test "decoding into a buffer that is too small is the only failure there is" {
    const reply = parseCapabilityReply("\x1bP1+r436f=323536\x1b\\").?;
    var it = reply.iterator();
    const cap = it.next().?;

    var name: [1]u8 = undefined;
    var value: [2]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, cap.decodeName(&name));
    try std.testing.expectError(error.NoSpaceLeft, cap.decodeValue(&value));

    // Exactly the length the reply promised is enough, and no more is needed.
    var exact: [3]u8 = undefined;
    try std.testing.expectEqualStrings("256", try cap.decodeValue(exact[0..cap.valueLen()]));
}

test "a name queried and a name parsed back agree on the bytes between them" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    // Every byte value, in the query's encoder and then the reply's decoder.
    var all: [256]u8 = undefined;
    for (&all, 0..) |*b, i| b.* = @intCast(i);
    try queryCapability(&out.writer, &all);

    // The query and the reply differ only in the `+q` and the status, so the
    // hex the encoder wrote is exactly what the decoder is handed.
    const hex = out.written()["\x1bP+q".len .. out.written().len - seq.st.len];
    var reply: Writer.Allocating = .init(std.testing.allocator);
    defer reply.deinit();
    try reply.writer.writeAll("\x1bP1+r");
    try reply.writer.writeAll(hex);
    try reply.writer.writeAll(seq.st);

    const parsed = parseCapabilityReply(reply.written()).?;
    var it = parsed.iterator();
    const cap = it.next().?;
    var decoded: [256]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &all, try cap.decodeName(&decoded));
}

test "fuzz parseCapabilityReply" {
    // The property: no input panics, every entry that parses has a non-empty
    // name and decodes to exactly the length it promised, and every half
    // re-encodes -- through the same hex writer the query uses -- to the
    // digits it came from. That is the codec checked in both directions on
    // inputs no test author enumerated, and it is why an odd-length or
    // non-hex field has to be refused at parse time rather than at decode.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [64]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];

            const reply = parseCapabilityReply(bytes) orelse return;
            try std.testing.expect(borrows(bytes, reply.entries));

            var it = reply.iterator();
            while (it.next()) |cap| {
                try std.testing.expect(cap.name.len != 0);
                try std.testing.expect(borrows(bytes, cap.name));
                if (cap.value) |value| try std.testing.expect(borrows(bytes, value));

                // Every field is inside a 64-byte input, so half of one fits.
                var name: [32]u8 = undefined;
                var value: [32]u8 = undefined;
                const decoded_name = try cap.decodeName(&name);
                const decoded_value = try cap.decodeValue(&value);
                try std.testing.expectEqual(cap.nameLen(), decoded_name.len);
                try std.testing.expectEqual(cap.valueLen(), decoded_value.len);

                var output: [64]u8 = undefined;
                var w: Writer = .fixed(&output);
                try writeHex(&w, decoded_name);
                try writeHex(&w, decoded_value);
                var expected: [64]u8 = undefined;
                var e: Writer = .fixed(&expected);
                try e.writeAll(cap.name);
                const raw_value: []const u8 = cap.value orelse "";
                try e.writeAll(raw_value);
                try std.testing.expect(std.ascii.eqlIgnoreCase(e.buffered(), w.buffered()));
            }

            // And the whole reply, rebuilt from what was read out of it.
            var output: [96]u8 = undefined;
            var w: Writer = .fixed(&output);
            try w.writeAll(seq.dcs);
            try w.writeByte(if (reply.known) '1' else '0');
            try w.writeAll("+r");
            try w.writeAll(reply.entries);
            try w.writeAll(seq.st);
            const again = parseCapabilityReply(w.buffered()).?;
            try std.testing.expectEqual(reply.known, again.known);
            try std.testing.expectEqualStrings(reply.entries, again.entries);
        }
    }.one, .{ .corpus = &.{
        corpus.seed("\x1bP1+r436f=323536\x1b\\"),
        corpus.seed("\x1bP1+r6b656e64=1b4f46\x1b\\"),
        corpus.seed("\x1bP1+r436f=323536;544e=7874657270\x07"),
        corpus.seed("\x1bP0+r6e6f7065\x1b\\"),
        corpus.seed("\x1bP1+r4B454E44=1B4F46\x1b\\"),
        corpus.seed("\x1bP1+r436f=\x1b\\"),
        corpus.seed("\x1bP0+r\x1b\\"),
        corpus.seed("\x1bP1+r436\x1b\\"),
        corpus.seed("\x1bP1+r436g\x1b\\"),
        corpus.seed("\x1bP1+r;436f\x1b\\"),
        corpus.seed("\x1bP2+r436f\x1b\\"),
        corpus.seed("\x1bP1+r436f=323536"),
    } });
}
