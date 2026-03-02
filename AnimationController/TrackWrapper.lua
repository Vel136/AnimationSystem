--!strict
-- TrackWrapper.lua
-- Wraps a single Roblox AnimationTrack.
-- Never exposed to consumers of the public API.
-- Owned and created/destroyed exclusively by AnimationController.
-- All field mutation is through the internal controlled API (prefixed with _Set).
--
-- SERVER CONTEXT:
-- On the server, _Play() and _Stop() are no-ops against the real track.
-- The server never renders visuals, so AnimationTrack playback is meaningless there.
-- The wrapper still maintains its bookkeeping fields (IsPlaying, StartTimestamp, etc.)
-- so that the rest of the framework — state machine, group manager, replication —
-- can operate correctly regardless of which machine is running.

local RunService = game:GetService("RunService")
local Signal     = require(script.Parent.Signal)
local Types      = require(script.Parent.Types)

type AnimationConfig = Types.AnimationConfig

local IS_SERVER = RunService:IsServer()

-- ── Public-facing read-only type surface ───────────────────────────────────

export type TrackWrapper = {
	-- Read-only from outside the controller
	Config          : AnimationConfig,
	EffectiveWeight : number,
	TargetWeight    : number,
	IsPlaying       : boolean,
	IsFading        : boolean,
	StartTimestamp  : number,
	PlaybackSpeed   : number,
	CompletedSignal : Signal.Signal<()>,

	-- Internal mutation API (consumed only by AnimationController and subsystems)
	_Play               : (self: TrackWrapper) -> (),
	_Stop               : (self: TrackWrapper, immediate: boolean) -> (),
	_SetTargetWeight    : (self: TrackWrapper, w: number) -> (),
	_SetEffectiveWeight : (self: TrackWrapper, w: number) -> (),
	_SetSpeed           : (self: TrackWrapper, s: number) -> (),
	_Reinitialize       : (self: TrackWrapper) -> (),
	_Destroy            : (self: TrackWrapper) -> (),
	_IsPoolReady        : (self: TrackWrapper) -> boolean,

	-- Private
	_track          : AnimationTrack?,  -- nil on server (no track loaded)
	_completedConn  : RBXScriptConnection?,
	_destroyed      : boolean,
	-- Bug #18 fix: generation counter to invalidate stale server-side task.delay closures.
	-- Each call to _Play increments _playGeneration. The delay closure captures the
	-- generation at the time it was created; if the wrapper is reinitialized and played
	-- again before the delay fires, the captured generation will be stale and the
	-- closure will no-op instead of prematurely completing the new play cycle.
	_playGeneration : number,
}

-- ── Constructor ────────────────────────────────────────────────────────────

local TrackWrapper = {}
TrackWrapper.__index = TrackWrapper

function TrackWrapper.new(config: AnimationConfig, track: AnimationTrack?): TrackWrapper
	local self = setmetatable({
		Config          = config,
		EffectiveWeight = 0,
		TargetWeight    = config.Weight,
		IsPlaying       = false,
		IsFading        = false,
		StartTimestamp  = 0,
		PlaybackSpeed   = config.Speed,
		CompletedSignal = Signal.new(),
		_track          = track,   -- nil when constructed on the server
		_completedConn  = nil,
		_destroyed      = false,
		_playGeneration = 0,
	}, TrackWrapper)

	-- Wire up natural completion event only on the client where a real track exists.
	-- On the server there is no track, so we simulate completion via a task.delay
	-- based on the animation's known duration when Looped = false.
	-- This keeps group manager succession working correctly server-side.
	if not IS_SERVER and track then
		self._completedConn = track.Stopped:Connect(function()
			if self.IsPlaying and not config.Looped then
				self.IsPlaying = false
				-- Fix: set TargetWeight = 0 so _PushWeights can reach EffectiveWeight == 0
				-- and retire this wrapper. Without this, naturally-completed animations
				-- stay in ActiveWrappers indefinitely and block new plays on the same layer.
				self.TargetWeight = 0
				self.CompletedSignal:Fire()
			end
		end)
	end

	return self :: any
