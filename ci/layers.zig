//! Production source layers, lowest first. Every production source has one
//! place; test code is in no layer.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "values", .patterns = &.{
        "src/base64.zig",
        "src/utf8.zig",
        "src/framing.zig",
        "src/key/event.zig",
        "src/seq.zig",
        "src/strings.zig",
        "src/strip.zig",
    } },
    .{ .name = "sequences", .patterns = &.{
        "src/clipboard.zig",
        "src/cursor.zig",
        "src/graphics.zig",
        "src/iterm.zig",
        "src/mode.zig",
        "src/mouse.zig",
        "src/notify.zig",
        "src/osc.zig",
        "src/query.zig",
        "src/sixel.zig",
        "src/status.zig",
        "src/style.zig",
        "src/tcap.zig",
    } },
    .{ .name = "protocols", .patterns = &.{
        "src/device.zig",
        "src/key/encode.zig",
        "src/multicursor.zig",
        "src/win32.zig",
    } },
    .{ .name = "replies", .patterns = &.{
        "src/reply.zig",
    } },
    .{ .name = "stream", .patterns = &.{
        "src/key.zig",
    } },
    .{ .name = "probes", .patterns = &.{
        "src/probe.zig",
    } },
    .{ .name = "public", .patterns = &.{
        "src/morse.zig",
    } },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{};
pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "std",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

pub const required = [_][]const u8{
    "src/base64.zig",
    "src/utf8.zig",
    "src/framing.zig",
    "src/key/event.zig",
    "src/seq.zig",
    "src/strings.zig",
    "src/strip.zig",
    "src/clipboard.zig",
    "src/cursor.zig",
    "src/graphics.zig",
    "src/iterm.zig",
    "src/mode.zig",
    "src/mouse.zig",
    "src/notify.zig",
    "src/osc.zig",
    "src/query.zig",
    "src/sixel.zig",
    "src/status.zig",
    "src/style.zig",
    "src/tcap.zig",
    "src/device.zig",
    "src/key/encode.zig",
    "src/multicursor.zig",
    "src/win32.zig",
    "src/reply.zig",
    "src/key.zig",
    "src/probe.zig",
    "src/morse.zig",
    "src/tests.zig",
};

/// Tokens only their owners may spell. morse spells and reads bytes; the
/// terminal device, its modes and the console are conduit's. Library code
/// and unit tests leave clocks to the caller and the bench branch.
pub const owned: []const gantry.rules.TokenRule = &.{
    .{ .name = "console owner", .token = "CreateFileW" },
    .{ .name = "console owner", .token = "ReadConsoleInputW" },
    .{ .name = "console owner", .token = "GetConsoleMode" },
    .{ .name = "console owner", .token = "SetConsoleMode" },
    .{ .name = "console owner", .kind = .string, .token = "kernel32" },
    .{ .name = "terminal mode owner", .token = "tcgetattr" },
    .{ .name = "terminal mode owner", .token = "tcsetattr" },
    .{ .name = "terminal mode owner", .token = "ioctl" },
    .{ .name = "clocks belong on the bench branch", .token = "Clock" },
    .{ .name = "clocks belong on the bench branch", .token = "Timer" },
    .{ .name = "clocks belong on the bench branch", .token = "Instant" },
    .{ .name = "clocks belong on the bench branch", .token = "nanoTimestamp" },
    .{ .name = "clocks belong on the bench branch", .token = "microTimestamp" },
    .{ .name = "clocks belong on the bench branch", .token = "milliTimestamp" },
    .{ .name = "clocks belong on the bench branch", .token = "timestamp" },
    .{ .name = "clocks belong on the bench branch", .token = "clock_gettime" },
    .{ .name = "clocks belong on the bench branch", .token = "gettimeofday" },
    .{ .name = "clocks belong on the bench branch", .token = "mach_absolute_time" },
    .{ .name = "clocks belong on the bench branch", .token = "QueryPerformanceCounter" },
    .{ .name = "clocks belong on the bench branch", .token = "sleep" },
};
