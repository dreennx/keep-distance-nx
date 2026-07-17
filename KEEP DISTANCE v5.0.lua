-- ═══════════════════════════════════════════════════════════
-- KEEP DISTANCE v8.0 · Núcleo de detección por capas
--
-- ★★ FIX v8.0 — EL FLYER QUE TE EMPUJABA (bug grave de v7.1) ★★
--   v7.1 subió VERT_UP a 250 para cazar flyers. Efecto secundario: `verticalBias`
--   devolvía 0 hasta 210 studs de altura, y la distancia se medía SOLO en XZ. O sea
--   que alguien volando 100 studs sobre tu cabeza se leía "a 0 studs" → el suelo
--   duro (prioridad 0, no negocia) se disparaba y te arrastraba por el mapa sin que
--   nadie te tocara nunca. Cuanto más alto volaba, igual de "encima" te parecía.
--   Causa raíz: UNA sola métrica respondiendo dos preguntas distintas.
--   Ahora son tres, cada una para lo suyo (ver "MEDIDAS"):
--     · nearest3D      → contacto físico REAL (con Y). Solo la usa el suelo duro.
--     · nearestThreat  → XZ + bias vertical. Decide SI evadís (respeta tu Air Walk).
--     · scoreAt        → como threat pero ponderada por comportamiento. Decide DÓNDE.
--   Y el bias de ARRIBA pasa a ser progresivo (pesa 1:1 desde VERT_UP_SOFT), no un
--   escalón: el que se cierne sobre ti sigue contando, el que pasa alto ya no.
--
-- ★★ FIX v8.0 — MISMO COMPORTAMIENTO EN MÓVIL Y EN PC ★★
--   Todo el movimiento de v7.x era por FRAME (MAX_STEP = 5 studs/frame). En la
--   práctica el tool corría a 150 studs/s en un móvil de 30fps y a 720 en un PC de
--   144: ninguna constante servía para las dos. Ahora todo va en studs/SEGUNDO y
--   grados/SEGUNDO, escalado por un dt acotado (DT_MAX: un lag spike no te
--   teletransporta). Los valores equivalen exactamente a los de v7.2 a 60fps.
--
-- ★★ FIX v8.0 — estimateVel NO FUNCIONABA ARRIBA DE 120 FPS ★★
--   v7.x derivaba la velocidad contra el frame anterior exigiendo dt >= 1/120. A
--   144fps el dt de un frame es 0.0069 < 0.0083 → la estimación jamás corría y los
--   replicados con AssemblyLinearVelocity = 0 (justo los rápidos, el caso que v7.0
--   quería resolver) quedaban sin predicción. Ahora la muestra base tiene timestamp
--   propio y se refresca cada VEL_SAMPLE: funciona igual a 30 que a 240 fps.
--
-- ★ NUEVO v8.0 — CAPA DE SENSADO (tracks):
--   Un track por jugador con memoria corta: parte cacheada (se acabó el
--   GetDescendants por frame), velocidad estable, confianza y flags. Recorte
--   espacial ANTES de puntuar: v7.x puntuaba rutas contra los 40 del servidor
--   (16 direcciones × 2 sondas × 40 jugadores por frame); ahora solo entran los
--   que pueden importar.
--
-- ★ NUEVO v8.0 — CAPA DE COMPORTAMIENTO (noclip · teleport · stalking · speed · fly):
--   ⚠ REGLA DE ORO: un flag NUNCA ejecuta una acción ni cambia el trigger de
--   evasión. Solo (a) prioriza —de quién huís primero cuando hay varios— y (b)
--   informa a la pre-detección. Un falso positivo acá te hace mirar más a alguien,
--   jamás saltar. Presupuesto de raycasts por frame: no cuesta FPS.
--
-- ★ v8.0 — SCORING COHERENTE: `look` y `HORIZON` ahora hablan del MISMO instante.
--   En v7.x tu posición se proyectaba ~4 frames (0.07s) pero la de los otros 0.35s:
--   las dos mitades del scoring comparaban momentos distintos.
--
-- Base heredada (intacta): UI glass NX + blindaje + watchdog + sessionAlive ·
-- ZIndexBehavior=Sibling (v6.5) · colores sólidos (v6.3) · tope TCPA (v7.0) ·
-- ghost de invisibles + caza-huérfanos (v7.1) · fix regreso al ancla (v7.2) ·
-- SIN SALTO (Air Walk safe) · el pre-radio SOLO informa.
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
local stuckTime     = 0       -- ★ v8.0: SEGUNDOS sin avanzar (era frames: se destrababa
                              -- a destiempo según el fps de cada máquina)
local lastFramePos  = nil     -- posición del frame anterior mientras evadimos
local speedSmooth   = 0       -- ★ v8.0: velocidad suavizada en studs/s (era paso/frame)

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
-- ★ v8.0 · TODO EN studs/SEGUNDO (antes era studs/FRAME).
-- Los valores son los de v7.2 multiplicados por 60: a 60fps el tool se mueve
-- EXACTAMENTE igual que antes, pero ahora un móvil a 30fps y un PC a 144 hacen
-- lo mismo en vez de correr a mitad y al doble de velocidad respectivamente.
local MODES = {
    -- More.SAFE_DISTANCE ya NO se usa directo: More sigue el slider del Radio (ver modeSafeDistance).
    More = { SAFE_DISTANCE = 125, MAX_SPEED = 300 },   -- era MAX_STEP 5   /frame
    Less = { SAFE_DISTANCE = 8,   MAX_SPEED = 150 },   -- era MAX_STEP 2.5 /frame
}
local GROUND_CHECK = 15
local WALL_CHECK   = 3

-- Techo del delta-time. Sin esto, un lag spike de 0.5s se traduce en un salto de
-- 150 studs en un frame (y el guard anti-fling lo leería como un ataque).
local DT_MAX = 0.08   -- s

