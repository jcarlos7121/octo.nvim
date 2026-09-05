---@diagnostic disable
local eq = assert.are.same
local config = require "octo.config"
local constants = require "octo.constants"
local activity = require "octo.ui.activity"
local issue_layout = require "octo.ui.issue_layout"
local layout = require "octo.ui.layout"
local writers = require "octo.ui.writers"

require("octo.ui.colors").setup()

local NOW = activity.epoch "2026-09-15T12:00:00Z"

---@param opts { minutes?: integer, hours?: integer, days?: integer }
---@return string
local function before(opts)
  local delta = (opts.minutes or 0) * 60 + (opts.hours or 0) * 3600 + (opts.days or 0) * 86400
  return os.date("!%Y-%m-%dT%H:%M:%SZ", NOW - delta)
end

---@param chunks [string, string?][]
---@return string
local function text(chunks)
  local out = {}
  for _, chunk in ipairs(chunks or {}) do
    table.insert(out, chunk[1])
  end
  return table.concat(out)
end

local LONG_LINE =
  "This line is deliberately long enough to reach past the gutter of the main column and keep its own space."

---A closed issue with a bit of everything the sidebar reads
---@return table
local function make_issue()
  return {
    __typename = "Issue",
    id = "I_1",
    number = 101,
    title = "Add a thing",
    url = "https://github.com/owner/repo/issues/101",
    state = "CLOSED",
    stateReason = "COMPLETED",
    issueType = { id = "t", name = "Feature", color = "BLUE" },
    body = table.concat({
      "## User Story",
      "As a user, I want the thing so I can do the task.",
      "",
      "## Problem",
      LONG_LINE,
      "",
      "## Acceptance criteria",
      "- [ ] First row appears",
      "- [x] Second row appears",
      "",
      "Closing words.",
    }, "\n"),
    createdAt = before { days = 60 },
    lastEditedAt = before { days = 8, hours = 2 },
    updatedAt = before { days = 1 },
    closedAt = before { hours = 6 },
    author = { login = "someone" },
    viewerDidAuthor = false,
    viewerCanUpdate = true,
    viewerSubscription = "SUBSCRIBED",
    assignees = { nodes = { { login = "another", isViewer = true } } },
    labels = { nodes = { { name = "bug", color = "d73a4a" } } },
    milestone = { title = "v1", state = "OPEN", openIssueCount = 3, closedIssueCount = 2, progressPercentage = 40 },
    parent = {
      __typename = "Issue",
      number = 90,
      title = "Add more things",
      state = "OPEN",
      repository = { nameWithOwner = "owner/repo" },
    },
    closedByPullRequestsReferences = {
      totalCount = 2,
      nodes = {
        {
          __typename = "PullRequest",
          number = 201,
          title = "Do it",
          state = "MERGED",
          isDraft = false,
          mergedAt = before { days = 7, hours = 1 },
          repository = { nameWithOwner = "owner/repo" },
        },
        {
          __typename = "PullRequest",
          number = 202,
          title = "Do it again",
          state = "MERGED",
          isDraft = false,
          mergedAt = before { days = 7, hours = 2 },
          repository = { nameWithOwner = "owner/repo" },
        },
      },
    },
    blockedBy = { nodes = {} },
    blocking = { nodes = {} },
    projectItems = {
      nodes = {
        {
          project = { title = "Board" },
          fieldValues = { nodes = { { name = "In review", field = { name = "Status" } } } },
        },
      },
    },
    reactionGroups = {},
    timelineItems = {
      nodes = {
        { __typename = "IssueTypeAddedEvent", createdAt = before { days = 60 }, issueType = { name = "Feature" } },
        { __typename = "LabeledEvent", createdAt = before { days = 59 } },
        { __typename = "ProjectV2ItemStatusChangedEvent", createdAt = before { days = 40 }, status = "In progress" },
        { __typename = "ProjectV2ItemStatusChangedEvent", createdAt = before { days = 39 }, status = "In review" },
        { __typename = "ParentIssueAddedEvent", createdAt = before { days = 3, hours = 1 } },
        {
          __typename = "ClosedEvent",
          createdAt = before { hours = 6 },
          closable = { __typename = "Issue", stateReason = "COMPLETED" },
        },
      },
    },
  }
