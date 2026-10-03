const std = @import("std");
const m = @import("morse");
const v = @import("vaxis");
const comparison = @import("options").comparison;
extern "c" fn read(c_int, [*]u8, usize) isize;
extern "c" fn write(c_int, [*]const u8, usize) isize;
fn emit(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch @panic("report too long");
    var n: usize = 0;
    while (n < s.len) {
        const got = write(1, s.ptr + n, s.len - n);
        if (got <= 0) @panic("write failed");
        n += @intCast(got);
    }
}
fn cp(key: m.Key) u21 {
    return switch (key) {
        .char => |c| c,
        .enter => 13,
        .tab => 9,
        .escape => 27,
        .backspace => 127,
        .up => v.Key.up,
        .down => v.Key.down,
        .left => v.Key.left,
        .right => v.Key.right,
        .home => v.Key.home,
        .end => v.Key.end,
        .f => |n| v.Key.f1 + n - 1,
        else => 0,
    };
}
fn morseEvent(e: m.Event, check: bool) void {
    std.mem.doNotOptimizeAway(e);
    if (!check) return;
    switch (e) {
        .key => |k| emit("key:{d}:{d}:{s}\n", .{ cp(k.key), k.mods.bits(), @tagName(k.kind) }),
        .text => |text| {
            var iter = (std.unicode.Utf8View.init(text) catch unreachable).iterator();
            while (iter.nextCodepoint()) |c| emit("key:{d}:0:press\n", .{c});
        },
        .mouse => |mouse| emit("{s}:{d}:{d}:{d}:{d}:{s}\n", .{ if (mouse.pixels) "pixel_mouse" else "mouse", @intFromEnum(mouse.button), mouse.x, mouse.y, @as(u8, @intFromBool(mouse.shift)) + 2 * @as(u8, @intFromBool(mouse.alt)) + 4 * @as(u8, @intFromBool(mouse.ctrl)), if (mouse.motion) "motion" else if (!mouse.press) "release" else "press" }),
        .reply => |reply| switch (reply) {
            .color => |c| emit("reply:color:{d}:{d}:{d}:{d}\n", .{ @intFromEnum(c.target), c.color.r >> 8, c.color.g >> 8, c.color.b >> 8 }),
            .clipboard => |c| {
                var buf: [1024]u8 = undefined;
                emit("clipboard:{s}\n", .{m.decodeClipboard(c, &buf) catch "invalid"});
            },
            else => emit("reply:{s}\n", .{@tagName(reply)}),
        },
        else => emit("{s}\n", .{@tagName(e)}),
    }
}
fn vaxisEvent(e: v.Event, check: bool) void {
    std.mem.doNotOptimizeAway(e);
    if (!check) return;
    switch (e) {
        .key_press, .key_release => |k| emit("key:{d}:{d}:{s}\n", .{ k.codepoint, @as(u8, @bitCast(k.mods)), if (e == .key_release) "release" else "press" }),
        .mouse => |mouse| emit("mouse:{d}:{d}:{d}:{d}:{s}\n", .{ @intFromEnum(mouse.button), @as(i32, mouse.col) + 1, @as(i32, mouse.row) + 1, @as(u3, @bitCast(mouse.mods)), if (mouse.type == .motion or mouse.type == .drag) "motion" else @tagName(mouse.type) }),
        .color_report => |c| emit("reply:color:{d}:{d}:{d}:{d}\n", .{ @as(u16, switch (c.kind) {
            .fg => 10,
            .bg => 11,
            .cursor => 12,
            .index => 4,
        }), c.value[0], c.value[1], c.value[2] }),
        .paste => |s| emit("clipboard:{s}\n", .{s}),
        else => emit("{s}\n", .{@tagName(e)}),
    }
}
fn decode(data: []const u8, chunk: usize, burst: usize, check: bool, pixels: bool) !usize {
    var count: usize = 0;
    if (!comparison) {
        var buffer: [8192]u8 = undefined;
        var parser = m.KeyParser.init(&buffer);
        parser.mouse_pixels = pixels;
        var pos: usize = 0;
        while (pos < data.len) {
            const burst_end = @min(pos - pos % burst + burst, data.len);
            const end = @min(pos + chunk, burst_end);
            var events = parser.feed(data[pos..end]);
            while (events.next()) |e| {
                count += 1;
                morseEvent(e, check);
            }
            pos = end;
            if (pos == burst_end) {
                if (parser.flush()) |e| {
                    count += 1;
                    morseEvent(e, check);
                }
            }
        }
        if (parser.flush()) |e| {
            count += 1;
            morseEvent(e, check);
        }
    } else {
        var parser: v.Parser = .{};
        // Standalone vaxis parses a complete prefix. Retain incomplete bytes
        // exactly as its event loop does, without copying the read buffer.
        var pos: usize = 0;
        var end: usize = 0;
        while (end < data.len) {
            const burst_end = @min(end - end % burst + burst, data.len);
            end = @min(end + chunk, burst_end);
            while (pos < end) {
                // A read boundary is not an Escape timeout or UTF-8 EOF.
                if (end < burst_end and end - pos == 1 and data[pos] == 27) break;
                const result = parser.parse(data[pos..end], std.heap.page_allocator) catch {
                    // InvalidUTF8 may mean a split UTF-8 character.
                    if (end < burst_end) break;
                    if (check) emit("error\n", .{});
                    count += 1;
                    pos = end;
                    break;
                };
                if (result.n == 0) break;
                pos += result.n;
                if (result.event) |e| {
                    count += 1;
                    vaxisEvent(e, check);
                    if (e == .paste) std.heap.page_allocator.free(e.paste);
                }
            }
        }
        if (pos != data.len) {
            if (check) emit("incomplete\n", .{});
            count += 1;
        }
    }
    return count;
}
fn encode(task: []const u8, data: []const u8, check: bool) !usize {
    var count: usize = 0;
    var buffer: [2048]u8 = undefined;
    for (data) |value| {
        var w: std.Io.Writer = .fixed(&buffer);
        if (std.mem.eql(u8, task, "style")) {
            if (!comparison) {
                try m.setStyle(&w, .{ .bold = true, .fg = .rgb(value, 100, 50) });
                try m.resetStyle(&w);
            } else {
                try w.writeAll(v.ctlseqs.bold_set);
                try w.print(v.ctlseqs.fg_rgb, .{ value, @as(u8, 100), @as(u8, 50) });
                try w.writeAll(v.ctlseqs.sgr_reset);
            }
        } else if (std.mem.eql(u8, task, "cursor")) {
            if (!comparison) {
                try m.cursorTo(&w, @as(u32, value) + 1, 12);
            } else {
                try w.print(v.ctlseqs.cup, .{ @as(u32, value) + 1, @as(u32, 12) });
            }
        } else if (std.mem.eql(u8, task, "link")) {
            if (!comparison) {
                try m.hyperlinkStart(&w, "https://example.org/bench", null);
                try m.hyperlinkEnd(&w);
            } else {
                try w.print(v.ctlseqs.osc8, .{ "", "https://example.org/bench" });
                try w.writeAll(v.ctlseqs.osc8_clear);
            }
        } else if (std.mem.eql(u8, task, "graphics")) {
            if (!comparison) {
                try m.placeImage(&w, .{ .image = .{ .id = @as(u32, value) + 1 }, .placement = .{ .keep_cursor = true } });
            } else {
                try w.print(v.ctlseqs.kitty_graphics_preamble, .{@as(u32, value) + 1});
                try w.writeAll(v.ctlseqs.kitty_graphics_closing);
            }
        } else return error.UnknownTask;
        const bytes = w.buffered();
        std.mem.doNotOptimizeAway(bytes);
        count += bytes.len;
        if (check) {
            for (bytes) |byte| emit("{x:0>2}", .{byte});
            emit("\n", .{});
        }
    }
    return count;
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4 and args.len != 5) return error.Arguments;
    const check = std.mem.eql(u8, args[2], "check");
    const timed = std.mem.eql(u8, args[2], "full");
    const chunk = try std.fmt.parseInt(usize, args[3], 10);
    if (chunk == 0) return error.ZeroChunk;
    const buf = try init.gpa.alloc(u8, 32 * 1024 * 1024);
    defer init.gpa.free(buf);
    var len: usize = 0;
    while (len < buf.len) {
        const got = read(0, buf.ptr + len, buf.len - len);
        if (got < 0) return error.ReadFailed;
        if (got == 0) break;
        len += @intCast(got);
    }
    if (len == buf.len) return error.InputTooLarge;
    const burst = if (args.len == 5) try std.fmt.parseInt(usize, args[4], 10) else @max(len, 1);
    if (burst == 0) return error.ZeroBurst;
    const start = if (timed) std.Io.Clock.now(.awake, init.io).toNanoseconds() else 0;
    const count = if (std.mem.startsWith(u8, args[1], "decode")) try decode(buf[0..len], chunk, burst, check, std.mem.eql(u8, args[1], "decode_pixels")) else try encode(args[1], buf[0..len], check);
    const elapsed = if (timed) std.Io.Clock.now(.awake, init.io).toNanoseconds() - start else 0;
    if (check) emit("count:{d}\n", .{count});
    if (!check) emit("{d}\t{d}\t{d}\n", .{ len, count, elapsed });
}
