-- Applied at 2026-06-17T14:45:09.114Z (ts=1781707509114)
-- bytes=42389
-- flags={"followOwner":true,"castSkill":true,"physAttack":true,"kite":false,"defendOwner":true,"followOwnerTarget":true,"followOwnerSkillTarget":true,"autoAttackMobs":true,"takeAggro":true,"fleeOwnMarineSphere":false}

-- preset:custom flags:{"followOwner":true,"castSkill":true,"physAttack":true,"kite":false,"defendOwner":true,"followOwnerTarget":true,"followOwnerSkillTarget":true,"autoAttackMobs":true,"fleeOwnMarineSphere":false,"takeAggro":true} params:{"ownerGID":2000291,"skid":8013,"level":5,"spCost":30,"skillRange":9,"perMob":{"1016":{"a":true,"p":true,"m":true,"k":false,"f":false},"1026":{"a":true,"p":true,"m":true,"k":false,"f":false},"1028":{"a":true,"p":true,"m":true,"k":false,"f":false},"1060":{"a":true,"p":true,"m":false,"k":false,"f":false},"1068":{"a":true,"p":true,"m":true,"k":false,"f":false},"1080":{"a":false,"p":true,"m":false,"k":false,"f":false},"1102":{"a":false,"p":true,"m":true,"k":false,"f":false},"1131":{"a":false,"p":true,"m":true,"k":false,"f":false},"1156":{"a":true,"p":true,"m":true,"k":false,"f":false},"1188":{"a":true,"p":true,"m":true,"k":false,"f":false},"1199":{"a":false,"p":true,"m":true,"k":false,"f":false},"1378":{"a":false,"p":true,"m":true,"k":false,"f":false},"1735":{"a":false,"p":false,"m":false,"k":true,"f":false},"1738":{"a":false,"p":false,"m":false,"k":true,"f":false},"1745":{"a":false,"p":false,"m":false,"k":true,"f":false}}}
-- =============================================================================
-- const.lua — tuning constants (K) + config-derived values (deriveConst).
--
-- K holds the static knobs (ranges, cooldowns, mob ids). deriveConst(cfg)
-- computes the values that depend on the user's skill range (skill range
-- squared, kite walk-to distance, leash engagement cap, SP floor) once at
-- initState time — they are stored flat in `st` and never mutated afterwards.
--
-- Block contract : K and deriveConst are declared first so every later block
-- (helpers/sensing/flee/engage/follow/main) captures them as upvalues.
-- =============================================================================

local K = {
  -- Move re-issue throttle (ms). `Move` is otherwise guarded by motion ~= 1,
  -- which leaves a stale destination while the target keeps moving ; refreshing
  -- every MOVE_REFRESH_MS lets the homun lazily track a fleeing / chasing mob.
  MOVE_REFRESH_MS = 500,

  -- Max range squared for the Lua-native defensive / tank aggro scan. 15² ~
  -- screen radius on cyro.live ; mobs attacking master beyond it are ignored.
  DEFENSIVE_MAX_RANGE_SQ = 225,

  -- Max range squared for the Lua-native whitelist (auto-attack) scan. 25²,
  -- aligned with the legacy JS-side AGGRO_LIST cap for behavioural continuity.
  WHITELIST_MAX_RANGE_SQ = 625,

  -- Marine Sphere avoidance. AM_DEMONSTRATION + NPC_SELFDESTRUCTION splash a
  -- 5x5-7x7 area ; flee when a sphere is within FLEE_DANGER_SQ (5²) and walk
  -- FLEE_TARGET_DISTANCE (9) cells away so walk speed can outrun the cast.
  MARINE_SPHERE_MOB_ID = 1142,
  FLEE_DANGER_SQ = 25,
  FLEE_TARGET_DISTANCE = 9,

  -- Leash distance². With followOwner on, the homun drops its target and runs
  -- home if the master is further than LEASH_MAX (12) cells away.
  LEASH_MAX = 12,
  LEASH_MAX_SQ = 144,

  -- Fallback kite distance for the per-mob `kite-no-skill` mode when no global
  -- skill is configured (skillRange 0). 4 cells = mid-range tracking distance.
  KITE_NO_SKILL_RANGE = 4,

  -- Anti-re-cast guard (ms) between two SkillObject calls. NOT the server-side
  -- skill cooldown — must be >= the homun skill's after-cast-delay so canCast
  -- doesn't re-flip true while the server is still delayed (would re-fire the
  -- cast silently and starve the melee fallthrough).
  SKILL_COOLDOWN_MS = 1800,

  -- Pre-empt cast delay (ms). When the engaged target was acquired via a
  -- master-driven channel (skillTarget / aggroTarget), hold the cast this long
  -- so the master lands a hit first and keeps loot / exp rights. Only the cast
  -- is delayed ; the homun still approaches / melees during the window.
  PREEMPT_CAST_DELAY_MS = 800,

  -- Engage watchdog timeout (ms). Drop a target engaged this long with no
  -- progress (no position change AND no melee swing) so pickup re-runs and the
  -- homun stops freezing on an unreachable / un-attackable mob.
  STUCK_ENGAGE_TIMEOUT_MS = 4000,

  -- How long a watchdog-dropped target stays blacklisted from pickup, so the
  -- homun engages a DIFFERENT reachable mob instead of re-selecting the same
  -- unreachable one every tick. Expires so a since-moved mob gets retried.
  BLACKLIST_TTL_MS = 8000,
}

-- Config-derived values (pure function of cfg ; computed once in initState).
local function deriveConst(cfg)
  local skillRange = cfg.skillRange or 0
  local kiteRange = skillRange > 0 and skillRange or K.KITE_NO_SKILL_RANGE
  -- Engagement reach for the pickup leash cap : the homun can stand at the
  -- leash edge and still hit a mob `reach` further (skill range, or 1 melee),
  -- so a mob within (LEASH_MAX + reach) of the owner is reachable.
  local leashReach = cfg.castSkill and skillRange or 1
  return {
    skillRangeSq = skillRange * skillRange,
    minR = math.max(0, skillRange - 1),         -- walk-to for skill-only-kite
    kiteRange = kiteRange,
    kiteMinR = math.max(0, kiteRange - 1),      -- walk-to for kite-no-skill
    leashReach = leashReach,
    leashCapSq = (K.LEASH_MAX + leashReach) * (K.LEASH_MAX + leashReach),
    -- SP floor : if the bundle didn't surface the real spcost (manual SKID),
    -- spCost is 0 and `sp >= 0` always passes → spam-cast at 0 SP. Floor at 1.
    spCost = math.max(cfg.spCost or 0, 1),
  }
