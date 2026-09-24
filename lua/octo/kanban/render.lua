---Draws board columns as buffer lines.
---
---Pure: columns in, lines and highlights out. Nothing here touches a buffer, so the
---exact shape of a card can be asserted in tests rather than eyeballed.
---
---Columns are laid side by side in the same lines, every cell padded to the same
---width. That is what lets Neovim's own `zH`/`zL` scroll the board horizontally —
---there is no scrolling logic here, only a wide, ragged-free rectangle.
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

---@param card octo.kanban.Card
---@return string
local function number_prefix(card)
  return "#" .. tostring(card.number) .. "  "
end

---@param card octo.kanban.Card
---@return string
local function number_highlight(card)
  local state = (card.state or ""):upper()
  if state == "CLOSED" then
    return "OctoPurple"
  elseif state == "MERGED" then
    return "OctoPurple"
  end
  return "OctoGreen"
end

---Builds one column's stack of lines, and who owns each of them.
---@return string[] lines
---@return table[] owners # sparse: blank lines belong to no card
---@return table[] marks # sparse: highlight group per line
local function build_cell(col, ci, width, title_lines)
  ---@type string[]
  local lines = {}
  ---@type table[]
  local owners = {}
  ---@type table[]
  local marks = {}

  -- an explicit row counter, because `owners[#owners + 1] = nil` does not grow a
  -- Lua array: blank lines would silently slide every later owner out of step
  local row = 0
  local function push(text, owner, hl)
    row = row + 1
    lines[row] = text
    owners[row] = owner
    marks[row] = hl
  end

  push(cut(string.format("%s (%d)", col.name, #col.cards), width), nil, "OctoBlue")
  push(string.rep("─", width), nil, "OctoGrey")

  for card_index, card in ipairs(col.cards) do
    local prefix = number_prefix(card)
    local prefix_width = vim.fn.strdisplaywidth(prefix)
    local indent = string.rep(" ", prefix_width)
    local limit = width - prefix_width
    local owner = { card = card, column_index = ci, card_index = card_index }

    for i, line in ipairs(wrap(card.title, limit, title_lines)) do
      push((i == 1 and prefix or indent) .. line, owner, i == 1 and number_highlight(card) or nil)
    end

    if card.labels and #card.labels > 0 then
      push(indent .. cut(table.concat(card.labels, "  "), limit), owner, "OctoGrey")
    end

    -- a blank line between cards; it belongs to no card, so the cursor cannot land on one
    push("", nil, nil)
  end

  return lines, owners, marks
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

  ---@type integer[]
  local column_x = {}
  local cells = {}
  local height = 0

  for ci, col in ipairs(columns) do
    column_x[ci] = (ci - 1) * (width + gap)
    local lines, owners, marks = build_cell(col, ci, width, title_lines)
    cells[ci] = { lines = lines, owners = owners, marks = marks }
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
      local text = cell.lines[row] or ""
      pieces[#pieces + 1] = pad(text, width)

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

      local hl = cell.marks[row]
      if hl and text ~= "" then
        highlights[#highlights + 1] = {
          line = row,
          col_start = column_x[ci],
          col_end = column_x[ci] + vim.fn.strdisplaywidth(text),
          hl_group = hl,
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
