--!strict
-- ─── ReplicationBridge.lua ────────────────────────────────────────────────────
--[[
    ReplicationBridge implements the three-role replication model for the animation
    system. It handles all network communication and desync recovery without ever
    touching a TrackWrapper or AnimationTrack directly.

    ── Authority Model ──────────────────────────────────────────────────────────

    Owning Client (IsOwningClient = true, IsServer = false):
        The only machine that directly responds to input and plays animations.
        Every animation decision originates here. After playing, it packages the
        action into an AnimationIntent and sends it to the server via the intent
        remote. It does NOT listen to the snapshot remote — it is the authority
        over its own character and should never reconcile against itself.

    Server (IsServer = true):
        Receives intents from the owning client, validates them (ownership check,
        stale threshold), then rebroadcasts to all OTHER clients. The server never
        plays animations. It also broadcasts periodic full-state snapshots so that
        non-owning clients can recover from dropped packets.

    Non-Owning Clients (IsOwningClient = false, IsServer = false):
        Receive rebroadcast intents from the server and reconstruct animation state
        locally by running the full AnimationController play pipeline. They also
        receive snapshots and trigger reconciliation if their local sequence counter
        drifts from the server's.

    ── Sequence Numbers and Desync Detection ────────────────────────────────────

    Every accepted intent increments a shared sequence counter on both the server
    and (via mirroring) on each non-owning client. Snapshots carry the server's
    current counter. A non-owning client whose local counter differs from the
    snapshot counter has dropped at least one intent and triggers reconciliation.

    Snapshots themselves do NOT increment the counter — only intents do. This
    ensures that the baseline for comparison is the number of processed intents,
    not the number of heartbeats, and that a perfectly synced client sees delta=0
    on every snapshot.

    ── What Is Never Replicated ─────────────────────────────────────────────────

    TrackWrappers, AnimationTrack handles, EffectiveWeights, and all internal
    controller state are strictly local to each machine. Only intent descriptors
    (animation name, action, timestamp, state context) and summary snapshots
    (current state name, active group animations, sequence number) cross the wire.
]]

local RunService = game:GetService("RunService")
local Types      = require(script.Parent.Types)

type AnimationIntent = Types.AnimationIntent

-- ─── Constants ────────────────────────────────────────────────────────────────

--[[
    STALE_INTENT_THRESHOLD_SECONDS:
        Intents older than this value (in seconds of server time) are discarded on
        the server without being rebroadcast. This prevents replaying stale inputs
        from a client that lagged or had a connection hiccup. 0.5 seconds is a
        generous window — a well-connected client sends intents within a few
        milliseconds of the local play call. Packets older than this are almost
        certainly from a frozen or reconnecting client.
]]
local STALE_INTENT_THRESHOLD_SECONDS = 0.5

--[[
    SNAPSHOT_INTERVAL_SECONDS:
        How often (in seconds) the server broadcasts a full state snapshot to all
        clients. 2.5 seconds is a balance between network bandwidth and recovery
        latency. A lower value speeds up desync detection but increases per-client
        bandwidth; a higher value reduces bandwidth but means a client that drops
        several intents in a row may display incorrect animations for longer before
        reconciling.
]]
local SNAPSHOT_INTERVAL_SECONDS = 2.5

--[[
    INTENT_POOL_SIZE:
        Number of AnimationIntent records to pre-allocate in the pool. The pool
        eliminates per-intent table allocation on the owning client. 32 slots is
        significantly more than the number of intents a character can realistically
        generate in a single tick (typically 1–4), providing ample headroom for
        burst states like a combo attack.
]]
local INTENT_POOL_SIZE = 32

-- ─── Intent Pool Initialization ───────────────────────────────────────────────

--[[
    MakeIntentPool pre-allocates a fixed array of AnimationIntent tables with
    their fields set to safe default values. Each slot is a reusable record;
    QueueIntent writes into a slot rather than allocating a new table each call.

    Why pre-allocate rather than use metatables or userdata?
    AnimationIntent is a plain data structure with a small, fixed set of string
    and number fields. Pre-allocating tables of this shape is the idiomatic Luau
    pattern for hot-path pools: it avoids GC pressure in the owning client's
    per-frame intent flush loop, where even small allocations can accumulate into
    noticeable stutter on low-memory devices.
]]
local function MakeIntentPool(PoolSize: number): { AnimationIntent }
	local Pool: { AnimationIntent } = table.create(PoolSize)
	for SlotIndex = 1, PoolSize do
		Pool[SlotIndex] = {
			CharacterId   = "",
			AnimationName = "",
			Action        = "PLAY",
			Timestamp     = 0,
			StateContext  = "",
		}
	end
	return Pool
