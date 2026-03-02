--!strict
-- ─── AnimationRegistry.lua ────────────────────────────────────────────────────
--[[
    Singleton registry for AnimationConfig records.

    This module is the authoritative source of animation metadata at runtime. It is
    shared across all AnimationController instances on the same machine (server or client)
    because animation configs are machine-wide constants — they do not vary per character.

    The registry operates in two phases:
      1. Uninitialized — no configs are stored. Queries assert-fail to prevent silent bugs.
      2. Initialized   — configs are validated, indexed, and deep-frozen. No further writes
                         are permitted. The singleton becomes permanently read-only.

    This strict two-phase design means misconfiguration (missing fields, wrong types,
    duplicate names) always surfaces at startup as a hard error rather than silently
    producing wrong animation behaviour during gameplay.

    Indexes maintained after Init:
      • _NameIndex  — O(1) lookup by config Name.
      • _TagIndex   — O(1) lookup of all configs bearing a given tag string.
      • _GroupIndex — O(1) lookup of all configs belonging to a given group name.
]]

local Types = require(script.Parent.Types)

-- Import the type alias locally so it can be used in type annotations below.
type AnimationConfig = Types.AnimationConfig

-- ─── Required Field Schema ────────────────────────────────────────────────────

--[[
    REQUIRED_FIELDS maps every field that MUST be present in a raw config table to the
    Lua type name that field's value must satisfy (as returned by the built-in type()).

    Using a table rather than a long series of if-statements means adding a new required
    field only requires one entry here — the validation loop picks it up automatically.
    Fields that are optional (Group, MinDuration, Metadata) are NOT listed here;
    they are checked separately below validateConfig with nil-tolerance.
]]
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

-- ─── Config Validation ────────────────────────────────────────────────────────

--[[
    validateConfig

    Description:
        Checks that a raw config table satisfies all structural requirements before
        it is frozen and stored. Validation is intentionally strict: every required
        field must exist and carry the correct type, and Weight must fall within its
        legal range. Optional fields are type-checked only when present.

    Parameters:
        RawConfig: any
            The raw table submitted by game code. Typed as `any` because it has not
            yet been validated — we cannot assume its shape is correct.

    Returns:
        (boolean, string)
            true, ""           — config is valid.
            false, errorMessage — first structural violation found. Only the first
                                   error is returned; callers assert on it immediately.

    Notes:
        The function returns rather than asserts so the caller can include the config
        index and name in the error message, producing more actionable output than a
        bare assert inside this function could provide.
]]
local function ValidateConfig(RawConfig: any): (boolean, string)
	-- Iterate every required field and verify presence and type.
	-- If any field is missing or has the wrong type, return immediately with a
	-- descriptive message rather than continuing — we want the FIRST violation.
	for FieldName, ExpectedType in REQUIRED_FIELDS do
		local FieldValue = RawConfig[FieldName]
		if FieldValue == nil then
			return false, string.format("Missing required field '%s'", FieldName)
		end
		if type(FieldValue) ~= ExpectedType then
			return false, string.format(
				"Field '%s' expected %s, got %s",
				FieldName, ExpectedType, type(FieldValue)
			)
		end
	end

	-- Weight has an additional range constraint beyond just being a number.
	-- The half-open interval (0, 1] is required because:
	--   • Weight = 0 would mean the animation never contributes, which is a no-op config.
	--   • Weight > 1 would multiply beyond the layer's CurrentWeight, producing a final
	--     EffectiveWeight above 1, which AnimationTrack:AdjustWeight does not accept.
	local IsWeightOutOfRange = (RawConfig.Weight <= 0) or (RawConfig.Weight > 1)
	if IsWeightOutOfRange then
		return false, string.format(
			"Field 'Weight' must be in (0, 1], got %g",
			RawConfig.Weight
		)
	end

	-- Optional fields: only validate type when the field is actually present.
	-- Using separate guards rather than a combined table means the error messages can
	-- be specific about which optional field violated its expected type.
	if RawConfig.Group ~= nil and type(RawConfig.Group) ~= "string" then
		return false, "Field 'Group' must be string or nil"
	end
	if RawConfig.MinDuration ~= nil and type(RawConfig.MinDuration) ~= "number" then
		return false, "Field 'MinDuration' must be number or nil"
	end
	if RawConfig.Metadata ~= nil and type(RawConfig.Metadata) ~= "table" then
		return false, "Field 'Metadata' must be table or nil"
	end

	return true, ""
end

-- ─── Deep Freeze Utility ──────────────────────────────────────────────────────

