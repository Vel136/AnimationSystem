--!strict
-- AnimationController.lua
-- Root orchestrator. One instance per character.
-- Owns: LayerManager, ExclusiveGroupManager, StateMachine, all TrackWrappers.
-- No external system may directly manipulate AnimationTracks.
-- All animation operations are routed through this class.

local RunService = game:GetService("RunService")

local Types               = require(script.Types)
local TrackWrapper        = require(script.TrackWrapper)
local LayerManager        = require(script.LayerManager)
local ExclusiveGroupManager = require(script.ExclusiveGroupManager)
local StateMachine        = require(script.StateMachine)
local ConflictResolver    = require(script.ConflictResolver)
local AnimationRegistry   = require(script.AnimationRegistry)
local ReplicationBridge   = require(script.ReplicationBridge)

type AnimationConfig    = Types.AnimationConfig
type LayerProfile       = Types.LayerProfile
type StateDefinition    = Types.StateDefinition
type AnimationDirective = Types.AnimationDirective
type PlayRequest        = Types.PlayRequest

-- ── Pool Constants ─────────────────────────────────────────────────────────

local MAX_POOL_SIZE_PER_CONFIG = 2

-- ── Construction Config ────────────────────────────────────────────────────

export type ControllerConfig = {
	CharacterId    : string,
	Animator       : Animator,
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
	assert(registry:IsInitialized(), "[AnimationController] AnimationRegistry must be initialized before creating controllers")

	local self = setmetatable({
		CharacterId  = cfg.CharacterId,
		Animator     = cfg.Animator,
		IsDestroyed  = false,

		-- Subsystems (created below)
		LayerManager = nil,
		GroupManager = nil,
		StateMachine = nil,

		-- Track management
		ActiveWrappers = {} :: { [string]: any }, -- keyed by Config.Name
		PendingQueue   = {} :: { PlayRequest },
		_wrapperPool   = {} :: { [string]: { any } }, -- keyed by Config.Name

		-- Replication
		_replication   = nil,

		-- Frame connections
		_frameConn     = nil :: RBXScriptConnection?,
	}, AnimationController)

	-- Build LayerManager
	self.LayerManager = LayerManager.new(cfg.LayerProfiles)

	-- Build ExclusiveGroupManager with pending-ready callback
	self.GroupManager = ExclusiveGroupManager.new(function(groupName: string, wrapper: any)
		self:_OnPendingReady(groupName, wrapper)
	end)

	-- Build StateMachine with state-change callback
	self.StateMachine = StateMachine.new(
		cfg.States,
		cfg.InitialState,
		cfg.Predicates,
		function(exitState: StateDefinition, enterState: StateDefinition)
			self:_OnStateChange(exitState, enterState)
		end
	)

	-- Build ReplicationBridge
	self._replication = ReplicationBridge.new(
		cfg.CharacterId,
		cfg.IntentRemote,
		cfg.SnapshotRemote,
		function(intent: Types.AnimationIntent)
			self:_OnIntentReceived(intent)
		end
	)

	-- Bind per-frame update
	local isServer = RunService:IsServer()
	local updateEvent = isServer and RunService.Heartbeat or RunService.RenderStepped
	self._frameConn = updateEvent:Connect(function(dt: number)
		self:_Tick(dt)
	end)

	return self
end

-- ── Per-Frame Pipeline ─────────────────────────────────────────────────────

function AnimationController:_Tick(dt: number)
	if self.IsDestroyed then return end

	-- Step 1: StateMachine evaluates pending transition requests
	self.StateMachine:Tick()

	-- Step 2: LayerManager recomputes blended weights for layers whose target changed
	self.LayerManager:UpdateWeights(dt)

	-- Step 3: Push computed weights to all active TrackWrappers
	self:_PushWeights()

	-- Step 4: Flush ReplicationBridge intent queue
	local activeGroupAnims = self:_BuildActiveGroupAnimMap()
	self._replication:Flush(dt, self.StateMachine:GetCurrentStateName(), activeGroupAnims)

	-- Step 5: Process pending play requests (queued mid-frame)
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

		-- Remove fully stopped, fully-faded wrappers
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

	-- Return to pool if pool has capacity
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

-- ── Wrapper Acquisition (with Pooling) ───────────────────────────────────

function AnimationController:_AcquireWrapper(config: AnimationConfig): any
	-- Check pool first
	local pool = self._wrapperPool[config.Name]
	if pool and #pool > 0 then
		local wrapper = table.remove(pool) :: any
		wrapper:_Reinitialize()
		return wrapper
	end

	-- Load a fresh AnimationTrack
	local anim = Instance.new("Animation")
	anim.AnimationId = config.AssetId
	local track = self.Animator:LoadAnimation(anim)
	anim:Destroy() -- Roblox keeps the track alive independently

	return TrackWrapper.new(config, track)
end

-- ── Public Play API ───────────────────────────────────────────────────────

-- Primary entry point for external systems.
-- Play requests arriving mid-frame are queued and processed at step 5 of the next tick.
-- (Exception: requests explicitly marked as immediate are processed inline — not in this impl;
--  external callers use the standard path and the pipeline handles timing.)
function AnimationController:Play(animationName: string)
	assert(not self.IsDestroyed, "[AnimationController] Cannot play on a destroyed controller")

	table.insert(self.PendingQueue, {
		ConfigName  = animationName,
		RequestTime = os.clock(),
	})
end

-- Convenience: play all animations with a given tag
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
	self._replication:QueueIntent(animationName, "STOP", self.StateMachine:GetCurrentStateName())
end

function AnimationController:StopGroup(groupName: string, immediate: boolean?)
	for _, wrapper in self.ActiveWrappers do
		if wrapper.Config.Group == groupName then
			self:Stop(wrapper.Config.Name, immediate)
		end
	end
end

-- ── Pending Queue Flush — O(Q) ────────────────────────────────────────────

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

	-- If already playing this exact animation, do nothing (idempotent)
	local existing = self.ActiveWrappers[configName]
	if existing and existing.IsPlaying then return end

	-- ── Group conflict evaluation ─────────────────────────────────────────
	if config.Group then
		self.GroupManager:EnsureGroup(config.Group)

		-- Build the incoming wrapper ahead of evaluation so we can pass it to group manager
		local incomingWrapper = self:_AcquireWrapper(config)

		local result = self.GroupManager:EvaluatePlayRequest(config.Group, incomingWrapper)

		if result.Verdict == "REJECT" then
			-- Discard the wrapper we just acquired
			incomingWrapper:_Destroy()
			return
		elseif result.Verdict == "DEFER" then
			-- Wrapper is now held as PendingWrapper in the group — do not play yet.
			-- The group manager will call _OnPendingReady when it's eligible.
			return
		elseif result.Verdict == "ALLOW" then
			-- Fade out the displaced active wrapper if any
			if result.WrapperToStop then
				result.WrapperToStop:_Stop(false)
			end
			if result.PendingEvicted then
				result.PendingEvicted:_Destroy()
			end
			-- Activate the incoming wrapper
			self:_ActivateWrapper(incomingWrapper, config, layerRecord)
			return
		end
	end

	-- ── Non-grouped: run ConflictResolver against same-layer incumbents ───
	-- Find any active wrapper on the same layer
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
			layerRecord.Order, -- same layer by definition in this branch
			incumbentWrapper.StartTimestamp
		)
	else
		verdict = "ALLOW"
	end

	if verdict == "ALLOW" then
		local wrapper = self:_AcquireWrapper(config)
		self:_ActivateWrapper(wrapper, config, layerRecord)
	end
	-- DEFER is not meaningful without group context; REJECT means do nothing.
