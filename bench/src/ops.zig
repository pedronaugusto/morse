//! One timed workload per public operation. Each record is one call: its
//! first byte seeds the arguments, the rest is the payload (text, image
//! bytes) or, for a reader, the whole reply. The table is the same at both
//! revisions; an operation the `before` revision lacks reports unavailable.
const std = @import("std");
const m = @import("morse");
const v = @import("vaxis");
const Writer = std.Io.Writer;

/// The process's Io, for libvaxis' cursor-report bookkeeping.
pub var io: std.Io = undefined;

pub const Op = *const fn (w: *Writer, rec: []const u8, check: bool, scratch: []u8) anyerror!usize;

fn n32(rec: []const u8) u32 {
    return @as(u32, rec[0]) + 1;
}
fn rgb16(x: u8) m.Rgb16 {
    return .{ .r = @as(u16, x) * 257, .g = 0x6464, .b = 0x3232 };
}
fn body(rec: []const u8) []const u8 {
    return rec[1..];
}
const color_targets = [_]m.ColorTarget{ .foreground, .background, .cursor };
const query_modes = [_]u16{ 1004, 2026, 2027, 2031 };
const set_modes = [_]u16{ 25, 1049, 2004, 2026, 1004 };
const shapes = [_]m.CursorShape{ .block_blink, .block, .underline_blink, .underline, .bar_blink, .bar };
const uri = "https://example.org/bench";
const kitty_flags: m.KittyFlags = .{ .disambiguate_escape_codes = true, .report_event_types = true, .report_alternate_keys = true };

// A reader's result, reduced to what every side can report.
fn emit(w: *Writer, check: bool, comptime fmt: []const u8, args: anytype) !usize {
    if (check) try w.print(fmt, args);
    return 1;
}
fn emitAny(w: *Writer, check: bool, result: anytype) !usize {
    std.mem.doNotOptimizeAway(&result);
    if (check) try w.print("{any}", .{result});
    return 1;
}

//=========================================================================
// morse, one function per public operation
//=========================================================================

