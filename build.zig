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
        }),
    });

    const test_step = b.step("test", "Run the morse tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

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
    }
    test_step.dependOn(examples_step);
}

/// Every example, listed rather than globbed: a build graph that scans a
/// directory is not reproducible from the manifest alone.
const example_sources = [_][]const u8{
    "examples/usage.zig",
};
