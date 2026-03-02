--[[
Signal (v2.1)
A high-performance, type-safe, and thread-safe Signal implementation for Roblox Luau.

This module is designed for production-grade games where performance, memory management, and type safety are critical. It utilizes Luau's latest features—including User Defined Type Functions (UDTFs) and --!native optimization—to provide the fastest possible signal implementation with full IDE autocomplete support.

===================================================================================================
                                    Features
===================================================================================================

Perfect Type Safety: Leverages Luau Type Functions to provide full autocomplete and type checking for :Fire() arguments and :Wait() returns. No more ...any.
Extreme Performance: Uses connection pooling, scratch arrays, and thread recycling to minimize Garbage Collection pressure and maximize execution speed.
Priority System: Connections are sorted by priority using binary insertion. Higher priority listeners always execute first.
Snapshot Semantics: Iterates over a snapshot of connections. If a listener disconnects during a fire, it still executes (preventing state desync), but is cleaned up immediately after.
Atomic Safety: The Once method uses a local boolean guard, ensuring atomic execution even during race conditions or asynchronous disconnects.
Flexible Threading: Choose between synchronous (immediate), asynchronous (deferred), or "safe" (error-handled) execution at both connect-time and fire-time.

===================================================================================================
                                    API Usage
===================================================================================================

local Signal = require(path.to.Signal)

-- Define the signature using a function type
local mySignal = Signal.new<(player: Player, damage: number) -> ()>()

-- Connect a listener
local connection = mySignal:Connect(function(player, damage)
    print(`${player.Name} took {damage} damage!`)
end)

-- Fire the signal (Arguments are fully typed!)
mySignal:Fire(game.Players:GetPlayers()[1], 10)

-- Disconnect
connection:Disconnect()
=========================================================
Priority
Listeners are executed in descending order of priority. Priority defaults to 0.

mySignal:Connect(function() print("Second") end, 0)
mySignal:Connect(function() print("First") end, 10) -- Higher priority runs first
mySignal:Fire()
-- Output:
--   First
--   Second
Async vs Sync
You can control threading behavior at connect time:

=========================================================
-- Runs immediately on the same thread (Fastest)
mySignal:ConnectSync(fn) 

-- Runs via task.defer (Async)
mySignal:ConnectAsync(fn) 
Or override it at fire time:

lua

-- Runs all listeners immediately
mySignal:FireSync(...) 

-- Runs all listeners asynchronously (via thread pool)
mySignal:FireAsync(...) 

-- Respects the Connect time preference (Mix of both)
mySignal:Fire(...) 
Error Handling (FireSafe)
By default, errors in listeners will crash the thread (standard Lua behavior). If you are running untrusted or unstable code, use FireSafe. It isolates errors and deep-copies arguments to prevent mutation.

=========================================================
-- Safe fire: catches errors and warns them
mySignal:FireSafe(player, damage) 
One-time Events
Once automatically disconnects after the first fire.

=========================================================
mySignal:Once(function(msg)
    print(`I only say this once: {msg}`)
end)
Waiting
Yields the current thread until the signal fires.

=========================================================
task.spawn(function()
    local player, damage = mySignal:Wait()
    print(`Wait finished: {damage}`)
end)

mySignal:Fire(player, 50)

===================================================================================================
                                    API Reference
===================================================================================================

Signal<Signature>

Method                          Description

new<Signature>()	            Creates a new signal. Signature must be a function type.
wrap(RBXScriptSignal)	        Wraps a native Roblox signal.
:Connect(Fn, Priority?)	        Connects a listener.
:ConnectAsync(Fn, Priority?)	Connects a listener to run asynchronously.
:Once(Fn, Priority?)	        Connects a listener that disconnects itself after one run.
:Fire(...)	                    Fires the signal, respecting listener async preferences.
:FireSync(...)	                Fires all listeners immediately (synchronous).
:FireAsync(...)	                Fires all listeners asynchronously (threaded).
:FireSafe(...)	                Fires safely, catching errors and copying arguments.
:Wait(Timeout?, Priority?)	    Yields until the signal fires.
:DisconnectAll()	            Disconnects all listeners.
:Destroy()	                    Disconnects all listeners and clears the signal.

Connection
	Property    Description
	
	.Connected	boolean (Read-only).
	.Priority	number (Read-only).
	.IsAsync	boolean (Read-only).
	:Disconnect()	Disconnects the listener.
	:Destroy()	Alias for Disconnect().
]]
