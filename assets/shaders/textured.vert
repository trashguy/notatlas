#version 450

// M14.2c textured-cube vertex shader. Mirrors box.vert but adds a
// vec2 UV attribute → forwarded to fragment for albedo sampling.
//
// `push.model` is rigid (no scale), so the upper-left 3×3 transforms
// normals correctly without an inverse-transpose. Same camera UBO
// shape as box.vert (set=0 binding=0 = view/proj/eye).

layout(location = 0) in vec3 i_pos;
layout(location = 1) in vec3 i_normal;
layout(location = 2) in vec2 i_uv;

layout(set = 0, binding = 0) uniform Camera {
    mat4 view;
    mat4 proj;
    vec4 eye;
} cam;

layout(push_constant) uniform Push {
    mat4 model;
    vec4 tint; // multiplicative tint over the sampled albedo (1,1,1,1 = pass-through)
} push;

layout(location = 0) out vec3 v_world_pos;
layout(location = 1) out vec3 v_world_normal;
layout(location = 2) out vec2 v_uv;
layout(location = 3) out vec3 v_tint;

void main() {
    vec4 wp = push.model * vec4(i_pos, 1.0);
    v_world_pos = wp.xyz;
    v_world_normal = mat3(push.model) * i_normal;
    v_uv = i_uv;
    v_tint = push.tint.xyz;
    gl_Position = cam.proj * cam.view * wp;
}
