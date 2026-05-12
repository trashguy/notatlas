#version 450

// M10.1 instanced-rendering fragment shader. Lighting + atmospheric fog
// match box.frag byte-for-byte so the migration from Box to Instanced is a
// visual no-op. Kept as a separate file (rather than #include'd) for the
// same glslc-include-path reason called out in box.frag.

layout(location = 0) in vec3 v_world_pos;
layout(location = 1) in vec3 v_world_normal;
layout(location = 2) in vec3 v_albedo;
layout(location = 0) out vec4 o_color;

layout(set = 0, binding = 0) uniform Camera {
    mat4 view;
    mat4 proj;
    vec4 eye;
} cam;

const vec3 SUN_DIR = normalize(vec3(-0.0773502691896258, 0.6, 0.5773502691896258));
const float FOG_DENSITY = 0.003;

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

const vec3 FOG_REF_DIR = normalize(vec3(0.0, 0.3, 1.0));

void main() {
    vec3 N = normalize(v_world_normal);
    vec3 to_eye = cam.eye.xyz - v_world_pos;
    float dist = length(to_eye);

    float n_dot_l = max(0.0, dot(N, SUN_DIR));
    vec3 sky_ambient = getAtmosphere(vec3(0.0, 1.0, 0.0));
    vec3 lit = v_albedo * (0.25 + 0.85 * n_dot_l) + sky_ambient * 0.05;

    vec3 atmo = getAtmosphere(FOG_REF_DIR);
    float fog_t = 1.0 - exp(-FOG_DENSITY * dist);
    vec3 col = mix(lit, atmo, fog_t);

    o_color = vec4(aces_tonemap(col * 2.0), 1.0);
}
