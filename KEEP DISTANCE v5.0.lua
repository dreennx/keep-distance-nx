-- ═══════════════════════════════════════════════════════════
-- KEEP DISTANCE v5.5 · Panel Glass Premium + BLINDAJE anti-ataques
-- CEREBRO DE ESCAPE: elige la mejor RUTA en vez de solo empujar:
--   anti-flanqueo (ya no se congela si te rodean) · esquiva paredes
--   anti-zigzag · anti-atasco · histéresis (no titubea en el borde)
-- SIN SALTO: movimiento horizontal puro (Air Walk safe)
-- BLINDAJE: watchdog reconstruye la UI si te la borran +
--           auto-reconexión de bucles + nombre aleatorio + reparent
-- ═══════════════════════════════════════════════════════════

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local Workspace        = game:GetService("Workspace")
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer      = Players.LocalPlayer

local SESSION = {}
_G.__KEEP_DISTANCE_SESSION = SESSION

-- ════════════ BLINDAJE (config) ════════════
local SHIELD = {
    USE_GETHUI  = false,  -- true = parent oculto (gethui/CoreGui). Si tus botones dejan de responder en Xeno, déjalo en false.
    REBUILD     = true,   -- reconstruye la UI si te la destruyen
    REPARENT    = true,   -- si te la desanclan (Parent=nil) la vuelve a meter al instante
    RANDOM_NAME = true,   -- nombre aleatorio en el ScreenGui (evita scripts que borran por nombre conocido)
    WATCH_HZ    = 0.5,    -- cada cuánto patrulla el watchdog (segundos)
}
local GUI_NAME = SHIELD.RANDOM_NAME
    and ("_" .. string.format("%x", math.random(0x100000, 0xFFFFFF)))
    or  "KeepDistanceSmart"

-- ════════════ ESTADO LÓGICO (persiste aunque reconstruya la UI) ════════════
local activeMode  = nil
local modeButtons = {}
local home        = nil
local anchored    = false
local lastPos     = nil
local safeY       = nil
local lastSafePos = nil

-- estado del cerebro de escape (keep distance)
local evading       = false   -- true mientras huimos (activa la histéresis)
local lastEscapeDir = nil     -- último rumbo elegido (anti-zigzag)
local stuckFrames   = 0       -- frames seguidos sin avanzar (anti-atasco)
local lastFramePos  = nil     -- posición del frame anterior mientras evadimos

-- estado del anillo de rango (indicador visual del radio)
local showRing    = false   -- ÚNICO control del círculo (botón ojo). false = no aparece NUNCA.
local destroyRing           -- forward-declare (selfDestruct lo necesita)

-- ════════════ CONEXIONES ════════════
local _conns        = {}   -- núcleo (bucles, watchdog, char) → viven toda la sesión
local _uiConns      = {}   -- de la UI (se purgan en cada reconstrucción)
local _loopConns    = {}   -- referencias a los bucles para auto-reconexión
local _gui
local _dead         = false
local _noclipForced = {}     -- partes a las que les pusimos CanCollide=false
local noclipUntil   = 0      -- os.clock() hasta cuando dura el noclip
local buildUI, safeRebuild   -- forward-declare (watchdog/reparent las necesitan)

local function track(conn)
    _conns[#_conns + 1] = conn
    return conn
end
local function trackUI(conn)
    _uiConns[#_uiConns + 1] = conn
    return conn
end
local function clearUIConns()
    for _, c in ipairs(_uiConns) do pcall(function() c:Disconnect() end) end
    table.clear(_uiConns)
end

local function selfDestruct()
    if _dead then return end
    _dead = true
    for _, c in ipairs(_conns)   do pcall(function() c:Disconnect() end) end
    for _, c in ipairs(_uiConns) do pcall(function() c:Disconnect() end) end
    _conns, _uiConns = {}, {}
    for p in pairs(_noclipForced) do
        pcall(function() if p and p.Parent then p.CanCollide = true end end)
    end
    _noclipForced = {}
    if destroyRing then pcall(destroyRing) end
    if _gui then pcall(function() _gui:Destroy() end) end
    if _G.__KEEP_DISTANCE_GUI == _gui then _G.__KEEP_DISTANCE_GUI = nil end
end

-- ¿Seguimos siendo la sesión válida?
--  • token == nuestro  -> sí
--  • token == nil      -> alguien lo borró para matarnos: lo RECUPERAMOS y seguimos
--  • token == otra tabla -> un re-exec legítimo tomó el control: morimos
local function sessionAlive()
    local cur = _G.__KEEP_DISTANCE_SESSION
    if cur == SESSION then return true end
    if cur == nil then
        _G.__KEEP_DISTANCE_SESSION = SESSION
        return true
    end
    return false
end

-- ════════════ CONFIG ════════════
local MODES = {
    -- More.SAFE_DISTANCE ya NO se usa directo: More sigue el slider del Radio (ver modeSafeDistance).
    More = { SAFE_DISTANCE = 125, MAX_STEP = 5   },
    Less = { SAFE_DISTANCE = 8,   MAX_STEP = 2.5 },
}
local GROUND_CHECK = 15
local WALL_CHECK   = 3

local ANCHOR = {
    RADIUS      = 125,   -- alcance de More Distance + radio del ancla + círculo azul (unificado)
    RADIUS_MIN  = 5,
    RADIUS_MAX  = 200,   -- tope del slider (subido a 200)
    RADIUS_STEP = 5,
    CLEAR_DIST  = 12,
    DEADZONE    = 0.4,
    MAX_STEP    = 5,
}

-- Distancia de reacción EFECTIVA del modo activo.
--  · "More": sigue el slider del Radio (ANCHOR.RADIUS) => el círculo azul = rango real de detección.
--  · "Less": mantiene su valor propio (acercarte a 8 studs).
local function modeSafeDistance(mode)
    if mode == "More" then return ANCHOR.RADIUS end
    return MODES[mode].SAFE_DISTANCE
end

local GUARD = {
    FLING_MAX = 30,
    FLING_VEL = 100,
    FALL_VEL  = 40,
    VOID_DROP = 60,
}

-- ════════════ SUPER DETECCIÓN (alta velocidad + invisibles) ════════════
local DETECT = {
    PREDICT_TIME = 0.08,   -- s de anticipación por velocidad (los detecta donde VAN a estar, no donde estaban)
    PREDICT_MAX  = 60,     -- studs máx de extrapolación (anti-fling: no perseguir fantasmas)
    HOLD_TIME    = 1.5,    -- s que recordamos su última posición (invisibles que parpadean / esconden el char)
    USE_PIVOT    = true,   -- fallback GetPivot() si no hay ninguna parte localizable
    DEEP_SCAN    = true,   -- buscar CUALQUIER BasePart si no hay HRP/Head (cazar partes ocultas)
}

-- ════════════ CEREBRO DE ESCAPE (elige ruta, no solo empuja) ════════════
local SMART = {
    DIRS         = 16,    -- direcciones candidatas alrededor tuyo
    LOOK_MULT    = 4,     -- cuántos pasos "mira hacia adelante" al puntuar cada ruta
    SEED_W       = 3,     -- bonus a la dirección natural de repulsión
    SMOOTH_W     = 2.5,   -- bonus a mantener el rumbo anterior (anti-zigzag)
    WALL_TRIES   = 4,     -- máx raycasts/frame buscando ruta sin pared (perf)
    EXIT_FACTOR  = 1.15,  -- histéresis: sigue evadiendo hasta safe*este margen
    STUCK_FRAMES = 6,     -- frames sin avanzar -> noclip + re-decidir ruta
}

-- ════════════ DISCORD (logo NX) ════════════
-- << PEGA AQUI TU INVITE DE DISCORD >>
local DISCORD_LINK = "https://discord.gg/TU_INVITE"

-- ════════════ PALETA (glass oscuro premium) ════════════
local C = {
    BG      = Color3.fromRGB(14, 15, 20),
    SURFACE = Color3.fromRGB(22, 24, 32),
    ROW     = Color3.fromRGB(28, 31, 42),
    ROW_HOV = Color3.fromRGB(36, 40, 54),
    ACCENT  = Color3.fromRGB(0, 150, 255),
    TEXT_HI = Color3.fromRGB(232, 236, 250),
    TEXT_LO = Color3.fromRGB(120, 128, 158),
    WHITE   = Color3.fromRGB(255, 255, 255),
    ON      = Color3.fromRGB(0, 200, 100),
    OFF     = Color3.fromRGB(50, 50, 55),
}

local DUR_FAST = 0.12
local DUR_MED  = 0.20
local DUR_SLOW = 0.30

local function tw(o, props, dur, style, dir)
    local t = TweenService:Create(o,
        TweenInfo.new(dur or DUR_MED, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out), props)
    t:Play(); return t
end
local function corner(p, r)
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r or 8); c.Parent = p; return c
end
local function stroke(p, transp, thick, col)
    local s = Instance.new("UIStroke")
    s.Color = col or C.WHITE; s.Transparency = transp or 0.85; s.Thickness = thick or 1; s.Parent = p
    return s
end
-- Fondo glass premium: navy profundo arriba -> casi negro abajo (sólido, sin lavado)
local function glassGrad(p)
    local g = Instance.new("UIGradient", p)
    g.Rotation = 90
    g.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0,    Color3.fromRGB(34, 38, 56)),
        ColorSequenceKeypoint.new(0.55, Color3.fromRGB(20, 22, 32)),
        ColorSequenceKeypoint.new(1,    Color3.fromRGB(11, 12, 18)),
    })
    return g