end

-- Activates a wrapper: registers it, plays it, notifies replication.
function AnimationController:_ActivateWrapper(wrapper: any, config: AnimationConfig, layerRecord: any)
	self.ActiveWrappers[config.Name] = wrapper
	self.LayerManager:RegisterTrack(config.Layer, wrapper)

	-- Wire completion for non-looped tracks to notify group manager
	if not config.Looped and config.Group then
		wrapper.CompletedSignal:Connect(function()
			self.GroupManager:OnActiveCompleted(config.Group :: string)
		end)
	end

	wrapper:_Play()
	self._replication:QueueIntent(config.Name, "PLAY", self.StateMachine:GetCurrentStateName())
end

-- ── Pending Ready Callback ────────────────────────────────────────────────

-- Called by ExclusiveGroupManager when a deferred request becomes eligible.
function AnimationController:_OnPendingReady(groupName: string, wrapper: any)
	if self.IsDestroyed then return end
	local config      = wrapper.Config
	local layerRecord = self.LayerManager:GetLayer(config.Layer)
	if not layerRecord then return end

	-- Re-run group evaluation to confirm no new conflict arose during the wait
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
	-- Dispatch ExitActions first (in order) before any entry begins
	for _, directive in exitState.ExitActions do
		self:_DispatchDirective(directive)
	end

	-- Compute diff-driven layer weight changes (minimum set of changes)
	-- Build sets for quick lookup
	local enterActive   : { [string]: boolean } = {}
	local enterSuppress : { [string]: boolean } = {}
	for _, name in enterState.ActiveLayers   do enterActive[name]   = true end
	for _, name in enterState.SuppressLayers do enterSuppress[name] = true end

	local exitActive   : { [string]: boolean } = {}
	local exitSuppress : { [string]: boolean } = {}
	for _, name in exitState.ActiveLayers   do exitActive[name]   = true end
	for _, name in exitState.SuppressLayers do exitSuppress[name] = true end

	-- Activate layers that are active in new state but were suppressed/inactive before
	for name in enterActive do
		if not exitActive[name] then
			self.LayerManager:SetLayerToBase(name)
		end
	end

	-- Suppress layers that should be suppressed in new state but weren't before
	for name in enterSuppress do
		if not exitSuppress[name] then
			self.LayerManager:SuppressLayer(name)
		end
	end

	-- Dispatch EntryActions
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

