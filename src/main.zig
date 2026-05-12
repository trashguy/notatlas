//! notatlas sandbox entry point. M2 raymarched water + atmospheric sky.
//! `data/waves/storm.yaml` drives the deterministic wave kernel;
//! `data/ocean.yaml` drives shading/foam/fog. Single-process; no networking.
//!
//! M2.6: data and shader files are watched live. Editing
//! `data/ocean.yaml`, `data/waves/storm.yaml`, or any shader under
//! `assets/shaders/` reloads the relevant resource without restarting.

const std = @import("std");
const notatlas = @import("notatlas");
const render = @import("render/render.zig");
const physics = @import("physics");
const zglfw = @import("zglfw");

const wave_config_path = "data/waves/storm.yaml";
const ocean_config_path = "data/ocean.yaml";
const hull_config_path = "data/ships/box.yaml";
const wind_config_path = "data/wind.yaml";
const arrows_vert_path = "assets/shaders/wind_arrows.vert";
const arrows_frag_path = "assets/shaders/wind_arrows.frag";

/// 16×16 = 256 cells over 800 m centered at origin. Step (50 m) is large
/// enough that arrows of length ARROW_SCALE_M (35 m) don't overlap, small
/// enough that storm gradients (σ=300 m for the storm preset) span ~6 cells.
const arrow_grid_dim: u32 = 16;
const arrow_grid_step_m: f32 = 50.0;
const arrow_count: u32 = arrow_grid_dim * arrow_grid_dim;
const vert_shader_path = "assets/shaders/fullscreen.vert";
const frag_shader_path = "assets/shaders/water.frag";
const instanced_vert_shader_path = "assets/shaders/instanced.vert";
const instanced_frag_shader_path = "assets/shaders/instanced.frag";
const merged_vert_shader_path = "assets/shaders/merged.vert";
const merged_frag_shader_path = "assets/shaders/merged.frag";

/// Passenger count for the M5.5 multi-pax demo. Three NPCs scattered on
/// the deck at fixed local poses with distinct colors. Every frame their
/// world models are composed from the interpolated ship pose so they stick
/// to the deck through pitches/rolls — the same SoT-style composition the
/// player camera uses, but rendered as actual visible bodies.
const npc_pax_count: u32 = 3;
const pax_total_count: u32 = 1 + npc_pax_count;