const M = struct {
    fn cursorUp(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.cursorUp(w, n32(r));
        return 0;
    }
    fn cursorDown(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.cursorDown(w, n32(r));
        return 0;
    }
    fn cursorRight(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.cursorRight(w, n32(r));
        return 0;
    }
    fn cursorLeft(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.cursorLeft(w, n32(r));
        return 0;
    }
    fn cursorNextLine(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.cursorNextLine(w, n32(r));
        return 0;
    }
    fn cursorPrevLine(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.cursorPrevLine(w, n32(r));
        return 0;
    }
    fn cursorColumn(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.cursorColumn(w, n32(r));
        return 0;
    }
    fn cursorRow(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.cursorRow(w, n32(r));
        return 0;
    }
    fn cursorSave(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.cursorSave(w);
        return 0;
    }
    fn cursorRestore(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.cursorRestore(w);
        return 0;
    }
    fn clearLine(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.clearLine(w, @enumFromInt(0));
        return 0;
    }
    fn clearScreen(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.clearScreen(w, @enumFromInt(0));
        return 0;
    }
    fn scrollRegion(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.scrollRegion(w, 1 + r[0] % 8, 20 + @as(u32, r[0]));
        return 0;
    }
    fn scrollRegionReset(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.scrollRegionReset(w);
        return 0;
    }
    fn scrollUp(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.scrollUp(w, n32(r));
        return 0;
    }
    fn scrollDown(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.scrollDown(w, n32(r));
        return 0;
    }
    fn insertLines(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.insertLines(w, n32(r));
        return 0;
    }
    fn deleteLines(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.deleteLines(w, n32(r));
        return 0;
    }
    fn insertChars(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.insertChars(w, n32(r));
        return 0;
    }
    fn deleteChars(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.deleteChars(w, n32(r));
        return 0;
    }
    fn eraseChars(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.eraseChars(w, n32(r));
        return 0;
    }
    fn repeatChar(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.repeatChar(w, n32(r));
        return 0;
    }
    fn resetStyle(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.resetStyle(w);
        return 0;
    }
    fn diffStyle(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        const from: m.Style = .{ .bold = r[0] & 1 != 0, .fg = .rgb(r[0], 100, 50) };
        const to: m.Style = .{ .italic = r[0] & 2 != 0, .fg = .rgb(r[0] +% 1, 100, 50), .bg = .palette(r[0]) };
        try m.diffStyle(w, from, to);
        return 0;
    }
    fn applySgr(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        if (comptime !@hasDecl(m, "applySgr")) return error.Unavailable;
        // A reader starts from the bytes: frame the CSI, then apply it.
        const csi = m.parseCsi(r) orelse return error.NotSgr;
        var style: m.Style = .{};
        m.applySgr(&style, csi.params);
        std.mem.doNotOptimizeAway(&style);
        const fg = style.fg;
        const bg = style.bg;
        return emit(w, check, "bold={} italic={} underline={} fg={s}:{d},{d},{d} bg={s}:{d},{d},{d}", .{ style.bold, style.italic, style.underline != .none, @tagName(fg.kind), fg.r, fg.g, fg.b, @tagName(bg.kind), bg.r, bg.g, bg.b });
    }
    fn paletteRgb(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        if (comptime !@hasDecl(m, "paletteRgb")) return error.Unavailable;
        return emitAny(w, check, m.paletteRgb(r[0]));
    }
    fn setMode(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.setMode(w, set_modes[r[0] % set_modes.len], r[0] & 1 != 0);
        return 0;
    }
    fn privateMode(comptime name: []const u8) Op {
        return struct {
            fn f(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
                try @field(m, name).set(w, r[0] & 1 != 0);
                return 0;
            }
        }.f;
    }
    fn mouse(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.mouse(w, .{ .motion = .any });
        return 0;
    }
    fn mouseOff(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.mouseOff(w);
        return 0;
    }
    fn kittyKeyboardPush(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.kittyKeyboardPush(w, .fromBits(@truncate((r[0] | 1) & 15)));
        return 0;
    }
    fn kittyKeyboardPop(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.kittyKeyboardPop(w);
        return 0;
    }
    fn kittyKeyboardQuery(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.kittyKeyboardQuery(w);
        return 0;
    }
    fn kittyKeyboardSet(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.kittyKeyboardSet(w, .fromBits(@truncate((r[0] | 1) & 15)), @enumFromInt(1 + r[0] % 3));
        return 0;
    }
    fn modifyKeys(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.modifyKeys(w, .other_keys, r[0] % 3);
        return 0;
    }
    fn modifyKeysReset(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.modifyKeysReset(w);
        return 0;
    }
    fn queryModifyKeys(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.queryModifyKeys(w, .other_keys);
        return 0;
    }
    fn cursorShape(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.cursorShape(w, shapes[r[0] % shapes.len]);
        return 0;
    }
    fn pointerShape(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.pointerShape(w, if (r[0] & 1 != 0) .pointer else .text);
        return 0;
    }
    fn pointerShapeReset(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.pointerShapeReset(w);
        return 0;
    }
    fn queryMode(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.queryMode(w, query_modes[r[0] % query_modes.len]);
        return 0;
    }
    fn requestCursorPosition(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.requestCursorPosition(w);
        return 0;
    }
    fn requestExtendedCursorPosition(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.requestExtendedCursorPosition(w);
        return 0;
    }
    fn queryColorScheme(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.queryColorScheme(w);
        return 0;
    }
    fn queryDeviceAttributes(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.queryDeviceAttributes(w);
        return 0;
    }
    fn querySecondaryDeviceAttributes(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.querySecondaryDeviceAttributes(w);
        return 0;
    }
    fn queryVersion(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.queryVersion(w);
        return 0;
    }
    fn queryColor(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.queryColor(w, color_targets[r[0] % 3]);
        return 0;
    }
    fn setColor(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.setColor(w, color_targets[r[0] % 3], rgb16(r[0]));
        return 0;
    }
    fn resetColor(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.resetColor(w, color_targets[r[0] % 3]);
        return 0;
    }
    fn queryPaletteColor(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.queryPaletteColor(w, r[0]);
        return 0;
    }
    fn setPaletteColor(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.setPaletteColor(w, r[0], rgb16(r[0]));
        return 0;
    }
    fn resetPaletteColor(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.resetPaletteColor(w, r[0]);
        return 0;
    }
    fn resetPalette(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.resetPalette(w);
        return 0;
    }
    fn queryWindowSize(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        const what = [_]m.SizeQuery{ .text_area_pixels, .cell_pixels, .text_area_cells };
        try m.queryWindowSize(w, what[r[0] % what.len]);
        return 0;
    }
    fn resizeTextArea(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.resizeTextArea(w, 24 + @as(u32, r[0]), 80 + @as(u32, r[0]));
        return 0;
    }
    fn queryCapability(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.queryCapability(w, if (r[0] & 1 != 0) "RGB" else "Smulx");
        return 0;
    }
    fn queryCapabilities(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.queryCapabilities(w, cap_names[0 .. r.len - 1]);
        return 0;
    }
    fn transmitImage(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.transmitImage(w, .{ .image = .{ .id = n32(r) }, .format = .rgba, .width = 1, .height = @intCast((r.len - 1) / 4), .quiet = .failures }, body(r));
        return 0;
    }
    fn placeImage(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.placeImage(w, .{ .image = .{ .id = n32(r) }, .placement = .{ .keep_cursor = true } });
        return 0;
    }
    fn deleteImage(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.deleteImage(w, .{ .target = .{ .image = .{ .id = n32(r) } } });
        return 0;
    }
    fn queryGraphics(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.queryGraphics(w, n32(r));
        return 0;
    }
    fn transmitFrame(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.transmitFrame(w, .{ .image = .{ .id = n32(r) }, .width = 1, .height = @intCast((r.len - 1) / 4) }, body(r));
        return 0;
    }
    fn animateImage(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.animateImage(w, .{ .image = .{ .id = n32(r) }, .state = .running, .current = 1 + r[0] % 4 });
        return 0;
    }
    fn composeFrames(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.composeFrames(w, .{ .image = .{ .id = n32(r) }, .source = 1, .destination = 2, .width = 8 + @as(u32, r[0]), .height = 8 });
        return 0;
    }
    fn placeholderRow(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.placeholderRow(w, .{ .id = n32(r), .row = r[0] % 32, .columns = 80 });
        return 0;
    }
    fn placeholderCell(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.placeholderCell(w, r[0] % 32, r[0] % 64, r[0]);
        return 0;
    }
    fn title(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.title(w, body(r));
        return 0;
    }
    fn iconName(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.iconName(w, body(r));
        return 0;
    }
    fn titlePush(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.titlePush(w);
        return 0;
    }
    fn titlePop(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.titlePop(w);
        return 0;
    }
    fn workingDirectory(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.workingDirectory(w, body(r));
        return 0;
    }
    fn hyperlink(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.hyperlink(w, body(r), uri);
        return 0;
    }
    fn textSize(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.textSize(w, .{ .scale = 2, .width = 1 }, body(r));
        return 0;
    }
    fn promptStart(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.promptStart(w);
        return 0;
    }
    fn promptEnd(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.promptEnd(w);
        return 0;
    }
    fn commandStart(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.commandStart(w);
        return 0;
    }
    fn commandEnd(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.commandEnd(w, r[0]);
        return 0;
    }
    fn progress(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.progress(w, .{ .percent = r[0] % 101 });
        return 0;
    }
    fn clipboardWrite(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.clipboardWrite(w, .clipboard, body(r));
        return 0;
    }
    fn clipboardRequest(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.clipboardRequest(w, .clipboard);
        return 0;
    }
    fn notify(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.notify(w, "bench", body(r));
        return 0;
    }
    fn notify9(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.notify9(w, body(r));
        return 0;
    }
    fn encodeMouse(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.encodeMouse(w, .{ .button = .left, .x = n32(r), .y = 12, .press = r[0] & 1 == 0 });
        return 0;
    }
    fn extraCursors(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.extraCursors(w, .block, &.{.{ .cells = cursor_cells[0 .. r.len - 1] }});
        return 0;
    }
    fn extraCursorsClear(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.extraCursorsClear(w);
        return 0;
    }
    fn extraCursorColor(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try m.extraCursorColor(w, .cursor, .rgb(r[0], 100, 50));
        return 0;
    }
    fn queryExtraCursorSupport(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.queryExtraCursorSupport(w);
        return 0;
    }
    fn queryExtraCursors(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.queryExtraCursors(w);
        return 0;
    }
    fn queryExtraCursorColors(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try m.queryExtraCursorColors(w);
        return 0;
    }
    fn probeWrite(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try (m.Probe{ .graphics_id = n32(r) }).write(w);
        return 0;
    }

    // Readers: the record is the reply, as the terminal sends it.
    fn parseMouse(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        return mouseLine(w, check, m.parseMouse(r) orelse return error.Rejected);
    }
    fn parseMouseX10(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        return mouseLine(w, check, m.parseMouseX10(r) orelse return error.Rejected);
    }
    fn parseMouseRxvt(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        return mouseLine(w, check, m.parseMouseRxvt(r) orelse return error.Rejected);
    }
    fn mouseLine(w: *Writer, check: bool, e: m.MouseEvent) !usize {
        std.mem.doNotOptimizeAway(&e);
        const mods = @as(u8, @intFromBool(e.shift)) + 2 * @as(u8, @intFromBool(e.alt)) + 4 * @as(u8, @intFromBool(e.ctrl));
        return emit(w, check, "mouse:{d}:{d}:{d}:{d}:{s}", .{ @intFromEnum(e.button), e.x, e.y, mods, if (e.motion) "motion" else if (e.press) "press" else "release" });
    }
    fn toCells(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        return emitAny(w, check, m.toCells(.{ .button = .left, .x = 8 * @as(u32, r[0]), .y = 16 * 12, .press = true, .pixels = true }, 8, 16));
    }
    fn toCellsAt(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        if (comptime !@hasDecl(m, "toCellsAt")) return error.Unavailable;
        return emitAny(w, check, m.toCellsAt(.{ .button = .left, .x = 8 * @as(u32, r[0]) + 3, .y = 16 * 12, .press = true, .pixels = true }, 7.5, 15.25));
    }
    fn parseCursorPosition(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        const p = m.parseCursorPosition(r) orelse return error.Rejected;
        std.mem.doNotOptimizeAway(&p);
        return emit(w, check, "{d};{d}", .{ p.row, p.col });
    }
    fn parseExtendedCursorPosition(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        return emitAny(w, check, m.parseExtendedCursorPosition(r) orelse return error.Rejected);
    }
    fn parseModeReply(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        const rep = m.parseModeReply(r) orelse return error.Rejected;
        std.mem.doNotOptimizeAway(&rep);
        return emit(w, check, "{d}:{d}", .{ rep.mode, @intFromEnum(rep.state) });
    }
    fn parseColorSchemeReply(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        const s = m.parseColorSchemeReply(r) orelse return error.Rejected;
        std.mem.doNotOptimizeAway(&s);
        return emit(w, check, "{s}", .{@tagName(s)});
    }
    fn parseDeviceAttributes(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        const da = m.parseDeviceAttributes(r) orelse return error.Rejected;
        std.mem.doNotOptimizeAway(&da);
        if (check) {
            for (da.list(), 0..) |a, i| try w.print("{s}{d}", .{ if (i == 0) "" else ";", a });
        }
        return 1;
    }
    fn parseSecondaryDeviceAttributes(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        return emitAny(w, check, m.parseSecondaryDeviceAttributes(r) orelse return error.Rejected);
    }
    fn parseVersion(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        const s = m.parseVersion(r) orelse return error.Rejected;
        std.mem.doNotOptimizeAway(s.ptr);
        return emit(w, check, "{s}", .{s});
    }
    fn parseKittyKeyboardReply(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        const f = m.parseKittyKeyboardReply(r) orelse return error.Rejected;
        std.mem.doNotOptimizeAway(&f);
        return emit(w, check, "flags:{d}", .{f.bits()});
    }
    fn parseModifyKeysReply(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        return emitAny(w, check, m.parseModifyKeysReply(r) orelse return error.Rejected);
    }
    fn parseColorReply(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        const c = m.parseColorReply(r) orelse return error.Rejected;
        std.mem.doNotOptimizeAway(&c);
        return emit(w, check, "{d}:{d}:{d}:{d}", .{ @intFromEnum(c.target), c.color.r >> 8, c.color.g >> 8, c.color.b >> 8 });
    }
    fn parsePaletteReply(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        const c = m.parsePaletteReply(r) orelse return error.Rejected;
        std.mem.doNotOptimizeAway(&c);
        return emit(w, check, "{d}:{d}:{d}:{d}", .{ c.index, c.color.r >> 8, c.color.g >> 8, c.color.b >> 8 });
    }
    fn parseWindowSize(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        const s = m.parseWindowSize(r) orelse return error.Rejected;
        std.mem.doNotOptimizeAway(&s);
        return emit(w, check, "{d}:{d}:{d}", .{ @intFromEnum(s.what), s.height, s.width });
    }
    fn parseCapabilityReply(w: *Writer, r: []const u8, check: bool, scratch: []u8) !usize {
        const reply = m.parseCapabilityReply(r) orelse return error.Rejected;
        var it = reply.iterator();
        var n: usize = 0;
        while (it.next()) |cap| : (n += 1) {
            const name = try cap.decodeName(scratch[0 .. scratch.len / 2]);
            const value = try cap.decodeValue(scratch[scratch.len / 2 ..]);
            std.mem.doNotOptimizeAway(name.ptr);
            std.mem.doNotOptimizeAway(value.ptr);
            if (check) try w.print("{s}={s};", .{ name, value });
        }
        return n;
    }
    fn parseGraphicsResponse(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        const g = m.parseGraphicsResponse(r) orelse return error.Rejected;
        std.mem.doNotOptimizeAway(&g);
        return emit(w, check, "ok={}", .{g.ok()});
    }
    fn parseClipboardReply(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        const c = m.parseClipboardReply(r) orelse return error.Rejected;
        std.mem.doNotOptimizeAway(&c);
        return emit(w, check, "{d}", .{c.decodedLen()});
    }
    fn clipboardReplyDecoded(w: *Writer, r: []const u8, check: bool, scratch: []u8) !usize {
        const c = m.parseClipboardReply(r) orelse return error.Rejected;
        const text = try m.decodeClipboard(c, scratch);
        std.mem.doNotOptimizeAway(text.ptr);
        if (check) try w.print("{x}", .{text});
        return text.len;
    }
    fn parseHyperlink(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        if (comptime !@hasDecl(m, "parseHyperlink")) return error.Unavailable;
        const cs = m.parseControlString(r) orelse return error.Rejected;
        const link = m.parseHyperlink(cs.body) orelse return error.Rejected;
        std.mem.doNotOptimizeAway(&link);
        return emit(w, check, "{s}|{s}", .{ link.params, link.uri });
    }
    fn parseTextSize(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        if (comptime !@hasDecl(m, "parseTextSize")) return error.Unavailable;
        const cs = m.parseControlString(r) orelse return error.Rejected;
        return emitAny(w, check, m.parseTextSize(cs.body) orelse return error.Rejected);
    }
    fn parseCsi(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        if (comptime !@hasDecl(m, "parseCsi")) return error.Unavailable;
        const c = m.parseCsi(r) orelse return error.Rejected;
        std.mem.doNotOptimizeAway(&c);
        return emit(w, check, "{s}|{s}|{s}|{c}|{d}", .{ if (c.marker == 0) "" else &[_]u8{c.marker}, c.params, c.intermediates, c.final, c.len });
    }
    fn parseControlString(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        if (comptime !@hasDecl(m, "parseControlString")) return error.Unavailable;
        const c = m.parseControlString(r) orelse return error.Rejected;
        std.mem.doNotOptimizeAway(&c);
        return emit(w, check, "{c}|{s}|{d}", .{ c.introducer, c.body, c.len });
    }
    fn parseExtraCursorSupport(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        return emitAny(w, check, m.parseExtraCursorSupport(r) orelse return error.Rejected);
    }
    fn parseExtraCursors(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        const rep = m.parseExtraCursors(r) orelse return error.Rejected;
        var it = rep.iterator();
        var n: usize = 0;
        while (it.next()) |c| : (n += 1) {
            std.mem.doNotOptimizeAway(&c);
            if (check) try w.print("{any};", .{c});
        }
        return n;
    }
    fn parseExtraCursorColors(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        return emitAny(w, check, m.parseExtraCursorColors(r) orelse return error.Rejected);
    }
    fn replyParse(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        const rep = m.Reply.parse(r) orelse return error.Rejected;
        std.mem.doNotOptimizeAway(&rep);
        return emit(w, check, "{s}", .{@tagName(rep)});
    }
    fn probeMatches(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        const q: m.Probe.Question = @enumFromInt(r[r.len - 1] % @typeInfo(m.Probe.Question).@"enum".fields.len);
        return emit(w, check, "{}", .{m.probeMatches(r[0 .. r.len - 1], q)});
    }
    fn probeAnswered(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        const rep = m.Reply.parse(r) orelse return error.Rejected;
        const q = m.probeAnswered(.{ .reply = rep });
        std.mem.doNotOptimizeAway(&q);
        return emit(w, check, "{s}", .{if (q) |x| @tagName(x) else "none"});
    }
    fn checkText(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        if (comptime !@hasDecl(m, "checkText")) return error.Unavailable;
        const ok = if (m.checkText(body(r))) true else |_| false;
        return emit(w, check, "{}", .{ok});
    }
    fn printable(w: *Writer, r: []const u8, check: bool, scratch: []u8) !usize {
        if (comptime !@hasDecl(m, "printable")) return error.Unavailable;
        const out = try m.printable(scratch, body(r));
        std.mem.doNotOptimizeAway(out.ptr);
        if (check) try w.print("{x}", .{out});
        return out.len;
    }
    fn keyEventTyped(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        if (comptime !@hasDecl(m.KeyEvent, "typed")) return error.Unavailable;
        const ev = m.KeyEvent.typed(body(r), .{ .ctrl = r[0] & 1 != 0 });
        std.mem.doNotOptimizeAway(&ev);
        return emit(w, check, "{s}:{d}", .{ @tagName(ev.key), ev.mods.bits() });
    }
    fn eventCopy(w: *Writer, r: []const u8, check: bool, scratch: []u8) !usize {
        if (comptime !@hasDecl(m.Event, "copy")) return error.Unavailable;
        // A run of pasted text, owned past the next read.
        const ev: m.Event = .{ .text = body(r) };
        const copy = try ev.copy(scratch);
        std.mem.doNotOptimizeAway(&copy);
        return emit(w, check, "{d}", .{copy.text.len});
    }
    fn consoleDecode(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        var d: m.ConsoleDecoder = .{};
        var n: usize = 0;
        for (body(r)) |c| {
            for ([_]bool{ true, false }) |down| {
                var events = d.feed(.{ .key = .{ .key_down = down, .virtual_key_code = std.ascii.toUpper(c), .unicode_char = c } });
                while (events.next()) |e| {
                    n += 1;
                    std.mem.doNotOptimizeAway(&e);
                    if (check) try w.print("{s};", .{@tagName(e)});
                }
            }
        }
        if (d.flush()) |e| {
            n += 1;
            std.mem.doNotOptimizeAway(&e);
        }
        return n;
    }
};

