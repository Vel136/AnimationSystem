--!strict
-- TrackWrapper.lua
-- Wraps a single Roblox AnimationTrack.
-- Never exposed to consumers of the public API.
-- Owned and created/destroyed exclusively by AnimationController.
-- All field mutation is through the internal controlled API (prefixed with _Set).

local Signal = require(script.Parent.Signal)
local Types  = require(script.Parent.Types)

type AnimationConfig = Types.AnimationConfig

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
	_Play          : (self: TrackWrapper) -> (),
	_Stop          : (self: TrackWrapper, immediate: boolean) -> (),
	_SetTargetWeight : (self: TrackWrapper, w: number) -> (),
	_SetEffectiveWeight : (self: TrackWrapper, w: number) -> (),
	_SetSpeed      : (self: TrackWrapper, s: number) -> (),
	_Reinitialize  : (self: TrackWrapper) -> (),
	_Destroy       : (self: TrackWrapper) -> (),
	_IsPoolReady   : (self: TrackWrapper) -> boolean,

	-- Private
	_track             : AnimationTrack,
	_completedConn     : RBXScriptConnection?,
	_destroyed         : boolean,
}

-- ── Constructor ────────────────────────────────────────────────────────────

local TrackWrapper = {}
TrackWrapper.__index = TrackWrapper

function TrackWrapper.new(config: AnimationConfig, track: AnimationTrack): TrackWrapper
	local self = setmetatable({
		Config          = config,
		EffectiveWeight = 0,
		TargetWeight    = config.Weight,
		IsPlaying       = false,
		IsFading        = false,
		StartTimestamp  = 0,
		PlaybackSpeed   = config.Speed,
		CompletedSignal = Signal.new(),
		_track          = track,
		_completedConn  = nil,
		_destroyed      = false,
	}, TrackWrapper)

	-- Wire up natural completion event for non-looped tracks
	self._completedConn = track.Stopped:Connect(function()
		if self.IsPlaying and not config.Looped then
			self.IsPlaying = false
			self.CompletedSignal:Fire()
		end
	end)

	return self :: any
end

-- ── Internal Mutation API ──────────────────────────────────────────────────

function TrackWrapper:_Play()
	assert(not self._destroyed, "[TrackWrapper] Attempt to play a destroyed wrapper")
	self._track:Play(self.Config.FadeInTime, self.TargetWeight, self.PlaybackSpeed)
	self.IsPlaying      = true
	self.IsFading       = self.Config.FadeInTime > 0
	self.StartTimestamp = os.clock()
	self.EffectiveWeight = 0 -- will ramp up via weight push
end

function TrackWrapper:_Stop(immediate: boolean)
	if self._destroyed then return end
	local fadeTime = immediate and 0 or self.Config.FadeOutTime
	self._track:Stop(fadeTime)
	self.IsPlaying = false
	self.IsFading  = fadeTime > 0
	self.TargetWeight = 0
end

function TrackWrapper:_SetTargetWeight(w: number)
	self.TargetWeight = math.clamp(w, 0, 1)
end

-- Called each frame by LayerManager / AnimationController weight push step
function TrackWrapper:_SetEffectiveWeight(w: number)
	local clamped = math.clamp(w, 0, 1)
	self.EffectiveWeight = clamped
	self._track:AdjustWeight(clamped)
	if clamped == 0 and self.IsFading then
		self.IsFading = false
	end
end

function TrackWrapper:_SetSpeed(s: number)
	self.PlaybackSpeed = s
	self._track:AdjustSpeed(s)
end

-- Reset pooled wrapper for reuse — called before re-playing from pool
function TrackWrapper:_Reinitialize()
	assert(not self._destroyed, "[TrackWrapper] Cannot reinitialize a destroyed wrapper")
	self.EffectiveWeight = 0
	self.TargetWeight    = self.Config.Weight
	self.IsPlaying       = false
	self.IsFading        = false
	self.StartTimestamp  = 0
	self.PlaybackSpeed   = self.Config.Speed
	self.CompletedSignal:DisconnectAll()
	-- Re-wire completion
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

-- Returns true if this wrapper is safe to pull from the pool (track still valid)
function TrackWrapper:_IsPoolReady(): boolean
	if self._destroyed then return false end
	-- Roblox tracks can become invalid if the Animator is destroyed
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
	if self._track and self._track.IsPlaying then
		self._track:Stop(0)
	end
	self._track = nil :: any
end

return TrackWrapper