--> Overdrive H On Top.
--> PERFORMANCE OPTIMIZER v2 — plugin independente para o ODH
--[[
  Tudo aqui é LOCAL ao seu cliente: nada toca personagem, Tools, rede, física
  ou replicação, então não existe "liso pra mim, travando pros outros".

  CORREÇÕES DA v2
  - applyProfile (e todas as funções) agora são definidas ANTES da interface. Na v1 o
    dropdown de perfil chamava applyProfile antes dele existir: se o ODH dispara o
    callback ao criar o dropdown, o script morria ali e só a 1ª seção aparecia.
  - Interface resiliente: cada seção/controle é criado dentro de pcall. Se algo falhar,
    o resto continua (e a falha aparece no Notify/console/Diagnóstico).
  - Perfil aplica em tempo real (sem reiniciar) e há um painel de Status
    "otimizados/indexados" para você VER o efeito.
  - O laço principal roda em pcall (um erro não mata a otimização em silêncio).
  - Ocultação distante menos restritiva (continua sem tocar em colisão/toque/prompts/GUIs/
    tags/atributos/nomes de coletáveis).

  AVALIAÇÃO DE CUSTO x BENEFÍCIO (resumo)
  - Particle / Shadow / LOD / Hide: por item = 1 leitura de Position + 1 comparação
    de distância ao quadrado. Só ESCREVE propriedade quando o item muda de zona
    (com histerese). Passes em lotes com orçamento de tempo, fora de
    RenderStepped/Heartbeat (laço task.wait), pulados com a câmera parada (adaptativo).
  - LOD: RenderFidelity nativo (Automatic/Performance). "Precise" não é oferecido:
    força detalhe máximo, o oposto do objetivo.
  - Post-Processing: poucas instâncias, só eventos ChildAdded (custo ~0).
  - Descoberta: travessia incremental (sem GetDescendants gigante) + DescendantAdded em fila.
  - Governor: ciclo estourou o orçamento -> intervalo sobe e orçamento cai; estouros
    repetidos desativam sozinhos a otimização mais cara.

  Exclusões (nunca tocados): personagens/NPCs (Humanoid), Tools, Accessories, itens não
  ancorados, partes com ProximityPrompt/ClickDetector/TouchTransmitter/Gui, tags,
  atributos, e nomes da lista BLOCK_KEYWORDS. Ocultação só em partes ancoradas SEM colisão.
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
local mathMin, mathMax = math.min, math.max
local WEAK = { __mode = "k" }

local function notify(msg, dur)
	pcall(function() shared.Notify(msg, dur or 3) end)
end

------------------------------------------------------------------
-- 1. CONFIGURAÇÃO
------------------------------------------------------------------
local ICON_PATH = "/0ppingo/PERF/refs/heads/main/icon"

local PROFILES = {
	LOW = {
		near = 150, far = 500, interval = 0.15, budgetMs = 0.5, particleZone = "far", lodMode = "Automatic",
		features = {
			particles = true, shadows = false, lod = false, hide = false,
			bloom = true, sunrays = true, dof = false, blur = false,
			adaptive = false, monitor = true,
		},
	},
	MEDIUM = {
		near = 140, far = 400, interval = 0.12, budgetMs = 0.8, particleZone = "far", lodMode = "Automatic",
		features = {
			particles = true, shadows = true, lod = true, hide = true,
			bloom = true, sunrays = true, dof = true, blur = false,
			adaptive = false, monitor = true,
		},
	},
	AGGRESSIVE = {
		near = 80, far = 220, interval = 0.1, budgetMs = 1.0, particleZone = "near", lodMode = "Performance",
		features = {
			particles = true, shadows = true, lod = true, hide = true,
			bloom = true, sunrays = true, dof = true, blur = true,
			adaptive = true, monitor = true,
		},
	},
}

local FEATURE_ORDER = {
	"particles", "shadows", "lod", "hide",
	"bloom", "sunrays", "dof", "blur",
	"adaptive", "monitor",
}

local PART_CLASSES = { Part = true, MeshPart = true, UnionOperation = true, WedgePart = true, CornerWedgePart = true }
local EMITTER_CLASSES = { ParticleEmitter = true, Fire = true, Smoke = true, Sparkles = true }
local DESCEND_CLASSES = { Model = true, Folder = true, Actor = true, WorldModel = true, Attachment = true }

-- Nomes que indicam função/coletável/interativo: nunca são tocados. Edite à vontade.
local BLOCK_KEYWORDS = {
	"coin", "token", "collect", "pickup", "orb", "gem", "loot", "drop", "reward", "crate",
	"chest", "spawn", "portal", "teleport", "door", "button", "prompt", "click", "shop",
	"npc", "tool", "weapon", "boss", "enemy", "mob", "heal", "powerup", "cash", "money",
	"fruit", "egg", "hitbox", "trigger", "damage", "kill", "lava", "interact", "item",
	"checkpoint", "goal", "finish", "target", "bomb", "projectile", "bullet", "ball",
	"key", "seat", "vehicle", "star", "gift", "present", "candies2026",
}

local HYSTERESIS = 0.9      -- para voltar ao detalhe, precisa entrar a 90% da distância
local MOVE_THRESHOLD = 6    -- studs que a câmera precisa andar para um novo passe (adaptativo)
local CHECK_EVERY = 32      -- itens entre checagens de relógio
local MAX_PENDING = 30000
local MIN_BUDGET = 0.0002
local MAX_INTERVAL = 0.5
local IDLE_WAIT = 0.25
local OVERRUN_LIMIT = 6
local MIN_HIDE_SIZE = 4     -- partes sem colisão menores que isso podem ser coletáveis: não oculta

local cfg = { near = 140, far = 400, interval = 0.12, budget = 0.0008, particleZone = "far" }

local rt = {
	running = false, loopId = 0,
	interval = cfg.interval, budget = cfg.budget,
	emaSpent = 0, overruns = 0, errors = 0, lastErr = "",
	adaptive = false, lastStatus = 0,
	worstF = nil, worstCost = 0,
}

local mon = { conn = nil, ema = 1 / 60, spikes = 0, lastSpikes = 0, loopId = 0, label = nil }

local conns = {}
local toggles, uiState, handlers = {}, {}, {}
local currentProfile = nil
local statusP = nil

------------------------------------------------------------------
-- 2. FEATURES (estado original sempre guardado em f.orig)
------------------------------------------------------------------
local function newFeature(key, label, prop, target, withOwner)
	return {
		key = key, label = label, prop = prop, target = target,
		enabled = false, draining = false,
		list = {}, known = setmetatable({}, WEAK), orig = setmetatable({}, WEAK),
		owner = withOwner and setmetatable({}, WEAK) or nil,
		cursor = 1, inPass = false, dirty = false, lastCam = nil,
		sq = 0, backSq = 0, mods = 0, cost = 0,
	}
end

local F = {
	particles = newFeature("particles", "Particle Culling", "Enabled", false, true),
	shadows = newFeature("shadows", "Shadow Culling", "CastShadow", false, false),
	lod = newFeature("lod", "LOD (RenderFidelity)", "RenderFidelity", Enum.RenderFidelity.Automatic, false),
	hide = newFeature("hide", "Distance Culling (ocultar)", "LocalTransparencyModifier", 1, false),
}
local function newPost(key, label, class)
	local f = newFeature(key, label, "Enabled", false, false)
	f.class = class
	return f
end
F.bloom = newPost("bloom", "Pós: Bloom", "BloomEffect")
F.sunrays = newPost("sunrays", "Pós: SunRays", "SunRaysEffect")
F.dof = newPost("dof", "Pós: DepthOfField", "DepthOfFieldEffect")
F.blur = newPost("blur", "Pós: Blur", "BlurEffect")

local WORLD = { F.particles, F.shadows, F.lod, F.hide }
local POST = { F.bloom, F.sunrays, F.dof, F.blur }
local ALL = { F.particles, F.shadows, F.lod, F.hide, F.bloom, F.sunrays, F.dof, F.blur }

local function getProp(inst, prop) return inst[prop] end
local function setProp(inst, prop, value) inst[prop] = value end

local function applyMod(f, inst)
	local ok, cur = pcall(getProp, inst, f.prop)
	if not ok or cur == nil or cur == f.target then return end
	if pcall(setProp, inst, f.prop, f.target) then
		f.orig[inst] = cur -- só guarda o original se a escrita deu certo
		f.mods = f.mods + 1
	end
end

local function restoreMod(f, inst)
	local o = f.orig[inst]
	if o == nil then return end
	f.orig[inst] = nil
	f.mods = mathMax(0, f.mods - 1)
	local ok, cur = pcall(getProp, inst, f.prop)
	-- se o jogo mudou o valor depois de nós, não sobrescrevemos
	if ok and cur == f.target then pcall(setProp, inst, f.prop, o) end
end

local function releaseFeature(f)
	f.list = {}
	f.known = setmetatable({}, WEAK)
	f.orig = setmetatable({}, WEAK)
	if f.owner then f.owner = setmetatable({}, WEAK) end
	f.mods, f.cursor, f.inPass, f.dirty, f.lastCam, f.draining = 0, 1, false, false, nil, false
end

-- Restauração incremental (ou total, com deadline = math.huge)
local function drainStep(f, deadline)
	local list, owner = f.list, f.owner
	local work = 0
	while #list > 0 do
		local n = #list
		local inst = list[n]
		list[n] = nil
		restoreMod(f, inst)
		f.known[inst] = nil
		if owner then owner[inst] = nil end
		work = work + 1
		if work >= 64 then
			work = 0
			if clock() > deadline then return false end
		end
	end
	releaseFeature(f)
	return true
end

local function drainNow(f) drainStep(f, math.huge) end

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

-- Filhos diretos (sem alocar tabela): usado em ancestrais, que podem ter milhares de filhos
local function directInteractive(inst)
	return inst:FindFirstChildOfClass("ProximityPrompt") ~= nil
		or inst:FindFirstChildOfClass("ClickDetector") ~= nil
		or inst:FindFirstChildOfClass("TouchTransmitter") ~= nil
		or inst:FindFirstChildOfClass("BillboardGui") ~= nil
		or inst:FindFirstChildOfClass("SurfaceGui") ~= nil
end

-- Partes têm poucos descendentes: dá para olhar também dentro de Attachments
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

-- parte ancorada, não interativa, fora de personagem/Tool/NPC => "decorativa estática"
local function isStaticDecorative(part)
	if nameBlocked(part.Name) or partInteractive(part) then return false end
	if #part:GetTags() > 0 or next(part:GetAttributes()) ~= nil then return false end -- alguém usa: função desconhecida
	local a, depth = part.Parent, 0
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

local function hideSizeOk(part)
	local s = part.Size
	return mathMax(s.X, s.Y, s.Z) >= MIN_HIDE_SIZE
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

local function addItem(f, inst, owner)
	if f.known[inst] then return end
	f.known[inst] = true
	local list = f.list
	list[#list + 1] = inst
	if owner then f.owner[inst] = owner end
	f.dirty = true
end

local function register(inst)
	local cn = inst.ClassName
	if PART_CLASSES[cn] then
		if not inst.Anchored then return end -- móvel/físico: não mexe
		local wantShadow = F.shadows.enabled and inst.CastShadow and not F.shadows.known[inst]
		local wantLod = F.lod.enabled and cn == "MeshPart" and not F.lod.known[inst]
			and inst.RenderFidelity ~= F.lod.target
		local wantHide = F.hide.enabled and not F.hide.known[inst] and inst.Transparency < 1
			and not inst.CanCollide and hideSizeOk(inst)
		if not (wantShadow or wantLod or wantHide) then return end
		if not isStaticDecorative(inst) then return end
		if wantShadow then addItem(F.shadows, inst) end
		if wantLod then addItem(F.lod, inst) end
		if wantHide then addItem(F.hide, inst) end
	elseif EMITTER_CLASSES[cn] then
		local f = F.particles
		if not f.enabled or f.known[inst] or not inst.Enabled then return end
		local owner = ownerPart(inst)
		if owner and PART_CLASSES[owner.ClassName] and owner.Anchored
			and not nameBlocked(inst.Name) and isStaticDecorative(owner) then
			addItem(f, inst, owner)
		end
	end
end

------------------------------------------------------------------
-- 4. DESCOBERTA INCREMENTAL (sem GetDescendants gigante)
------------------------------------------------------------------
local scan = { stack = {}, n = 0, kids = nil, ki = 1, active = false }
local pend = { head = 1, tail = 0, items = {} }

local function startScan()
	scan.stack, scan.n, scan.kids, scan.ki, scan.active = { Workspace }, 1, nil, 1, true
end

local function stopScan()
	scan.stack, scan.n, scan.kids, scan.ki, scan.active = {}, 0, nil, 1, false
	pend = { head = 1, tail = 0, items = {} }
end

local function scanStep(deadline)
	local stack, n = scan.stack, scan.n
	local kids, ki = scan.kids, scan.ki
	local work = 0
	while true do
		if not kids then
			if n == 0 then break end
			local container = stack[n]
			stack[n] = nil
			n = n - 1
			if container == Workspace or container.Parent ~= nil then
				kids = container:GetChildren()
				ki = 1
				work = work + 4
			end
		end
		if kids then
			local total = #kids
			while ki <= total do
				local kid = kids[ki]
				ki = ki + 1
				local cn = kid.ClassName
				local isPart = PART_CLASSES[cn]
				if isPart or EMITTER_CLASSES[cn] then register(kid) end
				if isPart or DESCEND_CLASSES[cn] then
					-- não desce em personagens/NPCs
					if not (cn == "Model" and kid:FindFirstChildOfClass("Humanoid")) then
						n = n + 1
						stack[n] = kid
					end
				end
				work = work + 1
				if work >= 64 then
					work = 0
					if clock() > deadline then
						scan.n, scan.kids, scan.ki = n, kids, ki
						return
					end
				end
			end
			kids = nil
		end
	end
	scan.n, scan.kids, scan.ki, scan.active = 0, nil, 1, false
end

local function drainPending(deadline)
	local p = pend
	local work = 0
	while p.head <= p.tail do
		local inst = p.items[p.head]
		p.items[p.head] = nil
		p.head = p.head + 1
		if inst.Parent ~= nil then register(inst) end
		work = work + 1
		if work >= 64 then
			work = 0
			if clock() > deadline then break end
		end
	end
	if p.head > p.tail then p.head, p.tail = 1, 0 end
end

local function onDescendantAdded(inst)
	local cn = inst.ClassName
	if PART_CLASSES[cn] or EMITTER_CLASSES[cn] then
		local p = pend
		if p.tail - p.head < MAX_PENDING then
			p.tail = p.tail + 1
			p.items[p.tail] = inst
		end
	end
end

------------------------------------------------------------------
-- 5. PASSE DE DISTÂNCIA (em lotes, com orçamento)
------------------------------------------------------------------
local function stepFeature(f, camPos, deadline)
	local list = f.list
	if not f.inPass then
		if #list == 0 then f.dirty = false; return false end
		local last = f.lastCam
		if rt.adaptive and not f.dirty and last and (camPos - last).Magnitude < MOVE_THRESHOLD then
			return false -- câmera parada: nada a recalcular
		end
		f.inPass, f.lastCam, f.dirty, f.cursor = true, camPos, false, 1
	end
	local orig, owner, known = f.orig, f.owner, f.known
	local sq, backSq = f.sq, f.backSq
	local cx, cy, cz = camPos.X, camPos.Y, camPos.Z
	local i, work = f.cursor, 0
	while true do
		local n = #list
		if i > n then
			f.inPass, f.cursor = false, 1
			return true
		end
		local inst = list[i]
		local part = inst
		if owner then part = owner[inst] end
		if part ~= nil and inst.Parent ~= nil and part.Parent ~= nil then
			local p = part.Position
			local dx, dy, dz = p.X - cx, p.Y - cy, p.Z - cz
			local d2 = dx * dx + dy * dy + dz * dz -- distância ao quadrado: sem raiz
			if orig[inst] ~= nil then
				if d2 < backSq then restoreMod(f, inst) end
			elseif d2 > sq then
				applyMod(f, inst)
			end
			i = i + 1
		else
			-- destruído / saiu do streaming: esquece (swap-remove)
			if orig[inst] ~= nil then
				orig[inst] = nil
				f.mods = mathMax(0, f.mods - 1)
			end
			known[inst] = nil
			if owner then owner[inst] = nil end
			list[i] = list[n]
			list[n] = nil
		end
		work = work + 1
		if work >= CHECK_EVERY then
			work = 0
			if clock() > deadline then
				f.cursor = i
				return true
			end
		end
	end
end

local function setZone(f, sq, back)
	f.sq, f.backSq, f.dirty = sq, back, true
end

local function recalc()
	local near = cfg.near
	local far = mathMax(cfg.far, near + 20)
	local nSq, nBack = near * near, (near * HYSTERESIS) ^ 2
	local fSq, fBack = far * far, (far * HYSTERESIS) ^ 2
	setZone(F.shadows, nSq, nBack)
	setZone(F.lod, nSq, nBack)
	setZone(F.hide, fSq, fBack)
	if cfg.particleZone == "near" then
		setZone(F.particles, nSq, nBack)
	else
		setZone(F.particles, fSq, fBack)
	end
end
recalc()

------------------------------------------------------------------
-- 6. STATUS (otimizados/indexados — para você VER o efeito)
------------------------------------------------------------------
local lastStatusText = ""
local function refreshStatus()
	if not statusP then return end
	local postMods = 0
	for i = 1, #POST do postMods = postMods + POST[i].mods end
	local text = string.format(
		"Perfil: %s\nOtimizados/indexados — Partículas %d/%d | Sombras %d/%d | LOD %d/%d | Ocultos %d/%d | Pós-FX %d\nCiclo %.2f ms | intervalo %d ms",
		currentProfile or "manual",
		F.particles.mods, #F.particles.list, F.shadows.mods, #F.shadows.list,
		F.lod.mods, #F.lod.list, F.hide.mods, #F.hide.list, postMods,
		rt.emaSpent * 1000, math.floor(rt.interval * 1000))
	if text ~= lastStatusText then
		lastStatusText = text
		pcall(function() statusP:SetValue(text) end)
	end
end

------------------------------------------------------------------
-- 7. SCHEDULER + GOVERNOR (orçamento de tempo)
------------------------------------------------------------------
local function anyEnabled(set)
	for i = 1, #set do
		if set[i].enabled then return true end
	end
	return false
end

local function loopNeeded()
	if scan.active or pend.head <= pend.tail then return true end
	for i = 1, #WORLD do
		local f = WORLD[i]
		if f.enabled or f.draining then return true end
	end
	return false
end

local setToggle -- definido na seção 9

local function autoDisable(f)
	notify("Otimizador: '" .. f.label .. "' desativado (custo alto).", 4)
	setToggle(f.key, false)
end

local function governor(spent)
	rt.emaSpent = rt.emaSpent * 0.8 + spent * 0.2
	if spent > rt.budget * 2 + 0.0005 or spent > 0.004 then
		rt.interval = mathMin(rt.interval * 1.5, MAX_INTERVAL)
		rt.budget = mathMax(rt.budget * 0.75, MIN_BUDGET)
		rt.overruns = rt.overruns + 1
		if rt.overruns >= OVERRUN_LIMIT then
			rt.overruns = 0
			local f = rt.worstF
			if f and f.enabled and rt.worstCost > spent * 0.5 then autoDisable(f) end
		end
	else
		if rt.overruns > 0 then rt.overruns = mathMax(0, rt.overruns - 0.5) end
		if rt.emaSpent < rt.budget * 0.5 then
			rt.interval = mathMax(rt.interval * 0.95, cfg.interval)
			rt.budget = mathMin(rt.budget * 1.05, cfg.budget)
		end
	end
	if mon.conn and mon.spikes > mon.lastSpikes then
		mon.lastSpikes = mon.spikes
		if rt.emaSpent > rt.budget * 0.6 then
			rt.interval = mathMin(rt.interval * 1.25, MAX_INTERVAL)
		end
	end
end

local function runCycle(t0, deadline, rotate)
	local worked = false
	rt.worstF, rt.worstCost = nil, 0

	for i = 1, #WORLD do
		local f = WORLD[i]
		if f.draining then
			worked = true
			drainStep(f, deadline)
		end
	end

	-- descoberta usa no máximo 70% do orçamento; o resto fica para os passes
	local discoverDeadline = t0 + (deadline - t0) * 0.7
	if scan.active then worked = true; scanStep(discoverDeadline) end
	if pend.head <= pend.tail then worked = true; drainPending(discoverDeadline) end

	local cam = Workspace.CurrentCamera
	if cam then
		local camPos = cam.CFrame.Position
		local count = #WORLD
		for k = 0, count - 1 do
			local f = WORLD[(rotate + k) % count + 1]
			if f.enabled and clock() < deadline then
				local t = clock()
				if stepFeature(f, camPos, deadline) then worked = true end
				local dt = clock() - t
				f.cost = f.cost * 0.8 + dt * 0.2
				if dt > rt.worstCost then rt.worstF, rt.worstCost = f, dt end
			end
		end
	end
	return worked
end

local restoreEverything -- definido na seção 9

local function ensureLoop()
	if rt.running then return end -- idempotente: nunca cria dois loops
	rt.running = true
	rt.loopId = rt.loopId + 1
	local myId = rt.loopId
	task.spawn(function()
		local rotate = 0
		while rt.loopId == myId do
			local t0 = clock()
			local ok, worked = pcall(runCycle, t0, t0 + rt.budget, rotate)
			if ok then
				rt.errors = 0
			else
				rt.errors = rt.errors + 1
				rt.lastErr = tostring(worked)
				worked = false
				print("[Perf] erro no ciclo: " .. rt.lastErr)
				if rt.errors >= 5 then
					rt.errors = 0
					notify("Otimizador parado por erros repetidos (tudo restaurado). Veja o console.", 6)
					rt.running = false
					restoreEverything(true)
					return
				end
			end
			rotate = rotate + 1
			governor(clock() - t0)
			if t0 - rt.lastStatus >= 1 then
				rt.lastStatus = t0
				refreshStatus()
			end
			if not loopNeeded() then break end
			local w = rt.interval
			if rt.adaptive and not worked then w = mathMax(w, IDLE_WAIT) end
			task.wait(w)
		end
		if rt.loopId == myId then
			rt.running = false
			refreshStatus()
		end
	end)
end

------------------------------------------------------------------
-- 8. ATIVAR / DESATIVAR (idempotente, conexões gerenciadas)
------------------------------------------------------------------
local function enableWorld(f)
	if f.enabled then return end
	if f.draining then drainNow(f) end
	f.enabled, f.dirty = true, true
	if not conns.added then
		conns.added = Workspace.DescendantAdded:Connect(onDescendantAdded)
	end
	startScan() -- reindexa para que o novo recurso enxergue os objetos já existentes
	ensureLoop()
end

local function disableWorld(f)
	if not f.enabled then return end
	f.enabled = false
	f.draining = true -- restaura aos poucos, sem travar
	if not anyEnabled(WORLD) then
		if conns.added then
			conns.added:Disconnect()
			conns.added = nil
		end
		stopScan()
	end
	ensureLoop()
end

-- Post-processing
local function pruneDead(f)
	local list, j, n = f.list, 0, #f.list
	for i = 1, n do
		local inst = list[i]
		if inst.Parent ~= nil then
			j = j + 1
			list[j] = inst
		else
			if f.orig[inst] ~= nil then
				f.orig[inst] = nil
				f.mods = mathMax(0, f.mods - 1)
			end
			f.known[inst] = nil
		end
	end
	for i = j + 1, n do list[i] = nil end
end

local function applyPost(f, inst)
	if inst.ClassName ~= f.class or f.known[inst] then return end
	if #f.list > 64 then pruneDead(f) end
	f.known[inst] = true
	f.list[#f.list + 1] = inst
	applyMod(f, inst)
end

local function onPostChild(inst)
	for i = 1, #POST do
		local f = POST[i]
		if f.enabled then applyPost(f, inst) end
	end
end

local function scanRoot(root, f)
	if not root then return end
	local kids = root:GetChildren()
	for i = 1, #kids do applyPost(f, kids[i]) end
end

local function bindCamera(scanNow)
	if conns.camAdded then
		conns.camAdded:Disconnect()
		conns.camAdded = nil
	end
	local cam = Workspace.CurrentCamera
	if cam then
		conns.camAdded = cam.ChildAdded:Connect(onPostChild)
		if scanNow then
			for i = 1, #POST do
				if POST[i].enabled then scanRoot(cam, POST[i]) end
			end
		end
	end
end

local function enablePost(f)
	if f.enabled then return end
	f.enabled = true
	if not conns.lightAdded then conns.lightAdded = Lighting.ChildAdded:Connect(onPostChild) end
	if not conns.camChanged then
		conns.camChanged = Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function() bindCamera(true) end)
	end
	if not conns.camAdded then bindCamera(false) end
	scanRoot(Lighting, f)
	scanRoot(Workspace.CurrentCamera, f)
end

local function disablePost(f)
	if not f.enabled then return end
	f.enabled = false
	drainNow(f)
	if not anyEnabled(POST) then
		for _, k in ipairs({ "lightAdded", "camAdded", "camChanged" }) do
			if conns[k] then
				conns[k]:Disconnect()
				conns[k] = nil
			end
		end
	end
end

local function setLodMode(mode)
	local enum = (mode == "Performance") and Enum.RenderFidelity.Performance or Enum.RenderFidelity.Automatic
	local f = F.lod
	if f.target == enum then return end
	local wasOn = f.enabled
	f.enabled = false
	drainNow(f) -- devolve tudo ao original antes de trocar o alvo
	f.target = enum
	if wasOn then enableWorld(f) end
end

------------------------------------------------------------------
-- 9. MONITOR (opcional; o Heartbeat só existe enquanto o toggle estiver ligado)
------------------------------------------------------------------
local function updateLabel()
	if not mon.label then return end
	local fps = math.floor(1 / mathMax(mon.ema, 0.001) + 0.5)
	pcall(function()
		mon.label:SetValue(string.format(
			"FPS ~%d | picos >50ms: %d | ciclo %.2f ms | int %d ms | mods P:%d S:%d L:%d H:%d",
			fps, mon.spikes, rt.emaSpent * 1000, math.floor(rt.interval * 1000),
			F.particles.mods, F.shadows.mods, F.lod.mods, F.hide.mods
		))
	end)
end

local function startMonitor()
	if mon.conn then return end
	mon.ema, mon.spikes, mon.lastSpikes = 1 / 60, 0, 0
	mon.conn = RunService.Heartbeat:Connect(function(dt)
		mon.ema = mon.ema + (dt - mon.ema) * 0.05
		if dt > 0.05 and dt > mon.ema * 3 then mon.spikes = mon.spikes + 1 end
	end)
	mon.loopId = mon.loopId + 1
	local myId = mon.loopId
	task.spawn(function()
		while mon.loopId == myId do
			updateLabel()
			task.wait(1)
		end
	end)
end

local function stopMonitor()
	if mon.conn then
		mon.conn:Disconnect()
		mon.conn = nil
	end
	mon.loopId = mon.loopId + 1
	if mon.label then pcall(function() mon.label:SetValue("Monitor: desligado") end) end
end

------------------------------------------------------------------
-- 10. TOGGLES, PERFIL E RESTAURAÇÃO (tudo definido ANTES da interface)
------------------------------------------------------------------
-- Alterna via o closure do ODH (atualiza o visual do toggle e chama o callback).
-- Se a UI não existir/sincronizar, aplica direto pelo handler: o efeito nunca depende da UI.
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

local lodDropdown, sliders = nil, {}

local function applyProfile(name)
	local p = PROFILES[name]
	if not p then return end
	currentProfile = name
	cfg.near, cfg.far, cfg.interval = p.near, p.far, p.interval
	cfg.budget, cfg.particleZone = p.budgetMs / 1000, p.particleZone
	rt.interval, rt.budget, rt.overruns = cfg.interval, cfg.budget, 0
	recalc()

	-- 1) modo de LOD primeiro (se o LOD já estiver ligado, ele é reaplicado com o novo alvo)
	pcall(setLodMode, p.lodMode)
	-- 2) recursos: aplicação IMEDIATA (liga/desliga + restaura o que saiu do perfil)
	for _, key in ipairs(FEATURE_ORDER) do setToggle(key, p.features[key] == true) end
	-- 3) só depois sincroniza o visual dos sliders/dropdown (se algo falhar aqui, o efeito já valeu)
	if sliders.near then pcall(function() sliders.near:SetValue(p.near) end) end
	if sliders.far then pcall(function() sliders.far:SetValue(p.far) end) end
	if sliders.budget then pcall(function() sliders.budget:SetValue(p.budgetMs) end) end
	if lodDropdown then pcall(function() lodDropdown:Select(p.lodMode) end) end
	-- os callbacks dos sliders recalculam; garante o valor final do perfil
	cfg.near, cfg.far, cfg.budget = p.near, p.far, p.budgetMs / 1000
	rt.budget = cfg.budget
	recalc()
	ensureLoop()
	refreshStatus()
	notify("Perfil " .. name .. " aplicado.", 2)
