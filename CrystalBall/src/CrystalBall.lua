--- Crystal Ball
--- Finds a seed matching structured criteria, then starts a run on it.
---
--- The mod never executes Immolate itself (impossible to do portably from inside
--- the game, especially under Proton). Instead it does a file handshake with an
--- external `watcher.py` running on the host OS:
---
---   mod  -> writes  <savedir>/CrystalBallBackendCommunication/request.txt   (id + query JSON)
---   host watcher    runs Immolate, writes response.txt (id + seed)
---   mod  <- pollsMods/CrystalBall/   <savedir>/CrystalBallBackendCommunication/response.txt   then Game:start_run
---
--- This is identical on Linux and Windows; only the watcher's paths differ.

local mod = SMODS.current_mod

-- Map: Balatro joker center key (e.g. "j_blueprint") -> Immolate enum name
-- (e.g. "Blueprint"), the exact string item_from_name() accepts. See src/joker_names.lua.
local JOKER_NAMES = assert(SMODS.load_file("CrystalBall/src/joker_names.lua"))()

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------

mod.config = mod.config or {}
mod.config.stake = 1
mod.config.timeout = 240 -- seconds to wait for the watcher
mod.config.poll_frames = 15

local HANDSHAKE_DIR = "/Mods/CrystalBall/CrystalBallHandshake"
local REQUEST = HANDSHAKE_DIR .. "/request.txt"
local RESPONSE = HANDSHAKE_DIR .. "/response.txt"

-- The filter is a list of clauses, all ANDed together (the query's single "all"
-- group). Each clause is { jokers = {center keys}, minAnte, maxAnte, atLeast }:
-- "at least <atLeast> of these jokers appear in a shop within [minAnte, maxAnte]".
-- Edited in-game via the filter editor; persisted across sessions.
local MIN_ANTE, MAX_ANTE = 1, 39

