-- Discord: wyvern_br  |  Roblox: Shurieo
--[[
	SeekerOrb.luau
	Server-authoritative homing-projectile ability for a Roblox combat game.

	Equip the "Seeker Orb" tool and click: a glowing orb launches from your
	character, locks onto the nearest enemy inside a forward cone and curves
	toward it using a clamped steering rule (bounded turn rate), then detonates on
	contact and deals damage. Everything runs on the server so the outcome cannot
	be spoofed by an exploiter — the client only asks, the server decides.

	Techniques demonstrated:
	  * Object-oriented Luau via metatables (the Projectile class).
	  * CFrame / vector math: CFrame.lookAt to orient the visual, and
	    CFrame.fromAxisAngle for the steering rotation (cross/dot products).
	  * Frame-rate-independent physics: velocity integration with acceleration,
	    a max-speed clamp, and a bounded turn rate scaled by delta-time.
	  * A swept raycast across each step so a fast orb can never tunnel through a
	    thin target or wall between frames.
	  * Efficiency: a single shared Heartbeat loop drives every live orb, and orb
	    parts are recycled through a pool instead of being re-created per shot.

	Place this Script in ServerScriptService. It builds its own training dummies
	so it is fully self-contained and demonstrable with no extra scripts.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")

--------------------------------------------------------------------------------
-- CONFIG — every tunable lives here so behaviour is data-driven, not hardcoded.
--------------------------------------------------------------------------------
local CONFIG = {
	LaunchSpeed = 40,                 -- studs/s the orb leaves the caster at
	MaxSpeed = 150,                   -- studs/s the orb accelerates up to
	Acceleration = 220,               -- studs/s^2 added along the heading
	TurnRate = math.rad(320),         -- max steering per second (radians)
	Lifetime = 4,                     -- seconds before an orb fizzles out
	HitRadius = 3.2,                  -- proximity fuse distance to the target
	Damage = 18,                      -- damage dealt on a direct hit

	AcquireRange = 120,               -- how far the orb will look for a target
	AcquireConeDot = math.cos(math.rad(55)), -- half-angle of the aiming cone
	Cooldown = 0.6,                   -- seconds between casts, per player

	OrbColor = Color3.fromRGB(120, 220, 255),
	OrbSize = Vector3.new(1.2, 1.2, 1.2),

	DummyCount = 3,                   -- training dummies spawned for the demo
	DummyRespawn = 3,                 -- seconds before a slain dummy returns
	ArenaCenter = Vector3.new(0, 5, -20), -- where the dummies stand
}

--------------------------------------------------------------------------------
-- SHARED STATE
--------------------------------------------------------------------------------
local Targets: { Model } = {}  -- enemy models an orb is allowed to home onto
local Active: { [any]: boolean } = {} -- set of live Projectile objects
local OrbPool: { BasePart } = {} -- recycled orb parts, to avoid churn

--------------------------------------------------------------------------------
-- ORB PART POOL
-- Re-creating an Instance for every shot is wasteful; instead we keep a small
-- pool and hand parts back and forth as orbs are born and die.
--------------------------------------------------------------------------------
local function buildOrbPart(): BasePart
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Ball
	part.Size = CONFIG.OrbSize
	part.Material = Enum.Material.Neon
	part.Color = CONFIG.OrbColor
	part.Anchored = true      -- movement is CFrame-driven, not physics-simulated
	part.CanCollide = false
	part.CanQuery = false     -- must never register on its own sweep raycast
	part.CastShadow = false

	local light = Instance.new("PointLight")
	light.Color = CONFIG.OrbColor
	light.Range = 10
	light.Brightness = 3
	light.Parent = part

	return part
end

local function acquireOrbPart(): BasePart
	local part = table.remove(OrbPool) -- reuse a retired part if we have one
	return part or buildOrbPart()
end

local function releaseOrbPart(part: BasePart)
	part.Parent = nil
	table.insert(OrbPool, part)
end

--------------------------------------------------------------------------------
-- TARGETING HELPERS
--------------------------------------------------------------------------------

-- A model is a valid target only while it exists and its Humanoid is alive.
local function isAlive(model: Model?): boolean
	if not model or not model.Parent then
		return false
	end
	local humanoid = model:FindFirstChildWhichIsA("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

-- Pick the nearest living enemy that sits inside the cone around `forward`.
-- The cone test is a single dot product: forward · toTargetUnit >= cos(angle).
local function acquireTarget(origin: Vector3, forward: Vector3): Model?
	local best: Model? = nil
	local bestDist = math.huge

	for _, model in Targets do
		if not isAlive(model) then
			continue
		end
		local offset = model:GetPivot().Position - origin
		local dist = offset.Magnitude
		if dist > CONFIG.AcquireRange or dist < 1e-3 then
			continue
		end
		-- Reject anything outside the forward cone (behind or off to the side).
		if forward:Dot(offset.Unit) < CONFIG.AcquireConeDot then
			continue
		end
		if dist < bestDist then
			bestDist = dist
			best = model
		end
	end

	return best
end

-- A quick expanding neon flash + light burst at the point of impact.
local function spawnImpactFx(position: Vector3)
	local flash = Instance.new("Part")
	flash.Shape = Enum.PartType.Ball
	flash.Size = Vector3.new(2, 2, 2)
	flash.CFrame = CFrame.new(position)
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.Material = Enum.Material.Neon
	flash.Color = CONFIG.OrbColor
	flash.Transparency = 0.1
	flash.Parent = Workspace

	local info = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(flash, info, { Size = Vector3.new(11, 11, 11), Transparency = 1 }):Play()
	Debris:AddItem(flash, 0.4) -- auto-clean so the FX never accumulates
end

--------------------------------------------------------------------------------
-- PROJECTILE CLASS (metatable-based OOP)
-- Each orb in flight is one Projectile object. All shared behaviour lives on the
-- class table; per-orb data (position, velocity, target...) lives on the instance.
--------------------------------------------------------------------------------
local Projectile = {}
Projectile.__index = Projectile

type Projectile = typeof(setmetatable(
	{} :: {
		owner: Model,
		position: Vector3,
		velocity: Vector3,
		speed: number,
		target: Model?,
		part: BasePart,
		rayParams: RaycastParams,
		life: number,
		alive: boolean,
	},
	Projectile
))

function Projectile.new(owner: Model, origin: Vector3, direction: Vector3): Projectile
	local self = setmetatable({}, Projectile) :: Projectile
	self.owner = owner
	self.position = origin
	self.speed = CONFIG.LaunchSpeed
	self.velocity = direction.Unit * self.speed
	self.target = acquireTarget(origin, direction.Unit)
	self.life = CONFIG.Lifetime
	self.alive = true

	-- Exclude every player character so orbs pass harmlessly through people and
	-- only ever interact with the world and the training dummies.
	local ignore: { Instance } = {}
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(ignore, player.Character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true
	self.rayParams = params

	local part = acquireOrbPart()
	part.CFrame = CFrame.new(origin)
	part.Parent = Workspace
	self.part = part

	Active[self] = true
	return self
end

-- Rotate the current heading toward the target by at most TurnRate*dt and return
-- the new unit heading. This bounded turn is what makes the orb curve gracefully
-- instead of snapping instantly to face the target.
function Projectile:_steerDirection(dt: number): Vector3
	local heading = self.velocity.Unit

	-- Drop a dead/expired target and try to reacquire; coast straight if none.
	if not isAlive(self.target) then
		self.target = acquireTarget(self.position, heading)
	end
	local target = self.target
	if not target then
		return heading
	end

	local toTarget = target:GetPivot().Position - self.position
	if toTarget.Magnitude < 1e-4 then
		return heading
	end
	local desired = toTarget.Unit

	-- Angular error between where we point and where we want to point.
	local angle = math.acos(math.clamp(heading:Dot(desired), -1, 1))
	local maxStep = CONFIG.TurnRate * dt
	if angle <= maxStep then
		return desired -- close enough to face the target this frame
	end

	-- Rotate `heading` toward `desired` by exactly maxStep, around the axis that
	-- is perpendicular to both (their cross product).
	local axis = heading:Cross(desired)
	if axis.Magnitude < 1e-4 then
		-- Degenerate case: heading and desired are anti-parallel, so the cross
		-- product is zero — fall back to any perpendicular axis.
		axis = heading:Cross(Vector3.yAxis)
		if axis.Magnitude < 1e-4 then
			axis = heading:Cross(Vector3.xAxis)
		end
	end
	return (CFrame.fromAxisAngle(axis.Unit, maxStep) * heading).Unit
end

-- End this orb's life: apply damage (if it struck a Humanoid), play FX, recycle.
function Projectile:_detonate(at: Vector3, humanoid: Humanoid?)
	if not self.alive then
		return
	end
	self.alive = false

	if humanoid then
		humanoid:TakeDamage(CONFIG.Damage)
	end
	spawnImpactFx(at)
	releaseOrbPart(self.part)
	Active[self] = nil
end

-- Advance the orb by one frame. Returns false once the orb has been retired.
function Projectile:step(dt: number): boolean
	if not self.alive then
		return false
	end

	-- 1) Accelerate along the current heading, clamped to the maximum speed.
	self.speed = math.min(self.speed + CONFIG.Acceleration * dt, CONFIG.MaxSpeed)

	-- 2) Steer the heading toward the target, then rebuild the velocity vector.
	local heading = self:_steerDirection(dt)
	self.velocity = heading * self.speed

	-- 3) Integrate position, but sweep a ray across the whole travel segment so a
	--    fast orb cannot skip over a thin wall or target between frames.
	local displacement = self.velocity * dt
	local hit = Workspace:Raycast(self.position, displacement, self.rayParams)
	if hit then
		local model = hit.Instance:FindFirstAncestorWhichIsA("Model")
		local humanoid = model and model:FindFirstChildWhichIsA("Humanoid") or nil
		self:_detonate(hit.Position, humanoid :: Humanoid?)
		return false
	end

	local newPosition = self.position + displacement

	-- Proximity fuse: also detonate if we pass within HitRadius of the target's
	-- centre, catching cases the segment ray would just miss.
	local target = self.target
	if target and isAlive(target) then
		local targetPos = target:GetPivot().Position
		if (targetPos - newPosition).Magnitude <= CONFIG.HitRadius then
			self:_detonate(newPosition, target:FindFirstChildWhichIsA("Humanoid") :: Humanoid?)
			return false
		end
	end

	-- Commit the move and point the visual where the orb is travelling.
	self.position = newPosition
	self.part.CFrame = CFrame.lookAt(newPosition, newPosition + heading)

	self.life -= dt
	if self.life <= 0 then
		self:_detonate(newPosition, nil) -- ran out of fuel — fizzle harmlessly
		return false
	end
	return true
end

--------------------------------------------------------------------------------
-- SIMULATION LOOP
-- One shared Heartbeat connection steps every live orb. This is far cheaper than
-- giving each orb its own connection and keeps all motion on a single clock.
--------------------------------------------------------------------------------
RunService.Heartbeat:Connect(function(dt: number)
	for projectile in Active do
		projectile:step(dt)
	end
end)

--------------------------------------------------------------------------------
-- TRAINING DUMMIES
-- Minimal humanoid rigs built purely from code so the demo needs no imported
-- models. Each carries a floating health bar and respawns after it is destroyed.
--------------------------------------------------------------------------------
local function buildDummy(position: Vector3): Model
	local model = Instance.new("Model")
	model.Name = "SeekerDummy"

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 4, 1)
	root.CFrame = CFrame.new(position)
	root.Color = Color3.fromRGB(200, 80, 80)
	root.Material = Enum.Material.SmoothPlastic
	root.Anchored = true
	root.Parent = model
	model.PrimaryPart = root

	-- A Humanoid instantly dies without a part named "Head", so give it one.
	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(1.4, 1.4, 1.4)
	head.CFrame = root.CFrame * CFrame.new(0, 2.7, 0)
	head.Color = Color3.fromRGB(200, 80, 80)
	head.Material = Enum.Material.SmoothPlastic
	head.Anchored = true
	head.Parent = model

	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = 100
	humanoid.Health = 100
	humanoid.RequiresNeck = false -- keep the rig alive without a Neck Motor6D
	humanoid.Parent = model

	-- Floating health bar so hits are clearly visible during the demo.
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(4, 0.5)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 2, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = head

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(60, 220, 90)
	fill.BorderSizePixel = 0
	fill.Parent = billboard

	humanoid.HealthChanged:Connect(function(health)
		fill.Size = UDim2.fromScale(math.clamp(health / humanoid.MaxHealth, 0, 1), 1)
	end)

	model.Parent = Workspace
	return model
