--!strict
-- ─── Types.lua ────────────────────────────────────────────────────────────────
--[[
    Shared structural type definitions for the entire Animation Controller Framework.

    This module is the single source of truth for every data shape used across all
    subsystems. All other modules import from here rather than declaring local types.
    This design prevents type drift (where two modules silently diverge on what a
    "config" looks like), makes the data model auditable in one place, and allows the
    Luau type checker to catch cross-module structural mismatches at analysis time
    rather than at runtime.

    No runtime logic lives here. The module exports an empty table at the bottom
    because Luau's `require` system requires a return value — the actual value of this
    file is entirely in the type declarations, which are erased by the type system
    and produce zero runtime overhead.
]]

-- ─── Animation Configuration ──────────────────────────────────────────────────

--[[
    AnimationConfig is the immutable descriptor for a single animation asset and all
    of its playback parameters.

    Instances originate as raw tables submitted to AnimationRegistry.Init, where they
    are validated, shallow-cloned, deep-frozen, and indexed. After Init completes,
    every consumer receives a reference to the same frozen object. No subsystem ever
    mutates an AnimationConfig — this immutability makes it safe to share one reference
    across multiple TrackWrappers, the ConflictResolver, the GroupManager, and any
    debug tooling simultaneously.

    Fields are ordered from most-commonly-queried to least, purely for readability.
]]
export type AnimationConfig = {
	-- Unique human-readable name. The primary key everywhere in the framework:
	-- registry lookups, ActiveWrappers map, wrapper pool, play-request queue.
	-- Must be globally unique across all registered configs — the registry asserts
	-- on duplicates during Init.
	Name: string,

	-- Roblox asset ID string, e.g. "rbxassetid://123456789".
	-- Passed verbatim to Animation.AnimationId before loading a track on the client.
	-- The server never reads this field because it does not load AnimationTracks.
	AssetId: string,

	-- Name of the logical layer this animation is assigned to.
	-- Must match exactly one LayerProfile.Name supplied to LayerManager at construction.
	-- Determines which other animations compete in the same priority space and which
	-- can coexist on separate layers simultaneously.
	Layer: string,

	-- Optional exclusive-group name. When present, ExclusiveGroupManager ensures at
	-- most one animation in this group carries non-zero weight at any time.
	-- When nil, the animation participates in standard layer-priority conflict resolution
	-- handled by ConflictResolver, with no mutual-exclusivity enforcement beyond layer order.
	Group: string?,

	-- Numeric priority for ConflictResolver Phase 3.
	-- When two non-grouped animations compete on the same layer, the one with the higher
	-- Priority wins. Ties proceed to Phase 4 (timestamp). There is no upper bound on
	-- this value; game code can assign arbitrary integers.
	Priority: number,

	-- Whether the AnimationTrack should loop continuously.
	-- Non-looped animations fire CompletedSignal when they reach their natural end,
	-- which is how ExclusiveGroupManager promotes pending grouped successors.
	-- Looped animations never fire CompletedSignal naturally; manual Stop is required.
	Looped: boolean,

	-- Seconds to crossfade this animation IN when it begins playing.
	-- Passed as the first argument to AnimationTrack:Play(FadeInTime, ...).
	-- A value of 0 causes an instant snap to full weight with no visual blend.
	FadeInTime: number,

	-- Seconds to crossfade this animation OUT when it is stopped.
	-- Passed to AnimationTrack:Stop(FadeOutTime). A value of 0 causes an instant hard stop.
	-- During a fade-out the wrapper's IsFading flag remains true and it stays in
	-- ActiveWrappers until EffectiveWeight reaches 0, at which point _RetireWrapper fires.
	FadeOutTime: number,

	-- Playback speed multiplier applied via AnimationTrack:AdjustSpeed.
	-- 1.0 = normal speed. Values below 1 slow the animation; values above 1 speed it up.
	Speed: number,

	-- Governs whether a competing incoming animation may interrupt this one.
	-- When false, ConflictResolver and ExclusiveGroupManager will DEFER or REJECT
	-- challengers until MinDuration seconds have elapsed since this animation started.
	-- When true, any higher-or-equal-priority challenger may immediately displace it.
	CanInterrupt: boolean,

	-- Arbitrary string tags. A single config can carry multiple tags.
	-- Used by AnimationController:PlayTag to trigger all animations bearing a given tag
	-- in one call (e.g. playing every animation tagged "locomotion" at once).
	Tags: { string },

	-- Whether this animation blends additively on top of lower-priority layers.
	-- Informational at the framework level; the Roblox engine handles actual additive
	-- blending through AnimationPriority. Stored here for DebugInspector display.
	Additive: boolean,

	-- Base weight contribution within its layer.
	-- The final EffectiveWeight pushed to the track is:
	--   Layer.CurrentWeight × TrackWrapper.TargetWeight × AnimationConfig.Weight
	-- Must be in the half-open interval (0, 1] — the registry rejects values outside
	-- this range at Init time. A value of 1.0 means this animation uses the full layer weight.
	Weight: number,

	-- Optional minimum play duration in seconds before CanInterrupt=false protection ends.
	-- When nil, protection lasts indefinitely (only CanInterrupt=true releases it).
	-- On the server, where no real AnimationTrack exists, this value doubles as a proxy
	-- for the animation's natural length, used by task.delay in TrackWrapper._Play to
	-- simulate non-looped completion so group succession still works server-side.
	MinDuration: number?,

	-- Optional free-form metadata table for game-specific use.
	-- The framework itself never reads this field; it is reserved for downstream systems
	-- (e.g. a sound controller that reads "SoundId" from metadata alongside an animation).
	-- Deep-frozen by AnimationRegistry after Init so nested tables are also immutable.
	Metadata: { [string]: any }?,
}

