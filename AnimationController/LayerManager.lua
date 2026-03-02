--!strict
-- ─── LayerManager.lua ────────────────────────────────────────────────────────
--[[
    Manages the ordered set of logical animation layers assigned to a character.

    A "layer" in this context is a blend channel on the character's Animator.
    Each layer has a weight (0–1) that scales all animations playing on it.
    LayerManager is responsible for:

      • Storing the static configuration of each layer (from LayerProfile).
      • Interpolating each layer's CurrentWeight toward its TargetWeight each frame.
      • Computing the final blended weight for any TrackWrapper based on layer weight,
        wrapper target weight, and the config's base Weight value.
      • Registering and unregistering TrackWrapper references per layer, so that
        DebugInspector can validate that no orphaned track references exist.

    LayerManager has NO awareness of ExclusiveGroups. It does not know which
    animations compete within a group — that is entirely ExclusiveGroupManager's job.
    LayerManager only computes weights and tracks registrations.

    Complexity targets:
      • UpdateWeights:         O(L)  — one pass over all layers.
      • ComputeFinalWeight:    O(1)  — single hash lookup + arithmetic.
      • RegisterTrack:         O(T)  — where T = tracks on the target layer.
      • UnregisterTrack:       O(T)
]]

local Types = require(script.Parent.Types)
type LayerProfile = Types.LayerProfile

-- ─── Constants ────────────────────────────────────────────────────────────────

--[[
    WEIGHT_EPSILON is the convergence threshold for the weight lerp loop.

    Without this, floating-point residuals from repeated lerp operations (e.g.
    0.99999998 when the target is 1.0) would keep `AnyLayerWeightChanged = true`
    every single frame, causing _PushWeights to run every tick even when all
    layers are visually settled. Over thousands of frames this wastes CPU and
    prevents the early-out optimisation that avoids redundant AdjustWeight calls.

    When the absolute difference between CurrentWeight and TargetWeight falls below
    WEIGHT_EPSILON, we snap CurrentWeight to TargetWeight and treat the layer as
    settled. 1e-6 is imperceptibly small relative to the 0–1 weight range.

    Bug #21 fix: previously the code compared CurrentWeight ~= TargetWeight (exact
    float equality), which could remain true indefinitely due to accumulation of
    floating-point rounding errors in the lerp step.
]]
local WEIGHT_EPSILON = 1e-6

-- ─── Layer Record ─────────────────────────────────────────────────────────────

--[[
    LayerRecord is the runtime representation of a layer. It combines the static
    fields from LayerProfile (never changed after construction) with runtime-mutable
    fields updated each frame or on state transitions.

    ActiveTracks: { TrackWrapper }
        Live references to every TrackWrapper currently registered on this layer.
        Maintained in insertion order. Used only for DebugInspector cross-validation
        (detecting wrappers that were retired without calling UnregisterTrack).
        Not used for weight computation — weight pushes iterate ActiveWrappers on
        the controller, not this list.
]]
type LayerRecord = {
	Name:           string,
	Order:          number,
	BaseWeight:     number,
	CurrentWeight:  number,
	TargetWeight:   number,
	Additive:       boolean,
	Isolated:       boolean,
	WeightLerpRate: number,
	ActiveTracks:   { any },
}

-- ─── LayerManager ─────────────────────────────────────────────────────────────

local LayerManager = {}
LayerManager.__index = LayerManager

export type LayerManager = typeof(setmetatable({} :: {
	_Layers:      { LayerRecord },
	_LayerByName: { [string]: LayerRecord },
}, LayerManager))

-- ─── Constructor ──────────────────────────────────────────────────────────────

