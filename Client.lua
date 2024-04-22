--!strict

--[[
	A 3D ViewportFrame radar/minimap implementation
	
	- See entities around you in a compact manner
	- Displays their altitude relative to you
	- Select entities to keep track of them
	
	by @Prototrode (Roblox and Discord handle)
]]

--services
local lp = game:GetService('Players').LocalPlayer
local res = game:GetService('ReplicatedStorage')
local rus = game:GetService('RunService')
local uis = game:GetService('UserInputService')
local sos = game:GetService('SoundService')
local gus = game:GetService('GuiService')

local rrr = res:WaitForChild('RadarRingsRequest')

--UI instances
local sui = script.Parent
local ringsInputFolder = sui:WaitForChild('RingsInput')
local radarF = sui:WaitForChild('Radar')
local mainF = radarF:WaitForChild('Main')
local overlayCG = radarF:WaitForChild('Overlay')
local VP = mainF:WaitForChild('Viewport')
local camVP = Instance.new('Camera', VP); VP.CurrentCamera = camVP --camera for ViewportFrame
local entitiesVP = VP:WaitForChild('Entities')
local ringsVP = VP:WaitForChild('Rings')

local selF = mainF:WaitForChild('Selection')
local selOutline = selF:WaitForChild('UIStroke')
local selLabelTL = selF:WaitForChild('Label')

local northTL = overlayCG:WaitForChild('North')
local eastTL = overlayCG:WaitForChild('East')
local southTL = overlayCG:WaitForChild('South')
local westTL = overlayCG:WaitForChild('West')
local infoTL = overlayCG:WaitForChild('Info')

local dotEX = script:WaitForChild('Dot')
local lineEX = script:WaitForChild('Line')
local soundsF = script:WaitForChild('Sounds')

type Entity = {
	Object: BasePart,
	State: 'Pending' | 'Appearing'| 'Normal' | 'Disappearing' | 'Dead', --this is ordered chronologically; the ideal life cycle of entities
	Active: boolean,
	Seen: boolean?, --if the entity was ever caught by the radar
	AbsoluteDistance: number,
	Transparency1: number, --for the Line object
	Transparency2: number, --for the Dot object
	
	Dot: BasePart,
	Line: BasePart,
}

type module = {
	--basic configs
	Scale: number, --global scale in studs
	Coverage: number, --range of the radar
	EntitySize: number,
	RingThickness: number,
	LineThickness: number,
	RingsIncrement: number,
	FOV: number,
	
	--vfx configs
	FadePrimaryStartAlpha: number,
	FadePrimaryEndAlpha: number,
	FadeSecondaryStartAlpha: number,
	FadeSecondaryEndAlpha: number,
	FadePrimarySpeed: number,
	FadeSecondarySpeed: number,
	
	SelectionRadius: number, --it may be hard to click on moving objects; you can think of this as "aim-assist"
	Selected: Entity?, --the entity that is currently being tracked by being highlighted
	AddEntity: (part: BasePart) -> (),
	RemoveEntity: (part: BasePart) -> boolean,
	PromptSound: (id: string) -> (),
	
	--the rest of these are used internally and shouldn't be touched
	
	__fade1Delta: number, --these are used for linear interpolation
	__fade2Delta: number,
	
	__sounds: {[string]: Sound}, --there are Sound instances parented to this module; they are added here at runtime
	__entities: {[BasePart]: Entity}, --the registry
	__actualEntitySize: number,
	__actualLineThickness: number,
	__cameraDistance: number,
	__cameraOffset: CFrame,
	__northPoint: Vector3, --these are for the compass inside the radar; 3D positions that are later transcribed to the screen
	__eastPoint: Vector3,
	__southPoint: Vector3,
	__westPoint: Vector3,
}
local module: module = {
	--configuration
	Scale = .1,
	Coverage = 500,
	EntitySize = .05,
	RingThickness = .025,
	LineThickness = .01,
	RingsIncrement = 100,
	FOV = 1,
	FadePrimaryStartAlpha = 0.9,
	FadePrimaryEndAlpha = 0.95,
	FadeSecondaryStartAlpha = 0.95,
	FadeSecondaryEndAlpha = 1,	
	FadePrimarySpeed = 2,
	FadeSecondarySpeed = 5,
	
	SelectionRadius = 16,
	
	--these module functions will be defined later
	AddEntity = nil::any,
	RemoveEntity = nil::any,
	PromptSound = nil::any,
	
	--the readonly properties are defined here as placeholders
	__fade1Delta = 0,
	__fade2Delta = 0,
	
	__sounds = {},
	__entities = {},
	__actualEntitySize = 0,
	__actualLineThickness = 0,
	__cameraDistance = 0,
	__cameraOffset = CFrame.identity,	
	__northPoint = Vector3.zero,
	__eastPoint = Vector3.zero,
	__southPoint = Vector3.zero,
	__westPoint = Vector3.zero,
}

