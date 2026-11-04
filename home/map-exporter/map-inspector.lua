-- run this with your executor while you are in a map, then use the map tool's own
-- save button once. it only reads: nothing is added, changed or saved by this
-- script. it writes what it finds to "map structure.txt" in your workspace, so
-- the injector can place squares through the tool itself instead of as clones
-- that disappear when you rejoin.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer

local out = {}

local function add(line)
	table.insert(out, line or "")
end

local function childValue(child)
	if child:IsA("TextLabel") or child:IsA("TextButton") or child:IsA("TextBox") then
		local text = tostring(child.Text or "")
		if text ~= "" then
			return ' text="' .. text .. '"'
		end
	elseif child:IsA("StringValue") then
		return ' value="' .. tostring(child.Value) .. '"'
	elseif child:IsA("IntValue") or child:IsA("NumberValue") then
		return " value=" .. tostring(child.Value)
	elseif child:IsA("ObjectValue") then
		local target = child.Value
		if target then
			return " value=" .. target:GetFullName()
		end
		return " value=nil"
	elseif child:IsA("ImageLabel") or child:IsA("ImageButton") then
		local image = tostring(child.Image or "")
		if image ~= "" then
			return " image=" .. image
		end
	end

	return ""
end

local function attributes(inst)
	local list = inst:GetAttributes()
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
	add(string.rep("  ", depth) .. inst.Name .. " [" .. inst.ClassName .. "]" .. childValue(inst) .. attributes(inst))

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

local function show(value, depth)
	local kind = type(value)

	if kind == "table" then
		if depth > 5 then
			return "{...}"
		end

		local parts = {}
		for key, inner in pairs(value) do
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

	return tostring(value)
end

add("== screen guis ==")
local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
if playerGui then
	for _, gui in ipairs(playerGui:GetChildren()) do
		if gui:IsA("ScreenGui") then
			add("")
			dump(gui, 0, 4)
		end
	end
end

add("")
add("== tools ==")
local places = { LocalPlayer, LocalPlayer:FindFirstChildOfClass("Backpack"), workspace }
for _, place in ipairs(places) do
	if place then
		for _, inst in ipairs(place:GetChildren()) do
			if inst:IsA("Tool") then
				add("")
				dump(inst, 0, 3)
			end
		end
	end
end

add("")
add("== remote events that look like map data ==")
for _, inst in ipairs(ReplicatedStorage:GetDescendants()) do
	local isRemote = inst:IsA("RemoteEvent") or inst:IsA("RemoteFunction") or inst.ClassName == "UnreliableRemoteEvent"
	if isRemote then
		local name = inst.Name:lower()
		if name:find("map") or name:find("dream") or name:find("data") or name:find("place") then
			add(inst:GetFullName() .. " [" .. inst.ClassName .. "]")
		end
	end
end

add("")
add("== saved payloads seen from now on ==")
add("use the map tool's own save button once, then this fills in")

local seen = 0

local function capture(remote, ...)
	seen = seen + 1
	add("")
	add("-- payload " .. seen .. " from " .. remote:GetFullName())

	local args = table.pack(...)
	for index = 1, args.n do
		add("arg " .. index .. " = " .. show(args[index], 0))
	end
end

local function watch(remote)
	pcall(function()
		remote.OnClientEvent:Connect(function(...)
			capture(remote, ...)
		end)
	end)
end

for _, inst in ipairs(ReplicatedStorage:GetDescendants()) do
	local isRemote = inst:IsA("RemoteEvent") or inst.ClassName == "UnreliableRemoteEvent"
	if isRemote then
		local name = inst.Name:lower()
		if name:find("map") or name:find("dream") or name:find("data") or name:find("place") then
			watch(inst)
		end
	end
end

local function report()
	local text = table.concat(out, "\n")
	print(text)

	if writefile then
		local ok = pcall(function()
			writefile("map structure.txt", text)
		end)
		if ok then
			print("")
			print("also written to map structure.txt in your workspace")
		end
	end
end

report()

-- a payload usually arrives after a save, so show the new lines as they land
task.spawn(function()
	local shown = #out
	while true do
		task.wait(1)
		if #out > shown then
			local fresh = {}
			for index = shown + 1, #out do
				table.insert(fresh, out[index])
			end
			shown = #out
			print(table.concat(fresh, "\n"))
		end
	end
end)
