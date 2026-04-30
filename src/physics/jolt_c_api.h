// Thin C wrapper around Jolt Physics, exposing only the surface notatlas
// uses. Designed for direct Zig FFI consumption — no Zig glue logic in
// here.
//
// API ABI is C; layer definitions, factories, and other Jolt internals are
// hidden behind opaque handles. The wrapper subclasses the three required
// Jolt virtual filters internally with a fixed two-layer scheme
// (NON_MOVING / MOVING) sufficient for ships+terrain.
//
// Threading: jolt_init / jolt_shutdown must be called from a single thread
// at process start/end. JoltSystem methods take `*JoltSystem` and are not
// internally synchronized — callers serialize their own access.

#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Global Jolt registration. Call once before any system-create, and call
// shutdown after all systems are destroyed. Idempotent.
void jolt_init(void);
void jolt_shutdown(void);

typedef struct JoltSystem JoltSystem;
typedef uint32_t JoltBodyId; // 0xFFFFFFFF means invalid

#define JOLT_INVALID_BODY 0xFFFFFFFFu

typedef enum {
    JOLT_MOTION_STATIC = 0,    // matches JPH::EMotionType::Static
    JOLT_MOTION_KINEMATIC = 1, // ::Kinematic
    JOLT_MOTION_DYNAMIC = 2,   // ::Dynamic
} JoltMotionType;

// Per-system capacity. Single source for max bodies / pairs / contact
// constraints; tuneable as M3+ scales up.
typedef struct {
    uint32_t max_bodies;
    uint32_t max_body_pairs;
    uint32_t max_contact_constraints;
    uint32_t num_body_mutexes; // 0 = Jolt default
    uint32_t temp_allocator_bytes; // pre-allocated per-step scratch
    uint32_t job_threads; // 0 = hardware concurrency - 1
} JoltSystemDesc;

JoltSystem* jolt_system_create(const JoltSystemDesc* desc);
void jolt_system_destroy(JoltSystem* sys);

// Step the simulation. `collision_steps` typically 1 at 60Hz; raise for
// larger dt or higher integration accuracy.
void jolt_system_step(JoltSystem* sys, float dt, int collision_steps);

// Optional: Jolt recommends calling this once after bulk-loading static
// bodies and before the first step. Skip during runtime.
void jolt_system_optimize_broad_phase(JoltSystem* sys);

typedef struct {
    float half_extents[3]; // box half-sizes in meters
    float position[3];     // world-space center
    float rotation[4];     // quaternion x,y,z,w (Jolt order)
    JoltMotionType motion;
    bool activate;         // wake the body on creation
    float friction;        // 0.2 is Jolt default
    float restitution;     // 0.0 = no bounce
    // Mass override; 0 = derive from shape volume * density (1000 kg/m³).
    float mass_override_kg;
} JoltBoxBodyDesc;

JoltBodyId jolt_body_create_box(JoltSystem* sys, const JoltBoxBodyDesc* desc);
void jolt_body_destroy(JoltSystem* sys, JoltBodyId id);

// Pose readout. `out_pos` / `out_quat` written in the same conventions as
// the create desc. Returns false if the id is invalid.
bool jolt_body_get_position(JoltSystem* sys, JoltBodyId id, float out_pos[3]);
bool jolt_body_get_rotation(JoltSystem* sys, JoltBodyId id, float out_quat[4]);
bool jolt_body_get_linear_velocity(JoltSystem* sys, JoltBodyId id, float out_vel[3]);
bool jolt_body_get_angular_velocity(JoltSystem* sys, JoltBodyId id, float out_vel[3]);

// Velocity setters. Counterparts to the getters above. Used at body
// (re)spawn — e.g. disembarking player inheriting the ship's velocity at
// the lever arm so they don't drop straight down off a moving deck.
// Calling these on a sleeping body is safe (Jolt activates as needed).
void jolt_body_set_linear_velocity(JoltSystem* sys, JoltBodyId id, const float vel[3]);
void jolt_body_set_angular_velocity(JoltSystem* sys, JoltBodyId id, const float vel[3]);

// Force application (Newtons). For buoyancy at M3.3: sample wave height at
// each hull point, compute Archimedes force, call this with `point` =
// world-space hull-point position.
void jolt_body_add_force_at_point(
    JoltSystem* sys,
    JoltBodyId id,
    const float force[3],
    const float point[3]);

#ifdef __cplusplus
}
#endif
