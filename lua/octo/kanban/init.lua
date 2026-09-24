---A project board for whatever a search returns.
---
---The interesting logic lives next door and is pure: `board` groups results into
---columns, `render` turns columns into lines, `query` talks to GitHub. This file is
---the thin part — a buffer, a cursor, and some keymaps over the top of those.
local actions = require "octo.kanban.actions"
local board = require "octo.kanban.board"
local config = require "octo.config"
local highlights = require "octo.kanban.highlights"
local query = require "octo.kanban.query"
local render = require "octo.kanban.render"
local utils = require "octo.utils"

local M = {}

---@class octo.kanban.State
---@field bufnr integer
---@field search string
---@field project octo.kanban.Project
---@field field table status field: id and options
---@field columns octo.kanban.Column[]
---@field layout octo.kanban.Layout
---@field focus { column: integer, card: integer }
---@field opts table

---@type octo.kanban.State?
M.state = nil

local NAMESPACE = vim.api.nvim_create_namespace "octo_kanban"

---@return table
local function options()
  local conf = config.values
  local kanban = conf.kanban or {}
  return {
    width = kanban.column_width or 38,
    gap = kanban.gap or 2,
    title_lines = kanban.title_lines or 2,
    max_issues = kanban.max_issues or 300,
    status_field = kanban.status_field or "Status",
  }
end

---The first buffer line a card occupies.
---@param layout octo.kanban.Layout
---@return integer?
local function line_of(layout, column_index, card_index)
  for _, region in ipairs(layout.regions) do
    if region.column_index == column_index and region.card_index == card_index then
      return region.line
    end
  end
  return nil
end

---Puts the cursor on the focused card.
local function place_cursor()
  local state = M.state
  if not state then
    return
  end
  local winid = vim.fn.bufwinid(state.bufnr)
  if winid == -1 then
    return
  end

  local line = line_of(state.layout, state.focus.column, state.focus.card)
  if not line then
    return
  end
  local column = state.layout.column_x[state.focus.column] or 0
  vim.api.nvim_win_set_cursor(winid, { line, column })

  -- Neovim would scroll just far enough to show the cursor, which leaves the rest
  -- of the column off screen. A board wants the whole column.
  vim.api.nvim_win_call(winid, function()
    local leftcol = vim.fn.winsaveview().leftcol
    local target = render.scroll_to(leftcol, vim.api.nvim_win_get_width(winid), column, state.opts.width)
    if target then
      vim.fn.winrestview { leftcol = target }
    end
  end)
end

---A floating reminder of what the board's keys do.
local function show_help()
  local lines = render.help()
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].bufhidden = "wipe"

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = width + 1,
    height = #lines,
    row = math.max(0, math.floor((vim.o.lines - #lines) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
  })

  for _, lhs in ipairs { "q", "<Esc>", "?" } do
    vim.keymap.set("n", lhs, function()
      pcall(vim.api.nvim_win_close, winid, true)
    end, { buffer = bufnr, nowait = true, silent = true })
  end
end

---Describes the board in the window bar, so the header never scrolls away.
local function set_winbar()
  local state = M.state
  if not state then
    return
  end
  local winid = vim.fn.bufwinid(state.bufnr)
  if winid == -1 then
    return
  end

  local column = state.columns[state.focus.column]
  local count = 0
  for _, col in ipairs(state.columns) do
    count = count + #col.cards
  end

  vim.wo[winid].winbar = string.format(
    "%%#OctoKanbanHeader#%s%%*  ·  %d cards  ·  %s (%d of %d)",
    state.project.title,
    count,
    column and column.name or "-",
    state.focus.column,
    #state.columns
  )
end

---Redraws the board from the current columns.
local function draw()
  local state = M.state
  if not state or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end

  state.layout = render.layout(state.columns, state.opts)

  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, state.layout.lines)
  vim.bo[state.bufnr].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.bufnr, NAMESPACE, 0, -1)
  for _, hl in ipairs(state.layout.highlights) do
    pcall(
      vim.api.nvim_buf_set_extmark,
      state.bufnr,
      NAMESPACE,
      hl.line - 1,
      hl.col_start,
      { end_col = hl.col_end, hl_group = hl.hl_group }
    )
  end

  set_winbar()
  place_cursor()
end

---Moves focus, skipping columns with nothing in them.
---@param delta integer
local function focus_column(delta)
  local state = M.state
  if not state then
    return
  end

  local index = state.focus.column + delta
  while state.columns[index] do
    if #state.columns[index].cards > 0 then
      state.focus.column = index
      state.focus.card = 1
      set_winbar()
      place_cursor()
      return
    end
    index = index + delta
  end
end

---@param delta integer
local function focus_card(delta)
  local state = M.state
  if not state then
    return
  end

  local column = state.columns[state.focus.column]
  if not column then
    return
  end
  local index = state.focus.card + delta
  if index >= 1 and index <= #column.cards then
    state.focus.card = index
    place_cursor()
  end
end

---@return octo.kanban.Card?
local function focused_card()
  local state = M.state
  if not state then
    return nil
  end
  local column = state.columns[state.focus.column]
  return column and column.cards[state.focus.card] or nil
end

local function open_focused()
  local card = focused_card()
  if not card then
    return
  end
  if card.is_pr then
    utils.get_pull_request(card.number, card.repo)
  else
    utils.get_issue(card.number, card.repo)
  end
end

