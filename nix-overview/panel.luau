--!nonstrict
local format = require("./lib/format.luau")

local GIB = 1024 * 1024 * 1024
local CARD_FILL = "surface_container/0.7"

local snapshot = noctalia.state.get("snapshot")

local function tr(key, subst)
	return noctalia.tr(key, subst)
end

local function request(action)
	-- A fresh table each time so the watch fires even for a repeated action.
	noctalia.state.set("request", { action = action, at = noctalia.nowMs() })
end

-- nix-monitor style: run in a terminal and keep it open to read the output.
local function runInTerminal(command)
	if command == nil or command == "" then
		return
	end
	local wrapped = command
	if noctalia.getConfig("keep_terminal_open") then
		local prompt = tr("terminal.press_enter")
		wrapped = `{command}; status=$?; echo; printf '%s ' "{prompt} ($status)"; read -r _`
	end
	panel.close()
	noctalia.runInTerminal(wrapped)
end

local function card(glyph, value, caption, extra)
	local children = {
		ui.row({ gap = 8, align = "center" }, {
			ui.glyph({ name = glyph, size = 18, color = "primary" }),
			ui.label({ text = value, fontSize = 16, fontWeight = "bold" }),
		}),
		ui.label({ text = caption, fontSize = 11, color = "on_surface_variant" }),
	}
	if extra ~= nil then
		table.insert(children, extra)
	end
	return ui.column({
		fill = CARD_FILL,
		radius = 8,
		padding = 10,
		gap = 4,
		flexGrow = 1,
	}, children)
end

local function statusRow(glyph, color, text)
	return ui.row({ gap = 8, align = "center", paddingH = 4 }, {
		ui.glyph({ name = glyph, size = 16, color = color }),
		ui.label({ text = text, fontSize = 12, maxLines = 2, flexGrow = 1 }),
	})
end