end

-- =============================================================================
-- CFG — runtime configuration emitted by the panel at the moment of Apply.
--
-- Read once at initState(CFG) and stored in `st` ; then passed as `cfg` to
-- every behavior block (sensing / flee / engage / follow). Mutation across
-- ticks is not supported — re-Apply from the panel to change anything.
-- =============================================================================
local CFG = {
  -- Top-level behavior flags (panel checkboxes, Global tab).
  followOwner            = true ,  -- leash + idle MoveToOwner fallback
  castSkill              = true ,  -- enable the skill cast branch
  physAttack             = true ,  -- enable the melee Attack branch
  kite                   = false,  -- skill-only positioning (walk to skillRange-1)
  defendOwner            = true ,  -- tank scan : engage mobs targeting master
  followOwnerTarget      = true ,  -- engage the master's native V_TARGET
  followOwnerSkillTarget = true ,  -- shim : master's skill target + aggressor
  autoAttackMobs         = true ,  -- pure-Lua whitelist scan (perMob[mid].a)
  fleeOwnMarineSphere    = false,  -- flee own Marine Spheres (1142) + plant assist
  takeAggro              = true ,  -- switch target to master's latest attacker

  -- Identity + skill parameters. ownerGID is always baked ; skid/level/
  -- spCost/skillRange only have meaning when castSkill is true.
  ownerGID   = 2000291,
  skid       = 8013,
  level      = 5,
  spCost     = 30,
  skillRange = 9,

  -- Per-mob overrides (Mobs tab). Indexed by mob_id (V_HOMUNTYPE).
  -- Each entry has 5 boolean flags overriding the global behavior for that
  -- specific monster :
  --   a = auto-attack : engage actively (whitelist pickup, needs autoAttackMobs)
  --   p = physical    : melee Attack allowed
  --   m = magic       : cast skill allowed
  --   k = kite        : back away while casting (needs castSkill)
  --   f = flee        : do not engage, run away
  perMob = {
    [1016] = { a = true , p = true , m = true , k = false, f = false },
    [1026] = { a = true , p = true , m = true , k = false, f = false },
    [1028] = { a = true , p = true , m = true , k = false, f = false },
    [1060] = { a = true , p = true , m = false, k = false, f = false },
    [1068] = { a = true , p = true , m = true , k = false, f = false },
    [1080] = { a = false, p = true , m = false, k = false, f = false },
    [1102] = { a = false, p = true , m = true , k = false, f = false },
    [1131] = { a = false, p = true , m = true , k = false, f = false },
    [1156] = { a = true , p = true , m = true , k = false, f = false },
    [1188] = { a = true , p = true , m = true , k = false, f = false },
    [1199] = { a = false, p = true , m = true , k = false, f = false },
    [1378] = { a = false, p = true , m = true , k = false, f = false },
    [1735] = { a = false, p = false, m = false, k = true , f = false },
    [1738] = { a = false, p = false, m = false, k = true , f = false },
    [1745] = { a = false, p = false, m = false, k = true , f = false },
  },
}
_G.CHAI_BUILD = "2.0.0-a.6"
-- =============================================================================
-- helpers.lua — logging + input + small geometry/motion helpers.
--
-- All declared `local` so later blocks capture them as upvalues. readUserCmd
-- wraps the shim-provided `chaiGetMsg` (the bundle's native GetMsg is broken on
-- cyro's Wasmoon) under a readable name ; if the shim is absent it nil-crashes
-- inside the pcall and the tick self-heals, matching a.11 degraded behaviour.
-- =============================================================================

-- Lua-side fallback for the JS-injected chaiDevLog bridge (ai-bridge.js
-- setupChaiDevLogBridge). When the JS bridge isn't installed (degraded mode),
-- pipe to native print so logs surface instead of nil-crashing. The JS install
-- is idempotent — this fallback only matters if applyLua ran first.
if type(chaiDevLog) ~= 'function' then
  chaiDevLog = function(lvl, m)
    if type(TraceAI) == 'function' then
      TraceAI('[chai-' .. tostring(lvl) .. '] ' .. tostring(m))
    else
      print('[chai-dbg] ' .. tostring(m))
    end
  end
end

-- Verbose-gated log helper. Neutralized since a.25 : per-tick logs (engage
-- attack/move/cast) flooded the dev-log server at ~10 Hz. Restore by reverting
-- to: local function v(msg) if _G.CHAI_VERBOSE then chaiDevLog('debug', msg) end end
local function v(_msg) end

-- Read the user's manual Alt+RClick command (MSG_ATTACK / MSG_MOVE). Thin
-- wrapper over the shim PREAMBLE's chaiGetMsg(homunId) -> (cmd, a1, a2).
local function readUserCmd(homunId)
  return chaiGetMsg(homunId)
end

-- Chebyshev (chessboard) distance — melee range test. The server accepts a
-- melee attack only when max(|dx|,|dy|) <= atkRange, NOT Euclidean.
local function chebyshev(dx, dy)
  return math.max(math.abs(dx), math.abs(dy))
end

-- Squared Euclidean distance — used for skill range / proximity comparisons
-- (avoids the sqrt ; compare against squared thresholds).
local function distSq(dx, dy)
  return dx * dx + dy * dy
end

-- Homun attack motions are ATTACK=2, ATTACK2=5, ATTACK3=6 (cf. EntityAction.js
-- TYPE_HOM). motion 4 is DIE, NOT an attack — never treat it as a swing.
local function isAttackMotion(m)
  return m == 2 or m == 5 or m == 6
end

-- =============================================================================
-- sensing.lua — target acquisition. One GetActors() + GetResMsg drain per tick,
-- shared by the take-aggro tank scan and the pickup priority chain.
--
-- sense(homunId, cfg, st) mutates st.lastSeenTarget (and arms st.preemptCastAfter
-- for master-driven targets). Runs after the flee steps and before engage.
--
-- Pickup priority : plant > skillTarget > aggroTarget > defensive > whitelist
-- > native. Each source is runtime-gated by its flag ; disabled sources stay 0
-- so the or-chain is uniform. The `V_* and GetV(...)` guards degrade gracefully
-- when the shim is absent (V_SKILL_TARGET / V_AGGRESSOR nil → fall back native).
-- =============================================================================

local function sense(homunId, cfg, st)
  local ownerGID = cfg.ownerGID

  -- One shared GetActors() + position fetch + GetResMsg drain when any actor
  -- scan is active (defensive / whitelist / plant). The drain is mandatory
  -- after GetActors() (belt-and-suspenders against the HOM_AGGRESSIVE=true edge
  -- case where AIDriver.GetActors would poison resMsg via setmsg(homunId,"0")).
  local actors, homunX, homunY, scanNow, ownerX, ownerY
  if cfg.defendOwner or cfg.autoAttackMobs or cfg.fleeOwnMarineSphere then
    actors = GetActors()
    local _ = GetResMsg(homunId)
    homunX, homunY = GetV(V_POSITION, homunId)
    scanNow = GetTick()
    if cfg.followOwner then ownerX, ownerY = GetV(V_POSITION, ownerGID) end
  end

  -- ===========================================================================
  -- 0.7. Take aggro / tank mode : override the target on a new attacker,
  -- bypassing the pickup gate. takeAggro reads V_AGGRESSOR (shim, NOTIFY_ACT,
  -- 4s TTL — fast). defendOwner is a pure-Lua scan for the closest mob whose
  -- V_TARGET points at master/homun ; runs every tick so the homun keeps
  -- switching to fresh attackers. V_AGGRESSOR wins when both are on (no scan).
  -- ===========================================================================
  if (cfg.takeAggro or cfg.defendOwner) and not st.manualLock then
    local newAggro = 0
    if cfg.takeAggro and V_AGGRESSOR then
      local va = GetV(V_AGGRESSOR, ownerGID)
      if va and va > 0 and IsMonster(va) == 1 then newAggro = va end
    end
    if cfg.defendOwner and newAggro == 0 then
      -- Tank scan : closest mob targeting master/homun within range.
      local aClosest, aBest = 0, K.DEFENSIVE_MAX_RANGE_SQ
      for i = 2, #actors do
        local g = actors[i]
        if g ~= 0 and g ~= ownerGID and g ~= homunId and IsMonster(g) == 1 then
          local tgt = GetV(V_TARGET, g)
          if tgt == ownerGID or tgt == homunId then
            local ex, ey = GetV(V_POSITION, g)
            local dsq = distSq(ex - homunX, ey - homunY)
            if dsq < aBest then
              aClosest = g
              aBest = dsq
            end
          end
        end
      end
      if aClosest > 0 then newAggro = aClosest end
    end
    if newAggro > 0 and newAggro ~= st.lastSeenTarget
       and (not cfg.fleeOwnMarineSphere or not CHAI_MY_SUMMONS[newAggro]) then
      st.lastSeenTarget = newAggro
      st.lastAtkTarget = 0
      -- Arm pre-empt gate here too : the pickup chain (lines 172-178) is
      -- skipped on this path because lastSeenTarget is already set. Mirror
      -- its master-channel match so a tank/aggro acquisition still respects
      -- the master's autoloot window.
      if cfg.castSkill and cfg.followOwnerSkillTarget then
        local skT = V_SKILL_TARGET and GetV(V_SKILL_TARGET, ownerGID) or 0
        local agT = V_AGGRESSOR    and GetV(V_AGGRESSOR,    ownerGID) or 0
        if newAggro == skT or newAggro == agT then
          st.preemptCastAfter = GetTick() + K.PREEMPT_CAST_DELAY_MS
          chaiDevLog('debug', 'preempt_armed src=tank target=' .. newAggro
            .. ' skT=' .. skT .. ' agT=' .. agT)
        end
      end
    end
  end

  -- ===========================================================================
  -- 1+2. Target pickup. Runs only with no current target (or current target
  -- dead) and no manual lock — preserves long single-mob engagements and never
  -- lets the master's V_TARGET stomp an active engage.
  -- ===========================================================================
  if not st.manualLock and (st.lastSeenTarget == 0 or IsMonster(st.lastSeenTarget) ~= 1) then
    local skillTarget, aggroTarget, nativeTarget = 0, 0, 0
    if cfg.followOwnerSkillTarget then
      skillTarget = V_SKILL_TARGET and GetV(V_SKILL_TARGET, ownerGID) or 0
      aggroTarget = V_AGGRESSOR and GetV(V_AGGRESSOR, ownerGID) or 0
    end
    if cfg.followOwnerTarget then
      nativeTarget = GetV(V_TARGET, ownerGID) or 0
    end

    local defensiveTarget, whitelistTarget, plantTarget = 0, 0, 0

    -- Defensive scan (tank pickup) : closest mob targeting master/homun.
    if cfg.defendOwner then
      local closest, bestDistSq = 0, K.DEFENSIVE_MAX_RANGE_SQ
      for i = 2, #actors do
        local g = actors[i]
        if g ~= 0 and g ~= ownerGID and g ~= homunId and IsMonster(g) == 1 then
          local tgt = GetV(V_TARGET, g)
          if tgt == ownerGID or tgt == homunId then
            local ex, ey = GetV(V_POSITION, g)
            local dsq = distSq(ex - homunX, ey - homunY)
            if dsq < bestDistSq
               and (not cfg.followOwner or distSq(ex - ownerX, ey - ownerY) <= st.leashCapSq) then
              closest = g
              bestDistSq = dsq
            end
          end
        end
      end
      defensiveTarget = closest
    end

    -- Whitelist scan (auto-attack pickup) : closest mob with PER_MOB[mid].a,
    -- skipping blacklisted GIDs (watchdog-dropped unreachable mobs).
    if cfg.autoAttackMobs then
      local closest, bestDistSq = 0, K.WHITELIST_MAX_RANGE_SQ
      for i = 2, #actors do
        local g = actors[i]
        if g ~= 0 and g ~= ownerGID and g ~= homunId and IsMonster(g) == 1
           and not (st.engageBlacklist[g] and scanNow < st.engageBlacklist[g]) then
          local mobId = GetV(V_HOMUNTYPE, g)
          local mc = cfg.perMob[mobId]
          if (mc and mc.a) or not mc then
            local ex, ey = GetV(V_POSITION, g)
            local dsq = distSq(ex - homunX, ey - homunY)
            if dsq < bestDistSq
               and (not cfg.followOwner or distSq(ex - ownerX, ey - ownerY) <= st.leashCapSq) then
              closest = g
              bestDistSq = dsq
            end
          end
        end
      end
      whitelistTarget = closest
    end

    -- Plant assist scan : iterate own-summon GIDs, pick the closest valid mob
    -- one of them is already targeting (burst-combo with the plant). Highest
    -- priority in the chain.
    if cfg.fleeOwnMarineSphere then
      local closest, bestDistSq = 0, 999999
      for g, _y in pairs(CHAI_MY_SUMMONS) do
        local tgt = GetV(V_TARGET, g)
        if tgt and tgt > 0 and not CHAI_MY_SUMMONS[tgt] and IsMonster(tgt) == 1 then
          local ex, ey = GetV(V_POSITION, tgt)
          local dsq = distSq(ex - homunX, ey - homunY)
          if dsq < bestDistSq then
            closest = tgt
            bestDistSq = dsq
          end
        end
      end
      plantTarget = closest
    end

    -- Own-summons filter : zero out any candidate that's one of our own summons
    -- (O(1) GID lookup) so the homun never targets a Mandragora it summoned.
    if cfg.fleeOwnMarineSphere then
      if skillTarget     > 0 and CHAI_MY_SUMMONS[skillTarget]     then skillTarget     = 0 end
      if aggroTarget     > 0 and CHAI_MY_SUMMONS[aggroTarget]     then aggroTarget     = 0 end
      if defensiveTarget > 0 and CHAI_MY_SUMMONS[defensiveTarget] then defensiveTarget = 0 end
      if whitelistTarget > 0 and CHAI_MY_SUMMONS[whitelistTarget] then whitelistTarget = 0 end
      if nativeTarget    > 0 and CHAI_MY_SUMMONS[nativeTarget]    then nativeTarget    = 0 end
    end

    local target = (plantTarget     > 0 and IsMonster(plantTarget)     == 1) and plantTarget
               or  (skillTarget     > 0 and IsMonster(skillTarget)     == 1) and skillTarget
               or  (aggroTarget     > 0 and IsMonster(aggroTarget)     == 1) and aggroTarget
               or  (defensiveTarget > 0 and IsMonster(defensiveTarget) == 1) and defensiveTarget
               or  (whitelistTarget > 0 and IsMonster(whitelistTarget) == 1) and whitelistTarget
               or  (nativeTarget    > 0 and IsMonster(nativeTarget)    == 1) and nativeTarget
               or  0
    if target > 0 then
      st.lastSeenTarget = target
      -- Pre-empt loot delay : arm the cast hold only when the target came from
      -- a master-driven channel (skillTarget / aggroTarget) so the master lands
      -- a hit first ; cleared otherwise so native/whitelist pickups cast at once.
      if cfg.castSkill and cfg.followOwnerSkillTarget then
        if (skillTarget > 0 and target == skillTarget) or (aggroTarget > 0 and target == aggroTarget) then
          st.preemptCastAfter = GetTick() + K.PREEMPT_CAST_DELAY_MS
        else
          st.preemptCastAfter = 0
        end
      end
    else
      -- Explicit clear : we entered the gate because the target was 0 or no
      -- longer a monster, and pickup found no replacement — don't leave a dead
      -- GID in place (would make engage walk to / attack the corpse position).
      st.lastSeenTarget = 0
    end
  end
end

-- =============================================================================
-- flee.lua — splash-damage avoidance. Both functions return true when they
-- issue a flee Move (the orchestrator then returns, suspending the rest of the
-- tick) ; false otherwise.
--
-- fleeMarineSphere : own AM_DEMONSTRATION spheres (mob_id 1142) via the
--   CHAI_MY_SUMMONS GID table (own summons only).
-- fleePerMob       : any mob with PER_MOB[mid].f within danger range, via a
--   dedicated GetActors() scan (this step can early-return before sensing runs).
-- =============================================================================

local function fleeMarineSphere(homunId, cfg, st)
  local ownerGID = cfg.ownerGID
  local homunX, homunY = GetV(V_POSITION, homunId)
  local fleeGID, fleeBestDsq = 0, K.FLEE_DANGER_SQ + 1
  for g, _y in pairs(CHAI_MY_SUMMONS) do
    if GetV(V_HOMUNTYPE, g) == K.MARINE_SPHERE_MOB_ID then
      local ex, ey = GetV(V_POSITION, g)
      local dsq = distSq(ex - homunX, ey - homunY)
      if dsq <= K.FLEE_DANGER_SQ and dsq < fleeBestDsq then
        fleeGID, fleeBestDsq = g, dsq
      end
    end
  end
  if fleeGID > 0 then
    st.lastSeenTarget = 0
    st.lastAtkTarget = 0
    st.manualLock = false
    local ex, ey = GetV(V_POSITION, fleeGID)
    local vx, vy = homunX - ex, homunY - ey
    if vx == 0 and vy == 0 then
      -- Homun is on top of the sphere : flee along the owner direction instead.
      local ox, oy = GetV(V_POSITION, ownerGID)
      vx, vy = ox - homunX, oy - homunY
      if vx == 0 and vy == 0 then vx, vy = 1, 0 end
    end
    local mag = math.sqrt(vx * vx + vy * vy)
    if mag < 0.5 then mag = 1 end
    local fx = math.floor(ex + vx / mag * K.FLEE_TARGET_DISTANCE + 0.5)
    local fy = math.floor(ey + vy / mag * K.FLEE_TARGET_DISTANCE + 0.5)
    local now = GetTick()
    if st.motion ~= 1 or now - st.lastMoveTick > K.MOVE_REFRESH_MS then
      Move(homunId, fx, fy)
      st.lastMoveTick = now
    end
    return true
  end
  return false
end

local function fleePerMob(homunId, cfg, st)
  local ownerGID = cfg.ownerGID
  local homunX, homunY = GetV(V_POSITION, homunId)
  local fleeGID, fleeBestDsq = 0, K.FLEE_DANGER_SQ + 1
  -- GetActors() drain : GetResMsg AFTER GetActors clears the HOM_AGGRESSIVE=true
  -- setmsg poison this scan could otherwise leave in resMsg.
  local actors = GetActors()
  local _drain = GetResMsg(homunId)
  for i = 2, #actors do
    local g = actors[i]
    if g ~= 0 and g ~= ownerGID and g ~= homunId and IsMonster(g) == 1 then
      local mid = GetV(V_HOMUNTYPE, g)
      local mc = cfg.perMob[mid]
      if mc and mc.f then
        local ex, ey = GetV(V_POSITION, g)
        local dsq = distSq(ex - homunX, ey - homunY)
        if dsq <= K.FLEE_DANGER_SQ and dsq < fleeBestDsq then
          fleeGID = g
          fleeBestDsq = dsq
        end
      end
    end
  end
  if fleeGID > 0 then
    st.lastSeenTarget = 0
    st.lastAtkTarget = 0
    st.manualLock = false
    local fex, fey = GetV(V_POSITION, fleeGID)
    local vx, vy = homunX - fex, homunY - fey
    if vx == 0 and vy == 0 then
      local ox, oy = GetV(V_POSITION, ownerGID)
      vx, vy = ox - homunX, oy - homunY
      if vx == 0 and vy == 0 then vx, vy = 1, 0 end
    end
    local mag = math.sqrt(vx * vx + vy * vy)
    if mag < 0.5 then mag = 1 end
    local fx = math.floor(fex + vx / mag * K.FLEE_TARGET_DISTANCE + 0.5)
    local fy = math.floor(fey + vy / mag * K.FLEE_TARGET_DISTANCE + 0.5)
    local now = GetTick()
    if st.motion ~= 1 or now - st.lastMoveTick > K.MOVE_REFRESH_MS then
      Move(homunId, fx, fy)
      st.lastMoveTick = now
    end
    return true
  end
  return false
end

-- =============================================================================
-- engage.lua — combat. modeFor resolves a per-target mode from PER_MOB ;
-- globalMode derives the fallback mode from the global flags ; engage runs the
-- watchdog and dispatches to one of the 5 combat modes (all present, gated at
-- runtime by `resolvedMode`).
--
-- engage(homunId, cfg, st) returns true when it handled the current target
-- (the orchestrator then returns, skipping follow) ; false when there's no
-- engageable target (fall through to follow-owner / idle).
-- =============================================================================

-- Per-target mode from the per-mob table. Returns nil for a mob with no entry,
-- so the caller falls back to globalMode (back-compat). Precedence (immuable) :
-- f > (k+m) > k-only > m-only > (p+m) > p-only > nil.
local function modeFor(cfg, tid)
  if tid == 0 then return nil end
  local mc = cfg.perMob[GetV(V_HOMUNTYPE, tid)]
  if not mc then return nil end
  if mc.f then return 'abort' end
  if mc.k and mc.m then return 'skill-only-kite' end
  if mc.k and not mc.m then return 'kite-no-skill' end
  if mc.m and not mc.p then return 'skill-only-static' end
  if mc.p and mc.m then return 'skill+melee' end
  if mc.p and not mc.m then return 'attack' end
  return nil
end

-- Global engagement mode derived from the flag set.
local function globalMode(cfg)
  if cfg.castSkill and cfg.physAttack then return 'skill+melee' end
  if cfg.castSkill and not cfg.physAttack then
    if cfg.kite then return 'skill-only-kite' else return 'skill-only-static' end
  end
  if not cfg.castSkill and cfg.physAttack then return 'attack' end
  return 'idle'
end

local function engage(homunId, cfg, st)
  if not (st.lastSeenTarget > 0 and IsMonster(st.lastSeenTarget) == 1) then
    return false
  end

  local atkRange = GetV(V_ATTACKRANGE, homunId)
  if atkRange == nil or atkRange < 1 then atkRange = 1 end
  local homunX, homunY = GetV(V_POSITION, homunId)
  local targetX, targetY = GetV(V_POSITION, st.lastSeenTarget)
  local dx, dy = targetX - homunX, targetY - homunY
  -- Melee range = Chebyshev, NOT Euclidean : the server accepts an attack only
  -- when max(|dx|,|dy|) <= atkRange. A Euclidean buffer reports inMelee at a
  -- straight-line distance of 2, the server refuses, and the homun freezes.
  local inMelee = chebyshev(dx, dy) <= atkRange
  local resolvedMode = modeFor(cfg, st.lastSeenTarget) or globalMode(cfg)

  if resolvedMode == 'abort' then
    -- PER_MOB[mid].f : cancel the engage and let pickup re-run next tick.
    st.lastSeenTarget = 0
    st.lastAtkTarget = 0
    return true
  end

  -- ===========================================================================
  -- Optimistic SP resync (see initState/spEst). cyro pushes the SP decrement
  -- late, so the raw GetV(V_SP) stays stale-high right after a cast. We trust
  -- the raw read ONLY when it changed (real decrement OR regen) — overwriting
  -- the estimate ; while it's stale-frozen we keep the locally-deducted spEst,
  -- so the gate below reads spEst (never the raw SP) and won't re-fire against
  -- pre-cast SP. Skipped when not casting (saves the GetV call).
  -- ===========================================================================
  if cfg.castSkill then
    local spRaw = GetV(V_SP, homunId)
    if spRaw ~= st.spLastRaw then
      st.spEst = spRaw
      st.spLastRaw = spRaw
    end
  end

  -- Issue the configured skill at the current target, then deduct spCost from
  -- the optimistic estimate. The homun_skill_cast log pairs with the JS-side
  -- master_skill_cast event (shim/patches.js) ; tail logs/ai-*.jsonl and
  -- delta the two timestamps to confirm the pre-empt gate held the cast
  -- PREEMPT_CAST_DELAY_MS. sincePreemptMs == 0 → gate wasn't armed for this
  -- target (non-master channel, or castSkill/followOwnerSkillTarget off).
  local function castSkillAt(now)
    local sincePreempt = (st.preemptCastAfter > 0)
      and (now - st.preemptCastAfter + K.PREEMPT_CAST_DELAY_MS)
      or 0
    chaiDevLog('debug', 'homun_skill_cast skid=' .. cfg.skid
      .. ' level=' .. cfg.level
      .. ' target=' .. st.lastSeenTarget
      .. ' sincePreemptMs=' .. sincePreempt
      .. ' spEst=' .. st.spEst
      .. ' spCost=' .. st.spCost)
    SkillObject(homunId, cfg.level, cfg.skid, st.lastSeenTarget)
    st.lastCast = now
    st.spEst = math.max(0, st.spEst - st.spCost)
  end

  -- ===========================================================================
  -- Engage watchdog : drop a target we've been stuck on with no progress (no
  -- position change, no melee swing, and — when casting — no recent cast) for
  -- too long, so pickup re-runs and the homun stops freezing on an unreachable
  -- / un-attackable mob. The dropped GID is blacklisted so pickup picks a
  -- DIFFERENT mob next tick instead of re-selecting the same unreachable one.
  -- ===========================================================================
  local watchNow = GetTick()
  if st.lastSeenTarget ~= st.lastEngageGID then
    st.lastEngageGID = st.lastSeenTarget
    st.engageStuckSince = watchNow
    st.lastHomunX, st.lastHomunY = homunX, homunY
  else
    if homunX ~= st.lastHomunX or homunY ~= st.lastHomunY or isAttackMotion(st.motion)
       or (cfg.castSkill and watchNow - st.lastCast < K.STUCK_ENGAGE_TIMEOUT_MS) then
      st.engageStuckSince = watchNow
      st.lastHomunX, st.lastHomunY = homunX, homunY
    elseif watchNow - st.engageStuckSince > K.STUCK_ENGAGE_TIMEOUT_MS then
      chaiDevLog('warn', 'engage watchdog drop target=' .. st.lastSeenTarget
        .. ' homType=' .. tostring(GetV(V_HOMUNTYPE, st.lastSeenTarget))
        .. ' inMelee=' .. tostring(inMelee) .. ' motion=' .. st.motion
        .. ' stuckMs=' .. (watchNow - st.engageStuckSince)
        .. ' blacklist=' .. K.BLACKLIST_TTL_MS .. 'ms')
      st.engageBlacklist[st.lastSeenTarget] = watchNow + K.BLACKLIST_TTL_MS
      st.lastSeenTarget = 0
      st.lastAtkTarget = 0
      st.lastEngageGID = 0
      return true
    end
  end

  -- ===========================================================================
  -- Combat modes (all present, runtime-gated by resolvedMode). An 'idle' mode
  -- matches none → the homun holds (had a target but no configured action).
  -- ===========================================================================
  if resolvedMode == 'attack' then
    -- Melee only : attack in range, else chase.
    if inMelee then
      if st.lastSeenTarget ~= st.lastAtkTarget or not isAttackMotion(st.motion) then
        Attack(homunId, st.lastSeenTarget)
        st.lastAtkTarget = st.lastSeenTarget
      end
    else
      local now = GetTick()
      if st.motion ~= 1 or now - st.lastMoveTick > K.MOVE_REFRESH_MS then
        Move(homunId, targetX, targetY)
        st.lastMoveTick = now
      end
    end

  elseif resolvedMode == 'skill+melee' then
    -- Move-to-melee is the spine ; the skill cast is opportunistic.
    local now = GetTick()
    local distSqv = distSq(dx, dy)
    local inSkillRange = st.skillRangeSq == 0 or distSqv <= st.skillRangeSq
    local cdReady = now - st.lastCast > K.SKILL_COOLDOWN_MS
    local spOk = st.spEst >= st.spCost
    -- 'now >= st.preemptCastAfter' holds the cast during the pre-empt loot
    -- delay ; 0 for non-pre-empt targets → no-op.
    local canCast = inSkillRange and cdReady and spOk and now >= st.preemptCastAfter
    if inSkillRange and not canCast then
      chaiDevLog('debug', 'cast_gate mode=skill+melee target=' .. st.lastSeenTarget
        .. ' distSq=' .. distSqv
        .. ' skillRangeSq=' .. st.skillRangeSq
        .. ' cdReady=' .. tostring(cdReady)
        .. ' spOk=' .. tostring(spOk)
        .. ' spEst=' .. tostring(st.spEst)
        .. ' spCost=' .. tostring(st.spCost)
        .. ' preemptReady=' .. tostring(now >= st.preemptCastAfter)
        .. ' now=' .. now
        .. ' preemptCastAfter=' .. st.preemptCastAfter
        .. ' inMelee=' .. tostring(inMelee)
        .. ' motion=' .. tostring(st.motion)
        .. ' hadMelee=' .. tostring(st.hadMeleeSinceLastCast))
    end
    if inMelee then
      -- hadMeleeSinceLastCast gate : require ≥1 observed swing between casts so
      -- a too-short SKILL_COOLDOWN_MS guess doesn't re-fire the cast while the
      -- server is still in after-cast-delay (which would starve the melee).
      if isAttackMotion(st.motion) then st.hadMeleeSinceLastCast = true end
      if canCast and st.hadMeleeSinceLastCast then
        castSkillAt(now)
        st.lastAtkTarget = 0
        st.hadMeleeSinceLastCast = false
      elseif st.lastSeenTarget ~= st.lastAtkTarget or not isAttackMotion(st.motion) then
        Attack(homunId, st.lastSeenTarget)
        st.lastAtkTarget = st.lastSeenTarget
      end
    else
      -- Out of melee : cast opportunistically while chasing, and always
      -- re-issue Move (the a.30 followOwner moveGate was a `not inMelee` prefix,
      -- which is a no-op in this already-out-of-melee branch).
      if canCast then
        castSkillAt(now)
        st.hadMeleeSinceLastCast = false
      end
      if st.motion ~= 1 or now - st.lastMoveTick > K.MOVE_REFRESH_MS then
        Move(homunId, targetX, targetY)
        st.lastMoveTick = now
      end
    end

  elseif resolvedMode == 'skill-only-kite' then
    -- Walk to (skillRange-1) cells from the target on the target->homun ray,
    -- cast when in range. rangeSq == 0 (unknown range) → cast immediately.
    local now = GetTick()
    local distSqv = distSq(dx, dy)
    if st.skillRangeSq == 0 then
      if now - st.lastCast > K.SKILL_COOLDOWN_MS and st.spEst >= st.spCost and now >= st.preemptCastAfter then
        castSkillAt(now)
      end
    else
      local d = math.sqrt(distSqv)
      if d < 0.5 then d = 1 end
      local kx = math.floor(targetX + (homunX - targetX) / d * st.minR + 0.5)
      local ky = math.floor(targetY + (homunY - targetY) / d * st.minR + 0.5)
      if distSq(kx - homunX, ky - homunY) > 1 then
        if st.motion ~= 1 or now - st.lastMoveTick > K.MOVE_REFRESH_MS then
          Move(homunId, kx, ky)
          st.lastMoveTick = now
        end
      else
        if now - st.lastCast > K.SKILL_COOLDOWN_MS and st.spEst >= st.spCost and now >= st.preemptCastAfter then
          castSkillAt(now)
        end
      end
    end

  elseif resolvedMode == 'skill-only-static' then
    -- Cast only when already in range ; never move.
    local now = GetTick()
    local distSqv = distSq(dx, dy)
    if st.skillRangeSq == 0 or distSqv <= st.skillRangeSq then
      if now - st.lastCast > K.SKILL_COOLDOWN_MS and st.spEst >= st.spCost and now >= st.preemptCastAfter then
        castSkillAt(now)
      end
    end

  elseif resolvedMode == 'kite-no-skill' then
    -- Walk to (kiteRange-1) cells without casting (track / shadow a mob).
    local now = GetTick()
    local d = math.sqrt(distSq(dx, dy))
    if d < 0.5 then d = 1 end
    local kx = math.floor(targetX + (homunX - targetX) / d * st.kiteMinR + 0.5)
    local ky = math.floor(targetY + (homunY - targetY) / d * st.kiteMinR + 0.5)
    if distSq(kx - homunX, ky - homunY) > 1 then
      if st.motion ~= 1 or now - st.lastMoveTick > K.MOVE_REFRESH_MS then
        Move(homunId, kx, ky)
        st.lastMoveTick = now
      end
    end
  end

  return true