const Scene = struct {
    ocean: *render.Ocean,
    /// M10.1: GPU-driven instancing path. Ship + passengers all live as
    /// slots in one SSBO and render in a single drawIndexed (one piece
    /// type for now). main.zig calls `updateTransform(id, ...)` each frame
    /// from the interpolated ship pose; albedos are written once at init.
    instanced: *render.Instanced,
    arrows: *render.WindArrows,
    /// M11.1: merged-mesh renderer for far-LOD anchorages. Always init'd;
    /// per-frame only records draws if an anchorage is in far-LOD.
    merged_renderer: *render.MergedMeshRenderer,
    /// M11.2: optional anchorage. null when `--anchorage-pieces` is 0.
    /// Per-frame `selectLod()` toggles between instanced (near) and
    /// merged (far) rendering paths.
    anchorage: ?*render.cluster_merge.Anchorage = null,
    /// M10.3: per-frame view-projection used by the GPU cull pass.
    /// Populated in the main loop right after `ocean.updateCamera`; read
    /// by prePass to upload frustum planes for the compute dispatch.
    view_proj: notatlas.math.Mat4 = notatlas.math.Mat4.identity,
};

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const cli = try parseCli(gpa);

    // RenderDoc must be loaded BEFORE the Vulkan instance is created so its
    // layer can hook the loader. Frame capture happens later, after a brief
    // warmup, so the captured frame is in steady state.
    var capture: ?render.capture.Capture = null;
    defer if (capture) |*c| c.deinit();
    if (cli.capture) {
        try std.fs.cwd().makePath("captures");
        capture = render.capture.Capture.init("captures/notatlas") catch |err| blk: {
            std.log.err("renderdoc init: {s} (continuing without capture)", .{@errorName(err)});
            break :blk null;
        };
    }

    var window = try render.Window.init(.{ .force_x11 = cli.capture });
    defer window.deinit();

    var gpu = try render.GpuContext.init(gpa, &window, .{});
    defer gpu.deinit();
    gpu.printCapabilities();

    // MAILBOX keeps the CPU/GPU loop unthrottled by display refresh
    // while still presenting tearing-free — the right "uncapped" mode
    // on Wayland, which never advertises IMMEDIATE.
    var swapchain = try render.Swapchain.init(gpa, &gpu, window.framebufferSize(), .{
        .present_mode = if (cli.uncap)
            render.types.vk.VK_PRESENT_MODE_MAILBOX_KHR
        else
            render.types.vk.VK_PRESENT_MODE_FIFO_KHR,
    });
    defer swapchain.deinit();

    var frame = try render.Frame.init(gpa, &gpu, &swapchain);
    defer frame.deinit();

    var ocean = try render.Ocean.init(gpa, &gpu, frame.render_pass, .{});
    defer ocean.deinit();

    // M10.1: single-piece palette (the same ±0.5 cube `Box` used). Ship +
    // passengers feed instance rows; one drawIndexed covers them all.
    // M10.4: `--piece-types K` replicates the same cube mesh K times so
    // each gets a distinct PieceEntry (and therefore a distinct
    // indirect-command bucket). Geometry is identical; the gate measures
    // bookkeeping, not mesh variety.
    const palette_pieces = try gpa.alloc(render.mesh_palette.PieceMesh, cli.piece_types);
    defer gpa.free(palette_pieces);
    for (palette_pieces) |*p| {
        p.* = .{
            .vertices = &render.box.cube_vertices,
            .indices = &render.box.cube_indices,
            // ±0.5 unit cube → smallest enclosing sphere radius = √3/2.
            .bounds_center = .{ 0, 0, 0 },
            .bounds_radius = 0.8660254,
        };
    }
    var palette = try render.MeshPalette.init(gpa, &gpu, palette_pieces);
    defer palette.deinit();

    // Reserve slots for ship + passengers + the optional NxN stress grid
    // + the optional M11.2 anchorage (which only consumes Instanced slots
    // when in near-LOD; reserved up-front to avoid allocator churn on
    // every LOD transition). The SSBO sizes for the high-water mark
    // either way.
    const grid_slot_count: u32 = cli.instance_grid * cli.instance_grid;
    var instanced = try render.Instanced.init(
        gpa,
        &gpu,
        frame.render_pass,
        ocean.camera_ubo.handle,
        &palette,
        pax_total_count + grid_slot_count + cli.anchorage_pieces,
    );
    defer instanced.deinit();
    instanced.setCullEnabled(!cli.no_cull);
    std.log.info("M10.3 GPU cull: {s}", .{if (cli.no_cull) "OFF (--no-cull)" else "ON"});

    var arrows = try render.WindArrows.init(&gpu, frame.render_pass, ocean.camera_ubo.handle, arrow_count);
    defer arrows.deinit();

    // M11.1 far-LOD merged-mesh renderer. Shares the same camera UBO as
    // ocean / instanced / arrows so all four passes agree on view/proj
    // without duplicate uploads.
    var merged_renderer = try render.MergedMeshRenderer.init(&gpu, frame.render_pass, ocean.camera_ubo.handle);
    defer merged_renderer.deinit();

    var scene: Scene = .{
        .ocean = &ocean,
        .instanced = &instanced,
        .arrows = &arrows,
        .merged_renderer = &merged_renderer,
    };

    const wave_params = try loadWaves(gpa, wave_config_path);
    ocean.setWaveParams(wave_params);

    const ocean_params = try loadOcean(gpa, ocean_config_path);
    ocean.setOceanParams(ocean_params);

    var watcher = try render.file_watch.Watcher.init(.{
        .wave_basename = std.fs.path.basename(wave_config_path),
        .hull_basename = std.fs.path.basename(hull_config_path),
    });
    defer watcher.deinit();
    std.log.info("hot-reload watching {s}, {s}, {s}, {s}, assets/shaders/*", .{
        ocean_config_path,
        wave_config_path,
        hull_config_path,
        wind_config_path,
    });
    std.log.info("present mode = {s}", .{if (cli.uncap) "MAILBOX (uncapped)" else "FIFO (vsync)"});

    // M3.1 smoke test: drop a 1×1×1 m box from y=20 onto a static floor
    // at y=0. Confirms Jolt FFI works end-to-end — gravity pulls it down,
    // collision halts it, body sleeps. Pose logged ~1 Hz.
    physics.init();
    defer physics.shutdown();
    var phys = try physics.System.init(.{});
    defer phys.deinit();

    // Hull params — half-extents, mass, sample points, drag — all live in
    // data/ships/box.yaml. Hot-reloadable below for buoyancy fields; mass
    // and shape changes still need a restart since Jolt has no recompute-
    // mass-properties path through our wrapper yet.
    var hull = try loadHull(gpa, hull_config_path);
    defer hull.deinit(gpa);

    // Wind field is loaded but not yet driving any forces — sails land
    // in M5. For M4.2 the value is logged ~1 Hz so hot-reload is visible
    // and the YAML→kernel path is exercised on every run.
    var wind_params = try loadWind(gpa, wind_config_path);
    defer wind_params.deinit(gpa);
    logWind(wind_params, 0.0);

    // M3.3: no static floor — the box floats on the wave heightfield,
    // which is the same scalar function the GPU raymarches. Body drops
    // from above SL onto the waves; buoyancy halts the fall. Modest drop
    // height keeps initial KE low so settle is visible.
    const box_id = try phys.createBox(.{
        .half_extents = hull.half_extents,
        .position = .{ 0, 4, 0 },
        .motion = .dynamic,
        .mass_override_kg = hull.mass_kg,
    });
    phys.optimizeBroadPhase();
    var phys_log_accum: f32 = 0;

    var buoy = physics.Buoyancy.init(buoyancyConfigFromHull(hull));

    // M5.1: physics runs at the locked 60Hz auth tick; render is uncapped.
    // We accumulate frame dt and step Jolt in fixed 1/60 s chunks. Each tick
    // snapshots the prior pose so the render frame can lerp/slerp between
    // (prev, curr) by `alpha = phys_accum / phys_dt_fixed`. The same
    // interpolation pattern carries forward to M5.3 where the passenger
    // composes against the *interpolated* ship pose — without it, a 144Hz
    // first-person camera on a 60Hz pitching deck shows visible jitter.
    //
    // `phys_t` is the simulation clock (advances by exactly phys_dt per step,
    // monotonic, identical run-to-run for a fixed soak duration). Wave queries
    // inside buoyancy use phys_t so successive ticks integrate against a
    // self-consistent height field. Camera, ocean shader time, and the
    // wind-arrow viz keep using the render-time `t` — they're cosmetic and
    // don't need bit-identical reproducibility.
    const phys_dt_fixed: f32 = 1.0 / 60.0;
    const max_steps_per_frame: u32 = 5;
    var phys_accum: f32 = 0;
    var phys_t: f32 = 0;
    var pose_prev_pos: [3]f32 = phys.getPosition(box_id) orelse .{ 0, 4, 0 };
    var pose_prev_rot: [4]f32 = phys.getRotation(box_id) orelse .{ 0, 0, 0, 1 };
    var pose_curr_pos: [3]f32 = pose_prev_pos;
    var pose_curr_rot: [4]f32 = pose_prev_rot;

    // M5.3 player. Spawn pre-boarded on top of the box: feet at local
    // y = +half_extents.y (deck surface), eye at +eye_height above. Yaw=0
    // looks down local -Z; the orbit-cam-era box position (0, 4, 0) puts
    // the bow toward -Z, so this faces "forward over the prow." When the
    // box pitches, the camera rolls with the deck because the world
    // composition rotates the local eye+forward by `ship_pose.rot`.
    //
    // attached_ship uses the Jolt BodyId since we have one ship and that's
    // the natural opaque handle. M5.5 multi-pax will need a registry layer
    // mapping ship handles to interpolated pose providers.
    var player: notatlas.player.Player = .{
        .pos = notatlas.math.Vec3.init(0, hull.half_extents[1], 0),
    };
    player.boardShip(box_id, player.pos);

    // M5.5 NPC passengers — three fixed poses on the deck, distinct colors,
    // facing different directions. They demonstrate that the SoT-style
    // composition handles multiple visible bodies on a pitching ship without
    // jitter or z-fighting; same math the player camera uses, rendered as
    // 0.5 × 1.7 × 0.5 m capsule-stand-ins (the existing Box mesh, scaled).
    var npc_pax: [npc_pax_count]notatlas.player.Player = undefined;
    // Spread across the new ship-like deck (4 m beam × 6 m length, hull
    // is half_extents 2 × 1.25 × 3). All three within the deck-clamp
    // walkable area (±(half - 0.3) inset).
    const npc_init: [npc_pax_count]struct { local_pos: notatlas.math.Vec3, yaw: f32 } = .{
        .{ .local_pos = notatlas.math.Vec3.init(1.2, hull.half_extents[1], -2.0), .yaw = 0 },
        .{ .local_pos = notatlas.math.Vec3.init(0.0, hull.half_extents[1], 2.0), .yaw = std.math.pi },
        .{ .local_pos = notatlas.math.Vec3.init(-1.2, hull.half_extents[1], -0.5), .yaw = std.math.pi * 0.5 },
    };
    const npc_albedo: [npc_pax_count][4]f32 = .{
        .{ 0.85, 0.30, 0.30, 0 }, // red
        .{ 0.30, 0.55, 0.90, 0 }, // blue
        .{ 0.40, 0.75, 0.40, 0 }, // green
    };
    for (0..npc_pax_count) |i| {
        npc_pax[i] = .{};
        npc_pax[i].boardShip(box_id, npc_init[i].local_pos);
        npc_pax[i].yaw = npc_init[i].yaw;
    }

    // M10.1: allocate one instance slot for the ship and one per passenger.
    // IDs are stable until destroy(); we hold them for the lifetime of the
    // sandbox and call updateTransform() once per frame from the
    // interpolated pose. Albedo is fixed at addInstance time.
    const initial_model: [16]f32 = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    };
    const ship_instance = try instanced.addInstance(0, initial_model, render.box.ship_albedo);
    var pax_instances: [npc_pax_count]render.instanced.InstanceId = undefined;
    for (0..npc_pax_count) |i| {
        pax_instances[i] = try instanced.addInstance(0, initial_model, npc_albedo[i]);
    }

    // M10.1 stress smoke. NxN cubes spaced 4 m apart on a flat grid
    // centered on the ship and lifted ~6 m above sea level. Static — IDs
    // are discarded since we never updateTransform. Albedo is a procedural
    // gradient over (i, j) so visually it's obvious if any cell is missing.
    if (cli.instance_grid > 0) {
        const n = cli.instance_grid;
        const spacing: f32 = 4.0;
        const half: f32 = @as(f32, @floatFromInt(n - 1)) * spacing * 0.5;
        const lift_y: f32 = 6.0;
        var gi: u32 = 0;
        var spawn_idx: u32 = 0;
        while (gi < n) : (gi += 1) {
            var gj: u32 = 0;
            while (gj < n) : (gj += 1) {
                const x = @as(f32, @floatFromInt(gi)) * spacing - half;
                const z = @as(f32, @floatFromInt(gj)) * spacing - half;
                const m = notatlas.math.Mat4.trs(
                    notatlas.math.Vec3.init(x, lift_y, z),
                    .{ 0, 0, 0, 1 },
                    notatlas.math.Vec3.init(1, 1, 1),
                );
                const r: f32 = @as(f32, @floatFromInt(gi)) / @as(f32, @floatFromInt(n));
                const g: f32 = @as(f32, @floatFromInt(gj)) / @as(f32, @floatFromInt(n));
                const albedo: [4]f32 = .{ r, g, 0.5, 0 };
                // Round-robin across piece types so each bucket has a
                // ~uniform population — the gate scenario.
                const piece_id: u32 = spawn_idx % cli.piece_types;
                _ = try instanced.addInstance(piece_id, m.data, albedo);
                spawn_idx += 1;
            }
        }
        std.log.info(
            "M10 stress: spawned {d}x{d}={d} static instances across {d} piece type(s)",
            .{ n, n, grid_slot_count, cli.piece_types },
        );
    }

    // M11.1/M11.2 anchorage cluster. When --anchorage-pieces N > 0,
    // build a deterministic cluster of N pieces inside a
    // `--anchorage-radius` disc centered ~120 m down +X from spawn.
    // M11.1 baked once and always rendered via merged path; M11.2 wraps
    // it in an Anchorage state machine that toggles between the
    // instanced (near) and merged (far) paths each frame based on
    // camera distance + a 10% hysteresis band.
    var anchorage: ?render.cluster_merge.Anchorage = null;
    defer if (anchorage) |*a| a.deinit();

    // M11.3 off-thread merge worker. Spawned unconditionally — cheap
    // when idle (one parked thread waiting on a cond). Used only when
    // an anchorage invalidates (I key in the sandbox; damage/placement
    // events in Phase 3).
    const worker = try render.cluster_merge_worker.Worker.spawn(gpa);
    defer worker.deinit();
    var pending_results: std.ArrayList(render.cluster_merge_worker.Result) = .empty;
    defer pending_results.deinit(gpa);
    var last_i_state: zglfw.Action = .release;
    if (cli.anchorage_pieces > 0) {
        if (cli.anchorage_piece_types > cli.piece_types) {
            std.log.warn(
                "anchorage-piece-types ({d}) > palette piece_types ({d}); clamping",
                .{ cli.anchorage_piece_types, cli.piece_types },
            );
        }
        const n: u32 = cli.anchorage_pieces;
        const types_used: u32 = @min(cli.anchorage_piece_types, cli.piece_types);
        const radius: f32 = cli.anchorage_radius;
        // Deterministic seed so the harness scene is reproducible.
        var rng = std.Random.DefaultPrng.init(0xA10C0A8E);
        const r = rng.random();

        const refs = try gpa.alloc(render.cluster_merge.PieceRef, n);
        defer gpa.free(refs);
        const pieces_for_merge = try gpa.alloc(render.mesh_palette.PieceMesh, n);
        defer gpa.free(pieces_for_merge);

        const center = notatlas.math.Vec3.init(120, 0, 0);
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            // Uniform-in-disc sample: r' = R·sqrt(u), θ = 2π·v.
            const u = r.float(f32);
            const v = r.float(f32);
            const rad = radius * @sqrt(u);
            const theta = 2.0 * std.math.pi * v;
            const dx = rad * @cos(theta);
            const dz = rad * @sin(theta);
            // y: low buildings 1-4 m tall, base at sea level.
            const height = 1.0 + r.float(f32) * 3.0;
            const yaw = 2.0 * std.math.pi * r.float(f32);
            const scale_xz = 1.0 + r.float(f32) * 2.0;
            const scale_y = height;

            const pos = notatlas.math.Vec3.init(
                center.x + dx,
                center.y + scale_y * 0.5,
                center.z + dz,
            );
            const s_half = @sin(yaw * 0.5);
            const c_half = @cos(yaw * 0.5);
            const m = notatlas.math.Mat4.trs(
                pos,
                .{ 0, s_half, 0, c_half },
                notatlas.math.Vec3.init(scale_xz, scale_y, scale_xz),
            );

            // Albedo: warm dockside palette banded by piece type.
            const tier: f32 = @as(f32, @floatFromInt(k % types_used)) /
                @as(f32, @floatFromInt(types_used));
            const albedo: [4]f32 = .{
                0.55 + 0.30 * tier,
                0.40 + 0.20 * (1.0 - tier),
                0.30 + 0.40 * r.float(f32),
                0,
            };

            const piece_id: u32 = k % types_used;
            refs[k] = .{ .piece_id = piece_id, .model = m.data, .albedo = albedo };
            // Round-robin across piece types — same pattern as the M10
            // instance-grid case so each piece-type bucket gets used.
            pieces_for_merge[k] = palette_pieces[piece_id];
        }

        var merge_timer = try std.time.Timer.start();
        anchorage = try render.cluster_merge.Anchorage.init(
            gpa,
            &gpu,
            0xA10C0A8E,
            pieces_for_merge,
            refs,
        );
        const merge_ns = merge_timer.read();
        const a = &anchorage.?;
        a.setForceFar(cli.force_far);
        std.log.info(
            "M11 anchorage: {d} pieces × {d} types in r={d:.1} m → {d} verts / {d} idx; merge {d:.2} ms (bounding r={d:.1} m){s}",
            .{
                n,
                types_used,
                radius,
                a.merged.vertex_count,
                a.merged.index_count,
                @as(f64, @floatFromInt(merge_ns)) / 1.0e6,
                a.merged.radius,
                if (cli.force_far) " [force-far]" else "",
            },
        );
        scene.anchorage = a;
    }

    var last_cursor: ?[2]f64 = null;
    var cursor_captured: bool = false;
    // Capture the cursor at startup so mouse-look works from the first frame.
    // `.disabled` mode hides the cursor and reports unbounded virtual
    // positions — the FPS standard. Esc releases, left-click recaptures.
    if (!cli.capture and cli.soak_seconds == 0) {
        zglfw.setInputMode(window.handle, .cursor, .disabled) catch {};
        cursor_captured = true;
    }

    var timer = try std.time.Timer.start();
    var t: f32 = 0.0;
    var soak_stats: SoakStats = .{};
    var wind_soak: WindSoakStats = .{};
    var pax_soak: PaxSoakStats = .{};
    var frame_soak: FrameSoakStats = .{};

    // 1Hz frame-time HUD for the M2.7 perf gate. Bar is ≤6.7 ms /
    // ≥150 fps on the dev box (RX 9070 XT @ 1280×720). Discard the
    // first frame because it bundles loop-preamble + Vulkan warm-up.
    var perf: PerfWindow = .{};

    // M11.2 L-key edge detection for the force-far override toggle.
    // Held key = no repeat; release-then-press is one transition.
    var last_l_state: zglfw.Action = .release;

    // RenderDoc capture: warm up for `capture_warmup_frames` to let pipeline
    // caches settle, then capture exactly one frame and exit. Frame 30 puts
    // the orbit camera at an above-water angle (~9 m altitude), good for
    // inspecting the steady-state water pass.
    const capture_warmup_frames: u32 = 30;
    var frame_index: u32 = 0;
    var capture_done = false;

    // Clear color is irrelevant — the fullscreen water/sky shader paints
    // every pixel.  Keep it black so any unrendered area is obvious.
    const clear: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 };

    while (!window.shouldClose()) {
        render.Window.pollEvents();

        var size = window.framebufferSize();
        while ((size[0] == 0 or size[1] == 0) and !window.shouldClose()) {
            render.Window.waitEvents();
            size = window.framebufferSize();
        }
        if (window.shouldClose()) break;

        const events = watcher.poll();
        if (events.any()) handleReload(gpa, &ocean, &instanced, &merged_renderer, &arrows, &hull, &buoy, &wind_params, frame.render_pass, events);

        const frame_ns = timer.lap();
        const dt: f32 = @as(f32, @floatFromInt(frame_ns)) / @as(f32, std.time.ns_per_s);
        t += dt;
        perf.tick(frame_ns);
        // M10.4 gate: per-render-frame timing histogrammed so we can
        // report p50/p99 at exit without storing every sample. ≥1 sample
        // outlier from the first frame (shader compile / pipeline cache
        // miss) is absorbed by the histogram, which is what we want.
        if (cli.soak_seconds > 0) frame_soak.observe(frame_ns);

        // Fixed-step physics. Owe `phys_accum` seconds of sim; consume in
        // exact 1/60 s chunks. `max_steps_per_frame` caps runaway: if the
        // sandbox stalls (RenderDoc capture pause, breakpoint), we'd
        // otherwise try to catch up by running hundreds of physics ticks
        // in one frame and tunneling through wave gradients. Better to
        // drop the residual and let the sim slow down briefly than to
        // explode the box.
        phys_accum += dt;
        var steps: u32 = 0;
        while (phys_accum >= phys_dt_fixed and steps < max_steps_per_frame) : (steps += 1) {
            pose_prev_pos = pose_curr_pos;
            pose_prev_rot = pose_curr_rot;
            buoy.step(&phys, box_id, wave_params, phys_t);
            phys.step(phys_dt_fixed, 1);
            phys_t += phys_dt_fixed;
            pose_curr_pos = phys.getPosition(box_id) orelse pose_curr_pos;
            pose_curr_rot = phys.getRotation(box_id) orelse pose_curr_rot;

            // Per-tick soak observations — uniform 1/60 s sampling, identical
            // to the rate the integrator actually steps at. Replaces the
            // pre-M5.1 per-render-frame sampling which redundantly observed
            // the same Jolt state ~15× per tick at uncapped framerates.
            if (cli.soak_seconds > 0) {
                const lin_v = phys.getLinearVelocity(box_id) orelse .{ 0, 0, 0 };
                const ang_v = phys.getAngularVelocity(box_id) orelse .{ 0, 0, 0 };
                soak_stats.observe(pose_curr_pos, lin_v, ang_v);
                wind_soak.observe(wind_params, phys_t);

                // M5.6 — observe the composed world eye for player + each
                // NPC pax. Builds the same `Pose` shape main passes to
                // worldEye at render time, but uses pose_curr (just-stepped,
                // deterministic at this tick boundary — no interpolation).
                // Catches NaN, unbounded growth, and per-tick teleports
                // through the SoT composition.
                const tick_ship_pose: notatlas.player.Pose = .{
                    .pos = notatlas.math.Vec3.init(pose_curr_pos[0], pose_curr_pos[1], pose_curr_pos[2]),
                    .rot = pose_curr_rot,
                };
                var eyes: [pax_total_count][3]f32 = undefined;
                {
                    const e = player.worldEye(tick_ship_pose);
                    eyes[0] = .{ e.x, e.y, e.z };
                }
                for (0..npc_pax_count) |i| {
                    const e = npc_pax[i].worldEye(tick_ship_pose);
                    eyes[1 + i] = .{ e.x, e.y, e.z };
                }
                pax_soak.observe(&eyes);
            }
            phys_accum -= phys_dt_fixed;
        }
        if (steps == max_steps_per_frame and phys_accum >= phys_dt_fixed) {
            phys_accum = 0;
        }

        phys_log_accum += dt;
        if (phys_log_accum >= 1.0) {
            const vel = phys.getLinearVelocity(box_id) orelse .{ 0, 0, 0 };
            std.log.info("phys: box pos=({d:.2},{d:.2},{d:.2}) vel=({d:.2},{d:.2},{d:.2})", .{
                pose_curr_pos[0], pose_curr_pos[1], pose_curr_pos[2], vel[0], vel[1], vel[2],
            });
            logWind(wind_params, t);
            phys_log_accum = 0;
        }

        // Render the box at the interpolated pose between the two most recent
        // physics ticks. `alpha ∈ [0, 1]` is the fractional position into the
        // next tick; at exactly the tick boundary alpha=0 and we render the
        // last completed pose.
        const alpha: f32 = std.math.clamp(phys_accum / phys_dt_fixed, 0.0, 1.0);
        const render_pos = notatlas.math.Vec3.init(
            pose_prev_pos[0] + (pose_curr_pos[0] - pose_prev_pos[0]) * alpha,
            pose_prev_pos[1] + (pose_curr_pos[1] - pose_prev_pos[1]) * alpha,
            pose_prev_pos[2] + (pose_curr_pos[2] - pose_prev_pos[2]) * alpha,
        );
        const render_rot = notatlas.math.quatSlerp(pose_prev_rot, pose_curr_rot, alpha);

        // Index 0 = ship itself: scaled to 4×4×4 m by the hull half-extents.
        const ship_model = notatlas.math.Mat4.trs(
            render_pos,
            render_rot,
            notatlas.math.Vec3.init(2 * hull.half_extents[0], 2 * hull.half_extents[1], 2 * hull.half_extents[2]),
        );
        instanced.updateTransform(ship_instance, ship_model.data);

        // Indices 1.. = NPC passengers, composed as ship_pose ⊗ pax_local.
        // ship_pose_only is unscaled (identity scale); the per-pax scale
        // (0.5 × 1.7 × 0.5 m) lives in the pax local model alongside the
        // local yaw. Feet sit on local y = +half_extents.y; the cube mesh is
        // ±0.5 in object space, so we lift its center by half the height
        // (1.7/2 = 0.85) to put the feet on the deck.
        const ship_pose_only = notatlas.math.Mat4.trs(
            render_pos,
            render_rot,
            notatlas.math.Vec3.init(1, 1, 1),
        );
        const pax_half_height: f32 = 0.85;
        for (0..npc_pax_count) |i| {
            const p = npc_pax[i];
            const local_offset = notatlas.math.Vec3.init(
                p.pos.x,
                p.pos.y + pax_half_height,
                p.pos.z,
            );
            const local_model = notatlas.math.Mat4.trs(
                local_offset,
                notatlas.math.quatYaw(p.yaw),
                notatlas.math.Vec3.init(0.5, 1.7, 0.5),
            );
            instanced.updateTransform(
                pax_instances[i],
                notatlas.math.Mat4.mul(ship_pose_only, local_model).data,
            );
        }

        if (cli.soak_seconds > 0 and t >= cli.soak_seconds) break;

        // M5.2 input. Mouse delta drives yaw/pitch (only while captured);
        // WASD + Space/Ctrl drive position. Esc releases the cursor (so the
        // window is dismissable); left-click re-captures. We re-poll cursor
        // position every frame regardless of capture state so re-capturing
        // doesn't snap the view by the cursor's drift while released.
        const cursor = window.handle.getCursorPos();
        if (cursor_captured) {
            if (last_cursor) |lc| {
                const dx: f32 = @floatCast(cursor[0] - lc[0]);
                const dy: f32 = @floatCast(cursor[1] - lc[1]);
                player.applyMouseDelta(dx, dy);
            }
            const move = pollMove(&window);
            player.applyMove(move, dt);
            // M5.4: pin to deck plane. Without this, walking off the edge
            // floats you in local-space air; Space/Ctrl would lift you off
            // the deck. Inset 0.3 m keeps the eye off the deck-edge corner
            // (the box's exact edge would clip the camera into nothing).
            player.clampToDeck(
                hull.half_extents[1],
                hull.half_extents[0],
                hull.half_extents[2],
                0.3,
            );
        }
        last_cursor = cursor;
        if (cursor_captured and window.handle.getKey(.escape) == .press) {
            zglfw.setInputMode(window.handle, .cursor, .normal) catch {};
            cursor_captured = false;
            last_cursor = null;
        } else if (!cursor_captured and window.handle.getMouseButton(.left) == .press) {
            zglfw.setInputMode(window.handle, .cursor, .disabled) catch {};
            cursor_captured = true;
            last_cursor = null;
        }

        // M5.3 SoT-style world camera composition. Pass the *interpolated*
        // ship pose (M5.1) so the camera stays smooth at high render rates;
        // the player's local fields are static between input ticks, so any
        // visible jitter on a pitching deck would have to come from the
        // ship pose source. Standing still + watching the deck rock is the
        // M5.3 headline gate.
        const ship_pose: notatlas.player.Pose = .{ .pos = render_pos, .rot = render_rot };
        const world_eye = player.worldEye(ship_pose);
        const world_fwd = player.worldForward(ship_pose);
        const camera: render.Camera = .{
            .eye = world_eye,
            .target = notatlas.math.Vec3.add(world_eye, world_fwd),
            .fov_y = player.fov_y,
            .aspect = @as(f32, @floatFromInt(size[0])) / @as(f32, @floatFromInt(size[1])),
        };
        ocean.updateCamera(camera);
        ocean.updateTime(t);
        // M10.3: stash view-proj for the prePass cull dispatch. Same
        // matrices the ocean UBO got — guarantees cull frustum matches
        // what the camera actually shows.
        scene.view_proj = notatlas.math.Mat4.mul(camera.projection(), camera.view());

        // M11.2: per-frame LOD selection for the anchorage. L toggles a
        // force-far override useful for visual A/B inspection of the
        // merged path. Transitions spawn/destroy instances in the
        // `Instanced` renderer so the same scene round-trips both
        // paths without leaking slots.
        if (anchorage) |*a| {
            const l_state = window.handle.getKey(.l);
            if (l_state == .press and last_l_state == .release) {
                const new_force = !a.force_far;
                a.setForceFar(new_force);
                std.log.info("anchorage[{d}]: force-far {s}", .{
                    a.id, if (new_force) "ON" else "OFF",
                });
            }
            last_l_state = l_state;

            // M11.3: drain worker results (if any) and apply. Done
            // before LOD selection so the new merged mesh is the one
            // we may render this frame. applyMerge calls
            // vkDeviceWaitIdle internally — safe to free the old GPU
            // mesh because no in-flight GPU work references it.
            const drained = worker.drain(&pending_results) catch 0;
            if (drained > 0) {
                for (pending_results.items) |result| {
                    defer gpa.free(result.vertices);
                    defer gpa.free(result.indices);
                    if (a.id != result.anchorage_id) continue;
                    a.applyMerge(&gpu, result.vertices, result.indices, result.stats) catch |err| {
                        std.log.err("anchorage[{d}] applyMerge: {s}", .{ a.id, @errorName(err) });
                        continue;
                    };
                    std.log.info(
                        "anchorage[{d}]: merge applied ({d} verts / {d} idx, worker {d:.2} ms, bounding r={d:.1} m)",
                        .{
                            a.id,
                            result.stats.vertex_count,
                            result.stats.index_count,
                            @as(f64, @floatFromInt(result.elapsed_ns)) / 1.0e6,
                            result.stats.radius,
                        },
                    );
                }
                pending_results.clearRetainingCapacity();
            }

            // M11.3: I key kicks an invalidate. Snapshots cached
            // PieceRefs into parallel slices + enqueues to the worker.
            // Heap-allocated; freed after enqueue (worker dup-copies).
            const i_state = window.handle.getKey(.i);
            if (i_state == .press and last_i_state == .release) {
                const n = a.pieces.len;
                const snap_pieces = gpa.alloc(render.mesh_palette.PieceMesh, n) catch null;
                const snap_transforms = gpa.alloc(notatlas.math.Mat4, n) catch null;
                const snap_albedos = gpa.alloc([4]f32, n) catch null;
                if (snap_pieces != null and snap_transforms != null and snap_albedos != null) {
                    defer gpa.free(snap_pieces.?);
                    defer gpa.free(snap_transforms.?);
                    defer gpa.free(snap_albedos.?);
                    a.snapshotForMerge(palette_pieces, snap_pieces.?, snap_transforms.?, snap_albedos.?);
                    worker.enqueue(a.id, .{
                        .pieces = snap_pieces.?,
                        .transforms = snap_transforms.?,
                        .albedos = snap_albedos.?,
                    }) catch |err| {
                        std.log.err("anchorage[{d}] enqueue: {s}", .{ a.id, @errorName(err) });
                    };
                    std.log.info("anchorage[{d}]: invalidate (enqueued worker job)", .{a.id});
                } else {
                    if (snap_pieces) |s| gpa.free(s);
                    if (snap_transforms) |s| gpa.free(s);
                    if (snap_albedos) |s| gpa.free(s);
                    std.log.err("anchorage[{d}] invalidate: OOM building snapshot", .{a.id});
                }
            }
            last_i_state = i_state;

            const transition = a.selectLod(world_eye, cli.anchorage_lod_distance);
            switch (transition) {
                .became_near => {
                    a.spawnInstances(&instanced) catch |err| {
                        std.log.err("anchorage[{d}] spawnInstances: {s}", .{ a.id, @errorName(err) });
                    };
                    std.log.info("anchorage[{d}]: became_near (dist={d:.1} m, {d} instances)", .{
                        a.id, a.distanceToCamera(world_eye), a.instance_ids.items.len,
                    });
                },
                .became_far => {
                    a.destroyInstances(&instanced);
                    std.log.info("anchorage[{d}]: became_far (dist={d:.1} m)", .{
                        a.id, a.distanceToCamera(world_eye),
                    });
                },
                .unchanged => {},
            }
        }

        // M10.3: CPU bucket/scatter/upload runs BEFORE `frame.draw` so the
        // indirect + instance buffers are visible to the compute culler
        // (which dispatches in `prePass` outside the render pass).
        instanced.prepareFrame();

        // Sample the wind on the debug grid and push to the arrows
        // instance buffer. 256 windAt() calls / frame; cheap (~0.1 ms).
        var arrow_instances: [arrow_count]render.wind_arrows.ArrowInstance = undefined;
        sampleWindGrid(wind_params, t, &arrow_instances);
        arrows.updateInstances(&arrow_instances);

        const capturing_this_frame = capture != null and !capture_done and frame_index == capture_warmup_frames;
        if (capturing_this_frame) capture.?.start();

        const result = try frame.draw(&swapchain, clear, recordScene, &scene, prePass, &scene);
        if (result == .resize_needed) {
            try swapchain.recreate(window.framebufferSize());
            try frame.recreateFramebuffers(&gpu, &swapchain);
        }

        if (capturing_this_frame) {
            const ok = capture.?.end();
            std.log.info("renderdoc capture {s}; .rdc dropped under captures/", .{
                if (ok) "ok" else "FAILED",
            });
            capture_done = true;
            break;
        }
        frame_index += 1;
    }

    // Drain the GPU before the defer chain destroys descriptor pools,
    // pipelines, and other resources still referenced by the in-flight
    // command buffer. Without this, validation fires
    // VUID-vkDestroyDescriptorPool-descriptorPool-00303 +
    // VUID-vkDestroyPipeline-pipeline-00765 on clean shutdown.
    _ = render.types.vk.vkDeviceWaitIdle(gpu.device);

    if (cli.soak_seconds > 0) {
        soak_stats.report(t);
        wind_soak.report(wind_params, t);
        pax_soak.report(t);
        frame_soak.report(cli, instanced.activeCount(), palette.pieceCount());
    }
}

