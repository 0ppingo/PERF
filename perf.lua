--> Overdrive H On Top.
--> PERFORMANCE OPTIMIZER v6 — plugin independente para o ODH
--[[
  Tudo LOCAL ao seu cliente (nada replica): não toca personagem, Tools, rede, ownership,
  física, colisão nem ScreenGuis do jogo.

  v6 — CORTAR O QUE ESTÁ LONGE DE VERDADE
  1) CULLING POR PROXIMIDADE E TAMANHO NA TELA (o "contar pixels"):
     - Cada parte decorativa recebe um alcance de visibilidade = tamanho * (500 / pixelMin),
       limitado ao alcance máximo. Peça pequena some mais cedo; peça grande vai mais longe.
     - Custo proporcional ao que está PERTO, não ao mapa inteiro: usa
       Workspace:GetPartBoundsInRadius (consulta espacial do motor) e só compara as peças
       próximas. Só roda quando a câmera andou, e só ESCREVE quando a peça cruza o limite.
     - Parte oculta = LocalTransparencyModifier 1 + sem sombra (peça invisível ainda projeta
       sombra, segundo a documentação do Roblox).
  2) EFEITOS: modo "Distantes" (por proximidade, inclui efeitos em objetos móveis) ou "Todos"
     (desliga qualquer efeito, exceto em personagens, Tools e itens interativos/coletáveis).
  3) FLAGS DO ENGINE via executor (setfflag/getfflag), só da allowlist oficial e só flags DF
     (dinâmicas, que o motor relê): distância de LOD de geometria, qualidade de textura e
     nível FRM (alcance de render). Se o executor não tiver setfflag, o plugin avisa e a seção
     Ajuda traz o JSON para colocar via FastStrap/RbxFPS (Shizuku).
  4) Terreno agora diz exatamente o que mudou (ou por que nada mudou).

  Segurança: tudo guarda o original e restaura; globais arriscados têm TESTE de 20 s (voltam
  sozinhos se você não confirmar); o culling se desliga sozinho se ficar caro.
  Exclusões (nunca tocados): personagens/NPCs (Humanoid), Tools, Accessories, câmera, itens não
  ancorados (no culling de partes), partes com ProximityPrompt/ClickDetector/TouchTransmitter/Gui,
  tags, atributos, CanQuery desligado e nomes da lista BLOCK_KEYWORDS.
]]

local shared = odh_shared_plugins

----------------------------------------------------------------------
-- 0. Re-execução segura: limpa a instância anterior antes de começar
----------------------------------------------------------------------
local GKEY = "__ODH_PERF_OPT_CLEANUP"
do
	local okG, g = pcall(function() return _G end)
	if okG and type(g) == "table" and type(g[GKEY]) == "function" then
		pcall(g[GKEY])
		g[GKEY] = nil
	end
end

local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local clock = os.clock
local mathMin, mathMax, mathFloor = math.min, math.max, math.floor
local lower = string.lower
local WEAK = { __mode = "k" }

local function notify(msg, dur)
	pcall(function() shared.Notify(msg, dur or 3) end)
end

------------------------------------------------------------------
-- 1. CONFIGURAÇÃO E PERFIS
------------------------------------------------------------------
local ICON_PATH = "/0ppingo/PERF/refs/heads/main/icon"

local cfg = {
	shadowMax = 8,         -- partes com maior dimensão <= isto perdem a sombra (studs)
	cullFar = 250,         -- alcance MÁXIMO de renderização das peças decorativas (studs)
	minPx = 8,             -- tamanho mínimo na tela (px): abaixo disso a peça some
	fxRange = 120,         -- alcance dos efeitos no modo "Distantes" (studs)
	fxMode = "Distantes",  -- "Distantes" ou "Todos"
	hideCollidable = false,
	lodMode = "Automatic",
	lodDist = 150,         -- flag CSG LOD (studs)
	texLevel = 1,          -- flag qualidade de textura: 1 baixa, 2 média
	frmLevel = 4,          -- flag nível FRM (1..10)
	qualityLevel = 3,      -- nível gráfico fixo 1..10
	fpsCap = 30,
	sliceMs = 1.5,
}

local PROFILES = {
	LOW = {
		cfg = { shadowMax = 4, cullFar = 400, minPx = 6, fxRange = 200, fxMode = "Distantes",
			hideCollidable = false, lodMode = "Automatic", sliceMs = 1.2 },
		features = { lights = true, fx = true },
	},
	MEDIUM = {
		cfg = { shadowMax = 8, cullFar = 300, minPx = 6, fxRange = 150, fxMode = "Distantes",
			hideCollidable = false, lodMode = "Automatic", sliceMs = 1.5 },
		features = { lights = true, fx = true, shadows = true, lod = true, hide = true },
	},
	AGGRESSIVE = {
		cfg = { shadowMax = 30, cullFar = 180, minPx = 12, fxRange = 80, fxMode = "Distantes",
			hideCollidable = true, lodMode = "Performance", sliceMs = 2 },
		features = {
			lights = true, fx = true, shadows = true, lod = true, decals = true, hide = true,
			hidecol = true, gshadows = true, terrain = true,
		},
	},
}

local FEATURE_ORDER = {
	"hidecol", "shadows", "lights", "lod", "fx", "decals", "hide",
	"gshadows", "terrain", "quality", "technology", "fpscap", "ffgeo", "fftex", "fffrm",
}
-- manuais: perfis não mexem (dependem do executor ou mudam o gráfico inteiro)
local MANUAL = { quality = true, technology = true, fpscap = true, ffgeo = true, fftex = true, fffrm = true }

local PART_CLASSES = { Part = true, MeshPart = true, UnionOperation = true, WedgePart = true, CornerWedgePart = true }
local LIGHT_CLASSES = { PointLight = true, SpotLight = true, SurfaceLight = true }
local EMITTER_CLASSES = { ParticleEmitter = true, Fire = true, Smoke = true, Sparkles = true, Trail = true, Beam = true }
local DECAL_CLASSES = { Decal = true, Texture = true }

-- Nomes que indicam função/coletável/interativo: nunca são tocados. Edite à vontade.
local BLOCK_KEYWORDS = {
	"coin", "token", "collect", "pickup", "orb", "gem", "loot", "drop", "reward", "crate",
	"chest", "spawn", "portal", "teleport", "door", "button", "prompt", "click", "shop",
	"npc", "tool", "weapon", "boss", "enemy", "mob", "heal", "powerup", "cash", "money",
	"fruit", "egg", "hitbox", "trigger", "damage", "kill", "lava", "interact", "item",
	"checkpoint", "goal", "finish", "target", "bomb", "projectile", "bullet", "ball",
	"key", "seat", "vehicle", "star", "gift", "present", "candies2026",
}

local MAX_PENDING = 20000
local MIN_WAIT, MAX_WAIT = 0.04, 0.4
local QUIET_SECONDS = 1.0
local FORCE_AFTER = 4
local STALL_SLACK = 0.25
local TRIAL_SECONDS = 20
local HIDE_MAX = 60           -- partes maiores que isso (chão, paredes enormes) nunca são ocultadas
local MIN_HIDE_SIZE = 4       -- partes SEM colisão menores que isso podem ser coletáveis: não oculta
local CULL_MIN = 25           -- nada some a menos de 25 studs
local QUERY_MAX = 3000        -- MaxParts da consulta espacial (se estourar, só mostra; nunca oculta)
local HIDE_CAP, SHOW_CAP = 200, 600
local MOVE_STUDS = 5          -- câmera precisa andar isso para recalcular
local MOB_MAX = 600

local conns = {}
local toggles, uiState, handlers = {}, {}, {}
local currentProfile = nil
local statusP = nil
local applyingProfile = false
local suppressTrial = false

------------------------------------------------------------------
-- 2. FEATURES (original guardado em tabela de chave FRACA: sem vazamento)
------------------------------------------------------------------
local function newFeature(key, label, short, prop, target)
	return {
		key = key, label = label, short = short, prop = prop, target = target,
		enabled = false, paused = false, orig = setmetatable({}, WEAK), mods = 0, gen = 0,
	}
