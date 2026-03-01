--!strict
-- AnimationController.lua
-- Root orchestrator. One instance per character.
-- Owns: LayerManager, ExclusiveGroupManager, StateMachine, all TrackWrappers.
-- No external system may directly manipulate AnimationTracks.
-- All animation operations are routed through this class.
--
-- ENVIRONMENT ROLES:
--   Owning Client  — plays animations locally, sends intents to server.
--   Server         — manages state machine authority, relays intents to other clients.
--                    Never loads or plays AnimationTracks.
--   Non-owning Client — receives relayed intents from server, plays animations locally
--                       to visually reconstruct the character's state on their screen.
--
-- AnimationTrack loading and playback only ever happens on clients.
-- The server runs the state machine and replication relay only.

local RunService = game:GetService("RunService")

local Types                 = require(script.Types)
local TrackWrapper          = require(script.TrackWrapper)
local LayerManager          = require(script.LayerManager)
local ExclusiveGroupManager = require(script.ExclusiveGroupManager)
local StateMachine          = require(script.StateMachine)
local ConflictResolver      = require(script.ConflictResolver)
local AnimationRegistry     = require(script.AnimationRegistry)
local ReplicationBridge     = require(script.ReplicationBridge)

type AnimationConfig    = Types.AnimationConfig
type LayerProfile       = Types.LayerProfile
type StateDefinition    = Types.StateDefinition
type AnimationDirective = Types.AnimationDirective
type PlayRequest        = Types.PlayRequest

local IS_SERVER = RunService:IsServer()

-- ── Pool Constants ─────────────────────────────────────────────────────────

local MAX_POOL_SIZE_PER_CONFIG = 2

-- ── Construction Config ────────────────────────────────────────────────────

export type ControllerConfig = {
	CharacterId    : string,
	Animator       : Animator?,   -- nil on the server; server never loads tracks
	IsOwningClient : boolean,     -- true only on the client that owns this character
	LayerProfiles  : { LayerProfile },
	States         : { StateDefinition },
	InitialState   : string,
	Predicates     : { [string]: () -> boolean },
	IntentRemote   : RemoteEvent?,
	SnapshotRemote : RemoteEvent?,
}

-- ── AnimationController ────────────────────────────────────────────────────

local AnimationController = {}
AnimationController.__index = AnimationController

function AnimationController.new(cfg: ControllerConfig): any
	local registry = AnimationRegistry.GetInstance()
	assert(registry:IsInitialized(),
		"[AnimationController] AnimationRegistry must be initialized before creating controllers")

	-- Server should never receive a real Animator — guard against misconfiguration.
	if IS_SERVER and cfg.Animator ~= nil then
		warn("[AnimationController] Animator was passed on the server. It will be ignored. " ..
			"The server does not load or play AnimationTracks.")
	end

	local self = setmetatable({
		CharacterId  = cfg.CharacterId,
		-- Only store the Animator on clients. Server gets nil.
		Animator     = IS_SERVER and nil or cfg.Animator,
		IsDestroyed  = false,

		LayerManager = nil,
		GroupManager = nil,
		StateMachine = nil,

		ActiveWrappers = {} :: { [string]: any },
		PendingQueue   = {} :: { PlayRequest },
		_wrapperPool   = {} :: { [string]: { any } },

		_replication   = nil,
		_frameConn     = nil :: RBXScriptConnection?,
	}, AnimationController)

	-- Build subsystems
	self.LayerManager = LayerManager.new(cfg.LayerProfiles)

	self.GroupManager = ExclusiveGroupManager.new(function(groupName: string, wrapper: any)
		self:_OnPendingReady(groupName, wrapper)
	end)

	self.StateMachine = StateMachine.new(
		cfg.States,
		cfg.InitialState,
		cfg.Predicates,
		function(exitState: StateDefinition, enterState: StateDefinition)
			self:_OnStateChange(exitState, enterState)
		end
	)

	self._replication = ReplicationBridge.new(
		cfg.CharacterId,
		cfg.IntentRemote,
		cfg.SnapshotRemote,
		cfg.IsOwningClient,
		function(intent: Types.AnimationIntent)
			self:_OnIntentReceived(intent)
		end
	)

	-- Bind per-frame update.
	-- Server uses Heartbeat. Clients use RenderStepped so the tick stays
	-- in sync with the render frame where animations are actually visible.
	local updateEvent = IS_SERVER and RunService.Heartbeat or RunService.RenderStepped
	self._frameConn = updateEvent:Connect(function(dt: number)
		self:_Tick(dt)
	end)

	return self
