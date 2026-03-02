--!strict
-- ─── ConflictResolver.lua ─────────────────────────────────────────────────────
--[[
    Stateless conflict resolution utility.

    When AnimationController receives a play request, it must decide what happens to
    any animation already occupying the same layer or group. ConflictResolver encodes
    that decision as a pure function — same inputs always produce the same output,
    with no internal state mutated and no side effects triggered.

    This statefulness design makes ConflictResolver trivially unit-testable, safe to
    call from any context without ordering concerns, and easy to reason about during
    code review because the entire resolution path is visible in a single function.

    ── Resolution Order ─────────────────────────────────────────────────────────

    Phase 1 — ExclusiveGroup:
        If both animations share a group, the pre-computed GroupVerdict from
        ExclusiveGroupManager is authoritative. Group logic is more complex than
        layer logic (it handles DEFER) so it is pre-evaluated outside this function.

    Phase 2 — Layer Priority (Order):
        Higher Layer.Order wins outright. An incoming animation on a higher-order layer
        always beats an active animation on a lower-order layer, and vice versa.

    Phase 2b — CanInterrupt / MinDuration (same-layer, non-grouped):
        Mirrors the same protection ExclusiveGroupManager applies for grouped animations.
        If the active animation has CanInterrupt = false and has not yet played for
        MinDuration seconds, the incoming animation is hard-rejected.

    Phase 3 — Animation Priority (Config.Priority):
        Within the same layer, higher Config.Priority wins.

    Phase 4 — Incumbent holds:
        All prior phases were equal. The conservative default is REJECT so the currently-
        playing animation is not needlessly interrupted. See the Bug #20 fix note below.

    ── Bug #20 Fix Note ─────────────────────────────────────────────────────────
    The original Phase 4 used `input.Now > activeTimestamp` as a "newer timestamp wins"
    tiebreaker. But input.Now is os.clock() at resolution time, which is always ≥
    activeTimestamp (the time the active animation started). So the incoming animation
    always appeared "newer" and always won — making Phase 4 an unconditional ALLOW.
    The correct conservative behaviour is REJECT: the incumbent holds in a true tie.
    A real "newer request wins" would require an IncomingTimestamp on the request itself,
    which PlayRequest does not currently carry.
]]

local Types = require(script.Parent.Types)

type AnimationConfig  = Types.AnimationConfig
type ConflictVerdict  = Types.ConflictVerdict

-- ─── Resolver Input ───────────────────────────────────────────────────────────

--[[
    ResolverInput bundles all data ConflictResolver.Resolve needs to evaluate a
    play request. Packaging inputs into a single record (rather than a long parameter
    list) makes call sites readable and makes it easy to add future phases without
    changing every caller's signature.
]]
export type ResolverInput = {
	-- The AnimationConfig of the animation being requested (the "challenger").
	IncomingConfig: AnimationConfig,

	-- Layer.Order value for the incoming animation's layer.
	-- Pre-fetched by the caller to avoid a LayerManager lookup inside this pure function.
	IncomingLayer: number,

	-- The AnimationConfig currently occupying the slot, or nil if the slot is empty.
	-- When nil, Resolve returns "ALLOW" immediately (no conflict to resolve).
	ActiveConfig: AnimationConfig?,

	-- Layer.Order value for the active animation's layer.
	-- May be nil when ActiveConfig is nil; also defaults to 0 if somehow missing.
	ActiveLayer: number?,

	-- os.clock() StartTimestamp of the active wrapper. Used in Phase 2b to compute
	-- how long the active animation has been playing when checking MinDuration.
	ActiveTimestamp: number?,

	-- Pre-computed verdict from ExclusiveGroupManager, required when both animations
	-- share the same Group. Nil when no group applies.
	GroupVerdict: ConflictVerdict?,

	-- Current timestamp (os.clock()) for Phase 2b elapsed-time calculation.
	-- Separate from ActiveTimestamp so the caller controls "now" (useful for testing).
	-- When nil, defaults to os.clock() inside Resolve.
	Now: number?,
}

-- ─── ConflictResolver ─────────────────────────────────────────────────────────

local ConflictResolver = {}

