//! iTerm2's inline images, on the writing side: a file -- a PNG, a JPEG, a
//! GIF, anything the terminal's platform can draw -- sent in `OSC 1337`
//! and drawn at the cursor. iTerm2 reads it, and so do WezTerm, mintty,
//! Konsole, Warp and Rio.
//!
//! One file is one `OSC 1337 ; File = keys : base64 ST`. iTerm2 3.5 added
//! a form for files too big for one sequence, and for multiplexers that
//! cap a sequence's length: `MultipartFile = keys ST`, the base64 in
//! `FilePart = ... ST` pieces, and `FileEnd ST`.
//!
//! The file goes as it is: this package does not decode, scale or convert
//! images. The keys say how big to draw it and whether to keep its shape.
//!
//! Read against iTerm2's "Inline Images Protocol" documentation, 3.7.

const std = @import("std");
const base64 = @import("base64.zig");
const seq = @import("seq.zig");

const Writer = std.Io.Writer;

/// How big to draw an image in one direction, as the `width` and `height`
/// keys spell it.
pub const ItermSize = union(enum) {
    /// `auto`, the image's own size: the key is left out.
    auto,
    /// `N`: this many cells.
    cells: u32,
    /// `Npx`: this many pixels.
    pixels: u32,
    /// `N%`: this share of the session's width or height.
    percent: u32,
};

/// What travels with an inline file.
pub const ItermFile = struct {
    /// The `name` key: the file's name, written base64 encoded. Null leaves
    /// it out, and the terminal calls it "Unnamed file".
    name: ?[]const u8 = null,
    /// The `width` key.
    width: ItermSize = .auto,
    /// The `height` key.
    height: ItermSize = .auto,
    /// The `preserveAspectRatio` key: whether to fit the image inside the
    /// width and height rather than stretch it to them.
    preserve_aspect_ratio: bool = true,
    /// The `inline` key: draw the file. False downloads it instead.
    inline_image: bool = true,
    /// The `doNotMoveCursor` key: leave the cursor where it was rather than
    /// below the image. Newer than the rest; a terminal that does not know
    /// it moves the cursor.
    do_not_move_cursor: bool = false,
};

/// The file bytes one `FilePart` of `itermImageMultipart` carries: 3072,
/// which encodes to 4096 base64 characters, far inside the 1 MiB iTerm2
/// and current tmux allow a sequence.
pub const iterm_part_bytes: usize = 3072;

/// Sends a file to draw inline, in one sequence:
/// `OSC 1337 ; File = keys : base64 ST`.
///
/// The keys are written in a fixed order -- `size`, `name`, `width`,
/// `height`, `preserveAspectRatio`, `inline`, `doNotMoveCursor` -- each
/// left out at its default but `size`, which is always the length of
/// `data`. `data` is encoded straight into the writer.
pub fn itermImage(w: *Writer, file: ItermFile, data: []const u8) Writer.Error!void {
    return spellImage(w, file, data);
}

/// Sends a file to draw inline in pieces: `OSC 1337 ; MultipartFile = keys
/// ST`, then the base64 in `FilePart` sequences of `part_bytes` of the file
/// each, then `FileEnd`.
///
/// `part_bytes` is rounded down to a multiple of three, and up to three if
/// it is less, so every piece but the last is whole base64 and the pieces
/// join into the encoding of the file; `iterm_part_bytes` is a size that
/// passes everything current, and 150 keeps each sequence under the 256
/// bytes an older tmux allows. Nothing else may be written in between.
pub fn itermImageMultipart(w: *Writer, file: ItermFile, data: []const u8, part_bytes: usize) Writer.Error!void {
    return spellMultipart(w, file, data, part_bytes);
}

/// How many bytes the iTerm2 writers write, by running the same code into a
/// counter.
pub const cost = struct {
    /// `itermImage`.
    pub fn itermImage(file: ItermFile, data: []const u8) usize {
        return seq.count(spellImage, .{ file, data });
    }

    /// `itermImageMultipart`.
    pub fn itermImageMultipart(file: ItermFile, data: []const u8, part_bytes: usize) usize {
        return seq.count(spellMultipart, .{ file, data, part_bytes });
    }
};

fn spellImage(w: anytype, file: ItermFile, data: []const u8) !void {
    try w.writeAll(seq.osc ++ "1337;File=");
    try writeKeys(w, file, data.len);
    try w.writeByte(':');
    try writeBase64(w, data);
    try w.writeAll(seq.st);
}

