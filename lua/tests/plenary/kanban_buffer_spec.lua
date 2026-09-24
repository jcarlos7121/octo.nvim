---@diagnostic disable
local kanban = require "octo.kanban"

describe("kanban buffer", function()
  describe("where closing the board lands", function()
    local function valid(set)
      return function(bufnr)
        return set[bufnr] == true
      end
    end

    it("goes back to the buffer the board was opened over", function()
      assert.are.equal(7, kanban.landing(7, 9, 3, valid { [7] = true, [9] = true }))
    end)

    it("falls back to the alternate when that buffer is gone", function()
      -- the file may have been closed, or an issue opened from the board and then
      -- deleted on its way out, which is what leaves nothing to land on
      assert.are.equal(9, kanban.landing(7, 9, 3, valid { [9] = true }))
    end)

    it("never lands on the board it is closing", function()
      assert.is_nil(kanban.landing(3, 3, 3, valid { [3] = true }))
    end)

    it("has nowhere to go when nothing is left", function()
      assert.is_nil(kanban.landing(7, 9, 3, valid {}))
      assert.is_nil(kanban.landing(nil, nil, 3, valid { [7] = true }))
    end)
  end)

  describe("naming", function()
    it("names the board as one of octo's own views", function()
      -- utils.is_octo_owned_buffer matches on `^octo://`, and previous_view_buffer
      -- only returns buffers it owns. That is what lets <localleader>q on an issue
      -- come back to the board it was opened from, rather than to a file.
      assert.is_truthy(kanban.buffer_name("assignee:me is:open"):match "^octo://")
    end)

    it("folds whitespace out of the name", function()
      assert.are.equal("octo://kanban/assignee:me+is:open", kanban.buffer_name "assignee:me is:open")
    end)

    it("survives a search that is only whitespace", function()
      assert.is_truthy(kanban.buffer_name("  "):match "^octo://kanban/")
    end)
  end)
end)
