#version 450

// M14.3 PBR fragment shader. Cook-Torrance BRDF (GGX + Schlick Fresnel
// + Smith geometry) on top of the M14.2c lit-then-fogged scaffold.
// Normal mapping uses derivative-based TBN — no explicit per-vertex
// tangents needed, at the cost of ~5 extra ALU per fragment vs an
// attribute-driven TBN. Acceptable for v1; explicit tangents land
// when artist content needs them (probably M16+).
//
// Texture set follows glTF KHR_materials convention:
//   - albedo: sRGB RGBA8 (auto-degamma'd by the SRGB image format)
//   - normal: linear RGBA8 tangent-space, R=X G=Y B=Z (decoded *2-1)
//   - orm:    linear RGBA8 packed, R=AO, G=roughness, B=metallic
//
// Atmosphere helper + ACES tonemap mirror box.frag verbatim — same
// trade as before, no #include path setup.

layout(location = 0) in vec3 v_world_pos;
layout(location = 1) in vec3 v_world_normal;
layout(location = 2) in vec2 v_uv;
layout(location = 3) in vec3 v_tint;
layout(location = 0) out vec4 o_color;

layout(set = 0, binding = 0) uniform Camera {
    mat4 view;
    mat4 proj;
    vec4 eye;
} cam;

// M14.3 — three texture bindings. SPIR-V reflection picks these up
// automatically; descriptor pool sized for 3 combined image samplers.
layout(set = 0, binding = 1) uniform sampler2D albedo_tex;
layout(set = 0, binding = 2) uniform sampler2D normal_tex;
layout(set = 0, binding = 3) uniform sampler2D orm_tex;

const vec3 SUN_DIR = normalize(vec3(-0.0773502691896258, 0.6, 0.5773502691896258));
const vec3 SUN_COLOR = vec3(1.0, 0.95, 0.85) * 3.0;
const float FOG_DENSITY = 0.003;
const float PI = 3.14159265359;

// ---- atmosphere/tonemap (copied from box.frag for parity) ----

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

// ---- normal mapping (derivative-based TBN, MikkTSpace-free) ----
//
// Reference: Blinn 1978 "Computer Display of Curved Surfaces" via
// Christian Schueler's "Followup: Normal Mapping Without Precomputed
// Tangents" (https://terathon.com/wiki/index.php?title=Normal_Mapping).
// Builds T and B from screen-space derivatives of the world position
// and UV. Equivalent visual quality to per-vertex TBN for our cube
// (uniform per-face normals); diverges only on smooth surfaces with
// curvature, which v1 doesn't ship.
vec3 perturb_normal(vec3 N, vec3 V, vec2 uv, vec3 normal_sample) {
    vec3 dp1 = dFdx(V);
    vec3 dp2 = dFdy(V);
    vec2 duv1 = dFdx(uv);
    vec2 duv2 = dFdy(uv);

    vec3 dp2perp = cross(dp2, N);
    vec3 dp1perp = cross(N, dp1);
    vec3 T = dp2perp * duv1.x + dp1perp * duv2.x;
    vec3 B = dp2perp * duv1.y + dp1perp * duv2.y;

    float invmax = inversesqrt(max(dot(T, T), dot(B, B)));
    mat3 TBN = mat3(T * invmax, B * invmax, N);
    return normalize(TBN * normal_sample);
}

// ---- Cook-Torrance BRDF building blocks ----
//
// Same shape every "PBR 101" tutorial uses (Karis 2013, Burley 2012):
//   D = GGX (Trowbridge-Reitz) — microfacet distribution
//   F = Schlick approximation — Fresnel
//   G = Smith (Schlick-GGX variant) — geometry/shadowing

float distributionGGX(float NdotH, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float denom = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / max(PI * denom * denom, 1e-7);
}

float geometrySchlickGGX(float NdotX, float roughness) {
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;
    return NdotX / (NdotX * (1.0 - k) + k);
}

float geometrySmith(float NdotV, float NdotL, float roughness) {
    return geometrySchlickGGX(NdotV, roughness) *
           geometrySchlickGGX(NdotL, roughness);
}

vec3 fresnelSchlick(float cos_theta, vec3 F0) {
    return F0 + (1.0 - F0) * pow(1.0 - cos_theta, 5.0);
}

// ---- main ----

void main() {
    vec3 V = normalize(cam.eye.xyz - v_world_pos);

    // Sample maps.
    vec3 albedo = texture(albedo_tex, v_uv).rgb * v_tint;
    vec3 N_sample = texture(normal_tex, v_uv).xyz * 2.0 - 1.0;
    vec3 orm = texture(orm_tex, v_uv).rgb;
    float ao = orm.r;
    float roughness = clamp(orm.g, 0.04, 1.0); // floor avoids singular GGX
    float metallic = orm.b;

    // Normal mapping in world space.
    vec3 N_geom = normalize(v_world_normal);
    vec3 N = perturb_normal(N_geom, v_world_pos, v_uv, N_sample);

    vec3 L = SUN_DIR;
    vec3 H = normalize(L + V);

    float NdotL = max(0.0, dot(N, L));
    float NdotV = max(1e-4, dot(N, V));
    float NdotH = max(0.0, dot(N, H));
    float HdotV = max(0.0, dot(H, V));

    // F0 = base reflectance at normal incidence. Dielectrics ≈ 0.04;
    // metals tint by their albedo. Standard PBR mix-with-metallic.
    vec3 F0 = mix(vec3(0.04), albedo, metallic);

    // Specular BRDF terms.
    float D = distributionGGX(NdotH, roughness);
    float G = geometrySmith(NdotV, NdotL, roughness);
    vec3 F = fresnelSchlick(HdotV, F0);
    vec3 specular = (D * G * F) / max(4.0 * NdotL * NdotV, 1e-4);

    // Energy conservation: diffuse = (1 - kS) * albedo / π, where kS = F.
    // Pure metals lose all diffuse → multiply by (1 - metallic).
    vec3 kS = F;
    vec3 kD = (vec3(1.0) - kS) * (1.0 - metallic);
    vec3 diffuse = kD * albedo / PI;

    vec3 direct = (diffuse + specular) * SUN_COLOR * NdotL;

    // Cheap sky-ambient. Multiplied by AO so deep crevices stay dim.
    vec3 sky_ambient = getAtmosphere(vec3(0.0, 1.0, 0.0));
    vec3 ambient = albedo * sky_ambient * 0.05 * ao;

    vec3 lit = direct + ambient;

    // Atmospheric distance fog (matches box.frag).
    float dist = length(cam.eye.xyz - v_world_pos);
    vec3 atmo = getAtmosphere(FOG_REF_DIR);
    float fog_t = 1.0 - exp(-FOG_DENSITY * dist);
    vec3 col = mix(lit, atmo, fog_t);

    o_color = vec4(aces_tonemap(col), 1.0);
}
