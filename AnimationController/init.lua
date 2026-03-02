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

	self.GroupManager = ExclusiveGroupManager.new(
		function(groupName: string, wrapper: any)
			self:_OnPendingReady(groupName, wrapper)
		end,
		-- Bug V fix: pool or destroy discarded pending wrappers directly.
		-- _RetireWrapper cannot be used here — it looks up the wrapper via
		-- ActiveWrappers, but pending wrappers are never in ActiveWrappers,
		-- so it would silently no-op and leak the wrapper.
		function(wrapper: any)
			local configName = wrapper.Config.Name
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
		end
	)

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

	-- Step 3: Push computed weights down to all active TrackWrappers.
	-- Bug fix: _PushWeights must run unconditionally every tick, not gated on
	-- whether layer weights changed. _PushWeights is also the wrapper retirement
	-- pump — it zeroes EffectiveWeight and calls _RetireWrapper for wrappers whose
	-- IsPlaying/IsFading flags were cleared (e.g. by natural track completion or
	-- _Stop). If layers are settled (weightsChanged=false) those wrappers would
	-- accumulate in ActiveWrappers and LayerManager.ActiveTracks indefinitely.
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

	-- Bug B fix: if this wrapper was the active wrapper for a group, proactively
	-- clear the group slot and promote any pending wrapper.
	-- The deferred CompletedSignal:Fire() from _Stop(false) will fire AFTER
	-- _RetireWrapper (task.defer runs after the current tick's thread), by which
	-- point DisconnectAll has already removed the Once/Connect listener that was
	-- supposed to call OnActiveCompleted. Without this call, the group slot stays
	-- occupied by the now-retired (possibly reused) wrapper indefinitely.
	-- Guard: only fire if ActiveWrapper still points to THIS wrapper, so we don't
	-- double-fire for natural completions (where the Connect listener already called
	-- OnActiveCompleted and updated the slot before we get here).
	if wrapper.Config.Group then
		local record = self.GroupManager._groups[wrapper.Config.Group]
		if record and record.ActiveWrapper == wrapper then
			self.GroupManager:OnActiveCompleted(wrapper.Config.Group)
		end
	end

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
	-- Fix: cancel any pending queued play for this animation so a Stop issued in the
	-- same frame (e.g. from a state transition ExitAction) is not undone by a queued
	-- Play that _FlushPendingQueue will execute at Step 5.
	for i = #self.PendingQueue, 1, -1 do
		if self.PendingQueue[i].ConfigName == animationName then
			table.remove(self.PendingQueue, i)
		end
	end

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
			-- Faded stop: promote when the fade completes.
			-- For LOOPED grouped animations, _ActivateWrapper does not connect
			-- CompletedSignal (looped anims never complete naturally), so we must
			-- connect Once here to handle manual stop promotion.
			-- For NON-LOOPED grouped animations, _ActivateWrapper already has a
			-- permanent Connect on CompletedSignal that fires on both natural AND
			-- manual completion. Adding a Once here as well causes OnActiveCompleted
			-- to be called TWICE on manual stop — the second call clears the group
			-- slot that was just assigned to the newly promoted wrapper.
			if wrapper.Config.Looped then
				wrapper.CompletedSignal:Once(function()
					self.GroupManager:OnActiveCompleted(group)
				end)
			end
			-- Non-looped: the Connect from _ActivateWrapper fires CompletedSignal
			-- and calls OnActiveCompleted exactly once, covering the manual stop path.
		end
	end

	if not IS_SERVER and self._replication._isOwningClient then
		self._replication:QueueIntent(animationName, "STOP", self.StateMachine:GetCurrentStateName())
	end
end

function AnimationController:StopGroup(groupName: string, immediate: boolean?)
	local registry = AnimationRegistry.GetInstance()
	-- Cancel pending queue entries for any animation in this group
	for i = #self.PendingQueue, 1, -1 do
		local cfg = registry:GetByName(self.PendingQueue[i].ConfigName)
		if cfg and cfg.Group == groupName then
			table.remove(self.PendingQueue, i)
		end
	end
	-- Stop currently active wrappers
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
	-- Bug A fix: nil existing after retiring so the incumbent search below does not
	-- compare against a dangling reference that is no longer in ActiveWrappers.
	if existing then
		self:_RetireWrapper(configName)
		existing = nil
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
	-- Bug E fix: the original code found only the single strongest incumbent and
	-- tested the incoming animation against it. If the incoming animation won, weaker
	-- incumbents on the same layer were never stopped and accumulated indefinitely.
	-- The fix collects ALL non-grouped wrappers on the same layer, resolves against
	-- the strongest one (correct authority), and if ALLOW, stops all of them.
	local layerIncumbents: { any } = {}
	local strongestIncumbent: any = nil
	for _, wrapper in self.ActiveWrappers do
		if wrapper.Config.Layer == config.Layer and wrapper.Config.Group == nil then
			table.insert(layerIncumbents, wrapper)
			if strongestIncumbent == nil or wrapper.Config.Priority > strongestIncumbent.Config.Priority then
				strongestIncumbent = wrapper
			end
		end
	end

	local verdict: Types.ConflictVerdict
	if strongestIncumbent then
		local incumbentLayer = self.LayerManager:GetLayer(strongestIncumbent.Config.Layer)
		verdict = ConflictResolver.ResolveNoGroup(
			config,
			layerRecord.Order,
			strongestIncumbent.Config,
			incumbentLayer and incumbentLayer.Order or 0,
			strongestIncumbent.StartTimestamp
		)
	else
		verdict = "ALLOW"
	end

	if verdict == "ALLOW" then
		-- Stop all incumbents on this layer, not just the strongest.
		for _, incumbent in layerIncumbents do
        self:Stop(incumbent.Config.Name, false)
    end
		local wrapper = self:_AcquireWrapper(config)
		self:_ActivateWrapper(wrapper, config, layerRecord)
	end
end

-- ── Wrapper Activation ────────────────────────────────────────────────────

function AnimationController:_ActivateWrapper(wrapper: any, config: AnimationConfig, layerRecord: any)
	self.ActiveWrappers[config.Name] = wrapper
	self.LayerManager:RegisterTrack(config.Layer, wrapper)

	if not config.Looped and config.Group then
		-- Fix: capture the wrapper reference so that if this wrapper is later interrupted
		-- by a new animation in the same group, its deferred CompletedSignal fire doesn't
		-- clear the NEW wrapper's group slot. Without this capture, the Connect closure
		-- closes over 'wrapper' by reference — but since the same variable is reused the
		-- slot ends up being cleared immediately after the new animation is assigned,
		-- breaking mutual exclusivity.
		local capturedWrapper = wrapper
		local capturedGroup   = config.Group :: string
		wrapper.CompletedSignal:Connect(function()
			local record = self.GroupManager._groups[capturedGroup]
			if record and record.ActiveWrapper == capturedWrapper then
				self.GroupManager:OnActiveCompleted(capturedGroup)
			end
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
		-- Bug I fix: OnActiveCompleted no longer clears ActiveWrapper upfront.
		-- On a failed promotion we must clear it here so the group slot doesn't
		-- stay occupied by the just-completed (no longer playing) wrapper forever.
		self.GroupManager:ClearActive(groupName)
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
		-- Bug I fix: a mismatch means a newer pending wrapper displaced this one
		-- before it could be promoted. ActiveWrapper should already be correctly
		-- managed by the newer request path, so no ClearActive needed here.
		return
	end

	-- Bug #1 fix: clear PendingWrapper from the record BEFORE calling
	-- EvaluatePlayRequest. EvaluatePlayRequest inspects record.PendingWrapper to
	-- determine what to evict. If we don't clear it first, it sees the incoming
	-- wrapper as the pending occupant, returns it as PendingEvicted, and the
	-- caller would then destroy the wrapper it is trying to activate.
	record.PendingWrapper = nil

	local config      = wrapper.Config
	local layerRecord = self.LayerManager:GetLayer(config.Layer)
	if not layerRecord then
		wrapper:_Destroy()
		-- Bug I fix: layer lookup failed — promotion cannot proceed.
		-- Clear the slot so the group is not permanently stuck on a dead wrapper.
		self.GroupManager:ClearActive(groupName)
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
	elseif result.Verdict == "DEFER" then
		-- Fix: a new CanInterrupt=false animation started in this group between the
		-- timer firing and this re-evaluation. EvaluatePlayRequest has re-stored
		-- 'wrapper' as record.PendingWrapper and scheduled a new timer. Do NOT
		-- destroy the wrapper (it is still owned as pending) and do NOT call
		-- ClearActive (the new animation is correctly the active wrapper).
		return
	else
		-- REJECT verdict
		wrapper:_Destroy()
		-- REJECT verdict — EvaluatePlayRequest did not commit a new ActiveWrapper,
		-- so clear the slot ourselves.
		self.GroupManager:ClearActive(groupName)
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

	-- Bug R fix: deactivate layers that were active in the exiting state but are
	-- neither active nor suppressed in the entering state. Without this loop, a
	-- layer activated by a state is never cleaned up when transitioning to a state
	-- that doesn't reference it — it stays at its raised weight indefinitely,
	-- with no state owning it, accumulating across transitions.
	for name in exitActive do
		if not enterActive[name] and not enterSuppress[name] then
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

	-- Stop and destroy all active wrappers immediately.
	-- Fix: call UnregisterTrack before destroying so LayerManager.ActiveTracks does not
	-- accumulate stale entries that corrupt DebugInspector output and ValidateInvariants.
	for name, wrapper in self.ActiveWrappers do
		self.LayerManager:UnregisterTrack(wrapper.Config.Layer, wrapper)
		wrapper:_Stop(true)
		wrapper:_Destroy()
	end
	table.clear(self.ActiveWrappers)

	-- Bug D fix: clear any play requests that were queued earlier this tick.
	-- Without this, stale requests flush in step 5 alongside the reconciliation
	-- plays and can immediately overwrite the snapshot-dictated state.
	table.clear(self.PendingQueue)

	-- Tear down and rebuild GroupManager so that pending wrappers in any group
	-- are destroyed and group records are cleared. Using ClearActive alone would
	-- leave pending wrappers orphaned with no path to ever be promoted or destroyed.
	self.GroupManager:Destroy()
	self.GroupManager = ExclusiveGroupManager.new(
		function(groupName: string, wrapper: any)
			self:_OnPendingReady(groupName, wrapper)
		end,
		-- Bug V fix: pool or destroy discarded pending wrappers directly.
		-- _RetireWrapper cannot be used here — pending wrappers are never in
		-- ActiveWrappers so it would silently no-op and leak the wrapper.
		function(wrapper: any)
			local configName = wrapper.Config.Name
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
		end
	)

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
			-- Bug F fix: warn if two wrappers from the same group are both active,
			-- which violates the exclusivity invariant. Last-write-wins so the map
			-- stays consistent, but the warning surfaces the violation for debugging.
			if map[wrapper.Config.Group] then
				warn(string.format(
					"[AnimationController] Group invariant violated: both '%s' and '%s' are active in group '%s'",
					map[wrapper.Config.Group], wrapper.Config.Name, wrapper.Config.Group
					))
			end
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

	-- Bug G fix: call _Stop(true) before _Destroy so that any wrapper that somehow
	-- reached the pool while its underlying track was still fading gets stopped
	-- cleanly rather than leaving a ghost track playing on the client until GC.
	for configName, pool in self._wrapperPool do
		for _, wrapper in pool do
			wrapper:_Stop(true)
			wrapper:_Destroy()
		end
	end
	table.clear(self._wrapperPool)

	self.GroupManager:Destroy()
	self._replication:Destroy()
	table.clear(self.PendingQueue)
end

return AnimationController