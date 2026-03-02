--!strict
-- ─── DebugInspector.lua ───────────────────────────────────────────────────────
--[[
    DebugInspector is an optional, read-only diagnostic surface attached to a live
    AnimationController instance. It exposes structured snapshots of internal state
    for tooling, automated test assertions, and developer console inspection.

    Design constraints:
        - Read-only: DebugInspector never mutates any controller state. It only
          reads fields that are already exposed by the controller's public surface.
          This means it cannot break gameplay by being attached or detached.

        - Weak attachment: The controller reference is stored by value, not wrapped
          in a destructor. If the controller is destroyed, DebugInspector methods
          check IsDestroyed and return safe empty results rather than erroring.

        - Production strippability: The entire module can be conditionally excluded
          from production builds by wrapping its require in a debug-only guard.
          Because it has no side effects on the controller, removing it changes
          nothing about runtime animation behaviour.

    Usage:
        local Inspector = Controller:AttachInspector()
        print(Inspector:GetAnimationTree())
        local Result = Inspector:ValidateInvariants()
        if not Result.Valid then
            warn(table.concat(Result.Violations, "\n"))
        end
]]

-- ─── Module Table ─────────────────────────────────────────────────────────────

--[[
    DebugInspector serves as both the module and the metatable for all instances.
    __index = DebugInspector means method lookups fall through to this table.
]]
local DebugInspector = {}
DebugInspector.__index = DebugInspector

-- ─── Exported Type ────────────────────────────────────────────────────────────

--[[
    The exported type uses typeof(setmetatable(...)) to let Luau infer method
    signatures automatically from the metatable without a separate interface block.

    _Controller is typed as `any` because AnimationController is defined in init.lua
    and would create a circular require if imported here. The `any` type is acceptable
    because DebugInspector only reads known fields by name; strict typing on those
    individual accesses is maintained by the compiler at the call sites.
]]
export type DebugInspector = typeof(setmetatable({} :: {
	_Controller : any,
}, DebugInspector))

-- ─── Constructor ──────────────────────────────────────────────────────────────

--[=[
    DebugInspector.New

    Description:
        Constructs a new DebugInspector attached to the given AnimationController
        instance. This is the only way to create an inspector; it cannot be
        meaningfully instantiated without a live controller.

        The controller is referenced directly — not cloned or weakened — because
        the inspector is expected to have the same lifetime as the controller it
        inspects. If the controller outlives the inspector, the inspector simply
        becomes unused. If the inspector outlives the controller, the IsDestroyed
        guard in every method returns safe empty results.

    Parameters:
        Controller : any
            A live AnimationController instance. Must be non-nil and non-destroyed
            at the time of construction. The assert here prevents constructing an
            inspector against a nil value, which would defer the failure until
            the first method call.

    Returns:
        DebugInspector
            A ready-to-use inspector bound to the provided controller.
]=]
function DebugInspector.New(Controller: any): DebugInspector
	assert(Controller, "[DebugInspector] Must be attached to a live AnimationController")
	return setmetatable({
		_Controller = Controller,
	}, DebugInspector)
end

-- ─── Active Wrapper Snapshot ──────────────────────────────────────────────────

--[=[
    GetActiveWrappers

    Description:
        Returns a sorted array of plain-table snapshots describing every
        TrackWrapper currently present in the controller's ActiveWrappers dictionary.

        The result is sorted by LayerOrder descending, then by Config.Priority
        descending. This ordering mirrors the visual rendering stack — the
        highest-priority animation on the topmost layer appears first.

    Returns:
        { { [string]: any } }
            Each entry is a plain table (never a live wrapper reference) containing:
                Name       — Config.Name of the animation.
                Layer      — Config.Layer string (layer name).
                LayerOrder — Numeric Order of the layer from LayerManager.
                Group      — Config.Group or nil if ungrouped.
                Weight     — Current EffectiveWeight (may be mid-lerp).
                Timestamp  — StartTimestamp (os.clock() when _Play was called).
                IsPlaying  — Whether the underlying track considers itself active.
                IsFading   — Whether a fade-in or fade-out is currently in progress.
                Priority   — Config.Priority value.

    Notes:
        LayerOrder is looked up from LayerManager rather than stored on the config
        because Layer in the config is a name string, not an Order number. The
        numeric Order lives in the LayerRecord and is needed for sort logic.

        If the controller has been destroyed, returns an empty table rather than
        erroring. This allows inspection code to run safely in teardown scenarios.
]=]
function DebugInspector:GetActiveWrappers(): { { [string]: any } }
	local Controller = self._Controller

	if Controller.IsDestroyed then
		return {}
	end

	local SnapshotEntries: { { [string]: any } } = {}

	for _, Wrapper in Controller.ActiveWrappers do
		local LayerRecord = Controller.LayerManager:GetLayer(Wrapper.Config.Layer)

		table.insert(SnapshotEntries, {
			Name       = Wrapper.Config.Name,
			Layer      = Wrapper.Config.Layer,
			LayerOrder = LayerRecord and LayerRecord.Order or 0,
			Group      = Wrapper.Config.Group,
			Weight     = Wrapper.EffectiveWeight,
			Timestamp  = Wrapper.StartTimestamp,
			IsPlaying  = Wrapper.IsPlaying,
			IsFading   = Wrapper.IsFading,
			Priority   = Wrapper.Config.Priority,
		})
	end

	-- Sort descending by LayerOrder first; within the same layer, descending
	-- by Priority. This mirrors how the engine composites animation tracks and
	-- makes the result intuitive when reading top-to-bottom.
	table.sort(SnapshotEntries, function(EntryA, EntryB)
		if EntryA.LayerOrder ~= EntryB.LayerOrder then
			return EntryA.LayerOrder > EntryB.LayerOrder
		end
		return EntryA.Priority > EntryB.Priority
	end)

	return SnapshotEntries
