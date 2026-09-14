//! Asking the terminal what it is, and reading the answers.
//!
//! These are the questions whose answers a program has to have before it can
//! decide what to draw with: which sequences the terminal implements, which
//! terminal it is, what colours the user has it set to, whether the kitty
//! keyboard protocol is there at all, and whether a graphics command landed.
//!
//! Every one of them can go unanswered. A terminal that does not implement a
//! query says nothing — no error, no empty reply, nothing on the input at
//! all — which is itself the answer, and the only way to read it is to stop
//! waiting. None of these may be waited on without a timeout the caller owns.

const std = @import("std");
const corpus = @import("corpus.zig");
const mode = @import("mode.zig");
const seq = @import("seq.zig");
const style = @import("style.zig");

const Writer = std.Io.Writer;

/// The kitty keyboard flags, which belong with the sequences that set them.
/// Aliased so `parseKittyKeyboardReply` reads as one line.
const KittyFlags = mode.KittyFlags;

/// The eight-bit colour `Rgb16.to8` produces. The same type an SGR colour is
/// written from, because a background the terminal reported and a background
/// the program draws are the same kind of thing.
const Rgb = style.Rgb;

/// `APC`, the application program command introducer, spelled `ESC _`. Not in
/// `seq` because the kitty graphics response is the only APC this package
/// reads.
const apc = [_]u8{ seq.esc, '_' };

//=========================================================================
// Primary device attributes.
//=========================================================================

/// Asks what the terminal is and what it implements, DA1: `CSI c`.
///
/// The oldest query there is, and the one nearly every terminal answers,
/// which makes it the usual companion to a query that might not be answered:
/// send both, and a DA1 reply arriving alone says the other went unanswered
/// rather than that the terminal is merely slow.
pub fn queryDeviceAttributes(w: *Writer) Writer.Error!void {
    try w.writeAll(seq.csi ++ "c");
}

/// A terminal's answer to `queryDeviceAttributes`.
pub const DeviceAttributes = struct {
    /// The most attributes a DA1 reply may carry and still be one this
    /// package hands back.
    ///
    /// Terminals in the wild send a dozen or so. The cap is what lets the
    /// reply be a value rather than an allocation, and a longer reply is
    /// refused rather than truncated, because a silently shortened capability
    /// list is worse than no list.
    pub const max_attributes = 32;

    /// The terminal class the emulator claims to be compatible with: 1 is a
    /// VT100, 62 a VT220, 64 a VT420, 65 a VT510 or later. Emulators pick the
    /// class whose sequences they implement, so this says more about the
    /// sequence set than about the program on the other end.
    class: u16,
    /// Storage for the attributes; read them with `list`. Fixed so the reply
    /// is a value, and zeroed so two replies carrying the same attributes
    /// compare equal whatever was in the unused tail.
    attribute_storage: [max_attributes]u16 = @splat(0),
    /// How many of `attribute_storage` the terminal sent. Never more than
    /// `max_attributes`, because a longer reply is refused outright.
    attribute_count: u8 = 0,

    /// The extensions the terminal claims, in the order it sent them.
    ///
    /// The order is the terminal's and carries no meaning; use `has` to ask
    /// about one. Borrows from `da`, so it is valid for as long as the
    /// `DeviceAttributes` it was taken from.
    pub fn list(da: *const DeviceAttributes) []const u16 {
        return da.attribute_storage[0..da.attribute_count];
    }

    /// Whether the terminal claimed `attribute`.
    ///
    /// The numbers worth asking about are 4, Sixel graphics, and 22, ANSI
    /// colour. A terminal that omits an attribute may still implement the
    /// feature, so a false here is a reason to fall back rather than proof of
    /// absence.
    pub fn has(da: DeviceAttributes, attribute: u16) bool {
        return std.mem.indexOfScalar(u16, da.list(), attribute) != null;
    }
};

/// Reads a DA1 reply: `CSI ? class ; attributes... c`.
///
/// The attribute list may be empty, which is a terminal claiming a class and
/// no extensions. Returns null for anything else — a reply carrying more than
/// `DeviceAttributes.max_attributes` attributes, an empty parameter, a trailing `;`, or a
/// number too large for its field included. `bytes` must be exactly the
/// sequence, with nothing before or after it.
pub fn parseDeviceAttributes(bytes: []const u8) ?DeviceAttributes {
    const prefix = seq.csi ++ "?";
    if (!std.mem.startsWith(u8, bytes, prefix)) return null;
    var rest = bytes[prefix.len..];

    const class = seq.scanInt(u16, rest) orelse return null;
    rest = rest[class.len..];

    var da: DeviceAttributes = .{ .class = class.value };
    while (rest.len != 0 and rest[0] == ';') {
        rest = rest[1..];
        const attribute = seq.scanInt(u16, rest) orelse return null;
        rest = rest[attribute.len..];
        if (da.attribute_count == DeviceAttributes.max_attributes) return null;
        da.attribute_storage[da.attribute_count] = attribute.value;
        da.attribute_count += 1;
    }
    if (!std.mem.eql(u8, rest, "c")) return null;

    return da;
}

//=========================================================================
// Secondary device attributes.
//=========================================================================

/// Asks for the terminal's identity and version, DA2: `CSI > c`.
///
/// Where DA1 asks what sequences the terminal speaks, this asks which
/// terminal is speaking them. Fewer terminals answer, and those that do
/// answer with numbers they chose themselves.
pub fn querySecondaryDeviceAttributes(w: *Writer) Writer.Error!void {
    try w.writeAll(seq.csi ++ ">c");
}

/// A terminal's answer to `querySecondaryDeviceAttributes`.
pub const SecondaryDeviceAttributes = struct {
    /// Which terminal family the emulator reports itself as: 0 is a VT100,
    /// 1 a VT220, 41 a VT420, and emulators pick a number and keep it. Two
    /// unrelated emulators may well report the same one.
    terminal_type: u16,
    /// The version, in whatever numbering the terminal chose. Not comparable
    /// across terminals and not a version number a program should branch on
    /// without also knowing which terminal answered.
    version: u32,
    /// The keyboard or cartridge field, zero on everything modern, and zero
    /// here when the terminal sent only two parameters.
    keyboard: u16 = 0,
};

/// Reads a DA2 reply: `CSI > type ; version ; keyboard c`.
///
/// The third parameter is optional, because terminals do omit it; when it is
/// absent `keyboard` is zero, which is what every terminal that sends it
/// sends. Returns null for anything else. `bytes` must be exactly the
/// sequence, with nothing before or after it.
pub fn parseSecondaryDeviceAttributes(bytes: []const u8) ?SecondaryDeviceAttributes {
    const prefix = seq.csi ++ ">";
    if (!std.mem.startsWith(u8, bytes, prefix)) return null;
    var rest = bytes[prefix.len..];

    const terminal_type = seq.scanInt(u16, rest) orelse return null;
    rest = rest[terminal_type.len..];
    if (rest.len == 0 or rest[0] != ';') return null;
    rest = rest[1..];

    const version = seq.scanInt(u32, rest) orelse return null;
    rest = rest[version.len..];

    var keyboard: u16 = 0;
    if (rest.len != 0 and rest[0] == ';') {
        rest = rest[1..];
        const scan = seq.scanInt(u16, rest) orelse return null;
        rest = rest[scan.len..];
        keyboard = scan.value;
    }
    if (!std.mem.eql(u8, rest, "c")) return null;

    return .{
        .terminal_type = terminal_type.value,
        .version = version.value,
        .keyboard = keyboard,
    };
}

//=========================================================================
// XTVERSION.
//=========================================================================

