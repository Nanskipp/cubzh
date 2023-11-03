local worldEditor = {}

local index = {}
local metatable = { __index = index, __metatable = false }
setmetatable(worldEditor, metatable)

local initDefaultMode

local padding = require("uitheme").current.padding

local objects = {}
local map
local mapIndex = 1
local mapName

local waitingForUUIDObj

local TRAILS_COLORS = { Color.Blue, Color.Red, Color.Green, Color.Yellow, Color.Grey, Color.Purple, Color.Beige, Color.Yellow, Color.Brown, Color.Pink }
local OBJECTS_COLLISION_GROUP = 7
local ALPHA_ON_DRAG = 0.6

local getObjectInfoTable = function(obj)
	return {
		uuid = obj.uuid,
		fullname = obj.fullname,
		Position = obj.Position or Number3(0, 0, 0),
		Rotation = obj.Rotation or Number3(0, 0, 0),
		Scale = obj.Scale or Number3(1, 1, 1),
		Name = obj.Name,
		itemDetailsCell = obj.itemDetailsCell,
		Physics = obj.Physics or PhysicsMode.StaticPerBlock
	}
end

-- multiplayer

local events = {
	P_END_PREPARING = "pep",
	END_PREPARING = "ep",
	P_PLACE_OBJECT = "ppo",
	PLACE_OBJECT = "po",
	P_EDIT_OBJECT = "peo",
	EDIT_OBJECT = "eo",
	P_REMOVE_OBJECT = "pro",
	REMOVE_OBJECT = "ro",
	P_PLACE_BLOCK = "ppb",
	PLACE_BLOCK = "pb",
	P_REMOVE_BLOCK = "prb",
	REMOVE_BLOCK = "rb",
	P_START_EDIT_OBJECT = "pseo",
	START_EDIT_OBJECT = "seo",
	P_END_EDIT_OBJECT = "peeo",
	END_EDIT_OBJECT = "eeo",
	SYNC = "s",
	MASTER = "m",
	PLAYER_ACTIVITY = "pa",
	P_SET_AMBIENCE = "psa",
	SET_AMBIENCE = "sa",
	P_LOAD_WORLD = "plw",
	LOAD_WORLD = "lw",
	P_EXPORT_WORLD = "pew",
	EXPORT_WORLD = "ew",
	P_EXPORT_GAME = "peg",
	EXPORT_GAME = "eg",
}

local sendToServer = function(event, data)
	local e = Event()
	e.a = event
	e.data = data
	e:SendTo(Server)
end

local states = {
	PREPARING = 1,
	DEFAULT = 2,
	GALLERY = 3,
	SPAWNING_OBJECT = 4,
	PLACING_OBJECT = 5,
	UPDATING_OBJECT = 6,
	DUPLICATE_OBJECT = 7,
	DESTROY_OBJECT = 8,
	EDIT_MAP = 9,
}

-- Substates

local subStates = {
	[states.UPDATING_OBJECT] = {
		DEFAULT = 1,
		GIZMO_MOVE = 2,
		GIZMO_ROTATE = 3,
		GIZMO_SCALE = 4,
	}
}

local setState
local setSubState

local state = states.PREPARING
local activeSubState = {}

local setObjectPhysicsMode = function(obj, physicsMode, syncMulti)
	syncMulti = syncMulti == nil and true or syncMulti
	if not obj then
		print("Error: tried to set physics mode on nil object")
		return
	end
	if obj.Physics == physicsMode then return end
	if physicsMode == PhysicsMode.Dynamic then
		obj.Physics = PhysicsMode.Dynamic
		require("hierarchyactions"):applyToDescendants(obj, { includeRoot = false }, function(o)
			o.Physics = PhysicsMode.Disabled
		end)
	else
		require("hierarchyactions"):applyToDescendants(obj, { includeRoot = true }, function(o)
			o.Physics = physicsMode
		end)
	end
	if syncMulti then
		sendToServer(events.P_EDIT_OBJECT, {
			uuid = obj.uuid,
			Physics = physicsMode
		})
	end
end

local tryPickObject = function(pe)
	local impact = pe:CastRay()
	if not impact then return end

	local obj = impact.Object
	while obj and not obj.isEditable do
		obj = obj:GetParent()
	end
	if not obj then setState(states.DEFAULT) return end

	if obj.currentlyEditedBy == Player then return end
	if obj.currentlyEditedBy then
		obj:TextBubble("Someone is editing...")
		return
	end
	setState(states.UPDATING_OBJECT, obj)
end

local setObjectAlpha = function(obj, alpha)
	require("hierarchyactions"):applyToDescendants(obj, { includeRoot = true }, function(o)
		if not o.Palette then return end
		if not o.savedAlpha then
			o.savedAlpha = {}
			for k=1,#o.Palette do
				local c = o.Palette[k]
				o.savedAlpha[k] = c.Color.Alpha / 255
			end
		end
		for k=1,#o.Palette do
			local c = o.Palette[k]
			c.Color.Alpha = o.savedAlpha[k] * alpha
		end
		o:RefreshModel()
	end)
end

local freezeObject = function(obj)
	if not obj then	return end
	obj.savedPhysicsState = obj.Physics
	setObjectPhysicsMode(obj, PhysicsMode.Disabled, true)
