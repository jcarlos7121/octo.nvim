---Two-column layout for octo buffers: a main column on the left and a metadata
---sidebar on the right, both drawn as virtual text over empty lines.
---
---Only virtual text, deliberately. A buffer's title, body and comments are real
---text that round-trips to GitHub on save, so nothing here may pad, wrap or
---rewrite a line the reader can edit -- the layout lives on the empty lines the
---writers reserve for it, and beside the text everywhere else.
local config = require "octo.config"
local constants = require "octo.constants"

local M = {}

---@alias octo.Chunk [string, string?] a piece of virtual text: content, highlight
---@alias octo.ChunkLine octo.Chunk[] one line of virtual text

---@class octo.LayoutDims
---@field width integer usable width of the window
---@field main integer width of the main column
---@field sidebar integer width of the sidebar, 0 when stacked
---@field gutter integer column the gap between the columns starts at
---@field stacked boolean the window is too narrow for two columns, so the sidebar goes below

---@class octo.LayoutRow
---@field [1] string the key
---@field [2] string|octo.ChunkLine the value
---@field links? octo.LinkedReference[] what the row points at, for `goto_link`

---@class octo.LayoutGroup
---@field title string
---@field note? string a quieter remark after the title, such as a count
---@field rows octo.LayoutRow[]

M.RAIL = "│"
M.GAP = 3 -- the rail and a space either side

---Usable width of the window showing a buffer: the text area, without the
---gutters neovim draws itself. A buffer being rendered is often not on screen
---yet, and the editor width is the best guess for the window it will land in.
---@param bufnr integer
---@return integer
local function window_width(bufnr)
  local winid = vim.fn.bufwinid(bufnr)
  if winid == -1 then
    return vim.o.columns
  end
  local info = vim.fn.getwininfo(winid)[1]
  local textoff = info ~= nil and info.textoff or 0
  return vim.api.nvim_win_get_width(winid) - textoff
end

---@param bufnr integer
---@param opts? { sidebar_width?: integer, min_main_width?: integer, width?: integer }
---@return octo.LayoutDims
function M.dims(bufnr, opts)
  opts = opts or {}
  local conf = config.values.ui
  local sidebar = opts.sidebar_width or conf.sidebar_width or 34
  local min_main = opts.min_main_width or conf.min_main_width or 56
  local width = opts.width or window_width(bufnr)
  local main = width - sidebar - M.GAP

  if main < min_main then
    return { width = width, main = width, sidebar = 0, gutter = width, stacked = true }
  end
  return { width = width, main = main, sidebar = sidebar, gutter = main, stacked = false }
end

---@param chunks octo.ChunkLine
---@return integer
function M.width(chunks)
  local width = 0
  for _, chunk in ipairs(chunks) do
    width = width + vim.fn.strdisplaywidth(chunk[1])
  end
  return width
end

---Clip a line to a width, marking the cut with an ellipsis
---@param chunks octo.ChunkLine
---@param width integer
---@return octo.ChunkLine
function M.truncate(chunks, width)
  if M.width(chunks) <= width then
    return vim.deepcopy(chunks)
  end

  local out = {} ---@type octo.ChunkLine
  local used = 0
  for _, chunk in ipairs(chunks) do
    local text, hl = chunk[1], chunk[2]
    local chunk_width = vim.fn.strdisplaywidth(text)
    if used + chunk_width <= width then
      table.insert(out, { text, hl })
      used = used + chunk_width
    else
      local room = width - used - 1
      if room > 0 then
        local cut = text
        while vim.fn.strdisplaywidth(cut) > room do
          cut = vim.fn.strcharpart(cut, 0, vim.fn.strchars(cut) - 1)
        end
        table.insert(out, { cut .. "…", hl })
      elseif width - used > 0 then
        table.insert(out, { "…", hl })
      end
      break
    end
  end
  return out
end