end

-- ─── Snapshot Type ────────────────────────────────────────────────────────────

--[[
    SnapshotData is the structure broadcast by the server every SNAPSHOT_INTERVAL_SECONDS.
    It carries the minimum information needed for a non-owning client to verify
    synchronisation and, if out of sync, reconcile its animation state.

    Fields:
        CharacterId      — Identifies which character this snapshot belongs to.
                           Non-owning clients filter by this to ignore snapshots
                           for other characters on the same remote.
        StateName        — The server-authoritative state machine state name.
                           Used to realign the non-owning client's FSM if it drifted.
        ActiveGroupAnims — Map of group name → animation name for animations currently
                           playing inside an exclusive group. Used to replay the
                           server-authoritative grouped animation set on reconciliation.
        SequenceNumber   — The server's current accepted-intent counter. Compared
                           against the local counter to detect dropped intents.
        ServerTime       — workspace:GetServerTimeNow() when the snapshot was sent.
                           Reserved for future latency compensation; not used in
                           reconciliation logic at this time.
]]
type SnapshotData = {
	CharacterId      : string,
	StateName        : string,
	ActiveGroupAnims : { [string]: string },
	SequenceNumber   : number,
	ServerTime       : number,
}

-- ─── Module Table ─────────────────────────────────────────────────────────────

local ReplicationBridge = {}
ReplicationBridge.__index = ReplicationBridge

-- ─── Exported Type ────────────────────────────────────────────────────────────

export type ReplicationBridge = typeof(setmetatable({} :: {
	_IsServer           : boolean,
	_IsOwningClient     : boolean,
	_CharacterId        : string,
	_IntentRemote       : RemoteEvent?,
	_SnapshotRemote     : RemoteEvent?,
	_IntentQueue        : { AnimationIntent },
	_IntentPool         : { AnimationIntent },
	_PoolCursor         : number,
	_SequenceNumber     : number,
	_SnapshotTimer      : number,
	_Connections        : { RBXScriptConnection },
	_OnSnapshotMismatch : ((Snapshot: SnapshotData) -> ())?,
	_Destroyed          : boolean,
	_OnIntentReceived   : ((AnimationIntent) -> ())?,
}, ReplicationBridge))

-- ─── Constructor ──────────────────────────────────────────────────────────────

