local SETTINGS = {
	ContainerName = "Collectibles",
	FloorLevel = 0,
	InteractionDistance = 10,
	InteractionKeyCode = Enum.KeyCode.E,
	HoldDuration = 0.3,
	CollectionCooldown = 0.75,
	CoreSpinSpeed = 1.2,
	CoreBobHeight = 0.16,
	CoreBobSpeed = 2,
	PersistCurrency = true,
	DataStoreName = "CollectibleCurrency_v1",
	AutosaveInterval = 90,
}

-- The server pays out these values directly so this table is the only place a reward can come from
local COLLECTIBLES = {
	{
		Id = "AuroraShard",
		DisplayName = "Aurora Shard",
		Value = 25,
		RespawnTime = 10,
		Position = Vector3.new(0, 2.6, -18),
		Color = Color3.fromRGB(105, 230, 255),
		Size = 1.4,
	},
	{
		Id = "EmberCore",
		DisplayName = "Ember Core",
		Value = 40,
		RespawnTime = 15,
		Position = Vector3.new(-22, 2.6, -4),
		Color = Color3.fromRGB(255, 138, 76),
		Size = 1.5,
	},
	{
		Id = "VerdantPrism",
		DisplayName = "Verdant Prism",
		Value = 55,
		RespawnTime = 20,
		Position = Vector3.new(18, 2.6, 6),
		Color = Color3.fromRGB(128, 240, 148),
		Size = 1.4,
	},
	{
		Id = "TidalPearl",
		DisplayName = "Tidal Pearl",
		Value = 70,
		RespawnTime = 25,
		Position = Vector3.new(-14, 2.6, 24),
		Color = Color3.fromRGB(86, 156, 255),
		Size = 1.6,
	},
	{
		Id = "SolarFragment",
		DisplayName = "Solar Fragment",
		Value = 90,
		RespawnTime = 30,
		Position = Vector3.new(26, 2.6, -22),
		Color = Color3.fromRGB(255, 214, 92),
		Size = 1.5,
	},
	{
		Id = "VoidCrystal",
		DisplayName = "Void Crystal",
		Value = 120,
		RespawnTime = 40,
		Position = Vector3.new(-30, 2.6, -24),
		Color = Color3.fromRGB(170, 110, 255),
		Size = 1.7,
	},
	{
		Id = "StormCell",
		DisplayName = "Storm Cell",
		Value = 160,
		RespawnTime = 50,
		Position = Vector3.new(8, 2.6, 32),
		Color = Color3.fromRGB(196, 214, 255),
		Size = 1.6,
	},
	{
		Id = "GoldenRelic",
		DisplayName = "Golden Relic",
		Value = 220,
		RespawnTime = 60,
		Position = Vector3.new(-32, 2.6, 8),
		Color = Color3.fromRGB(255, 186, 64),
		Size = 1.8,
	},
}

	-- Services and types and state

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

type CollectibleDefinition = {
	Id: string,
	DisplayName: string,
	Value: number,
	RespawnTime: number,
	Position: Vector3,
	Color: Color3,
	Size: number,
}

-- one of these is built for every entry in COLLECTIBLES at startup
type CollectibleState = {
	Definition: CollectibleDefinition,
	Model: Model,
	Core: BasePart,
	Pedestal: BasePart,
	Glow: PointLight,
	Prompt: ProximityPrompt,
	BaseCFrame: CFrame,
	CoreSize: Vector3,
	Available: boolean,
	Generation: number,
}

-- one of these exists for every player in the server
type PlayerState = {
	Cash: IntValue,
	Shards: IntValue,
	LastCollectAt: number,
	Ready: boolean,
	CanSave: boolean,
}

-- Prompts deactivate at InteractionDistance, the tolerance abosrbs character
-- movement and latency
-- anything lowk far away is still rejected
local RANGE_TOLERANCE = 6

local HIDE_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SHOW_TWEEN = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local collectibleFolder: Folder
local currencyStore: DataStore?
local spinConnection: RBXScriptConnection?
local elapsed = 0
local isShuttingDown = false

local collectibles: { CollectibleState } = {}
local playerStates: { [Player]: PlayerState } = {}

-- helperss
local function sanitizeAmount(value: any): number
	-- Saved data comes from outside this server so treat it as untrusted.
	local numberValue = tonumber(value)

	if not numberValue or numberValue ~= numberValue or math.abs(numberValue) == math.huge then
		return 0
	end

	return math.max(0, math.floor(numberValue))
end

local function openCurrencyStore(): DataStore?
	if not SETTINGS.PersistCurrency then
		return nil
	end

	local success, result = pcall(function()
		return DataStoreService:GetDataStore(SETTINGS.DataStoreName)
	end)

	if not success then
		-- a store that cannot be opened shouldnt stop the game from running
		warn("CollectibleSystem: could not open the currency DataStore. Progress will not persist this session.")
		warn(result)
		return nil
	end

	return result
end

