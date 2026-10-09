const std = @import("std");
const workloads = @import("budgets.zig");
const shakedown = @import("shakedown");
const bench = shakedown.bench;
const gpa = std.testing.allocator;
const metadata: bench.Metadata = .{ .commit = "test" };

test "measurement: smoke emits all prior timed workloads as valid JSONL" {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try workloads.measure(gpa, std.testing.io, &out.writer, .{ .smoke = true }, metadata);
    var parsed = try bench.parse(gpa, out.written());
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 30), parsed.rows.items.len);
    try std.testing.expectEqualStrings("diffStyle, two calls", parsed.rows.items[0].value.row);
    try std.testing.expectEqualStrings("KeyParser mixed, buffer 16384, read 131072", parsed.rows.items[29].value.row);
    for (parsed.rows.items) |row| {
        try std.testing.expect(row.value.smoke);
        try std.testing.expectEqual(@as(usize, 0), row.value.samples.len);
        try std.testing.expectEqualStrings("test", row.value.commit);
    }
}

test "measurement: row selection and invalid arguments" {
    const selected = try workloads.options(&.{ "budgets", "--row", "cursorTo", "--smoke" });
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try workloads.measure(gpa, std.testing.io, &out.writer, selected, metadata);
    var parsed = try bench.parse(gpa, out.written());
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.rows.items.len);
    try std.testing.expectEqualStrings("move", parsed.rows.items[0].value.unit);
    try std.testing.expectEqualStrings("four moves", parsed.rows.items[1].value.unit);
    try std.testing.expectError(error.UnknownArgument, workloads.options(&.{ "budgets", "--typo" }));
    try std.testing.expectError(error.MissingRow, workloads.options(&.{ "budgets", "--row" }));
    try std.testing.expectError(error.MissingRow, workloads.options(&.{ "budgets", "--row", "--smoke" }));
    try std.testing.expectError(error.DuplicateArgument, workloads.options(&.{ "budgets", "--smoke", "--smoke" }));
    try std.testing.expectError(error.DuplicateArgument, workloads.options(&.{ "budgets", "--row", "a", "--row", "b" }));
}

test "measurement: output errors propagate and calibration terminates" {
    var failing: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, workloads.measure(gpa, std.testing.io, &failing, .{ .smoke = true }, metadata));
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var context = try workloads.Context.init(gpa, true);
    defer context.deinit(gpa);
    var clock: shakedown.Clock = .init(std.testing.io, .{});
    try std.testing.expectError(error.Unmeasurable, bench.run(gpa, clock.io(), &out.writer, &context, &.{.{
        .name = "cursorTo",
        .unit = "move",
        .run = workloads.Context.cursorMove,
    }}, metadata, .{
        .minimum = .fromSeconds(60),
        .max_batch = 1,
    }));
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

test "measurement: callbacks reuse data and propagate workload failures" {
    var context = try workloads.Context.init(gpa, true);
    defer context.deinit(gpa);
    try context.check();
    const rows = [_]bench.Row(workloads.Context){
        .{ .name = "transmit 1 MB", .unit = "image", .run = workloads.Context.transmit },
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const sink = context.sink;
    {
        context.sink = sink[0..1];
        defer context.sink = sink;
        try std.testing.expectError(error.WriteFailed, bench.run(gpa, std.testing.io, &out.writer, &context, &rows, metadata, .{ .smoke = true }));
    }
    for (0..2) |_| {
        try context.styleDiff(2);
        try context.cursorMove(2);
        try context.encoder(2);
        try context.formatter(2);
        try context.transmit(2);
        try context.decode(context.mixed.len * 2);
    }
    try std.testing.expectError(error.PartialInput, context.decode(1));
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

test "measurement: real workload callback produces measured JSONL with shared policy" {
    const Cursor = struct {
        workload: *workloads.Context,
        clock: *shakedown.Clock,
        calls: usize = 0,
        fn run(context: *@This(), units: u64) !void {
            try context.workload.cursorMove(units);
            context.calls += 1;
            context.clock.advance(.fromNanoseconds(1000 * units));
        }
    };
    var workload = try workloads.Context.init(gpa, true);
    defer workload.deinit(gpa);
    var clock: shakedown.Clock = .init(std.testing.io, .{});
    var cursor: Cursor = .{ .workload = &workload, .clock = &clock };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try bench.run(gpa, clock.io(), &out.writer, &cursor, &.{.{
        .name = "cursorTo",
        .unit = "move",
        .run = Cursor.run,
    }}, metadata, .{ .minimum = .zero, .samples = 3, .warmup = 1, .max_batch = 1 });
    var parsed = try bench.parse(gpa, out.written());
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 5), cursor.calls);
    const row = parsed.rows.items[0].value;
    try std.testing.expect(!row.smoke);
    try std.testing.expectEqual(@as(usize, 3), row.samples.len);
    try std.testing.expectEqual(@as(f64, 1000), row.best);
    try std.testing.expectEqual(@as(f64, 1000), row.median);
    try std.testing.expectEqual(@as(f64, 1000), row.p99);
    try std.testing.expectEqual(@as(f64, 1_000_000), row.ops_per_second);
}
