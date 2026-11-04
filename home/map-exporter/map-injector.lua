--[[
	map-injector
	takes an export from workspace/home map exports and puts it back on the map,
	so you can carry a mapped world onto a new map or swap out the one you have.
	it never invents its own squares: every element is cloned from the map tool's
	own library (or from a square already on the canvas), given the place id,
	position, color, note and markers from the export, then wired back up with the
	tool's own exit lines. the tool's save button writes it like you placed it.

	buttons:
		export now          runs map-exporter on this map and saves a fresh export
		inject              adds the chosen export to the open map
		replace map         clears every mapped square, then adds the export
		remove all mapped   removes every square from the canvas
		remove all dupes    only shows when the export or the canvas has the same
		                    dream twice; keeps the first copy and rewires the rest
		save map            presses the map tool's own save button

	usage:
		1. equip the map tool and open the map once (C) so your data loads
		2. run this script:
		   loadstring(game:HttpGet("https://raw.githubusercontent.com/floams/troggy/refs/heads/main/home/map-exporter/map-injector.lua"))()
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local EXPORT_FOLDER = "home map exports"
local EXPORTER_URL = "https://raw.githubusercontent.com/floams/troggy/refs/heads/main/home/map-exporter/map-exporter.lua"

-- marker names used by the map tool's MarkerPickerFrame
local MARKER_NAMES = { [1] = "DeadEnd", [2] = "Badge", [3] = "AltExit" }

local COLORS = {
	base = Color3.fromRGB(30, 30, 46),
	panel = Color3.fromRGB(24, 24, 37),
	stroke = Color3.fromRGB(69, 71, 90),
	text = Color3.fromRGB(205, 214, 244),
	muted = Color3.fromRGB(127, 132, 156),
	mauve = Color3.fromRGB(203, 166, 247),
	green = Color3.fromRGB(166, 227, 161),
	red = Color3.fromRGB(243, 139, 168),
	yellow = Color3.fromRGB(249, 226, 175),
}

local FONT = Enum.Font.Code

local function deepFind(root, name)
	if not root then
		return nil
	end

	local direct = root:FindFirstChild(name)
	if direct then
		return direct
	end

	return root:FindFirstChild(name, true)
end

local function getPlayerGui()
	if not LocalPlayer then
		return nil
	end
	return LocalPlayer:FindFirstChild("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui", 10)
end

local function findMapGui()
	local playerGui = getPlayerGui()
	if playerGui then
		local direct = deepFind(playerGui, "MapGui")
		if direct and direct:FindFirstChild("ShiftingFrame", true) then
			return direct
		end

		for _, child in ipairs(playerGui:GetChildren()) do
			if child:FindFirstChild("ShiftingFrame", true) then
				return child
			end
		end
	end

	local backpack = LocalPlayer and LocalPlayer:FindFirstChild("Backpack")
	if backpack then
		return deepFind(backpack, "MapGui")
	end

	return nil
end

-- an element is a square on the canvas: an image, an exits list and an
-- entrances list. the same test the exporter uses, so we touch nothing else.
local function isElement(child)
	if not child:IsA("GuiObject") then
		return false
	end
	if not child:FindFirstChild("ImageClipper") then
		return false
	end
	return child:FindFirstChild("Exits") ~= nil and child:FindFirstChild("Entrances") ~= nil
end

local function canvasPosition(element, size)
	local position = element.Position

	local x = position.X.Scale
	local y = position.Y.Scale

	if size.X > 0 then
		x = x + position.X.Offset / size.X
	end
	if size.Y > 0 then
		y = y + position.Y.Offset / size.Y
	end

	return x, y
end

local function canvasElements(shiftingFrame)
	local found = {}
	local size = shiftingFrame.AbsoluteSize

	for order, child in ipairs(shiftingFrame:GetChildren()) do
		if isElement(child) then
			local x, y = canvasPosition(child, size)
			local label = child:FindFirstChild("DreamLabel")

			table.insert(found, {
				instance = child,
				order = order,
				placeId = child.Name == "CUSTOM" and "CUSTOM" or (tonumber(child.Name) or child.Name),
				name = label and label.Text or "",
				x = x,
				y = y,
			})
		end
	end

	table.sort(found, function(a, b)
		if a.y ~= b.y then
			return a.y < b.y
		end
		if a.x ~= b.x then
			return a.x < b.x
		end
		return a.order < b.order
	end)

	return found
end

-- a place id, but custom dreams all share the id "CUSTOM", so they are told
-- apart by their name instead
local function keyOf(placeId, name)
	if type(placeId) == "number" then
		return tostring(placeId)
	end

	local text = tostring(placeId or "")
	if text == "CUSTOM" then
		return "CUSTOM:" .. tostring(name or "")
	end
	return text
end

local function splitList(text)
	local list = {}
	for part in tostring(text or ""):gmatch("[^,]+") do
		local clean = part:match("^%s*(.-)%s*$")
		if clean ~= "" then
			table.insert(list, clean)
		end
	end
	return list
end

local function decode(text)
	local ok, value = pcall(HttpService.JSONDecode, HttpService, text)
	if ok and type(value) == "table" then
		return value
	end
	return nil
end

local function scanRaw(text)
	local found = {}
	for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
		local index, json = line:match("^%s*%[(%d+)%]%s*(%{.*%})%s*$")
		if index and json then
			table.insert(found, { index = tonumber(index), json = json })
		end
	end
	return found
end

-- dreams that are saved in the library but were never placed down have no
-- position of their own, so they are read separately from the placed squares
local function scanLibrary(text)
	local found = {}
	for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
		local index, json = line:match("^%s*%[L(%d+)%]%s*(%{.*%})%s*$")
		if index and json then
			table.insert(found, { index = tonumber(index), json = json })
		end
	end
	return found
end

local function numberOr(value, fallback)
	local number = tonumber(value)
	if number == nil then
		return fallback
	end
	return number
end

local function normalize(index, data)
	if type(data) ~= "table" then
		return nil
	end

	local placeId = data.PlaceId
	if placeId == nil then
		placeId = data.placeId
	end
	if placeId == nil then
		return nil
	end

	local name = data.Name or data.name or ""
	local position = data.ScalePosition or data.position or {}
	local color = data.Color or data.color or {}

	-- newer exports keep the exact scale and offset the map stored, which puts a
	-- square back on the same pixels even when the canvas has a different size
	local scaleOffset = nil
	if type(data.Position) == "table" and #data.Position == 4 then
		scaleOffset = {
			numberOr(data.Position[1], 0),
			numberOr(data.Position[2], 0),
			numberOr(data.Position[3], 0),
			numberOr(data.Position[4], 0),
		}
	end

	local markers = {}
	for _, id in ipairs(data.Markers or data.markers or {}) do
		local number = tonumber(id)
		if number and MARKER_NAMES[number] then
			table.insert(markers, number)
		end
	end
	table.sort(markers)

	local exits = {}
	for _, reference in ipairs(data.Exits or data.exits or {}) do
		local number = tonumber(reference)
		if number then
			table.insert(exits, math.floor(number))
		end
	end

	return {
		index = index,
		placeId = placeId,
		key = keyOf(placeId, name),
		name = tostring(name),
		image = tostring(data.ImageId or data.image or ""),
		note = tostring(data.Note or data.note or ""),
		markers = markers,
		color = {
			numberOr(color[1] or color.r, 1),
			numberOr(color[2] or color.g, 1),
			numberOr(color[3] or color.b, 1),
		},
		x = numberOr(position[1] or position.x, 0),
		y = numberOr(position[2] or position.y, 0),
		scaleOffset = scaleOffset,
		exits = exits,
	}
end

-- exports written before the raw data section still carry the same facts in
-- the readable part, so they can be read back too
local function scanLegacy(text)
	local records = {}
	local current = nil
	local inNote = false

	local function flushNote()
		inNote = false
	end

	for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
		local index, tag, name, x, y, hex = line:match(
			'^#(%d+)%s+%[([^%]]*)%]%s+"(.-)"%s+at%s+%(([%-%d%.]+),%s*([%-%d%.]+)%)%s+color%s+#(%x%x%x%x%x%x)'
		)

		if index then
			local placeId = tonumber(tag)
			if tag == "CUSTOM" then
				placeId = "CUSTOM"
			end

			local record = {
				index = tonumber(index),
				placeId = placeId or tag,
				key = keyOf(placeId or tag, name),
				name = name,
				image = "",
				note = "",
				markers = {},
				color = {
					tonumber(hex:sub(1, 2), 16) / 255,
					tonumber(hex:sub(3, 4), 16) / 255,
					tonumber(hex:sub(5, 6), 16) / 255,
				},
				x = tonumber(x) or 0,
				y = tonumber(y) or 0,
				exits = {},
			}

			table.insert(records, record)
			current = record
			flushNote()
		elseif current then
			local exitsPart = line:match("^%s+exits:%s*(.*)$")
			local markersPart = line:match("^%s+markers:%s*(.*)$")
			local notePart = line:match("^%s+note:%s?(.*)$")

			if exitsPart then
				for reference in exitsPart:gmatch("#(%d+)") do
					table.insert(current.exits, tonumber(reference))
				end
				flushNote()
			elseif markersPart then
				for _, item in ipairs(splitList(markersPart)) do
					for id, markerName in pairs(MARKER_NAMES) do
						if markerName == item then
							table.insert(current.markers, id)
						end
					end
				end
				table.sort(current.markers)
				flushNote()
			elseif notePart then
				current.note = notePart
				inNote = true
			elseif inNote then
				local continuation = line:match("^%s%s%s%s%s%s%s%s%s%s(.*)$")
				if continuation and continuation ~= "" then
					current.note = current.note .. "\n" .. continuation
				elseif line:match("^%s*$") or line:match("^%s+%a") then
					flushNote()
				end
			end
		end
	end

	return records
end

local function parseText(text)
	local raw = tostring(text or "")
	if raw:sub(1, 3) == "\239\187\191" then
		raw = raw:sub(4)
	end

	local trimmed = raw:gsub("^%s+", ""):gsub("%s+$", "")
	if trimmed == "" then
		return nil, {}
	end

	local library = {}

	local function readLibrary(list)
		for index, entry in ipairs(list or {}) do
			local record = normalize(index, entry)
			if record then
				table.insert(library, record)
			end
		end
	end

	if trimmed:sub(1, 1) == "{" or trimmed:sub(1, 1) == "[" then
		local data = decode(trimmed)
		if type(data) == "table" then
			if data.library ~= nil then
				readLibrary(data.library)
			end

			local list = data
			if data.elements ~= nil then
				list = data.elements
			elseif data.map ~= nil then
				list = data.map
			end

			if type(list) == "table" then
				local records = {}
				for index, entry in ipairs(list) do
					local record = normalize(index, entry)
					if record then
						table.insert(records, record)
					end
				end
				if #records > 0 then
					return records, library
				end
			end
		end
	end

	local scanned = scanRaw(raw)
	if #scanned > 0 then
		local records = {}
		for _, item in ipairs(scanned) do
			local record = normalize(item.index, decode(item.json))
			if record then
				table.insert(records, record)
			end
		end
		for _, item in ipairs(scanLibrary(raw)) do
			local record = normalize(item.index, decode(item.json))
			if record then
				table.insert(library, record)
			end
		end

		if #records > 0 then
			return records, library
		end
	end

	local legacy = scanLegacy(raw)
	if #legacy > 0 then
		return legacy, library
	end

	return nil, library
end

-- keeps the first copy of every dream and points everything that referred to a
-- dropped copy at the copy that stayed, so no connection is lost
local function dedupe(records)
	local kept, byKey, resolve, duplicates = {}, {}, {}, {}

	for _, record in ipairs(records) do
		local keptRecord = byKey[record.key]
		if keptRecord then
			resolve[record.index] = keptRecord
			table.insert(duplicates, record)
		else
			byKey[record.key] = record
			resolve[record.index] = record
			table.insert(kept, record)
		end
	end

	return kept, duplicates, resolve
end

-- everything the library saved that the map itself does not have placed down
local function libraryExtras(records, library)
	local placed = {}
	for _, record in ipairs(records) do
		placed[record.key] = true
	end

	local extras = {}
	for _, entry in ipairs(library or {}) do
		if not placed[entry.key] then
			placed[entry.key] = true
			table.insert(extras, entry)
		end
	end

	return extras
end

local function cloneRecordAt(record, x, y)
	local copy = {}
	for key, value in pairs(record) do
		copy[key] = value
	end
	copy.x = x
	copy.y = y
	return copy
end

-- saved dreams had no place on the map, so they take the first free squares,
-- clear of whatever is already on the canvas
local function freeSpots(count, existing, stepX, stepY)
	stepX = stepX or 0.12
	stepY = stepY or 0.12

	local spots = {}
	local y = stepY / 2

	local function taken(x, y)
		for _, item in ipairs(existing) do
			if math.abs(item.x - x) < stepX * 0.9 and math.abs(item.y - y) < stepY * 0.9 then
				return true
			end
		end
		for _, spot in ipairs(spots) do
			if math.abs(spot[1] - x) < stepX * 0.9 and math.abs(spot[2] - y) < stepY * 0.9 then
				return true
			end
		end
		return false
	end

	while y < 1 and #spots < count do
		local x = stepX / 2
		while x < 1 and #spots < count do
			if not taken(x, y) then
				table.insert(spots, { x, y })
			end
			x = x + stepX
		end
		y = y + stepY
	end

	return spots
end

local function cleanChildren(container)
	for _, child in ipairs(container:GetChildren()) do
		child:Destroy()
	end
end

local function ensureChild(parent, name, className)
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing
	end

	local child = Instance.new(className)
	child.Name = name
	child.Parent = parent
	return child
end

local function setValue(holder, text)
	if not holder then
		return
	end

	if holder:IsA("TextLabel") or holder:IsA("TextButton") or holder:IsA("TextBox") then
		holder.Text = text
		return
	end

	pcall(function()
		holder.Value = text
	end)
end

local function templateKey(instance)
	if instance.Name == "CUSTOM" then
		return "CUSTOM"
	end
	return tostring(tonumber(instance.Name) or instance.Name)
end

-- the map tool's own squares are the best template: they already carry the
-- clipper, label, marker holder and exits lists the tool expects
local function collectTemplates(shiftingFrame, mapGui)
	local templates, fallback, canvasSize = {}, nil, nil
	local markerTemplates = {}

	for _, child in ipairs(shiftingFrame:GetChildren()) do
		if isElement(child) then
			local key = templateKey(child)
			templates[key] = templates[key] or child
			fallback = fallback or child
			canvasSize = canvasSize or child.Size

			local holder = child:FindFirstChild("MarkerHolder")
			if holder then
				for _, marker in ipairs(holder:GetChildren()) do
					markerTemplates[marker.Name] = markerTemplates[marker.Name] or marker
				end
			end
		end
	end

	local inventory = deepFind(mapGui, "InventoryFrame")
	if inventory then
		for _, child in ipairs(inventory:GetDescendants()) do
			if child:IsA("GuiObject") and child:FindFirstChild("ImageClipper") then
				local key = templateKey(child)
				templates[key] = templates[key] or child
				fallback = fallback or child

				local holder = child:FindFirstChild("MarkerHolder")
				if holder then
					for _, marker in ipairs(holder:GetChildren()) do
						markerTemplates[marker.Name] = markerTemplates[marker.Name] or marker
					end
				end
			end
		end
	end

	return templates, fallback, canvasSize, markerTemplates
end

local function firstExitLine(shiftingFrame)
	for _, child in ipairs(shiftingFrame:GetChildren()) do
		if isElement(child) then
			local exits = child:FindFirstChild("Exits")
			if exits then
				for _, line in ipairs(exits:GetChildren()) do
					return line
				end
			end
		end
	end
	return nil
end

local function firstEntranceLink(shiftingFrame)
	for _, child in ipairs(shiftingFrame:GetChildren()) do
		if isElement(child) then
			local entrances = child:FindFirstChild("Entrances")
			if entrances then
				for _, link in ipairs(entrances:GetChildren()) do
					if link:IsA("ObjectValue") then
						return link
					end
				end
			end
		end
	end
	return nil
end

local function applyMarkers(element, record, markerTemplates)
	local holder = ensureChild(element, "MarkerHolder", "Folder")
	cleanChildren(holder)

	for _, id in ipairs(record.markers) do
		local markerName = MARKER_NAMES[id]
		local template = markerTemplates[markerName]

		if template then
			local clone = template:Clone()
			clone.Parent = holder
		elseif markerName then
			local marker = Instance.new("Frame")
			marker.Name = markerName
			marker.BackgroundTransparency = 1
			marker.Size = UDim2.fromOffset(10, 10)
			marker.Parent = holder
		end
	end
end

local function createElement(record, shiftingFrame, templates, fallback, canvasSize, markerTemplates)
	local template = templates[record.key] or fallback
	if not template then
		return nil, "the map library is empty, open the map once so your dreams load"
	end

	local element = template:Clone()
	element.Name = record.placeId == "CUSTOM" and "CUSTOM" or tostring(record.placeId)
	element.Visible = true
	-- this map has no limits on where a square can sit, so the saved coordinates
	-- go in untouched, even when they are negative or past the canvas edge. the
	-- exact scale and offset win when the export has them, so a square lands on
	-- the same pixels rather than only the same fraction of a different canvas
	if record.scaleOffset then
		element.Position = UDim2.new(
			record.scaleOffset[1],
			record.scaleOffset[3],
			record.scaleOffset[2],
			record.scaleOffset[4]
		)
	else
		element.Position = UDim2.fromScale(record.x, record.y)
	end
	if canvasSize then
		element.Size = canvasSize
	end

	local exits = ensureChild(element, "Exits", "Folder")
	local entrances = ensureChild(element, "Entrances", "Folder")
	cleanChildren(exits)
	cleanChildren(entrances)

	local clipper = element:FindFirstChild("ImageClipper")
	if clipper then
		local border = clipper:FindFirstChild("ImageBorder")
		if border then
			border.Color = Color3.new(record.color[1], record.color[2], record.color[3])
		end

		local thumbnail = clipper:FindFirstChild("Thumbnail")
		if thumbnail and record.image ~= "" then
			pcall(function()
				thumbnail.Image = record.image
			end)
		end
	end

	local label = element:FindFirstChild("DreamLabel")
	if label and (label:IsA("TextLabel") or label:IsA("TextButton")) then
		label.Text = record.name
	else
		-- a library chip can name its label differently, so any label still showing
		-- the chip's own name gets the dream's name instead
		local templateName = tostring(template.Name)
		for _, child in ipairs(element:GetDescendants()) do
			if child:IsA("TextLabel") or child:IsA("TextButton") then
				local text = tostring(child.Text or "")
				if text == "CUSTOM" or text == templateName then
					child.Text = record.name
				end
			end
		end
	end

	local note = ensureChild(element, "NoteText", "StringValue")
	setValue(note, record.note)

	applyMarkers(element, record, markerTemplates)

	element.Parent = shiftingFrame
	return element
end

local function linkExit(source, target, template, counter)
	local exits = source:FindFirstChild("Exits")
	if not exits then
		return false
	end

	local line = template and template:Clone() or Instance.new("Frame")
	if not template then
		line.Name = "Line" .. tostring(counter)
		line.BackgroundTransparency = 1
		line.Size = UDim2.fromOffset(1, 1)
	end
	line.Parent = exits

	local value = line:FindFirstChild("Exit") or ensureChild(line, "Exit", "ObjectValue")
	pcall(function()
		value.Value = target
	end)

	return true
end

local function linkEntrance(target, source, template)
	local entrances = target:FindFirstChild("Entrances")
	if not entrances then
		return false
	end

	local link = template and template:Clone() or Instance.new("ObjectValue")
	if not template then
		link.Name = "Entrance"
	end
	link.Parent = entrances

	pcall(function()
		link.Value = source
	end)

	return true
end

local function removeAllMapped(shiftingFrame)
	local removed = 0
	for _, child in ipairs(shiftingFrame:GetChildren()) do
		if isElement(child) then
			child:Destroy()
			removed = removed + 1
		end
	end
	return removed
end

local function countDuplicateSquares(shiftingFrame)
	local seen, duplicates = {}, 0
	for _, entry in ipairs(canvasElements(shiftingFrame)) do
		local key = keyOf(entry.placeId, entry.name)
		if seen[key] then
			duplicates = duplicates + 1
		else
			seen[key] = true
		end
	end
	return duplicates
end

-- keeps the first square on the canvas for each dream, moves the extra copies'
-- exits onto the one that stays, and repoints every entrance that led into a
-- copy, so nothing points at a square that is about to go
local function removeDuplicateSquares(shiftingFrame)
	local keepers, removed, groups = {}, 0, {}

	for _, entry in ipairs(canvasElements(shiftingFrame)) do
		local key = keyOf(entry.placeId, entry.name)
		local keeper = keepers[key]

		if not keeper then
			keepers[key] = entry.instance
		else
			local duplicate = entry.instance
			local duplicateExits = duplicate:FindFirstChild("Exits")
			local keeperExits = keeper:FindFirstChild("Exits")

			if duplicateExits and keeperExits then
				for _, line in ipairs(duplicateExits:GetChildren()) do
					local value = line:FindFirstChild("Exit")
					local target = value and value.Value
					if target and target ~= keeper then
						local linked = false
						for _, existing in ipairs(keeperExits:GetChildren()) do
							local existingValue = existing:FindFirstChild("Exit")
							if existingValue and existingValue.Value == target then
								linked = true
							end
						end

						if not linked then
							local clone = line:Clone()
							clone.Parent = keeperExits
							local cloneValue = clone:FindFirstChild("Exit")
							if cloneValue then
								pcall(function()
									cloneValue.Value = target
								end)
							end
						end
					end
				end
			end

			for _, other in ipairs(shiftingFrame:GetDescendants()) do
				if other:IsA("ObjectValue") and other.Value == duplicate then
					pcall(function()
						other.Value = keeper
					end)
				end
			end

			duplicate:Destroy()
			removed = removed + 1
			groups[key] = (groups[key] or 0) + 1
		end
	end

	return removed, groups
end

-- the panel up top counts what is mapped, and the tool only refreshes it when it
-- adds a square itself, so the count is nudged after every change we make
local function updateMappedCount(mapGui, shiftingFrame)
	local count = #canvasElements(shiftingFrame)
	local updated = 0

	local roots = { mapGui }
	local playerGui = getPlayerGui()
	if playerGui and playerGui ~= mapGui then
		table.insert(roots, playerGui)
	end

	for _, root in ipairs(roots) do
		for _, child in ipairs(root:GetDescendants()) do
			if child:IsA("TextLabel") or child:IsA("TextButton") then
				local name = tostring(child.Name):lower()
				local text = tostring(child.Text or "")
				local lower = text:lower()

				local isCount = name:find("count", 1, true)
					or name:find("mapped", 1, true)
					or name:find("places", 1, true)
					or name:find("placed", 1, true)
					or lower:find("mapped", 1, true)
					or lower:find("places", 1, true)

				if isCount and text:find("%d") then
					local replaced, changes = text:gsub("%d+", tostring(count), 1)
					if changes > 0 and replaced ~= text then
						child.Text = replaced
						updated = updated + 1
					end
				end
			elseif child:IsA("IntValue") or child:IsA("NumberValue") or child:IsA("StringValue") then
				local name = tostring(child.Name):lower()
				if name:find("count", 1, true) or name:find("mapped", 1, true) or name:find("places", 1, true) then
					if child:IsA("StringValue") then
						pcall(function()
							child.Value = tostring(count)
						end)
					else
						pcall(function()
							child.Value = count
						end)
					end
					updated = updated + 1
				end
			end
		end
	end

	return count, updated
end

local function inject(shiftingFrame, mapGui, records, library, clearFirst)
	local kept, duplicates, resolve = dedupe(records)
	local templates, fallback, canvasSize, markerTemplates = collectTemplates(shiftingFrame, mapGui)
	local exitTemplate = firstExitLine(shiftingFrame)
	local entranceTemplate = firstEntranceLink(shiftingFrame)

	local removed = clearFirst and removeAllMapped(shiftingFrame) or 0
	if not fallback then
		return 0, 0, #duplicates, removed, 0, "the map library is empty, open the map once so your dreams load"
	end

	local placed = {}
	local made = 0

	for _, record in ipairs(kept) do
		local element = createElement(record, shiftingFrame, templates, fallback, canvasSize, markerTemplates)
		if element then
			placed[record] = element
			made = made + 1
		end
	end

	local links = 0
	for _, record in ipairs(kept) do
		local source = placed[record]
		if source then
			for _, reference in ipairs(record.exits) do
				local targetRecord = resolve[reference]
				local target = targetRecord and placed[targetRecord]
				if target and target ~= source then
					if linkExit(source, target, exitTemplate, links + 1) then
						linkEntrance(target, source, entranceTemplate)
						links = links + 1
					end
				end
			end
		end
	end

	-- dreams that were saved but never placed still come across, into the first
	-- free squares, so an import loses nothing the library had
	local extras = libraryExtras(records, library)
	local occupied = {}
	for _, entry in ipairs(canvasElements(shiftingFrame)) do
		table.insert(occupied, { x = entry.x, y = entry.y })
	end

	-- saved dreams get spaced by the size of a real square, so they do not land
	-- on top of each other or on top of the squares that were just placed
	local stepX, stepY = 0.12, 0.12
	if canvasSize then
		local area = shiftingFrame.AbsoluteSize
		if area.X > 0 then
			stepX = math.max(0.12, canvasSize.X.Scale + canvasSize.X.Offset / area.X + 0.02)
		end
		if area.Y > 0 then
			stepY = math.max(0.12, canvasSize.Y.Scale + canvasSize.Y.Offset / area.Y + 0.02)
		end
	end

	local spots = freeSpots(#extras, occupied, stepX, stepY)
	local extrasMade = 0

	for index, entry in ipairs(extras) do
		local spot = spots[index]
		if spot then
			local element = createElement(
				cloneRecordAt(entry, spot[1], spot[2]),
				shiftingFrame,
				templates,
				fallback,
				canvasSize,
				markerTemplates
			)
			if element then
				extrasMade = extrasMade + 1
			end
		end
	end

	return made, links, #duplicates, removed, extrasMade
end

local function shortName(path)
	return (tostring(path):gsub("^.*[\\/]", ""))
end

local function listExports()
	local found = {}
	if type(listfiles) ~= "function" then
		return found
	end

	local ok, listing = pcall(listfiles, EXPORT_FOLDER)
	if not ok or type(listing) ~= "table" then
		return found
	end

	for _, path in ipairs(listing) do
		local lower = tostring(path):lower()
		if lower:sub(-4) == ".txt" or lower:sub(-5) == ".json" then
			table.insert(found, tostring(path))
		end
	end

	table.sort(found)

	-- file names start with the date, so the newest is the last one
	local newest = {}
	for index = #found, 1, -1 do
		table.insert(newest, found[index])
	end
	return newest
end

local function readExport(path)
	if type(readfile) ~= "function" then
		return nil, nil, "this executor has no readfile"
	end

	local ok, text = pcall(readfile, path)
	if not ok or type(text) ~= "string" then
		return nil, nil, "could not read " .. shortName(path)
	end

	local records, library = parseText(text)
	if not records or #records == 0 then
		return nil, library, "no elements in " .. shortName(path)
	end

	return records, library
end

local ui = {}
local state = { files = {}, path = nil, records = nil, library = {}, extras = 0, duplicateCount = 0 }

local function say(message)
	print("[map-injector] " .. message)
	if ui.log then
		ui.log.Text = message
	end
end

local function updateStatus()
	if not ui.status then
		return
	end

	if not state.records then
		ui.status.Text = "no export loaded :: pick one above or press export now"
	else
		local connections = 0
		for _, record in ipairs(state.records) do
			connections = connections + #record.exits
		end

		local text = string.format(
			"%s :: %d elements :: %d connections",
			shortName(state.path),
			#state.records,
			connections
		)

		if state.duplicateCount > 0 then
			text = text .. string.format(" :: %d dupes", state.duplicateCount)
		end

		if state.extras > 0 then
			text = text .. string.format(" :: %d saved not placed", state.extras)
		end

		ui.status.Text = text
	end
end

local function updateDupeButton()
	if not ui.dupe then
		return
	end

	local canvasDupes = 0
	local mapGui = findMapGui()
	local shiftingFrame = mapGui and deepFind(mapGui, "ShiftingFrame")
	if shiftingFrame then
		canvasDupes = countDuplicateSquares(shiftingFrame)
	end

	ui.dupe.Visible = state.duplicateCount > 0 or canvasDupes > 0
end

local function loadSelected()
	state.records = nil
	state.library = {}
	state.extras = 0
	state.duplicateCount = 0

	if not state.path then
		updateStatus()
		return
	end

	local records, library, problem = readExport(state.path)
	if not records then
		say(problem)
		updateStatus()
		return
	end

	state.records = records
	state.library = library or {}
	state.extras = #libraryExtras(records, state.library)
	local _, duplicates = dedupe(records)
	state.duplicateCount = #duplicates
	updateStatus()
end

local function refreshFiles()
	if not ui.list then
		return
	end

	for _, child in ipairs(ui.list:GetChildren()) do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end

	state.files = listExports()

	if #state.files == 0 then
		state.path = nil
		state.records = nil
		state.library = {}
		state.extras = 0
		state.duplicateCount = 0
		ui.list.CanvasSize = UDim2.fromOffset(0, 0)
		say("no exports in workspace/" .. EXPORT_FOLDER .. " :: press export now")
		updateStatus()
		updateDupeButton()
		return
	end

	local exists = false
	for _, path in ipairs(state.files) do
		if path == state.path then
			exists = true
		end
	end
	if not exists then
		state.path = state.files[1]
	end

	local width = math.max(120, ui.list.AbsoluteSize.X - 8)
	local y = 0

	for _, path in ipairs(state.files) do
		local button = ui.button(ui.list, shortName(path), 0, y, width, 22)
		button.Name = "file"
		if path == state.path then
			button.TextColor3 = COLORS.mauve
		end
		button.MouseButton1Click:Connect(function()
			state.path = path
			refreshFiles()
		end)
		y = y + 24
	end

	ui.list.CanvasSize = UDim2.fromOffset(0, y)
	loadSelected()
	updateDupeButton()
end

local function canTouchCanvas()
	local mapGui = findMapGui()
	if not mapGui then
		say("no map gui :: equip the map tool and open the map once (C)")
		return nil, nil
	end

	local shiftingFrame = deepFind(mapGui, "ShiftingFrame")
	if not shiftingFrame then
		say("the map canvas is not loaded :: open the map once (C)")
		return nil, nil
	end

	return mapGui, shiftingFrame
end

local function actionExport()
	if type(game.HttpGet) ~= "function" then
		say("this executor has no game:HttpGet")
		return
	end

	local fetched, source = pcall(game.HttpGet, game, EXPORTER_URL)
	if not fetched or type(source) ~= "string" then
		say("could not fetch the exporter :: run map-exporter.lua yourself")
		return
	end

	local loader = loadstring or load
	local chunk, problem = loader(source)
	if not chunk then
		say("could not load the exporter :: " .. tostring(problem))
		return
	end

	local ran, runProblem = pcall(chunk)
	if not ran then
		say("the exporter stopped :: " .. tostring(runProblem))
		return
	end

	refreshFiles()
	say("export finished :: the newest file is selected")
end

local function actionInject()
	local mapGui, shiftingFrame = canTouchCanvas()
	if not shiftingFrame then
		return
	end

	if not state.records then
		say("no export loaded :: pick one above or press export now")
		return
	end

	local existing = #canvasElements(shiftingFrame)
	local made, links, skipped, _, extrasMade, problem =
		inject(shiftingFrame, mapGui, state.records, state.library, false)

	if problem then
		say(problem)
		return
	end

	local mapped, counterUpdated = updateMappedCount(mapGui, shiftingFrame)

	local message = string.format("placed %d squares :: %d connections", made, links)
	if extrasMade > 0 then
		message = message .. string.format(" :: %d saved dreams from the library", extrasMade)
	end
	if skipped > 0 then
		message = message .. string.format(" :: skipped %d dupes", skipped)
	end
	if counterUpdated > 0 then
		message = message .. string.format(" :: counter shows %d", mapped)
	else
		message = message .. " :: could not find the mapped counter"
	end
	if existing > 0 then
		message = message .. " :: the canvas already had squares, replace map swaps them out"
	end

	say(message)
	updateDupeButton()
end

local function actionReplace()
	local mapGui, shiftingFrame = canTouchCanvas()
	if not shiftingFrame then
		return
	end

	if not state.records then
		say("no export loaded :: pick one above or press export now")
		return
	end

	local made, links, skipped, removed, extrasMade, problem =
		inject(shiftingFrame, mapGui, state.records, state.library, true)

	if problem then
		say(problem)
		return
	end

	local mapped, counterUpdated = updateMappedCount(mapGui, shiftingFrame)

	local message = string.format("removed %d squares :: placed %d :: %d connections", removed, made, links)
	if extrasMade > 0 then
		message = message .. string.format(" :: %d saved dreams from the library", extrasMade)
	end
	if skipped > 0 then
		message = message .. string.format(" :: skipped %d dupes", skipped)
	end
	if counterUpdated > 0 then
		message = message .. string.format(" :: counter shows %d", mapped)
	else
		message = message .. " :: could not find the mapped counter"
	end

	say(message)
	updateDupeButton()
end

local function actionRemoveAll()
	local mapGui, shiftingFrame = canTouchCanvas()
	if not shiftingFrame then
		return
	end

	local removed = removeAllMapped(shiftingFrame)
	local mapped, counterUpdated = updateMappedCount(mapGui, shiftingFrame)

	local message = string.format("removed %d mapped squares", removed)
	if counterUpdated > 0 then
		message = message .. string.format(" :: counter shows %d", mapped)
	end

	say(message)
	updateDupeButton()
end

local function actionRemoveDupes()
	local mapGui, shiftingFrame = canTouchCanvas()
	if not shiftingFrame then
		return
	end

	local removed, groups = removeDuplicateSquares(shiftingFrame)
	if removed == 0 then
		say("no duplicate squares on the map")
		return
	end

	updateMappedCount(mapGui, shiftingFrame)

	local parts = {}
	for key, count in pairs(groups) do
		table.insert(parts, string.format("%s x%d", key, count + 1))
	end
	table.sort(parts)

	say(string.format("removed %d duplicate squares :: kept one of %s", removed, table.concat(parts, " :: ")))
	updateDupeButton()
end

local function findSaveButton(root)
	for _, child in ipairs(root:GetDescendants()) do
		if child:IsA("TextButton") and child.Visible then
			local text = tostring(child.Text):lower()
			local name = tostring(child.Name):lower()
			if text:find("save", 1, true) or name:find("save", 1, true) then
				return child
			end
		end
	end
	return nil
end

local function actionSave()
	local mapGui = findMapGui()
	if not mapGui then
		say("no map gui :: equip the map tool and open the map once (C)")
		return
	end

	local button = findSaveButton(mapGui)
	if not button then
		say("could not find the map's save button :: press it yourself")
		return
	end

	if type(firesignal) ~= "function" then
		say("this executor has no firesignal :: press the map's save button yourself")
		return
	end

	local pressed = pcall(firesignal, button.MouseButton1Click)
	if pressed then
		say("pressed the map's save button")
	else
		say("could not press the map's save button :: press it yourself")
	end
end

local function makeButton(parent, text, x, y, width, height)
	local button = Instance.new("TextButton")
	button.Name = "action"
	button.Text = text
	button.Font = FONT
	button.TextSize = 11
	button.TextColor3 = COLORS.text
	button.BackgroundColor3 = COLORS.panel
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.TextXAlignment = Enum.TextXAlignment.Left
	button.Size = UDim2.fromOffset(width, height)
	button.Position = UDim2.fromOffset(x, y)
	button.Parent = parent

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Color = COLORS.stroke
	stroke.Thickness = 1
	stroke.Parent = button

	button.MouseEnter:Connect(function()
		button.BackgroundColor3 = COLORS.base
	end)
	button.MouseLeave:Connect(function()
		button.BackgroundColor3 = COLORS.panel
	end)

	return button
end

local function makeLabel(parent, text, x, y, width, height, color, textSize)
	local label = Instance.new("TextLabel")
	label.Text = text
	label.Font = FONT
	label.TextSize = textSize or 11
	label.TextColor3 = color or COLORS.text
	label.BackgroundTransparency = 1
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.TextWrapped = true
	label.Size = UDim2.fromOffset(width, height)
	label.Position = UDim2.fromOffset(x, y)
	label.Parent = parent
	return label
end

local function buildGui()
	local playerGui = getPlayerGui()
	if not playerGui then
		return false
	end

	local previous = playerGui:FindFirstChild("MapInjector")
	if previous then
		previous:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "MapInjector"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 90
	screenGui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Size = UDim2.fromOffset(360, 404)
	panel.Position = UDim2.new(0.5, -180, 0, 90)
	panel.BackgroundColor3 = COLORS.base
	panel.BorderSizePixel = 0
	panel.Active = true
	panel.Draggable = true
	panel.Parent = screenGui

	local stroke = Instance.new("UIStroke")
	stroke.Color = COLORS.stroke
	stroke.Thickness = 1
	stroke.Parent = panel

	local title = makeLabel(panel, "map injector", 12, 10, 300, 18, COLORS.mauve, 13)
	title.TextYAlignment = Enum.TextYAlignment.Center

	local close = makeButton(panel, "x", 330, 10, 18, 18)
	close.TextXAlignment = Enum.TextXAlignment.Center
	close.MouseButton1Click:Connect(function()
		screenGui:Destroy()
	end)

	ui.status = makeLabel(panel, "no export loaded", 12, 34, 336, 30, COLORS.muted, 11)

	local list = Instance.new("ScrollingFrame")
	list.Name = "Files"
	list.Size = UDim2.fromOffset(336, 96)
	list.Position = UDim2.fromOffset(12, 70)
	list.BackgroundColor3 = COLORS.panel
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 3
	list.ScrollBarImageColor3 = COLORS.stroke
	list.CanvasSize = UDim2.fromOffset(0, 0)
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.Parent = panel
	ui.list = list

	local exportButton = makeButton(panel, "export now", 12, 176, 336, 24)
	exportButton.MouseButton1Click:Connect(actionExport)

	local injectButton = makeButton(panel, "inject", 12, 206, 163, 24)
	injectButton.MouseButton1Click:Connect(actionInject)

	local replaceButton = makeButton(panel, "replace map", 185, 206, 163, 24)
	replaceButton.MouseButton1Click:Connect(actionReplace)

	local removeAllButton = makeButton(panel, "remove all mapped", 12, 236, 163, 24)
	removeAllButton.MouseButton1Click:Connect(actionRemoveAll)

	ui.dupe = makeButton(panel, "remove all dupes", 185, 236, 163, 24)
	ui.dupe.Visible = false
	ui.dupe.MouseButton1Click:Connect(actionRemoveDupes)

	local refreshButton = makeButton(panel, "refresh list", 12, 266, 163, 24)
	refreshButton.MouseButton1Click:Connect(function()
		refreshFiles()
		say("list refreshed")
	end)

	local saveButton = makeButton(panel, "save map", 185, 266, 163, 24)
	saveButton.MouseButton1Click:Connect(actionSave)

	ui.log = makeLabel(panel, "pick an export, then inject it or replace the map with it.", 12, 300, 336, 92, COLORS.muted, 11)

	ui.button = makeButton
	return true
end

-- ===== run =====
local mapGui = findMapGui()
if not mapGui then
	warn("[map-injector] could not find the map gui. equip the map tool and open the map once, then run this again.")
	return
end

local shiftingFrame = deepFind(mapGui, "ShiftingFrame")
if not shiftingFrame then
	warn("[map-injector] the map gui is loaded but has no map canvas yet. open the map once (C) so your data loads, then run this again.")
	return
end

if not buildGui() then
	warn("[map-injector] could not build the panel.")
	return
end

refreshFiles()
print("[map-injector] ready :: pick an export and inject it, or replace the map with it")