/// Asks the terminal to name itself in words, XTVERSION: `CSI > 0 q`.
///
/// The only query here whose answer a human can read. Terminals that predate
/// it answer nothing, and a few answer the empty string.
pub fn queryVersion(w: *Writer) Writer.Error!void {
    try w.writeAll(seq.csi ++ ">0q");
}

/// Reads an XTVERSION reply: `DCS > | name ST`, returning the name.
///
/// The name is a sub-slice of `bytes`, borrowed rather than owned: it is
/// valid for exactly as long as they are. It is a free-form string the
/// terminal chose, such as `xterm(390)`, with no agreed grammar for the
/// version part and no guarantee two releases spell it the same way — match
/// against it only as a last resort, after DA1 and the mode queries have
/// failed to say what a program needs to know.
///
/// An empty name is a valid reply and comes back as an empty slice. Returns
/// null for anything else, a reply cut short of its terminator included.
/// `bytes` must be exactly the sequence, with nothing before or after it.
pub fn parseVersion(bytes: []const u8) ?[]const u8 {
    const prefix = seq.dcs ++ ">|";
    if (!std.mem.startsWith(u8, bytes, prefix)) return null;
    return seq.stripStringTerminator(bytes[prefix.len..]);
}

//=========================================================================
// The kitty keyboard flags reply.
//=========================================================================

/// Reads the reply to a kitty keyboard flags query: `CSI ? flags u`.
///
/// `mode.kittyKeyboardQuery` asks; a terminal without the protocol answers
/// nothing at all, which is how a program detects support. There is no writer
/// for this sequence here because a program does not send it: it is what a
/// terminal sends back.
///
/// The protocol defines five bits, so a value above 31 is not flags this
/// package hands back and returns null rather than a truncated set. `bytes`
/// must be exactly the sequence, with nothing before or after it.
pub fn parseKittyKeyboardReply(bytes: []const u8) ?KittyFlags {
    const prefix = seq.csi ++ "?";
    if (!std.mem.startsWith(u8, bytes, prefix)) return null;
    var rest = bytes[prefix.len..];

    const flags = seq.scanInt(u8, rest) orelse return null;
    rest = rest[flags.len..];
    if (!std.mem.eql(u8, rest, "u")) return null;
    if (flags.value > 31) return null;

    return KittyFlags.fromBits(@intCast(flags.value));
}

//=========================================================================
// The colours outside the palette, OSC 10, 11 and 12.
//=========================================================================

/// A terminal colour that is not part of the palette.
pub const ColorTarget = enum(u16) {
    /// The default foreground, OSC 10.
    foreground = 10,
    /// The default background, OSC 11. The one worth asking for: it is what a
    /// program reads to decide whether it is drawing on a light or a dark
    /// terminal, a question no environment variable answers reliably.
    background = 11,
    /// The cursor's colour, OSC 12.
    cursor = 12,
};

/// A colour with sixteen bits per channel, as OSC 10 and 11 carry it.
///
/// The width is the protocol's, not a claim about the display: terminals
/// answer with the user's eight-bit colour doubled far more often than with
/// anything finer.
pub const Rgb16 = struct {
    /// Red.
    r: u16,
    /// Green.
    g: u16,
    /// Blue.
    b: u16,

    /// The same colour with eight bits per channel, for a program whose own
    /// colours are eight-bit.
    ///
    /// The top byte of each channel, which maps 0xffff to 0xff exactly and so
    /// round trips a colour a terminal spelled by doubling its bytes.
    pub fn to8(c: Rgb16) Rgb {
        return .{
            .r = @truncate(c.r >> 8),
            .g = @truncate(c.g >> 8),
            .b = @truncate(c.b >> 8),
        };
    }
};

/// Asks the terminal for one of its colours: `OSC target ; ? ST`.
///
/// The answer arrives on the terminal's input as a sequence `parseColorReply`
/// reads. Terminals that do not implement the query answer nothing.
pub fn queryColor(w: *Writer, target: ColorTarget) Writer.Error!void {
    try w.writeAll(seq.osc);
    try w.print("{d};?", .{@intFromEnum(target)});
    try w.writeAll(seq.st);
}

/// Sets one of the terminal's colours: `OSC target ; rgb:rrrr/gggg/bbbb ST`.
///
/// The terminal keeps it until something sets it back, this program's exit
/// included, so a program that changes one should call `resetColor` on the
/// way out — otherwise it leaves the user's shell in colours the user did not
/// choose.
pub fn setColor(w: *Writer, target: ColorTarget, color: Rgb16) Writer.Error!void {
    try w.writeAll(seq.osc);
    try w.print("{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}", .{
        @intFromEnum(target),
        color.r,
        color.g,
        color.b,
    });
    try w.writeAll(seq.st);
}

/// Puts one of the terminal's colours back to what the user configured:
/// `OSC 100 + target ; ST` — that is OSC 110, 111 and 112.
///
/// Back to the user's configuration, not to whatever this program found on
/// entry: there is no sequence for the latter, so a program that must restore
/// an outer program's colour has to read it with `queryColor` first and set
/// it again with `setColor`.
pub fn resetColor(w: *Writer, target: ColorTarget) Writer.Error!void {
    try w.writeAll(seq.osc);
    try w.print("{d};", .{@as(u16, @intFromEnum(target)) + 100});
    try w.writeAll(seq.st);
}

/// What a terminal says about one of its colours.
pub const ColorReport = struct {
    /// Which colour the terminal answered about — compare it against the one
    /// asked, because replies can arrive out of order and a program that asks
    /// for two at once has no other way to tell them apart.
    target: ColorTarget,
    /// The colour, widened to sixteen bits a channel whatever width the
    /// terminal spelled it in.
    color: Rgb16,
};

/// Reads a reply to `queryColor`: `OSC target ; rgb:rrrr/gggg/bbbb ST`.
///
/// A channel may be one, two, three or four hex digits, in either case, and
/// the three need not agree: that is what the X colour syntax allows and what
/// terminals send. Each is scaled to the full sixteen-bit range, so `rgb:f/0/0`
/// and `rgb:ffff/0000/0000` are the same colour.
///
/// The `#rgb` and `#rrggbb` spellings the same syntax permits are not read,
/// because no terminal answers in them and accepting a second spelling only
/// widens what a program has to be correct about.
///
/// Returns null for anything else, a target outside 10, 11 and 12 included.
/// `bytes` must be exactly the sequence, with nothing before or after it.
pub fn parseColorReply(bytes: []const u8) ?ColorReport {
    if (!std.mem.startsWith(u8, bytes, seq.osc)) return null;
    var rest = bytes[seq.osc.len..];

    const number = seq.scanInt(u16, rest) orelse return null;
    rest = rest[number.len..];
    const target: ColorTarget = switch (number.value) {
        10 => .foreground,
        11 => .background,
        12 => .cursor,
        else => return null,
    };
    if (rest.len == 0 or rest[0] != ';') return null;
    rest = rest[1..];

    const body = seq.stripStringTerminator(rest) orelse return null;
    const introducer = "rgb:";
    if (!std.mem.startsWith(u8, body, introducer)) return null;

    var channels = std.mem.splitScalar(u8, body[introducer.len..], '/');
    const r = scanChannel(channels.next() orelse return null) orelse return null;
    const g = scanChannel(channels.next() orelse return null) orelse return null;
    const b = scanChannel(channels.next() orelse return null) orelse return null;
    if (channels.next() != null) return null;

    return .{ .target = target, .color = .{ .r = r, .g = g, .b = b } };
}