--[=[
    ConflictResolver.Resolve

    Description:
        Evaluates a play request against the currently active animation and returns
        a ConflictVerdict. This is a pure function — it reads its inputs and returns
        a result without modifying any state or triggering any callbacks.

        The four phases are evaluated in strict order. The first phase that reaches
        a decisive result (any result other than "fall through") short-circuits the
        remaining phases.

    Parameters:
        Input: ResolverInput
            All data needed for the four resolution phases. See ResolverInput above.

    Returns:
        ConflictVerdict
            "ALLOW"  — the incoming animation may proceed.
            "DEFER"  — the incoming animation must wait (only via Phase 1 GroupVerdict).
            "REJECT" — the incoming animation is blocked.

    Notes:
        DEFER can only be produced in Phase 1 (via the pre-computed GroupVerdict).
        Phases 2–4 never produce DEFER because non-grouped animations have no pending
        slot — their only options are play immediately or be discarded.
]=]
function ConflictResolver.Resolve(Input: ResolverInput): ConflictVerdict
	-- If there is no active animation, there is no conflict to resolve.
	-- The slot is empty so the incoming animation can always start immediately.
	if Input.ActiveConfig == nil then
		return "ALLOW"
	end

	-- ── Phase 1: ExclusiveGroup ───────────────────────────────────────────────
	--
	-- Group enforcement is handled by ExclusiveGroupManager, which evaluates
	-- CanInterrupt, MinDuration, and pending-slot logic. The result is pre-computed
	-- and passed in as GroupVerdict. This function's only job in Phase 1 is to
	-- recognize that a group conflict exists and defer to that pre-computed answer.
	--
	-- Both animations must share the SAME group for this phase to activate.
	-- If only one has a group (or they are in different groups), group logic is
	-- irrelevant and we fall through to layer priority.
	local IncomingGroup = Input.IncomingConfig.Group
	local ActiveGroup   = Input.ActiveConfig and Input.ActiveConfig.Group

	local BothShareSameGroup = (IncomingGroup ~= nil)
		and (ActiveGroup ~= nil)
		and (IncomingGroup == ActiveGroup)

	if BothShareSameGroup then
		-- GroupVerdict must be provided by the caller when group enforcement applies.
		-- If it is nil here, the caller has a bug — assert loudly rather than silently
		-- defaulting to ALLOW or REJECT, which could mask the missing setup.
		assert(
			Input.GroupVerdict ~= nil,
			"[ConflictResolver] GroupVerdict must be provided when both animations share a group"
		)
		return Input.GroupVerdict :: ConflictVerdict
	end

	-- ── Phase 2: Layer Priority ───────────────────────────────────────────────
	--
	-- Higher Layer.Order beats lower. This models the visual layering of the Animator:
	-- an "UpperBody" layer (Order 2) should always override a "BaseLocomotion" layer
	-- (Order 0) when they conflict, regardless of animation Priority values.
	--
	-- When orders differ, the result is decisive — no further phases needed.
	local IncomingLayerOrder = Input.IncomingLayer
	local ActiveLayerOrder   = Input.ActiveLayer or 0

	if IncomingLayerOrder > ActiveLayerOrder then
		-- Incoming is on a higher-priority layer — it wins outright.
		return "ALLOW"
	elseif IncomingLayerOrder < ActiveLayerOrder then
		-- Active is on a higher-priority layer — incoming is blocked outright.
		return "REJECT"
	end

	-- ── Phase 2b: CanInterrupt / MinDuration ─────────────────────────────────
	--
	-- Both animations are on the same layer order. Before comparing priorities,
	-- check whether the active animation is protected by CanInterrupt = false.
	--
	-- This mirrors the same logic ExclusiveGroupManager applies for grouped animations,
	-- applied here for non-grouped animations on the same layer. The fix addresses
	-- Bug #3, where CanInterrupt was previously ignored for non-grouped animations.
	--
	-- Non-grouped animations have no pending slot (unlike grouped ones), so if
	-- MinDuration has not elapsed the result is a hard REJECT — there is nowhere to
	-- queue the incoming animation for later.
	local ActiveConfig = Input.ActiveConfig :: AnimationConfig

	if not ActiveConfig.CanInterrupt then
		local Now     = Input.Now or os.clock()
		local Elapsed = Now - (Input.ActiveTimestamp or 0)
		local MinDuration = ActiveConfig.MinDuration or 0

		local IsStillWithinProtectedWindow = Elapsed < MinDuration

		if IsStillWithinProtectedWindow then
			-- The active animation has CanInterrupt = false and has not yet played
			-- for its full MinDuration. Block the incoming animation completely.
			-- There is no DEFER path for non-grouped animations.
			return "REJECT"
		end
		-- MinDuration has elapsed — CanInterrupt protection is now expired.
		-- Fall through to Phase 3 for priority comparison.
	end

	-- ── Phase 3: Animation Priority ───────────────────────────────────────────
	--
	-- Same layer, CanInterrupt protection not blocking. Compare Config.Priority values.
	-- Higher priority wins. This allows a "hit-stagger" animation (Priority 100) to
	-- always displace a "walk" animation (Priority 1) on the same layer.
	local IncomingPriority = Input.IncomingConfig.Priority
	local ActivePriority   = ActiveConfig.Priority

	if IncomingPriority > ActivePriority then
		return "ALLOW"
	elseif IncomingPriority < ActivePriority then
		return "REJECT"
	end

	-- ── Phase 4: Incumbent Holds ──────────────────────────────────────────────
	--
	-- All phases above produced a tie: same layer order, CanInterrupt not blocking,
	-- same Config.Priority. There is no meaningful axis left to differentiate them.
	--
	-- The conservative default is REJECT — the currently-playing animation holds.
	-- This prevents flicker or unnecessary interruptions when identical-priority
	-- animations race to play simultaneously (e.g. two systems both requesting "Idle").
	--
	-- Bug #20 fix: the original code used `input.Now > activeTimestamp` here, intending
	-- a "newer request wins" tiebreaker. But `input.Now` is always os.clock() at resolution
	-- time, which is always ≥ `activeTimestamp` (the time the ACTIVE animation started,
	-- which is in the past). So the incoming animation always appeared "newer" and always
	-- won, making Phase 4 an unconditional ALLOW that silently broke the tie-breaking intent.
	-- A genuine incoming-timestamp-wins tiebreaker would require PlayRequest.RequestTime
	-- to be threaded into ResolverInput, which is not yet done. Until then, REJECT is correct.
	return "REJECT"
