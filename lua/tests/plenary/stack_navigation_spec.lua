---@diagnostic disable
local eq = assert.are.same

describe("go_to_stack_neighbor:", function()
  local navigation
  local utils
  local opened
  local info_messages
  local current_position

  local function make_stack_entry(position)
    return {
      position = position,
      stack = {
        id = "S_1",
        number = 350,
        size = 3,
        baseRefName = "main",
        entries = {
          nodes = {
            { position = 3, pullRequest = { number = 343, title = "Top PR", state = "OPEN", isDraft = false } },
            { position = 1, pullRequest = { number = 330, title = "Bottom PR", state = "MERGED", isDraft = false } },
            { position = 2, pullRequest = { number = 333, title = "Current PR", state = "OPEN", isDraft = false } },
          },
        },
      },
    }
  end

  local stack_entry

  before_each(function()
    opened = nil
    info_messages = {}
    current_position = 2
    stack_entry = make_stack_entry(current_position)

    navigation = require "octo.navigation"
    utils = require "octo.utils"

    utils.get_current_buffer = function()
      return {
        number = 333,
        repo = "owner/repo",
        isPullRequest = function()
          return true
        end,
        pullRequest = function()
          return { stackEntry = stack_entry }
        end,
      }
    end

    utils.get_pull_request = function(number, repo)
      opened = { number = number, repo = repo }
    end

    utils.info = function(msg)
      table.insert(info_messages, msg)
    end
  end)

  after_each(function()
    package.loaded["octo.navigation"] = nil
    package.loaded["octo.utils"] = nil
  end)

  it("goes up one PR in the stack", function()
    navigation.go_to_stack_neighbor(1)
    eq({ number = 343, repo = "owner/repo" }, opened)
  end)

  it("goes down one PR in the stack", function()
    navigation.go_to_stack_neighbor(-1)
    eq({ number = 330, repo = "owner/repo" }, opened)
  end)

  it("does nothing at the top of the stack", function()
    stack_entry = make_stack_entry(3)
    navigation.go_to_stack_neighbor(1)
    eq(nil, opened)
    eq(0, #info_messages)
  end)

  it("does nothing at the bottom of the stack", function()
    stack_entry = make_stack_entry(1)
    navigation.go_to_stack_neighbor(-1)
    eq(nil, opened)
    eq(0, #info_messages)
  end)

  it("notifies when the PR is not part of a stack", function()
    stack_entry = nil
    navigation.go_to_stack_neighbor(1)
    eq(nil, opened)
    eq(1, #info_messages)
  end)

  it("notifies when the neighbor PR is not accessible", function()
    stack_entry.stack.entries.nodes[1].pullRequest = vim.NIL
    navigation.go_to_stack_neighbor(1)
    eq(nil, opened)
    eq(1, #info_messages)
  end)

  it("does nothing outside PR buffers", function()
    utils.get_current_buffer = function()
      return nil
    end
    navigation.go_to_stack_neighbor(1)
    eq(nil, opened)
    eq(0, #info_messages)
  end)
end)