--[=[
    ReplicationBridge.New

    Description:
        Constructs and wires up a ReplicationBridge for a specific character.
        Depending on the execution context (server, owning client, non-owning client),
        different remote event connections are established.

    Parameters:
        CharacterId        : string
            A unique identifier for the character this bridge serves. Must match the
            identifier used when the bridge was created on other machines for the same
            character, as all filtering is keyed on this string.

        IntentRemote       : RemoteEvent?
            The remote event used for intent communication.
            - Server: listens via OnServerEvent for intents from the owning client,
              then rebroadcasts to other clients via FireClient.
            - Owning client: fires this remote toward the server (in Flush).
            - Non-owning client: listens via OnClientEvent for rebroadcast intents.
            May be nil in offline/solo scenarios; all remote calls are guarded.

        SnapshotRemote     : RemoteEvent?
            The remote event used for periodic full-state snapshots.
            - Server: fires this remote to all clients in Flush.
            - Non-owning client: listens via OnClientEvent for reconciliation snapshots.
            - Owning client: intentionally NOT subscribed (see Bug P fix notes).
            May be nil in offline/solo scenarios.

        IsOwningClient     : boolean
            True only on the client that owns and drives this character's animations.
            On the server this is always false, even if the value passed is true
            (IsServer takes precedence). This flag controls which remote subscriptions
            are established and whether Flush sends intents or snapshots.

        OnIntentReceived   : ((AnimationIntent) -> ())?
            Callback invoked on non-owning clients when a valid, non-stale intent
            arrives from the server relay. The callback drives AnimationController's
            Play/Stop pipeline to reconstruct the owning client's animation state.

        OnSnapshotMismatch : ((SnapshotData) -> ())?
            Callback invoked on non-owning clients when a snapshot reveals a
            sequence counter mismatch (dropped intents). The callback triggers full
            reconciliation in AnimationController (_OnSnapshotMismatch), which tears
            down current state and replays the server-authoritative animation set.

    Returns:
        ReplicationBridge
            A fully wired instance ready to accept QueueIntent and Flush calls.

    Notes:
        Bug #7 fix context:
            The original constructor accepted OnSnapshotMismatch as a parameter but
            never assigned it to the instance. _HandleSnapshot called the field but
            it was always nil, so snapshot reconciliation never fired on non-owning
            clients. The fix is the explicit _OnSnapshotMismatch assignment below.

        Bug P fix context:
            The owning client must NOT subscribe to the snapshot remote. The owning
            client is the animation authority; the server's snapshot is a delayed
            echo of intents the owning client already sent. Subscribing would cause
            the owning client to compare its always-zero local sequence counter
            against the server's ever-incrementing one, triggering reconciliation
            every 2.5 seconds and wiping all correctly-playing animations.
]=]
function ReplicationBridge.New(
	CharacterId        : string,
	IntentRemote       : RemoteEvent?,
	SnapshotRemote     : RemoteEvent?,
	IsOwningClient     : boolean,
	OnIntentReceived   : ((AnimationIntent) -> ())?,
	OnSnapshotMismatch : ((any) -> ())?
): ReplicationBridge

	local IsServer = RunService:IsServer()

	-- On the server, IsOwningClient is always false regardless of what was passed.
	-- The server never drives animations for any character.
	local EffectiveIsOwningClient = (not IsServer) and IsOwningClient

	-- Bug #7 fix: explicitly assign _OnSnapshotMismatch. Previously missing.
	local Self = setmetatable({
		_IsServer           = IsServer,
		_IsOwningClient     = EffectiveIsOwningClient,
		_CharacterId        = CharacterId,
		_IntentRemote       = IntentRemote,
		_SnapshotRemote     = SnapshotRemote,
		_IntentQueue        = {} :: { AnimationIntent },
		_IntentPool         = MakeIntentPool(INTENT_POOL_SIZE),
		_PoolCursor         = 1,
		_SequenceNumber     = 0,
		_SnapshotTimer      = 0,
		_Connections        = {} :: { RBXScriptConnection },
		_Destroyed          = false,
		_OnIntentReceived   = OnIntentReceived,
		_OnSnapshotMismatch = OnSnapshotMismatch,
	}, ReplicationBridge)

	-- ── Server: subscribe to incoming intents from the owning client ───────
	if IsServer then
		if IntentRemote then
			local ServerEventConnection = IntentRemote.OnServerEvent:Connect(
				function(SendingPlayer: Player, IncomingIntent: AnimationIntent)
					Self:_HandleClientIntent(SendingPlayer, IncomingIntent)
				end
			)
			table.insert(Self._Connections, ServerEventConnection)
		end

		-- ── Client: subscribe based on ownership role ──────────────────────────
	else
		if not IsOwningClient and IntentRemote then
			-- Non-owning clients receive relayed intents from the server and run
			-- them through the full AnimationController pipeline to reconstruct
			-- the owning client's visual state locally.
			local ClientIntentConnection = IntentRemote.OnClientEvent:Connect(
				function(RelayedIntent: AnimationIntent)
					Self:_HandleIncomingIntent(RelayedIntent)
				end
			)
			table.insert(Self._Connections, ClientIntentConnection)
		end

		-- Bug P fix: ONLY subscribe the non-owning client to the snapshot remote.
		-- The owning client is its own authority; receiving a snapshot of its own
		-- state with a stale sequence counter would trigger false reconciliation.
		if not IsOwningClient and SnapshotRemote then
			local ClientSnapshotConnection = SnapshotRemote.OnClientEvent:Connect(
				function(IncomingSnapshot: any)
					Self:_HandleSnapshot(IncomingSnapshot)
				end
			)
			table.insert(Self._Connections, ClientSnapshotConnection)
		end
	end

	return Self
end

-- ─── Intent Pool Management ───────────────────────────────────────────────────

