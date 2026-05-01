---
name: bring depth buffer in as soon as geometry overlaps in z
description: deferring the depth attachment past the first non-trivial 3D geometry produces "picket-fence" horizon artifacts that look like a shading bug
type: feedback
originSessionId: 0e70b569-17de-45d1-95e3-329e743019b1
---
Don't defer the depth attachment past the first milestone where geometry
actually overlaps in z. The notatlas Vulkan renderer skipped depth at
M2.3 (flat plane) and M2.4 (waves visible only as silhouettes) — fine
for those — but at M2.5 the Gerstner crests started overlapping each
other in screen space, and the symptoms looked like a shader bug:
spiky white "picket fence" along the horizon, distant peaks bleeding
through near troughs. The fix was to add the depth pass; the M2.5 frag
shader was correct.

**Why:** Without z-test, primitives paint in vertex order. As soon as
the surface has any vertical structure, multiple triangles project to
the same pixel and the painter's-order rendering produces flicker that
mimics z-fighting and aliasing. The triangle count is highest at the
horizon (where `dy/dx` of the projection is high), so the artifact
concentrates there.

**How to apply:** When stubbing in a new render pass, default to
including depth (D32_SFLOAT, attachment 1, clear on load, don't-care on
store) unless you have a positive reason to skip it. If you do skip it
intentionally (early "first pixels" milestones), leave a TODO at the
pipeline-create site so the omission is loud, and add depth as a
prerequisite of any milestone that introduces vertical displacement,
overlapping meshes, or a 3D camera path.
