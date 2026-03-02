--!strict
-- ─── StateMachine.lua ────────────────────────────────────────────────────────
--[[
    Owned exclusively by AnimationController. One instance exists per character.

    This module implements a flat, finite-state machine (FSM) that governs which
    animation states a character can be in and how they transition between them.
    "Flat" means there is no concept of nested or hierarchical states — every state
    exists at the same level and transitions are first-class records with priorities.

    Responsibilities:
        - Store and index all StateDefinitions registered at construction time.
        - Each tick, evaluate every outgoing TransitionRule from the current state
          by invoking its associated predicate function. The highest-priority true
          predicate wins; at most one transition fires per tick.
        - Accept externally queued transitions (e.g. from combat or movement systems)
          via RequestTransition, which are processed before condition-driven rules.
        - When a transition fires, invoke the onStateChange callback so AnimationController
          can dispatch entry/exit animation directives and layer weight changes.

    What this module does NOT do:
        - It does not play or stop AnimationTracks directly. That is the
          responsibility of AnimationController, which receives the transition
          callback and translates StateDefinition directives into wrapper operations.
        - It does not know about layers, groups, or replication. It is a pure
          FSM with a notification hook.

    Design note — why a flat FSM:
        Hierarchical state machines (e.g. HSMs) offer elegant handling of shared
        behaviour across state families, but they add significant complexity to
        traversal and diff logic. Because animation layers already provide a
        compositing mechanism for concurrent behaviour, a flat FSM is sufficient
        and much easier to validate and debug.
]]

local Types = require(script.Parent.Types)

-- Import type aliases so the strict type checker can verify all call sites.
type StateDefinition    = Types.StateDefinition
type TransitionRule     = Types.TransitionRule
type AnimationDirective = Types.AnimationDirective

-- ─── Internal Types ───────────────────────────────────────────────────────────

--[[
    PredicateFn is the type of every condition function registered with the FSM.
    It takes no arguments and returns a boolean indicating whether its associated
    TransitionRule's condition is currently satisfied. Predicates are evaluated
    every tick and must be cheap (no yielding, no allocation if avoidable).
]]
type PredicateFn = () -> boolean

--[[
    PendingTransition represents a transition request submitted externally via
    RequestTransition. It holds both the destination state name and a priority
    value so that if multiple external requests arrive in the same tick, only
    the highest-priority one is applied.
]]
type PendingTransition = {
	ToState  : string,
	Priority : number,
}

-- ─── Module Table ─────────────────────────────────────────────────────────────

--[[
    StateMachine is the module and metatable. Setting __index = StateMachine
    means every instance created via setmetatable({}, StateMachine) will look up
    missing keys on the module table, making all methods available as instance methods.
]]
local StateMachine = {}
StateMachine.__index = StateMachine

-- ─── Exported Type ────────────────────────────────────────────────────────────

--[[
    The exported type surface is expressed using typeof(setmetatable(...)) so that
    the Luau type checker can infer method signatures from the metatable without
    requiring a separate hand-written interface type. This is the idiomatic pattern
    for Luau OOP type exports.

    Fields:
        _States             — All registered StateDefinitions, keyed by Name.
        _Predicates         — All registered predicate functions, keyed by their
                              condition string (e.g. "IsGrounded", "IsInCombat").
        _CurrentState       — The name of the state currently active.
        _PendingTransitions — External transition requests awaiting the next tick.
        _TransitionTime     — os.clock() timestamp of the most recent transition.
                              Used by GetSnapshot to report time-since-transition.
        _OnStateChange      — Callback fired when a transition commits. Receives the
                              exiting StateDefinition and entering StateDefinition in
                              that order. Nil if no callback was provided (valid for
                              testing or headless simulation).
        _TerminalStates     — Set of state names that have no outgoing transitions.
                              Built once at init; queried by IsTerminal.
        _SortedTransitions  — Pre-sorted copy of each state's Transitions array,
                              keyed by state name. Sorted descending by Priority.
                              Built once at construction by _ValidateGraph so that
                              Tick never has to sort or clone during gameplay.
]]
export type StateMachine = typeof(setmetatable({} :: {
	_States             : { [string]: StateDefinition },
	_Predicates         : { [string]: PredicateFn },
	_CurrentState       : string,
	_PendingTransitions : { PendingTransition },
	_TransitionTime     : number,
	_OnStateChange      : ((ExitState: StateDefinition, EnterState: StateDefinition) -> ())?,
	_TerminalStates     : { [string]: boolean },
	_SortedTransitions  : { [string]: { TransitionRule } },
}, StateMachine))