end

local function getRoot()
    local char = LocalPlayer.Character
    if not char then return nil end
    return char:FindFirstChild("HumanoidRootPart")
end

-- ════════════ ANILLO DE RANGO (indicador visual del radio, perf-safe) ════════════
-- 1 sola Part (disco Neon fino) que sigue al HRP. Se actualiza el tamaño SOLO cuando
-- cambia el radio (event-based, no en loop). No interfiere: CanQuery/CanTouch/CanCollide
-- en false => los raycasts del movimiento lo ignoran por completo.
local RANGE_RING = {
    COLOR       = Color3.fromRGB(45, 160, 255),   -- núcleo azul premium
    GLOW_COLOR  = Color3.fromRGB(130, 205, 255),  -- halo más claro
    CORE_TRANSP = 0.58,   -- disco central (nítido pero no tapa el suelo)
    GLOW_TRANSP = 0.88,   -- halo suave alrededor
    GLOW_PAD    = 3.5,    -- studs de halo más allá del borde
    THICK       = 0.2,    -- grosor del disco (studs)
}
local _ring, _ringGlow, _ringR = nil, nil, -1

destroyRing = function()
    if _ring then pcall(function() _ring:Destroy() end) end   -- el glow es hijo => cae con él
    _ring, _ringGlow, _ringR = nil, nil, -1
    if _G.__KEEP_DISTANCE_RING then _G.__KEEP_DISTANCE_RING = nil end
end

-- disco Neon fino y horizontal; no interfiere (CanQuery/CanTouch/CanCollide en false).
local function makeDisc(color, transp)
    local p = Instance.new("Part")
    p.Shape        = Enum.PartType.Cylinder   -- largo sobre eje X local => lo giramos a horizontal
    p.Anchored     = true
    p.CanCollide   = false
    p.CanQuery     = false   -- ← clave: invisible para Workspace:Raycast (no estorba el movimiento)
    p.CanTouch     = false
    p.CastShadow   = false
    p.Locked       = true
    p.Material     = Enum.Material.Neon
    p.Color        = color
    p.Transparency = transp
    p.Size         = Vector3.new(RANGE_RING.THICK, 1, 1)
    return p
end

local function ensureRing()
    if _ring and _ring.Parent then return _ring end
    local core  = makeDisc(RANGE_RING.COLOR, RANGE_RING.CORE_TRANSP)
    core.Name   = "_nxRange"
    core.Parent = Workspace
    local glow  = makeDisc(RANGE_RING.GLOW_COLOR, RANGE_RING.GLOW_TRANSP)
    glow.Name   = "_nxRangeGlow"
    glow.Parent = core   -- hijo del núcleo => se limpia solo al destruir el núcleo (nada de fugas)
    _ring, _ringGlow, _ringR = core, glow, -1
    _G.__KEEP_DISTANCE_RING = core
    return core
end

-- se llama 1 vez por frame; barato (2 sets de CFrame). SOLO si showRing está ON.
local function updateRing(root)
    if not showRing then
        if _ring then destroyRing() end
        return
    end
    if not root then return end
    local core = ensureRing()
    if _ringR ~= ANCHOR.RADIUS then
        local d = ANCHOR.RADIUS * 2
        core.Size = Vector3.new(RANGE_RING.THICK, d, d)
        if _ringGlow then
            local dg = d + RANGE_RING.GLOW_PAD * 2
            _ringGlow.Size = Vector3.new(RANGE_RING.THICK * 0.8, dg, dg)
        end
        _ringR = ANCHOR.RADIUS
    end
    -- centrado en el HRP (sigue en el aire => Air Walk safe). Giro 90° en Z = disco horizontal.
    local cf = CFrame.new(root.Position) * CFrame.Angles(0, 0, math.rad(90))
    core.CFrame = cf
    if _ringGlow then _ringGlow.CFrame = cf end
end

-- ════════════ CACHE POR FRAME (perf) ════════════
local _excludeList = {}
local _otherPos    = {}
local _lastSeen    = {}   -- [player] = { pos = Vector3, t = os.clock() }  (memoria anti-invisible)
local _rayParams   = RaycastParams.new()
_rayParams.FilterType = Enum.RaycastFilterType.Exclude

-- Busca la mejor parte localizable del personaje (aunque esté invisible/oculto).
-- Prioridad: HumanoidRootPart > Head > (deep scan) cualquier BasePart.
local function getCharPart(char)
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if hrp and hrp:IsA("BasePart") then return hrp end
    local head = char:FindFirstChild("Head")
    if head and head:IsA("BasePart") then return head end
    if DETECT.DEEP_SCAN then
        for _, d in ipairs(char:GetDescendants()) do
            if d:IsA("BasePart") then return d end
        end
    end
    return nil
end

-- Posición de un personaje con predicción por velocidad (alta velocidad).
-- Devuelve nil si no se pudo localizar ni por partes ni por pivote.
local function resolveCharPos(char)
    local part = getCharPart(char)
    if part then
        local pos = part.Position
        local vel = part.AssemblyLinearVelocity
        if vel and vel.Magnitude > 0.1 then
            local pred = vel * DETECT.PREDICT_TIME
            if pred.Magnitude > DETECT.PREDICT_MAX then
                pred = pred.Unit * DETECT.PREDICT_MAX
            end
            pos = pos + pred
        end
        return pos
    end
    if DETECT.USE_PIVOT then
        local ok, piv = pcall(function() return char:GetPivot().Position end)
        if ok and piv then return piv end
    end
    return nil
end

