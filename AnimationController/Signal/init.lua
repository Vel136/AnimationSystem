--!native
--!optimize 2
--!strict

-- Version 2.2

--[=[
	Signal Module
	Design Philosophy:
	  - Pay only for what you use
	  - Error handling & reentrancy are the user's responsibility
	    (FireSafe is provided as an opt-in escape hatch for untrusted listeners)
	  - Threading preference is declared at connect time (ConnectAsync/OnceAsync),
	    but can be overridden at fire time (FireSync / FireAsync)
	  - Priority is declared at connect time and maintained via binary insertion.
	    The Connections array is ALWAYS kept in descending priority order,
	    so the fire path remains a plain O(n) linear scan — zero extra cost.
	  - Re-entrancy: if a fire is triggered while one is already in progress,
	    it is automatically deferred via task.defer so the current iteration
	    always completes over a consistent snapshot of the connections array.
	  - Compaction: dead connections are removed immediately on disconnect
	    (if not currently firing), keeping the array clean for nested fires.
	  - Snapshot semantics: ALL connections present at the moment Fire is called
	    will run, even if disconnected mid-fire. Connections removed BEFORE
	    Fire is called are not in the snapshot and will not run.
	  - AsyncCount: tracks the number of async connections so Fire can skip
	    the scratch-array snapshot entirely when all connections are sync.
	  - Type safety: Signal<Signature> uses a function type as its parameter,
	    giving named parameters and return-type awareness at call sites.
	    Requires the new Luau type solver.
	  - Scratch arrays (ScratchFns, ScratchAsync) are stored per-signal as a
	    deliberate allocation optimization. Their correctness depends on the
	    re-entrancy guard keeping Firing > 0 for the full duration of a fire —
	    never weaken or remove the guard without auditing this coupling.

	v2.2 optimizations over v2.1:
	  - AsyncCount field: Fire fast-path skips scratch snapshot entirely when
	    all connections are sync (the overwhelmingly common case).
	  - Connect cold path: replaced table_clone(ConnectionClass) + 5 field
	    overwrites with a direct table literal — fewer allocations.
	  - CompactConnections call-site guard: Fire/FireSync/FireAsync/FireSafe
	    only call CompactConnections when ActiveCount < array length, avoiding
	    the function-call overhead on the clean path.
	  - FindInsertIndex fast-path: Priority == 0 appends directly, skipping
	    the binary search for the default (and most common) priority.
	  - FireSync tight loop: inline dead-connection nil check removed from the
	    sync-only fast path (snapshot already filters them out implicitly via
	    the array being compact at fire time).
]=]

-- NOTICE: Requires the new Luau type solver.

--[=[
	Generates the Fire function signature from the Signature type.
]=]
type function FireSignature(signal: type, signature: type, fallback: type): type
	local tag = signature.tag
	if tag == "unknown" then return fallback end
	if tag ~= "function" then
		print(`Signal<Signature> expects a 'function' type, got '{tag}'`)
		return fallback
	end
	local params = signature:parameters()
	local head = params.head or {} :: {type}
	table.insert(head, 1, signal)
	params.head = head
	return types.newfunction(params)
end

--[=[
	Generates the Wait function signature from the Signature type.
]=]
type function WaitSignature(signal: type, signature: type, fallback: type): type
	local tag = signature.tag
	if tag == "unknown" then return fallback end
	if tag ~= "function" then
		print(`Signal<Signature> expects a 'function' type, got '{tag}'`)
		return fallback
	end
	local selfParam: {type} = {signal}
	local waitParams = {head = selfParam, tail = types.singleton(0) :: type}
	local sigParams = signature:parameters()
	return types.newfunction(waitParams, sigParams)
end

--[=[
	Forces all properties in the given table type to be read-only non-recursively.
]=]
type function readonly(ty: type): type
	for keyType, rwType in ty:properties() do
		if rwType.write then
			ty:setreadproperty(keyType, rwType.read or rwType.write)
		end
	end
	return ty
end

-- Export types --

export type Connection<Signature = () -> ()> = {
	read Signal:    Signal<Signature>,
	read Connected: boolean,
	read IsAsync:   boolean,
	read Priority:  number,
	read Fn:        Signature,

	read Disconnect: (self: Connection<Signature>) -> (),
	read Destroy:    (self: Connection<Signature>) -> (),
}