/// Reads one channel of the X colour syntax: one to four hex digits, scaled
/// to the full sixteen-bit range.
///
/// The scaling is what makes a short form mean the same colour as a long one:
/// `k` digits spell a value out of `16^k - 1`, so dividing by that and
/// multiplying by 0xffff sends every all-ones value to 0xffff exactly rather
/// than leaving `f` a sixteenth as bright as `ffff`. Returns null for no
/// digits, more than four, or anything that is not a hex digit.
fn scanChannel(text: []const u8) ?u16 {
    if (text.len == 0 or text.len > 4) return null;
    var value: u32 = 0;
    for (text) |c| {
        const digit = std.fmt.charToDigit(c, 16) catch return null;
        value = value * 16 + digit;
    }
    const widest = (@as(u32, 1) << @intCast(4 * text.len)) - 1;
    return @intCast(value * 0xffff / widest);
}

//=========================================================================
// How big the terminal is, XTWINOPS.
//=========================================================================

/// Which size a program is asking the terminal for.
///
/// The values are the parameter `CSI ... t` takes, and each has its own reply
/// code -- see `WindowSize.what`.
pub const SizeQuery = enum(u8) {
    /// The text area in pixels (`CSI 14 t`). Answered with code 4.
    text_area_pixels = 14,
    /// One character cell in pixels (`CSI 16 t`). Answered with code 6, and
    /// the one that makes a pixel mouse report usable: it is the `cell_w` and
    /// `cell_h` that `toCells` needs and that nothing else reports.
    cell_pixels = 16,
    /// The text area in characters (`CSI 18 t`). Answered with code 8. The
    /// terminal size, asked for over the wire rather than through an `ioctl`
    /// on a file descriptor this package never touches.
    text_area_cells = 18,
    /// The whole screen in characters (`CSI 19 t`). Answered with code 9.
    screen_cells = 19,
};

/// Asks the terminal how big something is: `CSI what t`.
///
/// The answer arrives on the terminal's input as a sequence `parseWindowSize`
/// reads. This is the size question asked of the terminal instead of of the
/// operating system, which is the only form of it that survives a
/// multiplexer, a pipe, or a terminal running on another machine -- and the
/// only form available to a program holding no file descriptor it may call
/// `ioctl` on.
///
/// Not every terminal answers, and xterm itself disables these unless its
/// `allowWindowOps` resource is set, so pair this with a query that is always
/// answered and be ready for silence. A program that also has an `ioctl` to
/// hand should prefer it and keep this for the cases where it has none.
pub fn queryWindowSize(w: *Writer, what: SizeQuery) Writer.Error!void {
    try w.writeAll(seq.csi);
    try w.print("{d}", .{@intFromEnum(what)});
    try w.writeByte('t');
}

/// Asks the terminal to resize its text area: `CSI 8 ; rows ; cols t`.
///
/// A request, not a command: a terminal is free to refuse, to clamp it to the
/// screen, or to ignore window operations entirely, and it does not say which
/// it did. The way to find out is to ask with `queryWindowSize`, or to have
/// `inBandResize` on and wait for the report.
pub fn resizeTextArea(w: *Writer, rows: u32, cols: u32) Writer.Error!void {
    try w.writeAll(seq.csi ++ "8;");
    try w.print("{d};{d}", .{ rows, cols });
    try w.writeByte('t');
}

/// What a terminal says about one of its sizes.
pub const WindowSize = struct {
    /// Which size this is, as the reply's own code names it. Compare it
    /// against what was asked, because replies can arrive out of order and a
    /// program that asks two questions at once has no other way to pair them
    /// up.
    pub const What = enum(u8) {
        /// The text area in pixels: the answer to `.text_area_pixels`.
        text_area_pixels = 4,
        /// The screen in pixels. No `SizeQuery` asks for this one; xterm's
        /// `CSI 15 t` does, and the reply is read here for a program that
        /// wrote that sequence itself.
        screen_pixels = 5,
        /// One character cell in pixels: the answer to `.cell_pixels`.
        cell_pixels = 6,
        /// The text area in characters: the answer to `.text_area_cells`.
        text_area_cells = 8,
        /// The screen in characters: the answer to `.screen_cells`.
        screen_cells = 9,
    };

    /// Which size the terminal answered about.
    what: What,
    /// The height: rows for a size in characters, pixels for one in pixels.
    height: u32,
    /// The width: columns for a size in characters, pixels for one in pixels.
    width: u32,
};

/// Reads a window size report: `CSI code ; height ; width t`.
///
/// Height before width, which is the order xterm chose and the opposite of
/// the order `cursorTo` takes -- a reply saying `24 ; 80` is 24 rows of 80
/// columns.
///
/// Returns null for anything else, a code this package does not name
/// included. The one-parameter window reports -- `CSI 1 t` for the window
/// state and the rest -- are not sizes and are not read here. `bytes` must be
/// exactly the sequence, with nothing before or after it.
///
/// The in-band resize report, `CSI 48 ; ... t`, is a different sequence: the
/// terminal sends it unprompted, so `KeyParser` decodes it as `Event.resize`
/// rather than handing it back for this.
pub fn parseWindowSize(bytes: []const u8) ?WindowSize {
    if (!std.mem.startsWith(u8, bytes, seq.csi)) return null;
    var rest = bytes[seq.csi.len..];

    const code = seq.scanInt(u8, rest) orelse return null;
    rest = rest[code.len..];
    const what: WindowSize.What = switch (code.value) {
        4 => .text_area_pixels,
        5 => .screen_pixels,
        6 => .cell_pixels,
        8 => .text_area_cells,
        9 => .screen_cells,
        else => return null,
    };
    if (rest.len == 0 or rest[0] != ';') return null;
    rest = rest[1..];

    const height = seq.scanInt(u32, rest) orelse return null;
    rest = rest[height.len..];
    if (rest.len == 0 or rest[0] != ';') return null;
    rest = rest[1..];

    const width = seq.scanInt(u32, rest) orelse return null;
    rest = rest[width.len..];
    if (!std.mem.eql(u8, rest, "t")) return null;

    return .{ .what = what, .height = height.value, .width = width.value };
}

//=========================================================================
// The kitty graphics response.
//=========================================================================

/// What a terminal says about a kitty graphics command it was sent.
pub const GraphicsResponse = struct {
    /// The image id the response is about, the `i=` key, as the command that
    /// prompted it gave. Null when the command carried none.
    id: ?u32 = null,
    /// The client-chosen image number, the `I=` key, which a program uses
    /// when it wants the terminal to assign the id. Null when absent.
    number: ?u32 = null,
    /// The placement id, the `p=` key, naming which of an image's placements
    /// the response is about. Null when absent.
    placement: ?u32 = null,
    /// What the terminal said: `OK`, or an error beginning with its name,
    /// such as `ENOENT:` or `EBADF:`. A sub-slice of the bytes handed to the
    /// parser, borrowed rather than owned: valid for exactly as long as they
    /// are.
    message: []const u8,

    /// Whether the terminal accepted the command. Anything other than exactly
    /// `OK` is a refusal, and `message` says which.
    pub fn ok(response: GraphicsResponse) bool {
        return std.mem.eql(u8, response.message, "OK");
    }
};

