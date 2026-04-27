#version 450

// M2.4: Gerstner displacement, ported line-for-line from
// `waveDisplacement` in src/wave_query.zig. Phases (`phi`) are precomputed
// CPU-side and shipped in the wave UBO — splitmix64 has no GLSL equivalent.
//
// Output `v_world` is the *displaced* world position so the fragment shader
// can use it for shading and the existing M2.3 grid (which warps with the
// surface — that's the visualization).

layout(location = 0) in vec3 in_pos;

layout(set = 0, binding = 0) uniform Camera {
    mat4 view;
    mat4 proj;
} cam;

const int MAX_COMPONENTS = 8;
struct Component {
    vec4 dir_amp_steep;       // (dir.x, dir.z, amplitude, steepness)
    vec4 wavelen_speed_phi;   // (wavelength, speed, phi, _pad)
};
layout(set = 0, binding = 1) uniform Waves {
    int   count;
    float time;
    vec2  _pad0;
    Component components[MAX_COMPONENTS];
} waves;

layout(location = 0) out vec3 v_world;

const float TAU = 6.28318530717958647692;

void main() {
    float dx = 0.0;
    float dy = 0.0;
    float dz = 0.0;

    for (int i = 0; i < waves.count; ++i) {
        Component c = waves.components[i];
        vec2 dir = c.dir_amp_steep.xy;
        float A   = c.dir_amp_steep.z;
        float Q   = c.dir_amp_steep.w;
        float wavelength = c.wavelen_speed_phi.x;
        float speed      = c.wavelen_speed_phi.y;
        float phi        = c.wavelen_speed_phi.z;

        float k     = TAU / wavelength;
        float omega = speed * k;
        float theta = k * (dir.x * in_pos.x + dir.y * in_pos.z) - omega * waves.time + phi;
        float ct    = cos(theta);
        float st    = sin(theta);
        float qa    = Q * A;

        dx += dir.x * qa * ct;
        dz += dir.y * qa * ct;
        dy += A * st;
    }

    vec3 world = vec3(in_pos.x + dx, dy, in_pos.z + dz);
    v_world = world;
    gl_Position = cam.proj * cam.view * vec4(world, 1.0);
}
