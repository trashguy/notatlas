const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    // Pin glibc_version on Linux hosts so Zig builds its bundled glibc
    // (incl. crt1.o) instead of pulling Arch's system Scrt1.o, whose
    // .sframe section currently trips Zig 0.15.2's bundled LLD on
    // linux-gnu native targets. Outside Linux hosts the field is
    // meaningless, so leave default_target empty and let standardTargetOptions
    // resolve to the host (or whatever -Dtarget the user passes).
    const default_target: std.Target.Query = if (builtin.os.tag == .linux)
        .{ .abi = .gnu, .glibc_version = .{ .major = 2, .minor = 38, .patch = 0 } }
    else
        .{};
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});

    const is_windows = target.result.os.tag == .windows;

    // Windows cross-compile: vulkan-1.lib import library lives under
    // libs/windows/. Fetched via `make setup-windows`.
    const vulkan_lib_path: ?std.Build.LazyPath = if (is_windows) b.path("libs/windows/vulkan/lib") else null;
    if (is_windows) {
        const lib_path = b.path("libs/windows/vulkan/lib/vulkan-1.lib").getPath(b);
        std.fs.cwd().access(lib_path, .{}) catch {
            std.log.err(
                \\
                \\=================================================================
                \\  Missing Windows Vulkan library!
                \\=================================================================
                \\
                \\  vulkan-1.lib not found at: libs/windows/vulkan/lib/
                \\
                \\  Run this to download it:
                \\    make setup-windows
                \\  or:
                \\    python3 scripts/fetch_windows_deps.py
                \\
                \\=================================================================
                \\
            , .{});
            std.process.exit(1);
        };
    }

    const ymlz_dep = b.dependency("ymlz", .{
        .target = target,
        .optimize = optimize,
    });
    const nats_dep = b.dependency("nats_zig", .{
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
    //
    // Jolt's intrinsics need SSE3+/AVX2 in the *codegen* target, not just in
    // -m flags. On native Linux, mcpu=native already covers it; for any
    // cross-compile (incl. x86_64-windows), -mcpu defaults to baseline (SSE2),
    // so we explicitly add the features Jolt's CMake assumes for the AVX2
    // configuration.
    const jolt_target = joltTarget(b, target);
    const jolt = buildJolt(b, jolt_target, optimize) catch @panic("jolt source enumeration failed");
    b.installArtifact(jolt);

    // Zig-side physics module: Jolt FFI + buoyancy. Buoyancy imports
    // notatlas math/wave_query, so the dependency edge goes that way.
    const physics_mod = b.addModule("physics", .{
        .root_source_file = b.path("src/physics/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    physics_mod.addImport("notatlas", notatlas_mod);

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
    if (is_windows) {
        if (vulkan_lib_path) |p| sandbox_mod.addLibraryPath(p);
        sandbox_mod.linkSystemLibrary("vulkan-1", .{});
    } else {
        // Pinned glibc makes Zig treat this as cross-compile; add system dirs
        // back so it can resolve libvulkan/libX11.
        sandbox_mod.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        sandbox_mod.linkSystemLibrary("vulkan", .{});
    }
    sandbox_mod.link_libc = true;

    // Compile GLSL → SPIR-V via system glslc and embed each blob into the
    // sandbox module as a named anonymous import. Code references them via
    // `@embedFile("ocean_vert_spv")` etc. M2.6 will replace this with a
    // runtime hot-reload subprocess.
    embedShader(b, sandbox_mod, "assets/shaders/fullscreen.vert", "fullscreen_vert_spv");
    embedShader(b, sandbox_mod, "assets/shaders/water.frag", "water_frag_spv");
    embedShader(b, sandbox_mod, "assets/shaders/box.vert", "box_vert_spv");
    embedShader(b, sandbox_mod, "assets/shaders/box.frag", "box_frag_spv");
    embedShader(b, sandbox_mod, "assets/shaders/wind_arrows.vert", "wind_arrows_vert_spv");
    embedShader(b, sandbox_mod, "assets/shaders/wind_arrows.frag", "wind_arrows_frag_spv");

    const sandbox = b.addExecutable(.{
        .name = "notatlas-sandbox",
        .root_module = sandbox_mod,
    });
    b.installArtifact(sandbox);

    const run_sandbox = b.addRunArtifact(sandbox);
    if (b.args) |args| run_sandbox.addArgs(args);
    const run_step = b.step("run", "Run the notatlas sandbox");
    run_step.dependOn(&run_sandbox.step);

    // ----- M6.3 services: cell-mgr + cell-mgr-harness -----
    //
    // Headless service binaries — no graphics deps. Both link the
    // notatlas library (for the replication module) and nats-zig.
    // Service binaries skip libc unless the underlying platform
    // demands it; nats-zig is std-only and works without it.
    const nats_mod = nats_dep.module("nats");

    const cell_mgr_mod = b.createModule(.{
        .root_source_file = b.path("src/services/cell_mgr/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cell_mgr_mod.addImport("notatlas", notatlas_mod);
    cell_mgr_mod.addImport("nats", nats_mod);
    const cell_mgr = b.addExecutable(.{
        .name = "cell-mgr",
        .root_module = cell_mgr_mod,
    });
    b.installArtifact(cell_mgr);

    const run_cell_mgr = b.addRunArtifact(cell_mgr);
    if (b.args) |args| run_cell_mgr.addArgs(args);
    const cell_mgr_step = b.step("cell-mgr", "Run the cell-mgr service");
    cell_mgr_step.dependOn(&run_cell_mgr.step);

    // The harness shares wire.zig with cell-mgr — register that file
    // as a named "wire" import so the harness can reach it without
    // climbing back into the cell-mgr/ tree on every import.
    const wire_mod = b.createModule(.{
        .root_source_file = b.path("src/services/cell_mgr/wire.zig"),
        .target = target,
        .optimize = optimize,
    });

    const harness_mod = b.createModule(.{
        .root_source_file = b.path("src/services/cell_mgr_harness/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    harness_mod.addImport("notatlas", notatlas_mod);
    harness_mod.addImport("nats", nats_mod);
    harness_mod.addImport("wire", wire_mod);
    const harness = b.addExecutable(.{
        .name = "cell-mgr-harness",
        .root_module = harness_mod,
    });
    b.installArtifact(harness);

    const run_harness = b.addRunArtifact(harness);
    if (b.args) |args| run_harness.addArgs(args);
    const harness_step = b.step("cell-mgr-harness", "Run the cell-mgr test harness");
    harness_step.dependOn(&run_harness.step);

    // cell-mgr unit tests (wire + state). Live outside the notatlas
    // module since they depend on the cell-mgr-only `wire` import.
    // Wired under the existing `test` step so `make test` covers them.
    const wire_test_mod = b.createModule(.{
        .root_source_file = b.path("src/services/cell_mgr/wire.zig"),
        .target = target,
        .optimize = optimize,
    });
    const wire_tests = b.addTest(.{ .root_module = wire_test_mod });
    test_step.dependOn(&b.addRunArtifact(wire_tests).step);

    const state_test_mod = b.createModule(.{
        .root_source_file = b.path("src/services/cell_mgr/state.zig"),
        .target = target,
        .optimize = optimize,
    });
    state_test_mod.addImport("notatlas", notatlas_mod);
    const state_tests = b.addTest(.{ .root_module = state_test_mod });
    test_step.dependOn(&b.addRunArtifact(state_tests).step);

    const fanout_test_mod = b.createModule(.{
        .root_source_file = b.path("src/services/cell_mgr/fanout.zig"),
        .target = target,
        .optimize = optimize,
    });
    fanout_test_mod.addImport("notatlas", notatlas_mod);
    const fanout_tests = b.addTest(.{ .root_module = fanout_test_mod });
    test_step.dependOn(&b.addRunArtifact(fanout_tests).step);

    // ----- ship-sim service (Phase 1, docs/08 §2A) -----
    //
    // Owns 60 Hz rigid-body authority for ships AND free-agent
    // players. Skeleton in this commit; subsequent sub-steps add
    // Jolt-driven ship state, multi-ship, board/disembark, and
    // free-agent player physics.
    const ship_sim_mod = b.createModule(.{
        .root_source_file = b.path("src/services/ship_sim/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    ship_sim_mod.addImport("notatlas", notatlas_mod);
    ship_sim_mod.addImport("nats", nats_mod);
    const ship_sim = b.addExecutable(.{
        .name = "ship-sim",
        .root_module = ship_sim_mod,
    });
    b.installArtifact(ship_sim);

    const run_ship_sim = b.addRunArtifact(ship_sim);
    if (b.args) |args| run_ship_sim.addArgs(args);
    const ship_sim_step = b.step("ship-sim", "Run the ship-sim service");
    ship_sim_step.dependOn(&run_ship_sim.step);

    const ship_sim_state_test_mod = b.createModule(.{
        .root_source_file = b.path("src/services/ship_sim/state.zig"),
        .target = target,
        .optimize = optimize,
    });
    ship_sim_state_test_mod.addImport("notatlas", notatlas_mod);
    const ship_sim_state_tests = b.addTest(.{ .root_module = ship_sim_state_test_mod });
    test_step.dependOn(&b.addRunArtifact(ship_sim_state_tests).step);
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

/// Return a target identical to `base` but with x86 SIMD features (SSE3
/// through AVX2 + BMI/LZCNT/POPCNT/F16C/FMA) explicitly enabled. Required
/// when `base` resolves to `mcpu=baseline` (any non-native target), since
/// Jolt's intrinsics won't compile against SSE2-only.
fn joltTarget(b: *std.Build, base: std.Build.ResolvedTarget) std.Build.ResolvedTarget {
    if (base.result.cpu.arch != .x86_64) return base;
    var query = base.query;
    const Feature = std.Target.x86.Feature;
    const features = [_]Feature{
        .sse3,  .ssse3,  .sse4_1, .sse4_2,
        .avx,   .avx2,   .bmi,    .bmi2,
        .lzcnt, .popcnt, .f16c,   .fma,
    };
    for (features) |f| query.cpu_features_add.addFeature(@intFromEnum(f));
    return b.resolveTargetQuery(query);
}

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
        "-mavx2",
        "-mbmi",
        "-mpopcnt",
        "-mlzcnt",
        "-mf16c",
        "-mfma",
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
