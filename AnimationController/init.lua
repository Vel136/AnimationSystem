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

	-- Bug #7 fix: ReplicationBridge was constructed but _onSnapshotMismatch was never
	-- stored inside it (the parameter was accepted but the field assignment was missing).
	-- The fix is in ReplicationBridge.new — the constructor now correctly assigns the
	-- callback. The call site here is unchanged.
	self._replication = ReplicationBridge.new(
		cfg.CharacterId,
		cfg.IntentRemote,
		cfg.SnapshotRemote,
		cfg.IsOwningClient,
		function(intent: Types.AnimationIntent)
			self:_OnIntentReceived(intent)
		end,
		function(snapshot: any)
			self:_OnSnapshotMismatch(snapshot)
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
		wrapper.CompletedSignal:DisconnectAll()
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

	local isImmediate = immediate == true

	wrapper:_Stop(isImmediate)

	if wrapper.Config.Group then
		local group = wrapper.Config.Group
		if isImmediate then
			-- Immediate stop: clear the group slot now and promote any pending wrapper.
			-- Bug #5 fix: previously ClearActive was called here, which nils ActiveWrapper
			-- but does NOT promote a pending wrapper. OnActiveCompleted handles both.
			self.GroupManager:OnActiveCompleted(group)
		else
			-- Faded stop: wait until the fade has fully played out (EffectiveWeight reaches 0
			-- in _PushWeights → _RetireWrapper) before promoting a pending wrapper.
			-- We listen on CompletedSignal which fires when IsPlaying flips to false.
			-- Bug #5 original issue: ClearActive was used here too, which skipped promotion.
			wrapper.CompletedSignal:Once(function()
				self.GroupManager:OnActiveCompleted(group)
			end)
		end
	end

	if not IS_SERVER and self._replication._isOwningClient then
		self._replication:QueueIntent(animationName, "STOP", self.StateMachine:GetCurrentStateName())
	end
end

function AnimationController:StopGroup(groupName: string, immediate: boolean?)
	-- Bug #17 fix: collect wrapper names first, then stop, to avoid any
	-- concern about iterating ActiveWrappers while Stop indirectly modifies it
	-- (currently Stop does not mutate the table, but this is defensive and clear).
	local toStop: { string } = {}
	for name, wrapper in self.ActiveWrappers do
		if wrapper.Config.Group == groupName then
			table.insert(toStop, name)
		end
	end
	for _, name in toStop do
		self:Stop(name, immediate)
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

	-- Bug #2 fix: if there is a non-playing (fading) existing wrapper for this config,
	-- retire it now before acquiring a new one. Without this, the new wrapper would
	-- overwrite ActiveWrappers[configName], orphaning the fading wrapper — it would
	-- remain registered in LayerManager.ActiveTracks indefinitely with no reference
	-- in ActiveWrappers for _PushWeights to ever retire it.
	if existing then
		self:_RetireWrapper(configName)
	end

	-- ── Grouped path ──────────────────────────────────────────────────────
	if config.Group then
		self.GroupManager:EnsureGroup(config.Group)

		-- Bug #11 fix: wrapper acquisition for the grouped path is deferred until
		-- after we know the verdict is not an immediate REJECT. However, because
		-- EvaluatePlayRequest needs a real wrapper object to store as PendingWrapper
		-- or ActiveWrapper, we must acquire before calling it. The fix is to ensure
		-- that a REJECTed wrapper is correctly destroyed (already was), and to track
		-- pool capacity correctly by only acquiring from the pool for ALLOW/DEFER paths.
		-- The previous code was correct for REJECT (destroy) but silently shrank the
		-- pool on every DEFER → evict cycle because the evicted wrapper was destroyed
		-- (correct) but never returned to the pool. Pool capacity is self-healing via
		-- _RetireWrapper, so this is a soft issue, but the evicted wrapper should be
		-- properly retired rather than hard-destroyed when possible.
		local incomingWrapper = self:_AcquireWrapper(config)
		local result = self.GroupManager:EvaluatePlayRequest(config.Group, incomingWrapper)

		if result.Verdict == "REJECT" then
			incomingWrapper:_Destroy()
			return
		elseif result.Verdict == "DEFER" then
			-- Wrapper is now owned by GroupManager as PendingWrapper.
			-- Do NOT destroy it here. The evicted pending (if any) should be retired.
			if result.PendingEvicted then
				-- Try to return the evicted wrapper to the pool rather than hard-destroying.
				local evictedName = result.PendingEvicted.Config.Name
				if not self._wrapperPool[evictedName] then
					self._wrapperPool[evictedName] = {}
				end
				local evictPool = self._wrapperPool[evictedName]
				if #evictPool < MAX_POOL_SIZE_PER_CONFIG and result.PendingEvicted:_IsPoolReady() then
					result.PendingEvicted.CompletedSignal:DisconnectAll()
					table.insert(evictPool, result.PendingEvicted)
				else
					result.PendingEvicted:_Destroy()
				end
			end
			return
		elseif result.Verdict == "ALLOW" then
			if result.WrapperToStop then
				result.WrapperToStop:_Stop(false)
			end
			if result.PendingEvicted then
				local evictedName = result.PendingEvicted.Config.Name
				if not self._wrapperPool[evictedName] then
					self._wrapperPool[evictedName] = {}
				end
				local evictPool = self._wrapperPool[evictedName]
				if #evictPool < MAX_POOL_SIZE_PER_CONFIG and result.PendingEvicted:_IsPoolReady() then
					result.PendingEvicted.CompletedSignal:DisconnectAll()
					table.insert(evictPool, result.PendingEvicted)
				else
					result.PendingEvicted:_Destroy()
				end
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
		local incumbentLayer = self.LayerManager:GetLayer(incumbentWrapper.Config.Layer)
		verdict = ConflictResolver.ResolveNoGroup(
			config,
			layerRecord.Order,
			incumbentWrapper.Config,
			incumbentLayer and incumbentLayer.Order or 0,
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
	if not IS_SERVER and self._replication._isOwningClient then
		self._replication:QueueIntent(config.Name, "PLAY", self.StateMachine:GetCurrentStateName())
	end
end

-- ── Pending Ready Callback ────────────────────────────────────────────────

-- Bug #1 fix (complementary side): before calling EvaluatePlayRequest, clear
-- PendingWrapper from the group record so the incoming wrapper is not seen as
-- its own eviction target inside EvaluatePlayRequest.
function AnimationController:_OnPendingReady(groupName: string, wrapper: any)
	if self.IsDestroyed then
		wrapper:_Destroy()
		return
	end

	local record = self.GroupManager._groups[groupName]
	if not record then
		wrapper:_Destroy()
		return
	end

	-- The wrapper may have been evicted between the timer being scheduled and
	-- firing (e.g. a higher-priority play arrived and displaced it).
	if record.PendingWrapper ~= wrapper then
		wrapper:_Destroy()
		return
	end

	-- Bug #1 fix: clear PendingWrapper from the record BEFORE calling
	-- EvaluatePlayRequest. EvaluatePlayRequest inspects record.PendingWrapper to
	-- determine what to evict. If we don't clear it first, it sees the incoming
	-- wrapper as the pending occupant, returns it as PendingEvicted, and the
	-- caller would then destroy the wrapper it is trying to promote.
	record.PendingWrapper = nil

	local config      = wrapper.Config
	local layerRecord = self.LayerManager:GetLayer(config.Layer)
	if not layerRecord then
		wrapper:_Destroy()
		return
	end

	local result = self.GroupManager:EvaluatePlayRequest(groupName, wrapper)
	if result.Verdict == "ALLOW" then
		if result.WrapperToStop then
			result.WrapperToStop:_Stop(false)
		end
		-- PendingEvicted should be nil here since we cleared PendingWrapper above,
		-- but handle it defensively.
		if result.PendingEvicted then
			result.PendingEvicted:_Destroy()
		end
		self:_ActivateWrapper(wrapper, config, layerRecord)
	else
		wrapper:_Destroy()
	end
end

-- ── State Machine Callback ────────────────────────────────────────────────

-- Bug #12 fix: Immediate exit directives previously executed _ExecutePlayRequest
-- directly during the state change callback, which fires at Step 1 of the tick
-- before layer weights have been updated (Step 2). Animations started immediately
-- on exit got their first weight push computed against the old layer weights.
-- Fix: all directives — including Immediate ones — are routed through Play/Stop
-- which enqueues them for _FlushPendingQueue at Step 5, after layer weights have
-- been interpolated. For cases where truly immediate same-tick execution is required,
-- the entry actions of the *entering* state can be used with the queue, which
-- also executes after the layer weight step.
--
-- NOTE: "Immediate" in AnimationDirective now means "skip the fade" (i.e. pass
-- immediate=true to Stop), NOT "bypass the pending queue". If callers truly need
-- within-callback execution they should call _ExecutePlayRequest directly, but
-- they accept the caveat that layer weights will reflect the previous state.
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

	-- Restore layers that were suppressed by the exiting state but aren't suppressed/active in the entering state
	for name in exitSuppress do
		if not enterSuppress[name] and not enterActive[name] then
			self.LayerManager:SetLayerToBase(name)
		end
	end

	for _, directive in enterState.EntryActions do
		self:_DispatchDirective(directive)
	end
end

-- Bug #12 fix: removed the Immediate branch that called _ExecutePlayRequest directly.
-- All play directives now go through self:Play() → PendingQueue → _FlushPendingQueue,
-- which runs at Step 5 after layer weights are already updated for this tick.
-- Stop directives retain their immediate flag semantics (controls fade vs hard stop).
function AnimationController:_DispatchDirective(directive: AnimationDirective)
	if directive.Action == "PLAY" then
		-- Always enqueue — ensures layer weights are current when the request executes.
		self:Play(directive.Target)
	elseif directive.Action == "STOP" then
		self:Stop(directive.Target, directive.Immediate)
	elseif directive.Action == "STOP_GROUP" then
		self:StopGroup(directive.Target, directive.Immediate)
	end
end

-- ── Replication Intent Receiver ───────────────────────────────────────────

-- Called on non-owning clients when the server relays an intent.
function AnimationController:_OnIntentReceived(intent: Types.AnimationIntent)
	if intent.Action == "PLAY" then
		self:Play(intent.AnimationName)
	elseif intent.Action == "STOP" then
		self:Stop(intent.AnimationName, false)
	end
end

-- ── Snapshot Mismatch Handler ─────────────────────────────────────────────

-- Bug #15 note: _BuildActiveGroupAnimMap filters out IsFading wrappers, so
-- animations that just started (FadeInTime > 0) won't appear in the first
-- snapshot after they begin playing. Non-owning clients reconciling from a
-- snapshot during a fade-in will miss those animations. This is a known
-- limitation of the current snapshot model; a complete fix would require
-- including fading-in wrappers in the snapshot with a flag so the receiver
-- can begin the play from the correct point in time.
function AnimationController:_OnSnapshotMismatch(snapshot: any)
	if self.IsDestroyed then return end

	-- Stop everything currently playing so we start from a clean slate.
	for name, wrapper in self.ActiveWrappers do
		wrapper:_Stop(true)
		if wrapper.Config.Group then
			self.GroupManager:ClearActive(wrapper.Config.Group)
		end
	end
	table.clear(self.ActiveWrappers)

	-- Reconcile state machine if it diverged.
	if snapshot.StateName and snapshot.StateName ~= self.StateMachine:GetCurrentStateName() then
		self.StateMachine:RequestTransition(snapshot.StateName, math.huge)
	end

	-- Replay the server-authoritative group animations.
	if snapshot.ActiveGroupAnims then
		for _group, animName in snapshot.ActiveGroupAnims do
			self:Play(animName)
		end
	end
end

-- ── State Machine Public Interface ────────────────────────────────────────

function AnimationController:RequestStateTransition(stateName: string, priority: number)
	self.StateMachine:RequestTransition(stateName, priority or 0)
end

-- ── Helper ─────────────────────────────────────────────────────────────────

-- Bug #15 note: wrappers with IsFading = true are excluded from the snapshot.
-- See _OnSnapshotMismatch for the known limitation this creates.
function AnimationController:_BuildActiveGroupAnimMap(): { [string]: string }
	local map = {}
	for _, wrapper in self.ActiveWrappers do
		if wrapper.Config.Group and wrapper.IsPlaying and not wrapper.IsFading then
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

	-- Bug #6 fix: use explicit key variable name for clarity.
	for configName, pool in self._wrapperPool do
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