end

restoreEverything = function(silent)
	for _, key in ipairs(FEATURE_ORDER) do setToggle(key, false) end
	for i = 1, #ALL do drainNow(ALL[i]) end
	currentProfile = nil
	rt.interval, rt.budget, rt.overruns = cfg.interval, cfg.budget, 0
	refreshStatus()
	if not silent then notify("Tudo restaurado ao estado original.", 2) end
end

-- Encerramento total (usado quando o script é executado de novo)
local function shutdown()
	rt.loopId = rt.loopId + 1
	rt.running = false
	for i = 1, #ALL do
		ALL[i].enabled = false
		drainNow(ALL[i])
	end
	for k, c in pairs(conns) do
		pcall(function() c:Disconnect() end)
		conns[k] = nil
	end
	mon.loopId = mon.loopId + 1
	if mon.conn then
		mon.conn:Disconnect()
		mon.conn = nil
	end
	stopScan()
end
pcall(function() _G[GKEY] = shutdown end)

------------------------------------------------------------------
-- 11. INTERFACE (somente métodos do guia ODH; cada passo isolado em pcall)
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

local function worldToggle(section, f)
	addToggle(section, f.key, f.label, function(on)
		if on then enableWorld(f) else disableWorld(f) end
	end)
end

local function postToggle(section, f)
	addToggle(section, f.key, f.label, function(on)
		if on then enablePost(f) else disablePost(f) end
	end)