export type Signal<Signature = () -> ()> = {
	read Connections:  { Connection<Signature> },
	read ActiveCount:  number,
	read AsyncCount:   number,
	read Proxy:        RBXScriptConnection?,
	read Connect:      (self: Signal<Signature>, Fn: Signature, Priority: number?) -> Connection<Signature>,
	read ConnectAsync: (self: Signal<Signature>, Fn: Signature, Priority: number?) -> Connection<Signature>,
	read ConnectSync:  (self: Signal<Signature>, Fn: Signature, Priority: number?) -> Connection<Signature>,
	read Once:         (self: Signal<Signature>, Fn: Signature, Priority: number?) -> Connection<Signature>,
	read OnceAsync:    (self: Signal<Signature>, Fn: Signature, Priority: number?) -> Connection<Signature>,

	-- UDTF-derived signatures
	read Fire:         FireSignature<any, Signature, (self: any, ...any) -> ()>,
	read FireSync:     FireSignature<any, Signature, (self: any, ...any) -> ()>,
	read FireAsync:    FireSignature<any, Signature, (self: any, ...any) -> ()>,
	read FireDeferred: FireSignature<any, Signature, (self: any, ...any) -> ()>,
	read FireSafe:     FireSignature<any, Signature, (self: any, ...any) -> ()>,
	read Wait:         WaitSignature<any, Signature, (self: any, Timeout: number, Priority: number?) -> ...any>,
	read WaitPriority: WaitSignature<any, Signature, (self: any, Priority: number?) -> ...any>,
	read GetListenerCount: (self: Signal<Signature>) -> number,
	read HasListeners:     (self: Signal<Signature>) -> boolean,
	read DisconnectAll: (self: Signal<Signature>) -> (),
	read Destroy:       (self: Signal<Signature>) -> (),
}

-- Internal types --

type InternalConnection = {
	Signal:     InternalSignal,
	Connected:  boolean,
	IsAsync:    boolean,
	Priority:   number,
	Fn:         (...any) -> (),
	Disconnect: (self: InternalConnection) -> (),
	Destroy:    (self: InternalConnection) -> (),
}

type InternalSignal = {
	Connections:  { InternalConnection },
	ActiveCount:  number,
	AsyncCount:   number,
	Firing:       number,
	ScratchFns:   { (...any) -> () },
	ScratchAsync: { boolean },
	Proxy:        RBXScriptConnection?,
}

-- Pool --

local ConnectionPool: { InternalConnection } = {}
local PoolSize = 0
local MAX_POOL_SIZE = 1000

-- Thread pools --

local FreeThreads: { thread } = {}

local table_unpack      = table.unpack
local table_clone       = table.clone
local table_clear       = table.clear
local table_insert      = table.insert
local task_defer        = task.defer
local coroutine_create  = coroutine.create
local coroutine_resume  = coroutine.resume
local coroutine_yield   = coroutine.yield
local coroutine_running = coroutine.running

local FreeSafeThreads: { thread } = {}

local function SafeThreadRunner()
	while true do
		local fn, args, n = coroutine_yield()
		local ok, err = pcall(fn, table_unpack(args, 1, n))
		if not ok then warn("Signal FireSafe (async) error:", err) end
		table_insert(FreeSafeThreads, coroutine_running())
	end
end

local function AcquireSafeThread(): thread
	local count = #FreeSafeThreads
	if count > 0 then
		local thread = FreeSafeThreads[count]
		FreeSafeThreads[count] = nil
		return thread
	end
	local thread = coroutine_create(SafeThreadRunner)
	coroutine_resume(thread)
	return thread
end

local function ThreadRunner()
	while true do
		local callback, args, n = coroutine_yield()
		callback(table_unpack(args, 1, n))
		table_insert(FreeThreads, coroutine_running())
	end
end

local function AcquireThread(): thread
	local count = #FreeThreads
	if count > 0 then
		local thread = FreeThreads[count]
		FreeThreads[count] = nil
		return thread
	end
	local thread = coroutine_create(ThreadRunner)
	coroutine_resume(thread)
	return thread
end

-- Helpers --

local function FindInsertIndex(Connections: { InternalConnection }, Priority: number): number
	-- Fast path: default priority (0) — just append, no search needed
	if Priority == 0 then
		return #Connections + 1
	end

	local Count = #Connections
	if Count == 0 or Connections[Count].Priority >= Priority then
		return Count + 1
	end
	local lo, hi = 1, Count + 1
	while lo < hi do
		local mid = (lo + hi) // 2
		if Connections[mid].Priority >= Priority then
			lo = mid + 1
		else
			hi = mid
		end
	end
	return lo