local function isDefinitionValid(definition: any): boolean
	if type(definition) ~= "table" then
		return false
	end

	-- one malformed entry should not take down the whole spawn pass
	return type(definition.Id) == "string"
		and type(definition.DisplayName) == "string"
		and type(definition.Value) == "number"
		and type(definition.RespawnTime) == "number"
		and typeof(definition.Position) == "Vector3"
		and typeof(definition.Color) == "Color3"
		and type(definition.Size) == "number"
end

-- collectibles
local function updateCollectibles(deltaTime: number)
	elapsed += deltaTime

	for _, collectible in collectibles do
		if collectible.Available then
			-- the phase offset stops every core from bobbing in unison
			local phase = collectible.Definition.Position.X
			local bob = math.sin(elapsed * SETTINGS.CoreBobSpeed + phase) * SETTINGS.CoreBobHeight
			local spin = CFrame.Angles(0, elapsed * SETTINGS.CoreSpinSpeed + phase, 0)
			collectible.Core.CFrame = collectible.BaseCFrame * CFrame.new(0, bob, 0) * spin
		end
	end
end

-- The attribute is there for inspection in the explorer the server reads the table field, never the attribute
local function hideCollectible(collectible: CollectibleState)
	collectible.Prompt.Enabled = false
	collectible.Glow.Enabled = false
	collectible.Model:SetAttribute("Available", false)

	TweenService:Create(collectible.Core, HIDE_TWEEN, {
		Transparency = 1,
		Size = collectible.CoreSize * 0.3,
	}):Play()
end

local function showCollectible(collectible: CollectibleState)
	collectible.Core.Size = collectible.CoreSize * 0.3
	collectible.Core.Transparency = 1
	collectible.Core.CFrame = collectible.BaseCFrame
	collectible.Prompt.Enabled = true
	collectible.Glow.Enabled = true
	collectible.Model:SetAttribute("Available", true)

	TweenService:Create(collectible.Core, SHOW_TWEEN, {
		Transparency = 0.05,
		Size = collectible.CoreSize,
	}):Play()
end

local function isWithinRange(player: Player, core: BasePart): boolean
	local character = player.Character

	if not character then
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")

	if not humanoid or humanoid.Health <= 0 or not rootPart or not rootPart:IsA("BasePart") then
		return false
	end

	-- Prompt activation is client reported so the server measures the distance itself instead of trusting what the client claims
	return (rootPart.Position - core.Position).Magnitude <= SETTINGS.InteractionDistance + RANGE_TOLERANCE
end

local function awardCollectible(player: Player, collectible: CollectibleState)
	local state = playerStates[player]

	if not state or not state.Ready or not collectible.Available then
		return
	end

	local now = os.clock()

	if now - state.LastCollectAt < SETTINGS.CollectionCooldown then
		return
	end

	if not isWithinRange(player, collectible.Core) then
		return
	end

	-- clear the flag before the animation or the reward, A second trigger that arrives during the tween has to see the collectible as gone already
	collectible.Available = false
	collectible.Generation += 1
	local generation = collectible.Generation

	state.LastCollectAt = now
	state.Cash.Value += collectible.Definition.Value
	state.Shards.Value += 1

	hideCollectible(collectible)

	task.delay(collectible.Definition.RespawnTime, function()
		-- w a new collection bumps the generation and  shutdown cancels everything
		if isShuttingDown or collectible.Generation ~= generation then
			return
		end

		collectible.Available = true
		showCollectible(collectible)
	end)
end

local function createCollectible(definition: CollectibleDefinition): CollectibleState
	local coreSize = Vector3.new(definition.Size, definition.Size * 1.35, definition.Size)
	local coreBottom = definition.Position.Y - coreSize.Y * 0.5
	local columnHeight = math.max(0.2, coreBottom - SETTINGS.FloorLevel - 0.35)
	local columnDiameter = definition.Size * 0.85

	local model = Instance.new("Model")
	model.Name = definition.Id
	model:SetAttribute("Value", definition.Value)
	model:SetAttribute("Available", true)

	local pedestal = Instance.new("Part")
	pedestal.Name = "Pedestal"
	pedestal.Shape = Enum.PartType.Cylinder
	pedestal.Size = Vector3.new(columnHeight, columnDiameter, columnDiameter)
	-- roblox cylinders run along x, so this rotation stands the pedestal up
	pedestal.CFrame = CFrame.new(definition.Position.X, SETTINGS.FloorLevel + columnHeight * 0.5, definition.Position.Z)
		* CFrame.Angles(0, 0, math.rad(90))
	pedestal.Anchored = true
	pedestal.CanCollide = false
	pedestal.CanTouch = false
	pedestal.Material = Enum.Material.SmoothPlastic
	pedestal.Color = definition.Color:Lerp(Color3.new(0, 0, 0), 0.65)
	pedestal.Parent = model

	local core = Instance.new("Part")
	core.Name = "Core"
	core.Size = coreSize
	core.CFrame = CFrame.new(definition.Position)
	core.Anchored = true
	core.CanCollide = false
	core.CanTouch = false
	core.CanQuery = false
	core.CastShadow = false
	core.Material = Enum.Material.Neon
	core.Color = definition.Color
	core.Transparency = 0.05
	core.Parent = model

	local glow = Instance.new("PointLight")
	glow.Color = definition.Color
	glow.Brightness = 1.4
	glow.Range = 9
	glow.Shadows = false
	glow.Parent = core

	-- The prompt sits inside the core so it follows the idle animation, it fires on the server, which is why this project needs no remotes
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Collect"
	prompt.ObjectText = definition.DisplayName
	prompt.HoldDuration = SETTINGS.HoldDuration
	prompt.MaxActivationDistance = SETTINGS.InteractionDistance
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = SETTINGS.InteractionKeyCode
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.Parent = core

	model.PrimaryPart = core
	model.Parent = collectibleFolder

	local collectible: CollectibleState = {
		Definition = definition,
		Model = model,
		Core = core,
		Pedestal = pedestal,
		Glow = glow,
		Prompt = prompt,
		BaseCFrame = core.CFrame,
		CoreSize = coreSize,
		Available = true,
		Generation = 0,
	}

	prompt.Triggered:Connect(function(player)
		awardCollectible(player, collectible)
	end)

	return collectible
