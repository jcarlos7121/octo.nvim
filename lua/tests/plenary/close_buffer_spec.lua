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

    -- octo/init.lua defines this global; specs run standalone do not get it
    _G.octo_buffers = _G.octo_buffers or {}

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

  it("lands on a real file rather than another Octo buffer", function()
    local file = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(file, "/tmp/routes.rb")
    local run_view = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(run_view, "octo-workflow-run:123:" .. run_view)
    local octo_buf = vim.api.nvim_create_buf(true, false)

    vim.api.nvim_set_current_buf(file)
    vim.api.nvim_set_current_buf(run_view)
    vim.api.nvim_set_current_buf(octo_buf) -- alternate is now the run view
    utils.get_current_buffer = function()
      return { bufnr = octo_buf }
    end

    commands.close_buffer()

    eq(file, vim.api.nvim_get_current_buf())
    eq(false, vim.api.nvim_buf_is_valid(octo_buf))

    vim.api.nvim_buf_delete(run_view, { force = true })
    vim.api.nvim_buf_delete(file, { force = true })
  end)

  describe("landing_buffer", function()
    it("skips octo-owned buffers and the buffer being closed", function()
      local file = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(file, "/tmp/schema.rb")
      local run_view = vim.api.nvim_create_buf(true, true)
      vim.api.nvim_buf_set_name(run_view, "octo-workflow-run:9:" .. run_view)
      local pr_view = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(pr_view, "octo://owner/repo/pull/7")
      local closing = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(closing, "/tmp/closing.rb")

      vim.api.nvim_set_current_buf(file)
      vim.api.nvim_set_current_buf(run_view)
      vim.api.nvim_set_current_buf(pr_view)
      vim.api.nvim_set_current_buf(closing)

      eq(file, utils.landing_buffer(closing))
      eq(true, utils.is_octo_owned_buffer(run_view))
      eq(true, utils.is_octo_owned_buffer(pr_view))
      eq(false, utils.is_octo_owned_buffer(file))

      for _, b in ipairs { file, run_view, pr_view, closing } do
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end)
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
