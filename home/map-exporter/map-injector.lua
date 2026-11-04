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
		remove all dupes    duplicates are cleared on their own now; this only shows
		                    if any are found and runs the same clean again
		save map            presses the map tool's own save button

	usage:
		1. equip the map tool and open the map once (C) so your data loads
		2. run this script:
		   loadstring(game:HttpGet("https://raw.githubusercontent.com/floams/troggy/refs/heads/main/home/map-exporter/map-injector.lua"))()
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
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
		-- two copies of a custom dream can differ only in spacing or case, and
		-- those are still the same dream
		local clean = tostring(name or ""):lower()
		clean = clean:gsub("^%s+", "")
		clean = clean:gsub("%s+$", "")
		return "CUSTOM:" .. clean
	end
	return text
end

-- the same world can be mapped more than once at different spots, so two squares
-- are only duplicates when they are the same dream in the same place
local function spotKey(key, x, y)
	return string.format("%s@%.3f,%.3f", tostring(key or ""), tonumber(x) or 0, tonumber(y) or 0)
end

-- the squares already on the canvas, by dream, so a dream that is already down
-- still gets its connectors instead of being skipped and left unwired
local function existingElements(shiftingFrame)
	local found = {}
	for _, entry in ipairs(canvasElements(shiftingFrame)) do
		local key = spotKey(keyOf(entry.placeId, entry.name), entry.x, entry.y)
		if not found[key] then
			found[key] = entry.instance
		end
	end
	return found
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
		local key = spotKey(record.key, record.x, record.y)
		local keptRecord = byKey[key]
		if keptRecord then
			resolve[record.index] = keptRecord
			table.insert(duplicates, record)
		else
			byKey[key] = record
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
	local templates, fallback = {}, nil
	local names, byName = {}, {}
	local markerTemplates = {}

	local function remember(child)
		local key = templateKey(child)
		templates[key] = templates[key] or child
		fallback = fallback or child

		local label = child:FindFirstChild("DreamLabel")
		local text = label and tostring(label.Text or "") or ""
		if text ~= "" and not names[key] then
			names[key] = text
		end

		-- a custom square is named after a world, so a world that goes by that name
		-- can stand in for it instead of leaving another nameless CUSTOM behind
		if tonumber(child.Name) and text ~= "" and not byName[text:lower()] then
			byName[text:lower()] = child
		end

		local holder = child:FindFirstChild("MarkerHolder")
		if holder then
			for _, marker in ipairs(holder:GetChildren()) do
				markerTemplates[marker.Name] = markerTemplates[marker.Name] or marker
			end
		end
	end

	for _, child in ipairs(shiftingFrame:GetChildren()) do
		if isElement(child) then
			remember(child)
		end
	end

	local inventory = deepFind(mapGui, "InventoryFrame")
	if inventory then
		for _, child in ipairs(inventory:GetDescendants()) do
			if child:IsA("GuiObject") and child:FindFirstChild("ImageClipper") then
				remember(child)
			end
		end
	end

	return templates, fallback, markerTemplates, names, byName
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

-- the map's own blank connection, so its arrow and stroke come along
local function lineTemplate(mapGui, shiftingFrame)
	local templates = mapGui and deepFind(mapGui, "Templates")
	local line = templates and templates:FindFirstChild("LineElement")
	if line then
		return line
	end
	return firstExitLine(shiftingFrame)
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

-- the map's own numbers, taken from its MapScript: a square is a fixed fraction
-- of the canvas at a fraction of the canvas, and zooming resizes the canvas in
-- pixels, so a square written this way zooms with the map like the map's own do
local SQUARE_SIZE = UDim2.fromScale(0.07944915254237288, 0.1482213438735178)

-- the map's own line maths: length and midpoint in the source square's pixels,
-- turned into fractions of it, plus the angle that makes the bar follow the line
local function drawLine(line, x1, y1, x2, y2)
	if not line then
		return
	end

	local parent = line.Parent
	if parent and parent.ClassName == "Folder" then
		parent = parent.Parent
	end
	if not parent then
		return
	end

	local size = parent.AbsoluteSize
	if size.X <= 0 or size.Y <= 0 then
		return
	end

	local length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)

	line.Size = UDim2.fromScale(length / size.X, 0.05)
	line.Position = UDim2.fromScale(((x1 + x2) / 2) / size.X, ((y1 + y2) / 2) / size.Y)
	line.Rotation = math.deg(math.atan2(y2 - y1, x2 - x1))
end

