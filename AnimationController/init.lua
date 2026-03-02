--!strict
-- ─── AnimationController / init.lua ──────────────────────────────────────────
--[[
    AnimationController is the root orchestrator for the entire animation framework.
    One instance exists per character, on each machine that simulates that character.

    ── Ownership and Environment Roles ──────────────────────────────────────────

    Owning Client (IsOwningClient = true, IS_SERVER = false):
        Responds to input and game logic by calling Play/Stop. These actions are
        executed locally on real AnimationTracks and simultaneously queued as
        AnimationIntents for relay to the server.

    Server (IS_SERVER = true):
        Runs the StateMachine and ExclusiveGroupManager to maintain authoritative
        state. Never loads or plays AnimationTracks — Animator is always nil on the
        server. Relays intents from the owning client to non-owning clients and
        broadcasts periodic snapshots for desync recovery.

    Non-Owning Client (IsOwningClient = false, IS_SERVER = false):
        Receives relayed intents from the server and reconstructs animation state
        locally by running the full play pipeline. Also subscribes to snapshots and
        reconciles when sequence counters diverge.

    ── Module Subsystems ─────────────────────────────────────────────────────────

    AnimationController owns and coordinates five subsystems:
        LayerManager          — Manages layer weight interpolation and track registration.
        ExclusiveGroupManager — Enforces mutual-exclusivity within named animation groups.
        StateMachine          — Flat FSM governing state transitions and directive dispatch.
        ReplicationBridge     — Handles intent serialisation, relay, and snapshot recovery.
        TrackWrappers         — Per-animation lifecycle wrappers (owned exclusively here).

    ── Invariants ────────────────────────────────────────────────────────────────

    1. No external system ever touches an AnimationTrack directly.
    2. All animation operations enter through Play or Stop and are flushed in order.
    3. The server's Animator field is always nil.
    4. A wrapper in the pool never has IsPlaying = true.
    5. ActiveWrappers[name] always matches LayerManager's ActiveTracks for that layer.
]]

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

-- ─── Environment Constant ─────────────────────────────────────────────────────

--[[
    IS_SERVER is evaluated once at module load time. Runtime environment never
    changes; caching this avoids a function call on every hot path that branches
    between server and client behaviour (track loading, weight pushing, etc.).
]]
local IS_SERVER = RunService:IsServer()

-- ─── Pool Constant ────────────────────────────────────────────────────────────

--[[
    MAX_POOL_SIZE_PER_CONFIG controls how many retired TrackWrappers are kept per
    animation config name. When an animation ends, its wrapper is reinitialized and
    returned to the pool rather than garbage-collected. The next Play request for the
    same animation pulls from the pool, avoiding an AnimationTrack load call.

    2 slots per config is sufficient for the common pattern of overlapping the same
    animation (e.g. fading out one instance while fading in another). A larger pool
    would reduce allocations further but increase memory usage for every character.
]]
local MAX_POOL_SIZE_PER_CONFIG = 2

-- ─── Construction Config Type ─────────────────────────────────────────────────

--[[
    ControllerConfig is the complete set of parameters required to initialize a
    fully functional AnimationController. All fields are validated during new.

    Fields:
        CharacterId    — Unique identifier used by replication to route intents and
                         snapshots to the correct character. In standard Roblox games
                         this is the character's Instance.Name (the player's username).
        Animator       — The Roblox Animator instance used to load AnimationTracks.
                         Must be nil on the server; must be non-nil on clients that
                         need to play animations. Passing a non-nil Animator on the
                         server logs a warning and the value is discarded.
        IsOwningClient — True only on the client whose input drives this character.
                         Controls which replication remote subscriptions are opened.
        LayerProfiles  — Array of LayerProfile records defining all animation layers.
                         Passed directly to LayerManager.
        States         — Array of StateDefinition records for the StateMachine.
        InitialState   — Name of the FSM state to start in.
        Predicates     — Map of condition-name strings to zero-argument boolean
                         functions for StateMachine transition evaluation.
        IntentRemote   — RemoteEvent for intent communication. May be nil in solo
                         or offline scenarios.
        SnapshotRemote — RemoteEvent for periodic state snapshots. May be nil.
]]
export type ControllerConfig = {
	CharacterId    : string,
	Animator       : Animator?,
	IsOwningClient : boolean,
	LayerProfiles  : { LayerProfile },
	States         : { StateDefinition },
	InitialState   : string,
	Predicates     : { [string]: () -> boolean },
	IntentRemote   : RemoteEvent?,
	SnapshotRemote : RemoteEvent?,
}

-- ─── Module Table ─────────────────────────────────────────────────────────────

local AnimationController = {}
AnimationController.__index = AnimationController

-- ─── Constructor ──────────────────────────────────────────────────────────────

