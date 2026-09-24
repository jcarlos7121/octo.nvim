---Draws board columns as buffer lines.
---
---Pure: columns in, lines and highlights out. Nothing here touches a buffer, so the
---exact shape of a card can be asserted in tests rather than eyeballed.
---
---Columns are laid side by side in the same lines, every cell padded to the same
---width. That is what lets Neovim's own `zH`/`zL` scroll the board horizontally —
---there is no scrolling logic here, only a wide, ragged-free rectangle.
local bubbles = require "octo.ui.bubbles"
local utils = require "octo.utils"

local M = {}

local DEFAULT_WIDTH = 62
local DEFAULT_GAP = 2
local DEFAULT_TITLE_LINES = 2

---@class octo.kanban.Region
---@field line integer 1-based buffer line
---@field from integer 0-based column where the card's cell starts
---@field to integer 0-based column just past the cell
---@field card octo.kanban.Card
---@field column_index integer
---@field card_index integer

---@class octo.kanban.Layout
---@field lines string[]
---@field highlights table[]
---@field regions octo.kanban.Region[]
---@field column_x integer[] 0-based start of each column
---@field width integer total board width

---@param text string
---@param limit integer
---@return string
local function cut(text, limit)
  if limit <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= limit then
    return text
  end
  return vim.fn.strcharpart(text, 0, math.max(0, limit - 1)) .. "…"
end

---@param text string
---@param limit integer
---@return string
local function pad(text, limit)
  local short = limit - vim.fn.strdisplaywidth(text)
  return short > 0 and text .. string.rep(" ", short) or text
end

