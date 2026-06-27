--- core/handshake: hand the search off to Immolate, resolve the result via mod.poll.
---
--- The game can't run Immolate portably (Proton = Windows process), so:
---   Linux/Proton: write request.txt; host watcher.py runs Immolate, writes response.txt
---   native Win:   launch Immolate.exe detached, translate its output into response.txt
--- Both paths land in the same per-frame poller, so the overlay keeps rendering.
--- ctx in: toast

return function(ctx)
	local mod = ctx.mod
	local toast = ctx.toast

	local HANDSHAKE_DIR = "/Mods/CrystalBall/CrystalBallHandshake"
	local REQUEST = HANDSHAKE_DIR .. "/request.txt"
	local RESPONSE = HANDSHAKE_DIR .. "/response.txt"

	local req_counter = 0
	local FILTER = "find_joker" -- query-aware Immolate filter (matches watcher.py default)

	-- True only on *native* Windows. Under Proton jit.os is also "Windows" (LuaJIT
	-- reports its compile-time target), so check the save-dir user too: Proton always
	-- runs as "steamuser", native Windows uses the real account. Native => inline exec;
	-- Proton => fall through to the host watcher (it can reach the GPU).
	local function is_native_windows()
		if jit.os ~= "Windows" then
			return false
		end
		local save = love.filesystem.getSaveDirectory():lower()
		return not save:find("/users/steamuser/", 1, true)
	end

	-- Windows inline-exec scratch files (all under HANDSHAKE_DIR, so reachable as both
	-- OS paths for cmd and love.filesystem virtual paths for poll).
	local WIN_OUT = HANDSHAKE_DIR .. "/winout.txt"
	local WIN_DONE = HANDSHAKE_DIR .. "/windone.txt"
	local WIN_BAT = HANDSHAKE_DIR .. "/run.bat"

	-- Launch Immolate.exe detached. Returns true, or false + error string.
	local function run_immolate_windows(query)
		love.filesystem.write(HANDSHAKE_DIR .. "/query.json", query)
		love.filesystem.remove(WIN_OUT) -- drop stale output/marker from a prior run
		love.filesystem.remove(WIN_DONE)

		local save = love.filesystem.getSaveDirectory()
		local function win(p)
			return (p:gsub("/", "\\"))
		end
		local exe = win(save .. "/Mods/CrystalBall/Immolate/Immolate.exe")
		local qfile = win(save .. "/" .. HANDSHAKE_DIR .. "/query.json")
		local out = win(save .. "/" .. WIN_OUT)
		local done = win(save .. "/" .. WIN_DONE)
		local bat = win(save .. "/" .. WIN_BAT)

		-- All quoting lives in the .bat (avoids nested cmd /c escaping). WIN_DONE holds
		-- Immolate's exit code, written only after it exits: presence => finished, and
		-- the code lets poll tell success (0) from failure (Fatal CL Error / GPU timeout),
		-- so a crash is never read as a seed. `> "file" echo` avoids cmd parsing `echo 0>`
		-- as a stream-0 redirect.
		love.filesystem.write(
			WIN_BAT,
			"@echo off\r\n"
				.. string.format('"%s" -f %s --first -q -s random -J "%s" > "%s"\r\n', exe, FILTER, qfile, out)
				.. string.format('> "%s" echo %%errorlevel%%\r\n', done)
		)

		-- `start "" /b` detaches: cmd returns at once, game never blocks. os.execute
		-- returns the shell status; nil/false => failed to spawn.
		local ok = os.execute(string.format('start "" /b "%s"', bat))
		if ok == nil or ok == false then
			return false, "could not launch Immolate.exe"
		end
		return true
	end

	-- Start a search. Writes the request (Linux/Proton) or launches Immolate.exe
	-- (native Windows); mod.poll resolves either asynchronously.
	function mod.request_seed(criteria)
		req_counter = req_counter + 1
		local id = string.format("%d-%d", os.time(), req_counter)
		local query = mod.query_json(criteria)

		love.filesystem.createDirectory(HANDSHAKE_DIR)
		love.filesystem.remove(RESPONSE) -- drop any stale result
		love.filesystem.write(REQUEST, id .. "\n" .. query .. "\n")
		mod.pending = { id = id, frames = 0 }

		if is_native_windows() then
			local ok, err = run_immolate_windows(query)
			if not ok then
				love.filesystem.write(RESPONSE, id .. "\n" .. ("ERROR: " .. err) .. "\n")
			else
				mod.pending.win_out = WIN_OUT
				mod.pending.win_done = WIN_DONE
			end
		end
	end

	-- seed (or nil on failure) is in: route to the deferred new-run or the manual flow.
	local function on_resolved(seed)
		mod.resolving = false
		if G.OVERLAY_MENU then
			G.FUNCS.exit_overlay_menu() -- dismiss the waiting screen
		end
		local d = mod.deferred
		mod.deferred = nil
		if not seed then
			return -- abandon the deferred run; interception already returned us to the menu
		end
		if d then
			d.args.seed = seed
			mod._orig_start_run(d.e, d.args)
		else
			mod.start_seeded_run(seed)
		end
	end

	-- Polled every frame; checks for the watcher's response.
	function mod.poll()
		local p = mod.pending
		if not p then
			return
		end

		p.frames = p.frames + 1
		if p.frames % mod.config.poll_frames ~= 0 then
			return
		end

		-- Native-Windows inline path: once WIN_DONE (the exit code) appears, translate the
		-- output into a RESPONSE. Only exit 0 AND a valid seed token count as success.
		if p.win_done then
			local marker = love.filesystem.read(p.win_done)
			if marker then
				local code = marker:match("%-?%d+")
				local seed = (love.filesystem.read(p.win_out) or ""):match("%S+")
				local good = code == "0" and seed and seed:match("^[A-Z0-9]+$") and #seed <= 8
				love.filesystem.write(RESPONSE, p.id .. "\n" .. (good and seed or "ERROR: search failed") .. "\n")
				love.filesystem.remove(p.win_out)
				love.filesystem.remove(p.win_done)
				p.win_done = nil
			end
		end

		local data = love.filesystem.read(RESPONSE)
		if data then
			local rid, payload = data:match("^(%S+)%s*\n(.-)%s*$")
			if rid == p.id then
				mod.pending = nil
				love.filesystem.remove(RESPONSE)
				if not payload or payload:match("^ERROR") then
					toast("Seed search failed")
					on_resolved(nil)
				else
					mod.last_seed = payload:match("%S+")
					on_resolved(mod.last_seed:upper())
				end
				return
			end
		end
	end

	-- One-time hint: where the watcher should point its --dir.
	sendInfoMessage("handshake dir: " .. love.filesystem.getSaveDirectory() .. "/" .. HANDSHAKE_DIR, "CrystalBall")
end