--[[
    DeepFreeze

    Description:
        Recursively applies table.freeze to a table and all nested tables within it.

        table.freeze is shallow — it prevents new keys from being added or existing
        keys from being reassigned on the DIRECT table, but any table values inside
        remain mutable. AnimationConfig.Metadata may contain arbitrarily nested tables,
        so a shallow freeze would leave inner tables writable, violating the invariant
        that configs are fully immutable after Init.

        By recursing into every table-valued field before freezing the parent, we
        guarantee that no code anywhere can mutate any part of a config after Init,
        regardless of nesting depth.

    Parameters:
        Target: { [any]: any }
            The table to freeze. Must not be frozen already (table.freeze on an already-
            frozen table raises an error in Luau).

    Returns:
        { [any]: any }
            The same table, now frozen. Returning it allows the call site to do
            `FrozenTable = DeepFreeze(table.clone(src))` in one expression.

    Notes:
        This function is only called during Init, so performance is not a concern.
        It is not exposed outside this module.
]]
local function DeepFreeze(Target: { [any]: any }): { [any]: any }
	for _, Value in Target do
		-- Only recurse into mutable tables. Frozen tables were already processed
		-- (or arrived frozen from somewhere else) and table.freeze on them would error.
		if type(Value) == "table" and not table.isfrozen(Value) then
			DeepFreeze(Value)
		end
	end
	-- Freeze the parent table after all its children are frozen so that nested
	-- tables are immutable before the parent itself becomes immutable.
	return table.freeze(Target)
end

-- ─── Module Definition ────────────────────────────────────────────────────────

local AnimationRegistry = {}
AnimationRegistry.__index = AnimationRegistry

-- ─── Instance Type ────────────────────────────────────────────────────────────

--[[
    The internal shape of an AnimationRegistry instance. Typed explicitly so that
    the Luau type checker can verify field access throughout the module.

    _NameIndex  — primary lookup map from animation Name → frozen AnimationConfig.
    _TagIndex   — secondary lookup map from tag string → array of matching configs.
    _GroupIndex — secondary lookup map from group name → array of member configs.
    _IsInitialized — once true, the registry is read-only and queries are legal.
                     The name _IsInitialized is more self-documenting than _Frozen.
]]
type RegistryInstance = {
	_NameIndex: { [string]: AnimationConfig },
	_TagIndex: { [string]: { AnimationConfig } },
	_GroupIndex: { [string]: { AnimationConfig } },
	_IsInitialized: boolean,
}

-- ─── Singleton Storage ────────────────────────────────────────────────────────

-- The single shared instance. nil until GetInstance() is first called.
-- Using a module-level upvalue rather than a field on the module table prevents
-- game code from accidentally overwriting it or constructing a second instance.
local _SingletonInstance: any = nil

-- ─── Singleton Access ─────────────────────────────────────────────────────────

--[=[
    AnimationRegistry.GetInstance

    Description:
        Returns the shared singleton AnimationRegistry. Creates it on the first call.

        All AnimationController instances on the same machine share one registry because
        animation configs are global constants — there is no per-character variant.
        Using a singleton avoids passing the registry through every constructor and
        ensures only one copy of the config data exists in memory.

    Returns:
        AnimationRegistry
            The singleton instance (untyped `any` to avoid circular reference issues
            in strict mode when the metatype references itself).

    Notes:
        The returned instance is uninitialized until Init is called. Calling any
        query method before Init will cause an assert.
]=]
function AnimationRegistry.GetInstance(): any
	if not _SingletonInstance then
		-- Construct the instance with empty indexes and _IsInitialized = false.
		-- The indexes are populated and frozen in Init.
		_SingletonInstance = setmetatable({
			_NameIndex     = {},
			_TagIndex      = {},
			_GroupIndex    = {},
			_IsInitialized = false,
		}, AnimationRegistry)
	end
	return _SingletonInstance
end

--[=[
    AnimationRegistry._ResetForTest

    Description:
        Destroys the singleton instance so that a new Init call can be made.
        MUST NOT be called in production builds. Intended exclusively for unit tests
        that need to construct a fresh registry with different config sets between
        test cases.

        Note: after calling this, all pooled TrackWrappers that were constructed
        against the old registry's configs should also be destroyed (and pools cleared)
        before re-initializing, because TrackWrapper caches the config reference and
        would otherwise hold stale pointers to configs that no longer exist in the new
        registry. See the Bug #14 note in TrackWrapper._Reinitialize.

    Notes:
        This function is intentionally not guarded — if it is called in production
        by mistake, the next GetInstance/Init call will construct a fresh registry.
        The game is responsible for not calling this outside test context.
]=]
function AnimationRegistry._ResetForTest()
	_SingletonInstance = nil
