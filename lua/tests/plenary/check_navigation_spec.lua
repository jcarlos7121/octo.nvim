---@diagnostic disable
local eq = assert.are.same

describe("go_to_check:", function()
  local navigation
  local utils
  local rendered
  local browsed
  local info_messages
  local offered
  local original_select

  local system_tests = {
    __typename = "CheckRun",
    name = "system_tests",
    detailsUrl = "https://github.com/owner/repo/actions/runs/123/job/456",
    checkSuite = { workflowRun = { workflow = { name = "CI" } } },
  }
  local docker_build = {
    __typename = "CheckRun",
    name = "docker_build",
    detailsUrl = "https://github.com/owner/repo/actions/runs/123/job/789",
    checkSuite = { workflowRun = { workflow = { name = "CI" } } },
  }
  local cla = {
    __typename = "StatusContext",
    context = "license/cla",
    targetUrl = "https://cla.example.com/status",
  }

  local function pr_buffer()
    return {
      repo = "owner/repo",
      isPullRequest = function()
        return true
      end,
      -- a line stands for the checks drawn on it: one in the classic list,
      -- a whole workflow in two columns
      checkByLine = {
        [8] = { system_tests },
        [9] = { cla },
        [10] = { { __typename = "CheckRun", name = "no-url" } },
        [11] = { system_tests, docker_build, cla },
      },
    }
  end

  before_each(function()
    rendered = nil
    browsed = nil
    info_messages = {}
    offered = nil

    package.loaded["octo.workflow_runs"] = {
      render = function(opts)
        rendered = opts
      end,
    }

    navigation = require "octo.navigation"
    utils = require "octo.utils"

    utils.info = function(msg)
      table.insert(info_messages, msg)
    end
    navigation.open_in_browser_raw = function(url)
      browsed = url
    end
    utils.get_current_buffer = pr_buffer

    original_select = vim.ui.select
  end)

  after_each(function()
    vim.ui.select = original_select
    package.loaded["octo.navigation"] = nil
    package.loaded["octo.utils"] = nil
    package.loaded["octo.workflow_runs"] = nil
  end)

  it("opens the workflow run of the check under the cursor", function()
    navigation.go_to_check(8)
    eq({ id = "123", repo = "owner/repo" }, rendered)
    eq(nil, browsed)
  end)

  it("opens external status contexts in the browser", function()
    navigation.go_to_check(9)
    eq("https://cla.example.com/status", browsed)
    eq(nil, rendered)
  end)

  it("notifies when the check has no link", function()
    navigation.go_to_check(10)
    eq(nil, rendered)
    eq(nil, browsed)
    eq(1, #info_messages)
  end)

  it("notifies when the line holds no check", function()
    navigation.go_to_check(3)
    eq(nil, rendered)
    eq(1, #info_messages)
  end)

  it("does nothing outside PR buffers", function()
    utils.get_current_buffer = function()
      return nil
    end
    navigation.go_to_check(8)
    eq(nil, rendered)
    eq(0, #info_messages)
  end)

  describe("on a line standing for several checks", function()
    it("offers them by name and opens the one chosen", function()
      vim.ui.select = function(items, opts, on_choice)
        offered = vim.tbl_map(opts.format_item, items)
        on_choice(items[2])
      end

      navigation.go_to_check(11)

      eq({ "CI / system_tests", "CI / docker_build", "license/cla" }, offered)
      eq({ id = "123", repo = "owner/repo" }, rendered)
      eq(nil, browsed)
    end)

    it("opens a status context chosen the same way", function()
      vim.ui.select = function(items, _, on_choice)
        on_choice(items[3])
      end

      navigation.go_to_check(11)

      eq("https://cla.example.com/status", browsed)
      eq(nil, rendered)
    end)

    it("does nothing when the choice is dismissed", function()
      vim.ui.select = function(_, _, on_choice)
        on_choice(nil)
      end

      navigation.go_to_check(11)

      eq(nil, rendered)
      eq(nil, browsed)
      eq(0, #info_messages)
    end)

    it("asks nothing when the line holds a single check", function()
      vim.ui.select = function()
        error "should not be asked"
      end

      navigation.go_to_check(8)

      eq({ id = "123", repo = "owner/repo" }, rendered)
    end)
  end)
end)
