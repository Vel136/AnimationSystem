--!strict
-- ─── ExclusiveGroupManager.lua ────────────────────────────────────────────────
--[[
    Enforces mutual exclusivity constraints for named animation groups.

    An exclusive group ensures that at most one animation in the group has non-zero
    weight at any given time. This is essential for things like "attack combo" groups
    where two attack animations must never blend together, or "facial expression" groups
    where only one expression may be visible.

    Each AnimationController owns one ExclusiveGroupManager instance. The manager
    maintains a GroupRecord per registered group, tracking which TrackWrapper is
    currently active and which (if any) is waiting in the single pending slot.

    ── Interrupt Algorithm (Section 4 of design spec) ───────────────────────────

    When EvaluatePlayRequest is called:

    Step 1 — EnsureGroup: create a record for this group if it doesn't exist yet.
    Step 2 — No active wrapper: immediately ALLOW the incoming animation.
    Step 3 — Active has CanInterrupt = false:
              If elapsed time < MinDuration → DEFER (store as PendingWrapper, schedule timer).
              If elapsed time ≥ MinDuration → treat as CanInterrupt = true, fall through.
    Step 4 — Active has CanInterrupt = true (or effectively): ALLOW.
              The old active becomes WrapperToStop. Any previous pending becomes PendingEvicted.

    The function returns an EvaluationResult describing what happened and what the
    caller (AnimationController) should do next. All actual track playback and stopping
    is handled by the caller — this manager only mutates GroupRecord state.
]]

local Types = require(script.Parent.Types)

type ConflictVerdict = Types.ConflictVerdict

-- ─── Group Record ─────────────────────────────────────────────────────────────

--[[
    GroupRecord is the runtime state for a single exclusive group.

    ActiveWrapper  — the TrackWrapper currently playing in this group, or nil if empty.
    PendingWrapper — a single deferred wrapper waiting for ActiveWrapper's MinDuration
                     to expire before it can be promoted. At most one pending at a time;
                     new deferred requests overwrite (evict) the previous pending.
    LockedUntil    — reserved field for future timed-lock features. Currently unused;
                     always 0 (meaning unlocked).
]]
type GroupRecord = {
	ActiveWrapper:  any?,
	PendingWrapper: any?,
	LockedUntil:    number,
}

-- ─── Evaluation Result ────────────────────────────────────────────────────────

--[[
    EvaluationResult is the output of EvaluatePlayRequest. It tells the caller what
    verdict was reached AND what side-effects should be performed:

    Verdict        — the conflict resolution outcome.
    WrapperToStop  — the previously active wrapper that the caller should fade out
                     (only non-nil when Verdict == "ALLOW" and there was an active wrapper).
    PendingEvicted — a previously pending wrapper that was displaced by the new request.
                     The caller should return it to the pool or destroy it — it will never play.
]]
type EvaluationResult = {
	Verdict:        ConflictVerdict,
	WrapperToStop:  any?,
	PendingEvicted: any?,
}

-- ─── ExclusiveGroupManager ────────────────────────────────────────────────────

local ExclusiveGroupManager = {}
ExclusiveGroupManager.__index = ExclusiveGroupManager

export type ExclusiveGroupManager = typeof(setmetatable({} :: {
	_Groups:           { [string]: GroupRecord },
	-- Per-group coroutine handles for the MinDuration recheck timer.
	-- Stored so a new timer can cancel an existing one before scheduling a replacement,
	-- preventing multiple timers from racing to promote the same pending wrapper.
	_PendingTimers:    { [string]: thread? },
	-- Callback fired when a deferred wrapper becomes eligible to play.
	-- Bound to AnimationController._OnPendingReady. The manager does not call
	-- _ActivateWrapper directly; it delegates back to the controller so that all
	-- the setup logic (RegisterTrack, QueueIntent, CompletedSignal wiring) runs.
	_OnPendingReady:   ((GroupName: string, Wrapper: any) -> ())?,
	-- Callback fired when a pending wrapper is discarded without ever being promoted
	-- (e.g. during Destroy). Lets the controller return the wrapper to its pool.
	-- If nil, the wrapper is hard-destroyed instead.
	_OnPendingDestroy: ((Wrapper: any) -> ())?,
	_IsDestroyed:      boolean,
}, ExclusiveGroupManager))

