--!strict
-- LayerManager.lua
-- Owned by AnimationController.
-- Manages the ordered set of logical layers assigned to a character.
-- Computes per-layer weight contributions and resolves inter-layer priority.
-- Has NO awareness of ExclusiveGroups.

local Types = require(script.Parent.Types)
type LayerProfile = Types.LayerProfile

-- ── Constants ──────────────────────────────────────────────────────────────

-- Bug #21 fix: floating-point equality against TargetWeight is unreliable after lerp.
-- Use an epsilon threshold instead so the early-out triggers correctly once the
-- weight is effectively settled, and weight pushes are not sent every frame forever.
local WEIGHT_EPSILON = 1e-6

-- ── Layer Runtime Record ───────────────────────────────────────────────────

type LayerRecord = {
	Name           : string,
	Order          : number,
	BaseWeight     : number,
	CurrentWeight  : number,
	TargetWeight   : number,
	Additive       : boolean,
	Isolated       : boolean,
	WeightLerpRate : number, -- fraction per second
	ActiveTracks   : { any }, -- { TrackWrapper }, kept in insertion order
}

-- ── LayerManager ───────────────────────────────────────────────────────────

local LayerManager = {}
LayerManager.__index = LayerManager

export type LayerManager = typeof(setmetatable({} :: {
	_layers       : { LayerRecord },      -- sorted ascending by Order
	_layerByName  : { [string]: LayerRecord },
}, LayerManager))

function LayerManager.new(profiles: { LayerProfile }): LayerManager
	local self = setmetatable({
		_layers      = {} :: { LayerRecord },
		_layerByName = {} :: { [string]: LayerRecord },
	}, LayerManager)

	-- Validate unique orders
	local seenOrders: { [number]: boolean } = {}
	for _, p in profiles do
		assert(not seenOrders[p.Order],
			string.format("[LayerManager] Duplicate layer Order %d for layer '%s'", p.Order, p.Name))
		assert(not self._layerByName[p.Name],
			string.format("[LayerManager] Duplicate layer name '%s'", p.Name))
		seenOrders[p.Order] = true

		local record: LayerRecord = {
			Name           = p.Name,
			Order          = p.Order,
			BaseWeight     = p.BaseWeight,
			CurrentWeight  = p.BaseWeight,
			TargetWeight   = p.BaseWeight,
			Additive       = p.Additive,
			Isolated       = p.Isolated,
			WeightLerpRate = p.WeightLerpRate,
			ActiveTracks   = {},
		}
		table.insert(self._layers, record)
		self._layerByName[p.Name] = record
	end

	-- Sort ascending by Order — invariant maintained, no runtime reorder permitted
	table.sort(self._layers, function(a, b) return a.Order < b.Order end)

	return self
end

-- ── Layer Queries ──────────────────────────────────────────────────────────

function LayerManager:GetLayer(name: string): LayerRecord?
	return self._layerByName[name]
end

function LayerManager:GetAllLayers(): { LayerRecord }
	return self._layers
end

-- ── Weight Targets ─────────────────────────────────────────────────────────

-- Called by StateMachine via AnimationController on state transition
function LayerManager:SetLayerTargetWeight(name: string, target: number)
	local layer = self._layerByName[name]
	assert(layer, string.format("[LayerManager] Unknown layer '%s'", name))
	layer.TargetWeight = math.clamp(target, 0, 1)
end

function LayerManager:SetLayerToBase(name: string)
	local layer = self._layerByName[name]
	if layer then
		layer.TargetWeight = layer.BaseWeight
	end
end

function LayerManager:SuppressLayer(name: string)
	local layer = self._layerByName[name]
	if layer then
		layer.TargetWeight = 0
	end
end

-- ── Per-Frame Weight Interpolation — O(L) ─────────────────────────────────