---Clip a line to a width and fill what is left with spaces
---@param chunks octo.ChunkLine
---@param width integer
---@return octo.ChunkLine
function M.pad(chunks, width)
  local out = M.truncate(chunks, width)
  local room = width - M.width(out)
  if room > 0 then
    table.insert(out, { string.rep(" ", room) })
  end
  return out
end

---Put two lines side by side, with the rail between them
---@param left octo.ChunkLine
---@param right octo.ChunkLine
---@param dims octo.LayoutDims
---@return octo.ChunkLine
function M.columns(left, right, dims)
  if dims.stacked then
    return vim.deepcopy(#left > 0 and left or right)
  end

  local out = M.pad(left, dims.main)
  table.insert(out, { " " .. M.RAIL .. " ", "OctoLayoutRail" })
  vim.list_extend(out, M.truncate(right, dims.sidebar))
  return out
end

---Zip a main column and a sidebar into lines. Stacked, the sidebar follows the
---main column with a blank line between them instead of sitting beside it.
---@param left octo.ChunkLine[]
---@param right octo.ChunkLine[]
---@param dims octo.LayoutDims
---@return octo.ChunkLine[]
function M.compose(left, right, dims)
  local out = {} ---@type octo.ChunkLine[]

  if dims.stacked then
    vim.list_extend(out, vim.deepcopy(left))
    if #left > 0 and #right > 0 then
      table.insert(out, {})
    end
    vim.list_extend(out, vim.deepcopy(right))
    return out
  end

  for i = 1, math.max(#left, #right) do
    table.insert(out, M.columns(left[i] or {}, right[i] or {}, dims))
  end
  return out
end

---Where the lines of a drawing land: the composed lines, and the row offset
---within them of every main-column and sidebar line. A caller that has to
---find a sidebar row again -- to answer a mapping on its buffer line -- reads
---the offset here rather than assuming the two columns line up, since stacked
---they do not.
---@class octo.LayoutPlacement
---@field lines octo.ChunkLine[]
---@field left integer[] 0-based row offset of each main-column line, by index
---@field right integer[] 0-based row offset of each sidebar line, by index

---Compose a main column and a sidebar, keeping where every line of either lands
---@param left octo.ChunkLine[]
---@param right octo.ChunkLine[]
---@param dims octo.LayoutDims
---@return octo.LayoutPlacement
function M.place(left, right, dims)
  local placement = { lines = M.compose(left, right, dims), left = {}, right = {} } ---@type octo.LayoutPlacement
  for i = 1, #left do
    placement.left[i] = i - 1
  end
  -- stacked, the sidebar starts after the main column and the blank between
  local base = 0
  if dims.stacked then
    base = #left > 0 and #right > 0 and #left + 1 or #left
  end
  for i = 1, #right do
    placement.right[i] = base + i - 1
  end
  return placement
end

---A sidebar group heading, with room for a quieter remark after it
---@param title string
---@param note? string
---@return octo.ChunkLine
function M.group(title, note)
  local out = { { title:upper(), "OctoLayoutGroup" } } ---@type octo.ChunkLine
  if note ~= nil and note ~= "" then
    table.insert(out, { "  " .. note, "OctoLayoutKey" })
  end
  return out
end

---A key and its value, the key padded so a group's values line up two columns
---past the longest key of the group
---@param key string
---@param value string|octo.ChunkLine
---@param key_width integer
---@return octo.ChunkLine
function M.kv(key, value, key_width)
  local out = M.pad({ { key, "OctoLayoutKey" } }, key_width + 2)
  if type(value) == "string" then
    table.insert(out, { value, "OctoDetailsValue" })
  else
    vim.list_extend(out, value)
  end
  return out
end

---Lay out sidebar groups: a heading per group, its rows aligned within it, and
---a blank line between groups. Groups without rows are left out entirely.
---Also says which row each line came from, so a caller can follow a line back
---to what it stands for, and where the blank lines between groups fell, so a
---caller splitting the sidebar can break between groups rather than inside one.
---@param groups octo.LayoutGroup[]
---@return octo.ChunkLine[] lines, table<integer, octo.LayoutRow> sources line index -> its row, integer[] breaks indexes of the blank lines between groups
function M.sidebar(groups)
  local out = {} ---@type octo.ChunkLine[]
  local sources = {} ---@type table<integer, octo.LayoutRow>
  local breaks = {} ---@type integer[]

  for _, group in ipairs(groups) do
    if #group.rows > 0 then
      if #out > 0 then
        table.insert(out, {})
        table.insert(breaks, #out)
      end
      table.insert(out, M.group(group.title, group.note))

      local key_width = 0
      for _, row in ipairs(group.rows) do
        key_width = math.max(key_width, vim.fn.strdisplaywidth(row[1]))
      end
      for _, row in ipairs(group.rows) do
        table.insert(out, M.kv(row[1], row[2], key_width))
        sources[#out] = row
      end
    end
  end

  return out, sources, breaks
end

---A horizontal rule across the width
---@param dims octo.LayoutDims
---@param opts? { hl?: string, char?: string }
---@return octo.ChunkLine
function M.rule(dims, opts)
  opts = opts or {}
  local char = opts.char or "─"
  return { { string.rep(char, math.max(dims.width, 0)), opts.hl or "OctoLayoutRule" } }
end

---What a paint reported back: the buffer line every line of the drawing
---landed on, for the width the window had at the time
---@class octo.LayoutPainted
---@field dims octo.LayoutDims
---@field left table<integer, integer> 1-indexed buffer line of each main-column line, by index; absent when clipped
---@field right table<integer, integer> the same for the sidebar

---@class octo.LayoutDrawOpts
---@field reserved? integer lines set aside for the drawing, which never paints past them; defaults to what it needs at the current width
---@field rule? boolean close the drawing with a full-width rule on the last reserved line
---@field on_paint? fun(painted: octo.LayoutPainted) told where every line landed, after each paint

---What is drawn, kept so a resize can lay it out again without asking GitHub
---@class octo.LayoutDrawing
---@field start_line integer 0-indexed line the drawing starts at
---@field left octo.ChunkLine[]
---@field right octo.ChunkLine[]
---@field reserved integer lines the drawing may paint, rule included
---@field rule boolean
---@field on_paint? fun(painted: octo.LayoutPainted)
M.drawings = {} ---@type table<integer, octo.LayoutDrawing>

local watching = false

---@param bufnr integer
local function paint(bufnr)
  local drawing = M.drawings[bufnr]
  if drawing == nil or not vim.api.nvim_buf_is_valid(bufnr) then
    M.drawings[bufnr] = nil
    return
  end

  local dims = M.dims(bufnr)
  local placement = M.place(drawing.left, drawing.right, dims)
  local room = drawing.reserved - (drawing.rule and 1 or 0)
  -- The lines were reserved once, at render. A window narrowed since then does
  -- not get to stack the sidebar below the main column when that would run
  -- into the text after the drawing: the columns stay side by side, cramped,
  -- and clipped where even that does not fit.
  if #placement.lines > room and dims.stacked then
    local cramped = M.dims(bufnr, { min_main_width = 0 })
    if not cramped.stacked then
      dims = cramped
      placement = M.place(drawing.left, drawing.right, dims)
    end
  end

  local last = vim.api.nvim_buf_line_count(bufnr)
  vim.api.nvim_buf_clear_namespace(
    bufnr,
    constants.OCTO_LAYOUT_NS,
    drawing.start_line,
    drawing.start_line + drawing.reserved
  )

  for i, chunks in ipairs(placement.lines) do
    if i > room then
      break
    end
    local line = drawing.start_line + i - 1
    if line < last and #chunks > 0 then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, constants.OCTO_LAYOUT_NS, line, 0, {
        virt_text = chunks,
        virt_text_pos = "overlay",
        hl_mode = "combine",
      })
    end
  end

  if drawing.rule then
    local line = drawing.start_line + drawing.reserved - 1
    if line < last then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, constants.OCTO_LAYOUT_NS, line, 0, {
        virt_text = M.rule(dims),
        virt_text_pos = "overlay",
        hl_mode = "combine",
      })
    end
  end

  if drawing.on_paint ~= nil then
    local painted = { dims = dims, left = {}, right = {} } ---@type octo.LayoutPainted
    for i, offset in ipairs(placement.left) do
      if offset < room then
        painted.left[i] = drawing.start_line + offset + 1
      end
    end
    for i, offset in ipairs(placement.right) do
      if offset < room then
        painted.right[i] = drawing.start_line + offset + 1
      end
    end
    drawing.on_paint(painted)
  end
end

---Draw a main column and a sidebar over the lines starting at `start_line`,
---and keep laying them out again as the window is resized. The caller reserves
---the lines; `M.lines(left, right, bufnr)` says how many that is, one more
---with a rule. The drawing never paints past what was reserved.
---@param bufnr integer
---@param start_line integer 0-indexed
---@param left octo.ChunkLine[]
---@param right octo.ChunkLine[]
---@param opts? octo.LayoutDrawOpts
function M.draw(bufnr, start_line, left, right, opts)
  opts = opts or {}
  local rule = opts.rule == true
  local reserved = opts.reserved or (M.lines(left, right, bufnr) + (rule and 1 or 0))
  M.drawings[bufnr] = {
    start_line = start_line,
    left = left,
    right = right,
    reserved = reserved,
    rule = rule,
    on_paint = opts.on_paint,
  }
  paint(bufnr)

  if watching then
    return
  end
  watching = true
  local group = vim.api.nvim_create_augroup("octo_layout", { clear = true })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = group,
    desc = "lay out octo's columns again for the new width",
    callback = function()
      for bufnr_ in pairs(M.drawings) do
        paint(bufnr_)
      end
    end,
  })