end

local selectedProfile = nil

-- Perfil
local secProfile = newSection("Perfil", "LOW • MEDIUM • AGGRESSIVE")
add(secProfile, "AddParagraph", "Aviso", "Seguro por design",
	"Só altera visuais locais e guarda o original de tudo. Nunca toca Tools, personagens, coletáveis, interativos, rede ou física.")
add(secProfile, "AddDropdown", "Perfil", "Perfil", { "LOW", "MEDIUM", "AGGRESSIVE" }, function(selected)
	selectedProfile = selected
	if ready then applyProfile(selected) end
end)
statusP = add(secProfile, "AddParagraph", "Status", "Status (otimizados/indexados)",
	"Nada ativo. Escolha um perfil ou ligue os recursos abaixo.", true)
add(secProfile, "AddButton", "Reaplicar", "Reaplicar perfil selecionado", function()
	if selectedProfile then applyProfile(selectedProfile) else notify("Escolha um perfil primeiro.", 2) end
end)

-- Render Optimizer
local secRender = newSection("Render Optimizer", "Culling • LOD • Sombras • Partículas")
worldToggle(secRender, F.particles)
worldToggle(secRender, F.shadows)
worldToggle(secRender, F.lod)
lodDropdown = add(secRender, "AddDropdown", "LOD modo", "LOD: modo", { "Automatic", "Performance" }, function(selected)
	local ok, err = pcall(setLodMode, selected)
	if not ok then print("[Perf] LOD: " .. tostring(err)) end
end)
worldToggle(secRender, F.hide)