end

-- Spawn a dummy, register it as a valid target, and wire up its respawn.
local function spawnDummy(position: Vector3)
	local model = buildDummy(position)
	table.insert(Targets, model)

	local humanoid = model:FindFirstChildWhichIsA("Humanoid") :: Humanoid
	humanoid.Died:Connect(function()
		local index = table.find(Targets, model)
		if index then
			table.remove(Targets, index) -- stop orbs homing onto a corpse
		end
		task.delay(CONFIG.DummyRespawn, function()
			model:Destroy()
			spawnDummy(position) -- bring a fresh dummy back at the same spot
		end)
	end)
end

--------------------------------------------------------------------------------
-- CAST TRIGGER
-- Players cast by clicking the "Seeker Orb" tool. Tool.Activated fires on the
-- server, so the client only signals intent — the server validates the caster's
-- state, enforces the cooldown, and is the sole authority that spawns the orb.
--------------------------------------------------------------------------------
local function tryCast(player: Player)
	local character = player.Character
	if not character then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character:FindFirstChildWhichIsA("Humanoid")
	if not root or not humanoid or humanoid.Health <= 0 then
		return
	end

	-- Per-player cooldown, stored server-side as an attribute.
	local now = os.clock()
	local readyAt = player:GetAttribute("SeekerReadyAt") or 0
	if now < (readyAt :: number) then
		return
	end
	player:SetAttribute("SeekerReadyAt", now + CONFIG.Cooldown)

	-- Launch from just in front of the chest, along the player's facing.
	local origin = root.Position + root.CFrame.LookVector * 2 + Vector3.new(0, 1.5, 0)
	Projectile.new(character, origin, root.CFrame.LookVector)
