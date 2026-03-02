--!strict
-- ─── AnimationController / init.lua ──────────────────────────────────────────
--[[
    AnimationController is the root orchestrator for the entire animation framework.
    One instance exists per character, on each machine that simulates that character.

    ── Ownership and Environment Roles ──────────────────────────────────────────

    Owning Client (IsOwningClient = true, IS_SERVER = false):
        Responds to input and game logic by calling Play/Stop. These actions are
        executed locally on real AnimationTracks and simultaneously queued as
        AnimationIntents for relay to the server.

    Server (IS_SERVER = true):
        Runs the StateMachine and ExclusiveGroupManager to maintain authoritative
        state. Never loads or plays AnimationTracks — Animator is always nil on the
        server. Relays intents from the owning client to non-owning clients and
        broadcasts periodic snapshots for desync recovery.

    Non-Owning Client (IsOwningClient = false, IS_SERVER = false):
        Receives relayed intents from the server and reconstructs animation state
        locally by running the full play pipeline. Also subscribes to snapshots and
        reconciles when sequence counters diverge.

    ── Module Subsystems ─────────────────────────────────────────────────────────

    AnimationController owns and coordinates five subsystems:
        LayerManager          — Manages layer weight interpolation and track registration.
        ExclusiveGroupManager — Enforces mutual-exclusivity within named animation groups.
        StateMachine          — Flat FSM governing state transitions and directive dispatch.
        ReplicationBridge     — Handles intent serialisation, relay, and snapshot recovery.
        TrackWrappers         — Per-animation lifecycle wrappers (owned exclusively here).

    ── Invariants ────────────────────────────────────────────────────────────────

    1. No external system ever touches an AnimationTrack directly.
    2. All animation operations enter through Play or Stop and are flushed in order.
    3. The server's Animator field is always nil.
    4. A wrapper in the pool never has IsPlaying = true.
    5. ActiveWrappers[name] always matches LayerManager's ActiveTracks for that layer.
]]

local RunService = game:GetService("RunService")

local Types                 = require(script.Types)
local TrackWrapper          = require(script.TrackWrapper)
local LayerManager          = require(script.LayerManager)
local ExclusiveGroupManager = require(script.ExclusiveGroupManager)
local StateMachine          = require(script.StateMachine)
local ConflictResolver      = require(script.ConflictResolver)
local AnimationRegistry     = require(script.AnimationRegistry)
local ReplicationBridge     = require(script.ReplicationBridge)

type AnimationConfig    = Types.AnimationConfig
type LayerProfile       = Types.LayerProfile
type StateDefinition    = Types.StateDefinition
type AnimationDirective = Types.AnimationDirective
type PlayRequest        = Types.PlayRequest

-- ─── Environment Constant ─────────────────────────────────────────────────────

local IS_SERVER = RunService:IsServer()

-- ─── Pool Constant ────────────────────────────────────────────────────────────

local MAX_POOL_SIZE_PER_CONFIG = 2

-- ─── Construction Config Type ─────────────────────────────────────────────────

--[[
    ControllerConfig is the complete set of parameters required to initialize a
    fully functional AnimationController.

    Fields:
        CharacterId    — Unique identifier used by replication to route intents and
                         snapshots to the correct character.
        Animator       — The Roblox Animator instance. Nil on server; non-nil on clients.
        IsOwningClient — True only on the client whose input drives this character.
        OwningPlayer   — The Player instance that owns this character. Required on the
                         server so ReplicationBridge can FireExcept the owner when
                         broadcasting snapshots. Nil on clients (unused).
        LayerProfiles  — Array of LayerProfile records for LayerManager.
        States         — Array of StateDefinition records for StateMachine.
        InitialState   — Name of the FSM state to start in.
        Predicates     — Map of condition strings to zero-arg boolean functions.

    Note: IntentRemote and SnapshotRemote have been removed. ReplicationBridge now
    requires the Blink-generated network modules directly as static dependencies.
]]
export type ControllerConfig = {
	CharacterId    : string,
	Animator       : Animator?,
	IsOwningClient : boolean,
	OwningPlayer   : Player?,
	LayerProfiles  : { LayerProfile },
	States         : { StateDefinition },
	InitialState   : string,
	Predicates     : { [string]: () -> boolean },
}

