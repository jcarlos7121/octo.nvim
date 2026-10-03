---What the board can do to a card.
local gh = require "octo.gh"
local graphql = require "octo.gh.graphql"

local M = {}

---Where a card would land if it moved one column in `direction`.
---
---Returns nothing rather than clamping, so a move at either end is a no-op instead
---of a silent write to the column the card is already in. Cards in the No Status
---column have no project item to write, and that column cannot be written to either,
---so neither end of such a move is allowed.
---@param columns octo.kanban.Column[]
---@param from_index integer
---@param direction integer -1 or 1
---@return integer? index of the destination column
function M.target_column(columns, from_index, direction)
  local from = columns[from_index]
  if not from or not from.option_id then
    return nil
  end

  local to_index = from_index + direction
  local to = columns[to_index]
  if not to or not to.option_id then
    return nil
  end

  return to_index
end

---Writes a card's new status to the project.
---@param opts table { project_id, item_id, field_id, option_id }
---@param cb fun(err: string?)
function M.move(opts, cb)
  local mutation = graphql(
    "update_project_v2_item_mutation",
    opts.project_id,
    opts.item_id,
    opts.field_id,
    opts.option_id
  )

  gh.api.graphql {
    query = mutation,
    opts = {
      cb = function(stdout, stderr)
        if stderr and stderr ~= "" then
          cb(stderr)
          return
        end
        local ok, decoded = pcall(vim.json.decode, stdout)
        if not ok or not decoded or not decoded.data then
          cb "could not move the card"
          return
        end
        cb(nil)
      end,
    },
  }
end

return M