end

local unfreezeObject = function(obj)
	if not obj or not obj.savedPhysicsState then return end
	setObjectPhysicsMode(obj, obj.savedPhysicsState, true)
	obj.savedPhysicsState = nil
end

local spawnObject = function(data, onDone)
	local uuid = data.uuid
	local fullname = data.fullname
	local name = data.Name
	local position = data.Position or Number3(0,0,0)
	local rotation = data.Rotation or Rotation(0,0,0)
	local scale = data.Scale or 0.5
	local itemDetailsCell = data.itemDetailsCell
	local physicsMode = data.Physics or PhysicsMode.StaticPerBlock

	Object:Load(fullname, function(obj)
		obj:SetParent(World)

		local box = Box()
		box:Fit(obj, true)
		obj.Pivot = Number3(obj.Width / 2, box.Min.Y + obj.Pivot.Y, obj.Depth / 2)
		box.Min = box.Min + obj.Pivot + Number3(0, box.Max.Y, 0)
		box.Max = box.Max + obj.Pivot + Number3(0, box.Max.Y, 0)
		obj.CollisionBox = box

		setObjectPhysicsMode(obj, physicsMode)
		obj.uuid = uuid
		obj.Position = position
		obj.Rotation = rotation
		obj.Scale = scale

		require("hierarchyactions"):applyToDescendants(obj, { includeRoot = true }, function(o)
			o.CollisionGroups = { 3, OBJECTS_COLLISION_GROUP }
		end)
		obj.CollidesWithGroups = Map.CollisionGroups + Player.CollisionGroups + { OBJECTS_COLLISION_GROUP }

		obj.isEditable = true
		obj.fullname = fullname
		obj.Name = name or fullname
		obj.itemDetailsCell = itemDetailsCell

		if obj.uuid ~= -1 then
			objects[obj.uuid] = obj
		end
		if onDone then onDone(obj) end
	end)
end

local editObject = function(objInfo)
	local obj = objects[objInfo.uuid]
	if not obj then
		print("Error: can't edit object")
		return
	end

	for field,value in pairs(objInfo) do
		obj[field] = value
	end

	local alpha = objInfo.alpha
	if alpha ~= nil then
		setObjectAlpha(obj, alpha)
	end
end

local removeObject = function(objInfo)
	objects[objInfo.uuid]:RemoveFromParent()
	objects[objInfo.uuid] = nil
end

local subStatesSettingsUpdatingObject = {
	-- DEFAULT
	{
		pointerUp = function(pe)
			if worldEditor.dragging then return end
			tryPickObject(pe)
		end
	},
	-- GIZMO_MOVE
	{
		onStateBegin = function()
			worldEditor.gizmo:setObject(worldEditor.object)
			worldEditor.gizmo:setMode(require("gizmo").Mode.Move)
			worldEditor.gizmo:setAxisVisibility(true, true, true)
			worldEditor.gizmo:setOnMoveBegin(function()
				setObjectAlpha(worldEditor.object, ALPHA_ON_DRAG)
				sendToServer(events.P_EDIT_OBJECT, { uuid = worldEditor.object.uuid, alpha = ALPHA_ON_DRAG })
			end)
			worldEditor.gizmo:setOnMoveEnd(function()
				setObjectAlpha(worldEditor.object, 1)
				sendToServer(events.P_EDIT_OBJECT, { uuid = worldEditor.object.uuid, alpha = 1 })
			end)
			worldEditor.gizmo:setOnMove(function()
				sendToServer(events.P_EDIT_OBJECT, {
					uuid = worldEditor.object.uuid,
					Position = worldEditor.object.Position
				})
			end)
			freezeObject(worldEditor.object)
		end,
		onStateEnd = function()
			if worldEditor.object then
				unfreezeObject(worldEditor.object)
			end
			worldEditor.gizmo:setObject(nil)
		end,
		pointerUp = function(pe)
			if worldEditor.dragging then return end
			tryPickObject(pe)
		end
	},
	-- GIZMO_ROTATE
	{
		onStateBegin = function()
			worldEditor.gizmo:setObject(worldEditor.object)
			worldEditor.gizmo:setMode(require("gizmo").Mode.Rotate)
			worldEditor.gizmo:setAxisVisibility(true, true, true)
			worldEditor.gizmo:setOnRotateBegin(function()
				setObjectAlpha(worldEditor.object, ALPHA_ON_DRAG)
				sendToServer(events.P_EDIT_OBJECT, { uuid = worldEditor.object.uuid, alpha = ALPHA_ON_DRAG })
			end)
			worldEditor.gizmo:setOnRotateEnd(function()
				setObjectAlpha(worldEditor.object, 1)
				sendToServer(events.P_EDIT_OBJECT, { uuid = worldEditor.object.uuid, alpha = 1 })
			end)
			worldEditor.gizmo:setOnRotate(function()
				sendToServer(events.P_EDIT_OBJECT, {
					uuid = worldEditor.object.uuid,
					Rotation = worldEditor.object.Rotation
				})
			end)
			freezeObject(worldEditor.object)
		end,
		onStateEnd = function()
			worldEditor.gizmo:setObject(nil)
			unfreezeObject(worldEditor.object)
		end,
		pointerUp = function(pe)
			if worldEditor.dragging then return end
			tryPickObject(pe)
		end
	},
	-- GIZMO_SCALE
	{
		onStateBegin = function()
			worldEditor.gizmo:setObject(worldEditor.object)
			worldEditor.gizmo:setMode(require("gizmo").Mode.Scale)
			worldEditor.gizmo:setAxisVisibility(true, false, false)
			worldEditor.gizmo:setOnScaleBegin(function()
				setObjectAlpha(worldEditor.object, ALPHA_ON_DRAG)
				sendToServer(events.P_EDIT_OBJECT, { uuid = worldEditor.object.uuid, alpha = ALPHA_ON_DRAG })
			end)
			worldEditor.gizmo:setOnScaleEnd(function()
				setObjectAlpha(worldEditor.object, 1)
				sendToServer(events.P_EDIT_OBJECT, { uuid = worldEditor.object.uuid, alpha = 1 })
			end)
			worldEditor.gizmo:setOnScale(function()
				sendToServer(events.P_EDIT_OBJECT, {
					uuid = worldEditor.object.uuid,
					Scale = worldEditor.object.Scale
				})
			end)
			freezeObject(worldEditor.object)
		end,
		onStateEnd = function()
			worldEditor.gizmo:setObject(nil)
			unfreezeObject(worldEditor.object)
		end,
		pointerUp = function(pe)
			if worldEditor.dragging then return end
			tryPickObject(pe)
		end
	},
}

