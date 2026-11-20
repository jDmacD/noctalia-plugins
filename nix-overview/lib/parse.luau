--!strict
-- Pure parsers for the command output the service collects. No host calls, so
-- the tests can load this module directly (`luau nix-overview/tests/run.luau`).

local M = {}

local function trim(value: string): string
	return value:match("^%s*(.-)%s*$") or ""
end

local function lines(text: string): { string }
	local out = {}
	for line in (text .. "\n"):gmatch("(.-)\r?\n") do
		local t = trim(line)
		if t ~= "" then
			table.insert(out, t)
		end
	end
	return out
end

M.trim = trim
M.lines = lines

-- Generation numbers from a profile directory listing, newest first.
-- `profile` is the link prefix: "system" or "home-manager".
function M.generations(names: { string }, profile: string): { number }
	local pattern = "^" .. profile:gsub("%-", "%%-") .. "%-(%d+)%-link$"
	local out: { number } = {}
	for _, name in ipairs(names) do
		local n = name:match(pattern)
		if n ~= nil then
			table.insert(out, tonumber(n) :: number)
		end
	end
	table.sort(out, function(a: number, b: number)
		return a > b
	end)
	return out
end

-- `readlink /nix/var/nix/profiles/system` -> "system-420-link" -> 420.
function M.profileGeneration(stdout: string): number?
	local n = trim(stdout):match("%-(%d+)%-link$")
	return if n ~= nil then tonumber(n) else nil
end

-- `stat -c '%n\t%Y' paths...` -> { [basename] = mtime }.
function M.statTimes(stdout: string): { [string]: number }
	local out = {}
	for _, line in ipairs(lines(stdout)) do
		local path, mtime = line:match("^(.-)\t(%d+)$")
		if path ~= nil then
			local base = path:match("([^/]+)$") or path
			out[base] = tonumber(mtime) :: number
		end
	end
	return out
end

-- The paths `readlink -m` is given, in order. Kernel, initrd and kernel
-- modules are what a reboot changes; the rest of a switch applies live.
M.BOOT_PARTS = { "kernel", "initrd", "kernel-modules" }

function M.readlinkArgs(): { string }
	local args = { "readlink", "-m", "/run/current-system", "/run/booted-system" }
	for _, part in ipairs(M.BOOT_PARTS) do
		table.insert(args, "/run/current-system/" .. part)
		table.insert(args, "/run/booted-system/" .. part)
	end
	return args
end

export type Boot = {
	current: string,
	booted: string,
	rebootNeeded: boolean,
	changed: { string },
}

function M.boot(stdout: string): Boot?
	local l = lines(stdout)
	if #l < 2 + 2 * #M.BOOT_PARTS then
		return nil
	end
	local changed = {}
	for i, part in ipairs(M.BOOT_PARTS) do
		if l[1 + 2 * i] ~= l[2 + 2 * i] then
			table.insert(changed, part)
		end
	end
	return {
		current = l[1],
		booted = l[2],
		rebootNeeded = #changed > 0,
		changed = changed,
	}
end

-- `nix path-info --closure-size /run/current-system` -> bytes.
function M.closureBytes(stdout: string): number?
	local first = lines(stdout)[1]
	if first == nil then
		return nil
	end
	local bytes = first:match("(%d+)$")
	return if bytes ~= nil then tonumber(bytes) else nil
end

-- The awk summary of `nix path-info --all --size`: "<paths> <bytes>".
function M.storeTotals(stdout: string): (number?, number?)
	local paths, bytes = trim(stdout):match("^(%d+)%s+(%d+)$")
	if paths == nil then
		return nil, nil
	end
	return tonumber(paths), tonumber(bytes)
end

-- `nixos-version --configuration-revision` -> rev, dirty. A system built from
-- a dirty tree records "<rev>-dirty" (flake `dirtyRev`).
function M.revision(stdout: string): (string?, boolean)
	local value = trim(stdout)
	local rev, suffix = value:match("^(%x+)(.*)$")
	if rev == nil or #rev < 7 then
		return nil, false
	end
	return rev, suffix == "-dirty"
end

-- `git rev-list --left-right --count RUNNING...REMOTE` -> ahead, behind.
-- Left is commits only the running revision has, right only the remote.
function M.leftRight(stdout: string): (number?, number?)
	local ahead, behind = trim(stdout):match("^(%d+)%s+(%d+)$")
	if ahead == nil then
		return nil, nil
	end
	return tonumber(ahead), tonumber(behind)
end

function M.configState(ahead: number, behind: number): string
	if ahead == 0 and behind == 0 then
		return "current"
	elseif ahead == 0 then
		return "behind"
	elseif behind == 0 then
		return "ahead"
	end
	return "diverged"
end

-- "origin/main" -> "origin"; nil for a ref with no remote part.
function M.remoteName(ref: string): string?
	return ref:match("^([%w%._%-]+)/.+$")
end

return M