local function refreshFrameCache()
    table.clear(_excludeList)
    table.clear(_otherPos)
    local now = os.clock()

    for _, plr in ipairs(Players:GetPlayers()) do
        local ch = plr.Character
        if ch then _excludeList[#_excludeList + 1] = ch end

        if plr ~= LocalPlayer then
            local pos = ch and resolveCharPos(ch) or nil
            if pos then
                _otherPos[#_otherPos + 1] = pos
                _lastSeen[plr] = { pos = pos, t = now }   -- visto: refresca memoria
            else
                -- invisible/oculto este frame: usa la última posición conocida si es reciente
                local ls = _lastSeen[plr]
                if ls and (now - ls.t) <= DETECT.HOLD_TIME then
                    _otherPos[#_otherPos + 1] = ls.pos
                end
            end
        end
    end

    -- purga de memoria: jugadores que se fueron o caducaron
    for plr, ls in pairs(_lastSeen) do
        if (now - ls.t) > DETECT.HOLD_TIME or not plr.Parent then
            _lastSeen[plr] = nil
        end
    end

    _rayParams.FilterDescendantsInstances = _excludeList
end

local function findGround(pos)
    local ray = Workspace:Raycast(pos + Vector3.new(0, 2, 0), Vector3.new(0, -(GROUND_CHECK + 2), 0), _rayParams)
    return ray and ray.Position or nil
end

local function pathClear(pos, direction)
    local ray = Workspace:Raycast(pos, direction * WALL_CHECK, _rayParams)
    return ray == nil
end

-- Movimiento v4.5: HORIZONTAL PURO. Conserva tu Y siempre (Air Walk).
-- Nunca pega al piso => NUNCA salta. Nunca cancela por falta de suelo.
local function resolveMove(myPos, pushVec)
    return myPos + pushVec, myPos.Y
end

local function nearestPlayerDist(pos)
    local best = math.huge
    for _, op in ipairs(_otherPos) do
        local off = Vector3.new(pos.X - op.X, 0, pos.Z - op.Z)
        local m = off.Magnitude
        if m < best then best = m end
    end
    return best
end

-- Muestrea SMART.DIRS direcciones y elige la mejor ruta de escape:
--   · puntúa qué tan lejos te deja de TODOS (no solo del más cercano)
--   · bonus a la repulsión natural (seed) y al rumbo anterior (anti-zigzag)
--   · de mejor a peor, la primera sin pared gana (máx WALL_TRIES raycasts)
-- Devuelve dir, clear. clear=false => todo bloqueado, el caller activa noclip.
local function bestEscapeDir(myPos, seed, stepLen)
    local look   = math.max(stepLen * SMART.LOOK_MULT, 6)
    local seedU  = (seed and seed.Magnitude > 0.05) and seed.Unit or nil
    local scored = {}
    for i = 0, SMART.DIRS - 1 do
        local a   = (i / SMART.DIRS) * math.pi * 2
        local dir = Vector3.new(math.cos(a), 0, math.sin(a))
        local s   = nearestPlayerDist(myPos + dir * look)
        if seedU         then s = s + dir:Dot(seedU) * SMART.SEED_W end
        if lastEscapeDir then s = s + dir:Dot(lastEscapeDir) * SMART.SMOOTH_W end
        scored[#scored + 1] = { dir = dir, score = s }
    end
    table.sort(scored, function(x, y) return x.score > y.score end)
    for i = 1, math.min(SMART.WALL_TRIES, #scored) do
        if pathClear(myPos, scored[i].dir) then return scored[i].dir, true end
    end
    return scored[1] and scored[1].dir or nil, false
end

local function computeAnchorTarget()
    local clear = ANCHOR.CLEAR_DIST
    if activeMode then
        clear = math.max(clear, math.min(modeSafeDistance(activeMode), ANCHOR.RADIUS))
    end

    if nearestPlayerDist(home) >= clear then
        return home, false
    end

    local repel = Vector3.new(0, 0, 0)
    for _, op in ipairs(_otherPos) do
        local off = Vector3.new(home.X - op.X, 0, home.Z - op.Z)
        local d = off.Magnitude
        if d > 0.05 and d < clear then
            repel = repel + off.Unit * (clear - d)
        end
    end

    local cand = home
    if repel.Magnitude > 0.05 then
        local shift = repel
        if shift.Magnitude > ANCHOR.RADIUS then shift = shift.Unit * ANCHOR.RADIUS end
        cand = Vector3.new(home.X + shift.X, home.Y, home.Z + shift.Z)
    end
    if nearestPlayerDist(cand) >= clear * 0.75 then
        return cand, true
    end

    local best, bestScore = cand, nearestPlayerDist(cand)
    local r = math.min(clear, ANCHOR.RADIUS)
    for i = 0, 11 do
        local a = (i / 12) * math.pi * 2
        local p = Vector3.new(home.X + math.cos(a) * r, home.Y, home.Z + math.sin(a) * r)
        local score = nearestPlayerDist(p)
        if score > bestScore then best, bestScore = p, score end
    end
    return best, true
end

-- ════════════ NO CLIP AUTO (atravesar paredes solo cuando topas) ════════════
local function noclipStep()
    if not sessionAlive() then return end
    local char = LocalPlayer.Character
    if not char then return end
    if os.clock() < noclipUntil then
        for _, p in ipairs(char:GetDescendants()) do
            if p:IsA("BasePart") and p.CanCollide then
                _noclipForced[p] = true
                p.CanCollide = false
            end
        end
    elseif next(_noclipForced) then
        for p in pairs(_noclipForced) do
            if p and p.Parent then p.CanCollide = true end
        end
        table.clear(_noclipForced)
    end
end

-- ════════════ BUCLE PRINCIPAL ════════════
local function mainHeartbeat()
    if not sessionAlive() then selfDestruct() return end
    pcall(function()
        local char = LocalPlayer.Character
        if not char then return end
        local root = char:FindFirstChild("HumanoidRootPart")
        if not root then return end
        local myPos = root.Position
        local vel   = root.AssemblyLinearVelocity

        refreshFrameCache()
        updateRing(root)   -- anillo de rango: sigue al personaje (barato: 1 CFrame/frame)

        -- ── BLINDAJE: SOLO cuando estas anclado (no estorbar fly/tp) ──
        if anchored and home then
            if lastPos then
                local jump = Vector3.new(myPos.X - lastPos.X, 0, myPos.Z - lastPos.Z)
                if jump.Magnitude > GUARD.FLING_MAX and vel.Magnitude > GUARD.FLING_VEL then
                    root.CFrame = CFrame.new(lastPos.X, lastPos.Y, lastPos.Z)
                                * CFrame.Angles(0, math.rad(root.Orientation.Y), 0)
                    root.AssemblyLinearVelocity = Vector3.zero
                    return
                end
            end

            local falling = (vel.Y < -GUARD.FALL_VEL and not findGround(myPos))
                         or ((home.Y - myPos.Y) > GUARD.VOID_DROP)
                         or (myPos.Y < Workspace.FallenPartsDestroyHeight + 50)
            if falling then
                local tgt = computeAnchorTarget()
                root.CFrame = CFrame.new(tgt.X, tgt.Y, tgt.Z)
                            * CFrame.Angles(0, math.rad(root.Orientation.Y), 0)
                root.AssemblyLinearVelocity = Vector3.zero
                safeY       = tgt.Y
                lastSafePos = tgt
                lastPos     = root.Position
                return
            end

            safeY       = myPos.Y
            lastPos     = myPos
            lastSafePos = myPos
        else
            lastPos, safeY, lastSafePos = nil, nil, nil
        end

        -- ── PRIORIDAD 1: ANCLA ──
        if anchored and home then
            local target, contested = computeAnchorTarget()
            local fromHome   = Vector3.new(myPos.X - home.X, 0, myPos.Z - home.Z)
            local outOfRange = fromHome.Magnitude > ANCHOR.RADIUS

            if not (contested or outOfRange) then return end

            local push = Vector3.new(target.X - myPos.X, 0, target.Z - myPos.Z)
            if push.Magnitude < ANCHOR.DEADZONE then return end
            if push.Magnitude > ANCHOR.MAX_STEP then push = push.Unit * ANCHOR.MAX_STEP end

            if not pathClear(myPos, push.Unit) then
                noclipUntil = os.clock() + 0.25
            end

            local destPos, finalY = resolveMove(myPos, push)
            root.CFrame = CFrame.new(destPos.X, finalY, destPos.Z)
                        * CFrame.Angles(0, math.rad(root.Orientation.Y), 0)
            return
        end

        -- ── PRIORIDAD 2: KEEP DISTANCE (cerebro de escape v5.5) ──
        if not activeMode then return end
        local config  = MODES[activeMode]
        local safeD   = modeSafeDistance(activeMode)   -- More sigue el slider del Radio
        local nearest = nearestPlayerDist(myPos)

        -- histéresis: al evadir seguimos hasta safe*EXIT_FACTOR (no titubea en el borde)
        local trigger = evading and (safeD * SMART.EXIT_FACTOR) or safeD
        if nearest >= trigger then
            evading, lastEscapeDir, stuckFrames, lastFramePos = false, nil, 0, nil
            return
        end
        evading = true

        -- repulsión clásica: semilla de dirección + medida de fuerza
        local totalPush = Vector3.zero
        for _, op in ipairs(_otherPos) do
            local flat = Vector3.new(myPos.X - op.X, 0, myPos.Z - op.Z)
            local dist = flat.Magnitude
            if dist < trigger and dist > 0.1 then
                totalPush = totalPush + flat.Unit * ((1 - dist / trigger) * config.MAX_STEP)
            end
        end

        -- fuerza del paso: aunque la repulsión se cancele (flanqueado) hay que moverse
        local stepLen = math.min(totalPush.Magnitude, config.MAX_STEP)
        if stepLen < 0.35 then
            stepLen = math.max(0.35, (1 - nearest / trigger) * config.MAX_STEP)
        end

        -- elegir la MEJOR ruta (no la más obvia): escapa de flanqueos, esquiva paredes
        local dir, clear = bestEscapeDir(myPos, totalPush, stepLen)
        if not dir then return end
        if not clear then
            noclipUntil = os.clock() + 0.25
        end

        -- anti-atasco: ordenamos movernos pero seguimos en el mismo sitio
        if lastFramePos and (myPos - lastFramePos).Magnitude < stepLen * 0.25 then
            stuckFrames = stuckFrames + 1
            if stuckFrames >= SMART.STUCK_FRAMES then
                noclipUntil   = os.clock() + 0.35
                lastEscapeDir = nil     -- re-decidir ruta desde cero
                stuckFrames   = 0
            end
        else
            stuckFrames = 0
        end
        lastFramePos  = myPos
        lastEscapeDir = dir

        local destPos, finalY = resolveMove(myPos, dir * stepLen)
        root.CFrame = CFrame.new(destPos.X, finalY, destPos.Z)
                    * CFrame.Angles(0, math.rad(root.Orientation.Y), 0)
    end)
end

-- ════════════ AUTO-RECONEXIÓN DE BUCLES (anti "se desactiva solo") ════════════
local function ensureLoops()
    if _dead or not sessionAlive() then return end
    if not (_loopConns.noclip and _loopConns.noclip.Connected) then
        _loopConns.noclip = track(RunService.Stepped:Connect(noclipStep))
    end
    if not (_loopConns.main and _loopConns.main.Connected) then
        _loopConns.main = track(RunService.Heartbeat:Connect(mainHeartbeat))
    end
end

-- ═══════════════════════════════════════════════════════════
-- UI v5.1 · sistema de componentes (encapsulado en buildUI para reconstruir)
-- ═══════════════════════════════════════════════════════════
local UI = {}   -- referencias estables entre reconstrucciones (setMode/setAnchor/sync...)

local function getParent()
    if SHIELD.USE_GETHUI then
        local ok, h = pcall(function()
            return (gethui and gethui()) or (get_hidden_gui and get_hidden_gui())
        end)
        if ok and h then return h end
        local ok2, cg = pcall(function() return game:GetService("CoreGui") end)
        if ok2 and cg then return cg end
    end
    return LocalPlayer:WaitForChild("PlayerGui")
end

local function protectGui(g)
    pcall(function()
        if syn and syn.protect_gui then syn.protect_gui(g)
        elseif type(protect_gui) == "function" then protect_gui(g) end
    end)
end

local function syncUI()
    if not UI.ready then return end
    pcall(function()
        UI.setMode(activeMode)
        UI.setAnchor(anchored)
        UI.setRadius(showRing)
        UI.updateAnchorStatus()
        UI.updateGlobalDot()
        UI.refreshRadius()
    end)
end

buildUI = function(firstBuild)
    if _dead then return end
    clearUIConns()
    if _gui then pcall(function() _gui:Destroy() end) end

    -- forward-declares internos
    local updateGlobalDot, updateAnchorStatus, setActiveMode

    local gui = Instance.new("ScreenGui")
    gui.Name           = GUI_NAME
    gui.ResetOnSpawn   = false
    gui.IgnoreGuiInset = true
    gui:SetAttribute("KD", true)      -- huella para que un re-exec lo encuentre aunque el nombre sea aleatorio
    protectGui(gui)
    gui.Parent         = getParent()
    _gui = gui
    _G.__KEEP_DISTANCE_GUI = gui

    -- reparent instantáneo si te lo desanclan (Parent=nil sin Destroy)
    if SHIELD.REPARENT then
        trackUI(gui.AncestryChanged:Connect(function()
            if _dead or not sessionAlive() then return end
            if gui.Parent == nil then
                task.defer(function()
                    if _dead or not sessionAlive() or _gui ~= gui then return end
                    local ok = pcall(function() gui.Parent = getParent() end)
                    if not ok and SHIELD.REBUILD then safeRebuild() end
                end)
            end
        end))
    end

    -- anti-apagado: si te lo deshabilitan (Enabled=false) lo reactivamos al instante
    trackUI(gui:GetPropertyChangedSignal("Enabled"):Connect(function()
        if not _dead and _gui == gui and not gui.Enabled then
            pcall(function() gui.Enabled = true end)
        end
    end))

    -- ── medidas del layout ──
    local PAD        = 14
    local W          = 272
    local HEAD_H     = 46
    local BODY_H     = 330
    local FULL_H     = HEAD_H + BODY_H

    local panel = Instance.new("Frame")
    panel.Size                   = UDim2.new(0, W, 0, FULL_H)
    panel.Position               = UDim2.new(0, 60, 0, 120)
    panel.BackgroundColor3       = C.BG
    panel.BackgroundTransparency = 0.04
    panel.BorderSizePixel        = 0
    panel.ClipsDescendants       = true
    panel.Parent                 = gui
    corner(panel, 16)
    stroke(panel, 0.55, 1.2)
    glassGrad(panel)

    -- glow de acento superior (premium)
    local topGlow = Instance.new("Frame", panel)
    topGlow.Size                   = UDim2.new(1, 0, 0, 64)
    topGlow.Position               = UDim2.new(0, 0, 0, 0)
    topGlow.BackgroundColor3       = C.ACCENT
    topGlow.BorderSizePixel        = 0
    topGlow.ZIndex                 = 0
    do
        local gg = Instance.new("UIGradient", topGlow)
        gg.Rotation = 90
        gg.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.80),
            NumberSequenceKeypoint.new(1, 1.00),
        })
    end

    -- brillo especular superior
    local spec = Instance.new("Frame", panel)
    spec.Size                   = UDim2.new(1, -16, 0, 1)
    spec.Position               = UDim2.new(0, 8, 0, 1)
    spec.BackgroundColor3       = C.WHITE
    spec.BackgroundTransparency = 0.4
    spec.BorderSizePixel        = 0
    corner(spec, 1)

    -- ════════════ HEADER ════════════
    local header = Instance.new("Frame", panel)
    header.Size                   = UDim2.new(1, 0, 0, HEAD_H)
    header.BackgroundTransparency = 1
    header.Active                 = true

    -- dot de estado (idle/keep/anchor)
    local dot = Instance.new("Frame", header)
    dot.Size                   = UDim2.new(0, 9, 0, 9)
    dot.Position               = UDim2.new(0, PAD + 2, 0.5, -4)
    dot.BackgroundColor3       = C.TEXT_LO
    dot.BorderSizePixel        = 0
    corner(dot, 5)
    local dotGlow = Instance.new("UIStroke", dot)
    dotGlow.Color = C.TEXT_LO; dotGlow.Transparency = 1; dotGlow.Thickness = 4

    local hTitle = Instance.new("TextLabel", header)
    hTitle.Size                   = UDim2.new(1, -100, 1, 0)
    hTitle.Position               = UDim2.new(0, PAD + 20, 0, 0)
    hTitle.BackgroundTransparency = 1
    hTitle.Text                   = "Keep Distance"
    hTitle.TextColor3             = C.TEXT_HI
    hTitle.Font                   = Enum.Font.GothamBold
    hTitle.TextSize               = 15
    hTitle.TextXAlignment         = Enum.TextXAlignment.Left

    -- ════════════ LOGO NX PREMIUM (elemento visual principal · clickeable -> Discord) ════════════
    -- Contenedor: 1 UIScale escala TODO junto en hover. Capas por ZIndex: glow < fill < texto < hit.
    local nxWrap = Instance.new("Frame", header)
    nxWrap.Size                   = UDim2.new(0, 46, 0, 28)
    nxWrap.Position               = UDim2.new(1, -88, 0.5, -14)
    nxWrap.BackgroundTransparency = 1
    local nxScale = Instance.new("UIScale", nxWrap); nxScale.Scale = 1

    -- glow azul detrás (respira con un loop suave)
    local nxGlow = Instance.new("Frame", nxWrap)
    nxGlow.Size                   = UDim2.new(1, 14, 1, 14)
    nxGlow.Position               = UDim2.new(0, -7, 0, -7)
    nxGlow.BackgroundColor3       = C.ACCENT
    nxGlow.BackgroundTransparency = 0.78
    nxGlow.BorderSizePixel        = 0
    nxGlow.ZIndex                 = 1
    corner(nxGlow, 13)
    do
        local gg = Instance.new("UIGradient", nxGlow)
        gg.Rotation = 90
        gg.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.25),
            NumberSequenceKeypoint.new(1, 0.85),
        })
    end

    -- fondo glass con gradiente moderno (navy premium)
    local nxFill = Instance.new("Frame", nxWrap)
    nxFill.Size                   = UDim2.new(1, 0, 1, 0)
    nxFill.BackgroundColor3       = C.SURFACE
    nxFill.BackgroundTransparency = 0.04
    nxFill.BorderSizePixel        = 0
    nxFill.ZIndex                 = 2
    corner(nxFill, 9)
    do
        local bg = Instance.new("UIGradient", nxFill)
        bg.Rotation = 120
        bg.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(30, 42, 66)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(13, 18, 30)),
        })
    end
    -- UIStroke con degradado (borde premium)
    local nxStroke = stroke(nxFill, 0.2, 1.4, C.ACCENT)
    do
        local sg = Instance.new("UIGradient", nxStroke)
        sg.Rotation = 90
        sg.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(120, 200, 255)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 110, 220)),
        })
    end

    -- texto "NX" con gradiente azul brillante (identidad NX)
    local nxText = Instance.new("TextLabel", nxWrap)
    nxText.Size                   = UDim2.new(1, 0, 1, 0)
    nxText.BackgroundTransparency = 1
    nxText.Text                   = "NX"
    nxText.TextColor3             = C.WHITE
    nxText.Font                   = Enum.Font.GothamBlack
    nxText.TextSize               = 16
    nxText.ZIndex                 = 3
    do
        local tg = Instance.new("UIGradient", nxText)
        tg.Rotation = 90
        tg.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(190, 225, 255)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 150, 255)),
        })
    end

    -- capa de click transparente (arriba de todo)
    local nxBadge = Instance.new("TextButton", nxWrap)
    nxBadge.Size                   = UDim2.new(1, 0, 1, 0)
    nxBadge.BackgroundTransparency = 1
    nxBadge.Text                   = ""
    nxBadge.AutoButtonColor        = false
    nxBadge.ZIndex                 = 5

    -- brillo animado: el glow respira (se pausa en hover para no pelear con el estado hover)
    local nxHover = false
    task.spawn(function()
        while not _dead and _gui == gui do
            if not nxHover then tw(nxGlow, { BackgroundTransparency = 0.6 }, 1.1, Enum.EasingStyle.Sine) end
            task.wait(1.2)
            if _dead or _gui ~= gui then break end
            if not nxHover then tw(nxGlow, { BackgroundTransparency = 0.82 }, 1.1, Enum.EasingStyle.Sine) end
            task.wait(1.2)
        end
    end)

    -- botón minimizar
    local minBtn = Instance.new("TextButton", header)
    minBtn.Size                   = UDim2.new(0, 28, 0, 28)
    minBtn.Position               = UDim2.new(1, -36, 0.5, -14)
    minBtn.BackgroundColor3       = C.ROW
    minBtn.BackgroundTransparency = 0.35
    minBtn.BorderSizePixel        = 0
    minBtn.Text                   = "—"
    minBtn.TextColor3             = C.TEXT_HI
    minBtn.Font                   = Enum.Font.GothamBold
    minBtn.TextSize               = 15
    minBtn.AutoButtonColor        = false
    corner(minBtn, 8)
    stroke(minBtn, 0.85)

    local hLine = Instance.new("Frame", panel)
    hLine.Size                   = UDim2.new(1, -2 * PAD, 0, 1)
    hLine.Position               = UDim2.new(0, PAD, 0, HEAD_H - 1)
    hLine.BackgroundColor3       = C.WHITE
    hLine.BackgroundTransparency = 0.88
    hLine.BorderSizePixel        = 0

    -- drag por el header (se bloquea si estamos arrastrando el slider)
    local _panelDrag = false   -- expuesto para que el slider lo bloquee
    do
        local dragStart, startPos = nil, nil
        trackUI(header.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
                _panelDrag = true; dragStart = i.Position; startPos = panel.Position
            end
        end))
        trackUI(UserInputService.InputChanged:Connect(function(i)
            if _panelDrag and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
                local d = i.Position - dragStart
                panel.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                                            startPos.Y.Scale, startPos.Y.Offset + d.Y)
            end
        end))
        trackUI(UserInputService.InputEnded:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
                _panelDrag = false
            end
        end))
    end

    -- ════════════ BODY (contenedor para minimizar) ════════════
    local body = Instance.new("Frame", panel)
    body.Size                   = UDim2.new(1, 0, 0, BODY_H)
    body.Position               = UDim2.new(0, 0, 0, HEAD_H)
    body.BackgroundTransparency = 1

    -- helper: anti-spam de clicks (memoria: Xeno = PlayerGui + MouseButton1Click)
    local function safeClick(btn, fn)
        local last = 0
        trackUI(btn.MouseButton1Click:Connect(function()
            local now = tick()
            if now - last < 0.20 then return end
            last = now
            fn()
        end))
    end

    -- ════════════ TOAST (notificación flotante) ════════════
    local function toast(msg, ok)
        local t = Instance.new("Frame", gui)
        t.Size                   = UDim2.new(0, 250, 0, 42)
        t.Position               = UDim2.new(0.5, -125, 1, 30)   -- fuera de pantalla (abajo)
        t.BackgroundColor3       = C.SURFACE
        t.BackgroundTransparency = 0.06
        t.BorderSizePixel        = 0
        corner(t, 11)
        stroke(t, 0.45, 1.2, ok and C.ON or C.ACCENT)

        local bar = Instance.new("Frame", t)
        bar.Size             = UDim2.new(0, 3, 1, -14)
        bar.Position         = UDim2.new(0, 8, 0, 7)
        bar.BackgroundColor3 = ok and C.ON or C.ACCENT
        bar.BorderSizePixel  = 0
        corner(bar, 2)

        local l = Instance.new("TextLabel", t)
        l.Size                   = UDim2.new(1, -28, 1, 0)
        l.Position               = UDim2.new(0, 20, 0, 0)
        l.BackgroundTransparency = 1
        l.Text                   = msg
        l.TextColor3             = C.TEXT_HI
        l.Font                   = Enum.Font.GothamMedium
        l.TextSize               = 13
        l.TextXAlignment         = Enum.TextXAlignment.Left

        tw(t, { Position = UDim2.new(0.5, -125, 1, -70) }, DUR_MED, Enum.EasingStyle.Back)
        task.delay(2.4, function()
            if t and t.Parent then
                tw(t, { Position = UDim2.new(0.5, -125, 1, 30), BackgroundTransparency = 1 }, DUR_MED)
                task.delay(DUR_MED + 0.05, function() pcall(function() t:Destroy() end) end)
            end
        end)
    end

    -- ════════════ ABRIR DISCORD (logo NX) ════════════
    -- Xeno bloquea OpenBrowserWindow -> copiamos al portapapeles + intento de abrir.
    local function openDiscord()
        local copied = false
        pcall(function()
            local clip = setclipboard or toclipboard or (syn and syn.write_clipboard) or writeclipboard
            if clip then clip(DISCORD_LINK); copied = true end
        end)
        pcall(function()
            game:GetService("GuiService"):OpenBrowserWindow(DISCORD_LINK)
        end)
        if copied then
            toast("Discord copiado · pégalo en tu navegador", true)
        else
            toast("Discord: " .. DISCORD_LINK, true)
        end
    end

    -- ── etiqueta de sección ──
    local function sectionLabel(parent, text, posY)
        local l = Instance.new("TextLabel", parent)
        l.Size                   = UDim2.new(1, -2 * PAD, 0, 14)
        l.Position               = UDim2.new(0, PAD, 0, posY)
        l.BackgroundTransparency = 1
        l.Text                   = text
        l.TextColor3             = Color3.fromRGB(132, 168, 235)
        l.Font                   = Enum.Font.GothamBold
        l.TextSize               = 11
        l.TextXAlignment         = Enum.TextXAlignment.Left
        return l
    end

    -- ════════════ COMPONENTE: FILA CON SWITCH ════════════
    -- Devuelve { row, setOn(state) }  ·  toda la fila es clickeable (touch 44px)
    local function makeSwitchRow(parent, title, subtitle, posY, onToggle)
        local row = Instance.new("TextButton", parent)
        row.Size                   = UDim2.new(1, -2 * PAD, 0, 44)
        row.Position               = UDim2.new(0, PAD, 0, posY)
        row.BackgroundColor3       = C.ROW
        row.BackgroundTransparency = 0.25
        row.BorderSizePixel        = 0
        row.Text                   = ""
        row.AutoButtonColor        = false
        corner(row, 10)
        local rowStroke = stroke(row, 0.86)
        do  -- UIStroke con degradado (borde glass premium)
            local sg = Instance.new("UIGradient", rowStroke)
            sg.Rotation = 90
            sg.Color = ColorSequence.new(Color3.fromRGB(150, 170, 210), Color3.fromRGB(40, 48, 70))
        end
        local rowScale = Instance.new("UIScale", row); rowScale.Scale = 1

        local tl = Instance.new("TextLabel", row)
        tl.Size                   = UDim2.new(1, -76, 0, subtitle and 16 or 44)
        tl.Position               = UDim2.new(0, 12, 0, subtitle and 6 or 0)
        tl.BackgroundTransparency = 1
        tl.Text                   = title
        tl.TextColor3             = C.TEXT_HI
        tl.Font                   = Enum.Font.GothamBold
        tl.TextSize               = 13
        tl.TextXAlignment         = Enum.TextXAlignment.Left
        tl.TextYAlignment         = Enum.TextYAlignment.Center

        local subLabel
        if subtitle then
            subLabel = Instance.new("TextLabel", row)
            subLabel.Size                   = UDim2.new(1, -76, 0, 14)
            subLabel.Position               = UDim2.new(0, 12, 0, 23)
            subLabel.BackgroundTransparency = 1
            subLabel.Text                   = subtitle
            subLabel.TextColor3             = C.TEXT_LO
            subLabel.Font                   = Enum.Font.Gotham
            subLabel.TextSize               = 10
            subLabel.TextXAlignment         = Enum.TextXAlignment.Left
        end

        -- switch (track + knob)
        local trackSw = Instance.new("Frame", row)
        trackSw.Size                   = UDim2.new(0, 44, 0, 24)
        trackSw.Position               = UDim2.new(1, -56, 0.5, -12)
        trackSw.BackgroundColor3       = C.OFF
        trackSw.BorderSizePixel        = 0
        corner(trackSw, 12)

        local knob = Instance.new("Frame", trackSw)
        knob.Size                   = UDim2.new(0, 18, 0, 18)
        knob.Position               = UDim2.new(0, 3, 0.5, -9)
        knob.BackgroundColor3       = C.WHITE
        knob.BorderSizePixel        = 0
        corner(knob, 9)
        local knobGlow = Instance.new("UIStroke", knob)   -- glow verde cuando está ON
        knobGlow.Color = C.ON; knobGlow.Thickness = 5; knobGlow.Transparency = 1

        local state = false
        local function setOn(on, instant)
            state = on
            local kPos = on and UDim2.new(1, -21, 0.5, -9) or UDim2.new(0, 3, 0.5, -9)
            local tCol = on and C.ON or C.OFF
            if instant then
                knob.Position = kPos; trackSw.BackgroundColor3 = tCol
                knobGlow.Transparency = on and 0.5 or 1
            else
                tw(knob, { Position = kPos }, DUR_MED, Enum.EasingStyle.Back)
                tw(trackSw, { BackgroundColor3 = tCol }, DUR_FAST)
                tw(knobGlow, { Transparency = on and 0.5 or 1 }, DUR_MED)
            end
        end

        -- estados Idle/Hover/Press con microanimaciones (sin tocar FPS)
        trackUI(row.MouseEnter:Connect(function()
            tw(row, { BackgroundTransparency = 0.10 }, DUR_FAST)
        end))
        trackUI(row.MouseLeave:Connect(function()
            tw(row, { BackgroundTransparency = 0.25 }, DUR_FAST)
            tw(rowScale, { Scale = 1 }, DUR_FAST)
        end))
        trackUI(row.MouseButton1Down:Connect(function()
            tw(rowScale, { Scale = 0.98 }, DUR_FAST)
        end))
        trackUI(row.MouseButton1Up:Connect(function()
            tw(rowScale, { Scale = 1 }, DUR_FAST, Enum.EasingStyle.Back)
        end))

        safeClick(row, function() onToggle(not state) end)

        local function setSub(text) if subLabel then subLabel.Text = text end end
        return { row = row, setOn = setOn, setSub = setSub }
    end

    -- ════════════ SECCIÓN: MOVIMIENTO ════════════
    sectionLabel(body, "MOVIMIENTO", 6)

    setActiveMode = function(modeKey)
        if activeMode == modeKey then activeMode = nil else activeMode = modeKey end
        evading, lastEscapeDir, stuckFrames, lastFramePos = false, nil, 0, nil
        for _, e in ipairs(modeButtons) do
            e.setOn(activeMode == e.modeKey)
        end
        updateGlobalDot()
    end

    local moreRow = makeSwitchRow(body, "More Distance", "Alejarte (" .. ANCHOR.RADIUS .. " studs)", 26,
        function() setActiveMode("More") end)
    local lessRow = makeSwitchRow(body, "Less Distance", "Acercarte (8 studs)", 76,
        function() setActiveMode("Less") end)

    table.clear(modeButtons)
    table.insert(modeButtons, { setOn = moreRow.setOn, modeKey = "More" })
    table.insert(modeButtons, { setOn = lessRow.setOn, modeKey = "Less" })

    -- ════════════ SECCIÓN: ANCLA INTELIGENTE ════════════
    sectionLabel(body, "ANCLA INTELIGENTE", 132)

    local wpStatus = Instance.new("TextLabel", body)
    wpStatus.Size                   = UDim2.new(0, 130, 0, 14)
    wpStatus.Position               = UDim2.new(1, -(PAD + 130), 0, 132)
    wpStatus.BackgroundTransparency = 1
    wpStatus.Text                   = "Sin ancla"
    wpStatus.TextColor3             = C.TEXT_LO
    wpStatus.Font                   = Enum.Font.GothamMedium
    wpStatus.TextSize               = 10
    wpStatus.TextXAlignment         = Enum.TextXAlignment.Right

    updateAnchorStatus = function()
        if anchored and home then
            wpStatus.Text       = string.format("[%d, %d, %d]",
                math.floor(home.X), math.floor(home.Y), math.floor(home.Z))
            wpStatus.TextColor3 = C.ON
        else
            wpStatus.Text       = "Sin ancla"
            wpStatus.TextColor3 = C.TEXT_LO
        end
    end

    local anchorRow   -- forward-declare (el closure debe verse a si mismo)
    anchorRow = makeSwitchRow(body, "Anclar aqui", "Fija tu posición actual", 152,
        function()
            if not anchored then
                local root = getRoot()
                if root then
                    home = root.Position; anchored = true
                else
                    anchorRow.setOn(false)   -- sin personaje: revertir visual
                    return
                end
            else
                anchored = false
            end
            anchorRow.setOn(anchored)
            updateAnchorStatus()
            updateGlobalDot()
        end)

    -- ── SLIDER de radio (arrastre continuo, valor en vivo · SOLO controla la distancia) ──
    local RMIN, RMAX = ANCHOR.RADIUS_MIN, ANCHOR.RADIUS_MAX

    local sliderRow = Instance.new("Frame", body)
    sliderRow.Size                   = UDim2.new(1, -2 * PAD, 0, 54)
    sliderRow.Position               = UDim2.new(0, PAD, 0, 198)
    sliderRow.BackgroundColor3       = C.ROW
    sliderRow.BackgroundTransparency = 0.25
    sliderRow.BorderSizePixel        = 0
    corner(sliderRow, 10)
    stroke(sliderRow, 0.88)

    local radLabel = Instance.new("TextLabel", sliderRow)
    radLabel.Size                   = UDim2.new(0, 120, 0, 16)
    radLabel.Position               = UDim2.new(0, 12, 0, 8)
    radLabel.BackgroundTransparency = 1
    radLabel.Text                   = "Radio"
    radLabel.TextColor3             = C.TEXT_HI
    radLabel.Font                   = Enum.Font.GothamMedium
    radLabel.TextSize               = 12
    radLabel.TextXAlignment         = Enum.TextXAlignment.Left

    -- valor en vivo (el slider SOLO controla la distancia; la visibilidad va en su propia fila)
    local radVal = Instance.new("TextLabel", sliderRow)
    radVal.Size                   = UDim2.new(0, 100, 0, 16)
    radVal.Position               = UDim2.new(1, -112, 0, 8)
    radVal.BackgroundTransparency = 1
    radVal.Text                   = ANCHOR.RADIUS .. " studs"
    radVal.TextColor3             = C.ACCENT
    radVal.Font                   = Enum.Font.GothamBold
    radVal.TextSize               = 13
    radVal.TextXAlignment         = Enum.TextXAlignment.Right

    -- carril + relleno + perilla
    local trackBar = Instance.new("Frame", sliderRow)
    trackBar.Size             = UDim2.new(1, -24, 0, 6)
    trackBar.Position         = UDim2.new(0, 12, 0, 38)
    trackBar.BackgroundColor3 = C.OFF
    trackBar.BorderSizePixel  = 0
    corner(trackBar, 3)

    local fill = Instance.new("Frame", trackBar)
    fill.BackgroundColor3 = C.ACCENT
    fill.BorderSizePixel  = 0
    fill.Size             = UDim2.new(0, 0, 1, 0)
    corner(fill, 3)

    local knob = Instance.new("Frame", trackBar)
    knob.Size             = UDim2.new(0, 16, 0, 16)
    knob.Position         = UDim2.new(0, -8, 0.5, -8)
    knob.BackgroundColor3 = C.WHITE
    knob.BorderSizePixel  = 0
    knob.ZIndex           = 3
    corner(knob, 8)
    stroke(knob, 0, 1.5, C.ACCENT)

    -- zona de agarre invisible (más alta que el carril => fácil de tomar, incluso touch)
    local grab = Instance.new("TextButton", sliderRow)
    grab.Size                   = UDim2.new(1, -24, 0, 26)
    grab.Position               = UDim2.new(0, 12, 0, 28)
    grab.BackgroundTransparency = 1
    grab.Text                   = ""
    grab.AutoButtonColor        = false
    grab.ZIndex                 = 4

    local function layoutSlider()
        local f = math.clamp((ANCHOR.RADIUS - RMIN) / (RMAX - RMIN), 0, 1)
        fill.Size     = UDim2.new(f, 0, 1, 0)
        knob.Position = UDim2.new(f, -8, 0.5, -8)
        radVal.Text   = ANCHOR.RADIUS .. " studs"
        moreRow.setSub("Alejarte (" .. ANCHOR.RADIUS .. " studs)")   -- More = el Radio, en vivo
    end
    layoutSlider()

    local function setFromX(px)
        local w   = math.max(trackBar.AbsoluteSize.X, 1)
        local rel = math.clamp((px - trackBar.AbsolutePosition.X) / w, 0, 1)
        local v   = math.floor(RMIN + rel * (RMAX - RMIN) + 0.5)   -- redondeo a 1 stud
        if v ~= ANCHOR.RADIUS then
            ANCHOR.RADIUS = v
            layoutSlider()
            _ringR = -1               -- fuerza re-tamaño del anillo (si está encendido) el próximo frame
        end
    end

    local sliding = false
    trackUI(grab.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            sliding = true
            _panelDrag = false   -- corta el drag del panel para que no se peleen
            tw(knob, { Size = UDim2.new(0, 20, 0, 20), Position = UDim2.new(knob.Position.X.Scale, -10, 0.5, -10) }, DUR_FAST, Enum.EasingStyle.Back)
            setFromX(i.Position.X)
        end
    end))
    trackUI(UserInputService.InputChanged:Connect(function(i)
        if not sliding then return end
        _panelDrag = false   -- seguro extra: mientras deslizas el slider, el panel NO se mueve
        if i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch then
            setFromX(i.Position.X)
        end
    end))
    trackUI(UserInputService.InputEnded:Connect(function(i)
        if sliding and (i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch) then
            sliding = false
            local f = math.clamp((ANCHOR.RADIUS - RMIN) / (RMAX - RMIN), 0, 1)
            tw(knob, { Size = UDim2.new(0, 16, 0, 16), Position = UDim2.new(f, -8, 0.5, -8) }, DUR_FAST, Enum.EasingStyle.Back)
        end
    end))

    -- ════════════ SHOW RADIUS: fila propia (responsabilidad separada del slider) ════════════
    -- El slider SOLO cambia la distancia. Este switch SOLO controla si se ve el círculo.
    local radiusRow
    radiusRow = makeSwitchRow(body, "Show Radius", "Círculo azul de alcance", 258,
        function(on)
            showRing = on
            radiusRow.setOn(on)
            toast(on and "Círculo de rango: ON" or "Círculo de rango: OFF", on)
        end)
    radiusRow.setOn(showRing, true)

    -- ── footer hint ──
    local hint = Instance.new("TextLabel", body)
    hint.Size                   = UDim2.new(1, -2 * PAD, 0, 14)
    hint.Position               = UDim2.new(0, PAD, 0, 308)
    hint.BackgroundTransparency = 1
    hint.Text                   = "Radio = alcance de More Distance · míralo con Show Radius"
    hint.TextColor3             = C.TEXT_LO
    hint.Font                   = Enum.Font.Gotham
    hint.TextSize               = 10
    hint.TextXAlignment         = Enum.TextXAlignment.Left

    -- ════════════ DOT DE ESTADO GLOBAL ════════════
    updateGlobalDot = function()
        local col, label
        if anchored then
            col, label = C.ON, "anclado"
        elseif activeMode then
            col, label = C.ACCENT, "activo"
        else
            col, label = C.TEXT_LO, "idle"
        end
        tw(dot, { BackgroundColor3 = col }, DUR_FAST)
        local active = anchored or (activeMode ~= nil)
        tw(dotGlow, { Color = col, Transparency = active and 0.55 or 1 }, DUR_MED)
    end

    -- ════════════ LOGO NX -> DISCORD (hover premium) ════════════
    trackUI(nxBadge.MouseEnter:Connect(function()
        nxHover = true
        tw(nxStroke, { Transparency = 0 }, DUR_FAST)
        tw(nxGlow,   { BackgroundTransparency = 0.48 }, DUR_FAST)
        tw(nxFill,   { BackgroundTransparency = 0 }, DUR_FAST)
        tw(nxScale,  { Scale = 1.14 }, DUR_MED, Enum.EasingStyle.Back)
    end))
    trackUI(nxBadge.MouseLeave:Connect(function()
        nxHover = false
        tw(nxStroke, { Transparency = 0.2 }, DUR_FAST)
        tw(nxGlow,   { BackgroundTransparency = 0.78 }, DUR_FAST)
        tw(nxFill,   { BackgroundTransparency = 0.04 }, DUR_FAST)
        tw(nxScale,  { Scale = 1 }, DUR_MED, Enum.EasingStyle.Back)
    end))
    -- feedback de press: hunde un pelín al tocar
    trackUI(nxBadge.MouseButton1Down:Connect(function() tw(nxScale, { Scale = 1.02 }, DUR_FAST) end))
    trackUI(nxBadge.MouseButton1Up:Connect(function() tw(nxScale, { Scale = nxHover and 1.14 or 1 }, DUR_FAST, Enum.EasingStyle.Back) end))
    safeClick(nxBadge, openDiscord)

    -- ════════════ MINIMIZAR ════════════
    local minimized = false
    trackUI(minBtn.MouseEnter:Connect(function() tw(minBtn, { BackgroundTransparency = 0.1 }, DUR_FAST) end))
    trackUI(minBtn.MouseLeave:Connect(function() tw(minBtn, { BackgroundTransparency = 0.35 }, DUR_FAST) end))
    safeClick(minBtn, function()
        minimized = not minimized
        if minimized then
            tw(panel, { Size = UDim2.new(0, W, 0, HEAD_H) }, DUR_MED)
            tw(body, { BackgroundTransparency = 1 }, DUR_FAST)
            body.Visible = false
            minBtn.Text = "+"
        else
            body.Visible = true
            tw(panel, { Size = UDim2.new(0, W, 0, FULL_H) }, DUR_MED)
            minBtn.Text = "—"
        end
    end)

    -- ════════════ EXPONER REFERENCIAS ESTABLES (para syncUI tras reconstruir) ════════════
    UI.setMode            = function(m) for _, e in ipairs(modeButtons) do e.setOn(m == e.modeKey) end end
    UI.setAnchor          = anchorRow.setOn
    UI.setRadius          = radiusRow.setOn
    UI.updateAnchorStatus = updateAnchorStatus
    UI.updateGlobalDot    = updateGlobalDot
    UI.refreshRadius      = layoutSlider
    UI.ready              = true

    -- ════════════ INIT estados (refleja el estado lógico actual) ════════════
    moreRow.setOn(activeMode == "More", true)
    lessRow.setOn(activeMode == "Less", true)
    anchorRow.setOn(anchored, true)
    updateAnchorStatus()
    updateGlobalDot()

    -- ════════════ ANIMACIÓN DE ENTRADA (solo en el primer build) ════════════
    if firstBuild then
        panel.BackgroundTransparency = 1
        local pScale = Instance.new("UIScale", panel); pScale.Scale = 0.94
        tw(panel, { BackgroundTransparency = 0.04 }, DUR_MED)
        tw(pScale, { Scale = 1 }, DUR_SLOW, Enum.EasingStyle.Back)

        -- stagger de las filas/secciones
        local stagger = { moreRow.row, lessRow.row, anchorRow.row, sliderRow, radiusRow.row }
        for i, el in ipairs(stagger) do
            local base = el.BackgroundTransparency
            el.BackgroundTransparency = 1
            local off  = el.Position
            el.Position = off + UDim2.fromOffset(0, 8)
            task.delay(0.04 * i, function()
                if _dead or _gui ~= gui then return end
                tw(el, { BackgroundTransparency = base }, DUR_MED)
                tw(el, { Position = off }, DUR_MED, Enum.EasingStyle.Quint)
            end)
        end
    end