local ANCHOR = {
    RADIUS      = 125,   -- alcance de More Distance + radio del ancla + círculo azul (unificado)
    RADIUS_MIN  = 5,
    RADIUS_MAX  = 200,   -- tope del slider
    RADIUS_STEP = 5,
    CLEAR_DIST  = 12,
    DEADZONE    = 0.4,
    MAX_SPEED   = 300,   -- studs/s (era MAX_STEP 5 /frame)
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
    HOLD_TIME     = 3.0,    -- ★ v7.1: 1.5→3.0 · aguantamos más al invisible que parpadea largo
    GHOST_MAX     = 0.6,    -- ★ v7.1: 0.35→0.6 · extrapolamos su rumbo el doble de tiempo
    USE_PIVOT     = true,   -- fallback GetPivot() si no hay ninguna parte localizable
    DEEP_SCAN     = true,   -- buscar CUALQUIER BasePart si no hay HRP/Head (cazar partes ocultas)
    SKIP_DEAD     = true,   -- ignorar personajes muertos (falso positivo puro)
    VEL_EST_MAX   = 400,    -- tope de la velocidad estimada por diferencia (anti-teleport)
    VEL_SAMPLE    = 1/30,   -- ★ v8.0: cada cuánto se refresca la muestra base de velocidad.
                            -- v7.x comparaba contra el frame anterior con un mínimo de
                            -- 1/120 s: a 144fps el dt de frame (0.0069) nunca lo alcanzaba
                            -- y la estimación quedaba muerta. Con muestra propia, el fps
                            -- deja de importar.
    -- ★ v8.0 · FILTRO VERTICAL ASIMÉTRICO (revisado) ★
    -- El filtro existe por tu Air Walk: vuelas y los del suelo se leían como amenaza.
    -- Eso solo pasa hacia ABAJO → ahí el corte es duro (VERT_DOWN, con fade).
    -- Hacia ARRIBA v7.1 puso un techo de 250 con bias 0 hasta los 210: como la
    -- distancia se mide en XZ, un flyer 100 studs sobre tu cabeza medía 0 studs y
    -- disparaba el suelo duro. Ahora la altura pesa PROGRESIVO (1:1 desde
    -- VERT_UP_SOFT): el que se cierne sobre ti cuenta, el que pasa alto no.
    VERT_DOWN      = 28,    -- studs POR DEBAJO tuyo a partir de los cuales dejan de ser amenaza (Air Walk)
    VERT_DOWN_FADE = 10,    -- desvanecido suave del filtro de abajo (sin parpadeo al subir/bajar)
    VERT_UP_SOFT   = 25,    -- ★ v8.0: hasta acá, alguien arriba cuenta como si estuviera a tu nivel
    VERT_UP        = 250,   -- techo de existencia: más arriba, ni se trackea
    ORPHAN_SCAN    = true,  -- ★ v7.1: si plr.Character = nil (cheat que reparenta) lo buscamos en Workspace
    SCAN_MARGIN    = 80,    -- ★ v8.0: studs de colchón del recorte espacial (predicción + look-ahead)
}

-- ════════════ BLINDAJE DE CONTACTO (nunca tocar a nadie) ════════════
local CONTACT = {
    HARD_R   = 6,     -- ★ SUELO DURO: nadie puede estar más cerca. Se hace cumplir SIEMPRE.
                      -- ★ v8.0: se mide en 3D REAL. Alguien 6 studs por encima ya no te
                      -- empuja (no te toca); a tu lado, se comporta igual que siempre.
    BUFFER   = 1.5,   -- margen extra al salir (evita rebotar en el borde exacto)
    MAX_STEP = 16,    -- studs máx de UN empujón del blindaje. Ojo: esto NO es velocidad y
                      -- por eso no se escala por dt — es una corrección de posición
                      -- ("cuánto me falta para salir"), que es geométrica y ya se
                      -- auto-limita: en cuanto sales, deja de dispararse.
    ESCAPE_V = 960,   -- studs/s a los que puede llegar la evasión con urgencia máxima
                      -- (= el viejo 16/frame × 60: lo que evita que un corredor te alcance)
    PANIC_R  = 10,    -- desde aquí la reacción del cerebro se acelera (no mueve por sí solo)
    PROBES   = 8,     -- resolución de la búsqueda del paso mínimo para salir
}

-- ════════════ CEREBRO DE ESCAPE (elige ruta, no solo empuja) ════════════
local SMART = {
    DIRS         = 16,    -- direcciones candidatas alrededor tuyo
    LOOK_MAX     = 40,    -- ★ v8.0: studs máx de proyección de TU ruta al puntuarla.
                          -- v7.x usaba LOOK_MULT=4 pasos (≈0.07s) mientras proyectaba a
                          -- los otros 0.35s: las dos mitades del scoring hablaban de
                          -- instantes distintos. Ahora `look` manda y el horizonte se
                          -- deriva de él (look/velocidad), así ambos miran el mismo momento.
    HORIZON      = 0.35,  -- s de futuro deseados (recortados por LOOK_MAX si vas muy rápido)
    SEED_W       = 3,     -- bonus a la dirección natural de repulsión
    SMOOTH_W     = 2.5,   -- bonus a mantener el rumbo anterior (anti-zigzag)
    WALL_TRIES   = 4,     -- máx raycasts/frame buscando ruta sin pared (perf)
    EXIT_FACTOR  = 1.15,  -- histéresis: sigue evadiendo hasta safe*este margen
    STUCK_TIME   = 0.1,   -- ★ v8.0: s sin avanzar -> noclip + re-decidir (era 6 FRAMES:
                          -- 0.1s a 60fps pero 0.2s a 30fps y 0.04s a 144 → se destrababa
                          -- a destiempo según la máquina)
}

-- ════════════ SUAVIDAD (anti movimientos bruscos) ════════════
-- El límite de giro se RELAJA con la urgencia: lejos = curva natural, encima = giro libre.
-- ★ v8.0: grados/SEGUNDO y constantes de tiempo. Equivalen a los valores de v7.2 a
-- 60fps (55°/frame × 60 = 3300°/s), pero ahora el giro se ve igual a cualquier fps
-- en vez de ser 2,4× más brusco en un monitor de 144Hz.
local SMOOTH = {
    TURN_MAX   = 3300,   -- grados/s de giro máx en calma        (era 55 /frame)
    TURN_PANIC = 10800,  -- grados/s con urgencia máxima          (era 180 /frame: sin límite práctico)
    RISE_TAU   = 0.04,   -- s · constante de tiempo al acelerar   (≡ rampa 0.35 /frame @60fps)
    FALL_TAU   = 0.085,  -- s · constante de tiempo al frenar     (≡ rampa 0.18 /frame @60fps)
}