-- a connection runs from the middle of the square that exits to the middle of the
-- square it points at, both measured against the canvas
local function drawLineBtwnElements(line, source, target, shiftingFrame)
	if not line or not source or not target or not shiftingFrame then
		return
	end

	local canvas = shiftingFrame.AbsoluteSize
	if canvas.X <= 0 or canvas.Y <= 0 then
		return
	end

	local mine = source.Position
	local theirs = target.Position

	local fromX = mine.X.Scale * canvas.X + mine.X.Offset
	local fromY = mine.Y.Scale * canvas.Y + mine.Y.Offset
	local toX = theirs.X.Scale * canvas.X + theirs.X.Offset
	local toY = theirs.Y.Scale * canvas.Y + theirs.Y.Offset

	drawLine(
		line,
		0.5 * source.AbsoluteSize.X,
		0.5 * source.AbsoluteSize.Y,
		toX - fromX + 0.5 * target.AbsoluteSize.X,
		toY - fromY + 0.5 * target.AbsoluteSize.Y
	)
end

-- what the map does to a square once it is down: the size it always uses, no
-- faded out look, and its markers showing again
local function normalizeElement(element)
	if not element then
		return
	end

	local clipper = element:FindFirstChild("ImageClipper")
	if clipper then
		local border = clipper:FindFirstChild("ImageBorder")
		if border then
			border.Transparency = 0
		end

		local thumbnail = clipper:FindFirstChild("Thumbnail")
		if thumbnail then
			thumbnail.ImageTransparency = 0
			thumbnail.BackgroundTransparency = 0
		end
	end

	local label = element:FindFirstChild("DreamLabel")
	if label then
		label.TextTransparency = 0
	end

	element.Size = SQUARE_SIZE

	local holder = element:FindFirstChild("MarkerHolder")
	if holder then
		local markers = 0
		for _, marker in ipairs(holder:GetChildren()) do
			if marker.ClassName ~= "UIListLayout" then
				marker.Size = UDim2.fromScale(1, 1)
				markers = markers + 1
			end
		end
		holder.Visible = markers > 0
	end
end

local function createElement(record, shiftingFrame, templates, fallback, markerTemplates, names, byName)
	local key = record.key
	local name = tostring(record.name or "")
	local lower = name:lower()

	-- a custom square that carries a world's name becomes that world, so it brings
	-- the real place id, label and picture with it
	local world = nil
	if tostring(record.placeId) == "CUSTOM" and lower ~= "" then
		world = byName[lower]
	end

	local template = world or templates[key] or fallback
	if not template then
		return nil, "the map library is empty, open the map once so your dreams load"
	end

	local element = template:Clone()
	element.Name = world and world.Name or (record.placeId == "CUSTOM" and "CUSTOM" or tostring(record.placeId))
	element.Visible = true

	-- the saved spot is a fraction of the canvas, which is exactly how the map
	-- itself puts a square down, so this map has no limits and the zoom carries
	-- the square with the map instead of stretching it
	element.Position = UDim2.fromScale(record.x, record.y)

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

		-- a real world already has its own picture, so only a custom square's own
		-- image is allowed to replace it
		local thumbnail = clipper:FindFirstChild("Thumbnail")
		if thumbnail and not world and record.image ~= "" then
			pcall(function()
				thumbnail.Image = record.image
			end)
		end
	end

	local shown = name
	if shown == "" or lower == "custom" then
		local worldKey = world and templateKey(world) or key
		shown = names[worldKey] or ""
		if shown == "" and type(record.placeId) == "number" then
			shown = tostring(record.placeId)
		end
	end

	local label = element:FindFirstChild("DreamLabel")
	if label and (label:IsA("TextLabel") or label:IsA("TextButton")) then
		if shown ~= "" then
			label.Text = shown
		end
	else
		-- a library chip can name its label differently, so any label still showing
		-- the chip's own name gets the dream's name instead
		local templateName = tostring(template.Name)
		for _, child in ipairs(element:GetDescendants()) do
			if child:IsA("TextLabel") or child:IsA("TextButton") then
				local text = tostring(child.Text or "")
				if shown ~= "" and (text == "CUSTOM" or text == templateName) then
					child.Text = shown
				end
			end
		end
	end

	local note = ensureChild(element, "NoteText", "StringValue")
	setValue(note, record.note)

	applyMarkers(element, record, markerTemplates)

	element.Parent = shiftingFrame
	normalizeElement(element)

	return element
end