end

-- reconstrucción con throttle (si te borran en bucle, no congela el FPS)
local _lastRebuild = 0
safeRebuild = function()
    if _dead or not sessionAlive() then return end
    local now = os.clock()
    if now - _lastRebuild < 0.15 then return end
    _lastRebuild = now
    pcall(function() buildUI(false) end)
    syncUI()
end

-- ════════════ MATAR INSTANCIA PREVIA (token + GUI directo + por nombre/huella) ════════════
do
    -- el bucle viejo ya se autodestruye al cambiar el token; aquí matamos su GUI directo
    if _G.__KEEP_DISTANCE_GUI  then pcall(function() _G.__KEEP_DISTANCE_GUI:Destroy() end) end
    if _G.__KEEP_DISTANCE_RING then pcall(function() _G.__KEEP_DISTANCE_RING:Destroy() end); _G.__KEEP_DISTANCE_RING = nil end
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then
        for _, g in ipairs(pg:GetChildren()) do
            if g:IsA("ScreenGui")
               and (g.Name == "KeepDistanceSmart" or g.Name == "KeepDistanceDual" or g:GetAttribute("KD")) then
                pcall(function() g:Destroy() end)
            end
        end
    end
end

-- ════════════ ARRANQUE ════════════
buildUI(true)
ensureLoops()

