--!strict
-- ExclusiveGroupManager.lua
-- Owned by AnimationController.
-- Enforces mutual exclusivity constraints across registered groups.
-- Maintains the currently-active TrackWrapper per group.
-- Contains the interrupt evaluation pipeline.

local Types  = require(script.Parent.Types)
type ConflictVerdict = Types.ConflictVerdict

-- ── Group Record ───────────────────────────────────────────────────────────

type GroupRecord = {
	ActiveWrapper  : any?,   -- TrackWrapper | nil
	PendingWrapper : any?,   -- TrackWrapper | nil — only one pending slot
	LockedUntil    : number, -- os.clock() timestamp; 0 = unlocked
}

-- ── ExclusiveGroupManager ──────────────────────────────────────────────────

local ExclusiveGroupManager = {}
ExclusiveGroupManager.__index = ExclusiveGroupManager

export type ExclusiveGroupManager = typeof(setmetatable({} :: {
	_groups           : { [string]: GroupRecord },
	_pendingTimers    : { [string]: thread? }, -- per-group coroutine watching MinDuration expiry
	_onPendingReady   : ((groupName: string, wrapper: any) -> ())?,
	_onPendingDestroy : ((wrapper: any) -> ())?,
	_destroyed        : boolean,
}, ExclusiveGroupManager))

-- onPendingReady: callback issued when a deferred request becomes eligible to play.
-- onPendingDestroy: callback issued when a pending wrapper is discarded without
--   being promoted (e.g. on Destroy). Allows the caller to return it to its pool.
--   If nil, wrappers are hard-destroyed.
function ExclusiveGroupManager.new(
	onPendingReady    : ((string, any) -> ())?,
	onPendingDestroy  : ((any) -> ())?
): ExclusiveGroupManager
	return setmetatable({
		_groups           = {},
		_pendingTimers    = {},
		_onPendingReady   = onPendingReady,
		_onPendingDestroy = onPendingDestroy,
		_destroyed        = false,
	}, ExclusiveGroupManager)
end

-- ── Group Lifecycle ────────────────────────────────────────────────────────

-- Registers a group if not already known. Safe to call multiple times.
function ExclusiveGroupManager:EnsureGroup(groupName: string)
	if not self._groups[groupName] then
		self._groups[groupName] = {
			ActiveWrapper  = nil,
			PendingWrapper = nil,
			LockedUntil    = 0,
		}
	end
end

-- ── Core Interrupt Algorithm ───────────────────────────────────────────────
-- Implements the algorithm from Section 4 of the spec.
-- Returns verdict AND mutates group state accordingly.
-- The caller (AnimationController) is responsible for actually playing/stopping wrappers.

type EvaluationResult = {
	Verdict         : ConflictVerdict,
	WrapperToStop   : any?,   -- ActiveWrapper that should be faded out (if ALLOW)
	PendingEvicted  : any?,   -- PendingWrapper that was displaced (gets REJECT)
}

function ExclusiveGroupManager:EvaluatePlayRequest(groupName: string, incomingWrapper: any): EvaluationResult
	self:EnsureGroup(groupName)
	local record = self._groups[groupName]

	-- Step 2: no active wrapper → ALLOW immediately
	if record.ActiveWrapper == nil then
		record.ActiveWrapper  = incomingWrapper
		record.PendingWrapper = nil
		return { Verdict = "ALLOW", WrapperToStop = nil, PendingEvicted = nil }
	end

	local active       = record.ActiveWrapper
	local activeConfig = active.Config
	local now          = os.clock()

	-- Step 3: CanInterrupt = false path
	if not activeConfig.CanInterrupt then
		local elapsed = now - active.StartTimestamp
		local minDur  = activeConfig.MinDuration or 0

		if elapsed < minDur then
			-- MinDuration not yet satisfied — DEFER.
			-- Evict any stale pending before storing the new one.
			local evicted = record.PendingWrapper
			-- Bug #1 fix: guard against evicting the incoming wrapper itself.
			-- This can happen if _OnPendingReady re-evaluates the same wrapper.
			if evicted == incomingWrapper then
				evicted = nil
			end
			record.PendingWrapper = incomingWrapper

			-- Set up a timer to re-evaluate once MinDuration expires
			self:_SchedulePendingReeval(groupName, minDur - elapsed)

			return { Verdict = "DEFER", WrapperToStop = nil, PendingEvicted = evicted }
		else
			-- MinDuration has passed — treat as CanInterrupt = true, fall through to step 4
		end
	end

	-- Step 4: CanInterrupt = true (or effectively so) → ALLOW.
	-- Bug #1 fix: only evict PendingWrapper if it is a different object from incomingWrapper.
	-- When _OnPendingReady promotes a pending wrapper it calls EvaluatePlayRequest with the
	-- same wrapper object that is currently stored as PendingWrapper. Without this guard the
	-- evicted field would point to incomingWrapper itself, and the caller would destroy the
	-- wrapper it is about to activate.
	local evicted = record.PendingWrapper
	if evicted == incomingWrapper then
		evicted = nil
	end
	record.PendingWrapper = nil
	record.ActiveWrapper  = incomingWrapper

	return { Verdict = "ALLOW", WrapperToStop = active, PendingEvicted = evicted }
