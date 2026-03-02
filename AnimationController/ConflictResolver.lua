--!strict
-- ConflictResolver.lua
-- Stateless utility. Consumed by AnimationController during every play request.
-- Applies the four-phase resolution order:
--   Phase 1 — ExclusiveGroup
--   Phase 2 — Layer priority (Order)
--   Phase 3 — Animation priority (Config.Priority)
--   Phase 4 — Timestamp (StartTimestamp) — newer challenger wins; incumbent wins on exact tie
--
-- Returns a verdict: "ALLOW" | "DEFER" | "REJECT"
-- The verdict is a pure function of inputs — no hidden state, no side effects.
--
-- NOTE: CanInterrupt / MinDuration enforcement for non-grouped animations is handled
-- here in Phase 2b. For grouped animations this is handled by ExclusiveGroupManager.

local Types = require(script.Parent.Types)
type AnimationConfig = Types.AnimationConfig
type ConflictVerdict = Types.ConflictVerdict

-- ── Input type ─────────────────────────────────────────────────────────────

export type ResolverInput = {
	-- Incoming request
	IncomingConfig  : AnimationConfig,
	IncomingLayer   : number,   -- Layer.Order of the incoming animation

	-- Active incumbent (may be nil if slot is empty)
	ActiveConfig    : AnimationConfig?,
	ActiveLayer     : number?,  -- Layer.Order of the active animation
	ActiveTimestamp : number?,  -- StartTimestamp of the active wrapper; used in Phase 4

	-- Group enforcement state (from ExclusiveGroupManager)
	GroupVerdict    : ConflictVerdict?, -- Pre-computed group verdict, nil if no group applies

	-- Current time for CanInterrupt / MinDuration evaluation on non-grouped animations.
	-- Required when ActiveConfig.CanInterrupt == false.
	Now             : number?,
}

-- ── ConflictResolver ───────────────────────────────────────────────────────

local ConflictResolver = {}

-- Resolve a play request against the current active animation.
-- All phases are evaluated in order; the first decisive phase wins.
function ConflictResolver.Resolve(input: ResolverInput): ConflictVerdict
	-- If there is no active animation, always allow.
	if input.ActiveConfig == nil then
		return "ALLOW"
	end

	-- ── Phase 1: ExclusiveGroup ──────────────────────────────────────────
	-- If both animations share a group, the group enforcement result is authoritative.
	-- GroupVerdict is pre-computed by ExclusiveGroupManager and passed in.
	local incomingGroup = input.IncomingConfig.Group
	local activeGroup   = input.ActiveConfig and input.ActiveConfig.Group

	if incomingGroup and activeGroup and incomingGroup == activeGroup then
		-- Group constraint applies; use the pre-computed verdict.
		assert(input.GroupVerdict ~= nil,
			"[ConflictResolver] GroupVerdict must be provided when both animations share a group")
		return input.GroupVerdict :: ConflictVerdict
	end

	-- ── Phase 2: Layer Priority ──────────────────────────────────────────
	-- Higher Order wins. If both are on the same layer, proceed to Phase 2b.
	local incomingOrder = input.IncomingLayer
	local activeOrder   = input.ActiveLayer or 0

	if incomingOrder > activeOrder then
		return "ALLOW"
	elseif incomingOrder < activeOrder then
		return "REJECT"
	end

	-- ── Phase 2b: CanInterrupt / MinDuration (non-grouped, same layer) ───
	-- Bug #3 fix: CanInterrupt was previously ignored for non-grouped animations.
	-- Mirror the same logic ExclusiveGroupManager applies for grouped animations.
	local activeConfig = input.ActiveConfig :: AnimationConfig
	if not activeConfig.CanInterrupt then
		local now       = input.Now or os.clock()
		local elapsed   = now - (input.ActiveTimestamp or 0)
		local minDur    = activeConfig.MinDuration or 0
		if elapsed < minDur then
			-- Active animation has not met its MinDuration — block the incoming.
			-- Non-grouped animations have no pending slot, so this is a hard REJECT.
			return "REJECT"
		end
		-- MinDuration satisfied — fall through to priority comparison.
	end

	-- ── Phase 3: Animation Priority ──────────────────────────────────────
	-- Within the same layer, higher Config.Priority wins.
	local incomingPrio = input.IncomingConfig.Priority
	local activePrio   = activeConfig.Priority

	if incomingPrio > activePrio then
		return "ALLOW"
	elseif incomingPrio < activePrio then
		return "REJECT"
	end

	-- ── Phase 4: Timestamp ───────────────────────────────────────────────
	-- Bug #20 fix: ActiveTimestamp was accepted and documented but never read.
	-- The more recently started animation wins ties; exact same timestamp → REJECT
	-- (incumbent holds, which is the correct conservative default).
	local incomingTime = input.Now or os.clock()
	local activeTime   = input.ActiveTimestamp or 0
	if incomingTime > activeTime then
		return "ALLOW"
	end
	return "REJECT"
end

-- Convenience: resolve without group context (for non-grouped animations).
-- Passes os.clock() as Now so Phase 2b and Phase 4 work correctly.
function ConflictResolver.ResolveNoGroup(
	incomingConfig     : AnimationConfig,
	incomingLayerOrder : number,
	activeConfig       : AnimationConfig?,
	activeLayerOrder   : number?,
	activeTimestamp    : number?
): ConflictVerdict
	return ConflictResolver.Resolve({
		IncomingConfig  = incomingConfig,
		IncomingLayer   = incomingLayerOrder,
		ActiveConfig    = activeConfig,
		ActiveLayer     = activeLayerOrder,
		ActiveTimestamp = activeTimestamp,
		GroupVerdict    = nil,
		Now             = os.clock(),
	})
end

return ConflictResolver