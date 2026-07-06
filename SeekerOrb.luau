-- Discord: wyvern_br  |  Roblox: Shurieo
-- Seeker Orb — server-sided homing projectile ability.
-- Equip the tool and click: an orb launches and chases the nearest dummy in the
-- cone in front of you, curving to follow it, then blows up on contact.
-- Self-contained (spawns its own dummies) — drop it in ServerScriptService and Play.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")

-- all tunables in one place
local CONFIG = {
	LaunchSpeed = 40,                 -- studs/s the orb leaves the caster at
	MaxSpeed = 150,                   -- studs/s the orb accelerates up to
	Acceleration = 220,               -- studs/s^2 added along the heading
	TurnRate = math.rad(320),         -- max steering per second (radians)
	Lifetime = 4,                     -- seconds before an orb fizzles out
	HitRadius = 3.2,                  -- proximity fuse distance to the target
	Damage = 18,

	AcquireRange = 120,
	AcquireConeDot = math.cos(math.rad(55)), -- half-angle of the aiming cone
	Cooldown = 0.6,                   -- seconds between casts, per player

	OrbColor = Color3.fromRGB(120, 220, 255),
	OrbSize = Vector3.new(1.2, 1.2, 1.2),

	DummyCount = 3,
	DummyRespawn = 3,
	ArenaCenter = Vector3.new(0, 5, -20),
}

local Targets: { Model } = {}
local Active: { [any]: boolean } = {}
local OrbPool: { BasePart } = {}

-- orb parts are pooled and reused instead of rebuilt every shot
local function buildOrbPart(): BasePart
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Ball
	part.Size = CONFIG.OrbSize
	part.Material = Enum.Material.Neon
	part.Color = CONFIG.OrbColor
	part.Anchored = true      -- moved by CFrame, not physics
	part.CanCollide = false
	part.CanQuery = false     -- so it doesn't hit its own sweep raycast
	part.CastShadow = false

	local light = Instance.new("PointLight")
	light.Color = CONFIG.OrbColor
	light.Range = 10
	light.Brightness = 3
	light.Parent = part

	return part
end

local function acquireOrbPart(): BasePart
	local part = table.remove(OrbPool)
	return part or buildOrbPart()
end

local function releaseOrbPart(part: BasePart)
	part.Parent = nil
	table.insert(OrbPool, part)
end

local function isAlive(model: Model?): boolean
	if not model or not model.Parent then
		return false
	end
	local humanoid = model:FindFirstChildWhichIsA("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

-- nearest live target inside the forward cone (dot-product test)
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
		if forward:Dot(offset.Unit) < CONFIG.AcquireConeDot then
			continue -- outside the cone
		end
		if dist < bestDist then
			bestDist = dist
			best = model
		end
	end

	return best
end

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
	Debris:AddItem(flash, 0.4)
end

-- one orb in flight = one Projectile object
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

	-- ignore all player characters so orbs only hit the world and the dummies
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

-- turn the heading toward the target by at most TurnRate*dt so it curves instead
-- of snapping; returns the new unit heading
function Projectile:_steerDirection(dt: number): Vector3
	local heading = self.velocity.Unit

	if not isAlive(self.target) then
		self.target = acquireTarget(self.position, heading) -- reacquire, or coast
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

	local angle = math.acos(math.clamp(heading:Dot(desired), -1, 1))
	local maxStep = CONFIG.TurnRate * dt
	if angle <= maxStep then
		return desired -- can face it this frame
	end

	-- rotate heading toward desired by maxStep, around the axis perpendicular to both
	local axis = heading:Cross(desired)
	if axis.Magnitude < 1e-4 then
		-- anti-parallel: cross is zero, so pick any perpendicular axis
		axis = heading:Cross(Vector3.yAxis)
		if axis.Magnitude < 1e-4 then
			axis = heading:Cross(Vector3.xAxis)
		end
	end
	return (CFrame.fromAxisAngle(axis.Unit, maxStep) * heading).Unit
end

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

function Projectile:step(dt: number): boolean
	if not self.alive then
		return false
	end

	self.speed = math.min(self.speed + CONFIG.Acceleration * dt, CONFIG.MaxSpeed)
	local heading = self:_steerDirection(dt)
	self.velocity = heading * self.speed

	-- sweep a ray over this frame's travel so a fast orb can't skip through a wall
	local displacement = self.velocity * dt
	local hit = Workspace:Raycast(self.position, displacement, self.rayParams)
	if hit then
		local model = hit.Instance:FindFirstAncestorWhichIsA("Model")
		local humanoid = model and model:FindFirstChildWhichIsA("Humanoid") or nil
		self:_detonate(hit.Position, humanoid :: Humanoid?)
		return false
	end

	local newPosition = self.position + displacement

	-- proximity fuse for a hit the segment ray would just miss
	local target = self.target
	if target and isAlive(target) then
		local targetPos = target:GetPivot().Position
		if (targetPos - newPosition).Magnitude <= CONFIG.HitRadius then
			self:_detonate(newPosition, target:FindFirstChildWhichIsA("Humanoid") :: Humanoid?)
			return false
		end
	end

	self.position = newPosition
	self.part.CFrame = CFrame.lookAt(newPosition, newPosition + heading)

	self.life -= dt
	if self.life <= 0 then
		self:_detonate(newPosition, nil) -- ran out of fuel
		return false
	end
	return true
end

-- one shared loop drives every live orb (cheaper than a connection each)
RunService.Heartbeat:Connect(function(dt: number)
	for projectile in Active do
		projectile:step(dt)
	end
end)

-- minimal humanoid dummies built in code, with a health bar and respawn
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

	local head = Instance.new("Part") -- a Humanoid dies instantly without a Head
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
	humanoid.RequiresNeck = false -- this rig has no Neck joint
	humanoid.Parent = model

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

local function spawnDummy(position: Vector3)
	local model = buildDummy(position)
	table.insert(Targets, model)

	local humanoid = model:FindFirstChildWhichIsA("Humanoid") :: Humanoid
	humanoid.Died:Connect(function()
		local index = table.find(Targets, model)
		if index then
			table.remove(Targets, index) -- stop homing onto a corpse
		end
		task.delay(CONFIG.DummyRespawn, function()
			model:Destroy()
			spawnDummy(position)
		end)
	end)
end

-- Tool.Activated fires on the server, so the whole cast stays server-authoritative
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

	local now = os.clock()
	local readyAt = player:GetAttribute("SeekerReadyAt") or 0
	if now < (readyAt :: number) then
		return -- still on cooldown
	end
	player:SetAttribute("SeekerReadyAt", now + CONFIG.Cooldown)

	local origin = root.Position + root.CFrame.LookVector * 2 + Vector3.new(0, 1.5, 0)
	Projectile.new(character, origin, root.CFrame.LookVector)
end

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
		giveTool(player) -- backpack is rebuilt on respawn
	end)
	if player.Character then
		giveTool(player)
	end
end)

-- put the dummies in front of the map's SpawnLocation if there is one
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