fn spellMultipart(w: anytype, file: ItermFile, data: []const u8, part_bytes: usize) !void {
    const part = @max(3, part_bytes / 3 * 3);
    try w.writeAll(seq.osc ++ "1337;MultipartFile=");
    try writeKeys(w, file, data.len);
    try w.writeAll(seq.st);
    var at: usize = 0;
    while (at < data.len) {
        const end = @min(at + part, data.len);
        try w.writeAll(seq.osc ++ "1337;FilePart=");
        try writeBase64(w, data[at..end]);
        try w.writeAll(seq.st);
        at = end;
    }
    try w.writeAll(seq.osc ++ "1337;FileEnd" ++ seq.st);
}

/// The `key=value` list, `;` between keys.
fn writeKeys(w: anytype, file: ItermFile, size: usize) !void {
    try w.writeAll("size=");
    try seq.writeInt(w, size);
    if (file.name) |name| {
        try w.writeAll(";name=");
        try writeBase64(w, name);
    }
    try writeSize(w, "width", file.width);
    try writeSize(w, "height", file.height);
    if (!file.preserve_aspect_ratio) try w.writeAll(";preserveAspectRatio=0");
    if (file.inline_image) try w.writeAll(";inline=1");
    if (file.do_not_move_cursor) try w.writeAll(";doNotMoveCursor=1");
}

fn writeSize(w: anytype, comptime key: []const u8, size: ItermSize) !void {
    const value, const unit = switch (size) {
        .auto => return,
        .cells => |n| .{ n, "" },
        .pixels => |n| .{ n, "px" },
        .percent => |n| .{ n, "%" },
    };
    try w.writeAll(";" ++ key ++ "=");
    try seq.writeInt(w, value);
    try w.writeAll(unit);
}

fn writeBase64(w: anytype, bytes: []const u8) !void {
    if (@TypeOf(w) == *seq.Count) {
        w.n += base64.encodedLen(bytes.len);
    } else {
        try base64.write(w, bytes);
    }
}

//=========================================================================
// Tests.
//=========================================================================

const testing = std.testing;

fn expectImage(expected: []const u8, file: ItermFile, data: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try itermImage(&w, file, data);
    try testing.expectEqualStrings(expected, w.buffered());
    try testing.expectEqual(w.buffered().len, cost.itermImage(file, data));
}

test "an inline file is its size, the inline key and its base64" {
    try expectImage("\x1b]1337;File=size=3;inline=1:YWJj\x1b\\", .{}, "abc");
    try expectImage("\x1b]1337;File=size=0;inline=1:\x1b\\", .{}, "");
}

test "every key is written in its order, and left out at its default" {
    try expectImage(
        "\x1b]1337;File=size=1;name=YS5wbmc=;width=10;height=50%;preserveAspectRatio=0;inline=1;doNotMoveCursor=1:eA==\x1b\\",
        .{
            .name = "a.png",
            .width = .{ .cells = 10 },
            .height = .{ .percent = 50 },
            .preserve_aspect_ratio = false,
            .do_not_move_cursor = true,
        },
        "x",
    );
    try expectImage("\x1b]1337;File=size=1;width=64px:eA==\x1b\\", .{ .width = .{ .pixels = 64 }, .inline_image = false }, "x");
}

test "a multipart file joins its pieces into the file's base64" {
    var data: [10]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i);
    var buffer: [512]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try itermImageMultipart(&w, .{ .name = "n" }, &data, 4);
    try testing.expectEqualStrings(
        "\x1b]1337;MultipartFile=size=10;name=bg==;inline=1\x1b\\" ++
            "\x1b]1337;FilePart=AAEC\x1b\\" ++
            "\x1b]1337;FilePart=AwQF\x1b\\" ++
            "\x1b]1337;FilePart=BgcI\x1b\\" ++
            "\x1b]1337;FilePart=CQ==\x1b\\" ++
            "\x1b]1337;FileEnd\x1b\\",
        w.buffered(),
    );
    try testing.expectEqual(w.buffered().len, cost.itermImageMultipart(.{ .name = "n" }, &data, 4));

    // The pieces are the base64 of the whole file, cut.
    var joined: [64]u8 = undefined;
    var n: usize = 0;
    var rest = w.buffered();
    while (std.mem.indexOf(u8, rest, "FilePart=")) |at| {
        rest = rest[at + "FilePart=".len ..];
        const end = std.mem.indexOf(u8, rest, "\x1b\\").?;
        @memcpy(joined[n..][0..end], rest[0..end]);
        n += end;
    }
    var whole: [64]u8 = undefined;
    try testing.expectEqualStrings(std.base64.standard.Encoder.encode(&whole, &data), joined[0..n]);
}

test "an empty multipart file is its header and its end" {
    var buffer: [128]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try itermImageMultipart(&w, .{}, "", iterm_part_bytes);
    try testing.expectEqualStrings("\x1b]1337;MultipartFile=size=0;inline=1\x1b\\\x1b]1337;FileEnd\x1b\\", w.buffered());
}
