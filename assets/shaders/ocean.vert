#version 450

// M2.3: pass through. World-space position is the vertex position; we
// transform straight to clip space. M2.4 will replace this body with the
// Gerstner displacement port from src/wave_query.zig.

layout(location = 0) in vec3 in_pos;

layout(set = 0, binding = 0) uniform Camera {
    mat4 view;
    mat4 proj;
} cam;

layout(location = 0) out vec3 v_world;

void main() {
    v_world = in_pos;
    gl_Position = cam.proj * cam.view * vec4(in_pos, 1.0);
}
