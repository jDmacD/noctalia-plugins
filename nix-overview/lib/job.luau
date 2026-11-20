--!strict
-- One command at a time per check, with a watchdog. A callback that never
-- arrives (script reload, CPU-budget kill) must not leave the job busy for
-- good, so `busy()` frees it once the command's own timeout plus a margin has
-- passed. Duplicate requests while busy are dropped, not queued.

export type Result = {
	exitCode: number,
	stdout: string,
	stderr: string,
	timedOut: boolean,
}

export type Host = {
	runAsync: (cmd: any, cb: (Result) -> (), timeoutMs: number) -> boolean,
	nowMs: () -> number,
}

local WATCHDOG_MARGIN_MS = 15000

local function new(host: Host, timeoutMs: number)
	local running = false
	local startedAt = 0

	local function busy(): boolean
		if running and host.nowMs() - startedAt > timeoutMs + WATCHDOG_MARGIN_MS then
			running = false
		end
		return running
	end

	-- Returns false when the job was busy or the process could not start;
	-- in the second case `cb` still runs, with exitCode -1.
	local function run(cmd: any, cb: (Result) -> ()): boolean
		if busy() then
			return false
		end
		running = true
		startedAt = host.nowMs()
		local started = host.runAsync(cmd, function(result)
			running = false
			cb(result)
		end, timeoutMs)
		if not started then
			running = false
			cb({ exitCode = -1, stdout = "", stderr = "could not start command", timedOut = false })
		end
		return started
	end

	return {
		run = run,
		busy = busy,
	}
end

return {
	new = new,
}
