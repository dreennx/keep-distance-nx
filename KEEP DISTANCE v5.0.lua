-- ═══════════════════════════════════════════════════════════
-- KEEP DISTANCE v7.0 · Detección blindada + Pre-detección + UI limpia
--
-- ★ NUEVO v7.0 — DETECCIÓN:
--   · HARD FLOOR (blindaje de contacto): nadie entra en CONTACT.HARD_R. Si alguien
--     lo cruza, el sistema calcula el paso EXACTO para salir (hasta 16 studs/frame)
--     y lo aplica aunque haya pared (noclip). Prioridad 0: por encima de todo.
--   · Predicción ADAPTATIVA: cuanto más rápido te cierra alguien, más lejos mira.
--   · Velocidad ESTIMADA por diferencia de posición (los replicados que llegan con
--     AssemblyLinearVelocity = 0 ya no se cuelan).
--   · Scoring con FUTURO: las rutas se puntúan contra dónde VAN a estar los otros,
--     no dónde estaban. Ya no te metes por delante del que viene.
--   · Filtro VERTICAL (anti falso positivo · Air Walk): la gente 28+ studs debajo
--     de ti ya no cuenta como amenaza. Se desvanece suave, no de golpe.
--   · Fantasmas: a los invisibles se les extrapola su última velocidad conocida.
--   · Muertos ignorados (Humanoid.Health <= 0).
--
-- ★ NUEVO v7.0 — SUAVIDAD (sin movimientos bruscos):
--   · Límite de giro por frame + rampa del paso. En emergencia el límite se relaja
--     de forma proporcional (no tocar > verse suave).
--
-- ★ NUEVO v7.0 — RADIO DE PRE-DETECCIÓN (segundo radio, independiente):
--   · SOLO informa y prepara. No mueve, no evita, no toca el movimiento.
--   · Precalcula la ruta mientras el jugador se acerca => al entrar al radio
--     principal la reacción es de 0 frames de latencia.
--
-- ★ NUEVO v7.0 — UI: fuera las sombras/halos de detrás del panel. Radios, bordes
--   y espaciado unificados por sistema (R.*, PAD/GAP/SEC).
--
-- Base heredada: FIX ZIndexBehavior=Sibling (v6.5) · colores sólidos (v6.3) ·
-- CEREBRO DE ESCAPE · SIN SALTO (Air Walk safe) · BLINDAJE anti-ataques.
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
local stepSmooth    = 0       -- longitud de paso suavizada (rampa · anti-brusquedad)

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
    RADIUS_MAX  = 200,   -- tope del slider
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

-- ════════════ SUPER DETECCIÓN (alta velocidad + invisibles + anti falso positivo) ════════════
local DETECT = {
    PREDICT_TIME  = 0.10,   -- s base de anticipación por velocidad
    PREDICT_ADAPT = 0.22,   -- s EXTRA cuando alguien te cierra rápido (predicción adaptativa)
    PREDICT_CLOSE = 120,    -- studs/s de cierre = anticipación máxima
    PREDICT_MAX   = 60,     -- studs máx de extrapolación (anti-fling: no perseguir fantasmas)
    HOLD_TIME     = 1.5,    -- s que recordamos su última posición (invisibles que parpadean)
    GHOST_MAX     = 0.35,   -- s máx que extrapolamos a un fantasma con su última velocidad
    USE_PIVOT     = true,   -- fallback GetPivot() si no hay ninguna parte localizable
    DEEP_SCAN     = true,   -- buscar CUALQUIER BasePart si no hay HRP/Head (cazar partes ocultas)
    SKIP_DEAD     = true,   -- ignorar personajes muertos (falso positivo puro)
    VEL_EST_MAX   = 400,    -- tope de la velocidad estimada por diferencia (anti-teleport)
    VERT_LIMIT    = 28,     -- ★ |ΔY| a partir del cual alguien deja de ser amenaza (Air Walk)
    VERT_FADE     = 10,     -- studs de desvanecido suave del filtro vertical (sin parpadeo)
}

-- ════════════ BLINDAJE DE CONTACTO (nunca tocar a nadie) ════════════
local CONTACT = {
    HARD_R   = 6,     -- ★ SUELO DURO: nadie puede estar más cerca. Se hace cumplir SIEMPRE.
    BUFFER   = 1.5,   -- margen extra al salir (evita rebotar en el borde exacto)
    MAX_STEP = 16,    -- studs/frame máx del blindaje (supera a cualquier corredor)
    PANIC_R  = 10,    -- desde aquí la reacción del cerebro se acelera (no mueve por sí solo)
    PROBES   = 8,     -- resolución de la búsqueda del paso mínimo para salir
}

-- ════════════ CEREBRO DE ESCAPE (elige ruta, no solo empuja) ════════════
local SMART = {
    DIRS         = 16,    -- direcciones candidatas alrededor tuyo
    LOOK_MULT    = 4,     -- cuántos pasos "mira hacia adelante" al puntuar cada ruta
    HORIZON      = 0.35,  -- ★ s de futuro con los que se puntúa cada ruta (ellos también se mueven)
    SEED_W       = 3,     -- bonus a la dirección natural de repulsión
    SMOOTH_W     = 2.5,   -- bonus a mantener el rumbo anterior (anti-zigzag)
    WALL_TRIES   = 4,     -- máx raycasts/frame buscando ruta sin pared (perf)
    EXIT_FACTOR  = 1.15,  -- histéresis: sigue evadiendo hasta safe*este margen
    STUCK_FRAMES = 6,     -- frames sin avanzar -> noclip + re-decidir ruta
}

-- ════════════ SUAVIDAD (anti movimientos bruscos) ════════════
-- El límite de giro se RELAJA con la urgencia: lejos = curva natural, encima = giro libre.
local SMOOTH = {
    TURN_MAX   = 55,    -- grados/frame de giro máx en calma
    TURN_PANIC = 180,   -- grados/frame con urgencia máxima (sin límite práctico)
    STEP_RISE  = 0.35,  -- rampa de aceleración del paso
    STEP_FALL  = 0.18,  -- rampa de frenado (suelta suave, no corta de golpe)
}

-- ════════════ RADIO DE PRE-DETECCIÓN (2º radio · SOLO informa) ════════════
-- Independiente del radio principal: NO ejecuta acciones, NO modifica el movimiento,
-- NO evita a nadie. Su único trabajo es avisar que alguien se aproxima y dejar la
-- decisión ya calculada para que la reacción del radio principal sea instantánea.
local PRE = {
    ENABLED  = true,
    EXTRA    = 45,    -- studs MÁS ALLÁ del radio principal donde empieza a mirar
    MIN      = 25,    -- radio mínimo de pre-detección
    HOLD     = 0.4,   -- s que mantiene el aviso tras salir (anti-parpadeo)
    ARM_HZ   = 0.12,  -- cada cuánto precalcula la ruta (perf: no cada frame)
    UI_HZ    = 0.2,   -- cada cuánto puede refrescar el texto (y solo si cambió)
}
local preOn      = true          -- switch de la UI
local preAlert   = false         -- ¿hay alguien en el radio de pre-detección?
local preCount   = 0
local preNearest = math.huge
local preClosing = 0             -- studs/s a los que te cierra el más cercano
local preUntil   = 0
local preparedDir = nil          -- ruta precalculada (semilla, no movimiento)
local _lastArm    = 0

-- ════════════ DISCORD (logo NX) ════════════
local DISCORD_INVITE = "https://discord.gg/JgsW2M6322"   -- tu invite (se copia + abre en la app)

