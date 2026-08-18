---@diagnostic disable
local eq = assert.are.same

describe("Octo stack sync:", function()
  local stack
  local gh
  local utils
  local sync_opts
  local conflicts_loaded
  local info_messages
  local error_messages

  before_each(function()
    sync_opts = nil
    conflicts_loaded = false
    info_messages = {}
    error_messages = {}

    stack = require "octo.stack"
    gh = require "octo.gh"
    utils = require "octo.utils"

    gh.stack = {
      sync = function(opts)
        sync_opts = opts
      end,
    }

    utils.info = function(msg)
      table.insert(info_messages, msg)
    end
    utils.error = function(msg)
      table.insert(error_messages, msg)
    end

    stack.load_conflicts = function()
      conflicts_loaded = true
    end
  end)

  after_each(function()
    package.loaded["octo.stack"] = nil
    package.loaded["octo.gh"] = nil
    package.loaded["octo.utils"] = nil
  end)

  it("runs gh stack sync", function()
    stack.sync()
    assert.is_not_nil(sync_opts)
    eq(nil, sync_opts.prune)
  end)

  it("passes prune through", function()
    stack.sync "prune"
    eq(true, sync_opts.prune)
  end)

  it("reports success with a fallback message", function()
    stack.sync()
    sync_opts.opts.cb("", "", 0)
    assert.is_truthy(info_messages[#info_messages]:find("Stack synced", 1, true))
  end)

  it("passes gh's summary through on success", function()
    stack.sync()
    sync_opts.opts.cb("", "✓ Trunk master fast-forwarded\n✓ Stack synced", 0)
    assert.is_truthy(info_messages[#info_messages]:find "fast%-forwarded")
  end)

  it("suggests gh stack init when not in a stack", function()
    stack.sync()
    sync_opts.opts.cb("", "not part of a stack", 2)
    assert.is_truthy(error_messages[1]:find("gh stack init", 1, true))
  end)

  it("suggests installing the gh-stack extension when the command is unknown", function()
    stack.sync()
    sync_opts.opts.cb("", 'unknown command "stack" for "gh"', 1)
    assert.is_truthy(error_messages[1]:find("gh extension install github/gh-stack", 1, true))
  end)

  it("loads conflicts into the quickfix list on a rebase conflict", function()
    stack.sync()
    sync_opts.opts.cb("", "conflict while rebasing", 3)
    eq(true, conflicts_loaded)
    assert.is_truthy(error_messages[1]:find "gh stack rebase %-%-continue")
  end)

  it("reports other failures", function()
    stack.sync()
    sync_opts.opts.cb("", "push rejected", 1)
    assert.is_truthy(error_messages[1]:find("push rejected", 1, true))
  end)
end)
