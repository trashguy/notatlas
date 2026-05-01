-- Pirate sloop AI — leaves for pirate_sloop.yaml.
--
-- Reads the perception ctx pushed by ai-sim each tick (see
-- src/services/ai_sim/perception.zig) and writes input via the
-- registered set_thrust / set_steer / set_fire helpers.
--
-- Input convention (from src/services/cell_mgr/wire.zig InputMsg):
--   thrust:  +1 forward (ship-local −Z), −1 reverse
--   steer:   +1 right turn (yaw clockwise from above), −1 left
--   fire:    edge-triggered cannon latch
--
-- Forward direction in world frame for heading h:
--   forward = (sin h, 0, -cos h)
-- Bearing world→target from origin facing −Z:
--   bearing = atan2(dx, -dz)
-- Steer command is the wrapped (desired_heading - own_heading)
-- normalized into [-1, 1].

-- ----- tuning -----
local cannon_range_m       = 180.0   -- enemy_in_range threshold
local broadside_offset_rad = math.pi / 2   -- starboard (cannon side)
local steer_gain           = 2.0 / math.pi -- diff in [-pi,pi] → [-1,1]ish

-- ----- helpers -----

local function heading_from_pose(p)
  -- ai-sim encodes heading as a yaw-only quat: qz=sin(h/2), qw=cos(h/2)
  return 2.0 * math.atan(p.qz, p.qw)
end

local function wrap_angle(a)
  while a >  math.pi do a = a - 2.0 * math.pi end
  while a < -math.pi do a = a + 2.0 * math.pi end
  return a
end

local function bearing_to(own, target)
  local dx = target.x - own.x
  local dz = target.z - own.z
  return math.atan(dx, -dz)
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function steer_toward(desired_heading, own_heading)
  -- Empirically (Jolt + ship-sim's lateral-force-at-bow setup):
  -- +steer drives heading_rad UP (Jolt's +Y rotation is CCW
  -- from above, i.e. left turn — the InputMsg "right turn"
  -- comment refers to a different visual convention). So if
  -- desired > own we want POSITIVE steer to grow heading toward
  -- desired. Sign matches `desired - own`.
  local diff = wrap_angle(desired_heading - own_heading)
  return clamp(diff * steer_gain, -1.0, 1.0)
end

-- ----- conds -----

function low_hp()
  -- Damage system not online yet — own_hp is stubbed to 1.0 in
  -- perception.zig, so this branch never fires today. Wired for the
  -- moment hp lands.
  return ctx.own_hp < 0.3
end

function enemy_spotted()
  return ctx.nearest_enemy ~= nil
end

function enemy_in_range()
  local e = ctx.nearest_enemy
  return e ~= nil and e.dist < cannon_range_m
end

-- ----- actions -----

function flee_to_open_water()
  local e = ctx.nearest_enemy
  if e == nil then return "failure" end
  local own_heading = heading_from_pose(ctx.own_pose)
  local bearing = bearing_to(ctx.own_pose, e)
  -- Desired heading: opposite of bearing (run away).
  local desired = bearing + math.pi
  set_thrust(1.0)
  set_steer(steer_toward(desired, own_heading))
  return "running"
end

function intercept()
  local e = ctx.nearest_enemy
  if e == nil then return "failure" end
  local own_heading = heading_from_pose(ctx.own_pose)
  local bearing = bearing_to(ctx.own_pose, e)
  set_thrust(0.8)
  set_steer(steer_toward(bearing, own_heading))
  return "running"
end

function aim_broadside()
  local e = ctx.nearest_enemy
  if e == nil then return "failure" end
  local own_heading = heading_from_pose(ctx.own_pose)
  local bearing = bearing_to(ctx.own_pose, e)
  -- Want enemy on starboard (+90° from forward), so own heading
  -- should be bearing - π/2.
  local desired = bearing - broadside_offset_rad
  -- Hold a moderate speed while orbiting the target.
  set_thrust(0.4)
  set_steer(steer_toward(desired, own_heading))
  return "running"
end

function fire_broadside()
  local e = ctx.nearest_enemy
  if e == nil then return "failure" end
  -- The BT cooldown node wrapping this leaf gates it to once every
  -- cooldown_ms (4 s in pirate_sloop.yaml). In between, this leaf
  -- isn't called. Each tick starts with pending_input cleared, so
  -- fire defaults to false — no need to set_fire(false) explicitly.
  set_fire(true)
  return "success"
end

function patrol_waypoints()
  -- v0 patrol: idle ahead. Waypoint logic lands when self.squad /
  -- archetype-level patrol_path support arrives (docs/09 §13 q2,
  -- post-v1).
  set_thrust(0.3)
  set_steer(0.0)
  return "running"
end