-- ════════════ CAPA DE COMPORTAMIENTO (v8.0) ════════════
-- ⚠ REGLA DE ORO: estos flags NO ejecutan acciones y NO cambian el trigger de
-- evasión (eso lo decide `nearestThreat`, la distancia real). Solo hacen dos cosas:
--   1) PRIORIZAR: entre dos rutas igual de libres, el scoring prefiere la que no
--      pasa cerca del que te atraviesa paredes persiguiéndote.
--   2) INFORMAR: el pre-radio te dice QUÉ es lo que se acerca, no solo cuántos.
-- Por eso un falso positivo acá es barato: te hace mirar más a alguien, nunca saltar.
local BEHAV = {
    SPEED_HI   = 45,    -- studs/s sostenidos = va más rápido de lo humano (walkspeed normal 16)
    TP_DIST    = 40,    -- studs de salto en un frame = teleport (no lag: el dt se comprueba)
    STALK_R    = 90,    -- studs dentro de los cuales cuenta como persecución
    STALK_T    = 2.5,   -- s viniendo derecho a por ti de forma sostenida = te sigue
    STALK_ALIGN= 0.9,   -- ★ qué tan alineado va su rumbo CONTIGO (0.9 ≈ 25° de tolerancia).
                        -- Sin esto había falso positivo: cualquiera que camina en línea
                        -- recta "cierra distancia" durante toda su aproximación, aunque
                        -- solo vaya a pasar por al lado. Lo que delata al perseguidor es
                        -- que CORRIGE el rumbo hacia ti: su velocidad te apunta y sigue
                        -- apuntándote. El que solo cruza pierde la alineación al acercarse.
    CLOSE_MIN  = 4,     -- studs/s mínimos de cierre para que cuente (ignora el paseo casual)
    FLY_DROP   = 30,    -- studs sin suelo debajo = vuela
    FALL_V     = 25,    -- studs/s de caída: por encima está cayendo, no volando
    RAY_R      = 110,   -- solo lanzamos rayos de comportamiento a los que estén así de cerca
    RAY_HZ     = 0.25,  -- s entre rayos POR jugador
    RAY_BUDGET = 2,     -- ★ máx rayos de comportamiento por FRAME en total (perf: techo duro)
    FLAG_HOLD  = 1.5,   -- s que un flag se mantiene tras dejar de verse (anti-parpadeo)
    -- pesos de prioridad (multiplican la amenaza percibida SOLO en el scoring de rutas)
    W_NOCLIP   = 0.5,
    W_STALK    = 0.4,
    W_TP       = 0.5,
    W_SPEED    = 0.3,
    W_FLY      = 0.15,
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
local preTag     = nil           -- ★ v8.0: QUÉ es lo más cercano ("noclip", "vuela"…)
local preUntil   = 0
local preparedDir = nil          -- ruta precalculada (semilla, no movimiento)
local _lastArm    = 0

-- ★ v8.0: sube acá arriba porque el recorte espacial de la capa de sensado necesita
-- saber hasta dónde mira el pre-radio antes de decidir a quién procesar.
local function preRadius()
    local base = activeMode and modeSafeDistance(activeMode) or ANCHOR.CLEAR_DIST
    return math.max(PRE.MIN, base + PRE.EXTRA)
end

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

-- ════════════ CAPA DE SENSADO · TRACKS (v8.0) ════════════
-- Sustituye al `_lastSeen` suelto de v7.x por un track con memoria corta por jugador.
-- Qué gana:
--   · la parte del personaje va CACHEADA → se acabó el GetDescendants() por frame
--   · la velocidad se estima contra una muestra con timestamp propio → funciona a
--     cualquier fps (v7.x se rompía por encima de 120)
--   · cada track arrastra sus flags de comportamiento entre frames
--
-- _tracks[player] = {
--   char, part      -- refs cacheadas (part se re-resuelve solo si se pierde)
--   pos, vel        -- último estado bueno (vel estable: replicada o estimada)
--   basePos, baseT  -- muestra base para derivar velocidad
--   lastT           -- último frame en que se le vio DE VERDAD (0 = nunca)
--   flags, threat   -- comportamiento (no mueven nada: priorizan e informan)
--   closingT        -- s acumulados cerrándote distancia (stalking)
--   nextRay         -- throttle propio del rayo de comportamiento
-- }
--
-- _others[i] = { p = predicha, r = real, v = horizontal, bias, threat, flags, ghost }
--   bias   = penalización de distancia por altura (filtro vertical). Se SUMA a la
--            distancia: alguien muy por debajo "cuenta" como si estuviera lejísimos.
--   threat = multiplicador de prioridad (SOLO lo usa el scoring de rutas).
local _excludeList = {}
local _others      = {}   -- ★ v8.0: solo los RELEVANTES (recortados por scanRadius)
local _tracks      = {}   -- [player] = track
local _rayLeft     = 0    -- presupuesto de rayos de comportamiento que queda este frame
local _rayParams   = RaycastParams.new()
_rayParams.FilterType = Enum.RaycastFilterType.Exclude

-- Busca la mejor parte localizable del personaje (aunque esté invisible/oculto).
-- Prioridad: HumanoidRootPart > Head > (deep scan) cualquier BasePart.
local function resolveCharPart(char)
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

-- ★ v8.0: la parte queda cacheada en el track. El deep scan (GetDescendants aloca una
-- tabla entera) pasa de correr CADA FRAME —por cada jugador sin HRP/Head— a correr
-- solo cuando la parte se pierde de verdad. IsDescendantOf cubre el respawn.
local function getCharPart(tr, char)
    local p = tr.part
    if p and p.Parent and p:IsDescendantOf(char) then return p end
    p = resolveCharPart(char)
    tr.part = p
    return p
end

local function getTrack(plr)
    local tr = _tracks[plr]
    if not tr then
        tr = { flags = {}, threat = 1, closingT = 0, nextRay = 0, lastT = 0 }
        _tracks[plr] = tr
    end
    return tr
end

-- ★ v7.1 · CAZA-HUÉRFANOS: personajes reparentados fuera de plr.Character.
-- Algunos cheats mueven el Character a otro sitio (Parent=nil, o a un Folder de
-- Workspace) para esconderse de scripts que solo miran plr.Character. Aquí lo
-- buscamos en Workspace por nombre y por Humanoid.Parent como fallback.
-- Cache breve para no barrer todo el Workspace cada frame.
local _orphanCache = {}   -- [playerName] = { m = Model, t = os.clock() }
local ORPHAN_TTL   = 0.5  -- s

local function findOrphanChar(name)
    local now  = os.clock()
    local hit  = _orphanCache[name]
    if hit and (now - hit.t) < ORPHAN_TTL and hit.m and hit.m.Parent then
        return hit.m
    end
    -- 1) atajo: hijo directo de Workspace con ese nombre
    local direct = Workspace:FindFirstChild(name)
    if direct and direct:IsA("Model") and direct:FindFirstChildWhichIsA("Humanoid") then
        _orphanCache[name] = { m = direct, t = now }
        return direct
    end
    -- 2) barrido superficial: 1 nivel de folders (típico "IgnoreFolder", "_hidden", …)
    for _, top in ipairs(Workspace:GetChildren()) do
        if top:IsA("Folder") or top:IsA("Model") then
            local m = top:FindFirstChild(name)
            if m and m:IsA("Model") and m:FindFirstChildWhichIsA("Humanoid") then
                _orphanCache[name] = { m = m, t = now }
                return m
            end
        end
    end
    _orphanCache[name] = { m = nil, t = now }
    return nil