--[=[
    _AcquireIntent

    Description:
        Returns a pre-allocated AnimationIntent record from the pool for the caller
        to write intent data into before inserting into the queue.

        The cursor scans forward from its current position to find a pool slot that
        is not currently in the _IntentQueue. This prevents the cursor from wrapping
        around and handing out a slot that is still waiting to be flushed to the
        server, which would corrupt the in-flight intent before it is sent.

        If all pool slots are currently in-flight (more QueueIntent calls than
        INTENT_POOL_SIZE in one tick without an intervening flush), a fresh table
        is allocated as a fallback. This is an edge case that should not occur in
        normal gameplay but must be handled safely.

    Returns:
        AnimationIntent
            A reusable record whose fields the caller should immediately overwrite.

    Notes:
        Bug S fix context:
            Before this fix, the pool cursor advanced blindly. If QueueIntent was
            called enough times in one tick to wrap the cursor before Flush drained
            the queue, the cursor would land on a slot still sitting in _IntentQueue
            and return it again. The next QueueIntent call would then overwrite its
            fields, corrupting the in-flight intent. The fix scans for a slot not
            currently in the queue before advancing the cursor.
]=]
function ReplicationBridge:_AcquireIntent(): AnimationIntent
	local StartCursor = self._PoolCursor
	local PoolSize    = INTENT_POOL_SIZE

	for SearchOffset = 0, PoolSize - 1 do
		local SlotIndex = ((StartCursor - 1 + SearchOffset) % PoolSize) + 1
		local CandidateSlot = self._IntentPool[SlotIndex]

		-- Check whether this slot is already queued for sending this tick.
		-- If so, handing it out would corrupt the queued intent.
		local IsSlotInFlight = false
		for _, QueuedIntent in self._IntentQueue do
			if QueuedIntent == CandidateSlot then
				IsSlotInFlight = true
				break
			end
		end

		if not IsSlotInFlight then
			-- Advance cursor past this slot so the next call starts after it.
			self._PoolCursor = (SlotIndex % PoolSize) + 1
			return CandidateSlot
		end
	end

	-- All pool slots are currently in the queue. Allocate a fresh table to avoid
	-- corrupting any queued intent. This should not occur under normal gameplay.
	return {
		CharacterId   = "",
		AnimationName = "",
		Action        = "PLAY",
		Timestamp     = 0,
		StateContext  = "",
	}
end

--[[
    _RecycleIntent

    Description:
        Marks an intent slot as available for reuse. In the current implementation
        this is a no-op because the pool is circular — slots are claimed by the
        cursor scan in _AcquireIntent and become available again naturally once
        they are no longer in the _IntentQueue.

        The method exists to make the intent lifecycle explicit at the call site
        (Flush calls this after sending each intent) and to provide an extension
        point if more sophisticated recycling is needed in the future (e.g. zeroing
        fields to aid GC or clear sensitive data).
]]
function ReplicationBridge:_RecycleIntent(_ConsumedIntent: AnimationIntent)
	-- Pool slots are reused via cursor wrap-around. No explicit action required.
end

-- ─── Intent Queueing (Owning Client Only) ────────────────────────────────────

--[=[
    QueueIntent

    Description:
        Records a PLAY or STOP animation action into the outgoing intent queue.
        Called by AnimationController immediately after playing or stopping a
        wrapper, so that the owning client's action is relayed to the server on
        the next Flush call.

        Intents are not sent immediately — they are batched in _IntentQueue and
        sent as a group in Flush. This batching means that multiple animations
        started in the same frame (e.g. two sounds triggered simultaneously by a
        state transition) are sent in a single network round trip rather than
        multiple separate FireServer calls.

    Parameters:
        AnimationName : string
            The Config.Name of the animation that was played or stopped.

        Action        : "PLAY" | "STOP"
            What happened to the animation.

        StateContext  : string
            The FSM state name at the time of the action (from
            StateMachine:GetCurrentStateName). Used on the receiving end for
            context-aware filtering or debugging; not directly used in the play
            pipeline by non-owning clients currently.

    Returns:
        Nothing. Mutates _IntentQueue by appending one intent record.

    Notes:
        Bug O fix context:
            The original code acquired a pool slot then immediately called
            table.clone to insert into the queue, making the pool pointless —
            it allocated a new table on every call. The fix writes directly into
            a pool slot and inserts that slot reference into the queue. Flush
            reads the slot, sends it, then recycles it. The pool's purpose —
            eliminating per-intent allocation — is now achieved.

        Bug A fix context:
            Timestamps were originally os.clock(), which is process uptime measured
            independently on each machine. A server and client can have wildly
            different os.clock() values with no meaningful relationship between them.
            workspace:GetServerTimeNow() returns a synchronized wall-clock timestamp
            that is consistent across server and all clients, making the age
            calculation in _HandleClientIntent (serverTime - intent.Timestamp) valid.
]=]
function ReplicationBridge:QueueIntent(
	AnimationName : string,
	Action        : "PLAY" | "STOP",
	StateContext  : string
)
	if self._Destroyed then return end

	-- Only the owning client produces intents. Server and non-owning clients
	-- never call QueueIntent; this guard prevents accidental calls.
	if not self._IsOwningClient then return end

	-- Bug O fix: write directly into the acquired pool slot rather than cloning.
	local IntentSlot = self:_AcquireIntent()
	IntentSlot.CharacterId   = self._CharacterId
	IntentSlot.AnimationName = AnimationName
	IntentSlot.Action        = Action
	-- Bug A fix: synchronized server time rather than local process uptime.
	IntentSlot.Timestamp     = workspace:GetServerTimeNow()
	IntentSlot.StateContext  = StateContext

	table.insert(self._IntentQueue, IntentSlot)
