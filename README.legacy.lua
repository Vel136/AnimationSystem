--[[
# Animation Controller Framework

Per-character animation orchestration for combat-heavy multiplayer Roblox titles.  
Implements the full system described in the design specification v1.0.

---

## Module Map

```
AnimationFramework/
├── Types.lua                  Shared type definitions (no runtime code)
├── Signal.lua                 Lightweight typed signal — zero BindableEvent overhead
├── AnimationRegistry.lua      Singleton metadata store; immutable after Init()
├── TrackWrapper.lua           Wraps one AnimationTrack; never exposed externally
├── LayerManager.lua           Ordered logical layers; per-frame weight interpolation
├── ConflictResolver.lua       Stateless 4-phase resolution: Group → Layer → Priority → Timestamp
├── ExclusiveGroupManager.lua  Mutual exclusivity; interrupt pipeline; pending slot
├── StateMachine.lua           Flat FSM; validated at init; diff-driven layer changes
├── ReplicationBridge.lua      Intent serialization; anti-desync snapshots
├── DebugInspector.lua         Read-only introspection; runtime invariant validation
├── AnimationController.lua    Root orchestrator; owns all subsystems; public API surface
└── Example.lua                Full wiring example for a combat character
```

---

## Quick Start

### 1 — Initialize the Registry (once, before any character loads)

```lua
local AnimationRegistry = require(AnimationFramework.AnimationRegistry)
AnimationRegistry.GetInstance():Init({
    {
        Name = "Idle", AssetId = "rbxassetid://...",
        Layer = "Locomotion", Group = "Locomotion",
        Priority = 10, Looped = true,
        FadeInTime = 0.2, FadeOutTime = 0.2, Speed = 1.0,
        CanInterrupt = true, Tags = {"locomotion"}, Additive = false, Weight = 1.0,
    },
    -- ... more configs
})
```

All fields except `Group`, `MinDuration`, and `Metadata` are required.  
The registry validates types and rejects malformed configs at init — not at runtime.

### 2 — Create a Controller per character

```lua
local controller = AnimationController.new({
    CharacterId   = player.UserId,
    Animator      = humanoid.Animator,
    LayerProfiles = { ... },
    States        = { ... },
    InitialState  = "Idle",
    Predicates    = { IsRunning = function() return speed > 1 end },
    IntentRemote  = intentRemote,    -- nil if not using replication
    SnapshotRemote = snapshotRemote,
})
```

### 3 — Drive animations from game systems

```lua
-- Combat system plays animations through the public API only:
controller:Play("SwordSwing")
controller:Stop("Block")
controller:StopGroup("CombatAction")

-- State machine transitions:
controller:RequestStateTransition("Running", 10) -- priority 10
```

External systems never hold references to TrackWrappers, LayerManager, or raw AnimationTracks.

---

## Conflict Resolution Order

Every play request passes through ConflictResolver before execution:

| Phase | Criterion | Winner |
|-------|-----------|--------|
| 1 | ExclusiveGroup membership | Group enforcement (ALLOW / DEFER / REJECT) |
| 2 | Layer.Order | Higher Order wins |
| 3 | Config.Priority | Higher Priority wins |
| 4 | StartTimestamp | Earlier (incumbent) wins; ties → REJECT |

The verdict is a **pure function** of static config fields and recorded timestamps.  
No hidden state, no call-order dependence, no Roblox scheduler sensitivity.

---

## Exclusive Groups & MinDuration

```
Config.CanInterrupt = false   →  cannot be cut short by default
Config.MinDuration  = 0.4     →  committed for at least 400 ms

If a request arrives while the active animation is within MinDuration:
  → Stored as PendingWrapper (one slot per group; newest evicts older)
  → Re-evaluated automatically when MinDuration expires or track completes
  → Caller observes CompletedSignal if it needs to know the outcome
```

---

## Per-Frame Pipeline

```
Heartbeat / RenderStepped
  1. StateMachine.Tick()          — evaluate pending transitions
  2. LayerManager.UpdateWeights() — interpolate CurrentWeight → TargetWeight  O(L)
  3. _PushWeights()               — apply FinalWeight to all TrackWrappers     O(W)
  4. ReplicationBridge.Flush()    — send queued intent deltas                  O(I)
  5. _FlushPendingQueue()         — process mid-frame play requests
```

Zero table allocations in the hot path. All pools pre-allocated.

---

## Debugging

```lua
local inspector = controller:AttachInspector()

-- Human-readable animation tree (deterministic — usable as test oracle)
print(inspector:GetAnimationTree())

-- Layer weights
local layers = inspector:GetLayerSnapshot()

-- Group state (active + pending per group)
local groups = inspector:GetGroupSnapshot()

-- Invariant check (run in CI after every operation; or at ~1/min in production)
local result = inspector:ValidateInvariants()
if not result.Valid then
    for _, violation in result.Violations do warn(violation) end
end
```

---

## Performance at Scale

| Metric | Value |
|--------|-------|
| Max layers per character | 16 |
| Max active TrackWrappers per character | 36 |
| Per-character per-frame operations | ~60–80 arithmetic + table reads |
| 60 players × 20 tracks | ~10,000 ops/frame — well within Lua VM budget |
| TrackWrapper pool cap | 2 per AnimationConfig |
| GC allocations per frame | Zero (pre-allocated pools, no table literals in hot path) |

---

## Replication

The server is authoritative. Non-owning clients reconstruct state from **intent streams**,  
not raw track data. Bandwidth scales with animation events, not frame rate.

Anti-desync: server broadcasts a lightweight state snapshot every ~2.5 seconds.  
On sequence mismatch, clients reconcile by replaying the delta — no visual pop  
because reconciliation operates on logical state, not visible weights.

---

## Destruction

```lua
controller:Destroy()
-- Synchronous. Stops all tracks immediately, destroys all wrappers,
-- disconnects all signals, cancels all pending timers.
-- Safe to call on character death/removal.
```

]]