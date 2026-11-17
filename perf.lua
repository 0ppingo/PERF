--> Overdrive H On Top.
--> PERFORMANCE OPTIMIZER v4 — plugin independente para o ODH
--[[
  Tudo LOCAL ao seu cliente (nada replica): não toca personagem, Tools, rede, ownership,
  física, colisão nem ScreenGuis do jogo.

  O QUE MUDOU NA v4 (baseado na pesquisa)
  - SEM ciclo permanente. Cada recurso roda UMA vez (varredura fatiada, com um único
    GetDescendants) e o trabalho PARA. Objetos novos entram por uma fila com debounce.
    Acabou o vai-e-volta de escritas por distância (que forçava o renderer a reprocessar
    milhares de partes) e o "ocultar distantes" (o motor já faz frustum/occlusion culling).
  - SEM listas fortes: só tabelas de chave fraca guardam o valor original, então instâncias
    destruídas/streamadas para fora são coletadas (sem vazamento de RAM do plugin).
  - Novos recursos: nível gráfico nativo (UserGameSettings.SavedQualityLevel),
    Lighting.Technology = Compatibility (executor), luzes sem sombra, Benchmark A/B.
  - Sombras agora por TAMANHO (partes pequenas), como recomenda a documentação oficial.

  Exclusões (nunca tocados): personagens/NPCs (Humanoid), Tools, Accessories, câmera,
  itens não ancorados, partes com ProximityPrompt/ClickDetector/TouchTransmitter/Gui,
  tags, atributos e nomes da lista BLOCK_KEYWORDS.

  RISCOS CONHECIDOS
  - "Qualidade gráfica" grava o nível salvo do Roblox: o plugin restaura ao desligar, mas se
    o app fechar antes, ajuste em Configurações do Roblox > Gráficos (Automático).
  - "Lighting: Compatibility" depende de sethiddenproperty do executor e muda bastante o
    visual (sem sombras dinâmicas). O plugin confere se pegou e restaura o original.
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
local WEAK = { __mode = "k" }

local function notify(msg, dur)
	pcall(function() shared.Notify(msg, dur or 3) end)
end

------------------------------------------------------------------
-- 1. CONFIGURAÇÃO E PERFIS
------------------------------------------------------------------
local ICON_PATH = "/0ppingo/PERF/refs/heads/main/icon"

local cfg = {
	shadowMax = 8,        -- partes com maior dimensão <= isto perdem a sombra (studs)
	minRate = 15,         -- emissores com Rate abaixo disto são mantidos
	qualityLevel = 3,     -- 1..10 (abaixo de 4 o motor desliga sombras sozinho)
	sliceMs = 1.5,        -- orçamento de cada fatia de trabalho
	lodMode = "Automatic",
}

local PROFILES = {
	LOW = {
		cfg = { shadowMax = 4, minRate = 40, qualityLevel = 3, sliceMs = 1.2, lodMode = "Automatic" },
		features = { lights = true, particles = true, bloom = true, sunrays = true },
	},
	MEDIUM = {
		cfg = { shadowMax = 8, minRate = 15, qualityLevel = 3, sliceMs = 1.5, lodMode = "Automatic" },
		features = {
			lights = true, particles = true, shadows = true, lod = true,
			bloom = true, sunrays = true, dof = true,
		},
	},
	AGGRESSIVE = {
		cfg = { shadowMax = 30, minRate = 0, qualityLevel = 3, sliceMs = 2, lodMode = "Performance" },
		features = {
			lights = true, particles = true, shadows = true, lod = true, decals = true,
			bloom = true, sunrays = true, dof = true, blur = true,
			gshadows = true, terrain = true,
		},
	},
}

local FEATURE_ORDER = {
	"shadows", "lights", "lod", "particles", "decals",
	"gshadows", "terrain", "quality", "technology",
	"bloom", "sunrays", "dof", "blur",
}

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
local MIN_WAIT, MAX_WAIT = 0.03, 0.3

local conns = {}
local toggles, uiState, handlers = {}, {}, {}
local currentProfile = nil
local statusP = nil
local applyingProfile = false

------------------------------------------------------------------
-- 2. FEATURES (original guardado em tabela de chave FRACA: sem vazamento)
------------------------------------------------------------------
local function newFeature(key, label, short, prop, target, group)
	return {
		key = key, label = label, short = short, prop = prop, target = target, group = group,
		enabled = false, paused = false, orig = setmetatable({}, WEAK), mods = 0, gen = 0,
	}
end

local F = {
	shadows = newFeature("shadows", "Sombras de partes pequenas", "sombras", "CastShadow", false, "index"),
	lights = newFeature("lights", "Luzes sem sombra", "luzes", "Shadows", false, "index"),
	lod = newFeature("lod", "LOD (RenderFidelity)", "LOD", "RenderFidelity", Enum.RenderFidelity.Automatic, "index"),
	particles = newFeature("particles", "Efeitos decorativos (partículas/trilhas)", "efeitos", "Enabled", false, "index"),
	decals = newFeature("decals", "Texturas/Decals decorativos", "texturas", "Transparency", 1, "index"),
}
local function newPost(key, label, short, class)
	local f = newFeature(key, label, short, "Enabled", false, "post")
	f.class = class
	return f
end
F.bloom = newPost("bloom", "Pós: Bloom", "bloom", "BloomEffect")
F.sunrays = newPost("sunrays", "Pós: SunRays", "sunrays", "SunRaysEffect")
F.dof = newPost("dof", "Pós: DepthOfField", "dof", "DepthOfFieldEffect")
F.blur = newPost("blur", "Pós: Blur", "blur", "BlurEffect")

local INDEX = { F.shadows, F.lights, F.lod, F.particles, F.decals }
local POST = { F.bloom, F.sunrays, F.dof, F.blur }
local ALLF = { F.shadows, F.lights, F.lod, F.particles, F.decals, F.bloom, F.sunrays, F.dof, F.blur }

local function getProp(inst, prop) return inst[prop] end
local function setProp(inst, prop, value) inst[prop] = value end

local function applyMod(f, inst)
	if f.orig[inst] ~= nil then return end -- idempotente: nunca sobrescreve o original salvo
	local ok, cur = pcall(getProp, inst, f.prop)
	if not ok or cur == nil or cur == f.target then return end
	if f.key == "decals" and type(cur) == "number" and cur >= 1 then return end
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
		local lower = string.lower(name)
		for i = 1, #BLOCK_KEYWORDS do
			if string.find(lower, BLOCK_KEYWORDS[i], 1, true) then c = true; break end
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

-- sobe a cadeia de pais até o Workspace; falso se passar por personagem/Tool/câmera/interativo
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

local function register(inst)
	local cn = inst.ClassName
	if PART_CLASSES[cn] then
		local wantS = on(F.shadows) and inst.CastShadow and maxDim(inst) <= cfg.shadowMax
		local wantL = on(F.lod) and cn == "MeshPart" and inst.RenderFidelity ~= F.lod.target
		if not (wantS or wantL) then return end
		if not inst.Anchored or not isStaticDecorative(inst) then return end
		if wantS then applyMod(F.shadows, inst) end
		if wantL then applyMod(F.lod, inst) end
	elseif LIGHT_CLASSES[cn] then
		if on(F.lights) and inst.Shadows and hostSafe(inst.Parent) then applyMod(F.lights, inst) end
	elseif EMITTER_CLASSES[cn] then
		if not on(F.particles) or not inst.Enabled then return end
		if cn == "ParticleEmitter" and inst.Rate < cfg.minRate then return end
		local owner = ownerPart(inst)
		if owner and owner.Anchored and not nameBlocked(inst.Name) and isStaticDecorative(owner) then
			applyMod(F.particles, inst)
		end
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
-- 4. TRABALHO ÚNICO EM FATIAS (sem ciclo permanente)
------------------------------------------------------------------
local scan = { arr = nil, i = 1, n = 0, active = false }
local pend = { head = 1, tail = 0, items = {} }
local worker = { running = false, scheduled = false, id = 0, wait = MIN_WAIT, errors = 0 }
local idxActive = false
local refreshStatus, disableAll

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

local function sliceStep(deadline)
	if scan.active then
		local arr, i, n = scan.arr, scan.i, scan.n
		local cnt = 0
		while i <= n do
			local inst = arr[i]
			arr[i] = nil -- libera a referência assim que processa
			i = i + 1
			if inst.Parent ~= nil then handle(inst) end
			cnt = cnt + 1
			if cnt % 16 == 0 and clock() > deadline then break end
		end
		scan.i = i
		if i > n then scan.active, scan.arr = false, nil end
	end
	if not scan.active or clock() < deadline then drainPending(deadline) end
end

local function workPending()
	return scan.active or pend.head <= pend.tail
end

local function ensureWorker()
	if worker.running then return end -- idempotente: nunca cria dois trabalhadores
	worker.running = true
	worker.id = worker.id + 1
	local my = worker.id
	task.spawn(function()
		while worker.id == my do
			local t0 = clock()
			local slice = cfg.sliceMs
			if scan.active then slice = mathMax(slice, 3) end -- varredura inicial: termina logo
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
				worker.wait = mathMin(worker.wait * 1.5, MAX_WAIT) -- passou do orçamento: espaça mais
			else
				worker.wait = mathMax(worker.wait * 0.9, MIN_WAIT)
			end
			if not workPending() then break end -- terminou: NENHUM laço fica rodando
			task.wait(worker.wait)
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
	task.delay(0.4, function() -- debounce: junta rajadas de objetos novos
		worker.scheduled = false
		if idxActive and workPending() then ensureWorker() end
	end)
end

local function startScan()
	if not idxActive then return end
	scan.arr = Workspace:GetDescendants() -- UMA alocação; descartada ao fim
	scan.n, scan.i, scan.active = #scan.arr, 1, true
	ensureWorker()
end

local function onAdded(inst)
	local cn = inst.ClassName
	if PART_CLASSES[cn] or LIGHT_CLASSES[cn] or EMITTER_CLASSES[cn] or DECAL_CLASSES[cn] then
		if pend.tail - pend.head < MAX_PENDING then
			pend.tail = pend.tail + 1
			pend.items[pend.tail] = inst
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
	if idxActive then return end -- idempotente
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
	scan.arr, scan.n, scan.i, scan.active = nil, 0, 1, false
	pend = { head = 1, tail = 0, items = {} }
	worker.id = worker.id + 1
	worker.running = false
	ancCache = setmetatable({}, WEAK)
end

-- Ligar/desligar recursos por varredura
local function enableIndex(f)
	if f.enabled then return end
	f.enabled, f.paused = true, false
	Index_acquire()
	startScan() -- reaplica em tudo que já existe (applyMod é idempotente)
end

local function disableIndex(f)
	if not f.enabled then return end
	f.enabled = false
	restoreChunked(f) -- restaura aos poucos, sem travar
	if not anyIndexEnabled() then Index_release() end
	refreshStatus()
end

-- Reaplica um recurso depois de mudar sua configuração (restaura tudo e varre de novo)
local function refreshFeature(f)
	if not f.enabled then return end
	f.paused = true -- enquanto restaura, não aplica nada novo
	restoreChunked(f, function()
		f.paused = false
		startScan()
	end)
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
		restoreChunked(f, function() -- restaura com o alvo ANTIGO, só então troca
			f.target = enum
			f.paused = false
			startScan()
		end)
	else
		f.target = enum
	end
end

------------------------------------------------------------------
-- 5. RECURSOS GLOBAIS (poucas escritas, uma vez; original sempre guardado)
------------------------------------------------------------------
local function sameVal(a, b)
	if a == b then return true end
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

local function newGlobal(key, label, short, resolve, fallback)
	return { key = key, label = label, short = short, resolve = resolve, fallback = fallback, enabled = false, saved = {} }
end

local function techTarget()
	local ok, v = pcall(function() return Enum.Technology.Compatibility end)
	if ok and v then return v end
	ok, v = pcall(function() return Enum.LightingTechnology.Compatibility end)
	if ok and v then return v end
	return 2
end

local G = {
	gshadows = newGlobal("gshadows", "Sombras globais (desligar)", "sombras globais", function()
		return { { inst = Lighting, prop = "GlobalShadows", target = false } }
	end),
	terrain = newGlobal("terrain", "Terreno: sem grama / água simples", "terreno", function()
		local t = Workspace:FindFirstChildOfClass("Terrain")
		if not t then return {}, "sem Terrain neste jogo" end
		return {
			{ inst = t, prop = "Decoration", target = false },
			{ inst = t, prop = "WaterWaveSize", target = 0 },
			{ inst = t, prop = "WaterWaveSpeed", target = 0 },
			{ inst = t, prop = "WaterReflectance", target = 0 },
		}
	end),
	quality = newGlobal("quality", "Qualidade gráfica (nível fixo)", "qualidade", function()
		local okU, ugs = pcall(function() return UserSettings():GetService("UserGameSettings") end)
		if not okU or not ugs then return {}, "UserGameSettings indisponível" end
		local okE, tgt = pcall(function() return Enum.SavedQualitySetting["QualityLevel" .. cfg.qualityLevel] end)
		if not okE or not tgt then return {}, "nível inválido" end
		return { { inst = ugs, prop = "SavedQualityLevel", target = tgt } }
	end, function()
		-- plano B (executor): settings().Rendering.QualityLevel
		local okR, r = pcall(function() return settings().Rendering end)
		if not okR or not r then return {} end
		local okE, tgt = pcall(function() return Enum.QualityLevel["Level" .. string.format("%02d", cfg.qualityLevel)] end)
		if not okE or not tgt then return {} end
		return { { inst = r, prop = "QualityLevel", target = tgt } }
	end),
	technology = newGlobal("technology", "Lighting: modo Compatibility (executor)", "iluminação", function()
		local sh = sethiddenproperty or set_hidden_property or set_hidden_prop
		if type(sh) ~= "function" then return {}, "este executor não tem sethiddenproperty" end
		local gh = gethiddenproperty or get_hidden_property or get_hidden_prop
		return { {
			target = techTarget(),
			get = function()
				if type(gh) == "function" then
					local v = gh(Lighting, "Technology")
					return v
				end
				return Lighting.Technology
			end,
			set = function(v) sh(Lighting, "Technology", v) end,
		} }
	end),
}
local GLIST = { G.gshadows, G.terrain, G.quality, G.technology }

local function tryItems(g, items)
	for i = 1, #items do
		local it = items[i]
		local cur = itemGet(it)
		if cur ~= nil and not sameVal(cur, it.target) and itemSet(it, it.target) then
			local now = itemGet(it)
			if now ~= nil and sameVal(now, it.target) then
				g.saved[#g.saved + 1] = { it = it, orig = cur }
			else
				itemSet(it, cur) -- não "pegou": desfaz
			end
		end
	end
end

local function enableGlobal(g)
	if g.enabled then return end -- idempotente: não sobrescreve o original já salvo
	g.enabled = true
	g.saved = {}
	local ok, items, why = pcall(g.resolve)
	if ok and items then tryItems(g, items) end
	if #g.saved == 0 and g.fallback then
		local ok2, items2 = pcall(g.fallback)
		if ok2 and items2 then tryItems(g, items2) end
	end
	if #g.saved == 0 then
		notify("'" .. g.label .. "': sem efeito (" .. tostring(why or "já estava assim ou não suportado") .. ").", 5)
	end
end

local function disableGlobal(g)
	if not g.enabled then return end
	g.enabled = false
	for i = 1, #g.saved do
		local s = g.saved[i]
		local cur = itemGet(s.it)
		-- se o jogo mudou depois de nós, não brigamos
		if cur ~= nil and sameVal(cur, s.it.target) then itemSet(s.it, s.orig) end
	end
	g.saved = {}
end

local function refreshGlobal(g)
	if applyingProfile or not g.enabled then return end
	disableGlobal(g)
	enableGlobal(g)
end

------------------------------------------------------------------
-- 6. POST-PROCESSING (eventos; poucas instâncias)
------------------------------------------------------------------
local function applyPost(f, inst)
	if inst.ClassName == f.class then applyMod(f, inst) end
end

local function onPostChild(inst)
	for i = 1, #POST do
		if POST[i].enabled then applyPost(POST[i], inst) end
	end
end

local function scanRoot(root, f)
	if not root then return end
	local kids = root:GetChildren()
	for i = 1, #kids do applyPost(f, kids[i]) end
end

local postCam = nil
local bindPostCamera
bindPostCamera = function(scanNow)
	if conns.camAdded then
		conns.camAdded:Disconnect()
		conns.camAdded = nil
	end
	postCam = Workspace.CurrentCamera
	if postCam then
		conns.camAdded = postCam.ChildAdded:Connect(onPostChild)
		if scanNow then
			for i = 1, #POST do
				if POST[i].enabled then scanRoot(postCam, POST[i]) end
			end
		end
	end
end

local function anyPost()
	for i = 1, #POST do
		if POST[i].enabled then return true end
	end
	return false
end

local function enablePost(f)
	if f.enabled then return end
	f.enabled = true
	if not conns.lightAdded then conns.lightAdded = Lighting.ChildAdded:Connect(onPostChild) end
	if not conns.camChanged then
		conns.camChanged = Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function() bindPostCamera(true) end)
	end
	if not conns.camAdded then bindPostCamera(false) end
	scanRoot(Lighting, f)
	scanRoot(Workspace.CurrentCamera, f)
end

local function disablePost(f)
	if not f.enabled then return end
	f.enabled = false
	restoreAllSync(f)
	if not anyPost() then
		for _, k in ipairs({ "lightAdded", "camAdded", "camChanged" }) do
			if conns[k] then
				conns[k]:Disconnect()
				conns[k] = nil
			end
		end
	end
end

------------------------------------------------------------------
-- 7. STATUS
------------------------------------------------------------------
local lastStatusText = ""
refreshStatus = function()
	if not statusP then return end
	local postMods = 0
	for i = 1, #POST do postMods = postMods + POST[i].mods end
	local gl = {}
	for i = 1, #GLIST do
		local g = GLIST[i]
		if g.enabled and #g.saved > 0 then gl[#gl + 1] = g.short end
	end
	local remaining = 0
	if scan.active then remaining = remaining + (scan.n - scan.i + 1) end
	remaining = remaining + mathMax(0, pend.tail - pend.head + 1)
	local state = "ocioso (nenhum laço rodando)"
	if remaining > 0 then state = "aplicando… faltam " .. remaining end
	local text = string.format(
		"Perfil: %s\nAplicados — Sombras %d | Luzes %d | LOD %d | Efeitos %d | Texturas %d | Pós-FX %d\nGlobais: %s\nEstado: %s",
		currentProfile or "manual",
		F.shadows.mods, F.lights.mods, F.lod.mods, F.particles.mods, F.decals.mods, postMods,
		(#gl > 0) and table.concat(gl, ", ") or "nenhum", state)
	if text ~= lastStatusText then
		lastStatusText = text
		pcall(function() statusP:SetValue(text) end)
	end
end

------------------------------------------------------------------
-- 8. TOGGLES, PERFIL E RESTAURAÇÃO (tudo definido ANTES da interface)
------------------------------------------------------------------
-- Alterna via o closure do ODH (atualiza o visual e chama o callback). Se a UI não
-- existir/sincronizar, aplica direto pelo handler: o efeito nunca depende da UI.
local function setToggle(key, desired)
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

local lodDropdown, sliders = nil, {}

local function applyProfile(name)
	local p = PROFILES[name]
	if not p then return end
	currentProfile = name
	applyingProfile = true

	local wasOn = {}
	for _, key in ipairs(FEATURE_ORDER) do wasOn[key] = uiState[key] == true end
	local old = { shadowMax = cfg.shadowMax, minRate = cfg.minRate, qualityLevel = cfg.qualityLevel }

	for k, v in pairs(p.cfg) do cfg[k] = v end
	pcall(setLodMode, p.cfg.lodMode) -- troca o alvo do LOD primeiro (reaplica se já estiver ligado)
	for _, key in ipairs(FEATURE_ORDER) do setToggle(key, p.features[key] == true) end

	-- recursos que já estavam ligados e continuam ligados: reaplica só se a configuração mudou
	if wasOn.shadows and F.shadows.enabled and old.shadowMax ~= cfg.shadowMax then refreshFeature(F.shadows) end
	if wasOn.particles and F.particles.enabled and old.minRate ~= cfg.minRate then refreshFeature(F.particles) end
	if wasOn.quality and G.quality.enabled and old.qualityLevel ~= cfg.qualityLevel then
		disableGlobal(G.quality)
		enableGlobal(G.quality)
	end

	-- sincroniza só o visual (se algo falhar aqui, o efeito já valeu)
	for _, id in ipairs({ "shadowMax", "minRate", "qualityLevel", "sliceMs" }) do
		local sl = sliders[id]
		if sl then pcall(function() sl:SetValue(cfg[id]) end) end
	end
	if lodDropdown then pcall(function() lodDropdown:Select(p.cfg.lodMode) end) end
	for k, v in pairs(p.cfg) do cfg[k] = v end -- garante o valor final do perfil

	applyingProfile = false
	refreshStatus()
	notify("Perfil " .. name .. " aplicado.", 2)
end

local function restoreEverything(silent)
	for _, key in ipairs(FEATURE_ORDER) do setToggle(key, false) end
	for i = 1, #ALLF do restoreAllSync(ALLF[i]) end -- garante restauração completa e imediata
	for i = 1, #GLIST do disableGlobal(GLIST[i]) end
	if anyPost() then
		for i = 1, #POST do POST[i].enabled = false end
	end
	for _, k in ipairs({ "lightAdded", "camAdded", "camChanged" }) do
		if conns[k] then
			conns[k]:Disconnect()
			conns[k] = nil
		end
	end
	for i = 1, #INDEX do INDEX[i].enabled = false end
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
-- 9. BENCHMARK (só mede quando você pede; nada fica rodando)
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
	local okC, c = pcall(function() return Stats.InstanceCount end)
	out.count = okC and c or nil
	return out
end

-- mede `seconds` de frames (conexão só existe durante a medição)
local function measure(seconds, cb)
	local samples, n = {}, 0
	local conn = RunService.Heartbeat:Connect(function(dt)
		if n < 3000 then
			n = n + 1
			samples[n] = dt
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

local function runMeasure()
	if benchBusy then return end
	benchBusy = true
	benchReport("Medindo 8 s… jogue normalmente.")
	measure(8, function(r)
		benchBusy = false
		local m = r.mem
		benchReport(string.format("FPS médio %s | 1%% piores %s | picos>50ms %s\nRAM total %s MB | Lua %s | Instâncias %s | Texturas %s",
			fmt(r.fps), fmt(r.low1), tostring(r.spikes or "?"), fmt(m.total, 0), fmt(m.lua), fmt(m.inst), fmt(m.tex)))
	end)
end

local function runAB()
	if benchBusy then return end
	local want = {}
	local any = false
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
		for _, key in ipairs(FEATURE_ORDER) do setToggle(key, want[key]) end
		local waited = 0
		while workPending() and waited < 40 do
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
			"SEM → COM otimizações\nFPS médio %s → %s (%s)\n1%% piores %s → %s (%s)\nPicos>50ms %s → %s\nRAM total %s → %s MB (%s)\nLua %s → %s | Instâncias %s → %s | Texturas %s → %s",
			fmt(A.fps), fmt(B.fps), d(A.fps, B.fps), fmt(A.low1), fmt(B.low1), d(A.low1, B.low1),
			tostring(A.spikes or "?"), tostring(B.spikes or "?"),
			fmt(A.mem.total, 0), fmt(B.mem.total, 0), d(A.mem.total, B.mem.total, 0),
			fmt(A.mem.lua), fmt(B.mem.lua), fmt(A.mem.inst), fmt(B.mem.inst), fmt(A.mem.tex), fmt(B.mem.tex)))
		notify("Teste A/B concluído (resultado no painel Benchmark).", 4)
	end)
end

------------------------------------------------------------------
-- 10. INTERFACE (somente métodos do guia ODH; cada passo isolado em pcall)
------------------------------------------------------------------
local ready = false -- ignora callbacks disparados durante a criação dos controles
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
	return firstSection -- se o ODH recusar seções extras, os controles vão para a primeira
end

local function addToggle(section, key, label, onChange)
	handlers[key] = onChange
	toggles[key] = add(section, "AddToggle", "Toggle " .. label, label, function(state)
		state = state == true
		if uiState[key] == state then return end -- idempotente
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
				task.delay(0.1, function() setToggle(g.key, false) end) -- nada aplicou: volta o toggle
			end
		else
			disableGlobal(g)
		end
	end)
end

local function postToggle(section, f)
	addToggle(section, f.key, f.label, function(on)
		if on then enablePost(f) else disablePost(f) end
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
	"Só altera visuais locais e guarda o original de tudo. Nunca toca Tools, personagens, coletáveis, interativos, rede, ownership ou colisão. Nenhum laço fica rodando: cada recurso aplica uma vez e para.")
add(secProfile, "AddDropdown", "Perfil", "Perfil", { "LOW", "MEDIUM", "AGGRESSIVE" }, function(selected)
	selectedProfile = selected
	if ready then applyProfile(selected) end
end)
statusP = add(secProfile, "AddParagraph", "Status", "Status",
	"Nada ativo. Escolha um perfil ou ligue os recursos abaixo.", true)
add(secProfile, "AddButton", "Reaplicar", "Reaplicar perfil selecionado", function()
	if selectedProfile then applyProfile(selectedProfile) else notify("Escolha um perfil primeiro.", 2) end
end)

-- Render Optimizer (varredura única)
local secRender = newSection("Render Optimizer", "Aplica uma vez e para")
indexToggle(secRender, F.shadows)
indexToggle(secRender, F.lights)
indexToggle(secRender, F.lod)
lodDropdown = add(secRender, "AddDropdown", "LOD modo", "LOD: modo", { "Automatic", "Performance" }, function(selected)
	local ok, err = pcall(setLodMode, selected)
	if not ok then print("[Perf] LOD: " .. tostring(err)) end
end)
indexToggle(secRender, F.particles)
indexToggle(secRender, F.decals)

-- Globais
local secGlobal = newSection("Gráficos globais", "Mudam o cliente inteiro (só local)")
globalToggle(secGlobal, G.gshadows)
globalToggle(secGlobal, G.terrain)
globalToggle(secGlobal, G.quality)
globalToggle(secGlobal, G.technology)

-- Post-processing
local secPost = newSection("Post-Processing", "Desativação individual")
postToggle(secPost, F.bloom)
postToggle(secPost, F.sunrays)
postToggle(secPost, F.dof)
postToggle(secPost, F.blur)

-- Ajustes
local secTune = newSection("Ajustes", "Valores usados na varredura")
addSlider(secTune, "shadowMax", "Tamanho máx. p/ tirar sombra (studs)", 1, 100, function() debounceRefresh(F.shadows) end)
addSlider(secTune, "minRate", "Efeitos: manter os com Rate abaixo de", 0, 100, function() debounceRefresh(F.particles) end)
addSlider(secTune, "qualityLevel", "Nível gráfico fixo (1 a 10)", 1, 10, function()
	if not applyingProfile and G.quality.enabled then
		task.delay(0.8, function() refreshGlobal(G.quality) end)
	end
end)
addSlider(secTune, "sliceMs", "Orçamento por fatia (ms)", 0.5, 4, nil)

-- Benchmark
local secBench = newSection("Benchmark", "Mede o ganho de verdade")
benchP = add(secBench, "AddParagraph", "Resultado", "Resultado",
	"Use 'Medir agora' ou o teste A/B (liga/desliga e compara).", true)
add(secBench, "AddButton", "Medir", "Medir agora (8 s)", runMeasure)
add(secBench, "AddButton", "AB", "Teste A/B automático (~35 s)", runAB)

-- Segurança
local secSafety = newSection("Segurança", "Restauração")
add(secSafety, "AddButton", "Restaurar tudo", "Restaurar tudo", function()
	restoreEverything(false)
end)

-- Ajuda
local secHelp = newSection("Ajuda", "O que cada opção faz")
add(secHelp, "AddParagraph", "Ajuda render", "Render Optimizer",
	"Sombras: tira a sombra de partes pequenas (o slider define o tamanho). Luzes: desliga a sombra de luzes decorativas. "
	.. "LOD: troca MeshParts por versão simplificada. Efeitos: desliga partículas/trilhas decorativas (o slider mantém os mais leves). "
	.. "Texturas: esconde decals/texturas de partes decorativas. Tudo é feito uma vez e restaurável.")
add(secHelp, "AddParagraph", "Ajuda globais", "Gráficos globais",
	"Sombras globais: desliga TODAS as sombras. Terreno: sem grama/ondas. Qualidade: fixa o nível gráfico do Roblox (abaixo de 4 o motor desliga sombras sozinho); é uma configuração salva, por isso o plugin restaura ao desligar. "
	.. "Lighting Compatibility: modo de iluminação mais leve (depende do executor e muda bastante o visual).")
add(secHelp, "AddParagraph", "Ajuda bench", "Benchmark",
	"FPS 'médio' e '1% piores' mostram estabilidade; RAM total/Lua/Instâncias/Texturas mostram se algo está crescendo. O teste A/B desliga tudo, mede, reaplica e mede de novo. Resultados variam com o jogo: repita 2 ou 3 vezes.")

-- Diagnóstico (só aparece se algo falhou ao montar a interface)
if #uiErrors > 0 then
	notify("Perf: " .. #uiErrors .. " controle(s) falharam ao carregar. Veja o console (F9).", 6)
	add(secSafety, "AddParagraph", "Diagnóstico", "Diagnóstico da interface", table.concat(uiErrors, "\n"))
end

-- Libera os callbacks após a criação (cobre callbacks disparados logo depois da montagem)
task.delay(0.5, function() ready = true end)