module.PromptSound = function(id: string)
	sos:PlayLocalSound(module.__sounds[id])
end

module.AddEntity = function(part: BasePart)
	local newDot = dotEX:Clone()
	local newLine = lineEX:Clone()
	local new: Entity = {
		Object = part,
		State = 'Pending',
		Active = true,
		AbsoluteDistance = 0,
		Transparency1 = 1,
		Transparency2 = 1,
		Dot = newDot,
		Line = newLine
	}
	module.__entities[part] = new
end

module.RemoveEntity = function(part: BasePart)
	local exists: Entity? = module.__entities[part]
	if exists then	
		exists.State = 'Disappearing' --this is not a "hard" remove; we want the entity to fade out in a pleasant manner
		module.PromptSound('Alert2')
		return true
	end
	return false
end

local function selectNearest() --track an entity by clicking on or near them
	module.Selected = nil
	local nearest: Entity?, nearestDist: number = nil, math.huge
	local vpAbsPos: Vector2 = VP.AbsolutePosition
	local vpAbsSize: Vector2 = VP.AbsoluteSize
	local mPos: Vector2 = uis:GetMouseLocation()
	for part, entity in module.__entities do
		if entity.State == 'Dead' or not entity.Active then continue end
		local pos: Vector3 = camVP:WorldToViewportPoint(entity.Dot.Position) --this vector is in [0, 1] interval scaled from the radar UI
		local posAbs: Vector2 = vpAbsPos + Vector2.new(pos.X*vpAbsSize.X, pos.Y*vpAbsSize.Y) + gus:GetGuiInset() --convert it into AbsolutePosition
		local dist: number = (posAbs - mPos).Magnitude --distance from mouse
		--if there are multiple entities in the selection radius, choose the nearest one
		if dist <= module.SelectionRadius and dist < nearestDist then
			nearest = entity
			nearestDist = dist
		end
	end
	module.Selected = nearest
end

local function init() --called at startup; called again to reapply the configuration if it changes in runtime
	
	--clear everything
	for part, entity: Entity in module.__entities do
		entity.State = 'Dead'
	end
	ringsVP:ClearAllChildren()
	
	--update the internal configs
	module.__actualEntitySize = module.Coverage*module.EntitySize*module.Scale
	dotEX.Size = Vector3.one*module.__actualEntitySize
	module.__actualLineThickness = module.Coverage*module.LineThickness*module.Scale
	
	camVP.FieldOfView = module.FOV
	module.__cameraDistance = (module.Coverage*module.Scale)/math.tan(math.rad(module.FOV*.5*.9))
	module.__cameraOffset = CFrame.new(0, 0, module.__cameraDistance)
	
	--the following code here creates the rings that you see in the radar.
	--because CSG can only be done on the server, it fires a remote to get the server to create the rings
	--the server sends the rings by putting them under PlayerGui. Yes, this is abusing a niche replication mechanic. No, I am not sorry.
	local ringThickness: number = module.RingThickness*module.Coverage*module.Scale
	
	local ringsTable: {number} = {}
	for i = module.RingsIncrement, module.Coverage, module.RingsIncrement do --space out rings every certain amount of studs (usually 100)
		table.insert(ringsTable, i*module.Scale)
	end
	rrr.OnClientEvent:Once(function(amount: number)
		local rings: {Instance}
		local timeOut: number = 0
		repeat --a loop to check if all the rings have been made by the server
			rings = ringsInputFolder:GetChildren()
			timeOut += task.wait()
		until #rings == amount or timeOut > 5
		--it's not the end of the world if the server somehow fails to make the rings
		if timeOut > 5 then
			warn('Failed to initialize radar distance ring UnionOperation')
		end
		for _, v in rings do
			v.Parent = ringsVP
		end
	end)
	rrr:FireServer(ringThickness, ringsTable)
	
	--set up the compass positions
	local compassOffset: number = module.Coverage * module.Scale
	module.__northPoint = -Vector3.zAxis * compassOffset
	module.__eastPoint = Vector3.xAxis * compassOffset
	module.__southPoint = Vector3.zAxis * compassOffset
	module.__westPoint = -Vector3.xAxis * compassOffset
	
	module.__fade1Delta = module.FadePrimaryEndAlpha - module.FadePrimaryStartAlpha
	module.__fade2Delta = module.FadeSecondaryEndAlpha - module.FadeSecondaryStartAlpha
	
	--set up sounds
	table.clear(module.__sounds)
	for _, v in soundsF:GetChildren() do
		module.__sounds[v.Name] = v
	end