fn loadWaves(gpa: std.mem.Allocator, rel_path: []const u8) !notatlas.wave_query.WaveParams {
    const abs = try std.fs.cwd().realpathAlloc(gpa, rel_path);
    defer gpa.free(abs);
    return notatlas.yaml_loader.loadFromFile(gpa, abs);
}

fn loadOcean(gpa: std.mem.Allocator, rel_path: []const u8) !notatlas.ocean_params.OceanParams {
    const abs = try std.fs.cwd().realpathAlloc(gpa, rel_path);
    defer gpa.free(abs);
    return notatlas.yaml_loader.loadOceanFromFile(gpa, abs);
}

fn loadHull(gpa: std.mem.Allocator, rel_path: []const u8) !notatlas.hull_params.HullParams {
    const abs = try std.fs.cwd().realpathAlloc(gpa, rel_path);
    defer gpa.free(abs);
    return notatlas.yaml_loader.loadHullFromFile(gpa, abs);
}

fn loadWind(gpa: std.mem.Allocator, rel_path: []const u8) !notatlas.wind_query.WindParams {
    const abs = try std.fs.cwd().realpathAlloc(gpa, rel_path);
    defer gpa.free(abs);
    return notatlas.yaml_loader.loadWindFromFile(gpa, abs);
}