-- ─── Module Table ─────────────────────────────────────────────────────────────

local AnimationController = {}
AnimationController.__index = AnimationController

-- ─── Constructor ──────────────────────────────────────────────────────────────

function AnimationController.new(Config: ControllerConfig): any
	local Registry = AnimationRegistry.GetInstance()
	assert(
		Registry:IsInitialized(),
		"[AnimationController] AnimationRegistry must be initialized before creating controllers"
	)

	if IS_SERVER and Config.Animator ~= nil then
		warn(
			"[AnimationController] Animator was passed on the server. It will be ignored. " ..
				"The server does not load or play AnimationTracks."
		)
	end

	local self = setmetatable({
		CharacterId  = Config.CharacterId,
		Animator     = IS_SERVER and nil or Config.Animator,
		IsDestroyed  = false,

		LayerManager = nil,
		GroupManager = nil,
		StateMachine = nil,

		ActiveWrappers = {} :: { [string]: any },
		PendingQueue   = {} :: { PlayRequest },
		_WrapperPool   = {} :: { [string]: { any } },

		_Replication = nil,
		_FrameConn   = nil :: RBXScriptConnection?,
	}, AnimationController)

	-- ── Build LayerManager ──────────────────────────────────────────────────
	self.LayerManager = LayerManager.new(Config.LayerProfiles)

	-- ── Build ExclusiveGroupManager ─────────────────────────────────────────
	self.GroupManager = ExclusiveGroupManager.new(
		function(GroupName: string, PendingWrapper: any)
			self:_OnPendingReady(GroupName, PendingWrapper)
		end,
		function(DiscardedWrapper: any)
			local ConfigName = DiscardedWrapper.Config.Name

			if not self._WrapperPool[ConfigName] then
				self._WrapperPool[ConfigName] = {}
			end

			local Pool = self._WrapperPool[ConfigName]
			local IsPoolBelowCapacity = #Pool < MAX_POOL_SIZE_PER_CONFIG
			local IsWrapperSafeToPool = DiscardedWrapper:_IsPoolReady()

			if IsPoolBelowCapacity and IsWrapperSafeToPool then
				DiscardedWrapper.CompletedSignal:DisconnectAll()
				table.insert(Pool, DiscardedWrapper)
			else
				DiscardedWrapper:_Destroy()
			end
		end
	)

	-- ── Build StateMachine ──────────────────────────────────────────────────
	self.StateMachine = StateMachine.new(
		Config.States,
		Config.InitialState,
		Config.Predicates,
		function(ExitingState: StateDefinition, EnteringState: StateDefinition)
			self:_OnStateChange(ExitingState, EnteringState)
		end
	)

	-- ── Build ReplicationBridge ─────────────────────────────────────────────

	-- required internally by ReplicationBridge as static dependencies.
	-- OwningPlayer is now passed so FireExcept works correctly on the server.
	self._Replication = ReplicationBridge.New(
		Config.CharacterId,
		Config.IsOwningClient,
		Config.OwningPlayer,
		function(ReceivedIntent: Types.AnimationIntent)
			self:_OnIntentReceived(ReceivedIntent)
		end,
		function(MismatchedSnapshot: any)
			self:_OnSnapshotMismatch(MismatchedSnapshot)
		end
	)

	-- ── Bind Per-Frame Update ───────────────────────────────────────────────
	local UpdateEvent = IS_SERVER and RunService.Heartbeat or RunService.RenderStepped
	self._FrameConn = UpdateEvent:Connect(function(DeltaTime: number)
		self:_Tick(DeltaTime)
	end)

	return self
end

-- ─── Per-Frame Pipeline ───────────────────────────────────────────────────────

function AnimationController:_Tick(DeltaTime: number)
	if self.IsDestroyed then return end

	self.StateMachine:Tick()
	self.LayerManager:UpdateWeights(DeltaTime)
	self:_PushWeights()

	local ActiveGroupAnimMap = self:_BuildActiveGroupAnimMap()
	self._Replication:Flush(
		DeltaTime,
		self.StateMachine:GetCurrentStateName(),
		ActiveGroupAnimMap
	)

	self:_FlushPendingQueue()
