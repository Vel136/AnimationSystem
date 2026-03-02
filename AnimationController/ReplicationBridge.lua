--!strict
-- ReplicationBridge.lua
--
-- Authority model:
--   • The OWNING CLIENT is authoritative over its own character's animations.
--     It plays animations locally in response to its own input and game logic,
--     then notifies the server of what it did via the intent remote.
--
--   • The SERVER receives intents from the owning client, validates them
--     (sequence check, stale threshold), and rebroadcasts to all OTHER clients.
--     The server never plays animations itself — it is a relay and authority check.
--
--   • NON-OWNING CLIENTS receive rebroadcast intents from the server and
--     reconstruct animation state locally by running the full play pipeline.
--     They also receive periodic snapshots for desync recovery.
--
-- Never replicates TrackWrappers or raw track state — only intent descriptors.

local RunService = game:GetService("RunService")
local Types      = require(script.Parent.Types)

type AnimationIntent = Types.AnimationIntent

-- ── Constants ──────────────────────────────────────────────────────────────

local STALE_INTENT_THRESHOLD_S = 0.5   -- Intents older than this are discarded on the server
local SNAPSHOT_INTERVAL_S      = 2.5   -- How often the server broadcasts a full state snapshot
local INTENT_POOL_SIZE         = 32    -- Pre-allocated intent record pool size

-- ── Intent Pool ────────────────────────────────────────────────────────────

local function makeIntentPool(size: number): { AnimationIntent }
	local pool = table.create(size)
	for i = 1, size do
		pool[i] = {
			CharacterId   = "",
			AnimationName = "",
			Action        = "PLAY",
			Timestamp     = 0,
			StateContext  = "",
		}
	end
	return pool
end

-- ── ReplicationBridge ──────────────────────────────────────────────────────

local ReplicationBridge = {}
ReplicationBridge.__index = ReplicationBridge

export type ReplicationBridge = typeof(setmetatable({} :: {
	_isServer        : boolean,
	_isOwningClient  : boolean,
	_characterId     : string,
	_intentRemote    : RemoteEvent?,
	_snapshotRemote  : RemoteEvent?,
	_intentQueue     : { AnimationIntent },
	_intentPool      : { AnimationIntent },
	_poolCursor      : number,
	_sequenceNumber  : number,
	_snapshotTimer   : number,
	_connections     : { RBXScriptConnection },
	_onSnapshotMismatch : ((snapshot: SnapshotData) -> ())?,
	_destroyed       : boolean,
	_onIntentReceived : ((AnimationIntent) -> ())?,
}, ReplicationBridge))

-- isOwningClient: pass true only on the client that owns this character.
function ReplicationBridge.new(
	characterId        : string,
	intentRemote       : RemoteEvent?,
	snapshotRemote     : RemoteEvent?,
	isOwningClient     : boolean,
	onIntentReceived   : ((AnimationIntent) -> ())?,
	onSnapshotMismatch : ((any) -> ())?
): ReplicationBridge

	local isServer = RunService:IsServer()

	-- Bug #7 fix: _onSnapshotMismatch was accepted as a parameter but never
	-- assigned to the instance. The field existed in the type declaration and
	-- _HandleSnapshot called it, but because the assignment was missing the
	-- callback was always nil and snapshot reconciliation never fired.
	local self = setmetatable({
		_isServer           = isServer,
		_isOwningClient     = (not isServer) and isOwningClient,
		_characterId        = characterId,
		_intentRemote       = intentRemote,
		_snapshotRemote     = snapshotRemote,
		_intentQueue        = {},
		_intentPool         = makeIntentPool(INTENT_POOL_SIZE),
		_poolCursor         = 1,
		_sequenceNumber     = 0,
		_snapshotTimer      = 0,
		_connections        = {},
		_destroyed          = false,
		_onIntentReceived   = onIntentReceived,
		_onSnapshotMismatch = onSnapshotMismatch,  -- was missing in original
	}, ReplicationBridge)

	if isServer then
		if intentRemote then
			local conn = intentRemote.OnServerEvent:Connect(function(player: Player, intent: AnimationIntent)
				self:_HandleClientIntent(player, intent)
			end)
			table.insert(self._connections, conn)
		end
	else
		if not isOwningClient and intentRemote then
			local conn = intentRemote.OnClientEvent:Connect(function(intent: AnimationIntent)
				self:_HandleIncomingIntent(intent)
			end)
			table.insert(self._connections, conn)
		end

		-- Bug P fix: the owning client must NOT subscribe to the snapshot remote.
		-- The owning client is the animation authority for its own character — it
		-- plays animations in response to its own input and sends intents to the
		-- server. The server's snapshot reflects what the owning client told it,
		-- with a delay. If the owning client subscribed, it would compare its
		-- always-zero local sequence number against the server's ever-incrementing
		-- one, trigger _OnSnapshotMismatch every 2.5 seconds, and wipe all its
		-- correctly-playing animations. Only non-owning clients need reconciliation.
		if not isOwningClient and snapshotRemote then
			local conn = snapshotRemote.OnClientEvent:Connect(function(snapshot: any)
				self:_HandleSnapshot(snapshot)
			end)
			table.insert(self._connections, conn)
		end
	end

	return self