/// Sample the wind at the origin and log direction + magnitude. Cheap
/// proof-of-life that the YAML→kernel path is wired and that hot-reload
/// updates are taking effect.
fn logWind(p: notatlas.wind_query.WindParams, t: f32) void {
    const w = notatlas.wind_query.windAt(p, 0, 0, t);
    const mag = @sqrt(w[0] * w[0] + w[1] * w[1]);
    std.log.info("wind: ({d:.2},{d:.2}) m/s |{d:.2}| storms={d}", .{
        w[0], w[1], mag, p.storms.len,
    });
}

fn buoyancyConfigFromHull(hull: notatlas.hull_params.HullParams) physics.BuoyancyConfig {
    return .{
        .sample_points = hull.sample_points,
        .cell_half_height = hull.cell_half_height,
        .cell_cross_section = hull.cell_cross_section,
        .drag_per_point = hull.drag_per_point,
    };
}

/// Apply whatever the watcher flagged. Errors are logged and swallowed —
/// a typo in YAML or a broken shader must not kill the running sandbox;
/// the user fixes the file and saves again.
fn handleReload(
    gpa: std.mem.Allocator,
    ocean: *render.Ocean,
    instanced: *render.Instanced,
    merged_renderer: *render.MergedMeshRenderer,
    arrows: *render.WindArrows,
    hull: *notatlas.hull_params.HullParams,
    buoy: *physics.Buoyancy,
    wind_params: *notatlas.wind_query.WindParams,
    render_pass: render.types.vk.VkRenderPass,
    events: render.file_watch.Events,
) void {
    var timer = std.time.Timer.start() catch return;

    if (events.ocean) {
        if (loadOcean(gpa, ocean_config_path)) |p| {
            ocean.setOceanParams(p);
            std.log.info("reload {s} ({d} ms)", .{ ocean_config_path, timer.lap() / std.time.ns_per_ms });
        } else |err| {
            std.log.err("reload {s}: {s}", .{ ocean_config_path, @errorName(err) });
        }
    }

    if (events.wave) {
        if (loadWaves(gpa, wave_config_path)) |p| {
            ocean.setWaveParams(p);
            std.log.info("reload {s} ({d} ms)", .{ wave_config_path, timer.lap() / std.time.ns_per_ms });
        } else |err| {
            std.log.err("reload {s}: {s}", .{ wave_config_path, @errorName(err) });
        }
    }

    // Hull hot-reload only updates buoyancy params + render scale.
    // mass_kg / half_extents changes need a restart — the Jolt body's
    // mass properties and collision shape are baked at create time.
    if (events.hull) {
        if (loadHull(gpa, hull_config_path)) |new_hull| {
            if (new_hull.mass_kg != hull.mass_kg or
                !std.mem.eql(f32, &new_hull.half_extents, &hull.half_extents))
            {
                std.log.warn("hull mass/half_extents changed — restart sandbox to pick up", .{});
            }
            hull.deinit(gpa);
            hull.* = new_hull;
            buoy.cfg = buoyancyConfigFromHull(new_hull);
            std.log.info("reload {s} ({d} ms)", .{ hull_config_path, timer.lap() / std.time.ns_per_ms });
        } else |err| {
            std.log.err("reload {s}: {s}", .{ hull_config_path, @errorName(err) });
        }
    }

    if (events.wind) {
        if (loadWind(gpa, wind_config_path)) |new_params| {
            wind_params.deinit(gpa);
            wind_params.* = new_params;
            std.log.info("reload {s} ({d} ms)", .{ wind_config_path, timer.lap() / std.time.ns_per_ms });
            logWind(new_params, 0.0);
        } else |err| {
            std.log.err("reload {s}: {s}", .{ wind_config_path, @errorName(err) });
        }
    }

    // Watcher emits a single .shader bool — no per-file granularity. Both
    // pipelines recompile on any shader edit. Cheap (~100ms total) and
    // simpler than fan-out per-shader bookkeeping.
    if (events.shader) {
        const vert_spv = render.shader_compile.compileGlsl(gpa, vert_shader_path, "fullscreen.vert") catch return;
        defer gpa.free(vert_spv);
        const frag_spv = render.shader_compile.compileGlsl(gpa, frag_shader_path, "water.frag") catch return;
        defer gpa.free(frag_spv);
        ocean.reloadShaders(render_pass, vert_spv, frag_spv) catch |err| {
            std.log.err("reload water shaders: {s}", .{@errorName(err)});
            return;
        };

        const inst_vert_spv = render.shader_compile.compileGlsl(gpa, instanced_vert_shader_path, "instanced.vert") catch return;
        defer gpa.free(inst_vert_spv);
        const inst_frag_spv = render.shader_compile.compileGlsl(gpa, instanced_frag_shader_path, "instanced.frag") catch return;
        defer gpa.free(inst_frag_spv);
        instanced.reloadShaders(render_pass, inst_vert_spv, inst_frag_spv) catch |err| {
            std.log.err("reload instanced shaders: {s}", .{@errorName(err)});
            return;
        };

        // M11.1 merged-mesh shaders.
        const merged_vert_spv = render.shader_compile.compileGlsl(gpa, merged_vert_shader_path, "merged.vert") catch return;
        defer gpa.free(merged_vert_spv);
        const merged_frag_spv = render.shader_compile.compileGlsl(gpa, merged_frag_shader_path, "merged.frag") catch return;
        defer gpa.free(merged_frag_spv);
        merged_renderer.reloadShaders(render_pass, merged_vert_spv, merged_frag_spv) catch |err| {
            std.log.err("reload merged shaders: {s}", .{@errorName(err)});
            return;
        };

        const arrows_vert_spv = render.shader_compile.compileGlsl(gpa, arrows_vert_path, "wind_arrows.vert") catch return;
        defer gpa.free(arrows_vert_spv);
        const arrows_frag_spv = render.shader_compile.compileGlsl(gpa, arrows_frag_path, "wind_arrows.frag") catch return;
        defer gpa.free(arrows_frag_spv);
        arrows.reloadShaders(render_pass, arrows_vert_spv, arrows_frag_spv) catch |err| {
            std.log.err("reload wind_arrows shaders: {s}", .{@errorName(err)});
            return;
        };

        std.log.info("reload shaders ({d} ms)", .{timer.lap() / std.time.ns_per_ms});
    }
}

