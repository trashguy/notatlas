#version 450

// notatlas sky pass. Fullscreen-triangle shader that paints the background
// for every pixel: atmosphere + sun for rays pointing up, fog gradient for
// the underwater case. Runs FIRST in the frame, with depthTest=FALSE and
// depthWrite=FALSE — the pass writes color only, leaves the depth buffer
// at its cleared value (1.0).
//
// This was extracted from `water.frag` to fix the waterline depth flicker:
// `water.frag` previously wrote `gl_FragDepth = 1.0` for sky pixels, which
// tied with the cleared depth buffer (also 1.0) under LESS_OR_EQUAL. Far
// wave crests also raymarched to depth ≈ 1.0; the tie-break flipped per
// frame, producing horizon-line shimmer. With sky pulled out:
//   - Sky paints first (no depth).
//   - Water paints later with strict LESS — only writes where it actually
//     hits a surface, `discard` on no-hit, so no more 1.0-ties.
//   - Rasterized geometry (cubes, ships) still passes the LESS test in
//     between, correctly occluding far waves.
//
// Atmosphere / sun / ACES tonemap functions are adapted from afl_ext's
// "Ocean" shadertoy (https://www.shadertoy.com/view/MdXyzX, MIT). Wave
// kernel matches the deterministic CPU port in wave_query.zig — only used
// here to detect whether the camera is currently below a wave crest.

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 o_color;

layout(set = 0, binding = 0) uniform Camera {
    mat4 view;
    mat4 proj;
    vec4 eye; // xyz = world-space camera position
} cam;

layout(set = 0, binding = 1) uniform Waves {
    vec4 a;       // (time, drag_multiplier, amplitude_m, wave_scale_m)
    vec4 b;       // (frequency_mult, base_time_mult, time_mult, weight_decay)
    vec4 c;       // (initial_iter, iterations_as_float, _, _)
} waves;

layout(set = 0, binding = 2) uniform OceanParams {
    vec4 shallow_color; // rgb + 0
    vec4 deep_color;
    vec4 fog_color;
    vec4 foam;          // (crest_threshold, crest_width, fog_density, _pad)
} ocean;

const vec3 SUN_DIR = normalize(vec3(-0.0773502691896258, 0.6, 0.5773502691896258));

vec3 extra_cheap_atmosphere(vec3 raydir, vec3 sundir) {
    sundir.y = max(sundir.y, -0.07);
    float special_trick = 1.0 / (raydir.y * 1.0 + 0.1);
    float special_trick2 = 1.0 / (sundir.y * 11.0 + 1.0);
    float raysundt = pow(abs(dot(sundir, raydir)), 2.0);
    float sundt = pow(max(0.0, dot(sundir, raydir)), 8.0);
    float mymie = sundt * special_trick * 0.2;
    vec3 suncolor = mix(vec3(1.0), max(vec3(0.0), vec3(1.0) - vec3(5.5, 13.0, 22.4) / 22.4), special_trick2);
    vec3 bluesky = vec3(5.5, 13.0, 22.4) / 22.4 * suncolor;
    vec3 bluesky2 = max(vec3(0.0), bluesky - vec3(5.5, 13.0, 22.4) * 0.002 * (special_trick + -6.0 * sundir.y * sundir.y));
    bluesky2 *= special_trick * (0.24 + raysundt * 0.24);
    return bluesky2 * (1.0 + 1.0 * pow(1.0 - raydir.y, 3.0));
}

vec3 getAtmosphere(vec3 dir) {
    return extra_cheap_atmosphere(dir, SUN_DIR) * 0.5;
}

float getSun(vec3 dir) {
    return pow(max(0.0, dot(dir, SUN_DIR)), 720.0) * 210.0;
}