end

-- ── Intent Pooling ─────────────────────────────────────────────────────────

function ReplicationBridge:_AcquireIntent(): AnimationIntent
	-- Bug S fix: pool slots written directly into _intentQueue (bug O fix) are
	-- shared mutable objects. If QueueIntent is called enough times in one tick
	-- to wrap the cursor before Flush drains the queue, the cursor lands on a slot
	-- that is still in _intentQueue and overwrites it before it is sent.
	-- Fix: scan forward from the current cursor position to find a slot that is
	-- not currently queued. In the worst case (queue full) we fall back to a fresh
	-- table allocation rather than corrupting an in-flight intent.
	local startCursor = self._poolCursor
	local size = INTENT_POOL_SIZE
	for i = 0, size - 1 do
		local idx = ((startCursor - 1 + i) % size) + 1
		local slot = self._intentPool[idx]
		-- Check whether this slot is already sitting in the queue.
		local inFlight = false
		for _, queued in self._intentQueue do
			if queued == slot then
				inFlight = true
				break
			end
		end
		if not inFlight then
			self._poolCursor = (idx % size) + 1
			return slot
		end
	end
	-- All pool slots are in-flight (more QueueIntent calls than pool size in one tick).
	-- Allocate a fresh table so we never corrupt queued intents.
	return {
		CharacterId   = "",
		AnimationName = "",
		Action        = "PLAY",
		Timestamp     = 0,
		StateContext  = "",
	}
end

function ReplicationBridge:_RecycleIntent(_intent: AnimationIntent)
	-- Pool is circular; slots are overwritten automatically.
end

-- ── Queueing — Owning Client Only ─────────────────────────────────────────

function ReplicationBridge:QueueIntent(
	animationName : string,
	action        : "PLAY" | "STOP",
	stateContext  : string
)
	if self._destroyed then return end
	if not self._isOwningClient then return end

	-- Bug O fix: the original code acquired a pool slot, mutated it, then
	-- immediately called table.clone to insert into the queue — allocating a new
	-- table on every call and making the pool completely pointless. The pool was
	-- designed to pre-allocate intent records and reuse them across frames.
	-- Fix: write directly into the queue using a pre-allocated slot from the pool.
	-- Flush consumes and clears the queue each tick, so pool slots are safe to
	-- reuse once the queue is drained. We track queue size separately from the
	-- pool cursor so concurrent calls within a tick each get their own slot.
	local intent = self:_AcquireIntent()
	intent.CharacterId   = self._characterId
	intent.AnimationName = animationName
	intent.Action        = action
	-- Bug A fix: was os.clock() (process uptime), which is independent per machine.
	-- Server's os.clock() and client's os.clock() have no relationship, making the
	-- age calculation in _HandleClientIntent meaningless. workspace:GetServerTimeNow()
	-- returns a synchronized timestamp on both client and server so the comparison is valid.
	intent.Timestamp     = workspace:GetServerTimeNow()
	intent.StateContext  = stateContext

	table.insert(self._intentQueue, intent)
end

-- ── Per-Tick Flush ─────────────────────────────────────────────────────────

function ReplicationBridge:Flush(dt: number, currentStateName: string, activeGroupAnims: { [string]: string })
	if self._destroyed then return end

	if self._isOwningClient then
		if #self._intentQueue > 0 and self._intentRemote then
			for _, intent in self._intentQueue do
				self._intentRemote:FireServer(intent)
				self:_RecycleIntent(intent)
			end
			table.clear(self._intentQueue)
		end
	end

	if self._isServer and self._snapshotRemote then
		self._snapshotTimer += dt
		if self._snapshotTimer >= SNAPSHOT_INTERVAL_S then
			self._snapshotTimer = 0
			-- Bug fix: do NOT increment _sequenceNumber here. Snapshots are
			-- checkpoints, not sequence events — only intents advance the counter.
			-- The client mirrors the server's counter via _HandleIncomingIntent (+1
			-- per relayed intent). If the server also bumps for each snapshot, the
			-- client's counter is always 1 behind, so _HandleSnapshot sees
			-- (snapshotSeq ~= prevSeq) as permanently true and fires
			-- _onSnapshotMismatch every 2.5 seconds, wiping all correctly-playing
			-- animations on every non-owning client. Broadcasting the current
			-- (un-bumped) value means delta=0 on a clean round and delta=N on N
			-- dropped intents, which is the intended behaviour.
			self._snapshotRemote:FireAllClients({
				CharacterId      = self._characterId,
				StateName        = currentStateName,
				ActiveGroupAnims = activeGroupAnims,
				SequenceNumber   = self._sequenceNumber,
				ServerTime       = workspace:GetServerTimeNow(),
			})
		end
	end