---Wraps a title, folding whatever will not fit into a trailing ellipsis.
---@param text string
---@param limit integer
---@param max_lines integer
---@return string[]
local function wrap(text, limit, max_lines)
  ---@type string[]
  local all = {}
  local current = ""

  for word in string.gmatch(text or "", "%S+") do
    local candidate = current == "" and word or current .. " " .. word
    if vim.fn.strdisplaywidth(candidate) <= limit then
      current = candidate
    else
      if current ~= "" then
        all[#all + 1] = current
      end
      current = word
    end
  end
  if current ~= "" then
    all[#all + 1] = current
  end

  if #all == 0 then
    return { "" }
  end

  if #all <= max_lines then
    for i, line in ipairs(all) do
      all[i] = cut(line, limit)
    end
    return all
  end

  ---@type string[]
  local kept = {}
  for i = 1, max_lines - 1 do
    kept[i] = cut(all[i], limit)
  end
  -- run the remaining words together so the cut lands mid-sentence and reads as
  -- "there is more", rather than stopping on a suspiciously tidy word boundary
  kept[max_lines] = cut(table.concat(all, " ", max_lines), limit)
  return kept
end

---Finished work should recede, not shout: a closed card's number is dimmed rather
---than given a colour of its own.
---@param card octo.kanban.Card
---@return string
local function number_highlight(card)
  local state = (card.state or ""):upper()
  if state == "CLOSED" or state == "MERGED" then
    return "OctoKanbanDone"
  end
  return "OctoKanbanNumber"
end

---@param card octo.kanban.Card
---@return string
local function state_icon(card)
  local state = (card.state or ""):upper()
  return utils.state_icon_map[state] or utils.state_icon_map.OPEN
end

---Chunks for one label, as a coloured bubble in its own GitHub colour.
---@param one octo.kanban.Label
---@param limit integer widest the bubble may be
---@return [string, string][] chunks, integer width
local function label_bubble(one, limit)
  -- the delimiters and margin cost four cells, so the name gets the rest
  local name = cut(one.name, math.max(1, limit - 4))
  local chunks = bubbles.make_label_bubble(name, one.color, { right_margin_width = 1 })
  local width = 0
  for _, chunk in ipairs(chunks) do
    width = width + vim.fn.strdisplaywidth(chunk[1])
  end
  return chunks, width
end

---Lays badges out across as many lines as they need.
---@param labels octo.kanban.Label[]
---@param limit integer
---@return table[][] one chunk list per line
local function badge_lines(labels, limit)
  local lines, current, used = {}, {}, 0

  for _, one in ipairs(labels) do
    local chunks, width = label_bubble(one, limit)
    if used > 0 and used + width > limit then
      lines[#lines + 1] = current
      current, used = {}, 0
    end
    for _, chunk in ipairs(chunks) do
      current[#current + 1] = chunk
    end
    used = used + width
  end

  if #current > 0 then
    lines[#lines + 1] = current
  end
  return lines
end

---Builds one column's stack of lines, and who owns each of them.
---@return table[] lines # chunk lists
---@return table[] owners # sparse: blank lines belong to no card
local function build_cell(col, ci, width, title_lines, show_repo)
  ---@type table[]
  local lines = {}
  ---@type table[]
  local owners = {}

  -- an explicit row counter, because `owners[#owners + 1] = nil` does not grow a
  -- Lua array: blank lines would silently slide every later owner out of step
  local row = 0
  ---@param chunks table[] {text, hl} pairs; hl may be nil
  local function push(chunks, owner)
    row = row + 1
    lines[row] = chunks
    owners[row] = owner
  end

  push { { cut(string.format("%s (%d)", col.name, #col.cards), width), "OctoKanbanHeader" } }
  push { { string.rep("─", width), "OctoKanbanRule" } }

  for card_index, card in ipairs(col.cards) do
    local owner = { card = card, column_index = ci, card_index = card_index }
    local state_hl = number_highlight(card)

    -- GitHub's card head: a state icon, the repository when it is worth saying,
    -- then the number. The title gets a line of its own below it rather than
    -- being pushed into whatever space is left beside the number.
    local head = { { state_icon(card), state_hl } }
    if show_repo and card.repo then
      head[#head + 1] = { cut(card.repo, math.max(4, width - 10)) .. " ", "OctoKanbanRepo" }
    end
    head[#head + 1] = { "#" .. tostring(card.number), state_hl }
    push(head, owner)

    for _, line in ipairs(wrap(card.title, width, title_lines)) do
      push({ { line } }, owner)
    end

    for _, badges in ipairs(badge_lines(card.labels or {}, width)) do
      push(badges, owner)
    end

    -- a blank line between cards; it belongs to no card, so the cursor cannot land on one
    push({ { "" } }, nil)
  end

  return lines, owners
end

---@param columns octo.kanban.Column[]
---@param opts table? { width, gap, title_lines }
---@return octo.kanban.Layout
function M.layout(columns, opts)
  opts = opts or {}
  local width = opts.width or DEFAULT_WIDTH
  local gap = opts.gap or DEFAULT_GAP
  local title_lines = opts.title_lines or DEFAULT_TITLE_LINES
  columns = columns or {}

  -- the repository is only worth a card's width when the board spans several
  local repos, repo_count = {}, 0
  for _, col in ipairs(columns) do
    for _, card in ipairs(col.cards) do
      if card.repo and not repos[card.repo] then
        repos[card.repo] = true
        repo_count = repo_count + 1
      end
    end
  end
  local show_repo = repo_count > 1

  ---@type integer[]
  local column_x = {}
  local cells = {}
  local height = 0

  for ci, col in ipairs(columns) do
    column_x[ci] = (ci - 1) * (width + gap)
    local lines, owners = build_cell(col, ci, width, title_lines, show_repo)
    cells[ci] = { lines = lines, owners = owners }
    height = math.max(height, #lines)
  end

  local total = #columns > 0 and (#columns * width + (#columns - 1) * gap) or 0

  ---@type string[]
  local out_lines = {}
  ---@type octo.kanban.Region[]
  local regions = {}
  ---@type table[]
  local highlights = {}

  for row = 1, height do
    ---@type string[]
    local pieces = {}
    for ci = 1, #columns do
      local cell = cells[ci]
      local chunks = cell.lines[row] or { { "" } }

      local text, offset = "", 0
      for _, chunk in ipairs(chunks) do
        local piece = chunk[1]
        local piece_width = vim.fn.strdisplaywidth(piece)
        if chunk[2] and piece_width > 0 then
          highlights[#highlights + 1] = {
            line = row,
            col_start = column_x[ci] + offset,
            col_end = column_x[ci] + offset + piece_width,
            hl_group = chunk[2],
          }
        end
        text = text .. piece
        offset = offset + piece_width
      end

      pieces[#pieces + 1] = pad(cut(text, width), width)

      local owner = cell.owners[row]
      if owner then
        regions[#regions + 1] = {
          line = row,
          from = column_x[ci],
          to = column_x[ci] + width,
          card = owner.card,
          column_index = owner.column_index,
          card_index = owner.card_index,
        }
      end
    end
    out_lines[row] = pad(table.concat(pieces, string.rep(" ", gap)), total)
  end

  return {
    lines = out_lines,
    highlights = highlights,
    regions = regions,
    column_x = column_x,
    width = total,
  }
end

---Where the window should be scrolled to so a whole column is on screen.
---
---Returns nothing when the column already fits in view, so a caller can leave the
---board where it is rather than jolting it on every keypress. Neovim's own cursor
---following would reveal only the edge of a column; a board wants the whole of it.
---@param leftcol integer current horizontal scroll
---@param win_width integer
---@param column_x integer 0-based start of the column
---@param column_width integer
---@return integer? new leftcol
function M.scroll_to(leftcol, win_width, column_x, column_width)
  local right = column_x + column_width
  if column_x >= leftcol and right <= leftcol + win_width then
    return nil
  end

  -- a column too wide for the window can never fit; show its start
  if column_width >= win_width then
    return math.max(0, column_x)
  end

  if column_x < leftcol then
    return math.max(0, column_x)
  end
  return math.max(0, right - win_width)
end

---The board's keys, for the `?` popup and the docs to share one source.
---@return string[]
function M.help()
  return {
    " Octo kanban ",
    "",
    " h  l      focus the previous / next column",
    " j  k      focus the previous / next card",
    " <CR>      open the card in an Octo buffer",
    " <  >      move the card to the previous / next column",
    " r         refresh the board",
    " q         close the board",
    " ?         show this list",
    "",
    " zH zL     scroll the board left / right",
    " zh zl     scroll by one cell",
  }
end

---What sits at a screen position, if anything.
---@param layout octo.kanban.Layout
---@param line integer 1-based buffer line
---@param col integer 0-based screen column
---@return octo.kanban.Region?
function M.card_at(layout, line, col)
  for _, region in ipairs(layout.regions or {}) do
    if region.line == line and col >= region.from and col < region.to then
      return region
    end
  end
  return nil
end

return M