end

-- Called when a pending request's MinDuration window expires.
-- Re-evaluates the pending wrapper as a fresh play request.
function ExclusiveGroupManager:_SchedulePendingReeval(groupName: string, delay: number)
	-- Cancel any existing timer for this group
	if self._pendingTimers[groupName] then
		task.cancel(self._pendingTimers[groupName])
		self._pendingTimers[groupName] = nil
	end

	self._pendingTimers[groupName] = task.delay(delay, function()
		-- Bug #10 fix: check _destroyed flag before touching any state.
		-- task.cancel is not guaranteed to prevent a same-frame resume, so we
		-- must guard with an explicit destroyed check rather than relying solely
		-- on table.clear having removed the group record.
		if self._destroyed then return end

		self._pendingTimers[groupName] = nil
		local record = self._groups[groupName]
		if not record then return end
		local pending = record.PendingWrapper
		if not pending then return end

		-- Attempt to promote pending to active
		if self._onPendingReady then
			self._onPendingReady(groupName, pending)
		end
	end)
end

-- ── Track Completion Notification ─────────────────────────────────────────

-- Called by AnimationController when the active wrapper for a group naturally completes.
-- Promotes any pending wrapper.
function ExclusiveGroupManager:OnActiveCompleted(groupName: string)
	local record = self._groups[groupName]
	if not record then return end

	local pending = record.PendingWrapper
	if pending then
		-- Bug I fix: do NOT clear ActiveWrapper before promotion is confirmed.
		-- If _onPendingReady fails early (e.g. the layer no longer exists), it
		-- destroys the pending wrapper and returns without ever setting a new
		-- ActiveWrapper. If we cleared ActiveWrapper here first, the group would
		-- be permanently dead — slot nil, no pending, no recovery path.
		-- Instead, leave ActiveWrapper in place until EvaluatePlayRequest commits
		-- the new wrapper (it unconditionally sets record.ActiveWrapper = incomingWrapper
		-- on an ALLOW verdict). On a failed promotion we also need to clear it, so
		-- _onPendingReady is responsible for calling ClearActive on failure.
		record.PendingWrapper = nil
		if self._onPendingReady then
			self._onPendingReady(groupName, pending)
		end
	else
		-- No pending successor — safe to clear the slot immediately.
		record.ActiveWrapper = nil
	end
end

-- ── Explicit Clear ─────────────────────────────────────────────────────────

-- Clears the active wrapper for a group without affecting pending.
function ExclusiveGroupManager:ClearActive(groupName: string)
	local record = self._groups[groupName]
	if record then
		record.ActiveWrapper = nil
	end
end

-- Called by AnimationController:Destroy — cancels all timers.
-- Bug #10 fix: set _destroyed = true BEFORE cancelling timers and clearing tables
-- so that any timer that races to fire on the same frame sees the flag and returns
-- immediately, without accessing cleared state.
function ExclusiveGroupManager:Destroy()
	if self._destroyed then return end
	self._destroyed = true

	for groupName, thread in self._pendingTimers do
		if thread then
			task.cancel(thread)
		end
	end

	-- Bug V fix: return pending wrappers to the controller's pool via _onPendingDestroy
	-- rather than hard-destroying them. Hard-destroying permanently shrinks pool
	-- capacity when Destroy is called from _OnSnapshotMismatch, which does not also
	-- clear the pool. Over repeated reconciliations the pool drains to zero and every
	-- grouped animation allocates a fresh wrapper instead of reusing a pooled one.
	for _, record in self._groups do
		if record.PendingWrapper then
			if self._onPendingDestroy then
				self._onPendingDestroy(record.PendingWrapper)
			else
				record.PendingWrapper:_Destroy()
			end
			record.PendingWrapper = nil
		end
	end

	table.clear(self._pendingTimers)
	table.clear(self._groups)
end

-- ── Snapshot for DebugInspector ────────────────────────────────────────────

function ExclusiveGroupManager:GetSnapshot(): { { [string]: any } }
	local out = {}
	for groupName, record in self._groups do
		table.insert(out, {
			Group                = groupName,
			ActiveAnimationName  = record.ActiveWrapper and record.ActiveWrapper.Config.Name or nil,
			StartTimestamp       = record.ActiveWrapper and record.ActiveWrapper.StartTimestamp or nil,
			CanInterrupt         = record.ActiveWrapper and record.ActiveWrapper.Config.CanInterrupt or nil,
			PendingAnimationName = record.PendingWrapper and record.PendingWrapper.Config.Name or nil,
		})
	end
	return out
end

-- Validates group invariants — used by DebugInspector:ValidateInvariants
function ExclusiveGroupManager:ValidateInvariants(): { string }
	local violations = {}
	for groupName, record in self._groups do
		if record.ActiveWrapper and record.PendingWrapper then
			if record.ActiveWrapper == record.PendingWrapper then
				table.insert(violations, string.format(
					"Group '%s': ActiveWrapper and PendingWrapper are the same object", groupName
				))
			end
		end
	end
	return violations
end

return ExclusiveGroupManager
