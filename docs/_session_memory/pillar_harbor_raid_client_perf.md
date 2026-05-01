---
name: notatlas sub-pillar — harbor raid client FPS
description: Companion to "naval combat at scale." Harbor raids combine ship components + player-built base structures in dense proximity, which tanked FPS in Atlas independent of server tick. This is a client-rendering problem with rendering-architecture answers and design-cap answers.
type: project
originSessionId: cb0aa047-d395-4803-bc6b-7df96341b031
---
The user flagged: "harbor raids with the loads of ship components would just tank fps." This is **distinct** from the naval-combat-at-scale concern. Different bottleneck:

| Problem | Bottleneck | Fix domain |
|---|---|---|
| Open-water 30-ship brawl | Server tick + replication bandwidth | Tiered replication, per-entity subjects, deterministic projectiles |
| Harbor raid (this) | Client GPU draw calls + state changes + animation/particle/light cost | GPU-driven rendering, instancing, LOD, content design caps |

**Why harbor raids broke Atlas specifically:**
- Player-built bases were 500-2000 individually-rendered structure pieces (foundations, walls, ceilings, cannons, storage, NPC crew)
- Attacking fleet adds 10-20 ships × 50-200 components each
- All visible simultaneously in a confined ~1km² area
- UE4's auto-instancing fights with composite player-built structures
- Each structure = draw call + shadow draws (×N cascades) + animation tick + replication callback
- Particle systems: cannon flashes, smoke, fires, splashes — each emitter compounds
- Dynamic lights: torches, cannon muzzle flashes, explosions — UE4 forward+ has fixed per-cluster caps
- Result: 5000+ draw calls, FPS drops below 30

**This is the engine you're building's real advantage.** A custom Zig+Vulkan renderer can be GPU-driven from day one, where UE4 fights you for it. Modern Vulkan can put 50,000 instances in a single draw call cheaply. The engine's selling point becomes: notatlas doesn't tank FPS in harbor raids because the renderer is the right shape.

**Required engine capabilities:**
1. **Bindless texture arrays** — material variation doesn't break instancing
2. **GPU-driven culling** — compute shader does frustum + occlusion, indirect draw counts. 5000 entities → only visible ones drawn.
3. **Indirect draws + instance arrays per piece type** — one draw call per palette piece, not per instance
4. **Static/dynamic separation** — bake static structures into precomputed scene graph; only re-bake on damage/destruction (async, off main thread)
5. **Hierarchical LOD with auto-merging** — distant base = single merged mesh, mid = low-poly instanced, near = full instanced
6. **Damage state via texture/mesh swap, not physics fragments** — no per-piece destruction physics on client
7. **Particle budget cap + GPU sim** — hard 100k particle ceiling, distance LOD, all GPU-resident
8. **Animation LOD** — distant chars: 5fps + reduced rig; close: full
9. **Shadow LOD** — cascade resolution by distance; don't shadow far structures at all (bake into terrain)
10. **Single uber-shader for all structures** — no first-sight compile stalls

**Required content design caps (free perf, lower implementation cost than engine work):**
- Hard cap structures per anchorage (e.g. 500 pieces). Atlas had no cap; players built monstrosities. The single most effective tool against harbor-raid FPS death is "you cannot build a base that big in the first place."
- Cap NPC crew per anchorage (e.g. 20)
- Cap concurrent attackers per anchorage (matchmade entry)
- Cap concurrent dynamic lights (e.g. 32) and explicitly time-out cannon flashes / explosions

**Design tension to flag:** the user wants huge harbor raids as a setpiece. The cap is not "no big raids" — it's "big raids are dense, not sprawling." 200 attackers vs 200 defenders around a 500-piece harbor with 30 ships is the *target*, not what we're cutting away from. The cap exists so that 200v200 stays at 60fps instead of becoming 1000v1000 at 12fps.

**Stress test gate (separate from naval brawl):**
Before Phase 3 content work: synthetic harbor with 500 random structures + 30 box-ships + 200 dummy characters + 100 cannon emitters firing simultaneously. Target: 60fps on a mid-range GPU (RTX 4060 / RX 7600). Profile with RenderDoc; if any single subsystem (draw call, shadow, particle, animation) takes >2ms, fix before adding content.