end

-- =============================================================================
-- follow.lua — leash + idle behaviour.
--
-- leash(homunId, cfg, st)        : drop target and run home if the master is
--   further than LEASH_MAX cells away (returns true → orchestrator returns).
--   Bypassed by manualLock so a user Alt+RClick on a far mob isn't yanked back.
-- followOwner(homunId, cfg, st)  : the idle fallback — regroup near own plants,
--   else walk back to the master (when followOwner is on) or stay put.
-- =============================================================================

local function leash(homunId, cfg, st)
  if st.manualLock then return false end
  local homunX, homunY = GetV(V_POSITION, homunId)
  local ox, oy = GetV(V_POSITION, cfg.ownerGID)
  if distSq(ox - homunX, oy - homunY) > K.LEASH_MAX_SQ then
    st.lastSeenTarget = 0
    st.lastAtkTarget = 0
    MoveToOwner(homunId)
    return true
  end
  return false
end

-- Walk near the closest own plant when idle. Excludes Marine Sphere (don't camp
-- on exploding summons). Bounded by LEASH_MAX_SQ so we never walk further from
-- the master than the leash allows. Returns true when it issues a Move.
local function plantRegroup(homunId, cfg, st)
  local homunX, homunY = GetV(V_POSITION, homunId)
  local pClosest, pBestDsq = 0, K.LEASH_MAX_SQ
  for g, _y in pairs(CHAI_MY_SUMMONS) do
    if GetV(V_HOMUNTYPE, g) ~= K.MARINE_SPHERE_MOB_ID then
      local ex, ey = GetV(V_POSITION, g)
      local dsq = distSq(ex - homunX, ey - homunY)
      -- Buffer (~2 cells) prevents jitter when already adjacent to the plant.
      if dsq > 4 and dsq < pBestDsq then
        pClosest = g
        pBestDsq = dsq
      end
    end
  end
  if pClosest > 0 then
    local ex, ey = GetV(V_POSITION, pClosest)
    local now = GetTick()
    if st.motion ~= 1 or now - st.lastMoveTick > K.MOVE_REFRESH_MS then
      Move(homunId, ex, ey)
      st.lastMoveTick = now
    end
    return true
  end
  return false