local function linkExit(source, target, template, shiftingFrame)
	local exits = source:FindFirstChild("Exits")
	if not exits then
		return false
	end

	-- one line per connection, so a second inject cannot stack beams on beams
	for _, existing in ipairs(exits:GetChildren()) do
		local existingValue = existing:FindFirstChild("Exit")
		if existingValue and existingValue.Value == target then
			return false
		end
	end

	local line = template and template:Clone() or Instance.new("Frame")
	if not template then
		line.Name = "LineElement"
		line.BackgroundTransparency = 1
		line.Size = UDim2.fromOffset(1, 1)
	end

	line.Visible = true
	line.Parent = exits

	local value = line:FindFirstChild("Exit") or ensureChild(line, "Exit", "ObjectValue")
	pcall(function()
		value.Value = target
	end)

	-- without this the line exists but has no length or angle, which is why the
	-- beams never showed up before
	drawLineBtwnElements(line, source, target, shiftingFrame)

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
		local key = spotKey(keyOf(entry.placeId, entry.name), entry.x, entry.y)
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
		local key = spotKey(keyOf(entry.placeId, entry.name), entry.x, entry.y)
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

-- the counter the map shows, so a clear can put it back to 0 every time
local counterObjects = {}

local function setCounterOn(child, count)
	if not child or not child.Parent then
		return false
	end

	if child:IsA("TextLabel") or child:IsA("TextButton") then
		local text = tostring(child.Text or "")
		if not text:find("%d") then
			return false
		end

		local replaced, changes = text:gsub("%d+", tostring(count), 1)
		if changes > 0 and replaced ~= text then
			child.Text = replaced
			return true
		end
		return false
	end

	local ok = pcall(function()
		if child:IsA("StringValue") then
			child.Value = tostring(count)
		else
			child.Value = count
		end
	end)

	return ok
end

-- the counter may not be named after counting at all, so any short label that
-- already shows the number of mapped squares is treated as the counter too
local function findCountLabels(mapGui, count)
	local found = {}
	if not mapGui or not count or count <= 0 then
		return found
	end

	local words = { "mapped", "places", "place", "count", "dream", "saved", "total" }
	local number = "%f[%d]" .. tostring(count) .. "%f[%D]"

	for _, child in ipairs(mapGui:GetDescendants()) do
		if child:IsA("TextLabel") or child:IsA("TextButton") then
			local text = tostring(child.Text or "")
			local lower = text:lower()

			local looksLikeCounter = text:match("^%s*%d+%s*$") ~= nil
				or text:match("^%s*%d+%s*/%s*%d+%s*$") ~= nil

			if not looksLikeCounter then
				for _, word in ipairs(words) do
					if lower:find(word, 1, true) then
						looksLikeCounter = true
						break
					end
				end
			end

			if looksLikeCounter and #text <= 40 and text:find(number) then
				table.insert(found, child)
			end
		end
	end

	return found
end

local function rememberCounter(child)
	for _, known in ipairs(counterObjects) do
		if known == child then
			return
		end
	end
	table.insert(counterObjects, child)
end

-- the panel up top counts what is mapped, and the tool only refreshes it when it
-- adds a square itself, so the count is nudged after every change we make. a
-- count can be forced, which is how remove all mapped lands on exactly 0
local function updateMappedCount(mapGui, shiftingFrame, value)
	local count = value or #canvasElements(shiftingFrame)
	local updated = 0

	for _, child in ipairs(counterObjects) do
		if setCounterOn(child, count) then
			updated = updated + 1
		end
	end

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

				if isCount then
					rememberCounter(child)
					if setCounterOn(child, count) then
						updated = updated + 1
					end
				end
			elseif child:IsA("IntValue") or child:IsA("NumberValue") or child:IsA("StringValue") then
				local name = tostring(child.Name):lower()
				if name:find("count", 1, true) or name:find("mapped", 1, true) or name:find("places", 1, true) then
					rememberCounter(child)
					if setCounterOn(child, count) then
						updated = updated + 1
					end
				end
			end
		end
	end

	return count, updated
end

