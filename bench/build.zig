const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const vaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize }).module("vaxis");
    const archived_root = b.option([]const u8, "package-root", "Archived package root");
    const package_root = archived_root orelse "..";
    const morse = if (archived_root == null) b.dependency("after", .{ .target = target, .optimize = optimize }).module("morse") else b.createModule(.{ .root_source_file = b.path(b.fmt("{s}/src/morse.zig", .{package_root})), .target = target, .optimize = optimize });
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
    const Side = enum { morse, vaxis, ghostty };
    for ([_]Side{ .morse, .vaxis, .ghostty }) |side| {
        const options = b.addOptions();
        options.addOption(Side, "side", side);
        const module = b.createModule(.{
            .root_source_file = b.path("src/zig.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{ .{ .name = "morse", .module = morse }, .{ .name = "options", .module = options.createModule() } },
        });
        // libvaxis and libghostty-vt each carry their own build of uucode,
        // so no binary takes both.
        if (side != .ghostty) module.addImport("vaxis", vaxis);
        if (side == .ghostty) {
            // The emulator morse's conformance step and tycho pin, without
            // its vendored SIMD C++, as morse builds it.
            const ghostty = b.lazyDependency("ghostty", .{ .target = target, .optimize = optimize, .simd = false }) orelse continue;
            module.addImport("vt", ghostty.module("ghostty-vt"));
        }
        const exe = b.addExecutable(.{ .name = b.fmt("{s}-bench", .{@tagName(side)}), .root_module = module });
        b.installArtifact(exe);
    }
}