end

---How many lines a drawing needs
---@param left octo.ChunkLine[]
---@param right octo.ChunkLine[]
---@param bufnr integer
---@return integer
function M.lines(left, right, bufnr)
  return #M.compose(left, right, M.dims(bufnr))
end

---@param bufnr integer
function M.clear(bufnr)
  M.drawings[bufnr] = nil
  M.besides[bufnr] = nil
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, constants.OCTO_LAYOUT_NS, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, constants.OCTO_SIDEBAR_NS, 0, -1)
  end
end

---A sidebar drawn beside real text rather than over reserved lines: each row
---goes on the next line that leaves the gutter free, so the text always wins
---and the sidebar yields as the reader types.
---@class octo.LayoutBeside
---@field rows octo.ChunkLine[] the sidebar, top to bottom
---@field block? integer 0-indexed first line of the block above the text; from there to the blank before the text, every line may carry a row
---@field region fun(): integer?, integer? 0-indexed first and last line of the text, nil once it is gone
---@field width? fun(line: integer, text: string): integer display width of a text line, when it is more than the text itself
---@field rule? integer 0-indexed line to draw a rule across, when it is empty
---@field prepare? fun(dims: octo.LayoutDims) run before every paint with the dims it will use, for whatever has to be drawn to the same measure first
---@field on_paint? fun(placed: table<integer, integer>) told where each row landed: row index -> 1-indexed line
M.besides = {} ---@type table<integer, octo.LayoutBeside>

