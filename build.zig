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
    const pg_dep = b.dependency("pg", .{
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

    // VMA module needs to be defined before any test mod that
    // transitively imports buffer.zig (cluster_merge_test_mod,
    // cluster_merge_worker_test_mod). The full VMA + libktx setup
    // stays grouped lower; this is just the module definition.
    const vma_lib = buildVMA(b, target, optimize);
    const vma_mod = b.addModule("vma", .{
        .root_source_file = b.path("src/render/vma.zig"),
        .target = target,
        .optimize = optimize,
    });
    vma_mod.addIncludePath(vulkan_include);
    vma_mod.addIncludePath(b.path("vendor/VulkanMemoryAllocator/include"));
    vma_mod.linkLibrary(vma_lib);
    if (is_windows) {
        if (vulkan_lib_path) |p| vma_mod.addLibraryPath(p);
        vma_mod.linkSystemLibrary("vulkan-1", .{});
    } else {
        vma_mod.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        vma_mod.linkSystemLibrary("vulkan", .{});
    }
    vma_mod.link_libcpp = true;
    vma_mod.link_libc = true;

    // M11.1 cluster_merge has a pure-CPU bake (mergeCluster /
    // measureCluster) covered by unit tests. Lives in src/render/ which
    // notatlas_mod doesn't see; needs notatlas math + Vulkan headers
    // (header references only — no link). The MergedMeshRenderer init
    // path is gated behind @embedFile-in-init so test compilation works
    // without the sandbox's SPV anonymous imports.
    const cluster_merge_test_mod = b.createModule(.{
        .root_source_file = b.path("src/render/cluster_merge.zig"),
        .target = target,
        .optimize = optimize,
    });
    cluster_merge_test_mod.addImport("notatlas", notatlas_mod);
    cluster_merge_test_mod.addImport("vma", vma_mod);
    cluster_merge_test_mod.addIncludePath(vulkan_include);
    const cluster_merge_tests = b.addTest(.{ .root_module = cluster_merge_test_mod });
    test_step.dependOn(&b.addRunArtifact(cluster_merge_tests).step);

    // M11.3 cluster_merge_worker. Worker spawn/enqueue/drain has a
    // synthetic merge job round-trip test that exercises the producer
    // /consumer pattern end-to-end. Same dependency shape as the
    // cluster_merge test target (notatlas math + Vulkan headers for
    // the cluster_merge import chain).
    const cluster_merge_worker_test_mod = b.createModule(.{
        .root_source_file = b.path("src/render/cluster_merge_worker.zig"),
        .target = target,
        .optimize = optimize,
    });
    cluster_merge_worker_test_mod.addImport("notatlas", notatlas_mod);
    cluster_merge_worker_test_mod.addImport("vma", vma_mod);
    cluster_merge_worker_test_mod.addIncludePath(vulkan_include);
    const cluster_merge_worker_tests = b.addTest(.{ .root_module = cluster_merge_worker_test_mod });
    test_step.dependOn(&b.addRunArtifact(cluster_merge_worker_tests).step);

    // M13 glTF parser. Lives in src/render/ alongside box.zig + mesh_palette.zig
    // (Vertex / PieceMesh types come from those). Same dependency shape as the
    // cluster_merge tests: notatlas math + Vulkan headers for the import chain,
    // no link needed.
    const gltf_test_mod = b.createModule(.{
        .root_source_file = b.path("src/render/gltf.zig"),
        .target = target,
        .optimize = optimize,
    });
    gltf_test_mod.addImport("notatlas", notatlas_mod);
    gltf_test_mod.addIncludePath(vulkan_include);
    const gltf_tests = b.addTest(.{ .root_module = gltf_test_mod });
    test_step.dependOn(&b.addRunArtifact(gltf_tests).step);

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

    // Lua 5.4 — vendored at vendor/lua (5.4.8). Built as a static C lib
    // from the 33 library .c files under vendor/lua/src/ (lua.c and
    // luac.c are CLI mains, intentionally excluded). See
    // vendor/lua/PROVENANCE.md and docs/09-ai-sim.md §13 q3 for the
    // VM-choice rationale.
    const lua = buildLua(b, target, optimize) catch @panic("lua source enumeration failed");
    b.installArtifact(lua);

    // libktx — vendored at vendor/KTX-Software (v4.4.2). Build via the
    // upstream CMake (1645-line, with sub-deps on basisu / dfdutils /
    // etcdec) — mirroring it into build.zig the way Jolt does is
    // multi-day infrastructure. M14 vintage targets `ktx_read`: read +
    // transcode, no Basis encoder. See `feedback_thin_c_bindings.md`:
    // we still bind against libktx's own C surface in our tree
    // (src/render/ktx_c.zig), the build is just delegated.
    //
    // Requires `cmake` on PATH. Output dir is Zig-managed via
    // addPrefixedOutputDirectoryArg, so the .a survives across zig
    // builds and reruns on argv changes.
    const ktx_artifacts = buildKTX(b, target);

    const ktx_mod = b.addModule("ktx", .{
        .root_source_file = b.path("src/render/ktx_c.zig"),
        .target = target,
        .optimize = optimize,
    });
    ktx_mod.addIncludePath(ktx_artifacts.include_path);
    ktx_mod.addObjectFile(ktx_artifacts.lib_path);
    // basisu transcoder + etcdec are C++; libktx headers themselves are C.
    ktx_mod.link_libcpp = true;
    ktx_mod.link_libc = true;

    // M14.1 smoke binary: open a KTX2 file, print its metadata, exit.
    // Proves the libktx vendoring + thin C binding round-trip without
    // any Vulkan/render integration. M14.2 wires the actual sampling
    // pipeline; this binary stays as the lowest-level libktx smoke.
    const m14_dump_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/m14_ktx_dump/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    m14_dump_mod.addImport("ktx", ktx_mod);
    const m14_dump = b.addExecutable(.{
        .name = "m14-ktx-dump",
        .root_module = m14_dump_mod,
    });
    b.installArtifact(m14_dump);

    // ktx_c.zig has a tiny round-trip test (CreateFromMemory on a
    // hand-built minimal KTX2 byte stream + Destroy) so an upstream
    // C-API drift surfaces under `make test`.
    const ktx_test_mod = b.createModule(.{
        .root_source_file = b.path("src/render/ktx_c.zig"),
        .target = target,
        .optimize = optimize,
    });
    ktx_test_mod.addIncludePath(ktx_artifacts.include_path);
    ktx_test_mod.addObjectFile(ktx_artifacts.lib_path);
    ktx_test_mod.link_libcpp = true;
    ktx_test_mod.link_libc = true;
    const ktx_tests = b.addTest(.{ .root_module = ktx_test_mod });
    test_step.dependOn(&b.addRunArtifact(ktx_tests).step);

    // Shared module: thin C binding (lua_c.zig) + comptime marshaling
    // (lua_bind.zig, ported from fallen-runes onto our own thin layer).
    // Anyone embedding Lua imports `lua` and links the `lua` artifact.
    const lua_mod = b.addModule("lua", .{
        .root_source_file = b.path("src/shared/lua/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lua_mod.addIncludePath(b.path("vendor/lua/src"));
    lua_mod.linkLibrary(lua);
    lua_mod.link_libc = true;

    // Lua binding tests. Cover the thin-C surface we use; a future
    // upstream bump that changes a C API signature trips these.
    const lua_test_mod = b.createModule(.{
        .root_source_file = b.path("src/shared/lua/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lua_test_mod.addIncludePath(b.path("vendor/lua/src"));
    lua_test_mod.linkLibrary(lua);
    lua_test_mod.link_libc = true;
    const lua_tests = b.addTest(.{ .root_module = lua_test_mod });
    test_step.dependOn(&b.addRunArtifact(lua_tests).step);

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
    sandbox_mod.addImport("vma", vma_mod);
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
    embedShader(b, sandbox_mod, "assets/shaders/instanced.vert", "instanced_vert_spv");
    embedShader(b, sandbox_mod, "assets/shaders/instanced.frag", "instanced_frag_spv");
    embedShader(b, sandbox_mod, "assets/shaders/instanced_cull.comp", "instanced_cull_comp_spv");
    embedShader(b, sandbox_mod, "assets/shaders/merged.vert", "merged_vert_spv");
    embedShader(b, sandbox_mod, "assets/shaders/merged.frag", "merged_frag_spv");
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
    ship_sim_mod.addImport("physics", physics_mod);
    // Share the cell-mgr wire types — `sim.entity.<id>.state` is a
    // contract between ship-sim (producer) and cell-mgr (consumer);
    // both must agree on the JSON shape. cell_mgr/wire.zig is the
    // canonical home until a `src/shared/wire.zig` refactor lifts
    // these out of the consumer-side tree.
    ship_sim_mod.addImport("wire", wire_mod);
    ship_sim_mod.linkLibrary(jolt);
    ship_sim_mod.link_libc = true;
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
    ship_sim_state_test_mod.addImport("physics", physics_mod);
    ship_sim_state_test_mod.linkLibrary(jolt);
    ship_sim_state_test_mod.link_libc = true;
    const ship_sim_state_tests = b.addTest(.{ .root_module = ship_sim_state_test_mod });
    test_step.dependOn(&b.addRunArtifact(ship_sim_state_tests).step);

    // ----- gateway service (Phase 1, docs/08 §1.2) -----
    //
    // Stateless TCP↔NATS relay. Skeleton subscribes to one
    // hardcoded client's `gw.client.<id>.cmd` and decodes the
    // batched payload header — TCP listener + framing comes in
    // subsequent sub-steps.
    const gateway_mod = b.createModule(.{
        .root_source_file = b.path("src/services/gateway/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    gateway_mod.addImport("notatlas", notatlas_mod);
    gateway_mod.addImport("nats", nats_mod);
    gateway_mod.addImport("wire", wire_mod);
    const gateway = b.addExecutable(.{
        .name = "gateway",
        .root_module = gateway_mod,
    });
    b.installArtifact(gateway);

    const run_gateway = b.addRunArtifact(gateway);
    if (b.args) |args| run_gateway.addArgs(args);
    const gateway_step = b.step("gateway", "Run the gateway service");
    gateway_step.dependOn(&run_gateway.step);

    const gateway_test_mod = b.createModule(.{
        .root_source_file = b.path("src/services/gateway/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    gateway_test_mod.addImport("notatlas", notatlas_mod);
    gateway_test_mod.addImport("nats", nats_mod);
    const gateway_tests = b.addTest(.{ .root_module = gateway_test_mod });
    test_step.dependOn(&b.addRunArtifact(gateway_tests).step);

    // ----- spatial-index service (Phase 2, docs/02 §1.4 / docs/08 §7.1) -----
    //
    // Global entity → cell membership oracle. Subscribes to the
    // sim.entity.*.state firehose, emits idx.spatial.cell.<x>_<z>.delta
    // events on cell transitions. cell-mgr is the consumer.
    const spatial_index_mod = b.createModule(.{
        .root_source_file = b.path("src/services/spatial_index/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    spatial_index_mod.addImport("notatlas", notatlas_mod);
    spatial_index_mod.addImport("nats", nats_mod);
    spatial_index_mod.addImport("wire", wire_mod);
    const spatial_index = b.addExecutable(.{
        .name = "spatial-index",
        .root_module = spatial_index_mod,
    });
    b.installArtifact(spatial_index);

    const run_spatial_index = b.addRunArtifact(spatial_index);
    if (b.args) |args| run_spatial_index.addArgs(args);
    const spatial_index_step = b.step("spatial-index", "Run the spatial-index service");
    spatial_index_step.dependOn(&run_spatial_index.step);

    const spatial_index_state_test_mod = b.createModule(.{
        .root_source_file = b.path("src/services/spatial_index/state.zig"),
        .target = target,
        .optimize = optimize,
    });
    const spatial_index_state_tests = b.addTest(.{ .root_module = spatial_index_state_test_mod });
    test_step.dependOn(&b.addRunArtifact(spatial_index_state_tests).step);

    const spatial_index_leader_test_mod = b.createModule(.{
        .root_source_file = b.path("src/services/spatial_index/leader.zig"),
        .target = target,
        .optimize = optimize,
    });
    spatial_index_leader_test_mod.addImport("nats", nats_mod);
    const spatial_index_leader_tests = b.addTest(.{ .root_module = spatial_index_leader_test_mod });
    test_step.dependOn(&b.addRunArtifact(spatial_index_leader_tests).step);

    // ----- ai-sim service (Phase 1 combat slice, docs/09-ai-sim.md) -----
    //
    // 20 Hz AI decision loop. Subscribes to sim.entity.*.state for
    // world snapshots; publishes sim.entity.<ai_id>.input
    // indistinguishable from gateway's player input. ship-sim
    // consumes both via the same `sim.entity.*.input` wildcard.
    // Pulls in `lua` (vendored 5.4) for behavior-tree leaf dispatch
    // and `notatlas.bt` / `notatlas.bt_loader` for the BT runtime.
    const ai_sim_mod = b.createModule(.{
        .root_source_file = b.path("src/services/ai_sim/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    ai_sim_mod.addImport("notatlas", notatlas_mod);
    ai_sim_mod.addImport("nats", nats_mod);
    ai_sim_mod.addImport("wire", wire_mod);
    ai_sim_mod.addImport("lua", lua_mod);
    ai_sim_mod.linkLibrary(lua);
    ai_sim_mod.link_libc = true;
    const ai_sim = b.addExecutable(.{
        .name = "ai-sim",
        .root_module = ai_sim_mod,
    });
    b.installArtifact(ai_sim);

    const run_ai_sim = b.addRunArtifact(ai_sim);
    if (b.args) |args| run_ai_sim.addArgs(args);
    const ai_sim_step = b.step("ai-sim", "Run the ai-sim service");
    ai_sim_step.dependOn(&run_ai_sim.step);

    const ai_sim_state_test_mod = b.createModule(.{
        .root_source_file = b.path("src/services/ai_sim/state.zig"),
        .target = target,
        .optimize = optimize,
    });
    ai_sim_state_test_mod.addImport("notatlas", notatlas_mod);
    ai_sim_state_test_mod.addImport("wire", wire_mod);
    const ai_sim_state_tests = b.addTest(.{ .root_module = ai_sim_state_test_mod });
    test_step.dependOn(&b.addRunArtifact(ai_sim_state_tests).step);

    const ai_sim_dispatcher_test_mod = b.createModule(.{
        .root_source_file = b.path("src/services/ai_sim/dispatcher.zig"),
        .target = target,
        .optimize = optimize,
    });
    ai_sim_dispatcher_test_mod.addImport("notatlas", notatlas_mod);
    ai_sim_dispatcher_test_mod.addImport("lua", lua_mod);
    ai_sim_dispatcher_test_mod.addImport("wire", wire_mod);
    ai_sim_dispatcher_test_mod.linkLibrary(lua);
    ai_sim_dispatcher_test_mod.link_libc = true;
    const ai_sim_dispatcher_tests = b.addTest(.{ .root_module = ai_sim_dispatcher_test_mod });
    test_step.dependOn(&b.addRunArtifact(ai_sim_dispatcher_tests).step);

    const ai_sim_perception_test_mod = b.createModule(.{
        .root_source_file = b.path("src/services/ai_sim/perception.zig"),
        .target = target,
        .optimize = optimize,
    });
    ai_sim_perception_test_mod.addImport("notatlas", notatlas_mod);
    ai_sim_perception_test_mod.addImport("wire", wire_mod);
    const ai_sim_perception_tests = b.addTest(.{ .root_module = ai_sim_perception_test_mod });
    test_step.dependOn(&b.addRunArtifact(ai_sim_perception_tests).step);

    // ----- env-sim service (Phase 2, docs/02 §5) -----
    //
    // Per-cell environmental sampling at 5 Hz. v0 publishes wind only
    // (waves / tide / time-of-day to follow). Loads `data/wind.yaml`
    // and samples `notatlas.wind_query.windAt` at each cell center.
    const env_sim_mod = b.createModule(.{
        .root_source_file = b.path("src/services/env_sim/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    env_sim_mod.addImport("notatlas", notatlas_mod);
    env_sim_mod.addImport("nats", nats_mod);
    env_sim_mod.addImport("wire", wire_mod);
    const env_sim = b.addExecutable(.{
        .name = "env-sim",
        .root_module = env_sim_mod,
    });
    b.installArtifact(env_sim);

    const run_env_sim = b.addRunArtifact(env_sim);
    if (b.args) |args| run_env_sim.addArgs(args);
    const env_sim_step = b.step("env-sim", "Run the env-sim service");
    env_sim_step.dependOn(&run_env_sim.step);

    // ----- persistence-writer service (Phase 2, docs/02 §5) -----
    //
    // Sole Postgres writer per locked architecture decision 5.
    // Consumes JetStream change streams (workqueue retention) and
    // batches them into PG. v0 skeleton: NATS connect + PG connect +
    // current-cycle probe + idle loop. Streams attach in follow-up
    // commits. PG client is karlseguin/pg.zig zig-0.15 branch (see
    // memory architecture_pg_client_pgzig.md).
    const pg_mod = pg_dep.module("pg");
    const persistence_writer_mod = b.createModule(.{
        .root_source_file = b.path("src/services/persistence_writer/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    persistence_writer_mod.addImport("nats", nats_mod);
    persistence_writer_mod.addImport("pg", pg_mod);
    persistence_writer_mod.addImport("wire", wire_mod);
    const persistence_writer = b.addExecutable(.{
        .name = "persistence-writer",
        .root_module = persistence_writer_mod,
    });
    b.installArtifact(persistence_writer);

    const run_persistence_writer = b.addRunArtifact(persistence_writer);
    if (b.args) |args| run_persistence_writer.addArgs(args);
    const persistence_writer_step = b.step("persistence-writer", "Run the persistence-writer service");
    persistence_writer_step.dependOn(&run_persistence_writer.step);

    // ----- market-sim service (Phase 2, docs/02 §201 / init.sql §161) -----
    //
    // Geo-scoped order matching. v0: single process, in-memory order
    // books per (cell_x, cell_y, item_def_id); subscribes to
    // `market.order.submit`; publishes `events.market.trade` on match.
    // pwriter consumes the trade stream into `market_trades` PG.
    const market_sim_mod = b.createModule(.{
        .root_source_file = b.path("src/services/market_sim/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    market_sim_mod.addImport("nats", nats_mod);
    market_sim_mod.addImport("wire", wire_mod);
    const market_sim = b.addExecutable(.{
        .name = "market-sim",
        .root_module = market_sim_mod,
    });
    b.installArtifact(market_sim);

    const run_market_sim = b.addRunArtifact(market_sim);
    if (b.args) |args| run_market_sim.addArgs(args);
    const market_sim_step = b.step("market-sim", "Run the market-sim service");
    market_sim_step.dependOn(&run_market_sim.step);

    // Unit tests for the in-memory matcher live in main.zig (small
    // enough; if it grows, extract to book.zig). Same import set as
    // the binary.
    const market_sim_test_mod = b.createModule(.{
        .root_source_file = b.path("src/services/market_sim/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    market_sim_test_mod.addImport("nats", nats_mod);
    market_sim_test_mod.addImport("wire", wire_mod);
    const market_sim_tests = b.addTest(.{ .root_module = market_sim_test_mod });
    test_step.dependOn(&b.addRunArtifact(market_sim_tests).step);

    // ----- inventory-sim service (Phase 2, init.sql §108) -----
    //
    // Authoritative in-memory inventory blob per character. v0: NATS
    // sub `inv.mutate` (batched), 100 ms flush tick emits one
    // `events.inventory.change.<char>` per dirty character with the
    // full `{slots:[...]}` blob. Closes the 4th SLA-arc producer.
    const inventory_sim_mod = b.createModule(.{
        .root_source_file = b.path("src/services/inventory_sim/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    inventory_sim_mod.addImport("nats", nats_mod);
    inventory_sim_mod.addImport("pg", pg_mod);
    inventory_sim_mod.addImport("wire", wire_mod);
    const inventory_sim = b.addExecutable(.{
        .name = "inventory-sim",
        .root_module = inventory_sim_mod,
    });
    b.installArtifact(inventory_sim);

    const run_inventory_sim = b.addRunArtifact(inventory_sim);
    if (b.args) |args| run_inventory_sim.addArgs(args);
    const inventory_sim_step = b.step("inventory-sim", "Run the inventory-sim service");
    inventory_sim_step.dependOn(&run_inventory_sim.step);

    const inventory_sim_test_mod = b.createModule(.{
        .root_source_file = b.path("src/services/inventory_sim/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    inventory_sim_test_mod.addImport("nats", nats_mod);
    inventory_sim_test_mod.addImport("pg", pg_mod);
    inventory_sim_test_mod.addImport("wire", wire_mod);
    const inventory_sim_tests = b.addTest(.{ .root_module = inventory_sim_test_mod });
    test_step.dependOn(&b.addRunArtifact(inventory_sim_tests).step);
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

const lua_root = "vendor/lua";

/// Build PUC Lua 5.4 as a static C library. Compiles the 33 library .c
/// files under `vendor/lua/src/`, excluding the two CLI mains (`lua.c`
/// for the standalone interpreter and `luac.c` for the bytecode
/// compiler) — notatlas embeds Lua, not the host program.
///
/// Linux: defines `LUA_USE_LINUX` (POSIX + dlopen, the standard
/// upstream Linux config minus readline since we don't ship a REPL).
/// Windows: no defines needed; Lua's default config works.
fn buildLua(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(b.path(lua_root ++ "/src"));

    if (target.result.os.tag == .linux) {
        mod.addCMacro("LUA_USE_LINUX", "");
    }

    const sources = try collectLuaSources(b);

    const c_flags: []const []const u8 = &.{
        "-std=c99",
        // Vendored upstream code; warnings here aren't actionable for
        // us. Mirror Jolt's no-warnings stance.
        "-w",
    };

    mod.addCSourceFiles(.{
        .root = b.path(lua_root),
        .files = sources,
        .language = .c,
        .flags = c_flags,
    });

    return b.addLibrary(.{
        .name = "lua",
        .root_module = mod,
        .linkage = .static,
    });
}

/// Walk `vendor/lua/src` and return every `.c` path relative to
/// `vendor/lua/` except the two CLI mains. Globbing keeps build.zig
/// from drifting on a 5.4.x bump.
fn collectLuaSources(b: *std.Build) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var dir = try std.fs.cwd().openDir(lua_root ++ "/src", .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".c")) continue;
        // CLI mains — excluded; we embed Lua as a library.
        if (std.mem.eql(u8, entry.name, "lua.c")) continue;
        if (std.mem.eql(u8, entry.name, "luac.c")) continue;
        const rel = try std.fmt.allocPrint(b.allocator, "src/{s}", .{entry.name});
        try list.append(b.allocator, rel);
    }
    return list.toOwnedSlice(b.allocator);
}

const vma_root = "vendor/VulkanMemoryAllocator";

/// Build VMA as a static C++ library from our single-TU wrapper
/// (src/render/vma_impl.cpp). VMA is single-header — vk_mem_alloc.h
/// IS the library; including it once with VMA_IMPLEMENTATION defined
/// emits the symbols. No CMake-from-zig needed.
///
/// Function-pointer dispatch: we set VMA_STATIC_VULKAN_FUNCTIONS=1 in
/// vma_impl.cpp, so VMA finds vk* symbols at link time (we statically
/// link libvulkan / vulkan-1.lib already). No runtime
/// vkGetInstanceProcAddr indirection.
fn buildVMA(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
    });
    mod.addIncludePath(b.path(vma_root ++ "/include"));
    // VMA's header transitively includes <vulkan/vulkan.h>; we use
    // the same vendored Khronos headers as the rest of the renderer.
    const vk_dep = b.dependency("vulkan-headers", .{});
    mod.addIncludePath(vk_dep.path("include"));

    mod.addCSourceFile(.{
        .file = b.path("src/render/vma_impl.cpp"),
        .language = .cpp,
        .flags = &.{
            "-std=c++17",
            // VMA's header issues many implicit-cast / unused-param
            // warnings under -Wall; mirror the upstream build's silence.
            "-w",
        },
    });

    return b.addLibrary(.{
        .name = "vma",
        .root_module = mod,
        .linkage = .static,
    });
}

const ktx_root = "vendor/KTX-Software";

const KtxArtifacts = struct {
    /// Path to libktx_read.a — the read + transcode subset (no Basis encoder).
    lib_path: std.Build.LazyPath,
    /// Path to KTX-Software/include — exposes ktx.h and (when enabled later)
    /// ktxvulkan.h. M14.1 only uses the core ktx.h surface.
    include_path: std.Build.LazyPath,
};

/// Configure + build libktx via upstream's CMake, wrapped as one
/// `sh -c` Run step. Two reasons not to use separate configure/build
/// Run steps:
///   1. Zig's LazyPath dependency edge follows the producing step.
///      A subpath of configure's output dir doesn't carry a dep on
///      build_cmd, so consumers wouldn't wait for the .a to exist.
///   2. cmake's own incremental tracking handles re-runs cheaply
///      inside the same build dir; no benefit to splitting.
///
/// Feature flags disable everything not needed for runtime read +
/// transcode: tools, tests, GL/Vulkan upload helpers, doc, JNI,
/// Python bindings, loadtest apps. Built target is `ktx_read` (~2.5 MB
/// .a vs 3.8 MB for the writer-included `ktx`).
///
/// KTX1 must stay ON: lib/texture.c's dispatcher unconditionally
/// references `ktxTexture1_constructFromStreamAndHeader`, so disabling
/// KTX1 leaves an unresolved symbol at link time. We don't use KTX1
/// at runtime, but the symbol has to exist.
fn buildKTX(b: *std.Build, target: std.Build.ResolvedTarget) KtxArtifacts {
    _ = target; // Configured for host until M14 needs cross-compile.

    const cmake_run = b.addSystemCommand(&.{ "sh", "-c" });
    // Inline shell wrapper. $0=script-name (sh convention),
    // $1=ktx_root, $2=build_dir, $3=published_lib_path.
    cmake_run.addArg(
        \\set -e
        \\KTX_SRC="$1"
        \\BUILD_DIR="$2"
        \\LIB_OUT="$3"
        \\cmake -S "$KTX_SRC" -B "$BUILD_DIR" \
        \\  -DCMAKE_BUILD_TYPE=Release \
        \\  -DBUILD_SHARED_LIBS=OFF \
        \\  -DKTX_FEATURE_DOC=OFF \
        \\  -DKTX_FEATURE_JNI=OFF \
        \\  -DKTX_FEATURE_PY=OFF \
        \\  -DKTX_FEATURE_TESTS=OFF \
        \\  -DKTX_FEATURE_TOOLS=OFF \
        \\  -DKTX_FEATURE_TOOLS_CTS=OFF \
        \\  -DKTX_FEATURE_LOADTEST_APPS=OFF \
        \\  -DKTX_FEATURE_GL_UPLOAD=OFF \
        \\  -DKTX_FEATURE_VK_UPLOAD=OFF \
        \\  -DKTX_FEATURE_KTX1=ON \
        \\  -DKTX_FEATURE_KTX2=ON \
        \\  -DKTX_FEATURE_ETC_UNPACK=ON >/dev/null
        \\cmake --build "$BUILD_DIR" --target ktx_read --parallel
        \\cp -f "$BUILD_DIR/libktx_read.a" "$LIB_OUT"
    );
    cmake_run.addArg("buildKTX"); // $0 — name reported in shell errors.
    cmake_run.addArg(b.path(ktx_root).getPath(b)); // $1
    _ = cmake_run.addOutputDirectoryArg("ktx-build"); // $2 — cmake's own dir.
    const lib_path = cmake_run.addOutputFileArg("libktx_read.a"); // $3

    return .{
        .lib_path = lib_path,
        .include_path = b.path(ktx_root ++ "/include"),
    };
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
