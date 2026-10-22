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

LoopAsync(100, function()
    ExecuteInGameThread(function() pcall(hudTick) end)
    return false
end)

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
        if speed > minV * 0.7 then
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

LoopAsync(50, function()
    ExecuteInGameThread(function() pcall(fallTick) end)
    return false
end)

-- Natural damage (falls etc.) goes through native code, so catch it instead of replacing it.
-- 1) fast watcher: health about to hit zero -> downed instead
LoopAsync(50, function()
    ExecuteInGameThread(function()
        pcall(function()
            crumb("watcher")
            local me = getLocalCached()
            if me and not downed[me:GetAddress()] and not finalDeath[me:GetAddress()] and me.bIsAlive ~= 0 and me.Health <= 0.02 then
                say("caught lethal health (%.3f)", me.Health)
                goDown(me)
            end
        end)
    end)
    return false
end)


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

local function aimRay(pc)
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

local function sendChat(text)
    text = cleanChat(text)
    if text == "" then return end
    if os.clock() - chat.lastSent < 0.5 then return end
    chat.lastSent = os.clock()
    local pc = getLocalController()
    if not pc then say("chat: no local controller") return end
    if isHost(pc) then
        broadcastChat(playerNameOf(pc) .. ": " .. text, pc.PlayerState)
    else
        local ok, err = pcall(function() pc:ServerExec("CCHAT " .. text) end)
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

local function handleEvt(text)
    local kind, rest = text:match("^(%u+)|(.*)$")
    if kind == "FEED" then
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
                if body ~= "" then broadcastChat(playerNameOf(pc) .. ": " .. body, pc.PlayerState) end
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
    box:SetHintText(FText("Type a message, Enter to send"))
    local slot = tree.RootWidget:AddChild(box)
    slot:SetAnchors({ Minimum = { X = 0.02, Y = 0.8 }, Maximum = { X = 0.02, Y = 0.8 } })
    slot:SetAlignment({ X = 0, Y = 0.5 })
    slot:SetPosition({ X = 0, Y = 0 })
    slot:SetAutoSize(false)
    slot:SetSize({ X = 700, Y = 44 })
    slot:SetZOrder(110)
    return box
end

local function closeChat()
    crumb("closeChat")
    chat.open = false
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
        pcall(function()
            local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
            lib:SetInputMode_GameOnly(pc)
            pc.bShowMouseCursor = false
        end)
    end
end

local function openChat()
    crumb("openChat")
    local pc = getLocalController()
    local hud = FindFirstOf("PlayWidgetInstance_C")
    if not pc or not alive(hud) then return end
    -- a visible mouse cursor means a menu is open: Enter there must not open the chat
    local cursor = pc.bShowMouseCursor
    if cursor == true or (type(cursor) == "number" and cursor ~= 0) then return end
    local box = getInputBox(hud)
    box:SetText(FText(""))
    box:SetVisibility(0)
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    lib:SetInputMode_UIOnlyEx(pc, box, 0)
    pc.bShowMouseCursor = true
    box:SetKeyboardFocus()
    chat.open = true
    chat.lastShown = os.clock()
end

local function submitChat()
    crumb("submitChat")
    local hud = FindFirstOf("PlayWidgetInstance_C")
    local text = ""
    if alive(hud) then
        local ok, t = pcall(function() return getInputBox(hud):GetText():ToString() end)
        if ok and type(t) == "string" then text = t end
    end
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
    local cfg = string.format('{"DAMAGE":%.3f,"SNIPE_DAMAGE":%.3f,"GUN_DAMAGE":%.3f,"GUN_COOLDOWN":%.2f,"HIT_RADIUS":%.0f,"BLEEDOUT_SECONDS":%.1f,"CRAWL_SPEED_SCALE":%.3f,"DOWNED_HEALTH":%.3f,"REVIVE_RANGE":%.0f,"REVIVE_SECONDS":%.1f,"EXPLODE_COUNT":%d,"PVP_IN_CREATIVE":%d}',
        DAMAGE, SNIPE_DAMAGE, GUN_DAMAGE, GUN_COOLDOWN, HIT_RADIUS, BLEEDOUT_SECONDS, CRAWL_SPEED_SCALE, DOWNED_HEALTH, REVIVE_RANGE, REVIVE_SECONDS, EXPLODE_COUNT, PVP_IN_CREATIVE)
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

LoopAsync(1000, function()
    ExecuteInGameThread(function() pcall(writeState) end)
    return false
end)

LoopAsync(400, function()
    local f = io.open(panelDir .. "commands.txt", "r")
    if f then
        local text = f:read("*a")
        f:close()
        if text and text ~= "" then
            local w = io.open(panelDir .. "commands.txt", "w")
            if w then w:close() end
            ExecuteInGameThread(function()
                for line in text:gmatch("[^\r\n]+") do
                    local ok, err = pcall(runCommand, line)
                    if not ok then say("panel command error: %s", tostring(err)) end
                end
            end)
        end
    end
    return false
end)

print("[CoopCombat] loaded: panel for admin, Enter = chat, F9 = sniper, hold the gun item + mouse button = gun\n")
