---Tests for the two-column layout primitives
local layout = require "octo.ui.layout"
local config = require "octo.config"

local eq = assert.are.same

---@param chunks octo.ChunkLine
---@return string
local function text(chunks)
  local out = {}
  for _, chunk in ipairs(chunks) do
    table.insert(out, chunk[1])
  end
  return table.concat(out)
end

describe("layout", function()
  local bufnr

  before_each(function()
    config.values = config.get_default_values()
    bufnr = vim.api.nvim_create_buf(false, true)
  end)

  describe("dims", function()
    it("splits a wide window into a main column and a sidebar", function()
      local dims = layout.dims(bufnr, { width = 120 })

      eq(false, dims.stacked)
      eq(34, dims.sidebar)
      eq(120 - 34 - layout.GAP, dims.main)
      eq(dims.main, dims.gutter)
    end)

    it("stacks when the main column would be cramped", function()
      local dims = layout.dims(bufnr, { width = 80 })

      eq(true, dims.stacked)
      eq(0, dims.sidebar)
      eq(80, dims.main)
    end)

    it("takes the widths from the config", function()
      config.values.ui.sidebar_width = 20
      config.values.ui.min_main_width = 30

      local dims = layout.dims(bufnr, { width = 60 })

      eq(false, dims.stacked)
      eq(20, dims.sidebar)
    end)
  end)

  describe("truncate", function()
    it("leaves a line that fits alone", function()
      local line = { { "abc", "Hl" }, { "de" } }

      eq(line, layout.truncate(line, 10))
    end)

    it("marks the cut with an ellipsis", function()
      eq("abcd…", text(layout.truncate({ { "abcdefghij" } }, 5)))
    end)

    it("drops the chunks past the width", function()
      local out = layout.truncate({ { "abc", "A" }, { "def", "B" }, { "ghi", "C" } }, 4)

      eq(2, #out)
      eq("A", out[1][2])
      eq("abc", out[1][1])
    end)

    it("counts what a wide character occupies, not its bytes", function()
      -- three double-width characters is six columns, so only two fit in five
      eq(5, vim.fn.strdisplaywidth(text(layout.truncate({ { "一二三" } }, 5))))
    end)
  end)

  describe("pad", function()
    it("fills what is left with spaces", function()
      eq("ab        ", text(layout.pad({ { "ab" } }, 10)))
    end)

    it("clips a line too long to pad", function()
      eq(4, vim.fn.strdisplaywidth(text(layout.pad({ { "abcdefg" } }, 4))))
    end)
  end)

  describe("columns", function()
    it("puts the sidebar past the main column, behind the rail", function()
      local dims = layout.dims(bufnr, { width = 100 })

      local line = text(layout.columns({ { "main" } }, { { "side" } }, dims))

      eq("main" .. string.rep(" ", dims.main - 4) .. " " .. layout.RAIL .. " side", line)
    end)

    it("draws no rail when stacked", function()
      local dims = layout.dims(bufnr, { width = 40 })

      eq("main", text(layout.columns({ { "main" } }, { { "side" } }, dims)))
    end)
  end)

  describe("compose", function()
    it("is as long as its longer side", function()
      local dims = layout.dims(bufnr, { width = 100 })

      eq(3, #layout.compose({ { { "a" } } }, { { { "b" } }, { { "c" } }, { { "d" } } }, dims))
    end)

    it("puts the sidebar below the main column when stacked", function()
      local dims = layout.dims(bufnr, { width = 40 })

      local lines = layout.compose({ { { "main" } } }, { { { "side" } } }, dims)

      eq(3, #lines)
      eq("main", text(lines[1]))
      eq("", text(lines[2]))
      eq("side", text(lines[3]))
    end)
  end)

  describe("sidebar", function()
    it("lines up the values of a group under each other", function()
      local lines = layout.sidebar {
        { title = "people", rows = { { "author", "someone" }, { "assignee", "nobody" } } },
      }

      eq("PEOPLE", text(lines[1]))
      eq("author    someone", text(lines[2]))
      eq("assignee  nobody", text(lines[3]))
    end)

    it("separates groups with a blank line and leaves empty ones out", function()
      local lines = layout.sidebar {
        { title = "one", rows = { { "a", "1" } } },
        { title = "empty", rows = {} },
        { title = "two", rows = { { "b", "2" } } },
      }

      eq({ "ONE", "a  1", "", "TWO", "b  2" }, vim.tbl_map(text, lines))
    end)

    it("takes a value already in chunks", function()
      local lines = layout.sidebar {
        { title = "t", rows = { { "k", { { "v", "OctoUser" } } } } },
      }

      eq("OctoUser", lines[2][#lines[2]][2])
    end)
  end)

  describe("draw", function()
    it("paints one extmark per line of the drawing", function()
      config.values.ui.min_main_width = 10 -- the columns fit, so the lines pair up
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "", "", "", "" })

      layout.draw(bufnr, 0, { { { "a" } }, { { "b" } } }, { { { "c" } } })

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, require("octo.constants").OCTO_LAYOUT_NS, 0, -1, {})
      eq(2, #marks)
    end)

    it("lays the drawing out again for a new width", function()
      config.values.ui.min_main_width = 10
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "", "" })
      layout.draw(bufnr, 0, { { { "main" } } }, { { { "side" } } })

      local ns = require("octo.constants").OCTO_LAYOUT_NS
      local before = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })[1][4].virt_text

      config.values.ui.min_main_width = 10000 -- as if the window had become narrow
      vim.api.nvim_exec_autocmds("VimResized", {})
      local after = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })[1][4].virt_text

      assert.is_truthy(text(before):find(layout.RAIL, 1, true))
      eq("main", text(after))
    end)

    it("forgets a buffer that is gone", function()
      local doomed = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(doomed, 0, -1, false, { "" })
      layout.draw(doomed, 0, { { { "a" } } }, {})
      vim.api.nvim_buf_delete(doomed, { force = true })

      vim.api.nvim_exec_autocmds("VimResized", {})

      eq(nil, layout.drawings[doomed])
    end)
  end)
end)