end

-- ─── Layer Snapshot ───────────────────────────────────────────────────────────

--[=[
    GetLayerSnapshot

    Description:
        Returns a plain-table array describing the current runtime state of every
        layer managed by LayerManager. Delegates directly to LayerManager:GetSnapshot.

        Useful for verifying that layer weight interpolation is progressing correctly,
        that suppression commands have taken effect, and that active track counts
        match expectations.

    Returns:
        { { [string]: any } }
            Array of layer records ordered by LayerManager's internal sorted order
            (ascending by Order). Each entry contains Name, Order, CurrentWeight,
            TargetWeight, Additive, Isolated, and ActiveTrackCount.
]=]
function DebugInspector:GetLayerSnapshot(): { { [string]: any } }
	local Controller = self._Controller

	if Controller.IsDestroyed then
		return {}
	end

	return Controller.LayerManager:GetSnapshot()
end

-- ─── Group Snapshot ───────────────────────────────────────────────────────────

--[=[
    GetGroupSnapshot

    Description:
        Returns a plain-table array describing the current runtime state of every
        exclusive group tracked by ExclusiveGroupManager. Delegates to
        GroupManager:GetSnapshot.

        Useful for verifying that group slots are being promoted correctly after
        natural completion or manual stop, and for inspecting pending wrapper state.

    Returns:
        { { [string]: any } }
            Each entry contains Group, ActiveAnimationName, StartTimestamp,
            CanInterrupt, and PendingAnimationName (nil if no pending wrapper).
]=]
function DebugInspector:GetGroupSnapshot(): { { [string]: any } }
	local Controller = self._Controller

	if Controller.IsDestroyed then
		return {}
	end

	return Controller.GroupManager:GetSnapshot()
end

-- ─── State Machine Snapshot ───────────────────────────────────────────────────

--[=[
    GetStateMachineSnapshot

    Description:
        Returns a plain-table snapshot of the StateMachine's current runtime state.
        Delegates to StateMachine:GetSnapshot.

    Returns:
        { [string]: any }
            Contains CurrentState (string), TimeSinceTransition (number, seconds),
            and PendingTransitions (array of destination state name strings).
]=]
function DebugInspector:GetStateMachineSnapshot(): { [string]: any }
	local Controller = self._Controller

	if Controller.IsDestroyed then
		return {}
	end

	return Controller.StateMachine:GetSnapshot()
end

-- ─── Animation Tree ───────────────────────────────────────────────────────────