-- ─── Constructor ──────────────────────────────────────────────────────────────

--[=[
    StateMachine.New

    Description:
        Constructs a new StateMachine instance, indexes all provided state
        definitions, validates the transition graph for integrity, pre-sorts
        every state's transition list by Priority (descending), and records
        which states are terminal (no outgoing transitions).

        Construction is the only time expensive validation and sorting work is
        done. All per-tick operations are O(T) where T is the number of outgoing
        transitions from the current state, with no allocations.

    Parameters:
        States        : { StateDefinition }
            Array of all state records the FSM will manage. Each must have a
            unique Name. The order of the array does not affect runtime behaviour.

        InitialState  : string
            The name of the state the FSM begins in. Must exist in States.
            Validated at construction; a missing initial state is a fatal error
            because the entire FSM is unusable without a valid starting point.

        Predicates    : { [string]: PredicateFn }
            Dictionary mapping condition-name strings to zero-argument boolean
            functions. Every condition string referenced in a TransitionRule must
            have a matching entry here; this is enforced during _ValidateGraph.
            Predicates are supplied externally so that the FSM remains decoupled
            from game-specific logic (movement, combat, etc.).

        OnStateChange : ((StateDefinition, StateDefinition) -> ())?
            Optional callback invoked when a transition commits. The first argument
            is the StateDefinition being exited; the second is the one being entered.
            Nil is acceptable for headless tests that only care about state names.

    Returns:
        StateMachine
            A fully initialized FSM ready to accept Tick calls.

    Notes:
        _ValidateGraph will call error() (via assert) if the graph contains any
        of: undefined destination states, undefined predicate conditions, or a
        missing initial state. These are all programming errors that must be
        caught at startup, not silently ignored at runtime.
]=]
function StateMachine.New(
	States        : { StateDefinition },
	InitialState  : string,
	Predicates    : { [string]: PredicateFn },
	OnStateChange : ((StateDefinition, StateDefinition) -> ())?
): StateMachine

	local Self = setmetatable({
		_States             = {} :: { [string]: StateDefinition },
		_Predicates         = Predicates,
		_CurrentState       = InitialState,
		_PendingTransitions = {} :: { PendingTransition },
		_TransitionTime     = os.clock(),
		_OnStateChange      = OnStateChange,
		_TerminalStates     = {} :: { [string]: boolean },
		_SortedTransitions  = {} :: { [string]: { TransitionRule } },
	}, StateMachine)

	-- Index every state by its Name so GetCurrentState and _DoTransition can
	-- perform O(1) lookups instead of scanning the array on every access.
	for _, StateRecord in States do
		assert(
			not Self._States[StateRecord.Name],
			string.format("[StateMachine] Duplicate state name '%s'", StateRecord.Name)
		)
		Self._States[StateRecord.Name] = StateRecord
	end

	-- Verify the requested initial state actually exists. Failing here is
	-- intentional — an FSM with a nonexistent starting state cannot function.
	assert(
		Self._States[InitialState],
		string.format("[StateMachine] Initial state '%s' not defined", InitialState)
	)

	-- Validate the full graph and build pre-sorted transition tables.
	-- This is the only moment we allocate the sorted arrays; Tick reuses them.
	Self:_ValidateGraph()

	return Self
end

-- ─── Graph Validation ─────────────────────────────────────────────────────────

