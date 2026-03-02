--!strict
-- AnimationRegistry.lua
-- Singleton. Shared across all controllers on a given machine.
-- Stores AnimationConfig records indexed by name, tag, and group.
-- Immutable after initialization. Never references live tracks or controllers.

local Types = require(script.Parent.Types)
type AnimationConfig = Types.AnimationConfig

-- ── Validation ─────────────────────────────────────────────────────────────

local REQUIRED_FIELDS: { [string]: string } = {
	Name         = "string",
	AssetId      = "string",
	Layer        = "string",
	Priority     = "number",
	Looped       = "boolean",
	FadeInTime   = "number",
	FadeOutTime  = "number",
	Speed        = "number",
	CanInterrupt = "boolean",
	Tags         = "table",
	Additive     = "boolean",
	Weight       = "number",
}

local function validateConfig(cfg: any): (boolean, string)
	for field, expectedType in REQUIRED_FIELDS do
		local value = cfg[field]
		if value == nil then
			return false, string.format("Missing required field '%s'", field)
		end
		if type(value) ~= expectedType then
			return false, string.format(
				"Field '%s' expected %s, got %s", field, expectedType, type(value)
			)
		end
	end
	if type(cfg.Weight) == "number" and (cfg.Weight <= 0 or cfg.Weight > 1) then
		return false, string.format("Field 'Weight' must be in (0, 1], got %g", cfg.Weight)
	end
	-- Optional typed fields
	if cfg.Group ~= nil and type(cfg.Group) ~= "string" then
		return false, "Field 'Group' must be string or nil"
	end
	if cfg.MinDuration ~= nil and type(cfg.MinDuration) ~= "number" then
		return false, "Field 'MinDuration' must be number or nil"
	end
	if cfg.Metadata ~= nil and type(cfg.Metadata) ~= "table" then
		return false, "Field 'Metadata' must be table or nil"
	end
	return true, ""
end

-- ── Module ─────────────────────────────────────────────────────────────────

local AnimationRegistry = {}
AnimationRegistry.__index = AnimationRegistry

type AnimationRegistry = {
	_nameIndex  : { [string]: AnimationConfig },
	_tagIndex   : { [string]: { AnimationConfig } },
	_groupIndex : { [string]: { AnimationConfig } },
	_frozen     : boolean,
}

-- Singleton instance
local _instance: any = nil

function AnimationRegistry.GetInstance(): any
	if not _instance then
		_instance = setmetatable({
			_nameIndex  = {},
			_tagIndex   = {},
			_groupIndex = {},
			_frozen     = false,
		}, AnimationRegistry)
	end
	return _instance
end

-- Reset for testing — not available in production builds
function AnimationRegistry._ResetForTest()
	_instance = nil
end

-- ── Initialization ─────────────────────────────────────────────────────────

-- Initialize with an array of raw config tables.
-- Validates all entries, then builds indexes and freezes.
-- Calling Init more than once is a fatal error.
function AnimationRegistry:Init(configs: { any })
	assert(not self._frozen, "[AnimationRegistry] Already initialized. Init may only be called once.")

	for i, cfg in configs do
		local ok, err = validateConfig(cfg)
		assert(ok, string.format("[AnimationRegistry] Config #%d ('%s'): %s", i, tostring(cfg.Name), err))
		assert(
			not self._nameIndex[cfg.Name],
			string.format("[AnimationRegistry] Duplicate animation name '%s' at index %d", cfg.Name, i)
		)

		local frozen: AnimationConfig = table.freeze({
			Name         = cfg.Name,
			AssetId      = cfg.AssetId,
			Layer        = cfg.Layer,
			Group        = cfg.Group,
			Priority     = cfg.Priority,
			Looped       = cfg.Looped,
			FadeInTime   = cfg.FadeInTime,
			FadeOutTime  = cfg.FadeOutTime,
			Speed        = cfg.Speed,
			CanInterrupt = cfg.CanInterrupt,
			Tags         = table.freeze(table.clone(cfg.Tags)),
			Additive     = cfg.Additive,
			Weight       = cfg.Weight,
			MinDuration  = cfg.MinDuration,
			Metadata     = cfg.Metadata and table.freeze(table.clone(cfg.Metadata)) or nil,
		})

		-- Name index
		self._nameIndex[cfg.Name] = frozen

		-- Tag index
		for _, tag in cfg.Tags do
			if not self._tagIndex[tag] then
				self._tagIndex[tag] = {}
			end
			table.insert(self._tagIndex[tag], frozen)
		end

		-- Group index
		if cfg.Group then
			if not self._groupIndex[cfg.Group] then
				self._groupIndex[cfg.Group] = {}
			end
			table.insert(self._groupIndex[cfg.Group], frozen)
		end
	end

	-- Freeze all index arrays
	for tag, arr in self._tagIndex do
		table.freeze(arr)
	end
	for group, arr in self._groupIndex do
		table.freeze(arr)
	end

	self._frozen = true
end

-- ── Queries — all O(1) primary lookup ─────────────────────────────────────

function AnimationRegistry:GetByName(name: string): AnimationConfig?
	assert(self._frozen, "[AnimationRegistry] Registry not yet initialized.")
	return self._nameIndex[name]
end

-- Returns array of configs bearing the given tag. O(1) retrieval of array.
function AnimationRegistry:GetByTag(tag: string): { AnimationConfig }
	assert(self._frozen, "[AnimationRegistry] Registry not yet initialized.")
	return self._tagIndex[tag] or {}
end

-- Returns array of configs in the given exclusive group.
function AnimationRegistry:GetByGroup(group: string): { AnimationConfig }
	assert(self._frozen, "[AnimationRegistry] Registry not yet initialized.")
	return self._groupIndex[group] or {}
end

function AnimationRegistry:IsInitialized(): boolean
	return self._frozen
end

return AnimationRegistry