--!nonstrict
-- Collects the NixOS figures and publishes one `snapshot` table that the
-- widget and panel watch. Cheap checks (generations, boot parts, disk) run
-- every minute; the closure size when /run/current-system changes; the store
-- total daily or after generations change; the config check per its settings.

local parse = require("./lib/parse.luau")
local job = require("./lib/job.luau")

local PROFILES = "/nix/var/nix/profiles"
local MINUTE_MS = 60 * 1000
local STORE_RECOUNT_DEBOUNCE_S = 10 * 60
local GENERATION_LIST_MAX = 8

-- Sums NAR sizes in awk so only one short line comes back: a Luau loop over
-- ~60k lines would blow the 25 ms callback budget.
local STORE_COMMAND = "nice -n 19 nix path-info --all --size 2>/dev/null"
	.. " | awk '{ n++; s += $2 } END { printf \"%d %.0f\\n\", n, s }'"

local host = {
	runAsync = noctalia.runAsync,
	nowMs = noctalia.nowMs,
}

local jobs = {
	gens = job.new(host, 5000),
	profile = job.new(host, 5000),
	boot = job.new(host, 5000),
	closure = job.new(host, 30000),
	store = job.new(host, 60000),
	revision = job.new(host, 5000),
	fetch = job.new(host, 60000),
	compare = job.new(host, 10000),
}

local snapshot = {
	generation = { current = nil, list = {}, count = 0, lastSwitch = nil, hmCount = 0 },
	boot = nil,
	closure = nil,
	store = nil,
	disk = nil,
	config = { state = "disabled" },
	busy = {},
	version = nil,
}

local lastFetchS = 0
local lastClosurePath = nil
local runningRev = nil
local runningDirty = false
local storeFile = nil

local function now(): number
	return os.time()
end

local function publish()
	snapshot.busy = {
		store = jobs.store.busy(),
		fetch = jobs.fetch.busy(),
	}
	snapshot.updatedAt = now()
	noctalia.state.set("snapshot", snapshot)
end

local function cfg(key)
	return noctalia.getConfig(key)
end

-- Store totals ---------------------------------------------------------------

local function loadStore()
	local dir = noctalia.pluginDataDir()
	if dir == nil then
		return
	end
	storeFile = dir .. "/store.json"
	local raw = noctalia.readFile(storeFile)
	if raw ~= nil then
		local data = noctalia.json.decode(raw)
		if type(data) == "table" and data.bytes ~= nil then
			snapshot.store = data
		end
	end
end

local function countStore(reason)
	local signature = table.concat(snapshot.generation.list, ",")
	local started = jobs.store.run(STORE_COMMAND, function(result)
		local paths, bytes = parse.storeTotals(result.stdout)
		if result.exitCode == 0 and paths ~= nil then
			snapshot.store = {
				paths = paths,
				bytes = bytes,
				checkedAt = now(),
				signature = signature,
			}
			if storeFile ~= nil then
				noctalia.writeFile(storeFile, noctalia.json.encode(snapshot.store))
			end
		else
			noctalia.log(`store count failed ({reason}): {result.timedOut and "timed out" or result.stderr}`)
		end
		publish()
	end)
	if started then
		publish()
	end
end

local function maybeCountStore()
	local hours = cfg("store_check_hours")
	local store = snapshot.store
	if store == nil then
		countStore("first run")
		return
	end
	local age = now() - (store.checkedAt or 0)
	-- A switch or a clean changes the generation list; recount after it,
	-- but not more than every few minutes.
	local signature = table.concat(snapshot.generation.list, ",")
	if store.signature ~= signature and age >= STORE_RECOUNT_DEBOUNCE_S then
		countStore("generations changed")
	elseif hours > 0 and age >= hours * 3600 then
		countStore("interval")
	end
end

-- Generations ----------------------------------------------------------------

local function checkGenerations()
	local names = noctalia.listDir(PROFILES) or {}
	local gens = parse.generations(names, "system")
	snapshot.generation.count = #gens

	local home = noctalia.getenv("HOME")
	if home ~= nil then
		local hmNames = noctalia.listDir(home .. "/.local/state/nix/profiles") or {}
		snapshot.generation.hmCount = #parse.generations(hmNames, "home-manager")
	end

	local args = { "stat", "-c", "%n\t%Y", PROFILES .. "/system" }
	for i, n in ipairs(gens) do
		if i > GENERATION_LIST_MAX then
			break
		end
		table.insert(args, `{PROFILES}/system-{n}-link`)
	end

	jobs.gens.run(args, function(result)
		local times = parse.statTimes(result.stdout)
		local list = {}
		local listTimes = {}
		for i, n in ipairs(gens) do
			if i > GENERATION_LIST_MAX then
				break
			end
			table.insert(list, n)
			listTimes[tostring(n)] = times[`system-{n}-link`]
		end
		snapshot.generation.list = list
		snapshot.generation.times = listTimes
		snapshot.generation.lastSwitch = times["system"]
		publish()
		maybeCountStore()
	end)

	jobs.profile.run({ "readlink", PROFILES .. "/system" }, function(result)
		snapshot.generation.current = parse.profileGeneration(result.stdout)
		publish()
	end)
end