--[=[
    LayerManager.new

    Description:
        Constructs a LayerManager from an array of LayerProfiles. Validates that
        all layer names and Order values are unique, then builds both a sorted array
        (_Layers) and a name-indexed map (_LayerByName) for O(1) lookups.

        The sorted array is built once at construction and never reordered. No runtime
        reordering is permitted — layer Order is a static compile-time concern.

    Parameters:
        Profiles: { LayerProfile }
            One entry per logical animation layer. Order values must be unique across
            all profiles. Names must also be unique.

    Returns:
        LayerManager
            A new instance with all layer records created and sorted by Order ascending.

    Notes:
        CurrentWeight and TargetWeight are both initialised to BaseWeight so the layer
        starts at its natural weight with no lerp needed.
]=]
function LayerManager.new(Profiles: { LayerProfile }): LayerManager
	local Self = setmetatable({
		_Layers      = {} :: { LayerRecord },
		_LayerByName = {} :: { [string]: LayerRecord },
	}, LayerManager)

	-- Validate uniqueness across all profiles before building any records.
	-- Using a temporary lookup table (rather than comparing each pair) keeps
	-- validation O(N) rather than O(N²).
	local SeenOrders: { [number]: boolean } = {}

	for _, Profile in Profiles do
		assert(
			not SeenOrders[Profile.Order],
			string.format(
				"[LayerManager] Duplicate layer Order %d for layer '%s'",
				Profile.Order, Profile.Name
			)
		)
		assert(
			not Self._LayerByName[Profile.Name],
			string.format("[LayerManager] Duplicate layer name '%s'", Profile.Name)
		)
		SeenOrders[Profile.Order] = true

		local Record: LayerRecord = {
			Name           = Profile.Name,
			Order          = Profile.Order,
			BaseWeight     = Profile.BaseWeight,
			-- Start at BaseWeight immediately so no lerp is needed before first use.
			CurrentWeight  = Profile.BaseWeight,
			TargetWeight   = Profile.BaseWeight,
			Additive       = Profile.Additive,
			Isolated       = Profile.Isolated,
			WeightLerpRate = Profile.WeightLerpRate,
			-- Empty initially; TrackWrappers register themselves when activated.
			ActiveTracks   = {},
		}

		table.insert(Self._Layers, Record)
		Self._LayerByName[Profile.Name] = Record
	end

	-- Sort ascending by Order so _Layers[1] is always the lowest-priority layer.
	-- This order is used by DebugInspector:GetAnimationTree for display and by
	-- ConflictResolver which compares Order values numerically.
	table.sort(Self._Layers, function(A, B)
		return A.Order < B.Order
	end)

	return Self
end

-- ─── Layer Queries ────────────────────────────────────────────────────────────

--[=[
    LayerManager:GetLayer

    Description:
        Returns the LayerRecord for the given layer name, or nil if unknown.

        Returns nil rather than asserting so callers can emit a warn() and continue
        rather than crashing on a typo in an AnimationConfig.Layer field.

    Parameters:
        Name: string
            The exact layer name to look up.

    Returns:
        LayerRecord?
            The matching record, or nil if no layer with that name was registered.
]=]
function LayerManager:GetLayer(Name: string): LayerRecord?
	return self._LayerByName[Name]
end

--[=[
    LayerManager:GetAllLayers

    Description:
        Returns the internal sorted array of all LayerRecords.
        The array is sorted ascending by Order (lowest-priority first).

        Used by DebugInspector:GetAnimationTree to iterate layers in display order.

    Returns:
        { LayerRecord }
            The live internal array — callers must not modify it.
]=]
function LayerManager:GetAllLayers(): { LayerRecord }
	return self._Layers
end

-- ─── Weight Target API ────────────────────────────────────────────────────────

--[=[
    LayerManager:SetLayerTargetWeight

    Description:
        Overrides the TargetWeight of a named layer. CurrentWeight will lerp toward
        this target in UpdateWeights at a rate of WeightLerpRate units per second.

        Called by the StateMachine → AnimationController._OnStateChange path when
        a state transition explicitly sets a layer's target (e.g. raising an overlay
        layer for a particular state).

    Parameters:
        Name:   string  — The layer to update.
        Target: number  — The desired weight, clamped to [0, 1].
]=]
function LayerManager:SetLayerTargetWeight(Name: string, Target: number)
	local Layer = self._LayerByName[Name]
	assert(Layer, string.format("[LayerManager] Unknown layer '%s'", Name))
	-- Clamp to [0, 1] so callers cannot set physically impossible weights.
	Layer.TargetWeight = math.clamp(Target, 0, 1)