end

-- Lectura cruda: posición real + velocidad real (sin predicción todavía).
local function readChar(tr, char)
    local part = getCharPart(tr, char)
    if part then return part.Position, part.AssemblyLinearVelocity end
    if DETECT.USE_PIVOT then
        local ok, piv = pcall(function() return char:GetPivot().Position end)
        if ok and piv then return piv, nil end
    end
    return nil, nil
end

-- ★★ v8.0 · FIX: LA ESTIMACIÓN DE VELOCIDAD NO CORRÍA ARRIBA DE 120 FPS ★★
-- La velocidad replicada llega en 0 en muchos casos (justo con los que van rápido),
-- así que hay que derivarla del movimiento. v7.x la comparaba contra el FRAME
-- ANTERIOR exigiendo dt >= 1/120 (0.0083s): en un monitor de 144Hz el dt de un frame
-- es 0.0069 → la condición NUNCA se cumplía, la función devolvía Vector3.zero y esa
-- gente quedaba sin predicción. Justo el caso que v7.0 quería resolver.
-- Ahora la muestra base tiene su PROPIO timestamp y solo se refresca cada VEL_SAMPLE:
-- el fps deja de importar, y entre refrescos devolvemos la última estimación buena
-- (rumbo estable en vez de parpadeo).
local function estimateVel(tr, raw, vel, now)
    if vel and vel.Magnitude >= 0.5 then
        tr.basePos, tr.baseT = raw, now   -- con velocidad buena, mantenemos la base fresca
        return vel
    end
    if not tr.basePos then
        tr.basePos, tr.baseT = raw, now
        return tr.vel or Vector3.zero
    end
    local dt = now - tr.baseT
    if dt < DETECT.VEL_SAMPLE then
        return tr.vel or Vector3.zero      -- todavía no toca remuestrear
    end
    local est = Vector3.zero
    if dt <= 0.5 then                      -- muestra vieja => no inventamos rumbo
        local e = (raw - tr.basePos) / dt
        local m = e.Magnitude
        if m > 0.5 and m < DETECT.VEL_EST_MAX then est = e end
    end
    tr.basePos, tr.baseT = raw, now
    return est
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

-- ★★ v8.0 · Filtro vertical ASIMÉTRICO (revisado). dy = otherY - myY (>0 = él arriba).
--   · dy < 0 (él ABAJO): corte DURO. Es la razón de ser del filtro: con Air Walk vuelas
--     y los del suelo se leerían como amenaza. A partir de VERT_DOWN no cuentan, con
--     fade para que no parpadeen al subir/bajar.
--   · dy > 0 (él ARRIBA): PROGRESIVO, no escalón. v7.1 devolvía bias 0 hasta 210 studs
--     y, como la distancia se mide en XZ, un flyer 100 studs sobre tu cabeza medía
--     0 studs → evasión permanente contra alguien inalcanzable (y con el suelo duro
--     usando la misma métrica, además te arrastraba). Ahora la altura pesa 1:1 desde
--     VERT_UP_SOFT: a 10 studs cuenta entero, a 100 cuenta como 75 studs más lejos.
--     El corte a nil en VERT_UP ya no da salto: a esa altura el bias (225) lo dejó
--     fuera de cualquier radio hace rato.
local function verticalBias(dy)
    if dy >= 0 then
        if dy >= DETECT.VERT_UP then return nil end
        return math.max(0, dy - DETECT.VERT_UP_SOFT)
    end
    local ady  = -dy
    local soft = DETECT.VERT_DOWN - DETECT.VERT_DOWN_FADE
    if ady <= soft then return 0 end
    if ady >= DETECT.VERT_DOWN then return nil end
    return ((ady - soft) / DETECT.VERT_DOWN_FADE) * 400
end

-- ════════════ CAPA DE COMPORTAMIENTO (v8.0) ════════════
-- ⚠ Nada de acá mueve al personaje ni cambia cuándo se evade. Devuelve la velocidad
-- de cierre (que el pre-radio reutiliza) y deja los flags + `threat` en el track.
local function updateBehavior(tr, raw, vel, myPos, dt, now, jumped)
    local f = tr.flags

    f.speeding = vel.Magnitude > BEHAV.SPEED_HI

    if jumped then tr.tpUntil = now + BEHAV.FLAG_HOLD end
    f.teleport = now < (tr.tpUntil or 0)

    -- stalking: viene DERECHO a por vos de forma sostenida. No basta con que "cierre
    -- distancia" (eso lo hace cualquiera que camine en tu dirección general durante su
    -- aproximación): pedimos además que su rumbo te apunte, que es lo que hace un
    -- perseguidor de verdad. Sube con dt y baja al doble de rápido: cuesta ganárselo,
    -- se pierde rápido.
    local toMe    = myPos - raw
    local d       = toMe.Magnitude
    local closing = (d > 0.1) and vel:Dot(toMe.Unit) or 0
    if closing > BEHAV.CLOSE_MIN and d < BEHAV.STALK_R
       and closing > vel.Magnitude * BEHAV.STALK_ALIGN then
        tr.closingT = math.min(tr.closingT + dt, BEHAV.STALK_T * 2)
    else
        tr.closingT = math.max(tr.closingT - dt * 2, 0)
    end
    f.stalking = tr.closingT >= BEHAV.STALK_T

    -- noclip + flying cuestan raycast → presupuesto por frame + solo los cercanos +
    -- throttle por jugador. Con RAY_BUDGET=2 el techo es de 2 rayos/frame pase lo que
    -- pase: los tracks se van turnando solos vía nextRay.
    if d < BEHAV.RAY_R and now >= tr.nextRay and _rayLeft > 0 then
        _rayLeft   = _rayLeft - 1
        tr.nextRay = now + BEHAV.RAY_HZ

        -- ¿hay geometría del mapa entre él y vos y aun así te cierra? → atraviesa paredes.
        -- (_rayParams excluye a TODOS los personajes: el rayo solo puede pegar en mapa)
        if closing > BEHAV.CLOSE_MIN and Workspace:Raycast(raw, toMe, _rayParams) then
            tr.ncUntil = now + BEHAV.FLAG_HOLD
        end
        -- ¿nada debajo suyo y no está cayendo? → vuela
        local below = Workspace:Raycast(raw, Vector3.new(0, -BEHAV.FLY_DROP, 0), _rayParams)
        if below == nil and vel.Y > -BEHAV.FALL_V then tr.flyUntil = now + BEHAV.FLAG_HOLD end
    end
    -- los tres caducan solos: si el presupuesto de rayos no le da turno a este track
    -- durante un rato, sus flags se apagan en vez de quedarse pegados para siempre
    f.noclip = now < (tr.ncUntil  or 0)
    f.flying = now < (tr.flyUntil or 0)

    local t = 1
    if f.noclip   then t = t + BEHAV.W_NOCLIP end
    if f.stalking then t = t + BEHAV.W_STALK  end
    if f.teleport then t = t + BEHAV.W_TP     end
    if f.speeding then t = t + BEHAV.W_SPEED  end
    if f.flying   then t = t + BEHAV.W_FLY    end
    tr.threat = t

    return closing
