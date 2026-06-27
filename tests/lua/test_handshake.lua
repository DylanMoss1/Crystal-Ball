-- Regression tests for the mod-side handshake state machine: request_seed writes
-- the request file the watcher reads, and poll() resolves the watcher's response
-- (seed / ERROR). Drives the REAL functions against the stub's
-- in-memory filesystem (CB_FS) -- no game, no watcher, no GPU.
--
-- The stub forces the Linux (watcher) path (jit.os = "Linux"), so request_seed
-- writes a request file rather than launching Immolate.exe.
--
-- Run: lua tests/lua/test_handshake.lua   (cwd = repo root)

local repo_root = os.getenv("CB_REPO_ROOT") or "."
local load_mod = dofile(repo_root .. "/tests/lua/balatro_stub.lua")
local T = dofile(repo_root .. "/tests/lua/harness.lua").new()

local mod = load_mod(repo_root)

local REQUEST = "/Mods/CrystalBall/CrystalBallHandshake/request.txt"
local RESPONSE = "/Mods/CrystalBall/CrystalBallHandshake/response.txt"

-- poll() only acts every config.poll_frames frames; pump enough to trigger it.
local function pump()
	for _ = 1, mod.config.poll_frames do
		mod.poll()
	end
end

local function reset()
	mod.pending, mod.deferred, mod.resolving, mod.last_seed = nil, nil, false, nil
	CB_FS[REQUEST], CB_FS[RESPONSE] = nil, nil
end

-- 1. request_seed writes "<id>\n<query>\n", with a "<time>-<n>" id.
reset()
mod.config.clauses = { { jokers = { "j_blueprint" }, minAnte = 1, maxAnte = 8, atLeast = 1 } }
local query = mod.query_json(mod.build_criteria())
mod.request_seed(mod.build_criteria())
T.ok("request_seed sets pending", mod.pending ~= nil)
T.match("request id format", mod.pending.id, "^%d+%-%d+$")
T.check("request file contents", CB_FS[REQUEST], mod.pending.id .. "\n" .. query .. "\n")

-- 2. poll resolves a matching response into an (upper-cased) seed.
reset()
mod.request_seed(mod.build_criteria())
local id = mod.pending.id
CB_FS[RESPONSE] = id .. "\nabcde123\n" -- watcher writes the seed back
pump()
T.check("poll resolves seed (upper)", mod.last_seed and mod.last_seed:upper(), "ABCDE123")
T.ok("poll clears pending on resolve", mod.pending == nil)
T.ok("poll consumes response file", CB_FS[RESPONSE] == nil)

-- 3. An ERROR payload resolves as a failure (pending cleared, no seed adopted).
reset()
mod.last_seed = "PREVSEED"
mod.request_seed(mod.build_criteria())
CB_FS[RESPONSE] = mod.pending.id .. "\nERROR: search failed\n"
pump()
T.ok("error clears pending", mod.pending == nil)
T.check("error leaves last_seed untouched", mod.last_seed, "PREVSEED")

-- 4. A response for a different id is ignored (not our request).
reset()
mod.request_seed(mod.build_criteria())
CB_FS[RESPONSE] = "some-other-id\nWRONG\n"
pump()
T.ok("mismatched id keeps pending", mod.pending ~= nil)
T.ok("mismatched id adopts no seed", mod.last_seed == nil)

T.finish()