fn recordScene(
    ctx: *anyopaque,
    cb: render.types.vk.VkCommandBuffer,
    extent: render.types.vk.VkExtent2D,
) void {
    const scene: *Scene = @ptrCast(@alignCast(ctx));
    scene.ocean.record(cb, extent);
    // M10.1: single SSBO-driven instanced pass covers ship + passengers in
    // one drawIndexed per piece type (currently 1). Return is the draw-call
    // count; we discard it here — the M10.4 gate harness will sample it.
    _ = scene.instanced.record(cb, extent);
    // M11.2: far-LOD merged anchorage renders as one drawIndexed.
    // shouldDrawMerged() is true only when the anchorage is in `.far`;
    // in `.near` the pieces ride the instanced path above and the
    // merged buffer goes untouched this frame.
    if (scene.anchorage) |a| {
        if (a.shouldDrawMerged()) {
            _ = scene.merged_renderer.record(cb, extent, &a.merged);
        }
    }
    scene.arrows.record(cb, extent);
}

/// Pre-pass: compute dispatches that must happen outside the render pass.
/// M10.3 GPU frustum culling lives here. Frustum extracted from the same
/// view-projection the ocean pipeline uses, so cull math agrees with what
/// the camera actually shows.
fn prePass(
    ctx: *anyopaque,
    cb: render.types.vk.VkCommandBuffer,
    extent: render.types.vk.VkExtent2D,
) void {
    _ = extent;
    const scene: *Scene = @ptrCast(@alignCast(ctx));
    scene.instanced.dispatchCull(cb, scene.view_proj);
}