end

-- ── Per-Frame Pipeline ─────────────────────────────────────────────────────

function AnimationController:_Tick(dt: number)
	if self.IsDestroyed then return end

	-- Step 1: StateMachine evaluates pending transitions
	self.StateMachine:Tick()

	-- Step 2: LayerManager smoothly interpolates layer weights
	self.LayerManager:UpdateWeights(dt)

	-- Step 3: Push computed weights down to all active TrackWrappers
	self:_PushWeights()

	-- Step 4: Flush ReplicationBridge
	local activeGroupAnims = self:_BuildActiveGroupAnimMap()
	self._replication:Flush(dt, self.StateMachine:GetCurrentStateName(), activeGroupAnims)

	-- Step 5: Process play requests queued mid-frame
	self:_FlushPendingQueue()
end

-- ── Weight Push — O(W) ────────────────────────────────────────────────────

function AnimationController:_PushWeights()
	local toRemove: { string } = {}

	for name, wrapper in self.ActiveWrappers do
		local finalWeight = self.LayerManager:ComputeFinalWeight(
			wrapper.Config.Layer,
			wrapper.TargetWeight,
			wrapper.Config.Weight
		)
		wrapper:_SetEffectiveWeight(finalWeight)

		if not wrapper.IsPlaying and not wrapper.IsFading and wrapper.EffectiveWeight == 0 then
			table.insert(toRemove, name)
		end
	end

	for _, name in toRemove do
		self:_RetireWrapper(name)
	end
end

-- ── Wrapper Retirement & Pooling ──────────────────────────────────────────

function AnimationController:_RetireWrapper(configName: string)
	local wrapper = self.ActiveWrappers[configName]
	if not wrapper then return end

	self.LayerManager:UnregisterTrack(wrapper.Config.Layer, wrapper)

	if not self._wrapperPool[configName] then
		self._wrapperPool[configName] = {}
	end
	local pool = self._wrapperPool[configName]

	if #pool < MAX_POOL_SIZE_PER_CONFIG and wrapper:_IsPoolReady() then
		table.insert(pool, wrapper)
	else
		wrapper:_Destroy()
	end

	self.ActiveWrappers[configName] = nil
end

-- ── Wrapper Acquisition ───────────────────────────────────────────────────

function AnimationController:_AcquireWrapper(config: AnimationConfig): any
	-- Check pool first
	local pool = self._wrapperPool[config.Name]
	if pool and #pool > 0 then
		local wrapper = table.remove(pool) :: any
		wrapper:_Reinitialize()
		return wrapper
	end

	-- On the server, create a wrapper with no real track.
	-- The wrapper still maintains bookkeeping for group/state logic.
	if IS_SERVER then
		return TrackWrapper.new(config, nil)
	end

	-- On the client, load a real AnimationTrack.
	assert(self.Animator, "[AnimationController] Animator is nil on client — cannot load track")
	local anim = Instance.new("Animation")
	anim.AnimationId = config.AssetId
	local track = self.Animator:LoadAnimation(anim)
	anim:Destroy()

	return TrackWrapper.new(config, track)
end

-- ── Public Play API ───────────────────────────────────────────────────────

function AnimationController:Play(animationName: string)
	assert(not self.IsDestroyed, "[AnimationController] Cannot play on a destroyed controller")
	table.insert(self.PendingQueue, {
		ConfigName  = animationName,
		RequestTime = os.clock(),
	})
end

function AnimationController:PlayTag(tag: string)
	local registry = AnimationRegistry.GetInstance()
	for _, cfg in registry:GetByTag(tag) do
		self:Play(cfg.Name)
	end
end

-- ── Public Stop API ───────────────────────────────────────────────────────

