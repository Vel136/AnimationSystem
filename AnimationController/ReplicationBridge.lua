--!strict
-- ─── ReplicationBridge.lua ────────────────────────────────────────────────────
--[[
    ReplicationBridge implements the three-role replication model for the animation
    system using Blink for network serialization and transport.

    ── What Changed From the RemoteEvent Version ────────────────────────────────

    The original bridge managed:
        • Two raw RemoteEvent references (IntentRemote, SnapshotRemote)
        • A manual intent pool and queue (32 pre-allocated slots, cursor tracking)
        • Manual RBXScriptConnection storage and disconnection in Destroy

    With Blink:
        • The correct Blink module is required at module load time based on
          IS_SERVER — script.Parent.Blink.Server on the server,
          script.Parent.Blink.Client on the client. Neither module is passed
          in as a parameter; they are static dependencies like any other require.
        • QueueIntent calls BlinkNet.SendIntent.Fire directly — Blink batches
          writes internally and flushes on Heartbeat, so no manual pool or queue
          is needed
        • Listeners are registered via BlinkNet.X.On, which returns a disconnect
          function stored in _Disconnects for cleanup in Destroy
        • The server snapshot path calls BlinkNet.SendSnapshot.FireExcept so the
          owning player (who sent the intent) never receives their own snapshot
          as a relay — matching the original FireAllClients intent while being
          more precise

    ── Authority Model (unchanged) ──────────────────────────────────────────────

    Owning Client  — fires SendIntent, never listens to RelayIntent or SendSnapshot.
    Server         — listens to SendIntent, fires RelayIntent.FireExcept and
                     SendSnapshot.FireExcept on the snapshot interval.
    Non-Owning     — listens to RelayIntent and SendSnapshot.
]]

local RunService = game:GetService("RunService")
local Types      = require(script.Parent.Types)

local IS_SERVER = RunService:IsServer()

-- Require the correct Blink module for this environment.
-- Each generated module guards itself — the client module errors if required
-- on the server and vice versa, so the IS_SERVER branch here is load-order
-- safety rather than just a hint to the type checker.
local BlinkNet = if IS_SERVER
	then require(script.Parent.Blink.Server)
	else require(script.Parent.Blink.Client)

type AnimationIntent = Types.AnimationIntent

-- ─── Constants ────────────────────────────────────────────────────────────────

local STALE_INTENT_THRESHOLD_SECONDS = 0.5
local SNAPSHOT_INTERVAL_SECONDS      = 2.5

-- ─── Module ───────────────────────────────────────────────────────────────────

local ReplicationBridge = {}
ReplicationBridge.__index = ReplicationBridge

export type ReplicationBridge = typeof(setmetatable({} :: {
	_IsServer           : boolean,
	_IsOwningClient     : boolean,
	_CharacterId        : string,
	-- On the server, the Player instance that owns this character.
	-- Used for FireExcept so the owning client never receives its own relay.
	_OwningPlayer       : Player?,
	_SequenceNumber     : number,
	_SnapshotTimer      : number,
	_Destroyed          : boolean,
	_OnIntentReceived   : ((AnimationIntent) -> ())?,
	_OnSnapshotMismatch : ((any) -> ())?,
	-- Blink .On() returns a disconnect function. Stored here so Destroy can
	-- cleanly unregister all listeners without holding RBXScriptConnections.
	_Disconnects        : { () -> () },
}, ReplicationBridge))

-- ─── Constructor ──────────────────────────────────────────────────────────────

