--[[
	map-exporter
	reads the map you have mapped (dream elements, their notes, markers and
	connections), plus every dream saved in your library even if it was never
	placed down, and writes it to your executor's workspace, in the folder
	"home map exports", as {date}-EXPORT-{time}.txt.

	this is read only. it never adds, moves, removes or saves anything on your
	map, and it never fires the map's DataRemoteEvent.

	usage:
		1. equip the map tool and open the map once (C) so your saved data loads
		2. run this script:
		   loadstring(game:HttpGet("https://raw.githubusercontent.com/floams/troggy/refs/heads/main/home/map-exporter/map-exporter.lua"))()
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

-- every run writes its own file, so an old export is never overwritten
local EXPORT_FOLDER = "home map exports"

local function exportFileName()
	return string.format("%s-EXPORT-%s.txt", os.date("%Y-%m-%d"), os.date("%H-%M-%S"))
end

local function ensureFolder(path)
	if type(isfolder) == "function" and isfolder(path) then
		return
	end
	if type(makefolder) == "function" then
		pcall(makefolder, path)
	end
end

-- marker names used by the map tool's MarkerPickerFrame
local MARKER_NAMES = { [1] = "DeadEnd", [2] = "Badge", [3] = "AltExit" }
local MARKER_IDS = { DeadEnd = 1, Badge = 2, AltExit = 3 }

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

	local backpack = LocalPlayer:FindFirstChild("Backpack")
	if backpack then
		return deepFind(backpack, "MapGui")
	end

	return nil
end

local function readMarkers(holder)
	local ids, names = {}, {}

	if not holder then
		return ids, names
	end

	for _, child in ipairs(holder:GetChildren()) do
		local id = MARKER_IDS[child.Name]
		if id then
			table.insert(ids, id)
			table.insert(names, child.Name)
		end
	end

	return ids, names
end

local function colorOf(element)
	local clipper = element:FindFirstChild("ImageClipper")
	local border = clipper and clipper:FindFirstChild("ImageBorder")

	if border then
		return border.Color
	end

	return Color3.new(1, 1, 1)
end

local function colorHex(color)
	return string.format(
		"#%02X%02X%02X",
		math.floor(color.R * 255 + 0.5),
		math.floor(color.G * 255 + 0.5),
		math.floor(color.B * 255 + 0.5)
	)
end

local function scalePosition(element, size)
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

-- the exact position as the map stores it: scale plus offset per axis, so a
-- square can be put back on the same spot even if the canvas is a different size
local function rawPosition(element)
	local position = element.Position
	return {
		position.X.Scale,
		position.Y.Scale,
		position.X.Offset,
		position.Y.Offset,
	}
end

local function readInventory(inventoryFrame)
	local library = {}
	local order = {}

	local scrolling = inventoryFrame and inventoryFrame:FindFirstChild("ScrollingFrame")
	if not scrolling then
		return library, order
	end

	for _, child in ipairs(scrolling:GetChildren()) do
		if child.Name == "CUSTOM" or tonumber(child.Name) then
			local label = child:FindFirstChild("DreamLabel")
			local clipper = child:FindFirstChild("ImageClipper")
			local thumbnail = clipper and clipper:FindFirstChild("Thumbnail")
			local noteValue = child:FindFirstChild("NoteText")
			local markerIds, markerNames = readMarkers(child:FindFirstChild("MarkerHolder"))

			local entry = {
				placeId = child.Name == "CUSTOM" and "CUSTOM" or tonumber(child.Name),
				name = label and label.Text or "",
				image = thumbnail and thumbnail.Image or "",
				note = noteValue and tostring(noteValue.Value) or "",
				markers = markerIds,
				markerNames = markerNames,
			}

			library[entry.placeId] = entry
			table.insert(order, entry)
		end
	end

	table.sort(order, function(a, b)
		return tostring(a.placeId) < tostring(b.placeId)
	end)

	return library, order
end

local function readElements(shiftingFrame, library)
	local records = {}
	local byInstance = {}
	local canvasSize = shiftingFrame.AbsoluteSize

	for order, child in ipairs(shiftingFrame:GetChildren()) do
		local exits = child:FindFirstChild("Exits")
		local entrances = child:FindFirstChild("Entrances")
		local isElement = child:IsA("GuiObject")
			and child:FindFirstChild("ImageClipper") ~= nil
			and exits ~= nil
			and entrances ~= nil

		if isElement then
			local placeId = child.Name == "CUSTOM" and "CUSTOM" or (tonumber(child.Name) or child.Name)
			local label = child:FindFirstChild("DreamLabel")
			local clipper = child:FindFirstChild("ImageClipper")
			local thumbnail = clipper and clipper:FindFirstChild("Thumbnail")
			local noteValue = child:FindFirstChild("NoteText")
			local markerIds, markerNames = readMarkers(child:FindFirstChild("MarkerHolder"))
			local x, y = scalePosition(child, canvasSize)

			local record = {
				element = child,
				order = order,
				placeId = placeId,
				x = x,
				y = y,
				scaleOffset = rawPosition(child),
				color = colorOf(child),
				note = noteValue and tostring(noteValue.Value) or "",
				markers = markerIds,
				markerNames = markerNames,
			}

			record.name = label and label.Text or ""
			record.image = thumbnail and thumbnail.Image or ""

			local known = library[placeId]
			if known then
				-- the map's own label can be blank, or just say CUSTOM, even for a
				-- real place, so the library's world name fills it in
				if placeId ~= "CUSTOM" and (record.name == "" or tostring(record.name):lower() == "custom") then
					record.name = known.name
				end
				if record.name == "" then
					record.name = known.name
				end
				if record.image == "" then
					record.image = known.image
				end
				if record.note == "" then
					record.note = known.note
				end
				if #record.markers == 0 then
					record.markers = known.markers
					record.markerNames = known.markerNames
				end
			end

			-- two lines pointing at the same square are one connection, or the
			-- import would draw two beams on top of each other
			local outgoing = {}
			local seenExit = {}
			for _, line in ipairs(exits:GetChildren()) do
				local exitValue = line:FindFirstChild("Exit")
				if exitValue and exitValue:IsA("ObjectValue") and exitValue.Value then
					if not seenExit[exitValue.Value] then
						seenExit[exitValue.Value] = true
						table.insert(outgoing, exitValue.Value)
					end
				end
			end

			local incoming = {}
			local seenEntrance = {}
			for _, link in ipairs(entrances:GetChildren()) do
				if link:IsA("ObjectValue") and link.Value and not seenEntrance[link.Value] then
					seenEntrance[link.Value] = true
					table.insert(incoming, link.Value)
				end
			end

			record.exits = outgoing
			record.entrances = incoming

			table.insert(records, record)
			byInstance[child] = record
		end
	end

	table.sort(records, function(a, b)
		if a.y ~= b.y then
			return a.y < b.y
		end
		if a.x ~= b.x then
			return a.x < b.x
		end
		return a.order < b.order
	end)

	for index, record in ipairs(records) do
		record.index = index
	end

	return records, byInstance
end

local function tagOf(record)
	return string.format("[%s]", tostring(record.placeId))
end

local function buildExport(records, byInstance, library, libraryOrder)
	local lines = {}

	local placedKeys = {}
	for _, record in ipairs(records) do
		placedKeys[tostring(record.placeId)] = true
	end

	local unplaced = 0
	for _, entry in ipairs(libraryOrder) do
		if not placedKeys[tostring(entry.placeId)] then
			unplaced = unplaced + 1
		end
	end
	local function push(line)
		table.insert(lines, line or "")
	end
	local function pushf(format, ...)
		table.insert(lines, string.format(format, ...))
	end
	local function pushNote(note)
		local first = true
		for line in (note .. "\n"):gmatch("(.-)\n") do
			if first then
				push("    note: " .. line)
				first = false
			else
				push("          " .. line)
			end
		end
	end

	local connectionCount = 0
	local markerCount = 0
	local noteCount = 0

	for _, record in ipairs(records) do
		connectionCount = connectionCount + #record.exits
		markerCount = markerCount + #record.markers
		if record.note ~= "" then
			noteCount = noteCount + 1
		end
	end

	push("map-export")
	pushf("place: %s (%s)", tostring(game.PlaceId), tostring(game.Name))
	pushf("job: %s", tostring(game.JobId))
	pushf("exported: %s", os.date("!%Y-%m-%dT%H:%M:%SZ"))
	push("read from: PlayerGui.MapGui (read only, nothing was changed)")
	push("")
	pushf(
		"elements: %d   connections: %d   markers: %d   notes: %d   library dreams: %d",
		#records,
		connectionCount,
		markerCount,
		noteCount,
		#libraryOrder
	)
	push("")

	push("== MAP ELEMENTS ==")
	push("")

	for _, record in ipairs(records) do
		pushf(
			"#%d  %s  %q  at (%.4f, %.4f)  color %s",
			record.index,
			tagOf(record),
			record.name,
			record.x,
			record.y,
			colorHex(record.color)
		)

		if #record.markerNames > 0 then
			push("    markers: " .. table.concat(record.markerNames, ", "))
		end

		if record.note ~= "" then
			pushNote(record.note)
		end

		if #record.entrances > 0 then
			local parts = {}
			for _, source in ipairs(record.entrances) do
				local other = byInstance[source]
				if other then
					table.insert(parts, string.format("#%d %s %q", other.index, tagOf(other), other.name))
				else
					table.insert(parts, "[gone]")
				end
			end
			push("    from: " .. table.concat(parts, ", "))
		end

		if #record.exits > 0 then
			local parts = {}
			for _, target in ipairs(record.exits) do
				local other = byInstance[target]
				if other then
					table.insert(parts, string.format("#%d %s %q", other.index, tagOf(other), other.name))
				else
					table.insert(parts, "[gone]")
				end
			end
			push("    exits: " .. table.concat(parts, ", "))
		end

		push("")
	end

	push("== CONNECTIONS ==")
	push("")

	for _, record in ipairs(records) do
		for _, target in ipairs(record.exits) do
			local other = byInstance[target]
			local targetText = other
				and string.format("#%d %s %q", other.index, tagOf(other), other.name)
				or "[gone]"

			pushf(
				"#%d %s %q -> %s",
				record.index,
				tagOf(record),
				record.name,
				targetText
			)
		end
	end

	push("")
	push("== DREAM LIBRARY ==")
	push("")

	for _, entry in ipairs(libraryOrder) do
		pushf("%s  %q", tostring(entry.placeId), entry.name)

		if not placedKeys[tostring(entry.placeId)] then
			push("    saved, not placed")
		end

		if #entry.markerNames > 0 then
			push("    markers: " .. table.concat(entry.markerNames, ", "))
		end

		if entry.note ~= "" then
			pushNote(entry.note)
		end
	end

	push("")
	push("== RAW DATA ==")
	push("one line per element, same shape the map tool saves")
	push("")

	for _, record in ipairs(records) do
		local exitIndices = {}
		for _, target in ipairs(record.exits) do
			local other = byInstance[target]
			if other then
				table.insert(exitIndices, other.index)
			end
		end

		local payload = {
			PlaceId = record.placeId,
			ScalePosition = { record.x, record.y },
			Position = record.scaleOffset,
			Exits = exitIndices,
			Color = { record.color.R, record.color.G, record.color.B },
			Name = record.name,
			ImageId = record.image,
			Markers = record.markers,
			Note = record.note,
		}

		local encoded, json = pcall(HttpService.JSONEncode, HttpService, payload)
		if encoded then
			pushf("[%d] %s", record.index, json)
		else
			pushf("[%d] <could not encode: %s>", record.index, tostring(json))
		end
	end

	push("")
	push("== SAVED DREAMS ==")
	push("every dream saved in your library, placed down or not, one line each")
	push("")

	for index, entry in ipairs(libraryOrder) do
		local payload = {
			PlaceId = entry.placeId,
			ScalePosition = { 0.5, 0.5 },
			Exits = {},
			Color = { 1, 1, 1 },
			Name = entry.name,
			ImageId = entry.image,
			Markers = entry.markers,
			Note = entry.note,
			Placed = placedKeys[tostring(entry.placeId)] == true,
		}

		local encoded, json = pcall(HttpService.JSONEncode, HttpService, payload)
		if encoded then
			pushf("[L%d] %s", index, json)
		end
	end

	return table.concat(lines, "\n") .. "\n", {
		elements = #records,
		connections = connectionCount,
		markers = markerCount,
		notes = noteCount,
		library = #libraryOrder,
		unplaced = unplaced,
	}
end

local mapGui = findMapGui()
if not mapGui then
	warn("[map-exporter] could not find the map gui. equip the map tool and open the map once, then run this again.")
	return
end

local shiftingFrame = deepFind(mapGui, "ShiftingFrame")
if not shiftingFrame then
	warn("[map-exporter] the map gui is loaded but has no map canvas yet. open the map once (C) so your data loads, then run this again.")
	return
end

local inventoryFrame = deepFind(mapGui, "InventoryFrame")
local library, libraryOrder = readInventory(inventoryFrame)
local records, byInstance = readElements(shiftingFrame, library)

if #records == 0 and #libraryOrder == 0 then
	warn("[map-exporter] nothing mapped found yet. open the map once (C), let your data load, then run this again.")
	return
end

local text, summary = buildExport(records, byInstance, library, libraryOrder)

print(string.format(
	"[map-exporter] read %d elements, %d connections, %d markers, %d notes, %d library dreams (%d saved but not placed)",
	summary.elements, summary.connections, summary.markers, summary.notes, summary.library, summary.unplaced
))

if type(writefile) == "function" then
	local fileName = exportFileName()
	local exportPath = EXPORT_FOLDER .. "/" .. fileName
	ensureFolder(EXPORT_FOLDER)

	local ok, err = pcall(writefile, exportPath, text)
	if ok then
		local size = #text
		local sizeText = size >= 1024
			and string.format("%.1f KB", size / 1024)
			or string.format("%d bytes", size)

		print(string.format("saved map export to workspace. %s (%s)", fileName, sizeText))
	else
		warn("[map-exporter] could not write " .. exportPath .. ": " .. tostring(err))
		print(text)
	end
else
	warn("[map-exporter] this executor has no writefile, printing the export instead")
	print(text)
end