function AnimationController:Stop(animationName: string, immediate: boolean?)
	local wrapper = self.ActiveWrappers[animationName]
	if not wrapper then return end
	wrapper:_Stop(immediate == true)
	if wrapper.Config.Group then
		self.GroupManager:ClearActive(wrapper.Config.Group)
	end
	if not IS_SERVER and self._replication._isOwningClient then
		self._replication:QueueIntent(animationName, "STOP", self.StateMachine:GetCurrentStateName())
	end
end

function AnimationController:StopGroup(groupName: string, immediate: boolean?)
	for _, wrapper in self.ActiveWrappers do
		if wrapper.Config.Group == groupName then
			self:Stop(wrapper.Config.Name, immediate)
		end
	end
end

-- ── Pending Queue Flush ────────────────────────────────────────────────────

function AnimationController:_FlushPendingQueue()
	if #self.PendingQueue == 0 then return end
	local queue = self.PendingQueue
	self.PendingQueue = {}
	for _, request in queue do
		self:_ExecutePlayRequest(request.ConfigName)
	end
end

-- ── Core Play Execution ───────────────────────────────────────────────────

function AnimationController:_ExecutePlayRequest(configName: string)
	local registry = AnimationRegistry.GetInstance()
	local config   = registry:GetByName(configName)
	if not config then
		warn(string.format("[AnimationController] Unknown animation '%s'", configName))
		return
	end

	local layerRecord = self.LayerManager:GetLayer(config.Layer)
	if not layerRecord then
		warn(string.format("[AnimationController] Animation '%s' references unknown layer '%s'",
			configName, config.Layer))
		return
	end

	local existing = self.ActiveWrappers[configName]
	if existing and existing.IsPlaying then return end

	-- ── Grouped path ──────────────────────────────────────────────────────
	if config.Group then
		self.GroupManager:EnsureGroup(config.Group)

		local incomingWrapper = self:_AcquireWrapper(config)
		local result = self.GroupManager:EvaluatePlayRequest(config.Group, incomingWrapper)

		if result.Verdict == "REJECT" then
			incomingWrapper:_Destroy()
			return
		elseif result.Verdict == "DEFER" then
			return
		elseif result.Verdict == "ALLOW" then
			if result.WrapperToStop then
				result.WrapperToStop:_Stop(false)
			end
			if result.PendingEvicted then
				result.PendingEvicted:_Destroy()
			end
			self:_ActivateWrapper(incomingWrapper, config, layerRecord)
			return
		end
	end

	-- ── Non-grouped path ──────────────────────────────────────────────────
	local incumbentWrapper: any = nil
	for _, wrapper in self.ActiveWrappers do
		if wrapper.Config.Layer == config.Layer and wrapper ~= existing then
			if incumbentWrapper == nil or wrapper.Config.Priority > incumbentWrapper.Config.Priority then
				incumbentWrapper = wrapper
			end
		end
	end

	local verdict: Types.ConflictVerdict
	if incumbentWrapper then
		verdict = ConflictResolver.ResolveNoGroup(
			config,
			layerRecord.Order,
			incumbentWrapper.Config,
			layerRecord.Order,
			incumbentWrapper.StartTimestamp
		)
	else
		verdict = "ALLOW"
	end

	if verdict == "ALLOW" then
		local wrapper = self:_AcquireWrapper(config)
		self:_ActivateWrapper(wrapper, config, layerRecord)
	end
end

-- ── Wrapper Activation ────────────────────────────────────────────────────

function AnimationController:_ActivateWrapper(wrapper: any, config: AnimationConfig, layerRecord: any)
	self.ActiveWrappers[config.Name] = wrapper
	self.LayerManager:RegisterTrack(config.Layer, wrapper)

	if not config.Looped and config.Group then
		wrapper.CompletedSignal:Connect(function()
			self.GroupManager:OnActiveCompleted(config.Group :: string)
		end)
	end

	wrapper:_Play()

	-- Only the owning client queues intents upward to the server.
	-- Non-owning clients are reconstructing state from a received intent,
	-- so sending another intent would create a replication loop.
	-- The server never sends intents — it only relays them.
	if not IS_SERVER and self._replication._isOwningClient then
		self._replication:QueueIntent(config.Name, "PLAY", self.StateMachine:GetCurrentStateName())
	end
end