-- States

local statesSettings = {
	-- PREPARING
	{
		onStateEnd = function()
			worldEditor.uiPrepareState:remove()
			worldEditor.uiPrepareState = nil
			initDefaultMode()
		end
	},
	-- DEFAULT
	{
		onStateBegin = function()
			worldEditor.defaultStateUI:show()
		end,
		onStateEnd = function()
			worldEditor.defaultStateUI:hide()
		end,
		pointerUp = function(pe)
			if worldEditor.dragging then return end
			tryPickObject(pe)
		end
	},
	-- GALLERY
	{
		onStateBegin = function()
			worldEditor.gallery:show()
		end,
		onStateEnd = function()
			worldEditor.gallery:hide()
		end
	},
	-- SPAWNING_OBJECT
	{
		onStateBegin = function(data)
			worldEditor.rotationShift = data.rotationShift or 0
			data.uuid = -1
			spawnObject(data, function(obj)
				waitingForUUIDObj = obj
				setState(states.PLACING_OBJECT, obj)
			end)
		end
	},
	-- PLACING_OBJECT
	{
		onStateBegin = function(obj)
			worldEditor.placingCancelBtn:show()
			worldEditor.placingObj = obj
			freezeObject(obj)
		end,
		onStateEnd = function()
			worldEditor.placingCancelBtn:hide()
		end,
		pointerMove = function(pe)
			local placingObj = worldEditor.placingObj

			-- place and rotate object
			local impact = pe:CastRay(Map.CollisionGroups + { OBJECTS_COLLISION_GROUP }, placingObj)
			if not impact then return end
			local pos = pe.Position + pe.Direction * impact.Distance
			placingObj.Position = pos
			placingObj.Rotation.Y = Player.Rotation.Y + worldEditor.rotationShift
		end,
		pointerDrag = function(pe)
			local placingObj = worldEditor.placingObj

			-- place and rotate object
			local impact = pe:CastRay(Map.CollisionGroups + { OBJECTS_COLLISION_GROUP }, placingObj)
			if not impact then return end
			local pos = pe.Position + pe.Direction * impact.Distance
			placingObj.Position = pos
			placingObj.Rotation.Y = Player.Rotation.Y + worldEditor.rotationShift
		end,
		pointerUp = function(pe)
			if pe.Index ~= 4 then return end

			if worldEditor.dragging then return end
			local placingObj = worldEditor.placingObj

			-- drop object
			worldEditor.placingObj = nil

			unfreezeObject(placingObj)

			objects[placingObj.uuid] = placingObj
			sendToServer(events.P_PLACE_OBJECT, getObjectInfoTable(placingObj))
			placingObj.currentlyEditedBy = Player
			setState(states.UPDATING_OBJECT, placingObj)
		end,
		pointerWheelPriority = function(delta)
			worldEditor.rotationShift = worldEditor.rotationShift + delta * 0.005
			worldEditor.placingObj.Rotation.Y = Player.Rotation.Y + worldEditor.rotationShift
			return true
		end
	},
	-- UPDATING_OBJECT
	{
		onStateBegin = function(obj)
			if obj.uuid ~= -1 then
				sendToServer(events.P_START_EDIT_OBJECT, { uuid = obj.uuid })
			end
			obj.currentlyEditedBy = Player
			worldEditor.object = obj
			-- require("box_gizmo").onScaleChange = function(_, newScale)
			-- 	sendToServer(events.P_EDIT_OBJECT, { uuid = worldEditor.object.uuid, Scale = newScale })
			-- end
			-- require("box_gizmo"):setGizmoMode("scale")
			-- require("box_gizmo"):toggle(obj, Color.White)
			worldEditor.nameInput.Text = obj.Name
			worldEditor.nameInput.onTextChange = function(o)
				worldEditor.object.Name = o.Text
				sendToServer(events.P_EDIT_OBJECT, { uuid = worldEditor.object.uuid, Name = o.Text })
			end
			worldEditor.infoBtn.onRelease = function()
				local cell = worldEditor.object.itemDetailsCell
				require("item_details"):createModal({ cell = cell })
			end
			worldEditor.updateObjectUI:show()

			local currentScale = obj.Scale:Copy()
			require("ease"):inOutQuad(obj, 0.15).Scale = currentScale * 1.1
			Timer(0.15, function()
				require("ease"):inOutQuad(obj, 0.15).Scale = currentScale
			end)
			require("sfx")("waterdrop_3", { Spatialized = false, Pitch = 1 + math.random() * 0.1 })
			obj.trail = require("trail"):create(Player, obj, TRAILS_COLORS[Player.ID], 0.5)
		end,
		onStateEnd = function()
			worldEditor.updateObjectUI:hide()
			sendToServer(events.P_END_EDIT_OBJECT, { uuid = worldEditor.object.uuid })
			worldEditor.object = nil
		end,
		subStatesSettings = subStatesSettingsUpdatingObject,
		pointerWheelPriority = function(delta)
			worldEditor.object.Rotation.Y = worldEditor.object.Rotation.Y + delta * 0.005
			sendToServer(events.P_EDIT_OBJECT, { uuid = worldEditor.object.uuid, Rotation = worldEditor.object.Rotation })
			return true
		end
	},
	-- DUPLICATE_OBJECT
	{
		onStateBegin = function(uuid)
			local obj = objects[uuid]
			if not obj then
				print("Error: can't duplicate this object")
				setState(states.DEFAULT)
				return
			end
			local data = getObjectInfoTable(obj)
			data.uuid = nil
			data.rotationShift = worldEditor.rotationShift
			setState(states.SPAWNING_OBJECT, data)
		end,
		onStateEnd = function()
			worldEditor.updateObjectUI:hide()
		end
	},
	-- DESTROY_OBJECT
	{
		onStateBegin = function(uuid)
			local obj = objects[uuid]
			if not obj then
				print("Error: can't remove this object")
				setState(states.DEFAULT)
				return
			end
			sendToServer(events.P_REMOVE_OBJECT, { uuid = uuid })
			setState(states.DEFAULT)
		end,
		onStateEnd = function()
			worldEditor.updateObjectUI:hide()
		end
	},
	-- EDIT_MAP
	{
		onStateBegin = function()
			worldEditor.selectedColor = Color.Grey
			local block = MutableShape()
			worldEditor.handBlock = block
			block:AddBlock(worldEditor.selectedColor, 0, 0, 0)
			Player:EquipRightHand(block)
			block.Scale = 5
			block.LocalPosition = { 1.5,1.5,1.5 }
			worldEditor.editMapValidateBtn:show()
			worldEditor.colorPicker:show()
			worldEditor.colorPicker.parentDidResize = function()
				worldEditor.colorPicker.pos = { Screen.Width - worldEditor.colorPicker.Width, -20 }
			end
			worldEditor.colorPicker:parentDidResize()
		end,
		onStateEnd = function()
			Player:EquipRightHand(nil)
			worldEditor.editMapValidateBtn:hide()
			worldEditor.colorPicker:hide()
		end,
		pointerUp = function(pe)
			if worldEditor.dragging then return end
			local impact = pe:CastRay(nil, Player)
			if not impact or not impact.Block or impact.Object ~= map then return end
			if pe.Index == 4 then
				local pos = impact.Block.Coords
				sendToServer(events.P_REMOVE_BLOCK, { pos = pos })
				impact.Block:Remove()
			elseif pe.Index == 5 then
				impact.Block:AddNeighbor(worldEditor.selectedColor, impact.FaceTouched)
				local pos = impact.Block.Coords:Copy()
				if impact.FaceTouched == Face.Front then pos.Z = pos.Z + 1
				elseif impact.FaceTouched == Face.Back then pos.Z = pos.Z - 1
				elseif impact.FaceTouched == Face.Top then pos.Y = pos.Y + 1
				elseif impact.FaceTouched == Face.Bottom then pos.Y = pos.Y - 1
				elseif impact.FaceTouched == Face.Right then pos.X = pos.X + 1
				elseif impact.FaceTouched == Face.Left then pos.X = pos.X - 1 end
				local color = worldEditor.selectedColor
				sendToServer(events.P_PLACE_BLOCK, {
					pos = pos,
					color = color
				})
			end
		end
	}
}

