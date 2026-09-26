//! A terminal's answers, read.
//!
//! Every question in this package has a parser for its answer, and the
//! answer arrives on the input stream among the keys. `KeyParser` frames it
//! and, rather than hand the bytes back for the program to try parser after
//! parser on, reads it here: an `Event.reply` is the answer as a value. A
//! sequence that answers nothing this package asks stays `Event.unhandled`.
//!
//! Each shape of answer is told from the others by its introducer, its
//! private marker, its intermediate and its final byte, so a sequence reads
//! as at most one of them and the order the parsers are tried in decides
//! nothing.
//!
//! What a reply carries borrows from the bytes it was read from, where it
//! carries bytes at all: the terminal's name, a capability's value, a
//! clipboard's contents, a graphics message. Everything else is a value.

const std = @import("std");

const clipboard = @import("clipboard.zig");
const device = @import("device.zig");
const graphics = @import("graphics.zig");
const mode = @import("mode.zig");
const multicursor = @import("multicursor.zig");
const query = @import("query.zig");
const tcap = @import("tcap.zig");

/// An answer the terminal sent, read.
pub const Reply = union(enum) {
    /// Whether a mode is set, reset, permanent or unknown (DECRPM), the
    /// answer to `queryMode`.
    mode: query.ModeReport,
    /// What the terminal claims to implement (DA1).
    device_attributes: device.DeviceAttributes,
    /// Which terminal family and version (DA2).
    secondary_device_attributes: device.SecondaryDeviceAttributes,
    /// What the terminal calls itself (XTVERSION). Borrowed.
    version: []const u8,
    /// The kitty keyboard flags in effect.
    kitty_keyboard: mode.KittyFlags,
    /// What a `modifyOtherKeys`-style resource is set to.
    modify_keys: device.ModifyKeysReport,
    /// One of the terminal's colours: foreground, background, cursor
    /// (OSC 10, 11, 12).
    color: device.ColorReport,
    /// One palette entry (OSC 4).
    palette: device.PaletteReport,
    /// A size: the text area or the screen in cells or pixels, or one cell
    /// in pixels (`CSI 4`, `5`, `6`, `8`, `9 ; height ; width t`).
    window_size: device.WindowSize,
    /// What the terminal said about a graphics command. Its message is
    /// borrowed; whether it was accepted is `ok()`.
    graphics: graphics.GraphicsResponse,
    /// Where the cursor is (CPR).
    cursor_position: query.CursorPosition,
    /// Where the cursor is, with its page (DECXCPR).
    extended_cursor_position: query.ExtendedCursorPosition,
    /// A capability's value, or that the terminal does not know it
    /// (XTGETTCAP). Borrowed.
    capability: tcap.CapabilityReply,
    /// The clipboard's contents (OSC 52). Borrowed.
    clipboard: clipboard.ClipboardReply,
    /// What the terminal can do with extra cursors.
    extra_cursor_support: multicursor.ExtraCursorSupport,
    /// Where the extra cursors are.
    extra_cursors: multicursor.ExtraCursorReport,
    /// What colours the extra cursors are drawn in.
    extra_cursor_colors: multicursor.ExtraCursorColors,

    /// Reads one whole sequence as the answer it is, or null for a sequence
    /// that answers nothing this package asks. `bytes` must be exactly the
    /// sequence, with nothing before or after it.
    pub fn parse(bytes: []const u8) ?Reply {
        if (query.parseModeReply(bytes)) |r| return .{ .mode = r };
        if (device.parseDeviceAttributes(bytes)) |r| return .{ .device_attributes = r };
        if (device.parseSecondaryDeviceAttributes(bytes)) |r| return .{ .secondary_device_attributes = r };
        if (device.parseVersion(bytes)) |r| return .{ .version = r };
        if (device.parseKittyKeyboardReply(bytes)) |r| return .{ .kitty_keyboard = r };
        if (device.parseModifyKeysReply(bytes)) |r| return .{ .modify_keys = r };
        if (device.parseColorReply(bytes)) |r| return .{ .color = r };
        if (device.parsePaletteReply(bytes)) |r| return .{ .palette = r };
        if (device.parseWindowSize(bytes)) |r| return .{ .window_size = r };
        if (graphics.parseGraphicsResponse(bytes)) |r| return .{ .graphics = r };
        if (query.parseCursorPosition(bytes)) |r| return .{ .cursor_position = r };
        if (query.parseExtendedCursorPosition(bytes)) |r| return .{ .extended_cursor_position = r };
        if (tcap.parseCapabilityReply(bytes)) |r| return .{ .capability = r };
        if (clipboard.parseClipboardReply(bytes)) |r| return .{ .clipboard = r };
        if (multicursor.parseExtraCursorSupport(bytes)) |r| return .{ .extra_cursor_support = r };
        if (multicursor.parseExtraCursors(bytes)) |r| return .{ .extra_cursors = r };
        if (multicursor.parseExtraCursorColors(bytes)) |r| return .{ .extra_cursor_colors = r };
        return null;
    }
};

const testing = std.testing;

test "every answer this package asks for reads as the one reply it is" {
    const cases = [_]struct { bytes: []const u8, tag: std.meta.Tag(Reply) }{
        .{ .bytes = "\x1b[?2026;2$y", .tag = .mode },
        .{ .bytes = "\x1b[?62;4;22c", .tag = .device_attributes },
        .{ .bytes = "\x1b[>1;4000;29c", .tag = .secondary_device_attributes },
        .{ .bytes = "\x1bP>|ghostty 1.3\x1b\\", .tag = .version },
        .{ .bytes = "\x1b[?5u", .tag = .kitty_keyboard },
        .{ .bytes = "\x1b[>4;2m", .tag = .modify_keys },
        .{ .bytes = "\x1b]11;rgb:1e1e/1e1e/2e2e\x07", .tag = .color },
        .{ .bytes = "\x1b]4;1;rgb:f3/8b/a8\x1b\\", .tag = .palette },
        .{ .bytes = "\x1b[6;20;9t", .tag = .window_size },
        .{ .bytes = "\x1b_Gi=7;OK\x1b\\", .tag = .graphics },
        .{ .bytes = "\x1b[12;40R", .tag = .cursor_position },
        .{ .bytes = "\x1b[?12;40;1R", .tag = .extended_cursor_position },
        .{ .bytes = "\x1bP1+r5463\x1b\\", .tag = .capability },
        .{ .bytes = "\x1b]52;c;aGk=\x07", .tag = .clipboard },
    };
    for (cases) |case| {
        const got = Reply.parse(case.bytes) orelse {
            std.debug.print("not read: {f}\n", .{std.ascii.hexEscape(case.bytes, .lower)});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqual(case.tag, std.meta.activeTag(got));
    }
    try testing.expectEqual(@as(u16, 2026), Reply.parse("\x1b[?2026;2$y").?.mode.mode);
    try testing.expect(Reply.parse("\x1b_Gi=7;OK\x1b\\").?.graphics.ok());
}

test "a sequence that answers nothing asked is not a reply" {
    for ([_][]const u8{ "\x1b[A", "\x1b]0;title\x07", "\x1b[?997;1n", "\x1b[48;24;80;480;720t", "", "\x1b[" }) |bytes| {
        try testing.expect(Reply.parse(bytes) == null);
    }
}