-- ── Pending Ready Callback ────────────────────────────────────────────────

function AnimationController:_OnPendingReady(groupName: string, wrapper: any)
	if self.IsDestroyed then return end
	local config      = wrapper.Config
	local layerRecord = self.LayerManager:GetLayer(config.Layer)
	if not layerRecord then return end

	local result = self.GroupManager:EvaluatePlayRequest(groupName, wrapper)
	if result.Verdict == "ALLOW" then
		if result.WrapperToStop then
			result.WrapperToStop:_Stop(false)
		end
		self:_ActivateWrapper(wrapper, config, layerRecord)
	else
		wrapper:_Destroy()
	end
end

-- ── State Machine Callback ────────────────────────────────────────────────

function AnimationController:_OnStateChange(exitState: StateDefinition, enterState: StateDefinition)
	for _, directive in exitState.ExitActions do
		self:_DispatchDirective(directive)
	end

	local enterActive   : { [string]: boolean } = {}
	local enterSuppress : { [string]: boolean } = {}
	for _, name in enterState.ActiveLayers   do enterActive[name]   = true end
	for _, name in enterState.SuppressLayers do enterSuppress[name] = true end

	local exitActive   : { [string]: boolean } = {}
	local exitSuppress : { [string]: boolean } = {}
	for _, name in exitState.ActiveLayers   do exitActive[name]   = true end
	for _, name in exitState.SuppressLayers do exitSuppress[name] = true end

	for name in enterActive do
		if not exitActive[name] then
			self.LayerManager:SetLayerToBase(name)
		end
	end

	for name in enterSuppress do
		if not exitSuppress[name] then
			self.LayerManager:SuppressLayer(name)
		end
	end

	for _, directive in enterState.EntryActions do
		self:_DispatchDirective(directive)
	end
end

function AnimationController:_DispatchDirective(directive: AnimationDirective)
	if directive.Action == "PLAY" then
		if directive.Immediate then
			self:_ExecutePlayRequest(directive.Target)
		else
			self:Play(directive.Target)
		end
	elseif directive.Action == "STOP" then
		self:Stop(directive.Target, directive.Immediate)
	elseif directive.Action == "STOP_GROUP" then
		self:StopGroup(directive.Target, directive.Immediate)
	end
end

-- ── Replication Intent Receiver ───────────────────────────────────────────

-- Called on non-owning clients when the server relays an intent.
-- Reconstructs animation state by running the full local pipeline.
function AnimationController:_OnIntentReceived(intent: Types.AnimationIntent)
	if intent.Action == "PLAY" then
		self:Play(intent.AnimationName)
	elseif intent.Action == "STOP" then
		self:Stop(intent.AnimationName, false)
	end
end

-- ── State Machine Public Interface ────────────────────────────────────────

function AnimationController:RequestStateTransition(stateName: string, priority: number)
	self.StateMachine:RequestTransition(stateName, priority or 0)
end

-- ── Helper ─────────────────────────────────────────────────────────────────

function AnimationController:_BuildActiveGroupAnimMap(): { [string]: string }
	local map = {}
	for _, wrapper in self.ActiveWrappers do
		if wrapper.Config.Group and wrapper.IsPlaying then
			map[wrapper.Config.Group] = wrapper.Config.Name
		end
	end
	return map
end

-- ── Debug Inspector ───────────────────────────────────────────────────────

function AnimationController:AttachInspector(): any
	local DebugInspector = require(script.DebugInspector)
	return DebugInspector.new(self)
end

-- ── Destruction ───────────────────────────────────────────────────────────

function AnimationController:Destroy()
	if self.IsDestroyed then return end
	self.IsDestroyed = true

	if self._frameConn then
		self._frameConn:Disconnect()
		self._frameConn = nil
	end

	for name, wrapper in self.ActiveWrappers do
		wrapper:_Stop(true)
		wrapper:_Destroy()
	end
	table.clear(self.ActiveWrappers)

	for _, pool in self._wrapperPool do
		for _, wrapper in pool do
			wrapper:_Destroy()
		end
	end
	table.clear(self._wrapperPool)

	self.GroupManager:Destroy()
	self._replication:Destroy()
	table.clear(self.PendingQueue)
end

return AnimationController