---
name: distance fog samples a fixed sky direction, not view→fragment
description: Atmospheric distance fog on opaque geometry should sample getAtmosphere() at a fixed reference direction; sampling along the view→fragment ray makes the fog tone pulse as the camera moves
type: feedback
originSessionId: ab1fdfa8-8749-49fe-880e-7aebeda96444
---
When tinting opaque geometry (box, ships, structures) with atmospheric
distance fog, sample `getAtmosphere()` at a **fixed reference direction**
(currently `normalize(vec3(0, 0.3, 1.0))` — horizon haze). Do **not** sample
along the camera→fragment view ray.

**Why:** physically the view-ray version is "correct" (sky light scattering
in from behind the object), but `extra_cheap_atmosphere` is steeply
direction-dependent. As the camera moves — orbit altitude bob, ship roll,
player look — the sampled direction sweeps through that gradient and the
fog *color* visibly pulses over stationary geometry. Caught at M3.2 with a
4m cube that read as "fog drifting up and down over the cube" while the
cube was static. Fixing the direction kills the pulse with no loss of haze
tint and is what `box.frag` ships at M3.2.

**How to apply:**
- New opaque-geometry shaders: do this from the start. Search for
  `getAtmosphere(view_*)` / `getAtmosphere(-to_eye)` patterns in shader
  reviews — they're the failure mode.
- Reflective surfaces (the water shader) DO want the directional sample
  because the reflection vector is the physical source of color. Don't
  blanket-replace there.
- The reference direction is a tunable; if a future shader reads "too
  blue" or "too white" against its environment, adjust the direction
  rather than re-introducing the view-dependent sample.
