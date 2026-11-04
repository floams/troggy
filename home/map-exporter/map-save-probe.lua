--[[
	map save probe (read only)

	the injector puts squares on the canvas, they show up, and after a rejoin the
	dreams are still in the sidebar but the squares are gone. that means the tool
	saves some of what it sees and not the rest, and this script is how we find out
	which part it keeps.

	run this with your executor while the map is open, then:
		1. press the map tool's own save button once
		2. wait a few seconds
		3. rejoin, open the map, and run this again the same way
		4. send me "map save probe.txt" from your workspace

	it does not place, move, remove or save anything itself.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer

local out = {}

local function add(line)
	table.insert(out, line or "")
end

local function deepFind(root, name)
	if not root then
		return nil
	end
	return root:FindFirstChild(name, true)
end

local function childValue(child)
	if child:IsA("TextLabel") or child:IsA("TextButton") or child:IsA("TextBox") then
		return ' text="' .. tostring(child.Text or "") .. '"'
	elseif child:IsA("StringValue") then
		return ' value="' .. tostring(child.Value) .. '"'
	elseif child:IsA("IntValue") or child:IsA("NumberValue") then
		return " value=" .. tostring(child.Value)
	elseif child:IsA("BoolValue") then
		return " value=" .. tostring(child.Value)
	elseif child:IsA("ObjectValue") then
		local target = child.Value
		return " value=" .. (target and target:GetFullName() or "nil")
	elseif child:IsA("ImageLabel") or child:IsA("ImageButton") then
		return " image=" .. tostring(child.Image or "")
	end
	return ""
end

local function attributesOf(inst)
	local ok, list = pcall(function()
		return inst:GetAttributes()
	end)
	if not ok or type(list) ~= "table" then
		return ""
	end

	local keys = {}
	for key in pairs(list) do
		table.insert(keys, tostring(key))
	end
	if #keys == 0 then
		return ""
	end

	table.sort(keys)
	local parts = {}
	for _, key in ipairs(keys) do
		table.insert(parts, key .. "=" .. tostring(list[key]))
	end
	return " {" .. table.concat(parts, ", ") .. "}"
end

local function dump(inst, depth, limit)
	local position = ""
	if inst:IsA("GuiObject") then
		position = string.format(
			" pos=%s,%s size=%s,%s visible=%s",
			tostring(inst.Position.X.Scale) .. "/" .. tostring(inst.Position.X.Offset),
			tostring(inst.Position.Y.Scale) .. "/" .. tostring(inst.Position.Y.Offset),
			tostring(inst.Size.X.Scale) .. "/" .. tostring(inst.Size.X.Offset),
			tostring(inst.Size.Y.Scale) .. "/" .. tostring(inst.Size.Y.Offset),
			tostring(inst.Visible)
		)
	end

	add(
		string.rep("  ", depth)
			.. inst.Name
			.. " ["
			.. inst.ClassName
			.. "]"
			.. childValue(inst)
			.. attributesOf(inst)
			.. position
	)

	if depth >= limit then
		return
	end

	local children = inst:GetChildren()
	table.sort(children, function(a, b)
		return a.Name < b.Name
	end)

	for _, child in ipairs(children) do
		dump(child, depth + 1, limit)
	end
end

-- what a square on the canvas looks like

local function findMapGui()
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil
	end

	local direct = deepFind(playerGui, "MapGui")
	if direct and direct:FindFirstChild("ShiftingFrame", true) then
		return direct
	end

	for _, child in ipairs(playerGui:GetChildren()) do
		if child:FindFirstChild("ShiftingFrame", true) then
			return child
		end
	end
	return nil
end

local function isElement(child)
	if not child:IsA("GuiObject") then
		return false
	end
	if not child:FindFirstChild("ImageClipper") then
		return false
	end
	return child:FindFirstChild("Exits") ~= nil and child:FindFirstChild("Entrances") ~= nil
end

local mapGui = findMapGui()
local shiftingFrame = mapGui and deepFind(mapGui, "ShiftingFrame")

add("== where this ran ==")
add("device: " .. tostring(workspace.CurrentCamera and "camera ok" or "no camera"))
add("workspace name: " .. tostring(game.PlaceId))

if not mapGui then
	add("no map gui found :: open the map once (C) and run this again")
else
	add("map gui: " .. mapGui:GetFullName())

	if not shiftingFrame then
		add("no ShiftingFrame :: open the map once (C) and run this again")
	else
		add("")
		add("== squares on the canvas ==")

		local squares = {}
		for _, child in ipairs(shiftingFrame:GetChildren()) do
			if isElement(child) then
				table.insert(squares, child)
			end
		end

		add("count: " .. tostring(#squares))
		for index, square in ipairs(squares) do
			if index > 3 then
				break
			end
			add("")
			add("-- square " .. index)
			dump(square, 1, 3)
		end

		add("")
		add("== library sidebar ==")

		local inventory = deepFind(mapGui, "InventoryFrame")
		if not inventory then
			add("no InventoryFrame found")
		else
			local chips = {}
			for _, child in ipairs(inventory:GetDescendants()) do
				if child:IsA("GuiObject") and child:FindFirstChild("ImageClipper") then
					table.insert(chips, child)
				end
			end

			add("chips: " .. tostring(#chips))
			for index, chip in ipairs(chips) do
				if index > 2 then
					break
				end
				add("")
				add("-- chip " .. index .. " (" .. chip:GetFullName() .. ")")
				dump(chip, 1, 3)
			end
		end
	end

	add("")
	add("== scripts and events inside the map ==")
	for _, child in ipairs(mapGui:GetDescendants()) do
		local class = child.ClassName
		if class == "LocalScript" or class == "Script" or class == "ModuleScript" or class == "BindableEvent" or class == "BindableFunction" then
			add(child:GetFullName() .. " [" .. class .. "]")
		end
	end
end

-- what the save sends, and what comes back

local shown = 0

local function show(value, depth)
	local kind = type(value)

	if kind == "table" then
		if depth > 3 then
			return "{...}"
		end
		local parts = {}
		local count = 0
		for key, inner in pairs(value) do
			count = count + 1
			if count > 25 then
				table.insert(parts, "...")
				break
			end
			table.insert(parts, tostring(key) .. "=" .. show(inner, depth + 1))
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	end

	if kind == "userdata" then
		local ok, name = pcall(function()
			return value:GetFullName()
		end)
		if ok then
			return name
		end
	end

	if kind == "string" and #value > 80 then
		return "string(" .. #value .. " chars) " .. value:sub(1, 80) .. "..."
	end

	return tostring(value)
end

-- anything long the map keeps as a value is usually its own saved data
add("")
add("== long values the map keeps around ==")
do
	local foundValues = 0
	for _, inst in ipairs(mapGui and mapGui:GetDescendants() or {}) do
		if inst:IsA("StringValue") and #tostring(inst.Value or "") > 40 then
			local value = tostring(inst.Value)
			foundValues = foundValues + 1
			if foundValues <= 12 then
				add(inst:GetFullName() .. " (" .. #value .. " chars) " .. value:sub(1, 200))
			end
		end
	end
	add("values found: " .. tostring(foundValues))
end

-- the table the save writes from, when it can be reached: a custom square has no
-- place id, so this is what tells us how the map remembers one
add("")
add("== tables in memory that look like map data ==")
do
	local scanned, reported = 0, 0

	if type(getgc) == "function" then
		local ok, objects = pcall(getgc, true)
		if ok and type(objects) == "table" then
			for _, object in ipairs(objects) do
				if type(object) == "table" then
					scanned = scanned + 1
					local sample = object[1]
					if type(sample) == "table" and (sample.ScalePosition or sample.PlaceId or sample.placeId) then
						reported = reported + 1
						if reported <= 5 then
							add("")
							add("-- table " .. reported .. " with " .. tostring(#object) .. " entries")
							add(show(sample, 0))
							if object[2] then
								add(show(object[2], 0))
							end
						end
					end
				end
			end
		else
			add("getgc failed")
		end
	else
		add("this executor has no getgc")
	end

	add("scanned " .. tostring(scanned) .. " tables :: " .. tostring(reported) .. " looked like map data")
end

local function record(label, args, from)
	shown = shown + 1
	add("")
	add("-- " .. label .. " " .. shown .. " " .. from)

	for index = 1, args.n or #args do
		add("arg " .. index .. " = " .. show(args[index], 0))
	end
end

-- outgoing calls: the tool sending its map to the server
pcall(function()
	local original = hookmetamethod
	if type(original) ~= "function" then
		return
	end

	local oldNamecall

	oldNamecall = original(game, "__namecall", function(self, ...)
		local method = getnamecallmethod and getnamecallmethod() or ""			if method == "FireServer" or method == "InvokeServer" then
				local args = table.pack(...)
				local remote = tostring(self:GetFullName())
				local ok = pcall(function()
					record("sent " .. method, args, remote)
				end)
			if not ok then
				add("could not read a " .. method .. " call")
			end
		end
		return oldNamecall(self, ...)
	end)
end)

-- incoming calls: what the map draws itself from on join
for _, inst in ipairs(ReplicatedStorage:GetDescendants()) do
	local isRemote = inst:IsA("RemoteEvent") or inst.ClassName == "UnreliableRemoteEvent"
	if isRemote then
		local name = inst.Name:lower()
		if name:find("map") or name:find("dream") or name:find("save") or name:find("data") or name:find("place") then
			pcall(function()
				inst.OnClientEvent:Connect(function(...)
					record("received", table.pack(...), inst:GetFullName())
				end)
			end)
			add("watching " .. inst:GetFullName())
		end
	end
end

local function report()
	local text = table.concat(out, "\n")
	print(text)

	if writefile then
		local ok = pcall(function()
			writefile("map save probe.txt", text)
		end)
		if ok then
			print("")
			print("[map save probe] also written to map save probe.txt")
		end
	end
end

report()
print("[map save probe] press the map tool's save button now :: it keeps writing for two minutes")

-- the save happens after the press, so keep rewriting while it lands
task.spawn(function()
	for _ = 1, 24 do
		task.wait(5)
		report()
	end
	print("[map save probe] done :: send me the file")
end)
