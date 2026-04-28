#version 450

// M3.2 debug box vertex shader. Position + normal in object space; output
// world-space pos+normal so the fragment can do per-pixel Lambert against
// the same SUN_DIR the water pass uses.
//
// `push.model` is rigid (Jolt rotation+translation only, no scale), so the
// upper-left 3×3 transforms normals correctly without an inverse-transpose.

layout(location = 0) in vec3 i_pos;
layout(location = 1) in vec3 i_normal;

layout(set = 0, binding = 0) uniform Camera {
    mat4 view;
    mat4 proj;
    vec4 eye;
} cam;

layout(push_constant) uniform Push {
    mat4 model;
} push;

layout(location = 0) out vec3 v_world_pos;
layout(location = 1) out vec3 v_world_normal;

void main() {
    vec4 wp = push.model * vec4(i_pos, 1.0);
    v_world_pos = wp.xyz;
    v_world_normal = mat3(push.model) * i_normal;
    gl_Position = cam.proj * cam.view * wp;
}
