--!strict
-- DebugInspector.lua
-- Optional module. Attaches to a live AnimationController.
-- Exposes read-only snapshots of internal state.
-- No write access to any live state.
-- Can be stripped in production builds via conditional require.

local DebugInspector = {}
DebugInspector.__index = DebugInspector

export type DebugInspector = typeof(setmetatable({} :: {
	_controller : any, -- AnimationController (weak reference by convention)
}, DebugInspector))

function DebugInspector.new(controller: any): DebugInspector
	assert(controller, "[DebugInspector] Must be attached to a live AnimationController")
	return setmetatable({
		_controller = controller,
	}, DebugInspector)
end

-- ── API ────────────────────────────────────────────────────────────────────

-- Returns snapshot of all active wrappers with non-zero weight or active fade.
-- Sorted by Layer.Order descending, then Config.Priority descending.
function DebugInspector:GetActiveWrappers(): { { [string]: any } }
	local ctrl = self._controller
	if ctrl.IsDestroyed then return {} end

	local results = {}
	for _, wrapper in ctrl.ActiveWrappers do
		local layerRecord = ctrl.LayerManager:GetLayer(wrapper.Config.Layer)
		table.insert(results, {
			Name      = wrapper.Config.Name,
			Layer     = wrapper.Config.Layer,
			LayerOrder = layerRecord and layerRecord.Order or 0,
			Group     = wrapper.Config.Group,
			Weight    = wrapper.EffectiveWeight,
			Timestamp = wrapper.StartTimestamp,
			IsPlaying = wrapper.IsPlaying,
			IsFading  = wrapper.IsFading,
			Priority  = wrapper.Config.Priority,
		})
	end

	table.sort(results, function(a, b)
		if a.LayerOrder ~= b.LayerOrder then
			return a.LayerOrder > b.LayerOrder -- descending order
		end
		return a.Priority > b.Priority
	end)

	return results
end

-- Returns current state of all layers.
function DebugInspector:GetLayerSnapshot(): { { [string]: any } }
	local ctrl = self._controller
	if ctrl.IsDestroyed then return {} end
	return ctrl.LayerManager:GetSnapshot()
end

-- Returns per-group state including pending play requests.
function DebugInspector:GetGroupSnapshot(): { { [string]: any } }
	local ctrl = self._controller
	if ctrl.IsDestroyed then return {} end
	return ctrl.GroupManager:GetSnapshot()
end

-- Returns current SM state and queued transitions.
function DebugInspector:GetStateMachineSnapshot(): { [string]: any }
	local ctrl = self._controller
	if ctrl.IsDestroyed then return {} end
	return ctrl.StateMachine:GetSnapshot()
end

-- Returns a deterministic formatted text tree of current animation state.
-- Format: Layer → Group → Animation → Weight → Status
-- Identical logical state always produces identical output (used as test oracle).
function DebugInspector:GetAnimationTree(): string
	local ctrl = self._controller
	if ctrl.IsDestroyed then return "[DESTROYED]" end

	local layers = ctrl.LayerManager:GetAllLayers()
	local lines  = {}

	-- Sort layers ascending by Order (already sorted in LayerManager, but explicit for clarity)
	for _, layer in layers do
		local layerLine = string.format(
			"Layer[%d] '%s'  cw=%.3f  tw=%.3f  %s%s",
			layer.Order, layer.Name,
			layer.CurrentWeight, layer.TargetWeight,
			layer.Additive  and "[ADDITIVE] " or "",
			layer.Isolated  and "[ISOLATED]" or ""
		)
		table.insert(lines, layerLine)

		-- Collect wrappers on this layer, sorted by Config.Priority desc, then StartTimestamp asc
		local wrappers = {}
		for _, wrapper in ctrl.ActiveWrappers do
			if wrapper.Config.Layer == layer.Name then
				table.insert(wrappers, wrapper)
			end
		end
		table.sort(wrappers, function(a, b)
			if a.Config.Priority ~= b.Config.Priority then
				return a.Config.Priority > b.Config.Priority
			end
			return a.StartTimestamp < b.StartTimestamp
		end)

		for _, wrapper in wrappers do
			local groupStr = wrapper.Config.Group and string.format("[G:%s] ", wrapper.Config.Group) or ""
			local statusStr
			if wrapper.IsPlaying and wrapper.IsFading then
				statusStr = "FADING"
			elseif wrapper.IsPlaying then
				statusStr = "PLAYING"
			else
				statusStr = "STOPPED"
			end
			local wrapperLine = string.format(
				"  └─ %s'%s'  w=%.3f  p=%d  %s",
				groupStr,
				wrapper.Config.Name,
				wrapper.EffectiveWeight,
				wrapper.Config.Priority,
				statusStr
			)
			table.insert(lines, wrapperLine)
		end

		if #wrappers == 0 then
			table.insert(lines, "  └─ (empty)")
		end
	end

	return table.concat(lines, "\n")
end

-- Executes all invariant checks at runtime. Returns any violations.
function DebugInspector:ValidateInvariants(): { Valid: boolean, Violations: { string } }
	local ctrl = self._controller
	local violations = {}

	if ctrl.IsDestroyed then
		return { Valid = false, Violations = { "AnimationController is destroyed" } }
	end

	-- Invariant: No two active wrappers in the same ExclusiveGroup with non-zero weight
	local groupWeights: { [string]: { { name: string, weight: number } } } = {}
	for _, wrapper in ctrl.ActiveWrappers do
		local group = wrapper.Config.Group
		if group and wrapper.EffectiveWeight > 0 then
			if not groupWeights[group] then groupWeights[group] = {} end
			table.insert(groupWeights[group], { name = wrapper.Config.Name, weight = wrapper.EffectiveWeight })
		end
	end
	for group, entries in groupWeights do
		if #entries > 1 then
			local names = {}
			for _, e in entries do table.insert(names, e.name) end
			table.insert(violations, string.format(
				"Group '%s' has %d wrappers with non-zero weight: %s",
				group, #entries, table.concat(names, ", ")
				))
		end
	end

	-- Invariant: All TrackWrapper EffectiveWeights within [0, 1]
	for _, wrapper in ctrl.ActiveWrappers do
		if wrapper.EffectiveWeight < 0 or wrapper.EffectiveWeight > 1 then
			table.insert(violations, string.format(
				"Wrapper '%s' EffectiveWeight %.4f is outside [0, 1]",
				wrapper.Config.Name, wrapper.EffectiveWeight
				))
		end
	end

	-- Invariant: LayerManager layers sorted ascending with no duplicates
	local layerViolations = ctrl.LayerManager:ValidateInvariants()
	for _, v in layerViolations do
		table.insert(violations, v)
	end

	-- Invariant: StateMachine has exactly one current state
	local smState = ctrl.StateMachine:GetCurrentStateName()
	if not smState or smState == "" then
		table.insert(violations, "StateMachine has no current state")
	end

	-- Invariant: No pooled wrapper with IsPlaying = true
	for _, pool in ctrl._wrapperPool do
		for _, wrapper in pool do
			if wrapper.IsPlaying then
				table.insert(violations, string.format(
					"Pooled wrapper for config '%s' has IsPlaying = true",
					wrapper.Config and wrapper.Config.Name or "unknown"
					))
			end
		end
	end

	-- Invariant: ExclusiveGroupManager invariants
	local groupViolations = ctrl.GroupManager:ValidateInvariants()
	for _, v in groupViolations do
		table.insert(violations, v)
	end

	return {
		Valid      = #violations == 0,
		Violations = violations,
	}
end

return DebugInspector