-- Pirate sloop AI leaves — STEP 5 PLACEHOLDERS.
--
-- These match the leaf names referenced in pirate_sloop.yaml and
-- exist only so ai-sim's dispatcher exercises the full call path
-- (Zig BT → Lua global → return tag string) end-to-end.
--
-- They DO NOT yet read perception ctx (own_pose, nearest_enemy,
-- threats, wind) — that ships in step 6 alongside the Zig-side ctx
-- push (docs/09 §7 / §14 step 6). Until then every cond returns
-- false and every action returns "failure", which means the BT
-- falls through to the patrol fallback every tick.
--
-- Step 6 will replace this file wholesale. Don't lean on these
-- semantics anywhere downstream.

-- ----- conds -----
function low_hp() return false end
function enemy_in_range() return false end
function enemy_spotted() return false end

-- ----- actions -----
function flee_to_open_water() return "failure" end
function aim_broadside() return "failure" end
function fire_broadside() return "failure" end
function intercept() return "failure" end
function patrol_waypoints() return "running" end