/// Reads a kitty graphics response: `APC G key=value,... ; message ST`.
///
/// This package writes no graphics commands: transmitting an image is a
/// protocol with chunking, formats and placement rules of its own, and it is
/// not bytes this package can usefully name. The response is parsed because a
/// program that does write one needs to know whether it worked, and because a
/// response arriving on the input stream has to be told apart from a key.
///
/// Keys other than `i`, `I` and `p` are read past rather than refused, since
/// the protocol adds them; a key repeated within one response is refused,
/// because there is no sensible rule for which of two values wins. A response
/// with no keys at all is valid, and so is an empty message. Returns null for
/// anything else. `bytes` must be exactly the sequence, with nothing before
/// or after it.
pub fn parseGraphicsResponse(bytes: []const u8) ?GraphicsResponse {
    if (!std.mem.startsWith(u8, bytes, &apc)) return null;
    var rest = bytes[apc.len..];
    if (rest.len == 0 or rest[0] != 'G') return null;
    rest = rest[1..];

    var response: GraphicsResponse = .{ .message = "" };
    var seen: u64 = 0;
    while (rest.len != 0 and rest[0] != ';') {
        const bit = letterBit(rest[0]) orelse return null;
        if (seen & bit != 0) return null;
        seen |= bit;
        const key = rest[0];
        rest = rest[1..];

        if (rest.len == 0 or rest[0] != '=') return null;
        rest = rest[1..];
        const value = seq.scanInt(u32, rest) orelse return null;
        rest = rest[value.len..];

        switch (key) {
            'i' => response.id = value.value,
            'I' => response.number = value.value,
            'p' => response.placement = value.value,
            else => {},
        }

        if (rest.len == 0 or rest[0] != ',') break;
        rest = rest[1..];
        // A comma promises another key. Ending the list on one is malformed
        // rather than a list with an empty tail, and the loop condition alone
        // would let it through.
        if (rest.len == 0 or rest[0] == ';') return null;
    }

    if (rest.len == 0 or rest[0] != ';') return null;
    response.message = seq.stripStringTerminator(rest[1..]) orelse return null;
    return response;
}

/// The bit standing for a one-letter key, used to refuse a repeated one.
///
/// Fifty-two letters in a `u64`, lowercase first, so the check costs nothing
/// and covers the keys the protocol has not defined yet as well as the three
/// this package reads. Returns null when `key` is not an ASCII letter, which
/// is also how a key of more than one letter is refused.
fn letterBit(key: u8) ?u64 {
    const index: u6 = switch (key) {
        'a'...'z' => @intCast(key - 'a'),
        'A'...'Z' => @intCast(key - 'A' + 26),
        else => return null,
    };
    return @as(u64, 1) << index;
}

/// Whether `inner` points into `outer`.
///
/// Test support: the check the fuzz tests for the two borrowing parsers make
/// in place of a round trip, since a free-form payload has no renderer to
/// round trip through.
fn borrows(outer: []const u8, inner: []const u8) bool {
    const start = @intFromPtr(outer.ptr);
    const at = @intFromPtr(inner.ptr);
    return at >= start and at + inner.len <= start + outer.len;
}

test "queryDeviceAttributes asks with DA1" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try queryDeviceAttributes(&out.writer);
    try std.testing.expectEqualStrings("\x1b[c", out.written());
}

test "querySecondaryDeviceAttributes asks with DA2" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try querySecondaryDeviceAttributes(&out.writer);
    try std.testing.expectEqualStrings("\x1b[>c", out.written());
}

test "queryVersion asks with XTVERSION" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try queryVersion(&out.writer);
    try std.testing.expectEqualStrings("\x1b[>0q", out.written());
}

test "queryColor asks for each colour it names" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try queryColor(&out.writer, .foreground);
    try queryColor(&out.writer, .background);
    try queryColor(&out.writer, .cursor);
    try std.testing.expectEqualStrings(
        "\x1b]10;?\x1b\\\x1b]11;?\x1b\\\x1b]12;?\x1b\\",
        out.written(),
    );
}

test "setColor writes four lowercase hex digits a channel" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try setColor(&out.writer, .foreground, .{ .r = 0xffff, .g = 0x8000, .b = 0 });
    try std.testing.expectEqualStrings("\x1b]10;rgb:ffff/8000/0000\x1b\\", out.written());
}

test "setColor pads a channel that needs fewer digits" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try setColor(&out.writer, .background, .{ .r = 0, .g = 1, .b = 0x00ab });
    try std.testing.expectEqualStrings("\x1b]11;rgb:0000/0001/00ab\x1b\\", out.written());
}

test "resetColor writes the OSC a hundred above the one that sets it" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try resetColor(&out.writer, .foreground);
    try resetColor(&out.writer, .background);
    try resetColor(&out.writer, .cursor);
    try std.testing.expectEqualStrings(
        "\x1b]110;\x1b\\\x1b]111;\x1b\\\x1b]112;\x1b\\",
        out.written(),
    );
}

test "parseDeviceAttributes reads replies terminals send" {
    const vt100 = parseDeviceAttributes("\x1b[?1;2c").?;
    try std.testing.expectEqual(@as(u16, 1), vt100.class);
    try std.testing.expectEqualSlices(u16, &.{2}, vt100.list());

    const vt220 = parseDeviceAttributes("\x1b[?62;1;6;9;15;22;29c").?;
    try std.testing.expectEqual(@as(u16, 62), vt220.class);
    try std.testing.expectEqualSlices(u16, &.{ 1, 6, 9, 15, 22, 29 }, vt220.list());

    const sixel = parseDeviceAttributes("\x1b[?62;4;22c").?;
    try std.testing.expectEqualSlices(u16, &.{ 4, 22 }, sixel.list());
}

test "parseDeviceAttributes reads a class with no attributes at all" {
    const da = parseDeviceAttributes("\x1b[?6c").?;
    try std.testing.expectEqual(@as(u16, 6), da.class);
    try std.testing.expectEqual(@as(u8, 0), da.attribute_count);
    try std.testing.expectEqual(@as(usize, 0), da.list().len);
}

test "DeviceAttributes.has finds what the terminal claimed and nothing else" {
    const da = parseDeviceAttributes("\x1b[?62;4;22c").?;
    try std.testing.expect(da.has(4));
    try std.testing.expect(da.has(22));
    try std.testing.expect(!da.has(9));
    try std.testing.expect(!da.has(62));
    try std.testing.expect(!da.has(0));
}

test "parseDeviceAttributes accepts exactly DeviceAttributes.max_attributes and no more" {
    const full = parseDeviceAttributes("\x1b[?62" ++ (";1" ** DeviceAttributes.max_attributes) ++ "c").?;
    try std.testing.expectEqual(@as(u8, DeviceAttributes.max_attributes), full.attribute_count);
    try std.testing.expect(parseDeviceAttributes("\x1b[?62" ++ (";1" ** (DeviceAttributes.max_attributes + 1)) ++ "c") == null);
}

test "two DeviceAttributes carrying the same reply compare equal" {
    // The unused tail of `attribute_storage` is zeroed rather than undefined
    // precisely so this holds.
    try std.testing.expectEqual(
        parseDeviceAttributes("\x1b[?62;1;6c").?,
        parseDeviceAttributes("\x1b[?62;1;6c").?,
    );
}

test "parseDeviceAttributes returns null on anything it does not recognise" {
    const rejected = [_][]const u8{
        "", // nothing at all
        "\x1b[?62;1;6", // no final byte
        "\x1b[?62;", // a trailing separator
        "\x1b[?62;;1c", // an empty parameter
        "\x1b[?;1c", // no class
        "\x1b[?c", // no parameters at all
        "\x1b[62;1c", // no `?`, so not a DA1 reply
        "\x1b]?62;1c", // OSC, not CSI
        "\x1b[?62;1R", // the wrong final byte
        "\x1b[?62;1cc", // trailing rubbish
        " \x1b[?62;1c", // leading rubbish
        "\x1b[?62;1 c", // a space where a separator should be
        "\x1b[?65536;1c", // a class too large for its field
        "\x1b[?62;65536c", // an attribute too large for its field
    };
    for (rejected) |bytes| {
        try std.testing.expect(parseDeviceAttributes(bytes) == null);
    }
}

test "parseDeviceAttributes survives a number long enough to overflow" {
    try std.testing.expect(parseDeviceAttributes("\x1b[?99999999999999999999;1c") == null);
    try std.testing.expect(parseDeviceAttributes("\x1b[?62;99999999999999999999c") == null);
    try std.testing.expect(parseDeviceAttributes("\x1b[?62;1;99999999999999999999c") == null);
}

