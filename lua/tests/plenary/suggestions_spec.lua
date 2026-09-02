---@diagnostic disable
local eq = assert.are.same

describe("review suggestions:", function()
  local suggestions
  local utils
  local gh
  local got ---@type table[] the api calls made, in order
  local info_messages
  local error_messages
  local file_lines
  local confirm_answer
  local original_confirm

  -- a hunk as GitHub sends it: a header, context, and the new lines
  local diffhunk = table.concat({
    "@@ -10,6 +10,7 @@ def render",
    " def render",
    "   setup",
    "-  old_call",
    "+  new_call",
    "+  extra_call",
    "   teardown",
  }, "\n")

  before_each(function()
    got = {}
    info_messages = {}
    error_messages = {}
    confirm_answer = 1
    file_lines = {}
    for i = 1, 20 do
      file_lines[i] = "line " .. i
    end

    suggestions = require "octo.suggestions"
    utils = require "octo.utils"
    gh = require "octo.gh"

    utils.info = function(msg)
      table.insert(info_messages, msg)
    end
    utils.error = function(msg)
      table.insert(error_messages, msg)
    end

    original_confirm = vim.fn.confirm
    vim.fn.confirm = function()
      return confirm_answer
    end

    -- GitHub: the head branch, the file, the write, and the resolve
    gh.api.graphql = function(opts)
      local cb = opts.opts and opts.opts.cb
      if opts.jq ~= nil and opts.jq:find "pullRequest" then
        table.insert(got, { kind = "head" })
        cb(
          vim.json.encode {
            headRefName = "feature_a",
            headRepository = { nameWithOwner = "owner/repo" },
            isCrossRepository = false,
            maintainerCanModify = false,
          },
          "",
          0
        )
      else
        table.insert(got, { kind = "resolve", id = opts.F and opts.F.id })
        cb("true", "", 0)
      end
    end
    gh.api.get = function(opts)
      table.insert(got, { kind = "read", repo = opts.format.repo, path = opts.format.path, ref = opts.F.ref })
      opts.opts.cb(
        vim.json.encode {
          content = vim.base64.encode(table.concat(file_lines, "\n")),
          sha = "blob-sha",
        },
        "",
        0
      )
    end
    gh.api.put = function(opts)
      table.insert(got, {
        kind = "write",
        repo = opts.format.repo,
        path = opts.format.path,
        branch = opts.F.branch,
        sha = opts.F.sha,
        message = opts.F.message,
        lines = vim.split(vim.base64.decode(opts.F.content), "\n"),
      })
      opts.opts.cb("{}", "", 0)
    end
  end)

  after_each(function()
    vim.fn.confirm = original_confirm
    package.loaded["octo.suggestions"] = nil
    package.loaded["octo.utils"] = nil
    package.loaded["octo.gh"] = nil
  end)

  ---@param opts table
  local function suggestion(opts)
    opts = opts or {}
    return {
      thread_id = "THREAD_1",
      path = "app/models/thing.rb",
      start_line = opts.start_line or 5,
      end_line = opts.end_line or 5,
      side = opts.side or "RIGHT",
      outdated = opts.outdated or false,
      lines = opts.lines or { "  new_call" },
      replaced = opts.replaced or { "line 5" },
    }
  end

  describe("parse", function()
    it("reads a suggestion out of a comment", function()
      local blocks = suggestions.parse "Please rename this.\n\n```suggestion\n  new_call\n```\n\nThanks!"
      eq({ { "  new_call" } }, blocks)
    end)

    it("reads several, in the order they appear", function()
      local blocks = suggestions.parse "```suggestion\nfirst\n```\ntext\n```suggestion\nsecond\nthird\n```"
      eq({ { "first" }, { "second", "third" } }, blocks)
    end)

    it("takes an unterminated fence as running to the end", function()
      eq({ { "one", "two" } }, suggestions.parse "```suggestion\none\ntwo")
    end)

    it("keeps an empty suggestion, which deletes the lines", function()
      eq({ {} }, suggestions.parse "drop this\n```suggestion\n```")
    end)

    it("ignores fences that are not suggestions, and comments without any", function()
      eq({}, suggestions.parse "```lua\nprint(1)\n```")
      eq({}, suggestions.parse "just a comment")
      eq({}, suggestions.parse(nil))
    end)
  end)

  describe("replaced_lines", function()
    it("reads the lines a suggestion would take away off the hunk", function()
      -- the new side: line 12 is "  new_call", 13 is "  extra_call"
      eq({ "  new_call" }, suggestions.replaced_lines(diffhunk, "RIGHT", 12, 12))
      eq({ "  new_call", "  extra_call" }, suggestions.replaced_lines(diffhunk, "RIGHT", 12, 13))
    end)

    it("reads the old side when the comment is on it", function()
      eq({ "  old_call" }, suggestions.replaced_lines(diffhunk, "LEFT", 12, 12))
    end)

    it("answers nothing when there is no hunk to read", function()
      eq({}, suggestions.replaced_lines(nil, "RIGHT", 1, 1))
      eq({}, suggestions.replaced_lines("", "RIGHT", 1, 1))
    end)
  end)

  describe("under the cursor", function()
    local buffer

    before_each(function()
      _G.octo_buffers = _G.octo_buffers or {}
      package.loaded["octo"] = { load_buffer = function() end }
      buffer = {
        bufnr = vim.api.nvim_get_current_buf(),
        repo = "owner/repo",
        number = 7,
        suggestionByLine = { [vim.fn.line "."] = { suggestion() } },
      }
      utils.get_current_buffer = function()
        return buffer
      end
    end)

    after_each(function()
      package.loaded["octo"] = nil
    end)

    it("commits the one the comment carries", function()
      suggestions.commit_at_cursor()

      eq({ "head", "read", "write", "resolve" }, {
        got[1].kind,
        got[2].kind,
        got[3].kind,
        got[4].kind,
      })
    end)

    it("does nothing when the answer is no", function()
      confirm_answer = 2

      suggestions.commit_at_cursor()

      eq({}, got)
    end)

    it("turning one down only resolves the thread", function()
      suggestions.dismiss_at_cursor()

      eq(1, #got)
      eq("resolve", got[1].kind)
      eq("THREAD_1", got[1].id)
      assert.is_truthy(info_messages[#info_messages]:find("turned down", 1, true))
    end)

    it("says so on a comment that carries none", function()
      buffer.suggestionByLine = {}

      suggestions.commit_at_cursor()

      eq({}, got)
      assert.is_truthy(info_messages[1]:find("No suggestion", 1, true))
    end)
  end)

  describe("commit", function()
    it("puts the suggestion where the comment points and resolves the thread", function()
      suggestions.commit(suggestion { lines = { "  new_call", "  extra_call" } }, "owner/repo", 7)

      local kinds = {}
      for _, call in ipairs(got) do
        table.insert(kinds, call.kind)
      end
      eq({ "head", "read", "write", "resolve" }, kinds)

      local write = got[3]
      eq("app/models/thing.rb", write.path)
      eq("feature_a", write.branch)
      eq("blob-sha", write.sha)
      assert.is_truthy(write.message:find("suggestion", 1, true))
      -- line 5 gone, the two suggested lines in its place, the rest untouched
      eq("line 4", write.lines[4])
      eq("  new_call", write.lines[5])
      eq("  extra_call", write.lines[6])
      eq("line 6", write.lines[7])
      eq(21, #write.lines)
      eq("THREAD_1", got[4].id)
    end)

    it("replaces a whole range with a single line", function()
      suggestions.commit(
        suggestion { start_line = 5, end_line = 8, replaced = { "line 5", "line 6", "line 7", "line 8" } },
        "owner/repo",
        7
      )

      local write = got[3]
      eq("line 4", write.lines[4])
      eq("  new_call", write.lines[5])
      eq("line 9", write.lines[6])
      eq(17, #write.lines)
    end)

    it("deletes the lines when the suggestion is empty", function()
      suggestions.commit(suggestion { lines = {} }, "owner/repo", 7)

      local write = got[3]
      eq("line 4", write.lines[4])
      eq("line 6", write.lines[5])
      eq(19, #write.lines)
    end)

    it("refuses one whose lines have moved on", function()
      suggestions.commit(suggestion { outdated = true }, "owner/repo", 7)

      eq({}, got)
      assert.is_truthy(error_messages[1]:find("moved", 1, true))
    end)

    it("refuses one on the old side of the diff", function()
      suggestions.commit(suggestion { side = "LEFT" }, "owner/repo", 7)

      eq({}, got)
      assert.is_truthy(error_messages[1]:find("old side", 1, true))
    end)

    it("refuses when the file no longer says what the suggestion replaces", function()
      file_lines[5] = "somebody else got here first"

      suggestions.commit(suggestion(), "owner/repo", 7)

      eq({ "head", "read" }, { got[1].kind, got[2].kind })
      eq(2, #got) -- nothing was written
      assert.is_truthy(error_messages[1]:find("has changed", 1, true))
    end)

    it("refuses when the suggestion points past the end of the file", function()
      suggestions.commit(suggestion { start_line = 90, end_line = 90, replaced = {} }, "owner/repo", 7)

      eq(2, #got)
      assert.is_truthy(error_messages[1]:find("points past", 1, true))
    end)

    it("refuses a fork that does not allow edits", function()
      gh.api.graphql = function(opts)
        opts.opts.cb(
          vim.json.encode {
            headRefName = "feature_a",
            headRepository = { nameWithOwner = "someone/repo" },
            isCrossRepository = true,
            maintainerCanModify = false,
          },
          "",
          0
        )
      end

      suggestions.commit(suggestion(), "owner/repo", 7)

      eq({}, got)
      assert.is_truthy(error_messages[1]:find("fork", 1, true))
    end)

    it("writes to the fork's own branch when edits are allowed", function()
      local answered = false
      gh.api.graphql = function(opts)
        if opts.jq ~= nil and opts.jq:find "pullRequest" and not answered then
          answered = true
          table.insert(got, { kind = "head" })
          opts.opts.cb(
            vim.json.encode {
              headRefName = "their_branch",
              headRepository = { nameWithOwner = "someone/repo" },
              isCrossRepository = true,
              maintainerCanModify = true,
            },
            "",
            0
          )
        else
          table.insert(got, { kind = "resolve", id = opts.F and opts.F.id })
          opts.opts.cb("true", "", 0)
        end
      end

      suggestions.commit(suggestion(), "owner/repo", 7)

      eq("read", got[2].kind)
      eq("someone/repo", got[2].repo) -- the file is read from the fork, not the base
      eq("their_branch", got[2].ref)
      eq("write", got[3].kind)
      eq("someone/repo", got[3].repo)
      eq("their_branch", got[3].branch)
    end)
  end)
end)
