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

local hudWasOn, hudErrShown = false, false

-- HUD text is looked up by path every time instead of being kept in a variable: the HUD is rebuilt when you
-- respawn and the game frees the old widgets later, so a stored reference becomes a dangling pointer
-- (that crashed UE4SS about 20 seconds after every death).
local function getText(hud, name, size, y, color)
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
    slot:SetAnchors({ Minimum = { X = 0.5, Y = y }, Maximum = { X = 0.5, Y = y } })
    slot:SetAlignment({ X = 0.5, Y = 0.5 })
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
            revive(target)
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
end

LoopAsync(100, function()
    ExecuteInGameThread(function() pcall(hudTick) end)
    return false
end)

local function goDown(astro)
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
    local token = st.token
    ExecuteWithDelay(BLEEDOUT_SECONDS * 1000, function()
        ExecuteInGameThread(function()
            local cur = downed[key]
            if not cur or cur.token ~= token then return end
            local a = findByAddress(key)
            if not a then downed[key] = nil return end
            say("bled out")
            downed[key] = nil
            pcall(function() a:AuthoritySetIsImmuneToDamage(false, a) end)
            finalDeath[key] = true
            local ok3, err3 = pcall(function() a:AuthorityForceKillAstro() end)
            ExecuteWithDelay(5000, function() finalDeath[key] = nil end)
            if not ok3 then say("could not kill: %s", tostring(err3)) end
        end)
    end)
end

function revive(astro)
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
end

local function killPlayer(astro)
    crumb("killPlayer")
    local key = astro:GetAddress()
    downed[key] = nil
    finalDeath[key] = true
    pcall(function() astro:AuthoritySetIsImmuneToDamage(false, astro) end)
    pcall(function() astro:AuthorityForceKillAstro() end)
    ExecuteWithDelay(5000, function() finalDeath[key] = nil end)
end

local function hurt(astro, amount)
    local before = astro.Health
    local after = before - amount
    if downed[astro:GetAddress()] then
        if after <= 0 then
            say("killed while downed")
            killPlayer(astro)
        else
            astro.Health = after
            say("Health %.2f -> %.2f (downed)", before, after)
        end
    elseif after <= 0 then
        goDown(astro)
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
local function explodePlayer(astro)
    crumb("explodePlayer")
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

-- Sniper: F9 (the only hotkey) fires along your camera ray at any range and hits the other player closest to the crosshair.
local SNIPE_DAMAGE = 0.5
local HIT_RADIUS = 80 -- cm, how far from the crosshair line still counts as a hit

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

local function aimTarget()
    local pc = getLocalController()
    if not pc then return nil end
    local me, others = getPlayers()
    local cam = pc.PlayerCameraManager
    local origin, rot = cam:GetCameraLocation(), cam:GetCameraRotation()
    local p, y = math.rad(rot.Pitch), math.rad(rot.Yaw)
    local fx, fy, fz = math.cos(p) * math.cos(y), math.cos(p) * math.sin(y), math.sin(p)
    local best, bestMiss, bestRange = nil, math.huge, 0
    for _, a in ipairs(others) do
        local loc = a:K2_GetActorLocation()
        local dx, dy, dz = loc.X - origin.X, loc.Y - origin.Y, loc.Z - origin.Z
        local along = dx * fx + dy * fy + dz * fz
        if along > 0 then
            local px, py, pz = dx - along * fx, dy - along * fy, dz - along * fz
            local miss = math.sqrt(px * px + py * py + pz * pz)
            if miss < HIT_RADIUS and miss < bestMiss then best, bestMiss, bestRange = a, miss, along end
        end
    end
    return best, bestRange, bestMiss
end

local function snipe()
    local best, range, miss = aimTarget()
    if best then
        say("SNIPE HIT at %.0f m (missed center by %.0f cm)", range / 100, miss)
        hurt(best, SNIPE_DAMAGE)
    else
        say("snipe missed")
    end
end

RegisterKeyBind(Key.F9, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(snipe)
        if not ok then say("snipe error: %s", tostring(err)) end
    end)
end)

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
    local cfg = string.format('{"DAMAGE":%.3f,"SNIPE_DAMAGE":%.3f,"HIT_RADIUS":%.0f,"BLEEDOUT_SECONDS":%.1f,"CRAWL_SPEED_SCALE":%.3f,"DOWNED_HEALTH":%.3f,"REVIVE_RANGE":%.0f,"REVIVE_SECONDS":%.1f,"EXPLODE_COUNT":%d}',
        DAMAGE, SNIPE_DAMAGE, HIT_RADIUS, BLEEDOUT_SECONDS, CRAWL_SPEED_SCALE, DOWNED_HEALTH, REVIVE_RANGE, REVIVE_SECONDS, EXPLODE_COUNT)
    local f = io.open(panelDir .. "state.json", "w")
    if not f then return end
    f:write(string.format('{"time":%d,"creative":%s,"players":[%s],"config":%s}', os.time(), tostring(creativeOn()), table.concat(list, ","), cfg))
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
    HIT_RADIUS = { 20, 500, function(v) HIT_RADIUS = v end },
    BLEEDOUT_SECONDS = { 5, 300, function(v) BLEEDOUT_SECONDS = v end },
    CRAWL_SPEED_SCALE = { 0.02, 1, function(v) CRAWL_SPEED_SCALE = v end },
    DOWNED_HEALTH = { 0.05, 1, function(v) DOWNED_HEALTH = v end },
    EXPLODE_COUNT = { 1, 100, function(v) EXPLODE_COUNT = math.floor(v) end },
    REVIVE_RANGE = { 100, 3000, function(v) REVIVE_RANGE = v end },
    REVIVE_SECONDS = { 1, 30, function(v) REVIVE_SECONDS = v end },
}

local function runCommand(line)
    crumb("command " .. line)
    local cmd, a, b = line:match("^(%a+)%s+(%S+)%s*(%S*)")
    if not cmd then return end
    if cmd == "set" then
        local def, val = settable[a], tonumber(b)
        if def and val then def[3](math.max(def[1], math.min(def[2], val))) say("panel: %s = %s", a, b) end
        return
    end
    local astro = findPlayer(a)
    if not astro then say("panel: player %s not found", a) return end
    if cmd == "hurt" then hurt(astro, tonumber(b) or DAMAGE)
    elseif cmd == "heal" then
        if downed[astro:GetAddress()] then revive(astro) end
        astro.Health = astro.MaxHealth
    elseif cmd == "down" then goDown(astro)
    elseif cmd == "revive" then revive(astro)
    elseif cmd == "kill" then killPlayer(astro)
    elseif cmd == "explode" then explodePlayer(astro)
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

print("[CoopCombat] loaded: controlled from the admin panel\n")