test "parseSecondaryDeviceAttributes reads replies terminals send" {
    try std.testing.expectEqual(
        SecondaryDeviceAttributes{ .terminal_type = 0, .version = 276, .keyboard = 0 },
        parseSecondaryDeviceAttributes("\x1b[>0;276;0c").?,
    );
    try std.testing.expectEqual(
        SecondaryDeviceAttributes{ .terminal_type = 41, .version = 357, .keyboard = 0 },
        parseSecondaryDeviceAttributes("\x1b[>41;357;0c").?,
    );
    try std.testing.expectEqual(
        SecondaryDeviceAttributes{ .terminal_type = 1, .version = 4000, .keyboard = 0 },
        parseSecondaryDeviceAttributes("\x1b[>1;4000c").?,
    );
}

test "parseSecondaryDeviceAttributes leaves the keyboard field zero when it is absent" {
    const two = parseSecondaryDeviceAttributes("\x1b[>1;4000c").?;
    const three = parseSecondaryDeviceAttributes("\x1b[>1;4000;0c").?;
    try std.testing.expectEqual(two, three);
    try std.testing.expectEqual(@as(u16, 0), two.keyboard);
}

test "parseSecondaryDeviceAttributes reads a keyboard field that is not zero" {
    const da = parseSecondaryDeviceAttributes("\x1b[>64;20;1c").?;
    try std.testing.expectEqual(@as(u16, 64), da.terminal_type);
    try std.testing.expectEqual(@as(u32, 20), da.version);
    try std.testing.expectEqual(@as(u16, 1), da.keyboard);
}

test "parseSecondaryDeviceAttributes returns null on anything it does not recognise" {
    const rejected = [_][]const u8{
        "", // nothing at all
        "\x1b[>0;276;0", // no final byte
        "\x1b[>0;276;", // a trailing separator
        "\x1b[>0;;0c", // an empty parameter
        "\x1b[>0c", // no version
        "\x1b[>;276;0c", // no terminal type
        "\x1b[>c", // no parameters at all
        "\x1b[?0;276;0c", // the primary form, a different reply
        "\x1b[0;276;0c", // no `>`
        "\x1b]>0;276;0c", // OSC, not CSI
        "\x1b[>0;276;0q", // the wrong final byte
        "\x1b[>0;276;0cc", // trailing rubbish
        " \x1b[>0;276;0c", // leading rubbish
        "\x1b[>0;276;0;1c", // a field too many
        "\x1b[>65536;276;0c", // a type too large for its field
        "\x1b[>0;4294967296;0c", // a version too large for its field
        "\x1b[>0;276;65536c", // a keyboard field too large for its field
    };
    for (rejected) |bytes| {
        try std.testing.expect(parseSecondaryDeviceAttributes(bytes) == null);
    }
}

test "parseSecondaryDeviceAttributes survives a number long enough to overflow" {
    try std.testing.expect(parseSecondaryDeviceAttributes("\x1b[>99999999999999999999;276;0c") == null);
    try std.testing.expect(parseSecondaryDeviceAttributes("\x1b[>0;99999999999999999999;0c") == null);
    try std.testing.expect(parseSecondaryDeviceAttributes("\x1b[>0;276;99999999999999999999c") == null);
}

test "parseVersion reads the name a terminal chose" {
    try std.testing.expectEqualStrings("xterm(390)", parseVersion("\x1bP>|xterm(390)\x1b\\").?);
    try std.testing.expectEqualStrings("WezTerm 20240203", parseVersion("\x1bP>|WezTerm 20240203\x1b\\").?);
}

test "parseVersion accepts BEL where a terminal uses it instead of ST" {
    try std.testing.expectEqualStrings("foot(1.16.2)", parseVersion("\x1bP>|foot(1.16.2)\x07").?);
}

test "parseVersion reads an empty name as an empty slice, not null" {
    const name = parseVersion("\x1bP>|\x1b\\").?;
    try std.testing.expectEqual(@as(usize, 0), name.len);
}

test "parseVersion borrows the name from the bytes it was given" {
    const bytes = "\x1bP>|xterm(390)\x1b\\";
    const name = parseVersion(bytes).?;
    try std.testing.expect(borrows(bytes, name));
    try std.testing.expectEqual(bytes.ptr + 4, name.ptr);
}

test "parseVersion reads a twenty-digit name as text, not as a number" {
    // Nothing in this reply is numeric, so a run of digits no integer could
    // hold is a perfectly good name.
    try std.testing.expectEqualStrings(
        "99999999999999999999",
        parseVersion("\x1bP>|99999999999999999999\x1b\\").?,
    );
}

test "parseVersion returns null on anything it does not recognise" {
    const rejected = [_][]const u8{
        "", // nothing at all
        "\x1bP>|xterm(390)", // no terminator
        "\x1bP>|xterm(390)\x1b", // a terminator cut in half
        "\x1bP>|", // no terminator, and no name either
        "\x1bP", // the introducer alone
        "\x1bP>xterm(390)\x1b\\", // no `|`
        "\x1bP|xterm(390)\x1b\\", // no `>`
        "\x1b[>|xterm(390)\x1b\\", // CSI, not DCS
        "\x1b_>|xterm(390)\x1b\\", // APC, not DCS
        "\x1b]>|xterm(390)\x1b\\", // OSC, not DCS
        "P>|xterm(390)\x1b\\", // no ESC
        " \x1bP>|xterm(390)\x1b\\", // leading rubbish
    };
    for (rejected) |bytes| {
        try std.testing.expect(parseVersion(bytes) == null);
    }
}

test "parseKittyKeyboardReply reads the flags a terminal reports" {
    try std.testing.expectEqual(KittyFlags{}, parseKittyKeyboardReply("\x1b[?0u").?);
    try std.testing.expectEqual(
        KittyFlags{ .disambiguate_escape_codes = true },
        parseKittyKeyboardReply("\x1b[?1u").?,
    );
    try std.testing.expectEqual(
        KittyFlags{ .disambiguate_escape_codes = true, .report_event_types = true },
        parseKittyKeyboardReply("\x1b[?3u").?,
    );
    try std.testing.expectEqual(
        KittyFlags{
            .disambiguate_escape_codes = true,
            .report_event_types = true,
            .report_alternate_keys = true,
            .report_all_keys_as_escape_codes = true,
            .report_associated_text = true,
        },
        parseKittyKeyboardReply("\x1b[?31u").?,
    );
}

test "parseKittyKeyboardReply reads every value the five bits can spell" {
    var buffer: [16]u8 = undefined;
    for (0..32) |value| {
        const bits: u5 = @intCast(value);
        const bytes = try std.fmt.bufPrint(&buffer, "\x1b[?{d}u", .{value});
        try std.testing.expectEqual(bits, parseKittyKeyboardReply(bytes).?.bits());
    }
}

test "parseKittyKeyboardReply returns null on anything it does not recognise" {
    const rejected = [_][]const u8{
        "", // nothing at all
        "\x1b[?1", // no final byte
        "\x1b[?u", // no flags
        "\x1b[?", // nothing but the introducer
        "\x1b[1u", // no `?`, so not a reply
        "\x1b[>1u", // the push, which a program sends rather than reads
        "\x1b]?1u", // OSC, not CSI
        "\x1b[?1U", // the wrong final byte
        "\x1b[?1uu", // trailing rubbish
        " \x1b[?1u", // leading rubbish
        "\x1b[?1;2u", // a field too many
        "\x1b[?32u", // one bit above the five the protocol defines
        "\x1b[?255u", // far above them
        "\x1b[?256u", // a value too large for its field
    };
    for (rejected) |bytes| {
        try std.testing.expect(parseKittyKeyboardReply(bytes) == null);
    }
}

