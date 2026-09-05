---@diagnostic disable
---Tests for the two-column PR details: the pure builder, the header chips, and
---what `write_details` does with them in a buffer
local eq = assert.are.same
local config = require "octo.config"
local constants = require "octo.constants"
local layout = require "octo.ui.layout"
local utils = require "octo.utils"
local writers = require "octo.ui.writers"

local function line_text(line)
  local text = ""
  for _, chunk in ipairs(line) do
    text = text .. chunk[1]
  end
  return text
end

---@param lines octo.ChunkLine[]
---@param needle string
---@return string?
local function line_with(lines, needle)
  for _, line in ipairs(lines) do
    local text = line_text(line)
    if text:find(needle, 1, true) then
      return text
    end
  end
  return nil
end

local function check_run(name, workflow, conclusion, started, completed)
  return {
    __typename = "CheckRun",
    name = name,
    status = conclusion and "COMPLETED" or "IN_PROGRESS",
    conclusion = conclusion or vim.NIL,
    startedAt = started or vim.NIL,
    completedAt = completed or vim.NIL,
    detailsUrl = "https://github.com/owner/repo/actions/runs/1/job/" .. name,
    checkSuite = { workflowRun = { workflow = { name = workflow } } },
  }
end

local function stack_pr(number, title, state)
  return {
    number = number,
    title = title,
    url = "https://github.com/owner/repo/pull/" .. number,
    state = state or "OPEN",
    isDraft = false,
    isInMergeQueue = false,
    reviewDecision = "APPROVED",
    statusCheckRollup = { state = "SUCCESS" },
  }
end

local function pull_request()
  return {
    __typename = "PullRequest",
    id = "PR_1",
    url = "https://github.com/owner/repo/pull/123",
    number = 123,
    title = "Add a thing",
    body = "Adds a thing.",
    state = "OPEN",
    isDraft = false,
    author = { login = "someone" },
    authorAssociation = "MEMBER",
    viewerDidAuthor = false,
    createdAt = "2026-09-03T13:00:00Z",
    updatedAt = "2026-09-04T11:57:00Z",
    headRefName = "feat-child",
    baseRefName = "feat-parent",
    labels = { nodes = { { name = "20 min review", color = "0e8a16" } } },
    timelineItems = {
      nodes = { { __typename = "PullRequestReview", author = { login = "someone" }, state = "APPROVED" } },
    },
    reactionGroups = {},
    participants = { nodes = {} },
    assignees = { nodes = { { login = "someone", isViewer = false } } },
    reviewRequests = { totalCount = 1, nodes = { { requestedReviewer = { login = "another" } } } },
    reviewDecision = "APPROVED",
    milestone = vim.NIL,
    projectItems = { nodes = {} },
    closingIssuesReferences = {
      totalCount = 1,
      nodes = { { __typename = "Issue", number = 101, title = "Move the thing" } },
    },
    additions = 255,
    deletions = 23,
    changedFiles = 11,
    commits = { totalCount = 4 },
    merged = false,
    mergeable = "MERGEABLE",
    mergeStateStatus = "BEHIND",
    autoMergeRequest = vim.NIL,
    viewerSubscription = "SUBSCRIBED",
    statusCheckRollup = {
      state = "PENDING",
      contexts = {
        nodes = {
          check_run("docker_build", "CI"),
          check_run("ruby", "CodeQL", "SUCCESS", "2026-09-04T10:00:00Z", "2026-09-04T10:02:42Z"),
          check_run("js-ts", "CodeQL", "SUCCESS", "2026-09-04T10:00:00Z", "2026-09-04T10:01:29Z"),
          check_run("deploy", "Review App", "SKIPPED"),
        },
      },
    },
    stackEntry = {
      position = 3,
      stack = {
        id = "S_1",
        number = 1,
        size = 3,
        baseRefName = "master",
        entries = {
          nodes = {
            { position = 1, pullRequest = stack_pr(121, "Support the new column in the widget") },
            { position = 2, pullRequest = stack_pr(122, "Remove the old entry point") },
            { position = 3, pullRequest = stack_pr(123, "Add a thing to the widget page, at length") },
          },
        },
      },
    },
  }