end

local F = {
	shadows = newFeature("shadows", "Sombras de partes pequenas", "sombras", "CastShadow", false),
	lights = newFeature("lights", "Luzes sem sombra", "luzes", "Shadows", false),
	lod = newFeature("lod", "LOD (RenderFidelity)", "LOD", "RenderFidelity", Enum.RenderFidelity.Automatic),
	fx = newFeature("fx", "Efeitos (partículas, fogo, trilhas, feixes)", "efeitos", "Enabled", false),
	decals = newFeature("decals", "Texturas/Decals decorativos", "texturas", "Transparency", 1),
	hide = newFeature("hide", "Ocultar 3D distante (alcance + pixels)", "ocultos", "LocalTransparencyModifier", 1),
	hcast = newFeature("hcast", "(sombra dos ocultos)", "", "CastShadow", false),
}
local INDEX = { F.shadows, F.lights, F.lod, F.fx, F.decals, F.hide, F.hcast }

local function getProp(inst, prop) return inst[prop] end
local function setProp(inst, prop, value) inst[prop] = value end

local function applyMod(f, inst)
	if f.orig[inst] ~= nil then return end -- idempotente: nunca sobrescreve o original salvo
	local ok, cur = pcall(getProp, inst, f.prop)
	if not ok or cur == nil or cur == f.target then return end
	if f.key == "decals" and type(cur) == "number" and cur >= 1 then return end
	if f.key == "hide" and type(cur) == "number" and cur >= 1 then return end
	if pcall(setProp, inst, f.prop, f.target) then
		f.orig[inst] = cur
		f.mods = f.mods + 1
	end
end

local function restoreMod(f, inst)
	local o = f.orig[inst]
	if o == nil then return end
	f.orig[inst] = nil
	f.mods = mathMax(0, f.mods - 1)
	local ok, cur = pcall(getProp, inst, f.prop)
	-- se o jogo mudou o valor depois de nós, não brigamos com ele
	if ok and cur == f.target then pcall(setProp, inst, f.prop, o) end
end

local function snapshotKeys(f)
	local keys, n = {}, 0
	for inst in pairs(f.orig) do
		n = n + 1
		keys[n] = inst
	end
	return keys, n
end

local function restoreAllSync(f)
	f.gen = f.gen + 1
	for inst in pairs(f.orig) do restoreMod(f, inst) end -- atribuir nil a chave existente durante pairs é permitido
	f.mods = 0
end

-- Restauração em pedaços (sem spike). Se o recurso for religado no meio, aborta com segurança.
local function restoreChunked(f, onDone)
	f.gen = f.gen + 1
	local g = f.gen
	local keys, n = snapshotKeys(f)
	task.spawn(function()
		for i = 1, n do
			if f.gen ~= g then return end
			restoreMod(f, keys[i])
			keys[i] = nil
			if i % 100 == 0 then task.wait() end
		end
		if f.gen == g and onDone then onDone() end
	end)
end

------------------------------------------------------------------
-- 3. CLASSIFICAÇÃO CONSERVADORA (cacheada)
------------------------------------------------------------------
local nameCache, nameCount = {}, 0
local function nameBlocked(name)
	local c = nameCache[name]
	if c == nil then
		c = false
		local l = lower(name)
		for i = 1, #BLOCK_KEYWORDS do
			if string.find(l, BLOCK_KEYWORDS[i], 1, true) then c = true; break end
		end
		if nameCount > 5000 then nameCache, nameCount = {}, 0 end
		nameCache[name] = c
		nameCount = nameCount + 1
	end
	return c
end

local function directInteractive(inst)
	return inst:FindFirstChildOfClass("ProximityPrompt") ~= nil
		or inst:FindFirstChildOfClass("ClickDetector") ~= nil
		or inst:FindFirstChildOfClass("TouchTransmitter") ~= nil
		or inst:FindFirstChildOfClass("BillboardGui") ~= nil
		or inst:FindFirstChildOfClass("SurfaceGui") ~= nil
end

local function partInteractive(part)
	if directInteractive(part) then return true end
	return part:FindFirstChildWhichIsA("ProximityPrompt", true) ~= nil
		or part:FindFirstChildWhichIsA("LayerCollector", true) ~= nil
end

local ancCache = setmetatable({}, WEAK)
local function ancestorBlocked(a)
	if a:IsA("Tool") or a:IsA("Accoutrement") or a:IsA("Camera") then return true end
	if a:IsA("Model") and (a:FindFirstChildOfClass("Humanoid") or Players:GetPlayerFromCharacter(a)) then
		return true
	end
	if nameBlocked(a.Name) then return true end
	return directInteractive(a)
end

local function ancestorsSafe(a)
	local depth = 0
	while a and a ~= Workspace do
		local c = ancCache[a]
		if c == nil then
			c = ancestorBlocked(a)
			ancCache[a] = c
		end
		if c then return false end
		a = a.Parent
		depth = depth + 1
		if depth > 40 then return false end
	end
	return a == Workspace
end

local function isStaticDecorative(part)
	if nameBlocked(part.Name) or partInteractive(part) then return false end
	if #part:GetTags() > 0 or next(part:GetAttributes()) ~= nil then return false end
	return ancestorsSafe(part.Parent)
end

local function hostSafe(par)
	if par == nil then return false end
	if par:IsA("Attachment") then par = par.Parent end
	if par == nil or not par:IsA("BasePart") then return false end
	return ancestorsSafe(par.Parent)
end

local function maxDim(part)
	local s = part.Size
	return mathMax(s.X, s.Y, s.Z)
end

local function hideSizeOk(part)
	local m = maxDim(part)
	if m > HIDE_MAX then return false end
	if not part.CanCollide and m < MIN_HIDE_SIZE then return false end
	return true
end

local function ownerPart(e)
	local p = e.Parent
	if not p then return nil end
	if p:IsA("BasePart") then return p end
	if p:IsA("Attachment") then
		local pp = p.Parent
		if pp and pp:IsA("BasePart") then return pp end
	end
	return nil
end

local function on(f) return f.enabled and not f.paused end

------------------------------------------------------------------
-- 4. ESTADO DO CULLING POR PROXIMIDADE
------------------------------------------------------------------
local function newProxHide()
	return {
		cand = setmetatable({}, WEAK), rad = setmetatable({}, WEAK),
		nearSet = setmetatable({}, WEAK), seen = setmetatable({}, WEAK),
	}
end
local function newProxFx()
	return {
		host = setmetatable({}, WEAK), known = setmetatable({}, WEAK),
		near = setmetatable({}, WEAK), seen = setmetatable({}, WEAK),
		mobE = {}, mobH = {}, mobN = 0,
	}
end

local ph, pf = newProxHide(), newProxFx()
local prox = { running = false, id = 0, interval = 0.5, stamp = 0, lastCam = nil, dirty = true, params = nil, errors = 0, over = 0 }
local camX, camY, camZ, camOk = 0, 0, 0, false

local function readCam()
	local cam = Workspace.CurrentCamera
	if cam then
		local p = cam.CFrame.Position
		camX, camY, camZ, camOk = p.X, p.Y, p.Z, true
	end
end

local function pxK() return 500 / mathMax(cfg.minPx, 1) end

local function hidePart(p)
	applyMod(F.hide, p)
	applyMod(F.hcast, p)
end

local function unhidePart(p)
	restoreMod(F.hide, p)
	restoreMod(F.hcast, p)
end

local function fxHostApply(h, disable)
	local arr = pf.host[h]
	if not arr then return end
	local j, n = 0, #arr
	for i = 1, n do
		local e = arr[i]
		if e.Parent ~= nil then
			j = j + 1
			arr[j] = e
			if disable then applyMod(F.fx, e) else restoreMod(F.fx, e) end
		end
	end
	for i = j + 1, n do arr[i] = nil end
end

local function distSq(p)
	local pos = p.Position
	local dx, dy, dz = pos.X - camX, pos.Y - camY, pos.Z - camZ
	return dx * dx + dy * dy + dz * dz
