--!nonstrict
local format = require("./lib/format.luau")

local PANEL = "jdmacd/nix-overview:panel"
local GIB = 1024 * 1024 * 1024

local snapshot = noctalia.state.get("snapshot")

local function tr(key, subst)
	return noctalia.tr(key, subst)
end

local function values(s)
	local gen = s.generation or {}
	local disk = s.disk or {}
	local store = s.store or {}
	local config = s.config or {}
	return {
		generation = gen.current and tostring(gen.current) or "…",
		generations = tostring(gen.count or 0),
		closure = format.bytes(s.closure),
		store = format.bytes(store.bytes),
		store_paths = format.thousands(store.paths),
		disk_free = format.bytes(disk.free),
		behind = tostring(config.behind or 0),
	}
end

local function show()
	local s = snapshot
	if s == nil then
		barWidget.setGlyph("snowflake")
		barWidget.setText("")
		barWidget.setTooltip(tr("widget.starting"))
		return
	end

	local v = values(s)
	local rebootNeeded = s.boot ~= nil and s.boot.rebootNeeded
	local behind = s.config ~= nil and (s.config.state == "behind" or s.config.state == "diverged")
	local lowDisk = s.disk ~= nil and s.disk.free ~= nil and s.disk.free < noctalia.getConfig("low_disk_gib") * GIB

	local markers = ""
	if noctalia.getConfig("show_markers") then
		if rebootNeeded then
			markers ..= "↻"
		end
		if behind then
			markers ..= "↓" .. tostring(s.config.behind)
		end
		if markers ~= "" then
			markers ..= " "
		end
	end

	barWidget.setGlyph("snowflake")
	if rebootNeeded or lowDisk then
		barWidget.setGlyphColor("error", "script")
	elseif behind then
		barWidget.setGlyphColor("primary", "script")
	else
		barWidget.setGlyphColor("on_surface")
	end
	barWidget.setText(markers .. format.template(noctalia.getConfig("text_format"), v))

	local gen = s.generation or {}
	local rows = {
		{ tr("label.generation"), tr("value.generation", { current = v.generation, count = v.generations }) },
	}
	if gen.lastSwitch ~= nil then
		table.insert(rows, { tr("label.last_switch"), format.age(os.time() - gen.lastSwitch) })
	end
	table.insert(rows, { tr("label.closure"), v.closure })
	if s.store ~= nil then
		table.insert(rows, { tr("label.store"), tr("value.store", { size = v.store, paths = v.store_paths }) })
	end
	if s.disk ~= nil then
		table.insert(rows, { tr("label.disk_free"), tr("value.disk", { free = v.disk_free, total = format.bytes(s.disk.total) }) })
	end
	if s.boot ~= nil then
		table.insert(rows, {
			tr("label.reboot"),
			rebootNeeded and tr("reboot.needed", { parts = table.concat(s.boot.changed, ", ") }) or tr("reboot.not_needed"),
		})
	end
	table.insert(rows, { tr("label.config"), format.configText(s.config, tr, noctalia.trp) })
	barWidget.setTooltip(rows)
end

noctalia.state.watch("snapshot", function(value)
	snapshot = value
	show()
end)

function update()
	-- Keeps "last switch" ages fresh between snapshots.
	show()
end

function onClick()
	noctalia.togglePanel(PANEL)
end

show()
noctalia.setUpdateInterval(60000)