end

-- player data

local function createPlayerState(player: Player): PlayerState
	-- create the leaderstats folder(obv)
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player

	local cash = Instance.new("IntValue")
	cash.Name = "Cash"
	cash.Parent = leaderstats

	local shards = Instance.new("IntValue")
	shards.Name = "Shards"
	shards.Parent = leaderstats

	local state: PlayerState = {
		Cash = cash,
		Shards = shards,
		LastCollectAt = 0,
		Ready = false,
		CanSave = false,
	}

	playerStates[player] = state
	return state
end

local function loadProfile(player: Player, state: PlayerState)
	local store = currencyStore

	if not store then
		state.Ready = true
		return
	end

	local success, result = pcall(function()
		return store:GetAsync(player.UserId)
	end)

	-- the player may have left while the request was in flight
	if playerStates[player] ~= state then
		return
	end

	if not success then
		-- rewareds stay on for this session, but saving is disabled, Writing defaults here would overwrite the real profile.
		warn(("CollectibleSystem: failed to load data for %s (%d). This session will not be saved."):format(player.Name, player.UserId))
		warn(result)
		state.Ready = true
		return
	end

	if type(result) == "table" then
		state.Cash.Value = sanitizeAmount(result.Cash)
		state.Shards.Value = sanitizeAmount(result.Collected)
	end

	state.CanSave = true
	state.Ready = true
end

local function saveProfile(player: Player, state: PlayerState)
	local store = currencyStore

	if not store or not state.CanSave then
		return
	end

	local payload = {
		Cash = state.Cash.Value,
		Collected = state.Shards.Value,
		Version = 1,
		UpdatedAt = os.time(),
	}

	local success, errorMessage = pcall(function()
		store:SetAsync(player.UserId, payload)
	end)

	if not success then
		warn(("CollectibleSystem: failed to save data for %s (%d). %s"):format(player.Name, player.UserId, tostring(errorMessage)))
	end
end

local function onPlayerAdded(player: Player)
	local state = createPlayerState(player)
	task.spawn(loadProfile, player, state)
end

local function onPlayerRemoving(player: Player)
	local state = playerStates[player]

	if not state then
		return
	end

	playerStates[player] = nil
	saveProfile(player, state)
end

local function runAutosave()
	while not isShuttingDown do
		task.wait(SETTINGS.AutosaveInterval)

		if isShuttingDown then
			break
		end

		for player, state in playerStates do
			if state.CanSave then
				task.spawn(saveProfile, player, state)
			end
		end
	end
end

-- startup and shutdown

local function start()
	currencyStore = openCurrencyStore()

	collectibleFolder = Instance.new("Folder")
	collectibleFolder.Name = SETTINGS.ContainerName
	collectibleFolder.Parent = workspace

	for index, definition in COLLECTIBLES do
		if isDefinitionValid(definition) then
			table.insert(collectibles, createCollectible(definition :: CollectibleDefinition))
		else
			warn(("CollectibleSystem: skipped invalid collectible definition at index %d."):format(index))
		end
	end

	-- one connection for every core, a loop per collectible would be easier to read and much worse at scale
	spinConnection = RunService.Heartbeat:Connect(updateCollectibles)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	task.spawn(runAutosave)
end

game:BindToClose(function()
	isShuttingDown = true

	if spinConnection then
		spinConnection:Disconnect()
	end

	-- BindToClose allows roughly 30 seconds stop waiting after 20 and let the remaining saves finish or time out on their own
	local pendingSaves = 0

	for player, state in playerStates do
		if state.CanSave then
			pendingSaves += 1

			task.spawn(function()
				saveProfile(player, state)
				pendingSaves -= 1
			end)
		end
	end

	local deadline = os.clock() + 20

	while pendingSaves > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
end)

start()