-- ════════════ PALETA (glass premium · vidrio translúcido) ════════════
local C = {
    BG       = Color3.fromRGB(18, 21, 31),
    SURFACE  = Color3.fromRGB(26, 29, 40),
    ROW      = Color3.fromRGB(48, 54, 76),      -- tarjeta CLARA: resalta sobre el panel y el texto blanco pega
    ROW_HOV  = Color3.fromRGB(64, 72, 98),
    ACCENT   = Color3.fromRGB(56, 158, 255),   -- azul cristal premium
    ACCENT_2 = Color3.fromRGB(126, 208, 255),  -- highlight claro del acento
    TEXT_HI  = Color3.fromRGB(238, 242, 255),
    TEXT_MID = Color3.fromRGB(168, 178, 208),
    TEXT_LO  = Color3.fromRGB(118, 128, 158),
    WHITE    = Color3.fromRGB(255, 255, 255),
    ON       = Color3.fromRGB(48, 214, 132),   -- verde menta premium
    ON_GLOW  = Color3.fromRGB(120, 240, 178),
    WARN     = Color3.fromRGB(255, 176, 64),   -- ámbar: pre-detección avisando
    OFF      = Color3.fromRGB(78, 84, 106),   -- track apagado VISIBLE sobre la tarjeta
    DISABLED = Color3.fromRGB(70, 74, 90),      -- estado deshabilitado (texto/track apagado)
}

-- ── SISTEMA DE RADIOS (consistencia visual: 4 valores, nada suelto) ──
local R = {
    PANEL = 16,   -- ventana
    CARD  = 12,   -- tarjetas / filas
    CTRL  = 10,   -- controles (botón minimizar, badge NX)
    PILL  = 8,    -- píldoras / toast interno
}

local DUR_FAST = 0.12
local DUR_MED  = 0.20
local DUR_SLOW = 0.34

local EASE_GLASS = Enum.EasingStyle.Quint   -- fluido, sin rebote (movimiento de ventana)
local EASE_POP   = Enum.EasingStyle.Back    -- micro-rebote (feedback de estado)
local EASE_SOFT  = Enum.EasingStyle.Sine    -- respiración / glow

local function tw(o, props, dur, style, dir)
    local t = TweenService:Create(o,
        TweenInfo.new(dur or DUR_MED, style or EASE_GLASS, dir or Enum.EasingDirection.Out), props)
    t:Play(); return t
end
local function corner(p, r)
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r or R.CARD); c.Parent = p; return c
end
local function stroke(p, transp, thick, col)
    local s = Instance.new("UIStroke")
    s.Color = col or C.WHITE; s.Transparency = transp or 0.85; s.Thickness = thick or 1
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    s.Parent = p
    return s
end
-- Borde con degradado tipo cristal (claro arriba -> oscuro abajo). Simula el reflejo del vidrio.
-- La base del stroke SIEMPRE en blanco — el UIGradient multiplica su color por el color
-- base, así el degradado pinta sus colores reales (si no, se doble-oscurece).
local function glassStroke(p, transp, thick, top, bottom)
    local s = stroke(p, transp, thick, C.WHITE)
    local g = Instance.new("UIGradient", s)
    g.Rotation = 90   -- vertical: canto de luz arriba, sombra abajo
    g.Color = ColorSequence.new(top or Color3.fromRGB(190, 205, 235), bottom or Color3.fromRGB(40, 46, 66))
    return s, g
end
-- Reflejo especular: línea/banda blanca translúcida (el "brillo" del cristal).
local function addSpecular(parent, y, h, transp)
    local s = Instance.new("Frame")
    s.Size                   = UDim2.new(1, -16, 0, h or 1)
    s.Position               = UDim2.new(0, 8, 0, y or 1)
    s.BackgroundColor3       = C.WHITE
    s.BackgroundTransparency = transp or 0.55
    s.BorderSizePixel        = 0
    s.Active                 = false
    s.Parent                 = parent
    corner(s, math.floor((h or 1) / 2))
    local g = Instance.new("UIGradient", s)   -- se desvanece en los bordes (no una línea dura)
    g.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0,    1.0),
        NumberSequenceKeypoint.new(0.5,  0.0),
        NumberSequenceKeypoint.new(1,    1.0),
    })
    return s
end
-- Fondo del panel: navy SÓLIDO (sin gradiente de color) para máxima legibilidad.
local function glassGrad(p)
    p.BackgroundColor3 = C.BG
    return nil
end

local function getRoot()
    local char = LocalPlayer.Character
    if not char then return nil end
    return char:FindFirstChild("HumanoidRootPart")
end