/// Snapshot WASD / Space / Ctrl into a FlyCamera move vector. Each axis is
/// the difference of two boolean keys, so chord cancellation works the same
/// as any FPS (W+S = 0, A+D = 0). Diagonal (W+D) is unnormalized — gives
/// the classic √2× bonus on diagonals; not worth normalizing for sandbox.
fn pollMove(window: *render.Window) notatlas.player.Move {
    const fw: f32 = if (window.handle.getKey(.w) == .press) 1 else 0;
    const bw: f32 = if (window.handle.getKey(.s) == .press) 1 else 0;
    const lf: f32 = if (window.handle.getKey(.a) == .press) 1 else 0;
    const rt: f32 = if (window.handle.getKey(.d) == .press) 1 else 0;
    const up: f32 = if (window.handle.getKey(.space) == .press) 1 else 0;
    const dn: f32 = if (window.handle.getKey(.left_control) == .press) 1 else 0;
    return .{ .forward = fw - bw, .strafe = rt - lf, .up = up - dn };
}

/// Fill `out` with `arrow_grid_dim²` windAt samples on a centered grid.
fn sampleWindGrid(
    wind_params: notatlas.wind_query.WindParams,
    t: f32,
    out: *[arrow_count]render.wind_arrows.ArrowInstance,
) void {
    const half: f32 = 0.5 * @as(f32, @floatFromInt(arrow_grid_dim - 1)) * arrow_grid_step_m;
    var idx: usize = 0;
    var i: u32 = 0;
    while (i < arrow_grid_dim) : (i += 1) {
        const x = -half + @as(f32, @floatFromInt(i)) * arrow_grid_step_m;
        var j: u32 = 0;
        while (j < arrow_grid_dim) : (j += 1) {
            const z = -half + @as(f32, @floatFromInt(j)) * arrow_grid_step_m;
            const w = notatlas.wind_query.windAt(wind_params, x, z, t);
            out[idx] = .{ .pos_xz = .{ x, z }, .wind_xz = w };
            idx += 1;
        }
    }
}

const Cli = struct {
    uncap: bool = false,
    capture: bool = false,
    /// Run the loop for this many seconds with pose telemetry accumulated,
    /// then print stats and exit. 0 = normal interactive run.
    soak_seconds: f32 = 0,
    /// M10.1 stress smoke: spawn an N×N grid of static cubes around the
    /// ship at startup. 0 = disabled. Validates the instanced renderer's
    /// SSBO/bucket/draw path scales beyond the 4 dynamic instances the
    /// sandbox uses by default; per piece-type bucketing still issues
    /// exactly one drawIndexed regardless of N (the M10 gate). Static
    /// once placed — updateTransform never called for grid cells.
    instance_grid: u32 = 0,
    /// M10.4 gate harness: number of distinct piece types the palette
    /// holds. Grid instances round-robin across them, so each piece type
    /// gets its own bucket and indirect-command entry. The M10 gate is
    /// ≤20 piece types renderable at once; setting this to 20 with
    /// --instance-grid 71 (5041 instances) exercises the published
    /// target. Piece geometry is identical (the same cube) — only the
    /// `PieceEntry` bookkeeping differs, which is what the gate measures.
    piece_types: u32 = 1,
    /// M10.3 toggle: when true, skip GPU compute frustum culling and let
    /// CPU prep write full bucket-size instance_counts + identity
    /// visible-indices. A/B compare cull-on vs cull-off frametimes via
    /// the M10.4 gate harness.
    no_cull: bool = false,
    /// M11.1: spawn a single anchorage cluster of N pieces at startup,
    /// merged into one mesh and rendered via the far-LOD merged path.
    /// 0 = off. Coexists with --instance-grid; the anchorage cluster is
    /// placed ~120 m down +X from the ship spawn so both are visible.
    /// LOD switching (M11.2) is not in this sub-commit — when set,
    /// the anchorage always renders via the merged path.
    anchorage_pieces: u32 = 0,
    /// M11.1: piece-type count for the anchorage (default 20, matches
    /// the M10 gate ceiling). Pieces are the same procedural cube as
    /// M10, drawn from the palette by id; the gate scene authors
    /// variety via per-piece TRS + per-instance albedo.
    anchorage_piece_types: u32 = 20,
    /// M11.1: anchorage cluster radius in metres (the disc within
    /// which piece transforms are randomized). Default 50 m matches
    /// the design cap for a single anchorage footprint.
    anchorage_radius: f32 = 50.0,
    /// M11.2: LOD distance threshold in metres. Camera nearer than
    /// (threshold * 0.9) of the cluster's bounding sphere → near-LOD
    /// (per-piece instanced draws). Past (threshold * 1.1) → far-LOD
    /// (one merged drawIndexed). 10% hysteresis around the threshold.
    anchorage_lod_distance: f32 = 200.0,
    /// M11.2 / M11.4: latch the anchorage into far-LOD regardless of
    /// camera distance. The gate harness sets this so frametime
    /// measurements reflect the merged path.
    force_far: bool = false,
};

fn parseCli(gpa: std.mem.Allocator) !Cli {
    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();
    _ = args.next(); // skip exe name
    var cli: Cli = .{};
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--uncap")) {
            cli.uncap = true;
        } else if (std.mem.eql(u8, a, "--capture")) {
            cli.capture = true;
        } else if (std.mem.eql(u8, a, "--soak")) {
            const v = args.next() orelse return error.MissingSoakValue;
            cli.soak_seconds = try std.fmt.parseFloat(f32, v);
        } else if (std.mem.eql(u8, a, "--instance-grid")) {
            const v = args.next() orelse return error.MissingInstanceGridValue;
            cli.instance_grid = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, a, "--piece-types")) {
            const v = args.next() orelse return error.MissingPieceTypesValue;
            cli.piece_types = try std.fmt.parseInt(u32, v, 10);
            if (cli.piece_types == 0) return error.PieceTypesMustBePositive;
        } else if (std.mem.eql(u8, a, "--no-cull")) {
            cli.no_cull = true;
        } else if (std.mem.eql(u8, a, "--anchorage-pieces")) {
            const v = args.next() orelse return error.MissingAnchoragePiecesValue;
            cli.anchorage_pieces = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, a, "--anchorage-piece-types")) {
            const v = args.next() orelse return error.MissingAnchoragePieceTypesValue;
            cli.anchorage_piece_types = try std.fmt.parseInt(u32, v, 10);
            if (cli.anchorage_piece_types == 0) return error.AnchoragePieceTypesMustBePositive;
        } else if (std.mem.eql(u8, a, "--anchorage-radius")) {
            const v = args.next() orelse return error.MissingAnchorageRadiusValue;
            cli.anchorage_radius = try std.fmt.parseFloat(f32, v);
        } else if (std.mem.eql(u8, a, "--anchorage-lod-distance")) {
            const v = args.next() orelse return error.MissingAnchorageLodDistanceValue;
            cli.anchorage_lod_distance = try std.fmt.parseFloat(f32, v);
        } else if (std.mem.eql(u8, a, "--force-far")) {
            cli.force_far = true;
        }
    }
    return cli;
}

