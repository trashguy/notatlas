#version 450

// M4.3 wind-arrow vertex shader. 9 hard-coded arrow vertices laid out in
// the XY plane (+X = arrow direction). Per-instance attributes carry
// world-space ground position and the wind vector at that point. The
// shader rotates the local arrow shape to align with wind direction,
// scales by magnitude (clamped so even calm cells stay visible), and
// projects via the shared camera UBO.

layout(location = 0) in vec2 i_pos_xz;
layout(location = 1) in vec2 i_wind_xz;

layout(set = 0, binding = 0) uniform Camera {
    mat4 view;
    mat4 proj;
    vec4 eye;
} cam;

layout(location = 0) out float v_mag;

const vec2 ARROW[9] = vec2[](
    // Stem rectangle (2 triangles, 6 verts).
    vec2(-0.40, -0.05),
    vec2( 0.30, -0.05),
    vec2(-0.40,  0.05),
    vec2( 0.30, -0.05),
    vec2( 0.30,  0.05),
    vec2(-0.40,  0.05),
    // Arrowhead (1 triangle, 3 verts).
    vec2( 0.30, -0.18),
    vec2( 0.50,  0.00),
    vec2( 0.30,  0.18)
);

const float ARROW_SCALE_M = 35.0;  // length at unit length-fraction
const float ARROW_HEIGHT_M = 60.0; // y above sea level — well above the
                                   // camera eye line so the field reads
                                   // as a high-altitude bird's-eye viz,
                                   // not a stripe pasted onto the horizon
const float MAX_REF_MAG = 25.0;    // mag at which the length is clamped to 1
const float MIN_LEN_FRAC = 0.25;   // arrows always render at ≥ this fraction

void main() {
    vec2 local = ARROW[gl_VertexIndex];

    float mag = length(i_wind_xz);
    float len_frac = max(MIN_LEN_FRAC, min(1.0, mag / MAX_REF_MAG));

    // Unit wind direction; degenerate to +X if magnitude is effectively
    // zero (an arrow at calm cells points east, which is fine for debug).
    vec2 dir = (mag > 1e-3) ? i_wind_xz / mag : vec2(1.0, 0.0);

    // 2D rotation: send local +X onto `dir`, and local +Y onto its
    // 90°-CCW perpendicular `(-dir.y, dir.x)`.
    vec2 rotated = vec2(
        dir.x * local.x - dir.y * local.y,
        dir.y * local.x + dir.x * local.y
    );
    rotated *= ARROW_SCALE_M * len_frac;

    vec3 world_pos = vec3(
        i_pos_xz.x + rotated.x,
        ARROW_HEIGHT_M,
        i_pos_xz.y + rotated.y
    );

    gl_Position = cam.proj * cam.view * vec4(world_pos, 1.0);
    v_mag = mag;
}