--[=[
    _ValidateGraph

    Description:
        Walks the full transition graph at construction time and asserts that:
          1. Every TransitionRule's ToState references a defined state.
          2. Every TransitionRule's Condition string has a registered predicate.

        In addition to validation, this method builds _SortedTransitions — a
        pre-sorted (descending Priority) copy of each state's Transitions array.
        Doing this once at construction eliminates the need to sort or clone
        inside Tick, which runs every frame.

        States with no outgoing transitions are classified as terminal states and
        recorded in _TerminalStates. Tick exits early for terminal states, and
        IsTerminal exposes this for external query.

    Parameters:
        None. Operates entirely on Self.

    Returns:
        Nothing. Mutates Self._TerminalStates and Self._SortedTransitions in place.

    Notes:
        This is the primary safety net for configuration errors. In a shipping
        game, all asserts here should trip only during development; by launch the
        graph should be fully validated and these paths should never execute.
]=]
function StateMachine:_ValidateGraph()
	for StateName, StateRecord in self._States do
		-- Verify each rule's destination and condition are properly defined.
		for _, Rule in StateRecord.Transitions do
			assert(
				self._States[Rule.ToState],
				string.format(
					"[StateMachine] State '%s' has transition to undefined state '%s'",
					StateName, Rule.ToState
				)
			)
			assert(
				self._Predicates[Rule.Condition],
				string.format(
					"[StateMachine] State '%s' transition references undefined predicate '%s'",
					StateName, Rule.Condition
				)
			)
		end

		-- A state with no outgoing transitions is "terminal" — the FSM will rest
		-- here indefinitely unless an external RequestTransition is submitted.
		-- This is valid for end states like "Dead" or "Ragdoll".
		if #StateRecord.Transitions == 0 then
			self._TerminalStates[StateName] = true
		end

        --[[
            Build a priority-sorted copy of this state's transition list.

            Why sort here instead of in Tick?
            Tick is called every frame (60+ times per second per character).
            table.clone + table.sort on even a small array allocates a new table
            and invokes the garbage collector more frequently. By sorting once at
            construction time and storing the result, Tick iterates a static array
            with zero allocation cost, regardless of how many states or transitions
            the FSM has.

            Sorted descending so index 1 is always the highest-priority rule,
            allowing Tick to break out of its loop as soon as it descends below
            the best-found priority.
        ]]
		local SortedRules = table.clone(StateRecord.Transitions)
		table.sort(SortedRules, function(RuleA, RuleB)
			return RuleA.Priority > RuleB.Priority
		end)
		self._SortedTransitions[StateName] = SortedRules
	end
end

-- ─── Per-Tick Evaluation ──────────────────────────────────────────────────────

