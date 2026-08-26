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

  it("notifies when the run was not opened from a pull request", function()
    workflow_runs.origin = nil
    workflow_runs.go_to_pull_request()

    eq(nil, opened)
    eq(1, #info_messages)
  end)
end)
