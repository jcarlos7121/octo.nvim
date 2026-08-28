---@diagnostic disable
local eq = assert.are.same

describe("goto_link:", function()
  local navigation
  local utils
  local opened ---@type { repo: string, number: integer }[]
  local info_messages
  local select_calls
  local select_choice

  before_each(function()
    opened = {}
    info_messages = {}
    select_calls = {}
    select_choice = nil
    _G.octo_buffers = _G.octo_buffers or {}

    navigation = require "octo.navigation"
    utils = require "octo.utils"
    utils.open_buffer = function(repo, number)
      table.insert(opened, { repo = repo, number = number })
    end
    utils.info = function(msg)
      table.insert(info_messages, msg)
    end
    -- nothing written in the text unless a test says so
    utils.extract_issue_at_cursor = function()
      return nil, nil
    end

    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(items, opts, on_choice)
      table.insert(select_calls, { items = items, opts = opts })
      on_choice(select_choice)
    end
  end)

  after_each(function()
    package.loaded["octo.navigation"] = nil
    package.loaded["octo.utils"] = nil
  end)

  ---@param links table<integer, table>
  local function pr_buffer(links)
    return {
      repo = "owner/repo",
      linkByLine = links,
      isPullRequest = function()
        return true
      end,
    }
  end

  it("follows a reference written in the text before anything else", function()
    utils.extract_issue_at_cursor = function()
      return "owner/repo", 456
    end
    utils.get_current_buffer = function()
      return pr_buffer { [1] = { { number = 1, repo = "owner/repo", title = "linked", kind = "issue" } } }
    end
    vim.fn.setpos(".", { 0, 1, 1, 0 })

    navigation.go_to_link()

    -- the cursor is literally on that reference, so it wins over the line
    eq({ { repo = "owner/repo", number = 456 } }, opened)
    eq(0, #select_calls)
  end)

  it("opens the only link a line carries", function()
    local line = vim.fn.line "."
    utils.get_current_buffer = function()
      return pr_buffer { [line] = { { number = 12, repo = "owner/repo", title = "Fix it", kind = "issue" } } }
    end

    navigation.go_to_link()

    eq({ { repo = "owner/repo", number = 12 } }, opened)
    eq(0, #select_calls)
  end)

  it("asks which one when a line carries several", function()
    local line = vim.fn.line "."
    local links = {
      { number = 12, repo = "owner/repo", title = "Fix it", kind = "issue" },
      { number = 34, repo = "owner/repo", title = "And this", kind = "issue" },
      { number = 56, repo = "other/repo", title = "Elsewhere", kind = "issue" },
    }
    utils.get_current_buffer = function()
      return pr_buffer { [line] = links }
    end
    select_choice = links[2]

    navigation.go_to_link()

    eq(1, #select_calls)
    eq(3, #select_calls[1].items)
    eq({ { repo = "owner/repo", number = 34 } }, opened)

    -- the entries name the repository only when it is not this buffer's own
    local format = select_calls[1].opts.format_item
    eq("#12 Fix it", format(links[1]))
    eq("other/repo#56 Elsewhere", format(links[3]))
  end)

  it("opens nothing when the choice is cancelled", function()
    local line = vim.fn.line "."
    utils.get_current_buffer = function()
      return pr_buffer {
        [line] = {
          { number = 12, repo = "owner/repo", title = "Fix it", kind = "issue" },
          { number = 34, repo = "owner/repo", title = "And this", kind = "issue" },
        },
      }
    end
    select_choice = nil

    navigation.go_to_link()

    eq(1, #select_calls)
    eq({}, opened)
  end)

  it("keeps a cross-repository link's own repository", function()
    local line = vim.fn.line "."
    utils.get_current_buffer = function()
      return pr_buffer { [line] = { { number = 7, repo = "other/repo", title = "Elsewhere", kind = "pull_request" } } }
    end

    navigation.go_to_link()

    eq({ { repo = "other/repo", number = 7 } }, opened)
  end)

  it("says so when the line has nothing to open", function()
    utils.get_current_buffer = function()
      return pr_buffer {}
    end

    navigation.go_to_link()

    eq({}, opened)
    eq(1, #info_messages)
    assert.is_truthy(info_messages[1]:find("Nothing to open", 1, true))
  end)

  it("opens a plain URL written in the text", function()
    local browsed = {}
    navigation.open_in_browser_raw = function(url)
      table.insert(browsed, url)
    end
    utils.extract_pattern_at_cursor = function(pattern)
      -- the markdown pattern is tried first and misses; the bare URL answers
      if pattern == require("octo.constants").URL_PATTERN then
        return "https://example.test/deploy/42"
      end
      return nil
    end
    utils.get_current_buffer = function()
      return pr_buffer {}
    end

    navigation.go_to_link()

    eq({ "https://example.test/deploy/42" }, browsed)
    eq({}, opened)
    eq(0, #info_messages)
  end)

  it("opens the environment of a deployment on the line", function()
    local browsed = {}
    navigation.open_in_browser_raw = function(url)
      table.insert(browsed, url)
    end
    local line = vim.fn.line "."
    utils.get_current_buffer = function()
      return pr_buffer {
        [line] = { { kind = "deployment", url = "https://review.example.test", title = "review (Active)" } },
      }
    end

    navigation.go_to_link()

    eq({ "https://review.example.test" }, browsed)
    eq({}, opened) -- a deployment is a link, not a buffer
  end)

  it("offers deployments and linked issues from the same line", function()
    local browsed = {}
    navigation.open_in_browser_raw = function(url)
      table.insert(browsed, url)
    end
    local line = vim.fn.line "."
    local links = {
      { kind = "issue", number = 12, repo = "owner/repo", title = "Fix it" },
      { kind = "deployment", url = "https://review.example.test", title = "review (Active)" },
    }
    utils.get_current_buffer = function()
      return pr_buffer { [line] = links }
    end
    select_choice = links[2]

    navigation.go_to_link()

    eq(1, #select_calls)
    local format = select_calls[1].opts.format_item
    eq("#12 Fix it", format(links[1]))
    eq("review (Active)", format(links[2])) -- a deployment names itself
    eq({ "https://review.example.test" }, browsed)
  end)

  it("does nothing outside an octo buffer", function()
    utils.get_current_buffer = function()
      return nil
    end

    navigation.go_to_link()

    eq({}, opened)
    eq(0, #info_messages)
  end)

  describe("write_details", function()
    local writers = require "octo.ui.writers"

    ---@param deployments table[]
    local function head_commit_deployments(deployments)
      return { nodes = { { commit = { deployments = { totalCount = #deployments, nodes = deployments } } } } }
    end

    local function pull_request(closing, deployments)
      return {
        url = "https://github.com/owner/repo/pull/7",
        number = 7,
        state = "OPEN",
        author = { login = "someone" },
        createdAt = "2026-08-01T10:00:00Z",
        headRefName = "feature_a",
        baseRefName = "master",
        repository = { nameWithOwner = "owner/repo" },
        labels = { nodes = {} },
        timelineItems = { nodes = {} },
        reactionGroups = {},
        assignees = { nodes = {} },
        reviewRequests = { totalCount = 0, nodes = {} },
        latestReviews = { nodes = {} },
        milestone = vim.NIL,
        projectCards = { nodes = {} },
        projectItems = { nodes = {} },
        additions = 1,
        deletions = 1,
        changedFiles = 1,
        commits = { totalCount = 1 },
        merged = false,
        mergeable = "MERGEABLE",
        mergeStateStatus = "CLEAN",
        isDraft = false,
        viewerSubscription = "SUBSCRIBED",
        closingIssuesReferences = closing,
        deployments = deployments,
      }
    end

    ---@param bufnr integer
    ---@param line integer
    ---@return string
    local function details_text(bufnr, line)
      local constants = require "octo.constants"
      local marks = vim.api.nvim_buf_get_extmarks(
        bufnr,
        constants.OCTO_DETAILS_VT_NS,
        { line - 1, 0 },
        { line - 1, -1 },
        { details = true }
      )
      local text = ""
      for _, chunk in ipairs(vim.tbl_get(marks, 1, 4, "virt_text") or {}) do
        text = text .. chunk[1]
      end
      return text
    end

    ---@return integer
    local function render(closing, deployments)
      local bufnr = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "title", "", "" })
      _G.octo_buffers[bufnr] = { bufnr = bufnr, repo = "owner/repo" }
      writers.write_details(bufnr, pull_request(closing, deployments), false, true)
      return bufnr
    end

    ---@param bufnr integer
    ---@param needle string
    ---@return integer? line, octo.LinkedReference[]? links
    local function line_with(bufnr, needle)
      for line, links in pairs(_G.octo_buffers[bufnr].linkByLine) do
        if details_text(bufnr, line):find(needle, 1, true) then
          return line, links
        end
      end
      return nil, nil
    end

    it("records the linked issues on the Development line", function()
      local bufnr = render {
        totalCount = 2,
        nodes = {
          { __typename = "Issue", number = 12, title = "Fix it", state = "OPEN" },
          {
            __typename = "Issue",
            number = 56,
            title = "Elsewhere",
            state = "CLOSED",
            repository = { nameWithOwner = "other/repo" },
          },
        },
      }

      local by_line = _G.octo_buffers[bufnr].linkByLine
      eq(1, vim.tbl_count(by_line))
      local line, links = next(by_line)
      -- the line it recorded is the one the reader sees the links on
      assert.is_truthy(details_text(bufnr, line):find("Development:", 1, true))
      eq(2, #links)
      eq({ number = 12, repo = "owner/repo", title = "Fix it", kind = "issue" }, links[1])
      eq({ number = 56, repo = "other/repo", title = "Elsewhere", kind = "issue" }, links[2])

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      _G.octo_buffers[bufnr] = nil
    end)

    it("lists the head commit's deployments and records them", function()
      local bufnr = render(
        { totalCount = 0, nodes = {} },
        head_commit_deployments {
          {
            environment = "review",
            state = "ACTIVE",
            task = "deploy",
            createdAt = "2026-08-28T21:46:43Z",
            latestStatus = {
              state = "SUCCESS",
              environmentUrl = "https://review.example.test",
              logUrl = "https://logs.example.test",
            },
          },
          {
            environment = "staging",
            state = "IN_PROGRESS",
            task = "deploy",
            createdAt = "2026-08-28T21:50:00Z",
            -- no environment yet: the log of the attempt is what there is to follow
            latestStatus = { state = "IN_PROGRESS", environmentUrl = "", logUrl = "https://logs.example.test/staging" },
          },
        }
      )

      local line, links = line_with(bufnr, "Deployments:")
      assert.is_not_nil(line)
      local text = details_text(bufnr, line)
      assert.is_truthy(text:find("review", 1, true))
      assert.is_truthy(text:find("Active", 1, true))
      assert.is_truthy(text:find("staging", 1, true))

      eq(2, #links)
      eq("deployment", links[1].kind)
      eq("https://review.example.test", links[1].url) -- the environment wins
      eq("review (Active)", links[1].title)
      eq("https://logs.example.test/staging", links[2].url) -- nowhere to visit yet
      eq("staging (In Progress)", links[2].title)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      _G.octo_buffers[bufnr] = nil
    end)

    it("writes no Deployments line when there are none", function()
      local bufnr = render({ totalCount = 0, nodes = {} }, nil)

      eq(nil, (line_with(bufnr, "Deployments:")))
      eq({}, _G.octo_buffers[bufnr].linkByLine)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      _G.octo_buffers[bufnr] = nil
    end)

    it("skips a deployment with nothing to follow", function()
      local bufnr = render(
        { totalCount = 0, nodes = {} },
        head_commit_deployments {
          { environment = "review", state = "INACTIVE", task = "deploy", createdAt = "2026-08-28T21:46:43Z" },
        }
      )

      local line, links = line_with(bufnr, "Deployments:")
      -- the line is still drawn, it simply has nothing to open
      eq(nil, line)
      eq({}, _G.octo_buffers[bufnr].linkByLine)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      _G.octo_buffers[bufnr] = nil
    end)

    it("records nothing when the pull request links to no issue", function()
      local bufnr = render { totalCount = 0, nodes = {} }

      eq({}, _G.octo_buffers[bufnr].linkByLine)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      _G.octo_buffers[bufnr] = nil
    end)

    it("starts the registry over on every render", function()
      local bufnr = render {
        totalCount = 1,
        nodes = { { __typename = "Issue", number = 12, title = "Fix it", state = "OPEN" } },
      }
      eq(1, vim.tbl_count(_G.octo_buffers[bufnr].linkByLine))

      -- the issue was unlinked in the meantime
      writers.write_details(bufnr, pull_request { totalCount = 0, nodes = {} }, false, true)
      eq({}, _G.octo_buffers[bufnr].linkByLine)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      _G.octo_buffers[bufnr] = nil
    end)
  end)
end)
