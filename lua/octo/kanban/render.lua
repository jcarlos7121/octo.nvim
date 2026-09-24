---Draws board columns as buffer lines.
---
---Pure: columns in, lines and highlights out. Nothing here touches a buffer, so the
---exact shape of a card can be asserted in tests rather than eyeballed.
---
---Columns are laid side by side in the same lines, every cell padded to the same
---width. That is what lets Neovim's own `zH`/`zL` scroll the board horizontally —
---there is no scrolling logic here, only a wide, ragged-free rectangle.
local bubbles = require "octo.ui.bubbles"
local octo_colors = require "octo.ui.colors"
local utils = require "octo.utils"

local M = {}

local DEFAULT_WIDTH = 62
local DEFAULT_GAP = 2
local DEFAULT_TITLE_LINES = 2
local DEFAULT_MAX_LABELS = 3

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

---GitHub's own palette for a single-select option, which is a named colour rather
---than a hex. These are the dark-mode values the web board draws with.
local STATUS_COLORS = {
  GRAY = "8b949e",
  BLUE = "58a6ff",
  GREEN = "3fb950",
  YELLOW = "d29922",
  ORANGE = "db6d28",
  RED = "f85149",
  PINK = "db61a2",
  PURPLE = "a371f7",
}

---The dot that opens a column header, in that status's own colour.
---@param color string? the option colour name
---@return table[] chunks
local function status_dot(color)
  local hex = color and STATUS_COLORS[tostring(color):upper()] or nil
  if not hex then
    return { { "○ ", "OctoKanbanRule" } }
  end
  return { { "● ", octo_colors.create_highlight(hex, { mode = "foreground" }) } }
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
---@param overflow integer how many labels were left out
---@return table[][] one chunk list per line
local function badge_lines(labels, limit, overflow)
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

  if overflow and overflow > 0 then
    local more = "+" .. tostring(overflow)
    if used > 0 and used + #more + 1 > limit then
      lines[#lines + 1] = current
      current = {}
    end
    current[#current + 1] = { more, "OctoKanbanLabel" }
  end

  if #current > 0 then
    lines[#lines + 1] = current
  end
  return lines
end

---Builds one column's stack of lines, and who owns each of them.
---@return table[] lines # chunk lists
---@return table[] owners # sparse: blank lines belong to no card
local function build_cell(col, ci, width, title_lines, show_repo, max_labels)
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

  -- a coloured dot, the name, then the count in a bubble: the shape GitHub's own
  -- board headers take
  local head = status_dot(col.color)
  local count = bubbles.make_bubble(tostring(#col.cards), "OctoBubble", { left_margin_width = 1 })
  local count_width = 0
  for _, chunk in ipairs(count) do
    count_width = count_width + vim.fn.strdisplaywidth(chunk[1])
  end

  head[#head + 1] = { cut(col.name, math.max(1, width - 2 - count_width)), "OctoKanbanHeader" }
  for _, chunk in ipairs(count) do
    head[#head + 1] = chunk
  end
  push(head)
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

    -- a card with six verbose labels is six lines of badge and one of title; the
    -- rest are counted rather than drawn
    local labels = card.labels or {}
    local overflow = 0
    if max_labels and #labels > max_labels then
      overflow = #labels - max_labels
      labels = vim.list_slice(labels, 1, max_labels)
    end

    for _, badges in ipairs(badge_lines(labels, width, overflow)) do
      push(badges, owner)
    end

    -- a blank line between cards; it belongs to no card, so the cursor cannot land on one
    push({ { "" } }, nil)
  end

  return lines, owners
end

---Lays one cell's chunks out, padded to the column width.
---
---Positions come back as byte offsets, not display cells. Extmarks are placed by
---byte, and a bubble delimiter is three bytes to one cell — measuring in cells puts
---every span after one in the wrong place and smears the colour sideways.
---@param chunks table[] {text, hl} pairs
---@param width integer display cells
---@return string text, table[] spans # {from, to, hl} in bytes from the cell start
local function compose_cell(chunks, width)
  local text, display = "", 0
  ---@type table[]
  local spans = {}

  for _, chunk in ipairs(chunks) do
    if display >= width then
      break
    end
    local piece = chunk[1]
    local piece_display = vim.fn.strdisplaywidth(piece)
    if display + piece_display > width then
      piece = cut(piece, width - display)
      piece_display = vim.fn.strdisplaywidth(piece)
    end

    if chunk[2] and #piece > 0 then
      spans[#spans + 1] = { from = #text, to = #text + #piece, hl = chunk[2] }
    end
    text = text .. piece
    display = display + piece_display
  end

  local short = width - display
  if short > 0 then
    text = text .. string.rep(" ", short)
  end
  return text, spans
end

---@param columns octo.kanban.Column[]
---@param opts table? { width, gap, title_lines }
---@return octo.kanban.Layout
function M.layout(columns, opts)
  opts = opts or {}
  local width = opts.width or DEFAULT_WIDTH
  local gap = opts.gap or DEFAULT_GAP
  local title_lines = opts.title_lines or DEFAULT_TITLE_LINES
  local max_labels = opts.max_labels or DEFAULT_MAX_LABELS
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
    local lines, owners = build_cell(col, ci, width, title_lines, show_repo, max_labels)
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
    local line, byte_offset = "", 0

    for ci = 1, #columns do
      if ci > 1 then
        local gap_text = string.rep(" ", gap)
        line = line .. gap_text
        byte_offset = byte_offset + #gap_text
      end

      local cell = cells[ci]
      local text, spans = compose_cell(cell.lines[row] or { { "" } }, width)

      for _, span in ipairs(spans) do
        highlights[#highlights + 1] = {
          line = row,
          col_start = byte_offset + span.from,
          col_end = byte_offset + span.to,
          hl_group = span.hl,
        }
      end

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

      line = line .. text
      byte_offset = byte_offset + #text
    end

    out_lines[row] = line
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
