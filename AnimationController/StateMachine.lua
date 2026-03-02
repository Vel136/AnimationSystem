--!strict
-- StateMachine.lua
-- Owned by AnimationController.
-- Flat, finite set of named states with defined transitions.
-- On state change, issues directives to LayerManager and ExclusiveGroupManager
-- via AnimationController. Does NOT play animations directly.
-- Transitions are evaluated once per tick at the top of the update pipeline.

local Types = require(script.Parent.Types)
type StateDefinition  = Types.StateDefinition
type TransitionRule   = Types.TransitionRule
type AnimationDirective = Types.AnimationDirective

-- ── Internal Types ─────────────────────────────────────────────────────────

type PredicateFn = () -> boolean

type PendingTransition = {
	ToState   : string,
	Priority  : number,
}

-- ── StateMachine ───────────────────────────────────────────────────────────

local StateMachine = {}
StateMachine.__index = StateMachine

export type StateMachine = typeof(setmetatable({} :: {
	_states             : { [string]: StateDefinition },
	_predicates         : { [string]: PredicateFn },
	_currentState       : string,
	_pendingTransitions : { PendingTransition },
	_transitionTime     : number,
	_onStateChange      : ((exitState: StateDefinition, enterState: StateDefinition) -> ())?,
	_terminalStates     : { [string]: boolean },
}, StateMachine))

-- onStateChange: callback to AnimationController that dispatches directives and layer diffs.
function StateMachine.new(
	states          : { StateDefinition },
	initialState    : string,
	predicates      : { [string]: PredicateFn },
	onStateChange   : ((StateDefinition, StateDefinition) -> ())?
): StateMachine

	local self = setmetatable({
		_states             = {},
		_predicates         = predicates,
		_currentState       = initialState,
		_pendingTransitions = {},
		_transitionTime     = os.clock(),
		_onStateChange      = onStateChange,
		_terminalStates     = {},
	}, StateMachine)

	-- Index states by name
	for _, state in states do
		assert(not self._states[state.Name],
			string.format("[StateMachine] Duplicate state name '%s'", state.Name))
		self._states[state.Name] = state
	end

	assert(self._states[initialState],
		string.format("[StateMachine] Initial state '%s' not defined", initialState))

	-- Validate transition graph at init — fatal errors here, not at runtime
	self:_ValidateGraph()

	return self
end

-- ── Graph Validation ───────────────────────────────────────────────────────

function StateMachine:_ValidateGraph()
	local statesWithNoOutgoing: { string } = {}

	for name, state in self._states do
		-- Every ToState must reference a defined state
		for _, rule in state.Transitions do
			assert(self._states[rule.ToState],
				string.format("[StateMachine] State '%s' has transition to undefined state '%s'",
					name, rule.ToState))
			assert(self._predicates[rule.Condition],
				string.format("[StateMachine] State '%s' transition references undefined predicate '%s'",
					name, rule.Condition))
		end

		if #state.Transitions == 0 then
			table.insert(statesWithNoOutgoing, name)
			self._terminalStates[name] = true
		end
	end

	if #statesWithNoOutgoing > 0 then
		-- Terminal states are valid; log at debug verbosity only.
	end
end

-- ── Per-Tick Evaluation — O(T) ─────────────────────────────────────────────

-- Called at step 1 of the update pipeline.
-- Evaluates all outgoing transitions from the current state.
-- If multiple are valid, the highest-Priority transition wins.
-- Applies at most one transition per tick.
--
-- Bug #16 fix: the original loop gated predicate evaluation behind
-- `rule.Priority > bestPriority`, which meant that once a lower-priority
-- true predicate was found, higher-priority rules were never tested.
-- The fix separates candidate selection from predicate evaluation:
-- all rules are sorted descending by priority, then evaluated in order so
-- the first true predicate at the highest priority level wins — regardless
-- of declaration order in the Transitions array.
function StateMachine:Tick()
	-- First, process any externally queued transitions (from RequestTransition).
	if #self._pendingTransitions > 0 then
		-- Sort descending by priority, take the highest.
		table.sort(self._pendingTransitions, function(a, b) return a.Priority > b.Priority end)
		local best = self._pendingTransitions[1]
		-- Bug #8 fix: clear the queue AFTER a successful transition, not before.
		-- If _DoTransition asserts, the pending request is preserved and can be
		-- retried or inspected rather than being silently lost.
		self:_DoTransition(best.ToState)
		table.clear(self._pendingTransitions)
		return
	end

	-- Then evaluate condition-driven transitions.
	local currentState = self._states[self._currentState]
	if not currentState or #currentState.Transitions == 0 then return end

	-- Bug #16 fix: sort a copy of the transitions descending by priority so
	-- predicates are evaluated in strict priority order. The original loop
	-- used `> bestPriority` to skip lower-priority candidates, but this caused
	-- equal-priority rules to be resolved purely by iteration order without
	-- evaluating all of their predicates. By sorting first and scanning linearly,
	-- we guarantee the highest-priority true predicate always wins, and all
	-- predicates at equal priority levels are evaluated fairly.
	local sorted: { TransitionRule } = table.clone(currentState.Transitions)
	table.sort(sorted, function(a, b) return a.Priority > b.Priority end)

	local bestTransition: TransitionRule? = nil

	for _, rule in sorted do
		-- Once we've found a winner and moved to a strictly lower priority band,
		-- no further rule can beat it — early out.
		if bestTransition and rule.Priority < bestTransition.Priority then
			break
		end

		local predFn = self._predicates[rule.Condition]
		if predFn and predFn() then
			-- Accept the first true predicate at the highest priority level.
			if bestTransition == nil then
				bestTransition = rule
			end
			-- If rule.Priority == bestTransition.Priority we keep the first winner
			-- (stable within a priority band). Continue scanning only for ties.
		end
	end

	if bestTransition then
		self:_DoTransition(bestTransition.ToState)
	end
end

-- ── Transition Execution ───────────────────────────────────────────────────

function StateMachine:_DoTransition(toStateName: string)
	local fromState = self._states[self._currentState]
	local toState   = self._states[toStateName]

	assert(toState, string.format("[StateMachine] Transition target '%s' not defined", toStateName))

	if self._onStateChange then
		self._onStateChange(fromState, toState)
	end

	self._currentState   = toStateName
	self._transitionTime = os.clock()
end

-- External systems (combat, movement) may queue a transition for next tick.
-- This is preferred over direct state mutation from outside.
function StateMachine:RequestTransition(toState: string, priority: number)
	assert(self._states[toState],
		string.format("[StateMachine] Requested transition to undefined state '%s'", toState))
	table.insert(self._pendingTransitions, {
		ToState  = toState,
		Priority = priority,
	})
end

-- ── Queries ────────────────────────────────────────────────────────────────

function StateMachine:GetCurrentState(): StateDefinition
	return self._states[self._currentState]
end

function StateMachine:GetCurrentStateName(): string
	return self._currentState
end

function StateMachine:IsTerminal(): boolean
	return self._terminalStates[self._currentState] == true
end

-- ── Snapshot for DebugInspector ────────────────────────────────────────────

function StateMachine:GetSnapshot(): { [string]: any }
	local pending = {}
	for _, t in self._pendingTransitions do
		table.insert(pending, t.ToState)
	end
	return {
		CurrentState        = self._currentState,
		TimeSinceTransition = os.clock() - self._transitionTime,
		PendingTransitions  = pending,
	}
end

return StateMachine