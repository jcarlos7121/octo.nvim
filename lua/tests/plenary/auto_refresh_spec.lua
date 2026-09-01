---@diagnostic disable
local eq = assert.are.same

describe("auto refresh:", function()
  local auto_refresh
  local utils
  local config
  local loaded ---@type integer[] buffers handed to load_buffer
  local refetched ---@type integer count of run refetches
  local info_messages
  local run_state

  ---@param kind string
  ---@param dirty boolean
  local function octo_buffer(bufnr, kind, dirty)
    _G.octo_buffers[bufnr] = {
      bufnr = bufnr,
      kind = kind,
      update_metadata = function() end,
      titleMetadata = { dirty = false },
      bodyMetadata = { dirty = dirty },
      commentsMetadata = {},
    }
    return _G.octo_buffers[bufnr]
  end

  before_each(function()
    loaded = {}
    refetched = 0
    info_messages = {}
    _G.octo_buffers = {}

    -- the two things a refresh reaches for
    run_state = {
      buf = nil,
      current_wf = { databaseId = 42, status = "in_progress" },
      refetch = function()
        refetched = refetched + 1
      end,
    }
    package.loaded["octo.workflow_runs"] = run_state
    package.loaded["octo"] = {
      load_buffer = function(opts)
        table.insert(loaded, opts.bufnr)
      end,
    }

    config = require "octo.config"
    config.values = config.get_default_values()
    utils = require "octo.utils"
    utils.info = function(msg)
      table.insert(info_messages, msg)
    end
    auto_refresh = require "octo.auto_refresh"
  end)

  after_each(function()
    for bufnr in pairs(auto_refresh.status().buffers) do
      auto_refresh.unwatch(bufnr)
    end
    package.loaded["octo.auto_refresh"] = nil
    package.loaded["octo.workflow_runs"] = nil
    package.loaded["octo.utils"] = nil
    package.loaded["octo"] = nil
    _G.octo_buffers = {}
  end)

  ---@return integer
  local function pull_buffer(dirty)
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(bufnr, "octo://owner/repo/pull/701")
    octo_buffer(bufnr, "pull", dirty or false)
    return bufnr
  end

  describe("kind_of", function()
    it("knows the buffers it can refresh", function()
      local pull = pull_buffer()
      eq("pull", auto_refresh.kind_of(pull))

      local issue = vim.api.nvim_create_buf(true, false)
      octo_buffer(issue, "issue", false)
      eq("issue", auto_refresh.kind_of(issue))

      local discussion = vim.api.nvim_create_buf(true, false)
      octo_buffer(discussion, "discussion", false)
      eq("discussion", auto_refresh.kind_of(discussion))

      local run = vim.api.nvim_create_buf(true, true)
      vim.api.nvim_buf_set_name(run, "octo-workflow-run:4242:" .. run)
      eq("run", auto_refresh.kind_of(run))

      for _, b in ipairs { pull, issue, discussion, run } do
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end)

    it("refuses buffers it has no way to refresh", function()
      local file = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(file, "/tmp/octo-auto-refresh-file.rb")
      eq(nil, auto_refresh.kind_of(file))

      local review = vim.api.nvim_create_buf(true, false)
      octo_buffer(review, "reviewthread", false)
      eq(nil, auto_refresh.kind_of(review))

      for _, b in ipairs { file, review } do
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end)
  end)

  describe("toggle", function()
    it("starts and stops watching the same buffer", function()
      local bufnr = pull_buffer()

      eq(true, auto_refresh.toggle(bufnr))
      eq(true, auto_refresh.is_watching(bufnr))
      eq(true, auto_refresh.status().running)
      assert.is_truthy(info_messages[1]:find("every 3s", 1, true))

      eq(false, auto_refresh.toggle(bufnr))
      eq(false, auto_refresh.is_watching(bufnr))
      eq(false, auto_refresh.status().running) -- the timer goes with the last watch
      assert.is_truthy(info_messages[2]:find("off", 1, true))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("will not start on a workflow run that already finished", function()
      local run = vim.api.nvim_create_buf(true, true)
      vim.api.nvim_buf_set_name(run, "octo-workflow-run:4242:" .. run)
      run_state.buf = run
      run_state.current_wf = { databaseId = 42, status = "completed" }

      eq(false, auto_refresh.toggle(run))
      eq(false, auto_refresh.is_watching(run))
      assert.is_truthy(info_messages[#info_messages]:find("finished", 1, true))

      pcall(vim.api.nvim_buf_delete, run, { force = true })
    end)

    it("says what it can refresh when the buffer is not one of them", function()
      local file = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(file, "/tmp/octo-auto-refresh-other.rb")

      eq(false, auto_refresh.toggle(file))
      eq(false, auto_refresh.is_watching(file))
      eq(1, #info_messages)

      pcall(vim.api.nvim_buf_delete, file, { force = true })
    end)
  end)

  describe("tick", function()
    it("reloads a watched pull request", function()
      local bufnr = pull_buffer()
      auto_refresh.toggle(bufnr)

      auto_refresh.tick()
      auto_refresh.tick()

      eq({ bufnr, bufnr }, loaded)
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("holds still while the buffer holds an unsent edit, and resumes after", function()
      local bufnr = pull_buffer(true) -- a comment being written
      auto_refresh.toggle(bufnr)

      auto_refresh.tick()
      eq({}, loaded)
      assert.is_truthy(info_messages[#info_messages]:find("unsent edits", 1, true))

      -- the comment goes out, the buffer is clean again
      _G.octo_buffers[bufnr].bodyMetadata.dirty = false
      auto_refresh.tick()

      eq({ bufnr }, loaded)
      assert.is_truthy(info_messages[#info_messages]:find("resumed", 1, true))
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("holds still while the reader is in insert or visual mode", function()
      local bufnr = pull_buffer()
      auto_refresh.toggle(bufnr)
      auto_refresh.editing = function()
        return true
      end

      auto_refresh.tick()

      eq({}, loaded)
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("says nothing twice while it keeps holding still", function()
      local bufnr = pull_buffer(true)
      auto_refresh.toggle(bufnr)
      local before = #info_messages

      auto_refresh.tick()
      auto_refresh.tick()
      auto_refresh.tick()

      eq(1, #info_messages - before)
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("stops once the workflow run has finished", function()
      local run = vim.api.nvim_create_buf(true, true)
      vim.api.nvim_buf_set_name(run, "octo-workflow-run:4242:" .. run)
      run_state.buf = run
      run_state.current_wf = { databaseId = 42, status = "in_progress" }
      auto_refresh.toggle(run)

      auto_refresh.tick()
      eq(1, refetched)
      eq(true, auto_refresh.is_watching(run))

      run_state.current_wf.status = "completed"
      auto_refresh.tick()

      eq(1, refetched) -- a finished run costs a synchronous round trip for nothing
      eq(false, auto_refresh.is_watching(run))
      eq(false, auto_refresh.status().running)
      assert.is_truthy(info_messages[#info_messages]:find("finished", 1, true))

      pcall(vim.api.nvim_buf_delete, run, { force = true })
    end)

    it("refetches the workflow run the view is showing", function()
      local run = vim.api.nvim_create_buf(true, true)
      vim.api.nvim_buf_set_name(run, "octo-workflow-run:4242:" .. run)
      run_state.buf = run
      run_state.current_wf = { databaseId = 42, status = "in_progress" }
      auto_refresh.toggle(run)

      auto_refresh.tick()
      eq(1, refetched)

      -- the view moved on to another run: this buffer is no longer its own
      run_state.buf = run + 1000
      auto_refresh.tick()
      eq(1, refetched)

      pcall(vim.api.nvim_buf_delete, run, { force = true })
    end)

    it("forgets a buffer that is gone and stops the timer with it", function()
      local bufnr = pull_buffer()
      auto_refresh.toggle(bufnr)
      vim.api.nvim_buf_delete(bufnr, { force = true })

      auto_refresh.tick()

      eq(false, auto_refresh.is_watching(bufnr))
      eq(false, auto_refresh.status().running)
      eq({}, loaded)
    end)

    it("keeps watching a buffer through its own refresh", function()
      local bufnr = pull_buffer()
      auto_refresh.toggle(bufnr)

      auto_refresh.tick()
      eq(true, auto_refresh.is_watching(bufnr))
      eq(true, auto_refresh.status().running)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  describe("notify = false", function()
    it("keeps quiet about holding still", function()
      config.values.auto_refresh.notify = false
      local bufnr = pull_buffer(true)
      auto_refresh.toggle(bufnr)
      local before = #info_messages

      auto_refresh.tick()

      eq(0, #info_messages - before)
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)
end)
