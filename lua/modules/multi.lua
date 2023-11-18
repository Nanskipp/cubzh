-- WORLK IN PROGRESS
-- This module helps implementing efficient
-- multiplayer sync depending on use cases.

-- So far, only synchronizes players.

---------------
-- CONSTANTS --
---------------

local SYNC_DELAY_TRIGGER = 66 -- sync every 66ms
local SYNC_DELAY_FORCED = 5000 -- force sync even if nothing moved
local SMOOTH_TIME = 80
local ROT_ZERO = Rotation(0, 0, 0)

-- event keys
local KEY_MULTI = "mt" -- key to identify events from this module
local KEY_ACTION = "a"
local KEY_POSITION = "p"
local KEY_ROTATION = "r"
local KEY_ROTATION_X = "rx"
local KEY_ROTATION_Y = "ry"
local KEY_ROTATION_Z = "rz"
local KEY_LOCALROTATION = "lr"
local KEY_LOCALROTATION_X = "lrx"
local KEY_LOCALROTATION_Y = "lry"
local KEY_LOCALROTATION_Z = "lrz"
local KEY_MOTION = "m"
local KEY_VELOCITY = "v"
local KEY_PLAYER_ACTION = "pa"
local KEY_PLAYER_ACTION_USERDATA = "pu"
local KEY_OBJ_NAME = "on"

local OBJECT_FIELD_TO_EVENT_KEY = {
	["Position"] = KEY_POSITION,
	["Rotation"] = KEY_ROTATION,
	["Rotation.X"] = KEY_ROTATION_X,
	["Rotation.Y"] = KEY_ROTATION_Y,
	["Rotation.Z"] = KEY_ROTATION_Z,
	["LocalRotation"] = KEY_LOCALROTATION,
	["LocalRotation.X"] = KEY_LOCALROTATION_X,
	["LocalRotation.Y"] = KEY_LOCALROTATION_Y,
	["LocalRotation.Z"] = KEY_LOCALROTATION_Z,
	["Motion"] = KEY_MOTION,
	["Velocity"] = KEY_VELOCITY,
}

local function split(str, separator)
	local t = {}
	local regex = "([^ " .. separator .. "]+)"
	for part in string.gmatch(str, regex) do
		table.insert(t, part)
	end
	return t
end

local EVENT_KEYS = {}
for _, v in pairs(OBJECT_FIELD_TO_EVENT_KEY) do
	table.insert(EVENT_KEYS, v)
end

local EVENT_KEY_TO_OBJECT_FIELDS = {} -- [ "rx" = {"Rotation", "X"} ]
for k, v in pairs(OBJECT_FIELD_TO_EVENT_KEY) do
	EVENT_KEY_TO_OBJECT_FIELDS[v] = split(k, ".")
end

local ACTION = {
	SYNC = 1,
	PLAYER_ACTION = 2,
}

---------------
-- VARIABLES --
---------------

local actionCallbacks = {}
local teleportTriggerDistance = 0
local sqrTeleportTriggerDistance = teleportTriggerDistance * teleportTriggerDistance

local multi = {}

local synced = {} -- local Objects, synced with remote actors

local linkedObjects = {} -- (receiving sync info from other actor)

-- Send event for all synced objects
local _syncObject = function(syncedObj, t, forced)
	local obj = syncedObj.object
	local triggered = false

	if not forced then
		local dt = t - syncedObj.sentAt
		local triggerDt = t - syncedObj.triggeredAt

		if triggerDt <= SYNC_DELAY_TRIGGER then
			return
		end

		if syncedObj.onSetTriggered then
			syncedObj.onSetTriggered = false
			syncedObj.triggeredAt = t
			triggered = true
		else
			-- Check if at least one trigger has been modified
			for i, triggerName in ipairs(syncedObj.config.triggers) do
				if not syncedObj.config.isOnSetTrigger[i] then
					if syncedObj.prev[triggerName] ~= obj[triggerName] then
						syncedObj.triggeredAt = t
						triggered = true
						break
					end
				end
			end
		end

		if triggered == false and dt <= SYNC_DELAY_FORCED then
			return
		end
	end

	syncedObj.sentAt = t

	local e = Event()
	e[KEY_MULTI] = true
	e[KEY_ACTION] = ACTION.SYNC
	e[KEY_OBJ_NAME] = syncedObj.name

	for _, eventKey in ipairs(syncedObj.config.eventKeys) do
		local objectFields = EVENT_KEY_TO_OBJECT_FIELDS[eventKey]
		local v
		for _, field in ipairs(objectFields) do
			if v == nil then
				v = obj[field]
			else
				v = v[field]
			end
		end
		e[eventKey] = v
	end

	e:SendTo(syncedObj.config.targets)

	-- Save triggers values
	for _, triggerName in ipairs(syncedObj.config.triggers) do
		syncedObj.prev[triggerName] = obj[triggerName]:Copy()
	end