const cap_names = blk: {
    var names: [64][]const u8 = undefined;
    const base = [_][]const u8{ "RGB", "Smulx", "Setulc", "Tc", "Ms", "Ss", "Se", "colors" };
    for (&names, 0..) |*n, i| n.* = base[i % base.len];
    break :blk names;
};
const cursor_cells = blk: {
    var cells: [256]m.CursorCell = undefined;
    for (&cells, 0..) |*c, i| c.* = .{ .row = 1 + i / 80, .col = 1 + i % 80 };
    break :blk cells;
};

fn costOp(comptime name: []const u8) Op {
    return struct {
        fn f(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
            if (comptime !@hasDecl(m, "cost")) return error.Unavailable;
            const c = @field(m.cost, name);
            const n = n32(r);
            const len: usize = if (comptime std.mem.eql(u8, name, "diffStyle"))
                c(.{ .bold = r[0] & 1 != 0, .fg = .rgb(r[0], 100, 50) }, .{ .fg = .rgb(r[0] +% 1, 100, 50), .bg = .palette(r[0]) })
            else if (comptime std.mem.eql(u8, name, "setStyle"))
                c(.{ .bold = true, .fg = .rgb(r[0], 100, 50) })
            else if (comptime std.mem.eql(u8, name, "cursorTo") or std.mem.eql(u8, name, "scrollRegion"))
                c(n, 12)
            else if (comptime std.mem.eql(u8, name, "clearLine") or std.mem.eql(u8, name, "clearScreen"))
                c(@enumFromInt(0))
            else if (comptime std.mem.eql(u8, name, "setMode"))
                c(set_modes[r[0] % set_modes.len], r[0] & 1 != 0)
            else if (comptime std.mem.eql(u8, name, "hyperlinkStart"))
                c(uri, null)
            else if (comptime std.mem.eql(u8, name, "hyperlink"))
                c(body(r), uri)
            else if (comptime std.mem.eql(u8, name, "textSize"))
                c(.{ .scale = 2, .width = 1 }, body(r))
            else if (comptime @typeInfo(@TypeOf(c)).@"fn".params.len == 0)
                c()
            else
                c(n);
            std.mem.doNotOptimizeAway(len);
            return emit(w, check, "{d}", .{len});
        }
    }.f;
}