---@param bufnr integer
local function paint_beside(bufnr)
  local drawing = M.besides[bufnr]
  if drawing == nil then
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    M.besides[bufnr] = nil
    return
  end
  local dims = M.dims(bufnr)
  if drawing.prepare then
    drawing.prepare(dims)
  end

  local ns = constants.OCTO_SIDEBAR_NS
  local last = vim.api.nvim_buf_line_count(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  if drawing.rule ~= nil and drawing.rule < last then
    local text = vim.api.nvim_buf_get_lines(bufnr, drawing.rule, drawing.rule + 1, false)[1]
    if text == "" then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, drawing.rule, 0, {
        virt_text = M.rule(dims),
        virt_text_pos = "overlay",
        hl_mode = "combine",
      })
    end
  end

  local rows = drawing.rows
  local placed = {} ---@type table<integer, integer>
  local next_row = 1
  local col = dims.gutter + 1

  ---The rail and, while any are left, the next row
  ---@param line integer 0-indexed
  local function place(line)
    local chunks = { { M.RAIL .. " ", "OctoLayoutRail" } } ---@type octo.ChunkLine
    local row = rows[next_row]
    if row ~= nil then
      vim.list_extend(chunks, M.truncate(row, dims.sidebar))
      placed[next_row] = line + 1
      next_row = next_row + 1
    end
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line, 0, {
      virt_text = chunks,
      virt_text_win_col = col,
      hl_mode = "combine",
    })
  end

  local first, final = drawing.region()
  if final ~= nil then
    final = math.min(final, last - 1)
  end

  if not dims.stacked then
    -- the block above the text first, while there are rows to put there
    if drawing.block ~= nil and first ~= nil then
      for line = drawing.block, math.min(first - 2, last - 1) do
        if next_row > #rows then
          break
        end
        place(line)
      end
    end
    if first ~= nil and final ~= nil then
      for line = first, final do
        local text = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or ""
        local width = drawing.width and drawing.width(line, text) or vim.fn.strdisplaywidth(text)
        -- the text keeps its own space: a line reaching the gutter carries no row
        if width < dims.gutter then
          place(line)
        end
      end
    end
  end

  -- what found no line goes under the text as virtual lines, still in its
  -- column when there is one
  if next_row <= #rows then
    local virt_lines = {} ---@type octo.ChunkLine[]
    for i = next_row, #rows do
      local chunks = {} ---@type octo.ChunkLine
      if not dims.stacked then
        table.insert(chunks, { string.rep(" ", col) })
        table.insert(chunks, { M.RAIL .. " ", "OctoLayoutRail" })
      end
      vim.list_extend(chunks, M.truncate(rows[i], dims.stacked and dims.width or dims.sidebar))
      table.insert(virt_lines, chunks)
    end
    local anchor = final or (last - 1)
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, math.max(anchor, 0), 0, { virt_lines = virt_lines })
  end

  if drawing.on_paint then
    drawing.on_paint(placed)
  end