setState = function(newState, data)
	local subState = activeSubState[state]
	if subState then
		onStateEnd = statesSettings[state].subStatesSettings[subState].onStateEnd
		if onStateEnd then onStateEnd(newState, data) end
	end

	local onStateEnd = statesSettings[state].onStateEnd
	if onStateEnd then onStateEnd(newState, data) end

	local oldState = state
	state = newState

	local onStateBegin = statesSettings[state].onStateBegin
	if onStateBegin then onStateBegin(data) end

	if statesSettings[state].subStatesSettings then
		-- if changing state, then going back to default
		if oldState ~= state then
			setSubState(subStates[state].DEFAULT)
		-- else keep the current subState
		else
			setSubState(activeSubState[state])
		end
	end
end

setSubState = function(newSubState, data)
	local subStatesSettings
	local subStateSetting

	-- handle onStateEnd for subState
	subStatesSettings = statesSettings[state].subStatesSettings
	if subStatesSettings then
		subStateSetting = subStatesSettings[activeSubState[state]]
		if subStateSetting then
			local onSubStateEnd = subStateSetting.onStateEnd
			if onSubStateEnd then
				onSubStateEnd(newSubState, data)
			end
		end
	end

	-- handle onStateBegin for subState
	subStatesSettings = statesSettings[state].subStatesSettings
	if not subStatesSettings then
		error("Current state has no subStates.", 2)
		return
	end

	subStateSetting = subStatesSettings[newSubState]
	if not subStateSetting then
		error("Can't currently switch to this subState, change the state before.", 2)
		return
	end

	activeSubState[state] = newSubState

	local onSubStateBegin = subStateSetting.onStateBegin
	if onSubStateBegin then onSubStateBegin(data) end