end

--[=[
    LayerManager:SetLayerToBase

    Description:
        Restores a layer's TargetWeight to its configured BaseWeight.
        Used by _OnStateChange to return a layer to its natural state when no
        active state is suppressing or elevating it.

        Silent no-op for unknown layer names (returns without asserting) because
        state transitions may reference layers that were valid at design time but
        removed from the config, and a crash here would be worse than a no-op.

    Parameters:
        Name: string — The layer to restore.
]=]
function LayerManager:SetLayerToBase(Name: string)
	local Layer = self._LayerByName[Name]
	if Layer then
		Layer.TargetWeight = Layer.BaseWeight
	end
end

--[=[
    LayerManager:SuppressLayer

    Description:
        Sets a layer's TargetWeight to 0, causing it to lerp to zero weight and
        effectively disable all animations on it visually.

        Used by _OnStateChange when a StateDefinition lists the layer in SuppressLayers.
        The layer is restored to BaseWeight when the state exits (via SetLayerToBase).

    Parameters:
        Name: string — The layer to suppress.
]=]
function LayerManager:SuppressLayer(Name: string)
	local Layer = self._LayerByName[Name]
	if Layer then
		Layer.TargetWeight = 0
	end
end

-- ─── Per-Frame Weight Interpolation ──────────────────────────────────────────

--[=[
    LayerManager:UpdateWeights

    Description:
        Advances every layer's CurrentWeight toward its TargetWeight by one frame step.
        Returns true if at least one layer's weight changed, signalling that a weight
        push to TrackWrappers is needed this frame.

        Called once per tick at Step 2 of the AnimationController update pipeline,
        BEFORE _PushWeights (Step 3). This ordering guarantees that when weights are
        pushed to tracks, they reflect the interpolation that just happened this frame.

    Parameters:
        DeltaTime: number
            Seconds elapsed since the last frame. Used to compute the step size:
            StepSize = WeightLerpRate × DeltaTime.

    Returns:
        boolean
            true if any layer weight changed this frame (caller may use this for
            early-out, though _PushWeights currently runs unconditionally).

    Notes:
        Bug #21 fix: replaced floating-point equality (CurrentWeight ~= TargetWeight)
        with an epsilon check. Exact float comparison can remain true indefinitely after
        many lerp steps due to accumulating rounding errors, keeping AnyLayerWeightChanged
        = true every frame even when layers are visually settled.

        When |delta| ≤ WEIGHT_EPSILON, CurrentWeight is snapped to TargetWeight and
        the residual is eliminated. This is O(L) where L = number of layers.
]=]
function LayerManager:UpdateWeights(DeltaTime: number): boolean
	local AnyLayerWeightChanged = false

	for _, Layer in self._Layers do
		local Delta = Layer.TargetWeight - Layer.CurrentWeight

		if math.abs(Delta) > WEIGHT_EPSILON then
			-- Weight is outside the convergence threshold — continue interpolating.
			local StepSize = Layer.WeightLerpRate * DeltaTime

			if math.abs(Delta) <= StepSize then
				-- The remaining gap is smaller than the step we can take this frame,
				-- so snap directly to TargetWeight to prevent overshooting.
				Layer.CurrentWeight = Layer.TargetWeight
			else
				-- Advance by one step in the direction of TargetWeight.
				-- math.sign returns -1, 0, or 1, ensuring we always move toward the target
				-- and never away from it regardless of the sign of Delta.
				Layer.CurrentWeight = Layer.CurrentWeight + math.sign(Delta) * StepSize
			end

			AnyLayerWeightChanged = true

		elseif Layer.CurrentWeight ~= Layer.TargetWeight then
			-- Within WEIGHT_EPSILON but not exactly equal due to float residuals.
			-- Snap to eliminate the residual permanently so this branch never fires again
			-- for this layer until TargetWeight changes.
			Layer.CurrentWeight = Layer.TargetWeight
			AnyLayerWeightChanged = true
		end
	end

	return AnyLayerWeightChanged