end

-- ── Internal Mutation API ──────────────────────────────────────────────────

function TrackWrapper:_Play()
	assert(not self._destroyed, "[TrackWrapper] Attempt to play a destroyed wrapper")

	-- Bug #18 fix: increment generation before scheduling the delay so that the
	-- closure below captures the new generation. Any previously scheduled delay
	-- that has not yet fired holds the old generation and will no-op.
	self._playGeneration += 1
	local capturedGeneration = self._playGeneration

	-- Update bookkeeping regardless of environment so the rest of the
	-- framework (conflict resolution, group management, replication) sees
	-- consistent state on both server and client.
	self.IsPlaying       = true
	self.IsFading        = self.Config.FadeInTime > 0
	self.StartTimestamp  = os.clock()
	self.EffectiveWeight = 0

	-- Only touch the real AnimationTrack on the client.
	if IS_SERVER or not self._track then
		-- Server: simulate non-looped completion so group succession still works.
		-- MinDuration is used as a proxy for duration since no real track exists.
		-- We always fire completion — even when MinDuration is 0 — so the group
		-- slot is never permanently held.
		if not self.Config.Looped then
			local duration = self.Config.MinDuration or 0
			task.delay(duration, function()
				-- Bug #18 fix: only fire if this closure belongs to the current play cycle.
				-- If _Reinitialize was called and _Play was called again before this delay
				-- fired, capturedGeneration < self._playGeneration and we skip, preventing
				-- premature completion of the new play cycle.
				if self._playGeneration ~= capturedGeneration then return end
				if self.IsPlaying then
					self.IsPlaying = false
					-- Fix: set TargetWeight = 0 so _PushWeights can reach EffectiveWeight == 0
					-- and retire this wrapper. Mirrors the same fix in the _completedConn path.
					self.TargetWeight = 0
					self.CompletedSignal:Fire()
				end
			end)
		end
		return
	end

	self._track:Play(self.Config.FadeInTime, self.TargetWeight, self.PlaybackSpeed)
end

function TrackWrapper:_Stop(immediate: boolean)
	if self._destroyed then return end

	-- Bug #4 fix: only set IsFading when the wrapper was actually playing.
	-- Capture wasPlaying before clearing IsPlaying so the IsFading assignment
	-- can reference it. The original fix accidentally set IsFading using
	-- self.IsPlaying after it had already been set to false, making IsFading
	-- always false and silently breaking all fade-out behaviour.
	local wasPlaying  = self.IsPlaying
	self.IsPlaying    = false
	self.IsFading     = wasPlaying and (not immediate) and self.Config.FadeOutTime > 0
	self.TargetWeight = 0

	if immediate then
		self.EffectiveWeight = 0
	end

	-- CompletedSignal must fire for every faded manual stop so group slot promotion
	-- and other CompletedSignal listeners run correctly. There are three separate
	-- completion paths and none covers all cases on its own:
	--
	--   1. _completedConn (track.Stopped): fires only when `IsPlaying` is still true
	--      at the moment track.Stopped fires. For NATURAL completion this works —
	--      the track plays to the end and stops while IsPlaying=true. For MANUAL
	--      faded stop it does NOT fire because _Stop already set IsPlaying=false
	--      before track.Stopped fires.
	--
	--   2. Server task.delay in _Play: fires only on NATURAL non-looped completion.
	--      Does not fire when _Stop is called manually.
	--
	--   3. This deferred fire: covers all MANUAL faded stops on both environments.
	--      Gated on `not immediate` because immediate stops are handled synchronously
	--      in Stop()'s isImmediate branch (OnActiveCompleted called directly), and
	--      firing here too would cause a double OnActiveCompleted call.
	--
	-- Bug B, Q fixes: server path. Bug X fix: client path (both looped and non-looped).
	if wasPlaying and not immediate then
		local capturedGeneration = self._playGeneration
		task.defer(function()
			if self._destroyed then return end
			if self._playGeneration ~= capturedGeneration then return end
			self.CompletedSignal:Fire()
		end)
	end

	-- Only interact with the real track on the client.
	if IS_SERVER or not self._track then return end

	local fadeTime = immediate and 0 or self.Config.FadeOutTime
	self._track:Stop(fadeTime)