end

describe("issue layout:", function()
  before_each(function()
    config.values = config.get_default_values()
  end)

  describe("header chips", function()
    it("puts the type first, then the state with its reason, the labels and the board status", function()
      local chips = text(issue_layout.header_chips(make_issue(), "COMPLETED"))

      local type_at = chips:find("Feature", 1, true)
      local state_at = chips:find("Completed", 1, true)
      local label_at = chips:find("bug", 1, true)
      local status_at = chips:find("In review", 1, true)
      assert.is_truthy(type_at and state_at and label_at and status_at)
      assert.is_true(type_at < state_at and state_at < label_at and label_at < status_at)
    end)

    it("leaves the type out when the repository has none", function()
      local issue = make_issue()
      issue.issueType = vim.NIL
      issue.labels = { nodes = {} }
      issue.projectItems = nil

      local chips = issue_layout.header_chips(issue, "OPEN")

      eq(nil, text(chips):find("Feature", 1, true))
      assert.is_truthy(text(chips):find("Open", 1, true))
    end)

    it("spells the state reason out in its own colour", function()
      local bubble = issue_layout.state_bubble "NOT_PLANNED"

      assert.is_truthy(text(bubble):find("Not Planned", 1, true))
      eq("OctoStateNotPlannedBubble", bubble[2][2])
    end)
  end)

  describe("when", function()
    it("is relative while recent and a short date once it is not", function()
      eq("just now", issue_layout.when(before { minutes = 0 }, NOW))
      eq("6 hours ago", issue_layout.when(before { hours = 6 }, NOW))
      eq("1 day ago", issue_layout.when(before { days = 1, hours = 1 }, NOW))
      eq("8 days ago", issue_layout.when(before { days = 8, hours = 2 }, NOW))

      local old = before { days = 60 }
      local ts = activity.epoch(old)
      eq(os.date("%b", ts) .. " " .. tostring(tonumber(os.date("%d", ts))), issue_layout.when(old, NOW))

      local other_year = "2025-02-18T12:00:00Z"
      assert.is_truthy(issue_layout.when(other_year, NOW):find(", 2025", 1, true))
    end)
  end)

  describe("pr summary", function()
    it("says how the closing pull requests stand", function()
      eq(nil, issue_layout.pr_summary {})
      eq("merged", issue_layout.pr_summary { { state = "MERGED" } })
      eq("all 3 merged", issue_layout.pr_summary { { state = "MERGED" }, { state = "MERGED" }, { state = "MERGED" } })
      eq(
        "2 merged, 1 open, 1 draft",
        issue_layout.pr_summary {
          { state = "MERGED" },
          { state = "OPEN", isDraft = true },
          { state = "OPEN" },
          { state = "MERGED" },
        }
      )
    end)
  end)

  describe("groups", function()
    it("lays the people, dates, links and activity out", function()
      local groups = issue_layout.groups(make_issue(), { now = NOW, repo = "owner/repo", width = 34 })

      eq(
        { "people", "dates", "links", "activity" },
        vim.tbl_map(function(g)
          return g.title
        end, groups)
      )

      local people = groups[1].rows
      eq("author", people[1][1])
      eq("someone", text(people[1][2]))
      eq("assignee", people[2][1])
      eq("another", text(people[2][2]))
      eq("OctoUserViewer", people[2][2][1][2])
      eq({ "watching", "all activity" }, people[3])

      local dates = groups[2].rows
      eq(
        { "opened", "edited", "closed" },
        vim.tbl_map(function(r)
          return r[1]
        end, dates)
      )
      eq("8 days ago", dates[2][2])
      eq("6 hours ago", dates[3][2])

      local links = groups[3].rows
      eq("parent", links[1][1])
      eq("#90 Add more things", text(links[1][2]))
      eq({ { kind = "issue", number = 90, repo = "owner/repo", title = "Add more things" } }, links[1].links)
      eq("prs", links[2][1])
      eq("#201 #202", text(links[2][2]))
      eq(2, #links[2].links)
      eq("", links[3][1])
      eq("all 2 merged", text(links[3][2]))
      eq("milestone", links[4][1])
      eq("v1 40%", text(links[4][2]))

      local act = groups[4]
      eq("9 · newest first", act.note)
      eq({ "6h", "closed as completed" }, act.rows[1])
      eq({ "3d", "parent issue added" }, act.rows[2])
      eq({ "7d", "2 PRs merged" }, act.rows[3])
    end)

    it("says when nobody is assigned and leaves out what is not there", function()
      local issue = make_issue()
      issue.assignees = { nodes = {} }
      issue.viewerSubscription = vim.NIL
      issue.parent = vim.NIL
      issue.closedByPullRequestsReferences = nil
      issue.milestone = vim.NIL
      issue.state = "OPEN"
      issue.stateReason = vim.NIL

      local groups = issue_layout.groups(issue, { now = NOW })

      eq({ "assignee", { { "nobody", "OctoMissingDetails" } } }, groups[1].rows[2])
      eq(2, #groups[1].rows)
      eq("updated", groups[2].rows[3][1])
      eq({}, groups[3].rows)
    end)
  end)

  describe("block rows", function()
    it("takes nothing when nothing is needed and everything when all is", function()
      eq(0, issue_layout.block_rows(0, { 5, 10 }, 20))
      eq(20, issue_layout.block_rows(20, { 5, 10 }, 20))
      eq(20, issue_layout.block_rows(25, { 5, 10 }, 20))
    end)

    it("keeps a count that already falls on a group boundary", function()
      eq(5, issue_layout.block_rows(5, { 5, 10 }, 20))
      eq(10, issue_layout.block_rows(10, { 5, 10 }, 20))
    end)

    it("moves to the nearer boundary, pulling the group up on a tie", function()
      eq(10, issue_layout.block_rows(8, { 5, 10 }, 20)) -- two up, three down
      eq(5, issue_layout.block_rows(6, { 5, 10 }, 20)) -- one down, four up
      eq(9, issue_layout.block_rows(7, { 5, 9 }, 20)) -- two either way
    end)

    it("treats the ends as boundaries when there is one group", function()
      eq(0, issue_layout.block_rows(3, {}, 10))
      eq(10, issue_layout.block_rows(8, {}, 10))
    end)
  end)

  describe("sidebar breaks", function()
    it("are the blank lines between the groups", function()
      local lines, _, breaks = layout.sidebar(issue_layout.groups(make_issue(), { now = NOW, width = 34 }))

      eq({ 5, 10, 16 }, breaks)
      for _, at in ipairs(breaks) do
        eq({}, lines[at])
      end
    end)
  end)

  describe("in a buffer", function()
    local bufnr, win, issue

    ---@return table[]
    local function sidebar_marks()
      return vim.api.nvim_buf_get_extmarks(bufnr, constants.OCTO_SIDEBAR_NS, 0, -1, { details = true })
    end

    ---0-indexed row -> the sidebar text drawn beside it
    ---@return table<integer, string>
    local function beside()
      local out = {}
      for _, mark in ipairs(sidebar_marks()) do
        if mark[4].virt_text_win_col ~= nil then
          out[mark[2]] = text(mark[4].virt_text)
        end
      end
      return out
    end

    ---Render an issue the way `render_issue` does, in a normal buffer shown
    ---in a window of a known width
    local function render()
      bufnr = vim.api.nvim_create_buf(true, false)
      win = vim.api.nvim_open_win(bufnr, true, { relative = "editor", width = 120, height = 60, row = 0, col = 0 })
      _G.octo_buffers = _G.octo_buffers or {}
      _G.octo_buffers[bufnr] = {
        bufnr = bufnr,
        repo = "owner/repo",
        kind = "issue",
        number = issue.number,
        isIssue = function()
          return true
        end,
        isPullRequest = function()
          return false
        end,
        isDiscussion = function()
          return false
        end,
        issue = function()
          return issue
        end,
      }
      writers.write_title(bufnr, issue.title, 1)
      writers.write_details(bufnr, issue)
      writers.write_state(bufnr, "COMPLETED", issue.number)
      writers.write_body(bufnr, issue)
    end

    local columns

    before_each(function()
      -- a float cannot be wider than the editor, and two columns need the room
      columns = vim.o.columns
      vim.o.columns = 160
      config.values.ui.layout = "columns"
      issue = make_issue()
      render()
    end)

    after_each(function()
      layout.clear(bufnr)
      _G.octo_buffers[bufnr] = nil
      pcall(vim.api.nvim_win_close, win, true)
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      vim.o.columns = columns
    end)

    it("draws the number before the title and the chips after it", function()
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, constants.OCTO_TITLE_VT_NS, 0, -1, { details = true })

      local by_pos = {}
      for _, mark in ipairs(marks) do
        by_pos[mark[4].virt_text_pos] = text(mark[4].virt_text)
      end
      eq("#101 ", by_pos.inline)
      assert.is_truthy(by_pos.eol_right_align:find("Completed", 1, true))
      assert.is_truthy(by_pos.eol_right_align:find("bug", 1, true))
      eq("Add a thing", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
    end)

    it("rules under the title and reserves a block for what the body cannot carry", function()
      local dims = layout.dims(bufnr)
      eq(false, dims.stacked)

      local rows, _, breaks = layout.sidebar(issue_layout.groups(issue, { repo = "owner/repo", width = dims.sidebar }))
      local usable = #issue_layout.body_lines(issue.body) - 1 -- the long line
      local needed = #rows - usable
      local block = issue_layout.block_rows(needed, breaks, #rows)
      -- this body's split would have parted a group, so the block moved to a boundary
      assert.is_true(block ~= needed)
      assert.is_truthy(vim.tbl_contains(breaks, block))

      local first_body = issue_layout.body_region(bufnr)
      eq(issue_layout.BLOCK_LINE + block + 1, first_body)
      eq("## User Story", vim.api.nvim_buf_get_lines(bufnr, first_body, first_body + 1, false)[1])

      -- the block ends on the blank between two groups, and a group heads the
      -- rows beside the body
      local placed = beside()
      eq(layout.RAIL .. " ", placed[first_body - 2])
      eq(layout.RAIL .. " " .. text(rows[block + 1]), placed[first_body])
      assert.is_truthy(vim.tbl_contains(breaks, block))

      local rule
      for _, mark in ipairs(sidebar_marks()) do
        if mark[2] == issue_layout.RULE_LINE and mark[4].virt_text_pos == "overlay" then
          rule = text(mark[4].virt_text)
        end
      end
      eq(string.rep("─", dims.width), rule)
    end)

    it("puts the sidebar beside the body and yields to a line that reaches the gutter", function()
      local dims = layout.dims(bufnr)
      local first = issue_layout.body_region(bufnr)
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local placed = beside()

      local long_row
      for row, line in ipairs(lines) do
        if line == LONG_LINE then
          long_row = row - 1
        end
      end
      assert.is_truthy(long_row)
      eq(nil, placed[long_row])
      assert.is_truthy(placed[long_row - 1])
      assert.is_truthy(placed[long_row + 1])

      -- every row sits in the sidebar column, past the rail
      for _, mark in ipairs(sidebar_marks()) do
        if mark[4].virt_text_win_col then
          eq(dims.gutter + 1, mark[4].virt_text_win_col)
          assert.is_truthy(vim.startswith(text(mark[4].virt_text), layout.RAIL))
        end
      end

      -- the rows read top to bottom without a gap for the long line, and the
      -- body lines left over after the last row carry the rail alone
      local rows = layout.sidebar(issue_layout.groups(issue, { repo = "owner/repo", width = dims.sidebar }))
      local sequence = {}
      for row = issue_layout.BLOCK_LINE, #lines - 1 do
        if placed[row] then
          table.insert(sequence, placed[row])
        end
      end
      for i, line in ipairs(sequence) do
        eq(layout.RAIL .. " " .. (rows[i] and text(rows[i]) or ""), line)
      end

      -- and whatever found no line hangs under the body, in order and in
      -- the same column
      local hanging = {}
      for _, mark in ipairs(sidebar_marks()) do
        for _, virt_line in ipairs(mark[4].virt_lines or {}) do
          table.insert(hanging, text(virt_line))
        end
      end
      eq(#rows, math.min(#sequence, #rows) + #hanging)
      for i, line in ipairs(hanging) do
        eq(string.rep(" ", dims.gutter + 1) .. layout.RAIL .. " " .. text(rows[#sequence + i]), line)
      end
    end)

    it("draws the body's structure over the text", function()
      local first = issue_layout.body_region(bufnr)
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, constants.OCTO_BODY_NS, 0, -1, { details = true })

      local title
      local panel_rows = {}
      for _, mark in ipairs(marks) do
        if mark[4].virt_lines_above then
          title = text(mark[4].virt_lines[1])
        end
        if mark[4].line_hl_group == "OctoLayoutPanel" then
          table.insert(panel_rows, mark[2])
        end
      end
      assert.is_truthy(title:find("Acceptance criteria 1/2", 1, true))
      eq({ first + 7, first + 8 }, panel_rows)
    end)

    it("stops the panel at the main column and carries the rail across it", function()
      local dims = layout.dims(bufnr)
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, constants.OCTO_BODY_NS, 0, -1, { details = true })

      local title, bottom
      for _, mark in ipairs(marks) do
        if mark[4].virt_lines_above then
          title = text(mark[4].virt_lines[1])
        elseif mark[4].virt_lines then
          bottom = text(mark[4].virt_lines[1])
        end
      end
      for _, line in ipairs { title, bottom } do
        -- the rail sits where the sidebar's rail sits, and nothing crosses it
        eq(dims.gutter + 2, vim.fn.strdisplaywidth(line))
        eq(layout.RAIL, vim.fn.strcharpart(line, dims.gutter + 1, 1))
        eq(" ", vim.fn.strcharpart(line, dims.gutter, 1))
      end
      eq("─", vim.fn.strcharpart(title, dims.main - 1, 1))
      eq(" ", vim.fn.strcharpart(title, dims.main, 1))
    end)

    it("registers the sidebar's links on the lines they landed on", function()
      local links = _G.octo_buffers[bufnr].linkByLine
      local parent_line, prs_line
      for row, chunks in pairs(beside()) do
        if chunks:find("^" .. layout.RAIL .. " parent%s") then
          parent_line = row + 1
        elseif chunks:find("^" .. layout.RAIL .. " prs%s") then
          prs_line = row + 1
        end
      end

      eq(90, links[parent_line][1].number)
      eq(
        { 201, 202 },
        vim.tbl_map(function(l)
          return l.number
        end, links[prs_line])
      )
    end)

    it("keeps the text as typed and moves the sidebar out of its way", function()
      local first = issue_layout.body_region(bufnr)
      local target = first + 1 -- "As a user, ..."
      local placed_before = beside()
      assert.is_truthy(placed_before[target])
      local row_after = placed_before[target + 1]

      local lines_before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { target + 1, 0 })
      local typed = " and then some more words so that this line reaches the gutter and keeps all of its own space"
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A" .. typed .. "<Esc>", true, false, true), "x", false)
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })

      local lines_after = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      eq(#lines_before, #lines_after)
      eq(lines_before[target + 1] .. typed, lines_after[target + 1])
      for i, line in ipairs(lines_before) do
        if i ~= target + 1 then
          eq(line, lines_after[i])
        end
      end

      local placed_after = beside()
      eq(nil, placed_after[target])
      eq(placed_before[target], placed_after[target + 1])
      eq(row_after, placed_after[target + 2])
    end)

    it("puts what no line can carry under the body", function()
      -- a body of long lines has room for nothing beside it
      issue.body = table.concat({ LONG_LINE, LONG_LINE }, "\n")
      layout.clear(bufnr)
      _G.octo_buffers[bufnr] = nil
      pcall(vim.api.nvim_win_close, win, true)
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      render()

      local first, last = issue_layout.body_region(bufnr)
      local rows = layout.sidebar(issue_layout.groups(issue, { repo = "owner/repo" }))
      -- the block above the body took them all, so nothing is left to hang below
      eq(issue_layout.BLOCK_LINE + #rows + 1, first)
      local placed = beside()
      for row = issue_layout.BLOCK_LINE, first - 2 do
        assert.is_truthy(placed[row])
      end
      for row = first, last do
        eq(nil, placed[row])
      end
      eq(0, #vim.tbl_filter(function(mark)
        return mark[4].virt_lines ~= nil
      end, sidebar_marks()))

      -- but once the block has fewer lines than the rows need, the rest hangs
      -- under the body
      vim.api.nvim_buf_set_lines(bufnr, first, last + 1, false, { LONG_LINE, LONG_LINE, "short", LONG_LINE })
      vim.api.nvim_buf_set_lines(bufnr, issue_layout.BLOCK_LINE, issue_layout.BLOCK_LINE + 3, false, {})
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })

      local hanging
      for _, mark in ipairs(sidebar_marks()) do
        if mark[4].virt_lines then
          hanging = mark[4].virt_lines
        end
      end
      assert.is_truthy(hanging)
      eq(3 - 1, #hanging) -- three lines gone, one row found the short line
    end)
  end)

  describe("in the classic layout", function()
    it("writes the details block and draws no sidebar", function()
      config.values.ui.layout = "classic"
      local issue = make_issue()
      local bufnr = vim.api.nvim_create_buf(true, false)
      local win =
        vim.api.nvim_open_win(bufnr, true, { relative = "editor", width = 120, height = 60, row = 0, col = 0 })
      _G.octo_buffers = _G.octo_buffers or {}
      _G.octo_buffers[bufnr] = {
        bufnr = bufnr,
        repo = "owner/repo",
        kind = "issue",
        number = issue.number,
        isIssue = function()
          return true
        end,
        isPullRequest = function()
          return false
        end,
        isDiscussion = function()
          return false
        end,
        issue = function()
          return issue
        end,
      }

      writers.write_title(bufnr, issue.title, 1)
      writers.write_details(bufnr, issue)
      writers.write_state(bufnr, "COMPLETED", issue.number)
      writers.write_body(bufnr, issue)

      local details = vim.api.nvim_buf_get_extmarks(bufnr, constants.OCTO_DETAILS_VT_NS, 0, -1, {})
      assert.is_true(#details > 5)
      eq({}, vim.api.nvim_buf_get_extmarks(bufnr, constants.OCTO_SIDEBAR_NS, 0, -1, {}))
      eq({}, vim.api.nvim_buf_get_extmarks(bufnr, constants.OCTO_BODY_NS, 0, -1, {}))
      local title_marks = vim.api.nvim_buf_get_extmarks(bufnr, constants.OCTO_TITLE_VT_NS, 0, -1, { details = true })
      eq(1, #title_marks)
      eq("eol", title_marks[1][4].virt_text_pos)
      eq(nil, layout.besides[bufnr])

      _G.octo_buffers[bufnr] = nil
      pcall(vim.api.nvim_win_close, win, true)
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)
end)