end

-- ─── Weight Push ──────────────────────────────────────────────────────────────

function AnimationController:_PushWeights()
	local WrappersToRetire: { string } = {}

	for AnimationName, Wrapper in self.ActiveWrappers do
		local FinalWeight = self.LayerManager:ComputeFinalWeight(
			Wrapper.Config.Layer,
			Wrapper.TargetWeight,
			Wrapper.Config.Weight
		)
		Wrapper:_SetEffectiveWeight(FinalWeight)

		local IsReadyToRetire = not Wrapper.IsPlaying
			and not Wrapper.IsFading
			and Wrapper.EffectiveWeight == 0

		if IsReadyToRetire then
			table.insert(WrappersToRetire, AnimationName)
		end
	end

	for _, AnimationName in WrappersToRetire do
		self:_RetireWrapper(AnimationName)
	end
end

-- ─── Wrapper Retirement and Pooling ──────────────────────────────────────────

function AnimationController:_RetireWrapper(ConfigName: string)
	local RetiredWrapper = self.ActiveWrappers[ConfigName]
	if not RetiredWrapper then return end

	self.LayerManager:UnregisterTrack(RetiredWrapper.Config.Layer, RetiredWrapper)

	-- Bug B fix: proactively clear the group slot if this wrapper still occupies it.

	if RetiredWrapper.Config.Group then
		local GroupName = RetiredWrapper.Config.Group
		local IsStillActiveInGroup = self.GroupManager:GetActiveWrapper(GroupName) == RetiredWrapper

		if IsStillActiveInGroup then
			self.GroupManager:OnActiveCompleted(GroupName)
		end
	end

	self.ActiveWrappers[ConfigName] = nil

	if not self._WrapperPool[ConfigName] then
		self._WrapperPool[ConfigName] = {}
	end

	local Pool = self._WrapperPool[ConfigName]
	local IsPoolBelowCapacity = #Pool < MAX_POOL_SIZE_PER_CONFIG
	local IsWrapperSafeToPool = RetiredWrapper:_IsPoolReady()

	if IsPoolBelowCapacity and IsWrapperSafeToPool then
		RetiredWrapper.CompletedSignal:DisconnectAll()
		table.insert(Pool, RetiredWrapper)
	else
		RetiredWrapper:_Destroy()
	end
end

-- ─── Wrapper Acquisition ──────────────────────────────────────────────────────

function AnimationController:_AcquireWrapper(Config: AnimationConfig): any
	local Pool = self._WrapperPool[Config.Name]
	if Pool and #Pool > 0 then
		local ReusedWrapper = table.remove(Pool) :: any
		ReusedWrapper:_Reinitialize()
		return ReusedWrapper
	end

	if IS_SERVER then
		return TrackWrapper.new(Config, nil)
	end

	assert(self.Animator, "[AnimationController] Animator is nil on client — cannot load track")

	local AnimationInstance = Instance.new("Animation")
	AnimationInstance.AnimationId = Config.AssetId

	local LoadedTrack = self.Animator:LoadAnimation(AnimationInstance)
	AnimationInstance:Destroy()

	return TrackWrapper.new(Config, LoadedTrack)
end

-- ─── Public Play API ──────────────────────────────────────────────────────────

function AnimationController:Play(AnimationName: string)
	assert(not self.IsDestroyed, "[AnimationController] Cannot play on a destroyed controller")
	table.insert(self.PendingQueue, {
		ConfigName  = AnimationName,
		RequestTime = os.clock(),
	})
end

function AnimationController:PlayTag(Tag: string)
	local Registry = AnimationRegistry.GetInstance()
	for _, Config in Registry:GetByTag(Tag) do
		self:Play(Config.Name)
	end
end

-- ─── Public Stop API ──────────────────────────────────────────────────────────