end

-- ─── Per-Tick Flush ───────────────────────────────────────────────────────────

--[=[
    Flush

    Description:
        Called once per tick by AnimationController at Step 4 of the update
        pipeline, after layer weights have been updated and weights have been
        pushed to wrappers. Performs two roles depending on execution context:

        Owning Client:
            Sends all accumulated intents in _IntentQueue to the server via
            FireServer on the intent remote, then clears the queue and recycles
            pool slots.

        Server:
            Advances the snapshot timer by dt. When the timer reaches
            SNAPSHOT_INTERVAL_SECONDS, resets the timer and broadcasts a full
            state snapshot to all clients via FireAllClients on the snapshot remote.

    Parameters:
        Dt                 : number
            Frame delta time in seconds. Used by the server to advance the snapshot timer.

        CurrentStateName   : string
            The FSM's current state name, included in snapshots for FSM reconciliation.

        ActiveGroupAnims   : { [string]: string }
            Map of group name → active animation name, included in snapshots so
            non-owning clients can replay the correct grouped animations during
            reconciliation.

    Returns:
        Nothing.

    Notes:
        Bug fix context (snapshot sequence counter):
            The server must NOT increment _SequenceNumber here. Snapshots are
            checkpoints, not intent events. Non-owning clients mirror the server's
            counter by incrementing once per received relay intent (_HandleIncomingIntent).
            If the server also bumped for snapshots, the non-owning client's counter
            would always be 1 behind, causing _HandleSnapshot to see a mismatch on
            every snapshot — triggering false reconciliation every 2.5 seconds even
            on a perfectly synced client.
]=]
function ReplicationBridge:Flush(
	Dt               : number,
	CurrentStateName : string,
	ActiveGroupAnims : { [string]: string }
)
	if self._Destroyed then return end

	-- ── Owning Client: drain the intent queue to the server ────────────────
	if self._IsOwningClient then
		local HasPendingIntents = #self._IntentQueue > 0
		local CanSend           = self._IntentRemote ~= nil

		if HasPendingIntents and CanSend then
			for _, PendingIntent in self._IntentQueue do
				self._IntentRemote:FireServer(PendingIntent)
				self:_RecycleIntent(PendingIntent)
			end
			table.clear(self._IntentQueue)
		end
	end

	-- ── Server: broadcast periodic state snapshots ─────────────────────────
	if self._IsServer and self._SnapshotRemote then
		self._SnapshotTimer += Dt

		local IsSnapshotDue = self._SnapshotTimer >= SNAPSHOT_INTERVAL_SECONDS

		if IsSnapshotDue then
			self._SnapshotTimer = 0
			-- Bug fix: do NOT increment _SequenceNumber here. Only intents
			-- advance the counter; snapshots carry the current (un-bumped) value
			-- so a clean round produces delta=0 on non-owning clients.
			self._SnapshotRemote:FireAllClients({
				CharacterId      = self._CharacterId,
				StateName        = CurrentStateName,
				ActiveGroupAnims = ActiveGroupAnims,
				SequenceNumber   = self._SequenceNumber,
				ServerTime       = workspace:GetServerTimeNow(),
			})
		end
	end