--[=[
    GetAnimationTree

    Description:
        Produces a deterministic, human-readable text tree of the complete
        animation state, formatted as:

            Layer[Order] 'Name'  cw=X.XXX  tw=X.XXX  [ADDITIVE] [ISOLATED]
              └─ [G:GroupName] 'AnimName'  w=X.XXX  p=N  PLAYING|FADING|STOPPED
              └─ (empty)

        One line per layer; one sub-line per active wrapper on that layer.
        Deterministic means that identical logical state always produces identical
        output — wrappers within a layer are sorted by priority descending, then
        by StartTimestamp ascending, so the tree is stable for test assertions.

    Returns:
        string
            A newline-joined tree string. Returns "[DESTROYED]" if the controller
            has been destroyed.

    Notes:
        This method is intentionally formatted for human reading (console output,
        test failure messages). It is NOT intended for machine parsing; use the
        individual snapshot methods for structured data.

        The status field uses three-way logic:
            FADING   — IsPlaying AND IsFading (active track in a crossfade).
            PLAYING  — IsPlaying AND NOT IsFading (fully blended, running normally).
            STOPPED  — NOT IsPlaying (completed or manually stopped, weight draining).
]=]
function DebugInspector:GetAnimationTree(): string
	local Controller = self._Controller

	if Controller.IsDestroyed then
		return "[DESTROYED]"
	end

	local AllLayers = Controller.LayerManager:GetAllLayers()
	local OutputLines: { string } = {}

	for _, LayerRecord in AllLayers do
		-- Format the layer header line with weight and flag indicators.
		local AdditiveMarker = LayerRecord.Additive  and "[ADDITIVE] " or ""
		local IsolatedMarker = LayerRecord.Isolated  and "[ISOLATED]"  or ""

		local LayerHeaderLine = string.format(
			"Layer[%d] '%s'  cw=%.3f  tw=%.3f  %s%s",
			LayerRecord.Order,
			LayerRecord.Name,
			LayerRecord.CurrentWeight,
			LayerRecord.TargetWeight,
			AdditiveMarker,
			IsolatedMarker
		)
		table.insert(OutputLines, LayerHeaderLine)

		-- Collect all wrappers assigned to this layer.
		local LayerWrappers: { any } = {}
		for _, Wrapper in Controller.ActiveWrappers do
			if Wrapper.Config.Layer == LayerRecord.Name then
				table.insert(LayerWrappers, Wrapper)
			end
		end

		-- Sort for determinism: descending priority so highest-priority animations
		-- appear first, then ascending StartTimestamp as a tiebreaker so that
		-- older animations appear before newer ones at the same priority level.
		table.sort(LayerWrappers, function(WrapperA, WrapperB)
			if WrapperA.Config.Priority ~= WrapperB.Config.Priority then
				return WrapperA.Config.Priority > WrapperB.Config.Priority
			end
			return WrapperA.StartTimestamp < WrapperB.StartTimestamp
		end)

		for _, Wrapper in LayerWrappers do
			-- Format the group prefix only when a group is assigned, so ungrouped
			-- wrappers don't have a visual artefact prefix.
			local GroupPrefix = Wrapper.Config.Group
				and string.format("[G:%s] ", Wrapper.Config.Group)
				or ""

			-- Three-way status: a wrapper can be simultaneously IsPlaying and
			-- IsFading during crossfade transitions; use the most informative label.
			local IsActivelyFading = Wrapper.IsPlaying and Wrapper.IsFading
			local IsActivelyPlaying = Wrapper.IsPlaying and not Wrapper.IsFading

			local StatusLabel: string
			if IsActivelyFading then
				StatusLabel = "FADING"
			elseif IsActivelyPlaying then
				StatusLabel = "PLAYING"
			else
				StatusLabel = "STOPPED"
			end

			local WrapperLine = string.format(
				"  └─ %s'%s'  w=%.3f  p=%d  %s",
				GroupPrefix,
				Wrapper.Config.Name,
				Wrapper.EffectiveWeight,
				Wrapper.Config.Priority,
				StatusLabel
			)
			table.insert(OutputLines, WrapperLine)
		end

		-- Emit a placeholder line for layers with no active wrappers so the
		-- tree is visually complete and layer presence is always apparent.
		if #LayerWrappers == 0 then
			table.insert(OutputLines, "  └─ (empty)")
		end
	end

	return table.concat(OutputLines, "\n")
end

-- ─── Invariant Validation ─────────────────────────────────────────────────────

