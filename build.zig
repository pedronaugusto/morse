const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //=====================================================================
    // The module. Pure Zig and aegis scalar types, nothing to link.
    //=====================================================================

    const module = b.addModule("morse", .{
        .root_source_file = b.path("src/morse.zig"),
        .target = target,
        .optimize = optimize,
    });

    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize });
    module.addImport("aegis", aegis.module("aegis"));

    // Everything below is morse's own tree: a program that depends on morse
    // builds the module and its aegis dependency; no checkout-only tools.
    if (b.pkg_hash.len != 0) return;

    //=====================================================================
    // Tests. The suite lives beside the code it tests, so the root module's
    // test block is what pulls every file in.
    //=====================================================================

    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const tests = b.addTest(.{
        .name = "morse-tests",
        .filters = if (test_filter) |filter| &.{filter} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("aegis", aegis.module("aegis"));
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
    // Conformance
    //
    // The suite above pins every writer to its exact bytes, which says morse
    // writes what the specifications say. It cannot say a terminal agrees.
    // The build under conformance/ builds a terminal emulator from source,
    // feeds it what the writers produce, and asserts on the state the
    // emulator ends up in -- then reads its replies back through this
    // package's parsers. It is a build of its own, with the emulator in its
    // own manifest: see conformance/build.zig for why.
    //=====================================================================

    const conformance_step = b.step("conformance", "Run the writers through a terminal emulator");
    const conformance = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test" });
    conformance.setCwd(b.path("conformance"));
    conformance.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    if (test_filter) |filter| conformance.addArg(b.fmt("-Dtest-filter={s}", .{filter}));
    conformance.has_side_effects = true;
    conformance_step.dependOn(&conformance.step);

    //=====================================================================
    // CI wiring, and the test doubles
    //
    // preflight and shakedown are lazy, and only morse's own tree asks for
    // them, both in one configure pass. A lazy package's build.zig can only
    // be reached through `lazyImport`: a plain `@import` of it fails to
    // compile in any project that depends on morse and has not fetched
    // preflight, which is every such project.
    //=====================================================================

    const ci = b.lazyImport(@This(), "preflight");
    // Test support and measuring stay outside the consumer module.
    const shakedown = try b.dependencyLazy("shakedown", .{ .target = target, .optimize = optimize });
    tests.root_module.addImport("shakedown", shakedown.module("shakedown"));
    const measurement_options = b.addOptions();
    measurement_options.addOption([]const u8, "commit", "test");
    measurement_options.addOption([]const u8, "cpu", b.graph.host.result.cpu.model.name);
    measurement_options.addOption([]const u8, "os", @tagName(b.graph.host.result.os.tag));
    const measurement_tests = b.addTest(.{
        .name = "measurement-tests",
        .filters = if (test_filter) |filter| &.{filter} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/budgets_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "morse", .module = module },
                .{ .name = "shakedown", .module = shakedown.module("shakedown") },
            },
        }),
    });
    measurement_tests.root_module.addOptions("preflight_bench_options", measurement_options);
    test_step.dependOn(&b.addRunArtifact(measurement_tests).step);
    check_step.dependOn(&measurement_tests.step);
    if (ci) |preflight| {
        preflight.addCi(b, .{
            .tests = test_step,
            .portable_tests = true,
            // Workloads only; shakedown measures and preflight wires the steps.
            .bench = .{
                .programs = &.{.{ .name = "budgets", .source = "bench/budgets.zig" }},
                .imports = benchImports,
                .target = target,
                .optimize = optimize,
            },
        });
        // The build a consumer gets: nothing morse fetches for itself.
        preflight.addConsumerCheck(b, .{ .package = "morse", .program = b.path("ci/consumer.zig"), .packages = &.{aegis} });
    }
}

/// morse in the mode a benchmark builds in: an imported module keeps its own
/// mode, so a ReleaseFast benchmark over the Debug module would time the
/// Debug module.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const morse = b.createModule(.{ .root_source_file = b.path("src/morse.zig"), .target = target, .optimize = optimize });
    morse.addImport("aegis", b.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis"));
    // Select morse's published measuring pin rather than preflight's default.
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize });
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "morse", .module = morse },
        .{ .name = "shakedown", .module = shakedown.module("shakedown") },
    }) catch @panic("OOM");
}

/// Every example, listed rather than globbed: a build graph that scans a
/// directory is not reproducible from the manifest alone.
const example_sources = [_][]const u8{
    "examples/usage.zig",
    "examples/quickstart.zig",
};