end

-- Listeners

local listeners = {
	Tick = "tick",
	PointerDown = "pointerDown",
	PointerMove = "pointerMove",
	PointerDrag = "pointerDrag",
	PointerDragBegin = "pointerDragBegin",
	PointerDragEnd = "pointerDragEnd",
	PointerUp = "pointerUp",
	PointerWheel = "pointerWheel",
}

local function handleLocalEventListener(listenerName, pe)
	local stateSettings = statesSettings[state]
	local callback

	if stateSettings.subStatesSettings then
		local subState = activeSubState[state]
		callback = stateSettings.subStatesSettings[subState][listenerName]
		if callback then
			if callback(pe) then return true end
		end
	end

	callback = stateSettings[listenerName]
	if callback then
		if callback(pe) then return true end
	end
end

for localEventName,listenerName in pairs(listeners) do
	LocalEvent:Listen(LocalEvent.Name[localEventName], function(pe)
		return handleLocalEventListener(listenerName .. "Priority", pe)
	end, { topPriority = true })
	LocalEvent:Listen(LocalEvent.Name[localEventName], function(pe)
		return handleLocalEventListener(listenerName, pe)
	end, { topPriority = false })
end

LocalEvent:Listen(LocalEvent.Name.PointerDrag, function(pe)
	if pe.Index ~= 4 then return end -- if not left click, return
	worldEditor.draggingCount = (worldEditor.draggingCount or 0) + 1
	if worldEditor.draggingCount > 4 then worldEditor.dragging = true end
end)
LocalEvent:Listen(LocalEvent.Name.PointerUp, function(pe)
	if pe.Index ~= 4 then return end -- if not left click, return
	worldEditor.draggingCount = 0
	worldEditor.dragging = false
end)

-- init

local maps = {
	"aduermael.hills",
	"aduermael.base_250x40x250",
	"claire.harbour",
	"buche.chess_board",
	"claire.apocalyptic_city",
	"aduermael.unicorn_land",
	"boumety.building_challenge",
	"claire.museum",
	"claire.summer_beach",
	"claire.voxowl_hq"
}

local loadMap

init = function()
	require("object_skills").addStepClimbing(Player)
	Camera:SetModeFree()
	local pivot = Object()
	pivot.Tick = function(pvt, dt)
		pvt.Rotation.Y = pvt.Rotation.Y + dt * 0.06
	end
	pivot:SetParent(World)
	Camera:SetParent(pivot)
	Camera.Far = 10000

	local ui = require("uikit")

	uiPrepareState = ui:createFrame()

	previousBtn = ui:createButton("<")
	previousBtn:setParent(uiPrepareState)
	previousBtn.onRelease = function()
		mapIndex = mapIndex - 1
		if mapIndex <= 0 then mapIndex = #maps end
		loadMap(maps[mapIndex])
	end
	nextBtn = ui:createButton(">")
	nextBtn:setParent(uiPrepareState)
	nextBtn.onRelease = function()
		mapIndex = mapIndex + 1
		if mapIndex > #maps then mapIndex = 1 end
		loadMap(maps[mapIndex])
	end

	galleryMapBtn = ui:createButton("or Pick an item as Map")
	galleryMapBtn:setParent(uiPrepareState)
	galleryMapBtn.onRelease = function()
		previousBtn:hide()
		nextBtn:hide()
		-- Gallery to pick a map
		local gallery
		gallery = require("gallery"):create(function() return Screen.Width end, function() return Screen.Height * 0.5 end, function(m) m.pos = { Screen.Width / 2 - m.Width / 2, Screen.Height * 0.2 } end, {
			onOpen = function(_, cell)
				local fullname = cell.repo.."."..cell.name
				sendToServer(events.P_END_PREPARING, { mapName = fullname })
				gallery:remove()
			end
		})
		gallery.didClose = function()
			previousBtn:show()
			nextBtn:show()
		end
	end

	validateBtn = ui:createButton("Start editing this map")
	validateBtn:setParent(uiPrepareState)
	validateBtn.onRelease = function()
		sendToServer(events.P_END_PREPARING, { mapName = mapName })
	end

	uiPrepareState.parentDidResize = function()
		uiPrepareState.Width = Screen.Width
		previousBtn.pos = { 50, Screen.Height * 0.5 - previousBtn.Height * 0.5}
		nextBtn.pos = { Screen.Width - 50 - nextBtn.Width, Screen.Height * 0.5 - nextBtn.Height * 0.5}
		galleryMapBtn.pos = { Screen.Width * 0.5 - galleryMapBtn.Width * 0.5, padding }
		validateBtn.pos = { Screen.Width * 0.5 - validateBtn.Width * 0.5, galleryMapBtn.pos.Y + galleryMapBtn.Height + padding }
	end
	uiPrepareState:parentDidResize()

	if Screen.Width > Screen.Height then
		local loadInput = ui:createTextInput("", "Paste JSON here")
		loadInput:setParent(uiPrepareState)

		loadBtn = ui:createButton("Load")
		loadBtn:setParent(uiPrepareState)
		loadBtn.parentDidResize = function()
			loadBtn.pos = { Screen.Width - loadBtn.Width - padding, padding }
			loadInput.pos = loadBtn.pos - { loadInput.Width + padding, 0, 0 }
			loadBtn.Height = loadInput.Height
		end
		loadBtn:parentDidResize()
		loadBtn.onRelease = function()
			sendToServer(events.P_LOAD_WORLD, { base64world = loadInput.Text })
		end
	end

	worldEditor.uiPrepareState = uiPrepareState

	loadMap = function(fullname, onDone)
		mapName = fullname
		Object:Load(fullname, function(obj)
			if map then map:RemoveFromParent() end
			map = MutableShape(obj)
			map.Scale = 5
			map.CollisionGroups = Map.CollisionGroups
			map.CollidesWithGroups = Map.CollidesWithGroups
			map.Physics = PhysicsMode.StaticPerBlock
			map:SetParent(World)
			map.Position = { 0, 0, 0 }
			map.Pivot = { 0, 0, 0 }

			Fog.On = false
			Camera.Rotation.Y = math.pi / 2
			Camera.Rotation.X = math.pi / 4

			local longestValue =  math.max(map.Width, math.max(map.Height,map.Depth))
			pivot.Position = Number3(map.Width * 0.5, longestValue, map.Depth * 0.5) * map.Scale
			Camera.Position = pivot.Position + { -longestValue * 4, 0, 0 }
			if onDone then onDone() end
		end)
	end

	loadMap(maps[1])
