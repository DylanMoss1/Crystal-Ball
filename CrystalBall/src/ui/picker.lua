--- ui/picker: joker picker -- hijacks the collection joker page to choose target jokers.
--- Click a grid joker to Add it to the selection line; click a line joker to highlight,
--- then Remove. Add/Remove reuse the in-card sell/use button slot.

return function(ctx)
	local mod = ctx.mod
	local JOKER_NAMES = ctx.joker_names
	local make_sel_card = ctx.make_sel_card
	local build_joker_line = ctx.build_joker_line
	local toggle_highlight = ctx.toggle_highlight

	local JOKERS_PER_PAGE = 15 -- GRID_ROWS x GRID_COLS
	local GRID_COLS = 5
	local GRID_ROWS = 3
	local GRID_ROW_GAP = 0.18 -- vertical gap between grid rows (game units)
	local GRID_SCALE = 0.75 -- collection card scale (shrunk so the line fits)

	mod._sel_area = nil -- live selection-line CardArea while the picker is open
	mod._sel_highlighted = nil -- highlighted selection card (single)
	mod._grid_highlighted = nil -- highlighted grid card (single)
	mod.picker_keys = {} -- working selection; committed on close
	mod._editing_clause = nil -- clause index being edited

	-- center -> Immolate enum name, or nil for non-vanilla jokers (key not in the map).
	local function joker_name_of(center)
		return center and center.key and JOKER_NAMES[center.key] or nil
	end

	-- Unlocked iff the game would not draw the j_locked sprite (see card.lua set_sprites).
	-- Locked jokers stay visible in the grid but can't be highlighted or added.
	local function is_unlocked(center)
		return center and center.unlocked ~= false
	end

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

	-- Card:highlight builds the use/sell UIBox for any highlighted Joker card, so flagging
	-- the card swaps in our button: crystalball_sel => Remove, crystalball_grid => Add.
	-- Everything else (real run jokers) defers to the original.
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

	-- Our cards carry a win sticker, which injects a second tooltip box into the hover
	-- popup -- the joker desc + sticker box together drive a side-popup flicker. Blank the
	-- sticker fields just for the popup build (restored at once); Card:draw still renders
	-- the sprite, reading these live at draw time.
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

	-- Put the hover popup LEFT/RIGHT of our cards (stock places it above/below, covering
	-- the grid / Add button). Side is decided once and cached so it can't flip as the card
	-- floats across centre: grid cards use their column, others a one-shot T.x test.
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

	-- Card:highlight anchors the Add button with a fixed offset.y = 0.65; on the smaller
	-- grid card that gaps too wide. Trim it so Add sits as close as the line's Remove.
	local _orig_card_highlight = Card.highlight
	function Card:highlight(is_highlighted)
		_orig_card_highlight(self, is_highlighted)
		if is_highlighted and self.crystalball_grid and self.children.use_button then
			self.children.use_button.config.offset.y = 0.58
		end
	end

	-- Add a joker to the live selection (no-op if already there). x,y = fly-in origin.
	function mod.add_joker(center, x, y)
		local name = joker_name_of(center)
		if not name then
			play_sound("cancel")
			return
		end
		if not is_unlocked(center) then
			play_sound("cancel") -- locked joker; not yet unlocked on this profile
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

	-- Remove button (on the highlighted selection card): drop it.
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

	-- Add button (on the highlighted grid card): add it, spawning from the grid card.
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

	-- Drop a surfaced Add/Remove button when the user clicks away (not the highlighted
	-- card or its button). Runs per-frame off a picker-overlay node; card/button clicks
	-- self-resolve in their handlers first, so this catches "clicked elsewhere".
	local function dismiss_if_outside(field, tgt)
		local hi = mod[field]
		if not hi then
			return
		end
		if tgt == hi then
			return -- the card itself; its click() toggles it
		end
		local btn = hi.children and hi.children.use_button
		if btn and tgt and tgt.UIBox == btn then
			return -- our Add/Remove button; its handler runs
		end
		hi:highlight(false)
		mod[field] = nil
	end

	G.FUNCS.crystalball_dismiss_outside = function(_)
		local C = G.CONTROLLER
		local down = C.is_cursor_down
		if down and not mod._was_cursor_down then -- rising edge of a press
			local tgt = C.cursor_down and C.cursor_down.target
			dismiss_if_outside("_grid_highlighted", tgt)
			dismiss_if_outside("_sel_highlighted", tgt)
		end
		mod._was_cursor_down = down
	end

	-- Lay the grid into GRID_ROWS x GRID_COLS (installed as align_cards, run every frame;
	-- stock title_2 would collapse to one line). Uniform cell width -- some jokers carry a
	-- smaller card.T.w and stepping by it would misplace them a column over.
	local function grid_align_cards(self)
		local cell_w = self.config.card_w
		local cell_h = GRID_SCALE * G.CARD_H
		for k, card in ipairs(self.cards) do
			local r = math.floor((k - 1) / GRID_COLS)
			local c = (k - 1) % GRID_COLS
			if not card.states.drag.is then
				card.T.r = 0
				-- Centre within the cell. Do NOT add shadow_parrallax.x -- it's hover-tilt
				-- driven, and feeding it back makes position depend on tilt (a wobble loop).
				card.T.x = self.T.x + c * cell_w + (cell_w - card.T.w) / 2
				card.T.y = self.T.y + r * (cell_h + GRID_ROW_GAP) + (cell_h - card.T.h) / 2
			end
			card.rank = k
		end
	end

	-- (Re)build one page into the grid CardArea, wiring each card to highlight-on-click.
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
			card.crystalball_grid = true
			-- Locked jokers render (as the j_locked sprite) but stay unclickable, so the Add
			-- button never surfaces -- can't select a joker you haven't unlocked.
			if is_unlocked(center) then
				card.states.click.can = true -- collection cards aren't clickable by default
				card.click = function(self)
					toggle_highlight(self, mod, "_grid_highlighted")
				end
			end
			area:emplace(card)
		end
		-- INIT_COLLECTION_CARD_ALERTS iterates G.your_collection; scope it to JUST our grid
		-- for this one pass so the global isn't left clobbered (deck carousel reads it).
		local saved_collection = G.your_collection
		G.your_collection = { mod._grid_area }
		INIT_COLLECTION_CARD_ALERTS()
		G.your_collection = saved_collection
	end

	G.FUNCS.crystalball_joker_page = function(args)
		if not args or not args.cycle_config then
			return
		end
		populate_joker_page(args.cycle_config.current_option)
	end

	-- Commit the working selection into the edited clause, then back to the editor. An
	-- empty clause (e.g. a fresh row) is dropped.
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
		ctx.save_config()
		mod._sel_area = nil
		mod._grid_area = nil
		mod._sel_highlighted = nil
		mod._grid_highlighted = nil
		mod._editing_clause = nil
		mod.show_filter_editor()
	end

	-- Build + show the picker overlay (clickable joker-collection clone + selection line).
	function mod.show_joker_picker(idx)
		mod._editing_clause = idx
		mod.picker_keys = {} -- seed the working selection from the clause
		mod._sel_highlighted = nil
		mod._grid_highlighted = nil
		mod._was_cursor_down = false -- edge tracker for crystalball_dismiss_outside
		local cl = idx and mod.config.clauses[idx]
		for i, k in ipairs(cl and cl.jokers or {}) do
			mod.picker_keys[i] = k
		end

		-- One CardArea for the whole page: the highlighted card draws LAST within a title_2
		-- area, so its Add button (anchored below) paints over its neighbours. align_cards
		-- (set below) grids the cards; the stock title_2 layout would line them up.
		local cw, ch = GRID_SCALE * G.CARD_W, GRID_SCALE * G.CARD_H
		mod._grid_area = CardArea(
			G.ROOM.T.x + 0.2 * G.ROOM.T.w / 2,
			G.ROOM.T.h,
			GRID_COLS * cw,
			GRID_ROWS * ch + (GRID_ROWS - 1) * GRID_ROW_GAP,
			{ card_limit = JOKERS_PER_PAGE, card_w = cw, type = "title_2", highlight_limit = 0, collection = true }
		)
		mod._grid_area.align_cards = grid_align_cards
		-- draw_layer defers this node past the page-cycle buttons, so the grid (and the Add
		-- button hanging below a highlighted card) paints on top of them.
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
							func = "crystalball_dismiss_outside", -- per-frame: clear Add/Remove on click-away
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
					-- Selection line. Click a joker here to surface its Remove button.
					{
						n = G.UIT.R,
						config = {
							align = "cm",
							minh = ctx.SEL_SCALE * G.CARD_H + 0.15,
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
end