local function render()
	local s = snapshot
	if s == nil then
		panel.render(ui.column({ padding = 12 }, { ui.label({ text = tr("widget.starting") }) }))
		return
	end

	local gen = s.generation or {}
	local now = os.time()

	-- Header ---------------------------------------------------------------
	local header = ui.row({ align = "center", gap = 8 }, {
		ui.glyph({ name = "snowflake", size = 20, color = "primary" }),
		ui.column({ gap = 0, flexGrow = 1 }, {
			ui.label({ text = tr("panel.title"), fontSize = 15, fontWeight = "bold" }),
			ui.label({ text = s.version or "", fontSize = 11, color = "on_surface_variant" }),
		}),
		ui.button({
			glyph = "refresh",
			variant = "ghost",
			controlSize = "sm",
			tooltip = tr("panel.refresh"),
			onClick = function()
				request("refresh")
			end,
		}),
		ui.button({
			glyph = "settings",
			variant = "ghost",
			controlSize = "sm",
			tooltip = tr("panel.settings"),
			onClick = function()
				noctalia.openSettings()
			end,
		}),
	})

	-- Status lines -----------------------------------------------------------
	local status = {}
	if s.boot ~= nil and s.boot.rebootNeeded then
		table.insert(status, statusRow("refresh-alert", "error", tr("reboot.needed", { parts = table.concat(s.boot.changed, ", ") })))
	else
		table.insert(status, statusRow("circle-check", "primary", tr("reboot.not_needed")))
	end

	local config = s.config or { state = "disabled" }
	local configGlyph, configColor = "git-branch", "on_surface_variant"
	if config.state == "current" then
		configGlyph, configColor = "circle-check", "primary"
	elseif config.state == "behind" or config.state == "diverged" then
		configGlyph, configColor = "arrow-down-circle", "error"
	elseif config.state == "ahead" then
		configGlyph, configColor = "arrow-up-circle", "primary"
	end
	local configLine = format.configText(config, tr, noctalia.trp)
	if config.running ~= nil then
		configLine ..= " · " .. format.shortRev(config.running)
	end
	if s.busy ~= nil and s.busy.fetch then
		configLine ..= " · " .. tr("panel.fetching")
	end
	table.insert(status, statusRow(configGlyph, configColor, configLine))

	-- Cards ------------------------------------------------------------------
	local lastSwitch = gen.lastSwitch and tr("value.switched_ago", { age = format.age(now - gen.lastSwitch) }) or ""
	local generationCard = card(
		"versions",
		gen.current and ("#" .. tostring(gen.current)) or "…",
		tr("card.generation", { count = gen.count or 0, switched = lastSwitch })
	)
	local closureCard = card("box", format.bytes(s.closure), tr("card.closure"))

	local store = s.store
	local storeCaption
	if s.busy ~= nil and s.busy.store then
		storeCaption = tr("card.store_counting")
	elseif store ~= nil then
		storeCaption = tr("card.store", { paths = format.thousands(store.paths), age = format.age(now - (store.checkedAt or now)) })
	else
		storeCaption = tr("card.store_unknown")
	end
	local storeCard = card("database", format.bytes(store and store.bytes), storeCaption)

	local disk = s.disk
	local diskCard
	if disk ~= nil then
		local low = disk.free < noctalia.getConfig("low_disk_gib") * GIB
		diskCard = card(
			"device-floppy",
			format.bytes(disk.free),
			tr("card.disk", { total = format.bytes(disk.total) }),
			ui.progress({
				progress = (disk.usagePercent or 0) / 100,
				fill = low and "error" or "primary",
				height = 4,
			})
		)
	else
		diskCard = card("device-floppy", "…", tr("card.disk_unknown"))
	end

	-- Generations list ---------------------------------------------------------
	local genRows = {}
	for _, n in ipairs(gen.list or {}) do
		local t = gen.times and gen.times[tostring(n)]
		local when = t and noctalia.formatTime("%Y-%m-%d %H:%M", t) or ""
		local tag = ""
		if n == gen.current then
			tag = tr("generation.current")
		end
		table.insert(genRows, ui.row({ key = "gen-" .. tostring(n), gap = 8, align = "center", paddingH = 4 }, {
			ui.label({
				text = "#" .. tostring(n),
				fontSize = 12,
				fontWeight = n == gen.current and "bold" or "medium",
				width = 48,
			}),
			ui.label({ text = when, fontSize = 12, flexGrow = 1 }),
			ui.label({ text = tag, fontSize = 11, color = "primary" }),
		}))
	end
	if gen.hmCount ~= nil and gen.hmCount > 0 then
		table.insert(genRows, ui.label({
			text = noctalia.trp("generation.home_manager", gen.hmCount),
			fontSize = 11,
			color = "on_surface_variant",
		}))
	end

	-- Actions ------------------------------------------------------------------
	local buttons = {}
	local function action(key, glyph, variant, label)
		local command = noctalia.getConfig(key)
		if command ~= nil and command ~= "" then
			table.insert(buttons, ui.button({
				text = tr(label),
				glyph = glyph,
				variant = variant,
				flexGrow = 1,
				tooltip = command,
				onClick = function()
					runInTerminal(command)
				end,
			}))
		end
	end
	action("update_command", "player-play", "primary", "panel.update")
	action("optimise_command", "database-cog", "outline", "panel.optimise")
	action("clean_command", "trash", "destructive", "panel.clean")
	table.insert(buttons, ui.button({
		text = tr("panel.recount"),
		glyph = "calculator",
		variant = "outline",
		flexGrow = 1,
		enabled = not (s.busy ~= nil and s.busy.store),
		tooltip = tr("panel.recount_tooltip"),
		onClick = function()
			request("store")
		end,
	}))

	panel.render(ui.column({ gap = 10, padding = 4 }, {
		header,
		ui.separator({ thickness = 1 }),
		ui.column({ gap = 6 }, status),
		ui.row({ gap = 8 }, { generationCard, closureCard }),
		ui.row({ gap = 8 }, { storeCard, diskCard }),
		ui.column({ fill = CARD_FILL, radius = 8, padding = 8, gap = 4 }, genRows),
		ui.row({ gap = 8 }, buttons),
	}))
end

noctalia.state.watch("snapshot", function(value)
	snapshot = value
	render()
end)

function onOpen(_ctx)
	snapshot = noctalia.state.get("snapshot")
	render()
	-- Catch what a terminal command (switch, clean) changed while closed.
	request("open")
end