end

-- calback receives sender + metadata (optional)
multi.onAction = function(_, name, callback)
	actionCallbacks[name] = callback
end
multi.registerPlayerAction = multi.onAction

multi.action = function(_, name, data)
	local e = Event()
	e[KEY_MULTI] = true
	e[KEY_ACTION] = ACTION.PLAYER_ACTION
	e[KEY_PLAYER_ACTION] = name
	e[KEY_PLAYER_ACTION_USERDATA] = data
	e:SendTo(OtherPlayers)
end
multi.playerAction = multi.action -- legacy name

local initPlayer = function(player)
	player:SetParent(World)
	if player == Player then
		multi:sync(player, "p_" .. player.ID, {
			keys = { "Motion", "Velocity", "Position", "Rotation.Y" },
			triggers = { "LocalRotation", "Rotation", "Motion", "Position", "Velocity" },
		})
		multi:sync(
			player.Head,
			"ph_" .. player.ID,
			{ keys = { "LocalRotation.X" }, triggers = { "LocalRotation", "Rotation" } }
		)
	else
		multi:link(player, "p_" .. player.ID)
		multi:link(player.Head, "ph_" .. player.ID)
	end
end

local removePlayer = function(player)
	multi:unlink("ph_" .. player.ID)
	multi:unlink("p_" .. player.ID)
	player:RemoveFromParent()
end

local receive = function(e)
	if e[KEY_MULTI] ~= true then
		return
	end -- event not handled by module

	if e[KEY_ACTION] == ACTION.SYNC then
		local name = e[KEY_OBJ_NAME]

		local obj = linkedObjects[name]
		if not obj then
			-- TODO: call multi.linkRequest callback if set
			return
		end

		if obj.multi == nil then
			obj.multi = {}
		end
		obj.multi.dt = 0

		if e[KEY_POSITION] then
			local newPos = e[KEY_POSITION]
			obj.multi.delta = obj.Position:Copy() - newPos:Copy()
			obj.parentBox.Position = newPos -- go there right away

			-- TODO: teleportTriggerDistance should be per Object
			if teleportTriggerDistance > 0 and obj.multi.delta.SquaredLength >= sqrTeleportTriggerDistance then
				obj.Position = newPos
				obj.multi.delta = nil
			end
		end

		obj.parentBox.Motion = e[KEY_MOTION] or Number3.Zero
		obj.parentBox.Velocity = e[KEY_VELOCITY] or Number3.Zero

		if e[KEY_ROTATION] or e[KEY_ROTATION_X] or e[KEY_ROTATION_Y] or e[KEY_ROTATION_Z] then
			local rotStart = obj.Rotation:Copy()

			local newRot = e[KEY_ROTATION] or obj.parentBox.Rotation:Copy()
			if e[KEY_ROTATION_X] then
				newRot.X = e[KEY_ROTATION_X]
			end
			if e[KEY_ROTATION_Y] then
				newRot.Y = e[KEY_ROTATION_Y]
			end
			if e[KEY_ROTATION_Z] then
				newRot.Z = e[KEY_ROTATION_Z]
			end

			obj.parentBox.Rotation = newRot -- set parentBox's rotation right away
			obj.Rotation = rotStart

			-- smoothing will bring LocalRotation to Number3.Zero
			obj.multi.localRotStart = obj.LocalRotation:Copy()
		elseif e[KEY_LOCALROTATION] or e[KEY_LOCALROTATION_X] or e[KEY_LOCALROTATION_Y] or e[KEY_LOCALROTATION_Z] then
			local rotStart = obj.Rotation:Copy()

			local newLocalRot = e[KEY_LOCALROTATION] or obj.parentBox.LocalRotation:Copy()
			if e[KEY_LOCALROTATION_X] then
				newLocalRot.X = e[KEY_LOCALROTATION_X]
			end
			if e[KEY_LOCALROTATION_Y] then
				newLocalRot.Y = e[KEY_LOCALROTATION_Y]
			end
			if e[KEY_LOCALROTATION_Z] then
				newLocalRot.Z = e[KEY_LOCALROTATION_Z]
			end

			obj.parentBox.LocalRotation = newLocalRot -- set parentBox's local rotation right away
			obj.Rotation = rotStart

			-- smoothing will bring LocalRotation to Number3.Zero
			obj.multi.localRotStart = obj.LocalRotation:Copy()
		end

		-- TEMPORARY, needed to trigger animations:
		obj.Motion = e[KEY_MOTION] or Number3.Zero
	elseif e[KEY_ACTION] == ACTION.PLAYER_ACTION then
		local callback = actionCallbacks[e[KEY_PLAYER_ACTION]]
		if callback ~= nil then
			callback(e.Sender, e[KEY_PLAYER_ACTION_USERDATA])
		end
	end