-- reset al respawnear (núcleo: resetea lógica y resincroniza la UI si existe)
track(LocalPlayer.CharacterAdded:Connect(function()
    anchored, home, lastPos, safeY, lastSafePos = false, nil, nil, nil, nil
    evading, lastEscapeDir, stuckFrames, lastFramePos = false, nil, 0, nil
    syncUI()
end))

-- ════════════ WATCHDOG (anti "no me lo desactiven" / "no se desactive solo") ════════════
task.spawn(function()
    while not _dead do
        task.wait(SHIELD.WATCH_HZ)
        if _dead then break end
        if not sessionAlive() then break end   -- re-exec legítimo tomó el control
        -- UI viva?
        local alive = _gui and _gui.Parent ~= nil
        if alive then
            -- re-asegurar propiedades por si te las cambiaron para "apagarlo"
            if not _gui.Enabled         then pcall(function() _gui.Enabled = true end) end
            if _gui.ResetOnSpawn        then pcall(function() _gui.ResetOnSpawn = false end) end
        elseif SHIELD.REBUILD then
            safeRebuild()
        end
        -- bucles vivos?
        ensureLoops()
    end
end)

print("KEEP DISTANCE v6.1 cargado · Radio unificado (More Distance detecta al valor del slider = círculo azul, tope 200) · UI PREMIUM · CEREBRO DE ESCAPE + SUPER DETECCIÓN + BLINDAJE · Air Walk safe.")