-- Boot parts, closure, running revision --------------------------------------

local checkConfig

local function readRevision()
	jobs.revision.run({ "nixos-version", "--configuration-revision" }, function(result)
		runningRev, runningDirty = nil, false
		if result.exitCode == 0 then
			runningRev, runningDirty = parse.revision(result.stdout)
		end
		checkConfig(false)
	end)
end

local function checkBoot()
	jobs.boot.run(parse.readlinkArgs(), function(result)
		local boot = parse.boot(result.stdout)
		if boot == nil then
			return
		end
		snapshot.boot = boot
		publish()

		if boot.current ~= lastClosurePath then
			lastClosurePath = boot.current
			jobs.closure.run({ "nix", "path-info", "--closure-size", "/run/current-system" }, function(res)
				snapshot.closure = parse.closureBytes(res.stdout)
				publish()
			end)
			-- A switch can change the configuration revision too.
			readRevision()
		end
	end)
end

local function checkDisk()
	local disk = noctalia.diskStats("/nix/store")
	if disk ~= nil then
		snapshot.disk = {
			free = disk.availableBytes,
			total = disk.totalBytes,
			usagePercent = disk.usagePercent,
		}
	end
end

-- Config: running revision vs the remote ref ---------------------------------

local function flakeDir(): string?
	local dir = cfg("flake_dir")
	if dir == nil or dir == "" then
		return nil
	end
	return noctalia.expandPath(dir)
end

local function compare(dir, remoteRef)
	local args = { "git", "-C", dir, "rev-list", "--left-right", "--count", `{runningRev}...{remoteRef}` }
	local paths = cfg("watch_paths") or {}
	if #paths > 0 then
		table.insert(args, "--")
		for _, p in ipairs(paths) do
			table.insert(args, p)
		end
	end
	jobs.compare.run(args, function(result)
		local ahead, behind = parse.leftRight(result.stdout)
		if result.exitCode ~= 0 or ahead == nil then
			snapshot.config = {
				state = "unknown",
				running = runningRev,
				dirty = runningDirty,
				message = noctalia.tr("config.not_in_checkout"),
			}
		else
			snapshot.config = {
				state = parse.configState(ahead, behind),
				ahead = ahead,
				behind = behind,
				running = runningRev,
				dirty = runningDirty,
				remoteRef = remoteRef,
				fetchedAt = if lastFetchS > 0 then lastFetchS else nil,
			}
		end
		publish()
	end)
end

function checkConfig(allowFetch: boolean)
	local dir = flakeDir()
	if dir == nil then
		snapshot.config = { state = "disabled" }
		publish()
		return
	end
	if runningRev == nil then
		snapshot.config = { state = "unknown", message = noctalia.tr("config.no_revision") }
		publish()
		return
	end

	local remoteRef = cfg("remote_ref")
	local remote = parse.remoteName(remoteRef)
	local interval = cfg("fetch_minutes")
	local due = interval > 0 and now() - lastFetchS >= interval * 60

	if allowFetch and remote ~= nil and due then
		local started = jobs.fetch.run({
			"env",
			"GIT_TERMINAL_PROMPT=0",
			"GIT_SSH_COMMAND=ssh -o BatchMode=yes -o ConnectTimeout=10",
			"git",
			"-C",
			dir,
			"fetch",
			"--quiet",
			remote,
		}, function(result)
			if result.exitCode == 0 then
				lastFetchS = now()
			else
				-- Offline is normal on a laptop: compare against what is
				-- already fetched and try again at the next interval.
				lastFetchS = now()
				noctalia.log(`git fetch failed: {result.timedOut and "timed out" or result.stderr}`)
			end
			compare(dir, remoteRef)
		end)
		if started then
			publish()
		end
		return
	end
	compare(dir, remoteRef)
end

-- Loop -------------------------------------------------------------------------

local function refresh(forceFetch: boolean)
	if forceFetch then
		lastFetchS = 0
	end
	checkDisk()
	checkGenerations()
	checkBoot()
	if runningRev ~= nil or flakeDir() == nil then
		checkConfig(true)
	end
end

noctalia.state.watch("request", function(request)
	if type(request) ~= "table" then
		return
	end
	if request.action == "refresh" then
		refresh(true)
	elseif request.action == "open" then
		refresh(false)
	elseif request.action == "store" then
		countStore("requested")
	end
end)

loadStore()
noctalia.runAsync({ "nixos-version" }, function(result)
	if result.exitCode == 0 then
		snapshot.version = parse.trim(result.stdout)
		publish()
	end
end)
refresh(false)
publish()
noctalia.setUpdateInterval(MINUTE_MS)

function update()
	refresh(false)
end

-- noctalia msg plugin jdmacd/nix-overview:service all <refresh|recount|dump>
function onIpc(event)
	if event == "refresh" then
		refresh(true)
	elseif event == "recount" then
		countStore("ipc")
	elseif event == "dump" then
		noctalia.log("snapshot " .. (noctalia.json.encode(snapshot) or "?"))
	end
end

function onResume()
	-- The network may still be coming up; a failed fetch retries next interval.
	refresh(true)
end

function onConfigChanged()
	lastFetchS = 0
	checkConfig(true)
end