test "parseKittyKeyboardReply survives a number long enough to overflow" {
    try std.testing.expect(parseKittyKeyboardReply("\x1b[?99999999999999999999u") == null);
}

test "Rgb16 narrows to eight bits a channel by taking the top byte" {
    try std.testing.expectEqual(
        Rgb{ .r = 0xff, .g = 0x80, .b = 0 },
        (Rgb16{ .r = 0xffff, .g = 0x8080, .b = 0 }).to8(),
    );
    try std.testing.expectEqual(
        Rgb{ .r = 0, .g = 0, .b = 0 },
        (Rgb16{ .r = 0x00ff, .g = 1, .b = 0 }).to8(),
    );
}

test "parseColorReply reads replies terminals send" {
    try std.testing.expectEqual(
        ColorReport{ .target = .background, .color = .{ .r = 0, .g = 0, .b = 0 } },
        parseColorReply("\x1b]11;rgb:0000/0000/0000\x1b\\").?,
    );
    try std.testing.expectEqual(
        ColorReport{ .target = .foreground, .color = .{ .r = 0xffff, .g = 0xffff, .b = 0xffff } },
        parseColorReply("\x1b]10;rgb:ffff/ffff/ffff\x1b\\").?,
    );
    try std.testing.expectEqual(
        ColorReport{ .target = .cursor, .color = .{ .r = 0x1c1c, .g = 0x1c1c, .b = 0x1c1c } },
        parseColorReply("\x1b]12;rgb:1c1c/1c1c/1c1c\x07").?,
    );
}

test "parseColorReply scales a short channel to the full range" {
    const cases = [_]struct { bytes: []const u8, color: Rgb16 }{
        // One digit: `f` is every bit set, so it is 0xffff, not 0x000f.
        .{ .bytes = "\x1b]11;rgb:f/0/0\x1b\\", .color = .{ .r = 0xffff, .g = 0, .b = 0 } },
        // Two digits: the eight-bit spelling of the same colour.
        .{ .bytes = "\x1b]11;rgb:ff/00/00\x1b\\", .color = .{ .r = 0xffff, .g = 0, .b = 0 } },
        // Two digits scale by 0x101, which is the byte doubled.
        .{ .bytes = "\x1b]11;rgb:80/00/00\x1b\\", .color = .{ .r = 0x8080, .g = 0, .b = 0 } },
        // Three digits, all ones, is still the top of the range.
        .{ .bytes = "\x1b]11;rgb:fff/000/000\x1b\\", .color = .{ .r = 0xffff, .g = 0, .b = 0 } },
        // Four digits are the range itself and are not scaled at all.
        .{ .bytes = "\x1b]11;rgb:8000/0000/0000\x1b\\", .color = .{ .r = 0x8000, .g = 0, .b = 0 } },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.color, parseColorReply(case.bytes).?.color);
    }
}

test "parseColorReply accepts channels of different widths and either case" {
    try std.testing.expectEqual(
        Rgb16{ .r = 0xffff, .g = 0, .b = 0x8080 },
        parseColorReply("\x1b]11;rgb:f/00/8080\x1b\\").?.color,
    );
    try std.testing.expectEqual(
        Rgb16{ .r = 0xabab, .g = 0xcdcd, .b = 0xefef },
        parseColorReply("\x1b]11;rgb:AB/CD/EF\x1b\\").?.color,
    );
}

test "a colour set and a colour parsed agree on the same bytes" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const report = parseColorReply("\x1b]11;rgb:1c1c/2d2d/3e3e\x1b\\").?;
    try setColor(&out.writer, report.target, report.color);
    try std.testing.expectEqualStrings("\x1b]11;rgb:1c1c/2d2d/3e3e\x1b\\", out.written());
}

test "parseColorReply returns null on anything it does not recognise" {
    const rejected = [_][]const u8{
        "", // nothing at all
        "\x1b]11;rgb:0000/0000/0000", // no terminator
        "\x1b]11;rgb:0000/0000/0000\x1b", // a terminator cut in half
        "\x1b]11;rgb:0000/0000/0000\x1b\\x", // trailing rubbish
        " \x1b]11;rgb:0/0/0\x1b\\", // leading rubbish
        "\x1b]13;rgb:0/0/0\x1b\\", // a target this package does not name
        "\x1b]4;1;rgb:0/0/0\x1b\\", // a palette colour, OSC 4
        "\x1b];rgb:0/0/0\x1b\\", // no target
        "\x1b]11rgb:0/0/0\x1b\\", // no separator after the target
        "\x1b[11;rgb:0/0/0\x1b\\", // CSI, not OSC
        "\x1b]11;0000/0000/0000\x1b\\", // no `rgb:` prefix
        "\x1b]11;#ff0000\x1b\\", // the hash spelling, which is not read
        "\x1b]11;rgb:0000/0000\x1b\\", // a channel short
        "\x1b]11;rgb:0/0/0/0\x1b\\", // a channel too many
        "\x1b]11;rgb:00000/00/00\x1b\\", // five digits in a channel
        "\x1b]11;rgb://0\x1b\\", // channels with no digits at all
        "\x1b]11;rgb:gg/00/00\x1b\\", // not hex digits
        "\x1b]11;rgb: 0/0/0\x1b\\", // a space inside a channel
        "\x1b]11;?\x1b\\", // the query, not a reply
        "\x1b]65536;rgb:0/0/0\x1b\\", // a target too large for its field
    };
    for (rejected) |bytes| {
        try std.testing.expect(parseColorReply(bytes) == null);
    }
}

test "parseColorReply survives a number long enough to overflow" {
    try std.testing.expect(parseColorReply("\x1b]99999999999999999999;rgb:0/0/0\x1b\\") == null);
    try std.testing.expect(parseColorReply("\x1b]11;rgb:99999999999999999999/0/0\x1b\\") == null);
    try std.testing.expect(parseColorReply("\x1b]11;rgb:0/99999999999999999999/0\x1b\\") == null);
    try std.testing.expect(parseColorReply("\x1b]11;rgb:0/0/99999999999999999999\x1b\\") == null);
}

test "parseGraphicsResponse reads an acknowledgement and a refusal" {
    const accepted = parseGraphicsResponse("\x1b_Gi=31;OK\x1b\\").?;
    try std.testing.expectEqual(@as(?u32, 31), accepted.id);
    try std.testing.expectEqual(@as(?u32, null), accepted.number);
    try std.testing.expectEqual(@as(?u32, null), accepted.placement);
    try std.testing.expectEqualStrings("OK", accepted.message);
    try std.testing.expect(accepted.ok());

    const refused = parseGraphicsResponse("\x1b_Gi=31;ENOENT:No such file\x1b\\").?;
    try std.testing.expectEqual(@as(?u32, 31), refused.id);
    try std.testing.expectEqualStrings("ENOENT:No such file", refused.message);
    try std.testing.expect(!refused.ok());
}

test "parseGraphicsResponse reads every key it names" {
    const response = parseGraphicsResponse("\x1b_Gi=1,I=2,p=3;OK\x1b\\").?;
    try std.testing.expectEqual(@as(?u32, 1), response.id);
    try std.testing.expectEqual(@as(?u32, 2), response.number);
    try std.testing.expectEqual(@as(?u32, 3), response.placement);
}

test "parseGraphicsResponse reads past keys it does not name" {
    // The protocol adds keys; a response carrying one is still a response.
    const response = parseGraphicsResponse("\x1b_Gi=31,q=2,z=0,p=7;OK\x1b\\").?;
    try std.testing.expectEqual(@as(?u32, 31), response.id);
    try std.testing.expectEqual(@as(?u32, 7), response.placement);
    try std.testing.expectEqual(@as(?u32, null), response.number);
}

