local gh = require "octo.gh"
local utils = require "octo.utils"
local window = require "octo.ui.window"

local M = {}

---@class octo.StackViewPR
---@field number integer
---@field url string
---@field state "OPEN"|"MERGED"|"QUEUED"

---@class octo.StackViewBranch
---@field name string
---@field head string
---@field base string
---@field isCurrent boolean
---@field isMerged boolean
---@field isQueued boolean
---@field needsRebase boolean
---@field pr? octo.StackViewPR

---@class octo.StackView
---@field trunk string
---@field currentBranch string
---@field branches octo.StackViewBranch[] bottom of the stack first

---Build the preview lines for a stack: top of the stack first, trunk last.
---@param stack octo.StackView
---@return string[]
function M.build_stack_preview(stack)
  local lines = {} ---@type string[]
  local needs_rebase = false
  for i = #stack.branches, 1, -1 do
    local branch = stack.branches[i]
    local marker = branch.isCurrent and "▶" or " "
    local pr_info ---@type string
    if branch.pr and branch.pr ~= vim.NIL then
      pr_info = string.format("#%d (%s)", branch.pr.number, branch.pr.state)
    else
      pr_info = "new PR"
    end
    table.insert(lines, string.format(" %s %s · %s", marker, branch.name, pr_info))
    needs_rebase = needs_rebase or branch.needsRebase
  end
  table.insert(lines, string.format(" ○ %s", stack.trunk))
  if needs_rebase then
    table.insert(lines, "")
    table.insert(lines, " ⚠ some branches need a rebase: run 'gh stack sync' first")
  end
  table.insert(lines, "")
  table.insert(lines, " <CR> create/update stack · q cancel")
  return lines
end

---Show the stack preview in a centered float; call on_confirm when accepted.
---@param stack octo.StackView
---@param on_confirm fun()
function M.show_stack_preview(stack, on_confirm)
  local winid, bufnr = window.create_centered_float {
    header = "Preview stack",
    content = M.build_stack_preview(stack),
    enter = true,
  }
  vim.bo[bufnr].modifiable = false

  local function close()
    window.try_close_wins(winid)
  end

  local mapping_opts = { silent = true, noremap = true, buffer = bufnr }
  vim.keymap.set("n", "q", close, mapping_opts)
  vim.keymap.set("n", "<Esc>", close, mapping_opts)
  vim.keymap.set("n", "<CR>", function()
    close()
    on_confirm()
  end, mapping_opts)
end

---Push the stack branches and create or update their PRs on GitHub.
function M.submit()
  utils.info "Submitting stack..."
  gh.stack.submit {
    auto = true,
    opts = {
      cb = function(output, stderr, exit_code)
        if exit_code == 0 then
          local message = not utils.is_blank(stderr) and stderr or output
          utils.info(utils.is_blank(message) and "Stack submitted" or message)
        else
          utils.error(utils.is_blank(stderr) and "Failed to submit the stack" or stderr)
        end
      end,
    },
  }
end

---Preview the stack for the current branch and submit it on confirmation.
---Requires the gh-stack extension (gh extension install github/gh-stack).
function M.create()
  gh.stack.view {
    json = true,
    opts = {
      cb = function(output, stderr, exit_code)
        if exit_code ~= 0 then
          if stderr and stderr:find('unknown command "stack"', 1, true) then
            utils.error "The gh-stack extension is required: run 'gh extension install github/gh-stack'"
          elseif exit_code == 2 then
            utils.error "The current branch is not part of a stack: run 'gh stack init' first"
          else
            utils.error(utils.is_blank(stderr) and "Failed to read the stack" or stderr)
          end
          return
        end

        local ok, stack = pcall(vim.json.decode, output)
        if not ok or utils.is_blank(stack) or utils.is_blank(stack.branches) then
          utils.error "Failed to parse the stack"
          return
        end

        M.show_stack_preview(stack, function()
          M.submit()
        end)
      end,
    },
  }
end

return M
