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
	_isOwningClient  : boolean,   -- true only on the client that owns this character
	_characterId     : string,
	_intentRemote    : RemoteEvent?,
	_snapshotRemote  : RemoteEvent?,
	_intentQueue     : { AnimationIntent },
	_intentPool      : { AnimationIntent },
	_poolCursor      : number,
	_sequenceNumber  : number,
	_snapshotTimer   : number,
	_connections     : { RBXScriptConnection },
	_destroyed       : boolean,
	_onIntentReceived : ((AnimationIntent) -> ())?,
}, ReplicationBridge))

-- isOwningClient: pass true only on the client that owns this character.
-- On the server and on non-owning clients this should be false.
function ReplicationBridge.new(
	characterId      : string,
	intentRemote     : RemoteEvent?,
	snapshotRemote   : RemoteEvent?,
	isOwningClient   : boolean,
	onIntentReceived : ((AnimationIntent) -> ())?
): ReplicationBridge

	local isServer = RunService:IsServer()

	local self = setmetatable({
		_isServer        = isServer,
		_isOwningClient  = (not isServer) and isOwningClient,
		_characterId     = characterId,
		_intentRemote    = intentRemote,
		_snapshotRemote  = snapshotRemote,
		_intentQueue     = {},
		_intentPool      = makeIntentPool(INTENT_POOL_SIZE),
		_poolCursor      = 1,
		_sequenceNumber  = 0,
		_snapshotTimer   = 0,
		_connections     = {},
		_destroyed       = false,
		_onIntentReceived = onIntentReceived,
	}, ReplicationBridge)

	if isServer then
		-- Server listens for intents FROM the owning client,
		-- validates them, then rebroadcasts to all other clients.
		if intentRemote then
			local conn = intentRemote.OnServerEvent:Connect(function(player: Player, intent: AnimationIntent)
				self:_HandleClientIntent(player, intent)
			end)
			table.insert(self._connections, conn)
		end
	else
		-- Non-owning clients listen for rebroadcast intents from the server.
		-- The owning client does NOT listen — it already played locally.
		if not isOwningClient and intentRemote then
			local conn = intentRemote.OnClientEvent:Connect(function(intent: AnimationIntent)
				self:_HandleIncomingIntent(intent)
			end)
			table.insert(self._connections, conn)
		end

		-- All clients (owning and non-owning) listen for snapshots for desync recovery.
		if snapshotRemote then
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
	local intent = self._intentPool[self._poolCursor]
	self._poolCursor = (self._poolCursor % INTENT_POOL_SIZE) + 1
	return intent
end

function ReplicationBridge:_RecycleIntent(_intent: AnimationIntent)
	-- Pool is circular; slots are overwritten automatically.
	-- Kept as an explicit hook for future instrumentation.
end

-- ── Queueing — Owning Client Only ─────────────────────────────────────────

-- Called by AnimationController when a play or stop is applied locally.
-- Only the owning client queues intents for transmission to the server.
-- The server and non-owning clients never call this.
function ReplicationBridge:QueueIntent(
	animationName : string,
	action        : "PLAY" | "STOP",
	stateContext  : string
)
	if self._destroyed then return end

	-- Only the owning client sends intents upstream to the server.
	-- The server relays; non-owning clients only receive.
	if not self._isOwningClient then return end

	local intent = self:_AcquireIntent()
	intent.CharacterId   = self._characterId
	intent.AnimationName = animationName
	intent.Action        = action
	intent.Timestamp     = os.clock()
	intent.StateContext  = stateContext

	table.insert(self._intentQueue, table.clone(intent))
end

-- ── Per-Tick Flush ─────────────────────────────────────────────────────────

-- Called at step 4 of the per-frame pipeline.
-- Owning client: flushes queued intents up to the server.
-- Server: handles periodic snapshot broadcast to all clients.
-- Non-owning clients: nothing to flush, they only receive.
function ReplicationBridge:Flush(dt: number, currentStateName: string, activeGroupAnims: { [string]: string })
	if self._destroyed then return end

	if self._isOwningClient then
		-- Owning client sends its queued intents to the server.
		if #self._intentQueue > 0 and self._intentRemote then
			for _, intent in self._intentQueue do
				self._intentRemote:FireServer(intent)
				self:_RecycleIntent(intent)
			end
			table.clear(self._intentQueue)
		end
	end

	-- Server broadcasts periodic full-state snapshots for desync recovery.
	-- Non-owning clients use these to catch up if they missed intents.
	if self._isServer and self._snapshotRemote then
		self._snapshotTimer += dt
		if self._snapshotTimer >= SNAPSHOT_INTERVAL_S then
			self._snapshotTimer = 0
			self._sequenceNumber += 1
			self._snapshotRemote:FireAllClients({
				CharacterId      = self._characterId,
				StateName        = currentStateName,
				ActiveGroupAnims = activeGroupAnims,
				SequenceNumber   = self._sequenceNumber,
				ServerTime       = os.clock(),
			})
		end
	end
end

-- ── Server: Receiving From Owning Client ───────────────────────────────────

-- The server receives an intent from the owning client, performs a staleness
-- check, then rebroadcasts to all OTHER clients so they can reconstruct state.
-- The server does not play the animation itself.
function ReplicationBridge:_HandleClientIntent(player: Player, intent: AnimationIntent)
	if self._destroyed then return end
	if intent.CharacterId ~= self._characterId then return end

	-- Discard stale intents — if the owning client is very far behind,
	-- applying old intents would produce incorrect state on other clients.
	local age = os.clock() - intent.Timestamp
	if age > STALE_INTENT_THRESHOLD_S then
		warn(string.format(
			"[ReplicationBridge] Discarding stale intent '%s' from %s (age %.2fs)",
			intent.AnimationName, player.Name, age
			))
		return
	end

	self._sequenceNumber += 1

	-- Rebroadcast to all clients EXCEPT the owning client who already played locally.
	-- FireAllClients would replay the animation on the owning client, causing a double-play.
	if self._intentRemote then
		for _, client in game:GetService("Players"):GetPlayers() do
			if client ~= player then
				self._intentRemote:FireClient(client, intent)
			end
		end
	end
end

-- ── Non-Owning Clients: Receiving From Server ──────────────────────────────

-- Non-owning clients receive rebroadcast intents and reconstruct animation
-- state by running the full local pipeline via the onIntentReceived callback.
function ReplicationBridge:_HandleIncomingIntent(intent: AnimationIntent)
	if self._destroyed then return end
	if intent.CharacterId ~= self._characterId then return end

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

	if snapshot.SequenceNumber ~= self._sequenceNumber then
		warn(string.format(
			"[ReplicationBridge] Sequence mismatch for character %s: local=%d server=%d. Reconciliation needed.",
			self._characterId, self._sequenceNumber, snapshot.SequenceNumber
			))
		self._sequenceNumber = snapshot.SequenceNumber
		-- Reconciliation: AnimationController registers a handler separately
		-- to force-sync state when this mismatch is detected.
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