end

-- ─── Final Weight Computation ─────────────────────────────────────────────────

--[=[
    LayerManager:ComputeFinalWeight

    Description:
        Computes the effective weight to push to a TrackWrapper's underlying AnimationTrack.

        The formula is:
            FinalWeight = Layer.CurrentWeight × WrapperTargetWeight × ConfigWeight

        Each factor represents a different level of the blending hierarchy:
            • Layer.CurrentWeight     — how much this entire layer contributes.
            • WrapperTargetWeight     — how much THIS animation within the layer contributes
                                        (used for fade-in and fade-out transitions).
            • ConfigWeight            — the animation's own base contribution (0–1 multiplier).

        The result is clamped to [0, 1] to satisfy AnimationTrack.AdjustWeight's contract.

    Parameters:
        LayerName:           string — The layer the animation plays on.
        WrapperTargetWeight: number — The wrapper's current target weight (0 = faded out, 1 = full).
        ConfigWeight:        number — The animation config's base Weight value.

    Returns:
        number — The final blended weight, clamped to [0, 1].

    Notes:
        Returns 0 for unknown layer names (silent rather than asserting) because weight
        pushes happen every frame and a missing layer should not crash the game — it
        simply produces a weight of 0 which looks like the animation isn't playing.
]=]
function LayerManager:ComputeFinalWeight(
	LayerName:           string,
	WrapperTargetWeight: number,
	ConfigWeight:        number
): number
	local Layer = self._LayerByName[LayerName]
	if not Layer then return 0 end
	return math.clamp(Layer.CurrentWeight * WrapperTargetWeight * ConfigWeight, 0, 1)
end

-- ─── Track Registration ───────────────────────────────────────────────────────

--[=[
    LayerManager:RegisterTrack

    Description:
        Adds a TrackWrapper to the named layer's ActiveTracks list.
        Safe to call with the same wrapper multiple times — double-registration is
        detected and silently ignored via a linear scan.

        Called from AnimationController._ActivateWrapper whenever a wrapper begins
        playing on a layer.

    Parameters:
        LayerName: string — The layer to register on.
        Wrapper:   any    — The TrackWrapper to add.
]=]
function LayerManager:RegisterTrack(LayerName: string, Wrapper: any)
	local Layer = self._LayerByName[LayerName]
	assert(Layer, string.format("[LayerManager] Cannot register track on unknown layer '%s'", LayerName))

	-- Guard against double-registration in case the same wrapper is activated twice.
	-- A linear scan is acceptable here because the number of concurrent tracks per
	-- layer is expected to be very small (1–3 in typical game scenarios).
	for _, ExistingWrapper in Layer.ActiveTracks do
		if ExistingWrapper == Wrapper then return end
	end

	table.insert(Layer.ActiveTracks, Wrapper)
end

--[=[
    LayerManager:UnregisterTrack

    Description:
        Removes a TrackWrapper from the named layer's ActiveTracks list.
        Silent no-op if the layer is unknown or the wrapper is not found.

        Called from AnimationController._RetireWrapper when a wrapper is pooled
        or destroyed. Failing to call this would leave a stale reference in
        ActiveTracks, which DebugInspector:ValidateInvariants would detect as a leak.

    Parameters:
        LayerName: string — The layer to unregister from.
        Wrapper:   any    — The TrackWrapper to remove.
]=]
function LayerManager:UnregisterTrack(LayerName: string, Wrapper: any)
	local Layer = self._LayerByName[LayerName]
	if not Layer then return end

	-- Iterate backward so we can use table.remove without invalidating the loop index.
	for Index = #Layer.ActiveTracks, 1, -1 do
		if Layer.ActiveTracks[Index] == Wrapper then
			table.remove(Layer.ActiveTracks, Index)
			return
		end
	end