end

initDefaultMode = function()
	Fog.On = true
    dropPlayer = function()
        Player.Position = Number3(map.Width * 0.5, map.Height + 10, map.Depth * 0.5) * map.Scale
        Player.Rotation = { 0, 0, 0 }
        Player.Velocity = { 0, 0, 0 }
    end
    Player:SetParent(World)
	Camera:SetModeThirdPerson()
    dropPlayer()

	require("jumpfly")

	Client.Tick = function()
		if Player.Position.Y < -500 then
			dropPlayer()
			Player:TextBubble("💀 Oops!", true)
		end
	end

    local ui = require("uikit")

	-- Gizmo
	Camera.Layers = { 1, 4 }
	require("gizmo"):setLayer(4)
	worldEditor.gizmo = require("gizmo"):create({ orientationMode =  require("gizmo").Mode.Local, moveSnap = 0.5 })

	-- Default ui, add btn
	local defaultStateUI = ui:createFrame()
	index.defaultStateUI = defaultStateUI
	defaultStateUI.parentDidResize = function()
		defaultStateUI.Width = Screen.Width
		defaultStateUI.Height = Screen.Height
	end
	defaultStateUI:parentDidResize()

	local defaultStateUIConfig = {
		{
			text = "➕ Object",
			pos = function(btn) return { Screen.Width * 0.5 - btn.Width - padding * 0.5, padding } end,
			mobilePos = function(btn) return { Screen.Width * 0.5 - btn.Width * 0.5, padding } end,
			state = states.GALLERY,
			name = "addBtn"
		},
		{
			text = "🖌 Map",
			pos = function() return { Screen.Width * 0.5 + padding * 0.5, padding } end,
			state = states.EDIT_MAP,
			name = "editMapBtn",
			visibleOnMobile = false
		},
		{
			text = "🎮 Export Game",
			pos = function(btn) return { Screen.Width - padding - btn.Width, padding } end,
			serverEvent = events.P_EXPORT_GAME,
			name = "exportGameBtn",
			visibleOnMobile = false
		},
		{
			text = "📑 Export",
			pos = function(btn) return worldEditor.exportGameBtn.pos - { padding + btn.Width, 0, 0 } end,
			serverEvent = events.P_EXPORT_WORLD,
			name = "exportBtn",
			visibleOnMobile = false
		},
	}

	for _,config in ipairs(defaultStateUIConfig) do
		local btn = ui:createButton(config.text)
		btn:setParent(worldEditor.defaultStateUI)
		btn.parentDidResize = function(b)
			if Screen.Width < Screen.Height and config.visibleOnMobile == false then
				b:hide()
			else
				if Screen.Width < Screen.Height and config.mobilePos then
					b.pos = config.mobilePos(b)
				else
					b.pos = config.pos(b)
				end
				b:show()
			end
		end
		btn.Height = btn.Height * 1.5
		btn:parentDidResize()
		btn.onRelease = function()
			if config.state then
				setState(config.state)
			elseif config.serverEvent then
				sendToServer(config.serverEvent)
			end
		end
		index[config.name] = btn
	end

	-- Gallery
	local galleryOnOpen = function(_, cell)
		local fullname = cell.repo.."."..cell.name
		setState(states.SPAWNING_OBJECT, { fullname = fullname, itemDetailsCell = cell })
	end
	local initGallery
	initGallery = function()
		worldEditor.gallery = require("gallery"):create(function() return Screen.Width end, function() return Screen.Height * 0.4 end, function(m) m.pos = { Screen.Width / 2 - m.Width / 2, 0 } end, { onOpen = galleryOnOpen })
		worldEditor.gallery.didClose = function()
			setState(states.DEFAULT)
			initGallery()
		end
		worldEditor.gallery:hide()
	end
	initGallery()

	-- Placing
	local placingCancelBtn = ui:createButton("❌")
	placingCancelBtn.onRelease = function()
		setState(states.DEFAULT)
		worldEditor.placingObj:RemoveFromParent()
		worldEditor.placingObj = nil
	end
	placingCancelBtn.parentDidResize = function()
		placingCancelBtn.pos = { Screen.Width * 0.5 - placingCancelBtn.Width * 0.5, placingCancelBtn.Height * 2 }
	end
	placingCancelBtn:parentDidResize()
	placingCancelBtn:hide()
	worldEditor.placingCancelBtn = placingCancelBtn

	-- Update object UI
	local updateObjectUI = ui:createFrame(Color(78, 78, 78))

	local nameInput = ui:createTextInput("", "Item Name")
	nameInput:setParent(updateObjectUI)
	worldEditor.nameInput = nameInput

	local infoBtn = ui:createButton("👁")
	infoBtn:setParent(updateObjectUI)
	worldEditor.infoBtn = infoBtn

	local bar = require("ui_container").createHorizontalContainer()
	bar:setParent(updateObjectUI)

	local barInfo = {
		{ type="button", text="⇢", subState=subStates[states.UPDATING_OBJECT].GIZMO_MOVE },
		-- { type="button", text="↻", subState=subStates[states.UPDATING_OBJECT].GIZMO_ROTATE },
		{ type="button", text="↻", callback = function()
			worldEditor.object:TextBubble("Mouse wheel: rotate object on Y axis.")
		end },
		{ type="separator" },
		{ type="button", text="📑", callback=function() setState(states.DUPLICATE_OBJECT,worldEditor.object.uuid) end },
		{ type="gap" },
		{ type="button", text="💀", callback=function() setState(states.DESTROY_OBJECT,worldEditor.object.uuid) end },
		{ type="gap" },
		{ type="button", text="✅", callback=function() setState(states.DEFAULT,worldEditor.object.uuid) end  },
	}

	for _,elem in ipairs(barInfo) do
		if elem.type == "button" then
			local btn = ui:createButton(elem.text)
			btn.onRelease = function()
				if elem.callback then
					elem.callback(btn)
					return
				end
				if elem.subState then
					if activeSubState[state] == elem.subState then
						setSubState(subStates[state].DEFAULT)
					else
						setSubState(elem.subState)
					end
				end
			end
			bar:pushElement(btn)
		elseif elem.type == "separator" then
			bar:pushSeparator()
		elseif elem.type == "gap" then
			bar:pushGap()
		end
	end

	updateObjectUI.parentDidResize = function()
		bar:refresh()
		updateObjectUI.Width = bar.Width + padding * 2
		updateObjectUI.Height = (bar.Height + padding) * 2
		infoBtn.Height = bar.Height
		infoBtn.Width = bar.Height
		nameInput.Width = updateObjectUI.Width - infoBtn.Width
		nameInput.Height = infoBtn.Height
		nameInput.pos = { 0, updateObjectUI.Height - nameInput.Height }
		infoBtn.pos = { nameInput.Width, updateObjectUI.Height - nameInput.Height }
		bar.pos = { padding, padding }
		updateObjectUI.pos = { Screen.Width * 0.5 - updateObjectUI.Width * 0.5, padding }
	end
	updateObjectUI:hide()
	updateObjectUI:parentDidResize()
	worldEditor.updateObjectUI = updateObjectUI

	-- Ambience editor
	local aiAmbienceButton = require("ui_ai_ambience"):createButton()
	aiAmbienceButton.parentDidResize = function()
		aiAmbienceButton.pos = { padding, Screen.Height - 90 }
	end
	aiAmbienceButton.onNewAmbience = function(data)
		sendToServer(events.P_SET_AMBIENCE, data)
	end
	aiAmbienceButton:parentDidResize()

	-- Edit Map
	local editMapValidateBtn = ui:createButton("✅")
	editMapValidateBtn.onRelease = function()
		setState(states.DEFAULT)
	end
	editMapValidateBtn.parentDidResize = function()
		editMapValidateBtn.pos = { Screen.Width * 0.5 - editMapValidateBtn.Width * 0.5, placingCancelBtn.Height * 2 }
	end
	editMapValidateBtn:parentDidResize()
	editMapValidateBtn:hide()
	worldEditor.editMapValidateBtn = editMapValidateBtn

	local picker = require("colorpicker"):create({ closeBtnIcon = "", uikit = ui, transparency = false, colorPreview = false, maxWidth = function() return Screen.Width * 0.5 end })
	picker.closeBtn:remove()
	picker.closeBtn = nil
	picker:setColor(Color.Grey)
	picker:hide()
	worldEditor.colorPicker = picker

	picker.didPickColor = function(_, color)
		worldEditor.selectedColor = color
		worldEditor.handBlock.Palette[1].Color = color
	end