/// Per-frame pose telemetry for the M3.5 stability gate. Tracks running
/// extrema and counts NaN appearances; bounded numbers across a 5-min run
/// are the gate.
const SoakStats = struct {
    samples: u64 = 0,
    nan_count: u64 = 0,

    pos_min: [3]f32 = .{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) },
    pos_max: [3]f32 = .{ -std.math.floatMax(f32), -std.math.floatMax(f32), -std.math.floatMax(f32) },
    speed_max: f32 = 0,
    angvel_max: f32 = 0,

    fn observe(self: *SoakStats, pos: [3]f32, lin_v: [3]f32, ang_v: [3]f32) void {
        self.samples += 1;
        for (pos) |c| if (std.math.isNan(c)) {
            self.nan_count += 1;
            return;
        };
        for (lin_v) |c| if (std.math.isNan(c)) {
            self.nan_count += 1;
            return;
        };
        for (ang_v) |c| if (std.math.isNan(c)) {
            self.nan_count += 1;
            return;
        };
        for (0..3) |i| {
            if (pos[i] < self.pos_min[i]) self.pos_min[i] = pos[i];
            if (pos[i] > self.pos_max[i]) self.pos_max[i] = pos[i];
        }
        const speed = @sqrt(lin_v[0] * lin_v[0] + lin_v[1] * lin_v[1] + lin_v[2] * lin_v[2]);
        const angsp = @sqrt(ang_v[0] * ang_v[0] + ang_v[1] * ang_v[1] + ang_v[2] * ang_v[2]);
        if (speed > self.speed_max) self.speed_max = speed;
        if (angsp > self.angvel_max) self.angvel_max = angsp;
    }

    fn report(self: SoakStats, duration_s: f32) void {
        std.log.info(
            \\soak: {d:.1}s, {d} samples, {d} NaN
            \\  pos x: [{d:.2}, {d:.2}]
            \\  pos y: [{d:.2}, {d:.2}]
            \\  pos z: [{d:.2}, {d:.2}]
            \\  max |lin v|: {d:.2} m/s
            \\  max |ang v|: {d:.2} rad/s
        , .{
            duration_s,      self.samples,
            self.nan_count,  self.pos_min[0],
            self.pos_max[0], self.pos_min[1],
            self.pos_max[1], self.pos_min[2],
            self.pos_max[2], self.speed_max,
            self.angvel_max,
        });
    }
};

/// M4.4 stability gate for the wind field. Each tick: samples a 16×16 grid
/// covering the entire toroidal storm world (so the σ rings are periodically
/// intersected as storms drift) and probes each storm's eye directly (so
/// peak / anti-peak magnitudes show up in the range regardless of where
/// storms happen to be). Tracks per-storm wrap-aware path length to verify
/// `stormCenter` translates linearly. Reports aggregate stats at end.
///
/// The renderer's arrow grid is intentionally NOT reused: it's centered on
/// the box at ±375 m, which on a 4096 m storm world rarely overlaps any
/// storm and would understate the magnitude range. The soak's job is to
/// verify the kernel globally, not to mirror what the camera sees.
///
/// Pass criteria (informal — the user reads the log):
///   - `nan_count` is 0
///   - `mag_max` close to the analytic upper bound
///     `base_speed_mps + max strength_mps` (depends on storm alignment;
///     for the storm preset, ~22 m/s is achievable when a storm's gust
///     aligns with the base wind direction at some moment)
///   - For each storm: `path_length` ≈ `speed_mps × duration` (within
///     a fraction of a meter over 5 min)
///   - `max_step` ≪ world size — no teleports / wrap discontinuities slip
///     through the wrap-aware delta
const max_tracked_storms: usize = 8;
const wind_soak_grid_dim: u32 = 16;

const WindSoakStats = struct {
    samples: u64 = 0,
    nan_count: u64 = 0,
    mag_min: f32 = std.math.floatMax(f32),
    mag_max: f32 = -std.math.floatMax(f32),

    storm_count: u32 = 0,
    storm_first_center: [max_tracked_storms][2]f32 = .{.{ 0, 0 }} ** max_tracked_storms,
    storm_last_center: [max_tracked_storms][2]f32 = .{.{ 0, 0 }} ** max_tracked_storms,
    storm_max_step: [max_tracked_storms]f32 = .{0} ** max_tracked_storms,
    storm_path_length: [max_tracked_storms]f32 = .{0} ** max_tracked_storms,

    fn observeMag(self: *WindSoakStats, w: [2]f32) void {
        self.samples += 1;
        if (std.math.isNan(w[0]) or std.math.isNan(w[1])) {
            self.nan_count += 1;
            return;
        }
        const m = @sqrt(w[0] * w[0] + w[1] * w[1]);
        if (m < self.mag_min) self.mag_min = m;
        if (m > self.mag_max) self.mag_max = m;
    }

    fn observe(self: *WindSoakStats, p: notatlas.wind_query.WindParams, t: f32) void {
        const first = self.samples == 0;
        if (first) self.storm_count = @intCast(@min(p.storms.len, max_tracked_storms));

        // Wide grid — covers the full storm world. Step ≈ world / 16 ≈ 256 m
        // for the 4096 m default, slightly under σ=300 m, so as storms drift
        // the grid passes through their σ rings and we observe peak magnitudes
        // every few seconds.
        const half = p.storm_world_m * 0.5;
        const step = p.storm_world_m / @as(f32, @floatFromInt(wind_soak_grid_dim));
        var i: u32 = 0;
        while (i < wind_soak_grid_dim) : (i += 1) {
            const x = -half + (@as(f32, @floatFromInt(i)) + 0.5) * step;
            var j: u32 = 0;
            while (j < wind_soak_grid_dim) : (j += 1) {
                const z = -half + (@as(f32, @floatFromInt(j)) + 0.5) * step;
                const w = notatlas.wind_query.windAt(p, x, z, t);
                self.observeMag(w);
            }
        }

        // Probe each storm's eye directly — guarantees peak / anti-peak
        // contribution shows up in the magnitude range every frame.
        var s: usize = 0;
        while (s < self.storm_count) : (s += 1) {
            const c = notatlas.wind_query.stormCenter(p, s, t);
            const w_eye = notatlas.wind_query.windAt(p, c[0], c[1], t);
            self.observeMag(w_eye);

            if (first) {
                self.storm_first_center[s] = c;
                self.storm_last_center[s] = c;
                continue;
            }
            const last = self.storm_last_center[s];
            // Wrap-aware delta — when a storm crosses the world edge the
            // raw c-last jump looks like ±world_m; subtracting the world
            // size folds it back to the true short-path step.
            var dx = c[0] - last[0];
            var dz = c[1] - last[1];
            if (dx > half) dx -= p.storm_world_m;
            if (dx < -half) dx += p.storm_world_m;
            if (dz > half) dz -= p.storm_world_m;
            if (dz < -half) dz += p.storm_world_m;
            const step_dist = @sqrt(dx * dx + dz * dz);
            if (step_dist > self.storm_max_step[s]) self.storm_max_step[s] = step_dist;
            self.storm_path_length[s] += step_dist;
            self.storm_last_center[s] = c;
        }
    }

    fn report(self: WindSoakStats, p: notatlas.wind_query.WindParams, duration_s: f32) void {
        std.log.info(
            \\wind soak: {d:.1}s, {d} samples, {d} NaN
            \\  mag range: [{d:.3}, {d:.3}] m/s
            \\  storms tracked: {d}/{d}
        , .{
            duration_s,     self.samples,
            self.nan_count, self.mag_min,
            self.mag_max,   self.storm_count,
            p.storms.len,
        });
        var i: usize = 0;
        while (i < self.storm_count) : (i += 1) {
            const expected = p.storms[i].speed_mps * duration_s;
            std.log.info("  storm[{d}]: path={d:.1} m, max-step={d:.4} m, expected drift={d:.1} m", .{
                i, self.storm_path_length[i], self.storm_max_step[i], expected,
            });
        }
    }
};