end

-- ─── Server: Receiving Intents From the Owning Client ────────────────────────

--[=[
    _HandleClientIntent

    Description:
        Called on the server when the owning client fires an AnimationIntent via
        the intent remote. Validates ownership and freshness, increments the server
        sequence counter, then rebroadcasts the intent to all other players.

    Parameters:
        SendingPlayer   : Player
            The Roblox Player instance whose client fired the event.
        IncomingIntent  : AnimationIntent
            The intent record received from the client.

    Returns:
        Nothing.

    Notes:
        Bug #5 fix context:
            Without the ownership check, any client that knows another character's
            CharacterId could inject arbitrary animation intents for that character.
            The fix verifies that SendingPlayer.Character.Name matches CharacterId.
            If the game uses a different identity scheme (UserId strings, GUIDs),
            this check must be updated to match that convention.

        Staleness filtering:
            Intents older than STALE_INTENT_THRESHOLD_SECONDS (measured in
            synchronized server time) are discarded with a warning. This prevents
            animations from being triggered long after the player's input, which
            would look incorrect or could be exploited for replay attacks.

        Sequence number:
            Incremented once per accepted (non-stale, non-spoofed) intent. Non-owning
            clients mirror this via _HandleIncomingIntent so their counters stay in
            lockstep for snapshot comparison.
]=]
function ReplicationBridge:_HandleClientIntent(SendingPlayer: Player, IncomingIntent: AnimationIntent)
	if self._Destroyed then return end

	-- Filter out intents for characters this bridge doesn't manage.
	if IncomingIntent.CharacterId ~= self._CharacterId then return end

	-- Bug #5 fix: verify the sending player actually owns this character.
	-- Character.Name is set to the player's Username in standard Roblox games.
	local SenderCharacter = SendingPlayer.Character
	local IsOwnerVerified = SenderCharacter and SenderCharacter.Name == self._CharacterId

	if not IsOwnerVerified then
		warn(string.format(
			"[ReplicationBridge] Rejected intent from %s for character '%s' — player does not own that character.",
			SendingPlayer.Name,
			self._CharacterId
			))
		return
	end

	local IntentAgeSeconds = workspace:GetServerTimeNow() - IncomingIntent.Timestamp
	local IsIntentStale    = IntentAgeSeconds > STALE_INTENT_THRESHOLD_SECONDS

	if IsIntentStale then
		warn(string.format(
			"[ReplicationBridge] Discarding stale intent '%s' from %s (age %.2fs)",
			IncomingIntent.AnimationName,
			SendingPlayer.Name,
			IntentAgeSeconds
			))
		return
	end

	-- Intent is valid. Advance the authoritative sequence counter and rebroadcast
	-- to every other connected player.
	self._SequenceNumber += 1

	if self._IntentRemote then
		for _, ConnectedClient in game:GetService("Players"):GetPlayers() do
			-- Never echo the intent back to the sender — they already played it.
			if ConnectedClient ~= SendingPlayer then
				self._IntentRemote:FireClient(ConnectedClient, IncomingIntent)
			end
		end
	end
end

-- ─── Non-Owning Clients: Receiving Relay Intents ─────────────────────────────

--[=[
    _HandleIncomingIntent

    Description:
        Called on non-owning clients when the server relays a validated intent.
        Increments the local sequence counter to mirror the server's, then fires
        the OnIntentReceived callback so AnimationController can replay the action.

    Parameters:
        RelayedIntent : AnimationIntent
            The intent record relayed from the server.

    Returns:
        Nothing.

    Notes:
        Bug T fix context:
            Non-owning clients originally never incremented _SequenceNumber here.
            The server increments its counter once per accepted intent. Because the
            non-owning client never mirrored this, its counter immediately fell behind
            and _HandleSnapshot always saw a mismatch, triggering full reconciliation
            on every snapshot (every 2.5 seconds) even when the client was perfectly
            in sync. The fix mirrors the increment so counters stay in lockstep under
            normal operation and reconciliation only fires on genuine gaps.
]=]
function ReplicationBridge:_HandleIncomingIntent(RelayedIntent: AnimationIntent)
	if self._Destroyed then return end

	-- Ignore intents for other characters that happen to share the same remote.
	if RelayedIntent.CharacterId ~= self._CharacterId then return end

	-- Bug T fix: mirror the server's sequence counter increment so the snapshot
	-- comparison in _HandleSnapshot reflects the true number of processed intents.
	self._SequenceNumber += 1

	if self._OnIntentReceived then
		self._OnIntentReceived(RelayedIntent)
	end
