--> Overdrive H On Top.
--> PERFORMANCE OPTIMIZER — plugin independente para o ODH
--[[
  Tudo aqui é LOCAL ao seu cliente: nada toca personagem, Tools, rede, física
  ou replicação, então não existe "liso pra mim, travando pros outros".

  AVALIAÇÃO DE CUSTO x BENEFÍCIO (resumo)
  - Particle / Shadow / LOD / Hide: por item = 1 leitura de Position + 1 comparação
    de distância ao quadrado. Só ESCREVE propriedade quando o item muda de zona
    (com histerese). Passes são em lotes, com orçamento de tempo, fora de
    RenderStepped/Heartbeat (loop task.wait), e pulados quando a câmera não andou
    (modo adaptativo).
  - LOD: usa o RenderFidelity nativo do motor (Automatic/Performance). "Precise" não é
    oferecido: força detalhe máximo (mais triângulos), é o oposto do objetivo.
  - Post-Processing: poucas instâncias, só eventos ChildAdded (custo ~0).
  - Descoberta de objetos: travessia incremental (sem GetDescendants gigante),
    uma vez por ativação + DescendantAdded em fila.
  - Governor: se um ciclo estoura o orçamento, o intervalo aumenta e o orçamento
    cai; estouros repetidos desativam sozinha a otimização mais cara.

  Exclusões (nunca tocados): personagens/NPCs (Humanoid), Tools, Accessories,
  itens não ancorados, partes com ProximityPrompt/ClickDetector/TouchTransmitter/
  Gui, e qualquer coisa com nome da lista BLOCK_KEYWORDS (moedas, tokens, coletáveis...).
  Ocultação distante só em partes ancoradas SEM colisão, SEM toque e SEM consulta.
]]

local shared = odh_shared_plugins

local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local clock = os.clock
local mathMin, mathMax = math.min, math.max
local WEAK = { __mode = "k" }

------------------------------------------------------------------
-- 1. CONFIGURAÇÃO
------------------------------------------------------------------
local ICON_PATH = "axioriasolver/testplugin/refs/heads/main/icon" -- TROQUE pelo ícone do seu repositório (formato do guia)