end

-- ── Server: Receiving From Owning Client ───────────────────────────────────

function ReplicationBridge:_HandleClientIntent(player: Player, intent: AnimationIntent)
	if self._destroyed then return end
	if intent.CharacterId ~= self._characterId then return end

	-- Bug 5 fix: verify the sending player actually owns this character.
	-- Without this, any client that knows another character's ID can drive
	-- their animations. Check the player's Character's Name against CharacterId.
	-- NOTE: This assumes CharacterId is set to the character's Instance Name
	-- (typically the player's username in Roblox). If your game uses a different
	-- scheme for CharacterId (e.g. UserId as string, or a GUID), update this
	-- check accordingly to match your identity convention.
	local character = player.Character
	if not character or character.Name ~= self._characterId then
		warn(string.format(
			"[ReplicationBridge] Rejected intent from %s for character '%s' — player does not own that character.",
			player.Name, self._characterId
			))
		return
	end

	local age = workspace:GetServerTimeNow() - intent.Timestamp
	if age > STALE_INTENT_THRESHOLD_S then
		warn(string.format(
			"[ReplicationBridge] Discarding stale intent '%s' from %s (age %.2fs)",
			intent.AnimationName, player.Name, age
			))
		return
	end

	self._sequenceNumber += 1

	if self._intentRemote then
		for _, client in game:GetService("Players"):GetPlayers() do
			if client ~= player then
				self._intentRemote:FireClient(client, intent)
			end
		end
	end
end

-- ── Non-Owning Clients: Receiving From Server ──────────────────────────────

function ReplicationBridge:_HandleIncomingIntent(intent: AnimationIntent)
	if self._destroyed then return end
	if intent.CharacterId ~= self._characterId then return end

	-- Bug T fix: the non-owning client never incremented _sequenceNumber when
	-- successfully receiving a rebroadcast intent. The server increments its counter
	-- on every accepted intent, so the non-owning client's counter immediately fell
	-- behind and _HandleSnapshot saw a mismatch on virtually every snapshot, triggering
	-- full reconciliation even when the client was perfectly in sync.
	-- Fix: mirror the server's increment here so the counters stay in lockstep under
	-- normal operation. Reconciliation then only triggers on genuine gaps (dropped intents).
	self._sequenceNumber += 1

	if self._onIntentReceived then
		self._onIntentReceived(intent)
	end
end

-- ── Snapshot Handling — All Clients ───────────────────────────────────────

type SnapshotData = {
	CharacterId      : string,
	StateName        : string,
	ActiveGroupAnims : { [string]: string },
	SequenceNumber   : number,
	ServerTime       : number,
}

function ReplicationBridge:_HandleSnapshot(snapshot: SnapshotData)
	if self._destroyed then return end
	if snapshot.CharacterId ~= self._characterId then return end

	-- Fix: always sync the local counter to the server's value regardless of whether
	-- they match. Only intents increment the sequence number (both server-side on
	-- receipt and client-side on relay). Snapshots do NOT increment it.
	-- Non-owning clients mirror intent increments, so under normal operation their
	-- counter stays in lockstep with the server's. A mismatch here means dropped
	-- intents — genuine desync — and reconciliation is warranted.
	local prevSeq = self._sequenceNumber
	self._sequenceNumber = snapshot.SequenceNumber

	if snapshot.SequenceNumber ~= prevSeq then
		warn(string.format(
			"[ReplicationBridge] Sequence mismatch for character %s: local=%d server=%d. Reconciling.",
			self._characterId, prevSeq, snapshot.SequenceNumber
			))
		-- Bug #7 fix: this callback was always nil in the original because the
		-- constructor never stored it. Now correctly fires AnimationController's
		-- _OnSnapshotMismatch for desync recovery.
		if self._onSnapshotMismatch then
			self._onSnapshotMismatch(snapshot)
		end
	end
end

-- ── Sequence Management ────────────────────────────────────────────────────

function ReplicationBridge:IncrementSequence()
	self._sequenceNumber += 1
end

function ReplicationBridge:GetSequenceNumber(): number
	return self._sequenceNumber
end

-- ── Destruction ────────────────────────────────────────────────────────────

function ReplicationBridge:Destroy()
	if self._destroyed then return end
	self._destroyed = true
	for _, conn in self._connections do
		conn:Disconnect()
	end
	table.clear(self._connections)
	table.clear(self._intentQueue)
end

return ReplicationBridge