function AnimationController:Stop(AnimationName: string, Immediate: boolean?)
	for QueueIndex = #self.PendingQueue, 1, -1 do
		if self.PendingQueue[QueueIndex].ConfigName == AnimationName then
			table.remove(self.PendingQueue, QueueIndex)
		end
	end

	local Wrapper = self.ActiveWrappers[AnimationName]
	if not Wrapper then return end

	local IsHardStop = Immediate == true

	Wrapper:_Stop(IsHardStop)

	if Wrapper.Config.Group then
		local GroupName = Wrapper.Config.Group

		if IsHardStop then
			self.GroupManager:OnActiveCompleted(GroupName)
		else
			if Wrapper.Config.Looped then
				Wrapper.CompletedSignal:Once(function()
					self.GroupManager:OnActiveCompleted(GroupName)
				end)
			end
		end
	end

	
	local IsOwningClient = not IS_SERVER and self._Replication._IsOwningClient
	if IsOwningClient then
		self._Replication:QueueIntent(AnimationName, "STOP")
	end
end

function AnimationController:StopGroup(GroupName: string, Immediate: boolean?)
	local Registry = AnimationRegistry.GetInstance()

	for QueueIndex = #self.PendingQueue, 1, -1 do
		local QueuedConfig = Registry:GetByName(self.PendingQueue[QueueIndex].ConfigName)
		if QueuedConfig and QueuedConfig.Group == GroupName then
			table.remove(self.PendingQueue, QueueIndex)
		end
	end

	local AnimationsToStop: { string } = {}
	for AnimationName, Wrapper in self.ActiveWrappers do
		if Wrapper.Config.Group == GroupName then
			table.insert(AnimationsToStop, AnimationName)
		end
	end

	for _, AnimationName in AnimationsToStop do
		self:Stop(AnimationName, Immediate)
	end
end

-- ─── Pending Queue Flush ──────────────────────────────────────────────────────

function AnimationController:_FlushPendingQueue()
	if #self.PendingQueue == 0 then return end

	local QueueSnapshot = self.PendingQueue
	self.PendingQueue = {}

	for _, Request in QueueSnapshot do
		self:_ExecutePlayRequest(Request.ConfigName)
	end
end

-- ─── Core Play Execution ──────────────────────────────────────────────────────

function AnimationController:_ExecutePlayRequest(ConfigName: string)
	local Registry = AnimationRegistry.GetInstance()
	local Config   = Registry:GetByName(ConfigName)

	if not Config then
		warn(string.format("[AnimationController] Unknown animation '%s'", ConfigName))
		return
	end

	local LayerRecord = self.LayerManager:GetLayer(Config.Layer)
	if not LayerRecord then
		warn(string.format(
			"[AnimationController] Animation '%s' references unknown layer '%s'",
			ConfigName,
			Config.Layer
			))
		return
	end

	local ExistingWrapper = self.ActiveWrappers[ConfigName]
	if ExistingWrapper and ExistingWrapper.IsPlaying then return end

	if ExistingWrapper then
		self:_RetireWrapper(ConfigName)
		ExistingWrapper = nil
	end

	-- ── Grouped animation path ─────────────────────────────────────────────
	if Config.Group then
		self.GroupManager:EnsureGroup(Config.Group)

		local IncomingWrapper = self:_AcquireWrapper(Config)
		local GroupResult = self.GroupManager:EvaluatePlayRequest(Config.Group, IncomingWrapper)

		if GroupResult.Verdict == "REJECT" then
			IncomingWrapper:_Destroy()
			return

		elseif GroupResult.Verdict == "DEFER" then
			if GroupResult.PendingEvicted then
				self:_PoolOrDestroyWrapper(GroupResult.PendingEvicted)
			end
			return

		elseif GroupResult.Verdict == "ALLOW" then
			if GroupResult.WrapperToStop then
				GroupResult.WrapperToStop:_Stop(false)
			end
			if GroupResult.PendingEvicted then
				self:_PoolOrDestroyWrapper(GroupResult.PendingEvicted)
			end
			self:_ActivateWrapper(IncomingWrapper, Config, LayerRecord)
			return
		end
	end

	-- ── Non-grouped animation path ─────────────────────────────────────────
	local LayerIncumbents: { any } = {}
	local StrongestIncumbent: any  = nil

	for _, Wrapper in self.ActiveWrappers do
		local IsOnSameLayer = Wrapper.Config.Layer == Config.Layer
		local IsNonGrouped  = Wrapper.Config.Group == nil

		if IsOnSameLayer and IsNonGrouped then
			table.insert(LayerIncumbents, Wrapper)

			local IsStrongerThanCurrent = StrongestIncumbent == nil
				or Wrapper.Config.Priority > StrongestIncumbent.Config.Priority

			if IsStrongerThanCurrent then
				StrongestIncumbent = Wrapper
			end
		end
	end

	local ConflictVerdict: Types.ConflictVerdict

	if StrongestIncumbent then
		local IncumbentLayer = self.LayerManager:GetLayer(StrongestIncumbent.Config.Layer)

		ConflictVerdict = ConflictResolver.ResolveNoGroup(
			Config,
			LayerRecord.Order,
			StrongestIncumbent.Config,
			IncumbentLayer and IncumbentLayer.Order or 0,
			StrongestIncumbent.StartTimestamp
		)
	else
		ConflictVerdict = "ALLOW"
	end

	if ConflictVerdict == "ALLOW" then
		for _, IncumbentWrapper in LayerIncumbents do
			self:Stop(IncumbentWrapper.Config.Name, false)
		end

		local newWrapper = self:_AcquireWrapper(Config)
		self:_ActivateWrapper(newWrapper, Config, LayerRecord)
	end