end

-- Starts syncing local Object
-- name: has to be a string
-- default config = { keys = { "Rotation", "Motion", "Position", "Velocity" }, triggers = { "Motion", "Rotation" } }
-- This means that Rotation, Motion, Position & Velocity are synced whenever Motion or Rotation is modified,
-- or after forced delay otherwise.
-- On other actors (Clients + Server), multi.linkRequest(name) callback will be triggered for Objects that aren't yet associated.
multi.sync = function(_, object, name, config)
	config = config or {}
	config.keys = config.keys or { "Rotation", "Motion", "Position", "Velocity" }

	-- translate keys (objet fields) into event keys
	config.eventKeys = {}
	for _, objectField in ipairs(config.keys) do
		local eventKey = OBJECT_FIELD_TO_EVENT_KEY[objectField]
		if eventKey == nil then
			error("multi.sync, unsupported Object field: " .. objectField, 2)
		end
		table.insert(config.eventKeys, eventKey)
	end

	if config.triggers == nil then
		-- default triggers
		config.triggers = {}
		if type(object.Motion) == "Number3" then
			table.insert(config.triggers, "Motion")
		end
		if type(object.Rotation) == "Rotation" then
			table.insert(config.triggers, "Rotation")
		end
		if type(object.Velocity) == "Number3" then
			table.insert(config.triggers, "Velocity")
		end
		if type(object.Position) == "Number3" then
			table.insert(config.triggers, "Position")
		end
	end

	config.onSetTriggers = {}

	config.targets = config.targets or OtherPlayers

	local syncedObj = {
		name = name, -- name arbitrary given to synced Object
		prev = {}, -- previous state (used for triggers)
		object = object, -- Object reference
		config = config, -- sync config
		sentAt = 0, -- unix timestamp, when info was last sent
		triggeredAt = 0, -- using separate timestamp for triggers, to avoid waiting after a force sync
		onSetTriggered = false, -- becomes true when triggered with field through OnSet callback
	}

	syncedObj.onSetTriggerCallback = function(_)
		syncedObj.onSetTriggered = true
	end

	config.isOnSetTrigger = {}

	for i, trigger in ipairs(config.triggers) do
		if object[trigger].AddOnSetCallback ~= nil then
			object[trigger]:AddOnSetCallback(syncedObj.onSetTriggerCallback)
			config.isOnSetTrigger[i] = true
		else
			config.isOnSetTrigger[i] = false
		end
	end

	synced[name] = syncedObj
end