pub const morse_ops = .{
    .{ "cursorUp", M.cursorUp },                                 .{ "cursorDown", M.cursorDown },
    .{ "cursorRight", M.cursorRight },                           .{ "cursorLeft", M.cursorLeft },
    .{ "cursorNextLine", M.cursorNextLine },                     .{ "cursorPrevLine", M.cursorPrevLine },
    .{ "cursorColumn", M.cursorColumn },                         .{ "cursorRow", M.cursorRow },
    .{ "cursorSave", M.cursorSave },                             .{ "cursorRestore", M.cursorRestore },
    .{ "clearLine", M.clearLine },                               .{ "clearScreen", M.clearScreen },
    .{ "scrollRegion", M.scrollRegion },                         .{ "scrollRegionReset", M.scrollRegionReset },
    .{ "scrollUp", M.scrollUp },                                 .{ "scrollDown", M.scrollDown },
    .{ "insertLines", M.insertLines },                           .{ "deleteLines", M.deleteLines },
    .{ "insertChars", M.insertChars },                           .{ "deleteChars", M.deleteChars },
    .{ "eraseChars", M.eraseChars },                             .{ "repeatChar", M.repeatChar },
    .{ "resetStyle", M.resetStyle },                             .{ "diffStyle", M.diffStyle },
    .{ "applySgr", M.applySgr },                                 .{ "paletteRgb", M.paletteRgb },
    .{ "setMode", M.setMode },                                   .{ "altScreen", M.privateMode("altScreen") },
    .{ "bracketedPaste", M.privateMode("bracketedPaste") },      .{ "syncOutput", M.privateMode("syncOutput") },
    .{ "focusEvents", M.privateMode("focusEvents") },            .{ "cursorVisible", M.privateMode("cursorVisible") },
    .{ "unicodeCore", M.privateMode("unicodeCore") },            .{ "inBandResize", M.privateMode("inBandResize") },
    .{ "win32Input", M.privateMode("win32Input") },              .{ "autoWrap", M.privateMode("autoWrap") },
    .{ "colorScheme", M.privateMode("colorScheme") },            .{ "mouse", M.mouse },
    .{ "mouseOff", M.mouseOff },                                 .{ "kittyKeyboardPush", M.kittyKeyboardPush },
    .{ "kittyKeyboardPop", M.kittyKeyboardPop },                 .{ "kittyKeyboardQuery", M.kittyKeyboardQuery },
    .{ "kittyKeyboardSet", M.kittyKeyboardSet },                 .{ "modifyKeys", M.modifyKeys },
    .{ "modifyKeysReset", M.modifyKeysReset },                   .{ "queryModifyKeys", M.queryModifyKeys },
    .{ "cursorShape", M.cursorShape },                           .{ "pointerShape", M.pointerShape },
    .{ "pointerShapeReset", M.pointerShapeReset },               .{ "queryMode", M.queryMode },
    .{ "requestCursorPosition", M.requestCursorPosition },       .{ "requestExtendedCursorPosition", M.requestExtendedCursorPosition },
    .{ "queryColorScheme", M.queryColorScheme },                 .{ "queryDeviceAttributes", M.queryDeviceAttributes },
    .{ "querySecondaryDeviceAttributes", M.querySecondaryDeviceAttributes }, .{ "queryVersion", M.queryVersion },
    .{ "queryColor", M.queryColor },                             .{ "setColor", M.setColor },
    .{ "resetColor", M.resetColor },                             .{ "queryPaletteColor", M.queryPaletteColor },
    .{ "setPaletteColor", M.setPaletteColor },                   .{ "resetPaletteColor", M.resetPaletteColor },
    .{ "resetPalette", M.resetPalette },                         .{ "queryWindowSize", M.queryWindowSize },
    .{ "resizeTextArea", M.resizeTextArea },                     .{ "queryCapability", M.queryCapability },
    .{ "queryCapabilities", M.queryCapabilities },               .{ "transmitImage", M.transmitImage },
    .{ "placeImage", M.placeImage },                             .{ "deleteImage", M.deleteImage },
    .{ "queryGraphics", M.queryGraphics },                       .{ "transmitFrame", M.transmitFrame },
    .{ "animateImage", M.animateImage },                         .{ "composeFrames", M.composeFrames },
    .{ "placeholderRow", M.placeholderRow },                     .{ "placeholderCell", M.placeholderCell },
    .{ "title", M.title },                                       .{ "iconName", M.iconName },
    .{ "titlePush", M.titlePush },                               .{ "titlePop", M.titlePop },
    .{ "workingDirectory", M.workingDirectory },                 .{ "hyperlink", M.hyperlink },
    .{ "textSize", M.textSize },                                 .{ "promptStart", M.promptStart },
    .{ "promptEnd", M.promptEnd },                               .{ "commandStart", M.commandStart },
    .{ "commandEnd", M.commandEnd },                             .{ "progress", M.progress },
    .{ "clipboardWrite", M.clipboardWrite },                     .{ "clipboardRequest", M.clipboardRequest },
    .{ "notify", M.notify },                                     .{ "notify9", M.notify9 },
    .{ "encodeMouse", M.encodeMouse },                           .{ "extraCursors", M.extraCursors },
    .{ "extraCursorsClear", M.extraCursorsClear },               .{ "extraCursorColor", M.extraCursorColor },
    .{ "queryExtraCursorSupport", M.queryExtraCursorSupport },   .{ "queryExtraCursors", M.queryExtraCursors },
    .{ "queryExtraCursorColors", M.queryExtraCursorColors },     .{ "Probe.write", M.probeWrite },
    .{ "parseMouse", M.parseMouse },                             .{ "parseMouseX10", M.parseMouseX10 },
    .{ "parseMouseRxvt", M.parseMouseRxvt },                     .{ "toCells", M.toCells },
    .{ "toCellsAt", M.toCellsAt },                               .{ "parseCursorPosition", M.parseCursorPosition },
    .{ "parseExtendedCursorPosition", M.parseExtendedCursorPosition }, .{ "parseModeReply", M.parseModeReply },
    .{ "parseColorSchemeReply", M.parseColorSchemeReply },       .{ "parseDeviceAttributes", M.parseDeviceAttributes },
    .{ "parseSecondaryDeviceAttributes", M.parseSecondaryDeviceAttributes }, .{ "parseVersion", M.parseVersion },
    .{ "parseKittyKeyboardReply", M.parseKittyKeyboardReply },   .{ "parseModifyKeysReply", M.parseModifyKeysReply },
    .{ "parseColorReply", M.parseColorReply },                   .{ "parsePaletteReply", M.parsePaletteReply },
    .{ "parseWindowSize", M.parseWindowSize },                   .{ "parseCapabilityReply", M.parseCapabilityReply },
    .{ "parseGraphicsResponse", M.parseGraphicsResponse },       .{ "parseClipboardReply", M.parseClipboardReply },
    .{ "clipboardReplyDecoded", M.clipboardReplyDecoded },       .{ "parseHyperlink", M.parseHyperlink },
    .{ "parseTextSize", M.parseTextSize },                       .{ "parseCsi", M.parseCsi },
    .{ "parseControlString", M.parseControlString },             .{ "parseExtraCursorSupport", M.parseExtraCursorSupport },
    .{ "parseExtraCursors", M.parseExtraCursors },               .{ "parseExtraCursorColors", M.parseExtraCursorColors },
    .{ "Reply.parse", M.replyParse },                            .{ "probeMatches", M.probeMatches },
    .{ "probeAnswered", M.probeAnswered },                       .{ "checkText", M.checkText },
    .{ "printable", M.printable },                               .{ "KeyEvent.typed", M.keyEventTyped },
    .{ "Event.copy", M.eventCopy },                              .{ "ConsoleDecoder", M.consoleDecode },
} ++ costs;