end

-- ─── Pool-or-Destroy Helper ───────────────────────────────────────────────────

function AnimationController:_PoolOrDestroyWrapper(EvictedWrapper: any)
	local ConfigName = EvictedWrapper.Config.Name

	if not self._WrapperPool[ConfigName] then
		self._WrapperPool[ConfigName] = {}
	end

	local Pool = self._WrapperPool[ConfigName]
	local IsPoolBelowCapacity = #Pool < MAX_POOL_SIZE_PER_CONFIG
	local IsWrapperSafeToPool = EvictedWrapper:_IsPoolReady()

	if IsPoolBelowCapacity and IsWrapperSafeToPool then
		EvictedWrapper.CompletedSignal:DisconnectAll()
		table.insert(Pool, EvictedWrapper)
	else
		EvictedWrapper:_Destroy()
	end
end

-- ─── Wrapper Activation ───────────────────────────────────────────────────────

function AnimationController:_ActivateWrapper(Wrapper: any, Config: AnimationConfig, LayerRecord: any)
	self.ActiveWrappers[Config.Name] = Wrapper
	self.LayerManager:RegisterTrack(Config.Layer, Wrapper)

	if not Config.Looped and Config.Group then
		local CapturedWrapper = Wrapper
		local CapturedGroup   = Config.Group :: string

		Wrapper.CompletedSignal:Connect(function()
		
			local IsStillActiveInGroup = self.GroupManager:GetActiveWrapper(CapturedGroup) == CapturedWrapper

			if IsStillActiveInGroup then
				self.GroupManager:OnActiveCompleted(CapturedGroup)
			end
		end)
	end

	Wrapper:_Play()


	local IsOwningClient = not IS_SERVER and self._Replication._IsOwningClient
	if IsOwningClient then
		self._Replication:QueueIntent(Config.Name, "PLAY")
	end
end

-- ─── Pending Ready Callback ───────────────────────────────────────────────────

