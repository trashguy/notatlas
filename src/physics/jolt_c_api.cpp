// Implementation of the C wrapper declared in jolt_c_api.h.
//
// Compiled with the same JPH_USE_* defines as the Jolt static library so
// header-defined SIMD intrinsics resolve identically; mismatched defines
// silently produce ABI-incompatible class layouts.

#include "jolt_c_api.h"

#include <Jolt/Jolt.h>
#include <Jolt/Core/Factory.h>
#include <Jolt/Core/JobSystemThreadPool.h>
#include <Jolt/Core/TempAllocator.h>
#include <Jolt/Physics/Body/BodyCreationSettings.h>
#include <Jolt/Physics/Body/BodyInterface.h>
#include <Jolt/Physics/Collision/Shape/BoxShape.h>
#include <Jolt/Physics/PhysicsSystem.h>
#include <Jolt/RegisterTypes.h>

#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <thread>

JPH_SUPPRESS_WARNINGS

using namespace JPH;
using namespace JPH::literals;

namespace {

// Two-layer scheme: NON_MOVING (terrain, anchored ships) vs MOVING (free
// rigid bodies). Sufficient for M3-M5; expand if M6+ needs e.g. a separate
// PROJECTILE layer.
namespace Layers {
constexpr ObjectLayer NON_MOVING = 0;
constexpr ObjectLayer MOVING = 1;
constexpr ObjectLayer NUM_LAYERS = 2;
}

namespace BroadPhaseLayers {
constexpr BroadPhaseLayer NON_MOVING(0);
constexpr BroadPhaseLayer MOVING(1);
constexpr uint NUM_LAYERS(2);
}

class BPLayerInterfaceImpl final : public BroadPhaseLayerInterface {
public:
    BPLayerInterfaceImpl() {
        m_table[Layers::NON_MOVING] = BroadPhaseLayers::NON_MOVING;
        m_table[Layers::MOVING] = BroadPhaseLayers::MOVING;
    }
    uint GetNumBroadPhaseLayers() const override { return BroadPhaseLayers::NUM_LAYERS; }
    BroadPhaseLayer GetBroadPhaseLayer(ObjectLayer layer) const override {
        JPH_ASSERT(layer < Layers::NUM_LAYERS);
        return m_table[layer];
    }
#if defined(JPH_EXTERNAL_PROFILE) || defined(JPH_PROFILE_ENABLED)
    const char* GetBroadPhaseLayerName(BroadPhaseLayer) const override { return "BP"; }
#endif

private:
    BroadPhaseLayer m_table[Layers::NUM_LAYERS];
};

class ObjectVsBroadPhaseLayerFilterImpl : public ObjectVsBroadPhaseLayerFilter {
public:
    bool ShouldCollide(ObjectLayer obj, BroadPhaseLayer bp) const override {
        switch (obj) {
        case Layers::NON_MOVING: return bp == BroadPhaseLayers::MOVING;
        case Layers::MOVING: return true;
        default: JPH_ASSERT(false); return false;
        }
    }
};

class ObjectLayerPairFilterImpl : public ObjectLayerPairFilter {
public:
    bool ShouldCollide(ObjectLayer a, ObjectLayer b) const override {
        switch (a) {
        case Layers::NON_MOVING: return b == Layers::MOVING;
        case Layers::MOVING: return true;
        default: JPH_ASSERT(false); return false;
        }
    }
};

void TraceImpl(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    char buf[1024];
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    std::fprintf(stderr, "jolt: %s\n", buf);
}

#ifdef JPH_ENABLE_ASSERTS
bool AssertFailedImpl(const char* expr, const char* msg, const char* file, uint line) {
    std::fprintf(stderr, "jolt assert: %s:%u: (%s) %s\n",
                 file, line, expr, msg ? msg : "");
    return true; // request breakpoint
}
#endif

std::atomic<int> g_init_count{0};

} // namespace

struct JoltSystem {
    BPLayerInterfaceImpl bp_layer;
    ObjectVsBroadPhaseLayerFilterImpl obj_vs_bp_filter;
    ObjectLayerPairFilterImpl obj_pair_filter;
    TempAllocatorImpl* temp_alloc;
    JobSystemThreadPool* jobs;
    PhysicsSystem* physics;
};

