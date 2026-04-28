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

    // Jolt physics — vendored at vendor/JoltPhysics (v5.5.0). Built as a
    // static C++ lib with the same compile defs Jolt's CMake emits for the
    // default x86_64 Linux configuration so headers see a matching ABI when
    // the C wrapper includes them. The wrapper itself (src/physics/
    // jolt_c_api.cpp) is bundled into the same library so libJolt.a is the
    // single physics artifact downstream code links.
    const jolt = buildJolt(b, target, optimize) catch @panic("jolt source enumeration failed");
    b.installArtifact(jolt);

    // Zig-side bindings for the C wrapper. Pure-Zig module; no graphics
    // deps. Importable as `physics`.
    const physics_mod = b.addModule("physics", .{
        .root_source_file = b.path("src/physics/jolt.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Sandbox executable: window + Vulkan playground. Phase 0 M2.
    const sandbox_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    sandbox_mod.addImport("notatlas", notatlas_mod);
    sandbox_mod.addImport("zglfw", zglfw_dep.module("root"));
    sandbox_mod.addImport("physics", physics_mod);
    sandbox_mod.addIncludePath(vulkan_include);
    sandbox_mod.linkLibrary(zglfw_dep.artifact("glfw"));
    sandbox_mod.linkLibrary(jolt);
    // Pinned glibc makes Zig treat this as cross-compile; add system dirs
    // back so it can resolve libvulkan/libX11.
    sandbox_mod.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    sandbox_mod.linkSystemLibrary("vulkan", .{});
    sandbox_mod.link_libc = true;

    // Compile GLSL → SPIR-V via system glslc and embed each blob into the
    // sandbox module as a named anonymous import. Code references them via
    // `@embedFile("ocean_vert_spv")` etc. M2.6 will replace this with a
    // runtime hot-reload subprocess.
    embedShader(b, sandbox_mod, "assets/shaders/fullscreen.vert", "fullscreen_vert_spv");
    embedShader(b, sandbox_mod, "assets/shaders/water.frag", "water_frag_spv");
    embedShader(b, sandbox_mod, "assets/shaders/box.vert", "box_vert_spv");
    embedShader(b, sandbox_mod, "assets/shaders/box.frag", "box_frag_spv");

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

const jolt_root = "vendor/JoltPhysics";

/// Build Jolt as a static library. Mirrors Jolt's `Jolt/Jolt.cmake` for the
/// default x86_64 Linux non-MSVC configuration: AVX2 instruction set, asserts
/// off in Release, no DebugRenderer / ObjectStream (their .cpp files are
/// `#ifdef`-gated and compile to empty TUs without the matching defines).
/// Single-precision; the standard simulation defaults.
fn buildJolt(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
    });
    mod.addIncludePath(b.path(jolt_root));

    // Match Jolt CMake `EMIT_X86_INSTRUCTION_SET_DEFINITIONS()` for the
    // AVX2 path. Headers expand SIMD intrinsics based on these — both the
    // library TUs and downstream code (the C wrapper) MUST agree, or the
    // resulting ABI mismatches at link time.
    const x86_defs = .{
        "JPH_USE_SSE4_1", "JPH_USE_SSE4_2", "JPH_USE_AVX",
        "JPH_USE_AVX2",   "JPH_USE_LZCNT",  "JPH_USE_TZCNT",
        "JPH_USE_F16C",   "JPH_USE_FMADD",
    };
    inline for (x86_defs) |d| mod.addCMacro(d, "");

    if (optimize == .Debug) mod.addCMacro("JPH_ENABLE_ASSERTS", "");

    const sources = try collectJoltSources(b);

    const cpp_flags: []const []const u8 = &.{
        "-std=c++17",
        "-mavx2", "-mbmi", "-mpopcnt", "-mlzcnt", "-mf16c", "-mfma",
        "-mfpmath=sse",
        "-pthread",
        // Vendored code; warnings here aren't actionable for us. Mirror
        // Jolt CMake's no-warnings stance for upstream `.cpp`s.
        "-w",
    };

    mod.addCSourceFiles(.{
        .root = b.path(jolt_root),
        .files = sources,
        .language = .cpp,
        .flags = cpp_flags,
    });

    // The C wrapper compiles into the same library so callers link a
    // single artifact and the wrapper sees identical Jolt defines.
    mod.addCSourceFile(.{
        .file = b.path("src/physics/jolt_c_api.cpp"),
        .language = .cpp,
        .flags = cpp_flags,
    });

    return b.addLibrary(.{
        .name = "Jolt",
        .root_module = mod,
        .linkage = .static,
    });
}

/// Walk `vendor/JoltPhysics/Jolt` and return every `.cpp` path relative to
/// that root. Jolt's CMake hand-lists files but every `.cpp` under that tree
/// is part of the library; globbing keeps build.zig from drifting when Jolt
/// adds files in a future bump.
fn collectJoltSources(b: *std.Build) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var dir = try std.fs.cwd().openDir(jolt_root ++ "/Jolt", .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(b.allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".cpp")) continue;
        const rel = try std.fmt.allocPrint(b.allocator, "Jolt/{s}", .{entry.path});
        try list.append(b.allocator, rel);
    }
    return list.toOwnedSlice(b.allocator);
}
