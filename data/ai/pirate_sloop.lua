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
-- aim_broadside thrust gating: while |heading error| is larger
-- than this, sails are slack (thrust=0) so the ship doesn't sail
-- itself off-aim during a rotation. Once within band, moderate
-- orbit thrust resumes. ~17° band picked so a square-rigger with
-- typical 5-10 s rotation time isn't penalized for the last few
-- degrees of alignment.
local aim_thrust_band_rad  = 0.3
local aim_orbit_thrust     = 0.4
-- PD heading controller: steer = clamp(Kp*diff - Kd*angvel_y, -1, 1).
-- The previous P-only law (gain 2/π) commanded full ±1 across most
-- of [-π, π] and thrashed across the ±π wrap because angular
-- velocity blew past the target while steer stayed pinned. We keep
-- Kp at the old 2/π so authority and time-to-aim stay roughly the
-- same; Kd is the addition — it brakes the rotation when angvel_y
-- is already in the desired direction so the ship coasts to the
-- target instead of overshooting and flipping sign at the wrap.
local steer_kp             = 2.0 / math.pi  -- proportional on heading error
local steer_kd             = 0.5            -- damping on yaw rate (rad/s)

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

-- Wrap-boundary band where `diff` is undefined-up-to-sign (a
-- target at the antipode is reachable by rotating either way).
-- Inside this band we ignore the wrap's sign and resolve the tie
-- with hysteresis on current rotation.
--
-- `wrap_band_rad` (~17°) is wide enough that the band persists
-- through several ticks of rotation, giving ω time to commit
-- before we exit. `wrap_omega_thresh` is the ω magnitude that
-- counts as "rotating" — set well above wave-induced ω jitter
-- (~±0.05 rad/s on a stationary sloop in 8 m swell) so micro-
-- flips don't pry the latch open.
local wrap_band_rad     = 0.3
local wrap_omega_thresh = 0.3

local function steer_toward(desired_heading, own_heading, angvel_y)
  -- Sign convention (verified by torque calculus on the lateral-
  -- force-at-bow model in ship-sim/main.zig applyShipInputForces):
  --
  --   forward_local = (0, 0, -1)
  --   forward_world = R(rot) · forward_local
  --   lateral       = forward_world × (0, 1, 0)        -- = ship's +X (starboard)
  --   F_steer       = steer_max_n × steer × lateral
  --   r_bow         = forward_world × half_extent.z    -- bow position rel. CoM
  --   τ_y           = (r × F)_y = -bow_offset_m × steer_max_n × steer
  --
  -- So +steer produces a NEGATIVE Y-axis torque → ω_y decreases
  -- → heading_rad decreases (heading is CCW-from-above with the
  -- yawFromQuat convention). To drive heading UP, we need negative
  -- steer. The controller therefore outputs `-(Kp*diff - Kd*ω)`.
  --
  -- At |diff| ≈ π the wrap is symmetric: rotating either direction
  -- by π reaches the antipode, and infinitesimal heading drift
  -- (waves) flips the sign of diff, which would thrash the command
  -- at ±1. Resolve the tie by:
  --   - if already rotating  → follow ω (commit once started)
  --   - if at rest           → default to CCW (positive diff)
  local omega = angvel_y or 0.0
  local diff = wrap_angle(desired_heading - own_heading)
  if math.abs(diff) > (math.pi - wrap_band_rad) then
    if math.abs(omega) > wrap_omega_thresh then
      diff = (omega >= 0) and math.abs(diff) or -math.abs(diff)
    else
      diff = math.abs(diff)
    end
  end
  return clamp(-(steer_kp * diff - steer_kd * omega), -1.0, 1.0)
end

-- ----- conds -----

function low_hp()
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
  set_steer(steer_toward(desired, own_heading, ctx.own_vel.ang.y))
  return "running"
end

function intercept()
  local e = ctx.nearest_enemy
  if e == nil then return "failure" end
  local own_heading = heading_from_pose(ctx.own_pose)
  local bearing = bearing_to(ctx.own_pose, e)
  set_thrust(0.8)
  set_steer(steer_toward(bearing, own_heading, ctx.own_vel.ang.y))
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
  local diff = wrap_angle(desired - own_heading)
  -- While |diff| is large the ship needs to rotate first; sailing
  -- forward in that window drags the firing solution off-target
  -- (with wind from astern the ship sails away from the orbit).
  -- Slack the sails until the rotation is mostly done, then resume
  -- orbital thrust to maintain a moving target profile.
  if math.abs(diff) > aim_thrust_band_rad then
    set_thrust(0.0)
  else
    set_thrust(aim_orbit_thrust)
  end
  set_steer(steer_toward(desired, own_heading, ctx.own_vel.ang.y))
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