end

-- Etiqueta corta del comportamiento, para el pre-radio. Solo texto: no mueve nada.
local function describeFlags(o)
    if o.ghost then return "invisible" end
    local f = o.flags
    if not f then return nil end
    if f.noclip   then return "noclip"   end
    if f.teleport then return "teleport" end
    if f.stalking then return "te sigue" end
    if f.speeding then return "veloz"    end
    if f.flying   then return "vuela"    end
    return nil
end

-- p = posición ANTICIPADA (para medir amenaza ahora mismo)
-- r = posición REAL    (para proyectar rutas a futuro: si no, se predice dos veces
--                       y el scoring cree que el atacante ya pasó de largo)
local function pushOther(list, pos, raw, vel, myPos, tr, ghost)
    local bias = verticalBias(pos.Y - myPos.Y)
    if not bias then return end   -- demasiada altura de diferencia: ni es amenaza ni la buscamos
    list[#list + 1] = {
        p      = pos,
        r      = raw or pos,
        v      = vel and Vector3.new(vel.X, 0, vel.Z) or Vector3.zero,
        bias   = bias,
        threat = tr and tr.threat or 1,
        flags  = tr and tr.flags or nil,
        ghost  = ghost or false,
    }
end

-- ★ v8.0 · RECORTE ESPACIAL: hasta dónde vale la pena procesar.
-- v7.x metía a los 40 jugadores del servidor en _others y después puntuaba 16
-- direcciones × 2 sondas contra TODOS, cada frame. Acá se decide una sola vez quién
-- puede llegar a importar. Si estás anclado se suma tu distancia al ancla, porque
-- computeAnchorTarget mide desde `home`, no desde vos.
local function scanRadius(myPos)
    local r = ANCHOR.CLEAR_DIST
    if activeMode then r = math.max(r, modeSafeDistance(activeMode) * SMART.EXIT_FACTOR) end
    if preOn      then r = math.max(r, preRadius()) end
    r = r + DETECT.SCAN_MARGIN
    if anchored and home then
        r = r + Vector3.new(myPos.X - home.X, 0, myPos.Z - home.Z).Magnitude
    end
    return r
end

