-- luau nix-overview/tests/run.luau  (or nix-overview/scripts/test)
local t = require("./testlib")
local parse = require("../lib/parse")
local format = require("../lib/format")
local job = require("../lib/job")

-- parse ---------------------------------------------------------------------

t.test("generations: system links only, newest first", function()
	local names = { "system", "system-418-link", "system-420-link", "system-9-link", "default", "per-user" }
	local gens = parse.generations(names, "system")
	t.eq(#gens, 3)
	t.eq(gens[1], 420)
	t.eq(gens[3], 9)
end)

t.test("generations: home-manager prefix is matched literally", function()
	local gens = parse.generations({ "home-manager-3-link", "home-manager", "homeXmanager-4-link" }, "home-manager")
	t.eq(#gens, 1)
	t.eq(gens[1], 3)
end)

t.test("profileGeneration", function()
	t.eq(parse.profileGeneration("system-420-link\n"), 420)
	t.eq(parse.profileGeneration(""), nil)
end)

t.test("statTimes keys by basename", function()
	local times = parse.statTimes(
		"/nix/var/nix/profiles/system\t1795131534\n/nix/var/nix/profiles/system-420-link\t1795131500\n"
	)
	t.eq(times["system"], 1795131534)
	t.eq(times["system-420-link"], 1795131500)
end)

-- Captured on a host whose system was switched (booted ≠ current) without a
-- kernel change: no reboot needed.
local SWITCHED_SAME_KERNEL = [[
/nix/store/myra0pqdg3qw26dz73iqdd9x9rij0h9k-nixos-system-surface-26.11.20261113.d5cc683
/nix/store/lf2yhvr2xi5h0z8v4bzg32cihi31p374-nixos-system-surface-26.11.20261113.d5cc683
/nix/store/75kcf62cqwp6pi53r2cb9qm3pfnb2r7j-linux-6.18.63/bzImage
/nix/store/75kcf62cqwp6pi53r2cb9qm3pfnb2r7j-linux-6.18.63/bzImage
/nix/store/913d1wl3wfnfi4bk0bjqbayx3vzr62wz-initrd-linux-6.18.63/initrd
/nix/store/913d1wl3wfnfi4bk0bjqbayx3vzr62wz-initrd-linux-6.18.63/initrd
/nix/store/almdw60ngcavl3ykh7msrx8n2j3vbww8-linux-6.18.63-modules
/nix/store/almdw60ngcavl3ykh7msrx8n2j3vbww8-linux-6.18.63-modules
]]

t.test("boot: switched without kernel change needs no reboot", function()
	local boot = parse.boot(SWITCHED_SAME_KERNEL)
	t.eq(boot ~= nil, true)
	t.eq(boot.rebootNeeded, false)
	t.eq(#boot.changed, 0)
	t.eq(boot.current ~= boot.booted, true)
end)

t.test("boot: kernel and modules change -> reboot needed", function()
	local out = SWITCHED_SAME_KERNEL
		:gsub("75kcf62cqwp6pi53r2cb9qm3pfnb2r7j%-linux%-6%.18%.63/bzImage\n/nix", "OLDKERNEL/bzImage\n/nix", 1)
		:gsub("almdw60ngcavl3ykh7msrx8n2j3vbww8", "OLDMODULES", 1)
	local boot = parse.boot(out)
	t.eq(boot.rebootNeeded, true)
	t.eq(table.concat(boot.changed, ","), "kernel,kernel-modules")
end)

t.test("boot: short output is rejected", function()
	t.eq(parse.boot("/nix/store/a\n/nix/store/b\n"), nil)
end)

t.test("readlinkArgs lines up with boot()", function()
	local args = parse.readlinkArgs()
	t.eq(args[1], "readlink")
	t.eq(args[2], "-m")
	t.eq(#args - 2, 2 + 2 * #parse.BOOT_PARTS)
	t.eq(args[5], "/run/current-system/kernel")
	t.eq(args[6], "/run/booted-system/kernel")
end)

t.test("closureBytes", function()
	t.eq(
		parse.closureBytes(
			"/nix/store/myra0pqdg3qw26dz73iqdd9x9rij0h9k-nixos-system-surface-26.11.20261113.d5cc683\t18136921016\n"
		),
		18136921016
	)
	t.eq(parse.closureBytes(""), nil)
end)

t.test("storeTotals", function()
	local paths, bytes = parse.storeTotals("60371 123456789012\n")
	t.eq(paths, 60371)
	t.eq(bytes, 123456789012)
	t.eq((parse.storeTotals("error: something")), nil)
end)

t.test("revision: clean and dirty", function()
	local rev, dirty = parse.revision("3efe5d3047e69991ade3ef838af00199c017e4f4\n")
	t.eq(rev, "3efe5d3047e69991ade3ef838af00199c017e4f4")
	t.eq(dirty, false)
	rev, dirty = parse.revision("3efe5d3047e69991ade3ef838af00199c017e4f4-dirty")
	t.eq(rev, "3efe5d3047e69991ade3ef838af00199c017e4f4")
	t.eq(dirty, true)
	t.eq((parse.revision("")), nil)
	t.eq((parse.revision("error: no revision")), nil)
end)

t.test("leftRight and configState", function()
	local ahead, behind = parse.leftRight("1\t0\n")
	t.eq(ahead, 1)
	t.eq(behind, 0)
	t.eq(parse.configState(0, 0), "current")
	t.eq(parse.configState(0, 3), "behind")
	t.eq(parse.configState(2, 0), "ahead")
	t.eq(parse.configState(1, 1), "diverged")
	t.eq((parse.leftRight("fatal: bad revision")), nil)
end)

t.test("remoteName", function()
	t.eq(parse.remoteName("origin/main"), "origin")
	t.eq(parse.remoteName("upstream/feat/x"), "upstream")
	t.eq(parse.remoteName("main"), nil)
end)

-- format --------------------------------------------------------------------

t.test("bytes", function()
	t.eq(format.bytes(nil), "…")
	t.eq(format.bytes(512), "512 B")
	t.eq(format.bytes(18136921016), "16.9 GiB")
	t.eq(format.bytes(125 * 1024 ^ 3), "125 GiB")
end)

t.test("thousands", function()
	t.eq(format.thousands(60371), "60,371")
	t.eq(format.thousands(999), "999")
	t.eq(format.thousands(1000000), "1,000,000")
end)

t.test("age", function()
	t.eq(format.age(5), "now")
	t.eq(format.age(125), "2 min")
	t.eq(format.age(7200), "2 h")
	t.eq(format.age(3 * 86400 + 5), "3 d")
end)

t.test("template keeps unknown placeholders", function()
	t.eq(format.template("{generation} · {disk_free} {nope}", { generation = "420", disk_free = "25 GiB" }), "420 · 25 GiB {nope}")
end)

t.test("configText", function()
	local function tr(key, subst)
		return key .. (subst and subst.ref and (":" .. subst.ref) or "")
	end
	local function trp(key, count, subst)
		return key .. (count == 1 and ".one" or ".other") .. ":" .. subst.ref
	end
	t.eq(format.configText(nil, tr, trp), "config.disabled")
	t.eq(format.configText({ state = "behind", behind = 1, remoteRef = "origin/main" }, tr, trp), "config.behind.one:origin/main")
	t.eq(format.configText({ state = "current", remoteRef = "origin/main", dirty = true }, tr, trp), "config.current:origin/main · config.dirty")
	t.eq(format.configText({ state = "unknown", message = "msg" }, tr, trp), "msg")
end)

-- job -----------------------------------------------------------------------

local function fakeHost()
	local h = { now = 0, pending = {}, start = true }
	h.nowMs = function()
		return h.now
	end
	h.runAsync = function(cmd, cb, timeoutMs)
		table.insert(h.pending, { cmd = cmd, cb = cb, timeoutMs = timeoutMs })
		return h.start
	end
	return h
end

t.test("job: drops duplicates while running, frees on callback", function()
	local h = fakeHost()
	local j = job.new(h, 5000)
	local got = 0
	t.eq(j.run({ "a" }, function()
		got += 1
	end), true)
	t.eq(j.run({ "b" }, function() end), false)
	t.eq(#h.pending, 1)
	t.eq(h.pending[1].timeoutMs, 5000)
	h.pending[1].cb({ exitCode = 0, stdout = "", stderr = "", timedOut = false })
	t.eq(got, 1)
	t.eq(j.busy(), false)
end)

t.test("job: watchdog frees a job whose callback was lost", function()
	local h = fakeHost()
	local j = job.new(h, 5000)
	j.run({ "a" }, function() end)
	h.now = 10000
	t.eq(j.busy(), true)
	h.now = 21000
	t.eq(j.busy(), false)
	t.eq(j.run({ "b" }, function() end), true)
end)

t.test("job: failed start reports exitCode -1 and stays free", function()
	local h = fakeHost()
	h.start = false
	local j = job.new(h, 5000)
	local code
	t.eq(j.run({ "a" }, function(r)
		code = r.exitCode
	end), false)
	t.eq(code, -1)
	t.eq(j.busy(), false)
end)

t.run()
