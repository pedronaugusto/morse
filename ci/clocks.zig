//! Library code and unit tests leave clocks to the caller and the bench.
const std = @import("std");

fn clockName(name: []const u8) bool {
    for ([_][]const u8{ "Clock", "Timer", "Instant", "nanoTimestamp", "microTimestamp", "milliTimestamp", "timestamp", "clock_gettime", "gettimeofday", "mach_absolute_time", "QueryPerformanceCounter", "sleep" }) |clock| {
        if (std.mem.eql(u8, clock, name)) return true;
    }
    return false;
}

fn count(text: [:0]const u8) usize {
    var tokenizer = std.zig.Tokenizer.init(text);
    var found: usize = 0;
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return found;
        if (token.tag == .identifier and clockName(text[token.loc.start..token.loc.end])) found += 1;
    }
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try std.Io.Dir.cwd().openDir(init.io, "src", .{ .iterate = true });
    defer dir.close(init.io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    var found: usize = 0;
    while (try walker.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const text = try dir.readFileAllocOptions(init.io, entry.path, a, .limited(16 * 1024 * 1024), .of(u8), 0);
        if (count(text) == 0) continue;
        var tokenizer = std.zig.Tokenizer.init(text);
        while (true) {
            const token = tokenizer.next();
            if (token.tag == .eof) break;
            const name = text[token.loc.start..token.loc.end];
            if (token.tag != .identifier or !clockName(name)) continue;
            const line = 1 + std.mem.count(u8, text[0..token.loc.start], "\n");
            std.debug.print("src/{s}:{d}: {s}: clocks belong on the bench branch\n", .{ entry.path, line, name });
            found += 1;
        }
    }
    if (found > 0) return error.ClockInUnitSuite;
}

test "clocks in code fail, literals and comments cannot supply a clock" {
    try std.testing.expectEqual(@as(usize, 2), count("const now = std.Io.Clock.now(io); sleep();"));
    try std.testing.expectEqual(@as(usize, 0), count("const fixture = \"Clock Timer sleep\"; // timestamp\n\\\\ Clock\n"));
    try std.testing.expectEqual(@as(usize, 1), count("test \"Clock\" { helper.Timer.start(); }"));
}