end

function TrackWrapper:_SetTargetWeight(w: number)
	self.TargetWeight = math.clamp(w, 0, 1)
end

-- Called each frame by LayerManager / AnimationController weight push step.
-- AdjustWeight is a client-only visual call.
function TrackWrapper:_SetEffectiveWeight(w: number)
	local clamped = math.clamp(w, 0, 1)
	self.EffectiveWeight = clamped

	if not IS_SERVER and self._track then
		self._track:AdjustWeight(clamped)
	end

	-- IsFading is true during both fade-in and fade-out transitions.
	-- _Play only sets IsFading=true when FadeInTime > 0, so IsFading=true while
	-- IsPlaying always means a fade-in is in progress.
	-- Clear conditions:
	--   • Fade-out complete: weight reaches 0
	--   • Fade-in complete: elapsed time since play start >= FadeInTime
	-- EffectiveWeight cannot be compared against TargetWeight to detect fade-in
	-- completion because EffectiveWeight is layer-modulated
	-- (LayerCurrentWeight × TargetWeight × ConfigWeight) while TargetWeight is
	-- the raw wrapper weight — different scales, not reliably comparable.
	if self.IsFading then
		if clamped == 0 then
			self.IsFading = false
		elseif self.IsPlaying then
			-- Fade-in: clear once FadeInTime has elapsed.
			if os.clock() - self.StartTimestamp >= self.Config.FadeInTime then
				self.IsFading = false
			end
		end
	end
end

function TrackWrapper:_SetSpeed(s: number)
	self.PlaybackSpeed = s

	if not IS_SERVER and self._track then
		self._track:AdjustSpeed(s)
	end
end

-- Reset pooled wrapper for reuse — called before re-playing from pool.
-- Bug #14 note: Config is intentionally NOT reset here. The caller (_AcquireWrapper)
-- is responsible for ensuring the config passed at construction time still matches
-- the registry. If the registry is reset in tests via _ResetForTest, all pooled
-- wrappers should be destroyed and pools cleared before re-initializing the registry.
function TrackWrapper:_Reinitialize()
	assert(not self._destroyed, "[TrackWrapper] Cannot reinitialize a destroyed wrapper")
	self.EffectiveWeight = 0
	self.TargetWeight    = self.Config.Weight
	self.IsPlaying       = false
	self.IsFading        = false
	self.StartTimestamp  = 0
	self.PlaybackSpeed   = self.Config.Speed
	-- Bug #18 fix: bump the generation so any in-flight server task.delay from the
	-- previous play cycle is invalidated on its next resume.
	self._playGeneration += 1
	self.CompletedSignal:DisconnectAll()

	-- Re-wire completion only on the client where a real track exists.
	if not IS_SERVER and self._track then
		if self._completedConn then
			self._completedConn:Disconnect()
		end
		self._completedConn = self._track.Stopped:Connect(function()
			if self.IsPlaying and not self.Config.Looped then
				self.IsPlaying = false
				self.TargetWeight = 0
				self.CompletedSignal:Fire()
			end
		end)
	end
end

-- Returns true if this wrapper is safe to pull from the pool.
-- On the server there is no track, so we just check the destroyed flag.
function TrackWrapper:_IsPoolReady(): boolean
	if self._destroyed then return false end
	if IS_SERVER then return not self.IsPlaying end
	return self._track ~= nil and not self.IsPlaying
end

function TrackWrapper:_Destroy()
	if self._destroyed then return end
	self._destroyed = true

	-- Invalidate any pending server-side completion delay.
	self._playGeneration += 1

	if self._completedConn then
		self._completedConn:Disconnect()
		self._completedConn = nil
	end

	self.CompletedSignal:DisconnectAll()

	-- Only stop and nil the track on the client.
	if not IS_SERVER and self._track then
		if self._track.IsPlaying then
			self._track:Stop(0)
		end
		self._track = nil
	end
end

return TrackWrapper