-- ─── Layer Profile ────────────────────────────────────────────────────────────

--[[
    LayerProfile is the static configuration for a logical animation layer. Profiles
    are supplied to LayerManager at construction time and never change after that point.
    LayerManager builds a LayerRecord from each profile, adding runtime-mutable fields
    (CurrentWeight, TargetWeight, ActiveTracks) on top of these immutable values.

    Layers represent independent blend channels on the character's Animator.
    A typical setup might have a "BaseLocomotion" layer (Order 0), an "UpperBody" layer
    (Order 1), and a "Facial" layer (Order 2). Higher-order layers visually override
    lower-order ones for the bones they affect.
]]
export type LayerProfile = {
	-- Unique name for this layer. Must match AnimationConfig.Layer strings exactly.
	-- Used as the key into LayerManager._LayerByName for O(1) lookups.
	Name: string,

	-- Numeric rank controlling priority in conflict resolution and display ordering.
	-- Higher Order = higher visual priority. Must be unique across all profiles;
	-- LayerManager asserts on duplicate orders at construction time.
	Order: number,

	-- The weight this layer rests at when no state has overridden it.
	-- LayerManager:SetLayerToBase restores CurrentWeight toward this value.
	-- Typically 1.0 for base layers and 0.0 for layers that are only raised on demand.
	BaseWeight: number,

	-- Mirrors the additive concept from AnimationConfig; stored at the layer level
	-- for DebugInspector reporting and future layer-global blend mode logic.
	Additive: boolean,

	-- Whether this layer is isolated from other layers during blending.
	-- Informational at this level; enforcement is via the Roblox Animator's
	-- AnimationPriority system when tracks are loaded.
	Isolated: boolean,

	-- Rate (weight units per second) at which CurrentWeight interpolates toward TargetWeight.
	-- A value of math.huge produces an instant snap with no lerp animation.
	-- Lower values create slower, more cinematic weight transitions.
	WeightLerpRate: number,
}

-- ─── Animation Directive ──────────────────────────────────────────────────────

