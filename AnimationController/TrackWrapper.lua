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
	_track         : AnimationTrack?,  -- nil on server (no track loaded)
	_completedConn : RBXScriptConnection?,
	_destroyed     : boolean,
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
	}, TrackWrapper)

	-- Wire up natural completion event only on the client where a real track exists.
	-- On the server there is no track, so we simulate completion via a task.delay
	-- based on the animation's known duration when Looped = false.
	-- This keeps group manager succession working correctly server-side.
	if not IS_SERVER and track then
		self._completedConn = track.Stopped:Connect(function()
			if self.IsPlaying and not config.Looped then
				self.IsPlaying = false
				self.CompletedSignal:Fire()
			end
		end)
	end

	return self :: any
end

-- ── Internal Mutation API ──────────────────────────────────────────────────

function TrackWrapper:_Play()
	assert(not self._destroyed, "[TrackWrapper] Attempt to play a destroyed wrapper")

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
		-- slot is never permanently held. Omitting the fire would deadlock the
		-- group manager, preventing any pending animation from ever being promoted.
		if not self.Config.Looped then
			local duration = self.Config.MinDuration or 0
			task.delay(duration, function()
				if self.IsPlaying then
					self.IsPlaying = false
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

	self.IsPlaying    = false
	self.IsFading     = (not immediate) and self.Config.FadeOutTime > 0
	self.TargetWeight = 0

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

	if clamped == 0 and self.IsFading then
		self.IsFading = false
	end
end

function TrackWrapper:_SetSpeed(s: number)
	self.PlaybackSpeed = s

	if not IS_SERVER and self._track then
		self._track:AdjustSpeed(s)
	end
end

-- Reset pooled wrapper for reuse — called before re-playing from pool.
function TrackWrapper:_Reinitialize()
	assert(not self._destroyed, "[TrackWrapper] Cannot reinitialize a destroyed wrapper")
	self.EffectiveWeight = 0
	self.TargetWeight    = self.Config.Weight
	self.IsPlaying       = false
	self.IsFading        = false
	self.StartTimestamp  = 0
	self.PlaybackSpeed   = self.Config.Speed
	self.CompletedSignal:DisconnectAll()

	-- Re-wire completion only on the client where a real track exists.
	if not IS_SERVER and self._track then
		if self._completedConn then
			self._completedConn:Disconnect()
		end
		self._completedConn = self._track.Stopped:Connect(function()
			if self.IsPlaying and not self.Config.Looped then
				self.IsPlaying = false
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