-- Called once per tick by AnimationController.
-- Advances CurrentWeight toward TargetWeight at the layer's configured rate.
-- Returns true if any layer changed (indicating weight-push step needed).
--
-- Bug #21 fix: replaced ~= comparison with an epsilon check so that weights
-- that have lerped to within WEIGHT_EPSILON of their target are snapped and
-- treated as settled. Without this, floating-point residuals (e.g. 0.9999999)
-- keep anyChanged = true every frame, defeating the early-out optimisation.
function LayerManager:UpdateWeights(dt: number): boolean
	local anyChanged = false
	for _, layer in self._layers do
		local delta = layer.TargetWeight - layer.CurrentWeight
		if math.abs(delta) > WEIGHT_EPSILON then
			local step = layer.WeightLerpRate * dt
			if math.abs(delta) <= step then
				layer.CurrentWeight = layer.TargetWeight
			else
				layer.CurrentWeight = layer.CurrentWeight + math.sign(delta) * step
			end
			anyChanged = true
		elseif layer.CurrentWeight ~= layer.TargetWeight then
			-- Snap the residual to eliminate the float drift permanently.
			layer.CurrentWeight = layer.TargetWeight
			anyChanged = true
		end
	end
	return anyChanged
end

-- ── Final Weight Computation ───────────────────────────────────────────────

-- Computes final weight for a TrackWrapper on its layer.
-- FinalWeight = Layer.CurrentWeight × Wrapper.TargetWeight × Config.Weight
-- Returns a value clamped to [0, 1].
function LayerManager:ComputeFinalWeight(layerName: string, wrapperTargetWeight: number, configWeight: number): number
	local layer = self._layerByName[layerName]
	if not layer then return 0 end
	return math.clamp(layer.CurrentWeight * wrapperTargetWeight * configWeight, 0, 1)
end

-- ── Track Registration ─────────────────────────────────────────────────────

function LayerManager:RegisterTrack(layerName: string, wrapper: any)
	local layer = self._layerByName[layerName]
	assert(layer, string.format("[LayerManager] Cannot register track on unknown layer '%s'", layerName))
	-- Avoid double-registration
	for _, existing in layer.ActiveTracks do
		if existing == wrapper then return end
	end
	table.insert(layer.ActiveTracks, wrapper)
end

function LayerManager:UnregisterTrack(layerName: string, wrapper: any)
	local layer = self._layerByName[layerName]
	if not layer then return end
	for i = #layer.ActiveTracks, 1, -1 do
		if layer.ActiveTracks[i] == wrapper then
			table.remove(layer.ActiveTracks, i)
			return
		end
	end
end

-- Returns snapshot data for DebugInspector
function LayerManager:GetSnapshot(): { { [string]: any } }
	local out = {}
	for _, layer in self._layers do
		table.insert(out, {
			Name             = layer.Name,
			Order            = layer.Order,
			CurrentWeight    = layer.CurrentWeight,
			TargetWeight     = layer.TargetWeight,
			Additive         = layer.Additive,
			Isolated         = layer.Isolated,
			ActiveTrackCount = #layer.ActiveTracks,
		})
	end
	return out
end

-- Validates layer invariants — used by DebugInspector:ValidateInvariants
-- Bug #13 fix: added cross-validation between ActiveTracks and the caller-supplied
-- activeWrappers map so that orphaned track registrations are surfaced.
function LayerManager:ValidateInvariants(activeWrappers: { [string]: any }?): { string }
	local violations = {}

	-- Check sorted ascending order with no duplicates
	for i = 2, #self._layers do
		if self._layers[i].Order <= self._layers[i - 1].Order then
			table.insert(violations, string.format(
				"Layer order violation: '%s' (Order %d) not strictly greater than '%s' (Order %d)",
				self._layers[i].Name, self._layers[i].Order,
				self._layers[i - 1].Name, self._layers[i - 1].Order
			))
		end
	end

	-- Cross-check ActiveTracks against the controller's ActiveWrappers if provided.
	-- An entry in ActiveTracks that is not in ActiveWrappers indicates a leak from
	-- a wrapper that was retired without UnregisterTrack being called.
	if activeWrappers then
		for _, layer in self._layers do
			for _, trackWrapper in layer.ActiveTracks do
				local found = false
				for _, w in activeWrappers do
					if w == trackWrapper then
						found = true
						break
					end
				end
				if not found then
					table.insert(violations, string.format(
						"Layer '%s' ActiveTracks contains a wrapper ('%s') not in AnimationController.ActiveWrappers — possible leak",
						layer.Name,
						trackWrapper.Config and trackWrapper.Config.Name or "unknown"
					))
				end
			end
		end
	end

	return violations
end

return LayerManager
return LayerManager
