#version 450

// notatlas water surface pass. Surface-only after the sky-pass split
// (2026-05-14, see issue_waterline_depth_flicker.md). Previously this
// shader also painted sky + underwater; both moved to sky.frag, which
// runs first with depth disabled. This file now ONLY shades raymarched
// water-surface hits and `discard`s no-hit fragments.
//
// Render order: sky → opaque geometry → water → arrows. Water pipeline
// uses strict LESS (was LESS_OR_EQUAL), safe now that nothing else
// writes depth=1.0 to fragments we care about.
//
// Atmosphere / sun / ACES tonemap functions adapted from afl_ext's
// "Ocean" shadertoy (https://www.shadertoy.com/view/MdXyzX, MIT). Wave
// kernel matches the deterministic CPU port in wave_query.zig so
// server-side buoyancy and client-side visuals agree at every (x, z, t).

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

const float TAU = 6.28318530717958647692;

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

// ---------------- wave kernel (port of wave_query.zig) ----------------

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

// ---------------- raymarch + normal ----------------

// Two-phase intersect: sphere-trace step until bracket, then 6 bisection
// halvings. Returns -1.0 on miss (caller `discard`s); positive distance
// on hit. See `src/wave_query.zig` for the same kernel CPU-side.
float raymarchWater(vec3 origin, vec3 ray, float amp) {
    float t_high = (amp - origin.y) / ray.y;
    float t_low = (-amp - origin.y) / ray.y;
    float t_start = max(0.0, t_high);
    float t_end = max(t_start + 0.001, t_low);
    vec3 start = origin + ray * t_start;
    vec3 end = origin + ray * t_end;

    vec3 prev = start;
    vec3 pos = start;
    vec3 dir = normalize(end - start);
    float total_dist = distance(start, end);
    float vy = max(0.0001, -dir.y);

    uint iterations = uint(waves.c.y);
    bool hit = false;
    for (uint i = 0u; i < 64u; ++i) {
        float h = waveHeight(pos.xz, iterations);
        if (h + 0.01 > pos.y) {
            hit = true;
            break;
        }
        prev = pos;
        pos += dir * ((pos.y - h) / vy) * 0.5;
        if (distance(start, pos) > total_dist) break;
    }
    if (!hit) return -1.0;

    for (uint i = 0u; i < 6u; ++i) {
        vec3 mid = 0.5 * (prev + pos);
        float h = waveHeight(mid.xz, iterations);
        if (mid.y - h > 0.0) prev = mid; else pos = mid;
    }
    return distance(0.5 * (prev + pos), origin);
}

vec3 waveNormal(vec2 world_xz, float eps_m, uint iterations) {
    float h_c = waveHeight(world_xz, iterations);
    float h_l = waveHeight(world_xz - vec2(eps_m, 0.0), iterations);
    float h_f = waveHeight(world_xz + vec2(0.0, eps_m), iterations);
    float ax = eps_m;
    float ay = h_c - h_l;
    float bz = eps_m;
    float by = h_c - h_f;
    vec3 n = vec3(ay * (-bz) - 0.0, 0.0 - ax * (-bz), ax * by - ay * 0.0);
    return normalize(n);
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

    // Sky-pass owns these branches now. Discard so we never write color
    // or depth for non-surface pixels.
    uint iter_eye = uint(waves.c.y);
    if (eye.y < waveHeight(eye.xz, iter_eye)) discard;
    if (ray.y >= 0.0) discard;

    float amp = waves.a.z;
    float hit_dist = raymarchWater(eye, ray, amp);
    if (hit_dist < 0.0) discard; // miss — sky-pass already painted this pixel
    vec3 hit = eye + ray * hit_dist;

    vec3 N = waveNormal(hit.xz, 0.1, uint(waves.c.y));
    N = normalize(mix(N, vec3(0.0, 1.0, 0.0), 0.8 * min(1.0, sqrt(hit_dist * 0.01) * 1.1)));

    float ndotv = max(0.0, dot(N, -ray));
    float fresnel = 0.04 + 0.96 * pow(clamp(1.0 - ndotv, 0.0, 1.0), 5.0);

    vec3 R = reflect(ray, N);
    R.y = abs(R.y);
    vec3 reflection = getAtmosphere(R) + vec3(getSun(R));

    float depth_t = clamp(hit.y * 0.15 + 0.5, 0.0, 1.0);
    vec3 scatter = mix(ocean.deep_color.rgb, ocean.shallow_color.rgb, depth_t) * 0.25;

    vec3 col = mix(scatter, reflection, fresnel);

    float curvature = clamp(1.0 - N.y, 0.0, 1.0);
    vec2 npos = hit.xz * 0.4 + waves.a.x * 0.05;
    vec2 ip = floor(npos);
    vec2 fp = fract(npos);
    fp = fp * fp * (3.0 - 2.0 * fp);
    vec4 h4 = fract(sin(vec4(
        dot(ip, vec2(127.1, 311.7)),
        dot(ip + vec2(1, 0), vec2(127.1, 311.7)),
        dot(ip + vec2(0, 1), vec2(127.1, 311.7)),
        dot(ip + vec2(1, 1), vec2(127.1, 311.7))
    )) * 43758.5453);
    float n = mix(mix(h4.x, h4.y, fp.x), mix(h4.z, h4.w, fp.x), fp.y);
    float foam_break = smoothstep(0.35, 0.85, n);
    float foam_t = smoothstep(
        ocean.foam.x - ocean.foam.y,
        ocean.foam.x + ocean.foam.y,
        curvature) * foam_break;
    vec3 foam_color = getAtmosphere(vec3(0.0, 1.0, 0.0)) * 6.0 + vec3(0.4);
    col = mix(col, foam_color, foam_t);

    // Underwater fog (camera below sea level but above local crest:
    // brief transition while wading in). The hard underwater case is
    // handled by sky-pass.
    if (eye.y < 0.0) {
        float fog_density = ocean.foam.z;
        float fog_t = 1.0 - exp(-fog_density * hit_dist);
        col = mix(col, ocean.fog_color.rgb, fog_t);
    }

    o_color = vec4(aces_tonemap(col * 2.0), 1.0);

    // Write depth so rasterized geometry (cubes, ships) drawn AFTER
    // water can z-test against the surface correctly.
    vec4 hit_clip = cam.proj * cam.view * vec4(hit, 1.0);
    gl_FragDepth = hit_clip.z / hit_clip.w;
}