end

------------------------------------------------------------------
-- 5. REGISTRO (varredura/eventos)
------------------------------------------------------------------
local function registerFx(inst)
	if not on(F.fx) or pf.known[inst] or not inst.Enabled then return end
	if nameBlocked(inst.Name) then return end
	local host = ownerPart(inst)
	if not host or not hostSafe(inst.Parent) or nameBlocked(host.Name) or partInteractive(host) then return end
	pf.known[inst] = true
	if cfg.fxMode == "Todos" then
		applyMod(F.fx, inst)
		return
	end
	local r = cfg.fxRange
	if host.Anchored and host.CanQuery then
		local arr = pf.host[host]
		if not arr then
			arr = {}
			pf.host[host] = arr
		end
		arr[#arr + 1] = inst
		if camOk and distSq(host) > r * r then
			applyMod(F.fx, inst)
		else
			pf.near[host] = true
		end
	else
		-- host móvel (ou fora da consulta espacial): lista pequena, posição lida ao vivo
		if pf.mobN < MOB_MAX then
			local n = pf.mobN + 1
			pf.mobN = n
			pf.mobE[n], pf.mobH[n] = inst, host
			if camOk and distSq(host) > r * r then applyMod(F.fx, inst) end
		end
	end
end

local function register(inst)
	local cn = inst.ClassName
	if PART_CLASSES[cn] then
		local wantS = on(F.shadows) and inst.CastShadow and maxDim(inst) <= cfg.shadowMax
		local wantL = on(F.lod) and cn == "MeshPart" and inst.RenderFidelity ~= F.lod.target
		local wantH = on(F.hide) and not ph.cand[inst] and inst.Transparency < 1
			and (cfg.hideCollidable or not inst.CanCollide) and hideSizeOk(inst) and inst.CanQuery
		if not (wantS or wantL or wantH) then return end
		if not inst.Anchored or not isStaticDecorative(inst) then return end
		if wantS then applyMod(F.shadows, inst) end
		if wantL then applyMod(F.lod, inst) end
		if wantH then
			local r = mathMin(cfg.cullFar, mathMax(CULL_MIN, maxDim(inst) * pxK()))
			ph.cand[inst], ph.rad[inst] = true, r
			if camOk and distSq(inst) > r * r then
				hidePart(inst)
			else
				ph.nearSet[inst] = true
			end
		end
	elseif LIGHT_CLASSES[cn] then
		if on(F.lights) and inst.Shadows and hostSafe(inst.Parent) then applyMod(F.lights, inst) end
	elseif EMITTER_CLASSES[cn] then
		registerFx(inst)
	elseif DECAL_CLASSES[cn] then
		if not on(F.decals) or inst.Transparency >= 1 then return end
		local owner = inst.Parent
		if owner and PART_CLASSES[owner.ClassName] and owner.Anchored and isStaticDecorative(owner) then
			applyMod(F.decals, inst)
		end
	end
end

local function handle(inst)
	local cn = inst.ClassName
	if PART_CLASSES[cn] or LIGHT_CLASSES[cn] or EMITTER_CLASSES[cn] or DECAL_CLASSES[cn] then register(inst) end
end

------------------------------------------------------------------
-- 6. TRABALHO ÚNICO EM FATIAS (varredura) + FILA COM "SILÊNCIO"
------------------------------------------------------------------
local scan = { top = nil, ti = 1, tn = 0, arr = nil, i = 1, n = 0, active = false, requested = false, waitingLoad = false }
local pend = { head = 1, tail = 0, items = {}, lastAdd = 0, firstAt = 0 }
local worker = { running = false, scheduled = false, id = 0, wait = MIN_WAIT, errors = 0, stalls = 0, lastStatus = 0 }
local idxActive = false
local refreshStatus, disableAll, ensureProx

local function workPending()
	return scan.active or pend.head <= pend.tail
end

local function drainPending(deadline)
	local p = pend
	local cnt = 0
	while p.head <= p.tail do
		local inst = p.items[p.head]
		p.items[p.head] = nil
		p.head = p.head + 1
		if inst.Parent ~= nil then handle(inst) end
		cnt = cnt + 1
		if cnt % 8 == 0 and clock() > deadline then break end
	end
	if p.head > p.tail then p.head, p.tail = 1, 0 end
end

local function nextChunk()
	local cam = Workspace.CurrentCamera
	while scan.ti <= scan.tn do
		local c = scan.top[scan.ti]
		scan.top[scan.ti] = nil
		scan.ti = scan.ti + 1
		local cn = c.ClassName
		if c ~= cam and cn ~= "Terrain" and c.Parent ~= nil
			and not (cn == "Model" and c:FindFirstChildOfClass("Humanoid")) then
			handle(c)
			local d = c:GetDescendants()
			scan.arr, scan.i, scan.n = d, 1, #d
			return true
		end
	end
	return false
end

local function sliceStep(deadline)
	readCam()
	local timeUp = false
	while scan.active and not timeUp do
		if not scan.arr then
			if not nextChunk() then
				scan.active, scan.top = false, nil
				break
			end
		end
		local arr, i, n = scan.arr, scan.i, scan.n
		local cnt = 0
		while i <= n do
			local inst = arr[i]
			arr[i] = nil
			i = i + 1
			if inst.Parent ~= nil then handle(inst) end
			cnt = cnt + 1
			if cnt % 16 == 0 and clock() > deadline then
				timeUp = true
				break
			end
		end
		scan.i = i
		if i > n then scan.arr = nil end
	end
	if not scan.active or clock() < deadline then drainPending(deadline) end
end

local function ensureWorker()
	if worker.running then return end
	worker.running = true
	worker.id = worker.id + 1
	local my = worker.id
	task.spawn(function()
		while worker.id == my do
			local t0 = clock()
			local slice = cfg.sliceMs
			if worker.stalls > 0 then slice = slice * 0.5 end
			local ok, err = pcall(sliceStep, t0 + slice / 1000)
			if ok then
				worker.errors = 0
			else
				worker.errors = worker.errors + 1
				print("[Perf] erro: " .. tostring(err))
				if worker.errors >= 5 then
					worker.errors = 0
					worker.running = false
					notify("Otimizador parado por erros repetidos (tudo restaurado). Veja o console.", 6)
					disableAll()
					return
				end
			end
			local spent = clock() - t0
			if spent > slice / 1000 * 3 then
				worker.wait = mathMin(worker.wait * 1.5, MAX_WAIT)
			else
				worker.wait = mathMax(worker.wait * 0.95, MIN_WAIT)
			end
			if t0 - worker.lastStatus >= 1 then
				worker.lastStatus = t0
				refreshStatus()
			end
			if not workPending() then break end
			local el = task.wait(worker.wait)
			if type(el) == "number" and el > worker.wait + STALL_SLACK then
				worker.stalls = worker.stalls + 1
				worker.wait = mathMin(worker.wait * 2, MAX_WAIT)
				if worker.stalls >= 3 then
					task.wait(5)
					worker.stalls = 0
				end
			elseif worker.stalls > 0 then
				worker.stalls = mathMax(0, worker.stalls - 0.2)
			end
		end
		if worker.id == my then
			worker.running = false
			refreshStatus()
		end
	end)
end

local function scheduleWorker()
	if worker.running or worker.scheduled then return end
	worker.scheduled = true
	local function check()
		if not idxActive then
			worker.scheduled = false
			return
		end
		local now = clock()
		local quiet = now - pend.lastAdd >= QUIET_SECONDS
		local big = (pend.tail - pend.head) > 1500 and now - pend.firstAt >= FORCE_AFTER
		if quiet or big then
			worker.scheduled = false
			if workPending() then ensureWorker() end
		else
			task.delay(0.5, check)
		end
	end
	task.delay(0.5, check)
end

local function startScanNow()
	if not idxActive then return end
	scan.top = Workspace:GetChildren()
	scan.tn, scan.ti = #scan.top, 1
	scan.arr, scan.i, scan.n = nil, 1, 0
	scan.active = true
	scheduleWorker()
end

local function requestScan()
	if not idxActive or scan.requested then return end
	local okL, loaded = pcall(function() return game:IsLoaded() end)
	if okL and not loaded then
		if not scan.waitingLoad then
			scan.waitingLoad = true
			task.spawn(function()
				pcall(function() game.Loaded:Wait() end)
				scan.waitingLoad = false
				requestScan()
			end)
		end
		return
	end
	scan.requested = true
	task.delay(0.3, function()
		scan.requested = false
		startScanNow()
	end)
end

local function onAdded(inst)
	local cn = inst.ClassName
	if PART_CLASSES[cn] or LIGHT_CLASSES[cn] or EMITTER_CLASSES[cn] or DECAL_CLASSES[cn] then
		local p = pend
		if p.tail - p.head < MAX_PENDING then
			local now = clock()
			if p.head > p.tail then p.firstAt = now end
			p.lastAdd = now
			p.tail = p.tail + 1
			p.items[p.tail] = inst
			scheduleWorker()
		end
	end
end

local function anyIndexEnabled()
	for i = 1, #INDEX do
		if INDEX[i].enabled then return true end
	end
	return false
end

local function Index_acquire()
	if idxActive then return end
	idxActive = true
	conns.added = Workspace.DescendantAdded:Connect(onAdded)
end

local function Index_release()
	if not idxActive then return end
	idxActive = false
	if conns.added then
		conns.added:Disconnect()
		conns.added = nil
	end
	scan.top, scan.arr, scan.n, scan.i, scan.tn, scan.ti, scan.active = nil, nil, 0, 1, 0, 1, false
	pend = { head = 1, tail = 0, items = {}, lastAdd = 0, firstAt = 0 }
	worker.id = worker.id + 1
	worker.running = false
	worker.scheduled = false
	ancCache = setmetatable({}, WEAK)
	ph, pf = newProxHide(), newProxFx()
end

------------------------------------------------------------------
-- 7. ATUALIZAÇÃO POR PROXIMIDADE (alcance + pixels). Só roda se a câmera andou.
------------------------------------------------------------------
local function proxWanted()
	return F.hide.enabled or (F.fx.enabled and cfg.fxMode == "Distantes")
end

local function proxUpdate(camPos)
	readCam()
	prox.stamp = prox.stamp + 1
	local st = prox.stamp
	if not prox.params then
		local params = OverlapParams.new()
		params.MaxParts = QUERY_MAX
		prox.params = params
	end
	local doHide = on(F.hide)
	local doFx = on(F.fx) and cfg.fxMode == "Distantes"
	local R = mathMax(cfg.cullFar, cfg.fxRange)
	local N = Workspace:GetPartBoundsInRadius(camPos, R, prox.params)
	local capped = #N >= QUERY_MAX -- consulta cheia: por segurança só MOSTRA, nunca oculta
	local fr = cfg.fxRange
	local frBand = (fr * 1.1) * (fr * 1.1)
	local fr2 = fr * fr
	local shows, hides = 0, 0
	local cand, rad, nearSet, seen = ph.cand, ph.rad, ph.nearSet, ph.seen
	local fhost, fnear, fseen = pf.host, pf.near, pf.seen

	for i = 1, #N do
		local p = N[i]
		local isH = doHide and cand[p]
		local fxs = doFx and fhost[p]
		if isH or fxs then
			local d2 = distSq(p)
			if isH then
				local r = rad[p]
				if d2 <= r * r then
					seen[p] = st
					if F.hide.orig[p] ~= nil then
						if shows < SHOW_CAP then
							unhidePart(p)
							shows = shows + 1
							nearSet[p] = true
						else
							seen[p] = nil
						end
					else
						nearSet[p] = true
					end
				elseif d2 <= (r * 1.1) * (r * 1.1) then
					seen[p] = st -- faixa de histerese: mantém o estado atual
				end
			end
			if fxs then
				if d2 <= fr2 then
					fseen[p] = st
					if not fnear[p] then
						fxHostApply(p, false)
						fnear[p] = true
					end
				elseif d2 <= frBand then
					fseen[p] = st
				end
			end
		end
	end

	if not capped then
		if doHide then
			for p in pairs(nearSet) do
				if seen[p] ~= st and hides < HIDE_CAP then
					hidePart(p)
					nearSet[p] = nil
					hides = hides + 1
				end
			end
		end
		if doFx then
			for h in pairs(fnear) do
				if fseen[h] ~= st then
					fxHostApply(h, true)
					fnear[h] = nil
				end
			end
		end
	end

	-- efeitos em objetos móveis (lista pequena; posição ao vivo)
	if doFx and pf.mobN > 0 then
		local mE, mH = pf.mobE, pf.mobH
		local i, n = 1, pf.mobN
		while i <= n do
			local e, h = mE[i], mH[i]
			if e.Parent == nil or h.Parent == nil then
				mE[i], mH[i] = mE[n], mH[n]
				mE[n], mH[n] = nil, nil
				n = n - 1
			else
				local d2 = distSq(h)
				if F.fx.orig[e] ~= nil then
					if d2 <= fr2 * 0.81 then restoreMod(F.fx, e) end
				elseif d2 > fr2 then
					applyMod(F.fx, e)
				end
				i = i + 1
			end
		end
		pf.mobN = n
	end
end

local function autoDisableProx(reason)
	notify("Culling desligado automaticamente (" .. reason .. ").", 6)
	if toggles.hide and uiState.hide then pcall(toggles.hide) end
	if toggles.fx and uiState.fx then pcall(toggles.fx) end
end

ensureProx = function()
	if prox.running or not proxWanted() then return end
	prox.running = true
	prox.id = prox.id + 1
	prox.dirty = true
	local my = prox.id
	task.spawn(function()
		while prox.id == my and proxWanted() do
			local t0 = clock()
			local cam = Workspace.CurrentCamera
			if cam then
				local p = cam.CFrame.Position
				local moved = true
				if prox.lastCam and not prox.dirty then
					moved = (p - prox.lastCam).Magnitude >= MOVE_STUDS
				end
				if moved then
					prox.lastCam, prox.dirty = p, false
					local ok, err = pcall(proxUpdate, p)
					if ok then
						prox.errors = 0
					else
						prox.errors = prox.errors + 1
						print("[Perf] culling: " .. tostring(err))
						if prox.errors >= 3 then
							prox.running = false
							autoDisableProx("erros repetidos na consulta espacial")
							return
						end
					end
					local spent = clock() - t0
					if spent > 0.008 then
						prox.over = prox.over + 1
						prox.interval = mathMin(prox.interval * 1.5, 2)
						if prox.over >= 5 then
							prox.running = false
							autoDisableProx("custo alto: " .. string.format("%.1f", spent * 1000) .. " ms por atualização")
							return
						end
					else
						prox.over = mathMax(0, prox.over - 0.5)
						prox.interval = mathMax(0.5, prox.interval * 0.9)
					end
				end
			end
			task.wait(prox.interval)
		end
		if prox.id == my then prox.running = false end
	end)
end

------------------------------------------------------------------
-- 8. LIGAR/DESLIGAR RECURSOS POR VARREDURA
------------------------------------------------------------------
local function enableIndex(f)
	if f.enabled then return end
	f.enabled, f.paused = true, false
	if f.key == "hide" then F.hcast.enabled, F.hcast.paused = true, false end
	Index_acquire()
	requestScan()
	ensureProx()
end

local function disableIndex(f)
	if not f.enabled then return end
	f.enabled = false
	restoreChunked(f)
	if f.key == "hide" then
		F.hcast.enabled = false
		restoreChunked(F.hcast)
		ph = newProxHide()
	elseif f.key == "fx" then
		pf = newProxFx()
	end
	if not anyIndexEnabled() then Index_release() end
	refreshStatus()
end

local function refreshFeature(f)
	if not f.enabled then return end
	f.paused = true
	if f.key == "hide" then F.hcast.paused = true end
	local function finish()
		f.paused = false
		if f.key == "hide" then
			F.hcast.paused = false
			ph = newProxHide()
		elseif f.key == "fx" then
			pf = newProxFx()
		end
		prox.dirty = true
		requestScan()
		ensureProx()
	end
	if f.key == "hide" then restoreChunked(F.hcast) end
	restoreChunked(f, finish)
end

local debounceFlags = {}
local function debounceRefresh(f)
	if applyingProfile or not f.enabled then return end
	debounceFlags[f.key] = true
	task.delay(0.8, function()
		if debounceFlags[f.key] then
			debounceFlags[f.key] = false
			refreshFeature(f)
		end
	end)
end

local function setLodMode(mode)
	local enum = (mode == "Performance") and Enum.RenderFidelity.Performance or Enum.RenderFidelity.Automatic
	cfg.lodMode = mode
	local f = F.lod
	if f.target == enum then return end
	if f.enabled then
		f.paused = true
		restoreChunked(f, function()
			f.target = enum
			f.paused = false
			requestScan()
		end)
	else
		f.target = enum
	end
end

------------------------------------------------------------------
-- 9. RECURSOS GLOBAIS (poucas escritas, uma vez; original sempre guardado)
------------------------------------------------------------------
local function sameVal(a, b)
	if a == b then return true end
	if type(a) == "string" and type(b) == "string" then return lower(a) == lower(b) end
	local function val(x)
		if type(x) == "number" then return x end
		local ok, v = pcall(function() return x.Value end)
		if ok and type(v) == "number" then return v end
		return nil
	end
	local va, vb = val(a), val(b)
	return va ~= nil and va == vb
end

local function itemGet(it)
	local ok, v
	if it.get then ok, v = pcall(it.get) else ok, v = pcall(getProp, it.inst, it.prop) end
	if ok then return v end
	return nil
end

local function itemSet(it, v)
	if it.set then return (pcall(it.set, v)) end
	return (pcall(setProp, it.inst, it.prop, v))
end

local function newGlobal(key, label, short, resolve, fallback, risky)
	return {
		key = key, label = label, short = short, resolve = resolve, fallback = fallback,
		risky = risky, enabled = false, saved = {}, reason = nil,
	}
end

local function techTarget()
	local ok, v = pcall(function() return Enum.Technology.Compatibility end)
	if ok and v then return v end
	ok, v = pcall(function() return Enum.LightingTechnology.Compatibility end)
	if ok and v then return v end
	return 2
end

-- Flags do engine via executor: só DF (dinâmicas) da allowlist; leitura de volta confirma
local function ffItems(list)
	local sf = setfflag or set_fflag or setfastflag
	local gf = getfflag or get_fflag or getfastflag
	if type(sf) ~= "function" or type(gf) ~= "function" then
		return {}, "este executor não tem setfflag/getfflag"
	end
	local items = {}
	for i = 1, #list do
		local name, value = list[i][1], tostring(list[i][2])
		items[#items + 1] = {
			name = name, target = value,
			get = function()
				local v = gf(name)
				if v == nil then error("flag desconhecida: " .. name) end
				return tostring(v)
			end,
			set = function(v) sf(name, v) end,
		}
	end
	return items
end

local G = {
	gshadows = newGlobal("gshadows", "Sombras globais (desligar)", "sombras globais", function()
		return { { inst = Lighting, prop = "GlobalShadows", target = false } }
	end),
	terrain = newGlobal("terrain", "Terreno: sem grama / água simples", "terreno", function()
		local t = Workspace:FindFirstChildOfClass("Terrain")
		if not t then return {}, "este jogo não tem Terrain" end
		return {
			{ inst = t, prop = "Decoration", target = false },
			{ inst = t, prop = "WaterWaveSize", target = 0 },
			{ inst = t, prop = "WaterWaveSpeed", target = 0 },
			{ inst = t, prop = "WaterReflectance", target = 0 },
		}
	end),
	quality = newGlobal("quality", "Qualidade gráfica fixa (teste 20 s)", "qualidade", function()
		local okU, ugs = pcall(function() return UserSettings():GetService("UserGameSettings") end)
		if not okU or not ugs then return {}, "UserGameSettings indisponível" end
		local okE, tgt = pcall(function() return Enum.SavedQualitySetting["QualityLevel" .. cfg.qualityLevel] end)
		if not okE or not tgt then return {}, "nível inválido" end
		return { { inst = ugs, prop = "SavedQualityLevel", target = tgt } }
	end, function()
		local okR, r = pcall(function() return settings().Rendering end)
		if not okR or not r then return {} end
		local okE, tgt = pcall(function() return Enum.QualityLevel["Level" .. string.format("%02d", cfg.qualityLevel)] end)
		if not okE or not tgt then return {} end
		return { { inst = r, prop = "QualityLevel", target = tgt } }
	end, true),
	technology = newGlobal("technology", "Lighting: modo Compatibility (teste 20 s)", "iluminação", function()
		local sh = sethiddenproperty or set_hidden_property or set_hidden_prop
		if type(sh) ~= "function" then return {}, "este executor não tem sethiddenproperty" end
		local gh = gethiddenproperty or get_hidden_property or get_hidden_prop
		return { {
			name = "Lighting.Technology", target = techTarget(),
			get = function()
				if type(gh) == "function" then
					local v = gh(Lighting, "Technology")
					return v
				end
				return Lighting.Technology
			end,
			set = function(v) sh(Lighting, "Technology", v) end,
		} }
	end, nil, true),
	fpscap = newGlobal("fpscap", "Limitar FPS (estabilidade)", "FPS cap", function()
		local set = setfpscap or set_fps_cap
		if type(set) ~= "function" then return {}, "este executor não tem setfpscap" end
		local get = getfpscap or get_fps_cap
		local assumed = 60
		return { {
			name = "FPS", target = cfg.fpsCap, noverify = true,
			get = function()
				if type(get) == "function" then
					local v = get()
					if type(v) == "number" then return v end
				end
				return assumed
			end,
			set = function(v) set(v) end,
		} }
	end),
	ffgeo = newGlobal("ffgeo", "Flag: LOD de geometria distante (CSG)", "LOD geometria", function()
		local d = cfg.lodDist
		return ffItems({
			{ "DFIntCSGLevelOfDetailSwitchingDistance", d },
			{ "DFIntCSGLevelOfDetailSwitchingDistanceL12", d },
			{ "DFIntCSGLevelOfDetailSwitchingDistanceL23", d },
			{ "DFIntCSGLevelOfDetailSwitchingDistanceL34", d },
		})
	end),
	fftex = newGlobal("fftex", "Flag: qualidade de textura (teste 20 s)", "textura", function()
		return ffItems({
			{ "DFFlagTextureQualityOverrideEnabled", "True" },
			{ "DFIntTextureQualityOverride", cfg.texLevel },
		})
	end, nil, true),
	fffrm = newGlobal("fffrm", "Flag: nível FRM / alcance de render (teste 20 s)", "FRM", function()
		return ffItems({ { "DFIntDebugFRMQualityLevelOverride", cfg.frmLevel } })
	end, nil, true),
}
local GLIST = { G.gshadows, G.terrain, G.quality, G.technology, G.fpscap, G.ffgeo, G.fftex, G.fffrm }

local function tryItems(g, items)
	for i = 1, #items do
		local it = items[i]
		local cur = itemGet(it)
		if cur ~= nil and not sameVal(cur, it.target) and itemSet(it, it.target) then
			local now = itemGet(it)
			if it.noverify or (now ~= nil and sameVal(now, it.target)) then
				g.saved[#g.saved + 1] = { it = it, orig = cur }
			else
				itemSet(it, cur)
			end
		end
	end
end

local function describeSaved(g)
	local names = {}
	for i = 1, #g.saved do
		local it = g.saved[i].it
		names[#names + 1] = tostring(it.name or it.prop or "?")
	end
	return table.concat(names, ", ")
end

local function enableGlobal(g)
	if g.enabled then return end
	g.enabled = true
	g.saved, g.reason = {}, nil
	local ok, items, why = pcall(g.resolve)
	if ok and items then tryItems(g, items) end
	if #g.saved == 0 and g.fallback then
		local ok2, items2 = pcall(g.fallback)
		if ok2 and items2 then tryItems(g, items2) end
	end
	if #g.saved == 0 then
		g.reason = tostring(why or "já estava nesse valor, ou o jogo/executor não deixa mudar")
		notify("'" .. g.label .. "': nada mudou (" .. g.reason .. ").", 6)
	else
		notify(g.short .. ": aplicou " .. describeSaved(g) .. ".", 4)
	end
end

local function disableGlobal(g)
	if not g.enabled then return end
	g.enabled = false
	for i = 1, #g.saved do
		local s = g.saved[i]
		local cur = itemGet(s.it)
		if s.it.noverify or (cur ~= nil and sameVal(cur, s.it.target)) then itemSet(s.it, s.orig) end
	end
	g.saved = {}
end

local function refreshGlobal(g)
	if applyingProfile or not g.enabled then return end
	disableGlobal(g)
	enableGlobal(g)
end

-- TESTE DE SEGURANÇA: globais arriscados voltam sozinhos se você não confirmar
local trials = {}
local setToggle

local function startTrial(g)
	if suppressTrial then return end
	local id = (trials[g.key] or 0) + 1
	trials[g.key] = id
	notify("Teste de " .. TRIAL_SECONDS .. " s: " .. g.short .. ". Se travar ou piorar, volta sozinho. Para manter, toque em 'Confirmar'.", 7)
	task.delay(TRIAL_SECONDS, function()
		if trials[g.key] == id then
			trials[g.key] = nil
			setToggle(g.key, false)
			notify("Revertido (sem confirmação): " .. g.short .. ".", 5)
		end
	end)
end

local function confirmTrials()
	local any = false
	for k in pairs(trials) do
		trials[k] = nil
		any = true
	end
	notify(any and "Mudanças confirmadas." or "Nada para confirmar.", 2)
end

------------------------------------------------------------------
-- 10. STATUS
------------------------------------------------------------------
local lastStatusText = ""
refreshStatus = function()
	if not statusP then return end
	local gl = {}
	for i = 1, #GLIST do
		local g = GLIST[i]
		if g.enabled and #g.saved > 0 then gl[#gl + 1] = g.short end
	end
	local state = "ocioso"
	if scan.active then
		state = string.format("varrendo… bloco %d/%d", mathMin(scan.ti, scan.tn), scan.tn)
	elseif pend.head <= pend.tail then
		state = "aguardando o jogo ficar quieto (" .. (pend.tail - pend.head + 1) .. " novos)"
	end
	if prox.running then state = state .. " | culling ativo" end
	local text = string.format(
		"Perfil: %s\nOcultos %d | Sombras %d | LOD %d | Efeitos %d | Texturas %d\nGlobais: %s\nEstado: %s",
		currentProfile or "manual",
		F.hide.mods, F.shadows.mods + F.hcast.mods, F.lod.mods, F.fx.mods, F.decals.mods,
		(#gl > 0) and table.concat(gl, ", ") or "nenhum", state)
	if text ~= lastStatusText then
		lastStatusText = text
		pcall(function() statusP:SetValue(text) end)
	end
end

------------------------------------------------------------------
-- 11. TOGGLES, PERFIL E RESTAURAÇÃO (tudo definido ANTES da interface)
------------------------------------------------------------------
setToggle = function(key, desired)
	desired = desired == true
	if (uiState[key] == true) == desired then return end
	local fn = toggles[key]
	if type(fn) == "function" then
		pcall(fn)
		if (uiState[key] == true) == desired then return end
	end
	local h = handlers[key]
	if h then
		uiState[key] = desired
		local ok, err = pcall(h, desired)
		if not ok then print("[Perf] erro em '" .. key .. "': " .. tostring(err)) end
	end
end

local lodDropdown, fxDropdown, sliders = nil, nil, {}

local function applyProfile(name)
	local p = PROFILES[name]
	if not p then return end
	currentProfile = name
	applyingProfile = true

	local wasOn = {}
	for _, key in ipairs(FEATURE_ORDER) do wasOn[key] = uiState[key] == true end
	local old = {
		shadowMax = cfg.shadowMax, cullFar = cfg.cullFar, minPx = cfg.minPx,
		fxMode = cfg.fxMode, hideCollidable = cfg.hideCollidable,
	}

	for k, v in pairs(p.cfg) do cfg[k] = v end
	pcall(setLodMode, p.cfg.lodMode)
	for _, key in ipairs(FEATURE_ORDER) do
		if not MANUAL[key] then setToggle(key, p.features[key] == true) end
	end

	if wasOn.shadows and F.shadows.enabled and old.shadowMax ~= cfg.shadowMax then refreshFeature(F.shadows) end
	if wasOn.hide and F.hide.enabled and (old.cullFar ~= cfg.cullFar or old.minPx ~= cfg.minPx
		or old.hideCollidable ~= cfg.hideCollidable) then
		refreshFeature(F.hide)
	end
	if wasOn.fx and F.fx.enabled and old.fxMode ~= cfg.fxMode then refreshFeature(F.fx) end

	for _, id in ipairs({ "shadowMax", "cullFar", "minPx", "fxRange", "sliceMs" }) do
		local sl = sliders[id]
		if sl then pcall(function() sl:SetValue(cfg[id]) end) end
	end
	if lodDropdown then pcall(function() lodDropdown:Select(p.cfg.lodMode) end) end
	if fxDropdown then pcall(function() fxDropdown:Select(p.cfg.fxMode) end) end
	for k, v in pairs(p.cfg) do cfg[k] = v end

	prox.dirty = true
	applyingProfile = false
	ensureProx()
	refreshStatus()
	notify("Perfil " .. name .. " aplicado.", 2)
end

local function restoreEverything(silent)
	for k in pairs(trials) do trials[k] = nil end
	for _, key in ipairs(FEATURE_ORDER) do setToggle(key, false) end
	for i = 1, #INDEX do
		restoreAllSync(INDEX[i])
		INDEX[i].enabled = false
	end
	for i = 1, #GLIST do disableGlobal(GLIST[i]) end
	prox.id = prox.id + 1
	prox.running = false
	Index_release()
	currentProfile = nil
	refreshStatus()
	if not silent then notify("Tudo restaurado ao estado original.", 2) end
end
disableAll = function() restoreEverything(true) end

local function shutdown()
	restoreEverything(true)
	for k, c in pairs(conns) do
		pcall(function() c:Disconnect() end)
		conns[k] = nil
	end
	worker.id = worker.id + 1
	worker.running = false
end
pcall(function() _G[GKEY] = shutdown end)

------------------------------------------------------------------
-- 12. BENCHMARK (só mede quando você pede; nada fica rodando)
------------------------------------------------------------------
local benchP = nil
local benchBusy = false

local function memSnapshot()
	local out = {}
	local okS, Stats = pcall(function() return game:GetService("Stats") end)
	if not okS or not Stats then return out end
	local function tag(name)
		local ok, v = pcall(function() return Stats:GetMemoryUsageMbForTag(Enum.DeveloperMemoryTag[name]) end)
		if ok and type(v) == "number" then return v end
		return nil
	end
	local okT, tot = pcall(function() return Stats:GetTotalMemoryUsageMb() end)
	out.total = okT and tot or nil
	out.lua, out.inst, out.tex = tag("LuaHeap"), tag("Instances"), tag("GraphicsTexture")
	return out
end

local function pingMs()
	local ok, v = pcall(function() return Players.LocalPlayer:GetNetworkPing() end)
	if ok and type(v) == "number" and v > 0 then return v * 2000 end
	return nil
end

local function measure(seconds, cb)
	local samples, n, pings, acc = {}, 0, {}, 0
	local conn = RunService.Heartbeat:Connect(function(dt)
		if n < 3000 then
			n = n + 1
			samples[n] = dt
		end
		acc = acc + dt
		if acc >= 1 then
			acc = 0
			local p = pingMs()
			if p then pings[#pings + 1] = p end
		end
	end)
	task.delay(seconds, function()
		conn:Disconnect()
		local res = { frames = n, mem = memSnapshot() }
		if n > 0 then
			table.sort(samples)
			local sum, spikes = 0, 0
			for i = 1, n do
				sum = sum + samples[i]
				if samples[i] > 0.05 then spikes = spikes + 1 end
			end
			local k = mathMax(1, mathFloor(n * 0.01))
			local worst = 0
			for i = n - k + 1, n do worst = worst + samples[i] end
			res.fps = 1 / (sum / n)
			res.low1 = 1 / (worst / k)
			res.spikes = spikes
		end
		if #pings > 0 then
			local s, lo, hi = 0, math.huge, 0
			for i = 1, #pings do
				s = s + pings[i]
				lo = mathMin(lo, pings[i])
				hi = mathMax(hi, pings[i])
			end
			res.ping, res.jitter = s / #pings, hi - lo
		end
		cb(res)
	end)
end

local function fmt(v, d)
	if v == nil then return "?" end
	return string.format("%." .. (d or 1) .. "f", v)
end

local function benchReport(text)
	if benchP then pcall(function() benchP:SetValue(text) end) end
end

local function diagnose(r)
	if r.fps == nil then return "" end
	local netBad = (r.ping and r.ping > 150) or (r.jitter and r.jitter > 80)
	local cpuBad = r.low1 and r.low1 < 24
	if netBad and not cpuBad then return "\n→ Parece REDE/servidor (ping/jitter altos). O plugin não resolve isso."
	elseif cpuBad and not netBad then return "\n→ Parece o SEU APARELHO (quedas de FPS)."
	elseif cpuBad and netBad then return "\n→ Os dois: aparelho e rede."
	end
	return "\n→ Sem sinal claro de problema nesta janela de medição."
end

local function runMeasure()
	if benchBusy then return end
	benchBusy = true
	benchReport("Medindo 10 s… jogue normalmente.")
	measure(10, function(r)
		benchBusy = false
		local m = r.mem
		benchReport(string.format(
			"FPS médio %s | 1%% piores %s | picos>50ms %s\nPing ~%s ms | jitter %s ms\nRAM total %s MB | Lua %s | Instâncias %s | Texturas %s%s",
			fmt(r.fps), fmt(r.low1), tostring(r.spikes or "?"), fmt(r.ping, 0), fmt(r.jitter, 0),
			fmt(m.total, 0), fmt(m.lua), fmt(m.inst), fmt(m.tex), diagnose(r)))
	end)
end

local function runAB()
	if benchBusy then return end
	local want, any = {}, false
	for _, key in ipairs(FEATURE_ORDER) do
		want[key] = uiState[key] == true
		if want[key] then any = true end
	end
	if not any then
		notify("Ative um perfil (ou recursos) antes do teste A/B.", 3)
		return
	end
	benchBusy = true
	task.spawn(function()
		benchReport("A/B: desligando tudo e medindo a linha de base (8 s)…")
		restoreEverything(true)
		task.wait(2)
		local A
		measure(8, function(r) A = r end)
		while not A do task.wait(0.5) end
		benchReport("A/B: reaplicando e aguardando terminar…")
		suppressTrial = true
		for _, key in ipairs(FEATURE_ORDER) do setToggle(key, want[key]) end
		suppressTrial = false
		local waited = 0
		while (workPending() or scan.requested) and waited < 60 do
			task.wait(0.5)
			waited = waited + 0.5
		end
		task.wait(3)
		benchReport("A/B: medindo com otimizações (8 s)…")
		local B
		measure(8, function(r) B = r end)
		while not B do task.wait(0.5) end
		benchBusy = false
		local function d(a, b, dec)
			if a == nil or b == nil then return "?" end
			return string.format("%+." .. (dec or 1) .. "f", b - a)
		end
		benchReport(string.format(
			"SEM → COM otimizações\nFPS médio %s → %s (%s)\n1%% piores %s → %s (%s)\nPicos>50ms %s → %s\nPing ~%s → %s ms | jitter %s → %s\nRAM total %s → %s MB (%s)\nLua %s → %s | Instâncias %s → %s | Texturas %s → %s",
			fmt(A.fps), fmt(B.fps), d(A.fps, B.fps), fmt(A.low1), fmt(B.low1), d(A.low1, B.low1),
			tostring(A.spikes or "?"), tostring(B.spikes or "?"),
			fmt(A.ping, 0), fmt(B.ping, 0), fmt(A.jitter, 0), fmt(B.jitter, 0),
			fmt(A.mem.total, 0), fmt(B.mem.total, 0), d(A.mem.total, B.mem.total, 0),
			fmt(A.mem.lua), fmt(B.mem.lua), fmt(A.mem.inst), fmt(B.mem.inst), fmt(A.mem.tex), fmt(B.mem.tex)))
		notify("Teste A/B concluído (resultado no painel Benchmark).", 4)
	end)
end

------------------------------------------------------------------
-- 13. INTERFACE (somente métodos do guia ODH; cada passo isolado em pcall)
------------------------------------------------------------------
local ready = false
local uiErrors = {}

local function guard(name, fn, ...)
	local ok, res = pcall(fn, ...)
	if not ok then
		uiErrors[#uiErrors + 1] = name .. ": " .. tostring(res)
		print("[Perf] UI: falhou '" .. name .. "': " .. tostring(res))
		return nil
	end
	return res
end

local function add(section, method, name, ...)
	if not section then return nil end
	return guard(name, section[method], section, ...)
end

local my_tab = shared.CreateTab("Performance Optimizer", ICON_PATH)

local firstSection = nil
local function newSection(title, subtitle)
	local s = guard("Seção " .. title, my_tab.AddSection, my_tab, title, subtitle)
	if s then
		if not firstSection then firstSection = s end
		return s
	end
	return firstSection
end

local function addToggle(section, key, label, onChange)
	handlers[key] = onChange
	toggles[key] = add(section, "AddToggle", "Toggle " .. label, label, function(state)
		state = state == true
		if uiState[key] == state then return end
		uiState[key] = state
		local ok, err = pcall(onChange, state)
		if not ok then print("[Perf] erro em '" .. key .. "': " .. tostring(err)) end
		refreshStatus()
	end)
end

local function indexToggle(section, f)
	addToggle(section, f.key, f.label, function(on)
		if on then enableIndex(f) else disableIndex(f) end
	end)
end

local function globalToggle(section, g)
	addToggle(section, g.key, g.label, function(on)
		if on then
			enableGlobal(g)
			if #g.saved == 0 then
				task.delay(0.1, function() setToggle(g.key, false) end)
			elseif g.risky then
				startTrial(g)
			end
		else
			trials[g.key] = nil
			disableGlobal(g)
		end
	end)
end

local function addSlider(section, id, label, lo, hi, onChange)
	sliders[id] = add(section, "AddSlider", "Slider " .. label, label, lo, hi, cfg[id], function(v)
		if type(v) ~= "number" or cfg[id] == v then return end
		cfg[id] = v
		if onChange then onChange() end
	end)
end

local selectedProfile = nil

-- Perfil
local secProfile = newSection("Perfil", "LOW • MEDIUM • AGGRESSIVE")
add(secProfile, "AddParagraph", "Aviso", "Seguro por design",
	"Só altera visuais locais e guarda o original de tudo. Nunca toca Tools, personagens, coletáveis, interativos, rede, ownership ou colisão.")
add(secProfile, "AddDropdown", "Perfil", "Perfil", { "LOW", "MEDIUM", "AGGRESSIVE" }, function(selected)
	selectedProfile = selected
	if ready then applyProfile(selected) end
end)
statusP = add(secProfile, "AddParagraph", "Status", "Status",
	"Nada ativo. Escolha um perfil ou ligue os recursos abaixo.", true)
add(secProfile, "AddButton", "Reaplicar", "Reaplicar perfil selecionado", function()
	if selectedProfile then applyProfile(selectedProfile) else notify("Escolha um perfil primeiro.", 2) end
end)

-- Render: cortar o que está longe
local secCull = newSection("Cortar o que está longe", "Alcance + tamanho na tela")
indexToggle(secCull, F.hide)
addToggle(secCull, "hidecol", "Ocultar também partes sólidas decorativas", function(on)
	cfg.hideCollidable = on
	if not applyingProfile then debounceRefresh(F.hide) end
end)
addSlider(secCull, "cullFar", "Alcance máximo de renderização (studs)", 60, 800, function() debounceRefresh(F.hide) end)
addSlider(secCull, "minPx", "Tamanho mínimo na tela (px): maior = some mais cedo", 2, 30, function() debounceRefresh(F.hide) end)

-- Render: detalhe
local secRender = newSection("Detalhe e efeitos", "Aplica uma vez e para")
indexToggle(secRender, F.shadows)
addSlider(secRender, "shadowMax", "Tamanho máx. p/ tirar sombra (studs)", 1, 100, function() debounceRefresh(F.shadows) end)
indexToggle(secRender, F.lights)
indexToggle(secRender, F.lod)
lodDropdown = add(secRender, "AddDropdown", "LOD modo", "LOD: modo", { "Automatic", "Performance" }, function(selected)
	local ok, err = pcall(setLodMode, selected)
	if not ok then print("[Perf] LOD: " .. tostring(err)) end
end)
indexToggle(secRender, F.decals)
indexToggle(secRender, F.fx)
fxDropdown = add(secRender, "AddDropdown", "Efeitos modo", "Efeitos: modo", { "Distantes", "Todos" }, function(selected)
	if cfg.fxMode == selected then return end
	cfg.fxMode = selected
	if not applyingProfile then refreshFeature(F.fx) end
end)
addSlider(secRender, "fxRange", "Efeitos: alcance (studs)", 20, 400, function()
	prox.dirty = true
end)

-- Globais
local secGlobal = newSection("Gráficos globais", "Mudam o cliente inteiro (só local)")
globalToggle(secGlobal, G.gshadows)
globalToggle(secGlobal, G.terrain)
globalToggle(secGlobal, G.quality)
addSlider(secGlobal, "qualityLevel", "Nível gráfico fixo (1 a 10)", 1, 10, function()
	if not applyingProfile and G.quality.enabled then task.delay(0.8, function() refreshGlobal(G.quality) end) end
end)
globalToggle(secGlobal, G.technology)
globalToggle(secGlobal, G.fpscap)
addSlider(secGlobal, "fpsCap", "Limite de FPS", 20, 60, function()
	if not applyingProfile and G.fpscap.enabled then task.delay(0.8, function() refreshGlobal(G.fpscap) end) end
end)
add(secGlobal, "AddButton", "Confirmar", "Confirmar mudanças em teste", confirmTrials)

-- Flags do engine (executor)
local secFlags = newSection("Flags do engine (executor)", "Geometria e texturas — só flags da allowlist")
globalToggle(secFlags, G.ffgeo)
addSlider(secFlags, "lodDist", "Distância do LOD de geometria (studs; menor = mais simples)", 0, 1000, function()
	if not applyingProfile and G.ffgeo.enabled then task.delay(0.8, function() refreshGlobal(G.ffgeo) end) end
end)
globalToggle(secFlags, G.fftex)
add(secFlags, "AddDropdown", "Textura", "Qualidade de textura", { "Baixa (1)", "Média (2)" }, function(selected)
	cfg.texLevel = (selected == "Média (2)") and 2 or 1
	if not applyingProfile and G.fftex.enabled then task.delay(0.8, function() refreshGlobal(G.fftex) end) end
end)
globalToggle(secFlags, G.fffrm)
addSlider(secFlags, "frmLevel", "Nível FRM (1 a 10; menor = alcance de render menor)", 1, 10, function()
	if not applyingProfile and G.fffrm.enabled then task.delay(0.8, function() refreshGlobal(G.fffrm) end) end
end)

-- Ajustes
local secTune = newSection("Ajustes", "Execução")
addSlider(secTune, "sliceMs", "Orçamento por fatia (ms)", 0.5, 4, nil)

-- Benchmark
local secBench = newSection("Benchmark", "Aparelho ou rede? Mede de verdade")
benchP = add(secBench, "AddParagraph", "Resultado", "Resultado",
	"'Medir agora' mostra FPS, ping, jitter e RAM. O teste A/B compara com e sem otimizações.", true)
add(secBench, "AddButton", "Medir", "Medir agora (10 s)", runMeasure)
add(secBench, "AddButton", "AB", "Teste A/B automático (~35 s)", runAB)

-- Segurança
local secSafety = newSection("Segurança", "Restauração")
add(secSafety, "AddButton", "Restaurar tudo", "Restaurar tudo", function()
	restoreEverything(false)
end)

-- Ajuda
local secHelp = newSection("Ajuda", "O que cada opção faz")
add(secHelp, "AddParagraph", "Ajuda culling", "Cortar o que está longe",
	"Cada peça decorativa tem um alcance: tamanho × (500 ÷ px mínimo), limitado ao alcance máximo. Peça pequena some mais cedo, "
	.. "peça grande vai mais longe. Só valem peças ancoradas, sem prompt/toque/GUI/tag, com CanQuery ligado, de até 60 studs. "
	.. "Peça oculta fica invisível e sem sombra, e volta sozinha quando você chega perto. Coletáveis e interativos nunca somem.")
add(secHelp, "AddParagraph", "Ajuda efeitos", "Efeitos",
	"Distantes: desliga efeitos (partículas, fogo, trilhas, feixes) além do alcance, inclusive em objetos que se mexem. "
	.. "Todos: desliga todos de uma vez. Efeitos de personagens, Tools e itens interativos/coletáveis são sempre preservados.")
add(secHelp, "AddParagraph", "Ajuda flags", "Flags do engine",
	"Precisam de setfflag/getfflag no executor e só mexem em flags DF da allowlist do Roblox. 'Nada mudou' = o executor não tem a função "
	.. "ou o motor não aceitou. Se o jogo reaplicar o valor depois de uns minutos, é normal (flags dinâmicas se atualizam). "
	.. "Sem setfflag: use o JSON abaixo no FastStrap/RbxFPS (Shizuku).")
add(secHelp, "AddParagraph", "JSON flags", "JSON para FastStrap/RbxFPS",
	'{"DFIntCSGLevelOfDetailSwitchingDistance":150,"DFIntCSGLevelOfDetailSwitchingDistanceL12":150,'
	.. '"DFIntCSGLevelOfDetailSwitchingDistanceL23":150,"DFIntCSGLevelOfDetailSwitchingDistanceL34":150,'
	.. '"DFFlagTextureQualityOverrideEnabled":true,"DFIntTextureQualityOverride":1}')
add(secHelp, "AddParagraph", "Ajuda terreno", "Terreno (grama/água)",
	"Só controla grama e ondas/reflexo da água. NÃO remove textura do terreno: isso o Lua não expõe. "
	.. "Se nada mudar, o aviso diz o motivo (jogo sem Terrain, ou valores já iguais).")
add(secHelp, "AddParagraph", "Ajuda lag", "Lag dos outros jogadores",
	"O plugin só mexe no seu aparelho: não reduz carga do servidor nem muda como os outros te veem. Use o Benchmark para ver ping/jitter.")
add(secHelp, "AddParagraph", "Ajuda resolução", "Resolução (fora do Roblox)",
	"O Roblox não expõe resolução por script. No Android, com Shizuku + aShell You: 'wm size' mostra a nativa; 'wm size LARGURAxALTURA' "
	.. "com ~80% (ex.: 720x1640 → 576x1312). Volta com 'wm size reset'; se algo ficar estranho, 'wm density reset'.")

if #uiErrors > 0 then
	notify("Perf: " .. #uiErrors .. " controle(s) falharam ao carregar. Veja o console (F9).", 6)
	add(secSafety, "AddParagraph", "Diagnóstico", "Diagnóstico da interface", table.concat(uiErrors, "\n"))
end

task.delay(0.5, function() ready = true end)
