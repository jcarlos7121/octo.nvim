---@diagnostic disable
local eq = assert.are.same

describe("go_to_stack_pr:", function()
  local navigation
  local utils
  local opened
  local info_messages

  before_each(function()
    opened = nil
    info_messages = {}

    navigation = require "octo.navigation"
    utils = require "octo.utils"

    utils.get_current_buffer = function()
      return {
        repo = "owner/repo",
        isPullRequest = function()
          return true
        end,
        stackPRByLine = { [8] = 343, [9] = 333 },
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

  it("opens the stacked PR on the given line", function()
    navigation.go_to_stack_pr(8)
    eq({ number = 343, repo = "owner/repo" }, opened)
  end)

  it("notifies when the line holds no stack entry", function()
    navigation.go_to_stack_pr(3)
    eq(nil, opened)
    eq(1, #info_messages)
  end)

  it("does nothing outside PR buffers", function()
    utils.get_current_buffer = function()
      return nil
    end
    navigation.go_to_stack_pr(8)
    eq(nil, opened)
    eq(0, #info_messages)
  end)

  it("notifies when the PR has no stack", function()
    utils.get_current_buffer = function()
      return {
        repo = "owner/repo",
        isPullRequest = function()
          return true
        end,
      }
    end
    navigation.go_to_stack_pr(8)
    eq(nil, opened)
    eq(1, #info_messages)
  end)
end)
