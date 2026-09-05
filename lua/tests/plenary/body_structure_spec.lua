---@diagnostic disable
local eq = assert.are.same
local body = require "octo.ui.body"
local constants = require "octo.constants"

---@param chunks [string, string?][]
---@return string
local function text(chunks)
  local out = {}
  for _, chunk in ipairs(chunks) do
    table.insert(out, chunk[1])
  end
  return table.concat(out)
end

describe("body structure:", function()
  describe("parse", function()
    it("reads headings with their level, marker and text", function()
      local structure = body.parse { "# One", "text", "##  Two words  ", "#not a heading", "####### seven" }

      eq(2, #structure.headings)
      eq({ line = 1, level = 1, marker = 2, text = "One" }, structure.headings[1])
      eq({ line = 3, level = 2, marker = 4, text = "Two words" }, structure.headings[2])
    end)

    it("finds a run of tasks and counts what is done", function()
      local structure = body.parse { "intro", "- [ ] a", "- [x] b", "- [X] c", "after" }

      eq(1, #structure.tasklists)
      local list = structure.tasklists[1]
      eq(2, list.first)
      eq(4, list.last)
      eq(2, list.done)
      eq(3, list.total)
      eq({ indent = 0, bullet = 2 }, list.markers[2])
    end)

    it("takes its title from the heading above, across blank lines", function()
      local structure = body.parse { "## Steps", "", "- [ ] a", "- [ ] b" }

      eq("Steps", structure.tasklists[1].title)
    end)

    it("falls back to a generic title when nothing above is a heading", function()
      local structure = body.parse { "Some prose", "- [ ] a" }

      eq(body.DEFAULT_TITLE, structure.tasklists[1].title)
      eq(body.DEFAULT_TITLE, body.parse({ "- [ ] first thing" }).tasklists[1].title)
    end)

    it("splits runs on a line that is not a task", function()
      local structure = body.parse { "- [ ] a", "prose", "- [x] b", "- [ ] c" }

      eq(2, #structure.tasklists)
      eq({ 1, 1 }, { structure.tasklists[1].first, structure.tasklists[1].last })
      eq({ 3, 4 }, { structure.tasklists[2].first, structure.tasklists[2].last })
    end)

    it("ignores headings and tasks inside fenced code", function()
      local structure = body.parse { "```", "# not a heading", "- [ ] not a task", "```", "~~~", "## nor this", "~~~" }

      eq({}, structure.headings)
      eq({}, structure.tasklists)
    end)

    it("accepts ordered and nested items in one run", function()
      local structure = body.parse { "1. [ ] a", "   - [x] b", "2) [ ] c" }

      eq(1, #structure.tasklists)
      eq(3, structure.tasklists[1].total)
      eq({ indent = 3, bullet = 2 }, structure.tasklists[1].markers[2])
      eq({ indent = 0, bullet = 3 }, structure.tasklists[1].markers[3])
    end)

    it("does not mistake a box glued to text for a task", function()
      eq({}, body.parse({ "- [ ]x" }).tasklists)
      eq(1, #body.parse({ "- [ ]" }).tasklists)
    end)
  end)

  describe("inset", function()
    it("is the rail's width on a task line and nothing elsewhere", function()
      local structure = body.parse { "# H", "- [ ] a", "- [ ] b", "prose" }

      eq(0, body.inset(structure, 1))
      eq(2, body.inset(structure, 2))
      eq(2, body.inset(structure, 3))
      eq(0, body.inset(structure, 4))
    end)
  end)

  describe("render", function()
    local bufnr
    local lines = { "## Story", "prose", "", "## Steps", "- [ ] one", "- [x] two", "  - [ ] three", "after" }

    before_each(function()
      bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    end)

    after_each(function()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    ---@return table[]
    local function marks()
      return vim.api.nvim_buf_get_extmarks(bufnr, constants.OCTO_BODY_NS, 0, -1, { details = true })
    end

    it("leaves the text byte for byte as it was", function()
      body.render(bufnr, 0, lines, { width = 40 })

      eq(lines, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    end)

    it("conceals the hashes and highlights the heading", function()
      body.render(bufnr, 0, lines, { width = 40 })

      local concealed, highlighted = {}, {}
      for _, mark in ipairs(marks()) do
        local row, col, details = mark[2], mark[3], mark[4]
        if details.conceal == "" and details.end_col == 3 and col == 0 then
          table.insert(concealed, row)
        elseif details.hl_group == "OctoLayoutHeading" then
          table.insert(highlighted, { row, col, details.end_col })
        end
      end
      eq({ 0, 3 }, concealed)
      eq({ { 0, 3, #"## Story" }, { 3, 3, #"## Steps" } }, highlighted)
    end)

    it("draws a titled panel with a rail over a task run", function()
      body.render(bufnr, 0, lines, { width = 40 })

      local panel_rows, title, bottom, bullets = {}, nil, nil, {}
      for _, mark in ipairs(marks()) do
        local row, col, details = mark[2], mark[3], mark[4]
        if details.line_hl_group == "OctoLayoutPanel" then
          table.insert(panel_rows, row)
          eq("inline", details.virt_text_pos)
          eq("│ ", text(details.virt_text))
        end
        if details.virt_lines and details.virt_lines_above then
          title = text(details.virt_lines[1])
        elseif details.virt_lines then
          bottom = { row, text(details.virt_lines[1]) }
        end
        if details.conceal == "" and details.end_col == col + 2 and row >= 4 then
          table.insert(bullets, { row, col })
        end
      end
      eq({ 4, 5, 6 }, panel_rows)
      assert.is_truthy(title:find("┌ Steps 1/3 ", 1, true))
      eq(40, vim.fn.strdisplaywidth(title))
      eq({ 6, "└" }, bottom)
      eq({ { 4, 0 }, { 5, 0 }, { 6, 2 } }, bullets)
    end)

    it("clips the panel's lines to the column and carries the rail across them", function()
      body.render(bufnr, 0, lines, { width = 30, rail = 33 })

      local title, bottom
      for _, mark in ipairs(marks()) do
        if mark[4].virt_lines_above then
          title = text(mark[4].virt_lines[1])
        elseif mark[4].virt_lines then
          bottom = text(mark[4].virt_lines[1])
        end
      end
      -- the rule fills the column, stops there, and the rail stands in its place
      eq(34, vim.fn.strdisplaywidth(title))
      eq("─", vim.fn.strcharpart(title, 29, 1))
      eq("   │", vim.fn.strcharpart(title, 30, 4))
      eq("└" .. string.rep(" ", 32) .. "│", bottom)
    end)

    it("shortens a title that would not fit the column", function()
      local long = { "## " .. string.rep("x", 60), "- [ ] a" }
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, long)
      body.render(bufnr, 0, long, { width = 30, rail = 33 })

      local title
      for _, mark in ipairs(marks()) do
        if mark[4].virt_lines_above then
          title = text(mark[4].virt_lines[1])
        end
      end
      eq(34, vim.fn.strdisplaywidth(title))
      assert.is_truthy(title:find("…", 1, true))
    end)

    it("draws nothing over a body without structure", function()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "just prose", "and more" })
      body.render(bufnr, 0, { "just prose", "and more" })

      eq({}, marks())
    end)

    it("starts over on a second render", function()
      body.render(bufnr, 0, lines)
      local before = #marks()
      body.render(bufnr, 0, lines)

      eq(before, #marks())
    end)
  end)
end)
