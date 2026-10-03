//! libghostty-vt for the operations it has a standalone API for: encoding a
//! key (`input.encodeKey`, what tycho's bay calls today) and reading a
//! program's output (`Stream`, whose printed text is what `strip` leaves).
//! Pinned to the commit morse's conformance step and tycho pin.
const std = @import("std");
const m = @import("morse");
const ghostty = @import("vt");
const ops = @import("ops.zig");
const Writer = std.Io.Writer;

fn physical(c: u21) ghostty.input.Key {
    return if (c < 0x80) ghostty.input.Key.fromASCII(@intCast(c)) orelse .unidentified else .unidentified;
}

fn named(k: m.Key) ghostty.input.Key {
    return switch (k) {
        .enter => .enter,
        .tab => .tab,
        .backspace => .backspace,
        .escape => .escape,
        .up => .arrow_up,
        .left => .arrow_left,
        .home => .home,
        .page_up => .page_up,
        .delete => .delete,
        .f => |n| if (n == 1) .f1 else .f5,
        else => unreachable,
    };
}

/// The same key `ops.benchKey` builds, as ghostty's event: the physical
/// key, the text the layout types for it, and the unshifted codepoint.
fn event(v: u8, utf8: *[4]u8) ghostty.input.KeyEvent {
    const ours = ops.benchKey(v);
    var ev: ghostty.input.KeyEvent = .{
        .mods = .{ .shift = ours.mods.shift, .ctrl = ours.mods.ctrl, .alt = ours.mods.alt },
    };
    switch (ours.key) {
        .char => |c| {
            const typed = if (ours.mods.shift) ops.benchShifted(c) else c;
            const n = std.unicode.utf8Encode(typed, utf8) catch unreachable;
            ev.key = physical(c);
            ev.utf8 = utf8[0..n];
            ev.unshifted_codepoint = c;
            ev.consumed_mods = .{ .shift = ours.mods.shift };
        },
        else => ev.key = named(ours.key),
    }
    return ev;
}

fn encodeKey(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
    var utf8: [4]u8 = undefined;
    var opts: ghostty.input.KeyEncodeOptions = .{ .alt_esc_prefix = true, .macos_option_as_alt = .true };
    if (r[1] != 0) opts.kitty_flags = @bitCast(ops.bench_key_flags);
    try ghostty.input.encodeKey(w, event(r[0], &utf8), opts);
    return 0;
}

/// The text a `Stream` prints and the C0 controls a program writes into
/// text, into the writer.
const Printed = struct {
    w: *Writer,
    failed: bool = false,

    fn put(p: *Printed, cp: u21) void {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        p.w.writeAll(buf[0..n]) catch {
            p.failed = true;
        };
    }

    pub fn vt(p: *Printed, comptime action: ghostty.StreamAction.Tag, value: ghostty.StreamAction.Value(action)) void {
        switch (action) {
            .print => p.put(value.cp),
            .print_slice => for (value.cps) |cp| p.put(@intCast(cp)),
            .linefeed => p.put('\n'),
            .carriage_return => p.put('\r'),
            .horizontal_tab => p.put('\t'),
            .bell => p.put(0x07),
            else => {},
        }
    }
};

fn strip(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
    var printed: Printed = .{ .w = w };
    var stream: ghostty.Stream(*Printed) = .init(.{ .handler = &printed });
    stream.nextSlice(r);
    if (printed.failed) return error.WriteFailed;
    return 0;
}

pub const table = .{
    .{ "encodeKey", encodeKey },
    .{ "strip", strip },
};