const cost_names = .{
    "diffStyle",      "setStyle",       "resetStyle",     "cursorTo",          "cursorUp",    "cursorDown",
    "cursorRight",    "cursorLeft",     "cursorNextLine", "cursorPrevLine",    "cursorColumn", "cursorRow",
    "cursorSave",     "cursorRestore",  "clearLine",      "clearScreen",       "scrollRegion", "scrollRegionReset",
    "scrollUp",       "scrollDown",     "insertLines",    "deleteLines",       "insertChars", "deleteChars",
    "eraseChars",     "repeatChar",     "setMode",        "hyperlinkStart",    "hyperlinkEnd", "hyperlink",
    "textSize",
};
const costs = blk: {
    var out: [cost_names.len]struct { []const u8, Op } = undefined;
    for (&out, 0..) |*o, i| o.* = .{ "cost." ++ cost_names[i], costOp(cost_names[i]) };
    break :blk out;
};

//=========================================================================
// libvaxis: its control-sequence spellings and its input parser
//=========================================================================

const V = struct {
    fn cursorRight(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try w.print(v.ctlseqs.cuf, .{n32(r)});
        return 0;
    }
    fn cursorLeft(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try w.print(v.ctlseqs.cub, .{n32(r)});
        return 0;
    }
    fn clearScreen(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try w.writeAll(v.ctlseqs.erase_below_cursor);
        return 0;
    }
    fn resetStyle(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try w.writeAll(v.ctlseqs.sgr_reset);
        return 0;
    }
    fn fixed(comptime on: []const u8, comptime off: []const u8) Op {
        return struct {
            fn f(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
                try w.writeAll(if (r[0] & 1 != 0) on else off);
                return 0;
            }
        }.f;
    }
    fn constant(comptime s: []const u8) Op {
        return struct {
            fn f(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
                try w.writeAll(s);
                return 0;
            }
        }.f;
    }
    fn kittyKeyboardPush(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try w.print(v.ctlseqs.csi_u_push, .{@as(u5, @truncate((r[0] | 1) & 15))});
        return 0;
    }
    fn cursorShape(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try w.print(v.ctlseqs.cursor_shape, .{@intFromEnum(shapes[r[0] % shapes.len])});
        return 0;
    }
    fn pointerShape(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try w.print(v.ctlseqs.osc22_mouse_shape, .{if (r[0] & 1 != 0) "pointer" else "text"});
        return 0;
    }
    fn queryMode(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try w.writeAll(switch (query_modes[r[0] % query_modes.len]) {
            1004 => v.ctlseqs.decrqm_focus,
            2026 => v.ctlseqs.decrqm_sync,
            2027 => v.ctlseqs.decrqm_unicode,
            else => v.ctlseqs.decrqm_color_scheme,
        });
        return 0;
    }
    fn queryColor(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try w.writeAll(switch (r[0] % 3) {
            0 => v.ctlseqs.osc10_query,
            1 => v.ctlseqs.osc11_query,
            else => v.ctlseqs.osc12_query,
        });
        return 0;
    }
    fn setColor(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        const args = .{ r[0], r[0], @as(u8, 0x64), @as(u8, 0x64), @as(u8, 0x32), @as(u8, 0x32) };
        switch (r[0] % 3) {
            0 => try w.print(v.ctlseqs.osc10_set, args),
            1 => try w.print(v.ctlseqs.osc11_set, args),
            else => try w.print(v.ctlseqs.osc12_set, args),
        }
        return 0;
    }
    fn resetColor(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try w.writeAll(switch (r[0] % 3) {
            0 => v.ctlseqs.osc10_reset,
            1 => v.ctlseqs.osc11_reset,
            else => v.ctlseqs.osc12_reset,
        });
        return 0;
    }
    fn queryPaletteColor(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try w.print(v.ctlseqs.osc4_query, .{r[0]});
        return 0;
    }
    fn placeImage(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try w.print(v.ctlseqs.kitty_graphics_preamble, .{n32(r)});
        try w.writeAll(v.ctlseqs.kitty_graphics_closing);
        return 0;
    }
    fn deleteAll(w: *Writer, _: []const u8, _: bool, _: []u8) !usize {
        try w.writeAll(v.ctlseqs.kitty_graphics_clear);
        return 0;
    }
    fn title(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try w.print(v.ctlseqs.osc2_set_title, .{body(r)});
        return 0;
    }
    fn hyperlink(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try w.print(v.ctlseqs.osc8, .{ "", uri });
        try w.writeAll(body(r));
        try w.writeAll(v.ctlseqs.osc8_clear);
        return 0;
    }
    fn textSize(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try w.print(v.ctlseqs.scaled_text, .{ 2, 1, body(r) });
        return 0;
    }
    fn clipboardWrite(w: *Writer, r: []const u8, _: bool, scratch: []u8) !usize {
        // libvaxis takes the payload already in base64; encoding it is the caller's job.
        const encoded = std.base64.standard.Encoder.encode(scratch, body(r));
        try w.print(v.ctlseqs.osc52_clipboard_copy, .{encoded});
        return 0;
    }
    fn notify(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try w.print(v.ctlseqs.osc777_notify, .{ "bench", body(r) });
        return 0;
    }
    fn notify9(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try w.print(v.ctlseqs.osc9_notify, .{body(r)});
        return 0;
    }
    fn extraCursorColor(w: *Writer, r: []const u8, _: bool, _: []u8) !usize {
        try w.print(v.ctlseqs.secondary_cursors_rgb, .{ r[0], 100, 50 });
        return 0;
    }

    // The input parser: one complete reply per call.
    fn parse(r: []const u8, cpr: bool) !?v.Event {
        var pending: v.Parser.CursorPositionRequests = .{ .io = io };
        var parser: v.Parser = .{ .cursor_position_requests = &pending };
        if (cpr) pending.request();
        const result = try parser.parse(r, std.heap.c_allocator);
        if (result.n != r.len) return error.Partial;
        return result.event;
    }
    fn parseMouse(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        const e = (try parse(r, false)) orelse return error.Rejected;
        std.mem.doNotOptimizeAway(&e);
        const mouse = e.mouse;
        return emit(w, check, "mouse:{d}:{d}:{d}:{d}:{s}", .{ @intFromEnum(mouse.button), @as(i32, mouse.col) + 1, @as(i32, mouse.row) + 1, @as(u3, @bitCast(mouse.mods)), if (mouse.type == .motion or mouse.type == .drag) "motion" else @tagName(mouse.type) });
    }
    fn parseCursorPosition(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        const e = (try parse(r, true)) orelse return error.Rejected;
        std.mem.doNotOptimizeAway(&e);
        return emit(w, check, "{d};{d}", .{ e.cursor_position.row + 1, e.cursor_position.col + 1 });
    }
    fn parseColorSchemeReply(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        const e = (try parse(r, false)) orelse return error.Rejected;
        std.mem.doNotOptimizeAway(&e);
        return emit(w, check, "{s}", .{@tagName(e.color_scheme)});
    }
    fn present(comptime tag: std.meta.Tag(v.Event)) Op {
        return struct {
            fn f(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
                const e = (try parse(r, false)) orelse return error.Rejected;
                std.mem.doNotOptimizeAway(&e);
                if (e != tag) return error.Rejected;
                return emit(w, check, "present", .{});
            }
        }.f;
    }
    fn colorReport(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        const e = (try parse(r, false)) orelse return error.Rejected;
        std.mem.doNotOptimizeAway(&e);
        const c = e.color_report;
        const which: u16 = switch (c.kind) {
            .fg => 10,
            .bg => 11,
            .cursor => 12,
            .index => |i| i,
        };
        return emit(w, check, "{d}:{d}:{d}:{d}", .{ which, c.value[0], c.value[1], c.value[2] });
    }
    fn clipboardReplyDecoded(w: *Writer, r: []const u8, check: bool, _: []u8) !usize {
        const e = (try parse(r, false)) orelse return error.Rejected;
        defer std.heap.c_allocator.free(e.paste);
        std.mem.doNotOptimizeAway(e.paste.ptr);
        if (check) try w.print("{x}", .{e.paste});
        return e.paste.len;
    }
};

