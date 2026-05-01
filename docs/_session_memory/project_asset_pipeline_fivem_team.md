---
name: asset pipeline must match FiveM-RP workflow for incoming devs
description: Other devs joining notatlas come from GTA 5 / FiveM RP modding. Their asset pipeline expectations shape how content tooling needs to look in Phase 2/3.
type: project
originSessionId: 66fc34e7-0baa-4b1c-921e-326aaa61a1d8
---
The user's other devs come from a **GTA 5 / FiveM RP server modding** background, not a from-scratch engine background. This colors what the notatlas content pipeline needs to look like by the time Phase 2/3 lands and content starts flowing in.

**Why:** they have to be productive without a deep Zig / engine ramp-up. The closer the content workflow feels to FiveM's, the faster they ship art / props / ship variants without blocking on the engine team.

**FiveM workflow they expect:**
- Author meshes in Blender/Maya → export to format (FiveM uses `.ydr/.ytd/.ymap` via OpenIV/CodeWalker; we'd use glTF or KTX2 textures).
- Drop file in a `resources/<thing>/` folder.
- Write a small Lua/JSON manifest declaring it (loadable name, properties).
- `restart <resource>` console command hot-reloads it without restarting the server.
- Lua scripting for behavior; permissive — "drop in, see it work".

**How to apply (when Phase 2/3 content tooling decisions land):**

1. **glTF for meshes**, not a custom binary format. fallen-runes already has `gltf_loader.zig` (~2.4 k LOC) we can lift per the reference rules. Standard tool support (Blender → glTF Export) means zero asset-toolchain work for the team.
2. **Hot-reload by default for new asset categories** — already established for shaders + YAML data (M2.6 / M3.4 / M4.2). Extending to meshes + textures keeps the muscle-memory workflow intact.
3. **Data-driven manifests in YAML + Lua** — already planned per docs/05. Make sure the structure is discoverable: `data/ships/<ship>.yaml`, `data/props/<prop>.yaml`, etc. with one file per content unit (no monolithic registries).
4. **Onboarding doc with a worked example** before content scaling — pick the smallest meaningful change (e.g. "add a new sail texture to the sloop") and document the file-by-file path. Target audience: someone who's installed Zig once and never opened the engine.
5. **Tension to manage**: FiveM ships assets to clients on demand (200+ MB packs are normal). notatlas may want pre-baked deterministic client builds with content versioning. Don't blanket-adopt FiveM's "drop file, client downloads" model — it conflicts with cycle-wipe determinism. The content WORKFLOW can mirror FiveM; the SHIPPING model can differ.
6. **Don't let permissive-mode habits leak into gameplay code.** FiveM Lua scripts can mutate game state from anywhere. notatlas keeps gameplay in ECS systems per docs/02. Lua should be config / scripting / triggers, not the systems layer.
7. **Lua surface spans both sides** (locked 2026-04-29): server-side for content / scripting / triggers per (6) AND client-side for UI + client logic (HUD widgets, menus, in-world panels, user-side interaction handlers). FiveM devs are used to writing both halves in Lua and that's the right call here too — same language across the wire keeps content-author productivity high and matches their existing muscle memory. The client embedding will need its own Lua context (sandbox, separate API surface from server) but the language and dev experience stay consistent.

8. **Systems vs content split is load-bearing** (recognised 2026-04-29). The engine team writes the SYSTEMS layer in Zig: physics, replication, networking, fanout, ECS skeleton, movement primitives, AI helpers (pathfinder, perception, steering), event bus, dialogue runtime. The content team writes the BEHAVIOURS in Lua: NPC personalities, encounter triggers, quest scripts, dialogue trees, AI decision logic ("the harbour drunk wanders, talks to anyone within 3m, fights if attacked"), faction relations, raid encounter choreography, vendor inventory logic, harbour inhabitant routines. **Without a rich Lua scripting surface, every new NPC type bottlenecks on engine-team code changes** — exactly the fail mode FiveM avoided by making everything Lua-scriptable. Plan for this when the AI / NPC ECS systems get designed: every system should expose Lua hooks for the per-instance personality, not bake behaviour in Zig. Similar for quest / encounter systems — the SYSTEM is `quest_runner`, the CONTENT is N Lua scripts that the runner executes.

**Not a tomorrow task** — but worth raising during Phase 2/3 planning so the asset pipeline is a deliberate design, not an afterthought when devs are already blocked.