end

-- the clock the relative times are measured against, as parse_utc_date counts
local now = utils.parse_utc_date "2026-09-04T12:00:00Z"

describe("PR columns:", function()
  describe("build_pr_columns", function()
    local dims = layout.dims(0, { width = 120 })

    it("leads the main column with the context of the PR", function()
      local left = writers.build_pr_columns(pull_request(), { dims = dims, now = now }).left
      eq("CONTEXT", line_text(left[1]))
      assert.is_truthy(line_with(left, "repo"):find "owner/repo$")
      assert.is_truthy(line_with(left, "author"):find("someone (member)", 1, true))
      assert.is_truthy(line_with(left, "opened"):find("23h ago · upd 3m", 1, true))
      assert.is_truthy(line_with(left, "assignee"):find "someone$")
      assert.is_truthy(line_with(left, "milestone"):find("—", 1, true))
      assert.is_truthy(line_with(left, "subscribed"):find("all activity", 1, true))
    end)

    it("lines the values of a group up under each other", function()
      local left = writers.build_pr_columns(pull_request(), { dims = dims, now = now }).left
      local repo = line_with(left, "repo")
      local author = line_with(left, "author")
      eq(repo:find("owner/repo", 1, true), author:find("someone", 1, true))
    end)

    it("says what the PR closes and where it goes", function()
      local left = writers.build_pr_columns(pull_request(), { dims = dims, now = now }).left
      assert.is_truthy(line_with(left, "BRANCHES"))
      assert.is_truthy(line_with(left, "from"):find("feat-child", 1, true))
      assert.is_truthy(line_with(left, "into"):find("feat-parent", 1, true))
      assert.is_truthy(line_with(left, "tracks"):find("#101 Move the thing", 1, true))
    end)

    it("ends the main column with the diff on one line", function()
      local left = writers.build_pr_columns(pull_request(), { dims = dims, now = now }).left
      eq("DIFF", line_text(left[#left - 1]))
      local diff = line_text(left[#left])
      assert.is_truthy(diff:find("11 files", 1, true))
      assert.is_truthy(diff:find("+255 -23", 1, true))
      assert.is_truthy(diff:find("■■■■□", 1, true)) -- five cells, additions heavy
      assert.is_truthy(diff:find("4 commits", 1, true))
    end)

    it("opens the sidebar with the review and what blocks the merge", function()
      local right = writers.build_pr_columns(pull_request(), { dims = dims, now = now }).right
      eq("REVIEW", line_text(right[1]))
      local review = line_text(right[2])
      assert.is_truthy(review:find("approved", 1, true))
      assert.is_truthy(review:find("someone ✓", 1, true))
      assert.is_truthy(review:find("another", 1, true))
      eq("! merge: out-of-date with base", line_text(right[3]))
    end)

    it("says who merged a merged PR instead", function()
      local pr = pull_request()
      pr.state = "MERGED"
      pr.merged = true
      pr.mergedBy = { login = "another" }
      pr.closedAt = "2026-09-04T10:00:00Z"
      local columns = writers.build_pr_columns(pr, { dims = dims, now = now })
      assert.is_truthy(line_with(columns.right, "merged by another"))
      assert.is_nil(line_with(columns.right, "merge:"))
      assert.is_truthy(line_with(columns.left, "opened"):find("merged 2h", 1, true))
    end)

    it("heads the checks with their counts and compresses them by workflow", function()
      local columns = writers.build_pr_columns(pull_request(), { dims = dims, now = now })
      local heading = line_with(columns.right, "CHECKS")
      assert.is_truthy(heading:find("2 ✓", 1, true))
      assert.is_truthy(heading:find("1 ●", 1, true))
      assert.is_truthy(heading:find("1 ⊘", 1, true))
      assert.is_truthy(line_with(columns.right, "● CI / docker_build running"))
      assert.is_truthy(line_with(columns.right, "✓ CodeQL ruby 2m42s · js-ts 1m29s"))
      assert.is_truthy(line_with(columns.right, "⊘ Review App / deploy skipped"))
    end)

    it("maps each checks row to the checks it stands for", function()
      local columns = writers.build_pr_columns(pull_request(), { dims = dims, now = now })
      local rows = 0
      for index, contexts in pairs(columns.checks) do
        rows = rows + 1
        local text = line_text(columns.right[index])
        for _, context in ipairs(contexts) do
          assert.is_truthy(text:find(context.name, 1, true), text .. " should name " .. context.name)
        end
      end
      eq(3, rows)
    end)

    it("caps the workflows and counts what the cap hides", function()
      local pr = pull_request()
      for i = 1, 6 do
        table.insert(pr.statusCheckRollup.contexts.nodes, check_run("job", "Workflow " .. i, "SUCCESS"))
      end
      local columns = writers.build_pr_columns(pr, { dims = dims, now = now, max_check_rows = 4 })
      eq(5, columns.hidden_checks)
      local more = line_with(columns.right, "+5 more")
      assert.is_truthy(more)
      -- and the row still answers for every check it hides
      for index, contexts in pairs(columns.checks) do
        if line_text(columns.right[index]) == more then
          eq(5, #contexts)
        end
      end
    end)

    it("draws the stack as a tree with the badges in view", function()
      local right = writers.build_pr_columns(pull_request(), { dims = dims, now = now }).right
      eq("STACK  3 of 3 → master", line_with(right, "STACK"))
      local current = line_with(right, "#123")
      assert.is_truthy(current:find "^▶ ")
      assert.is_truthy(current:find("READY", 1, true))
      assert.is_truthy(current:find("…", 1, true)) -- the title gave way to the badge
      assert.is_truthy(line_with(right, "#122"):find "^│ ")
      assert.is_truthy(line_with(right, "#121"):find "^└ ")
      for _, line in ipairs(right) do
        assert.is_true(layout.width(line) <= dims.sidebar, line_text(line) .. " overflows the sidebar")
      end
    end)

    it("lists the standing deployments with what they hold, and where they lead", function()
      local pr = pull_request()
      pr.deployments = {
        nodes = {
          {
            commit = {
              abbreviatedOid = "0000aaa",
              deployments = {
                totalCount = 1,
                nodes = {
                  {
                    environment = "staging",
                    state = "ACTIVE",
                    task = "deploy",
                    createdAt = "2026-09-04T09:00:00Z",
                    latestStatus = { state = "ACTIVE", environmentUrl = "https://staging.example.test", logUrl = "" },
                  },
                },
              },
            },
          },
          {
            commit = {
              abbreviatedOid = "1111bbb",
              deployments = {
                totalCount = 2,
                nodes = {
                  {
                    environment = "review",
                    state = "ERROR",
                    task = "deploy",
                    createdAt = "2026-09-04T10:00:00Z",
                    latestStatus = { state = "ERROR", environmentUrl = "", logUrl = "https://logs.example.test/1" },
                  },
                  {
                    environment = "review",
                    state = "IN_PROGRESS",
                    task = "deploy",
                    createdAt = "2026-09-04T11:00:00Z",
                    latestStatus = {
                      state = "IN_PROGRESS",
                      environmentUrl = "",
                      logUrl = "https://logs.example.test/2",
                    },
                  },
                },
              },
            },
          },
        },
      }
      local columns = writers.build_pr_columns(pr, { dims = dims, now = now })

      eq("DEPLOYMENTS  1 in progress · 1 active", line_with(columns.right, "DEPLOYMENTS"))
      local review = line_with(columns.right, "review")
      assert.is_truthy(review:find("In Progress", 1, true)) -- the redeploy under way, not the failure before it
      assert.is_truthy(review:find("1111bbb · 1h", 1, true))
      assert.is_truthy(line_with(columns.right, "staging"):find("0000aaa · 3h", 1, true))

      local followed = {}
      for index, refs in pairs(columns.links.right) do
        followed[line_text(columns.right[index]):match "^%a+"] = refs[1].url
      end
      eq({ review = "https://logs.example.test/2", staging = "https://staging.example.test" }, followed)
    end)

    it("leaves out what the PR does not have", function()
      local pr = pull_request()
      pr.stackEntry = vim.NIL
      pr.statusCheckRollup = vim.NIL
      pr.closingIssuesReferences = { totalCount = 0, nodes = {} }
      pr.assignees = { nodes = {} }
      local columns = writers.build_pr_columns(pr, { dims = dims, now = now })
      assert.is_nil(line_with(columns.right, "STACK"))
      assert.is_nil(line_with(columns.right, "CHECKS"))
      assert.is_nil(line_with(columns.left, "tracks"))
      assert.is_truthy(line_with(columns.left, "assignee"):find("—", 1, true))
    end)

    it("fits the sidebar rows to the main column when stacked", function()
      local stacked = layout.dims(0, { width = 60 })
      local columns = writers.build_pr_columns(pull_request(), { dims = stacked, now = now })
      for _, line in ipairs(columns.right) do
        assert.is_true(layout.width(line) <= stacked.main)
      end
    end)
  end)

  describe("build_header_chips", function()
    it("puts the state first and the labels after it", function()
      local chips = writers.build_header_chips(pull_request(), "OPEN")
      local text = line_text(chips)
      assert.is_truthy(text:find("Open", 1, true))
      assert.is_truthy(text:find("20 min review", 1, true))
      assert.is_true(text:find("Open", 1, true) < text:find("20 min review", 1, true))
    end)

    it("colours a label the way GitHub does", function()
      local chips = writers.build_header_chips(pull_request(), "OPEN")
      local hl
      for _, chunk in ipairs(chips) do
        if chunk[1] == "20 min review" then
          hl = chunk[2]
        end
      end
      -- a highlight made for the label's colour, not the fallback bubble
      assert.is_truthy(hl:find("0e8a16", 1, true))
      assert.are_not.same("NormalFloat", hl)
    end)
  end)

  describe("write_details", function()
    local bufnr
    local win
    local buffer

    ---@param count integer
    local function scratch()
      local b = vim.api.nvim_create_buf(false, true)
      local w = vim.api.nvim_open_win(b, true, { relative = "editor", width = 120, height = 60, row = 0, col = 0 })
      return b, w
    end

    ---@param pr table
    local function octo_buffer(pr)
      return {
        bufnr = bufnr,
        repo = "owner/repo",
        number = pr.number,
        kind = "pull",
        isPullRequest = function()
          return true
        end,
        isIssue = function()
          return false
        end,
        isDiscussion = function()
          return false
        end,
        pullRequest = function()
          return pr
        end,
      }
    end

    ---@param pr table
    local function render(pr)
      buffer = octo_buffer(pr)
      _G.octo_buffers[bufnr] = buffer
      writers.write_title(bufnr, pr.title, 1)
      writers.write_details(bufnr, pr)
      writers.write_body(bufnr, pr)
    end

    local function layout_marks()
      return vim.api.nvim_buf_get_extmarks(bufnr, constants.OCTO_LAYOUT_NS, 0, -1, { details = true })
    end

    local columns_before

    before_each(function()
      _G.octo_buffers = _G.octo_buffers or {}
      config.values = config.get_default_values()
      config.values.ui.layout = "columns"
      -- a float is clipped to the editor, and the headless editor is 80 wide
      columns_before = vim.o.columns
      vim.o.columns = 160
      bufnr, win = scratch()
    end)

    after_each(function()
      config.values = config.get_default_values()
      _G.octo_buffers[bufnr] = nil
      layout.clear(bufnr)
      pcall(vim.api.nvim_win_close, win, true)
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      vim.o.columns = columns_before
    end)

    ---The two marks on the title line: the number before the title, the chips at the right edge
    ---@return string number, string chips, string chips_pos
    local function title_marks()
      local number, chips, pos
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, constants.OCTO_TITLE_VT_NS, 0, -1, { details = true })) do
        if mark[4].virt_text_pos == "inline" then
          number = line_text(mark[4].virt_text)
        else
          chips = line_text(mark[4].virt_text)
          pos = mark[4].virt_text_pos
        end
      end
      return number, chips, pos
    end

    it("draws the columns over empty lines and leaves the text alone", function()
      render(pull_request())

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      eq("Add a thing", lines[1])
      local body_line
      for i = 2, #lines do
        if lines[i] ~= "" then
          body_line = i
          break
        end
      end
      eq("Adds a thing.", lines[body_line])
      -- the drawing stops before the body: a rule, then a blank
      local marks = layout_marks()
      assert.is_true(#marks > 10)
      local last = marks[#marks]
      eq(body_line - 3, last[2])
      assert.is_nil(line_text(last[4].virt_text):find "[^─]")
      for _, mark in ipairs(marks) do
        eq("", lines[mark[2] + 1])
      end
    end)

    it("puts the two columns on the same lines behind the rail", function()
      render(pull_request())
      local marks = layout_marks()
      local first = line_text(marks[1][4].virt_text)
      assert.is_truthy(first:find "^CONTEXT")
      assert.is_truthy(first:find(layout.RAIL .. " REVIEW", 1, true))
    end)

    it("keeps the checks answerable by line, several to a row", function()
      render(pull_request())

      local by_line = buffer.checkByLine
      local lines, multi = 0, 0
      for line, contexts in pairs(by_line) do
        lines = lines + 1
        eq("", vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1])
        if #contexts > 1 then
          multi = multi + 1
          eq("CodeQL", contexts[1].checkSuite.workflowRun.workflow.name)
        end
      end
      eq(3, lines)
      eq(1, multi)
      eq(nil, buffer.checksFold)
    end)

    it("keeps the tracked issues followable from their row", function()
      render(pull_request())

      local lines = 0
      for line, links in pairs(buffer.linkByLine) do
        lines = lines + 1
        eq({ { kind = "issue", number = 101, repo = "owner/repo", title = "Move the thing" } }, links)
        -- and the row is the one that names it
        local text = ""
        for _, mark in ipairs(layout_marks()) do
          if mark[2] == line - 1 then
            text = line_text(mark[4].virt_text)
          end
        end
        assert.is_truthy(text:find "^tracks%s+#101 Move the thing")
      end
      eq(1, lines)
    end)

    it("keeps the deployments followable from their row, beside the main column", function()
      local pr = pull_request()
      pr.deployments = {
        nodes = {
          {
            commit = {
              abbreviatedOid = "1111bbb",
              deployments = {
                totalCount = 1,
                nodes = {
                  {
                    environment = "review",
                    state = "ACTIVE",
                    task = "deploy",
                    createdAt = "2026-09-04T11:00:00Z",
                    latestStatus = { state = "ACTIVE", environmentUrl = "https://review.example.test", logUrl = "" },
                  },
                },
              },
            },
          },
        },
      }
      render(pr)

      local deployment_line
      for line, links in pairs(buffer.linkByLine) do
        for _, link in ipairs(links) do
          if link.kind == "deployment" then
            deployment_line = line
            eq("https://review.example.test", link.url)
          end
        end
      end
      assert.is_truthy(deployment_line)
      -- the row sits in the sidebar, past the rail
      local text = ""
      for _, mark in ipairs(layout_marks()) do
        if mark[2] == deployment_line - 1 then
          text = line_text(mark[4].virt_text)
        end
      end
      local rail = text:find(layout.RAIL, 1, true)
      assert.is_truthy(rail)
      assert.is_truthy(text:find("review", rail, true))
    end)

    it("moves the state and the labels to the right edge of the title", function()
      render(pull_request())
      writers.write_state(bufnr, "OPEN", 123)

      eq(2, #vim.api.nvim_buf_get_extmarks(bufnr, constants.OCTO_TITLE_VT_NS, 0, -1, {}))
      local number, chips, pos = title_marks()
      eq("#123 ", number)
      eq("eol_right_align", pos)
      assert.is_truthy(chips:find("Open", 1, true))
      assert.is_truthy(chips:find("20 min review", 1, true))
    end)

    it("redraws within the lines it reserved on update", function()
      local pr = pull_request()
      render(pr)
      local count = vim.api.nvim_buf_line_count(bufnr)
      local reserved = layout.drawings[bufnr].reserved

      table.insert(pr.labels.nodes, { name = "bug", color = "d73a4a" })
      writers.write_details(bufnr, pr, true)

      eq(count, vim.api.nvim_buf_line_count(bufnr))
      eq(reserved, layout.drawings[bufnr].reserved)
      local _, chips = title_marks()
      assert.is_truthy(chips:find("bug", 1, true))
    end)

    it("caps the checks list and lifts the cap when asked", function()
      local pr = pull_request()
      for i = 1, 6 do
        table.insert(pr.statusCheckRollup.contexts.nodes, check_run("job", "Workflow " .. i, "SUCCESS"))
      end
      render(pr)
      eq(9 - writers.CHECK_ROWS, buffer.checksHidden)
      local more = false
      for _, mark in ipairs(layout_marks()) do
        if line_text(mark[4].virt_text):find("+3 more", 1, true) then
          more = true
        end
      end
      assert.is_true(more)

      vim.b[bufnr].octo_checks_unfolded = true
      _G.octo_buffers[bufnr] = nil
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
      render(pr)
      eq(0, buffer.checksHidden)
    end)

    it("stays on the classic list unless asked for columns", function()
      config.values.ui.layout = "classic"
      render(pull_request())

      eq(0, #layout_marks())
      assert.is_true(vim.tbl_count(buffer.checkByLine) > 0)
      for _, contexts in pairs(buffer.checkByLine) do
        eq(1, #contexts)
      end
      local details = vim.api.nvim_buf_get_extmarks(bufnr, constants.OCTO_DETAILS_VT_NS, 0, -1, { details = true })
      assert.is_truthy(line_text(details[1][4].virt_text):find("Repo:", 1, true))
    end)

    it("keeps the list for previews, which draw their own status line", function()
      _G.octo_buffers[bufnr] = octo_buffer(pull_request())
      writers.write_details(bufnr, pull_request(), false, true)
      eq(0, #layout_marks())
    end)
  end)

  describe("toggle_checks in columns", function()
    local navigation
    local messages
    local rendered
    local buffer

    before_each(function()
      config.values = config.get_default_values()
      config.values.ui.layout = "columns"
      messages = {}
      rendered = 0
      navigation = require "octo.navigation"
      utils.info = function(msg)
        table.insert(messages, { "info", msg })
      end
      utils.error = function(msg)
        table.insert(messages, { "error", msg })
      end
      local bufnr = vim.api.nvim_create_buf(false, true)
      buffer = {
        bufnr = bufnr,
        checksHidden = 2,
        titleMetadata = { dirty = false },
        bodyMetadata = { dirty = false },
        commentsMetadata = { { dirty = false } },
        threadsMetadata = {},
        isPullRequest = function()
          return true
        end,
        update_metadata = function() end,
        render_issue = function()
          rendered = rendered + 1
        end,
      }
      utils.get_current_buffer = function()
        return buffer
      end
    end)

    after_each(function()
      config.values = config.get_default_values()
      package.loaded["octo.navigation"] = nil
      package.loaded["octo.utils"] = nil
      utils = require "octo.utils"
      pcall(vim.api.nvim_buf_delete, buffer.bufnr, { force = true })
    end)

    it("lifts the cap by rendering the buffer again, and puts it back", function()
      navigation.toggle_checks()
      eq(true, vim.b[buffer.bufnr].octo_checks_unfolded)
      eq(1, rendered)

      buffer.checksHidden = 0
      navigation.toggle_checks()
      eq(false, vim.b[buffer.bufnr].octo_checks_unfolded)
      eq(2, rendered)
    end)

    it("says so when every check is already listed", function()
      buffer.checksHidden = 0
      navigation.toggle_checks()
      eq(0, rendered)
      eq("info", messages[1][1])
    end)

    it("refuses while the buffer holds unsaved edits", function()
      buffer.commentsMetadata[1].dirty = true
      navigation.toggle_checks()
      eq(0, rendered)
      eq("error", messages[1][1])
      eq(nil, vim.b[buffer.bufnr].octo_checks_unfolded)
    end)
  end)
end)

describe("toggle_checks re-render:", function()
  -- a real OctoBuffer rendered for real, in a window wide enough for two columns
  local OctoBuffer = require("octo.model.octo-buffer").OctoBuffer
  local navigation = require "octo.navigation"
  local utils = require "octo.utils"
  local config = require "octo.config"
  local bufnr
  local win
  local columns_before

  local function check_run(name, workflow)
    return {
      __typename = "CheckRun",
      name = name,
      status = "COMPLETED",
      conclusion = "SUCCESS",
      startedAt = vim.NIL,
      completedAt = vim.NIL,
      checkSuite = { workflowRun = { workflow = { name = workflow } } },
    }
  end

  local function pull_request()
    local contexts = {}
    for i = 1, 9 do
      table.insert(contexts, check_run("job", "Workflow " .. i))
    end
    return {
      __typename = "PullRequest",
      id = "PR_1",
      url = "https://github.com/owner/repo/pull/123",
      number = 123,
      title = "Add a thing",
      body = "Adds a thing.",
      state = "OPEN",
      isDraft = false,
      author = { login = "someone" },
      authorAssociation = "MEMBER",
      viewerCanUpdate = true,
      createdAt = "2026-09-03T13:00:00Z",
      updatedAt = "2026-09-04T11:57:00Z",
      headRefName = "feat-child",
      baseRefName = "feat-parent",
      labels = { nodes = {} },
      timelineItems = { nodes = {} },
      reactionGroups = {},
      participants = { nodes = {} },
      assignees = { nodes = {} },
      reviewRequests = { totalCount = 0, nodes = {} },
      reviewDecision = vim.NIL,
      milestone = vim.NIL,
      projectItems = { nodes = {} },
      closingIssuesReferences = { totalCount = 0, nodes = {} },
      additions = 1,
      deletions = 1,
      changedFiles = 1,
      commits = { totalCount = 1 },
      merged = false,
      mergeable = "MERGEABLE",
      mergeStateStatus = "CLEAN",
      autoMergeRequest = vim.NIL,
      viewerSubscription = "SUBSCRIBED",
      statusCheckRollup = { state = "SUCCESS", contexts = { nodes = contexts } },
    }
  end

  ---Every mark in an octo namespace
  ---@return integer
  local function octo_marks()
    local total = 0
    for name, ns in pairs(vim.api.nvim_get_namespaces()) do
      if name:find "^octo" ~= nil then
        total = total + #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
      end
    end
    return total
  end

  before_each(function()
    _G.octo_buffers = _G.octo_buffers or {}
    config.values = config.get_default_values()
    config.values.ui.layout = "columns"
    columns_before = vim.o.columns
    vim.o.columns = 160
    bufnr = vim.api.nvim_create_buf(true, false)
    win = vim.api.nvim_open_win(bufnr, true, { relative = "editor", width = 120, height = 60, row = 0, col = 0 })
  end)

  after_each(function()
    config.values = config.get_default_values()
    require("octo.ui.layout").clear(bufnr)
    _G.octo_buffers[bufnr] = nil
    pcall(vim.api.nvim_clear_autocmds, { group = "octobuffer_autocmds", buffer = bufnr })
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    vim.o.columns = columns_before
  end)

  it("keeps the mark count stable across repeated toggles", function()
    local pr = pull_request()
    local buffer = OctoBuffer:new { bufnr = bufnr, number = pr.number, repo = "owner/repo", kind = "pull", node = pr }
    buffer:render_issue()
    assert.is_true(buffer.checksHidden > 0)
    local capped = octo_marks()

    navigation.toggle_checks()
    eq(0, buffer.checksHidden)
    local lifted = octo_marks()

    navigation.toggle_checks()
    eq(capped, octo_marks())
    navigation.toggle_checks()
    eq(lifted, octo_marks())
    navigation.toggle_checks()
    eq(capped, octo_marks())

    -- and the text is what it was: a render never rewrites what the reader edits
    eq("Add a thing", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
    eq(false, vim.bo[bufnr].modified)
    assert.is_truthy(utils.get_current_buffer())
  end)
end)
