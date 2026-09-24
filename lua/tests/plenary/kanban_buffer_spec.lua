---@diagnostic disable
local kanban = require "octo.kanban"

describe("kanban buffer", function()
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
