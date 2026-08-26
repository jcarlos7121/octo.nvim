---@diagnostic disable
local eq = assert.are.same

describe("workflow runs: back to the pull request", function()
  local workflow_runs
  local utils
  local opened
  local info_messages

  before_each(function()
    opened = nil
    info_messages = {}

    -- octo/init.lua defines this global; specs run standalone do not get it
    _G.octo_buffers = _G.octo_buffers or {}

    workflow_runs = require "octo.workflow_runs"
    utils = require "octo.utils"

    utils.get_pull_request = function(number, repo)
      opened = { number = number, repo = repo }
    end
    utils.info = function(msg)
      table.insert(info_messages, msg)
    end
  end)

  after_each(function()
    package.loaded["octo.workflow_runs"] = nil
    package.loaded["octo.utils"] = nil
  end)

  it("returns to the origin buffer while it is still loaded", function()
    local origin = vim.api.nvim_create_buf(false, true)
    local other = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(other)

    workflow_runs.origin = { bufnr = origin, repo = "owner/repo", number = 42 }
    workflow_runs.go_to_pull_request()

    eq(origin, vim.api.nvim_get_current_buf())
    eq(nil, opened)

    vim.api.nvim_buf_delete(origin, { force = true })
    vim.api.nvim_buf_delete(other, { force = true })
  end)

  it("reopens the pull request when the origin buffer is gone", function()
    local gone = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_delete(gone, { force = true })

    workflow_runs.origin = { bufnr = gone, repo = "owner/repo", number = 42 }
    workflow_runs.go_to_pull_request()

    eq({ number = 42, repo = "owner/repo" }, opened)
  end)

  describe("close_buffer", function()
    it("closes the run buffer and returns to the pull request", function()
      local pr_view = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(pr_view, "octo://owner/repo/pull/42")
      local run_view = vim.api.nvim_create_buf(true, true)
      vim.api.nvim_buf_set_name(run_view, "octo-workflow-run:123:" .. run_view)
      vim.api.nvim_set_current_buf(run_view)

      workflow_runs.origin = { bufnr = pr_view, repo = "owner/repo", number = 42 }
      workflow_runs.close_buffer()

      eq(pr_view, vim.api.nvim_get_current_buf())
      eq(false, vim.api.nvim_buf_is_valid(run_view))

      vim.api.nvim_buf_delete(pr_view, { force = true })
    end)

    it("falls back to a real file when the pull request buffer is gone", function()
      local file = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(file, "/tmp/routes.rb")
      local run_view = vim.api.nvim_create_buf(true, true)
      vim.api.nvim_buf_set_name(run_view, "octo-workflow-run:123:" .. run_view)
      vim.api.nvim_set_current_buf(file)
      vim.api.nvim_set_current_buf(run_view)

      workflow_runs.origin = nil
      workflow_runs.close_buffer()

      eq(file, vim.api.nvim_get_current_buf())
      eq(false, vim.api.nvim_buf_is_valid(run_view))

      vim.api.nvim_buf_delete(file, { force = true })
    end)
  end)

  it("notifies when the run was not opened from a pull request", function()
    workflow_runs.origin = nil
    workflow_runs.go_to_pull_request()

    eq(nil, opened)
    eq(1, #info_messages)
  end)
  it("reopens the file the run was opened over when nothing else is left", function()
    local path = vim.fn.resolve "/tmp" .. "/octo-run-origin-spec.rb"
    vim.fn.writefile({ "# routes" }, path)
    local run_buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(run_buf, "octo-workflow-run:77:" .. run_buf)
    vim.api.nvim_set_current_buf(run_buf)
    vim.b[run_buf].octo_origin_file = path
    workflow_runs.origin = nil
    utils.landing_buffer = function()
      return nil
    end

    workflow_runs.close_buffer()

    eq(path, vim.api.nvim_buf_get_name(0))
    eq(false, vim.api.nvim_buf_is_valid(run_buf))
    pcall(vim.api.nvim_buf_delete, vim.fn.bufnr(path), { force = true })
    vim.fn.delete(path)
  end)
end)