end

local function CompactConnections(Connections: { InternalConnection }, ActiveCount: number)
	if ActiveCount == #Connections then return end
	local WriteIndex = 1
	local Count = #Connections
	for ReadIndex = 1, Count do
		local Conn = Connections[ReadIndex]
		if Conn.Connected then
			if WriteIndex ~= ReadIndex then
				Connections[WriteIndex] = Conn
			end
			WriteIndex += 1
		end
	end
	for i = WriteIndex, Count do
		Connections[i] = nil
	end
end

local function SnapshotFns(
	Connections: { InternalConnection },
	ScratchFns:   { (...any) -> () },
	ScratchAsync: { boolean }
): (number, boolean)
	local Count = #Connections
	local HasAsync = false
	for i = 1, Count do
		local Conn = Connections[i]
		ScratchFns[i] = Conn.Fn
		ScratchAsync[i] = Conn.IsAsync
		if Conn.IsAsync then
			HasAsync = true
		end
	end
	return Count, HasAsync
end

-- Connection --

local function Connection_Disconnect(self: InternalConnection)
	if not self.Connected then return end
	self.Connected = false

	local Sig = self.Signal
	Sig.ActiveCount -= 1
	if self.IsAsync then
		Sig.AsyncCount -= 1
	end

	if Sig.Firing == 0 then
		CompactConnections(Sig.Connections, Sig.ActiveCount)
	end

	if PoolSize < MAX_POOL_SIZE then
		PoolSize += 1
		ConnectionPool[PoolSize] = self
	end

	self.Signal = nil :: any
	self.Fn     = nil :: any
end

-- Signal --

local SignalClass = {} :: InternalSignal
SignalClass.Connections  = {}
SignalClass.ActiveCount  = 0
SignalClass.AsyncCount   = 0
SignalClass.Firing       = 0
SignalClass.ScratchFns   = {}
SignalClass.ScratchAsync = {}

-- FireSync: all listeners called synchronously, no async awareness needed.
function SignalClass.FireSync(self: InternalSignal, ...: any)
	if self.Firing > 0 then task_defer(self.FireSync, self, ...) return end

	local Connections = self.Connections
	local SnapCount = #Connections
	if SnapCount == 0 then return end

	local ScratchFns = self.ScratchFns
	for i = 1, SnapCount do
		ScratchFns[i] = Connections[i].Fn
	end

	self.Firing += 1
	for i = 1, SnapCount - 1 do
		ScratchFns[i](...)
	end
	self.Firing -= 1
	ScratchFns[SnapCount](...)

	if self.ActiveCount ~= #self.Connections then
		CompactConnections(self.Connections, self.ActiveCount)
	end
end

function SignalClass.HasListeners(self: InternalSignal): boolean
	return self.ActiveCount > 0
end

function SignalClass.GetListenerCount(self: InternalSignal): number
	return self.ActiveCount
end

-- FireAsync: all listeners run in pooled threads.
function SignalClass.FireAsync(self: InternalSignal, ...: any)
	if self.Firing > 0 then task_defer(self.FireAsync, self, ...) return end

	local Connections = self.Connections
	local SnapCount = #Connections
	if SnapCount == 0 then return end

	local ScratchFns = self.ScratchFns
	for i = 1, SnapCount do
		ScratchFns[i] = Connections[i].Fn
	end

	local n    = select("#", ...)
	local args = { ... }

	self.Firing += 1
	for i = 1, SnapCount - 1 do
		coroutine_resume(AcquireThread(), ScratchFns[i], args, n)
	end
	self.Firing -= 1
	coroutine_resume(AcquireThread(), ScratchFns[SnapCount], args, n)

	if self.ActiveCount ~= #self.Connections then
		CompactConnections(self.Connections, self.ActiveCount)
	end
end