--[=[
    AnimationController.new

    Description:
        Constructs a fully initialized AnimationController for a single character.
        Builds and wires all subsystems, binds the per-frame update connection,
        and validates environment preconditions.

    Parameters:
        Config : ControllerConfig
            Full initialization parameters. See ControllerConfig type above for
            field-by-field documentation.

    Returns:
        AnimationController
            A running controller instance. The per-frame pipeline begins executing
            immediately after construction.

    Notes:
        AnimationRegistry must be initialized before calling new. The registry is
        a singleton shared across all controllers on the same machine; the controller
        reads from it on every play request to look up AnimationConfig records.

        The frame update is bound to RunService.Heartbeat on the server and
        RunService.RenderStepped on clients. RenderStepped fires synchronously with
        the render frame, ensuring animation weight pushes and track adjustments
        happen in the same frame that is being composited — preventing a one-frame
        visual lag. The server uses Heartbeat because it never renders.
]=]
function AnimationController.new(Config: ControllerConfig): any
	local Registry = AnimationRegistry.GetInstance()
	assert(
		Registry:IsInitialized(),
		"[AnimationController] AnimationRegistry must be initialized before creating controllers"
	)

	-- Guard against server misconfiguration. The server never renders visuals,
	-- so passing an Animator is always a mistake. We warn rather than asserting
	-- so that a misconfigured server doesn't crash; we just discard the value.
	if IS_SERVER and Config.Animator ~= nil then
		warn(
			"[AnimationController] Animator was passed on the server. It will be ignored. " ..
				"The server does not load or play AnimationTracks."
		)
	end

	local self = setmetatable({
		CharacterId  = Config.CharacterId,
		-- Only store the Animator on clients. The server explicitly receives nil
		-- so that any code path that accidentally calls LoadAnimation on the server
		-- will produce a clear nil-dereference error rather than silent misbehaviour.
		Animator     = IS_SERVER and nil or Config.Animator,
		IsDestroyed  = false,

		-- Subsystems are populated below after self is constructed.
		LayerManager = nil,
		GroupManager = nil,
		StateMachine = nil,

		-- ActiveWrappers maps Config.Name → TrackWrapper for every animation
		-- currently either playing or fading. _PushWeights retires wrappers whose
		-- IsPlaying and IsFading are both false and EffectiveWeight has reached 0.
		ActiveWrappers = {} :: { [string]: any },

		-- PendingQueue accumulates Play requests submitted mid-frame (from state
		-- transition callbacks or external calls during the tick). Flushed at Step 5,
		-- after layer weights have been updated, so every play sees current weights.
		PendingQueue = {} :: { PlayRequest },

		-- _WrapperPool maps Config.Name → array of retired-but-reusable wrappers.
		-- Pooling avoids loading AnimationTracks on every play, which is expensive.
		_WrapperPool = {} :: { [string]: { any } },

		_Replication = nil,
		_FrameConn   = nil :: RBXScriptConnection?,
	}, AnimationController)

	-- ── Build LayerManager ──────────────────────────────────────────────────
	-- LayerManager is stateless beyond its layer records and active track lists.
	-- Constructed first because other subsystems reference it.
	self.LayerManager = LayerManager.new(Config.LayerProfiles)

	-- ── Build ExclusiveGroupManager ─────────────────────────────────────────
	-- Two callbacks are wired into GroupManager so it can notify the controller
	-- without holding a direct reference back (avoiding a reference cycle):
	--
	--   OnPendingReady: fires when a DEFER'd wrapper's MinDuration window expires.
	--     The controller then re-evaluates and potentially activates the wrapper.
	--
	--   OnPendingDestroy: fires when GroupManager discards a pending wrapper
	--     (e.g. during Destroy). The controller returns the wrapper to its pool
	--     rather than hard-destroying it, preserving pool capacity.
	--     NOTE: _RetireWrapper cannot be used here — it looks up wrappers via
	--     ActiveWrappers, but pending wrappers are never in ActiveWrappers. Using
	--     _RetireWrapper would silently no-op, leaking the wrapper.
	self.GroupManager = ExclusiveGroupManager.new(
		function(GroupName: string, PendingWrapper: any)
			self:_OnPendingReady(GroupName, PendingWrapper)
		end,
		function(DiscardedWrapper: any)
			-- Bug V fix: pool rather than hard-destroy so pool capacity is preserved
			-- across snapshot reconciliation cycles.
			local ConfigName = DiscardedWrapper.Config.Name

			if not self._WrapperPool[ConfigName] then
				self._WrapperPool[ConfigName] = {}
			end

			local Pool = self._WrapperPool[ConfigName]
			local IsPoolBelowCapacity = #Pool < MAX_POOL_SIZE_PER_CONFIG
			local IsWrapperSafeToPool = DiscardedWrapper:_IsPoolReady()

			if IsPoolBelowCapacity and IsWrapperSafeToPool then
				DiscardedWrapper.CompletedSignal:DisconnectAll()
				table.insert(Pool, DiscardedWrapper)
			else
				DiscardedWrapper:_Destroy()
			end
		end
	)

	-- ── Build StateMachine ──────────────────────────────────────────────────
	-- The _OnStateChange callback is the bridge between FSM transitions and
	-- animation directives. It is called inside _DoTransition after _CurrentState
	-- has already been updated (Bug U fix), so GetCurrentStateName within the
	-- callback returns the entering state's name.
	self.StateMachine = StateMachine.new(
		Config.States,
		Config.InitialState,
		Config.Predicates,
		function(ExitingState: StateDefinition, EnteringState: StateDefinition)
			self:_OnStateChange(ExitingState, EnteringState)
		end
	)

	-- ── Build ReplicationBridge ─────────────────────────────────────────────
	-- Bug #7 fix: the OnSnapshotMismatch callback is correctly passed and stored
	-- inside ReplicationBridge.new (the original had the parameter but lost it).
	self._Replication = ReplicationBridge.new(
		Config.CharacterId,
		Config.IntentRemote,
		Config.SnapshotRemote,
		Config.IsOwningClient,
		function(ReceivedIntent: Types.AnimationIntent)
			self:_OnIntentReceived(ReceivedIntent)
		end,
		function(MismatchedSnapshot: any)
			self:_OnSnapshotMismatch(MismatchedSnapshot)
		end
	)

	-- ── Bind Per-Frame Update ───────────────────────────────────────────────
	-- Server uses Heartbeat (physics/simulation cadence; no rendering).
	-- Clients use RenderStepped (fires before each frame is composited) so weight
	-- adjustments are visible in the same frame they are computed — no visual lag.
	local UpdateEvent = IS_SERVER and RunService.Heartbeat or RunService.RenderStepped
	self._FrameConn = UpdateEvent:Connect(function(DeltaTime: number)
		self:_Tick(DeltaTime)
	end)

	return self
end

-- ─── Per-Frame Pipeline ───────────────────────────────────────────────────────

--[=[
    _Tick

    Description:
        The per-frame update pipeline. Called on every Heartbeat (server) or
        RenderStepped (client). Executes five ordered steps:

        Step 1 — StateMachine.Tick:
            Evaluates pending external transitions and condition-driven rules.
            Fires _OnStateChange if a transition occurs, which dispatches directives
            into the pending queue and adjusts layer weight targets.

        Step 2 — LayerManager.UpdateWeights:
            Advances each layer's CurrentWeight toward TargetWeight by the layer's
            configured WeightLerpRate. Returns true if any layer changed.

        Step 3 — _PushWeights:
            Computes final per-wrapper weights and calls _SetEffectiveWeight.
            Also serves as the wrapper retirement pump: wrappers with IsPlaying =
            false, IsFading = false, and EffectiveWeight = 0 are removed from
            ActiveWrappers and returned to the pool. This runs unconditionally every
            tick because retirement must happen even when layer weights are stable.

        Step 4 — ReplicationBridge.Flush:
            Sends queued intents to the server (owning client) or broadcasts a
            snapshot if the timer has elapsed (server).

        Step 5 — _FlushPendingQueue:
            Executes all Play/Stop requests that were queued during steps 1–4.
            Runs last so every play sees fully updated layer weights and the correct
            post-transition state context for intent tagging.

    Parameters:
        DeltaTime : number
            Frame delta time in seconds.
]=]
function AnimationController:_Tick(DeltaTime: number)
	if self.IsDestroyed then return end

	-- Step 1: Evaluate FSM transitions. May dispatch directives into PendingQueue.
	self.StateMachine:Tick()

	-- Step 2: Lerp layer weights toward their targets.
	self.LayerManager:UpdateWeights(DeltaTime)

	-- Step 3: Push computed weights to all wrappers. Retires completed wrappers.
	-- Runs unconditionally — retirement must not be gated on weight changes.
	self:_PushWeights()

	-- Step 4: Send queued intents and/or broadcast snapshot.
	local ActiveGroupAnimMap = self:_BuildActiveGroupAnimMap()
	self._Replication:Flush(
		DeltaTime,
		self.StateMachine:GetCurrentStateName(),
		ActiveGroupAnimMap
	)

	-- Step 5: Execute all plays/stops that accumulated during steps 1–4.
	self:_FlushPendingQueue()
end

-- ─── Weight Push ──────────────────────────────────────────────────────────────