pub const vaxis_ops = .{
    .{ "cursorRight", V.cursorRight },                    .{ "cursorLeft", V.cursorLeft },
    .{ "clearScreen", V.clearScreen },                    .{ "resetStyle", V.resetStyle },
    .{ "altScreen", V.fixed(v.ctlseqs.smcup, v.ctlseqs.rmcup) },
    .{ "bracketedPaste", V.fixed(v.ctlseqs.bp_set, v.ctlseqs.bp_reset) },
    .{ "syncOutput", V.fixed(v.ctlseqs.sync_set, v.ctlseqs.sync_reset) },
    .{ "cursorVisible", V.fixed(v.ctlseqs.show_cursor, v.ctlseqs.hide_cursor) },
    .{ "unicodeCore", V.fixed(v.ctlseqs.unicode_set, v.ctlseqs.unicode_reset) },
    .{ "inBandResize", V.fixed(v.ctlseqs.in_band_resize_set, v.ctlseqs.in_band_resize_reset) },
    .{ "colorScheme", V.fixed(v.ctlseqs.color_scheme_set, v.ctlseqs.color_scheme_reset) },
    .{ "kittyKeyboardPush", V.kittyKeyboardPush },        .{ "kittyKeyboardPop", V.constant(v.ctlseqs.csi_u_pop) },
    .{ "kittyKeyboardQuery", V.constant(v.ctlseqs.csi_u_query) },
    .{ "cursorShape", V.cursorShape },                    .{ "pointerShape", V.pointerShape },
    .{ "queryMode", V.queryMode },                        .{ "requestCursorPosition", V.constant(v.ctlseqs.cursor_position_request) },
    .{ "queryColorScheme", V.constant(v.ctlseqs.color_scheme_request) },
    .{ "queryDeviceAttributes", V.constant(v.ctlseqs.primary_device_attrs) },
    .{ "queryVersion", V.constant(v.ctlseqs.xtversion) }, .{ "queryColor", V.queryColor },
    .{ "setColor", V.setColor },                          .{ "resetColor", V.resetColor },
    .{ "queryPaletteColor", V.queryPaletteColor },        .{ "resetPalette", V.constant(v.ctlseqs.osc4_reset) },
    .{ "placeImage", V.placeImage },                      .{ "title", V.title },                                .{ "hyperlink", V.hyperlink },
    .{ "textSize", V.textSize },                          .{ "clipboardWrite", V.clipboardWrite },
    .{ "clipboardRequest", V.constant(v.ctlseqs.osc52_clipboard_request) },
    .{ "notify", V.notify },                              .{ "notify9", V.notify9 },
    .{ "extraCursorsClear", V.constant(v.ctlseqs.reset_secondary_cursors) },
    .{ "extraCursorColor", V.extraCursorColor },          .{ "queryExtraCursorSupport", V.constant(v.ctlseqs.multi_cursor_query) },
    .{ "parseMouse", V.parseMouse },                      .{ "parseMouseX10", V.parseMouse },
    .{ "parseCursorPosition", V.parseCursorPosition },    .{ "parseColorSchemeReply", V.parseColorSchemeReply },
    .{ "parseDeviceAttributes", V.present(.cap_da1) },    .{ "parseKittyKeyboardReply", V.present(.cap_kitty_keyboard) },
    .{ "parseGraphicsResponse", V.present(.cap_kitty_graphics) },
    .{ "parseColorReply", V.colorReport },                .{ "parsePaletteReply", V.colorReport },
    .{ "clipboardReplyDecoded", V.clipboardReplyDecoded },
};

pub fn find(comptime table: anytype, name: []const u8) ?Op {
    inline for (table) |entry| {
        if (std.mem.eql(u8, entry[0], name)) return entry[1];
    }
    return null;
}