---Moves the focused card one column over and writes it to the project.
---@param direction integer
local function move_focused(direction)
  local state = M.state
  local card = focused_card()
  if not state or not card then
    return
  end

  if not card.item_id then
    utils.error "This card is not on the board, so it has no status to change"
    return
  end

  local to_index = actions.target_column(state.columns, state.focus.column, direction)
  if not to_index then
    return
  end
  local destination = state.columns[to_index]

  actions.move({
    project_id = state.project.id,
    item_id = card.item_id,
    field_id = state.field.id,
    option_id = destination.option_id,
  }, function(err)
    vim.schedule(function()
      if err then
        utils.error("Could not move the card: " .. err)
        -- the board still shows the truth, because nothing was moved locally yet
        return
      end

      local from = state.columns[state.focus.column]
      table.remove(from.cards, state.focus.card)
      card.status = destination.name
      destination.cards[#destination.cards + 1] = card

      state.focus.column = to_index
      state.focus.card = #destination.cards
      draw()
      utils.info(string.format("#%d → %s", card.number, destination.name))
    end)
  end)
end

---@param bufnr integer
local function apply_mappings(bufnr)
  local map = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = bufnr, nowait = true, silent = true, desc = desc })
  end

  map("<CR>", open_focused, "Open the issue or pull request")
  map("l", function()
    focus_column(1)
  end, "Focus the next column")
  map("h", function()
    focus_column(-1)
  end, "Focus the previous column")
  map("j", function()
    focus_card(1)
  end, "Focus the next card")
  map("k", function()
    focus_card(-1)
  end, "Focus the previous card")
  map(">", function()
    move_focused(1)
  end, "Move the card to the next column")
  map("<", function()
    move_focused(-1)
  end, "Move the card to the previous column")
  map("r", function()
    M.open(M.state and M.state.search or "")
  end, "Refresh the board")
  map("q", function()
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end, "Close the board")
  map("?", show_help, "Show the board's keys")
end

---The board's buffer name.
---
---It starts with `octo://` deliberately: that is what `utils.is_octo_owned_buffer`
---recognises, and only buffers it owns are offered by `previous_view_buffer`. Without
---it, closing an issue opened from the board would land on a file rather than back on
---the board. The octo:// autocmds are all guarded on there being an OctoBuffer model
---for the buffer, which a board has not got, so they no-op here.
---@param search string
---@return string
function M.buffer_name(search)
  return "octo://kanban/" .. (search or ""):gsub("%s+", "+")
end

---@param search string
---@return integer bufnr
local function ensure_buffer(search)
  if M.state and vim.api.nvim_buf_is_valid(M.state.bufnr) then
    return M.state.bufnr
  end

  highlights.setup()

  local bufnr = vim.api.nvim_create_buf(true, true)
  pcall(vim.api.nvim_buf_set_name, bufnr, M.buffer_name(search))
  vim.bo[bufnr].filetype = "octo_kanban"
  -- `hide`, never `wipe`: opening a card replaces the board in its window, and a
  -- wiped board is one there is no going back to. `hide` also keeps it loaded, so
  -- returning to it never re-reads the name as if it were an issue URI.
  vim.bo[bufnr].bufhidden = "hide"
  vim.api.nvim_set_current_buf(bufnr)

  local winid = vim.api.nvim_get_current_win()
  vim.wo[winid].wrap = false
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].cursorline = false
  vim.wo[winid].signcolumn = "no"

  apply_mappings(bufnr)
  return bufnr
end

---Builds the board and shows it.
---@param search string
---@param nodes table[]
---@param project octo.kanban.Project
---@param field table
---@param opts table
local function present(search, nodes, project, field, opts)
  local cards = board.normalize(nodes, project.id)
  local columns = board.columns(cards, field.options)

  local bufnr = ensure_buffer(search)
  M.state = {
    bufnr = bufnr,
    search = search,
    project = project,
    field = field,
    columns = columns,
    layout = { lines = {}, highlights = {}, regions = {}, column_x = {}, width = 0 },
    focus = { column = 1, card = 1 },
    opts = opts,
  }

  -- start on the first column that actually holds something
  for index, column in ipairs(columns) do
    if #column.cards > 0 then
      M.state.focus.column = index
      break
    end
  end

  draw()
end

---@param message string
local function fail(message)
  vim.schedule(function()
    utils.error(message)
  end)
end

---Opens a board for a search.
---@param search string
function M.open(search)
  if utils.is_blank(search) then
    utils.error "Octo kanban needs a search, for example: Octo kanban search assignee:@me"
    return
  end

  local opts = options()
  utils.info "Building the board…"

  -- When the search names the project there is no need to discover it from the
  -- results, so the search and the board's columns come back together — one `gh`
  -- invocation instead of two, and each costs about a third of a second before
  -- GitHub is even asked anything.
  local ref = query.project_ref(search)
  if ref then
    query.combined({
      search = search,
      ref = ref,
      status_field = opts.status_field,
      max_issues = opts.max_issues,
    }, function(nodes, project, field, err)
      if err then
        fail("Could not build the board: " .. err)
        return
      end
      if not nodes or #nodes == 0 then
        fail("Nothing matched: " .. search)
        return
      end
      vim.schedule(function()
        present(search, nodes, project, field, opts)
      end)
    end)
    return
  end

  -- No project named: the results have to say which board they belong to first.
  query.search({
    search = search,
    status_field = opts.status_field,
    max_issues = opts.max_issues,
  }, function(nodes, err)
    if err then
      fail("Search failed: " .. err)
      return
    end
    if not nodes or #nodes == 0 then
      fail("Nothing matched: " .. search)
      return
    end

    local project = board.choose_project(nodes)
    if not project then
      fail "None of those results are on a project board"
      return
    end

    query.status_field(project.id, opts.status_field, function(field, field_err)
      if field_err or not field then
        fail("Could not read the board's columns: " .. (field_err or "unknown error"))
        return
      end
      vim.schedule(function()
        present(search, nodes, project, field, opts)
      end)
    end)
  end)
end

return M