function AnimationController:_OnPendingReady(GroupName: string, PendingWrapper: any)
	if self.IsDestroyed then
		PendingWrapper:_Destroy()
		self.GroupManager:ClearActive(GroupName)
		return
	end

	
	local CurrentPending = self.GroupManager:GetPendingWrapper(GroupName)

	if not CurrentPending then
		PendingWrapper:_Destroy()
		return
	end

	if CurrentPending ~= PendingWrapper then
		-- A newer request displaced this wrapper while the timer was in-flight.
		PendingWrapper:_Destroy()
		return
	end

	local Config      = PendingWrapper.Config
	local LayerRecord = self.LayerManager:GetLayer(Config.Layer)

	if not LayerRecord then
		PendingWrapper:_Destroy()
		self.GroupManager:ClearActive(GroupName)
		return
	end

	-- Bug #1 fix: clear PendingWrapper BEFORE calling EvaluatePlayRequest so the
	-- evaluation does not see the incoming wrapper as its own eviction target.
	self.GroupManager:ClearPending(GroupName)

	local PromotionResult = self.GroupManager:EvaluatePlayRequest(GroupName, PendingWrapper)

	if PromotionResult.Verdict == "ALLOW" then
		if PromotionResult.WrapperToStop then
			PromotionResult.WrapperToStop:_Stop(false)
		end
		if PromotionResult.PendingEvicted then
			PromotionResult.PendingEvicted:_Destroy()
		end
		self:_ActivateWrapper(PendingWrapper, Config, LayerRecord)

	elseif PromotionResult.Verdict == "DEFER" then
		-- Re-deferred: EvaluatePlayRequest has re-stored the wrapper and scheduled
		-- a new timer. Nothing to do here.
		return

	else
		-- REJECT: wrapper cannot be promoted.
		PendingWrapper:_Destroy()
		self.GroupManager:ClearActive(GroupName)
	end
end

-- ─── State Machine Callback ───────────────────────────────────────────────────

function AnimationController:_OnStateChange(ExitingState: StateDefinition, EnteringState: StateDefinition)
	for _, Directive in ExitingState.ExitActions do
		self:_DispatchDirective(Directive)
	end

	local EnteringActiveLayers:   { [string]: boolean } = {}
	local EnteringSuppressLayers: { [string]: boolean } = {}
	local ExitingActiveLayers:    { [string]: boolean } = {}
	local ExitingSuppressLayers:  { [string]: boolean } = {}

	for _, LayerName in EnteringState.ActiveLayers   do EnteringActiveLayers[LayerName]   = true end
	for _, LayerName in EnteringState.SuppressLayers do EnteringSuppressLayers[LayerName] = true end
	for _, LayerName in ExitingState.ActiveLayers    do ExitingActiveLayers[LayerName]    = true end
	for _, LayerName in ExitingState.SuppressLayers  do ExitingSuppressLayers[LayerName]  = true end

	for LayerName in EnteringActiveLayers do
		if not ExitingActiveLayers[LayerName] then
			self.LayerManager:SetLayerToBase(LayerName)
		end
	end

	for LayerName in EnteringSuppressLayers do
		if not ExitingSuppressLayers[LayerName] then
			self.LayerManager:SuppressLayer(LayerName)
		end
	end

	for LayerName in ExitingSuppressLayers do
		local IsStillSuppressed     = EnteringSuppressLayers[LayerName]
		local IsNowExplicitlyActive = EnteringActiveLayers[LayerName]

		if not IsStillSuppressed and not IsNowExplicitlyActive then
			self.LayerManager:SetLayerToBase(LayerName)
		end
	end

	for LayerName in ExitingActiveLayers do
		local IsStillActive   = EnteringActiveLayers[LayerName]
		local IsNowSuppressed = EnteringSuppressLayers[LayerName]

		if not IsStillActive and not IsNowSuppressed then
			self.LayerManager:SetLayerToBase(LayerName)
		end
	end

	for _, Directive in EnteringState.EntryActions do
		self:_DispatchDirective(Directive)
	end
end

-- ─── Directive Dispatch ───────────────────────────────────────────────────────

function AnimationController:_DispatchDirective(Directive: AnimationDirective)
	if Directive.Action == "PLAY" then
		self:Play(Directive.Target)
	elseif Directive.Action == "STOP" then
		self:Stop(Directive.Target, Directive.Immediate)
	elseif Directive.Action == "STOP_GROUP" then
		self:StopGroup(Directive.Target, Directive.Immediate)
	end
end

-- ─── Replication: Intent Receiver ────────────────────────────────────────────

function AnimationController:_OnIntentReceived(ReceivedIntent: Types.AnimationIntent)
	if ReceivedIntent.Action == "PLAY" then
		self:Play(ReceivedIntent.AnimationName)
	elseif ReceivedIntent.Action == "STOP" then
		self:Stop(ReceivedIntent.AnimationName, false)
	end