end

local function followOwner(homunId, cfg, st)
  st.lastAtkTarget = 0
  if cfg.followOwner then
    -- Don't fight a walk in progress ; let it finish before re-evaluating.
    if st.motion == 1 then return end
    if cfg.fleeOwnMarineSphere and plantRegroup(homunId, cfg, st) then return end
    local ox, oy = GetV(V_POSITION, cfg.ownerGID)
    local homunX, homunY = GetV(V_POSITION, homunId)
    -- Only close in when more than 3 cells away (9 = 3²).
    if distSq(ox - homunX, oy - homunY) > 9 then MoveToOwner(homunId) end
  else
    -- followOwner off : stay where we are, but still regroup on own plants.
    if cfg.fleeOwnMarineSphere then plantRegroup(homunId, cfg, st) end
  end
end

-- =============================================================================
-- main.lua — chunk-top global resets, runtime state factory, per-tick
-- orchestrator, and the AI() entry point. `CFG` (the serialized config table)
-- is injected by presets.js immediately before this block, so it is in scope
-- as an upvalue for initState / tick / AI below.
-- =============================================================================

-- Global contract resets (run once at Apply). CHAI_AGGRESSOR / CHAI_MY_SUMMONS
-- are also managed by the shim ; resetting here keeps the script self-contained
-- in degraded mode (no shim). CHAI_VERBOSE is preserved across reloads.
_G.CHAI_AGGRESSOR = 0
_G.CHAI_MY_SUMMONS = _G.CHAI_MY_SUMMONS or {}
if _G.CHAI_VERBOSE == nil then _G.CHAI_VERBOSE = true end