/// M5.6 stability gate for the M5 SoT composition. Each tick, observes the
/// world-space eye position for the player + each NPC pax — the value
/// `player.worldEye(ship_pose)` produces against the just-stepped (not
/// interpolated) ship pose. Tracks per-pax y range (sanity-bounds the
/// composition output against the wave amplitude + eye height) plus the
/// max single-tick eye delta (catches teleports / NaN-induced jumps that
/// wouldn't show up in M3.5's box-pose-only soak).
///
/// Pass criteria (informal — the user reads the log):
///   - `nan_count` is 0
///   - `y_max - y_min` consistent with the storm preset's ±5 m wave bound
///     plus the player's eye-height offset (~3.7 m above local-y=0)
///   - `max_step` per pax << ship motion, since the per-tick ship delta
///     itself is bounded by the integrator (~10 m/s × 1/60 s ≈ 0.17 m).
const PaxSoakStats = struct {
    samples: u64 = 0,
    nan_count: u64 = 0,
    pax_count: u32 = 0,
    y_min: [pax_total_count]f32 = .{std.math.floatMax(f32)} ** pax_total_count,
    y_max: [pax_total_count]f32 = .{-std.math.floatMax(f32)} ** pax_total_count,
    max_step: [pax_total_count]f32 = .{0} ** pax_total_count,
    last_eye: [pax_total_count][3]f32 = .{.{ 0, 0, 0 }} ** pax_total_count,

    fn observe(self: *PaxSoakStats, eyes: *const [pax_total_count][3]f32) void {
        const first = self.samples == 0;
        if (first) self.pax_count = pax_total_count;
        for (eyes, 0..) |eye, i| {
            if (std.math.isNan(eye[0]) or std.math.isNan(eye[1]) or std.math.isNan(eye[2])) {
                self.nan_count += 1;
                continue;
            }
            if (eye[1] < self.y_min[i]) self.y_min[i] = eye[1];
            if (eye[1] > self.y_max[i]) self.y_max[i] = eye[1];
            if (!first) {
                const dx = eye[0] - self.last_eye[i][0];
                const dy = eye[1] - self.last_eye[i][1];
                const dz = eye[2] - self.last_eye[i][2];
                const step = @sqrt(dx * dx + dy * dy + dz * dz);
                if (step > self.max_step[i]) self.max_step[i] = step;
            }
            self.last_eye[i] = eye;
        }
        self.samples += 1;
    }

    fn report(self: PaxSoakStats, duration_s: f32) void {
        std.log.info(
            \\pax soak: {d:.1}s, {d} samples, {d} NaN, {d} pax tracked
        , .{ duration_s, self.samples, self.nan_count, self.pax_count });
        for (0..self.pax_count) |i| {
            const role = if (i == 0) "player" else "npc";
            std.log.info("  pax[{d}] ({s}): world_eye y∈[{d:.2},{d:.2}] max_step={d:.4} m", .{
                i, role, self.y_min[i], self.y_max[i], self.max_step[i],
            });
        }
    }
};

/// M10.4 per-render-frame timing histogram. 0.1 ms bins from 0..50 ms;
/// frames over 50 ms land in the top bin (won't poison the percentile —
/// the gate fails on either count anyway). Fixed memory cost (500 u32s)
/// regardless of soak duration; numerically robust for long runs.
///
/// `observe` skips the first `warmup_skip` calls so pipeline-cache misses
/// + shader compile cost on early frames don't poison the distribution.
const FrameSoakStats = struct {
    const bin_count: usize = 500;
    const bin_width_ms: f64 = 0.1;
    const warmup_skip: u32 = 30;

    bins: [bin_count]u32 = .{0} ** bin_count,
    total_samples: u64 = 0,
    skipped: u32 = 0,
    max_frame_ns: u64 = 0,
    min_frame_ns: u64 = std.math.maxInt(u64),
    sum_frame_ns: u64 = 0,

    fn observe(self: *FrameSoakStats, frame_ns: u64) void {
        if (self.skipped < warmup_skip) {
            self.skipped += 1;
            return;
        }
        self.total_samples += 1;
        self.sum_frame_ns += frame_ns;
        if (frame_ns > self.max_frame_ns) self.max_frame_ns = frame_ns;
        if (frame_ns < self.min_frame_ns) self.min_frame_ns = frame_ns;

        const frame_ms: f64 = @as(f64, @floatFromInt(frame_ns)) / 1.0e6;
        var bin: usize = @intFromFloat(@floor(frame_ms / bin_width_ms));
        if (bin >= bin_count) bin = bin_count - 1;
        self.bins[bin] +%= 1;
    }

    /// Linear-interpolated percentile across the histogram. Returns 0 on
    /// empty (no samples). Approximate at bin granularity (0.5 ms).
    fn percentileMs(self: *const FrameSoakStats, p: f64) f64 {
        if (self.total_samples == 0) return 0;
        const target = @as(f64, @floatFromInt(self.total_samples)) * (p / 100.0);
        var cumulative: f64 = 0;
        var i: usize = 0;
        while (i < bin_count) : (i += 1) {
            cumulative += @as(f64, @floatFromInt(self.bins[i]));
            if (cumulative >= target) {
                return @as(f64, @floatFromInt(i)) * bin_width_ms + bin_width_ms * 0.5;
            }
        }
        return @as(f64, bin_count) * bin_width_ms;
    }

    fn report(self: *const FrameSoakStats, cli: Cli, active_instances: u32, piece_types: usize) void {
        if (self.total_samples == 0) {
            std.log.info("frame soak: no samples", .{});
            return;
        }
        const ns_to_ms: f64 = 1.0 / 1.0e6;
        const avg_ms = (@as(f64, @floatFromInt(self.sum_frame_ns)) / @as(f64, @floatFromInt(self.total_samples))) * ns_to_ms;
        const min_ms = @as(f64, @floatFromInt(self.min_frame_ns)) * ns_to_ms;
        const max_ms = @as(f64, @floatFromInt(self.max_frame_ns)) * ns_to_ms;
        const p50 = self.percentileMs(50.0);
        const p99 = self.percentileMs(99.0);
        const fps_avg = 1000.0 / avg_ms;

        // M10 gate: ≤20 draw calls (logical indirect-cmd buckets = piece
        // type count for now, since every piece has ≥1 instance in the
        // round-robin distribution). + 60 fps target. The instanced pass
        // currently issues exactly 1 vkCmdDrawIndexedIndirect/frame, so
        // the API-level draw call count is 1 regardless.
        const gate_60fps = avg_ms <= 16.67;
        const gate_p99 = p99 <= 16.67;
        const gate_draws = piece_types <= 20;

        std.log.info("==== M10 gate harness ====", .{});
        std.log.info("  scene: {d} instances across {d} piece type(s) ({d}x{d} grid + 4 dynamic)", .{
            active_instances, piece_types, cli.instance_grid, cli.instance_grid,
        });
        std.log.info("  present mode: {s}", .{if (cli.uncap) "MAILBOX (uncapped)" else "FIFO (vsync — frametime clamped to refresh)"});
        std.log.info("  frametime: avg {d:.3} ms  min {d:.3}  p50 {d:.2}  p99 {d:.2}  max {d:.3}", .{
            avg_ms, min_ms, p50, p99, max_ms,
        });
        std.log.info("  fps (avg): {d:.1}", .{fps_avg});
        std.log.info("  samples: {d} (skipped first {d} for warmup)", .{ self.total_samples, self.skipped });

        // Under FIFO the GPU finishes early and idles to vsync; the
        // p99/max metrics are effectively dropped-frame counts, not
        // workload cost. Under MAILBOX the histogram reflects real GPU
        // time. We report both gates either way; only --uncap is
        // load-bearing for "do we have headroom past the 5000 target."
        std.log.info("  gate: piece-types≤20 {s} | avg≤16.67ms (60fps) {s} | p99≤16.67ms {s}", .{
            if (gate_draws) "PASS" else "FAIL",
            if (gate_60fps) "PASS" else "FAIL",
            if (gate_p99) "PASS" else "FAIL",
        });
        if (!cli.uncap) {
            std.log.warn("  ^ FIFO mode: p99/max include vsync waits; rerun with --uncap for true GPU cost", .{});
        }
    }
};

const PerfWindow = struct {
    accum_ns: u64 = 0,
    frames: u32 = 0,
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,
    accum_dt: f32 = 0,
    skip_first: bool = true,

    /// Roll a frame-time sample into the 1-second window. Logs and
    /// resets when the window closes. `frame_ns` includes the entire
    /// CPU loop iteration — pollEvents, watcher poll, draw record +
    /// submit, present — which is what the gate cares about.
    fn tick(self: *PerfWindow, frame_ns: u64) void {
        if (self.skip_first) {
            self.skip_first = false;
            return;
        }
        self.accum_ns += frame_ns;
        self.frames += 1;
        if (frame_ns < self.min_ns) self.min_ns = frame_ns;
        if (frame_ns > self.max_ns) self.max_ns = frame_ns;
        self.accum_dt += @as(f32, @floatFromInt(frame_ns)) / @as(f32, std.time.ns_per_s);
        if (self.accum_dt >= 1.0) {
            const avg_ns = self.accum_ns / self.frames;
            std.log.info("perf: avg {d:.2} ms / min {d:.2} ms / max {d:.2} ms ({d} fps)", .{
                @as(f64, @floatFromInt(avg_ns)) / 1.0e6,
                @as(f64, @floatFromInt(self.min_ns)) / 1.0e6,
                @as(f64, @floatFromInt(self.max_ns)) / 1.0e6,
                std.time.ns_per_s / avg_ns,
            });
            self.accum_ns = 0;
            self.frames = 0;
            self.min_ns = std.math.maxInt(u64);
            self.max_ns = 0;
            self.accum_dt = 0;
        }
    }
};
