#version 450

// M4.3 wind-arrow fragment shader. Color encodes magnitude on a four-stop
// ramp (blue → cyan → yellow → red), so a glance at the field tells you
// where the gusts are without reading individual arrow lengths.

layout(location = 0) in float v_mag;
layout(location = 0) out vec4 o_color;

const float MAX_REF_MAG = 25.0;

vec3 magToColor(float t) {
    t = clamp(t, 0.0, 1.0);
    vec3 c0 = vec3(0.05, 0.10, 0.40); // dark blue (calm)
    vec3 c1 = vec3(0.10, 0.65, 0.85); // cyan
    vec3 c2 = vec3(0.95, 0.85, 0.30); // yellow
    vec3 c3 = vec3(0.95, 0.20, 0.15); // red (storm peaks)
    if (t < 0.33) return mix(c0, c1, t / 0.33);
    if (t < 0.66) return mix(c1, c2, (t - 0.33) / 0.33);
    return mix(c2, c3, (t - 0.66) / 0.34);
}

void main() {
    o_color = vec4(magToColor(v_mag / MAX_REF_MAG), 1.0);
}
