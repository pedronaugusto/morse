const std = @import("std");

pub fn build(b: *std.Build) !void {
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
        .filters = if (b.option([]const u8, "test-filter", "Select tests by name")) |filter| &.{filter} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // The tests' corpus entries and repeated text come from shakedown, a
    // lazy, test-only dependency asked for only in morse's own tree: a
    // program that depends on morse neither builds these tests nor fetches
    // it. A dependency still to fetch is kept and returned last, so one
    // configure pass asks for every one of them.
    var needed: error{LazyDependencyNeeded}!void = {};
    if (b.pkg_hash.len == 0) {
        if (b.dependencyLazy("shakedown", .{ .target = target, .optimize = optimize })) |shakedown| {
            tests.root_module.addImport("shakedown", shakedown.module("shakedown"));
        } else |err| needed = err;
    }

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
    // proves the bytes are still the bytes. examples/quickstart.zig is also where
    // README.md's Usage block comes from -- see zig build docs -- usage -- so the
    // snippet a reader copies cannot drift from code CI executes.
    //=====================================================================

    const examples_step = b.step("examples", "Build and run the examples");
    for (example_sources) |source| {
        const example = b.addExecutable(.{
            .name = std.Io.Dir.path.stem(source),
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
    // Benchmarks
    //
    // Speed ceilings with a clock in them, run by hand on a quiet machine:
    // `zig build bench`, usually with -Doptimize=ReleaseFast. `check`
    // compiles them, so CI keeps them building, and nothing in CI runs
    // them: a timing on a shared runner says more about the runner.
    //=====================================================================

    const bench = b.addTest(.{
        .name = "morse-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/budgets.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "morse", .module = module }},
        }),
    });
    const bench_step = b.step("bench", "Run the speed ceilings in bench/ (by hand, on a quiet machine)");
    bench_step.dependOn(&b.addRunArtifact(bench).step);
    check_step.dependOn(&bench.step);

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
    // asked for only when morse is the root package: `dependencyLazy` marks
    // a dependency needed for the whole invocation rather than for the step
    // that called it, and a program that merely depends on morse must not
    // fetch a terminal emulator to build. Its error is kept and returned last,
    // as shakedown's is.
    //=====================================================================

    const conformance_step = b.step("conformance", "Run the writers through a terminal emulator");
    if (b.pkg_hash.len != 0) {
        conformance_step.dependOn(&b.addFail(
            "the conformance step runs in morse's own tree, not from a package that depends on it",
        ).step);
    } else if (b.dependencyLazy("emulator", .{
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
    } else |err| needed = err;

    //=====================================================================
    // CI wiring
    //
    // Only in morse's own tree. preflight is a lazy dependency, and a lazy
    // package's build.zig can only be reached through `lazyImport`: a plain
    // `@import` of it fails to compile in any project that depends on morse
    // and has not fetched preflight, which is every such project.
    //=====================================================================

    if (b.pkg_hash.len != 0) return;
    if (b.lazyImport(@This(), "preflight")) |preflight| {
        preflight.addCi(b, .{ .tests = test_step, .portable_tests = true });
        // The build a consumer gets: nothing morse fetches for itself.
        preflight.addConsumerCheck(b, .{ .package = "morse", .program = b.path("ci/consumer.zig") });
    }
    return needed;
}

/// Every example, listed rather than globbed: a build graph that scans a
/// directory is not reproducible from the manifest alone.
const example_sources = [_][]const u8{
    "examples/usage.zig",
    "examples/quickstart.zig",
};