--[=[
    Tick

    Description:
        Called once per frame by AnimationController at Step 1 of the update
        pipeline — before layer weight interpolation, weight pushing, replication
        flushing, or pending queue execution.

        Tick performs two distinct phases in order:

        Phase A — External (queued) transitions:
            If any transitions were submitted via RequestTransition since the last
            tick, the highest-priority one is applied immediately and the function
            returns. Pending transitions take unconditional precedence over
            predicate-driven transitions to ensure that explicit game-logic commands
            (e.g. "go to Death state now") cannot be blocked by an automatically
            firing condition.

        Phase B — Condition-driven transitions:
            If no pending transitions exist, Tick iterates the pre-sorted transition
            list of the current state. Each rule's predicate is evaluated in
            descending priority order. The first true predicate at the highest
            priority level wins. At most one transition fires per tick.

    Parameters:
        None.

    Returns:
        Nothing. Side effects: may call _DoTransition, which fires _OnStateChange.

    Notes:
        Bug #16 fix context:
            The original implementation gated predicate evaluation behind
            `rule.Priority > bestPriority`. This meant that if a lower-priority
            rule was found true first, higher-priority rules were never tested,
            because the early-exit condition prevented the loop from reaching them.
            The fix uses a sorted list so the highest-priority rules are always
            evaluated first; iteration stops only when we descend below the
            best-found priority level, which is safe because no later rule can
            beat the current best.

        Bug W fix context:
            Sorting a single-element PendingTransitions slice still invokes the
            Lua sort internals and allocates an internal comparison buffer. When
            only one pending transition exists, sorting is unnecessary — we skip
            it as a micro-optimisation to reduce GC pressure on characters that
            receive frequent single-transition requests.
]=]
function StateMachine:Tick()
	-- ── Phase A: Process externally queued transitions first ──────────────
	-- External systems (combat, movement, cutscene managers) may have submitted
	-- transition requests via RequestTransition. These represent intentional,
	-- explicit commands that must override automatic predicate evaluation.
	if #self._PendingTransitions > 0 then
		-- Only sort when multiple transitions are competing; a single entry needs
		-- no comparison. This avoids the allocation cost of sort for the common
		-- case where exactly one external transition arrives per tick.
		if #self._PendingTransitions > 1 then
			table.sort(self._PendingTransitions, function(A, B)
				return A.Priority > B.Priority
			end)
		end

		local BestPending = self._PendingTransitions[1]

		-- Bug #8 fix: clear the queue AFTER a successful transition, not before.
		-- If _DoTransition asserts (e.g. undefined target state), the pending
		-- entry is preserved and can be inspected or retried. Clearing before
		-- would silently lose the request, making the failure impossible to diagnose.
		self:_DoTransition(BestPending.ToState)
		table.clear(self._PendingTransitions)
		return
	end

	-- ── Phase B: Evaluate condition-driven transitions ─────────────────────
	-- Look up the current state record. If this state has no transitions (terminal)
	-- the early-out prevents any evaluation, which is correct — terminal states
	-- cannot transition autonomously.
	local CurrentStateRecord = self._States[self._CurrentState]
	local IsTerminalState    = not CurrentStateRecord or #CurrentStateRecord.Transitions == 0

	if IsTerminalState then
		return
	end

	-- Retrieve the pre-sorted transition list built by _ValidateGraph.
	-- This is a static array; iterating it costs no allocation.
	local SortedRules = self._SortedTransitions[self._CurrentState]
	local BestMatchingRule: TransitionRule? = nil

	for _, Rule in SortedRules do
		-- Once we have found a winning rule and the current rule's priority is
		-- strictly lower, no subsequent rule can beat the winner — exit early.
		-- This is only safe because the array is already sorted descending.
		local IsLowerPriorityThanBest = BestMatchingRule ~= nil
			and Rule.Priority < BestMatchingRule.Priority

		if IsLowerPriorityThanBest then
			break
		end

		local PredicateFn = self._Predicates[Rule.Condition]
		local IsConditionMet = PredicateFn and PredicateFn()

		if IsConditionMet then
			-- Accept the first true predicate at the highest priority level.
			-- If two rules share the same priority, we keep the first winner
			-- (stable within a priority band). We continue scanning only to
			-- handle ties, where the first true match in sorted order wins.
			if BestMatchingRule == nil then
				BestMatchingRule = Rule
			end
		end
	end

	if BestMatchingRule then
		self:_DoTransition(BestMatchingRule.ToState)
	end
end

-- ─── Transition Execution ─────────────────────────────────────────────────────

--[=[
    _DoTransition

    Description:
        Commits a state transition from the current state to the named target.
        Updates _CurrentState and _TransitionTime, then fires _OnStateChange so
        AnimationController can dispatch directives and adjust layer weights.

    Parameters:
        ToStateName : string
            The name of the destination state. Must exist in _States. An undefined
            target is a programming error and triggers an assert.

    Returns:
        Nothing. Mutates _CurrentState, _TransitionTime, and fires _OnStateChange.

    Notes:
        Self-transition guard:
            If ToStateName equals the current state, the method returns immediately
            without firing _OnStateChange. This matters because a self-transition
            would execute all ExitActions followed by all EntryActions for the same
            state, stopping animations that should keep playing. The guard preserves
            idempotency when the same state is requested redundantly.

        Bug U fix context:
            _CurrentState is updated BEFORE _OnStateChange fires. The callback runs
            AnimationController:_ActivateWrapper, which calls
            StateMachine:GetCurrentStateName to tag the outgoing intent with the
            correct state context. If _CurrentState were updated after the callback,
            every intent queued during entry actions would be tagged with the exiting
            state name, corrupting the replication StateContext field.
]=]
function StateMachine:_DoTransition(ToStateName: string)
	-- Self-transitions are silently suppressed. Replaying exit and entry actions
	-- for a state the FSM is already in would stop and restart animations that
	-- should be playing continuously (e.g. an idle loop). Guard against this.
	if ToStateName == self._CurrentState then
		return
	end

	local ExitingStateRecord  = self._States[self._CurrentState]
	local EnteringStateRecord = self._States[ToStateName]

	-- Validate the target exists. Undefined destinations are always programming
	-- errors — the graph should have been validated at construction. This assert
	-- is a last-resort safety net for dynamically requested transitions.
	assert(
		EnteringStateRecord,
		string.format("[StateMachine] Transition target '%s' not defined", ToStateName)
	)

	-- Bug U fix: assign the new state BEFORE firing the callback. Any code
	-- executing inside _OnStateChange (e.g. _ActivateWrapper calling
	-- GetCurrentStateName) must see the new state, not the old one.
	self._CurrentState   = ToStateName
	self._TransitionTime = os.clock()

	if self._OnStateChange then
		self._OnStateChange(ExitingStateRecord, EnteringStateRecord)
	end