end

-- Hand every player a click-to-cast tool. RequiresHandle is false so the ability
-- needs no held model, and the tool is re-issued on every respawn.
local function giveTool(player: Player)
	local tool = Instance.new("Tool")
	tool.Name = "Seeker Orb"
	tool.RequiresHandle = false
	tool.CanBeDropped = false
	tool.ToolTip = "Click to launch a homing orb"
	tool.Activated:Connect(function()
		tryCast(player)
	end)
	tool.Parent = player:WaitForChild("Backpack")
end

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function()
		giveTool(player)
	end)
	if player.Character then
		giveTool(player)
	end
end)

--------------------------------------------------------------------------------
-- BOOTSTRAP
-- Stand the dummies just ahead of the map's SpawnLocation when one exists, so the
-- demo is always visible right where players appear; otherwise use ArenaCenter.
--------------------------------------------------------------------------------
local function resolveArenaCenter(): Vector3
	local spawn = Workspace:FindFirstChildWhichIsA("SpawnLocation", true)
	if spawn then
		return spawn.Position + spawn.CFrame.LookVector * 18 + Vector3.new(0, 3, 0)
	end
	return CONFIG.ArenaCenter
end

local arenaCenter = resolveArenaCenter()
for i = 1, CONFIG.DummyCount do
	local angle = (i / CONFIG.DummyCount) * math.pi * 2
	local offset = Vector3.new(math.cos(angle), 0, math.sin(angle)) * 14
	spawnDummy(arenaCenter + offset)
end

print("[SeekerOrb] Ready — equip the Seeker Orb tool and click to fire.")