test "parseGraphicsResponse reads a response with no keys and one with no message" {
    const keyless = parseGraphicsResponse("\x1b_G;OK\x1b\\").?;
    try std.testing.expectEqual(@as(?u32, null), keyless.id);
    try std.testing.expectEqualStrings("OK", keyless.message);
    try std.testing.expect(keyless.ok());

    const silent = parseGraphicsResponse("\x1b_Gi=31;\x1b\\").?;
    try std.testing.expectEqual(@as(usize, 0), silent.message.len);
    try std.testing.expect(!silent.ok());
}

test "parseGraphicsResponse accepts BEL where a terminal uses it instead of ST" {
    const response = parseGraphicsResponse("\x1b_GI=99;EBADF:bad file descriptor\x07").?;
    try std.testing.expectEqual(@as(?u32, 99), response.number);
    try std.testing.expectEqualStrings("EBADF:bad file descriptor", response.message);
}

test "parseGraphicsResponse borrows the message from the bytes it was given" {
    const bytes = "\x1b_Gi=31;OK\x1b\\";
    const response = parseGraphicsResponse(bytes).?;
    try std.testing.expect(borrows(bytes, response.message));
    try std.testing.expectEqual(bytes.ptr + 8, response.message.ptr);
}

test "parseGraphicsResponse returns null on anything it does not recognise" {
    const rejected = [_][]const u8{
        "", // nothing at all
        "\x1b_Gi=31;OK", // no terminator
        "\x1b_Gi=31;OK\x1b", // a terminator cut in half
        "\x1b_G", // the introducer alone
        "\x1b_Gi=31", // no message and no terminator
        "\x1b_i=31;OK\x1b\\", // no `G`
        "\x1bPGi=31;OK\x1b\\", // DCS, not APC
        "\x1b[Gi=31;OK\x1b\\", // CSI, not APC
        "\x1b]Gi=31;OK\x1b\\", // OSC, not APC
        " \x1b_Gi=31;OK\x1b\\", // leading rubbish
        "\x1b_Gi=31;OK\x1b\\x", // trailing rubbish
        "\x1b_Gi=31OK\x1b\\", // no `;` before the message
        "\x1b_Gii=31;OK\x1b\\", // a key of more than one letter
        "\x1b_G1=31;OK\x1b\\", // a key that is not a letter
        "\x1b_Gi31;OK\x1b\\", // no `=`
        "\x1b_Gi=;OK\x1b\\", // no value
        "\x1b_Gi=x;OK\x1b\\", // a value that is not digits
        "\x1b_Gi=1,;OK\x1b\\", // a trailing comma with no key after it
        "\x1b_Gi=1,,p=2;OK\x1b\\", // an empty key
        "\x1b_Gi=1,i=2;OK\x1b\\", // a duplicated key
        "\x1b_Gq=1,q=2;OK\x1b\\", // a duplicated key this package does not name
        "\x1b_Gi=4294967296;OK\x1b\\", // an id too large for its field
    };
    for (rejected) |bytes| {
        try std.testing.expect(parseGraphicsResponse(bytes) == null);
    }
}

test "parseGraphicsResponse survives a number long enough to overflow" {
    try std.testing.expect(parseGraphicsResponse("\x1b_Gi=99999999999999999999;OK\x1b\\") == null);
    try std.testing.expect(parseGraphicsResponse("\x1b_GI=99999999999999999999;OK\x1b\\") == null);
    try std.testing.expect(parseGraphicsResponse("\x1b_Gp=99999999999999999999;OK\x1b\\") == null);
}

test "fuzz parseDeviceAttributes" {
    // The property: no input panics or overflows, and every reply that parses
    // renders back to a reply that parses to the same attributes. A terminal
    // writes these; the round trip is against that renderer.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [64]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];

            const da = parseDeviceAttributes(bytes) orelse return;
            try std.testing.expect(da.attribute_count <= DeviceAttributes.max_attributes);

            var output: [256]u8 = undefined;
            var w: Writer = .fixed(&output);
            try w.print("\x1b[?{d}", .{da.class});
            for (da.list()) |attribute| try w.print(";{d}", .{attribute});
            try w.writeAll("c");
            try std.testing.expectEqual(da, parseDeviceAttributes(w.buffered()).?);
        }
    }.one, .{ .corpus = &.{
        corpus.seed("\x1b[?1;2c"),
        corpus.seed("\x1b[?62;1;6;9;15;22;29c"),
        corpus.seed("\x1b[?6c"),
        corpus.seed("\x1b[?0;0c"),
        corpus.seed("\x1b[?65535;65535c"),
        corpus.seed("\x1b[?62;65536c"),
        corpus.seed("\x1b[?62;;1c"),
        corpus.seed("\x1b[?62;"),
        corpus.seed("\x1b[62;1c"),
        corpus.seed("\x1b[?62;1cc"),
    } });
}

test "fuzz parseSecondaryDeviceAttributes" {
    // The property: no input panics or overflows, and every reply that parses
    // renders back -- always in the three-parameter form, since a missing
    // keyboard field means zero -- to a reply that parses the same.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [64]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];

            const da = parseSecondaryDeviceAttributes(bytes) orelse return;

            var output: [64]u8 = undefined;
            var w: Writer = .fixed(&output);
            try w.print("\x1b[>{d};{d};{d}c", .{ da.terminal_type, da.version, da.keyboard });
            try std.testing.expectEqual(da, parseSecondaryDeviceAttributes(w.buffered()).?);
        }
    }.one, .{ .corpus = &.{
        corpus.seed("\x1b[>0;276;0c"),
        corpus.seed("\x1b[>1;4000c"),
        corpus.seed("\x1b[>41;357;0c"),
        corpus.seed("\x1b[>65535;4294967295;65535c"),
        corpus.seed("\x1b[>0;4294967296;0c"),
        corpus.seed("\x1b[>0;276;0;1c"),
        corpus.seed("\x1b[?0;276;0c"),
        corpus.seed("\x1b[>0;276;0"),
    } });
}

test "fuzz parseVersion" {
    // The property: no input panics or overflows, the name is always a
    // sub-slice of the bytes it was read from, and the same bytes parse the
    // same way twice. A round trip would prove less than it looks: the name is
    // free-form, so re-rendering it is only concatenation.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [64]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];

            const name = parseVersion(bytes) orelse return;
            try std.testing.expect(borrows(bytes, name));
            try std.testing.expect(name.len <= bytes.len);
            try std.testing.expectEqualStrings(name, parseVersion(bytes).?);
        }
    }.one, .{ .corpus = &.{
        corpus.seed("\x1bP>|xterm(390)\x1b\\"),
        corpus.seed("\x1bP>|foot(1.16.2)\x07"),
        corpus.seed("\x1bP>|\x1b\\"),
        corpus.seed("\x1bP>|99999999999999999999\x1b\\"),
        corpus.seed("\x1bP>|xterm(390)"),
        corpus.seed("\x1bP>xterm(390)\x1b\\"),
        corpus.seed("\x1b[>|xterm(390)\x1b\\"),
        corpus.seed("\x1bP>|"),
    } });
}

test "fuzz parseKittyKeyboardReply" {
    // The property: no input panics or overflows, every set of flags that
    // parses is within the five bits the protocol defines, and rendering it
    // back gives a reply that parses to the same flags.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [64]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];

            const flags = parseKittyKeyboardReply(bytes) orelse return;

            var output: [32]u8 = undefined;
            var w: Writer = .fixed(&output);
            try w.print("\x1b[?{d}u", .{flags.bits()});
            try std.testing.expectEqual(flags, parseKittyKeyboardReply(w.buffered()).?);
        }
    }.one, .{ .corpus = &.{
        corpus.seed("\x1b[?0u"),
        corpus.seed("\x1b[?1u"),
        corpus.seed("\x1b[?31u"),
        corpus.seed("\x1b[?32u"),
        corpus.seed("\x1b[?255u"),
        corpus.seed("\x1b[?256u"),
        corpus.seed("\x1b[?1;2u"),
        corpus.seed("\x1b[>1u"),
        corpus.seed("\x1b[?1"),
    } });
}