vec3 aces_tonemap(vec3 color) {
    mat3 m1 = mat3(
        0.59719, 0.07600, 0.02840,
        0.35458, 0.90834, 0.13383,
        0.04823, 0.01566, 0.83777);
    mat3 m2 = mat3(
        1.60475, -0.10208, -0.00327,
       -0.53108,  1.10813, -0.07276,
       -0.07367, -0.00605,  1.07602);
    vec3 v = m1 * color;
    vec3 a = v * (v + 0.0245786) - 0.000090537;
    vec3 b = v * (0.983729 * v + 0.4329510) + 0.238081;
    return pow(clamp(m2 * (a / b), 0.0, 1.0), vec3(1.0 / 2.2));
}

// Wave kernel — only needed to check whether the camera is currently
// below a local wave crest (the underwater branch). Ported from
// wave_query.zig in lockstep with water.frag.
vec2 wavedx(vec2 pos, vec2 dir, float frequency, float timeshift) {
    float x = dot(dir, pos) * frequency + timeshift;
    float wave = exp(sin(x) - 1.0);
    float dx = wave * cos(x);
    return vec2(wave, -dx);
}

float getWavesNorm(vec2 pos, uint iterations) {
    if (iterations == 0u) return 0.5;
    float drag_mult    = waves.a.y;
    float freq_mult    = waves.b.x;
    float base_time    = waves.b.y;
    float time_mult    = waves.b.z;
    float weight_decay = waves.b.w;
    float initial_iter = waves.c.x;
    float t            = waves.a.x;

    vec2 p = pos;
    float iter = initial_iter;
    float freq = 1.0;
    float tm = base_time;
    float weight = 1.0;
    float sumv = 0.0;
    float sumw = 0.0;
    float phase_shift = length(p) * 0.1;
    for (uint i = 0u; i < iterations; ++i) {
        vec2 dir = vec2(sin(iter), cos(iter));
        vec2 res = wavedx(p, dir, freq, t * tm + phase_shift);
        p += dir * res.y * weight * drag_mult;
        sumv += res.x * weight;
        sumw += weight;
        weight *= weight_decay;
        freq *= freq_mult;
        tm *= time_mult;
        iter += 1232.399963;
    }
    return sumv / sumw;
}

float waveHeight(vec2 world_xz, uint iterations) {
    float scale = waves.a.w;
    float amp = waves.a.z;
    vec2 norm = world_xz / scale;
    float h = getWavesNorm(norm, iterations);
    return (h * 2.0 - 1.0) * amp;
}

vec3 viewRayFromUv(vec2 uv) {
    vec2 ndc = uv * 2.0 - 1.0;
    mat4 inv_vp = inverse(cam.proj * cam.view);
    vec4 world = inv_vp * vec4(ndc, 1.0, 1.0);
    return normalize(world.xyz / world.w - cam.eye.xyz);
}

void main() {
    vec3 ray = viewRayFromUv(v_uv);
    vec3 eye = cam.eye.xyz;

    // Underwater: camera below the local surface (not just mean sea
    // level, since a crest can rise above the camera). Paint fog with
    // a brightness gradient along ray.y so the image still has "up".
    uint iter_eye = uint(waves.c.y);
    float eye_h = waveHeight(eye.xz, iter_eye);
    if (eye.y < eye_h) {
        float up = max(0.0, ray.y);
        vec3 col = ocean.fog_color.rgb * (0.6 + 0.8 * up);
        o_color = vec4(aces_tonemap(col * 2.0), 1.0);
        return;
    }

    // Sky: ray points up. Atmosphere + sun.
    if (ray.y >= 0.0) {
        vec3 col = getAtmosphere(ray) + vec3(getSun(ray));
        o_color = vec4(aces_tonemap(col * 2.0), 1.0);
        return;
    }

    // Ray points down at the water surface — let the water pass paint
    // these pixels. We still write a sky color as a fallback for the
    // case where water's `discard` fires (raymarch miss); the depth
    // buffer is unmodified so water can still win when it does hit.
    vec3 col = getAtmosphere(ray) + vec3(getSun(ray));
    o_color = vec4(aces_tonemap(col * 2.0), 1.0);
}