end

-- ─── Snapshot Handling ────────────────────────────────────────────────────────

--[=[
    _HandleSnapshot

    Description:
        Called on non-owning clients when the server broadcasts a periodic snapshot.
        Syncs the local sequence counter to the server's value, then fires
        _OnSnapshotMismatch if the counters differed — indicating dropped intents
        and a need for full reconciliation.

    Parameters:
        IncomingSnapshot : SnapshotData
            The full-state snapshot broadcast by the server.

    Returns:
        Nothing.

    Notes:
        Counter sync strategy:
            The local counter is always overwritten with the server's value,
            regardless of whether they match. This ensures the local counter
            converges to the server baseline after reconciliation rather than
            drifting further. A mismatch triggers reconciliation and the subsequent
            sync ensures the next snapshot comparison starts from a clean baseline.

        OnSnapshotMismatch:
            Bug #7 fix context: this callback was always nil in the original because
            the constructor never stored it. Now correctly fires AnimationController's
            _OnSnapshotMismatch for desync recovery.
]=]
function ReplicationBridge:_HandleSnapshot(IncomingSnapshot: SnapshotData)
	if self._Destroyed then return end

	-- Ignore snapshots for other characters.
	if IncomingSnapshot.CharacterId ~= self._CharacterId then return end

	local PreviousLocalSequence = self._SequenceNumber
	-- Always sync to the server value so future comparisons are relative to the
	-- correct baseline regardless of whether reconciliation fires.
	self._SequenceNumber = IncomingSnapshot.SequenceNumber

	local HasSequenceDrifted = IncomingSnapshot.SequenceNumber ~= PreviousLocalSequence

	if HasSequenceDrifted then
		warn(string.format(
			"[ReplicationBridge] Sequence mismatch for character %s: local=%d server=%d. Reconciling.",
			self._CharacterId,
			PreviousLocalSequence,
			IncomingSnapshot.SequenceNumber
			))
		-- Bug #7 fix: _OnSnapshotMismatch is now correctly stored on the instance.
		if self._OnSnapshotMismatch then
			self._OnSnapshotMismatch(IncomingSnapshot)
		end
	end
end

-- ─── Sequence Management ──────────────────────────────────────────────────────

--[=[
    IncrementSequence

    Description:
        Manually increments the local sequence counter by one. Exposed for cases
        where the controller needs to advance the counter outside of the normal
        intent relay path (e.g. during snapshot reconciliation to align the counter
        after replaying server-authoritative animations).

    Returns:
        Nothing.
]=]
function ReplicationBridge:IncrementSequence()
	self._SequenceNumber += 1
end

--[=[
    GetSequenceNumber

    Description:
        Returns the current local sequence counter value. Used by AnimationController
        to read the counter for debugging or for building snapshot payloads.

    Returns:
        number
            The current sequence number. Starts at 0 and increments once per
            accepted intent on both the server and non-owning clients.
]=]
function ReplicationBridge:GetSequenceNumber(): number
	return self._SequenceNumber
end

-- ─── Destruction ──────────────────────────────────────────────────────────────

--[=[
    Destroy

    Description:
        Tears down the ReplicationBridge by disconnecting all remote event
        connections and clearing the intent queue. After calling Destroy, no further
        network traffic is sent or received and all callbacks stop firing.

        Idempotent — safe to call multiple times; subsequent calls after the first
        are no-ops.

    Returns:
        Nothing.
]=]
function ReplicationBridge:Destroy()
	if self._Destroyed then return end
	self._Destroyed = true

	for _, EventConnection in self._Connections do
		EventConnection:Disconnect()
	end
	table.clear(self._Connections)

	-- Clear the queue so that any intents accumulated after the last flush are
	-- discarded. Pool slots referenced by queued intents will simply be
	-- overwritten on the next hypothetical AcquireIntent call, which will never
	-- come because the bridge is destroyed.
	table.clear(self._IntentQueue)
end

return ReplicationBridge