-- ─── Constructor ──────────────────────────────────────────────────────────────

--[=[
    ExclusiveGroupManager.new

    Description:
        Creates a new ExclusiveGroupManager with empty group records and the two
        lifecycle callbacks that connect it back to the owning AnimationController.

    Parameters:
        OnPendingReady: ((GroupName: string, Wrapper: any) -> ())?
            Called when a deferred wrapper's MinDuration window expires and it is
            ready to be promoted. The controller should attempt to activate it.

        OnPendingDestroy: ((Wrapper: any) -> ())?
            Called when a pending wrapper is discarded without being promoted.
            The controller should return the wrapper to its pool or destroy it.
            If nil, the manager calls wrapper:_Destroy() directly (safe but less
            pool-efficient).

    Returns:
        ExclusiveGroupManager
            A new instance ready to accept EnsureGroup / EvaluatePlayRequest calls.
]=]
function ExclusiveGroupManager.new(
	OnPendingReady:   ((string, any) -> ())?,
	OnPendingDestroy: ((any) -> ())?
): ExclusiveGroupManager
	return setmetatable({
		_Groups           = {},
		_PendingTimers    = {},
		_OnPendingReady   = OnPendingReady,
		_OnPendingDestroy = OnPendingDestroy,
		_IsDestroyed      = false,
	}, ExclusiveGroupManager)
end

-- ─── Group Lifecycle ──────────────────────────────────────────────────────────

--[=[
    ExclusiveGroupManager:EnsureGroup

    Description:
        Registers a group record for the given name if one does not already exist.
        Safe to call multiple times for the same group name.

        This is called lazily at play-request time rather than eagerly at Init
        because the set of groups in active use may be a subset of all groups defined
        in the registry (some groups may never be triggered in a given session).

    Parameters:
        GroupName: string
            The exclusive group name to register.
]=]
function ExclusiveGroupManager:EnsureGroup(GroupName: string)
	if not self._Groups[GroupName] then
		self._Groups[GroupName] = {
			ActiveWrapper  = nil,
			PendingWrapper = nil,
			LockedUntil    = 0,
		}
	end
end

-- ─── Core Interrupt Algorithm ─────────────────────────────────────────────────

