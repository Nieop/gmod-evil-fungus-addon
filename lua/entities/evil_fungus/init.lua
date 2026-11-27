AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")
if not Evil then return end
include("evil_fungus/sv_mat.lua")
include("sv_feel.lua")
include("sv_nav.lua")
include("sv_debug.lua")
include("sv_settle.lua")

local Mat = EvilFungus.Mat
local EMPTY = Mat.EMPTY

local CAP = 4
local FLOW = 160
local SPREAD = 0.8
local SPREAD_MASS = 0.2
local GROW_MASS = 1
local GROW_COST = 0.1
-- What a strand must hold over and above the plant price to put another one out, so it can plant again straight
-- away instead of draining to the floor and waiting for a full unit of flow to crawl back in.
local PLANT_RESERVE = 0.1
-- A dense strand is the thick kind the mat hardens into structure. Putting one down costs more body than a plain
-- strand. The cap is code, not a setting, and sits under CAP so a strand can always afford one outright with
-- something left over -- otherwise a high growth-cost setting could price dense strands out of reach entirely.
local DENSE_GROW_COST = 0.2
local DENSE_COST_MAX = CAP - 0.5
local MIN_BODY = 8
-- Leftover cleanup is a mat-wide sweep, and it will happily eat strands a colony that small still needs to
-- reach and regrow with. Once the body is down to a handful it stops, same as at nothing, until there's body again.
local LEFTOVER_BODY = 10
local REACH_RATE = 2.5
local SPREAD_RATE = 3
local REACH_JITTER = 0.7
local ROUTE_JITTER = 0.4
local SEED_RING = 8
local DECIDE_INTERVAL = 0.25
-- How long the goal can sit in one spot before whatever holds it has to be worth aiming at, and how far it can
-- wander and still count as sitting in one spot -- the merge reach, since strands that close are one clump. A
-- strand climbing through open air starts at no body and is only fed once it's on a surface, so it gets longer
-- than the rest.
local GOAL_GRACE = 0.2
local GOAL_SAME = 28
local AIR_GRACE = 3
-- A strand that has just been fed is not bare for good, and the flat grace is far shorter than it takes body to
-- crawl out along a long mat. Both of those buy the goal time before it is judged a scrap; TRANSIT_WAIT keeps the
-- wait bounded so a strand nothing actually reaches still goes.
local FED_HOLD = 0.5
local TRANSIT_WAIT = 15
-- How far from a spot to look for a strand the body can feed before falling back to the whole mat.
local FEED_SCAN = 96
-- A goal parked on settled mat wakes its own patch rather than waiting for the rouse pass to hear something stir
-- near it, so this only stops a patch that refuses to wake (nothing of it left in the cell lookup) being asked
-- again every tick.
local DEMERGE_HOLD = 0.5
local COST_WINDOW = 1
local WANDER_TIME = { 8, 16 }
local WANDER_RANGE = 700
local WANDER_TRIES = 6
local PATROL_CHANCE = 0.3
local PATROL_NODES = 40
local ARRIVE = 32
local REST_TIME = { 2, 5 }
local LOSE_TIME = 8
local NEAR_GOAL = 96
local LEAD_TIME = 1.5
local HEADING_TIME = 0.6
local LEAD_LIFT = Vector(0, 0, 16)
local RISE_JITTER = 0.3
local TUNNEL_HOLD = 2
local AIR_HOLD = 10
local AIR_DROP = 2
local WEAVE_RATE = 6
local WEAVE_RADIUS = 64
local WEAVE_SPACING = 7
local WEAVE_MAX = 30
local WEAVE_BUDGET = 240
local DEBT_CAP = 3
local SPROUTS_PER_TICK = 48
local OVERGROW_EXTRA = 48
local BUD_TRIES = 8
local OVERGROW_SPINS = 400
local OVERGROW_CAP = 5000
local FLOW_SUBSTEPS = 4
local MIN_DECIDE = 0.08
local SPORE_BODY = 80
local SPORE_SHARE = 0.3
local SPORE_EVERY = 45
local SPORE_RANGE = 1200
local SPORE_CLEAR = 300
local SPORE_TRIES = 4
-- How close a strand has to be to the point the spore leaves from to be the one it came out of.
local SPORE_SOURCE = 64
local MAX_COLONIES = 16
local FLEE = 4
local BURN_COST = 1e6
local HEAT_COST = 40
local BEHIND = 4
local BEHIND_MARGIN = 24
local DETOUR_FLAT = 48
local DETOUR_PROBES = 8
local DETOUR_RANGE = 384
local DETOUR_STEP = 48
local DETOUR_DROP = 16
local DETOUR_LEAN = 0.3
local DETOUR_HOLD = 6
local DETOUR_OFF = 64
local DETOUR_MOVED = 256
local LOBE_BODY = 12
local BIAS_RATE = 600
local BIAS_MAX = 3000
local WANT = { hunt = 4, tend = 3, carrion = 2, roam = 1, on = 3, felt = 2, nest = 2, food = 1 }

local ai_disabled = GetConVar("ai_disabled")

EvilFungus.Colonies = EvilFungus.Colonies or {}

local PRESENCE_REACH = 320

-- However fast it's told to run, the whole map only lays so many strands a tick.
hook.Add("Tick", "EvilFungusSprouts", function()
	EvilFungus.SproutsLeft = SPROUTS_PER_TICK + math.ceil(EvilFungus.Setting("hurtilizer") * OVERGROW_EXTRA)
end)

-- Every strand on the map, all fungus together, since it's all one fungus.
function EvilFungus.Strands()
	local n = 0
	for colony in pairs(EvilFungus.Colonies) do
		if colony.Mat then n = n + colony.Mat.count - colony.Mat.wovenCount end
	end
	return n
end

function EvilFungus.Settled()
	local n = 0
	for colony in pairs(EvilFungus.Colonies) do
		if colony.Mat then n = n + colony.Mat.settledCount end
	end
	return n
end

function EvilFungus.Woven()
	local n = 0
	for colony in pairs(EvilFungus.Colonies) do
		if colony.Mat then n = n + colony.Mat.wovenCount end
	end
	return n
end

-- Whoever spawned the fungus can clean up every patch it starts, not just the first.
local function Own(colony, ply)
	if not IsValid(ply) or not ply:IsPlayer() then return end
	colony:SetCreator(ply)
	if cleanup then cleanup.Add(ply, "sents", colony) end
end

function ENT:SpawnFunction(ply, tr, class)
	if not tr.HitWorld or tr.HitSky then return end

	local ent = ents.Create(class)
	ent:SetPos(tr.HitPos + tr.HitNormal * 4)
	ent.SpawnAt = tr.HitPos
	ent.SpawnUp = tr.HitNormal
	ent:Spawn()
	ent:Activate()
	return ent
end