--[=[
    ReplicationBridge.New

    Parameters:
        CharacterId        : string
            Unique identifier for the character this bridge serves.

        IsOwningClient     : boolean
            True only on the client whose input drives this character.

        OwningPlayer       : Player?
            The Roblox Player that owns this character. Required on the server
            for FireExcept — the owning player should not receive relay intents
            or snapshots intended for other clients.
            Nil on clients (unused).

        OnIntentReceived   : ((AnimationIntent) -> ())?
            Fired on non-owning clients when a relay intent arrives.

        OnSnapshotMismatch : ((any) -> ())?
            Fired on non-owning clients when sequence counter drift is detected.
]=]
function ReplicationBridge.New(
	CharacterId        : string,
	IsOwningClient     : boolean,
	OwningPlayer       : Player?,
	OnIntentReceived   : ((AnimationIntent) -> ())?,
	OnSnapshotMismatch : ((any) -> ())?
): ReplicationBridge

	local EffectiveIsOwningClient = (not IS_SERVER) and IsOwningClient

	local Self = setmetatable({
		_IsServer           = IS_SERVER,
		_IsOwningClient     = EffectiveIsOwningClient,
		_CharacterId        = CharacterId,
		_OwningPlayer       = OwningPlayer,
		_SequenceNumber     = 0,
		_SnapshotTimer      = 0,
		_Destroyed          = false,
		_OnIntentReceived   = OnIntentReceived,
		_OnSnapshotMismatch = OnSnapshotMismatch,
		_Disconnects        = {},
	}, ReplicationBridge)

	-- ── Server: listen for intents from the owning client ──────────────────
	if IS_SERVER then
		local Disconnect = BlinkNet.SendIntent.On(function(SendingPlayer: Player, Intent: any)
			-- Filter: only handle intents for this character.
			if Intent.CharacterId ~= CharacterId then return end
			Self:_HandleClientIntent(SendingPlayer, Intent)
		end)
		table.insert(Self._Disconnects, Disconnect)

		-- ── Non-owning client: listen for relay intents and snapshots ──────────
	elseif not EffectiveIsOwningClient then
		local DisconnectRelay = BlinkNet.RelayIntent.On(function(Intent: any)
			Self:_HandleIncomingIntent(Intent)
		end)
		table.insert(Self._Disconnects, DisconnectRelay)

		local DisconnectSnapshot = BlinkNet.SendSnapshot.On(function(Snapshot: any)
			Self:_HandleSnapshot(Snapshot)
		end)
		table.insert(Self._Disconnects, DisconnectSnapshot)

		-- Owning client intentionally does NOT subscribe to RelayIntent or
		-- SendSnapshot. It is its own authority; receiving echoes of its own
		-- state would trigger false reconciliation (Bug P fix, preserved).
	end

	return Self
end

-- ─── Intent Sending (Owning Client Only) ─────────────────────────────────────

--[=[
    QueueIntent

    Calls BlinkNet.SendIntent.Fire directly. Blink batches writes internally
    and flushes to the server on Heartbeat — no manual pool or queue needed.

    The old intent pool (32 pre-allocated slots, cursor scan) is gone. Blink's
    buffer management handles allocation more efficiently than the hand-rolled
    pool did, and the pool logic was a source of subtle corruption bugs (Bug S).
]=]
function ReplicationBridge:QueueIntent(
	AnimationName : string,
	Action        : "PLAY" | "STOP"
)
	if self._Destroyed then return end
	if not self._IsOwningClient then return end

	-- Map PLAY/STOP → Blink enum strings Play/Stop.
	local BlinkAction: "Play" | "Stop" = if Action == "PLAY" then "Play" else "Stop"

	BlinkNet.SendIntent.Fire({
		CharacterId   = self._CharacterId,
		AnimationName = AnimationName,
		Action        = BlinkAction,
		Timestamp     = workspace:GetServerTimeNow(),
	})
end

-- ─── Per-Tick Flush ───────────────────────────────────────────────────────────

--[=[
    Flush

    Owning client: no-op. Blink flushes its write buffer on Heartbeat automatically.

    Server: advances the snapshot timer and broadcasts a full state snapshot to
    all clients except the owning player when the interval elapses.

    Parameters:
        Dt               : number  — Frame delta time in seconds.
        CurrentStateName : string  — Current FSM state for the snapshot.
        ActiveGroupAnims : { [string]: string } — Group → animation map for snapshot.
]=]
function ReplicationBridge:Flush(
	Dt               : number,
	CurrentStateName : string,
	ActiveGroupAnims : { [string]: string }
)
	if self._Destroyed then return end
	if not self._IsServer then return end

	self._SnapshotTimer += Dt

	if self._SnapshotTimer < SNAPSHOT_INTERVAL_SECONDS then return end
	self._SnapshotTimer = 0

	-- FireExcept: the owning player already has authoritative state and must
	-- not receive snapshots (would trigger false reconciliation — Bug P fix).
	if self._OwningPlayer then
		BlinkNet.SendSnapshot.FireExcept(self._OwningPlayer, {
			StateName        = CurrentStateName,
			ActiveGroupAnims = ActiveGroupAnims,
			SequenceNumber   = self._SequenceNumber,
			ServerTime       = workspace:GetServerTimeNow(),
		})
	else
		-- Fallback: no owning player known (e.g. NPC), broadcast to all.
		BlinkNet.SendSnapshot.FireAll({
			StateName        = CurrentStateName,
			ActiveGroupAnims = ActiveGroupAnims,
			SequenceNumber   = self._SequenceNumber,
			ServerTime       = workspace:GetServerTimeNow(),
		})
	end