end

-- ─── Snapshot and Invariant API ───────────────────────────────────────────────

--[=[
    LayerManager:GetSnapshot

    Description:
        Returns a plain-table snapshot of all layer records for display in DebugInspector.
        Does not include live wrapper references — only serialisable data.

    Returns:
        { { [string]: any } }
            Array of records ordered by layer sort order (ascending by Order),
            each containing: Name, Order, CurrentWeight, TargetWeight, Additive,
            Isolated, ActiveTrackCount.
]=]
function LayerManager:GetSnapshot(): { { [string]: any } }
	local Snapshot = {}
	for _, Layer in self._Layers do
		table.insert(Snapshot, {
			Name             = Layer.Name,
			Order            = Layer.Order,
			CurrentWeight    = Layer.CurrentWeight,
			TargetWeight     = Layer.TargetWeight,
			Additive         = Layer.Additive,
			Isolated         = Layer.Isolated,
			ActiveTrackCount = #Layer.ActiveTracks,
		})
	end
	return Snapshot
end

--[=[
    LayerManager:ValidateInvariants

    Description:
        Checks structural invariants and optionally cross-validates ActiveTracks
        against a live wrapper set from AnimationController.

        Bug #13 fix: the cross-validation parameter was added so that LayerManager
        can surface orphaned track registrations — wrappers that appear in
        ActiveTracks but have been retired from ActiveWrappers without calling
        UnregisterTrack. Without this check, such leaks would silently accumulate
        and corrupt DebugInspector output.

    Parameters:
        ActiveWrappers: { [string]: any }?
            The AnimationController.ActiveWrappers map (animName → TrackWrapper).
            When provided, every entry in each layer's ActiveTracks is verified to
            exist in this map. Omit for partial validation that only checks layer ordering.

    Returns:
        { string }
            Array of violation descriptions. Empty if all invariants hold.
]=]
function LayerManager:ValidateInvariants(ActiveWrappers: { [string]: any }?): { string }
	local Violations = {}

	-- Verify the _Layers array is sorted strictly ascending with no duplicate Orders.
	-- The array is sorted at construction time and never modified, so this should
	-- always pass — but validating at runtime surfaces bugs in future code changes.
	for Index = 2, #self._Layers do
		local IsOutOfOrder = self._Layers[Index].Order <= self._Layers[Index - 1].Order
		if IsOutOfOrder then
			table.insert(Violations, string.format(
				"Layer order violation: '%s' (Order %d) not strictly greater than '%s' (Order %d)",
				self._Layers[Index].Name,     self._Layers[Index].Order,
				self._Layers[Index - 1].Name, self._Layers[Index - 1].Order
				))
		end
	end

	-- Cross-validate ActiveTracks against the controller's ActiveWrappers map.
	-- Any TrackWrapper in ActiveTracks that is NOT in ActiveWrappers was retired
	-- from the controller without UnregisterTrack being called — a memory/reference leak.
	if ActiveWrappers then
		for _, Layer in self._Layers do
			for _, TrackedWrapper in Layer.ActiveTracks do
				local IsInActiveWrappers = false
				for _, LiveWrapper in ActiveWrappers do
					if LiveWrapper == TrackedWrapper then
						IsInActiveWrappers = true
						break
					end
				end

				if not IsInActiveWrappers then
					table.insert(Violations, string.format(
						"Layer '%s' ActiveTracks contains a wrapper ('%s') not in AnimationController.ActiveWrappers — possible leak",
						Layer.Name,
						TrackedWrapper.Config and TrackedWrapper.Config.Name or "unknown"
						))
				end
			end
		end
	end

	return Violations
end

return LayerManager