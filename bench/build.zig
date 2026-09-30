const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const vaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize }).module("vaxis");
    const morse = b.createModule(.{ .root_source_file = b.path("../src/morse.zig"), .target = target, .optimize = optimize });
    for ([_]bool{ false, true }) |rival| {
        const options = b.addOptions();
        options.addOption(bool, "rival", rival);
        const exe = b.addExecutable(.{
            .name = if (rival) "vaxis-bench" else "morse-bench",
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