function ENT:Initialize()
	self:SetModel("models/props_junk/PopCan01a.mdl")
	self:SetMoveType(MOVETYPE_NONE)
	self:SetSolid(SOLID_NONE)
	self:DrawShadow(false)

	local now = CurTime()
	self.Mind = self.Mind or EvilFungus.NewMind()
	local mat = EvilFungus.NewMat()
	-- A patch grown from a dense spore stays dense: every strand it puts out is dense from the moment it's added.
	if self.DenseAll then mat.dense = true end
	self.Mat = mat

	local up = self.SpawnUp or vector_up
	local seed = mat:Add(self.SpawnAt or self:GetPos(), up)
	local ring = { seed }
	local ang = up:Angle()
	local right, side = ang:Right(), ang:Up()
	for i = 1, SEED_RING do
		local a = i / SEED_RING * math.pi * 2
		local node = mat:Grow(seed, right * math.cos(a) + side * math.sin(a), now)
		if node then ring[#ring + 1] = node end
	end
	local share = (self.StartMass or EvilFungus.Setting("start_mass")) / #ring
	for _, node in ipairs(ring) do mat:SetMass(node, share) end

	self.Center, self.Up, self.Body = seed.pos, up, share * #ring
	self.ReachDebt, self.SpreadDebt, self.WeaveDebt = 0, 0, 0
	self.Parts, self.Bias, self.ReachTurn = {}, {}, 0
	self.NextDecide = 0
	self.TargetUntil = 0
	self.Claimed = {}
	self.Costs, self.CostReport, self.CostSince = {}, {}, now
	self:InitFeel()

	EvilFungus.Colonies[self] = true
	Evil.Presence(self, { reach = PRESENCE_REACH, near = self.Nearest })
	for _, node in ipairs(ring) do
		if self:Meet(node, now) then return end
	end
end

function ENT:Think()
	local now = CurTime()
	if self.Absorbed then return end
	if self.Mat.count <= 0 then
		self:Remove()
		return
	end
	if not (ai_disabled and ai_disabled:GetBool()) then
		local t = SysTime()
		local scale = EvilFungus.TimeScale()
		if now >= self.NextDecide then
			self:Decide(now)
			self.NextDecide = now + math.max(MIN_DECIDE, DECIDE_INTERVAL / scale)
			t = self:Cost("decide", t)
		end
		local dt = FrameTime() * scale
		local steps = math.Clamp(math.ceil(scale), 1, FLOW_SUBSTEPS)
		local rate = FLOW * EvilFungus.Setting("flow_speed")
		if self.Hunting then rate = rate * (0.5 + 0.5 * EvilFungus.Setting("aggression")) end
		for _ = 1, steps do self:Flow(dt / steps, now, rate) end
		t = self:Cost("flow", t)
		self:Spread(dt, now)
		if self.Absorbed then return end
		self:Spores(dt)
		t = self:Cost("grow", t)
		self:StepPlan(now)
		t = self:Cost("nav", t)
		self:Settling(now)
		self:Rouse(now)
		t = self:Cost("settle", t)
		self:Feel(now)
		self:Cost("feel", t)
	else
		self:Slump(FrameTime() * EvilFungus.TimeScale())
	end
	self:Report(now)
	self:DebugDraw(now)
	self:NextThink(now)
	return true
end

function ENT:Cost(name, since)
	local t = SysTime()
	self.Costs[name] = (self.Costs[name] or 0) + t - since
	return t
end

-- Milliseconds of server time each part took over the last second.
function ENT:Report(now)
	local span = now - self.CostSince
	if span < COST_WINDOW then return end
	for name, cost in pairs(self.Costs) do
		self.CostReport[name] = cost * 1000 / span
		self.Costs[name] = 0
	end
	self.CostSince = now
end

function ENT:Settle()
	local cx, cy, cz, ux, uy, uz, body = 0, 0, 0, 0, 0, 0, 0
	for node in pairs(self.Mat.full) do
		local m, n = node.m, node.normal
		cx, cy, cz = cx + node.x * m, cy + node.y * m, cz + node.z * m
		local nx, ny, nz = n:Unpack()
		ux, uy, uz = ux + nx * m, uy + ny * m, uz + nz * m
		body = body + m
	end
	self.Body = body
	if body <= EMPTY then return end
	self.Center = Vector(cx / body, cy / body, cz / body)
	self.Up = Vector(ux, uy, uz):GetNormalized()
	self:SetPos(self.Center + self.Up * 4)
end

local function Behind(node, x, y, z)
	if node.air then return false end
	local nx, ny, nz = node.normal:Unpack()
	return (node.x - x) * nx + (node.y - y) * ny + (node.z - z) * nz > BEHIND_MARGIN
end

-- The strand nearest a point. sided discounts strands whose face looks away, so the body goes for the front
-- of something rather than the far side of it. Distance is the only thing that counts: body in a strand says
-- nothing about whether it's worth aiming at, and a bare path is still the shortest way there.
function ENT:Closest(pos, sided)
	local px, py, pz = pos:Unpack()
	local function ok(n)
		return not sided or not Behind(n, px, py, pz)
	end
	local node = self.Mat:Nearest(pos, NEAR_GOAL, ok)
	if node then return node end
	local bestD2 = math.huge
	for _, n in pairs(self.Mat.nodes) do
		local dx, dy, dz = n.x - px, n.y - py, n.z - pz
		local d2 = dx * dx + dy * dy + dz * dz
		if sided and Behind(n, px, py, pz) then d2 = d2 * BEHIND end
		if d2 < bestD2 then node, bestD2 = n, d2 end
	end
	return node
end

-- The goal is kept honest here as the mat changes underfoot: a strand cut loose from the body, too thin to plant
-- from, or a settled patch standing where its strands should be is judged here, not left for growth to trip over.
-- It starts with how long the body still needs to crawl along the mat to reach a strand: the distance field is
-- measured over the mat from every strand still carrying body, at the rate Flow pushes mass, so it is the honest
-- answer to "is something on its way?". Nil when no strand with body can reach it at all.
function ENT:Transit(node)
	local d = self.Dist and self.Dist[node]
	if not d or d <= 0 then return end
	local rate = FLOW * EvilFungus.Setting("flow_speed")
	if self.Hunting then rate = rate * (0.5 + 0.5 * EvilFungus.Setting("aggression")) end
	if rate <= 0 then return end
	return d / rate
end

-- What a strand must hold before it can plant from it: the price of the strand, plus a sliver left over. Growing
-- off a dense strand costs more than off a plain one, so the price is the real gate; hurtilizer makes both free,
-- leaving only the reserve.
function ENT:CanPlant(node)
	return node.m > self:GrowCost(node.dense) + PLANT_RESERVE
end

-- Can plant, and isn't in a state growth can't start from. The one rule the frontier scan and the goal share.
function ENT:Frontier(node)
	return self:CanPlant(node) and not node.burn and not node.heat
end

-- A settled patch (or a run of them) stands in for a clump of strands that no longer exist. Growing off one is a
-- trace from its rim that crowding mostly refuses, and it only splits back into real strands when something stirs
-- near it -- which a goal sitting on it never does. So the goal wakes its own patch: the same Wake the rouse pass
-- uses, just heard straight away. A run splits into patches first and those into strands, so it takes two passes.
function ENT:Demerge(node, now)
	local mat = self.Mat
	if not node or node.dead or not node.felt then return false end
	if now - (self.DemergeAt or -math.huge) < DEMERGE_HOLD then return false end
	self.DemergeAt = now
	if not next(mat.settled) then return false end
	local woke
	for _ = 1, 2 do
		if not mat:Wake(node.pos, Mat.FELT, now) then break end
		woke = true
	end
	if not woke then return false end
	self.GoalStale = true
	return true
end

-- The nearest strand that can actually put out a new one, searched from the goal so the mat keeps working the
-- same side of the prey. mat.full holds exactly the strands carrying body, so the scan stays on that set.
function ENT:GrowFrom(node, now)
	local body = now and self:Connected(now)
	local best, bestD2, spare, spareD2
	local px, py, pz = node.x, node.y, node.z
	for other in pairs(self.Mat.full) do
		if other ~= node and self:CanPlant(other) and not other.dead and not other.burn and not other.heat then
			local dx, dy, dz = other.x - px, other.y - py, other.z - pz
			local d2 = dx * dx + dy * dy + dz * dz
			if not spareD2 or d2 < spareD2 then spare, spareD2 = other, d2 end
			if body and body[other] and (not bestD2 or d2 < bestD2) then best, bestD2 = other, d2 end
		end
	end
	return best or spare
end

-- Whether the body can feed a strand at all. Everything joined by strands to a piece still carrying body counts,
-- a bare front tip included, since the piece sends mass out to it. A scrap cut loose from the mat keeps whatever
-- body it had, plants a few strands of its own and starves: nothing behind it ever sends more.
function ENT:Feedable(node, now)
	if not node or node.dead then return false end
	return self:Connected(now)[node] == true
end

-- The strand nearest a spot that the body can feed, preferring the face turned toward the target. Distance alone
-- picks scraps cut off from the mat, and a goal parked on one looks like it is on its way for a moment and then
-- goes nowhere while strands that do have body to spare sit unfelt.
function ENT:FeedNear(pos, now, sided)
	local body = self:Connected(now)
	local px, py, pz = pos:Unpack()
	local function Front(n) return not sided or not Behind(n, px, py, pz) end
	local node = self.Mat:Nearest(pos, FEED_SCAN, function(n) return body[n] and not n.air and Front(n) end)
	if node then return node end
	local best, bestD2 = nil, math.huge
	for n in pairs(body) do
		if not n.air and not n.dead and Front(n) then
			local d2 = n.pos:DistToSqr(pos)
			if d2 < bestD2 then best, bestD2 = n, d2 end
		end
	end
	return best
end

-- A strand the goal has been sitting on for its grace that can't put out another strand -- a lone point, or
-- too thin to grow from -- sends the goal to the nearest strand that can grow instead, and is only dropped when
-- there is no such strand anywhere. Only run while hunting: on the hunt the goal is pinned to whatever is nearest
-- the prey and can end up parked on a scrap, where roaming just picks its own way on and the mat needs every
-- strand it has standing. The wait is stamped on the strand, but carries over to the next one when the goal only
-- steps to a neighbour: the colony picks among the strands in one tangled clump from tick to tick, and a fresh
-- wait on every hop is what let a bare scrap sit there for good. Returns the strand the goal should hold.
function ENT:Leftover(node, now)
	if not node then
		self.GoalAt, self.GoalSince = nil, nil
		return nil
	end
	-- Nothing left to lose and nothing to regrow with: once the body is down to a handful the cleanup only eats the
	-- mat itself, so it stops until there's body again. The stamp is cleared so the wait starts fresh when it does.
	if self.Body <= LEFTOVER_BODY then
		node.sat = nil
		return node
	end
	if not node.sat then
		local at, since = self.GoalAt, self.GoalSince
		node.sat = at and since and at:DistToSqr(node.pos) <= GOAL_SAME * GOAL_SAME and since or now
	end
	self.GoalAt, self.GoalSince = node.pos, node.sat
	-- Air isn't judged as quickly as the rest: a strand still climbing toward the target is a new node every step,
	-- so it keeps moving and never builds up here, while one that's stopped where nothing can reach goes once the
	-- longer grace is up.
	if now - node.sat <= (node.air and AIR_GRACE or GOAL_GRACE) then return node end
	if #node.edges == 0 or not self:CanPlant(node) then
		-- Settled mat is the scrappiest kind of holder: no live strands under it to grow from at all. Split it here
		-- and let the next pick find the strands it turns into, instead of waiting for something to walk past.
		if self:Demerge(node, now) then
			self.GoalAt, self.GoalSince = nil, nil
			return nil
		end
		-- Nothing here to grow from. Body still crawling out to it, or a neighbour clump just fed, earns the wait;
		-- once nothing is on its way the goal steps to the nearest strand that can actually grow.
		local eta = self:Transit(node)
		if eta and now - node.sat < math.min(eta, TRANSIT_WAIT) then return node end
		if now - (node.fed or -math.huge) < FED_HOLD then return node end
		local grow = self:GrowFrom(node, now)
		if grow then
			self.GoalAt, self.GoalSince = nil, nil
			self.GoalStale = true
			return grow
		end
		-- Not a strand with body anywhere on the mat: the scrap really is all there is, so it goes.
		self.Mat:Remove(node)
		self.GoalAt, self.GoalSince = nil, nil
		self.GoalStale = true
		return nil
	end
	node.sat = nil
	self.GoalAt, self.GoalSince = nil, nil
	return node
end

local function Gap(lift, dir, drop)
	local tr = util.TraceLine({ start = lift, endpos = lift + dir * DETOUR_RANGE, mask = MASK_SOLID_BRUSHONLY })
	local wall = tr.Hit and not tr.HitSky and tr.Fraction * DETOUR_RANGE or math.huge
	for dist = DETOUR_STEP, math.min(wall, DETOUR_RANGE), DETOUR_STEP do
		local p = lift + dir * dist
		if not util.TraceLine({ start = p, endpos = p + drop, mask = MASK_SOLID_BRUSHONLY }).Hit then return dist end
	end
	return wall
end

local function Stuck(node, target)
	if node.air then return false end
	local to = target - node.pos
	local n = node.normal
	local off = to:Dot(n)
	return math.abs(off) > DETOUR_OFF and (to - n * off):Length() < DETOUR_FLAT
end

local function Detour(node, target)
	local n = node.normal
	local ang = n:Angle()
	local right, up = ang:Right(), ang:Up()
	local lift = node.pos + n * 4
	local drop = n * -DETOUR_DROP
	local to = target - node.pos
	local along = to - n * to:Dot(n)
	local toward = along:LengthSqr() > 1 and along:GetNormalized()
	local spin = math.random() * math.pi * 2
	local best, bestGap, bestScore
	for i = 1, DETOUR_PROBES do
		local a = spin + i / DETOUR_PROBES * math.pi * 2
		local dir = right * math.cos(a) + up * math.sin(a)
		local gap = Gap(lift, dir, drop)
		local score = gap
		if toward then score = score * (1 - DETOUR_LEAN * dir:Dot(toward)) end
		if not bestScore or score < bestScore then best, bestGap, bestScore = dir, gap, score end
	end
	return lift + best * math.min(bestGap, DETOUR_RANGE)
end

function ENT:Around(goal, now)
	-- A way round that was actually found beats feeling along the wall.
	local routed = self:Navigate(goal, now)
	if routed then return routed end
	local target = self.Target
	if not goal or not target or self.Hunting and (self.Tunnel or 0) > 0 then
		self.Waypoint = nil
		return goal
	end
	local way = self.Waypoint
	if way then
		local near = self.Mat:Nearest(way, ARRIVE * 2, function(n) return n ~= self.WaypointFrom end)
		if now > self.WaypointUntil or target:DistToSqr(self.WaypointFor) > DETOUR_MOVED * DETOUR_MOVED or near and not Stuck(near, target) then
			self.Waypoint, self.GoalStale = nil, true
			return self:Closest(target, true) or goal
		end
		if near then
			way, self.Waypoint, goal = nil, nil, near
		end
	end
	if not way and Stuck(goal, target) then
		way = Detour(goal, target)
		self.Waypoint, self.WaypointFrom, self.WaypointUntil, self.WaypointFor = way, goal, now + DETOUR_HOLD, target
	end
	if way then return self:Closest(way) or goal end
	return goal
end

local function RandomNode(set, accept)
	local pick, seen = nil, 0
	for key, value in pairs(set) do
		local node = value == true and key or value
		if not accept or accept(node) then
			seen = seen + 1
			if math.random(seen) == 1 then pick = node end
		end
	end
	return pick
end

function ENT:PickTarget(now)
	self.TargetUntil = now + math.Rand(WANDER_TIME[1], WANDER_TIME[2])
	self.Resting = false
	self.GoalStale = true

	if self.Limit or self.Mat.count > PATROL_NODES and math.random() < PATROL_CHANCE then
		self.Target = RandomNode(self.Mat.nodes, function(n) return not n.air end).pos
		return
	end

	local from = self.Center + self.Up * 16
	for _ = 1, WANDER_TRIES do
		local dir = VectorRand():GetNormalized()
		local tr = util.TraceLine({ start = from, endpos = from + dir * WANDER_RANGE, mask = MASK_SOLID_BRUSHONLY })
		if tr.Hit and not tr.HitSky and not tr.HitNoDraw and not tr.StartSolid and tr.Fraction > 0.15 then
			self.Target = tr.HitPos
			return
		end
	end
	self.Target = self.Center
end

-- Up off the ground, it only knows to go after you as well as it knows the trick you're using.
function ENT:Aloft(prey)
	local mind = self.Mind
	if prey:IsPlayer() and prey:GetMoveType() == MOVETYPE_NOCLIP then return mind:Knows("noclip") end
	if not EvilFungus.OnGround(prey) then return math.max(mind:Knows("jump"), mind:Knows("bhop")) end
	local ground = prey:GetGroundEntity()
	if IsValid(ground) and not ground:IsWorld() then return mind:Knows("high") end
	return 0
end

local function Tip(mat, node)
	for _, e in ipairs(node.edges) do
		local other = mat:Other(e, node)
		if other.air and other.height > node.height then return false end
	end
	return true
end

-- With nothing up there left to reach for, the strands in the air let go from the tips back and run down into the rest.
function ENT:Retract()
	local mat, dropped = self.Mat, 0
	for node in pairs(mat.air) do
		if Tip(mat, node) then
			local low
			for _, e in ipairs(node.edges) do
				local other = mat:Other(e, node)
				if not low or other.height < low.height then low = other end
			end
			if low then mat:SetMass(low, low.m + node.m) end
			mat:Remove(node)
			dropped = dropped + 1
			if dropped >= AIR_DROP then return end
		end
	end
end

function ENT:Decide(now)
	self.Threads, self.Parts, self.Bias = self.Threads or {}, self.Parts or {}, self.Bias or {}
	self.ReachTurn = self.ReachTurn or 0
	self:Settle()
	if next(self.Mat.woven) then self:Unravel() end
	if next(self.Mat.air) and now - (self.TunnelAt or -math.huge) > AIR_HOLD then self:Retract() end

	local prey, node = self.Prey, self.PreyNode
	local memory = LOSE_TIME * math.max(0.25, EvilFungus.Setting("aggression")) / EvilFungus.TimeScale()
	local known = IsValid(prey) and (self:Touches(prey) or self.Smelled == prey)
	local still = IsValid(prey) and node and not node.dead and self:Perceivable(prey, known)
	self.Hunting = still and now - self.FeltAt < memory
	if still and not self.Hunting and prey:IsPlayer() then self.Mind:Watch(prey, "outrun", 1) end
	if not self.Hunting then
		self.Prey, self.PreyNode, self.PreyFrom, self.Eating = nil, nil, nil, nil
	end
	for ent, t in pairs(self.Threads) do
		if now - t.at >= memory or t.node.dead or not self:Perceivable(ent, t.smelled) then self.Threads[ent] = nil end
	end

	local aloft = self.Hunting and known and self:Aloft(prey) or 0
	if aloft > 0 then
		self.Tunnel, self.TunnelAt = aloft, now
	elseif not self.Hunting or now - (self.TunnelAt or -math.huge) > TUNNEL_HOLD then
		self.Tunnel = 0
	end

	local goal
	self.Tending = not self.Hunting and self:Patient() or nil
	if self.Hunting then
		self.Target = known and self:Lead(prey, now) or self.PreyFrom or node.pos
		-- Nearest to the prey, but only among strands the body is joined to. A scrap cut off from the mat can lie
		-- nearer without ever being fed, so aiming at it makes no progress and the cross sits there.
		goal = self:FeedNear(self.Target, now, true) or self:Closest(self.Target, true) or node
		goal = self:Around(goal, now)
		-- A strand can still be too thin to plant from even on the body; that is judged here rather than left for
		-- the roam branch to find, since on the hunt the goal is pinned to whatever is nearest the prey. Leftover
		-- can cull the strand it was handed and answer with none, so the pick falls back on the one the mat stands
		-- on: there is always a goal while there is a mat.
		if not self:Leftover(goal, now) then
			goal = self:FeedNear(self.Target, now, true) or self:Closest(self.Target, true) or node
		end
		-- After Leftover, so it names the strand the goal ends up on and not the one it was moved off.
		self.PreyNode = goal
	elseif self.Tending then
		goal = self.Tending.nest
		self.Target, self.Waypoint = goal.pos, nil
		self.GoalStale = true
	else
		local was = self.Carrion
		local body = not self.Limit and self:Scavenge(now)
		if body then
			local pos = body:GetPos()
			if body ~= was or not self.Target or self.Target:DistToSqr(pos) > ARRIVE * ARRIVE then self.GoalStale = true end
			self.Target, self.Lure, self.Resting = pos, nil, false
			self.TargetUntil = now + WANDER_TIME[1]
		elseif self.Lure and not self.Limit then
			self.Target, self.Lure, self.Resting, self.GoalStale = self.Lure, nil, false, true
			self.TargetUntil = now + math.Rand(WANDER_TIME[1], WANDER_TIME[2])
		end
		if not self.Target or now >= self.TargetUntil then self:PickTarget(now) end
		goal = self.Goal
		-- A goal left on a piece that has since drained or been cut loose can never be fed again, so it is re-picked
		-- even when nothing else has marked it stale.
		if self.GoalStale or not goal or goal.dead or not self:Feedable(goal, now) then
			goal = self:FeedNear(self.Target, now, true) or self:Closest(self.Target, true)
			self.GoalStale = false
		end
		goal = self:Around(goal, now)
		if not body and not self.Resting and goal and goal.m > GROW_MASS and goal.pos:Distance(self.Target) < ARRIVE then
			self.Resting = true
			self.TargetUntil = math.min(self.TargetUntil, now + math.Rand(REST_TIME[1], REST_TIME[2]))
		end
	end
	self.Goal = goal

	local want = self.Hunting and WANT.hunt or self.Tending and WANT.tend or self.Carrion and WANT.carrion or WANT.roam
	local sources, owner = self:Lobes(goal, want)

	-- Only the body needs to know the way, so the search ends once it has reached every part of it.
	local mat = self.Mat
	local left, reached = 0, {}
	for _ in pairs(mat.full) do left = left + 1 end
	self.Dist = mat:Distances(sources, function(e)
		if e.a.burn or e.b.burn then return BURN_COST end
		local heat = math.max(e.a.heat or 0, e.b.heat or 0)
		return e.len / mat:Conductance(e, now) * (1 + heat * HEAT_COST)
	end, nil,
		function(node)
			if not mat.full[node] or reached[node] then return false end
			reached[node] = true
			left = left - 1
			return left <= 0
		end, owner)
	self:Balance(owner)
end

function ENT:Errands()
	local list = {}
	for ent, st in pairs(self.Touching) do
		if ent ~= self.Prey and IsValid(ent) and st.node and not st.node.dead then
			list[#list + 1] = { key = ent, goal = st.node, want = st.food and WANT.food or WANT.on }
		end
	end
	for ent, t in pairs(self.Threads) do
		if ent ~= self.Prey and not self.Touching[ent] and IsValid(ent) then
			local target = t.smelled and ent:GetPos() or t.from or t.node.pos
			local goal = self:Closest(target, true)
			if goal then list[#list + 1] = { key = ent, goal = goal, target = target, want = WANT.felt } end
		end
	end
	if self.Hunting then
		local s = self:Patient()
		if s then list[#list + 1] = { key = s.rag, goal = s.nest, want = WANT.nest } end
	end
	table.sort(list, function(a, b) return a.want > b.want end)
	return list
end

function ENT:Lobes(goal, want)
	local list = {}
	if goal then list[1] = { key = "main", goal = goal, want = want } end
	local cap = math.min(math.floor(EvilFungus.Setting("split")), math.floor(self.Body / LOBE_BODY))
	if cap > 1 then
		for _, lobe in ipairs(self:Errands()) do
			if #list >= cap then break end
			list[#list + 1] = lobe
		end
	end
	self.Parts = list
	local sources, owner = {}, {}
	for _, lobe in ipairs(list) do
		local start = -(self.Bias[lobe.key] or 0)
		if lobe.goal and (not sources[lobe.goal] or start < sources[lobe.goal]) then
			sources[lobe.goal], owner[lobe.goal] = start, lobe
		end
	end
	self.Sources = sources
	return sources, owner
end

function ENT:Balance(owner)
	local list = self.Parts
	if #list < 2 then
		self.Bias = {}
		return
	end
	local held, total, wanted = {}, 0, 0
	for node in pairs(self.Mat.full) do
		local lobe = owner[node]
		if lobe then
			held[lobe] = (held[lobe] or 0) + node.m
			total = total + node.m
		end
	end
	if total <= EMPTY then return end
	for _, lobe in ipairs(list) do wanted = wanted + lobe.want end
	local bias = {}
	for _, lobe in ipairs(list) do
		local gap = lobe.want / wanted - (held[lobe] or 0) / total
		bias[lobe.key] = math.Clamp((self.Bias[lobe.key] or 0) + gap * BIAS_RATE, -BIAS_MAX, BIAS_MAX)
	end
	self.Bias = bias
end

-- The more it knows, the less it goes where you are and the more it goes where you're headed.
-- It reads that off how you've been moving, not off the last juke.
function ENT:Lead(prey, now)
	local pos = prey:GetPos()
	local vel = prey:GetVelocity()
	vel.z = 0
	if self.LeadOf ~= prey then
		self.LeadOf, self.Heading = prey, vel
	else
		self.Heading = LerpVector(1 - math.exp(-(now - self.LeadAt) / HEADING_TIME), self.Heading, vel)
	end
	self.LeadAt = now

	local ahead = LEAD_TIME * self.Mind:Grasp() / EvilFungus.TimeScale()
	if ahead <= 0 then return pos end
	local tr = util.TraceLine({ start = pos + LEAD_LIFT, endpos = pos + self.Heading * ahead + LEAD_LIFT, mask = MASK_SOLID_BRUSHONLY })
	return tr.HitPos - LEAD_LIFT
end

local flowList = {}
local Conductance, Thicken, SetMass = Mat.Conductance, Mat.Thicken, Mat.SetMass

function ENT:Flow(dt, now, rate)
	local dist, mat = self.Dist, self.Mat
	if not dist then return end

	local n = 0
	for node in pairs(mat.full) do
		n = n + 1
		flowList[n] = node
	end

	local spread = math.min(0.25, SPREAD * dt)
	for i = 1, n do
		local node = flowList[i]
		flowList[i] = nil
		local m = node.m
		local heat = node.burn and 2 or node.heat
		if m > EMPTY and not node.dead and heat then
			local edges, safe = node.edges, 0
			for j = 1, #edges do
				local other = edges[j].a == node and edges[j].b or edges[j].a
				if (other.burn and 2 or other.heat or 0) < heat and not other.asleep then safe = safe + 1 end
			end
			if safe > 0 then
				local q = m * math.min(0.9, FLEE * dt) / safe
				for j = 1, #edges do
					local e = edges[j]
					local other = e.a == node and e.b or e.a
					if (other.burn and 2 or other.heat or 0) < heat and not other.asleep then
						SetMass(mat, other, other.m + q)
						other.fed = now
						m = m - q
					end
				end
				SetMass(mat, node, m)
			end
		elseif m > EMPTY and not node.dead then
			local edges = node.edges
			local d, down, to = dist[node] or math.huge, nil, nil
			for j = 1, #edges do
				local e = edges[j]
				local other = e.a == node and e.b or e.a
				local od = dist[other]
				if od and od < d and other.m < CAP and not other.burn and not other.heat and not other.asleep then
					d, down, to = od, e, other end
			end
			if down then
				local q = m * math.min(0.9, rate * Conductance(mat, down, now) / down.len * dt)
				m = m - q
				SetMass(mat, to, to.m + q)
				to.fed = now
				Thicken(mat, down, q, now)
			end
			if m > SPREAD_MASS then
				for j = 1, #edges do
					local e = edges[j]
					local other = e.a == node and e.b or e.a
					local om = other.m
					if om < m and not other.burn and not other.heat and not other.asleep then
						local q = (m - om) * spread
						m = m - q
						SetMass(mat, other, om + q)
						other.fed = now
					end
				end
			end
			SetMass(mat, node, m)
		end
	end
end

function ENT:Slump(dt)
	local mat = self.Mat
	local now = CurTime()
	local n = 0
	for node in pairs(mat.full) do
		n = n + 1
		flowList[n] = node
	end
	local k = math.min(0.25, SPREAD * dt)
	for i = 1, n do
		local node = flowList[i]
		flowList[i] = nil
		local m = node.m
		if m > EMPTY and not node.dead then
			local edges = node.edges
			for j = 1, #edges do
				local e = edges[j]
				local other = e.a == node and e.b or e.a
				local om = other.m
				if om < m and not other.asleep then
					local q = (m - om) * k
					m = m - q
					SetMass(mat, other, om + q)
				end
			end
			SetMass(mat, node, m)
		end
	end
end

-- The newest catch still within reach of rescue. The body goes and sits with it.
function ENT:Patient()
	local best
	for rag in pairs(self.Claimed) do
		local s = EvilFungus.Sleepers[rag]
		if s and s.nest and not s.nest.dead and (s.stage == EvilFungus.LOOSE or s.stage == EvilFungus.CONSUMING)
			and (not best or s.since > best.since) then
			best = s
		end
	end
	return best
end

-- One plant off a strand. opts holds everything that varies between calls:
--   now      the clock it's planted at
--   spacing  step length for the walk, when it isn't the mat's own
--   payer    the strand that pays, when it isn't the one growing
--   rise     climb off the surface instead of growing along it
--   catch    ragdoll to weave the new strand onto
--   through  body set a route may grow over its own leftovers with
function ENT:Sprout(from, dir, opts)
	local now = opts.now
	if from.burn or from.heat then return end
	local payer = opts.payer or from
	local cost = self:GrowCost(from.dense)
	if payer.m < cost or (EvilFungus.SproutsLeft or 1) <= 0 then return end
	EvilFungus.SproutsLeft = (EvilFungus.SproutsLeft or 1) - 1
	local node
	if opts.rise then
		node = self.Mat:Rise(from, dir, now)
	elseif from.felt then
		node = self.Mat:Bud(from, dir, now)
		-- A refused trace off a patch is usually the patch standing where the strands should be: wake it so the
		-- growth actually has strands to come out of on the next try.
		if not node then self:Demerge(from, now) end
	else
		node = self.Mat:Grow(from, dir, now, opts.spacing, opts.through)
	end
	if not node then return end
	if cost > 0 then self.Mat:SetMass(payer, payer.m - cost) end
	if opts.catch then self.Mat:Weave(node, opts.catch) end
	local goal, target = self.Goal, self.Waypoint or self.Target
	if not self.Hunting and goal and target and node.pos:DistToSqr(target) < goal.pos:DistToSqr(target) then
		self.Goal = node
	end
	self:Meet(node, now)
	return node
end

-- What one plant costs in body. Zero when hurtilizer is on, which makes the mat grow free. A dense strand
-- costs DENSE_GROW_COST instead, up to DENSE_COST_MAX.
function ENT:GrowCost(dense)
	if EvilFungus.Setting("hurtilizer") > 0 then return 0 end
	local setting = EvilFungus.Setting("grow_cost")
	if dense then return math.min(DENSE_GROW_COST * setting, DENSE_COST_MAX) end
	return GROW_COST * setting
end

-- Puts a strand right on a route point from a strand that can see it, paid for like any other. The
-- plant is forced past the crowding check, since a point only counts as reached once a strand is on it.
-- pay names the strand the body comes out of, for when that is not the one the strand grows from.
function ENT:Leap(from, pos, normal, now, pay)
	if from.burn or from.heat or from.air then return end
	local mat = self.Mat
	if EvilFungus.Strands() >= EvilFungus.Setting("max_nodes") or self.Limit and mat.count - mat.wovenCount >= self.Limit then return end
	local cost = self:GrowCost(from.dense)
	local payer = pay or from
	if payer.m < cost or (EvilFungus.SproutsLeft or 1) <= 0 then return end
	local node = self.Mat:Leap(from, pos, normal, now, true)
	if not node then return end
	EvilFungus.SproutsLeft = (EvilFungus.SproutsLeft or 1) - 1
	if cost > 0 then self.Mat:SetMass(payer, payer.m - cost) end
	self:Meet(node, now)
	return node
end

local function Open(open, node)
	if open.at[node] then return end
	local n = #open.list + 1
	open.list[n], open.at[node] = node, n
end

local function Close(open, node)
	local i = open.at[node]
	if not i then return end
	local list, n = open.list, #open.list
	local last = list[n]
	list[i], open.at[last] = last, i
	list[n], open.at[node] = nil, nil
end

function ENT:Opened(node)
	if self.Open and node then Open(self.Open, node) end
end

local function Heading(node)
	local ang = node.normal:Angle()
	local a = (node.tries or 0) / BUD_TRIES * math.pi * 2 + math.Rand(-0.3, 0.3)
	return ang:Right() * math.cos(a) + ang:Up() * math.sin(a)
end

function ENT:Sow(from, dir, now)
	if (EvilFungus.SproutsLeft or 0) <= 0 or from.burn or from.heat or from.air then return end
	EvilFungus.SproutsLeft = EvilFungus.SproutsLeft - 1
	local node = self.Mat:Sow(from, dir, now)
	if not node then return end
	self:Meet(node, now)
	return node
end

function ENT:Overgrow(now)
	local open = self.Open
	if not open then
		open = { list = {}, at = {} }
		self.Open = open
		for _, node in pairs(self.Mat.nodes) do Open(open, node) end
	end
	if EvilFungus.Strands() - EvilFungus.Settled() >= OVERGROW_CAP then return end
	local mat, spins = self.Mat, 0
	while (EvilFungus.SproutsLeft or 0) > 0 and #open.list > 0 and spins < OVERGROW_SPINS do
		spins = spins + 1
		local node = open.list[math.random(#open.list)]
		if node.dead or node.air or node.burn then
			Close(open, node)
		else
			local dir = Heading(node)
			local made = not mat:Covered(node.pos + dir * Mat.FELT, node.normal) and self:Sow(node, dir, now)
			if self.Absorbed then return end
			if made then
				Open(open, made)
			else
				node.tries = (node.tries or 0) + 1
				if node.tries >= BUD_TRIES then Close(open, node) end
			end
		end
	end
end

-- There is only one fungus. Two mats that touch recognise each other and carry on as one.
function ENT:Meet(node, now)
	local range = node.felt and Mat.FELT or Mat.FUSE
	local reach = Vector(range, range, range)
	local pos = node.pos
	for other in pairs(EvilFungus.Colonies) do
		local mat = other ~= self and IsValid(other) and not other.Absorbed and other.Mat
		if mat and mat.mins and pos:WithinAABox(mat.mins - reach, mat.maxs + reach) then
			local theirs = mat:Nearest(pos, range, function(n) return Mat.Facing(node, n) and Mat.Reaches(node, n) end)
			if theirs then return self:Fuse(other, node, theirs, now) end
		end
	end
	return false
end

function ENT:Fuse(other, mine, theirs, now)
	local keep, lose = self, other
	if other.Mat.count > self.Mat.count then keep, lose = other, self end

	if not IsValid(keep:GetCreator()) then Own(keep, lose:GetCreator()) end
	keep.Mat:Absorb(lose.Mat)
	if keep.Open and lose.Open then
		for _, node in ipairs(lose.Open.list) do Open(keep.Open, node) end
	else
		keep.Open = nil
	end
	keep.Limit = keep.Limit and lose.Limit and keep.Limit + lose.Limit or nil
	EvilFungus.Converge(keep.Mind, lose.Mind)
	keep.Mat:Link(mine, theirs, now)
	keep:Adopt(lose)
	keep:Ripple(mine, now)
	keep.NextDecide = 0
	keep.GoalStale = true

	lose.Absorbed = true
	EvilFungus.Colonies[lose] = nil
	lose:Remove()
	return lose == self
end

function ENT:Spread(dt, now)
	local mat = self.Mat
	if EvilFungus.Setting("hurtilizer") > 0 then
		self:Overgrow(now)
		return
	end
	self.Open = nil
	if self.Body < MIN_BODY then return end
	local speed = EvilFungus.Setting("grow_speed")
	local sprawl = EvilFungus.Setting("sprawl")
	local cap = math.min(SPROUTS_PER_TICK, DEBT_CAP * math.max(1, EvilFungus.TimeScale()))
	local reach = REACH_RATE * (self.Hunting and EvilFungus.Setting("aggression") or 1)
	self.ReachDebt = math.min(cap, self.ReachDebt + reach * speed * dt)
	self.SpreadDebt = math.min(cap, self.SpreadDebt + SPREAD_RATE * sprawl * speed * dt)
	if self.ReachDebt < 1 and self.SpreadDebt < 1 and not self.Tending then return end
	if EvilFungus.Strands() >= EvilFungus.Setting("max_nodes") or self.Limit and mat.count - mat.wovenCount >= self.Limit then
		self.ReachDebt, self.SpreadDebt = 0, 0
		self:Weave(dt, now, speed)
		return
	end

	-- New strands start empty, so the edge it grows from only changes once a strand's cost takes it under.
	-- Only what's on a surface wanders off. What's up in the air is only ever there to reach something.
	local frontier
	local targets = {}
	local main = self.Waypoint or self.Target
	if main then targets[1] = { pos = main, tunnel = self.Hunting and self.Tunnel or 0 } end
	for _, lobe in ipairs(self.Parts) do
		if lobe.target then targets[#targets + 1] = { pos = lobe.target, tunnel = 0 } end
	end
	local function Scan()
		frontier = {}
		for _, t in ipairs(targets) do t.best, t.d2 = nil, math.huge end
		for node in pairs(mat.full) do
			if self:Frontier(node) then
				if not node.air then frontier[#frontier + 1] = node end
				for _, t in ipairs(targets) do
					if t.tunnel > 0 or not node.air then
						local tx, ty, tz = t.pos:Unpack()
						local dx, dy, dz = node.x - tx, node.y - ty, node.z - tz
						local d2 = dx * dx + dy * dy + dz * dz
						if Behind(node, tx, ty, tz) then d2 = d2 * BEHIND end
						if d2 < t.d2 then t.best, t.d2 = node, d2 end
					end
				end
			end
		end
	end

	while self.ReachDebt >= 1 and #targets > 0 do
		self.ReachDebt = self.ReachDebt - 1
		self.ReachTurn = self.ReachTurn % #targets + 1
		local t = targets[self.ReachTurn]
		if not frontier or t.best and not self:Frontier(t.best) then Scan() end
		local best, target, tunnel, d2 = t.best, t.pos, t.tunnel, t.d2
		local routed = t == targets[1] and self.Route and self:RouteFrom(now)
		if routed then best, d2 = routed, routed.pos:DistToSqr(target) end
		if best and d2 > ARRIVE * ARRIVE then
			-- Going up after something in the air, it heads straight out through it, and climbs whatever's in the way.
			local rise = tunnel > 0 and (best.air or math.random() < tunnel)
			local jitter = REACH_JITTER * (0.5 + 0.5 * sprawl) * (rise and RISE_JITTER or 1)
			-- On a route the points are close together and the wander would only pull it off them.
			if t == targets[1] and self.Route then jitter = jitter * ROUTE_JITTER end
			local dir = (target - best.pos):GetNormalized() + VectorRand() * jitter
			-- A route may grow over its own leftovers rather than being refused by them; greedy growth has no way
			-- through set and keeps its old refusal, so it does not double up on dead mat either.
			local through = routed and self:Connected(now) or nil
			local grown = rise and self:Sprout(best, dir, { now = now, rise = true, through = through })
			if not grown and not self.Absorbed then grown = self:Sprout(best, dir, { now = now, through = through }) end
			if self.Absorbed then return end
			if routed then self:RouteStep(routed, grown, now) end
		end
	end

	while self.SpreadDebt >= 1 do
		self.SpreadDebt = self.SpreadDebt - 1
		if not frontier then Scan() end
		local from
		for _ = 1, #frontier do
			local i = math.random(#frontier)
			if self:Frontier(frontier[i]) then from = frontier[i] break end
		end
		if from then self:Sprout(from, VectorRand(), { now = now }) end
		if self.Absorbed then return end
	end

	self:Weave(dt, now, speed)
end

-- Around a fresh catch the mat knits itself much tighter than anywhere else.
function ENT:Weave(dt, now, speed)
	local s = self.Tending
	if not s or (s.woven or 0) >= WEAVE_MAX or EvilFungus.Woven() >= WEAVE_BUDGET then
		self.WeaveDebt = 0
		return
	end
	local cap = math.min(SPROUTS_PER_TICK, DEBT_CAP * math.max(1, EvilFungus.TimeScale()))
	self.WeaveDebt = math.min(cap, self.WeaveDebt + WEAVE_RATE * speed * dt)
	local opts = { now = now, spacing = WEAVE_SPACING, payer = s.nest, catch = s.rag }
	while self.WeaveDebt >= 1 and (s.woven or 0) < WEAVE_MAX do
		self.WeaveDebt = self.WeaveDebt - 1
		local near = {}
		self.Mat:Near(s.nest.pos, WEAVE_RADIUS, function(node) near[#near + 1] = node end)
		if #near == 0 then return end
		if self:Sprout(near[math.random(#near)], VectorRand(), opts) then
			s.woven = (s.woven or 0) + 1
		end
		if self.Absorbed then return end
	end
end

function ENT:Unravel()
	local mat, loose = self.Mat, {}
	for node in pairs(mat.woven) do
		local s = IsValid(node.weave) and EvilFungus.Sleepers[node.weave]
		if not s or s.stage == EvilFungus.FREED then loose[#loose + 1] = node end
	end
	for _, node in ipairs(loose) do
		local into
		for _, e in ipairs(node.edges) do
			local other = mat:Other(e, node)
			if not mat.woven[other] then
				into = other
				break
			end
			into = into or other
		end
		if into then mat:SetMass(into, into.m + node.m) end
		mat:Remove(node)
	end
end

local function Colonies()
	local n = 0
	for colony in pairs(EvilFungus.Colonies) do
		if IsValid(colony) and not colony.Absorbed then n = n + 1 end
	end
	return n
end

-- Whether the map has room for another patch at all.
function EvilFungus.Room()
	return Colonies() < MAX_COLONIES and EvilFungus.Strands() < EvilFungus.Setting("max_nodes") * 0.9
end

function EvilFungus.Taken(pos, clear)
	clear = clear or SPORE_CLEAR
	for colony in pairs(EvilFungus.Colonies) do
		if IsValid(colony) and colony.Mat and colony.Mat:Nearest(pos, clear) then return true end
	end
	return false
end
local Taken = EvilFungus.Taken

-- A new patch on the ground at pos. opts:
--   mass     the body it starts with
--   mind     the mind it thinks with
--   creator  who gets the credit for it
--   limit    cap on unsettled strands
--   dense    the whole patch comes out dense, since the spore left a dense strand
function EvilFungus.Plant(pos, normal, opts)
	local spore = ents.Create("evil_fungus")
	if not IsValid(spore) then return end
	spore:SetPos(pos + normal * 4)
	spore.SpawnAt, spore.SpawnUp, spore.StartMass = pos, normal, opts.mass
	spore.Mind, spore.Limit, spore.DenseAll = opts.mind, opts.limit, opts.dense
	spore:Spawn()
	spore:Activate()
	Own(spore, creator)
	return spore
end

concommand.Add("evil_fungus_clear", function(ply)
	if IsValid(ply) and not ply:IsSuperAdmin() then return end
	local list = {}
	for colony in pairs(EvilFungus.Colonies) do
		if IsValid(colony) then list[#list + 1] = colony end
	end
	for _, colony in ipairs(list) do colony:Remove() end
	if EvilFungus.Hosts then EvilFungus.Hosts.Clear() end
	hook.Run("EvilFungusCleared")
end, nil, "Remove every patch of fungus on the map")

-- Takes that much body out of the mat, evenly from everywhere it has any.
function ENT:Spend(mass)
	if self.Body <= EMPTY then return end
	local keep = math.max(0, 1 - mass / self.Body)
	for node in pairs(self.Mat.full) do self.Mat:SetMass(node, node.m * keep) end
	self.Body = self.Body * keep
end

function ENT:Throw(from, dir, dense)
	local tr = util.TraceLine({ start = from, endpos = from + dir * SPORE_RANGE, mask = MASK_SOLID_BRUSHONLY })
	if not tr.HitWorld or tr.HitSky or tr.HitNoDraw or tr.StartSolid or tr.Fraction <= 0.2 or Taken(tr.HitPos) then return false end
	local mass = self.Body * SPORE_SHARE
	local opts = { mass = mass, mind = self.Mind, creator = self:GetCreator(), dense = dense }
	if not EvilFungus.Plant(tr.HitPos, tr.HitNormal, opts) then return true end
	self:Spend(mass)

	local fx = EffectData()
	fx:SetStart(from)
	fx:SetOrigin(tr.HitPos)
	fx:SetNormal(tr.HitNormal)
	util.Effect("evil_fungus_spore", fx, true, true)
	return true
end

-- Fed well enough, it throws part of itself somewhere else to start over. Same fungus, so they find each other again.
-- Whoever it can smell getting away gets one at their feet, or once it's learned a bit, wherever they're running to.
function ENT:Spores(dt)
	local rate = EvilFungus.Setting("spores")
	if rate <= 0 or self.Limit or self.Body < SPORE_BODY then
		self.SporeDebt = 0
		return
	end
	self.SporeDebt = (self.SporeDebt or 0) + dt * rate / SPORE_EVERY
	if self.SporeDebt < 1 then return end
	self.SporeDebt = 0
	if not EvilFungus.Room() then return end

	local from = self.Center + self.Up * 24
	-- Note the strand it pushes out of: a spore off a dense one grows a patch that's dense throughout.
	local src = self.Mat:Nearest(from, SPORE_SOURCE)
	local dense = src and src.dense
	local prey = self.Hunting and self.Smelled == self.Prey and self.Prey
	local at = IsValid(prey) and self.Target
	if at and from:DistToSqr(at) < SPORE_RANGE * SPORE_RANGE
		and self:Throw(from, (at - from):GetNormalized(), dense) then
		return
	end
	for _ = 1, SPORE_TRIES do
		local dir = VectorRand()
		dir.z = math.abs(dir.z) * 0.5 + 0.2
		dir:Normalize()
		if self:Throw(from, dir, dense) then return end
	end
end

function ENT:Nearest(pos)
	local mat = self.Mat
	if not mat or not mat.mins then return end
	local pad = Vector(PRESENCE_REACH, PRESENCE_REACH, PRESENCE_REACH)
	if not pos:WithinAABox(mat.mins - pad, mat.maxs + pad) then return end
	local node = mat:Nearest(pos, PRESENCE_REACH)
	return node and node.pos
end

function ENT:OnRemove()
	EvilFungus.Colonies[self] = nil
	if not self.Absorbed and self.Mat and EvilFungus.Net then
		self.Mat:Forget()
	end
	if not self.Absorbed then
		for rag in pairs(self.Claimed or {}) do
			local s = EvilFungus.Sleepers[rag]
			if s and s.stage < EvilFungus.KEPT then
				EvilFungus.Sleep.Free(s)
			elseif EvilFungus.Sleep.wired[rag] then
				EvilFungus.Sleep.wired[rag].fungus = nil
			elseif IsValid(rag) then
				rag:Remove()
			end
		end
	end
	self:ReleaseAll()
end
