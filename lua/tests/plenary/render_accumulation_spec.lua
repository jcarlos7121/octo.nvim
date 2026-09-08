---@diagnostic disable
local eq = assert.are.same

describe("rendering the same buffer again:", function()
  local OctoBuffer
  local autocmds
  local constants
  local bufnr

  before_each(function()
    _G.octo_buffers = _G.octo_buffers or {}
    OctoBuffer = require("octo.model.octo-buffer").OctoBuffer
    autocmds = require "octo.autocmds"
    constants = require "octo.constants"
    bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "two", "three" })
  end)

  after_each(function()
    pcall(vim.api.nvim_clear_autocmds, { group = "octobuffer_autocmds", buffer = bufnr })
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    _G.octo_buffers[bufnr] = nil
  end)

  ---@return integer
  local function octo_marks()
    local total = 0
    for name, ns in pairs(vim.api.nvim_get_namespaces()) do
      if name:find "^octo" ~= nil then
        total = total + #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
      end
    end
    return total
  end

  it("starts from a blank slate, whatever marks the last one left", function()
    local buffer = OctoBuffer:new { bufnr = bufnr, number = 1, repo = "owner/repo", kind = "pull", node = {} }

    -- the marks a render leaves scattered across its namespaces
    for _, ns in ipairs {
      constants.OCTO_COMMENT_NS,
      constants.OCTO_EVENT_VT_NS,
      constants.OCTO_THREAD_NS,
      constants.OCTO_TITLE_NS,
      constants.OCTO_DETAILS_VT_NS,
      vim.api.nvim_create_namespace "octo_details_folds",
    } do
      vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, { virt_text = { { "left over", "Normal" } } })
      vim.api.nvim_buf_set_extmark(bufnr, ns, 1, 0, {})
    end
    eq(12, octo_marks())

    buffer:clear()

    eq(0, octo_marks())
  end)

  it("leaves a namespace of its own alone", function()
    local buffer = OctoBuffer:new { bufnr = bufnr, number = 1, repo = "owner/repo", kind = "pull", node = {} }
    local mine = vim.api.nvim_create_namespace "some_other_plugin"
    vim.api.nvim_buf_set_extmark(bufnr, mine, 0, 0, { virt_text = { { "not ours", "Normal" } } })

    buffer:clear()

    eq(1, #vim.api.nvim_buf_get_extmarks(bufnr, mine, 0, -1, {}))
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, mine, 0, -1)
  end)

  it("watches for edits once per buffer, not once per render", function()
    local function watchers()
      local found = 0
      for _, entry in ipairs(vim.api.nvim_get_autocmds { buffer = bufnr }) do
        if entry.group_name == "octobuffer_autocmds" then
          found = found + 1
        end
      end
      return found
    end

    autocmds.update_signs(bufnr)
    eq(2, watchers()) -- TextChanged and TextChangedI

    -- configure() runs again on every render, and used to leave a pair behind
    autocmds.update_signs(bufnr)
    autocmds.update_signs(bufnr)
    autocmds.update_signs(bufnr)

    eq(2, watchers())
  end)
end)
