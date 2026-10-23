-- CoopCombat: controls live in the admin panel (panel/). The only hotkey is F9 (sniper, needs your crosshair). Walking up to a downed player revives them.
-- Health in Astroneer is normalized: 1.0 = full, 0 = dead.
-- At 0 health a player is "downed" instead of dying: slow crawl, no jumping, immune, bleeds out after BLEEDOUT_SECONDS.
local DAMAGE = 0.25
local DOWNED_HEALTH = 1.0 -- fraction of max health you get back when knocked down
local BLEEDOUT_SECONDS = 30
local REVIVE_RANGE = 400 -- cm
local CRAWL_SPEED_SCALE = 0.15
local EXPLODE_COUNT = 50
local REVIVE_SECONDS = 3 -- stand this long next to a downed player to revive them

local downed = {} -- address -> { astro, speed, jump, boost, token }
local nextToken = 0

-- Breadcrumb: the last step the mod reached, rewritten constantly. If the game crashes, panel/breadcrumb.txt
-- says what the mod was doing at that moment.
local crumbPath = (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("[Ss]cripts[\\/]main%.lua$", "")) .. "panel\\breadcrumb.txt"
local function crumb(step)
    local f = io.open(crumbPath, "w")
    if f then
        f:write(os.date("%H:%M:%S") .. " " .. step .. "\n")
        f:close()
    end
end

local function pawnOf(pc)
    local ok, pawn = pcall(function()
        if not pc:IsValid() then return nil end
        return pc:K2_GetPawn()
    end)
    if ok and pawn and pawn:IsValid() then return pawn end
    return nil
end

-- safe while the game is loading or respawning: returns nil, {} when there are no valid players
local function getPlayers()
    local me, others = nil, {}
    local ok = pcall(function()
        crumb("getPlayers: FindAllOf")
        local list = FindAllOf("PlayController")
        if type(list) ~= "table" then return end
        for i = 1, #list do
            crumb("getPlayers: controller " .. i)
            local pc = list[i]
            local pawn = pawnOf(pc)
            if pawn then
                local okL, isLocal = pcall(function() return pc:IsLocalController() end)
                if okL and isLocal then me = pawn else table.insert(others, pawn) end
            end
        end
    end)
    if not ok then return nil, {} end
    return me, others
end

-- background loops share one lookup per tick instead of scanning every object several times per frame
local cache = { t = -1, me = nil }
local function getLocalCached()
    local now = os.clock()
    if now - cache.t > 0.02 then
        cache.t = now
        local me = getPlayers()
        cache.me = me
    end
    return cache.me
end

local function dist(a, b)
    local la, lb = a:K2_GetActorLocation(), b:K2_GetActorLocation()
    local dx, dy, dz = la.X - lb.X, la.Y - lb.Y, la.Z - lb.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Creative mode: the game takes no natural damage, so our own fall-damage handling must stand down too.
-- (Panel actions like Hurt/Explode are admin overrides and still work.) Re-read once a second.
local creativeCache = { t = -10, on = false }
local function creativeOn()
    local now = os.clock()
    if now - creativeCache.t > 1.0 then
        creativeCache.t = now
        local ok, v = pcall(function()
            local gs = FindFirstOf("AstroGameState")
            if gs == nil or not gs:IsValid() then return false end
            local c = gs.bCreativeModeActive
            return c == true or (type(c) == "number" and c ~= 0)
        end)
        creativeCache.on = ok and v == true
    end
    return creativeCache.on
end

local function findByAddress(addr)
    local me, others = getPlayers()
    if me and me:GetAddress() == addr then return me end
    for _, a in ipairs(others) do
        if a:GetAddress() == addr then return a end
    end
    return nil
end


local function say(fmt, ...) print("[CoopCombat] " .. string.format(fmt, ...) .. "\n") end

local function charName(astro)
    local ok, n = pcall(function() return astro:GetOnlinePlayerName():ToString() end)
    if ok and type(n) == "string" and n ~= "" then return n end
    return "Player"
end

local feed, sendEvt -- kill feed / network events, defined with the chat code below
local allowDamage -- creative-mode PvP switch, defined below

local hudWasOn, hudErrShown = false, false

-- HUD text is looked up by path every time instead of being kept in a variable: the HUD is rebuilt when you
-- respawn and the game frees the old widgets later, so a stored reference becomes a dangling pointer
-- (that crashed UE4SS about 20 seconds after every death).
local function getText(hud, name, size, y, color, x, ax)
    local tree = hud.WidgetTree
    local full = tree:GetFullName():match("^%S+%s+(.+)$")
    if full then
        local found = StaticFindObject(full .. "." .. name)
        if found ~= nil and found:IsValid() then return found end
    end
    local tb = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), tree, FName(name))
    tb:SetText(FText(""))
    tb.Font.Size = size
    tb:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 })
    tb:SetShadowOffset({ X = 3, Y = 3 })
    tb:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 1 })
    local slot = tree.RootWidget:AddChild(tb)
    slot:SetAnchors({ Minimum = { X = x or 0.5, Y = y }, Maximum = { X = x or 0.5, Y = y } })
    slot:SetAlignment({ X = ax or 0.5, Y = 0.5 })
    slot:SetPosition({ X = 0, Y = 0 })
    slot:SetAutoSize(true)
    slot:SetZOrder(100)
    return tb
end
local rescueFailed = false
local finalDeath = {} -- address -> true while a bleed-out kill is in progress, so it isn't rescued

-- HUD: reuse the game's own low-health overlay (HealthImage) and a text block (Tutorial_Text)
local savedHud = nil
local function setOverlay(hud, on)
    crumb("setOverlay " .. tostring(on))
    pcall(function()
        if on then
            if not savedHud then
                savedHud = { low = hud.LowHealthColor, color = hud.HealthImage:GetColorAndOpacity(), vis = hud.HealthImage:GetVisibility() }
            end
            hud.HealthImageOpacity = 1.0
            hud.LowHealthColor = { R = 0.7, G = 0.0, B = 0.0, A = 0.85 }
            hud.HealthImage:SetVisibility(4) -- HitTestInvisible
            hud.HealthImage:SetColorAndOpacity({ R = 0.7, G = 0.0, B = 0.0, A = 0.85 })
        else
            hud.HealthImageOpacity = 0.0
            if savedHud then
                hud.LowHealthColor = savedHud.low
                hud.HealthImage:SetColorAndOpacity(savedHud.color)
                hud.HealthImage:SetVisibility(savedHud.vis)
                savedHud = nil
            else
                hud.HealthImage:SetColorAndOpacity({ R = 0.7, G = 0.0, B = 0.0, A = 0.0 })
            end
        end
    end)
end

-- returns true once the HUD was reachable
local function setHud(on, secondsLeft)
    crumb("setHud " .. tostring(on))
    local hud = FindFirstOf("PlayWidgetInstance_C")
    if not hud or not hud:IsValid() then return false end
    setOverlay(hud, on)
    local ok, err = pcall(function()
        local t = getText(hud, "CoopBleedText", 56, 0.18, { R = 1.0, G = 0.1, B = 0.1, A = 1.0 })
        if on then
            t:SetText(FText(string.format("BLEEDING OUT  %d", math.max(0, math.ceil(secondsLeft)))))
            t:SetVisibility(4)
        else
            t:SetText(FText(""))
            t:SetVisibility(1)
        end
    end)
    if not ok and not hudErrShown then
        hudErrShown = true
        say("HUD text error: %s", tostring(err))
    end
    return true
end

local revive -- defined below, used by the walk-up revive
local chatTick -- defined below, called from hudTick

local function alive(o)
    local ok, v = pcall(function() return o ~= nil and o:IsValid() end)
    return ok and v == true
end

-- revive prompt, shown while standing within REVIVE_RANGE of a downed player
local promptWasOn = false
local reviveTarget, reviveStart = nil, 0
local function setPrompt(show, text)
    crumb("setPrompt " .. tostring(show))
    local hud = FindFirstOf("PlayWidgetInstance_C")
    if not alive(hud) then return end
    local ok, err = pcall(function()
        local t = getText(hud, "CoopReviveText", 40, 0.7, { R = 1.0, G = 1.0, B = 1.0, A = 1.0 })
        if show then
            t:SetText(FText(text or "Reviving..."))
            t:SetVisibility(4)
        else
            t:SetText(FText(""))
            t:SetVisibility(1)
        end
    end)
    if not ok then say("prompt error: %s", tostring(err)) end
end

local function nearbyDownedOther(me, others)
    for _, a in ipairs(others) do
        if downed[a:GetAddress()] and dist(me, a) <= REVIVE_RANGE then return a end
    end
    return nil
end

local function hudTick()
    crumb("hudTick")
    local me, others = getPlayers()
    -- forget downed players that are gone (died, respawned, left). Compare addresses only.
    local present = {}
    if me then present[me:GetAddress()] = true end
    for _, a in ipairs(others) do present[a:GetAddress()] = true end
    for key in pairs(downed) do
        if not present[key] then downed[key] = nil end
    end
    local st = me and downed[me:GetAddress()]
    local target = (me ~= nil and st == nil) and nearbyDownedOther(me, others) or nil
    if target then
        local tk = target:GetAddress()
        if reviveTarget ~= tk then reviveTarget, reviveStart = tk, os.clock() end
        local left = REVIVE_SECONDS - (os.clock() - reviveStart)
        if left <= 0 then
            revive(target, charName(me))
            reviveTarget = nil
            setPrompt(false)
            promptWasOn = false
        else
            setPrompt(true, string.format("REVIVING...  %d", math.ceil(left)))
            promptWasOn = true
        end
    else
        reviveTarget = nil
        if promptWasOn then
            promptWasOn = false
            setPrompt(false)
        end
    end
    if st then
        setHud(true, BLEEDOUT_SECONDS - (os.clock() - st.startedAt))
        hudWasOn = true
    elseif hudWasOn then
        if setHud(false) then hudWasOn = false end
    end
    pcall(chatTick)