-- Migrate the old single-list shape (target_jokers) into one clause.
if not mod.config.clauses and mod.config.target_jokers then
	mod.config.clauses = {
		{ jokers = mod.config.target_jokers, minAnte = 1, maxAnte = 1, atLeast = #mod.config.target_jokers },
	}
	mod.config.target_jokers = nil
end

mod.config.clauses = mod.config.clauses or {}

-- A blank clause (used when adding a new row).
local function new_clause()
	return { jokers = {}, minAnte = 1, maxAnte = 1, atLeast = 1 }
end

-- True if any clause has at least one joker (so there is something to search for).
function mod.has_filter()
	for _, cl in ipairs(mod.config.clauses) do
		if #cl.jokers > 0 then
			return true
		end
	end
	return false
end

-- Builds the 3-level query from the clauses. Fixed schema:
--   any = OR over groups (single group), all = AND over clauses,
--   clause = at least N of {of...} in a shop within antes [minAnte,maxAnte].
-- Empty clauses are skipped; atLeast is clamped to the joker count.
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

-- Intercept "new run" so a blank-seed run uses the search instead of a random seed.
mod.config.intercept_new_run = true

mod.last_seed = nil
mod.pending = nil -- { id, frames, started }
mod.deferred = nil -- { e, args } captured from start_run while searching
mod.resolving = false

--------------------------------------------------------------------------------
-- Criteria -> JSON (matches Immolate's query_parse.h grammar)
--------------------------------------------------------------------------------

local function clause_json(cl)
	local of = {}
	for _, name in ipairs(cl.of) do
		of[#of + 1] = string.format('"%s"', name)
	end
	return string.format(
		'{"atLeast":%d,"minAnte":%d,"maxAnte":%d,"of":[%s]}',
		cl.atLeast,
		cl.minAnte,
		cl.maxAnte,
		table.concat(of, ",")
	)
end

local function group_json(g)
	local cls = {}
	for _, cl in ipairs(g.all) do
		cls[#cls + 1] = clause_json(cl)
	end
	return string.format('{"all":[%s]}', table.concat(cls, ","))
end

function mod.query_json(criteria)
	local gs = {}
	for _, g in ipairs(criteria.any) do
		gs[#gs + 1] = group_json(g)
	end
	return string.format('{"any":[%s]}', table.concat(gs, ","))
end

--------------------------------------------------------------------------------
-- Handshake
--------------------------------------------------------------------------------

local req_counter = 0
local FILTER = "find_joker" -- query-aware Immolate filter (matches watcher.py default)

-- True only on *native* Windows. Under Proton jit.os is also "Windows" (the game is a
-- Wine process and LuaJIT reports its compile-time target), so we further check the
-- username in the save dir. From inside Wine getSaveDirectory() returns the Wine view
-- (C:/users/steamuser/AppData/Roaming/Balatro) -- the host-side drive_c/compatdata
-- components are not visible -- but Proton always runs as the fixed user "steamuser",
-- whereas native Windows uses the real account name. Native Windows => inline exec;
-- Proton => fall through to the host watcher, which can reach the GPU.
local function is_native_windows()
	if jit.os ~= "Windows" then
		return false
	end
	local save = love.filesystem.getSaveDirectory():lower()
	return not save:find("/users/steamuser/", 1, true)
end

-- Windows ships no watcher: the mod launches Immolate.exe itself. The launch must
-- be *detached* -- a blocking io.popen would freeze the game thread (and so the
-- waiting overlay) for the whole search. Instead a generated .bat runs the searcher,
-- redirects its seed to WIN_OUT, then writes WIN_DONE as a completion marker; mod.poll
-- watches for WIN_DONE (so the game keeps rendering meanwhile, exactly like the Linux
-- watcher path). All files live under HANDSHAKE_DIR (inside the love save dir), so they
-- are reachable both as OS paths (for cmd) and love.filesystem virtual paths (for poll).
local WIN_OUT = HANDSHAKE_DIR .. "/winout.txt"
local WIN_DONE = HANDSHAKE_DIR .. "/windone.txt"
local WIN_BAT = HANDSHAKE_DIR .. "/run.bat"

-- Launches Immolate.exe detached. Returns true on launch, or false + error string.
local function run_immolate_windows(query)
	love.filesystem.write(HANDSHAKE_DIR .. "/query.json", query)
	love.filesystem.remove(WIN_OUT) -- drop any stale output/marker from a prior run
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

	-- Keep all the quoting in a .bat file (avoids the nested `cmd /c ""prog" args""`
	-- escaping). The done marker holds Immolate's exit code, written only after it exits:
	-- its presence means "finished", and the code lets mod.poll tell success (0, WIN_OUT
	-- holds the seed -- possibly empty if none matched) from failure (e.g. Fatal CL Error
	-- -5 / GPU timeout), so a crash is never mistaken for a seed. The `> "file" echo` form
	-- avoids cmd reading `echo 0> file` as a stream-0 redirect.
	love.filesystem.write(
		WIN_BAT,
		"@echo off\r\n"
			.. string.format('"%s" -f %s --first -q -J "%s" > "%s"\r\n', exe, FILTER, qfile, out)
			.. string.format('> "%s" echo %%errorlevel%%\r\n', done)
	)

	-- `start "" /b` detaches the .bat: cmd returns immediately, so the game never blocks.
	-- os.execute (LuaJIT/5.1) returns the shell status; nil/false means it failed to spawn.
	local ok = os.execute(string.format('start "" /b "%s"', bat))
	if ok == nil or ok == false then
		return false, "could not launch Immolate.exe"
	end
	return true
end

-- Starts a search. On Linux/Proton this writes a request file for the host watcher;
-- on native Windows it launches Immolate.exe detached (no watcher). Either way the
-- result is resolved asynchronously through the same per-frame poller (mod.poll), so
-- the game keeps rendering the waiting overlay while the search runs.
function mod.request_seed(criteria)
	req_counter = req_counter + 1
	local id = string.format("%d-%d", os.time(), req_counter)
	local query = mod.query_json(criteria)

	love.filesystem.createDirectory(HANDSHAKE_DIR)
	love.filesystem.remove(RESPONSE) -- drop any stale result
	love.filesystem.write(REQUEST, id .. "\n" .. query .. "\n")
	mod.pending = { id = id, frames = 0, started = os.time() }

	if is_native_windows() then
		-- No watcher: launch Immolate detached and let mod.poll translate its output
		-- into a RESPONSE once the done marker appears (keeps the overlay animating).
		local ok, err = run_immolate_windows(query)
		if not ok then
			love.filesystem.write(RESPONSE, id .. "\n" .. ("ERROR: " .. err) .. "\n")
		else
			mod.pending.win_out = WIN_OUT
			mod.pending.win_done = WIN_DONE
		end
	end
end

local function toast(text, hold)
	attention_text({ text = text, scale = 0.8, hold = hold or 3, cover = G.ROOM_ATTACH, align = "cm" })
end

-- Modal "searching" overlay shown while the watcher works. no_esc forces the
-- player out through the Cancel button, so closing it always cancels the search
-- (esc would only hide it, leaving the seed to start a run later).
--
-- Styled to match attention_text (the "Seed search timed out" toast): the title
-- is an animated DynaText (float + shadow + pop-in) so it reads as the same big
-- toast, but it lives inside an overlay_menu because a toast can't host a button.
local function show_waiting_overlay()
	local title = DynaText({
		string = { "Finding seed..." },
		colours = { G.C.UI.TEXT_LIGHT },
		shadow = true,
		float = true,
		silent = true,
		pop_in = 0,
		pop_in_rate = 4,
		scale = 0.9,
	})
	G.FUNCS.overlay_menu({
		config = { no_esc = true },
		definition = {
			n = G.UIT.ROOT,
			config = { align = "cm", padding = 0.3, r = 0.1, colour = G.C.GREY, minw = 6, minh = 3 },
			nodes = {
				{
					n = G.UIT.R,
					config = { align = "cm", padding = 0.2, minh = 1 },
					nodes = {
						{ n = G.UIT.O, config = { object = title } },
					},
				},
				{
					n = G.UIT.R,
					config = { align = "cm", padding = 0.1 },
					nodes = {
						UIBox_button({
							label = { "Cancel" },
							button = "crystalball_cancel",
							colour = G.C.RED,
							minw = 3,
							minh = 0.7,
							scale = 0.5,
						}),
					},
				},
			},
		},
	})
end

-- Cancel button: abandon the in-flight search and return to the main menu.
G.FUNCS.crystalball_cancel = function(_)
	mod.pending = nil
	mod.deferred = nil
	mod.resolving = false
	G.FUNCS.exit_overlay_menu()
end

-- Called when the watcher returns a seed (or fails). Routes to either the
-- deferred new-run flow or the manual button flow.
local function on_resolved(seed) -- seed = nil on failure
	mod.resolving = false
	if G.OVERLAY_MENU then
		G.FUNCS.exit_overlay_menu() -- dismiss the waiting screen
	end
	local d = mod.deferred
	mod.deferred = nil
	if not seed then
		-- No seed: abandon the deferred new-run instead of starting a random one.
		-- The interception already returned us to the main menu, so there is
		-- nothing to do here but leave the player there (the failure toast shows).
		return
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

	-- Native-Windows inline path: once Immolate's done marker (its exit code) appears,
	-- translate the output into a RESPONSE for the shared handling below. Only a clean
	-- exit (0) AND a valid seed token count as success -- a nonzero exit (Fatal CL Error
	-- -5 / GPU timeout) or junk output resolves as a failure, never a bogus seed.
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

	if os.time() - p.started > mod.config.timeout then
		mod.pending = nil
		toast("Seed search timed out")
		on_resolved(nil)
	end
end

--------------------------------------------------------------------------------
-- Joker picker: hijacks the collection joker page to choose target jokers.
-- Click a grid joker to ADD it to the selection line (a clone of the in-game
-- owned-joker row). Click a joker IN the line to highlight it; a red "Remove"
-- button (the repurposed in-card sell button) drops it.
--------------------------------------------------------------------------------

local JOKERS_PER_PAGE = 15 -- GRID_ROWS x GRID_COLS, matching the vanilla layout
local GRID_COLS = 5 -- picker grid columns
local GRID_ROWS = 3 -- picker grid rows
local GRID_ROW_GAP = 0.18 -- vertical gap between grid rows (game units)
local GRID_SCALE = 0.75 -- collection card scale (shrunk so the line fits)
local SEL_SCALE = 0.78 -- selection-line card scale (picker): taller cards
local PREVIEW_SCALE = 0.72 -- joker-line card scale in the editor rows (readable)

mod._sel_area = nil -- live CardArea for the selection line while the picker is open
mod._sel_highlighted = nil -- the currently highlighted selection card (single)
mod._grid_highlighted = nil -- the currently highlighted grid card (single)
mod.picker_keys = {} -- working list of selected center keys; committed on close
mod._editing_clause = nil -- index of the clause the picker is editing
mod._editor_page = 1 -- current page (section) of clause rows in the editor

-- Maps a center to its Immolate enum name via center.key.
-- returns: enum name string, or nil for non-vanilla jokers (key not in the map).
local function joker_name_of(center)
	return center and center.key and JOKER_NAMES[center.key] or nil
end

-- Index of a key in picker_keys, or nil.
local function selected_index(key)
	for i, k in ipairs(mod.picker_keys) do
		if k == key then
			return i
		end
	end
	return nil
end

-- One in-card action button (the repurposed sell/use UIBox slot).
local function action_button(card, text, colour, button_fn)
	return {
		n = G.UIT.ROOT,
		config = { padding = 0, colour = G.C.CLEAR },
		nodes = {
			{
				n = G.UIT.C,
				config = {
					ref_table = card,
					align = "cm",
					padding = 0.1,
					r = 0.08,
					minw = 1.25,
					hover = true,
					shadow = true,
					colour = colour,
					one_press = true,
					button = button_fn,
				},
				nodes = {
					{ n = G.UIT.T, config = { text = text, colour = G.C.UI.TEXT_LIGHT, scale = 0.4, shadow = true } },
				},
			},
		},
	}
end

-- Replace the in-card sell/use UI with our own button. Card:highlight builds this
-- UIBox whenever a Joker-set card is highlighted, so flagging the card is enough:
--   crystalball_sel  -> red "Remove" (selection line), crystalball_grid -> green
--   "Add" (grid). Every other card defers to the original (real run jokers, etc).
local _orig_use_and_sell = G.UIDEF.use_and_sell_buttons
function G.UIDEF.use_and_sell_buttons(card)
	if card and card.crystalball_sel then
		return action_button(card, "Remove", G.C.RED, "crystalball_remove_card")
	end
	if card and card.crystalball_grid then
		return action_button(card, "Add", G.C.GREEN, "crystalball_add_card")
	end
	return _orig_use_and_sell(card)
end

-- Our picker cards carry a win sticker (set in populate_joker_page) so players see what
-- they've won with. A sticker also injects a SECOND tooltip box into the hover popup
-- (card.lua:945 -> loc_vars.sticker -> common_events.lua info_queue), and a popup holding
-- BOTH the joker description and that sticker box is what drives the side-popup flicker.
-- Blank the sticker fields just for the popup-content build (restored immediately) so the
-- tooltip omits the sticker box; Card:draw still renders the sticker sprite, since it
-- reads these fields live at draw time (after they're restored here).
local _orig_gen_ability_table = Card.generate_UIBox_ability_table
function Card:generate_UIBox_ability_table(...)
	if self.crystalball_grid or self.crystalball_sel then
		local sticker, sticker_run = self.sticker, self.sticker_run
		self.sticker, self.sticker_run = nil, nil
		local tbl = _orig_gen_ability_table(self, ...)
		self.sticker, self.sticker_run = sticker, sticker_run
		return tbl
	end
	return _orig_gen_ability_table(self, ...)
end

-- Put the hover info panel to the LEFT or RIGHT of our picker cards (stock places it
-- above/below, covering the grid row / Add button). The side is decided ONCE per card and
-- cached so it can't flip as the card floats across screen centre: grid cards use their
-- static column, others a one-shot T.x test at first hover.
local _orig_align_h_popup = Card.align_h_popup
function Card:align_h_popup()
	if self.crystalball_grid or self.crystalball_sel then
		local cfg = _orig_align_h_popup(self)
		if self.crystalball_popup_right == nil then
			if self.crystalball_grid and self.rank then
				self.crystalball_popup_right = ((self.rank - 1) % GRID_COLS) < GRID_COLS / 2
			else
				self.crystalball_popup_right = self.T.x + self.T.w / 2 < G.ROOM.T.x + G.ROOM.T.w / 2
			end
		end
		local right = self.crystalball_popup_right
		cfg.type = right and "cr" or "cl"
		cfg.offset = { x = right and 0.1 or -0.1, y = 0 }
		return cfg
	end
	return _orig_align_h_popup(self)
end

-- Pull the grid card's "Add" button closer to the card. Card:highlight anchors the
-- use/sell UIBox "bmi" with a fixed offset.y = 0.65 (card.lua:4594); on the smaller
-- grid card that reads as a larger gap than the selection row's "Remove". Trim the
-- offset for grid cards so the two buttons sit the same distance below their card.
local _orig_card_highlight = Card.highlight
function Card:highlight(is_highlighted)
	_orig_card_highlight(self, is_highlighted)
	if is_highlighted and self.crystalball_grid and self.children.use_button then
		self.children.use_button.config.offset.y = 0.58
	end
end

-- Single-highlight a card within a group, toggling off if already highlighted.
-- holder[field] tracks the group's current highlight. Drives Card:highlight
-- directly to avoid CardArea highlight machinery, which only runs for 'joker'/
-- 'hand' areas and reaches into the run-only G.jokers (nil on the menu => crash).
local function toggle_highlight(card, holder, field)
	local cur = holder[field]
	if cur and cur ~= card then
		cur:highlight(false)
	end
	if card.highlighted then
		card:highlight(false)
		holder[field] = nil
	else
		card:highlight(true)
		holder[field] = card
		-- The grid is a single title_2 CardArea, which draws the highlighted card LAST
		-- (cardarea.lua:331-345), so its Add button (anchored "bmi" => below the card by
		-- Card:highlight) paints on top of every neighbour - no per-row z-fighting.
	end
end

-- Builds a selection-line card for a center. Spawns at (x, y) so it animates in
-- from there (the grid card / click point) rather than the top-left corner.
-- interactive cards highlight on click (single-select) to surface the Remove
-- button; the config-tab preview passes interactive=false for a static row.
local function make_sel_card(center, x, y, interactive, scale)
	scale = scale or SEL_SCALE
	local card = Card(x or 0, y or 0, scale * G.CARD_W, scale * G.CARD_H, nil, center, {
		bypass_discovery_center = true,
		bypass_discovery_ui = true,
	})
	if interactive then
		card.crystalball_sel = true
		card.states.click.can = true
		card.click = function(self)
			toggle_highlight(self, mod, "_sel_highlighted")
		end
	end
	return card
end

-- Add a joker to the live selection (no-op if already present). x,y = spawn
-- origin for the fly-in animation (the clicked grid card's position).
function mod.add_joker(center, x, y)
	local name = joker_name_of(center)
	if not name then
		play_sound("cancel")
		return
	end
	if selected_index(center.key) then
		play_sound("cancel") -- already selected; remove via the on-card Remove button
		return
	end
	mod._sel_area:emplace(make_sel_card(center, x, y, true))
	mod.picker_keys[#mod.picker_keys + 1] = center.key
	play_sound("cardSlide1", 1, 0.3)
end

-- Remove button (on the highlighted selection card): drop it from the selection.
G.FUNCS.crystalball_remove_card = function(e)
	local card = e and e.config and e.config.ref_table
	if not card then
		return
	end
	local key = card.config.center and card.config.center.key
	if mod._sel_highlighted == card then
		mod._sel_highlighted = nil
	end
	local area = card.area
	if area then
		local rc = area:remove_card(card);
		(rc or card):remove()
	else
		card:remove()
	end
	local i = key and selected_index(key)
	if i then
		table.remove(mod.picker_keys, i)
	end
	play_sound("cardSlide2", 1, 0.3)
end

-- Add button (on the highlighted grid card): add it to the selection. Spawns the
-- new selection card from the grid card's position, then drops the highlight so
-- the Add button disappears.
G.FUNCS.crystalball_add_card = function(e)
	local card = e and e.config and e.config.ref_table
	if not card then
		return
	end
	mod.add_joker(card.config.center, card.T.x, card.T.y)
	if mod._grid_highlighted == card then
		mod._grid_highlighted = nil
	end
	card:highlight(false)
end

-- Drop a surfaced Add/Remove button when the user clicks anything that isn't the
-- highlighted card or its button. Runs per-frame (ui.lua:948) off a node in the
-- picker overlay; fires on the rising edge of a cursor press and inspects what was
-- pressed (G.CONTROLLER.cursor_down.target: a Card for card clicks, a UIElement for
-- button clicks, G.ROOM for empty space). The card / button cases self-resolve in
-- the click handlers before this runs, so in practice this catches "clicked away".
local function dismiss_if_outside(field, tgt)
	local hi = mod[field]
	if not hi then
		return
	end
	if tgt == hi then
		return -- pressed the highlighted card itself; its click() toggles it
	end
	local btn = hi.children and hi.children.use_button
	if btn and tgt and tgt.UIBox == btn then
		return -- pressed our Add/Remove button; its handler runs
	end
	hi:highlight(false)
	mod[field] = nil
end

G.FUNCS.crystalball_dismiss_outside = function(_)
	local C = G.CONTROLLER
	local down = C.is_cursor_down
	if down and not mod._was_cursor_down then
		local tgt = C.cursor_down and C.cursor_down.target
		dismiss_if_outside("_grid_highlighted", tgt)
		dismiss_if_outside("_sel_highlighted", tgt)
	end
	mod._was_cursor_down = down
end

-- Lays the picker grid's cards into a GRID_ROWS x GRID_COLS grid. Installed as the
-- area's align_cards (called every frame via CardArea:move) so it stays gridded;
-- the stock title_2 branch would collapse the cards onto one line. card index k (in
-- emplace order) maps to row floor((k-1)/cols), col (k-1)%cols.
local function grid_align_cards(self)
	-- Uniform cell width: some jokers (e.g. Wee Joker) carry a smaller card.T.w, so
	-- stepping by the card's own width would misplace it into the previous column.
	local cell_w = self.config.card_w
	local cell_h = GRID_SCALE * G.CARD_H
	for k, card in ipairs(self.cards) do
		local r = math.floor((k - 1) / GRID_COLS)
		local c = (k - 1) % GRID_COLS
		if not card.states.drag.is then
			card.T.r = 0
			-- Centre within the cell: smaller cards (e.g. Wee Joker carry a reduced
			-- card.T.w/h) would otherwise sit in the cell's top-left corner.
			-- NB: do NOT add card.shadow_parrallax.x here. That parallax is driven by the
			-- hover tilt (the card leans toward the cursor); feeding it back into the card's
			-- target X makes a hovered card's position depend on its own tilt, a lagged
			-- feedback loop that wobbles the card -- and its glued info popup -- left/right.
			card.T.x = self.T.x + c * cell_w + (cell_w - card.T.w) / 2
			card.T.y = self.T.y + r * (cell_h + GRID_ROW_GAP) + (cell_h - card.T.h) / 2
		end
		card.rank = k
	end
end

-- (Re)builds the cards for one page into the single grid CardArea, wiring each to
-- highlight-on-click (surfacing its green Add button). Shared by the initial build
-- and paging.
local function populate_joker_page(page)
	page = page or 1
	mod._grid_highlighted = nil
	local area = mod._grid_area
	for i = #area.cards, 1, -1 do
		local c = area:remove_card(area.cards[i])
		c:remove()
	end
	for k = 1, JOKERS_PER_PAGE do
		local center = G.P_CENTER_POOLS["Joker"][k + JOKERS_PER_PAGE * (page - 1)]
		if not center then
			break
		end
		local card = Card(area.T.x, area.T.y, GRID_SCALE * G.CARD_W, GRID_SCALE * G.CARD_H, G.P_CARDS.empty, center)
		card.sticker = get_joker_win_sticker(center)
		-- Collection cards aren't highlightable by default, so make them a click
		-- target and drive highlight manually to surface the Add button.
		card.crystalball_grid = true
		card.states.click.can = true
		card.click = function(self)
			toggle_highlight(self, mod, "_grid_highlighted")
		end
		area:emplace(card)
	end
	INIT_COLLECTION_CARD_ALERTS()
end

-- Paging callback for the picker's option cycle.
G.FUNCS.crystalball_joker_page = function(args)
	if not args or not args.cycle_config then
		return
	end
	populate_joker_page(args.cycle_config.current_option)
end

-- Commit the working selection into the clause being edited, then return to the
-- filter editor. A clause left empty (e.g. a freshly-added row) is dropped.
G.FUNCS.crystalball_picker_back = function(_)
	local idx = mod._editing_clause
	local cl = idx and mod.config.clauses[idx]
	if cl then
		cl.jokers = {}
		for i, k in ipairs(mod.picker_keys) do
			cl.jokers[i] = k
		end
		cl.atLeast = math.max(1, #cl.jokers) -- default: require all chosen jokers
		if #cl.jokers == 0 then
			table.remove(mod.config.clauses, idx)
		end
	end
	if SMODS.save_mod_config then
		SMODS.save_mod_config(mod)
	end
	mod._sel_area = nil
	mod._grid_area = nil
	G.your_collection = nil
	mod._sel_highlighted = nil
	mod._grid_highlighted = nil
	mod._editing_clause = nil
	mod.show_filter_editor()
end

local SEL_LIMIT = 10 -- selection-line capacity (no hard selection cap; line compresses)
local SEL_SPAN = 6.5 -- selection-line width in card-widths: < SEL_LIMIT so the rack
-- stays thin and the cards pack/overlap tighter rather than spreading out.

-- Builds a joker-row CardArea from a list of center keys (the owned-joker line).
-- Always type 'title_2' (a passive collection-style row) to avoid the run-only
-- 'joker'-area code paths. clickable=true cards highlight on click and surface the
-- Remove button; clickable=false is a static preview (config tab).
local function build_joker_line(keys, clickable, scale)
	scale = scale or SEL_SCALE
	-- The clickable picker line keeps a fixed capacity (cards stream in); the static
	-- preview sizes to its contents so the jokers sit snug instead of spread across
	-- the full SEL_LIMIT width.
	local n = #keys
	local cap = clickable and SEL_LIMIT or math.max(1, n)
	-- title_2 has a special exactly-2-cards branch (cardarea.lua) that packs them at
	-- 25%/75% of the area; at a 2-wide area that overlaps, so widen to 3 for n==2.
	-- The static preview's width is capped at PREVIEW_MAX_SPAN cards: beyond that the
	-- cards compress (overlap) into the fixed width instead of the row growing wider.
	local PREVIEW_MAX_SPAN = 5
	local span = clickable and SEL_SPAN or (n == 2 and 3 or math.max(1, math.min(n, PREVIEW_MAX_SPAN)))
	local area = CardArea(0, 0, span * scale * G.CARD_W, scale * G.CARD_H, {
		card_limit = cap,
		card_w = scale * G.CARD_W,
		type = "title_2",
		highlight_limit = 0,
	})
	for _, key in ipairs(keys) do
		local center = G.P_CENTERS[key]
		if center then
			area:emplace(make_sel_card(center, nil, nil, clickable, scale))
		end
	end
	return area
end

-- Builds and shows the picker overlay (a clickable clone of the joker collection
-- with a live selection line beneath it). Edits clause `idx`.
function mod.show_joker_picker(idx)
	mod._editing_clause = idx
	-- Seed the working selection from the clause being edited.
	mod.picker_keys = {}
	mod._sel_highlighted = nil
	mod._grid_highlighted = nil
	mod._was_cursor_down = false -- edge tracker for crystalball_dismiss_outside
	local cl = idx and mod.config.clauses[idx]
	for i, k in ipairs(cl and cl.jokers or {}) do
		mod.picker_keys[i] = k
	end

	-- One CardArea for the whole page (not three stacked rows). Within a single
	-- title_2 area the highlighted card draws LAST (cardarea.lua:331-345), so its
	-- green Add button - anchored BELOW the card - paints on top of every neighbour.
	-- grid_align_cards (installed below) lays the cards out as a GRID_ROWS x GRID_COLS
	-- grid; the stock title_2 layout would put them on one line.
	local cw, ch = GRID_SCALE * G.CARD_W, GRID_SCALE * G.CARD_H
	mod._grid_area = CardArea(
		G.ROOM.T.x + 0.2 * G.ROOM.T.w / 2,
		G.ROOM.T.h,
		GRID_COLS * cw,
		GRID_ROWS * ch + (GRID_ROWS - 1) * GRID_ROW_GAP,
		{ card_limit = JOKERS_PER_PAGE, card_w = cw, type = "title_2", highlight_limit = 0, collection = true }
	)
	mod._grid_area.align_cards = grid_align_cards
	-- INIT_COLLECTION_CARD_ALERTS iterates G.your_collection (button_callbacks.lua:1198);
	-- register our single area there so win-sticker alerts initialise without crashing.
	G.your_collection = { mod._grid_area }
	-- draw_layer defers this node's draw to after all normal overlay nodes
	-- (ui.lua:295), so the grid - and the highlighted card's Add button hanging below
	-- it - paints ON TOP of the page-cycle buttons instead of being covered by them.
	local deck_table = {
		n = G.UIT.R,
		config = { align = "cm", padding = 0.04, no_fill = true },
		nodes = { { n = G.UIT.O, config = { object = mod._grid_area, draw_layer = 1 } } },
	}

	local pages = {}
	local num_pages = math.ceil(#G.P_CENTER_POOLS.Joker / JOKERS_PER_PAGE)
	for i = 1, num_pages do
		pages[i] = localize("k_page") .. " " .. tostring(i) .. "/" .. tostring(num_pages)
	end

	populate_joker_page(1)
	mod._sel_area = build_joker_line(mod.picker_keys, true)

	G.FUNCS.overlay_menu({
		definition = create_UIBox_generic_options({
			back_func = "crystalball_picker_back",
			contents = {
				{
					n = G.UIT.R,
					config = {
						align = "cm",
						padding = 0.03,
						r = 0.1,
						colour = G.C.BLACK,
						emboss = 0.05,
						-- Per-frame watcher: clears a surfaced Add/Remove button on a click away.
						func = "crystalball_dismiss_outside",
					},
					nodes = { deck_table },
				},
				{
					n = G.UIT.R,
					config = { align = "cm", padding = 0 },
					nodes = {
						create_option_cycle({
							options = pages,
							w = 2.9,
							scale = 0.74,
							cycle_shoulders = true,
							opt_callback = "crystalball_joker_page",
							current_option = 1,
							colour = G.C.RED,
							no_pips = true,
							focus_args = { snap_to = true, nav = "wide" },
						}),
					},
				},
				-- Selection line (owned-joker row clone). Click a joker here to surface
				-- its red Remove button.
				{
					n = G.UIT.R,
					config = {
						align = "cm",
						minh = SEL_SCALE * G.CARD_H + 0.15,
						minw = 5,
						r = 0.1,
						colour = G.C.UI.TRANSPARENT_DARK,
						padding = 0.05,
					},
					nodes = {
						{ n = G.UIT.O, config = { object = mod._sel_area } },
					},
				},
			},
		}),
	})
end

--------------------------------------------------------------------------------
-- Filter editor: a vertical list of clause rows (jokers + min/max ante + atLeast
-- + edit/delete), all ANDed. "Add row" appends a clause. Rebuilt on every edit.
--------------------------------------------------------------------------------

local ROWS_PER_PAGE = 3 -- clause rows per section; flick between sections via < >

local function clamp(v, lo, hi)
	return math.max(lo, math.min(v or lo, hi))
end

local function save_config()
	if SMODS.save_mod_config then
		SMODS.save_mod_config(mod)
	end
end

-- A small labelled action button (Edit / Delete / Add row / scroll). C node so it
-- sits horizontally alongside the option cycles. When disabled it renders greyed
-- out and inert (no hover, no callback) - used for scroll arrows at the extremes.
local function ui_button(text, colour, button_fn, ref, disabled)
	return {
		n = G.UIT.C,
		config = { align = "cm", padding = 0.05 },
		nodes = {
			{
				n = G.UIT.C,
				config = {
					ref_table = ref,
					align = "cm",
					padding = 0.1,
					r = 0.08,
					minw = 1.7,
					minh = 0.7,
					hover = not disabled,
					shadow = not disabled,
					colour = disabled and G.C.UI.BACKGROUND_INACTIVE or colour,
					one_press = not disabled or nil,
					button = not disabled and button_fn or nil,
				},
				nodes = {
					{
						n = G.UIT.T,
						config = {
							text = text,
							colour = disabled and G.C.UI.TEXT_INACTIVE or G.C.UI.TEXT_LIGHT,
							scale = 0.5,
							shadow = true,
						},
					},
				},
			},
		},
	}
end

-- Whether the move (kind,delta) would violate a bound, given the clause's current
-- values. Recomputed live (see crystalball_arrow_vis) so the arrow greys without a
-- full overlay rebuild.
local function arrow_disabled(cl, kind, delta)
	local njokers = math.max(1, #cl.jokers)
	local minA = clamp(cl.minAnte, MIN_ANTE, MAX_ANTE)
	local maxA = clamp(cl.maxAnte, MIN_ANTE, MAX_ANTE)
	local atL = clamp(cl.atLeast, 1, njokers)
	if kind == "minante" then
		return delta < 0 and minA <= MIN_ANTE or (delta > 0 and minA >= maxA)
	elseif kind == "maxante" then
		return delta < 0 and maxA <= minA or (delta > 0 and maxA >= MAX_ANTE)
	else -- numjokers
		return delta < 0 and atL <= 1 or (delta > 0 and atL >= njokers)
	end
end

-- A single < or > stepper arrow. The button stays live always (crystalball_step
-- clamps, so a press at a bound is a harmless no-op); crystalball_arrow_vis greys it
-- in place each frame when the bound is hit, avoiding a whole-overlay rebuild.
local function step_arrow(glyph, cl, kind, delta, disp)
	local dis = arrow_disabled(cl, kind, delta)
	return {
		n = G.UIT.C,
		config = {
			align = "cm",
			r = 0.1,
			minw = 0.4,
			minh = 0.55,
			padding = 0.04,
			hover = true,
			shadow = true,
			colour = dis and G.C.UI.BACKGROUND_INACTIVE or G.C.RED,
			one_press = true,
			button = "crystalball_step",
			func = "crystalball_arrow_vis",
			ref_table = { cl = cl, kind = kind, delta = delta, disp = disp },
		},
		nodes = {
			{
				n = G.UIT.T,
				config = {
					text = glyph,
					scale = 0.42,
					colour = dis and G.C.UI.TEXT_INACTIVE or G.C.UI.TEXT_LIGHT,
					shadow = true,
				},
			},
		},
	}
end

-- A labelled [< value >] stepper. C node so it flows horizontally beside siblings.
-- `disp` is a per-row display table; the value text live-binds to disp[kind] (ui.lua
-- update_text re-renders when it changes) so crystalball_step can update one field in
-- place rather than rebuilding the whole editor overlay.
local function stepper(label, cl, kind, disp)
	return {
		n = G.UIT.C,
		config = { align = "cm", padding = 0.1 },
		nodes = {
			{
				n = G.UIT.R,
				config = { align = "cm" },
				nodes = { { n = G.UIT.T, config = { text = label, scale = 0.36, colour = G.C.UI.TEXT_LIGHT } } },
			},
			{
				n = G.UIT.R,
				config = { align = "cm", padding = 0.02 },
				nodes = {
					step_arrow("<", cl, kind, -1, disp),
					{
						n = G.UIT.C,
						config = {
							align = "cm",
							minw = 0.75,
							minh = 0.55,
							r = 0.1,
							colour = G.C.RED,
							emboss = 0.1,
							padding = 0.05,
						},
						nodes = {
							{
								n = G.UIT.R,
								config = { align = "cm" },
								nodes = {
									{
										n = G.UIT.T,
										config = {
											ref_table = disp,
											ref_value = kind,
											scale = 0.42,
											colour = G.C.UI.TEXT_LIGHT,
											shadow = true,
										},
									},
								},
							},
						},
					},
					step_arrow(">", cl, kind, 1, disp),
				},
			},
		},
	}
end

-- One clause row: joker preview (left) beside the controls (right). Controls stack
-- two rows vertically - the steppers on top, Edit/Delete beneath them.
local function build_clause_row(cl, idx)
	local has = #cl.jokers > 0
	local njokers = math.max(1, #cl.jokers)
	local minA = clamp(cl.minAnte, MIN_ANTE, MAX_ANTE)
	local maxA = clamp(cl.maxAnte, MIN_ANTE, MAX_ANTE)
	local atL = clamp(cl.atLeast, 1, njokers)
	-- "Num matches" reads ">=N", or "All" when it equals the joker count.
	-- "\226\137\165" is the UTF-8 for the >= glyph (U+2265).
	local num_text = (atL >= #cl.jokers and has) and "All" or ("\226\137\165" .. atL)
	-- Live display strings, keyed by stepper `kind`; crystalball_step mutates these so
	-- the value text updates without rebuilding the overlay.
	local disp = { minante = tostring(minA), maxante = tostring(maxA), numjokers = num_text }
	local line_node = has and { n = G.UIT.O, config = { object = build_joker_line(cl.jokers, false, PREVIEW_SCALE) } }
		or { n = G.UIT.T, config = { text = localize("k_none"), scale = 0.5, colour = G.C.UI.TEXT_LIGHT } }
	return {
		n = G.UIT.R,
		config = { align = "cm", padding = 0.05, r = 0.1, colour = G.C.L_BLACK, emboss = 0.05, minw = 8 },
		nodes = {
			-- joker line (left). C sibling so it flows horizontally beside the controls.
			{
				n = G.UIT.C,
				config = {
					align = "cm",
					minh = PREVIEW_SCALE * G.CARD_H,
					minw = 2,
					r = 0.1,
					colour = G.C.UI.TRANSPARENT_DARK,
					padding = 0.05,
				},
				nodes = { line_node },
			},
			-- controls (right). C sibling => sits to the right of the preview; its two
			-- R children stack vertically (steppers above, action buttons below).
			{
				n = G.UIT.C,
				config = { align = "cm", padding = 0.05 },
				nodes = {
					{
						n = G.UIT.R,
						config = { align = "cm", padding = 0.03 },
						nodes = {
							stepper("Min ante", cl, "minante", disp),
							stepper("Max ante", cl, "maxante", disp),
							stepper("Num matches", cl, "numjokers", disp),
						},
					},
					{
						n = G.UIT.R,
						config = { align = "cm", padding = 0.03 },
						nodes = {
							ui_button("Edit", G.C.BLUE, "crystalball_edit_clause", { idx = idx }),
							ui_button("Delete", G.C.RED, "crystalball_delete_clause", { idx = idx }),
						},
					},
				},
			},
		},
	}
end

-- Builds and shows the filter editor overlay. `instant` suppresses the overlay
-- slide-in (overlay_menu defaults to offset y=10, easing up from below) so an
-- in-place re-render after a stepper press doesn't replay the pop-up animation.
function mod.show_filter_editor(instant)
	local contents = {
		{
			n = G.UIT.R,
			config = { align = "cm", padding = 0.02 },
			nodes = {
				{
					n = G.UIT.T,
					config = { text = "Seed filter (all rows must match)", scale = 0.6, colour = G.C.UI.TEXT_LIGHT },
				},
			},
		},
	}
	local total = #mod.config.clauses
	local num_pages = math.max(1, math.ceil(total / ROWS_PER_PAGE))
	mod._editor_page = clamp(mod._editor_page, 1, num_pages)
	local first = (mod._editor_page - 1) * ROWS_PER_PAGE + 1
	local last = math.min(total, mod._editor_page * ROWS_PER_PAGE)

	-- Section flicker (< >): only when the rows span more than one page.
	if num_pages > 1 then
		local pages = {}
		for i = 1, num_pages do
			pages[i] = localize("k_page") .. " " .. i .. "/" .. num_pages
		end
		contents[#contents + 1] = {
			n = G.UIT.R,
			config = { align = "cm", padding = 0.02 },
			nodes = {
				create_option_cycle({
					options = pages,
					current_option = mod._editor_page,
					cycle_shoulders = true,
					opt_callback = "crystalball_editor_page",
					w = 2.5,
					scale = 0.7,
					no_pips = true,
					focus_args = { snap_to = true, nav = "wide" },
				}),
			},
		}
	end

	-- Wrap rows in a container: inter-row gap = the container's padding (the engine
	-- inserts the PARENT's padding between children, ui.lua:188-197), not each row's.
	local rows = {}
	for i = first, last do
		rows[#rows + 1] = build_clause_row(mod.config.clauses[i], i)
	end
	contents[#contents + 1] = { n = G.UIT.R, config = { align = "cm", padding = 0.13 }, nodes = rows }
	contents[#contents + 1] = {
		n = G.UIT.R,
		config = { align = "cm", padding = 0.03 },
		nodes = { ui_button("+ Add row", G.C.GREEN, "crystalball_add_clause", nil) },
	}
	G.FUNCS.overlay_menu({
		definition = create_UIBox_generic_options({ back_func = "exit_overlay_menu", contents = contents }),
		config = instant and { offset = { x = 0, y = 0 } } or nil,
	})
end

-- Stepper callback: nudge a clause field by +-1, clamped to its bound, persist, and
-- re-render (so the arrows re-grey at the new extremes). The disabled-arrow guard in
-- build_clause_row already blocks moves that would violate min<=max; the clamp here
-- is belt-and-braces.
G.FUNCS.crystalball_step = function(e)
	local r = e and e.config and e.config.ref_table
	local cl = r and r.cl
	if not cl then
		return
	end
	local disp = r.disp
	if r.kind == "minante" then
		cl.minAnte = clamp((cl.minAnte or MIN_ANTE) + r.delta, MIN_ANTE, cl.maxAnte or MAX_ANTE)
		if disp then
			disp.minante = tostring(cl.minAnte)
		end
	elseif r.kind == "maxante" then
		cl.maxAnte = clamp((cl.maxAnte or MAX_ANTE) + r.delta, cl.minAnte or MIN_ANTE, MAX_ANTE)
		if disp then
			disp.maxante = tostring(cl.maxAnte)
		end
	elseif r.kind == "numjokers" then
		cl.atLeast = clamp((cl.atLeast or 1) + r.delta, 1, math.max(1, #cl.jokers))
		if disp then
			disp.numjokers = (cl.atLeast >= #cl.jokers and #cl.jokers > 0) and "All" or ("\226\137\165" .. cl.atLeast)
		end
	end
	save_config()
	-- Rebuild the editor so the pressed arrow (a one_press node) re-arms: without a
	-- rebuild it fires at most once (the value live-binds via `disp`, but the button
	-- stays latched). This matches Edit/Delete/page buttons, which rebuild and so stay
	-- clickable. instant=true suppresses the slide-in; the `disp` updates above are now
	-- redundant but harmless.
	mod.show_filter_editor(true)
end

-- Per-frame visual refresh for a stepper arrow: greys it (and its glyph) when the
-- move would breach a bound. Runs each frame because the node carries a `button`
-- (ui.lua:463). The button stays live; crystalball_step clamps, so a bound press no-ops.
G.FUNCS.crystalball_arrow_vis = function(e)
	local r = e.config.ref_table
	if not (r and r.cl) then
		return
	end
	local dis = arrow_disabled(r.cl, r.kind, r.delta)
	e.config.colour = dis and G.C.UI.BACKGROUND_INACTIVE or G.C.RED
	local glyph = e.children and e.children[1]
	if glyph and glyph.config then
		glyph.config.colour = dis and G.C.UI.TEXT_INACTIVE or G.C.UI.TEXT_LIGHT
	end
end

-- Flick to another editor section (page).
G.FUNCS.crystalball_editor_page = function(args)
	if not args or not args.cycle_config then
		return
	end
	mod._editor_page = args.to_key
	mod.show_filter_editor(true)
end

-- Edit a clause's jokers (opens the picker; returns here on back).
G.FUNCS.crystalball_edit_clause = function(e)
	local idx = e and e.config and e.config.ref_table and e.config.ref_table.idx
	if idx then
		mod.show_joker_picker(idx)
	end
end

-- Delete a clause row.
G.FUNCS.crystalball_delete_clause = function(e)
	local idx = e and e.config and e.config.ref_table and e.config.ref_table.idx
	if idx then
		table.remove(mod.config.clauses, idx)
		save_config()
		mod.show_filter_editor(true)
	end
end

-- Add a new (empty) clause and immediately pick its jokers. Jump to the section
-- holding the new row so it is in view when we come back from the picker.
G.FUNCS.crystalball_add_clause = function(_)
	mod.config.clauses[#mod.config.clauses + 1] = new_clause()
	mod._editor_page = math.ceil(#mod.config.clauses / ROWS_PER_PAGE)
	mod.show_joker_picker(#mod.config.clauses)
end

-- Mod config tab (Mods > Crystal Ball > Config): a button into the filter editor.
function mod.config_tab()
	return {
		n = G.UIT.ROOT,
		config = { align = "cm", padding = 0.1, colour = G.C.CLEAR },
		nodes = {
			{
				n = G.UIT.R,
				config = { align = "cm", padding = 0.1 },
				nodes = {
					{
						n = G.UIT.T,
						config = {
							text = #mod.config.clauses .. " filter row(s) set",
							scale = 0.5,
							colour = G.C.UI.TEXT_LIGHT,
						},
					},
				},
			},
			{
				n = G.UIT.R,
				config = { align = "cm", padding = 0.1 },
				nodes = {
					UIBox_button({
						label = { "Edit seed filter" },
						button = "crystalball_open_editor",
						colour = G.C.BLUE,
						minw = 4,
						minh = 0.8,
						scale = 0.5,
					}),
				},
			},
		},
	}
end

G.FUNCS.crystalball_open_editor = function(_)
	mod._editor_page = 1
	mod.show_filter_editor()
end

--------------------------------------------------------------------------------
-- Start a run on a seed
--------------------------------------------------------------------------------

function mod.start_seeded_run(seed)
	if not seed or seed == "" then
		return false
	end
	if G.STAGE == G.STAGES.RUN then
		G:delete_run()
	end
	G:start_run({ stake = mod.config.stake, seed = seed:upper() })
	return true
end

--------------------------------------------------------------------------------
-- Frame poll hook
--------------------------------------------------------------------------------

local game_update = Game.update
function Game:update(dt)
	game_update(self, dt)
	mod.poll()
end

--------------------------------------------------------------------------------
-- New-run interception: a blank-seed run resolves a seed via the search first
--------------------------------------------------------------------------------

-- start_run is the engine entry for "begin a run" (the new-run / play buttons).
-- We intercept only blank-seed, non-challenge runs: defer them, kick off a
-- search, and let mod.poll resume the real start_run once a seed comes back.
mod._orig_start_run = G.FUNCS.start_run
G.FUNCS.start_run = function(e, args)
	args = args or {}
	local have_target = mod.config.intercept_new_run and mod.has_filter()
	if have_target and not args.seed and not args.challenge then
		if mod.resolving then
			return
		end -- already searching; ignore re-clicks
		mod.deferred = { e = e, args = args }
		mod.resolving = true
		mod.request_seed(mod.build_criteria())
		show_waiting_overlay() -- modal with a Cancel button; closed by on_resolved
		return -- deferred; mod.poll resumes the run
	end
	return mod._orig_start_run(e, args)
end

-- One-time hint: where the watcher should point its --dir.
sendInfoMessage("handshake dir: " .. love.filesystem.getSaveDirectory() .. "/" .. HANDSHAKE_DIR, "CrystalBall")
