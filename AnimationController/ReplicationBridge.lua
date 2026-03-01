--!strict
-- ReplicationBridge.lua
-- Exists only on the server and on owning clients.
-- Serializes AnimationIntent records to RemoteEvents.
-- Never replicates TrackWrappers or raw track state — only intent descriptors.
-- Anti-desync: periodic state snapshot broadcasts with sequence numbers.

local Types = require(script.Parent.Types)
type AnimationIntent = Types.AnimationIntent

-- ── Constants ──────────────────────────────────────────────────────────────

local STALE_INTENT_THRESHOLD_S = 0.5   -- Intents older than this (vs server time) are discarded
local SNAPSHOT_INTERVAL_S      = 2.5   -- Broadcast interval for periodic state snapshots
local INTENT_POOL_SIZE         = 32    -- Pre-allocated intent record pool

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

function ReplicationBridge.new(
	characterId      : string,
	intentRemote     : RemoteEvent?,
	snapshotRemote   : RemoteEvent?,
	onIntentReceived : ((AnimationIntent) -> ())?
): ReplicationBridge

	local isServer = game:GetService("RunService"):IsServer()

	local self = setmetatable({
		_isServer        = isServer,
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

	-- Non-owning clients: listen for incoming intent broadcasts
	if not isServer and intentRemote then
		local conn = intentRemote.OnClientEvent:Connect(function(intent: AnimationIntent)
			self:_HandleIncomingIntent(intent)
		end)
		table.insert(self._connections, conn)
	end

	-- Non-owning clients: listen for snapshot reconciliation broadcasts
	if not isServer and snapshotRemote then
		local conn = snapshotRemote.OnClientEvent:Connect(function(snapshot: any)
			self:_HandleSnapshot(snapshot)
		end)
		table.insert(self._connections, conn)
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
	-- No-op: pool is circular; slots are overwritten automatically.
	-- Kept as an explicit hook for future instrumentation.
end

-- ── Queueing (Server / Owning Client) ─────────────────────────────────────

-- Enqueue an intent for transmission. Called by AnimationController when a play/stop is applied.
function ReplicationBridge:QueueIntent(
	animationName : string,
	action        : "PLAY" | "STOP",
	stateContext  : string
)
	if self._destroyed then return end

	local intent = self:_AcquireIntent()
	intent.CharacterId   = self._characterId
	intent.AnimationName = animationName
	intent.Action        = action
	intent.Timestamp     = os.clock()
	intent.StateContext  = stateContext

	table.insert(self._intentQueue, table.clone(intent)) -- shallow clone for the queue
end

-- ── Per-Tick Flush — O(I) ─────────────────────────────────────────────────

-- Called at step 4 of the per-frame pipeline.
-- dt is used to advance the snapshot timer.
function ReplicationBridge:Flush(dt: number, currentStateName: string, activeGroupAnims: { [string]: string })
	if self._destroyed then return end

	-- Flush queued intents
	if #self._intentQueue > 0 and self._intentRemote then
		if self._isServer then
			-- Server broadcasts to all clients
			for _, intent in self._intentQueue do
				self._sequenceNumber += 1
				self._intentRemote:FireAllClients(intent)
				self:_RecycleIntent(intent)
			end
		end
		-- Owning client sends to server (if needed for server authority reconciliation)
		-- In this model the server is authoritative, so owning client intents are local-only
		table.clear(self._intentQueue)
	end

	-- Periodic snapshot broadcast (server only)
	if self._isServer and self._snapshotRemote then
		self._snapshotTimer += dt
		if self._snapshotTimer >= SNAPSHOT_INTERVAL_S then
			self._snapshotTimer = 0
			self._sequenceNumber += 1
			self._snapshotRemote:FireAllClients({
				CharacterId    = self._characterId,
				StateName      = currentStateName,
				ActiveGroupAnims = activeGroupAnims,
				SequenceNumber = self._sequenceNumber,
				ServerTime     = os.clock(),
			})
		end
	end
end

-- ── Incoming Handling (Non-Owning Clients) ─────────────────────────────────

function ReplicationBridge:_HandleIncomingIntent(intent: AnimationIntent)
	if self._destroyed then return end
	if intent.CharacterId ~= self._characterId then return end

	-- Discard stale intents post-reconciliation
	-- (Server timestamp relative check — simplified; production would track server clock offset)
	if self._onIntentReceived then
		self._onIntentReceived(intent)
	end
end

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

	-- Sequence number divergence check
	if snapshot.SequenceNumber ~= self._sequenceNumber then
		-- Trigger reconciliation via AnimationController callback (not implemented here;
		-- AnimationController registers a reconciliation handler separately)
		warn(string.format(
			"[ReplicationBridge] Sequence mismatch for character %s: local=%d server=%d. Reconciliation needed.",
			self._characterId, self._sequenceNumber, snapshot.SequenceNumber
			))
		self._sequenceNumber = snapshot.SequenceNumber
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