--[=[
    _PushWeights

    Description:
        Iterates every active wrapper, computes its final blended weight, and
        calls _SetEffectiveWeight to push the value to the underlying AnimationTrack
        (client only; _SetEffectiveWeight no-ops on the server for the track call).

        After updating weights, retires any wrapper whose animation is fully complete:
            IsPlaying = false  — The track has stopped playing (natural or manual).
            IsFading  = false  — The fade-out has finished (EffectiveWeight drains to 0).
            EffectiveWeight == 0 — The weight has fully reached zero.

        All three conditions must be true simultaneously for retirement. Checking
        only IsPlaying would retire wrappers mid-fade-out, causing an abrupt cut.

    Notes:
        Why this runs unconditionally every tick:
            _PushWeights is not just a visual update — it is the retirement pump.
            Wrappers are not removed from ActiveWrappers immediately when their track
            stops; their EffectiveWeight must drain to 0 first. If _PushWeights were
            gated on "did layer weights change", wrappers on settled layers would
            accumulate in ActiveWrappers indefinitely, leaking memory and blocking
            future plays on the same layer.
]=]
function AnimationController:_PushWeights()
	-- Collect names to retire before mutating ActiveWrappers to avoid modifying
	-- a table we are currently iterating.
	local WrappersToRetire: { string } = {}

	for AnimationName, Wrapper in self.ActiveWrappers do
		local FinalWeight = self.LayerManager:ComputeFinalWeight(
			Wrapper.Config.Layer,
			Wrapper.TargetWeight,
			Wrapper.Config.Weight
		)
		Wrapper:_SetEffectiveWeight(FinalWeight)

		local IsReadyToRetire = not Wrapper.IsPlaying
			and not Wrapper.IsFading
			and Wrapper.EffectiveWeight == 0

		if IsReadyToRetire then
			table.insert(WrappersToRetire, AnimationName)
		end
	end

	for _, AnimationName in WrappersToRetire do
		self:_RetireWrapper(AnimationName)
	end
end

-- ─── Wrapper Retirement and Pooling ──────────────────────────────────────────

--[=[
    _RetireWrapper

    Description:
        Fully removes a wrapper from the active set and either returns it to the
        pool (for future reuse) or destroys it if the pool is full or the wrapper
        is not in a reusable state.

    Parameters:
        ConfigName : string
            The Config.Name of the wrapper to retire. Used as the key in both
            ActiveWrappers and _WrapperPool.

    Returns:
        Nothing.

    Notes:
        Group slot cleanup (Bug B fix):
            When a wrapper that owns a group slot is retired, the group slot must
            be cleared and any pending wrapper promoted. The natural completion path
            (track.Stopped or server task.delay) fires CompletedSignal, which in
            _ActivateWrapper's Connect calls OnActiveCompleted. However, for faded
            manual stops, _Stop fires CompletedSignal via task.defer AFTER this tick.
            By the time it fires, DisconnectAll has already run on the wrapper's
            signal, so the listener never executes and the group slot stays occupied.
            The fix proactively calls OnActiveCompleted here, guarded by checking that
            the group's ActiveWrapper is still this specific wrapper (to avoid double-
            firing if the natural completion path already ran first).

        Pool reuse conditions:
            Only wrappers that pass _IsPoolReady are pooled. On the client, this
            requires a non-nil, non-playing underlying track. On the server (no track),
            it requires IsPlaying = false. Wrappers that fail this check are destroyed
            immediately to prevent handing out a broken wrapper to a future play request.
]=]
function AnimationController:_RetireWrapper(ConfigName: string)
	local RetiredWrapper = self.ActiveWrappers[ConfigName]
	if not RetiredWrapper then return end

	-- Unregister from the layer's ActiveTracks list so LayerManager's invariant
	-- checks and active track counts remain accurate.
	self.LayerManager:UnregisterTrack(RetiredWrapper.Config.Layer, RetiredWrapper)

	-- Bug B fix: proactively clear the group slot and promote pending if this
	-- wrapper was the active group occupant. Guards against the race where the
	-- CompletedSignal listener was disconnected before the deferred fire arrived.
	if RetiredWrapper.Config.Group then
		local GroupName   = RetiredWrapper.Config.Group
		local GroupRecord = self.GroupManager._groups[GroupName]
		local IsStillActiveInGroup = GroupRecord and GroupRecord.ActiveWrapper == RetiredWrapper

		if IsStillActiveInGroup then
			self.GroupManager:OnActiveCompleted(GroupName)
		end
	end

	-- Remove from the active set before pooling so the pool check and any
	-- subsequent code never sees this wrapper as "active".
	self.ActiveWrappers[ConfigName] = nil

	if not self._WrapperPool[ConfigName] then
		self._WrapperPool[ConfigName] = {}
	end

	local Pool = self._WrapperPool[ConfigName]
	local IsPoolBelowCapacity = #Pool < MAX_POOL_SIZE_PER_CONFIG
	local IsWrapperSafeToPool = RetiredWrapper:_IsPoolReady()

	if IsPoolBelowCapacity and IsWrapperSafeToPool then
		-- Disconnect all CompletedSignal listeners before pooling so that stale
		-- listeners from the previous play cycle don't fire when this wrapper
		-- is reused in a future play request.
		RetiredWrapper.CompletedSignal:DisconnectAll()
		table.insert(Pool, RetiredWrapper)
	else
		RetiredWrapper:_Destroy()
	end
end

-- ─── Wrapper Acquisition ──────────────────────────────────────────────────────

--[=[
    _AcquireWrapper

    Description:
        Retrieves a TrackWrapper for the given config, either from the pool or by
        constructing a new one. Pool hits call _Reinitialize to reset all fields
        before use; misses load a real AnimationTrack on the client or construct
        a server-side no-op wrapper.

    Parameters:
        Config : AnimationConfig
            The frozen config record from AnimationRegistry describing the animation.

    Returns:
        TrackWrapper (typed as any due to circular reference constraints)
            A ready-to-use wrapper. Callers must call _Play to begin playback.

    Notes:
        On the server, no AnimationTrack is loaded — the wrapper is constructed with
        a nil track. Server-side wrappers still maintain full bookkeeping (IsPlaying,
        StartTimestamp, group slot management) so the state machine, group manager,
        and replication pipeline function correctly on both environments.

        The assert on Animator only fires on the client; IS_SERVER short-circuits
        before reaching it, so the assert is not reachable in server code.
]=]
function AnimationController:_AcquireWrapper(Config: AnimationConfig): any
	local Pool = self._WrapperPool[Config.Name]
	if Pool and #Pool > 0 then
		local ReusedWrapper = table.remove(Pool) :: any
		-- Reset all runtime fields to construction defaults. Config is preserved
		-- (Bug #14 note: the registry is immutable after Init, so the Config the
		-- wrapper was built with is still valid).
		ReusedWrapper:_Reinitialize()
		return ReusedWrapper
	end

	-- Server path: no track loading, no Animator needed.
	if IS_SERVER then
		return TrackWrapper.new(Config, nil)
	end

	-- Client path: load a real AnimationTrack from the Animator.
	assert(self.Animator, "[AnimationController] Animator is nil on client — cannot load track")

	local AnimationInstance = Instance.new("Animation")
	AnimationInstance.AnimationId = Config.AssetId

	-- Load the track before destroying the Animation instance. LoadAnimation uses
	-- the AnimationId at call time; once loaded the instance is no longer needed.
	local LoadedTrack = self.Animator:LoadAnimation(AnimationInstance)
	AnimationInstance:Destroy()

	return TrackWrapper.new(Config, LoadedTrack)
end

-- ─── Public Play API ──────────────────────────────────────────────────────────

--[=[
    Play

    Description:
        Enqueues a play request for the named animation. The request is processed at
        Step 5 of the current tick (_FlushPendingQueue), after layer weights have
        been updated and the state machine has settled. Requests submitted during
        state transition callbacks, external input handlers, or other mid-tick calls
        all arrive here safely.

        Play does NOT execute the request immediately. This ensures:
          1. Layer weights computed at Step 2 are current when conflict resolution runs.
          2. Multiple plays submitted in the same tick are processed in submission order.
          3. State context tagged on intents reflects the post-transition state (Bug U fix).

    Parameters:
        AnimationName : string
            The Config.Name of the animation to play. Validated in _ExecutePlayRequest
            via AnimationRegistry lookup; unknown names produce a warning, not an error.

    Returns:
        Nothing.
]=]
function AnimationController:Play(AnimationName: string)
	assert(not self.IsDestroyed, "[AnimationController] Cannot play on a destroyed controller")
	table.insert(self.PendingQueue, {
		ConfigName  = AnimationName,
		RequestTime = os.clock(),
	})