test "fuzz parseColorReply" {
    // The property: no input panics or overflows, and every reply that parses
    // re-renders -- in four digits a channel, whatever width it arrived in --
    // to a reply that parses to the same colour. That is a real check on the
    // scaling arithmetic: a short channel that scaled wrongly would not come
    // back to itself through the four-digit form.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [64]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];

            const report = parseColorReply(bytes) orelse return;

            var output: [64]u8 = undefined;
            var w: Writer = .fixed(&output);
            try setColor(&w, report.target, report.color);
            try std.testing.expectEqual(report, parseColorReply(w.buffered()).?);
        }
    }.one, .{ .corpus = &.{
        corpus.seed("\x1b]11;rgb:0000/0000/0000\x1b\\"),
        corpus.seed("\x1b]10;rgb:ffff/ffff/ffff\x1b\\"),
        corpus.seed("\x1b]12;rgb:1c1c/1c1c/1c1c\x07"),
        corpus.seed("\x1b]11;rgb:f/0/0\x1b\\"),
        corpus.seed("\x1b]11;rgb:80/00/00\x1b\\"),
        corpus.seed("\x1b]11;rgb:f/00/8080\x1b\\"),
        corpus.seed("\x1b]11;rgb:AB/CD/EF\x1b\\"),
        corpus.seed("\x1b]11;rgb:00000/00/00\x1b\\"),
        corpus.seed("\x1b]11;rgb:0/0/0/0\x1b\\"),
        corpus.seed("\x1b]13;rgb:0/0/0\x1b\\"),
        corpus.seed("\x1b]11;#ff0000\x1b\\"),
        corpus.seed("\x1b]11;?\x1b\\"),
    } });
}

test "fuzz parseGraphicsResponse" {
    // The property: no input panics or overflows, the message is always a
    // sub-slice of the bytes it was read from, and the same bytes parse the
    // same way twice. The message is free-form and this package writes no
    // graphics commands, so there is no renderer to round trip through.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [64]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];

            const response = parseGraphicsResponse(bytes) orelse return;
            try std.testing.expect(borrows(bytes, response.message));
            try std.testing.expect(response.message.len <= bytes.len);

            const again = parseGraphicsResponse(bytes).?;
            try std.testing.expectEqual(response.id, again.id);
            try std.testing.expectEqual(response.number, again.number);
            try std.testing.expectEqual(response.placement, again.placement);
            try std.testing.expectEqualStrings(response.message, again.message);
            try std.testing.expectEqual(response.ok(), again.ok());
        }
    }.one, .{ .corpus = &.{
        corpus.seed("\x1b_Gi=31;OK\x1b\\"),
        corpus.seed("\x1b_Gi=1,I=2,p=3;OK\x1b\\"),
        corpus.seed("\x1b_Gi=31;ENOENT:No such file\x1b\\"),
        corpus.seed("\x1b_GI=99;EBADF:bad\x07"),
        corpus.seed("\x1b_G;OK\x1b\\"),
        corpus.seed("\x1b_Gi=31;\x1b\\"),
        corpus.seed("\x1b_Gi=31,q=2,z=0,p=7;OK\x1b\\"),
        corpus.seed("\x1b_Gi=1,i=2;OK\x1b\\"),
        corpus.seed("\x1b_Gi=4294967296;OK\x1b\\"),
        corpus.seed("\x1b_Gii=31;OK\x1b\\"),
        corpus.seed("\x1b_Gi=1,;OK\x1b\\"),
        corpus.seed("\x1b_Gi=31;OK"),
    } });
}

test "queryWindowSize asks with the number for each size" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try queryWindowSize(&out.writer, .text_area_pixels);
    try queryWindowSize(&out.writer, .cell_pixels);
    try queryWindowSize(&out.writer, .text_area_cells);
    try queryWindowSize(&out.writer, .screen_cells);
    try std.testing.expectEqualStrings("\x1b[14t\x1b[16t\x1b[18t\x1b[19t", out.written());
}

test "resizeTextArea asks in rows and then columns" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try resizeTextArea(&out.writer, 24, 80);
    try std.testing.expectEqualStrings("\x1b[8;24;80t", out.written());
}

test "parseWindowSize reads every code it names" {
    const cases = [_]struct { bytes: []const u8, what: WindowSize.What }{
        .{ .bytes = "\x1b[4;384;640t", .what = .text_area_pixels },
        .{ .bytes = "\x1b[5;1080;1920t", .what = .screen_pixels },
        .{ .bytes = "\x1b[6;16;8t", .what = .cell_pixels },
        .{ .bytes = "\x1b[8;24;80t", .what = .text_area_cells },
        .{ .bytes = "\x1b[9;67;240t", .what = .screen_cells },
    };
    for (cases) |case| {
        const size = parseWindowSize(case.bytes).?;
        try std.testing.expectEqual(case.what, size.what);
    }
}

test "parseWindowSize reads height before width" {
    const size = parseWindowSize("\x1b[8;24;80t").?;
    try std.testing.expectEqual(@as(u32, 24), size.height);
    try std.testing.expectEqual(@as(u32, 80), size.width);
}

test "a cell size reply is what toCells needs" {
    const cell = parseWindowSize("\x1b[6;16;8t").?;
    try std.testing.expectEqual(WindowSize.What.cell_pixels, cell.what);
    try std.testing.expectEqual(@as(u32, 8), cell.width);
    try std.testing.expectEqual(@as(u32, 16), cell.height);
}

test "parseWindowSize returns null on anything it does not recognise" {
    const rejected = [_][]const u8{
        "", // nothing at all
        "\x1b[8;24;80", // truncated
        "\x1b[8;24;80T", // wrong final byte
        "\x1b[8;24t", // a field short
        "\x1b[8;24;80;1t", // a field too many
        "\x1b[7;24;80t", // a code this package does not name
        "\x1b[48;24;80t", // the in-band resize report, which is an event
        "\x1b[1t", // a window state report, which is not a size
        "\x1b[?8;24;80t", // a private marker
        "\x1b8;24;80t", // no CSI
        "\x1b[8;24;80tt", // trailing rubbish
        "\x1b[8;4294967296;80t", // a height too large for its field
        "\x1b[8;24;4294967296t", // a width too large for its field
        "\x1b[256;24;80t", // a code too large for its field
    };
    for (rejected) |bytes| {
        try std.testing.expect(parseWindowSize(bytes) == null);
    }
}

test "fuzz parseWindowSize" {
    // The property: no input panics or overflows, and every report that
    // parses renders back to a report that parses to the same size.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [64]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];

            const size = parseWindowSize(bytes) orelse return;

            var output: [64]u8 = undefined;
            var w: Writer = .fixed(&output);
            try w.print("\x1b[{d};{d};{d}t", .{
                @intFromEnum(size.what),
                size.height,
                size.width,
            });
            try std.testing.expectEqual(size, parseWindowSize(w.buffered()).?);
        }
    }.one, .{ .corpus = &.{
        corpus.seed("\x1b[8;24;80t"),
        corpus.seed("\x1b[6;16;8t"),
        corpus.seed("\x1b[4;0;0t"),
        corpus.seed("\x1b[9;4294967295;4294967295t"),
        corpus.seed("\x1b[8;4294967296;80t"),
        corpus.seed("\x1b[7;24;80t"),
        corpus.seed("\x1b[48;24;80t"),
        corpus.seed("\x1b[8;24;80"),
    } });
}
