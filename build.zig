const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //=====================================================================
    // The module. Pure Zig, no dependencies, nothing to link.
    //=====================================================================

    const module = b.addModule("morse", .{
        .root_source_file = b.path("src/morse.zig"),
        .target = target,
        .optimize = optimize,
    });

    //=====================================================================
    // Tests. The suite lives beside the code it tests, so the root module's
    // test block is what pulls every file in.
    //=====================================================================

    const tests = b.addTest(.{
        .name = "morse-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/morse.zig"),
            .target = target,
            .optimize = optimize,
            // Off so that `zig build test --fuzz` compiles. Zig 0.16.0's
            // test runner hands `@errorReturnTrace()` to a function that
            // takes the other `StackTrace`, which is a type error at every
            // fuzz call site and only under `-ffuzz`. Error return traces
            // are worth little in a fuzz run -- the input is the report --
            // and the ordinary `zig build test` prints the same failures
            // with the same messages.
            .error_tracing = false,
        }),
    });

    const test_step = b.step("test", "Run the morse tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Compiling without running is what a target this host cannot execute can
    // still be held to, and it is also the default step: a module on its own
    // installs nothing, so `zig build -Dtarget=...` would otherwise compile
    // nothing at all and report a pass it did not earn.
    const check_step = b.step("check", "Compile the tests and the examples without running them");
    check_step.dependOn(&tests.step);
    b.getInstallStep().dependOn(check_step);

    //=====================================================================
    // Examples
    //
    // Built AND run, against the module a consumer gets. An example that is
    // only compiled proves the names still resolve; running it is what
    // proves the bytes are still the bytes. examples/usage.zig is also where
    // README.md's Usage block comes from -- see ci/readme_usage.sh -- so the
    // snippet a reader copies cannot drift from code CI executes.
    //=====================================================================

    const examples_step = b.step("examples", "Build and run the examples");
    for (example_sources) |source| {
        const example = b.addExecutable(.{
            .name = std.fs.path.stem(source),
            .root_module = b.createModule(.{
                .root_source_file = b.path(source),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "morse", .module = module }},
            }),
        });
        examples_step.dependOn(&b.addRunArtifact(example).step);
        check_step.dependOn(&example.step);
    }
    test_step.dependOn(examples_step);

    //=====================================================================
    // Conformance
    //
    // The suite above pins every writer to its exact bytes, which says morse
    // writes what the specifications say. It cannot say a terminal agrees.
    // This step builds a terminal emulator from source, feeds it what the
    // writers produce, and asserts on the state the emulator ends up in --
    // then reads its replies back through this package's parsers.
    //
    // The dependency is lazy and pinned to a commit, because the step is a
    // claim about what one revision of one emulator accepted. It is also
    // asked for only when morse is the root package: `lazyDependency` marks
    // a dependency needed for the whole invocation rather than for the step
    // that called it, and a program that merely depends on morse must not
    // fetch a terminal emulator to build.
    //=====================================================================

    const conformance_step = b.step("conformance", "Run the writers through a terminal emulator");
    if (b.pkg_hash.len != 0) {
        conformance_step.dependOn(&b.addFail(
            "the conformance step runs in morse's own tree, not from a package that depends on it",
        ).step);
    } else if (b.lazyDependency("emulator", .{
        .target = target,
        .optimize = optimize,
        // The emulator's SIMD paths are vendored C and C++, and nothing
        // under test here goes through them. morse's own promise is that
        // building it involves no C toolchain; the step that checks morse
        // should not quietly need one.
        .simd = false,
    })) |emulator| {
        const conformance = b.addTest(.{
            .name = "morse-conformance",
            .root_module = b.createModule(.{
                .root_source_file = b.path("conformance/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "morse", .module = module },
                    .{ .name = "vt", .module = emulator.module("ghostty-vt") },
                },
            }),
        });
        conformance_step.dependOn(&b.addRunArtifact(conformance).step);
    } else {
        // Reached only where the fetch cannot happen at all. A step that
        // quietly does nothing would report a pass it did not earn.
        conformance_step.dependOn(&b.addFail(
            "the conformance step needs its emulator dependency, and it was not fetched",
        ).step);
    }
}

/// Every example, listed rather than globbed: a build graph that scans a
/// directory is not reproducible from the manifest alone.
const example_sources = [_][]const u8{
    "examples/usage.zig",
};
