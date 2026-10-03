---@diagnostic disable
local kanban = require "octo.kanban"

describe("kanban buffer", function()
  describe("where closing the board lands", function()
    local function plan(opts)
      return kanban.landing(vim.tbl_extend("force", {
        board = 3,
        valid = function()
          return false
        end,
        readable = function()
          return false
        end,
      }, opts))
    end

    local function only(...)
      local live = {}
      for _, bufnr in ipairs { ... } do
        live[bufnr] = true
      end
      return function(bufnr)
        return live[bufnr] == true
      end
    end

    it("goes back to the buffer the board was opened over", function()
      assert.are.same({ buffer = 7 }, plan { origin = 7, alternate = 9, valid = only(7, 9) })
    end)

    it("falls back to the alternate when that buffer is gone", function()
      assert.are.same({ buffer = 9 }, plan { origin = 7, alternate = 9, valid = only(9) })
    end)

    it("never lands on the board it is closing", function()
      assert.is_nil(plan { origin = 3, alternate = 3, valid = only(3) })
    end)

    it("reopens the file when every buffer has been dropped", function()
      -- a bufhidden=delete setup deletes the file buffer the moment the board
      -- takes its window, so by closing time there is no buffer left to go back to
      assert.are.same(
        { path = "/code/routes.rb" },
        plan {
          origin = 7,
          origin_path = "/code/routes.rb",
          alternate = 9,
          readable = function()
            return true
          end,
        }
      )
    end)

    it("prefers a living buffer over reopening the file", function()
      assert.are.same(
        { buffer = 7 },
        plan {
          origin = 7,
          origin_path = "/code/routes.rb",
          valid = only(7),
          readable = function()
            return true
          end,
        }
      )
    end)

    it("has nowhere to go when the file is gone too", function()
      assert.is_nil(plan { origin = 7, origin_path = "/code/gone.rb" })
      assert.is_nil(plan {})
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
