---Structure read off a description: markdown headings and task lists, drawn
---over the text with extmarks. The text is what the reader edits and what
---goes back to GitHub on save, so nothing here rewrites a byte of it -- the
---markup is concealed, never removed, and a run whose shape cannot be read is
---simply left as it is.
local constants = require "octo.constants"
local layout = require "octo.ui.layout"

local M = {}

---@class octo.BodyHeading
---@field line integer 1-indexed line within the body
---@field level integer
---@field marker integer byte length of the `## ` prefix
---@field text string

---@class octo.BodyTaskMarker
---@field indent integer byte length of the leading whitespace
---@field bullet integer byte length of the bullet and the space after it

---@class octo.BodyTaskList
---@field first integer 1-indexed first line of the run
---@field last integer 1-indexed last line of the run
---@field done integer
---@field total integer
---@field title string
---@field markers table<integer, octo.BodyTaskMarker> line -> where its bullet is

---@class octo.BodyStructure
---@field headings octo.BodyHeading[]
---@field tasklists octo.BodyTaskList[]

M.DEFAULT_TITLE = "Checklist"

---@param line string
---@return integer? level, integer? marker, string? text
local function heading(line)
  local hashes, spaces, text = line:match "^(#+)( +)(.-)%s*$"
  if hashes == nil or #hashes > 6 or text == "" then
    return nil
  end
  return #hashes, #hashes + #spaces, text
end

---@param line string
---@return octo.BodyTaskMarker? marker, boolean? done
local function task(line)
  local indent, bullet, box = line:match "^(%s*)([-*+] )%[([ xX])%]"
  if bullet == nil then
    indent, bullet, box = line:match "^(%s*)(%d+[.)] )%[([ xX])%]"
  end
  if bullet == nil then
    return nil
  end
  -- the box ends the item or is followed by its text; `[ ]x` is not a task
  local rest = line:sub(#indent + #bullet + 4)
  if rest ~= "" and rest:sub(1, 1) ~= " " then
    return nil
  end
  return { indent = #indent, bullet = #bullet }, box ~= " "
end

---@param line string
---@return boolean
local function fence(line)
  return line:match "^%s*```" ~= nil or line:match "^%s*~~~" ~= nil
end

---The heading the run belongs to: the nearest line above it that is not blank,
---when that is a heading
---@param lines string[]
---@param first integer
---@return string
local function title_above(lines, first)
  for i = first - 1, 1, -1 do
    local line = lines[i]
    if line:match "%S" then
      local _, _, text = heading(line)
      return text or M.DEFAULT_TITLE
    end
  end
  return M.DEFAULT_TITLE
end

---Read the headings and task-list runs out of a body. Fenced code is skipped:
---a `# comment` or a `- [ ]` inside it is not structure.
---@param lines string[]
---@return octo.BodyStructure
function M.parse(lines)
  local structure = { headings = {}, tasklists = {} } ---@type octo.BodyStructure
  local in_fence = false
  local run ---@type octo.BodyTaskList?

  local function close_run()
    if run ~= nil then
      table.insert(structure.tasklists, run)
      run = nil
    end
  end

  for i, line in ipairs(lines) do
    if fence(line) then
      in_fence = not in_fence
      close_run()
    elseif not in_fence then
      local marker, done = task(line)
      if marker ~= nil then
        if run == nil then
          run = { first = i, last = i, done = 0, total = 0, title = title_above(lines, i), markers = {} }
        end
        run.last = i
        run.total = run.total + 1
        if done then
          run.done = run.done + 1
        end
        run.markers[i] = marker
      else
        close_run()
        local level, hmarker, text = heading(line)
        if level ~= nil and hmarker ~= nil and text ~= nil then
          table.insert(structure.headings, { line = i, level = level, marker = hmarker, text = text })
        end
      end
    end
  end
  close_run()

  return structure
end

---Display columns the rendering adds to a line: the rail drawn inline before a
---task, nothing anywhere else. Concealed markup is not subtracted -- the text
---is measured generously so that it is never covered.
---@param structure octo.BodyStructure
---@param line integer 1-indexed line within the body
---@return integer
function M.inset(structure, line)
  for _, list in ipairs(structure.tasklists) do
    if line >= list.first and line <= list.last then
      return 2
    end
  end
  return 0
end

---@class octo.BodyRenderOpts
---@field width? integer how wide the panels may draw: the main column, or the window when there is no sidebar
---@field rail? integer window column of the rail between the columns, to carry it across the panels' lines

---A line the panel draws across the column: clipped to the column's width so
---it never runs into the sidebar, and carrying the rail between the columns
---when there is one, so the rail reads unbroken down the page
---@param chunks octo.ChunkLine
---@param opts octo.BodyRenderOpts
---@return octo.ChunkLine
local function across(chunks, opts)
  local out = opts.width ~= nil and layout.truncate(chunks, opts.width) or chunks
  if opts.rail ~= nil then
    local room = opts.rail - layout.width(out)
    if room > 0 then
      table.insert(out, { string.rep(" ", room) })
    end
    table.insert(out, { layout.RAIL, "OctoLayoutRail" })
  end
  return out
end

---@param list octo.BodyTaskList
---@param opts octo.BodyRenderOpts
---@return octo.ChunkLine
local function panel_title(list, opts)
  ---@type octo.ChunkLine
  local title = {
    { "┌ ", "OctoLayoutRail" },
    { list.title, "OctoLayoutHeading" },
    { string.format(" %d/%d ", list.done, list.total), "OctoLayoutKey" },
  }
  local room = (opts.width or 0) - layout.width(title)
  if room > 0 then
    table.insert(title, { string.rep("─", room), "OctoLayoutRail" })
  end
  return across(title, opts)
end

---Draw the structure over the body: headings get their highlight with the
---hashes concealed, and each task-list run becomes a panel with a rail and a
---title reading `<title> <done>/<total>`.
---@param bufnr integer
---@param start integer 0-indexed buffer line the body begins on
---@param lines string[] the body, one entry per buffer line
---@param opts? octo.BodyRenderOpts
---@return octo.BodyStructure
function M.render(bufnr, start, lines, opts)
  opts = opts or {}
  local ns = constants.OCTO_BODY_NS
  local structure = M.parse(lines)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  ---@param row integer 0-indexed
  ---@param col integer
  ---@param mark table the extmark's options
  local function set(row, col, mark)
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, col, mark)
  end

  for _, h in ipairs(structure.headings) do
    local row = start + h.line - 1
    set(row, 0, { end_col = h.marker, conceal = "" })
    set(row, h.marker, { end_col = #lines[h.line], hl_group = "OctoLayoutHeading" })
  end

  for _, list in ipairs(structure.tasklists) do
    for line = list.first, list.last do
      local row = start + line - 1
      ---@type table
      local mark = {
        line_hl_group = "OctoLayoutPanel",
        virt_text = { { layout.RAIL .. " ", "OctoLayoutRail" } },
        virt_text_pos = "inline",
      }
      if line == list.first then
        mark.virt_lines = { panel_title(list, opts) }
        mark.virt_lines_above = true
      end
      set(row, 0, mark)
      -- the bullet is concealed so the box leads the line; the indent stays,
      -- so nested items still read as nested
      local marker = list.markers[line]
      if marker ~= nil and marker.bullet > 0 then
        set(row, marker.indent, { end_col = marker.indent + marker.bullet, conceal = "" })
      end
    end
    set(start + list.last - 1, 0, { virt_lines = { across({ { "└", "OctoLayoutRail" } }, opts) } })
  end

  return structure
end

return M
