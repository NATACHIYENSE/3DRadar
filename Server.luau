--[[
	this is the serverscript complement of the Radar which creates the rings using CSG operation
	
	by @Prototrode (Roblox and Discord handle)
]]

local pls = game:GetService('Players')
local res = game:GetService('ReplicatedStorage')
local rrr = res.RadarRingsRequest
local ring = script.Ring
local virtual = script.WorldModel --doing it in workspace would cause it to replicate to all players; don't want that so it uses a proxy

local called: {[Player]: number} = {}
local function flag(p: Player, i: number?) --anticheat to prevent remote-spamming because CSG is kinda expensive
	if called[p] then
		called[p] += i or 1
	else
		called[p] = i or 1
	end
	
	if called[p] > 10 then
		p.Parent = nil --hehehehah
	end
end
pls.PlayerRemoving:Connect(function(p) --not including this would cause a memory leak
	called[p] = nil
end)

rrr.OnServerEvent:Connect(function(p, thickness: number, rings: {number})
	flag(p)
	local success: boolean, result: string = pcall(function()
		local pgui = p.PlayerGui.Radar.RingsInput
		local amount: number = 0
		for i, size in ipairs(rings) do	
			if i > 10 then break end
			size *= 2
			
			local negSize: number = size - thickness
			
			local neg = ring:Clone()
			neg.Size = Vector3.new(thickness*2, negSize, negSize)
			local actual = ring:Clone()
			actual.Size = Vector3.new(thickness*.5, size, size)	
			actual.Parent = virtual
			local ring = actual:SubtractAsync({neg}, Enum.CollisionFidelity.Box, Enum.RenderFidelity.Precise)
			ring.Name = `Ring{size}`
			ring.Parent = pgui --put it in the caller's PlayerGui; yes I'm aware that this is not a good idea
			
			amount += 1
		end
		rrr:FireClient(p, amount)
	end)
	if not success then
		print(result)
		flag(p, 10)
	end
end)
