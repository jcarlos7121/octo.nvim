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

    ---@param deployments table[] against the newest commit
    ---@param older table[]? against the commit before it
    local function commit_deployments(deployments, older)
      local nodes = {}
      if older ~= nil then
        table.insert(nodes, {
          commit = { abbreviatedOid = "0000aaa", deployments = { totalCount = #older, nodes = older } },
        })
      end
      table.insert(nodes, {
        commit = { abbreviatedOid = "1111bbb", deployments = { totalCount = #deployments, nodes = deployments } },
      })
      return { nodes = nodes }
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

    ---@param environment string
    ---@param state string
    ---@param opts { url: string?, log: string?, creator: string?, at: string? }
    local function deployment(environment, state, opts)
      opts = opts or {}
      return {
        environment = environment,
        state = state,
        task = "deploy",
        createdAt = opts.at or "2026-08-28T21:46:43Z",
        creator = opts.creator and { login = opts.creator } or nil,
        latestStatus = { state = state, environmentUrl = opts.url or "", logUrl = opts.log or "" },
      }
    end

    it("counts the deployments, then gives each environment its own line", function()
      local bufnr = render(
        { totalCount = 0, nodes = {} },
        commit_deployments {
          deployment("review", "ACTIVE", { url = "https://review.example.test", creator = "someone" }),
          -- no environment yet: the log of the attempt is what there is to follow
          deployment("staging", "IN_PROGRESS", { log = "https://logs.example.test/staging" }),
        }
      )

      local summary_line, summary_links = line_with(bufnr, "Deployments:")
      assert.is_not_nil(summary_line)
      local summary = details_text(bufnr, summary_line)
      assert.is_truthy(summary:find("1 active", 1, true))
      assert.is_truthy(summary:find("1 in progress", 1, true))
      eq(2, #summary_links) -- the summary offers both

      -- a row each, in the order the deployments came
      local first = details_text(bufnr, summary_line + 1)
      assert.is_truthy(first:find("review", 1, true))
      assert.is_truthy(first:find("Active", 1, true))
      assert.is_truthy(first:find("by someone", 1, true))
      local second = details_text(bufnr, summary_line + 2)
      assert.is_truthy(second:find("staging", 1, true))
      assert.is_truthy(second:find("In Progress", 1, true))

      -- and each row opens only its own
      local by_line = _G.octo_buffers[bufnr].linkByLine
      eq(1, #by_line[summary_line + 1])
      eq("https://review.example.test", by_line[summary_line + 1][1].url) -- the environment wins
      eq("review (Active)", by_line[summary_line + 1][1].title)
      eq(1, #by_line[summary_line + 2])
      eq("https://logs.example.test/staging", by_line[summary_line + 2][1].url) -- nowhere to visit yet
      eq("staging (In Progress)", by_line[summary_line + 2][1].title)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      _G.octo_buffers[bufnr] = nil
    end)

    it("shows an environment still deploying, and what deployed it", function()
      local bufnr = render(
        { totalCount = 0, nodes = {} },
        commit_deployments {
          deployment("review", "IN_PROGRESS", { log = "https://logs.example.test/run", creator = "someone" }),
        }
      )

      local summary_line = line_with(bufnr, "Deployments:")
      assert.is_truthy(details_text(bufnr, summary_line):find("1 in progress", 1, true))
      local row = details_text(bufnr, summary_line + 1)
      assert.is_truthy(row:find("review", 1, true))
      assert.is_truthy(row:find("In Progress", 1, true))
      assert.is_truthy(row:find("1111bbb", 1, true)) -- the commit it is putting there

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      _G.octo_buffers[bufnr] = nil
    end)

    it("shows a failed or retired environment rather than hiding it", function()
      local bufnr = render(
        { totalCount = 0, nodes = {} },
        commit_deployments {
          deployment("review", "ERROR", { log = "https://logs.example.test/failed", at = "2026-08-28T22:00:00Z" }),
          deployment("staging", "INACTIVE", { at = "2026-08-28T21:00:00Z" }),
        }
      )

      local summary_line = line_with(bufnr, "Deployments:")
      local summary = details_text(bufnr, summary_line)
      assert.is_truthy(summary:find("1 error", 1, true))
      assert.is_truthy(summary:find("1 inactive", 1, true))
      -- freshest first
      assert.is_truthy(details_text(bufnr, summary_line + 1):find("review", 1, true))
      assert.is_truthy(details_text(bufnr, summary_line + 1):find("Error", 1, true))
      assert.is_truthy(details_text(bufnr, summary_line + 2):find("staging", 1, true))
      assert.is_truthy(details_text(bufnr, summary_line + 2):find("Inactive", 1, true))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      _G.octo_buffers[bufnr] = nil
    end)

    it("carries an environment over from the commit before, until the new one deploys", function()
      -- the moment after a push: the new commit has no deployment of its own yet
      local bufnr = render(
        { totalCount = 0, nodes = {} },
        commit_deployments({}, { deployment("review", "ACTIVE", { url = "https://review.example.test" }) })
      )

      local summary_line, links = line_with(bufnr, "Deployments:")
      assert.is_not_nil(summary_line) -- rather than no line at all
      assert.is_truthy(details_text(bufnr, summary_line):find("1 active", 1, true))
      assert.is_truthy(details_text(bufnr, summary_line + 1):find("0000aaa", 1, true))
      eq(1, #links)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      _G.octo_buffers[bufnr] = nil
    end)

    it("keeps one line per environment, the deployment that stands", function()
      local bufnr = render(
        { totalCount = 0, nodes = {} },
        commit_deployments {
          -- the newest comes first here: order in the answer means nothing
          deployment("review", "ACTIVE", { url = "https://review.example.test", at = "2026-08-28T22:00:00Z" }),
          deployment("review", "ERROR", { log = "https://logs.example.test/first", at = "2026-08-28T21:00:00Z" }),
        }
      )

      local summary_line, summary_links = line_with(bufnr, "Deployments:")
      local summary = details_text(bufnr, summary_line)
      -- the attempt that failed is the timeline's business, not the header's
      eq(nil, summary:find("error", 1, true))
      assert.is_truthy(summary:find("1 active", 1, true))
      eq(1, #summary_links)

      local by_line = _G.octo_buffers[bufnr].linkByLine
      eq("https://review.example.test", by_line[summary_line + 1][1].url)
      eq(nil, by_line[summary_line + 2]) -- there is no second row

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
        commit_deployments {
          { environment = "review", state = "INACTIVE", task = "deploy", createdAt = "2026-08-28T21:46:43Z" },
        }
      )

      local line = line_with(bufnr, "Deployments:")
      -- the lines are still drawn, they simply have nothing to open
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
