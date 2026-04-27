const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const notatlas_mod = b.addModule("notatlas", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ymlz_dep = b.dependency("ymlz", .{
        .target = target,
        .optimize = optimize,
    });
    notatlas_mod.addImport("ymlz", ymlz_dep.module("root"));

    const lib = b.addLibrary(.{
        .name = "notatlas",
        .root_module = notatlas_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    const tests = b.addTest(.{
        .root_module = notatlas_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
