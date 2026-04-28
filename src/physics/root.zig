//! Public surface of the `physics` module. Combines:
//!   - Jolt FFI bindings (`jolt.zig`) — rigid body simulation
//!   - Buoyancy (`buoyancy.zig`) — Archimedes force application against
//!     the deterministic wave-query heightfield
//!
//! The buoyancy layer sits on top of Jolt: it queries body pose, computes
//! per-sample-point forces, and applies them via the Jolt body interface.

pub const jolt = @import("jolt.zig");
pub const buoyancy = @import("buoyancy.zig");

pub const System = jolt.System;
pub const SystemConfig = jolt.SystemConfig;
pub const BodyId = jolt.BodyId;
pub const BoxBodyConfig = jolt.BoxBodyConfig;
pub const MotionType = jolt.MotionType;
pub const init = jolt.init;
pub const shutdown = jolt.shutdown;

pub const Buoyancy = buoyancy.Buoyancy;
pub const BuoyancyConfig = buoyancy.Config;