--[=[
    ValidateInvariants

    Description:
        Executes a comprehensive suite of runtime invariant checks against the
        controller's current state and returns any violations found. Designed
        for use in automated tests, CI pipelines, and developer-mode assertions.

        Invariants checked:

          1. ExclusiveGroup uniqueness:
             No two active wrappers in the same group should have a non-zero
             EffectiveWeight simultaneously. If they do, the mutual-exclusivity
             contract has been violated, which causes undefined animation blending.

          2. EffectiveWeight bounds:
             Every wrapper's EffectiveWeight must be in [0, 1]. Values outside
             this range indicate a bug in ComputeFinalWeight or direct mutation.

          3. LayerManager structural integrity:
             Layers must remain sorted ascending by Order with no duplicates, and
             every entry in ActiveTracks must correspond to a wrapper still present
             in ActiveWrappers (no leaked unregistered wrappers).

          4. StateMachine has an active state:
             The FSM must always be in exactly one defined state. An empty or nil
             current state name indicates a construction or transition error.

          5. Pooled wrapper IsPlaying guard:
             No wrapper currently sitting in the pool should have IsPlaying = true.
             A playing wrapper in the pool means it was incorrectly recycled while
             still in use, which would cause it to be handed to a new request while
             its underlying track is still running.

          6. ExclusiveGroupManager invariants:
             Delegated to GroupManager:ValidateInvariants, which checks that no
             group has ActiveWrapper and PendingWrapper pointing to the same object.

    Returns:
        { Valid: boolean, Violations: { string } }
            Valid      — True if no violations were found.
            Violations — Array of human-readable violation descriptions. Empty
                         when Valid is true.
]=]
function DebugInspector:ValidateInvariants(): { Valid: boolean, Violations: { string } }
	local Controller = self._Controller
	local Violations: { string } = {}

	-- Early exit: a destroyed controller cannot satisfy any invariants.
	if Controller.IsDestroyed then
		return {
			Valid      = false,
			Violations = { "AnimationController is destroyed" },
		}
	end

	-- ── Invariant 1: ExclusiveGroup uniqueness ─────────────────────────────
	-- Build a map from group name to all wrappers with non-zero EffectiveWeight.
	-- Any group with more than one entry has violated mutual exclusivity.
	local GroupActiveEntries: { [string]: { { Name: string, Weight: number } } } = {}

	for _, Wrapper in Controller.ActiveWrappers do
		local GroupName = Wrapper.Config.Group
		local HasNonZeroWeight = Wrapper.EffectiveWeight > 0

		if GroupName and HasNonZeroWeight then
			if not GroupActiveEntries[GroupName] then
				GroupActiveEntries[GroupName] = {}
			end
			table.insert(GroupActiveEntries[GroupName], {
				Name   = Wrapper.Config.Name,
				Weight = Wrapper.EffectiveWeight,
			})
		end
	end

	for GroupName, ActiveEntries in GroupActiveEntries do
		local HasMultipleActiveWrappers = #ActiveEntries > 1

		if HasMultipleActiveWrappers then
			local ActiveNames: { string } = {}
			for _, Entry in ActiveEntries do
				table.insert(ActiveNames, Entry.Name)
			end

			table.insert(Violations, string.format(
				"Group '%s' has %d wrappers with non-zero weight: %s",
				GroupName,
				#ActiveEntries,
				table.concat(ActiveNames, ", ")
				))
		end
	end

	-- ── Invariant 2: EffectiveWeight bounds ────────────────────────────────
	-- EffectiveWeight is the product of three clamped values and must stay in
	-- [0, 1]. Values outside this range indicate an overflow or underflow
	-- somewhere in the weight computation pipeline.
	for _, Wrapper in Controller.ActiveWrappers do
		local IsWeightOutOfBounds = Wrapper.EffectiveWeight < 0 or Wrapper.EffectiveWeight > 1

		if IsWeightOutOfBounds then
			table.insert(Violations, string.format(
				"Wrapper '%s' EffectiveWeight %.4f is outside [0, 1]",
				Wrapper.Config.Name,
				Wrapper.EffectiveWeight
				))
		end
	end

	-- ── Invariant 3: LayerManager structural integrity ─────────────────────
	-- Pass the full ActiveWrappers map so LayerManager can cross-validate its
	-- ActiveTracks entries against the controller's live wrapper set. Any entry
	-- in ActiveTracks that is not in ActiveWrappers is an unregistered leak.
	local LayerViolations = Controller.LayerManager:ValidateInvariants(Controller.ActiveWrappers)
	for _, ViolationMessage in LayerViolations do
		table.insert(Violations, ViolationMessage)
	end

	-- ── Invariant 4: StateMachine has exactly one current state ────────────
	-- The FSM must always report a non-empty current state name. An empty string
	-- or nil indicates a construction failure or corrupted transition.
	local CurrentStateName = Controller.StateMachine:GetCurrentStateName()
	local HasNoActiveState = not CurrentStateName or CurrentStateName == ""

	if HasNoActiveState then
		table.insert(Violations, "StateMachine has no current state")
	end

	-- ── Invariant 5: No pooled wrapper with IsPlaying = true ───────────────
	-- Wrappers are only returned to the pool after _Stop(true) and after their
	-- EffectiveWeight reaches 0. A pooled wrapper with IsPlaying = true means
	-- it was prematurely recycled while its track was still running, and the
	-- next acquisition would hand out an actively-playing wrapper to new content.
	for _, WrapperPool in Controller._WrapperPool do
		for _, PooledWrapper in WrapperPool do
			if PooledWrapper.IsPlaying then
				table.insert(Violations, string.format(
					"Pooled wrapper for config '%s' has IsPlaying = true",
					PooledWrapper.Config and PooledWrapper.Config.Name or "unknown"
					))
			end
		end
	end

	-- ── Invariant 6: ExclusiveGroupManager invariants ─────────────────────
	-- Delegates to GroupManager for group-specific checks (e.g. active and
	-- pending pointing to the same wrapper object).
	local GroupViolations = Controller.GroupManager:ValidateInvariants()
	for _, ViolationMessage in GroupViolations do
		table.insert(Violations, ViolationMessage)
	end

	return {
		Valid      = #Violations == 0,
		Violations = Violations,
	}
end

return DebugInspector