end

---Draw a sidebar beside the text of a buffer and keep it there: it is laid
---out again whenever the text changes or the window is resized. Extmarks only,
---so a repaint on every keystroke is cheap and the text is never touched.
---@param bufnr integer
---@param drawing octo.LayoutBeside
function M.beside(bufnr, drawing)
  M.besides[bufnr] = drawing
  paint_beside(bufnr)

  local group = vim.api.nvim_create_augroup("octo_layout_beside", { clear = false })
  -- this buffer may have been rendered before; handlers must not pile up
  pcall(vim.api.nvim_clear_autocmds, { group = group, buffer = bufnr })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = bufnr,
    desc = "let octo's sidebar yield to the text as it is typed",
    callback = function()
      paint_beside(bufnr)
    end,
  })
  pcall(vim.api.nvim_clear_autocmds, { group = group, event = { "VimResized", "WinResized" } })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = group,
    desc = "lay out octo's sidebars again for the new width",
    callback = function()
      for bufnr_ in pairs(M.besides) do
        paint_beside(bufnr_)
      end
    end,
  })
end

---Lay a sidebar drawn with `beside` out again, after what it sits next to
---has changed
---@param bufnr integer
function M.repaint(bufnr)
  paint_beside(bufnr)
end

---Whether the two-column layout is on
---@return boolean
function M.enabled()
  return config.values.ui.layout == "columns"
end

return M
