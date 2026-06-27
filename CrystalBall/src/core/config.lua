--- core/config: persisted filter (clauses) -> criteria. No UI, no I/O.
--- ctx out: new_clause, save_config

return function(ctx)
	local mod = ctx.mod
	local JOKER_NAMES = ctx.joker_names

	mod.config = mod.config or {}
	mod.config.stake = 1
	mod.config.poll_frames = 15
	mod.config.debug = mod.config.debug or false -- see core/debug.lua

	-- A clause is { jokers = {center keys}, minAnte, maxAnte, atLeast }: "at least
	-- <atLeast> of these jokers in a shop within [minAnte, maxAnte]". Filter = all ANDed.

	-- Migrate the old single-list shape (target_jokers) into one clause.
	if not mod.config.clauses and mod.config.target_jokers then
		mod.config.clauses = {
			{ jokers = mod.config.target_jokers, minAnte = 1, maxAnte = 1, atLeast = #mod.config.target_jokers },
		}
		mod.config.target_jokers = nil
	end

	mod.config.clauses = mod.config.clauses or {}

	-- A blank clause (new row).
	function ctx.new_clause()
		return { jokers = {}, minAnte = 1, maxAnte = 1, atLeast = 1 }
	end

	-- Persist the mod config (no-op pre-SMODS-support).
	function ctx.save_config()
		if SMODS.save_mod_config then
			SMODS.save_mod_config(mod)
		end
	end

	-- True if any clause has a joker (something to search for).
	function mod.has_filter()
		for _, cl in ipairs(mod.config.clauses) do
			if #cl.jokers > 0 then
				return true
			end
		end
		return false
	end

	-- Clauses -> { any = { { all = {clause...} } } }. Empty clauses skipped; atLeast
	-- clamped to the joker count.
	function mod.build_criteria()
		local all = {}
		for _, cl in ipairs(mod.config.clauses) do
			if #cl.jokers > 0 then
				local of = {}
				for _, key in ipairs(cl.jokers) do
					of[#of + 1] = JOKER_NAMES[key]
				end
				all[#all + 1] = {
					atLeast = math.min(cl.atLeast or #of, #of),
					minAnte = cl.minAnte or 1,
					maxAnte = cl.maxAnte or 1,
					of = of,
				}
			end
		end
		return { any = { { all = all } } }
	end

	-- Intercept "new run" so a blank-seed run searches instead of using a random seed.
	mod.config.intercept_new_run = true

	-- Async search state, resolved through mod.poll (core/handshake.lua).
	mod.last_seed = nil
	mod.pending = nil -- { id, frames }
	mod.deferred = nil -- { e, args } captured from start_run while searching
	mod.resolving = false
end
