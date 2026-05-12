#version 450

// M10.1 GPU-driven instancing vertex shader.
//
// Per-vertex input (pos+normal) is identical to box.vert; what changes is
// where the per-instance transform/albedo come from. Box's push constant is
// gone — model + albedo (and bounds, for later compute culling) live in an
// SSBO indexed by gl_InstanceIndex. One drawIndexed call covers a whole
// bucket of instances of the same piece type, with firstInstance pointing
// at the bucket's base row.
//
// Output channels match box.frag's input, so the fragment shader is shared
// verbatim (instanced.frag is byte-equivalent to box.frag).

layout(location = 0) in vec3 i_pos;
layout(location = 1) in vec3 i_normal;

layout(set = 0, binding = 0) uniform Camera {
    mat4 view;
    mat4 proj;
    vec4 eye;
} cam;

struct Instance {
    mat4 model;    // column-major, rigid (no scale) — same as box.vert.push.model
    vec4 albedo;   // xyz = sRGB-ish color, w = unused (std430 padding)
    vec4 bounds;   // xyz = world-space center, w = radius — for M10.3 cull
};

layout(set = 0, binding = 1, std430) readonly buffer Instances {
    Instance data[];
} instances;

layout(location = 0) out vec3 v_world_pos;
layout(location = 1) out vec3 v_world_normal;
layout(location = 2) out vec3 v_albedo;

void main() {
    Instance inst = instances.data[gl_InstanceIndex];

    vec4 wp = inst.model * vec4(i_pos, 1.0);
    v_world_pos = wp.xyz;
    v_world_normal = mat3(inst.model) * i_normal;
    v_albedo = inst.albedo.xyz;
    gl_Position = cam.proj * cam.view * wp;
}
