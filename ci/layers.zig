//! Source layers, lowest first. Every source has one explicit place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "values", .patterns = &.{
        "src/base64.zig",
        "src/corpus.zig",
        "src/key_types.zig",
        "src/seq.zig",
        "src/strings.zig",
    } },
    .{ .name = "sequences", .patterns = &.{
        "src/clipboard.zig",
        "src/cursor.zig",
        "src/graphics.zig",
        "src/mode.zig",
        "src/mouse.zig",
        "src/notify.zig",
        "src/osc.zig",
        "src/query.zig",
        "src/status.zig",
        "src/style.zig",
        "src/tcap.zig",
    } },
    .{ .name = "protocols", .patterns = &.{
        "src/device.zig",
        "src/multicursor.zig",
        "src/win32.zig",
    } },
    .{ .name = "replies", .patterns = &.{
        "src/reply.zig",
    } },
    .{ .name = "stream", .patterns = &.{
        "src/key.zig",
    } },
    .{ .name = "probes and tests", .patterns = &.{
        "src/probe.zig",
        "src/work_test.zig",
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

pub const required = blk: {
    var count: usize = 0;
    for (layers) |layer| count += layer.patterns.len;
    var paths: [count][]const u8 = undefined;
    var i: usize = 0;
    for (layers) |layer| for (layer.patterns) |path| {
        paths[i] = path;
        i += 1;
    };
    break :blk paths;
};