end

local function goDown(astro, by)
    crumb("goDown")
    local key = astro:GetAddress()
    if downed[key] then return end
    local mv = astro.AstroMovementComponent
    nextToken = nextToken + 1
    local st = { speed = mv.MaxSpeed, jump = mv.JumpVerticalImpulse, boost = mv.JumpBoostImpulse, token = nextToken, startedAt = os.clock() }
    downed[key] = st
    astro.Health = astro.MaxHealth * DOWNED_HEALTH
    mv.MaxSpeed = st.speed * CRAWL_SPEED_SCALE
    mv.JumpVerticalImpulse = 0
    mv.JumpBoostImpulse = 0
    say("DOWNED! %d seconds to be revived", BLEEDOUT_SECONDS)
    local who = charName(astro)
    local safe = who:gsub("|", "/")
    pcall(sendEvt, "DOWN|" .. safe .. "|" .. BLEEDOUT_SECONDS)
    pcall(feed, by and (by .. " knocked down " .. who) or (who .. " was knocked down"))
    local token = st.token
    ExecuteWithDelay(BLEEDOUT_SECONDS * 1000, function()
        ExecuteInGameThread(function()
            local cur = downed[key]
            if not cur or cur.token ~= token then return end
            local a = findByAddress(key)
            if not a then downed[key] = nil return end
            say("bled out")
            downed[key] = nil
            allowDamage(a)
            pcall(function() a:AuthoritySetIsImmuneToDamage(false, a) end)
            finalDeath[key] = true
            local ok3, err3 = pcall(function() a:AuthorityForceKillAstro() end)
            ExecuteWithDelay(5000, function() finalDeath[key] = nil end)
            if not ok3 then say("could not kill: %s", tostring(err3)) end
            pcall(sendEvt, "UP|" .. safe .. "|dead")
            pcall(feed, who .. " bled out")
        end)
    end)
end

function revive(astro, by)
    crumb("revive")
    local key = astro:GetAddress()
    local st = downed[key]
    if not st then return end
    downed[key] = nil
    local mv = astro.AstroMovementComponent
    mv.MaxSpeed = st.speed
    mv.JumpVerticalImpulse = st.jump
    mv.JumpBoostImpulse = st.boost
    pcall(function() astro:AuthoritySetIsImmuneToDamage(false, astro) end)
    astro.Health = 0.5
    say("REVIVED")
    local who = charName(astro)
    local safe = who:gsub("|", "/")
    pcall(sendEvt, "UP|" .. safe .. "|revived")
    pcall(feed, by and (by .. " revived " .. who) or (who .. " was revived"))
end

-- Creative mode protects players from damage. PvP should still work there, so before we hurt/kill/blow up
-- a player we switch their invincibility off for a few seconds, then put creative's protection back.
local PVP_IN_CREATIVE = 1
local pvpSaved = {} -- address -> { inv, imm, token }
function allowDamage(astro)
    if PVP_IN_CREATIVE == 0 or not creativeOn() then return end
    crumb("allowDamage")
    local key = astro:GetAddress()
    local rec = pvpSaved[key]
    if not rec then
        rec = { token = 0 }
        local ok1, inv = pcall(function() return astro.bInvincible end)
        local ok2, imm = pcall(function() return astro.bIsImmuneToDamage end)
        if ok1 then rec.inv = inv end
        if ok2 then rec.imm = imm end
        pvpSaved[key] = rec
    end
    rec.token = rec.token + 1
    local token = rec.token
    pcall(function() astro.bInvincible = false end)
    pcall(function() astro.bIsImmuneToDamage = false end)
    ExecuteWithDelay(4000, function()
        ExecuteInGameThread(function()
            local cur = pvpSaved[key]
            if not cur or cur.token ~= token then return end
            pvpSaved[key] = nil
            local a = findByAddress(key)
            if a and creativeOn() then
                if cur.inv ~= nil then pcall(function() a.bInvincible = cur.inv end) end
                if cur.imm ~= nil then pcall(function() a.bIsImmuneToDamage = cur.imm end) end
            end
        end)
    end)
end

local function killPlayer(astro, by)
    crumb("killPlayer")
    allowDamage(astro)
    local key = astro:GetAddress()
    local who = charName(astro)
    local safe = who:gsub("|", "/")
    downed[key] = nil
    finalDeath[key] = true
    pcall(function() astro:AuthoritySetIsImmuneToDamage(false, astro) end)
    pcall(function() astro:AuthorityForceKillAstro() end)
    ExecuteWithDelay(5000, function() finalDeath[key] = nil end)
    pcall(sendEvt, "UP|" .. safe .. "|dead")
    pcall(feed, by and (by .. " killed " .. who) or (who .. " died"))
end

local function hurt(astro, amount, by)
    allowDamage(astro)
    local before = astro.Health
    local after = before - amount
    if downed[astro:GetAddress()] then
        if after <= 0 then
            say("killed while downed")
            killPlayer(astro, by)
        else
            astro.Health = after
            say("Health %.2f -> %.2f (downed)", before, after)
        end
    elseif after <= 0 then
        goDown(astro, by)
    else
        astro.Health = after
        say("Health %.2f -> %.2f", before, after)
    end
end


-- Fall damage: the game kills in one native step, so hold damage immunity while falling fast,
-- then apply the fall damage ourselves on landing (which can down the player instead of killing).
local fall = { armed = false, peak = 0, initiator = nil }
local fallLogged = false

local function speedOf(mv)
    local v = mv.Velocity
    return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
end

local function fallTick()
    crumb("fallTick")
    local me = getLocalCached()
    if not me or not me:IsValid() then return end
    local key = me:GetAddress()
    if creativeOn() then
        if fall.armed then
            fall.armed = false
            pcall(function() me:AuthoritySetIsImmuneToDamage(false, me) end)
        end
        return
    end
    if downed[key] or finalDeath[key] then
        fall.armed = false
        return
    end
    local mv = me.AstroMovementComponent
    local minV, maxV = mv.MinFallingDamageVelocity, mv.MaxFallingDamageVelocity
    if not fallLogged then
        fallLogged = true
        say("fall damage velocity range: %.0f .. %.0f", minV, maxV)
    end
    local speed = speedOf(mv)
    if not fall.armed then
        if speed > minV * 0.5 then
            fall.armed, fall.peak = true, speed
            pcall(function() me:AuthoritySetIsImmuneToDamage(true, me) end)
        end
    else
        if speed > fall.peak then fall.peak = speed end
        if speed < fall.peak * 0.5 then
            -- landed
            fall.armed = false
            pcall(function() me:AuthoritySetIsImmuneToDamage(false, me) end)
            local dmg = (fall.peak - minV) / math.max(1, maxV - minV)
            if dmg > 0 then
                say("landed at %.0f, fall damage %.2f", fall.peak, dmg)
                hurt(me, dmg)
            end
        elseif speed < minV * 0.3 then
            fall.armed = false
            pcall(function() me:AuthoritySetIsImmuneToDamage(false, me) end)
        end
    end
end

-- Natural damage (falls etc.) goes through native code, so catch it instead of replacing it.
-- watcher: health about to hit zero -> downed instead
local function watcherTick()
    crumb("watcher")
    local me = getLocalCached()
    if me and not downed[me:GetAddress()] and not finalDeath[me:GetAddress()] and me.bIsAlive ~= 0 and me.Health <= 0.02 then
        say("caught lethal health (%.3f)", me.Health)
        goDown(me)
    end
end