end

LocalEvent:Listen(LocalEvent.Name.DidReceiveEvent, function(e)
	local data = e.data
	local sender = Players[e.pID]
	local isLocalPlayer = e.pID == Player.ID

	if e.a == events.END_PREPARING then
		loadMap(data.mapName, function()
			setState(states.DEFAULT)
		end)
	elseif e.a == events.SYNC then
		if state == states.PREPARING then -- joining
			local t = Data(data, { format = "base64" }):ToTable()
			loadMap(t.mapName, function()
				setState(states.DEFAULT)
				local blocks = t.blocks
				if blocks then
					for _,d in ipairs(blocks) do
						local k = d[1]
						local color = d[2]
						-- get pos
						local x = math.floor(k % 1000)
						local y = math.floor((k / 1000) % 1000)
						local z = math.floor(k / 1000000)
						local b = map:GetBlock(x,y,z)
						if b then b:Remove() end
						if color ~= nil and color ~= -1 then
							map:AddBlock(Color(math.floor(color[1]), math.floor(color[2]), math.floor(color[3])), x, y, z)
						end
					end
				end
				if t.objects then
					for _,objInfo in ipairs(t.objects) do
						objInfo.currentlyEditedBy = nil
						spawnObject(objInfo)
					end
				end
				if t.ambience then
					require("ui_ai_ambience"):setFromAIConfig(t.ambience)
				end
			end)
		end
	elseif e.a == events.PLACE_OBJECT then
		if isLocalPlayer then
			waitingForUUIDObj.uuid = e.data.uuid
			objects[waitingForUUIDObj.uuid] = waitingForUUIDObj
			sendToServer(events.P_START_EDIT_OBJECT, { uuid = e.data.uuid })
			waitingForUUIDObj = nil
		else
			spawnObject(data, function()
				local obj = objects[data.uuid]
				obj.currentlyEditedBy = sender
				if obj.trail then
					obj.trail:remove()
				end
				obj.trail = require("trail"):create(sender, obj, TRAILS_COLORS[sender.ID], 0.5)
			end)
		end
	elseif e.a == events.EDIT_OBJECT and not isLocalPlayer then
		editObject(data)
	elseif e.a == events.REMOVE_OBJECT then
		removeObject(data)
	elseif e.a == events.START_EDIT_OBJECT then
		local obj = objects[data.uuid]
		if not obj or isLocalPlayer then return end
		obj.currentlyEditedBy = sender
		if obj.trail then
			obj.trail:remove()
		end
		obj.trail = require("trail"):create(sender, obj, TRAILS_COLORS[sender.ID], 0.5)
	elseif e.a == events.END_EDIT_OBJECT then
		local obj = objects[data.uuid]
		if not obj then
			print("can't end edit object")
			return
		end
		if obj.trail then
			obj.trail:remove()
			obj.trail = nil
		end
		obj.currentlyEditedBy = nil
	elseif e.a == events.PLACE_BLOCK and not isLocalPlayer then
		local color = data.color
		map:AddBlock(color, data.pos.X, data.pos.Y, data.pos.Z)
	elseif e.a == events.REMOVE_BLOCK and not isLocalPlayer then
		local b = map:GetBlock(data.pos.X, data.pos.Y, data.pos.Z)
		if b then b:Remove() end
	elseif e.a == events.PLAYER_ACTIVITY then
		for pIDUserID,t in pairs(data.activity) do
			if t and t.editing then
				local pID = tonumber(string.sub(pIDUserID, 1, 1))
				local obj = objects[t.editing]
				local player = Players[pID]
				if not obj or obj.currentlyEditedBy == player then return end
				obj.currentlyEditedBy = player
				if obj.trail then
					obj.trail:remove()
				end
				obj.trail = require("trail"):create(player, obj, TRAILS_COLORS[pID], 0.5)
			end
		end
	elseif e.a == events.SET_AMBIENCE and not isLocalPlayer then
		require("ui_ai_ambience"):setFromAIConfig(data)
	elseif e.a == events.EXPORT_WORLD then
		Dev:CopyToClipboard(data.base64world)

		local exportBtn = worldEditor.exportBtn
		exportBtn.Text = "Copied!"
		exportBtn.pos = worldEditor.exportGameBtn.pos - { padding + exportBtn.Width, 0, 0 }
		Timer(1, function()
			exportBtn.Text = "📑 Export"
			exportBtn.pos = worldEditor.exportGameBtn.pos - { padding + exportBtn.Width, 0, 0 }
		end)
	elseif e.a == events.EXPORT_GAME then
		Dev:CopyToClipboard(data.game)

		local exportGameBtn = worldEditor.exportGameBtn
		exportGameBtn.Text = "Copied game!"
		exportGameBtn.pos = { Screen.Width - padding - exportGameBtn.Width, padding }
		Timer(1, function()
			exportGameBtn.Text = "🎮 Export Game"
			exportGameBtn.pos = { Screen.Width - padding - exportGameBtn.Width, padding }
		end)
	end
end)

init()

return worldEditor