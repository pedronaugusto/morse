//! The conformance build: morse's writers fed to a terminal emulator that is
//! not ours, and its replies read back through morse's parsers.
//!
//! Separate from the package's own build on purpose. Zig compiles the build
//! script of every package a manifest names once it is in the package
//! cache, asked for or not, so an emulator named in morse's manifest, even
//! lazily, would be compiled by every build of a program on morse whose
//! cache holds it -- and that build script accepts exactly one Zig. Named
//! only here, it is in no tree but this one. `zig build conformance` in the
//! package root runs this.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const morse = b.dependency("morse", .{ .target = target, .optimize = optimize });
    const emulator = b.dependency("emulator", .{
        .target = target,
        .optimize = optimize,
        // The emulator's SIMD paths are vendored C and C++, and nothing
        // under test here goes through them. morse's own promise is that
        // building it involves no C toolchain; the build that checks morse
        // should not quietly need one.
        .simd = false,
    });

    const tests = b.addTest(.{
        .name = "morse-conformance",
        .filters = if (b.option([]const u8, "test-filter", "Select tests by name")) |filter| &.{filter} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "morse", .module = morse.module("morse") },
                .{ .name = "vt", .module = emulator.module("ghostty-vt") },
            },
        }),
    });

    const test_step = b.step("test", "Run the writers through the terminal emulator");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    b.getInstallStep().dependOn(&tests.step);
}
