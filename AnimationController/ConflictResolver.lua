--!strict
-- ConflictResolver.lua
-- Stateless utility. Consumed by AnimationController during every play request.
-- Applies the four-phase resolution order:
--   Phase 1 — ExclusiveGroup
--   Phase 2 — Layer priority (Order)
--   Phase 3 — Animation priority (Config.Priority)
--   Phase 4 — Timestamp (StartTimestamp)
--
-- Returns a verdict: "ALLOW" | "DEFER" | "REJECT"
-- The verdict is a pure function of inputs — no hidden state, no side effects.

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
	ActiveTimestamp : number?,  -- StartTimestamp of the active wrapper

	-- Group enforcement state (from ExclusiveGroupManager)
	GroupVerdict    : ConflictVerdict?, -- Pre-computed group verdict, nil if no group applies
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
	-- Higher Order wins. If both are on the same layer, proceed to Phase 3.
	local incomingOrder = input.IncomingLayer
	local activeOrder   = input.ActiveLayer or 0

	if incomingOrder > activeOrder then
		return "ALLOW"
	elseif incomingOrder < activeOrder then
		return "REJECT"
	end

	-- ── Phase 3: Animation Priority ──────────────────────────────────────
	-- Within the same layer, higher Config.Priority wins.
	local incomingPrio = input.IncomingConfig.Priority
	local activePrio   = (input.ActiveConfig :: AnimationConfig).Priority

	if incomingPrio > activePrio then
		return "ALLOW"
	elseif incomingPrio < activePrio then
		return "REJECT"
	end

	-- Phase 4: Timestamp — incumbent always wins ties
	return "REJECT"
end

-- Convenience: resolve without group context (for non-grouped animations)
function ConflictResolver.ResolveNoGroup(
	incomingConfig  : AnimationConfig,
	incomingLayerOrder : number,
	activeConfig    : AnimationConfig?,
	activeLayerOrder : number?,
	activeTimestamp : number?
): ConflictVerdict
	return ConflictResolver.Resolve({
		IncomingConfig  = incomingConfig,
		IncomingLayer   = incomingLayerOrder,
		ActiveConfig    = activeConfig,
		ActiveLayer     = activeLayerOrder,
		ActiveTimestamp = activeTimestamp,
		GroupVerdict    = nil,
	})
end

return ConflictResolver