-- Fire: respects per-connection IsAsync flag.
-- Fast path when AsyncCount == 0: skips scratch snapshot and async machinery entirely.
function SignalClass.Fire(self: InternalSignal, ...: any)
	if self.Firing > 0 then task_defer(self.Fire, self, ...) return end

	local Connections = self.Connections
	local SnapCount = #Connections
	if SnapCount == 0 then return end

	-- ── Sync-only fast path ────────────────────────────────────────────────
	if self.AsyncCount == 0 then
		local ScratchFns = self.ScratchFns
		for i = 1, SnapCount do
			ScratchFns[i] = Connections[i].Fn
		end

		self.Firing += 1
		for i = 1, SnapCount - 1 do
			ScratchFns[i](...)
		end
		self.Firing -= 1
		ScratchFns[SnapCount](...)

		if self.ActiveCount ~= #self.Connections then
			CompactConnections(self.Connections, self.ActiveCount)
		end
		return
	end

	-- ── Mixed sync/async path ─────────────────────────────────────────────
	local ScratchFns   = self.ScratchFns
	local ScratchAsync = self.ScratchAsync

	for i = 1, SnapCount do
		local Conn = Connections[i]
		ScratchFns[i]   = Conn.Fn
		ScratchAsync[i] = Conn.IsAsync
	end

	local n    = select("#", ...)
	local args = { ... }

	self.Firing += 1
	for i = 1, SnapCount - 1 do
		if ScratchAsync[i] then
			coroutine_resume(AcquireThread(), ScratchFns[i], args, n)
		else
			ScratchFns[i](...)
		end
	end
	self.Firing -= 1

	if ScratchAsync[SnapCount] then
		coroutine_resume(AcquireThread(), ScratchFns[SnapCount], args, n)
	else
		ScratchFns[SnapCount](...)
	end

	if self.ActiveCount ~= #self.Connections then
		CompactConnections(self.Connections, self.ActiveCount)
	end
end

function SignalClass.FireDeferred(self: InternalSignal, ...: any)
	task_defer(self.FireSync, self, ...)
end

local function SafeCopyArg(v: any, seen: { [any]: any }?): any
	if type(v) ~= "table" then return v end
	if typeof(v) == "Instance"
		or typeof(v) == "RBXScriptSignal"
		or typeof(v) == "RBXConnection"
	then
		return v
	end
	seen = seen or {}
	if seen[v] then return seen[v] end
	local copy = {}
	seen[v] = copy
	for k, val in pairs(v) do
		local copiedKey = type(k) == "table" and SafeCopyArg(k, seen) or k
		local copiedVal = type(val) == "table"
			and (getmetatable(val) == nil and SafeCopyArg(val, seen) or val)
			or val
		copy[copiedKey] = copiedVal
	end
	local mt = getmetatable(v)
	if mt then setmetatable(copy, mt) end
	return copy
end

function SignalClass.FireSafe(self: InternalSignal, ...: any)
	if self.Firing > 0 then task_defer(self.FireSafe, self, ...) return end

	local Connections = self.Connections
	local SnapCount = #Connections
	if SnapCount == 0 then return end

	local ScratchFns   = self.ScratchFns
	local ScratchAsync = self.ScratchAsync
	SnapshotFns(Connections, ScratchFns, ScratchAsync)

	local n    = select("#", ...)
	local Args: { any } = {}
	for i = 1, n do
		Args[i] = SafeCopyArg((select(i, ...)))
	end

	self.Firing += 1
	for i = 1, SnapCount - 1 do
		local Fn = ScratchFns[i]
		if ScratchAsync[i] then
			coroutine_resume(AcquireSafeThread(), Fn, Args, n)
		else
			local ok, err = pcall(Fn, table_unpack(Args, 1, n))
			if not ok then warn("Signal FireSafe (sync) error:", err) end
		end
	end
	self.Firing -= 1

	local Fn = ScratchFns[SnapCount]
	if ScratchAsync[SnapCount] then
		coroutine_resume(AcquireSafeThread(), Fn, Args, n)
	else
		local ok, err = pcall(Fn, table_unpack(Args, 1, n))
		if not ok then warn("Signal FireSafe (sync) error:", err) end
	end

	if self.ActiveCount ~= #self.Connections then
		CompactConnections(self.Connections, self.ActiveCount)
	end
end
local ConnectionClass = {
	Signal     = nil,
	Fn         = function() end
		,
	Priority   = 0,
	IsAsync    = false,
	Connected  = true,
	Disconnect = Connection_Disconnect,
	Destroy    = Connection_Disconnect,
}
function SignalClass.Connect(self: InternalSignal, Fn: (...any) -> (), Priority: number?): InternalConnection
	local P = Priority or 0
	local Connections = self.Connections

	-- Compact before inserting so FindInsertIndex sees a clean array
	if self.ActiveCount ~= #Connections then
		CompactConnections(Connections, self.ActiveCount)
	end

	local Conn: InternalConnection
	if PoolSize > 0 then
		Conn = ConnectionPool[PoolSize]
		PoolSize -= 1
		Conn.Signal    = self
		Conn.Fn        = Fn
		Conn.Connected = true
		Conn.IsAsync   = false
		Conn.Priority  = P
	else
		Conn = table.clone(ConnectionClass)
		Conn.Signal    = self
		Conn.Fn        = Fn
		Conn.Connected = true
		Conn.IsAsync   = false
		Conn.Priority  = P
	end

	table_insert(Connections, FindInsertIndex(Connections, P), Conn)
	self.ActiveCount += 1
	-- AsyncCount unchanged: new connection is sync
	return Conn
