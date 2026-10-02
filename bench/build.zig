const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const vaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize }).module("vaxis");
    const package_root = b.option([]const u8, "package-root", "Archived package root") orelse "..";
    const morse = b.createModule(.{ .root_source_file = b.path(b.fmt("{s}/src/morse.zig", .{package_root})), .target = target, .optimize = optimize });
    const budget_options = b.addOptions();
    budget_options.addOption(bool, "smoke", b.option(bool, "smoke", "Skip every benchmark clock") orelse false);
    const budgets = b.addTest(.{
        .name = "morse-budgets",
        .filters = &.{"bench:"},
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("{s}/bench.zig", .{package_root})),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "bench_options", .module = budget_options.createModule() }},
        }),
    });
    b.installArtifact(budgets);
    for ([_]bool{ false, true }) |comparison| {
        const options = b.addOptions();
        options.addOption(bool, "comparison", comparison);
        const exe = b.addExecutable(.{
            .name = if (comparison) "vaxis-bench" else "morse-bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/zig.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{ .{ .name = "morse", .module = morse }, .{ .name = "vaxis", .module = vaxis }, .{ .name = "options", .module = options.createModule() } },
            }),
        });
        b.installArtifact(exe);
    }
}
