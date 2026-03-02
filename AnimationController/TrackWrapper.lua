--!strict
-- ─── TrackWrapper.lua ─────────────────────────────────────────────────────────
--[[
    Wraps a single Roblox AnimationTrack with the bookkeeping fields the framework needs.

    TrackWrapper is the lowest-level animation primitive in the framework. It bridges
    between the Roblox AnimationTrack API (which is visual-only and client-side) and
    the framework's logical state (which must work on both server and client).

    ── Server vs Client Behaviour ───────────────────────────────────────────────

    AnimationTrack playback only ever happens on the client — the server never loads
    or renders animations. However, the rest of the framework (state machine, group
    manager, replication) needs consistent "is this playing" semantics on both sides.

    To bridge this:
      • On the client: _Play calls AnimationTrack:Play, _Stop calls AnimationTrack:Stop.
        Natural completion fires via track.Stopped → CompletedSignal.
      • On the server: _Play and _Stop are no-ops on the track, but they update the
        bookkeeping fields (IsPlaying, StartTimestamp, etc.) identically. Non-looped
        animations simulate completion via task.delay(MinDuration) to drive group
        succession server-side.

    ── Ownership ─────────────────────────────────────────────────────────────────

    TrackWrappers are created, reused (via pool), and destroyed exclusively by
    AnimationController. No external system holds a TrackWrapper reference directly.
    The public-facing API surface is read-only; all mutation methods are prefixed with
    underscore (_Play, _Stop, etc.) to communicate that only AnimationController should
    call them.

    ── Generation Counter (_PlayGeneration) ──────────────────────────────────────

    Bug #18 fix: non-looped animations on the server schedule a task.delay at play time
    to simulate completion. If the wrapper is reused (Reinitialize + _Play called again)
    before the delay fires, the delay from the previous play cycle would fire and mark
    the new play cycle as complete prematurely. _PlayGeneration is incremented on every
    _Play and _Reinitialize call. The closure captures the generation at scheduling time;
    if it mismatches at fire time, the delay no-ops.
]]

local RunService = game:GetService("RunService")
local Signal     = require(script.Parent.sign)
local Types      = require(script.Parent.Types)

type AnimationConfig = Types.AnimationConfig

-- Cached once at module load. RunService:IsServer() is a fast lookup but calling it
-- on every _Play and _Stop (which fire every animation play event) adds up over a session.
local IS_SERVER = RunService:IsServer()

-- ─── Public Type Surface ──────────────────────────────────────────────────────

--[[
    TrackWrapper is the exported type. Fields without underscore are read-only from
    outside the controller (by convention — Luau does not enforce property visibility).
    Methods prefixed with underscore are the internal mutation API for AnimationController.
]]
export type TrackWrapper = {
	Config:          AnimationConfig,
	EffectiveWeight: number,
	TargetWeight:    number,
	IsPlaying:       boolean,
	IsFading:        boolean,
	StartTimestamp:  number,
	PlaybackSpeed:   number,
	CompletedSignal: Signal.Signal<()>,

	_Play:               (self: TrackWrapper) -> (),
	_Stop:               (self: TrackWrapper, Immediate: boolean) -> (),
	_SetTargetWeight:    (self: TrackWrapper, Weight: number) -> (),
	_SetEffectiveWeight: (self: TrackWrapper, Weight: number) -> (),
	_SetSpeed:           (self: TrackWrapper, Speed: number) -> (),
	_Reinitialize:       (self: TrackWrapper) -> (),
	_Destroy:            (self: TrackWrapper) -> (),
	_IsPoolReady:        (self: TrackWrapper) -> boolean,

	_Track:          AnimationTrack?,
	_CompletedConn:  RBXScriptConnection?,
	_IsDestroyed:    boolean,
	_PlayGeneration: number,
}

-- ─── Constructor ──────────────────────────────────────────────────────────────

local TrackWrapper = {}
TrackWrapper.__index = TrackWrapper

