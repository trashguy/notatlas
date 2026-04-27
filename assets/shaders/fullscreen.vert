#version 450

// Fullscreen triangle, no vertex buffer. The frag shader covers the whole
// framebuffer; everything visual (sky and water) happens in water.frag.
//
// Vertex IDs 0,1,2 → uvs (0,0), (2,0), (0,2) → NDC (-1,-1), (3,-1), (-1,3).
// One triangle that overhangs the [-1, 1]² viewport on two sides; cheaper
// than a quad and avoids the diagonal seam.

layout(location = 0) out vec2 v_uv;

void main() {
    vec2 uv = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    v_uv = uv;
    gl_Position = vec4(uv * 2.0 - 1.0, 0.0, 1.0);
}