multi.link = function(_, object, name)
	linkedObjects[name] = object
	local parentBox = Object()
	object.parentBox = parentBox

	parentBox.Physics = object.Physics

	if object.Physics == PhysicsMode.Disabled then
		parentBox.CollisionGroups = {}
		parentBox.CollidesWithGroups = {}
	else
		local box = object.CollisionBox:Copy()
		box.Max = box.Max * object.Scale.X
		box.Min = box.Min * object.Scale.X

		parentBox.CollisionBox = box
		parentBox.CollisionGroups = object.CollisionGroups
		parentBox.CollidesWithGroups = object.CollidesWithGroups
		parentBox.Bounciness = object.Bounciness
		parentBox.Friction = object.Friction
	end

	local parent = object.Parent or World

	parent:AddChild(parentBox)

	parentBox.LocalPosition = object.LocalPosition
	parentBox.LocalRotation = object.LocalRotation

	object.Physics = PhysicsMode.Trigger
	object.CollidesWithGroups = {}

	parentBox:AddChild(object)

	object.LocalPosition = Number3.Zero
	object.LocalRotation = ROT_ZERO
end

multi.unlink = function(_, name)
	linkedObjects[name] = nil
	if synced[name] ~= nil then
		local object = synced[name]
		local config = object.config

		-- remove onset triggers
		for i, trigger in ipairs(config.triggers) do
			if config.isOnSetTrigger[i] then
				object[trigger]:RemoveOnSetCallback(object.onSetTriggerCallback)
			end
		end
		synced[name] = nil
	end
end

-- Can be called to force sync an Object
-- Calling this can also be used to claim ownership on an Object
-- and become the actor responsible for sync.
-- NOTE: what if Object owner leaves the game? (soccer game case)
-- Maybe server should just be owner in that case and allow syncs from non-actors?
-- On server side: multi:sync(Object(), "ball", { keys = { "Rotation", "Motion", "Position", "Velocity" }, triggers = {} })
multi.forceSync = function(_, name)
	local localObject = synced[name]
	if localObject then
		_syncObject(localObject, Time.UnixMilli(), true)
		return
	end

	local remoteObject = linkedObjects[name]
	if remoteObject then
		local e = Event()
		e[KEY_MULTI] = true
		e[KEY_ACTION] = ACTION.SYNC
		e[KEY_OBJ_NAME] = name
		e[KEY_POSITION] = remoteObject.parentBox.Position
		e[KEY_MOTION] = remoteObject.parentBox.Motion
		e[KEY_VELOCITY] = remoteObject.parentBox.Velocity
		e:SendTo(Players)
	end
end

local tick = function(dt)
	local t = Time.UnixMilli()

	for _, syncedObj in pairs(synced) do
		_syncObject(syncedObj, t)
	end

	local msDT = math.floor(dt * 1000)

	-- apply smoothing deltas to linked objects
	local p

	for _, o in pairs(linkedObjects) do
		if o.multi.dt ~= nil and o.multi.dt < SMOOTH_TIME then
			o.multi.dt = o.multi.dt + msDT
			if o.multi.dt > SMOOTH_TIME then
				o.multi.dt = SMOOTH_TIME
			end
			p = o.multi.dt / SMOOTH_TIME

			if o.multi.delta then
				o.Position = o.parentBox.Position + o.multi.delta * (1.0 - p)
			end

			if o.multi.localRotStart then
				o.LocalRotation:Slerp(o.multi.localRotStart, ROT_ZERO, p)
				-- head movement issues with Lerp, but movement seems to be better for body rotation
				-- o.LocalRotation:Lerp(o.multi.localRotStart, ROT_ZERO, p)
			end

			if p == 1 then
				o.multi.dt = nil
				o.multi.delta = nil
				o.multi.localRotStart = nil
			end
		end
	end
end

LocalEvent:Listen(LocalEvent.Name.Tick, function(dt)
	tick(dt)
end)
LocalEvent:Listen(LocalEvent.Name.OnPlayerJoin, function(p)
	initPlayer(p)
end)
LocalEvent:Listen(LocalEvent.Name.OnPlayerLeave, function(p)
	removePlayer(p)
end)
LocalEvent:Listen(LocalEvent.Name.DidReceiveEvent, function(e)
	receive(e)
end)

----------------
-- DEPRECATED --
----------------

local function deprecateFunction(name)
	local displayed = false
	multi[name] = function()
		if not displayed then
			print("⚠️ multi." .. name .. " is deprecated, no need to call it anymore!")
			displayed = true
		end
	end
end

deprecateFunction("initPlayer")
deprecateFunction("removePlayer")
deprecateFunction("receive")
deprecateFunction("tick")

return multi
