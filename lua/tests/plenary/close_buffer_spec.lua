---@diagnostic disable
local eq = assert.are.same

describe("close_buffer:", function()
  local commands
  local utils
  local original_confirm
  local confirm_answer
  local confirm_prompts

  local function make_buffers()
    local previous = vim.api.nvim_create_buf(true, true)
    -- octo buffers are acwrite, not scratch: 'modified' does not stick on nofile buffers
    local octo_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(previous)
    vim.api.nvim_set_current_buf(octo_buf) -- previous becomes the alternate
    return previous, octo_buf
  end

  before_each(function()
    confirm_answer = 1
    confirm_prompts = {}

    commands = require "octo.commands"
    utils = require "octo.utils"

    original_confirm = vim.fn.confirm
    vim.fn.confirm = function(prompt)
      table.insert(confirm_prompts, prompt)
      return confirm_answer
    end
  end)

  after_each(function()
    vim.fn.confirm = original_confirm
    package.loaded["octo.commands"] = nil
    package.loaded["octo.utils"] = nil
  end)

  it("closes the buffer and returns to the previous one", function()
    local previous, octo_buf = make_buffers()
    utils.get_current_buffer = function()
      return { bufnr = octo_buf }
    end

    commands.close_buffer()

    eq(previous, vim.api.nvim_get_current_buf())
    eq(false, vim.api.nvim_buf_is_valid(octo_buf))
    eq(0, #confirm_prompts)

    vim.api.nvim_buf_delete(previous, { force = true })
  end)

  it("keeps the buffer when unsaved changes are not discarded", function()
    local previous, octo_buf = make_buffers()
    vim.api.nvim_buf_set_lines(octo_buf, 0, -1, false, { "unsynced comment" })
    utils.get_current_buffer = function()
      return { bufnr = octo_buf }
    end
    confirm_answer = 2 -- "No"

    commands.close_buffer()

    eq(1, #confirm_prompts)
    eq(true, vim.api.nvim_buf_is_valid(octo_buf))
    eq(octo_buf, vim.api.nvim_get_current_buf())

    vim.bo[octo_buf].modified = false
    vim.api.nvim_buf_delete(octo_buf, { force = true })
    vim.api.nvim_buf_delete(previous, { force = true })
  end)

  it("closes a modified buffer once discarding is confirmed", function()
    local previous, octo_buf = make_buffers()
    vim.api.nvim_buf_set_lines(octo_buf, 0, -1, false, { "unsynced comment" })
    utils.get_current_buffer = function()
      return { bufnr = octo_buf }
    end
    confirm_answer = 1 -- "Yes"

    commands.close_buffer()

    eq(1, #confirm_prompts)
    eq(false, vim.api.nvim_buf_is_valid(octo_buf))

    vim.api.nvim_buf_delete(previous, { force = true })
  end)

  it("does nothing outside octo buffers", function()
    local other = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_set_current_buf(other)
    utils.get_current_buffer = function()
      return nil
    end

    commands.close_buffer()

    eq(other, vim.api.nvim_get_current_buf())
    eq(true, vim.api.nvim_buf_is_valid(other))
    vim.api.nvim_buf_delete(other, { force = true })
  end)
end)