-- Build the mutable per-homun runtime state (created once per Apply). Derived
-- read-only constants (skill range, kite distance, leash cap, SP floor) are
-- folded in via deriveConst. Call gates (usesSense / hasEngage / hasPerMobFlee)
-- are precomputed so the hot tick path never re-scans PER_MOB.
local function initState(cfg)
  local d = deriveConst(cfg)
  local st = {
    lastSeenTarget = 0,
    lastAtkTarget = 0,
    userMoveDeadline = 0,
    manualLock = false,
    lastMoveTick = 0,
    lastCast = 0,
    hadMeleeSinceLastCast = true,
    preemptCastAfter = 0,
    -- Optimistic SP accounting. cyro pushes the homun's SP decrement late /
    -- in bursts, so entity.life.sp (what GetV(V_SP) reads — same source as the
    -- SP bar) stays stale-high right after a cast. The raw read would re-pass
    -- `sp >= spCost` and re-fire SkillObject every cooldown → server rejects
    -- ("Insufficient SP" spam). spEst tracks an optimistic estimate : the gate
    -- reads spEst (not the raw SP), each cast deducts spCost locally, and any
    -- packet change (real decrement OR regen) resyncs spEst to the truth.
    spEst = 0,
    spLastRaw = -1,
    engageStuckSince = 0,
    lastEngageGID = 0,
    lastHomunX = -1,
    lastHomunY = -1,
    engageBlacklist = {},
    motion = 0,
    -- derived consts (never mutated after init)
    skillRangeSq = d.skillRangeSq,
    minR = d.minR,
    kiteRange = d.kiteRange,
    kiteMinR = d.kiteMinR,
    leashReach = d.leashReach,
    leashCapSq = d.leashCapSq,
    spCost = d.spCost,
  }
  st.usesSense = cfg.followOwnerSkillTarget or cfg.followOwnerTarget or cfg.defendOwner
    or cfg.autoAttackMobs or cfg.fleeOwnMarineSphere or cfg.takeAggro
  st.hasEngage = globalMode(cfg) ~= 'idle'
  st.hasPerMobFlee = false
  for _, mc in pairs(cfg.perMob) do
    if mc.f then st.hasPerMobFlee = true end
    if mc.p or mc.m or mc.k then st.hasEngage = true end
  end
  return st