end

-- ─── Replication: Snapshot Reconciliation ────────────────────────────────────

function AnimationController:_OnSnapshotMismatch(MismatchedSnapshot: any)
	if self.IsDestroyed then return end

	for _, Wrapper in self.ActiveWrappers do
		self.LayerManager:UnregisterTrack(Wrapper.Config.Layer, Wrapper)
		Wrapper:_Stop(true)
		Wrapper:_Destroy()
	end
	table.clear(self.ActiveWrappers)

	table.clear(self.PendingQueue)

	self.GroupManager:Destroy()
	self.GroupManager = ExclusiveGroupManager.new(
		function(GroupName: string, PendingWrapper: any)
			self:_OnPendingReady(GroupName, PendingWrapper)
		end,
		function(DiscardedWrapper: any)
			local ConfigName = DiscardedWrapper.Config.Name
			if not self._WrapperPool[ConfigName] then
				self._WrapperPool[ConfigName] = {}
			end
			local Pool = self._WrapperPool[ConfigName]
			local IsPoolBelowCapacity = #Pool < MAX_POOL_SIZE_PER_CONFIG
			local IsWrapperSafeToPool = DiscardedWrapper:_IsPoolReady()

			if IsPoolBelowCapacity and IsWrapperSafeToPool then
				DiscardedWrapper.CompletedSignal:DisconnectAll()
				table.insert(Pool, DiscardedWrapper)
			else
				DiscardedWrapper:_Destroy()
			end
		end
	)

	local ServerStateName = MismatchedSnapshot.StateName
	local IsFsmStateWrong = ServerStateName
		and ServerStateName ~= self.StateMachine:GetCurrentStateName()

	if IsFsmStateWrong then
		self.StateMachine:RequestTransition(ServerStateName, math.huge)
	end

	if MismatchedSnapshot.ActiveGroupAnims then
		for _, AnimationName in MismatchedSnapshot.ActiveGroupAnims do
			self:Play(AnimationName)
		end
	end
end

-- ─── Public State Machine Interface ──────────────────────────────────────────

function AnimationController:RequestStateTransition(StateName: string, Priority: number)
	self.StateMachine:RequestTransition(StateName, Priority or 0)
end

-- ─── Active Group Animation Map ───────────────────────────────────────────────

function AnimationController:_BuildActiveGroupAnimMap(): { [string]: string }
	local GroupAnimMap: { [string]: string } = {}

	for _, Wrapper in self.ActiveWrappers do
		local IsGroupedAndFullyPlaying = Wrapper.Config.Group
			and Wrapper.IsPlaying
			and not Wrapper.IsFading

		if IsGroupedAndFullyPlaying then
			local GroupName = Wrapper.Config.Group :: string

			if GroupAnimMap[GroupName] then
				warn(string.format(
					"[AnimationController] Group invariant violated: both '%s' and '%s' are active in group '%s'",
					GroupAnimMap[GroupName],
					Wrapper.Config.Name,
					GroupName
					))
			end

			GroupAnimMap[GroupName] = Wrapper.Config.Name
		end
	end

	return GroupAnimMap
end

-- ─── Debug Inspector ──────────────────────────────────────────────────────────

function AnimationController:AttachInspector(): any
	local DebugInspector = require(script.DebugInspector)
	return DebugInspector.new(self)
end

-- ─── Destruction ──────────────────────────────────────────────────────────────

function AnimationController:Destroy()
	if self.IsDestroyed then return end
	self.IsDestroyed = true

	if self._FrameConn then
		self._FrameConn:Disconnect()
		self._FrameConn = nil
	end

	for _, Wrapper in self.ActiveWrappers do
		Wrapper:_Stop(true)
		Wrapper:_Destroy()
	end
	table.clear(self.ActiveWrappers)

	for _, Pool in self._WrapperPool do
		for _, PooledWrapper in Pool do
			PooledWrapper:_Stop(true)
			PooledWrapper:_Destroy()
		end
	end
	table.clear(self._WrapperPool)

	self.GroupManager:Destroy()
	self._Replication:Destroy()

	table.clear(self.PendingQueue)
end

return AnimationController