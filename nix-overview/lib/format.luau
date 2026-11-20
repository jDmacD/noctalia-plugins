--!strict
-- Pure display helpers shared by the widget and the panel.

local M = {}

local UNITS = { "B", "KiB", "MiB", "GiB", "TiB" }

function M.bytes(n: number?): string
	if n == nil then
		return "…"
	end
	local value = n
	local unit = 1
	while value >= 1024 and unit < #UNITS do
		value /= 1024
		unit += 1
	end
	if unit == 1 then
		return string.format("%d B", value)
	end
	return string.format(if value >= 100 then "%.0f %s" else "%.1f %s", value, UNITS[unit])
end

function M.thousands(n: number?): string
	if n == nil then
		return "…"
	end
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

-- Compact age: "now", "12 min", "3 h", "5 d".
function M.age(seconds: number?): string
	if seconds == nil then
		return "…"
	end
	if seconds < 60 then
		return "now"
	elseif seconds < 3600 then
		return string.format("%d min", seconds // 60)
	elseif seconds < 86400 then
		return string.format("%d h", seconds // 3600)
	end
	return string.format("%d d", seconds // 86400)
end

-- "{generation} · {disk_free}" with values; unknown placeholders stay as-is.
function M.template(fmt: string, values: { [string]: string }): string
	local out = fmt:gsub("{([%w_]+)}", function(key)
		return values[key]
	end)
	return out
end

-- One line for the config check. `tr` and `trp` are noctalia.tr/trp, passed
-- in so this module stays host-free.
function M.configText(config: any, tr: (string, any?) -> string, trp: (string, number, any?) -> string): string
	if config == nil then
		return tr("config.disabled")
	end
	local state = config.state
	local text
	if state == "behind" then
		text = trp("config.behind", config.behind, { ref = config.remoteRef })
	elseif state == "ahead" then
		text = trp("config.ahead", config.ahead, { ref = config.remoteRef })
	elseif state == "diverged" then
		text = tr("config.diverged", { ahead = config.ahead, behind = config.behind, ref = config.remoteRef })
	elseif state == "current" then
		text = tr("config.current", { ref = config.remoteRef })
	elseif state == "unknown" then
		text = config.message or tr("config.unknown")
	else
		text = tr("config.disabled")
	end
	if config.dirty then
		text ..= " · " .. tr("config.dirty")
	end
	return text
end

function M.shortRev(rev: string?): string
	if rev == nil then
		return "…"
	end
	return rev:sub(1, 7)
end

return M