end

-- ─── Initialization ───────────────────────────────────────────────────────────

--[=[
    AnimationRegistry:Init

    Description:
        Validates an array of raw config tables, builds the three lookup indexes,
        deep-freezes every config, and locks the registry against further writes.

        After Init returns, the registry is permanently read-only. Any attempt to call
        Init again on the same instance is a fatal error (asserted), because allowing
        re-initialization would silently invalidate references held by already-running
        controllers and wrappers.

    Parameters:
        Configs: { any }
            Array of raw tables, each representing one animation config. Typed as
            `any` rather than `AnimationConfig` because they have not yet been
            validated — asserting the type here would be the wrong layer of defense.

    Notes:
        • Validation runs on all configs before any freezing begins, so the full error
          list is surfaced in one pass rather than partly building indexes before failing.
          (Actually, the current implementation validates-then-inserts per config;
           changing this to validate-all-first would require two loops but better error UX.)
        • The Tags and Group arrays in each frozen config are frozen independently
          from the outer table to prevent mutation of the arrays even though the outer
          table is frozen.
        • Metadata undergoes a full DeepFreeze because it may contain nested tables.
]=]
function AnimationRegistry:Init(Configs: { any })
	-- Prevent double-initialization. Controllers cache the registry reference at
	-- construction time; re-initializing would leave them pointing at stale data.
	assert(
		not self._IsInitialized,
		"[AnimationRegistry] Already initialized. Init may only be called once."
	)

	for ConfigIndex, RawConfig in Configs do
		-- Validate structure and types before touching any internal state.
		-- This ensures partial initialization never occurs — if config #5 of 10 fails,
		-- configs 1–4 are already inserted, but _IsInitialized remains false so queries
		-- cannot reach them. Callers should treat a failed Init as a fatal startup error.
		local IsValid, ValidationError = ValidateConfig(RawConfig)
		assert(
			IsValid,
			string.format(
				"[AnimationRegistry] Config #%d ('%s'): %s",
				ConfigIndex, tostring(RawConfig.Name), ValidationError
			)
		)

		-- Duplicate names would silently overwrite the first entry in _NameIndex.
		-- Asserting here makes name collisions an immediate fatal error, which is far
		-- more debuggable than a hard-to-trace "wrong animation plays" at runtime.
		assert(
			not self._NameIndex[RawConfig.Name],
			string.format(
				"[AnimationRegistry] Duplicate animation name '%s' at index %d",
				RawConfig.Name, ConfigIndex
			)
		)

		-- Deep-freeze Metadata separately because DeepFreeze recurses into tables
		-- before freezing the parent. We clone first to avoid freezing the caller's
		-- original table, which they may still be using. Nil is preserved as nil.
		local FrozenMetadata: { [string]: any }? = nil
		if RawConfig.Metadata ~= nil then
			FrozenMetadata = DeepFreeze(table.clone(RawConfig.Metadata)) :: { [string]: any }
		end

		-- Build the frozen config by explicitly listing every field.
		-- Explicitly mapping fields (rather than cloning the raw table directly) ensures:
		--   1. No unexpected extra fields from the raw table are preserved.
		--   2. The type signature of the frozen record exactly matches AnimationConfig.
		--   3. The Tags array is frozen as a separate inner freeze (table.freeze is called
		--      on the clone, not the original, to leave the caller's data intact).
		local FrozenConfig: AnimationConfig = table.freeze({
			Name         = RawConfig.Name,
			AssetId      = RawConfig.AssetId,
			Layer        = RawConfig.Layer,
			Group        = RawConfig.Group,
			Priority     = RawConfig.Priority,
			Looped       = RawConfig.Looped,
			FadeInTime   = RawConfig.FadeInTime,
			FadeOutTime  = RawConfig.FadeOutTime,
			Speed        = RawConfig.Speed,
			CanInterrupt = RawConfig.CanInterrupt,
			-- Clone Tags before freezing so the caller's original array is not frozen.
			-- The array itself must be frozen (not just the outer config table) to prevent
			-- code from appending to FrozenConfig.Tags after Init.
			Tags         = table.freeze(table.clone(RawConfig.Tags)),
			Additive     = RawConfig.Additive,
			Weight       = RawConfig.Weight,
			MinDuration  = RawConfig.MinDuration,
			Metadata     = FrozenMetadata,
		})

		-- Primary name index: O(1) lookup by exact config name.
		self._NameIndex[RawConfig.Name] = FrozenConfig

		-- Tag index: a config may carry multiple tags, so it can appear in multiple
		-- tag buckets. Buckets are created on demand to avoid pre-allocating for every
		-- possible tag name upfront.
		for _, TagName in RawConfig.Tags do
			if not self._TagIndex[TagName] then
				self._TagIndex[TagName] = {}
			end
			table.insert(self._TagIndex[TagName], FrozenConfig)
		end

		-- Group index: used by external tools and StopGroup to enumerate all configs
		-- belonging to an exclusive group. Only populated when a Group is specified.
		if RawConfig.Group then
			if not self._GroupIndex[RawConfig.Group] then
				self._GroupIndex[RawConfig.Group] = {}
			end
			table.insert(self._GroupIndex[RawConfig.Group], FrozenConfig)
		end
	end

	-- Freeze the index arrays themselves so callers who receive a tag or group
	-- result cannot append to or remove from the live index bucket.
	-- We do NOT freeze the top-level index tables (_TagIndex, _GroupIndex) because
	-- that would prevent new buckets being created during a hypothetical future
	-- hot-reload Init. The arrays inside are what matter.
	for _, TagBucket in self._TagIndex do
		table.freeze(TagBucket)
	end
	for _, GroupBucket in self._GroupIndex do
		table.freeze(GroupBucket)
	end

	-- Mark the registry as initialized. From this point, all query methods are legal
	-- and all write methods (Init itself) will assert-fail if called again.
	self._IsInitialized = true
end

-- ─── Query API ────────────────────────────────────────────────────────────────

--[[
    All queries assert that Init has been called first. This design means any access
    to registry data before startup completes produces a clear error message pointing
    to the registry, rather than a cryptic nil-index error deep in some other module.

    All lookups are O(1) — the three indexes were built during Init specifically to
    ensure that per-frame conflict resolution and play requests do not incur O(N) scans.
]]

--[=[
    AnimationRegistry:GetByName

    Description:
        Returns the frozen AnimationConfig whose Name exactly matches the given string,
        or nil if no such config was registered.

        This is the primary lookup path used by AnimationController._ExecutePlayRequest
        on every play request. O(1) hash lookup.

    Parameters:
        Name: string
            The exact animation name to search for.

    Returns:
        AnimationConfig?
            The matching config, or nil if not found.

    Notes:
        Returns nil rather than asserting on unknown names so that AnimationController
        can emit a warn() and continue rather than crashing on a typo in game code.
]=]
function AnimationRegistry:GetByName(Name: string): AnimationConfig?
	assert(self._IsInitialized, "[AnimationRegistry] Registry not yet initialized.")
	return self._NameIndex[Name]
end

--[=[
    AnimationRegistry:GetByTag

    Description:
        Returns the frozen array of AnimationConfigs that carry the given tag.
        If no configs bear this tag, returns an empty table (never nil).

        Used by AnimationController:PlayTag to batch-play all animations tagged
        with a given string (e.g. "hit-reaction", "locomotion").

    Parameters:
        Tag: string
            The tag string to search for.

    Returns:
        { AnimationConfig }
            Array of matching configs. Empty if the tag is unknown. The returned
            array is frozen — callers must not mutate it.

    Notes:
        Returning {} instead of nil removes the need for nil-guards at every call site.
        The empty table is a new allocation, but call sites that iterate it with a
        for-loop get zero iterations for free without any special-casing.
]=]
function AnimationRegistry:GetByTag(Tag: string): { AnimationConfig }
	assert(self._IsInitialized, "[AnimationRegistry] Registry not yet initialized.")
	return self._TagIndex[Tag] or {}
end

--[=[
    AnimationRegistry:GetByGroup

    Description:
        Returns the frozen array of AnimationConfigs that belong to the given
        exclusive group, or an empty table if the group name is unknown.

        Used primarily by debug tooling and by StopGroup to enumerate all configs
        that could be playing in a given group.

    Parameters:
        Group: string
            The group name to search for.

    Returns:
        { AnimationConfig }
            Array of member configs. Empty if the group is unknown. Frozen.
]=]
function AnimationRegistry:GetByGroup(Group: string): { AnimationConfig }
	assert(self._IsInitialized, "[AnimationRegistry] Registry not yet initialized.")
	return self._GroupIndex[Group] or {}
end

--[=[
    AnimationRegistry:IsInitialized

    Description:
        Returns whether Init has been successfully called on this instance.

        Used by AnimationController.new to guard against constructing a controller
        before the registry is ready, producing a clear error at the right callsite.

    Returns:
        boolean
            true if Init has completed; false if not yet called.
]=]
function AnimationRegistry:IsInitialized(): boolean
	return self._IsInitialized
end

return AnimationRegistry