end

--[=[
    PlayTag

    Description:
        Enqueues play requests for every animation in the registry bearing the
        given tag. Convenience wrapper for batch-playing thematically grouped
        animations (e.g. all animations tagged "Combat" or "Emote").

    Parameters:
        Tag : string
            A tag string to look up in AnimationRegistry. Returns silently if no
            animations are registered under the tag.

    Returns:
        Nothing.
]=]
function AnimationController:PlayTag(Tag: string)
	local Registry = AnimationRegistry.GetInstance()
	for _, Config in Registry:GetByTag(Tag) do
		self:Play(Config.Name)
	end
end

-- ─── Public Stop API ──────────────────────────────────────────────────────────

--[=[
    Stop

    Description:
        Stops the named animation, optionally with an immediate hard cut or a
        configured fade-out. Also cancels any pending play request for the same
        animation that hasn't been flushed yet, ensuring that a Stop issued in the
        same tick as a Play (e.g. from a state ExitAction) is not undone.

    Parameters:
        AnimationName : string
            The Config.Name of the animation to stop.

        Immediate : boolean?
            If true, the animation is cut immediately with no fade. If false or nil,
            the animation fades out over Config.FadeOutTime seconds. Immediate stops
            clear the group slot synchronously via OnActiveCompleted; faded stops
            defer slot promotion until the fade completes via CompletedSignal.

    Returns:
        Nothing.

    Notes:
        Group slot management on faded stop:
            For LOOPED grouped animations: _ActivateWrapper does not connect a
            CompletedSignal listener because looped animations never complete
            naturally. A Once listener is added here to call OnActiveCompleted when
            the deferred CompletedSignal fires after the fade completes.

            For NON-LOOPED grouped animations: _ActivateWrapper already has a
            permanent Connect listener. Adding a Once here too would result in
            OnActiveCompleted firing twice on manual stop — clearing the newly
            promoted wrapper's slot. Non-looped animations use only the Connect
            from _ActivateWrapper.
]=]
function AnimationController:Stop(AnimationName: string, Immediate: boolean?)
	-- Cancel any pending queue entry for this animation. Without this, a Stop
	-- issued during a state transition callback could be overridden by a Play
	-- that was queued earlier in the same tick (Bug #12 fix context).
	for QueueIndex = #self.PendingQueue, 1, -1 do
		if self.PendingQueue[QueueIndex].ConfigName == AnimationName then
			table.remove(self.PendingQueue, QueueIndex)
		end
	end

	local Wrapper = self.ActiveWrappers[AnimationName]
	if not Wrapper then return end

	local IsHardStop = Immediate == true

	Wrapper:_Stop(IsHardStop)

	if Wrapper.Config.Group then
		local GroupName = Wrapper.Config.Group

		if IsHardStop then
			-- Immediate stop: clear the slot and promote any pending wrapper now.
			-- Bug #5 fix: ClearActive alone would nil ActiveWrapper but would not
			-- promote pending. OnActiveCompleted handles both in sequence.
			self.GroupManager:OnActiveCompleted(GroupName)
		else
			-- Faded stop: only connect the Once listener for looped animations.
			-- Non-looped animations already have a permanent Connect from _ActivateWrapper
			-- that handles both natural and manual completion.
			if Wrapper.Config.Looped then
				Wrapper.CompletedSignal:Once(function()
					self.GroupManager:OnActiveCompleted(GroupName)
				end)
			end
		end
	end

	-- Queue the stop intent for relay to the server (owning client only).
	local IsOwningClient = not IS_SERVER and self._Replication._isOwningClient
	if IsOwningClient then
		self._Replication:QueueIntent(
			AnimationName,
			"STOP",
			self.StateMachine:GetCurrentStateName()
		)
	end
end

--[=[
    StopGroup

    Description:
        Stops all animations currently playing in the named exclusive group.
        Also cancels any pending queue entries for animations belonging to the group.

    Parameters:
        GroupName : string
            The exclusive group to stop.

        Immediate : boolean?
            Passed through to each individual Stop call. If true, all group members
            are hard-stopped simultaneously; if false or nil, each fades out.

    Returns:
        Nothing.
]=]
function AnimationController:StopGroup(GroupName: string, Immediate: boolean?)
	local Registry = AnimationRegistry.GetInstance()

	-- Cancel pending queue entries for any animation belonging to this group.
	for QueueIndex = #self.PendingQueue, 1, -1 do
		local QueuedConfig = Registry:GetByName(self.PendingQueue[QueueIndex].ConfigName)
		if QueuedConfig and QueuedConfig.Group == GroupName then
			table.remove(self.PendingQueue, QueueIndex)
		end
	end

	-- Collect names first to avoid modifying ActiveWrappers during iteration.
	local AnimationsToStop: { string } = {}
	for AnimationName, Wrapper in self.ActiveWrappers do
		if Wrapper.Config.Group == GroupName then
			table.insert(AnimationsToStop, AnimationName)
		end
	end

	for _, AnimationName in AnimationsToStop do
		self:Stop(AnimationName, Immediate)
	end
end

-- ─── Pending Queue Flush ──────────────────────────────────────────────────────

--[=[
    _FlushPendingQueue

    Description:
        Processes all play requests accumulated in PendingQueue since the last
        flush. Runs at Step 5 of _Tick — after layer weights and weight pushes have
        completed — so every request sees the freshest layer weights.

        The queue is swapped out before iteration to safely handle the case where
        _ExecutePlayRequest itself calls Play (which would append to the queue).
        Any new entries added during this flush will be processed in the next tick.

    Returns:
        Nothing.
]=]
function AnimationController:_FlushPendingQueue()
	if #self.PendingQueue == 0 then return end

	-- Swap out the queue before iterating. This allows _ExecutePlayRequest to
	-- call Play safely without its new entries being processed in this flush.
	local QueueSnapshot = self.PendingQueue
	self.PendingQueue = {}

	for _, Request in QueueSnapshot do
		self:_ExecutePlayRequest(Request.ConfigName)
	end
end

-- ─── Core Play Execution ──────────────────────────────────────────────────────

--[=[
    _ExecutePlayRequest

    Description:
        The core play pipeline. Looks up the config, validates the layer, resolves
        conflicts, and either activates, defers, or rejects the incoming animation.

        Grouped animations are routed through ExclusiveGroupManager, which enforces
        mutual exclusivity. Non-grouped animations are resolved against all other
        non-grouped incumbents on the same layer via ConflictResolver.

    Parameters:
        ConfigName : string
            The Config.Name of the animation to attempt to play.

    Returns:
        Nothing. Side effects: may activate, defer, or reject the animation.

    Notes:
        Existing-wrapper retirement (Bug #2 fix):
            If a wrapper for this config is already in ActiveWrappers but is not
            playing (e.g. it is fading out from a previous stop), it is retired
            before acquiring a new one. Without this, the new wrapper would
            overwrite the dictionary entry, orphaning the fading wrapper in
            LayerManager.ActiveTracks with no path to ever be retired.

        Non-grouped incumbent collection (Bug E fix):
            The original code found only the single strongest incumbent and resolved
            against it. Weaker incumbents on the same layer were never stopped if the
            incoming animation won, accumulating indefinitely. The fix collects ALL
            non-grouped incumbents on the layer, resolves against the strongest for
            authority, and if ALLOW, stops all of them.
]=]
function AnimationController:_ExecutePlayRequest(ConfigName: string)
	local Registry = AnimationRegistry.GetInstance()
	local Config   = Registry:GetByName(ConfigName)

	if not Config then
		warn(string.format("[AnimationController] Unknown animation '%s'", ConfigName))
		return
	end

	local LayerRecord = self.LayerManager:GetLayer(Config.Layer)
	if not LayerRecord then
		warn(string.format(
			"[AnimationController] Animation '%s' references unknown layer '%s'",
			ConfigName,
			Config.Layer
			))
		return
	end

	-- Skip if this animation is already actively playing. Allows re-queuing the
	-- same animation (e.g. from a looping system) without causing double-plays.
	local ExistingWrapper = self.ActiveWrappers[ConfigName]
	if ExistingWrapper and ExistingWrapper.IsPlaying then return end

	-- Bug #2 fix: if a non-playing (fading) wrapper exists, retire it first.
	-- This prevents the new wrapper from orphaning the fading wrapper in the
	-- layer's ActiveTracks list.
	if ExistingWrapper then
		self:_RetireWrapper(ConfigName)
		ExistingWrapper = nil
	end

	-- ── Grouped animation path ─────────────────────────────────────────────
	if Config.Group then
		self.GroupManager:EnsureGroup(Config.Group)

		-- Acquire a wrapper before calling EvaluatePlayRequest because the
		-- group manager needs a real wrapper object to store as ActiveWrapper
		-- or PendingWrapper. If the verdict is REJECT, we destroy the wrapper.
		local IncomingWrapper = self:_AcquireWrapper(Config)
		local GroupResult = self.GroupManager:EvaluatePlayRequest(Config.Group, IncomingWrapper)

		if GroupResult.Verdict == "REJECT" then
			-- Not eligible to play. Destroy immediately; don't pool because the
			-- wrapper was never played and has no state to preserve.
			IncomingWrapper:_Destroy()
			return

		elseif GroupResult.Verdict == "DEFER" then
			-- Wrapper is now owned by GroupManager as PendingWrapper.
			-- Do NOT destroy it. Retire any evicted pending to the pool.
			if GroupResult.PendingEvicted then
				self:_PoolOrDestroyWrapper(GroupResult.PendingEvicted)
			end
			return

		elseif GroupResult.Verdict == "ALLOW" then
			-- Stop the previous occupant with a fade before activating the new one.
			if GroupResult.WrapperToStop then
				GroupResult.WrapperToStop:_Stop(false)
			end
			-- Retire any evicted pending wrapper.
			if GroupResult.PendingEvicted then
				self:_PoolOrDestroyWrapper(GroupResult.PendingEvicted)
			end
			self:_ActivateWrapper(IncomingWrapper, Config, LayerRecord)
			return
		end
	end

	-- ── Non-grouped animation path ─────────────────────────────────────────
	-- Bug E fix: collect ALL non-grouped incumbents on the same layer, not just
	-- the strongest. Resolve authority against the strongest; on ALLOW, stop all.
	local LayerIncumbents: { any } = {}
	local StrongestIncumbent: any  = nil

	for _, Wrapper in self.ActiveWrappers do
		local IsOnSameLayer    = Wrapper.Config.Layer == Config.Layer
		local IsNonGrouped     = Wrapper.Config.Group == nil

		if IsOnSameLayer and IsNonGrouped then
			table.insert(LayerIncumbents, Wrapper)

			local IsStrongerThanCurrent = StrongestIncumbent == nil
				or Wrapper.Config.Priority > StrongestIncumbent.Config.Priority

			if IsStrongerThanCurrent then
				StrongestIncumbent = Wrapper
			end
		end
	end

	-- Resolve the incoming animation against the strongest incumbent.
	local ConflictVerdict: Types.ConflictVerdict

	if StrongestIncumbent then
		local IncumbentLayer = self.LayerManager:GetLayer(StrongestIncumbent.Config.Layer)

		ConflictVerdict = ConflictResolver.ResolveNoGroup(
			Config,
			LayerRecord.Order,
			StrongestIncumbent.Config,
			IncumbentLayer and IncumbentLayer.Order or 0,
			StrongestIncumbent.StartTimestamp
		)
	else
		-- No incumbent means an empty slot — always allow.
		ConflictVerdict = "ALLOW"
	end

	if ConflictVerdict == "ALLOW" then
		-- Stop ALL incumbents on this layer, not just the strongest.
		-- Without this, weaker incumbents accumulate and are never retired.
		for _, IncumbentWrapper in LayerIncumbents do
			self:Stop(IncumbentWrapper.Config.Name, false)
		end

		local newWrapper = self:_AcquireWrapper(Config)
		self:_ActivateWrapper(newWrapper, Config, LayerRecord)
	end
	-- REJECT: incoming animation lost conflict resolution; do nothing.
end

-- ─── Pool-or-Destroy Helper ───────────────────────────────────────────────────

--[[
    _PoolOrDestroyWrapper

    Description:
        Attempts to return a wrapper to its config's pool. If the pool is at
        capacity or the wrapper fails the safety check, destroys it instead.

        This helper centralises the repeated pool-or-destroy pattern that appears
        when handling evicted pending wrappers in the grouped play path, avoiding
        code duplication and ensuring pool capacity is respected consistently.

    Parameters:
        EvictedWrapper : any
            A wrapper that was displaced from a group's pending slot and must be
            either recycled or destroyed.
]]
function AnimationController:_PoolOrDestroyWrapper(EvictedWrapper: any)
	local ConfigName = EvictedWrapper.Config.Name

	if not self._WrapperPool[ConfigName] then
		self._WrapperPool[ConfigName] = {}
	end

	local Pool = self._WrapperPool[ConfigName]
	local IsPoolBelowCapacity = #Pool < MAX_POOL_SIZE_PER_CONFIG
	local IsWrapperSafeToPool = EvictedWrapper:_IsPoolReady()

	if IsPoolBelowCapacity and IsWrapperSafeToPool then
		EvictedWrapper.CompletedSignal:DisconnectAll()
		table.insert(Pool, EvictedWrapper)
	else
		EvictedWrapper:_Destroy()
	end
end

-- ─── Wrapper Activation ───────────────────────────────────────────────────────

--[=[
    _ActivateWrapper

    Description:
        Registers the wrapper as active, connects the completion listener for
        non-looped grouped animations, starts playback, and queues a PLAY intent
        for relay to the server.

    Parameters:
        Wrapper     : any
            The TrackWrapper to activate. Must have been acquired via _AcquireWrapper
            and not yet played.

        Config      : AnimationConfig
            The frozen config record associated with this wrapper.

        LayerRecord : any
            The LayerRecord from LayerManager for the config's layer. Used for
            registration; passed in to avoid a redundant lookup.

    Returns:
        Nothing.

    Notes:
        CompletedSignal connection design:
            Non-looped grouped animations connect a permanent listener here.
            This listener fires OnActiveCompleted for BOTH natural completion
            (track reaches end) AND manual faded stop (via the deferred
            CompletedSignal:Fire in TrackWrapper:_Stop). Having one permanent
            Connect handle both paths is simpler and less error-prone than
            maintaining separate Once listeners for manual vs natural completion.

            The captured wrapper reference in the closure is critical (Bug fix):
            without capturing to a local, the closure closes over the 'Wrapper'
            parameter variable. If the parameter is reused in a future call
            (Lua closures capture by reference, not by value for upvalues), the
            wrong wrapper's slot could be cleared. Capturing once at activation time
            ensures the closure always refers to the specific wrapper it was created for.

        Intent queuing:
            Only the owning client queues intents. The server and non-owning clients
            never call QueueIntent to avoid echo loops.
]=]
function AnimationController:_ActivateWrapper(Wrapper: any, Config: AnimationConfig, LayerRecord: any)
	-- Register in ActiveWrappers and LayerManager.ActiveTracks.
	self.ActiveWrappers[Config.Name] = Wrapper
	self.LayerManager:RegisterTrack(Config.Layer, Wrapper)

	-- For non-looped grouped animations, connect a permanent CompletedSignal listener
	-- that clears the group slot and promotes any pending wrapper when this animation ends.
	-- Looped grouped animations never complete naturally, so no listener is needed here;
	-- Stop handles slot promotion via an ad-hoc Once listener when called.
	if not Config.Looped and Config.Group then
		local CapturedWrapper = Wrapper
		local CapturedGroup   = Config.Group :: string

		Wrapper.CompletedSignal:Connect(function()
			local GroupRecord = self.GroupManager._groups[CapturedGroup]
			-- Guard: only fire OnActiveCompleted if the group slot still points to
			-- this specific wrapper. If another animation won the slot between this
			-- animation starting and completing, firing here would clear the wrong slot.
			local IsStillActiveInGroup = GroupRecord and GroupRecord.ActiveWrapper == CapturedWrapper

			if IsStillActiveInGroup then
				self.GroupManager:OnActiveCompleted(CapturedGroup)
			end
		end)
	end

	-- Begin playback. On the server this updates bookkeeping only (no track call).
	Wrapper:_Play()

	-- Queue a PLAY intent for the server relay (owning client only).
	local IsOwningClient = not IS_SERVER and self._Replication._isOwningClient
	if IsOwningClient then
		self._Replication:QueueIntent(
			Config.Name,
			"PLAY",
			self.StateMachine:GetCurrentStateName()
		)
	end
end

-- ─── Pending Ready Callback ───────────────────────────────────────────────────

--[=[
    _OnPendingReady

    Description:
        Called by ExclusiveGroupManager when a DEFER'd wrapper's MinDuration
        window expires and the wrapper is eligible to be promoted to active.

        Re-evaluates the wrapper as a fresh play request. If the group is still
        occupied by a CanInterrupt=false animation whose MinDuration has reset
        (rare edge case), the wrapper may be DEFER'd again. If the group is now
        free, the wrapper is activated.

    Parameters:
        GroupName : string
            The exclusive group the wrapper belongs to.

        PendingWrapper : any
            The wrapper that was stored as PendingWrapper in the group record.

    Returns:
        Nothing.

    Notes:
        Bug #1 fix context:
            EvaluatePlayRequest inspects record.PendingWrapper to decide what to
            evict. If we call it without first clearing PendingWrapper, it sees the
            incoming wrapper as the pending occupant, returns it as PendingEvicted,
            and the caller would destroy the wrapper it is trying to activate.
            The fix clears record.PendingWrapper BEFORE calling EvaluatePlayRequest.

        Bug I fix context:
            OnActiveCompleted no longer clears ActiveWrapper before promotion is
            confirmed. If promotion fails (controller destroyed, layer missing,
            REJECT verdict), this method is responsible for calling ClearActive so
            the group slot is not permanently held by a defunct wrapper.
]=]
function AnimationController:_OnPendingReady(GroupName: string, PendingWrapper: any)
	-- If the controller was destroyed between the timer being scheduled and firing,
	-- destroy the wrapper and clear the group slot.
	if self.IsDestroyed then
		PendingWrapper:_Destroy()
		-- Bug I fix: clear the slot so it doesn't stay occupied by a dead wrapper.
		self.GroupManager:ClearActive(GroupName)
		return
	end

	local GroupRecord = self.GroupManager._groups[GroupName]
	if not GroupRecord then
		PendingWrapper:_Destroy()
		return
	end

	-- If the wrapper was displaced by a newer request between the timer firing and
	-- this callback executing, it is no longer the registered pending wrapper.
	-- Destroy it silently; the replacement wrapper will handle its own promotion.
	if GroupRecord.PendingWrapper ~= PendingWrapper then
		PendingWrapper:_Destroy()
		return
	end

	-- Bug #1 fix: clear PendingWrapper BEFORE calling EvaluatePlayRequest so the
	-- evaluation doesn't see the incoming wrapper as its own eviction target.
	GroupRecord.PendingWrapper = nil

	local Config      = PendingWrapper.Config
	local LayerRecord = self.LayerManager:GetLayer(Config.Layer)

	if not LayerRecord then
		-- Layer was removed while the wrapper was pending. Cannot promote.
		PendingWrapper:_Destroy()
		-- Bug I fix: clear the slot to unblock future plays in this group.
		self.GroupManager:ClearActive(GroupName)
		return
	end

	local PromotionResult = self.GroupManager:EvaluatePlayRequest(GroupName, PendingWrapper)

	if PromotionResult.Verdict == "ALLOW" then
		if PromotionResult.WrapperToStop then
			PromotionResult.WrapperToStop:_Stop(false)
		end
		-- PendingEvicted should be nil here since we cleared PendingWrapper above.
		-- Handle defensively in case of an unexpected race.
		if PromotionResult.PendingEvicted then
			PromotionResult.PendingEvicted:_Destroy()
		end
		self:_ActivateWrapper(PendingWrapper, Config, LayerRecord)

	elseif PromotionResult.Verdict == "DEFER" then
		-- A new CanInterrupt=false animation started in this group between the
		-- timer firing and this re-evaluation. EvaluatePlayRequest has re-stored
		-- PendingWrapper and scheduled a new delay timer. Do nothing here.
		return

	else
		-- REJECT: wrapper cannot be promoted. Destroy it and clear the group slot.
		PendingWrapper:_Destroy()
		-- Bug I fix: EvaluatePlayRequest did not commit a new ActiveWrapper on REJECT.
		self.GroupManager:ClearActive(GroupName)
	end
end

-- ─── State Machine Callback ───────────────────────────────────────────────────

--[=[
    _OnStateChange

    Description:
        Invoked by StateMachine._DoTransition immediately after _CurrentState is
        updated (Bug U fix). Responsible for:
          1. Executing all exit directives from the exiting state.
          2. Diffing layer weight targets between the exiting and entering states.
          3. Executing all entry directives from the entering state.

        All directives are routed through _DispatchDirective, which sends Play calls
        through the pending queue (Step 5) rather than executing immediately. This
        guarantees that every play during a state transition sees fully interpolated
        layer weights, not the pre-transition weights at Step 1.

    Parameters:
        ExitingState  : StateDefinition
            The state being left.

        EnteringState : StateDefinition
            The state being entered.

    Returns:
        Nothing.

    Notes:
        Bug R fix context:
            Without the exit-active cleanup loop, layers that were activated by the
            exiting state but not referenced in the entering state would remain at
            their raised weight indefinitely. The fix explicitly calls SetLayerToBase
            for any layer that was Active in the exiting state but is neither Active
            nor Suppressed in the entering state.

        Bug #12 fix context:
            "Immediate" in AnimationDirective means "skip fade-out", not "bypass
            queue". All Play directives go through self:Play → PendingQueue regardless
            of the Immediate flag. Stop directives pass Immediate through to control
            whether the fade is skipped.
]=]
function AnimationController:_OnStateChange(ExitingState: StateDefinition, EnteringState: StateDefinition)
	-- Execute exit directives first. These typically stop animations that were
	-- started by the exiting state's entry actions.
	for _, Directive in ExitingState.ExitActions do
		self:_DispatchDirective(Directive)
	end

	-- Build lookup sets for fast membership testing during the layer diff.
	local EnteringActiveLayers:   { [string]: boolean } = {}
	local EnteringSuppressLayers: { [string]: boolean } = {}
	local ExitingActiveLayers:    { [string]: boolean } = {}
	local ExitingSuppressLayers:  { [string]: boolean } = {}

	for _, LayerName in EnteringState.ActiveLayers   do EnteringActiveLayers[LayerName]   = true end
	for _, LayerName in EnteringState.SuppressLayers do EnteringSuppressLayers[LayerName] = true end
	for _, LayerName in ExitingState.ActiveLayers    do ExitingActiveLayers[LayerName]    = true end
	for _, LayerName in ExitingState.SuppressLayers  do ExitingSuppressLayers[LayerName]  = true end

	-- ── Layer diff: activate newly-active layers ───────────────────────────
	-- Restore layers that are Active in the entering state but were not Active
	-- in the exiting state (they may have been suppressed or simply absent).
	for LayerName in EnteringActiveLayers do
		if not ExitingActiveLayers[LayerName] then
			self.LayerManager:SetLayerToBase(LayerName)
		end
	end

	-- ── Layer diff: suppress newly-suppressed layers ───────────────────────
	for LayerName in EnteringSuppressLayers do
		if not ExitingSuppressLayers[LayerName] then
			self.LayerManager:SuppressLayer(LayerName)
		end
	end

	-- ── Layer diff: restore layers that are no longer suppressed ───────────
	-- Layers that were suppressed by the exiting state but are neither suppressed
	-- nor explicitly active in the entering state should return to their base weight.
	for LayerName in ExitingSuppressLayers do
		local IsStillSuppressed = EnteringSuppressLayers[LayerName]
		local IsNowExplicitlyActive = EnteringActiveLayers[LayerName]

		if not IsStillSuppressed and not IsNowExplicitlyActive then
			self.LayerManager:SetLayerToBase(LayerName)
		end
	end

	-- ── Layer diff: deactivate layers no longer referenced ─────────────────
	-- Bug R fix: layers that were Active in the exiting state but are neither
	-- Active nor Suppressed in the entering state must be returned to base weight.
	-- Without this, they stay at their raised weight indefinitely.
	for LayerName in ExitingActiveLayers do
		local IsStillActive    = EnteringActiveLayers[LayerName]
		local IsNowSuppressed  = EnteringSuppressLayers[LayerName]

		if not IsStillActive and not IsNowSuppressed then
			self.LayerManager:SetLayerToBase(LayerName)
		end
	end

	-- Execute entry directives after the layer diff so that any play request
	-- in EntryActions sees the updated layer weight targets at Step 5.
	for _, Directive in EnteringState.EntryActions do
		self:_DispatchDirective(Directive)
	end
end

-- ─── Directive Dispatch ───────────────────────────────────────────────────────

--[=[
    _DispatchDirective

    Description:
        Translates an AnimationDirective into a controller API call.

        PLAY directives are always enqueued via self:Play, which adds them to
        PendingQueue for execution at Step 5. This ensures layer weights are
        current when the conflict resolution runs (Bug #12 fix).

        STOP and STOP_GROUP directives are executed via self:Stop/StopGroup.
        The Immediate flag on these directives controls whether the stop uses a
        fade-out (Immediate = false) or a hard cut (Immediate = true).

    Parameters:
        Directive : AnimationDirective
            The directive to dispatch. Action is one of "PLAY", "STOP", "STOP_GROUP".
            Target is the animation name or group name. Immediate controls fade behaviour.

    Returns:
        Nothing.
]=]
function AnimationController:_DispatchDirective(Directive: AnimationDirective)
	if Directive.Action == "PLAY" then
		-- Always enqueue; never execute immediately. Layer weights must be current.
		self:Play(Directive.Target)
	elseif Directive.Action == "STOP" then
		self:Stop(Directive.Target, Directive.Immediate)
	elseif Directive.Action == "STOP_GROUP" then
		self:StopGroup(Directive.Target, Directive.Immediate)
	end
end

-- ─── Replication: Intent Receiver ────────────────────────────────────────────

--[=[
    _OnIntentReceived

    Description:
        Called on non-owning clients when the ReplicationBridge receives a relayed
        AnimationIntent from the server. Replays the action through the normal
        Play/Stop pipeline so the animation is reconstructed locally.

    Parameters:
        ReceivedIntent : Types.AnimationIntent
            The validated intent relayed from the owning client via the server.

    Returns:
        Nothing.
]=]
function AnimationController:_OnIntentReceived(ReceivedIntent: Types.AnimationIntent)
	if ReceivedIntent.Action == "PLAY" then
		self:Play(ReceivedIntent.AnimationName)
	elseif ReceivedIntent.Action == "STOP" then
		self:Stop(ReceivedIntent.AnimationName, false)
	end
end

-- ─── Replication: Snapshot Reconciliation ────────────────────────────────────

--[=[
    _OnSnapshotMismatch

    Description:
        Called on non-owning clients when a snapshot reveals the local sequence
        counter differs from the server's — indicating one or more dropped intents.
        Performs a full reconciliation: tears down all active animation state and
        replays the server-authoritative group animations and FSM state.

    Parameters:
        MismatchedSnapshot : any
            The SnapshotData received from the server. Fields used:
                StateName        — Target FSM state for realignment.
                ActiveGroupAnims — Map of group → animation name to replay.

    Returns:
        Nothing.

    Notes:
        Bug #15 note:
            Wrappers with IsFading = true (just started playing with FadeInTime > 0)
            are excluded from _BuildActiveGroupAnimMap and therefore from the snapshot.
            Non-owning clients reconciling during a fade-in miss those animations.
            This is a known limitation; a complete fix would require including
            fading-in wrappers in the snapshot with timing metadata.

        Bug D fix context:
            PendingQueue is cleared after stopping active wrappers. Without this,
            stale queue entries from earlier in the same tick would flush at Step 5
            alongside the reconciliation plays, potentially overwriting the
            snapshot-dictated state immediately.

        GroupManager rebuild:
            Destroy + reconstruct is safer than selectively clearing groups.
            ClearActive alone would leave pending wrappers orphaned with no path to
            promotion or destruction. The full rebuild ensures a clean slate.
]=]
function AnimationController:_OnSnapshotMismatch(MismatchedSnapshot: any)
	if self.IsDestroyed then return end

	-- Stop and destroy every active wrapper immediately.
	-- Unregister from LayerManager first so its ActiveTracks list is clean.
	for _, Wrapper in self.ActiveWrappers do
		self.LayerManager:UnregisterTrack(Wrapper.Config.Layer, Wrapper)
		Wrapper:_Stop(true)
		Wrapper:_Destroy()
	end
	table.clear(self.ActiveWrappers)

	-- Bug D fix: clear stale queue entries accumulated earlier this tick so they
	-- don't pollute the post-reconciliation state.
	table.clear(self.PendingQueue)

	-- Tear down and rebuild GroupManager to destroy pending wrappers cleanly
	-- and reset all group records to an empty state.
	self.GroupManager:Destroy()
	self.GroupManager = ExclusiveGroupManager.new(
		function(GroupName: string, PendingWrapper: any)
			self:_OnPendingReady(GroupName, PendingWrapper)
		end,
		-- Bug V fix: pool discarded pending wrappers rather than hard-destroying
		-- them, to preserve pool capacity across repeated reconciliation cycles.
		function(DiscardedWrapper: any)
			local ConfigName = DiscardedWrapper.Config.Name
			if not self._WrapperPool[ConfigName] then
				self._WrapperPool[ConfigName] = {}
			end
			local Pool = self._WrapperPool[ConfigName]
			local IsPoolBelowCapacity = #Pool < MAX_POOL_SIZE_PER_CONFIG
			local IsWrapperSafeToPool = DiscardedWrapper:_IsPoolReady()

			if IsPoolBelowCapacity and IsWrapperSafeToPool then
				DiscardedWrapper.CompletedSignal:DisconnectAll()
				table.insert(Pool, DiscardedWrapper)
			else
				DiscardedWrapper:_Destroy()
			end
		end
	)

	-- Realign the FSM to the server's authoritative state. Using math.huge priority
	-- ensures this override beats any pending condition-driven transitions.
	local ServerStateName   = MismatchedSnapshot.StateName
	local IsFsmStateWrong   = ServerStateName
		and ServerStateName ~= self.StateMachine:GetCurrentStateName()

	if IsFsmStateWrong then
		self.StateMachine:RequestTransition(ServerStateName, math.huge)
	end

	-- Replay the server's active grouped animations.
	if MismatchedSnapshot.ActiveGroupAnims then
		for _, AnimationName in MismatchedSnapshot.ActiveGroupAnims do
			self:Play(AnimationName)
		end
	end
end

-- ─── Public State Machine Interface ──────────────────────────────────────────

--[=[
    RequestStateTransition

    Description:
        Submits an external transition request to the StateMachine. Queued for
        the next Tick's Phase A, where it competes with other pending transitions
        by priority.

        Use this from external systems (combat, cutscenes, UI) rather than directly
        mutating the FSM, to ensure all state changes occur at the well-defined
        point in the update pipeline.

    Parameters:
        StateName : string
            The destination state name. Must exist in the StateMachine's state table.

        Priority  : number
            Higher values win when multiple requests arrive in the same tick.
            Use math.huge for unconditional overrides.

    Returns:
        Nothing.
]=]
function AnimationController:RequestStateTransition(StateName: string, Priority: number)
	self.StateMachine:RequestTransition(StateName, Priority or 0)
end

-- ─── Active Group Animation Map ───────────────────────────────────────────────

--[=[
    _BuildActiveGroupAnimMap

    Description:
        Constructs the { [groupName]: animationName } map used by ReplicationBridge
        snapshots and passed to Flush each tick. Contains only wrappers that are
        fully playing (IsPlaying = true, IsFading = false), so animations that are
        still fading in are excluded.

    Returns:
        { [string]: string }
            Maps exclusive group name → the animation name currently active in that group.

    Notes:
        Bug #15 note: See _OnSnapshotMismatch for the known limitation around fading-in
        wrappers being excluded from this map.

        Bug F fix: if two wrappers from the same group are both active (violating
        exclusivity), last-write-wins in the map and a warning is logged. The map
        stays consistent but the violation is surfaced for debugging.
]=]
function AnimationController:_BuildActiveGroupAnimMap(): { [string]: string }
	local GroupAnimMap: { [string]: string } = {}

	for _, Wrapper in self.ActiveWrappers do
		local IsGroupedAndFullyPlaying = Wrapper.Config.Group
			and Wrapper.IsPlaying
			and not Wrapper.IsFading

		if IsGroupedAndFullyPlaying then
			local GroupName = Wrapper.Config.Group :: string

			-- Bug F fix: detect and warn on mutual-exclusivity violations.
			if GroupAnimMap[GroupName] then
				warn(string.format(
					"[AnimationController] Group invariant violated: both '%s' and '%s' are active in group '%s'",
					GroupAnimMap[GroupName],
					Wrapper.Config.Name,
					GroupName
					))
			end

			GroupAnimMap[GroupName] = Wrapper.Config.Name
		end
	end

	return GroupAnimMap
end

-- ─── Debug Inspector ──────────────────────────────────────────────────────────

--[=[
    AttachInspector

    Description:
        Creates and returns a DebugInspector bound to this controller.
        The inspector provides read-only snapshots and invariant validation
        without modifying any controller state.

        Lazily requires DebugInspector so that production builds can strip it
        via a conditional require guard without affecting this module.

    Returns:
        DebugInspector
            A live inspector attached to this controller.
]=]
function AnimationController:AttachInspector(): any
	local DebugInspector = require(script.DebugInspector)
	return DebugInspector.new(self)
end

-- ─── Destruction ──────────────────────────────────────────────────────────────

--[=[
    Destroy

    Description:
        Fully tears down the AnimationController and all subsystems it owns.
        Disconnects the per-frame update connection, stops and destroys all active
        wrappers, drains and destroys all pooled wrappers, tears down subsystems,
        and clears the pending queue.

        Idempotent — safe to call multiple times; subsequent calls are no-ops.

    Returns:
        Nothing.

    Notes:
        Bug G fix context:
            Pooled wrappers have _Stop(true) called before _Destroy. Without this,
            a wrapper that was pooled while its underlying track was still mid-fade
            would leave a ghost track playing on the client until GC collected the
            wrapper, producing a visual artefact.

        Order of operations matters:
            1. IsDestroyed = true first, so _Tick no-ops if it fires between now
               and the frame connection being disconnected.
            2. Frame connection disconnected before touching subsystems, so no
               further ticks can run against partially torn-down state.
            3. Active wrappers stopped and destroyed.
            4. Pooled wrappers stopped and destroyed.
            5. GroupManager destroyed (cancels pending timers, returns pending wrappers).
            6. Replication destroyed (disconnects remote connections).
            7. Pending queue cleared.
]=]
function AnimationController:Destroy()
	if self.IsDestroyed then return end
	self.IsDestroyed = true

	-- Disconnect the frame update first so no further _Tick calls can run.
	if self._FrameConn then
		self._FrameConn:Disconnect()
		self._FrameConn = nil
	end

	-- Stop and destroy all currently active wrappers.
	for _, Wrapper in self.ActiveWrappers do
		Wrapper:_Stop(true)
		Wrapper:_Destroy()
	end
	table.clear(self.ActiveWrappers)

	-- Bug G fix: _Stop(true) before _Destroy on pooled wrappers to clean up any
	-- tracks that reached the pool while still fading.
	for _, Pool in self._WrapperPool do
		for _, PooledWrapper in Pool do
			PooledWrapper:_Stop(true)
			PooledWrapper:_Destroy()
		end
	end
	table.clear(self._WrapperPool)

	-- Destroy subsystems in dependency order.
	self.GroupManager:Destroy()
	self._Replication:Destroy()

	table.clear(self.PendingQueue)
end

return AnimationController