--[[
    AnimationDirective is a play or stop instruction emitted by the StateMachine
    during state transitions (EntryActions and ExitActions). AnimationController
    receives these from its _OnStateChange callback and routes each one through its
    public Play/Stop/StopGroup API.

    Importantly, directives do NOT execute immediately inline — they are enqueued
    (via AnimationController.Play/Stop which writes to PendingQueue or ActiveWrappers)
    and flushed at Step 5 of the tick, after layer weights have been interpolated.
    This guarantees that animations started in response to a state change receive
    correct layer weights from their very first frame. See the Bug #12 fix notes in
    AnimationController for the full rationale.
]]
export type AnimationDirective = {
	-- The operation to perform:
	--   "PLAY"       → AnimationController:Play(Target)
	--   "STOP"       → AnimationController:Stop(Target, Immediate)
	--   "STOP_GROUP" → AnimationController:StopGroup(Target, Immediate)
	Action: "PLAY" | "STOP" | "STOP_GROUP",

	-- For PLAY/STOP: the animation config name to operate on.
	-- For STOP_GROUP: the group name whose active animation should be stopped.
	Target: string,

	-- Controls the stop behaviour for STOP and STOP_GROUP:
	--   true  → hard stop with no fade-out (FadeOutTime is ignored).
	--   false → graceful fade-out using the config's FadeOutTime.
	-- Has no effect for PLAY directives (fade-in is always governed by FadeInTime).
	Immediate: boolean,
}

-- ─── Transition Rule ──────────────────────────────────────────────────────────

--[[
    TransitionRule defines one directed edge in the StateMachine's transition graph.
    Each StateDefinition carries an array of TransitionRules, each pointing to a
    target state and the predicate condition that enables it.

    Every tick, StateMachine evaluates all rules for the current state in descending
    Priority order and fires the first one whose predicate returns true.
]]
export type TransitionRule = {
	-- The name of the state to transition to when this rule's predicate is true.
	-- Must reference a state that was registered with StateMachine.new.
	-- Validated at construction time in StateMachine._ValidateGraph.
	ToState: string,

	-- Key into the predicates table supplied to StateMachine.new.
	-- StateMachine calls Predicates[Condition]() each tick; when it returns true
	-- this rule becomes a candidate for the next state transition.
	-- Validated at construction time — an unknown key causes a fatal assert.
	Condition: string,

	-- Tie-breaking value when multiple conditions are simultaneously true in a tick.
	-- Higher value wins. Within a priority band, declaration order is the secondary sort.
	-- Allows certain transitions (e.g. "take damage → stagger") to always beat others
	-- (e.g. "idle timeout → walk") regardless of predicate evaluation order.
	Priority: number,
}

-- ─── State Definition ─────────────────────────────────────────────────────────

--[[
    StateDefinition describes one node in the StateMachine's directed graph. It
    declares what animations to start/stop when entering and leaving, which layers
    should be active or suppressed while it is the current state, and the outgoing
    transitions that can move the machine to other states.

    The StateMachine never directly manipulates animations — it issues AnimationDirectives
    and layer commands through the AnimationController callback, keeping animation
    logic cleanly separated from state logic.
]]
export type StateDefinition = {
	-- Unique identifier for this state. Used as the key in StateMachine._States.
	-- Must be unique within the set of states passed to StateMachine.new.
	Name: string,

	-- Directives executed when transitioning INTO this state.
	-- Fired after the exiting state's ExitActions have been dispatched.
	-- Typically used to start the animations that represent this state visually.
	EntryActions: { AnimationDirective },

	-- Directives executed when transitioning OUT OF this state.
	-- Fired before the entering state's EntryActions are dispatched.
	-- Typically used to stop or fade out animations that belong exclusively to this state.
	ExitActions: { AnimationDirective },

	-- Outgoing TransitionRules evaluated every tick while this is the current state.
	-- An empty array makes this a terminal state with no automatic exits.
	Transitions: { TransitionRule },

	-- Names of layers to set to their BaseWeight when this state is active.
	-- Layers listed here that were not listed in the previous state's ActiveLayers
	-- are raised; layers that were active before but aren't listed here are restored
	-- to BaseWeight when transitioning away. See _OnStateChange for the full diff logic.
	ActiveLayers: { string },

	-- Names of layers to suppress (weight → 0) while this state is active.
	-- Useful for disabling a lower layer (e.g. legs) during a specific animation.
	-- Restored to BaseWeight when the state exits and the entering state does not
	-- also suppress them.
	SuppressLayers: { string },
}