-- Post-processing
local secPost = newSection("Post-Processing", "Desativação individual")
postToggle(secPost, F.bloom)
postToggle(secPost, F.sunrays)
postToggle(secPost, F.dof)
postToggle(secPost, F.blur)

-- Runtime Optimizer
local secRuntime = newSection("Runtime Optimizer", "Orçamento e atualizações adaptativas")
addToggle(secRuntime, "adaptive", "Atualizações adaptativas", function(on)
	rt.adaptive = on
	for i = 1, #WORLD do WORLD[i].dirty = true end
end)
addToggle(secRuntime, "monitor", "Monitor de frametime", function(on)
	if on then startMonitor() else stopMonitor() end
end)
mon.label = add(secRuntime, "AddLabel", "Monitor", "Monitor: desligado", true)
sliders.near = add(secRuntime, "AddSlider", "Distância próxima", "Distância próxima (studs)", 30, 500, 140, function(v)
	cfg.near = v
	recalc()
end)
sliders.far = add(secRuntime, "AddSlider", "Distância longe", "Distância longe (studs)", 80, 1500, 400, function(v)
	cfg.far = v
	recalc()
end)
sliders.budget = add(secRuntime, "AddSlider", "Orçamento", "Orçamento por ciclo (ms)", 0.2, 2, 0.8, function(v)
	cfg.budget = v / 1000
	rt.budget = cfg.budget
end)

-- Segurança
local secSafety = newSection("Segurança", "Restauração")
add(secSafety, "AddButton", "Restaurar tudo", "Restaurar tudo", function()
	restoreEverything(false)
end)

-- Diagnóstico (só aparece se algo falhou ao montar a interface)
if #uiErrors > 0 then
	notify("Perf: " .. #uiErrors .. " controle(s) falharam ao carregar. Veja o console (F9).", 6)
	add(secSafety, "AddParagraph", "Diagnóstico", "Diagnóstico da interface", table.concat(uiErrors, "\n"))
end

-- Libera os callbacks após a criação (cobre callbacks disparados logo depois da montagem)
task.delay(0.5, function() ready = true end)