end

-- ─── External Transition Request ─────────────────────────────────────────────

--[=[
    RequestTransition

    Description:
        Enqueues a transition request for evaluation at the start of the next Tick.
        Used by external systems (combat manager, cutscene controller, etc.) to
        drive the FSM toward a specific state without evaluating predicate conditions.

        Pending transitions are not applied immediately — they are batched and the
        highest-priority one wins at the top of the next Tick. This design ensures
        that all state changes occur at a single well-known point in the update
        pipeline (Tick's Phase A), preventing mid-frame state mutations that could
        corrupt the weight push or directive dispatch steps.

    Parameters:
        ToState  : string
            The name of the target state. Must exist in _States; validated here
            with an assert so callers discover mistakes at the call site rather
            than later inside Tick.

        Priority : number
            Higher values take precedence when multiple external transitions are
            queued in the same tick. Use large values (e.g. math.huge) for
            unconditional overrides such as snapshot reconciliation.

    Returns:
        Nothing.
]=]
function StateMachine:RequestTransition(ToState: string, Priority: number)
	assert(
		self._States[ToState],
		string.format("[StateMachine] Requested transition to undefined state '%s'", ToState)
	)
	table.insert(self._PendingTransitions, {
		ToState  = ToState,
		Priority = Priority,
	})
end

-- ─── Queries ──────────────────────────────────────────────────────────────────

--[=[
    GetCurrentState

    Description:
        Returns the full StateDefinition record for the currently active state.
        Used by AnimationController and external systems that need to read the
        full state configuration (EntryActions, ExitActions, ActiveLayers, etc.)
        rather than just the name.

    Returns:
        StateDefinition
            The live StateDefinition object from _States. Callers must not mutate it.
]=]
function StateMachine:GetCurrentState(): StateDefinition
	return self._States[self._CurrentState]
end

--[=[
    GetCurrentStateName

    Description:
        Returns the string name of the currently active state.

        This is the lightweight query used frequently by AnimationController to
        tag replication intents with the current state context. It avoids the
        overhead of returning the full StateDefinition record when only the name
        is needed.

    Returns:
        string
            The name of the active state. Always non-nil after construction.
]=]
function StateMachine:GetCurrentStateName(): string
	return self._CurrentState
end

--[=[
    IsTerminal

    Description:
        Returns whether the current state is terminal — i.e. has no outgoing
        transitions and can only be exited via an explicit RequestTransition.

        Used by external systems to determine whether the character has reached
        a stable final state (e.g. "Dead") and no further automatic transitions
        are possible.

    Returns:
        boolean
            True if the current state has no outgoing TransitionRules, false otherwise.
]=]
function StateMachine:IsTerminal(): boolean
	return self._TerminalStates[self._CurrentState] == true
end

-- ─── Debug Snapshot ───────────────────────────────────────────────────────────

--[=[
    GetSnapshot

    Description:
        Returns a plain table snapshot of the FSM's current runtime state for
        consumption by DebugInspector. The snapshot is a copy, not a reference,
        so it cannot be used to mutate internal state.

    Returns:
        { [string]: any }
            A dictionary containing:
                CurrentState        — Name of the active state.
                TimeSinceTransition — Seconds elapsed since the last transition.
                PendingTransitions  — Array of pending destination state names.
]=]
function StateMachine:GetSnapshot(): { [string]: any }
	-- Collect only the destination names, not the full PendingTransition records,
	-- so the snapshot remains a lightweight plain-data structure.
	local PendingNames: { string } = {}
	for _, PendingTransition in self._PendingTransitions do
		table.insert(PendingNames, PendingTransition.ToState)
	end

	return {
		CurrentState        = self._CurrentState,
		TimeSinceTransition = os.clock() - self._TransitionTime,
		PendingTransitions  = PendingNames,
	}
end

return StateMachine