end

-- ─── Convenience Wrapper ──────────────────────────────────────────────────────

--[=[
    ConflictResolver.ResolveNoGroup

    Description:
        Shorthand for ConflictResolver.Resolve on non-grouped animations.

        Populates Now from os.clock() automatically and leaves GroupVerdict nil,
        since non-grouped animations never reach Phase 1. Removes boilerplate at
        call sites where the group context is known to be absent.

    Parameters:
        IncomingConfig: AnimationConfig
            The animation being requested.

        IncomingLayerOrder: number
            Layer.Order of the incoming animation's layer.

        ActiveConfig: AnimationConfig?
            The currently active animation config, or nil if the slot is empty.

        ActiveLayerOrder: number?
            Layer.Order of the active animation's layer. Defaults to 0 if nil.

        ActiveTimestamp: number?
            os.clock() when the active animation started. Used for Phase 2b elapsed check.

    Returns:
        ConflictVerdict
            "ALLOW" or "REJECT" (never "DEFER" — non-grouped animations have no pending slot).
]=]
function ConflictResolver.ResolveNoGroup(
	IncomingConfig: AnimationConfig,
	IncomingLayerOrder: number,
	ActiveConfig: AnimationConfig?,
	ActiveLayerOrder: number?,
	ActiveTimestamp: number?
): ConflictVerdict
	return ConflictResolver.Resolve({
		IncomingConfig  = IncomingConfig,
		IncomingLayer   = IncomingLayerOrder,
		ActiveConfig    = ActiveConfig,
		ActiveLayer     = ActiveLayerOrder,
		ActiveTimestamp = ActiveTimestamp,
		GroupVerdict    = nil,
		-- Pass os.clock() here so Phase 2b and Phase 4 have a consistent "now"
		-- for the elapsed-time calculation, rather than letting Resolve call
		-- os.clock() internally (which would be a different value if this is called
		-- mid-frame and there is system clock jitter).
		Now             = os.clock(),
	})
end

return ConflictResolver