//! Zig bindings for the Jolt C wrapper (`src/physics/jolt_c_api.h`). Plain
//! `extern fn` mirror of the C ABI plus idiomatic wrappers (`System`,
//! `BoxBodyConfig`) on top so callers don't deal with raw handles.
//!
//! Linkage: the C symbols live in libJolt.a (the wrapper.cpp is bundled
//! into the same static library as the upstream Jolt sources). The build
//! wires `linkLibrary(jolt)` on whatever module imports this module.

const std = @import("std");

pub const SystemHandle = opaque {};
pub const BodyId = u32;
pub const invalid_body: BodyId = 0xFFFFFFFF;

pub const MotionType = enum(c_int) {
    static = 0,
    kinematic = 1,
    dynamic = 2,
};

/// Mirrors C `JoltSystemDesc`. Fields with default 0 in the desc fall back
/// to Jolt-side defaults (see jolt_c_api.cpp).
pub const SystemDesc = extern struct {
    max_bodies: u32,
    max_body_pairs: u32,
    max_contact_constraints: u32,
    num_body_mutexes: u32,
    temp_allocator_bytes: u32,
    job_threads: u32,
};

pub const BoxBodyDesc = extern struct {
    half_extents: [3]f32,
    position: [3]f32,
    rotation: [4]f32, // quaternion x,y,z,w
    motion: MotionType,
    activate: bool,
    friction: f32,
    restitution: f32,
    mass_override_kg: f32,
};

// ---------- Raw C ABI ----------

pub const c = struct {
    pub extern fn jolt_init() void;
    pub extern fn jolt_shutdown() void;

    pub extern fn jolt_system_create(desc: *const SystemDesc) ?*SystemHandle;
    pub extern fn jolt_system_destroy(sys: ?*SystemHandle) void;
    pub extern fn jolt_system_step(sys: *SystemHandle, dt: f32, collision_steps: c_int) void;
    pub extern fn jolt_system_optimize_broad_phase(sys: *SystemHandle) void;

    pub extern fn jolt_body_create_box(sys: *SystemHandle, desc: *const BoxBodyDesc) BodyId;
    pub extern fn jolt_body_destroy(sys: *SystemHandle, id: BodyId) void;

    pub extern fn jolt_body_get_position(sys: *SystemHandle, id: BodyId, out: *[3]f32) bool;
    pub extern fn jolt_body_get_rotation(sys: *SystemHandle, id: BodyId, out: *[4]f32) bool;
    pub extern fn jolt_body_get_linear_velocity(sys: *SystemHandle, id: BodyId, out: *[3]f32) bool;
    pub extern fn jolt_body_get_angular_velocity(sys: *SystemHandle, id: BodyId, out: *[3]f32) bool;

    pub extern fn jolt_body_add_force_at_point(
        sys: *SystemHandle,
        id: BodyId,
        force: *const [3]f32,
        point: *const [3]f32,
    ) void;
};

// ---------- Idiomatic Zig wrappers ----------

/// Call once at process start, once at shutdown. The C side is reference-
/// counted; nested init/shutdown pairs are safe.
pub fn init() void {
    c.jolt_init();
}

pub fn shutdown() void {
    c.jolt_shutdown();
}

pub const SystemConfig = struct {
    max_bodies: u32 = 1024,
    max_body_pairs: u32 = 1024,
    max_contact_constraints: u32 = 1024,
    num_body_mutexes: u32 = 0,
    temp_allocator_bytes: u32 = 10 * 1024 * 1024,
    job_threads: u32 = 0,
};

pub const System = struct {
    handle: *SystemHandle,

    pub fn init(cfg: SystemConfig) !System {
        const desc: SystemDesc = .{
            .max_bodies = cfg.max_bodies,
            .max_body_pairs = cfg.max_body_pairs,
            .max_contact_constraints = cfg.max_contact_constraints,
            .num_body_mutexes = cfg.num_body_mutexes,
            .temp_allocator_bytes = cfg.temp_allocator_bytes,
            .job_threads = cfg.job_threads,
        };
        const handle = c.jolt_system_create(&desc) orelse return error.JoltSystemCreateFailed;
        return .{ .handle = handle };
    }

    pub fn deinit(self: *System) void {
        c.jolt_system_destroy(self.handle);
        self.handle = undefined;
    }

    pub fn step(self: *System, dt: f32, collision_steps: u32) void {
        c.jolt_system_step(self.handle, dt, @intCast(collision_steps));
    }

    pub fn optimizeBroadPhase(self: *System) void {
        c.jolt_system_optimize_broad_phase(self.handle);
    }

    pub fn createBox(self: *System, cfg: BoxBodyConfig) !BodyId {
        const desc: BoxBodyDesc = .{
            .half_extents = cfg.half_extents,
            .position = cfg.position,
            .rotation = cfg.rotation,
            .motion = cfg.motion,
            .activate = cfg.activate,
            .friction = cfg.friction,
            .restitution = cfg.restitution,
            .mass_override_kg = cfg.mass_override_kg,
        };
        const id = c.jolt_body_create_box(self.handle, &desc);
        if (id == invalid_body) return error.JoltBodyCreateFailed;
        return id;
    }

    pub fn destroyBody(self: *System, id: BodyId) void {
        c.jolt_body_destroy(self.handle, id);
    }

    pub fn getPosition(self: *System, id: BodyId) ?[3]f32 {
        var out: [3]f32 = undefined;
        if (!c.jolt_body_get_position(self.handle, id, &out)) return null;
        return out;
    }

    pub fn getRotation(self: *System, id: BodyId) ?[4]f32 {
        var out: [4]f32 = undefined;
        if (!c.jolt_body_get_rotation(self.handle, id, &out)) return null;
        return out;
    }

    pub fn getLinearVelocity(self: *System, id: BodyId) ?[3]f32 {
        var out: [3]f32 = undefined;
        if (!c.jolt_body_get_linear_velocity(self.handle, id, &out)) return null;
        return out;
    }

    pub fn getAngularVelocity(self: *System, id: BodyId) ?[3]f32 {
        var out: [3]f32 = undefined;
        if (!c.jolt_body_get_angular_velocity(self.handle, id, &out)) return null;
        return out;
    }

    pub fn addForceAtPoint(self: *System, id: BodyId, force: [3]f32, point: [3]f32) void {
        c.jolt_body_add_force_at_point(self.handle, id, &force, &point);
    }
};

pub const BoxBodyConfig = struct {
    half_extents: [3]f32,
    position: [3]f32 = .{ 0, 0, 0 },
    rotation: [4]f32 = .{ 0, 0, 0, 1 }, // identity (x,y,z,w)
    motion: MotionType = .dynamic,
    activate: bool = true,
    friction: f32 = 0.2,
    restitution: f32 = 0.0,
    /// 0 = derive from shape volume × 1000 kg/m³ (water density default).
    /// For ships this will be set explicitly in `data/ships/<hull>.yaml`.
    mass_override_kg: f32 = 0,
};
