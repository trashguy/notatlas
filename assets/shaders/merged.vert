#version 450

// M11.1 merged-anchorage vertex shader.
//
// Each vertex was pre-baked into world space at merge time, so the model
// transform is identity here — pos is already in world space and the
// fragment shader's lighting + fog math (shared with instanced.frag)
// works directly.
//
// Per-vertex albedo is baked in so one drawIndexed handles N piece
// colors without per-instance state. The merged-mesh path trades vertex
// memory for draw-call count — a 500-piece anchorage at far-LOD becomes
// one draw call instead of 500.

layout(location = 0) in vec3 i_pos;
layout(location = 1) in vec3 i_normal;
layout(location = 2) in vec3 i_albedo;

layout(set = 0, binding = 0) uniform Camera {
    mat4 view;
    mat4 proj;
    vec4 eye;
} cam;

layout(location = 0) out vec3 v_world_pos;
layout(location = 1) out vec3 v_world_normal;
layout(location = 2) out vec3 v_albedo;

void main() {
    v_world_pos = i_pos;
    v_world_normal = i_normal;
    v_albedo = i_albedo;
    gl_Position = cam.proj * cam.view * vec4(i_pos, 1.0);
}