--[=[
    TrackWrapper.new

    Description:
        Creates a new TrackWrapper for the given config, optionally wrapping a real
        AnimationTrack. On the server, Track will always be nil; on the client, a
        loaded AnimationTrack should be supplied.

        Wires the natural-completion listener (track.Stopped) only on the client where
        a real track exists. On the server, completion is simulated via task.delay
        inside _Play, driven by Config.MinDuration as a proxy for animation length.

    Parameters:
        Config: AnimationConfig
            The frozen config descriptor for this animation. Stored by reference —
            never cloned — because configs are globally immutable after Init.

        Track: AnimationTrack?
            The loaded Roblox AnimationTrack. Nil on the server and when constructing
            server-side wrapper shell objects.

    Returns:
        TrackWrapper
            A new wrapper in the stopped, zero-weight state, ready for _Play.
]=]
function TrackWrapper.new(Config: AnimationConfig, Track: AnimationTrack?): TrackWrapper
	local self = setmetatable({
		Config          = Config,
		-- EffectiveWeight starts at 0. It is pushed up by _SetEffectiveWeight once
		-- the wrapper is active and FadeInTime begins accumulating.
		EffectiveWeight = 0,
		-- TargetWeight starts at Config.Weight (the animation's configured base weight).
		-- This is the weight the wrapper should converge toward once playing.
		TargetWeight    = Config.Weight,
		IsPlaying       = false,
		IsFading        = false,
		StartTimestamp  = 0,
		PlaybackSpeed   = Config.Speed,
		CompletedSignal = Signal.new(),
		_Track          = Track,
		_CompletedConn  = nil,
		_IsDestroyed    = false,
		-- Generation counter starts at 0. _Play increments it before scheduling any
		-- delayed completion. If _Reinitialize is called before the delay fires,
		-- the captured generation in the closure will be stale and the delay no-ops.
		_PlayGeneration = 0,
	}, TrackWrapper)

	-- Wire up natural completion only on the client where a real track exists.
	-- The Stopped event fires when the track reaches the end of a non-looped animation
	-- OR when :Stop() is called (regardless of looped state). We gate on `not Config.Looped`
	-- so looped animations never fire CompletedSignal naturally — they require a manual Stop.
	if not IS_SERVER and Track then
		self._CompletedConn = Track.Stopped:Connect(function()
			local IsNaturalCompletion = self.IsPlaying and not Config.Looped
			if IsNaturalCompletion then
				self.IsPlaying = false
				-- Setting TargetWeight to 0 marks this wrapper for retirement.
				-- _PushWeights computes ComputeFinalWeight → 0, then calls _RetireWrapper
				-- once EffectiveWeight also reaches 0 via the fade-out lerp.
				-- Without this assignment, TargetWeight stays at Config.Weight and the
				-- wrapper never gets retired — it stays in ActiveWrappers indefinitely,
				-- leaking memory and blocking future plays of the same animation.
				self.TargetWeight = 0
				self.CompletedSignal:Fire()
			end
		end)
	end

	return self :: any
end

-- ─── Internal Mutation API ────────────────────────────────────────────────────

--[=[
    TrackWrapper:_Play

    Description:
        Begins playback of the wrapped animation. Updates bookkeeping fields
        on both server and client. On the client, delegates to AnimationTrack:Play.
        On the server, schedules a task.delay to simulate non-looped completion.

    Notes:
        Bug #18 fix: _PlayGeneration is incremented BEFORE the task.delay is scheduled
        so the closure captures the new generation. Any previously scheduled delay
        captures an older generation and will no-op when it fires.

        The bookkeeping update (IsPlaying, IsFading, StartTimestamp) happens before the
        track call on the client so that any code reading the wrapper's state during or
        after this frame sees consistent values.
]=]
function TrackWrapper:_Play()
	assert(not self._IsDestroyed, "[TrackWrapper] Attempt to play a destroyed wrapper")

	-- Increment generation before scheduling the delay so the closure below captures
	-- the correct (new) generation value. This is the Bug #18 fix — see module header.
	self._PlayGeneration += 1
	local CapturedGeneration = self._PlayGeneration

	-- Update bookkeeping unconditionally. The server needs these fields for group
	-- management and replication even though no visual track is played.
	self.IsPlaying      = true
	-- IsFading during play means a fade-IN is in progress. Only set when FadeInTime > 0,
	-- because a zero FadeInTime means the animation snaps to full weight immediately —
	-- there is nothing to "fade in".
	self.IsFading       = self.Config.FadeInTime > 0
	-- Record the exact start time. Used by ExclusiveGroupManager to compute elapsed time
	-- against MinDuration, and by ConflictResolver Phase 2b.
	self.StartTimestamp = os.clock()
	-- EffectiveWeight starts at 0 and is pushed up by _SetEffectiveWeight each frame.
	-- Starting at 0 rather than TargetWeight means the fade-in always begins from nothing.
	self.EffectiveWeight = 0

	-- Server path: no real AnimationTrack exists.
	-- Simulate non-looped completion via task.delay so ExclusiveGroupManager's group
	-- succession logic (OnActiveCompleted → promote pending) still works server-side.
	if IS_SERVER or not self._Track then
		if not self.Config.Looped then
			local SimulatedDuration = self.Config.MinDuration or 0
			task.delay(SimulatedDuration, function()
				-- Bug #18 fix: only fire if this delay belongs to the current play cycle.
				-- If _Reinitialize was called and _Play was called again before this fires,
				-- _PlayGeneration > CapturedGeneration and we skip — preventing premature
				-- completion of the new cycle.
				local IsCurrentPlayCycle = self._PlayGeneration == CapturedGeneration
				if not IsCurrentPlayCycle then return end

				if self.IsPlaying then
					self.IsPlaying = false
					-- Mirror the client Stopped handler: set TargetWeight = 0 so
					-- _PushWeights can drive EffectiveWeight to 0 and retire this wrapper.
					self.TargetWeight = 0
					self.CompletedSignal:Fire()
				end
			end)
		end
		return
	end

	-- Client path: delegate to the real AnimationTrack.
	-- FadeInTime, TargetWeight, and PlaybackSpeed are passed directly from config/state.
	self._Track:Play(self.Config.FadeInTime, self.TargetWeight, self.PlaybackSpeed)
end

--[=[
    TrackWrapper:_Stop

    Description:
        Stops the wrapped animation, either immediately (no fade) or with a fade-out.

        Updates bookkeeping fields and schedules a deferred CompletedSignal fire for
        all manual faded stops. This is necessary because there are three distinct
        completion paths, none of which covers all cases on their own:

          1. _CompletedConn (track.Stopped): fires for NATURAL non-looped client completion.
             Does NOT fire for manual stops because IsPlaying is already false when Stop runs.
          2. Server task.delay: fires for NATURAL server completion only.
          3. This deferred fire: covers ALL manual faded stops on both environments.

    Parameters:
        Immediate: boolean
            true  → zero-duration stop, EffectiveWeight snaps to 0 immediately.
            false → fade-out over Config.FadeOutTime; CompletedSignal fires deferred.

    Notes:
        Bug #4 fix: WasPlaying is captured BEFORE IsPlaying is set to false, so the
        IsFading assignment below correctly reflects "was playing before this Stop call"
        rather than always false. The original fix accidentally evaluated IsPlaying after
        clearing it, making IsFading always false and silently breaking all fade-out behaviour.

        Bug B, Q, X fixes: the deferred CompletedSignal fire covers the server path (B, Q)
        and the client path for both looped and non-looped animations (X).
        It is gated on `WasPlaying and not Immediate` because:
          • Immediate stops clear EffectiveWeight synchronously and AnimationController
            calls OnActiveCompleted directly — a deferred fire would double-trigger it.
          • We only need to drive group succession for animations that were actually playing
            (a Stop on an already-stopped wrapper is a no-op).
]=]
function TrackWrapper:_Stop(Immediate: boolean)
	if self._IsDestroyed then return end

	-- Capture playing state BEFORE clearing it. This is the Bug #4 fix.
	local WasPlaying   = self.IsPlaying
	self.IsPlaying     = false
	-- IsFading during stop means a fade-OUT is in progress. Only true when:
	--   • The animation was actually playing before this Stop call (WasPlaying).
	--   • The stop is not immediate (otherwise there is no fade to track).
	--   • The config has a non-zero FadeOutTime.
	self.IsFading      = WasPlaying and (not Immediate) and (self.Config.FadeOutTime > 0)
	self.TargetWeight  = 0

	if Immediate then
		-- Snap EffectiveWeight to 0 immediately. _PushWeights will then retire
		-- this wrapper in the same frame because all three retirement conditions
		-- (not IsPlaying, not IsFading, EffectiveWeight == 0) are simultaneously true.
		self.EffectiveWeight = 0
	end

	-- Schedule a deferred CompletedSignal fire for manual faded stops.
	-- This drives group succession (ExclusiveGroupManager.OnActiveCompleted) for
	-- animations that were manually stopped rather than naturally completing.
	--
	-- "Deferred" (task.defer) rather than immediate (CompletedSignal:Fire() here) because
	-- CompletedSignal listeners in AnimationController close over wrapper state. Firing
	-- synchronously here could cause re-entrant play requests before the current stop
	-- path has finished updating GroupManager state, leading to ordering bugs.
	--
	-- The generation guard prevents a stale deferred fire (from a wrapper that was
	-- reinitialized and played again before this defer runs) from triggering group
	-- succession for the new play cycle.
	if WasPlaying and not Immediate then
		local CapturedGeneration = self._PlayGeneration
		task.defer(function()
			if self._IsDestroyed then return end
			local IsCurrentGeneration = self._PlayGeneration == CapturedGeneration
			if not IsCurrentGeneration then return end
			self.CompletedSignal:Fire()
		end)
	end

	-- Only interact with the real AnimationTrack on the client.
	if IS_SERVER or not self._Track then return end

	local FadeOutDuration = Immediate and 0 or self.Config.FadeOutTime
	self._Track:Stop(FadeOutDuration)
end

--[=[
    TrackWrapper:_SetTargetWeight

    Description:
        Updates the wrapper's TargetWeight, clamping to [0, 1].
        TargetWeight is the weight the wrapper WANTS to be at; EffectiveWeight is the
        weight that is actually pushed to the track each frame via ComputeFinalWeight.

    Parameters:
        Weight: number — The desired target weight, clamped to [0, 1].
]=]
function TrackWrapper:_SetTargetWeight(Weight: number)
	self.TargetWeight = math.clamp(Weight, 0, 1)
end

--[=[
    TrackWrapper:_SetEffectiveWeight

    Description:
        Sets the EffectiveWeight and pushes it to the underlying AnimationTrack via
        AdjustWeight (client-only). Also clears IsFading when the fade is complete.

        Called every frame by AnimationController._PushWeights with the result of
        LayerManager:ComputeFinalWeight. EffectiveWeight is the final blended value
        (layer × target × config) that the track should actually use for rendering.

    Parameters:
        Weight: number — The new effective weight, clamped to [0, 1].

    Notes:
        IsFading clearing logic:
          • Fade-out complete: weight reaches 0 (regardless of IsPlaying state).
          • Fade-in complete: time since play start ≥ Config.FadeInTime.

        We cannot compare EffectiveWeight against TargetWeight to detect fade-in
        completion because EffectiveWeight is layer-modulated (Layer × Target × Config)
        while TargetWeight is the raw wrapper weight — different scales, not reliably
        comparable. Elapsed time is the reliable measure for fade-in completion.
]=]
function TrackWrapper:_SetEffectiveWeight(Weight: number)
	local ClampedWeight  = math.clamp(Weight, 0, 1)
	self.EffectiveWeight = ClampedWeight

	-- Push the weight to the real AnimationTrack on the client only.
	-- AdjustWeight is meaningless (and would error) if there is no track.
	if not IS_SERVER and self._Track then
		self._Track:AdjustWeight(ClampedWeight)
	end

	-- Clear IsFading once the relevant transition is complete.
	if self.IsFading then
		local IsFadeOutComplete = ClampedWeight == 0
		if IsFadeOutComplete then
			-- Both fade-in and fade-out complete when weight reaches zero.
			self.IsFading = false
		elseif self.IsPlaying then
			-- We are in a fade-IN (IsPlaying = true with IsFading = true means
			-- fade-in is in progress, as _Play only sets IsFading=true for FadeInTime > 0).
			local ElapsedSincePlay = os.clock() - self.StartTimestamp
			local IsFadeInComplete = ElapsedSincePlay >= self.Config.FadeInTime
			if IsFadeInComplete then
				self.IsFading = false
			end
		end
	end
end

--[=[
    TrackWrapper:_SetSpeed

    Description:
        Updates PlaybackSpeed and pushes it to the underlying track via AdjustSpeed.

    Parameters:
        Speed: number — The new playback speed multiplier.
]=]
function TrackWrapper:_SetSpeed(Speed: number)
	self.PlaybackSpeed = Speed

	if not IS_SERVER and self._Track then
		self._Track:AdjustSpeed(Speed)
	end
end

--[=[
    TrackWrapper:_Reinitialize

    Description:
        Resets all runtime fields so this wrapper can be reused from the pool for a
        new play request, without allocating a new TrackWrapper or loading a new track.

        Increments _PlayGeneration to invalidate any in-flight server task.delay or
        deferred CompletedSignal from the previous play cycle.

        Re-wires the track.Stopped completion listener on the client, since
        CompletedSignal:DisconnectAll cleared it.

    Notes:
        Bug #14 note: Config is intentionally NOT reset here. The pool only stores
        wrappers whose Config still matches the current registry. If the registry is
        rebuilt (in tests via _ResetForTest), all pools must be cleared before re-use.

        Bug #18 fix: _PlayGeneration is bumped so any pending task.delay from the
        previous cycle is invalidated — it captures the old generation and will no-op.
]=]
function TrackWrapper:_Reinitialize()
	assert(not self._IsDestroyed, "[TrackWrapper] Cannot reinitialize a destroyed wrapper")

	self.EffectiveWeight = 0
	-- Restore TargetWeight to the config's base weight, ready for the next fade-in.
	self.TargetWeight    = self.Config.Weight
	self.IsPlaying       = false
	self.IsFading        = false
	self.StartTimestamp  = 0
	self.PlaybackSpeed   = self.Config.Speed
	-- Bump generation to invalidate any in-flight task.delay or task.defer closures
	-- from the previous play cycle that have not fired yet.
	self._PlayGeneration += 1

	-- Disconnect all listeners before re-wiring to prevent stale handlers from the
	-- previous cycle from firing alongside the new ones.
	self.CompletedSignal:DisconnectAll()

	-- Re-wire the natural completion listener on the client.
	-- This mirrors the same setup in TrackWrapper.new — see that function for rationale.
	if not IS_SERVER and self._Track then
		if self._CompletedConn then
			self._CompletedConn:Disconnect()
		end
		self._CompletedConn = self._Track.Stopped:Connect(function()
			local IsNaturalCompletion = self.IsPlaying and not self.Config.Looped
			if IsNaturalCompletion then
				self.IsPlaying = false
				self.TargetWeight = 0
				self.CompletedSignal:Fire()
			end
		end)
	end
end

--[=[
    TrackWrapper:_IsPoolReady

    Description:
        Returns whether this wrapper is safe to pull from the pool and reuse.

        A wrapper is pool-ready when:
          • It has not been destroyed (destroyed wrappers must not be reused).
          • It is not currently playing (playing wrappers are still in ActiveWrappers).
          • On the client: its track handle is valid (non-nil).

        A wrapper whose track handle is nil on the client indicates it was constructed
        in an error state or the track was unloaded — it should not be reused.

    Returns:
        boolean — true if safe to reuse; false if it should be destroyed instead.
]=]
function TrackWrapper:_IsPoolReady(): boolean
	if self._IsDestroyed then return false end
	if IS_SERVER then
		-- On the server there is no track to check — only verify it is not playing.
		return not self.IsPlaying
	end
	-- On the client, the track handle must be valid AND the wrapper must not be playing.
	return self._Track ~= nil and not self.IsPlaying
end

--[=[
    TrackWrapper:_Destroy

    Description:
        Permanently disposes this wrapper. Disconnects all signal connections, stops
        the underlying track immediately (if on client and track is playing), and
        invalidates any in-flight completion delays via the generation counter.

        Safe to call multiple times — subsequent calls are no-ops.

        After _Destroy, no methods should be called on this wrapper.
]=]
function TrackWrapper:_Destroy()
	if self._IsDestroyed then return end
	self._IsDestroyed = true

	-- Bump generation to invalidate any task.delay or task.defer closures that
	-- may still be scheduled and have not yet fired.
	self._PlayGeneration += 1

	if self._CompletedConn then
		self._CompletedConn:Disconnect()
		self._CompletedConn = nil
	end

	-- Disconnect all external listeners (e.g. OnActiveCompleted hooks set up by
	-- AnimationController._ActivateWrapper) so they cannot fire after destroy.
	self.CompletedSignal:DisconnectAll()

	-- Stop and nil the track on the client to release the underlying Roblox resource.
	-- Not needed on the server (there is no track), and would error if called there.
	if not IS_SERVER and self._Track then
		if self._Track.IsPlaying then
			-- Hard stop with zero fade time so the track does not linger in memory
			-- playing silently after the wrapper is gone.
			self._Track:Stop(0)
		end
		self._Track = nil
	end
end

return TrackWrapper