end

-- ─── Server: Receiving Intents From the Owning Client ────────────────────────

function ReplicationBridge:_HandleClientIntent(SendingPlayer: Player, Intent: any)
	if self._Destroyed then return end

	-- Ownership check: the sending player must own this character.
	local SenderCharacter = SendingPlayer.Character
	local IsOwnerVerified = SenderCharacter and SenderCharacter.Name == self._CharacterId

	if not IsOwnerVerified then
		warn(string.format(
			"[ReplicationBridge] Rejected intent from %s for character '%s' — ownership check failed.",
			SendingPlayer.Name,
			self._CharacterId
			))
		return
	end

	local IntentAgeSeconds = workspace:GetServerTimeNow() - Intent.Timestamp
	if IntentAgeSeconds > STALE_INTENT_THRESHOLD_SECONDS then
		warn(string.format(
			"[ReplicationBridge] Discarding stale intent '%s' from %s (age %.2fs)",
			Intent.AnimationName,
			SendingPlayer.Name,
			IntentAgeSeconds
			))
		return
	end

	self._SequenceNumber += 1

	-- Relay to all other clients. FireExcept skips the sender — they already
	-- played the animation locally and must not receive an echo of their own intent.
	BlinkNet.RelayIntent.FireExcept(SendingPlayer, {
		AnimationName = Intent.AnimationName,
		Action        = Intent.Action,
		Timestamp     = Intent.Timestamp,
	})
end

-- ─── Non-Owning Clients: Receiving Relay Intents ─────────────────────────────

function ReplicationBridge:_HandleIncomingIntent(Intent: any)
	if self._Destroyed then return end

	-- Mirror the server sequence counter so snapshot comparisons stay in lockstep.
	self._SequenceNumber += 1

	if self._OnIntentReceived then
		-- Map Blink enum back to the internal PLAY/STOP strings AnimationController expects.
		self._OnIntentReceived({
			CharacterId   = self._CharacterId,
			AnimationName = Intent.AnimationName,
			Action        = if Intent.Action == "Play" then "PLAY" else "STOP",
			Timestamp     = Intent.Timestamp,
		})
	end
end

-- ─── Snapshot Handling ────────────────────────────────────────────────────────

function ReplicationBridge:_HandleSnapshot(Snapshot: any)
	if self._Destroyed then return end

	local PreviousSequence = self._SequenceNumber
	-- Always sync to the server value so future comparisons start from the
	-- correct baseline regardless of whether reconciliation fires.
	self._SequenceNumber = Snapshot.SequenceNumber

	if Snapshot.SequenceNumber ~= PreviousSequence then
		warn(string.format(
			"[ReplicationBridge] Sequence mismatch for '%s': local=%d server=%d. Reconciling.",
			self._CharacterId,
			PreviousSequence,
			Snapshot.SequenceNumber
			))
		if self._OnSnapshotMismatch then
			self._OnSnapshotMismatch(Snapshot)
		end
	end
end

-- ─── Sequence Management ──────────────────────────────────────────────────────

function ReplicationBridge:IncrementSequence()
	self._SequenceNumber += 1
end

function ReplicationBridge:GetSequenceNumber(): number
	return self._SequenceNumber
end

-- ─── Destruction ──────────────────────────────────────────────────────────────

function ReplicationBridge:Destroy()
	if self._Destroyed then return end
	self._Destroyed = true

	-- Call every Blink disconnect function returned by .On registrations.
	for _, Disconnect in self._Disconnects do
		Disconnect()
	end
	table.clear(self._Disconnects)
end

return ReplicationBridge