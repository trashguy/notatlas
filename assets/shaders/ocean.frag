#version 450

// M2.3: anti-aliased grid pattern over a flat sea-colored plane. The grid
// makes the tessellation visible and confirms that the perspective
// projection is sane. M2.5 replaces this with real water shading.

layout(location = 0) in vec3 v_world;
layout(location = 0) out vec4 o_color;

const float CELL_M = 4.0;            // grid spacing in world meters
const vec3  SEA   = vec3(0.04, 0.16, 0.30);
const vec3  LINE  = vec3(0.20, 0.55, 0.70);

void main() {
    vec2 p = v_world.xz / CELL_M;
    vec2 g = abs(fract(p - 0.5) - 0.5) / fwidth(p);
    float line = min(g.x, g.y);
    float strength = 1.0 - min(line, 1.0);
    o_color = vec4(mix(SEA, LINE, strength), 1.0);
}
