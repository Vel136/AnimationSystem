--!strict
-- Types.lua
-- Shared type definitions for the Animation Controller Framework.
-- All modules import from here. Do not define structural types elsewhere.

export type AnimationConfig = {
	Name         : string,
	AssetId      : string,
	Layer        : string,
	Group        : string?,
	Priority     : number,
	Looped       : boolean,
	FadeInTime   : number,
	FadeOutTime  : number,
	Speed        : number,
	CanInterrupt : boolean,
	Tags         : { string },
	Additive     : boolean,
	Weight       : number,
	MinDuration  : number?,
	Metadata     : { [string]: any }?,
}

export type LayerProfile = {
	Name        : string,
	Order       : number,
	BaseWeight  : number,
	Additive    : boolean,
	Isolated    : boolean,
	WeightLerpRate : number, -- Units per second toward TargetWeight
}

export type AnimationDirective = {
	Action    : "PLAY" | "STOP" | "STOP_GROUP",
	Target    : string,
	Immediate : boolean,
}

export type TransitionRule = {
	ToState   : string,
	Condition : string,
	Priority  : number,
}

export type StateDefinition = {
	Name           : string,
	EntryActions   : { AnimationDirective },
	ExitActions    : { AnimationDirective },
	Transitions    : { TransitionRule },
	ActiveLayers   : { string },
	SuppressLayers : { string },
}

export type AnimationIntent = {
	CharacterId   : string,
	AnimationName : string,
	Action        : "PLAY" | "STOP",
	Timestamp     : number,
	StateContext  : string,
}

export type PlayRequest = {
	ConfigName  : string,
	RequestTime : number, -- os.clock() at submission
}

export type ConflictVerdict = "ALLOW" | "DEFER" | "REJECT"

return {}