end
init()

--the radar centers on the player's character; automatically resets if the player respawns
local hrp: BasePart = (lp.Character or lp.CharacterAdded:Wait()):WaitForChild('HumanoidRootPart')
lp.CharacterAdded:Connect(function(ch)
	hrp = ch:WaitForChild('HumanoidRootPart')
end)

VP.InputBegan:Connect(function(i) --the player clicks on the radar to track entities
	if i.UserInputType == Enum.UserInputType.MouseButton1 then
		selectNearest()
	end
end)

local Vec1H1: Vector3 = Vector3.new(1, .5, 1) --just a constant

local cycle: boolean
local accumulatedDt: number = 0
local activeEntitiesCounter: number = 0
rus.RenderStepped:Connect(function(dt: number)
	--some camera constants stored for efficiency
	local camCF: CFrame = workspace.CurrentCamera.CFrame
	local camPos: Vector3 = camCF.Position
	local camVPCF: CFrame = camCF.Rotation * module.__cameraOffset
	local camVPPos: Vector3 = camVPCF.Position
	camVP.CFrame = camVPCF
	
	local camElevation: number, camAzimuth: number = camCF:ToOrientation()
	local camAzimuthCF: CFrame = CFrame.Angles(0, camAzimuth, 0)
	
	--set the position of the compass signs
	local northPos: Vector3 = camVP:WorldToViewportPoint(module.__northPoint)
	northTL.Position = UDim2.fromScale(northPos.X, northPos.Y)
	local eastPos: Vector3 = camVP:WorldToViewportPoint(module.__eastPoint)
	eastTL.Position = UDim2.fromScale(eastPos.X, eastPos.Y)
	local southPos: Vector3 = camVP:WorldToViewportPoint(module.__southPoint)
	southTL.Position = UDim2.fromScale(southPos.X, southPos.Y)
	local westPos: Vector3 = camVP:WorldToViewportPoint(module.__westPoint)
	westTL.Position = UDim2.fromScale(westPos.X, westPos.Y)
	
	--show how many entities are on the radar
	--I LOVE STRING INTERPOLATION!!!!
	infoTL.Text = `<b>Entities: {activeEntitiesCounter}</b><br />{module.Coverage} Stud Detection Radius`
	local infoTLHeight: number = infoTL.AbsoluteSize.Y
	local overlayCGRadius: number = overlayCG.AbsoluteSize.Y*.5
	--some trig math to make the display be positioned below the horizon of the radar
	infoTL.Position = UDim2.new(.5, 0, .5, math.min(math.sin(math.abs(camElevation))*overlayCGRadius, overlayCGRadius-infoTLHeight))
	
	--for performance reasons, this entire loop only runs every second frame
	--this is done by just constantly toggling a boolean
	cycle = not cycle
	accumulatedDt += dt --collect the deltatime so it doesn't influence the timings, e.g. vfx fading durations
	if cycle then
		activeEntitiesCounter = 0
		for part, entity: Entity in module.__entities do
			local disp: Vector3 = part.CFrame.Position - hrp.Position
			local dist: number = disp.Magnitude
			entity.AbsoluteDistance = dist
			local outOfRange: boolean = dist > module.Coverage
			
			--change the State of the entity
			if entity.State == 'Pending' then --entity hasn't been discovered yet
				entity.Dot.Parent = entitiesVP
				entity.Line.Parent = entitiesVP
				entity.State = 'Appearing'
				if not outOfRange then
					module.PromptSound('Alert1') --this is a new entity; play a sound to alert the player
				end
			end
			--for fading, it slowly increments/decrements the transparency by the deltatime of the frame
			if entity.State == 'Appearing' then --the entity is fading into the radar
				entity.Transparency1 = math.clamp(entity.Transparency1 - accumulatedDt*module.FadePrimarySpeed, 0, 1)
				entity.Transparency2 = math.clamp(entity.Transparency2 - accumulatedDt*module.FadeSecondarySpeed, 0, 1)
				if entity.Transparency1 == 0 then
					entity.State = 'Normal'
				end
			end
			if entity.State == 'Disappearing' then --the entity is fading out of the radar; it either escapes coverage or is destroyed
				entity.Transparency1 = math.clamp(entity.Transparency1 + accumulatedDt*module.FadePrimarySpeed, 0, 1)
				entity.Transparency2 = math.clamp(entity.Transparency2 + accumulatedDt*module.FadeSecondarySpeed, 0, 1)
				if entity.Transparency1 == 1 then
					entity.State = 'Dead'
				end
			end
			if entity.State == 'Dead' then --dead entities are garbagecollected
				entity.Line:Destroy()
				entity.Dot:Destroy()
				module.__entities[part] = nil
				continue
			end
			
			local dot = entity.Dot
			local line = entity.Line
					
			if outOfRange then --hide entities that are out of range
				if entity.Active then
					dot.Transparency = 1
					line.Transparency = 1
					entity.Active = false
				end
				continue
			end
			activeEntitiesCounter += 1
			entity.Active = true
			if not entity.Seen then
				entity.Seen = true
				module.PromptSound('Alert1')
			end
			
			--do some math to figure out the correct Transparency value for entities based on the config and their distance
			local alpha: number = math.clamp(dist / module.Coverage, 0, 1)
			local fadeTransparency1: number = math.clamp((alpha-module.FadePrimaryStartAlpha)/module.__fade1Delta, 0, 1) --these are basically inverse linear interpolation; finding the value given alpha
			local fadeTransparency2: number = math.clamp((alpha-module.FadeSecondaryStartAlpha)/module.__fade2Delta, 0, 1)
			local actualTransparency1: number = 1 - ((1-fadeTransparency1) * (1-entity.Transparency1))
			local actualTransparency2: number = 1 - ((1-fadeTransparency2) * (1-entity.Transparency2))
			
			--and finally apply the properties
			local radarPos: Vector3 = disp*module.Scale
			dot.CFrame = CFrame.lookAt(radarPos, camVPPos) --make the entity face the camera so they appear as squares at all times
			dot.Transparency = actualTransparency2
			dot.Color = Color3.fromHSV(0, 0, 1-actualTransparency1) --this is grayscale btw
			line.Size = Vector3.new(module.__actualLineThickness, math.abs(radarPos.Y), module.__actualLineThickness) --line extends up from ground to the entity dot
			line.CFrame = camAzimuthCF + radarPos*Vec1H1 --positioned right in the middle (done by multiplying the Y component by 0.5)
			line.Transparency = actualTransparency1
		end
		
		--track the selected entity by encasing them in a yellow box
		--the box disappears when the entity disappears, but automatically reappears if the entity is seen again
		local selected: Entity? = module.Selected
		if selected and selected.Active then
			if selected.State == 'Disappearing' or selected.State == 'Dead' then --if the entity expires then stop tracking them
				module.Selected = nil
				selOutline.Enabled = false
				selLabelTL.Visible = false
			else
				selOutline.Enabled = true
				selLabelTL.Visible = true
				selLabelTL.Text = `<b>{selected.Object.Name}</b><br />{selected.AbsoluteDistance//1}` --look there's idiv here! :3
				
				local pos: Vector3 = camVP:WorldToViewportPoint(selected.Dot.Position)
				selF.Position = UDim2.fromScale(pos.X, pos.Y)
			end
		else
			selOutline.Enabled = false
			selLabelTL.Visible = false
		end
		
		accumulatedDt = 0
	end
	
	
end)

return module
