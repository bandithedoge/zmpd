const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const assert_version = b.option(
        bool,
        "assert_version",
        "Whether to assert the minimum required MPD version for various functions in Debug mode",
    ) orelse (optimize == .Debug);

    const options = b.addOptions();
    options.addOption(bool, "assert_version", assert_version);

    const zmpd = b.addModule("zmpd", .{
        .root_source_file = b.path("src/zmpd.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "options", .module = options.createModule() }},
    });

    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{
        .root_module = zmpd,
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    const lib = b.addLibrary(.{
        .name = "zmpd",
        .root_module = zmpd,
    });

    const docs_step = b.step("docs", "Build API documentation");
    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "doc",
    });
    docs_step.dependOn(&install_docs.step);

    const check = b.step("check", "Check compile errors");
    check.dependOn(&lib.step);
}