-- ─── Animation Intent ─────────────────────────────────────────────────────────

--[[
    AnimationIntent is the network replication primitive. It records what the owning
    client has already done (played or stopped an animation) so the server can validate
    authorship and relay the information to non-owning clients.

    The design is intentional: intents describe past actions, not future commands.
    The owning client is the animation authority for its own character. It plays
    animations in direct response to its own input and game logic, then sends intents
    as a notification. The server never decides what animations to play — it only
    validates that the sender is the correct owner and rebroadcasts to others.
    This avoids the latency of waiting for server round-trip confirmation before
    an animation can start.
]]
export type AnimationIntent = {
	-- Matches ControllerConfig.CharacterId for the character this intent describes.
	-- Used server-side to verify the sending player owns this character (anti-spoofing).
	CharacterId: string,

	-- The config Name of the animation that was played or stopped.
	AnimationName: string,

	-- "PLAY" if the animation was started; "STOP" if it was stopped.
	Action: "PLAY" | "STOP",

	-- workspace:GetServerTimeNow() at the instant the intent was created.
	-- Server-synchronized time is used (not os.clock()) so the age calculation in
	-- _HandleClientIntent is meaningful across the network boundary.
	-- Intents older than STALE_INTENT_THRESHOLD_S are discarded as too late to be useful.
	Timestamp: number,
}

-- ─── Play Request ─────────────────────────────────────────────────────────────

--[[
    PlayRequest is an internal queue record created when AnimationController:Play is called.

    Rather than executing play logic immediately, Play enqueues a PlayRequest into
    PendingQueue. _FlushPendingQueue processes the queue at Step 5 of the per-frame tick,
    after LayerManager has interpolated all layer weights (Step 2) and _PushWeights has
    propagated them (Step 3). This ordering guarantees that any animation started in
    response to a state transition sees the correct layer weights on its very first frame.

    See the Bug #12 fix notes in AnimationController._OnStateChange for the full rationale.
]]
export type PlayRequest = {
	-- The AnimationConfig.Name to look up in the registry and play.
	ConfigName: string,

	-- os.clock() at the moment AnimationController:Play was called.
	-- Not currently used in conflict resolution, but reserved as a future
	-- IncomingTimestamp so ConflictResolver Phase 4 can properly compare the
	-- age of a new request against the incumbent's StartTimestamp.
	RequestTime: number,
}

-- ─── Conflict Verdict ─────────────────────────────────────────────────────────

--[[
    ConflictVerdict is the output of ConflictResolver.Resolve and
    ExclusiveGroupManager.EvaluatePlayRequest. It encodes the outcome of comparing
    an incoming animation against the currently-active animation.

        "ALLOW"  — The incoming animation wins. The caller should stop the active
                   animation (if any) and begin playing the incoming one.

        "DEFER"  — The incoming animation must wait. It is stored as a PendingWrapper
                   in its ExclusiveGroup and will be re-evaluated once the active
                   animation's MinDuration has elapsed. Only possible for grouped animations.

        "REJECT" — The incoming animation loses. The caller should discard it
                   without playing. The currently-active animation is undisturbed.
]]
export type ConflictVerdict = "ALLOW" | "DEFER" | "REJECT"

-- This module exports no runtime values. The empty table satisfies Luau's
-- require() return requirement while the type declarations above do all the work.
return {}