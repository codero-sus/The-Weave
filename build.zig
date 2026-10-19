const std = @import("std");

/// Weave — a single-file full-stack language.
///
/// Build targets:
///   zig build            -> install `weave` into zig-out/bin
///   zig build run -- ... -> run the CLI with arguments
///   zig build test       -> unit tests (leak-checked)
///   zig build itest      -> end-to-end protocol test (boots a real server, drives it over WebSocket)
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // No preferred mode: `-Doptimize=…` picks it, and a plain `zig build` stays
    // Debug so local runs keep safety checks and leak detection.
    const optimize = b.standardOptimizeOption(.{});

    const version = b.option([]const u8, "version", "Version string baked into the binary") orelse "0.1.0";

    // Browser assets live in assets/ and reach the binary through @embedFile.
    const assets = b.addModule("assets", .{ .root_source_file = b.path("assets/embed.zig") });
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    // ---- main executable -------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "weave",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addOptions("build_options", options);
    exe.root_module.addImport("assets", assets);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the weave CLI");
    run_step.dependOn(&run_cmd.step);

    // ---- unit tests ------------------------------------------------------
    // Tests always build Debug: runtime safety checks and leak detection are
    // the whole point of running them.
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = .Debug,
    });
    unit_tests.root_module.addOptions("build_options", options);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // ---- end-to-end integration test ------------------------------------
    const itest = b.addExecutable(.{
        .name = "weave-itest",
        .root_source_file = b.path("src/itest.zig"),
        .target = target,
        .optimize = .Debug,
    });
    itest.root_module.addOptions("build_options", options);
    itest.root_module.addImport("assets", assets);
    const run_itest = b.addRunArtifact(itest);
    const itest_step = b.step("itest", "Run the end-to-end server/WebSocket protocol test");
    itest_step.dependOn(&run_itest.step);

    // ---- examples check (parses + type-checks every bundled example) -----
    const examples = b.addExecutable(.{
        .name = "weave-examples",
        .root_source_file = b.path("src/examples_check.zig"),
        .target = target,
        .optimize = .Debug,
    });
    examples.root_module.addOptions("build_options", options);
    const run_examples = b.addRunArtifact(examples);
    const examples_step = b.step("examples", "Compile + render every bundled example");
    examples_step.dependOn(&run_examples.step);
}