extern "C" {

void jolt_init(void) {
    if (g_init_count.fetch_add(1) > 0) return;
    RegisterDefaultAllocator();
    Trace = TraceImpl;
    JPH_IF_ENABLE_ASSERTS(AssertFailed = AssertFailedImpl;)
    Factory::sInstance = new Factory();
    RegisterTypes();
}

void jolt_shutdown(void) {
    if (g_init_count.fetch_sub(1) > 1) return;
    UnregisterTypes();
    delete Factory::sInstance;
    Factory::sInstance = nullptr;
}

JoltSystem* jolt_system_create(const JoltSystemDesc* desc) {
    auto* sys = new JoltSystem();

    const uint32_t temp_bytes = desc->temp_allocator_bytes ? desc->temp_allocator_bytes : (10u * 1024u * 1024u);
    sys->temp_alloc = new TempAllocatorImpl(temp_bytes);

    const uint32_t threads = desc->job_threads != 0
        ? desc->job_threads
        : (std::thread::hardware_concurrency() > 0 ? std::thread::hardware_concurrency() - 1 : 1);
    sys->jobs = new JobSystemThreadPool(cMaxPhysicsJobs, cMaxPhysicsBarriers, static_cast<int>(threads));

    sys->physics = new PhysicsSystem();
    sys->physics->Init(
        desc->max_bodies,
        desc->num_body_mutexes,
        desc->max_body_pairs,
        desc->max_contact_constraints,
        sys->bp_layer,
        sys->obj_vs_bp_filter,
        sys->obj_pair_filter);
    return sys;
}

void jolt_system_destroy(JoltSystem* sys) {
    if (!sys) return;
    delete sys->physics;
    delete sys->jobs;
    delete sys->temp_alloc;
    delete sys;
}

void jolt_system_step(JoltSystem* sys, float dt, int collision_steps) {
    sys->physics->Update(dt, collision_steps, sys->temp_alloc, sys->jobs);
}

void jolt_system_optimize_broad_phase(JoltSystem* sys) {
    sys->physics->OptimizeBroadPhase();
}

JoltBodyId jolt_body_create_box(JoltSystem* sys, const JoltBoxBodyDesc* desc) {
    BoxShapeSettings shape_settings(Vec3(desc->half_extents[0], desc->half_extents[1], desc->half_extents[2]));
    shape_settings.SetEmbedded();
    auto shape_result = shape_settings.Create();
    if (shape_result.HasError()) return JOLT_INVALID_BODY;
    ShapeRefC shape = shape_result.Get();

    const ObjectLayer layer = (desc->motion == JOLT_MOTION_STATIC) ? Layers::NON_MOVING : Layers::MOVING;
    BodyCreationSettings settings(
        shape,
        RVec3(desc->position[0], desc->position[1], desc->position[2]),
        Quat(desc->rotation[0], desc->rotation[1], desc->rotation[2], desc->rotation[3]),
        static_cast<EMotionType>(desc->motion),
        layer);
    settings.mFriction = desc->friction;
    settings.mRestitution = desc->restitution;
    if (desc->mass_override_kg > 0.0f) {
        settings.mOverrideMassProperties = EOverrideMassProperties::CalculateInertia;
        settings.mMassPropertiesOverride.mMass = desc->mass_override_kg;
    }

    BodyInterface& bi = sys->physics->GetBodyInterface();
    BodyID id = bi.CreateAndAddBody(settings, desc->activate ? EActivation::Activate : EActivation::DontActivate);
    if (id.IsInvalid()) return JOLT_INVALID_BODY;
    return id.GetIndexAndSequenceNumber();
}

void jolt_body_destroy(JoltSystem* sys, JoltBodyId id) {
    BodyID bid(id);
    BodyInterface& bi = sys->physics->GetBodyInterface();
    bi.RemoveBody(bid);
    bi.DestroyBody(bid);
}

bool jolt_body_get_position(JoltSystem* sys, JoltBodyId id, float out[3]) {
    BodyID bid(id);
    if (bid.IsInvalid()) return false;
    RVec3 p = sys->physics->GetBodyInterface().GetCenterOfMassPosition(bid);
    out[0] = static_cast<float>(p.GetX());
    out[1] = static_cast<float>(p.GetY());
    out[2] = static_cast<float>(p.GetZ());
    return true;
}

bool jolt_body_get_rotation(JoltSystem* sys, JoltBodyId id, float out[4]) {
    BodyID bid(id);
    if (bid.IsInvalid()) return false;
    Quat q = sys->physics->GetBodyInterface().GetRotation(bid);
    out[0] = q.GetX();
    out[1] = q.GetY();
    out[2] = q.GetZ();
    out[3] = q.GetW();
    return true;
}

bool jolt_body_get_linear_velocity(JoltSystem* sys, JoltBodyId id, float out[3]) {
    BodyID bid(id);
    if (bid.IsInvalid()) return false;
    Vec3 v = sys->physics->GetBodyInterface().GetLinearVelocity(bid);
    out[0] = v.GetX();
    out[1] = v.GetY();
    out[2] = v.GetZ();
    return true;
}

bool jolt_body_get_angular_velocity(JoltSystem* sys, JoltBodyId id, float out[3]) {
    BodyID bid(id);
    if (bid.IsInvalid()) return false;
    Vec3 v = sys->physics->GetBodyInterface().GetAngularVelocity(bid);
    out[0] = v.GetX();
    out[1] = v.GetY();
    out[2] = v.GetZ();
    return true;
}

void jolt_body_set_linear_velocity(JoltSystem* sys, JoltBodyId id, const float vel[3]) {
    BodyID bid(id);
    if (bid.IsInvalid()) return;
    sys->physics->GetBodyInterface().SetLinearVelocity(bid, Vec3(vel[0], vel[1], vel[2]));
}

void jolt_body_set_angular_velocity(JoltSystem* sys, JoltBodyId id, const float vel[3]) {
    BodyID bid(id);
    if (bid.IsInvalid()) return;
    sys->physics->GetBodyInterface().SetAngularVelocity(bid, Vec3(vel[0], vel[1], vel[2]));
}

void jolt_body_add_force_at_point(
    JoltSystem* sys,
    JoltBodyId id,
    const float force[3],
    const float point[3]) {
    BodyID bid(id);
    sys->physics->GetBodyInterface().AddForce(
        bid,
        Vec3(force[0], force[1], force[2]),
        RVec3(point[0], point[1], point[2]));
}

} // extern "C"
