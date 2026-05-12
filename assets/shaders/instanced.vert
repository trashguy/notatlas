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
    mat4 model;    // column-major, rigid-ish; cull reads max-axis scale
    vec4 albedo;   // xyz = sRGB-ish color, w = unused (std430 padding)
    vec4 bounds;   // xyz = piece-local center, w = radius (cull transforms by model)
    uvec4 meta;    // x = piece_id (cull reads); yzw reserved
};

layout(set = 0, binding = 1, std430) readonly buffer Instances {
    Instance data[];
} instances;

// M10.3: visible-indices indirection. Compute culler writes the slot
// indices of visible instances into per-piece sub-ranges; the vertex
// shader looks up its bucket-base + ordinal here to get the original
// instance slot. Pre-M10.3 (or with `--no-cull` later) the CPU writes
// an identity mapping so the indirection is a no-op.
layout(set = 0, binding = 2, std430) readonly buffer VisibleIndices {
    uint data[];
} visible;

layout(location = 0) out vec3 v_world_pos;
layout(location = 1) out vec3 v_world_normal;
layout(location = 2) out vec3 v_albedo;

void main() {
    uint orig = visible.data[gl_InstanceIndex];
    Instance inst = instances.data[orig];

    vec4 wp = inst.model * vec4(i_pos, 1.0);
    v_world_pos = wp.xyz;
    v_world_normal = mat3(inst.model) * i_normal;
    v_albedo = inst.albedo.xyz;
    gl_Position = cam.proj * cam.view * wp;
}
