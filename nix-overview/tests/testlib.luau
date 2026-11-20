-- Minimal test harness (after mindnbytes/nix-status's): register with
-- `test`, then `run` prints PASS/FAIL and errors if anything failed.
local tests = {}

local function test(name, callback)
	table.insert(tests, { name = name, callback = callback })
end

local function eq(actual, expected, message)
	if actual ~= expected then
		error(
			(message or "values differ") .. "\n  expected: " .. tostring(expected) .. "\n  actual:   " .. tostring(actual),
			2
		)
	end
end

local function run()
	local failures = 0
	for _, entry in ipairs(tests) do
		local ok, err = pcall(entry.callback)
		if ok then
			print("PASS " .. entry.name)
		else
			failures += 1
			print("FAIL " .. entry.name)
			print("     " .. tostring(err):gsub("\n", "\n     "))
		end
	end
	print(string.format("\n%d/%d tests passed", #tests - failures, #tests))
	if failures > 0 then
		error(tostring(failures) .. " test(s) failed", 0)
	end
end

return { test = test, eq = eq, run = run }