-- ════════════ ANILLO DE RANGO (indicador visual del radio, perf-safe) ════════════
local RANGE_RING = {
    COLOR       = Color3.fromRGB(45, 160, 255),   -- núcleo azul premium
    GLOW_COLOR  = Color3.fromRGB(130, 205, 255),  -- halo más claro
    CORE_TRANSP = 0.58,
    GLOW_TRANSP = 0.88,
    GLOW_PAD    = 3.5,
    THICK       = 0.2,
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
-- _others[i] = { p = Vector3 predicha, v = Vector3 horizontal, bias = número }
--   bias = penalización de distancia por altura (filtro vertical suave). Se SUMA a la
--   distancia medida: un jugador muy por debajo "cuenta" como si estuviera lejísimos.
local _excludeList = {}
local _others      = {}
local _lastSeen    = {}   -- [player] = { raw = Vector3, v = Vector3, t = os.clock() }
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

-- Lectura cruda: posición real + velocidad real (sin predicción todavía).
local function readChar(char)
    local part = getCharPart(char)
    if part then return part.Position, part.AssemblyLinearVelocity or Vector3.zero end
    if DETECT.USE_PIVOT then
        local ok, piv = pcall(function() return char:GetPivot().Position end)
        if ok and piv then return piv, nil end
    end
    return nil, nil
end

-- ★ La velocidad replicada llega en 0 en muchos casos (justo con los que van rápido).
-- Fallback: la derivamos de cuánto se movió desde el frame anterior.
local function estimateVel(plr, raw, vel, now)
    if vel and vel.Magnitude >= 0.5 then return vel end
    local ls = _lastSeen[plr]
    if ls and ls.raw then
        local dt = now - ls.t
        if dt >= (1 / 120) and dt <= 0.5 then
            local est = (raw - ls.raw) / dt
            local m   = est.Magnitude
            if m > 0.5 and m < DETECT.VEL_EST_MAX then return est end
        end
    end
    return vel or Vector3.zero
end

-- ★ Predicción ADAPTATIVA: la anticipación crece con la velocidad a la que te cierra.
-- Alguien parado se lee donde está; alguien que te embiste se lee donde VA a estar.
--
-- ★★ CLAVE (v7.0) · TOPE EN EL PUNTO DE MÁXIMA APROXIMACIÓN (TCPA):
-- extrapolar más allá del cruce es lo que te hacía TOCAR a la gente rápida: el
-- atacante se "leía" ya pasado de largo, o sea al OTRO lado tuyo, y entonces la
-- huida apuntaba HACIA él. Cuanto más rápido iba, peor. Nunca se predice más allá
-- del instante en que te alcanza; y a quien se aleja no se le predice nada.
local function predictPos(raw, vel, myPos)
    if not vel or vel.Magnitude <= 0.1 then return raw end
    local t = DETECT.PREDICT_TIME
    if myPos then
        local toMe = myPos - raw
        if toMe.Magnitude > 0.1 then
            local closing = vel:Dot(toMe.Unit)   -- >0 = viene hacia ti
            if closing <= 0 then return raw end  -- se aleja: no hay nada que anticipar
            t = t + math.clamp(closing / DETECT.PREDICT_CLOSE, 0, 1) * DETECT.PREDICT_ADAPT
            local tcpa = toMe:Dot(vel) / vel:Dot(vel)   -- s hasta su máxima aproximación
            if tcpa > 0 then t = math.min(t, tcpa) end  -- ← el tope que evita el contacto
        end
    end
    local pred = vel * t
    if pred.Magnitude > DETECT.PREDICT_MAX then pred = pred.Unit * DETECT.PREDICT_MAX end
    return raw + pred
end

-- ★ Filtro vertical (anti falso positivo con Air Walk): devuelve el bias de distancia.
-- Dentro de LIMIT-FADE: amenaza real (bias 0). Más allá de LIMIT: no es amenaza (nil).
-- En medio: se desvanece progresivo => nada de parpadeos al subir/bajar.
local function verticalBias(dy)
    local ady  = math.abs(dy)
    local soft = DETECT.VERT_LIMIT - DETECT.VERT_FADE
    if ady <= soft then return 0 end
    if ady >= DETECT.VERT_LIMIT then return nil end
    return ((ady - soft) / DETECT.VERT_FADE) * 400
end

-- p = posición ANTICIPADA (para medir amenaza ahora mismo)
-- r = posición REAL    (para proyectar rutas a futuro: si no, se predice dos veces
--                       y el scoring cree que el atacante ya pasó de largo)
local function pushOther(list, pos, raw, vel, myPos)
    local bias = verticalBias(pos.Y - myPos.Y)
    if not bias then return end   -- demasiada altura de diferencia: ni es amenaza ni la buscamos
    list[#list + 1] = {
        p    = pos,
        r    = raw or pos,
        v    = vel and Vector3.new(vel.X, 0, vel.Z) or Vector3.zero,
        bias = bias,
    }
end

local function refreshFrameCache(myPos)
    table.clear(_excludeList)
    table.clear(_others)
    local now = os.clock()

    for _, plr in ipairs(Players:GetPlayers()) do
        local ch = plr.Character
        if ch then _excludeList[#_excludeList + 1] = ch end

        if plr ~= LocalPlayer then
            local dead = false
            if DETECT.SKIP_DEAD and ch then
                local hum = ch:FindFirstChildOfClass("Humanoid")
                dead = (hum ~= nil and hum.Health <= 0)
            end

            if not dead then
                -- ch == nil (te esconden el Character entero) cae al rastro de abajo
                local raw, vel
                if ch then raw, vel = readChar(ch) end
                if raw then
                    vel = estimateVel(plr, raw, vel, now)
                    pushOther(_others, predictPos(raw, vel, myPos), raw, vel, myPos)
                    _lastSeen[plr] = { raw = raw, v = vel, t = now }
                else
                    -- invisible/oculto este frame: seguimos su rastro con la última velocidad
                    -- conocida (un invisible que corre no se congela en su última posición).
                    local ls = _lastSeen[plr]
                    if ls and (now - ls.t) <= DETECT.HOLD_TIME then
                        local age   = now - ls.t
                        local decay = 1 - (age / DETECT.HOLD_TIME)   -- la confianza cae con el tiempo
                        local ghost = ls.raw + (ls.v or Vector3.zero) * math.min(age, DETECT.GHOST_MAX) * decay
                        pushOther(_others, ghost, ghost, ls.v, myPos)
                    end
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

-- ════════════ MEDIDAS DE AMENAZA ════════════
-- Distancia efectiva al más cercano en un punto, mirando `t` segundos al futuro.
--   t = 0 -> amenaza AHORA: se mide contra la posición anticipada (o.p).
--   t > 0 -> encuentro FUTURO: se proyecta desde la posición REAL (o.r), nunca desde
--            la anticipada. Si no, la predicción se aplicaría dos veces y una ruta
--            que te lleva contra el atacante puntuaría bien ("ya habrá pasado").
local function nearestDistAt(pos, t)
    local best = math.huge
    for _, o in ipairs(_others) do
        local ox, oz
        if t and t > 0 then
            ox = o.r.X + o.v.X * t
            oz = o.r.Z + o.v.Z * t
        else
            ox, oz = o.p.X, o.p.Z
        end
        local m = Vector3.new(pos.X - ox, 0, pos.Z - oz).Magnitude + o.bias
        if m < best then best = m end
    end
    return best
end

local function nearestPlayerDist(pos)
    return nearestDistAt(pos, 0)
end

-- Igual que nearestPlayerDist pero devuelve TAMBIÉN el rumbo de huida natural.
local function nearestInfo(pos)
    local best, bestDir = math.huge, nil
    for _, o in ipairs(_others) do
        local off = Vector3.new(pos.X - o.p.X, 0, pos.Z - o.p.Z)
        local m   = off.Magnitude
        local eff = m + o.bias
        if eff < best then
            best    = eff
            bestDir = (m > 0.05) and off.Unit or nil
        end
    end
    return best, bestDir
end

-- ★ Suavizado de rumbo: limita cuántos grados puedes girar en un frame.
-- maxDeg alto (urgencia) = giro libre; bajo (calma) = curva natural, nada de latigazos.
local function limitTurn(prev, want, maxDeg)
    if not prev or not want then return want end
    if maxDeg >= 179 then return want end
    local dot = math.clamp(prev:Dot(want), -1, 1)
    if math.deg(math.acos(dot)) <= maxDeg then return want end
    local crossY = prev.Z * want.X - prev.X * want.Z
    local a      = math.rad(maxDeg) * ((crossY < 0) and 1 or -1)
    local cs, sn = math.cos(a), math.sin(a)
    local r      = Vector3.new(prev.X * cs - prev.Z * sn, 0, prev.X * sn + prev.Z * cs)
    return (r.Magnitude > 0.001) and r.Unit or want
end

-- Muestrea SMART.DIRS direcciones y elige la mejor ruta de escape:
--   · puntúa qué tan lejos te deja de TODOS (no solo del más cercano)
--   · ★ v7.0: puntúa a MEDIO y FINAL de la ruta, con los otros ya movidos (predicción):
--     una ruta que hoy parece libre pero te cruza con el que viene, ahora puntúa mal
--   · bonus a la repulsión natural (seed) y al rumbo anterior (anti-zigzag)
--   · de mejor a peor, la primera sin pared gana (máx WALL_TRIES raycasts)
-- Devuelve dir, clear. clear=false => todo bloqueado, el caller activa noclip.
local function bestEscapeDir(myPos, seed, stepLen)
    local look   = math.max(stepLen * SMART.LOOK_MULT, 6)
    local hz     = SMART.HORIZON
    local seedU  = (seed and seed.Magnitude > 0.05) and seed.Unit or nil
    local scored = {}
    for i = 0, SMART.DIRS - 1 do
        local a   = (i / SMART.DIRS) * math.pi * 2
        local dir = Vector3.new(math.cos(a), 0, math.sin(a))
        -- el peor momento de la ruta manda: así se descartan las que te cruzan por delante
        local sMid = nearestDistAt(myPos + dir * (look * 0.5), hz * 0.5)
        local sEnd = nearestDistAt(myPos + dir * look,          hz)
        local s    = math.min(sMid, sEnd)
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

-- ★ Paso mínimo a lo largo de `dir` que te deja a `need` studs de todos.
-- Es el corazón del suelo duro: no "empuja y reza", calcula lo que hace falta.
local function pushOutStep(myPos, dir, need)
    for k = 1, CONTACT.PROBES do
        local t = (k / CONTACT.PROBES) * CONTACT.MAX_STEP
        if nearestDistAt(myPos + dir * t, 0) >= need then return t end
    end
    return CONTACT.MAX_STEP
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
    for _, o in ipairs(_others) do
        local off = Vector3.new(home.X - o.p.X, 0, home.Z - o.p.Z)
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

-- ════════════ PRIORIDAD 0 · SUELO DURO (nunca tocar a nadie) ════════════
-- Se hace cumplir SIEMPRE que el sistema esté al mando (modo activo o ancla).
-- No negocia, no suaviza: si alguien entra en HARD_R, sales. Devuelve true si actuó.
local function hardFloorStep(root, myPos)
    if not (activeMode or anchored) then return false end
    local d, away = nearestInfo(myPos)
    if d >= CONTACT.HARD_R then return false end

    local need = CONTACT.HARD_R + CONTACT.BUFFER
    -- ruta inteligente incluso en emergencia (si hay pared, la atravesamos)
    local dir, clear = bestEscapeDir(myPos, away, need)
    dir = dir or away
    if not dir then return false end
    if not clear then noclipUntil = os.clock() + 0.3 end

    local step = pushOutStep(myPos, dir, need)
    local destPos, finalY = resolveMove(myPos, dir * step)
    root.CFrame = CFrame.new(destPos.X, finalY, destPos.Z)
                * CFrame.Angles(0, math.rad(root.Orientation.Y), 0)

    -- deja el cerebro alineado con lo que acaba de pasar (sin latigazo al frame siguiente)
    evading      = true
    lastEscapeDir = dir
    stepSmooth   = math.min(step, CONTACT.MAX_STEP)
    return true
end

-- ════════════ RADIO DE PRE-DETECCIÓN (solo lectura + preparación) ════════════
-- ⚠ Este bloque NO mueve al personaje. Nunca. Solo observa y deja la ruta lista.
local function preRadius()
    local base = activeMode and modeSafeDistance(activeMode) or ANCHOR.CLEAR_DIST
    return math.max(PRE.MIN, base + PRE.EXTRA)
end

local function updatePreDetect(myPos)
    if not preOn then
        preAlert, preCount, preNearest, preClosing, preparedDir = false, 0, math.huge, 0, nil
        return
    end

    local radius  = preRadius()
    local count   = 0
    local nearest = math.huge
    local closing = 0
    local seed    = Vector3.zero

    for _, o in ipairs(_others) do
        local off = Vector3.new(myPos.X - o.p.X, 0, myPos.Z - o.p.Z)
        local eff = off.Magnitude + o.bias
        if eff < radius then
            count = count + 1
            -- ojo: `*` liga más fuerte que `and/or` → el unitario va a su propia variable
            local u = (off.Magnitude > 0.05) and off.Unit or Vector3.zero
            seed = seed + u * (1 - eff / radius)
            if eff < nearest then
                nearest = eff
                -- velocidad a la que te cierra (proyección de su velocidad sobre la línea hacia ti)
                closing = (off.Magnitude > 0.05) and o.v:Dot(off.Unit) or 0
            end
        end
    end

    local now = os.clock()
    if count > 0 then
        preUntil = now + PRE.HOLD          -- anti-parpadeo al rozar el borde del radio
        preAlert = true
    elseif now >= preUntil then
        preAlert = false
        preparedDir = nil
    end

    preCount   = count
    preNearest = nearest
    preClosing = closing

    -- ★ Preparación (no acción): deja la ruta ya resuelta para que el radio principal
    -- reaccione en el frame 0 en vez de gastar el primer frame decidiendo.
    -- Solo si el sistema está al mando: en idle no gastamos ni un raycast.
    if (activeMode or anchored) and preAlert and count > 0 and not evading
       and (now - _lastArm) >= PRE.ARM_HZ then
        _lastArm = now
        local step = activeMode and MODES[activeMode].MAX_STEP or ANCHOR.MAX_STEP
        local dir  = bestEscapeDir(myPos, seed, step)
        preparedDir = dir
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

        refreshFrameCache(myPos)
        updateRing(root)        -- anillo de rango: sigue al personaje (barato: 1 CFrame/frame)
        updatePreDetect(myPos)  -- 2º radio: informa y prepara, NO mueve

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

        -- ── PRIORIDAD 0: SUELO DURO (nadie te toca, pase lo que pase) ──
        if hardFloorStep(root, myPos) then return end

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

        -- ── PRIORIDAD 2: KEEP DISTANCE (cerebro de escape) ──
        if not activeMode then return end
        local config  = MODES[activeMode]
        local safeD   = modeSafeDistance(activeMode)   -- More sigue el slider del Radio
        local nearest = nearestPlayerDist(myPos)

        -- histéresis: al evadir seguimos hasta safe*EXIT_FACTOR (no titubea en el borde)
        local trigger = evading and (safeD * SMART.EXIT_FACTOR) or safeD
        if nearest >= trigger then
            evading, lastEscapeDir, stuckFrames, lastFramePos = false, nil, 0, nil
            stepSmooth = 0
            return
        end

        -- ★ arranque instantáneo: si la pre-detección ya dejó una ruta lista, la usamos
        -- como rumbo previo => el primer frame de evasión ya sale derecho (0 latencia).
        if not evading and preparedDir then lastEscapeDir = preparedDir end
        evading = true

        -- ★ urgencia 0..1: 0 = te vigilo tranquilo, 1 = te tengo encima.
        -- Escala reacción, paso y libertad de giro. Aquí muere el "movimiento brusco":
        -- solo es brusco cuando la alternativa es que te toquen.
        -- El umbral es RELATIVO al modo: en "Less" (safe 8) estar a 7 studs es lo que
        -- pediste, no una emergencia — si el pánico fuera fijo en 10, Less daría saltos.
        local panicAt = math.max(CONTACT.HARD_R + 1, math.min(CONTACT.PANIC_R, safeD * 0.6))
        local urgency = math.clamp(
            (panicAt - nearest) / math.max(panicAt - CONTACT.HARD_R, 0.1), 0, 1)

        -- repulsión clásica: semilla de dirección + medida de fuerza
        local totalPush = Vector3.zero
        for _, o in ipairs(_others) do
            local flat = Vector3.new(myPos.X - o.p.X, 0, myPos.Z - o.p.Z)
            local dist = flat.Magnitude + o.bias
            if dist < trigger and flat.Magnitude > 0.1 then
                totalPush = totalPush + flat.Unit * ((1 - dist / trigger) * config.MAX_STEP)
            end
        end

        -- fuerza del paso: aunque la repulsión se cancele (flanqueado) hay que moverse
        local wantStep = math.min(totalPush.Magnitude, config.MAX_STEP)
        if wantStep < 0.35 then
            wantStep = math.max(0.35, (1 - nearest / trigger) * config.MAX_STEP)
        end
        -- con urgencia alta el paso puede pasarse del MAX_STEP del modo: es lo que evita
        -- que un corredor más rápido que tú te alcance.
        if urgency > 0 then
            wantStep = wantStep + (CONTACT.MAX_STEP - wantStep) * (urgency * urgency)
        end

        -- ★ rampa: acelera y frena progresivo (nada de saltos de 0 a full en 1 frame).
        -- En urgencia la rampa se salta: la seguridad manda sobre la estética.
        local rate = (wantStep > stepSmooth) and SMOOTH.STEP_RISE or SMOOTH.STEP_FALL
        rate = rate + (1 - rate) * urgency
        stepSmooth = stepSmooth + (wantStep - stepSmooth) * rate
        local stepLen = math.max(stepSmooth, 0.35)

        -- elegir la MEJOR ruta (no la más obvia): escapa de flanqueos, esquiva paredes
        local dir, clear = bestEscapeDir(myPos, totalPush, stepLen)
        if not dir then return end
        if not clear then
            noclipUntil = os.clock() + 0.25
        end

        -- ★ giro limitado (anti-latigazo). El límite se abre con la urgencia.
        local maxTurn = SMOOTH.TURN_MAX + (SMOOTH.TURN_PANIC - SMOOTH.TURN_MAX) * urgency
        dir = limitTurn(lastEscapeDir, dir, maxTurn)

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

        -- ★ RED FINAL: si el destino calculado aún deja a alguien dentro del suelo duro,
        -- se alarga el paso lo justo para salir. El movimiento nunca termina en contacto.
        local need = CONTACT.HARD_R + CONTACT.BUFFER
        if nearestDistAt(destPos, 0) < CONTACT.HARD_R then
            local ext = pushOutStep(myPos, dir, need)
            destPos, finalY = resolveMove(myPos, dir * math.max(ext, stepLen))
            noclipUntil = os.clock() + 0.25
        end

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
-- UI v7.0 · sistema de componentes (encapsulado en buildUI para reconstruir)
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
        UI.setPre(preOn)
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
    -- ★ FIX RAÍZ (v6.5): sin esto el executor deja el GUI en ZIndexBehavior=Global,
    -- donde el panel TAPA todo el contenido. Con Sibling los hijos SIEMPRE van
    -- delante de su padre → todo se ve.
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
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

    -- ── MEDIDAS DEL LAYOUT (todo el espaciado sale de aquí: nada de números sueltos) ──
    local PAD    = 14    -- margen lateral
    local GAP    = 8     -- separación entre tarjetas hermanas
    local SEC    = 16    -- aire antes de una etiqueta de sección
    local ROW_H  = 46    -- alto de fila con switch
    local SLD_H  = 54    -- alto de la tarjeta del slider
    local LBL_H  = 14    -- alto de etiqueta de sección
    local W      = 272
    local HEAD_H = 46

    -- cursor de layout: cada bloque avanza => el espaciado es consistente por construcción
    local y = 6
    local Y = {}
    Y.secMove   = y;                    y = y + LBL_H + 6
    Y.more      = y;                    y = y + ROW_H + GAP
    Y.less      = y;                    y = y + ROW_H + SEC
    Y.secAnchor = y;                    y = y + LBL_H + 6
    Y.anchor    = y;                    y = y + ROW_H + GAP
    Y.slider    = y;                    y = y + SLD_H + SEC
    Y.secDetect = y;                    y = y + LBL_H + 6
    Y.pre       = y;                    y = y + ROW_H + GAP
    Y.radius    = y;                    y = y + ROW_H + 10
    Y.hint      = y;                    y = y + LBL_H + 12
    local BODY_H = y
    local FULL_H = HEAD_H + BODY_H

    -- ── PANEL (v7.0: sin sombra ni halo detrás · la profundidad la da el propio vidrio) ──
    local panel = Instance.new("Frame")
    panel.Size                   = UDim2.new(0, W, 0, FULL_H)
    panel.Position               = UDim2.new(0, 60, 0, 120)
    panel.BackgroundColor3       = C.BG
    panel.BackgroundTransparency = 0.05   -- vidrio sutil (el contenido va DELANTE, no se lava)
    panel.BorderSizePixel        = 0
    panel.ClipsDescendants       = true
    panel.ZIndex                 = 2
    panel.Parent                 = gui
    corner(panel, R.PANEL)
    local panelStroke = glassStroke(panel, 0.12, 1.4,   -- borde cristal: canto de luz arriba
        Color3.fromRGB(150, 200, 255), Color3.fromRGB(30, 40, 62))
    glassGrad(panel)

    -- glow de acento superior (baña el header en luz azul · DENTRO del panel, no detrás)
    local topGlow = Instance.new("Frame", panel)
    topGlow.Size                   = UDim2.new(1, 0, 0, 78)
    topGlow.Position               = UDim2.new(0, 0, 0, 0)
    topGlow.BackgroundColor3       = C.ACCENT
    topGlow.BorderSizePixel        = 0
    topGlow.ZIndex                 = 0
    topGlow.Active                 = false
    do
        local gg = Instance.new("UIGradient", topGlow)
        gg.Rotation = 90
        gg.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.72),
            NumberSequenceKeypoint.new(1, 1.00),
        })
    end

    -- brillo especular superior (el filo de luz del cristal)
    addSpecular(panel, 1, 1, 0.35)

    -- ════════════ HEADER ════════════
    local header = Instance.new("Frame", panel)
    header.Size                   = UDim2.new(1, 0, 0, HEAD_H)
    header.BackgroundTransparency = 1
    header.Active                 = true

    -- dot de estado (idle/pre-alerta/keep/anchor)
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

    -- ════════════ LOGO NX (clickeable -> Discord) ════════════
    local nxWrap = Instance.new("Frame", header)
    nxWrap.Size                   = UDim2.new(0, 46, 0, 28)
    nxWrap.Position               = UDim2.new(1, -88, 0.5, -14)
    nxWrap.BackgroundTransparency = 1
    local nxScale = Instance.new("UIScale", nxWrap); nxScale.Scale = 1

    -- glow azul detrás del badge (respira con un loop suave)
    local nxGlow = Instance.new("Frame", nxWrap)
    nxGlow.Size                   = UDim2.new(1, 14, 1, 14)
    nxGlow.Position               = UDim2.new(0, -7, 0, -7)
    nxGlow.BackgroundColor3       = C.ACCENT
    nxGlow.BackgroundTransparency = 0.78
    nxGlow.BorderSizePixel        = 0
    nxGlow.ZIndex                 = 1
    corner(nxGlow, R.CTRL + 3)
    do
        local gg = Instance.new("UIGradient", nxGlow)
        gg.Rotation = 90
        gg.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.25),
            NumberSequenceKeypoint.new(1, 0.85),
        })
    end

    -- fondo glass con gradiente moderno (base BLANCA → el gradiente navy se ve real)
    local nxFill = Instance.new("Frame", nxWrap)
    nxFill.Size                   = UDim2.new(1, 0, 1, 0)
    nxFill.BackgroundColor3       = C.WHITE
    nxFill.BackgroundTransparency = 0.04
    nxFill.BorderSizePixel        = 0
    nxFill.ZIndex                 = 2
    nxFill.ClipsDescendants       = true
    corner(nxFill, R.CTRL)
    do
        local bg = Instance.new("UIGradient", nxFill)
        bg.Rotation = 120
        bg.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(30, 42, 66)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(13, 18, 30)),
        })
    end

    local nxStroke = stroke(nxFill, 0.2, 1.4, C.WHITE)
    do
        local sg = Instance.new("UIGradient", nxStroke)
        sg.Rotation = 90
        sg.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(120, 200, 255)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 110, 220)),
        })
    end

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

    local nxBadge = Instance.new("TextButton", nxWrap)
    nxBadge.Size                   = UDim2.new(1, 0, 1, 0)
    nxBadge.BackgroundTransparency = 1
    nxBadge.Text                   = ""
    nxBadge.AutoButtonColor        = false
    nxBadge.ZIndex                 = 5

    local nxHover = false
    task.spawn(function()
        while not _dead and _gui == gui do
            if not nxHover then tw(nxGlow, { BackgroundTransparency = 0.6 }, 1.1, EASE_SOFT) end
            task.wait(1.2)
            if _dead or _gui ~= gui then break end
            if not nxHover then tw(nxGlow, { BackgroundTransparency = 0.82 }, 1.1, EASE_SOFT) end
            task.wait(1.2)
        end
    end)

    -- botón minimizar (glass)
    local minBtn = Instance.new("TextButton", header)
    minBtn.Size                   = UDim2.new(0, 28, 0, 28)
    minBtn.Position               = UDim2.new(1, -36, 0.5, -14)
    minBtn.BackgroundColor3       = C.ROW
    minBtn.BackgroundTransparency = 0.45
    minBtn.BorderSizePixel        = 0
    minBtn.Text                   = "—"
    minBtn.TextColor3             = C.TEXT_HI
    minBtn.Font                   = Enum.Font.GothamBold
    minBtn.TextSize               = 15
    minBtn.AutoButtonColor        = false
    corner(minBtn, R.CTRL)
    glassStroke(minBtn, 0.7, 1)

    local hLine = Instance.new("Frame", panel)
    hLine.Size                   = UDim2.new(1, -2 * PAD, 0, 1)
    hLine.Position               = UDim2.new(0, PAD, 0, HEAD_H - 1)
    hLine.BackgroundColor3       = C.WHITE
    hLine.BackgroundTransparency = 0.82
    hLine.BorderSizePixel        = 0
    do  -- separador minimalista: se desvanece en los extremos (no una línea dura)
        local lg = Instance.new("UIGradient", hLine)
        lg.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0,   1.0),
            NumberSequenceKeypoint.new(0.5, 0.0),
            NumberSequenceKeypoint.new(1,   1.0),
        })
    end

    -- drag por el header (smooth lerp · se bloquea si estamos arrastrando el slider)
    local _panelDrag = false   -- expuesto para que el slider lo bloquee
    do
        local dragStart, startPos = nil, nil
        local dragTargetX, dragTargetY = 0, 0
        local DRAG_SMOOTH = 0.22   -- lerp factor (0 = pegajoso, 1 = directo)

        trackUI(header.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
                _panelDrag = true; dragStart = i.Position; startPos = panel.Position
                dragTargetX = startPos.X.Offset
                dragTargetY = startPos.Y.Offset
                -- feedback de "levantar la ventana": ahora vive en el borde, no en un halo
                tw(panelStroke, { Transparency = 0 }, DUR_MED, EASE_SOFT)
            end
        end))
        trackUI(UserInputService.InputChanged:Connect(function(i)
            if _panelDrag and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
                local d = i.Position - dragStart
                dragTargetX = startPos.X.Offset + d.X
                dragTargetY = startPos.Y.Offset + d.Y
            end
        end))
        trackUI(UserInputService.InputEnded:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
                if _panelDrag then tw(panelStroke, { Transparency = 0.12 }, DUR_SLOW, EASE_SOFT) end
                _panelDrag = false
            end
        end))

        -- el corte de "ya llegué" mira X e Y (si no, los arrastres verticales quedan a medias)
        trackUI(RunService.RenderStepped:Connect(function()
            if not startPos then return end
            local cx = panel.Position.X.Offset
            local cy = panel.Position.Y.Offset
            if not _panelDrag
               and math.abs(cx - dragTargetX) < 0.5
               and math.abs(cy - dragTargetY) < 0.5 then
                return
            end
            local nx = cx + (dragTargetX - cx) * DRAG_SMOOTH
            local ny = cy + (dragTargetY - cy) * DRAG_SMOOTH
            if not _panelDrag and math.abs(nx - dragTargetX) < 0.5 and math.abs(ny - dragTargetY) < 0.5 then
                nx, ny = dragTargetX, dragTargetY
            end
            panel.Position = UDim2.new(startPos.X.Scale, nx, startPos.Y.Scale, ny)
        end))
    end

    -- ════════════ BODY (contenedor para minimizar) ════════════
    local body = Instance.new("Frame", panel)
    body.Size                   = UDim2.new(1, 0, 0, BODY_H)
    body.Position               = UDim2.new(0, 0, 0, HEAD_H)
    body.BackgroundTransparency = 1

    -- helper: anti-spam de clicks (Xeno = PlayerGui + MouseButton1Click)
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
        t.ZIndex                 = 60   -- Sibling: por encima del panel aunque se solapen
        corner(t, R.CARD)
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

    -- ════════════ ABRIR DISCORD (logo NX) — RPC LOCAL DE LA APP ════════════
    local httpReq     = (syn and syn.request) or (http and http.request) or http_request or request
    local HttpService = game:GetService("HttpService")

    local function openDiscord()
        -- 1) copia SIEMPRE (red de seguridad, por si la app no está abierta)
        local copied = false
        pcall(function()
            local clip = setclipboard or toclipboard or (syn and syn.write_clipboard) or writeclipboard
            if clip then clip(DISCORD_INVITE); copied = true end
        end)

        -- 2) saca el código del invite (lo último del link) y dispara el RPC en la app
        local code = DISCORD_INVITE:match("([%w%-_]+)%s*$")
        if code and httpReq then
            task.spawn(function()
                for port = 6463, 6472 do                      -- Discord escucha en uno de estos
                    pcall(function()
                        httpReq({
                            Url     = "http://127.0.0.1:" .. port .. "/rpc?v=1",
                            Method  = "POST",
                            Headers = {
                                ["Content-Type"] = "application/json",
                                ["Origin"]       = "https://discord.com",
                            },
                            Body = HttpService:JSONEncode({
                                cmd   = "INVITE_BROWSER",
                                args  = { code = code },
                                nonce = HttpService:GenerateGUID(false),
                            }),
                        })
                    end)
                end
            end)
            toast("Abriendo Discord en la app…", true)
            return
        end

        -- 3) sin http_request: al menos quedó en el portapapeles
        toast(copied and "Discord copiado · pégalo en tu navegador"
                     or  ("Discord: " .. DISCORD_INVITE), true)
    end

    -- ── etiqueta de sección (con tick de acento para jerarquía) ──
    local function sectionLabel(parent, text, posY)
        local tick = Instance.new("Frame", parent)
        tick.Size             = UDim2.new(0, 3, 0, 11)
        tick.Position         = UDim2.new(0, PAD, 0, posY + 1)
        tick.BackgroundColor3 = C.ACCENT
        tick.BorderSizePixel  = 0
        corner(tick, 2)

        local l = Instance.new("TextLabel", parent)
        l.Size                   = UDim2.new(1, -2 * PAD - 10, 0, LBL_H)
        l.Position               = UDim2.new(0, PAD + 10, 0, posY)
        l.BackgroundTransparency = 1
        l.Text                   = string.upper(text)
        l.TextColor3             = Color3.fromRGB(170, 198, 255)
        l.Font                   = Enum.Font.GothamBold
        l.TextSize               = 11
        l.TextXAlignment         = Enum.TextXAlignment.Left
        return l
    end

    -- ════════════ COMPONENTE: FILA CON SWITCH ════════════
    -- Devuelve { row, setOn(state), setSub(text), setEnabled(bool) }
    local function makeSwitchRow(parent, title, subtitle, posY, onToggle)
        local row = Instance.new("TextButton", parent)
        row.Size                   = UDim2.new(1, -2 * PAD, 0, ROW_H)
        row.Position               = UDim2.new(0, PAD, 0, posY)
        row.BackgroundColor3       = C.ROW      -- color SÓLIDO: nada de "multiply" de UIGradient
        row.BackgroundTransparency = 0.0
        row.BorderSizePixel        = 0
        row.Text                   = ""
        row.AutoButtonColor        = false
        row.AutoLocalize           = false
        corner(row, R.CARD)
        local rowStroke = glassStroke(row, 0.6, 1.2)   -- borde cristal con degradado
        addSpecular(row, 1, 1, 0.65)                   -- filo de luz superior
        local rowScale = Instance.new("UIScale", row); rowScale.Scale = 1

        local tl = Instance.new("TextLabel", row)
        tl.Size                   = UDim2.new(1, -76, 0, subtitle and 16 or (ROW_H - 2))
        tl.Position               = UDim2.new(0, 12, 0, subtitle and 6 or 0)
        tl.BackgroundTransparency = 1
        tl.Text                   = title
        tl.TextColor3             = C.TEXT_HI
        tl.Font                   = Enum.Font.GothamBold
        tl.TextSize               = 14
        tl.TextXAlignment         = Enum.TextXAlignment.Left
        tl.TextYAlignment         = Enum.TextYAlignment.Center

        local subLabel
        if subtitle then
            subLabel = Instance.new("TextLabel", row)
            subLabel.Size                   = UDim2.new(1, -76, 0, LBL_H)
            subLabel.Position               = UDim2.new(0, 12, 0, 24)
            subLabel.BackgroundTransparency = 1
            subLabel.Text                   = subtitle
            subLabel.TextColor3             = C.TEXT_MID
            subLabel.Font                   = Enum.Font.Gotham
            subLabel.TextSize               = 11
            subLabel.TextXAlignment         = Enum.TextXAlignment.Left
            subLabel.TextTruncate           = Enum.TextTruncate.AtEnd
        end

        -- switch (track + knob)
        local trackSw = Instance.new("Frame", row)
        trackSw.Size                   = UDim2.new(0, 44, 0, 24)
        trackSw.Position               = UDim2.new(1, -56, 0.5, -12)
        trackSw.BackgroundColor3       = C.OFF
        trackSw.BorderSizePixel        = 0
        corner(trackSw, 12)

        local trackGlow = Instance.new("UIStroke", trackSw)   -- halo del track cuando está ON
        trackGlow.Color = C.ON_GLOW; trackGlow.Thickness = 6; trackGlow.Transparency = 1

        local knob = Instance.new("Frame", trackSw)
        knob.Size                   = UDim2.new(0, 18, 0, 18)
        knob.Position               = UDim2.new(0, 3, 0.5, -9)
        knob.BackgroundColor3       = C.WHITE
        knob.BorderSizePixel        = 0
        knob.ZIndex                 = 2
        corner(knob, 9)
        local knobGlow = Instance.new("UIStroke", knob)   -- glow verde cuando está ON
        knobGlow.Color = C.ON_GLOW; knobGlow.Thickness = 5; knobGlow.Transparency = 1

        local state    = false
        local disabled = false
        local function setOn(on, instant)
            state = on
            local kPos = on and UDim2.new(1, -21, 0.5, -9) or UDim2.new(0, 3, 0.5, -9)
            local tCol = on and C.ON or C.OFF
            if instant then
                knob.Position = kPos; trackSw.BackgroundColor3 = tCol
                knobGlow.Transparency  = on and 0.45 or 1
                trackGlow.Transparency = on and 0.55 or 1
            else
                tw(knob, { Position = kPos }, DUR_MED, EASE_POP)
                tw(trackSw, { BackgroundColor3 = tCol }, DUR_FAST)
                tw(knobGlow,  { Transparency = on and 0.45 or 1 }, DUR_MED)
                tw(trackGlow, { Transparency = on and 0.55 or 1 }, DUR_MED)
            end
        end

        -- estado DISABLED (apaga la fila: no responde y se atenúa)
        local function setEnabled(en)
            disabled = not en
            row.Active   = en
            row.AutoButtonColor = false
            tw(row, { BackgroundTransparency = en and 0.0 or 0.5 }, DUR_FAST)
            tw(tl,  { TextTransparency = en and 0 or 0.55 }, DUR_FAST)
            if subLabel then tw(subLabel, { TextTransparency = en and 0 or 0.55 }, DUR_FAST) end
            trackSw.BackgroundColor3 = (not en) and C.DISABLED or (state and C.ON or C.OFF)
        end

        -- estados Idle/Hover/Press con microanimaciones (sin tocar FPS)
        trackUI(row.MouseEnter:Connect(function()
            if disabled then return end
            tw(row, { BackgroundColor3 = C.ROW_HOV, BackgroundTransparency = 0.0 }, DUR_FAST)
            tw(rowScale, { Scale = 1.015 }, DUR_FAST, EASE_POP)
            tw(rowStroke, { Transparency = 0.3 }, DUR_FAST)
        end))
        trackUI(row.MouseLeave:Connect(function()
            if disabled then return end
            tw(row, { BackgroundColor3 = C.ROW, BackgroundTransparency = 0.0 }, DUR_FAST)
            tw(rowScale, { Scale = 1 }, DUR_FAST)
            tw(rowStroke, { Transparency = 0.6 }, DUR_FAST)
        end))
        trackUI(row.MouseButton1Down:Connect(function()
            if disabled then return end
            tw(rowScale, { Scale = 0.975 }, DUR_FAST)
        end))
        trackUI(row.MouseButton1Up:Connect(function()
            if disabled then return end
            tw(rowScale, { Scale = 1.015 }, DUR_FAST, EASE_POP)
        end))

        safeClick(row, function() if not disabled then onToggle(not state) end end)

        local function setSub(text) if subLabel then subLabel.Text = text end end
        return { row = row, setOn = setOn, setSub = setSub, setEnabled = setEnabled }
    end

    -- ════════════ SECCIÓN: MOVIMIENTO ════════════
    sectionLabel(body, "MOVIMIENTO", Y.secMove)

    setActiveMode = function(modeKey)
        if activeMode == modeKey then activeMode = nil else activeMode = modeKey end
        evading, lastEscapeDir, stuckFrames, lastFramePos = false, nil, 0, nil
        stepSmooth = 0
        for _, e in ipairs(modeButtons) do
            e.setOn(activeMode == e.modeKey)
        end
        updateGlobalDot()
    end

    local moreRow = makeSwitchRow(body, "More Distance", "Alejarte (" .. ANCHOR.RADIUS .. " studs)", Y.more,
        function() setActiveMode("More") end)
    local lessRow = makeSwitchRow(body, "Less Distance", "Acercarte (8 studs)", Y.less,
        function() setActiveMode("Less") end)

    table.clear(modeButtons)
    table.insert(modeButtons, { setOn = moreRow.setOn, modeKey = "More" })
    table.insert(modeButtons, { setOn = lessRow.setOn, modeKey = "Less" })

    -- ════════════ SECCIÓN: ANCLA INTELIGENTE ════════════
    sectionLabel(body, "ANCLA INTELIGENTE", Y.secAnchor)

    local wpStatus = Instance.new("TextLabel", body)
    wpStatus.Size                   = UDim2.new(0, 130, 0, LBL_H)
    wpStatus.Position               = UDim2.new(1, -(PAD + 130), 0, Y.secAnchor)
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
    anchorRow = makeSwitchRow(body, "Anclar aqui", "Fija tu posición actual", Y.anchor,
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
    sliderRow.Size                   = UDim2.new(1, -2 * PAD, 0, SLD_H)
    sliderRow.Position               = UDim2.new(0, PAD, 0, Y.slider)
    sliderRow.BackgroundColor3       = C.ROW    -- misma jerarquía visual que las filas
    sliderRow.BackgroundTransparency = 0.0
    sliderRow.BorderSizePixel        = 0
    corner(sliderRow, R.CARD)
    glassStroke(sliderRow, 0.6, 1.2)
    addSpecular(sliderRow, 1, 1, 0.6)

    local radLabel = Instance.new("TextLabel", sliderRow)
    radLabel.Size                   = UDim2.new(0, 120, 0, 16)
    radLabel.Position               = UDim2.new(0, 12, 0, 8)
    radLabel.BackgroundTransparency = 1
    radLabel.Text                   = "Radio"
    radLabel.TextColor3             = C.TEXT_HI
    radLabel.Font                   = Enum.Font.GothamMedium
    radLabel.TextSize               = 12
    radLabel.TextXAlignment         = Enum.TextXAlignment.Left

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

    local fill = Instance.new("Frame", trackBar)   -- relleno azul SÓLIDO (color exacto)
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
    local knobHalo = Instance.new("UIStroke", knob)   -- halo del acento alrededor de la perilla
    knobHalo.Color = C.ACCENT_2; knobHalo.Thickness = 5; knobHalo.Transparency = 0.7

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
            tw(knob, { Size = UDim2.new(0, 20, 0, 20), Position = UDim2.new(knob.Position.X.Scale, -10, 0.5, -10) }, DUR_FAST, EASE_POP)
            tw(knobHalo, { Transparency = 0.35, Thickness = 7 }, DUR_FAST)   -- feedback en vivo al agarrar
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
            tw(knob, { Size = UDim2.new(0, 16, 0, 16), Position = UDim2.new(f, -8, 0.5, -8) }, DUR_FAST, EASE_POP)
            tw(knobHalo, { Transparency = 0.7, Thickness = 5 }, DUR_MED)   -- vuelve a reposo
        end
    end))

    -- ════════════ SECCIÓN: DETECCIÓN ════════════
    sectionLabel(body, "DETECCIÓN", Y.secDetect)

    -- ── PRE-DETECCIÓN: 2º radio. Solo avisa (no mueve, no evita, no toca nada) ──
    local preRow
    preRow = makeSwitchRow(body, "Pre-detección", "Solo avisa · no mueve", Y.pre,
        function(on)
            preOn = on
            preRow.setOn(on)
            if not on then
                preAlert, preCount, preNearest, preClosing, preparedDir = false, 0, math.huge, 0, nil
                preRow.setSub("Off")
            else
                preRow.setSub("Vigilando…")
            end
            updateGlobalDot()
            toast(on and "Pre-detección: ON" or "Pre-detección: OFF", on)
        end)
    preRow.setOn(preOn, true)

    -- ── SHOW RADIUS: el slider SOLO cambia la distancia; esto SOLO el círculo ──
    local radiusRow
    radiusRow = makeSwitchRow(body, "Show Radius", "Círculo azul de alcance", Y.radius,
        function(on)
            showRing = on
            radiusRow.setOn(on)
            toast(on and "Círculo de rango: ON" or "Círculo de rango: OFF", on)
        end)
    radiusRow.setOn(showRing, true)

    -- ── footer hint ──
    local hint = Instance.new("TextLabel", body)
    hint.Size                   = UDim2.new(1, -2 * PAD, 0, LBL_H)
    hint.Position               = UDim2.new(0, PAD, 0, Y.hint)
    hint.BackgroundTransparency = 1
    hint.Text                   = "Pre-detección = aviso anticipado · Radio = alcance real"
    hint.TextColor3             = C.TEXT_LO
    hint.Font                   = Enum.Font.Gotham
    hint.TextSize               = 10
    hint.TextXAlignment         = Enum.TextXAlignment.Left

    -- ════════════ DOT DE ESTADO GLOBAL ════════════
    updateGlobalDot = function()
        local col
        if anchored then
            col = C.ON
        elseif activeMode and preAlert then
            col = C.WARN            -- ámbar: alguien se aproxima (aviso de la pre-detección)
        elseif activeMode then
            col = C.ACCENT
        else
            col = C.TEXT_LO
        end
        tw(dot, { BackgroundColor3 = col }, DUR_FAST)
        local active = anchored or (activeMode ~= nil)
        tw(dotGlow, { Color = col, Transparency = active and 0.55 or 1 }, DUR_MED)
    end

    -- ════════════ INFO EN VIVO DE LA PRE-DETECCIÓN (incremental: solo si cambió) ════════════
    -- Nada de scans aquí: lee el estado que el heartbeat ya calculó, y solo toca el
    -- texto cuando cambia de verdad. Cero coste cuando no pasa nada.
    local _preTextLast, _preAlertLast, _preTick = nil, nil, 0
    trackUI(RunService.Heartbeat:Connect(function()
        if _dead or _gui ~= gui then return end
        local now = os.clock()
        if now - _preTick < PRE.UI_HZ then return end
        _preTick = now

        if not preOn then
            if _preTextLast ~= "Off" then preRow.setSub("Off"); _preTextLast = "Off" end
            return
        end

        local txt
        if preCount > 0 then
            txt = string.format("%d cerca · %d studs", preCount, math.floor(math.min(preNearest, 9999)))
            if preClosing > 8 then txt = txt .. " ↓" end   -- viene hacia ti
        else
            txt = "Vigilando… · " .. math.floor(preRadius()) .. " studs"
        end
        if txt ~= _preTextLast then preRow.setSub(txt); _preTextLast = txt end
        if preAlert ~= _preAlertLast then _preAlertLast = preAlert; updateGlobalDot() end
    end))

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
    trackUI(nxBadge.MouseButton1Down:Connect(function() tw(nxScale, { Scale = 1.02 }, DUR_FAST) end))
    trackUI(nxBadge.MouseButton1Up:Connect(function() tw(nxScale, { Scale = nxHover and 1.14 or 1 }, DUR_FAST, Enum.EasingStyle.Back) end))
    safeClick(nxBadge, openDiscord)

    -- ════════════ MINIMIZAR ════════════
    local minimized = false
    trackUI(minBtn.MouseEnter:Connect(function() tw(minBtn, { BackgroundTransparency = 0.1 }, DUR_FAST) end))
    trackUI(minBtn.MouseLeave:Connect(function() tw(minBtn, { BackgroundTransparency = 0.45 }, DUR_FAST) end))
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
    UI.setPre             = preRow.setOn
    UI.updateAnchorStatus = updateAnchorStatus
    UI.updateGlobalDot    = updateGlobalDot
    UI.refreshRadius      = layoutSlider
    UI.ready              = true

    -- ════════════ INIT estados (refleja el estado lógico actual) ════════════
    moreRow.setOn(activeMode == "More", true)
    lessRow.setOn(activeMode == "Less", true)
    anchorRow.setOn(anchored, true)
    radiusRow.setOn(showRing, true)
    preRow.setOn(preOn, true)
    updateAnchorStatus()
    updateGlobalDot()

    -- ════════════ ANIMACIÓN DE ENTRADA (solo en el primer build) ════════════
    if firstBuild then
        panel.BackgroundTransparency = 1
        local pScale = Instance.new("UIScale", panel); pScale.Scale = 0.92
        tw(panel, { BackgroundTransparency = 0.05 }, DUR_MED)
        tw(pScale, { Scale = 1 }, DUR_SLOW, EASE_POP)

        -- stagger de las filas/secciones
        local stagger = { moreRow.row, lessRow.row, anchorRow.row, sliderRow, preRow.row, radiusRow.row }
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
    stepSmooth = 0
    preAlert, preCount, preNearest, preClosing, preparedDir = false, 0, math.huge, 0, nil
    table.clear(_lastSeen)
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
            if not _gui.Enabled  then pcall(function() _gui.Enabled = true end) end
            if _gui.ResetOnSpawn then pcall(function() _gui.ResetOnSpawn = false end) end
        elseif SHIELD.REBUILD then
            safeRebuild()
        end
        -- bucles vivos?
        ensureLoops()
    end
end)

print("KEEP DISTANCE v7.0 cargado · SUELO DURO (nadie entra en " .. CONTACT.HARD_R .. " studs) · predicción adaptativa + velocidad estimada + scoring con futuro · filtro vertical anti falso positivo (Air Walk) · PRE-DETECCIÓN (2º radio, solo avisa) · giro y paso suavizados · UI sin sombras · Air Walk safe.")