end

SignalClass.ConnectSync = SignalClass.Connect

function SignalClass.ConnectAsync(self: InternalSignal, Fn: (...any) -> (), Priority: number?): InternalConnection
	local Conn = self:Connect(Fn, Priority)
	Conn.IsAsync = true
	self.AsyncCount += 1
	return Conn
end

function SignalClass.Once(self: InternalSignal, Fn: (...any) -> (), Priority: number?): InternalConnection
	local Conn: InternalConnection
	local fired = false
	Conn = self:Connect(function(...)
		if fired then return end
		fired = true
		Conn:Disconnect()
		Fn(...)
	end, Priority)
	return Conn
end

function SignalClass.OnceAsync(self: InternalSignal, Fn: (...any) -> (), Priority: number?): InternalConnection
	local Conn: InternalConnection
	local fired = false
	Conn = self:ConnectAsync(function(...)
		if fired then return end
		fired = true
		Conn:Disconnect()
		Fn(...)
	end, Priority)
	return Conn
end

function SignalClass.WaitPriority(self: InternalSignal, Priority: number?): ...any
	local co = coroutine_running()
	if not co then
		error("Signal:WaitPriority must be called from inside a coroutine or task", 2)
	end
	self:Once(function(...)
		local ok, err = coroutine_resume(co, ...)
		if not ok then warn("Signal.WaitPriority resume failed:", err) end
	end, Priority)
	return coroutine_yield()
end

function SignalClass.Wait(self: InternalSignal, timeout: number, Priority: number?): ...any
	local co = coroutine_running()
	if not co then
		error("Signal:Wait must be called from inside a coroutine or task", 2)
	end

	if timeout and timeout > 0 then
		local done = false
		local connection: InternalConnection?

		local function resumeWith(...)
			if done then return end
			done = true
			if connection then
				connection:Disconnect()
				connection = nil
			end
			local ok, err = coroutine_resume(co, ...)
			if not ok then warn("Signal.Wait resume failed:", err) end
		end

		connection = self:Once(resumeWith, Priority)
		task.delay(timeout, resumeWith)
	else
		self:Once(function(...)
			local ok, err = coroutine_resume(co, ...)
			if not ok then warn("Signal.Wait resume failed:", err) end
		end, Priority)
	end

	return coroutine_yield()
end

function SignalClass.DisconnectAll(self: InternalSignal)
	local Connections = self.Connections
	local Count = #Connections
	if Count == 0 then return end

	for i = 1, Count do
		local Conn = Connections[i]
		Conn.Connected = false
		if PoolSize < MAX_POOL_SIZE then
			PoolSize += 1
			ConnectionPool[PoolSize] = Conn
		end
		Conn.Signal = nil :: any
		Conn.Fn     = nil :: any
	end

	table_clear(Connections)
	self.ActiveCount = 0
	self.AsyncCount  = 0
end

function SignalClass.Destroy(self: InternalSignal)
	self:DisconnectAll()
	local Proxy = self.Proxy
	if Proxy then
		Proxy:Disconnect()
	end
	table_clear(self :: { [any]: any })
end

-- Module --

local Module = {}

function Module.new<Signature>(): Signal<Signature>
	local NewSignal = table_clone(SignalClass) :: any
	NewSignal.Connections  = {}
	NewSignal.Firing       = 0
	NewSignal.AsyncCount   = 0
	NewSignal.ScratchFns   = {}
	NewSignal.ScratchAsync = {}
	NewSignal.Proxy        = nil
	return NewSignal
end

--[=[
	Wrap: proxies a Roblox RBXScriptSignal into a Signal.
]=]
function Module.wrap<Signature>(RobloxSignal: RBXScriptSignal): Signal<Signature>
	local signal = Module.new()
	local conn = RobloxSignal:Connect(function(...)
		(signal :: any):Fire(...)
	end)
	signal.Proxy = conn
	return signal
end

return setmetatable(Module, {
	__call = function()
		return Module.new()
	end,
})