function AnimationController:_OnIntentReceived(intent: Types.AnimationIntent)
	-- Non-owning clients reconstruct state from intent stream
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

-- ── Helper: active group anim map for replication snapshots ───────────────

function AnimationController:_BuildActiveGroupAnimMap(): { [string]: string }
	local map = {}
	for _, wrapper in self.ActiveWrappers do
		if wrapper.Config.Group and wrapper.IsPlaying then
			map[wrapper.Config.Group] = wrapper.Config.Name
		end
	end
	return map
end

-- ── Attach DebugInspector ─────────────────────────────────────────────────

function AnimationController:AttachInspector(): any
	local DebugInspector = require(script.Parent.DebugInspector)
	return DebugInspector.new(self)
end

-- ── Destruction ───────────────────────────────────────────────────────────

-- Synchronous. Stops all active tracks, releases all wrappers,
-- disconnects all signals, deregisters from ReplicationBridge.
function AnimationController:Destroy()
	if self.IsDestroyed then return end
	self.IsDestroyed = true

	-- Disconnect frame update
	if self._frameConn then
		self._frameConn:Disconnect()
		self._frameConn = nil
	end

	-- Stop and destroy all active wrappers (immediate, no fade)
	for name, wrapper in self.ActiveWrappers do
		wrapper:_Stop(true)
		wrapper:_Destroy()
	end
	table.clear(self.ActiveWrappers)

	-- Destroy all pooled wrappers
	for _, pool in self._wrapperPool do
		for _, wrapper in pool do
			wrapper:_Destroy()
		end
	end
	table.clear(self._wrapperPool)

	-- Destroy subsystems
	self.GroupManager:Destroy()
	self._replication:Destroy()

	-- Clear pending queue
	table.clear(self.PendingQueue)
end

return AnimationController