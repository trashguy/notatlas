const std = @import("std");

pub fn build(b: *std.Build) void {
    // Pin glibc_version so Zig builds its bundled glibc (incl. crt1.o)
    // instead of pulling Arch's system Scrt1.o, whose .sframe section
    // currently trips Zig 0.15.2's bundled LLD on linux-gnu native targets.
    const target = b.standardTargetOptions(.{
        .default_target = .{ .abi = .gnu, .glibc_version = .{ .major = 2, .minor = 38, .patch = 0 } },
    });
    const optimize = b.standardOptimizeOption(.{});

    const ymlz_dep = b.dependency("ymlz", .{
        .target = target,
        .optimize = optimize,
    });
    const zglfw_dep = b.dependency("zglfw", .{
        .target = target,
        .optimize = optimize,
    });
    const vulkan_headers_dep = b.dependency("vulkan-headers", .{});
    const vulkan_include = vulkan_headers_dep.path("include");

    // Library module: math, wave_query, yaml_loader. No graphics deps here.
    const notatlas_mod = b.addModule("notatlas", .{
        .root_source_file = b.path("src/root.zig"),
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

    // Sandbox executable: window + Vulkan playground. Phase 0 M2.
    const sandbox_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    sandbox_mod.addImport("notatlas", notatlas_mod);
    sandbox_mod.addImport("zglfw", zglfw_dep.module("root"));
    sandbox_mod.addIncludePath(vulkan_include);
    sandbox_mod.linkLibrary(zglfw_dep.artifact("glfw"));
    // Pinned glibc makes Zig treat this as cross-compile; add system dirs
    // back so it can resolve libvulkan/libX11.
    sandbox_mod.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    sandbox_mod.linkSystemLibrary("vulkan", .{});
    sandbox_mod.link_libc = true;

    // Compile GLSL → SPIR-V via system glslc and embed each blob into the
    // sandbox module as a named anonymous import. Code references them via
    // `@embedFile("ocean_vert_spv")` etc. M2.6 will replace this with a
    // runtime hot-reload subprocess.
    embedShader(b, sandbox_mod, "assets/shaders/ocean.vert", "ocean_vert_spv");
    embedShader(b, sandbox_mod, "assets/shaders/ocean.frag", "ocean_frag_spv");

    const sandbox = b.addExecutable(.{
        .name = "notatlas-sandbox",
        .root_module = sandbox_mod,
    });
    b.installArtifact(sandbox);

    const run_sandbox = b.addRunArtifact(sandbox);
    if (b.args) |args| run_sandbox.addArgs(args);
    const run_step = b.step("run", "Run the notatlas sandbox");
    run_step.dependOn(&run_sandbox.step);
}

fn embedShader(
    b: *std.Build,
    mod: *std.Build.Module,
    src_path: []const u8,
    import_name: []const u8,
) void {
    const cmd = b.addSystemCommand(&.{ "glslc", "--target-env=vulkan1.3", "-O" });
    cmd.addFileArg(b.path(src_path));
    cmd.addArg("-o");
    const spv = cmd.addOutputFileArg(b.fmt("{s}.spv", .{import_name}));
    mod.addAnonymousImport(import_name, .{ .root_source_file = spv });
}