--[=[
    ExclusiveGroupManager:EvaluatePlayRequest

    Description:
        Evaluates an incoming play request against the current group state, updates
        the group record accordingly, and returns an EvaluationResult describing
        what the caller (AnimationController) must do next.

        This function MUTATES GroupRecord state (ActiveWrapper, PendingWrapper).
        It does NOT call _Play, _Stop, or any callbacks directly — all side effects
        are left to the caller so that the activation pipeline stays in one place.

    Parameters:
        GroupName: string
            The exclusive group to evaluate against.

        IncomingWrapper: any
            The TrackWrapper representing the animation being requested. This object
            is acquired by the caller before this function is called so the manager
            can store it directly in the GroupRecord without a round-trip.

    Returns:
        EvaluationResult
            Verdict + pointers to wrappers that need external action:
            • WrapperToStop  — should be faded out by the caller (ALLOW only).
            • PendingEvicted — should be returned to pool or destroyed by the caller.

    Notes:
        Bug #1 fix: guards prevent a wrapper from appearing as its own eviction target.
        When _OnPendingReady promotes a pending wrapper, it calls EvaluatePlayRequest
        with the same wrapper object that is stored as PendingWrapper. Without the guard,
        PendingEvicted would point to IncomingWrapper itself, and the caller would destroy
        the wrapper it is about to activate.
]=]
function ExclusiveGroupManager:EvaluatePlayRequest(GroupName: string, IncomingWrapper: any): EvaluationResult
	self:EnsureGroup(GroupName)
	local Record = self._Groups[GroupName]

	-- ── Step 2: Empty slot — allow immediately ────────────────────────────────
	-- No active animation means no conflict. Assign the incoming wrapper as active
	-- and clear any stale pending (shouldn't be one if Active was nil, but be safe).
	if Record.ActiveWrapper == nil then
		Record.ActiveWrapper  = IncomingWrapper
		Record.PendingWrapper = nil
		return { Verdict = "ALLOW", WrapperToStop = nil, PendingEvicted = nil }
	end

	local ActiveWrapper  = Record.ActiveWrapper
	local ActiveConfig   = ActiveWrapper.Config
	local Now            = os.clock()

	-- ── Step 3: CanInterrupt = false path ─────────────────────────────────────
	-- The active animation is protected. Check whether MinDuration has elapsed.
	if not ActiveConfig.CanInterrupt then
		local Elapsed      = Now - ActiveWrapper.StartTimestamp
		local MinDuration  = ActiveConfig.MinDuration or 0

		local IsProtectionActive = Elapsed < MinDuration

		if IsProtectionActive then
			-- Active animation has not yet played long enough to be interrupted.
			-- Store IncomingWrapper in the single pending slot and schedule a
			-- timer that will re-evaluate once the protection window expires.
			--
			-- If there was already a pending wrapper, it is evicted (only one
			-- pending slot exists per group — last request wins).
			local EvictedPending = Record.PendingWrapper

			-- Bug #1 fix: guard against the incoming wrapper being its own eviction
			-- target. This can happen when _OnPendingReady re-evaluates the wrapper
			-- that is currently stored as PendingWrapper (promotion path). If we
			-- returned IncomingWrapper as PendingEvicted, the caller would destroy
			-- the wrapper it is trying to activate.
			local IsEvictingSelf = EvictedPending == IncomingWrapper
			if IsEvictingSelf then
				EvictedPending = nil
			end

			Record.PendingWrapper = IncomingWrapper

			-- Schedule the re-evaluation timer for the remaining protection window.
			-- The delay is computed from how much of MinDuration is left, so the
			-- promotion fires as close as possible to the exact expiry moment.
			self:_SchedulePendingReeval(GroupName, MinDuration - Elapsed)

			return { Verdict = "DEFER", WrapperToStop = nil, PendingEvicted = EvictedPending }
		end

		-- Protection window has elapsed — fall through to the ALLOW path below.
		-- Treating an expired CanInterrupt = false as effectively CanInterrupt = true
		-- avoids a special case in Step 4 and keeps the flow linear.
	end

	-- ── Step 4: CanInterrupt = true (or protection expired) — allow ───────────
	-- The active animation can be displaced. The incoming wrapper takes over as active.
	-- Any previous pending is evicted because the incoming request is more recent.

	local EvictedPending = Record.PendingWrapper

	-- Bug #1 fix: same guard as Step 3 — don't evict the incoming wrapper itself.
	local IsEvictingSelf = EvictedPending == IncomingWrapper
	if IsEvictingSelf then
		EvictedPending = nil
	end

	-- Capture the old active before overwriting it, so we can return it as WrapperToStop.
	local WrapperToStop = ActiveWrapper

	Record.PendingWrapper = nil
	Record.ActiveWrapper  = IncomingWrapper

	return { Verdict = "ALLOW", WrapperToStop = WrapperToStop, PendingEvicted = EvictedPending }
end

-- ─── Pending Recheck Timer ────────────────────────────────────────────────────

--[=[
    ExclusiveGroupManager:_SchedulePendingReeval

    Description:
        Schedules a task.delay to re-evaluate the pending wrapper once the active
        animation's MinDuration protection window expires.

        Any previously scheduled timer for this group is cancelled first, ensuring
        only one timer is ever live per group at a time. Without cancellation, two
        concurrent timers could both fire and both attempt to promote the pending
        wrapper, triggering double activation.

    Parameters:
        GroupName: string
            The group whose pending wrapper should be re-evaluated after the delay.

        Delay: number
            Seconds to wait before re-evaluation. Equal to (MinDuration - Elapsed)
            at the moment of deferral.
]=]
function ExclusiveGroupManager:_SchedulePendingReeval(GroupName: string, Delay: number)
	-- Cancel any existing timer for this group before scheduling a new one.
	-- A previous DEFER call may have left a timer running; the new timer supersedes it
	-- because the pending wrapper has been replaced by a more recent request.
	if self._PendingTimers[GroupName] then
		task.cancel(self._PendingTimers[GroupName])
		self._PendingTimers[GroupName] = nil
	end

	self._PendingTimers[GroupName] = task.delay(Delay, function()
		-- Bug #10 fix: check _IsDestroyed before touching any internal state.
		-- task.cancel is not guaranteed to prevent a same-frame resume in all engine
		-- versions. The explicit _IsDestroyed flag provides a reliable second guard
		-- even if the cancellation races with the timer firing on the same frame.
		if self._IsDestroyed then return end

		-- Clear the timer entry now that it has fired.
		self._PendingTimers[GroupName] = nil

		local Record = self._Groups[GroupName]
		if not Record then return end

		-- Only promote if there is still a pending wrapper waiting.
		-- It may have been evicted by a later DEFER or cleared by a Stop between
		-- when the timer was scheduled and when it fires.
		local PendingWrapper = Record.PendingWrapper
		if not PendingWrapper then return end

		-- Delegate promotion to the controller via the callback. The controller
		-- runs the full activation pipeline (conflict re-check, RegisterTrack, etc.)
		-- rather than us activating directly here.
		if self._OnPendingReady then
			self._OnPendingReady(GroupName, PendingWrapper)
		end
	end)
end

-- ─── Active Completion Notification ──────────────────────────────────────────

--[=[
    ExclusiveGroupManager:OnActiveCompleted

    Description:
        Called by AnimationController when the active wrapper for a group ends
        (either naturally via CompletedSignal or manually via Stop).

        If a pending wrapper exists, delegates its promotion to _OnPendingReady.
        If no pending exists, clears the active slot so the group is available for
        the next play request.

    Parameters:
        GroupName: string
            The group whose active animation just completed.

    Notes:
        Bug I fix: this function intentionally does NOT clear ActiveWrapper before
        promotion is confirmed. The old approach cleared ActiveWrapper first, then
        called _OnPendingReady. If promotion failed (e.g. the layer no longer exists),
        _OnPendingReady would destroy the pending wrapper and return, leaving
        ActiveWrapper = nil with no pending — the group permanently stuck.

        Now, ActiveWrapper remains set until EvaluatePlayRequest unconditionally
        overwrites it on an ALLOW verdict. If promotion fails, _OnPendingReady is
        responsible for calling ClearActive so the slot doesn't stay on a dead wrapper.
]=]
function ExclusiveGroupManager:OnActiveCompleted(GroupName: string)
	local Record = self._Groups[GroupName]
	if not Record then return end

	local PendingWrapper = Record.PendingWrapper

	if PendingWrapper then
		-- A pending wrapper is waiting for this slot. Promote it via the controller.
		-- Clear PendingWrapper first so that EvaluatePlayRequest (called from within
		-- _OnPendingReady) does not see it as the current pending occupant and return
		-- it as PendingEvicted.
		Record.PendingWrapper = nil
		if self._OnPendingReady then
			self._OnPendingReady(GroupName, PendingWrapper)
		end
	else
		-- No successor waiting. Clear the slot so it is available for future requests.
		Record.ActiveWrapper = nil
	end
end

-- ─── Explicit Clear ───────────────────────────────────────────────────────────

--[=[
    ExclusiveGroupManager:ClearActive

    Description:
        Sets a group's ActiveWrapper to nil without touching PendingWrapper or
        triggering any promotion.

        Used by AnimationController._OnPendingReady in error/failure paths where
        promotion cannot proceed (controller destroyed, layer missing, etc.) and we
        need to release the group slot so future requests are not permanently blocked.

    Parameters:
        GroupName: string
            The group whose active slot should be cleared.
]=]
function ExclusiveGroupManager:ClearActive(GroupName: string)
	local Record = self._Groups[GroupName]
	if Record then
		Record.ActiveWrapper = nil
	end
end

-- ─── Destruction ──────────────────────────────────────────────────────────────

--[=[
    ExclusiveGroupManager:Destroy

    Description:
        Cancels all scheduled timers, returns all pending wrappers to the controller's
        pool via _OnPendingDestroy, and clears all internal tables.

        Safe to call multiple times — subsequent calls after the first are no-ops.

    Notes:
        Bug #10 fix: _IsDestroyed is set to true BEFORE cancelling timers and clearing
        tables. Any timer that races to fire on the same frame as Destroy (a real edge
        case in Roblox's task scheduler) sees _IsDestroyed = true and exits immediately,
        preventing it from accessing the already-cleared state.

        Bug V fix: pending wrappers are returned to the controller's pool via
        _OnPendingDestroy rather than hard-destroyed. Hard-destroying them would
        permanently shrink pool capacity when Destroy is called from
        AnimationController._OnSnapshotMismatch (which rebuilds the GroupManager
        but does not clear the pool). Over repeated reconciliations the pool would
        drain to zero and every grouped animation would allocate a fresh wrapper.
]=]
function ExclusiveGroupManager:Destroy()
	if self._IsDestroyed then return end

	-- Set the flag FIRST so any racing timer callbacks see it and bail out immediately.
	self._IsDestroyed = true

	-- Cancel all pending recheck timers before they fire.
	for _, TimerThread in self._PendingTimers do
		if TimerThread then
			task.cancel(TimerThread)
		end
	end

	-- Return pending wrappers to the pool instead of destroying them.
	-- Wrappers in the pending slot were never activated (never in ActiveWrappers),
	-- so the controller's _RetireWrapper path would not reach them. We handle them
	-- here directly via the provided callback.
	for _, Record in self._Groups do
		if Record.PendingWrapper then
			if self._OnPendingDestroy then
				self._OnPendingDestroy(Record.PendingWrapper)
			else
				-- Fallback: no pool callback provided, hard-destroy the wrapper.
				Record.PendingWrapper:_Destroy()
			end
			Record.PendingWrapper = nil
		end
	end

	table.clear(self._PendingTimers)
	table.clear(self._Groups)
end

-- ─── Snapshot and Invariant API ───────────────────────────────────────────────

--[=[
    ExclusiveGroupManager:GetSnapshot

    Description:
        Returns a plain-table snapshot of all group records, suitable for display
        in DebugInspector. The snapshot is a shallow copy — it does not contain live
        wrapper references, only the names of the animations stored in each slot.

    Returns:
        { { [string]: any } }
            Array of records, one per registered group, each with fields:
            Group, ActiveAnimationName, StartTimestamp, CanInterrupt, PendingAnimationName.
]=]
function ExclusiveGroupManager:GetSnapshot(): { { [string]: any } }
	local Snapshot = {}
	for GroupName, Record in self._Groups do
		table.insert(Snapshot, {
			Group                = GroupName,
			ActiveAnimationName  = Record.ActiveWrapper and Record.ActiveWrapper.Config.Name or nil,
			StartTimestamp       = Record.ActiveWrapper and Record.ActiveWrapper.StartTimestamp or nil,
			CanInterrupt         = Record.ActiveWrapper and Record.ActiveWrapper.Config.CanInterrupt or nil,
			PendingAnimationName = Record.PendingWrapper and Record.PendingWrapper.Config.Name or nil,
		})
	end
	return Snapshot
end

--[=[
    ExclusiveGroupManager:ValidateInvariants

    Description:
        Checks that no group has ActiveWrapper and PendingWrapper pointing to the
        same object, which would indicate a bug in the promotion/eviction logic.

        Called by DebugInspector:ValidateInvariants during runtime assertions.

    Returns:
        { string }
            Array of violation descriptions. Empty if all invariants hold.
]=]
function ExclusiveGroupManager:ValidateInvariants(): { string }
	local Violations = {}
	for GroupName, Record in self._Groups do
		-- A wrapper can only be in one slot (Active or Pending) at a time.
		-- Finding the same object in both slots means a bug in EvaluatePlayRequest's
		-- eviction or assignment logic failed to maintain the separation.
		local ActiveAndPendingAreSame = (Record.ActiveWrapper ~= nil)
			and (Record.PendingWrapper ~= nil)
			and (Record.ActiveWrapper == Record.PendingWrapper)

		if ActiveAndPendingAreSame then
			table.insert(Violations, string.format(
				"Group '%s': ActiveWrapper and PendingWrapper are the same object",
				GroupName
				))
		end
	end
	return Violations
end

return ExclusiveGroupManager