end

local ST = initState(CFG)

-- Per-tick orchestrator. Order : userCmd -> leash -> flee -> sense -> engage
-- -> follow. Each step that takes over the tick returns early.
local function tick(homunId, cfg, st)
  st.motion = GetV(V_MOTION, homunId)

  -- 0. Consume user manual commands (Alt + right-click).
  --   '3,<targetGID>' -> MSG_ATTACK : lock onto target until it dies / leaves.
  --   '1,<x>,<y>'     -> MSG_MOVE   : walk to (x,y), suspend AI for 3s.
  local userCmd, a1, a2 = readUserCmd(homunId)
  if userCmd > 0 then
    chaiDevLog('debug', 'msg cmd=' .. userCmd .. ' a1=' .. a1 .. ' a2=' .. a2)
  end
  if userCmd == 3 then
    if a1 > 0 and IsMonster(a1) == 1 then
      st.lastSeenTarget = a1
      st.manualLock = true
      st.lastAtkTarget = 0
      st.userMoveDeadline = 0
      chaiDevLog('info', 'manual lock acquired target=' .. a1)
    else
      chaiDevLog('warn', 'manual lock REJECTED a1=' .. a1 .. ' isMonster=' .. tostring(IsMonster(a1)))
    end
  elseif userCmd == 1 then
    st.lastSeenTarget = 0
    st.lastAtkTarget = 0
    st.manualLock = false
    st.userMoveDeadline = GetTick() + 3000
    Move(homunId, a1, a2)
    return
  end

  if st.userMoveDeadline > 0 then
    if GetTick() < st.userMoveDeadline then return end
    st.userMoveDeadline = 0
  end

  -- Release the manual lock when the chosen target is dead / out of screen.
  if st.manualLock and (st.lastSeenTarget == 0 or IsMonster(st.lastSeenTarget) ~= 1) then
    st.manualLock = false
    st.lastSeenTarget = 0
  end

  -- 0.3. Leash to master.
  if cfg.followOwner and leash(homunId, cfg, st) then return end
  -- 0.5 / 0.6. Flee splash damage.
  if cfg.fleeOwnMarineSphere and fleeMarineSphere(homunId, cfg, st) then return end
  if st.hasPerMobFlee and fleePerMob(homunId, cfg, st) then return end
  -- 0.7 + 1+2. Take aggro + target pickup.
  if st.usesSense then sense(homunId, cfg, st) end
  -- 3. Engage the remembered target.
  if st.hasEngage and engage(homunId, cfg, st) then return end
  -- 4. Idle : follow owner / regroup / stay put.
  followOwner(homunId, cfg, st)
end

-- pcall self-heal : a Lua exception on an edge-case target no longer freezes
-- the homun — log to the dev-log and clear the engage state so the next tick
-- recovers on its own.
function AI(homunId)
  CFG.ownerGID = GetV(V_OWNER, homunId) or CFG.ownerGID
  local ok, err = pcall(tick, homunId, CFG, ST)
  if not ok then
    chaiDevLog('error', 'AI tick error: ' .. tostring(err) .. ' lastSeenTarget=' .. ST.lastSeenTarget)
    ST.lastSeenTarget = 0
    ST.lastAtkTarget = 0
    ST.manualLock = false
  end
end