local function inject(shiftingFrame, mapGui, records, library, clearFirst)
	local kept, duplicates, resolve = dedupe(records)

	-- the map has to be cleared before anything is cloned from it, or the clones
	-- come from squares that no longer exist
	local removed = clearFirst and removeAllMapped(shiftingFrame) or 0
	local onCanvas = clearFirst and {} or existingElements(shiftingFrame)

	local templates, fallback, markerTemplates, names, byName = collectTemplates(shiftingFrame, mapGui)
	local exitTemplate = lineTemplate(mapGui, shiftingFrame)
	local entranceTemplate = firstEntranceLink(shiftingFrame)

	if not fallback then
		return 0, 0, #duplicates, removed, 0, "the map library is empty, open the map once so your dreams load"
	end

	local placed = {}
	local made = 0

	for _, record in ipairs(kept) do
		local element = onCanvas[spotKey(record.key, record.x, record.y)]
		if element then
			-- already down, so it keeps its square and only needs its connectors
			table.insert(duplicates, record)
			placed[record] = element
		else
			local created = createElement(record, shiftingFrame, templates, fallback, markerTemplates, names, byName)
			if created then
				placed[record] = created
				made = made + 1
			end
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
					if linkExit(source, target, exitTemplate, shiftingFrame) then
						linkEntrance(target, source, entranceTemplate)
						links = links + 1
					end
				end
			end
		end
	end

	local extrasMade = 0

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

-- duplicates are never left lying around: wherever the canvas is touched, one
-- copy of each dream stays, the spare copies' exits move onto it, every entrance
-- is repointed, and the spares are destroyed
local function clearDuplicates(mapGui, shiftingFrame, quiet)
	local removed, groups = removeDuplicateSquares(shiftingFrame)
	if removed == 0 then
		if not quiet then
			say("no duplicate squares on the map")
		end
		return 0
	end

	updateMappedCount(mapGui, shiftingFrame)

	if not quiet then
		local parts = {}
		for key, count in pairs(groups) do
			table.insert(parts, string.format("%s x%d", key, count + 1))
		end
		table.sort(parts)

		say(string.format("removed %d duplicate squares :: kept one of %s", removed, table.concat(parts, " :: ")))
	end

	return removed
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

	local dupes = clearDuplicates(mapGui, shiftingFrame, true)
	local mapped, counterUpdated = updateMappedCount(mapGui, shiftingFrame)

	local message = string.format("placed %d squares :: %d connections", made, links)
	if extrasMade > 0 then
		message = message .. string.format(" :: %d saved dreams from the library", extrasMade)
	end
	if skipped > 0 then
		message = message .. string.format(" :: skipped %d dupes", skipped)
	end
	if dupes > 0 then
		message = message .. string.format(" :: removed %d dupes", dupes)
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

	local dupes = clearDuplicates(mapGui, shiftingFrame, true)
	local mapped, counterUpdated = updateMappedCount(mapGui, shiftingFrame)

	local message = string.format("removed %d squares :: placed %d :: %d connections", removed, made, links)
	if extrasMade > 0 then
		message = message .. string.format(" :: %d saved dreams from the library", extrasMade)
	end
	if skipped > 0 then
		message = message .. string.format(" :: skipped %d dupes", skipped)
	end
	if dupes > 0 then
		message = message .. string.format(" :: removed %d dupes", dupes)
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

	-- catch the labels showing the number of squares before they go, so the count
	-- can be put back to 0 even when its label is not named after counting
	local showsCount = findCountLabels(mapGui, #canvasElements(shiftingFrame))

	local removed = removeAllMapped(shiftingFrame)

	local zeroed = 0
	for _, child in ipairs(showsCount) do
		if setCounterOn(child, 0) then
			zeroed = zeroed + 1
		end
	end

	local mapped, counterUpdated = updateMappedCount(mapGui, shiftingFrame, 0)

	local message = string.format("removed %d mapped squares", removed)
	if zeroed + counterUpdated > 0 then
		message = message .. " :: counter 0"
	else
		message = message .. " :: counter not found"
	end

	say(message)
	updateDupeButton()
end

local function actionRemoveDupes()
	local mapGui, shiftingFrame = canTouchCanvas()
	if not shiftingFrame then
		return
	end

	clearDuplicates(mapGui, shiftingFrame, false)
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

-- the map can already be holding two copies of every dream, so it is cleaned up
-- front, before any export is even picked
local cleaned = clearDuplicates(mapGui, shiftingFrame, true)
if cleaned > 0 then
	say(string.format("cleaned %d duplicate squares already on the map", cleaned))
	updateDupeButton()
end

-- the tool may still be laying its squares out, so look again once it settles
pcall(function()
	task.wait(2)

	local gui = findMapGui()
	local frame = gui and deepFind(gui, "ShiftingFrame")
	if frame then
		local late = clearDuplicates(gui, frame, true)
		if late > 0 then
			say(string.format("cleaned %d more duplicate squares", late))
			updateDupeButton()
		end
	end
end)

print("[map-injector] ready :: pick an export and inject it, or replace the map with it")