local PROFILES = {
	LOW = {
		near = 150, far = 500, interval = 0.15, budgetMs = 0.5, particleZone = "far",
		features = {
			particles = true, shadows = false, lod = false, hide = false,
			bloom = true, sunrays = true, dof = false, blur = false,
			adaptive = false, monitor = true,
		},
	},
	MEDIUM = {
		near = 140, far = 400, interval = 0.12, budgetMs = 0.8, particleZone = "far",
		features = {
			particles = true, shadows = true, lod = true, hide = true,
			bloom = true, sunrays = true, dof = true, blur = false,
			adaptive = false, monitor = true,
		},
	},
	AGGRESSIVE = {
		near = 80, far = 220, interval = 0.1, budgetMs = 1.0, particleZone = "near",
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
local INTERACTIVE_CLASSES = {
	ProximityPrompt = true, ClickDetector = true, TouchTransmitter = true,
	BillboardGui = true, SurfaceGui = true, DragDetector = true,
}

-- Nomes que indicam função/coletável/interativo: nunca são tocados. Edite à vontade.
local BLOCK_KEYWORDS = {
	"coin", "token", "collect", "pickup", "orb", "gem", "loot", "drop", "reward", "crate",
	"chest", "spawn", "portal", "teleport", "door", "button", "prompt", "click", "shop",
	"npc", "tool", "weapon", "boss", "enemy", "mob", "heal", "powerup", "cash", "money",
	"fruit", "egg", "hitbox", "trigger", "damage", "kill", "lava", "interact", "item",
	"checkpoint", "goal", "finish", "target", "bomb", "projectile", "bullet", "ball",
	"key", "seat", "vehicle", "star", "gift", "present",
}

local HYSTERESIS = 0.9      -- para voltar ao detalhe, precisa entrar a 90% da distância
local MOVE_THRESHOLD = 6    -- studs que a câmera precisa andar para um novo passe (adaptativo)
local CHECK_EVERY = 32      -- itens entre checagens de relógio
local MAX_PENDING = 30000
local MIN_BUDGET = 0.0002
local MAX_INTERVAL = 0.5
local IDLE_WAIT = 0.25
local OVERRUN_LIMIT = 6

local cfg = { near = 120, far = 300, interval = 0.12, budget = 0.0008, particleZone = "far" }

local rt = {
	running = false, loopId = 0,
	interval = cfg.interval, budget = cfg.budget,
	emaSpent = 0, overruns = 0,
	adaptive = false,
	worstF = nil, worstCost = 0,
}

local mon = { conn = nil, ema = 1 / 60, spikes = 0, lastSpikes = 0, loopId = 0, label = nil }

local conns = {}
local toggles, uiState = {}, {}

local function setToggle(key, desired)
	local fn = toggles[key]
	if fn and (uiState[key] == true) ~= desired then fn() end
end

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
		f.mods += 1
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
		work += 1
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
			if string.find(lower, BLOCK_KEYWORDS[i], 1, true) then c = true break end
		end
		if nameCount > 5000 then nameCache, nameCount = {}, 0 end
		nameCache[name] = c
		nameCount += 1
	end
	return c
end

local function hasInteractiveChild(inst)
	local kids = inst:GetChildren()
	for i = 1, #kids do
		if INTERACTIVE_CLASSES[kids[i].ClassName] then return true end
	end
	return false
end

local ancCache = setmetatable({}, WEAK)
local function ancestorBlocked(a)
	if a:IsA("Tool") or a:IsA("Accoutrement") or a:IsA("Camera") then return true end
	if a:IsA("Model") and a:FindFirstChildOfClass("Humanoid") then return true end
	if nameBlocked(a.Name) then return true end
	return hasInteractiveChild(a)
end

-- parte ancorada, não interativa, fora de personagem/Tool/NPC => "decorativa estática"
local function isStaticDecorative(part)
	if nameBlocked(part.Name) or hasInteractiveChild(part) then return false end
	local a, depth = part.Parent, 0
	while a and a ~= Workspace do
		local c = ancCache[a]
		if c == nil then
			c = ancestorBlocked(a)
			ancCache[a] = c
		end
		if c then return false end
		a = a.Parent
		depth += 1
		if depth > 40 then return false end
	end
	return a == Workspace
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
			and not inst.CanCollide and not inst.CanTouch and not inst.CanQuery
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
			n -= 1
			if container == Workspace or container.Parent ~= nil then
				kids = container:GetChildren()
				ki = 1
				work += 4
			end
		end
		if kids then
			local total = #kids
			while ki <= total do
				local kid = kids[ki]
				ki += 1
				local cn = kid.ClassName
				local isPart = PART_CLASSES[cn]
				if isPart or EMITTER_CLASSES[cn] then register(kid) end
				if isPart or DESCEND_CLASSES[cn] then
					-- não desce em personagens/NPCs
					if not (cn == "Model" and kid:FindFirstChildOfClass("Humanoid")) then
						n += 1
						stack[n] = kid
					end
				end
				work += 1
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
		p.head += 1
		if inst.Parent ~= nil then register(inst) end
		work += 1
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
			p.tail += 1
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
		if #list == 0 then f.dirty = false return false end
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
			i += 1
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
		work += 1
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
-- 6. SCHEDULER + GOVERNOR (orçamento de tempo)
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

local function autoDisable(f)
	shared.Notify("Otimizador: '" .. f.label .. "' desativado (custo alto).", 4)
	setToggle(f.key, false)
end

local function governor(spent)
	rt.emaSpent = rt.emaSpent * 0.8 + spent * 0.2
	if spent > rt.budget * 2 + 0.0005 or spent > 0.004 then
		rt.interval = mathMin(rt.interval * 1.5, MAX_INTERVAL)
		rt.budget = mathMax(rt.budget * 0.75, MIN_BUDGET)
		rt.overruns += 1
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
	if scan.active then worked = true scanStep(discoverDeadline) end
	if pend.head <= pend.tail then worked = true drainPending(discoverDeadline) end

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

local function ensureLoop()
	if rt.running then return end -- idempotente: nunca cria dois loops
	rt.running = true
	rt.loopId += 1
	local myId = rt.loopId
	task.spawn(function()
		local rotate = 0
		while rt.loopId == myId do
			local t0 = clock()
			local worked = runCycle(t0, t0 + rt.budget, rotate)
			rotate += 1
			governor(clock() - t0)
			if not loopNeeded() then break end
			local w = rt.interval
			if rt.adaptive and not worked then w = mathMax(w, IDLE_WAIT) end
			task.wait(w)
		end
		if rt.loopId == myId then rt.running = false end
	end)
end

------------------------------------------------------------------
-- 7. ATIVAR / DESATIVAR (idempotente, conexões gerenciadas)
------------------------------------------------------------------
local function enableWorld(f)
	if f.enabled then return end
	if f.draining then drainNow(f) end
	f.enabled, f.dirty = true, true
	if not conns.added then
		conns.added = Workspace.DescendantAdded:Connect(onDescendantAdded)
	end
	startScan()
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
			j += 1
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
-- 8. MONITOR (opcional; o Heartbeat só existe enquanto o toggle estiver ligado)
------------------------------------------------------------------
local function updateLabel()
	if not mon.label then return end
	local fps = math.floor(1 / mathMax(mon.ema, 0.001) + 0.5)
	mon.label:SetValue(string.format(
		"FPS ~%d | picos >50ms: %d | ciclo %.2f ms | int %d ms | mods P:%d S:%d L:%d H:%d",
		fps, mon.spikes, rt.emaSpent * 1000, math.floor(rt.interval * 1000),
		F.particles.mods, F.shadows.mods, F.lod.mods, F.hide.mods
	))
end

local function startMonitor()
	if mon.conn then return end
	mon.ema, mon.spikes, mon.lastSpikes = 1 / 60, 0, 0
	mon.conn = RunService.Heartbeat:Connect(function(dt)
		mon.ema += (dt - mon.ema) * 0.05
		if dt > 0.05 and dt > mon.ema * 3 then mon.spikes += 1 end
	end)
	mon.loopId += 1
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
	mon.loopId += 1
	if mon.label then mon.label:SetValue("Monitor: desligado") end
end

------------------------------------------------------------------
-- 9. RESTAURAÇÃO TOTAL
------------------------------------------------------------------
local function restoreEverything()
	for _, key in ipairs(FEATURE_ORDER) do setToggle(key, false) end
	for i = 1, #ALL do drainNow(ALL[i]) end
	rt.interval, rt.budget, rt.overruns = cfg.interval, cfg.budget, 0
	shared.Notify("Tudo restaurado ao estado original.", 2)
end

------------------------------------------------------------------
-- 10. INTERFACE (somente métodos do guia ODH)
------------------------------------------------------------------
local applyProfile
local sliders = {}

local my_tab = shared.CreateTab("Performance Optimizer", ICON_PATH)

local function addToggle(section, key, label, onChange)
	toggles[key] = section:AddToggle(label, function(state)
		state = state == true
		if uiState[key] == state then return end -- idempotente
		uiState[key] = state
		onChange(state)
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

-- Perfil
local secProfile = my_tab:AddSection("Perfil", "LOW • MEDIUM • AGGRESSIVE")
secProfile:AddParagraph(
	"Seguro por design",
	"Só altera visuais locais e guarda o original de tudo. Nunca toca Tools, personagens, coletáveis, interativos, rede ou física."
)
secProfile:AddDropdown("Perfil", { "LOW", "MEDIUM", "AGGRESSIVE" }, function(selected)
	applyProfile(selected)
end)

-- Render Optimizer
local secRender = my_tab:AddSection("Render Optimizer", "Culling • LOD • Sombras • Partículas")
worldToggle(secRender, F.particles)
worldToggle(secRender, F.shadows)
worldToggle(secRender, F.lod)
secRender:AddDropdown("LOD: modo", { "Automatic", "Performance" }, function(selected)
	setLodMode(selected)
end)
worldToggle(secRender, F.hide)

-- Post-processing
local secPost = my_tab:AddSection("Post-Processing", "Desativação individual")
postToggle(secPost, F.bloom)
postToggle(secPost, F.sunrays)
postToggle(secPost, F.dof)
postToggle(secPost, F.blur)

-- Runtime Optimizer
local secRuntime = my_tab:AddSection("Runtime Optimizer", "Orçamento e atualizações adaptativas")
addToggle(secRuntime, "adaptive", "Atualizações adaptativas", function(on)
	rt.adaptive = on
	for i = 1, #WORLD do WORLD[i].dirty = true end
end)
addToggle(secRuntime, "monitor", "Monitor de frametime", function(on)
	if on then startMonitor() else stopMonitor() end
end)
mon.label = secRuntime:AddLabel("Monitor: desligado", true)
sliders.near = secRuntime:AddSlider("Distância próxima (studs)", 30, 500, 120, function(v)
	cfg.near = v
	recalc()
end)
sliders.far = secRuntime:AddSlider("Distância longe (studs)", 80, 1500, 300, function(v)
	cfg.far = v
	recalc()
end)
sliders.budget = secRuntime:AddSlider("Orçamento por ciclo (ms)", 0.2, 2, 0.8, function(v)
	cfg.budget = v / 1000
	rt.budget = cfg.budget
end)

-- Segurança
local secSafety = my_tab:AddSection("Segurança", "Restauração")
secSafety:AddButton("Restaurar tudo", function()
	restoreEverything()
end)

applyProfile = function(name)
	local p = PROFILES[name]
	if not p then return end
	cfg.near, cfg.far, cfg.interval = p.near, p.far, p.interval
	cfg.budget, cfg.particleZone = p.budgetMs / 1000, p.particleZone
	rt.interval, rt.budget, rt.overruns = cfg.interval, cfg.budget, 0
	recalc()
	sliders.near:SetValue(p.near)
	sliders.far:SetValue(p.far)
	sliders.budget:SetValue(p.budgetMs)
	for _, key in ipairs(FEATURE_ORDER) do setToggle(key, p.features[key] == true) end
	shared.Notify("Perfil " .. name .. " aplicado.", 2)
end