-- Explode: spawn EXPLODE_COUNT dynamite on the player and detonate them, in small batches to avoid a hitch.
local function explodePlayer(astro, by)
    crumb("explodePlayer")
    allowDamage(astro)
    pcall(feed, charName(astro) .. " was blown up" .. (by and (" by " .. by) or ""))
    local key = astro:GetAddress()
    downed[key] = nil
    finalDeath[key] = true -- the blast is meant to kill: don't rescue into the downed state
    ExecuteWithDelay(10000, function() finalDeath[key] = nil end)
    local world = astro:GetWorld()
    local class = StaticFindObject("/Game/Components_Small/Dynamite.Dynamite_C")
    if not alive(world) or not alive(class) then say("explode: no world or dynamite class") return end
    local loc = astro:K2_GetActorLocation()
    local total, batch = EXPLODE_COUNT, 10
    say("exploding player with %d dynamite", total)
    local function spawnBatch(from)
        if from > total then return end
        local spawned = {}
        for i = from, math.min(from + batch - 1, total) do
            local pos = { X = loc.X + (math.random() - 0.5) * 80, Y = loc.Y + (math.random() - 0.5) * 80, Z = loc.Z + 20 + math.random() * 80 }
            local ok, dyn = pcall(function() return world:SpawnActor(class, pos, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
            if ok and alive(dyn) then table.insert(spawned, dyn) end
        end
        ExecuteWithDelay(250, function()
            ExecuteInGameThread(function()
                for _, dyn in ipairs(spawned) do
                    if alive(dyn) then
                        local ok = pcall(function() dyn.Explosive:Detonate() end)
                        if not ok then pcall(function() dyn["SERVER Detonate"](dyn) end) end
                    end
                end
            end)
        end)
        ExecuteWithDelay(120, function() ExecuteInGameThread(function() pcall(spawnBatch, from + batch) end) end)
    end
    spawnBatch(1)
end

-- ===== Shooting =====
-- The host resolves every shot (only the host can see all the players). Clients send the aim to the host.
local SNIPE_DAMAGE = 0.5
local HIT_RADIUS = 80 -- cm, how far from the crosshair line still counts as a hit
local GUN_DAMAGE = 0.2
local GUN_COOLDOWN = 0.4
local GUN_ITEM = "WorkLight" -- the item you hold to use the gun
local GUN_KEY = "LMB"
local GUN_PROPS = {
    WorkLight = "/Game/Components_Small/WorkLight.WorkLight_C",
    FloodLight = "/Game/Components_Small/FloodLight_BP.FloodLight_BP_C",
    Beacon = "/Game/Components_Small/Beacon_Small_Item.Beacon_Small_Item_C",
    Skybreaker = "/Game/Components_Small/Skybreaker.Skybreaker_C",
    Battery = "/Game/Components_Small/Battery.Battery_C",
}
local GUN_KEYS = { LMB = true, RMB = true, MMB = true, MOUSE4 = true, MOUSE5 = true }

local function getLocalController()
    local list = FindAllOf("PlayController")
    if type(list) ~= "table" then return nil end
    for i = 1, #list do
        local pc = list[i]
        local ok, isLocal = pcall(function() return pc:IsValid() and pc:IsLocalController() end)
        if ok and isLocal then return pc end
    end
    return nil
end

local function isHost(pc)
    local ok, v = pcall(function() return pc:HasAuthority() end)
    return ok and v == true
end

-- the player (other than the shooter) closest to a ray
local function bestOnRay(shooterAddr, origin, dir)
    local me, others = getPlayers()
    local all = {}
    if me then table.insert(all, me) end
    for _, a in ipairs(others) do table.insert(all, a) end
    local best, bestMiss, bestRange, count = nil, math.huge, 0, 0
    for _, a in ipairs(all) do
        if a:GetAddress() ~= shooterAddr then
            count = count + 1
            local loc = a:K2_GetActorLocation()
            local dx, dy, dz = loc.X - origin.X, loc.Y - origin.Y, loc.Z - origin.Z
            local along = dx * dir.X + dy * dir.Y + dz * dir.Z
            if along > 0 then
                local px, py, pz = dx - along * dir.X, dy - along * dir.Y, dz - along * dir.Z
                local miss = math.sqrt(px * px + py * py + pz * pz)
                if miss < bestMiss then best, bestMiss, bestRange = a, miss, along end
            end
        end
    end
    return best, bestMiss, bestRange, count
end

-- host only: one shot fired by shooterPC (the host's own controller, or a client's)
local function resolveShot(shooterPC, origin, dir, label)
    crumb("resolveShot")
    local shooter = pawnOf(shooterPC)
    local shooterAddr = shooter and shooter:GetAddress() or 0
    local damage = (label == "gun") and GUN_DAMAGE or SNIPE_DAMAGE
    local best, miss, range, count = bestOnRay(shooterAddr, origin, dir)
    if best and miss <= HIT_RADIUS then
        say("%s HIT %s at %.0f m (%.0f cm off center)", label, charName(best), range / 100, miss)
        hurt(best, damage, shooter and charName(shooter) or "Someone")
    else
        say("%s missed (%d other players; closest: %s)", label, count,
            best and string.format("%.0f m away, %.0f cm off the crosshair", range / 100, miss) or "nobody in front of you")
    end
end

local aimLogged = false
-- Astroneer aims with the mouse cursor, not a crosshair in the middle of the screen, so the ray goes through the
-- cursor. If that call doesn't give an answer, fall back to the middle of the screen.
local function aimRay(pc)
    local loc, dir = {}, {}
    local ok, r1, r2, r3 = pcall(function() return pc:DeprojectMousePositionToWorld(loc, dir) end)
    local function vec(t) return t and type(t) == "table" and t.X ~= nil and t.Y ~= nil and t.Z ~= nil end
    if ok then
        if not vec(loc) and vec(r2) then loc = r2 end
        if not vec(dir) and vec(r3) then dir = r3 end
    end
    if ok and vec(loc) and vec(dir) then
        if not aimLogged then aimLogged = true say("aim: using the mouse cursor") end
        return { X = loc.X, Y = loc.Y, Z = loc.Z }, { X = dir.X, Y = dir.Y, Z = dir.Z }
    end
    if not aimLogged then aimLogged = true say("aim: cursor deprojection gave nothing (%s), using screen center", tostring(ok and "empty" or r1)) end
    local cam = pc.PlayerCameraManager
    local origin, rot = cam:GetCameraLocation(), cam:GetCameraRotation()
    local p, y = math.rad(rot.Pitch), math.rad(rot.Yaw)
    return { X = origin.X, Y = origin.Y, Z = origin.Z },
        { X = math.cos(p) * math.cos(y), Y = math.cos(p) * math.sin(y), Z = math.sin(p) }
end

-- the local player fires: the host resolves it directly, a client asks the host
local function fireLocal(label)
    local pc = getLocalController()
    if not pc then return end
    local origin, dir = aimRay(pc)
    if isHost(pc) then
        resolveShot(pc, origin, dir, label)
    else
        pc:ServerExec(string.format("CCFIRE %s %.1f %.1f %.1f %.4f %.4f %.4f", label, origin.X, origin.Y, origin.Z, dir.X, dir.Y, dir.Z))
    end
end

-- host side of a client's "CCFIRE" message. The client only says where it aimed, never how much damage.
local lastFire = {}
local function hostFire(pc, args)
    local label, ox, oy, oz, dx, dy, dz = args:match("^(%a+) (%-?[%d%.]+) (%-?[%d%.]+) (%-?[%d%.]+) (%-?[%d%.]+) (%-?[%d%.]+) (%-?[%d%.]+)$")
    if label ~= "sniper" and label ~= "gun" then return end
    local key = pc:GetAddress()
    local now = os.clock()
    if lastFire[key] and now - lastFire[key] < 0.25 then return end
    lastFire[key] = now
    local nx, ny, nz = tonumber(dx), tonumber(dy), tonumber(dz)
    if not (nx and ny and nz and tonumber(ox) and tonumber(oy) and tonumber(oz)) then return end
    local len = math.sqrt(nx * nx + ny * ny + nz * nz)
    if len < 0.5 then return end
    resolveShot(pc, { X = tonumber(ox), Y = tonumber(oy), Z = tonumber(oz) }, { X = nx / len, Y = ny / len, Z = nz / len }, label)
end

-- spawn the gun item next to a player; GUN_ITEM must be one of GUN_PROPS
local function giveGun(astro)
    local path = GUN_PROPS[GUN_ITEM]
    if not path then say("give gun: unknown item '%s'", GUN_ITEM) return end
    local world = astro:GetWorld()
    local class = StaticFindObject(path)
    if not alive(world) or not alive(class) then say("give gun: could not find %s", path) return end
    local loc = astro:K2_GetActorLocation()
    local yaw = math.rad(astro:K2_GetActorRotation().Yaw)
    local pos = { X = loc.X + math.cos(yaw) * 140, Y = loc.Y + math.sin(yaw) * 140, Z = loc.Z + 60 }
    local ok, a = pcall(function() return world:SpawnActor(class, pos, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
    say("give gun: %s", (ok and alive(a)) and "spawned, pick it up and hold it" or "spawn failed")
end

-- Teleport a player next to the shuttle nearest to them. The host does this to the player's character.
-- Returns a short message for the player.
-- Every shuttle-like actor in the world, personal shuttle first, then nearest first. Class names are unreliable (an item
-- type and the vehicle are both called "Shuttle_C"), so this scans all actors and goes by the class part of their name.
local function findShuttles(from, needles)
    local found = {}
    local scanned = 0
    needles = needles or { "shuttle", "dropship" }
    local skip = { "wrecked", "panel", "platform", "display", "camera", "beacon", "door", "lid", "slot", "anim" }
    local actors = FindAllOf("Actor")
    if type(actors) == "table" then
        for i = 1, #actors do
            pcall(function()
                local a = actors[i]
                scanned = scanned + 1
                local full = a:GetFullName()
                local class = full:match("^(%S+)") or ""
                local lower = class:lower()
                local matches = false
                for _, needle in ipairs(needles) do
                    if lower:find(needle, 1, true) then matches = true end
                end
                if not matches then return end
                if full:find("Default__", 1, true) or full:find("_GEN_VARIABLE", 1, true) then return end
                for _, word in ipairs(skip) do
                    if lower:find(word, 1, true) then return end
                end
                local l = a:K2_GetActorLocation()
                local d = math.sqrt((l.X - from.X) ^ 2 + (l.Y - from.Y) ^ 2 + (l.Z - from.Z) ^ 2)
                table.insert(found, { actor = a, dist = d, class = class, personal = lower:find("personal", 1, true) ~= nil })
            end)
        end
    end
    table.sort(found, function(x, y)
        if x.personal ~= y.personal then return x.personal end
        return x.dist < y.dist
    end)
    say("tptoshuttle: scanned %d actors, %d shuttle-like candidates", scanned, #found)
    for i = 1, math.min(#found, 6) do
        say("tptoshuttle: candidate %s, %.0f m away", found[i].class, found[i].dist / 100)
    end
    return found
end

local function tpToShuttle(astro, needles, what)
    crumb("tpToShuttle")
    what = what or "shuttle"
    local from = astro:K2_GetActorLocation()
    local pick = findShuttles(from, needles)[1]
    if not pick then
        say("tp: no %s found", what)
        return "no " .. what .. " found in this world"
    end
    local l = pick.actor:K2_GetActorLocation()
    local target = { X = l.X + 250, Y = l.Y, Z = l.Z + 300 }
    say("tptoshuttle: going to %s, %.0f m away", pick.class, pick.dist / 100)
    -- K2_TeleportTo has no output parameters (K2_SetActorLocation needs a hit-result struct, which is risky from Lua)
    local ok, err = pcall(function() astro:K2_TeleportTo(target, astro:K2_GetActorRotation()) end)
    if not ok then say("tptoshuttle error: %s", tostring(err)) return "teleport failed" end
    pcall(function() astro.AstroMovementComponent:ZeroVelocity() end)
    return string.format("teleported next to %s (%.0f m away)", pick.class, pick.dist / 100)
end

-- Every planet, station and platform in the world with the name the game shows for it. The first word of the class name
-- (T2_Planet_Terran_C -> Terran) is the id, the text the game shows (Sylva, Novus...) is the display name.
local function listBodies()
    local out = {}
    local seen = {}
    for _, className in ipairs({ "AstroPlanet", "GateStation", "OrbitalPlatform" }) do
        local list = FindAllOf(className)
        if type(list) == "table" then
            for i = 1, #list do
                pcall(function()
                    local b = list[i]
                    local full = b:GetFullName()
                    if full:find("Default__", 1, true) then return end
                    local addr = b:GetAddress()
                    if seen[addr] then return end
                    seen[addr] = true
                    local class = full:match("^(%S+)") or "?"
                    local id = class:gsub("^T2_Planet_", ""):gsub("_C$", "")
                    local display = ""
                    pcall(function() display = b.Name:ToString() end)
                    local c = b:GetCenter()
                    local radius = 0
                    pcall(function() radius = b:GetRadius() end)
                    if type(radius) ~= "number" or radius <= 0 then radius = 0 end
                    table.insert(out, {
                        body = b, id = id, display = display, class = class, radius = radius,
                        center = { X = c.X, Y = c.Y, Z = c.Z },
                    })
                end)
            end
        end
    end
    table.sort(out, function(x, y) return x.id < y.id end)
    return out
end

-- /tpplanet <number or name>: put the player above that planet (or next to that station)
local function tpToBody(astro, query)
    crumb("tpToBody")
    local bodies = listBodies()
    local pick
    local q = (query or ""):lower()
    local n = tonumber(q)
    if n then
        pick = bodies[n]
    elseif q ~= "" then
        for _, b in ipairs(bodies) do
            if b.id:lower():find(q, 1, true) or b.display:lower():find(q, 1, true) or b.class:lower():find(q, 1, true) then
                pick = b
                break
            end
        end
    end
    if not pick then return "no planet matches '" .. (query or "") .. "'. Type planets to see the list" end
    local altitude = (pick.radius > 0) and (pick.radius + 4000) or 1500
    local target = { X = pick.center.X, Y = pick.center.Y, Z = pick.center.Z + altitude }
    say("tpplanet: going to %s (%s), radius %.0f", pick.id, pick.display, pick.radius)
    local ok, err = pcall(function() astro:K2_TeleportTo(target, astro:K2_GetActorRotation()) end)
    if not ok then say("tpplanet error: %s", tostring(err)) return "teleport failed" end
    pcall(function() astro:AuthoritySetLocalSolarBody(pick.body) end)
    pcall(function() astro.AstroMovementComponent:ZeroVelocity() end)
    return "teleported above " .. pick.id .. (pick.display ~= "" and (" (" .. pick.display .. ")") or "")
end

-- /spawnsatellite (experimental): the end-game "unidentified satellite" only exists during its mission, so it isn't in the
-- world. The game files have /Game/Story/EXO_Satellite (next to Landing_Locations). This loads that asset, logs what it
-- is, and spawns it in front of the player only if it is an actor. It may not be the satellite, or may not work outside
-- its mission; everything it finds is logged.
local function spawnSatellite(astro)
    crumb("spawnSatellite")
    local path = "/Game/Story/EXO_Satellite"
    if LoadAsset == nil then return "this UE4SS version cannot load assets on demand" end
    local okLoad, loaded = pcall(function() return LoadAsset(path) end)
    say("satellite: LoadAsset %s (%s)", path, okLoad and "ok" or tostring(loaded))
    -- whatever LoadAsset handed back, and every object that now belongs to that package
    if okLoad and loaded ~= nil then
        pcall(function()
            say("satellite: LoadAsset returned %s (%s)", tostring(loaded:GetFullName()), tostring(loaded:GetClass():GetFullName()))
        end)
    end
    if ForEachUObject ~= nil then
        local count = 0
        pcall(function()
            ForEachUObject(function(obj)
                pcall(function()
                    local name = obj:GetFullName()
                    if name:find("/Game/Story/EXO_Satellite", 1, true) and count < 40 then
                        count = count + 1
                        say("satellite: object %s", name)
                    end
                end)
            end)
        end)
        say("satellite: %d objects belong to the EXO_Satellite package", count)
    end
    local class = StaticFindObject(path .. ".EXO_Satellite_C")
    if not alive(class) and okLoad and loaded ~= nil then
        pcall(function()
            local fullName = loaded:GetFullName()
            if fullName:find("Class", 1, true) then class = loaded end
        end)
    end
    if not alive(class) then
        local asset = StaticFindObject(path .. ".EXO_Satellite")
        say("satellite: no EXO_Satellite_C class; asset object: %s", alive(asset) and asset:GetFullName() or "none")
        return "the asset loaded but has no spawnable class (details in the log)"
    end
    -- walk up the parent classes: only spawn it if one of them is an Actor
    local isActor, chain = false, {}
    pcall(function()
        local c = class
        for _ = 1, 10 do
            c = c:GetSuperStruct()
            if c == nil or not c:IsValid() then break end
            local name = c:GetFullName()
            table.insert(chain, name)
            if name:find("/Script/Engine.Actor", 1, true) then isActor = true end
        end
    end)
    say("satellite: class %s, parents: %s", class:GetFullName(), table.concat(chain, " > "))
    if not isActor then return "it isn't an actor, so it can't be spawned (details in the log)" end
    local world = astro:GetWorld()
    if not alive(world) then return "no world to spawn into" end
    local loc = astro:K2_GetActorLocation()
    local yaw = astro:K2_GetActorRotation().Yaw
    local rad = math.rad(yaw)
    local pos = { X = loc.X + math.cos(rad) * 5000, Y = loc.Y + math.sin(rad) * 5000, Z = loc.Z + 1500 }
    local ok, a = pcall(function() return world:SpawnActor(class, pos, { Pitch = 0, Yaw = yaw, Roll = 0 }) end)
    local worked = ok and alive(a)
    say("satellite: spawn %s", worked and "worked" or "failed")
    return worked and "something was spawned about 50 m in front of you (look around for it)" or "the spawn failed (details in the log)"
end

-- /spawnshuttle [xl]: a shuttle appears in front of the player. The host spawns it so it exists for everyone.
local SHUTTLE_VEHICLES = {
    normal = "/Game/Vehicles/Shuttle.Shuttle_C",
    xl = "/Game/Vehicles/Shuttle_XLarge.Shuttle_XLarge_C",
}
local function spawnShuttle(astro, size, withParts)
    crumb("spawnShuttle")
    local path = SHUTTLE_VEHICLES[size] or SHUTTLE_VEHICLES.normal
    local world = astro:GetWorld()
    local class = StaticFindObject(path)
    if not alive(world) or not alive(class) then
        say("spawnshuttle: could not find %s", path)
        return "could not find the shuttle class"
    end
    local loc = astro:K2_GetActorLocation()
    local yaw = astro:K2_GetActorRotation().Yaw
    local rad = math.rad(yaw)
    local pos = { X = loc.X + math.cos(rad) * 900, Y = loc.Y + math.sin(rad) * 900, Z = loc.Z + 150 }
    local ok, a = pcall(function() return world:SpawnActor(class, pos, { Pitch = 0, Yaw = yaw, Roll = 0 }) end)
    local worked = ok and alive(a)
    say("spawnshuttle: %s at 9 m in front of the player (%s)", path, worked and "spawned" or "spawn failed")
    if not worked then return "the shuttle could not be spawned" end
    if not withParts then return "a shuttle was spawned about 9 m in front of you" end
    -- loose parts next to it: two medium thrusters (they go into the two medium slots of the thruster module).
    -- The module itself and attaching parts to slots needs the game's slot system, which isn't safe to drive from here.
    local thrusterClass = StaticFindObject("/Game/Components_Medium/Thruster_Medium.Thruster_Medium_C")
    local spawned = 0
    if alive(thrusterClass) then
        local side = rad + math.pi / 2
        for i = 1, 2 do
            local offset = (i == 1) and 350 or -350
            local ppos = { X = pos.X + math.cos(side) * offset, Y = pos.Y + math.sin(side) * offset, Z = pos.Z + 100 }
            local okp, p = pcall(function() return world:SpawnActor(thrusterClass, ppos, { Pitch = 0, Yaw = yaw, Roll = 0 }) end)
            if okp and alive(p) then spawned = spawned + 1 end
        end
    end
    say("spawnshuttle: %d medium thrusters spawned next to it", spawned)
    return string.format("a shuttle and %d medium thruster(s) were spawned in front of you", spawned)
end

-- /spawndropship: the base dropship (a physical item with its own thruster, seat and navigation) in front of the player.
-- (The Dropship_ShelterSpawner variant is the starter ship that also spawns a shelter package, so it is not used.)
local function spawnDropship(astro)
    crumb("spawnDropship")
    local path = "/Game/Components_Medium/Dropship.Dropship_C"
    local world = astro:GetWorld()
    local class = StaticFindObject(path)
    if not alive(world) or not alive(class) then
        say("spawndropship: could not find %s", path)
        return "could not find the dropship class"
    end
    local loc = astro:K2_GetActorLocation()
    local yaw = astro:K2_GetActorRotation().Yaw
    local rad = math.rad(yaw)
    local pos = { X = loc.X + math.cos(rad) * 900, Y = loc.Y + math.sin(rad) * 900, Z = loc.Z + 150 }
    local ok, a = pcall(function() return world:SpawnActor(class, pos, { Pitch = 0, Yaw = yaw, Roll = 0 }) end)
    local worked = ok and alive(a)
    say("spawndropship: %s (%s)", path, worked and "spawned" or "spawn failed")
    return worked and "a dropship was spawned about 9 m in front of you" or "the dropship could not be spawned"
end

-- ===== Chat =====
-- Uses the game's own network channels, no outside service:
--   client -> host : the engine RPC PlayerController:ServerExec carrying "CCHAT <text>". It does nothing in a shipping
--                    build, we only read it in a hook on the host.
--   host -> everyone: PlayerController:ClientTeamMessage with message type "CoopChat"; every copy of the mod listens.
-- Press Enter to open the chat box, Enter again to send, Escape to cancel.
local CHAT_TYPE = "CoopChat"
local CHAT_MAX_LINES = 8
local CHAT_FADE_SECONDS = 12
local chat = { open = false, lines = {}, lastShown = 0, lastSent = 0, shownText = nil, shownHud = nil }

local function cleanChat(t)
    local x = tostring(t or ""):gsub("%c", " ")
    x = x:gsub("^%s+", "")
    x = x:gsub("%s+$", "")
    if #x > 200 then x = x:sub(1, 200) end
    return x
end

local function addChatLine(line)
    table.insert(chat.lines, line)
    while #chat.lines > CHAT_MAX_LINES do table.remove(chat.lines, 1) end
    chat.lastShown = os.clock()
    say("chat: %s", line)
end

local function playerNameOf(pc)
    local ok, name = pcall(function() return pc.PlayerState:GetPlayerName():ToString() end)
    if ok and type(name) == "string" and name ~= "" then return name end
    return "Player"
end

-- host only: push one line to every player's screen
local function broadcastChat(line, senderPS, mtype)
    crumb("broadcastChat")
    local list = FindAllOf("PlayController")
    if type(list) ~= "table" then return end
    for i = 1, #list do
        local pc = list[i]
        local ok, err = pcall(function()
            if pc:IsValid() then pc:ClientTeamMessage(senderPS, line, FName(mtype or CHAT_TYPE), 8.0) end
        end)
        if not ok then say("chat broadcast error: %s", tostring(err)) end
    end
end

-- Chat commands. Anything typed in chat that starts with "/" is a command, not a public message. The host runs them.
local ALLOW_GIVEGUN = 1 -- panel switch: may players get a gun with /givemegun?
local cmdLast = {} -- player address -> time of their last command

-- a one-line answer shown only to the player who typed the command
local function replyTo(pc, line)
    pcall(function() pc:ClientTeamMessage(pc.PlayerState, line, FName(CHAT_TYPE), 8.0) end)
end

local function runChatCommand(pc, text)
    local cmd = text:match("^/(%S+)")
    local key = pc:GetAddress()
    local now = os.clock()
    if cmdLast[key] and now - cmdLast[key] < 5 then
        replyTo(pc, "[Server] slow down, wait a few seconds between commands")
        return
    end
    cmdLast[key] = now
    if cmd == "givemegun" then
        if ALLOW_GIVEGUN == 0 then
            replyTo(pc, "[Server] /givemegun is turned off")
            return
        end
        local pawn = pawnOf(pc)
        if not pawn then replyTo(pc, "[Server] you have no character right now") return end
        giveGun(pawn)
        replyTo(pc, "[Server] a " .. GUN_ITEM .. " is next to you. Pick it up, hold it, and use the fire button.")
        pcall(feed, charName(pawn) .. " got a gun")
    elseif cmd == "spawnshuttle" then
        local pawn = pawnOf(pc)
        if not pawn then replyTo(pc, "[Server] you have no character right now") return end
        local args = (text:match("^/%S+%s+(.*)$") or ""):lower()
        local size = args:find("xl", 1, true) and "xl" or "normal"
        replyTo(pc, "[Server] " .. spawnShuttle(pawn, size, args:find("parts", 1, true) ~= nil))
    elseif cmd == "tptoshuttle" then
        local pawn = pawnOf(pc)
        if not pawn then replyTo(pc, "[Server] you have no character right now") return end
        local msg = tpToShuttle(pawn)
        replyTo(pc, "[Server] " .. msg)
    elseif cmd == "spawnsatellite" then
        local pawn = pawnOf(pc)
        if not pawn then replyTo(pc, "[Server] you have no character right now") return end
        replyTo(pc, "[Server] " .. spawnSatellite(pawn))
    elseif cmd == "tpplanet" then
        local pawn = pawnOf(pc)
        if not pawn then replyTo(pc, "[Server] you have no character right now") return end
        replyTo(pc, "[Server] " .. tpToBody(pawn, text:match("^/%S+%s+(.*)$")))
    elseif cmd == "tptodropship" then
        local pawn = pawnOf(pc)
        if not pawn then replyTo(pc, "[Server] you have no character right now") return end
        replyTo(pc, "[Server] " .. tpToShuttle(pawn, { "dropship" }, "dropship"))
    elseif cmd == "spawndropship" then
        local pawn = pawnOf(pc)
        if not pawn then replyTo(pc, "[Server] you have no character right now") return end
        replyTo(pc, "[Server] " .. spawnDropship(pawn))
    elseif cmd == "nobarrier" then
        sendEvt("BARRIER|0")
        pcall(feed, "world barriers removed")
        replyTo(pc, "[Server] barriers removed for everyone. /barrier puts them back.")
    elseif cmd == "barrier" then
        sendEvt("BARRIER|1")
        pcall(feed, "world barriers restored")
        replyTo(pc, "[Server] barriers restored.")
    else
        replyTo(pc, "[Server] unknown command. Try givemegun, planets, tpplanet, spawnshuttle or nobarrier")
    end
end

-- /probe: measures where you are compared to the planet and what you overlap, to find the real invisible walls.
-- It only reads values and shows them in your own chat log and in the UE4SS log. Runs on your own PC, nothing is sent.
local function probe()
    crumb("probe")
    local pc = getLocalController()
    local me = pc and pawnOf(pc)
    if not me then addChatLine("[Probe] no character found") return end
    local loc = me:K2_GetActorLocation()
    say("probe: player at %.0f, %.0f, %.0f", loc.X, loc.Y, loc.Z)
    local planets = FindAllOf("AstroPlanet")
    if type(planets) == "table" then
        for i = 1, #planets do
            pcall(function()
                local p = planets[i]
                if not p:IsValid() or p:GetFullName():find("Default__", 1, true) then return end
                local c = p:GetCenter()
                local r = p:GetRadius()
                local d = math.sqrt((loc.X - c.X) ^ 2 + (loc.Y - c.Y) ^ 2 + (loc.Z - c.Z) ^ 2)
                say("probe: planet %s radius %.0f gravityRadius %.0f worldSize %.0f, you are %.0f from its center (%.2f x radius)",
                    p:GetFullName(), r, p.GravityRadius, p.WorldSize, d, d / math.max(r, 1))
                addChatLine(string.format("[Probe] %.2f x planet radius (%.0f of %.0f)", d / math.max(r, 1), d, r))
            end)
        end
    end
    pcall(function()
        local mv = me.AstroMovementComponent
        say("probe: movement mode %s, speed %.0f, gravity %.0f", tostring(mv.CurrentMovementMode), mv.MaxSpeed, mv.Gravity)
    end)
    -- everything within 80 m of you, nearest first: whatever forms the wall should be in this list
    local near = {}
    local actors = FindAllOf("Actor")
    if type(actors) == "table" then
        for i = 1, #actors do
            pcall(function()
                local a = actors[i]
                local full = a:GetFullName()
                if full:find("Default__", 1, true) then return end
                local l = a:K2_GetActorLocation()
                local d = math.sqrt((l.X - loc.X) ^ 2 + (l.Y - loc.Y) ^ 2 + (l.Z - loc.Z) ^ 2)
                if d < 8000 then table.insert(near, { class = full:match("^(%S+)") or "?", d = d }) end
            end)
        end
    end
    table.sort(near, function(x, y) return x.d < y.d end)
    say("probe: %d actors within 80 m of you", #near)
    for i = 1, math.min(#near, 60) do
        say("probe: near #%d %s at %.0f", i, near[i].class, near[i].d)
    end
    addChatLine(string.format("[Probe] %d actors near you, listed in UE4SS.log", #near))
end

-- /hardness used to call the game's "ignore terrain hardness" function on every terrain tool in the world. That crashed
-- Astroneer itself (a tool with no owner), so it now only prints a hint and touches nothing. Use the switch in the
-- creative terrain menu instead.
local function ignoreHardness()
    addChatLine("[Hardness] this command crashed the game, so it does nothing now. Use the creative terrain menu's ignore-hardness switch.")
end

-- commands can be typed without the slash too (typing "/" is awkward on some keyboard layouts)
local COMMAND_NAMES = { givemegun = true, probe = true, hardness = true, nobarrier = true, barrier = true, tptoshuttle = true, spawnshuttle = true, tptodropship = true, spawndropship = true, tpplanet = true, planets = true, spawnsatellite = true }

-- /planets: shows every planet and station with its number and the name the game uses. Runs on your own PC.
local function showPlanets()
    local bodies = listBodies()
    if #bodies == 0 then addChatLine("[Planets] none found") return end
    local row = {}
    for i, b in ipairs(bodies) do
        local label = string.format("%d=%s%s", i, b.id, b.display ~= "" and (" (" .. b.display .. ")") or "")
        say("planets: %s", label)
        table.insert(row, label)
        if #row == 2 or i == #bodies then
            addChatLine("[Planets] " .. table.concat(row, ", "))
            row = {}
        end
    end
    addChatLine("[Planets] type tpplanet <number or name> to go there")
end

local function sendChat(text)
    text = cleanChat(text)
    if text == "" then return end
    local lowered = text:lower()
    if COMMAND_NAMES[lowered:match("^(%S+)") or ""] then
        text = "/" .. text
        lowered = "/" .. lowered
    end
    if lowered == "/probe" then pcall(probe) return end
    if lowered == "/planets" then pcall(showPlanets) return end
    if lowered == "/hardness" then pcall(ignoreHardness) return end
    if os.clock() - chat.lastSent < 0.5 then return end
    chat.lastSent = os.clock()
    local pc = getLocalController()
    if not pc then say("chat: no local controller") return end
    if isHost(pc) then
        if text:sub(1, 1) == "/" then
            runChatCommand(pc, text)
            return
        end
        broadcastChat(playerNameOf(pc) .. ": " .. text, pc.PlayerState)
    else
        local ok, err = pcall(function() pc:ServerExec("CCHAT " .. text) end)
        say("chat: sent to the host (%d chars, ok=%s)", #text, tostring(ok))
        if not ok then say("chat send error: %s", tostring(err)) end
    end
end

local function adminSay(text)
    text = cleanChat(text)
    if text == "" then return end
    local pc = getLocalController()
    if not pc then return end
    if isHost(pc) then broadcastChat("[Admin] " .. text, pc.PlayerState)
    else say("admin say: only the host can broadcast") end
end

-- ===== network events (kill feed, down markers) =====
-- Same channel as chat but another message type. Text format: KIND|field|field
--   FEED|text          a line for the kill feed
--   DOWN|name|seconds  a player is downed (drives the marker)
--   UP|name|reason     a player was revived or died
local CHAT_EVT = "CoopEvt"
local remote = { down = {} } -- player name -> { untilT }

function sendEvt(text)
    local pc = getLocalController()
    if not pc then return end
    if isHost(pc) then
        broadcastChat(text, pc.PlayerState, CHAT_EVT)
    else
        pcall(function() pc:ServerExec("CCEVT " .. text) end)
    end
end

function feed(text)
    sendEvt("FEED|" .. text)
end

-- World barriers. The camera rig has "hard" and "soft" distance bounds (an inner and an outer distance from the
-- planet centre, with a correction speed that pushes you back), and DeformSafeZone components block digging inside
-- a radius. "Off" opens them all up, "on" puts the game's own values back. Each machine changes its own game, so
-- this is triggered by a network event. The original values are logged so we can see what the game uses.
local barrierSaved = {} -- address -> original values
local function applyBarriers(off)
    crumb("applyBarriers")
    local changed = 0
    local function each(className, fn)
        local list = FindAllOf(className)
        if type(list) ~= "table" then return end
        for i = 1, #list do
            local c = list[i]
            local ok, err = pcall(function()
                if c:IsValid() and not c:GetFullName():find("Default__", 1, true) then fn(c) end
            end)
            if not ok then say("barrier: skipped one %s (%s)", className, tostring(err)) end
        end
    end
    each("DistanceBoundsModifierComponent", function(c)
        local key = c:GetAddress()
        if off then
            if not barrierSaved[key] then
                barrierSaved[key] = { c.InnerBound, c.OuterBound, c.CorrectionSpeed }
                say("barrier: %s inner=%.0f outer=%.0f speed=%.2f", c:GetFullName(), c.InnerBound, c.OuterBound, c.CorrectionSpeed)
            end
            c.InnerBound = 0
            c.OuterBound = 1e9
            c.CorrectionSpeed = 0
        elseif barrierSaved[key] then
            c.InnerBound, c.OuterBound, c.CorrectionSpeed = barrierSaved[key][1], barrierSaved[key][2], barrierSaved[key][3]
            barrierSaved[key] = nil
        end
        changed = changed + 1
    end)
    each("DeformSafeZoneComponent", function(c)
        local key = "z" .. c:GetAddress()
        if off then
            if not barrierSaved[key] then
                barrierSaved[key] = { c.Radius }
                say("barrier: %s dig-safe-zone radius=%.0f", c:GetFullName(), c.Radius)
            end
            c.Radius = 0
        elseif barrierSaved[key] then
            c.Radius = barrierSaved[key][1]
            barrierSaved[key] = nil
        end
        changed = changed + 1
    end)
    -- The planet core: every planet has a Gateway Engine at its centre, and the engine has a mesh component called
    -- "Entry Barrier Shell". That is the invisible wall around the core. Its collision is what blocks you.
    local engines = FindAllOf("Actor")
    local shells = 0
    if type(engines) == "table" then
        for i = 1, #engines do
            pcall(function()
                local a = engines[i]
                local full = a:GetFullName()
                local class = full:match("^(%S+)") or ""
                if not class:find("GatewayEngine_", 1, true) or full:find("Default__", 1, true) then return end
                local shell = a["Entry Barrier Shell"]
                if shell == nil or not shell:IsValid() then
                    say("barrier: %s has no readable Entry Barrier Shell", class)
                    return
                end
                local key = "g" .. shell:GetAddress()
                if off then
                    if barrierSaved[key] == nil then
                        barrierSaved[key] = { shell:GetCollisionEnabled() }
                        say("barrier: %s Entry Barrier Shell collision was %s", class, tostring(barrierSaved[key][1]))
                    end
                    shell:SetCollisionEnabled(0) -- no collision
                elseif barrierSaved[key] then
                    shell:SetCollisionEnabled(barrierSaved[key][1])
                    barrierSaved[key] = nil
                end
                shells = shells + 1
            end)
        end
    end
    changed = changed + shells
    say("barriers %s (%d components changed, %d core barrier shells)", off and "removed" or "restored", changed, shells)
end

local function handleEvt(text)
    local kind, rest = text:match("^(%u+)|(.*)$")
    if kind == "BARRIER" then
        local ok, err = pcall(applyBarriers, rest == "0")
        if not ok then say("barrier error: %s", tostring(err)) end
    elseif kind == "FEED" then
        addChatLine("[Feed] " .. rest)
    elseif kind == "DOWN" then
        local name, secs = rest:match("^(.-)|([%d%.]+)$")
        if name then remote.down[name] = { untilT = os.clock() + (tonumber(secs) or BLEEDOUT_SECONDS) } end
    elseif kind == "UP" then
        local name = rest:match("^(.-)|")
        if name then remote.down[name] = nil end
    end
end

-- receive: every machine shows lines that arrive with our message type
pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientTeamMessage", function(self, senderPS, s, mtype, life)
        local ok, err = pcall(function()
            local t = mtype:get():ToString()
            if t == CHAT_TYPE then
                addChatLine(s:get():ToString())
            elseif t == CHAT_EVT then
                handleEvt(s:get():ToString())
            end
        end)
        if not ok then say("chat receive error: %s", tostring(err)) end
    end)
end)

-- host: a client's ServerExec arrives here
pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ServerExec", function(self, msg)
        local ok, err = pcall(function()
            local pc = self:get()
            if not isHost(pc) then return end
            local text = msg:get():ToString()
            local body = text:match("^CCHAT (.*)$")
            if body then
                body = cleanChat(body)
                if body:sub(1, 1) == "/" then
                    runChatCommand(pc, body)
                elseif body ~= "" then
                    broadcastChat(playerNameOf(pc) .. ": " .. body, pc.PlayerState)
                end
                return
            end
            local evt = text:match("^CCEVT (.*)$")
            if evt then
                local kind = evt:match("^(%u+)|")
                if kind == "FEED" or kind == "DOWN" or kind == "UP" then
                    broadcastChat(evt:sub(1, 200), pc.PlayerState, CHAT_EVT)
                end
                return
            end
            local fire = text:match("^CCFIRE (.*)$")
            if fire then hostFire(pc, fire) end
        end)
        if not ok then say("chat host error: %s", tostring(err)) end
    end)
end)

local function getInputBox(hud)
    local tree = hud.WidgetTree
    local full = tree:GetFullName():match("^%S+%s+(.+)$")
    if full then
        local found = StaticFindObject(full .. ".CoopChatInput")
        if found ~= nil and found:IsValid() then return found end
    end
    local box = StaticConstructObject(StaticFindObject("/Script/UMG.EditableTextBox"), tree, FName("CoopChatInput"))
    box:SetHintText(FText("Type a message or a command (givemegun, planets, tpplanet, spawnshuttle), Enter to send"))
    local slot = tree.RootWidget:AddChild(box)
    slot:SetAnchors({ Minimum = { X = 0.02, Y = 0.8 }, Maximum = { X = 0.02, Y = 0.8 } })
    slot:SetAlignment({ X = 0, Y = 0.5 })
    slot:SetPosition({ X = 0, Y = 0 })
    slot:SetAutoSize(false)
    slot:SetSize({ X = 700, Y = 44 })
    slot:SetZOrder(110)
    return box
end

-- shows what has been typed so far in the chat box (the box is read-only, the mod collects the key presses itself)
local function renderBuffer()
    local hud = FindFirstOf("PlayWidgetInstance_C")
    if not alive(hud) then return end
    getInputBox(hud):SetText(FText((chat.buffer or "") .. "|"))
end

local function closeChat()
    crumb("closeChat")
    chat.open = false
    chat.buffer = ""
    local pc = getLocalController()
    local hud = FindFirstOf("PlayWidgetInstance_C")
    if alive(hud) then
        pcall(function()
            local box = getInputBox(hud)
            box:SetText(FText(""))
            box:SetVisibility(1)
        end)
    end
    if pc then
        local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        -- Astroneer plays with a visible mouse cursor, so put the cursor back the way we found it. The game's own
        -- input mode isn't known, so try the likely ones until one works.
        local restored = pcall(function() lib:SetInputMode_GameAndUIEx(pc, nil, 0, false) end)
        if not restored then restored = pcall(function() lib:SetInputMode_GameOnly(pc) end) end
        pcall(function() lib:SetFocusToGameViewport() end)
        if chat.prevCursor ~= nil then pcall(function() pc.bShowMouseCursor = chat.prevCursor end) end
        say("chat closed (input mode restored: %s)", tostring(restored))
    end
end

local function openChat()
    crumb("openChat")
    local pc = getLocalController()
    local hud = FindFirstOf("PlayWidgetInstance_C")
    if not pc then say("chat: Enter pressed but there is no local controller") return end
    if not alive(hud) then say("chat: Enter pressed but the HUD isn't ready") return end
    local box = getInputBox(hud)
    chat.buffer = ""
    pcall(function() box:SetIsReadOnly(true) end)
    box:SetText(FText("|"))
    box:SetVisibility(0)
    local ok, prev = pcall(function() return pc.bShowMouseCursor end)
    if ok then chat.prevCursor = (prev == true) or (type(prev) == "number" and prev ~= 0) end
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    lib:SetInputMode_UIOnlyEx(pc, box, 0)
    pc.bShowMouseCursor = true
    box:SetKeyboardFocus()
    chat.open = true
    chat.lastShown = os.clock()
    say("chat opened (cursor was visible: %s)", tostring(chat.prevCursor))
end

local function submitChat()
    crumb("submitChat")
    local text = chat.buffer or ""
    say("chat: submitting %d characters", #text)
    closeChat()
    sendChat(text)
end

-- down marker: "Friend DOWN 18s  >>  43m" for every downed player we know about, with the direction to them
local markerState = { t = 0, text = nil, hud = nil }
local function markerTick(hud)
    local now = os.clock()
    if now - markerState.t < 0.3 then return end
    markerState.t = now
    local lines = {}
    local pc = getLocalController()
    if pc then
        local ok, err = pcall(function()
            local cam = pc.PlayerCameraManager
            local origin, rot = cam:GetCameraLocation(), cam:GetCameraRotation()
            local mePawn = pawnOf(pc)
            local myName = mePawn and charName(mePawn) or ""
            local chars = nil
            for name, st in pairs(remote.down) do
                local left = st.untilT - now
                if left <= 0 then
                    remote.down[name] = nil
                elseif name ~= myName then
                    chars = chars or FindAllOf("AstroCharacter")
                    if type(chars) == "table" then
                        for i = 1, #chars do
                            local a = chars[i]
                            if alive(a) and charName(a) == name then
                                local loc = a:K2_GetActorLocation()
                                local dx, dy, dz = loc.X - origin.X, loc.Y - origin.Y, loc.Z - origin.Z
                                local rel = math.deg(math.atan(dy, dx)) - rot.Yaw
                                while rel > 180 do rel = rel - 360 end
                                while rel < -180 do rel = rel + 360 end
                                local arrow = "^"
                                if rel > 135 or rel < -135 then arrow = "v" elseif rel > 45 then arrow = ">>" elseif rel < -45 then arrow = "<<" end
                                local meters = math.sqrt(dx * dx + dy * dy + dz * dz) / 100
                                table.insert(lines, string.format("%s DOWN %ds   %s   %dm", name, math.ceil(left), arrow, meters))
                                break
                            end
                        end
                    end
                end
            end
        end)
        if not ok then say("marker error: %s", tostring(err)) end
    end
    table.sort(lines)
    local text = table.concat(lines, "\n")
    local hudAddr = hud:GetAddress()
    if text == markerState.text and hudAddr == markerState.hud then return end
    markerState.text, markerState.hud = text, hudAddr
    pcall(function()
        local t = getText(hud, "CoopMarker", 34, 0.1, { R = 1.0, G = 0.6, B = 0.1, A = 1.0 })
        t:SetText(FText(text))
        t:SetVisibility(text ~= "" and 4 or 1)
    end)
end

-- the on-screen log (bottom left): shows for a while after a message, or while the box is open
function chatTick()
    local hud = FindFirstOf("PlayWidgetInstance_C")
    if not alive(hud) then return end
    pcall(markerTick, hud)
    if chat.open and not getLocalController() then chat.open = false end
    local visible = #chat.lines > 0 and (chat.open or os.clock() - chat.lastShown < CHAT_FADE_SECONDS)
    local text = visible and table.concat(chat.lines, "\n") or ""
    local hudAddr = hud:GetAddress()
    if text == chat.shownText and hudAddr == chat.shownHud then return end
    chat.shownText, chat.shownHud = text, hudAddr
    crumb("chatTick")
    local ok, err = pcall(function()
        local t = getText(hud, "CoopChatLog", 28, 0.62, { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }, 0.02, 0)
        t:SetText(FText(text))
        t:SetVisibility(text ~= "" and 4 or 1)
    end)
    if not ok then say("chat log error: %s", tostring(err)) end
end

RegisterKeyBind(Key.RETURN, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            say("chat: Enter pressed (box open: %s)", tostring(chat.open))
            if chat.open then submitChat() else openChat() end
        end)
        if not ok then
            say("chat key error: %s", tostring(err))
            pcall(closeChat)
        end
    end)
end)

RegisterKeyBind(Key.ESCAPE, function()
    ExecuteInGameThread(function()
        if chat.open then pcall(closeChat) end
    end)
end)

-- Typing. The text box never received the keystrokes in Astroneer, so while the chat is open the mod collects them
-- itself. The game's own controls are off in that mode, and the key binds only watch, they don't steal the key.
local TYPE_KEYS = {} -- key name -> { normal character, shifted character }
for i = 0, 25 do
    local lower = string.char(97 + i)
    TYPE_KEYS[string.char(65 + i)] = { lower, lower:upper() }
end
local DIGIT_NAMES = { "ZERO", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE" }
local DIGIT_SHIFT = { ")", "!", "@", "#", "$", "%", "^", "&", "*", "(" }
for i = 1, 10 do TYPE_KEYS[DIGIT_NAMES[i]] = { tostring(i - 1), DIGIT_SHIFT[i] } end
TYPE_KEYS.SPACE = { " ", " " }
-- punctuation uses UE4SS's own key names; the characters assume a US layout, other layouts print what a US layout
-- would on that physical key. The numpad keys are the same on every layout, so numpad "/" always types a slash.
TYPE_KEYS.OEM_COMMA = { ",", "<" }
TYPE_KEYS.OEM_PERIOD = { ".", ">" }
TYPE_KEYS.OEM_MINUS = { "-", "_" }
TYPE_KEYS.OEM_PLUS = { "=", "+" }
TYPE_KEYS.OEM_ONE = { ";", ":" }
TYPE_KEYS.OEM_TWO = { "/", "?" }
TYPE_KEYS.OEM_THREE = { "`", "~" }
TYPE_KEYS.OEM_FOUR = { "[", "{" }
TYPE_KEYS.OEM_FIVE = { "\\", "|" }
TYPE_KEYS.OEM_SIX = { "]", "}" }
TYPE_KEYS.OEM_SEVEN = { "'", '"' }
TYPE_KEYS.DIVIDE = { "/", "/" }
TYPE_KEYS.MULTIPLY = { "*", "*" }
TYPE_KEYS.ADD = { "+", "+" }
TYPE_KEYS.SUBTRACT = { "-", "-" }
TYPE_KEYS.DECIMAL = { ".", "." }
local NUMPAD_NAMES = { "NUM_ZERO", "NUM_ONE", "NUM_TWO", "NUM_THREE", "NUM_FOUR", "NUM_FIVE", "NUM_SIX", "NUM_SEVEN", "NUM_EIGHT", "NUM_NINE" }
for i = 1, 10 do TYPE_KEYS[NUMPAD_NAMES[i]] = { tostring(i - 1), tostring(i - 1) } end

local function shiftDown()
    if IsKeyBindDown == nil then return false end
    local ok, v = pcall(function() return IsKeyBindDown(Key.LEFT_SHIFT) or IsKeyBindDown(Key.RIGHT_SHIFT) end)
    return ok and v == true
end

local function typingKeyPressed(name)
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            if not chat.open then return end
            if name == "BACKSPACE" then
                chat.buffer = (chat.buffer or ""):sub(1, -2)
            else
                local entry = TYPE_KEYS[name]
                if not entry or #(chat.buffer or "") >= 200 then return end
                chat.buffer = (chat.buffer or "") .. (shiftDown() and entry[2] or entry[1])
            end
            renderBuffer()
        end)
        if not ok then say("typing error: %s", tostring(err)) end
    end)
end

local boundKeys = 0
for name in pairs(TYPE_KEYS) do
    local keyEnum = Key[name]
    if keyEnum ~= nil then
        pcall(function() RegisterKeyBind(keyEnum, function() typingKeyPressed(name) end) end)
        boundKeys = boundKeys + 1
    end
end
if Key.BACKSPACE ~= nil then
    pcall(function() RegisterKeyBind(Key.BACKSPACE, function() typingKeyPressed("BACKSPACE") end) end)
end
say("chat typing: %d keys bound, shift detection %s", boundKeys, IsKeyBindDown ~= nil and "available" or "not available (lowercase only)")

-- F9 is the only hotkey: the sniper (fires along your crosshair, any range)
RegisterKeyBind(Key.F9, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(fireLocal, "sniper")
        if not ok then say("sniper error: %s", tostring(err)) end
    end)
end)

-- the gun: hold the gun item, press the chosen mouse button
local gunLast = 0
local function holdingGun(pc)
    local me = pawnOf(pc)
    if not me then return false end
    local ok, v = pcall(function()
        local item = me.HeldItem
        return alive(item) and item:GetFullName():find(GUN_ITEM, 1, true) ~= nil
    end)
    return ok and v == true
end

local function gunKeyPressed(name)
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            if name ~= GUN_KEY or chat.open then return end
            local now = os.clock()
            if now - gunLast < GUN_COOLDOWN then return end
            local pc = getLocalController()
            if not pc or not holdingGun(pc) then return end
            gunLast = now
            fireLocal("gun")
        end)
        if not ok then say("gun error: %s", tostring(err)) end
    end)
end

local function bindGunKey(name, keyEnum)
    if keyEnum == nil then return end
    pcall(function() RegisterKeyBind(keyEnum, function() gunKeyPressed(name) end) end)
end
bindGunKey("LMB", Key.LEFT_MOUSE_BUTTON)
bindGunKey("RMB", Key.RIGHT_MOUSE_BUTTON)
bindGunKey("MMB", Key.MIDDLE_MOUSE_BUTTON)
bindGunKey("MOUSE4", Key.XBUTTON_ONE)
bindGunKey("MOUSE5", Key.XBUTTON_TWO)

-- Admin panel bridge: writes panel/state.json once a second, executes lines from panel/commands.txt.
-- The local web panel (panel/server.py) is the other end. Nothing here listens on the network.
local panelDir = (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("[Ss]cripts[\\/]main%.lua$", "")) .. "panel\\"

local function jstr(v)
    return '"' .. tostring(v):gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"'
end

local function playerName(astro, fallback)
    local ok, name = pcall(function() return astro:GetOnlinePlayerName():ToString() end)
    if ok and type(name) == "string" and name ~= "" then return name end
    return fallback
end

local function playerJson(astro, isLocal, n)
    local key = astro:GetAddress()
    local st = downed[key]
    return string.format('{"id":%s,"name":%s,"local":%s,"health":%.3f,"maxHealth":%.3f,"downed":%s,"bleed":%.1f}',
        jstr(key), jstr(playerName(astro, "Player " .. n)), tostring(isLocal), astro.Health, astro.MaxHealth,
        tostring(st ~= nil), st and math.max(0, BLEEDOUT_SECONDS - (os.clock() - st.startedAt)) or 0)
end

local function writeState()
    crumb("writeState")
    local me, others = getPlayers()
    local list, n = {}, 0
    if alive(me) then n = n + 1 table.insert(list, playerJson(me, true, n)) end
    for _, a in ipairs(others) do
        if alive(a) then n = n + 1 table.insert(list, playerJson(a, false, n)) end
    end
    local cfg = string.format('{"DAMAGE":%.3f,"SNIPE_DAMAGE":%.3f,"GUN_DAMAGE":%.3f,"GUN_COOLDOWN":%.2f,"HIT_RADIUS":%.0f,"BLEEDOUT_SECONDS":%.1f,"CRAWL_SPEED_SCALE":%.3f,"DOWNED_HEALTH":%.3f,"REVIVE_RANGE":%.0f,"REVIVE_SECONDS":%.1f,"EXPLODE_COUNT":%d,"PVP_IN_CREATIVE":%d,"ALLOW_GIVEGUN":%d}',
        DAMAGE, SNIPE_DAMAGE, GUN_DAMAGE, GUN_COOLDOWN, HIT_RADIUS, BLEEDOUT_SECONDS, CRAWL_SPEED_SCALE, DOWNED_HEALTH, REVIVE_RANGE, REVIVE_SECONDS, EXPLODE_COUNT, PVP_IN_CREATIVE, ALLOW_GIVEGUN)
    local f = io.open(panelDir .. "state.json", "w")
    if not f then return end
    local chatJson = {}
    for _, l in ipairs(chat.lines) do table.insert(chatJson, jstr(l)) end
    f:write(string.format('{"time":%d,"creative":%s,"players":[%s],"config":%s,"strings":{"GUN_ITEM":%s,"GUN_KEY":%s},"chat":[%s]}', os.time(), tostring(creativeOn()), table.concat(list, ","), cfg, jstr(GUN_ITEM), jstr(GUN_KEY), table.concat(chatJson, ",")))
    f:close()
end

local function findPlayer(id)
    local me, others = getPlayers()
    if alive(me) and tostring(me:GetAddress()) == id then return me end
    for _, a in ipairs(others) do
        if alive(a) and tostring(a:GetAddress()) == id then return a end
    end
    return nil
end

local settable = {
    DAMAGE = { 0.01, 1, function(v) DAMAGE = v end },
    SNIPE_DAMAGE = { 0.01, 1, function(v) SNIPE_DAMAGE = v end },
    GUN_DAMAGE = { 0.01, 1, function(v) GUN_DAMAGE = v end },
    GUN_COOLDOWN = { 0.1, 3, function(v) GUN_COOLDOWN = v end },
    HIT_RADIUS = { 20, 500, function(v) HIT_RADIUS = v end },
    BLEEDOUT_SECONDS = { 5, 300, function(v) BLEEDOUT_SECONDS = v end },
    CRAWL_SPEED_SCALE = { 0.02, 1, function(v) CRAWL_SPEED_SCALE = v end },
    DOWNED_HEALTH = { 0.05, 1, function(v) DOWNED_HEALTH = v end },
    EXPLODE_COUNT = { 1, 100, function(v) EXPLODE_COUNT = math.floor(v) end },
    PVP_IN_CREATIVE = { 0, 1, function(v) PVP_IN_CREATIVE = (v >= 0.5) and 1 or 0 end },
    ALLOW_GIVEGUN = { 0, 1, function(v) ALLOW_GIVEGUN = (v >= 0.5) and 1 or 0 end },
    REVIVE_RANGE = { 100, 3000, function(v) REVIVE_RANGE = v end },
    REVIVE_SECONDS = { 1, 30, function(v) REVIVE_SECONDS = v end },
}

local function runCommand(line)
    crumb("command " .. line)
    if line:sub(1, 4) == "say " then
        adminSay(line:sub(5))
        return
    end
    local cmd, a, b = line:match("^(%a+)%s+(%S+)%s*(%S*)")
    if not cmd then return end
    if cmd == "barrier" then
        sendEvt("BARRIER|" .. ((a == "off") and "0" or "1"))
        pcall(feed, (a == "off") and "world barriers removed" or "world barriers restored")
        return
    end
    if cmd == "setstr" then
        if a == "GUN_ITEM" and GUN_PROPS[b] then GUN_ITEM = b say("panel: GUN_ITEM = %s", b)
        elseif a == "GUN_KEY" and GUN_KEYS[b] then GUN_KEY = b say("panel: GUN_KEY = %s", b) end
        return
    end
    if cmd == "set" then
        local def, val = settable[a], tonumber(b)
        if def and val then def[3](math.max(def[1], math.min(def[2], val))) say("panel: %s = %s", a, b) end
        return
    end
    local astro = findPlayer(a)
    if not astro then say("panel: player %s not found", a) return end
    if cmd == "hurt" then hurt(astro, tonumber(b) or DAMAGE, "Admin")
    elseif cmd == "heal" then
        if downed[astro:GetAddress()] then revive(astro) end
        astro.Health = astro.MaxHealth
    elseif cmd == "down" then goDown(astro, "Admin")
    elseif cmd == "revive" then revive(astro, "Admin")
    elseif cmd == "kill" then killPlayer(astro, "Admin")
    elseif cmd == "explode" then explodePlayer(astro, "Admin")
    elseif cmd == "give" then giveGun(astro)
    end
    say("panel: %s", line)
end

-- reads the panel's commands.txt and runs the lines in it
local function commandTick()
    local f = io.open(panelDir .. "commands.txt", "r")
    if not f then return end
    local text = f:read("*a")
    f:close()
    if not text or text == "" then return end
    local w = io.open(panelDir .. "commands.txt", "w")
    if w then w:close() end
    for line in text:gmatch("[^\r\n]+") do
        local ok, err = pcall(runCommand, line)
        if not ok then say("panel command error: %s", tostring(err)) end
    end
end

-- ONE timer drives everything. Before, five separate timers each handed a new callback to the game thread (about 100
-- a second); UE4SS logged "Ref was not function" errors under that load and crashed every few minutes.
local tickCount = 0
local function masterTick()
    tickCount = tickCount + 1
    pcall(hudTick)
    pcall(fallTick)
    pcall(watcherTick)
    if tickCount % 4 == 0 then pcall(commandTick) end
    if tickCount % 10 == 0 then pcall(writeState) end
end

LoopAsync(100, function()
    ExecuteInGameThread(masterTick)
    return false
end)

print("[CoopCombat] loaded: panel for admin, Enter = chat, F9 = sniper, hold the gun item + mouse button = gun\n")