local function refreshFrameCache(myPos, dt, now)
    table.clear(_others)
    _rayLeft = BEHAV.RAY_BUDGET

    -- ── PASE 1: lista de exclusión de raycasts ──
    -- Va primero y aparte: la capa de comportamiento lanza rayos DENTRO del pase 2 y
    -- necesita el filtro ya puesto. Si no, sus rayos chocarían contra los propios
    -- jugadores y todo el mundo parecería estar detrás de una pared (noclip everywhere).
    table.clear(_excludeList)
    for _, plr in ipairs(Players:GetPlayers()) do
        local ch = plr.Character
        -- ★ v7.1: si su Character = nil, intentamos rescatarlo del Workspace
        if not ch and plr ~= LocalPlayer and DETECT.ORPHAN_SCAN then
            ch = findOrphanChar(plr.Name)
        end
        if plr ~= LocalPlayer then getTrack(plr).char = ch end
        if ch then _excludeList[#_excludeList + 1] = ch end
    end
    _rayParams.FilterDescendantsInstances = _excludeList

    -- ── PASE 2: tracks + comportamiento + recorte ──
    local rScan2 = scanRadius(myPos) ^ 2   -- al cuadrado: nos ahorramos la raíz por jugador

    for plr, tr in pairs(_tracks) do
        -- Purga aquí mismo (Lua permite poner a nil la clave que estás visitando).
        -- Antes de v8.0 la purga iba en un loop aparte DESPUÉS de procesar, así que el
        -- que se acababa de ir contaba como amenaza un frame de más con su última pose.
        if not plr.Parent or (tr.lastT > 0 and (now - tr.lastT) > DETECT.HOLD_TIME + 5) then
            _tracks[plr] = nil
            continue
        end

        local ch   = tr.char
        local dead = false
        if DETECT.SKIP_DEAD and ch then
            local hum = ch:FindFirstChildOfClass("Humanoid")
            dead = (hum ~= nil and hum.Health <= 0)
        end

        if not dead then
            -- ch == nil (te esconden el Character entero) cae al rastro de abajo
            local raw, vel
            if ch then raw, vel = readChar(tr, ch) end

            if raw then
                local dx, dz = raw.X - myPos.X, raw.Z - myPos.Z
                if (dx * dx + dz * dz) <= rScan2 then
                    -- teleport: salto grande en un frame. El dt se comprueba para no
                    -- confundirlo con un lag spike (ahí todos "saltan").
                    local jumped = tr.pos and dt < 0.2
                                   and (raw - tr.pos).Magnitude > BEHAV.TP_DIST or false
                    vel = estimateVel(tr, raw, vel, now)
                    updateBehavior(tr, raw, vel, myPos, dt, now, jumped)
                    pushOther(_others, predictPos(raw, vel, myPos), raw, vel, myPos, tr, false)
                else
                    -- fuera del recorte: lo seguimos viendo (para que entre sin latencia
                    -- cuando se acerque) pero no gastamos ni predicción ni rayos en él.
                    vel = vel or Vector3.zero
                    tr.closingT = 0
                end
                tr.pos, tr.vel, tr.lastT = raw, vel, now
            elseif tr.lastT > 0 and tr.pos and (now - tr.lastT) <= DETECT.HOLD_TIME then
                -- invisible/oculto este frame: seguimos su rastro con la última velocidad
                -- conocida (un invisible que corre no se congela en su última posición).
                local age   = now - tr.lastT
                local decay = 1 - (age / DETECT.HOLD_TIME)   -- la confianza cae con el tiempo
                local ghost = tr.pos + (tr.vel or Vector3.zero) * math.min(age, DETECT.GHOST_MAX) * decay
                local dx, dz = ghost.X - myPos.X, ghost.Z - myPos.Z
                if (dx * dx + dz * dz) <= rScan2 then
                    pushOther(_others, ghost, ghost, tr.vel, myPos, tr, true)
                end
            end
        end
    end
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

-- ════════════ MEDIDAS · TRES MÉTRICAS, UNA POR PREGUNTA (v8.0) ════════════
-- v7.x tenía UNA sola (XZ + bias) respondiendo a todo, y ahí nació el peor bug de la
-- serie: el suelo duro preguntaba "¿me está tocando alguien?" y recibía una respuesta
-- HORIZONTAL. Un flyer 100 studs sobre tu cabeza medía 0 studs → prioridad 0 → te
-- arrastraba por el mapa sin haberte tocado jamás. El contacto es 3D; la amenaza no.

-- (1) CONTACTO · distancia física REAL, con Y, sin bias ni pesos. Solo el suelo duro.
--     Devuelve además el rumbo de salida, que es HORIZONTAL a propósito: no tocamos
--     tu altura nunca (Air Walk). Si está justo encima/debajo, no hay rumbo XZ que
--     dar → devuelve nil y el caller deja que el cerebro elija.
local function nearest3D(pos)
    local best, bestDir = math.huge, nil
    for _, o in ipairs(_others) do
        local off = pos - o.p
        local m   = off.Magnitude
        if m < best then
            best    = m
            bestDir = Vector3.new(off.X, 0, off.Z)
        end
    end
    if bestDir and bestDir.Magnitude > 0.05 then bestDir = bestDir.Unit else bestDir = nil end
    return best, bestDir
end

-- (2) AMENAZA · XZ + bias vertical. Decide SI evadís (y respeta tu Air Walk).
--     Sin ponderar por comportamiento: un flag JAMÁS cambia el trigger.
local function nearestThreat(pos)
    local best = math.huge
    for _, o in ipairs(_others) do
        local m = Vector3.new(pos.X - o.p.X, 0, pos.Z - o.p.Z).Magnitude + o.bias
        if m < best then best = m end
    end
    return best
end

-- (3) SCORING · como (2), proyectada `t` segundos y PONDERADA por comportamiento.
--     Decide HACIA DÓNDE. Acá sí pesan los flags: dividir por threat hace que el
--     noclipper que te persigue "ocupe" más espacio que el tipo parado, así que entre
--     dos rutas igual de libres se elige la que no pasa cerca de él.
--   t = 0 -> ahora mismo: contra la posición anticipada (o.p).
--   t > 0 -> encuentro FUTURO: se proyecta desde la posición REAL (o.r), nunca desde
--            la anticipada. Si no, la predicción se aplicaría dos veces y una ruta
--            que te lleva contra el atacante puntuaría bien ("ya habrá pasado").
local function scoreAt(pos, t)
    local best = math.huge
    for _, o in ipairs(_others) do
        local ox, oz
        if t and t > 0 then
            ox = o.r.X + o.v.X * t
            oz = o.r.Z + o.v.Z * t
        else
            ox, oz = o.p.X, o.p.Z
        end
        local m = (Vector3.new(pos.X - ox, 0, pos.Z - oz).Magnitude + o.bias) / o.threat
        if m < best then best = m end
    end
    return best
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

-- ★ v8.0 · buffers reusados: las 16 direcciones son fijas y la tabla de puntajes se
-- recicla. v7.x alocaba 16 Vector3 + 17 tablas en CADA llamada (y se llama varias
-- veces por frame) → basura constante para el GC, que en Roblox se paga en hitches.
local _dirs = {}
for i = 0, SMART.DIRS - 1 do
    local a = (i / SMART.DIRS) * math.pi * 2
    _dirs[i + 1] = Vector3.new(math.cos(a), 0, math.sin(a))
end
local _scored = {}
for i = 1, SMART.DIRS do _scored[i] = { dir = _dirs[i], score = 0 } end

-- Muestrea SMART.DIRS direcciones y elige la mejor ruta de escape:
--   · puntúa qué tan lejos te deja de TODOS (no solo del más cercano)
--   · puntúa a MEDIO y FINAL de la ruta, con los otros ya movidos (predicción):
--     una ruta que hoy parece libre pero te cruza con el que viene, puntúa mal
--   · ★ v8.0: `look` y horizonte hablan del MISMO instante (ver abajo)
--   · bonus a la repulsión natural (seed) y al rumbo anterior (anti-zigzag)
--   · de mejor a peor, la primera sin pared gana (máx WALL_TRIES raycasts)
-- `speed` en studs/s. Devuelve dir, clear. clear=false => todo bloqueado, el caller
-- activa noclip.
local function bestEscapeDir(myPos, seed, speed)
    -- ★ v8.0 · COHERENCIA TEMPORAL: v7.x proyectaba TU ruta 4 pasos (≈0.07s a 60fps)
    -- pero movía a los otros SMART.HORIZON (0.35s). Las dos mitades del scoring
    -- comparaban instantes distintos, así que "dónde estaré yo" y "dónde estarán
    -- ellos" no eran el mismo momento. Ahora `look` manda y el horizonte se deriva
    -- de él: si vas a 300 studs/s, 40 studs SON 0.13s, y con eso se mueven ellos.
    local look  = math.clamp(speed * SMART.HORIZON, 8, SMART.LOOK_MAX)
    local hz    = look / math.max(speed, 1)
    local seedU = (seed and seed.Magnitude > 0.05) and seed.Unit or nil

    for i = 1, SMART.DIRS do
        local dir = _dirs[i]
        -- el peor momento de la ruta manda: así se descartan las que te cruzan por delante
        local sMid = scoreAt(myPos + dir * (look * 0.5), hz * 0.5)
        local sEnd = scoreAt(myPos + dir * look,          hz)
        local s    = math.min(sMid, sEnd)
        if seedU         then s = s + dir:Dot(seedU) * SMART.SEED_W end
        if lastEscapeDir then s = s + dir:Dot(lastEscapeDir) * SMART.SMOOTH_W end
        local e = _scored[i]
        e.dir, e.score = dir, s
    end
    table.sort(_scored, function(x, y) return x.score > y.score end)
    for i = 1, math.min(SMART.WALL_TRIES, SMART.DIRS) do
        if pathClear(myPos, _scored[i].dir) then return _scored[i].dir, true end
    end
    return _scored[1] and _scored[1].dir or nil, false
end

-- ★ Paso mínimo a lo largo de `dir` que te deja a `need` studs de todos.
-- Es el corazón del suelo duro: no "empuja y reza", calcula lo que hace falta.
-- ★ v8.0: mide en 3D (es contacto físico) y NO se escala por dt — no es una
-- velocidad sino una corrección de posición: "cuánto me falta para salir" es
-- geométrico, igual a 30 que a 144 fps, y se auto-limita (al salir, deja de dispararse).
local function pushOutStep(myPos, dir, need)
    for k = 1, CONTACT.PROBES do
        local t = (k / CONTACT.PROBES) * CONTACT.MAX_STEP
        if nearest3D(myPos + dir * t) >= need then return t end
    end
    return CONTACT.MAX_STEP
end

local function computeAnchorTarget()
    local clear = ANCHOR.CLEAR_DIST
    if activeMode then
        clear = math.max(clear, math.min(modeSafeDistance(activeMode), ANCHOR.RADIUS))
    end

    if nearestThreat(home) >= clear then
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
    if nearestThreat(cand) >= clear * 0.75 then
        return cand, true
    end

    local best, bestScore = cand, nearestThreat(cand)
    local r = math.min(clear, ANCHOR.RADIUS)
    for i = 0, 11 do
        local a = (i / 12) * math.pi * 2
        local p = Vector3.new(home.X + math.cos(a) * r, home.Y, home.Z + math.sin(a) * r)
        local score = nearestThreat(p)
        if score > bestScore then best, bestScore = p, score end
    end
    return best, true
end

-- ════════════ NO CLIP AUTO (atravesar paredes solo cuando topas) ════════════
-- ★ v8.0: las partes propias van cacheadas. v7.x llamaba char:GetDescendants() en
-- CADA frame de noclip (una tabla nueva por frame, y el noclip puede durar segundos).
-- El TTL corto cubre lo que aparezca después (accesorios, tools).
local _myParts, _myPartsChar, _myPartsT = {}, nil, 0
local function myParts(char)
    local now = os.clock()
    if _myPartsChar ~= char or (now - _myPartsT) > 2 then
        table.clear(_myParts)
        for _, p in ipairs(char:GetDescendants()) do
            if p:IsA("BasePart") then _myParts[#_myParts + 1] = p end
        end
        _myPartsChar, _myPartsT = char, now
    end
    return _myParts
end

local function noclipStep()
    if not sessionAlive() then return end
    local char = LocalPlayer.Character
    if not char then return end
    if os.clock() < noclipUntil then
        for _, p in ipairs(myParts(char)) do
            if p.Parent and p.CanCollide then
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
    -- ★★ v8.0 · MÉTRICA 3D REAL ★★
    -- Acá vivía el peor bug de v7.1: esto preguntaba "¿me está tocando alguien?" con
    -- una medida HORIZONTAL, así que un flyer 100 studs sobre tu cabeza contestaba
    -- "sí, a 0 studs" y esta función —prioridad 0, no negocia— te arrastraba por el
    -- mapa activando noclip, sin que nadie te hubiera tocado nunca. El contacto es 3D.
    local d, away = nearest3D(myPos)
    if d >= CONTACT.HARD_R then return false end

    local need = CONTACT.HARD_R + CONTACT.BUFFER
    -- ruta inteligente incluso en emergencia (si hay pared, la atravesamos).
    -- `away` puede venir nil si está justo encima/debajo: el cerebro elige solo.
    local dir, clear = bestEscapeDir(myPos, away, CONTACT.ESCAPE_V)
    dir = dir or away
    if not dir then return false end
    if not clear then noclipUntil = os.clock() + 0.3 end

    local step = pushOutStep(myPos, dir, need)
    local destPos, finalY = resolveMove(myPos, dir * step)
    root.CFrame = CFrame.new(destPos.X, finalY, destPos.Z)
                * CFrame.Angles(0, math.rad(root.Orientation.Y), 0)

    -- deja el cerebro alineado con lo que acaba de pasar (sin latigazo al frame siguiente)
    evading       = true
    lastEscapeDir = dir
    speedSmooth   = CONTACT.ESCAPE_V
    return true
end

-- ════════════ RADIO DE PRE-DETECCIÓN (solo lectura + preparación) ════════════
-- ⚠ Este bloque NO mueve al personaje. Nunca. Solo observa y deja la ruta lista.
-- (preRadius() se define arriba: el recorte espacial lo necesita antes que esto)
local function updatePreDetect(myPos, now)
    if not preOn then
        preAlert, preCount, preNearest, preClosing, preTag, preparedDir =
            false, 0, math.huge, 0, nil, nil
        return
    end

    local radius  = preRadius()
    local count   = 0
    local nearest = math.huge
    local closing = 0
    local tag     = nil
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
                tag     = describeFlags(o)   -- ★ v8.0: QUÉ es, no solo cuántos hay
            end
        end
    end

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
    preTag     = tag

    -- ★ Preparación (no acción): deja la ruta ya resuelta para que el radio principal
    -- reaccione en el frame 0 en vez de gastar el primer frame decidiendo.
    -- Solo si el sistema está al mando: en idle no gastamos ni un raycast.
    if (activeMode or anchored) and preAlert and count > 0 and not evading
       and (now - _lastArm) >= PRE.ARM_HZ then
        _lastArm = now
        local spd = activeMode and MODES[activeMode].MAX_SPEED or ANCHOR.MAX_SPEED
        preparedDir = bestEscapeDir(myPos, seed, spd)
    end
end

-- ════════════ BUCLE PRINCIPAL ════════════
local _lastFrameT = os.clock()
local function mainHeartbeat(dtRaw)
    if not sessionAlive() then selfDestruct() return end
    pcall(function()
        local char = LocalPlayer.Character
        if not char then return end
        local root = char:FindFirstChild("HumanoidRootPart")
        if not root then return end
        local myPos = root.Position
        local vel   = root.AssemblyLinearVelocity

        -- ★★ v8.0 · dt REAL Y ACOTADO ★★
        -- Todo el movimiento pasa a studs/segundo. v7.x movía studs/FRAME: el mismo
        -- tool corría a 150 studs/s en un móvil de 30fps y a 720 en un PC de 144, así
        -- que ninguna constante servía para ambos. El techo (DT_MAX) evita que un lag
        -- spike se traduzca en un salto de 150 studs en un frame.
        local now = os.clock()
        local dt  = math.clamp(dtRaw or (now - _lastFrameT), 1/240, DT_MAX)
        _lastFrameT = now

        refreshFrameCache(myPos, dt, now)
        updateRing(root)             -- anillo de rango: sigue al personaje (barato: 1 CFrame/frame)
        updatePreDetect(myPos, now)  -- 2º radio: informa y prepara, NO mueve

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
        -- ★ v7.2 FIX (bug reportado: "tarda en volver"): antes solo tiraba de
        -- vuelta si el ancla estaba disputada O si salías del ANCHOR.RADIUS.
        -- Con radios grandes (More = 125) podías quedar 100 studs del ancla,
        -- sin nadie cerca, y no te movía nunca. Ahora siempre regresa a target
        -- (que sin amenaza = home). La DEADZONE evita el temblor en el sitio.
        if anchored and home then
            local target, _ = computeAnchorTarget()

            local push    = Vector3.new(target.X - myPos.X, 0, target.Z - myPos.Z)
            local maxStep = ANCHOR.MAX_SPEED * dt   -- ★ v8.0: studs/s → studs este frame
            if push.Magnitude < ANCHOR.DEADZONE then return end
            if push.Magnitude > maxStep then push = push.Unit * maxStep end

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
        -- ★ v8.0: el trigger usa la métrica de AMENAZA pura (XZ + bias vertical), sin
        -- ponderar por comportamiento. Los flags no deciden SI evadís — solo hacia dónde.
        local nearest = nearestThreat(myPos)

        -- histéresis: al evadir seguimos hasta safe*EXIT_FACTOR (no titubea en el borde)
        local trigger = evading and (safeD * SMART.EXIT_FACTOR) or safeD
        if nearest >= trigger then
            evading, lastEscapeDir, stuckTime, lastFramePos = false, nil, 0, nil
            speedSmooth = 0
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

        -- repulsión clásica: semilla de dirección + medida de fuerza (ahora en studs/s)
        local totalPush = Vector3.zero
        for _, o in ipairs(_others) do
            local flat = Vector3.new(myPos.X - o.p.X, 0, myPos.Z - o.p.Z)
            local dist = flat.Magnitude + o.bias
            if dist < trigger and flat.Magnitude > 0.1 then
                totalPush = totalPush + flat.Unit * ((1 - dist / trigger) * config.MAX_SPEED)
            end
        end

        -- velocidad deseada: aunque la repulsión se cancele (flanqueado) hay que moverse.
        -- MIN_V (21 studs/s) es el viejo mínimo de 0.35 studs/frame a 60fps.
        local MIN_V = 21
        local wantSpeed = math.min(totalPush.Magnitude, config.MAX_SPEED)
        if wantSpeed < MIN_V then
            wantSpeed = math.max(MIN_V, (1 - nearest / trigger) * config.MAX_SPEED)
        end
        -- con urgencia alta la velocidad puede pasarse del MAX_SPEED del modo: es lo que
        -- evita que un corredor más rápido que tú te alcance.
        if urgency > 0 then
            wantSpeed = wantSpeed + (CONTACT.ESCAPE_V - wantSpeed) * (urgency * urgency)
        end

        -- ★ rampa: acelera y frena progresivo (nada de saltos de 0 a full de golpe).
        -- ★ v8.0: exponencial por constante de tiempo en vez de un factor por frame.
        -- El viejo `x += (want-x) * 0.35` aplicaba 0.35 por FRAME, así que a 144fps la
        -- rampa era 2,4× más rápida que a 60. Con tau + dt la curva es la misma en
        -- cualquier máquina. En urgencia tau colapsa: la seguridad manda sobre la estética.
        local tau = (wantSpeed > speedSmooth) and SMOOTH.RISE_TAU or SMOOTH.FALL_TAU
        tau = math.max(tau * (1 - urgency), 1e-4)
        speedSmooth = speedSmooth + (wantSpeed - speedSmooth) * (1 - math.exp(-dt / tau))

        local moveSpeed = math.max(speedSmooth, MIN_V)
        local stepLen   = moveSpeed * dt

        -- elegir la MEJOR ruta (no la más obvia): escapa de flanqueos, esquiva paredes
        local dir, clear = bestEscapeDir(myPos, totalPush, moveSpeed)
        if not dir then return end
        if not clear then
            noclipUntil = now + 0.25
        end

        -- ★ giro limitado (anti-latigazo). El límite se abre con la urgencia.
        -- ★ v8.0: grados/s × dt = lo que puede girar ESTE frame (antes: grados/frame,
        -- o sea 2,4× más latigazo en un monitor de 144Hz que en uno de 60).
        local maxTurn = (SMOOTH.TURN_MAX + (SMOOTH.TURN_PANIC - SMOOTH.TURN_MAX) * urgency) * dt
        dir = limitTurn(lastEscapeDir, dir, maxTurn)

        -- anti-atasco: ordenamos movernos pero seguimos en el mismo sitio.
        -- ★ v8.0: se mide en SEGUNDOS (antes 6 frames = 0.1s a 60fps, 0.2s a 30, 0.04s a 144).
        if lastFramePos and (myPos - lastFramePos).Magnitude < stepLen * 0.25 then
            stuckTime = stuckTime + dt
            if stuckTime >= SMART.STUCK_TIME then
                noclipUntil   = now + 0.35
                lastEscapeDir = nil     -- re-decidir ruta desde cero
                stuckTime     = 0
            end
        else
            stuckTime = 0
        end
        lastFramePos  = myPos
        lastEscapeDir = dir

        local destPos, finalY = resolveMove(myPos, dir * stepLen)

        -- ★ RED FINAL: si el destino calculado aún deja a alguien dentro del suelo duro,
        -- se alarga el paso lo justo para salir. El movimiento nunca termina en contacto.
        -- (3D, igual que hardFloorStep: las dos puertas del contacto miden lo mismo)
        local need = CONTACT.HARD_R + CONTACT.BUFFER
        if nearest3D(destPos) < CONTACT.HARD_R then
            local ext = pushOutStep(myPos, dir, need)
            destPos, finalY = resolveMove(myPos, dir * math.max(ext, stepLen))
            noclipUntil = now + 0.25
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
        evading, lastEscapeDir, stuckTime, lastFramePos = false, nil, 0, nil
        speedSmooth = 0
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
            -- ★ v8.0: qué es lo más cercano (noclip/teleport/te sigue/veloz/vuela/invisible).
            -- Solo texto: la capa de comportamiento no mueve nada.
            if preTag then txt = txt .. " · " .. preTag end
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
    evading, lastEscapeDir, stuckTime, lastFramePos = false, nil, 0, nil
    speedSmooth = 0
    preAlert, preCount, preNearest, preClosing, preTag, preparedDir =
        false, 0, math.huge, 0, nil, nil
    table.clear(_tracks)   -- ★ v8.0: los tracks se rehacen solos en el próximo frame
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

print("KEEP DISTANCE v8.0 cargado · SUELO DURO 3D (" .. CONTACT.HARD_R .. " studs · los que vuelan encima ya no te empujan) · movimiento en studs/s (igual en móvil que en PC) · velocidad estimada a cualquier fps · CAPA DE COMPORTAMIENTO (noclip/teleport/te sigue/veloz/vuela: priorizan e informan, nunca mueven) · recorte espacial · ghost " .. DETECT.HOLD_TIME .. "s + huérfanos · filtro vertical asimétrico (abajo " .. DETECT.VERT_DOWN .. ", arriba progresivo desde " .. DETECT.VERT_UP_SOFT .. ") · PRE-DETECCIÓN · Air Walk safe.")
