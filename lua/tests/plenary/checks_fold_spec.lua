---@diagnostic disable
local eq = assert.are.same
local config = require "octo.config"
local constants = require "octo.constants"
local folds = require "octo.folds"

---A buffer of empty lines in a real window: manual folds live in the window
---@param count integer
local function scratch(count)
  local lines = {}
  for _ = 1, count do
    table.insert(lines, "")
  end
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 120,
    height = 60,
    row = 0,
    col = 0,
  })
  return bufnr, win
end

---@param bufnr integer
---@param line integer
---@param chunks [string, string][]
local function details_text(bufnr, line, chunks)
  vim.api.nvim_buf_set_extmark(bufnr, constants.OCTO_DETAILS_VT_NS, line - 1, 0, {
    virt_text = chunks,
    virt_text_pos = "eol",
  })
end

describe("checks fold:", function()
  local bufnr
  local win
  local original_foldtext

  before_each(function()
    _G.octo_buffers = _G.octo_buffers or {}
    original_foldtext = config.values.ui.use_foldtext
    config.values.ui.use_foldtext = true
    bufnr, win = scratch(20)
  end)

  after_each(function()
    config.values.ui.use_foldtext = original_foldtext
    _G.octo_buffers[bufnr] = nil
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  describe("create_checks", function()
    it("folds the checks away behind the summary line", function()
      local fold = folds.create_checks(bufnr, 5, 9, false)

      eq({ start = 5, stop = 9, summary_line = 5, count = 4 }, fold)
      eq(5, vim.fn.foldclosed(5)) -- the summary stands in for the fold
      eq(9, vim.fn.foldclosedend(5))
      eq(-1, vim.fn.foldclosed(10)) -- the detail below it is untouched
    end)

    it("keeps the summary out of the fold without octo's foldtext", function()
      config.values.ui.use_foldtext = false
      local fold = folds.create_checks(bufnr, 5, 9, false)

      eq(6, fold.start)
      eq(-1, vim.fn.foldclosed(5)) -- summary still readable
      eq(6, vim.fn.foldclosed(6))
    end)

    it("leaves the fold open when asked", function()
      local fold = folds.create_checks(bufnr, 5, 9, true)

      eq(-1, vim.fn.foldclosed(fold.start))
      eq(1, vim.fn.foldlevel(fold.start)) -- the fold exists, it is just open
    end)

    it("has nothing to fold with a summary and no checks", function()
      eq(nil, folds.create_checks(bufnr, 5, 5, false))
      eq(0, vim.fn.foldlevel(5))
    end)

    it("moves the state of an existing fold rather than nesting a new one", function()
      folds.create_checks(bufnr, 5, 9, false)
      local fold = folds.create_checks(bufnr, 5, 9, true) -- a re-render

      eq(5, fold.start)
      eq(1, vim.fn.foldlevel(6)) -- still one fold, not two
      eq(-1, vim.fn.foldclosed(5))
    end)
  end)

  describe("foldtext", function()
    it("shows the summary and the number of checks it hides", function()
      details_text(bufnr, 5, { { "Checks: ", "OctoDetailsLabel" }, { "1 failed", "OctoStateDismissed" } })
      _G.octo_buffers[bufnr] = { checksFold = folds.create_checks(bufnr, 5, 9, false) }

      local chunks = folds.foldtext_for(bufnr, 5)
      eq("Checks: ", chunks[1][1])
      eq("1 failed", chunks[2][1])
      assert.is_truthy(chunks[3][1]:find("4 checks", 1, true))
    end)

    it("shows only the count when the summary stays on screen", function()
      config.values.ui.use_foldtext = false
      details_text(bufnr, 5, { { "Checks: ", "OctoDetailsLabel" } })
      local fold = folds.create_checks(bufnr, 5, 9, false)
      _G.octo_buffers[bufnr] = { checksFold = fold }

      local chunks = folds.foldtext_for(bufnr, fold.start)
      eq(2, #chunks)
      assert.is_truthy(chunks[2][1]:find("4 checks", 1, true))
      assert.is_falsy(chunks[1][1]:find("Checks:", 1, true))
    end)

    it("leaves other folds to the usual foldtext", function()
      details_text(bufnr, 12, { { "    ", "Normal" } })
      _G.octo_buffers[bufnr] = { checksFold = folds.create_checks(bufnr, 5, 9, false) }

      eq({ { "    ", "Normal" } }, folds.foldtext_for(bufnr, 12))
    end)
  end)

  describe("write_details", function()
    local writers = require "octo.ui.writers"

    ---@param name string
    ---@param conclusion string
    local function check(name, conclusion)
      return {
        __typename = "CheckRun",
        name = name,
        status = "COMPLETED",
        conclusion = conclusion,
        startedAt = vim.NIL,
        completedAt = vim.NIL,
        checkSuite = { workflowRun = { workflow = { name = "CI" } } },
      }
    end

    local function pull_request()
      return {
        url = "https://github.com/owner/repo/pull/7",
        number = 7,
        state = "OPEN",
        author = { login = "someone" },
        createdAt = "2026-08-01T10:00:00Z",
        headRefName = "feature_a",
        baseRefName = "master",
        labels = { nodes = {} },
        timelineItems = { nodes = {} },
        reactionGroups = {},
        assignees = { nodes = {} },
        reviewRequests = { totalCount = 0, nodes = {} },
        latestReviews = { nodes = {} },
        milestone = vim.NIL,
        projectCards = { nodes = {} },
        projectItems = { nodes = {} },
        additions = 3,
        deletions = 1,
        changedFiles = 2,
        commits = { totalCount = 2 },
        merged = false,
        mergeable = "MERGEABLE",
        mergeStateStatus = "CLEAN",
        isDraft = false,
        viewerSubscription = "SUBSCRIBED",
        statusCheckRollup = {
          state = "FAILURE",
          contexts = {
            nodes = {
              check("a", "FAILURE"),
              check("b", "SUCCESS"),
              check("c", "SKIPPED"),
              check("d", "SUCCESS"),
            },
          },
        },
      }
    end

    it("folds the rendered checks list and keeps the checks navigable", function()
      _G.octo_buffers[bufnr] = { bufnr = bufnr }
      writers.write_details(bufnr, pull_request(), false, true)

      local fold = _G.octo_buffers[bufnr].checksFold
      eq(4, fold.count)
      eq(fold.summary_line, fold.start) -- octo's foldtext stands in for it
      eq(fold.start, vim.fn.foldclosed(fold.start))
      eq(fold.stop, vim.fn.foldclosedend(fold.start))

      -- the summary the reader sees while it is closed
      local chunks = folds.foldtext_for(bufnr, fold.start)
      local text = ""
      for _, chunk in ipairs(chunks) do
        text = text .. chunk[1]
      end
      assert.is_truthy(text:find("1 failed", 1, true))
      assert.is_truthy(text:find("▸ 4 checks", 1, true))

      -- and the folded lines still answer `goto_check`
      eq(4, vim.tbl_count(_G.octo_buffers[bufnr].checkByLine))
    end)

    it("renders the list unfolded when the option is off", function()
      config.values.ui.fold_checks = false
      _G.octo_buffers[bufnr] = { bufnr = bufnr }
      writers.write_details(bufnr, pull_request(), false, true)

      eq(nil, _G.octo_buffers[bufnr].checksFold)
      eq(0, vim.fn.foldlevel(13))
      config.values.ui.fold_checks = true
    end)
  end)

  describe("toggle_checks", function()
    local navigation
    local utils
    local buffer
    local info_messages

    before_each(function()
      info_messages = {}
      navigation = require "octo.navigation"
      utils = require "octo.utils"
      utils.info = function(msg)
        table.insert(info_messages, msg)
      end
      buffer = {
        bufnr = bufnr,
        isPullRequest = function()
          return true
        end,
        checksFold = folds.create_checks(bufnr, 5, 9, false),
      }
      utils.get_current_buffer = function()
        return buffer
      end
    end)

    after_each(function()
      package.loaded["octo.navigation"] = nil
      package.loaded["octo.utils"] = nil
      -- the outer after_each may already have wiped the buffer
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.b[bufnr].octo_checks_unfolded = nil
      end
    end)

    it("unfolds a closed list and folds it back", function()
      navigation.toggle_checks()
      eq(-1, vim.fn.foldclosed(5))
      eq(true, vim.b[bufnr].octo_checks_unfolded)

      navigation.toggle_checks()
      eq(5, vim.fn.foldclosed(5))
      eq(false, vim.b[bufnr].octo_checks_unfolded)
    end)

    it("says so when the PR has no checks list", function()
      buffer.checksFold = nil
      navigation.toggle_checks()

      eq(1, #info_messages)
      assert.is_truthy(info_messages[1]:find("checks", 1, true))
      eq(5, vim.fn.foldclosed(5)) -- the fold in the window is left alone
    end)

    it("does nothing outside a pull request buffer", function()
      buffer.isPullRequest = function()
        return false
      end
      navigation.toggle_checks()

      eq(0, #info_messages)
      eq(5, vim.fn.foldclosed(5))
    end)
  end)
end)
