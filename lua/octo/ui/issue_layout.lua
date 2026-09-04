---The issue buffer in the two-column layout: chips in the header, the
---description's structure drawn over its text, and a sidebar of metadata
---beside it that yields to the text.
---
---Everything here is virtual text and extmarks. The title and body are the
---reader's to edit and go back to GitHub on save, so the layout reserves only
---the empty lines it needs above the body and draws beside the text below.
local activity = require "octo.ui.activity"
local body = require "octo.ui.body"
local bubbles = require "octo.ui.bubbles"
local constants = require "octo.constants"
local layout = require "octo.ui.layout"
local logins = require "octo.logins"
local utils = require "octo.utils"

local M = {}

-- 0-indexed lines of the header, laid down by `write_title`
M.TITLE_LINE = 0
M.RULE_LINE = 1 -- the blank the title leaves under itself
M.BLOCK_LINE = 2 -- where the block above the body begins

local SUBSCRIPTION = {
  SUBSCRIBED = "all activity",
  UNSUBSCRIBED = "participating",
  IGNORED = "never",
}

---What was drawn over each body, so a repaint can measure the text again
---@type table<integer, { start: integer, structure: octo.BodyStructure }>
local structures = {}

---Which lines the sidebar last claimed for its links, to give them back
---@type table<integer, integer[]>
local link_lines = {}

---@param value any
---@return boolean
local function present(value)
  return value ~= nil and value ~= vim.NIL
end

---How long ago, the way the sidebar says it: relative while recent, a short
---date once it is not
---@param iso string
---@param now integer epoch seconds
---@return string
function M.when(iso, now)
  local ts = activity.epoch(iso)
  local age = now - ts
  ---@param n integer
  ---@param unit string
  ---@return string
  local function ago(n, unit)
    return string.format("%d %s%s ago", n, unit, n == 1 and "" or "s")
  end
  if age < 60 then
    return "just now"
  elseif age < 3600 then
    return ago(math.floor(age / 60), "minute")
  elseif age < 86400 then
    return ago(math.floor(age / 3600), "hour")
  elseif age < 30 * 86400 then
    return ago(math.floor(age / 86400), "day")
  end
  local day = tostring(tonumber(os.date("%d", ts)))
  if os.date("%Y", ts) == os.date("%Y", now) then
    return os.date("%b", ts) .. " " .. day
  end
  return os.date("%b", ts) .. " " .. day .. ", " .. os.date("%Y", ts)
end

---@param state string display state of an issue
---@return octo.Chunk
local function state_icon(state)
  if state == "OPEN" then
    return utils.icons.issue.open
  elseif state == "NOT_PLANNED" or state == "DUPLICATE" then
    return utils.icons.issue.not_planned
  end
  return utils.icons.issue.closed
end

---The state as a bubble, with its reason spelled out: COMPLETED, NOT PLANNED,
---DUPLICATE rather than a bare CLOSED
---@param state string display state
---@return octo.ChunkLine
function M.state_bubble(state)
  local icon = state_icon(state)[1]:match "^(.-)%s*$"
  local text = utils.title_case(utils.remove_underscore(state))
  local hl = (utils.state_hl_map[state] or "OctoStateClosed") .. "Bubble"
  return bubbles.make_bubble(icon .. " " .. text, hl)
end

---The status of the issue on each project board it is on
---@param issue octo.Issue
---@return string[]
function M.project_statuses(issue)
  local statuses = {} ---@type string[]
  for _, item in ipairs(vim.tbl_get(issue, "projectItems", "nodes") or {}) do
    if present(item) and present(item.project) then
      for _, value in ipairs(vim.tbl_get(item, "fieldValues", "nodes") or {}) do
        if
          present(value)
          and present(value.field)
          and value.field.name == "Status"
          and not utils.is_blank(value.name)
        then
          table.insert(statuses, value.name)
        end
      end
    end
  end
  return statuses
end

---The chips at the right of the header: the issue type when the repository
---uses them, the state with its reason, the labels in their colours, and the
---status on each board
---@param issue octo.Issue
---@param state string display state
---@return octo.ChunkLine
function M.header_chips(issue, state)
  local chips = {} ---@type octo.ChunkLine

  ---@param bubble octo.ChunkLine
  local function add(bubble)
    if #chips > 0 then
      table.insert(chips, { " " })
    end
    vim.list_extend(chips, bubble)
  end

  local issue_type = issue.issueType
  if issue_type ~= nil and issue_type ~= vim.NIL and not utils.is_blank(issue_type.name) then
    add(bubbles.make_label_bubble(issue_type.name, issue_type.color))
  end

  add(M.state_bubble(state))

  for _, label in ipairs(vim.tbl_get(issue, "labels", "nodes") or {}) do
    if present(label) then
      add(bubbles.make_label_bubble(label.name, label.color))
    end
  end

  for _, status in ipairs(M.project_statuses(issue)) do
    add(bubbles.make_bubble(status, "OctoBubble"))
  end

  return chips
end

---The header: the number inline before the title, the chips right-aligned
---after it. Replaces what `write_state` draws in the classic layout.
---@param bufnr integer
---@param issue octo.Issue
---@param state string display state
---@param number integer
function M.write_header(bufnr, issue, state, number)
  local ns = constants.OCTO_TITLE_VT_NS
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if vim.api.nvim_buf_line_count(bufnr) == 0 then
    return
  end

  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, M.TITLE_LINE, 0, {
    virt_text = { { "#" .. tostring(number) .. " ", "OctoIssueId" } },
    virt_text_pos = "inline",
    right_gravity = false,
  })

  local chips = M.header_chips(issue, state)
  if #chips > 0 then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, M.TITLE_LINE, 0, {
      virt_text = chips,
      virt_text_pos = "eol_right_align",
    })
  end
end

---@param item { __typename?: string, number: integer, title?: string, repository?: { nameWithOwner: string } }
---@param fallback_repo string
---@return octo.LinkedReference
local function reference(item, fallback_repo)
  local repo = fallback_repo
  if present(item.repository) and not utils.is_blank(item.repository.nameWithOwner) then
    repo = item.repository.nameWithOwner
  end
  return {
    number = item.number,
    repo = repo,
    title = item.title or "",
    kind = item.__typename == "PullRequest" and "pull_request" or "issue",
  }
end

---`#12 #34 #56`, each number in the colour of its state
---@param items { number: integer, state?: string, stateReason?: string, isDraft?: boolean, __typename?: string }[]
---@return octo.ChunkLine
local function numbers(items)
  local out = {} ---@type octo.ChunkLine
  for i, item in ipairs(items) do
    if i > 1 then
      table.insert(out, { " " })
    end
    local state =
      utils.get_displayed_state(item.__typename ~= "PullRequest", item.state or "OPEN", item.stateReason, item.isDraft)
    table.insert(out, { "#" .. tostring(item.number), utils.state_hl_map[state] or "OctoDetailsValue" })
  end
  return out
end

---How the pull requests closing an issue stand, in a phrase: `all 3 merged`,
---`2 merged, 1 open`, nil when there are none
---@param prs octo.ClosingPullRequest[]
---@return string?
function M.pr_summary(prs)
  if #prs == 0 then
    return nil
  end
  local counts = {} ---@type table<string, integer>
  local order = { "merged", "open", "draft", "closed" }
  for _, pr in ipairs(prs) do
    local state = utils.get_displayed_state(false, pr.state, nil, pr.isDraft):lower()
    counts[state] = (counts[state] or 0) + 1
  end
  if counts.merged == #prs then
    return #prs == 1 and "merged" or string.format("all %d merged", #prs)
  end
  local parts = {} ---@type string[]
  for _, state in ipairs(order) do
    if counts[state] then
      table.insert(parts, string.format("%d %s", counts[state], state))
    end
  end
  return table.concat(parts, ", ")
end

---@param nodes any
---@return table[]
local function present_nodes(nodes)
  local out = {} ---@type table[]
  if type(nodes) == "table" then
    for _, node in ipairs(nodes) do
      if present(node) then
        table.insert(out, node)
      end
    end
  end
  return out
end

---@class octo.IssueSidebarOpts
---@field now? integer epoch seconds, for the dates; the clock by default
---@field repo? string the buffer's repository, for links without one of their own
---@field width? integer sidebar width, for wrapping the activity

---The sidebar's groups: PEOPLE, DATES, LINKS and ACTIVITY. Rows that point at
---an issue or pull request carry it as `links`, for `goto_link`.
---@param issue octo.Issue
---@param opts? octo.IssueSidebarOpts
---@return octo.LayoutGroup[]
function M.groups(issue, opts)
  opts = opts or {}
  local now = opts.now or os.time()
  local repo = opts.repo or select(2, utils.parse_url(issue.url or "")) or ""

  -- people
  local people = {} ---@type octo.LayoutRow[]
  local author = logins.format_author(issue.author)
  table.insert(people, { "author", { { author.login, issue.viewerDidAuthor and "OctoUserViewer" or "OctoUser" } } })

  local assignees = present_nodes(vim.tbl_get(issue, "assignees", "nodes"))
  if #assignees > 0 then
    local value = {} ---@type octo.ChunkLine
    for i, assignee in ipairs(assignees) do
      if i > 1 then
        table.insert(value, { ", " })
      end
      table.insert(value, { assignee.login, assignee.isViewer and "OctoUserViewer" or "OctoUser" })
    end
    table.insert(people, { #assignees == 1 and "assignee" or "assignees", value })
  else
    table.insert(people, { "assignee", { { "nobody", "OctoMissingDetails" } } })
  end

  local watching = SUBSCRIPTION[issue.viewerSubscription]
  if watching ~= nil then
    table.insert(people, { "watching", watching })
  end

  -- dates
  local dates = {} ---@type octo.LayoutRow[]
  if type(issue.createdAt) == "string" then
    table.insert(dates, { "opened", M.when(issue.createdAt, now) })
  end
  if type(issue.lastEditedAt) == "string" and issue.lastEditedAt ~= issue.createdAt then
    table.insert(dates, { "edited", M.when(issue.lastEditedAt, now) })
  end
  if issue.state == "CLOSED" and type(issue.closedAt) == "string" then
    table.insert(dates, { "closed", M.when(issue.closedAt, now) })
  elseif type(issue.updatedAt) == "string" and issue.updatedAt ~= issue.createdAt then
    table.insert(dates, { "updated", M.when(issue.updatedAt, now) })
  end

  -- links
  local links = {} ---@type octo.LayoutRow[]
  local parent = issue.parent
  if present(parent) and type(parent.number) == "number" then
    table.insert(links, {
      "parent",
      { { "#" .. tostring(parent.number) .. " ", "OctoDetailsValue" }, { parent.title or "" } },
      links = { reference(parent, repo) },
    })
  end

  local prs = present_nodes(vim.tbl_get(issue, "closedByPullRequestsReferences", "nodes")) --[[@as octo.ClosingPullRequest[] ]]
  if #prs > 0 then
    local refs = {} ---@type octo.LinkedReference[]
    for _, pr in ipairs(prs) do
      table.insert(refs, reference(pr, repo))
    end
    table.insert(links, { "prs", numbers(prs), links = refs })
    table.insert(links, { "", { { M.pr_summary(prs) or "", "OctoLayoutKey" } } })
  end

  for _, field in ipairs { { "blockedBy", "blocked by" }, { "blocking", "blocking" } } do
    local nodes = present_nodes(vim.tbl_get(issue, field[1], "nodes"))
    if #nodes > 0 then
      local refs = {} ---@type octo.LinkedReference[]
      for _, node in ipairs(nodes) do
        table.insert(refs, reference(node, repo))
      end
      table.insert(links, { field[2], numbers(nodes), links = refs })
    end
  end

  local milestone = issue.milestone
  if present(milestone) and not utils.is_blank(milestone.title) then
    local value = { { milestone.title, "OctoDetailsValue" } } ---@type octo.ChunkLine
    local progress = utils.get_milestone_progress(milestone)
    if progress then
      table.insert(value, { string.format(" %d%%", progress.percentage), "OctoLayoutKey" })
    end
    table.insert(links, { "milestone", value })
  end

  -- activity
  local rows, total = activity.compress(activity.collect(issue), { now = now, width = opts.width })

  return {
    { title = "people", rows = people },
    { title = "dates", rows = dates },
    { title = "links", rows = links },
    { title = "activity", note = tostring(total) .. " · newest first", rows = rows },
  }
end

---The body's lines, split the way `write_body_agnostic` writes them
---@param text string
---@return string[]
function M.body_lines(text)
  text = utils.trim(text or "")
  if vim.startswith(text, constants.NO_BODY_MSG) or utils.is_blank(text) then
    text = " "
  end
  return vim.split((text:gsub("\r\n", "\n")), "\n", { plain = true })
end

---Where the body is now, read off its mark: it moves as the reader types
---@param bufnr integer
---@return integer? first, integer? last 0-indexed
function M.body_region(bufnr)
  local buffer = octo_buffers[bufnr]
  local id = buffer and buffer.bodyMetadata and buffer.bodyMetadata.extmark
  if id == nil then
    return nil
  end
  local ok, mark = pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, constants.OCTO_COMMENT_NS, id, { details = true })
  if not ok or mark == nil or #mark == 0 then
    return nil
  end
  local first, last = utils.get_extmark_region(bufnr, mark)
  if type(first) ~= "number" or type(last) ~= "number" then
    return nil
  end
  return first, last
end

---Draw the body's structure over its current text, to the same measure the
---sidebar is about to be painted with: the panels stop at the main column
---and carry the rail, so the sidebar's column stays clear
---@param bufnr integer
---@param dims octo.LayoutDims
local function render_structure(bufnr, dims)
  local first, last = M.body_region(bufnr)
  if first == nil or last == nil then
    structures[bufnr] = nil
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, first, last + 1, false)
  local opts = { width = dims.stacked and dims.width or dims.main } ---@type octo.BodyRenderOpts
  if not dims.stacked then
    opts.rail = dims.gutter + 1
  end
  structures[bufnr] = { start = first, structure = body.render(bufnr, first, lines, opts) }
end

---Display width of a body line, counting what the structure draws inline
---@param bufnr integer
---@param line integer 0-indexed
---@param text string
---@return integer
local function line_width(bufnr, line, text)
  local width = vim.fn.strdisplaywidth(text)
  local drawn = structures[bufnr]
  if drawn ~= nil then
    width = width + body.inset(drawn.structure, line - drawn.start + 1)
  end
  return width
end

---Hand the sidebar's links to the buffer's registry at the lines they landed
---on, taking back the lines they had before
---@param bufnr integer
---@param links_by_row table<integer, octo.LinkedReference[]>
---@param placed table<integer, integer> row index -> 1-indexed line
local function record_links(bufnr, links_by_row, placed)
  local buffer = octo_buffers[bufnr]
  if buffer == nil then
    return
  end
  buffer.linkByLine = buffer.linkByLine or {}
  for _, line in ipairs(link_lines[bufnr] or {}) do
    buffer.linkByLine[line] = nil
  end
  local mine = {} ---@type integer[]
  for row, line in pairs(placed) do
    local links = links_by_row[row]
    if links ~= nil then
      buffer.linkByLine[line] = links
      table.insert(mine, line)
    end
  end
  link_lines[bufnr] = mine
end

---How many sidebar rows go in the block above the body when the body has no
---room beside it for `needed` of them: the nearest group boundary, so that no
---group is split across the block and the body -- a heading orphaned from its
---rows reads wrong. The blank row between groups goes above, so the next
---group heads the rows beside the body. Pulling a group up costs empty lines
---above the body; pushing it down leaves rows hanging under the body; the
---cheaper wins and a tie pulls up, since then nothing hangs.
---@param needed integer rows the body has no room beside
---@param breaks integer[] indexes of the blank rows between groups
---@param total integer how many rows there are
---@return integer
function M.block_rows(needed, breaks, total)
  if needed <= 0 then
    return 0
  end
  if needed >= total then
    return total
  end
  local lo, hi = 0, total
  for _, at in ipairs(breaks) do
    if at <= needed and at > lo then
      lo = at
    end
    if at >= needed and at < hi then
      hi = at
    end
  end
  if lo == needed or hi == needed then
    return needed
  end
  if hi - needed <= needed - lo then
    return hi
  end
  return lo
end

---The details of an issue in the columns layout: the header chips and the
---sidebar. Fresh, it reserves the block above the body -- a line for every
---sidebar row the body has no room beside, rounded to a group boundary, and
---the blank the body's mark wants before it -- and the rest of the sidebar
---goes beside the body once `write_body` has laid it down. On an update, only
---the drawing changes.
---@param bufnr integer
---@param issue octo.Issue
---@param update? boolean
function M.write_details(bufnr, issue, update)
  local writers = require "octo.ui.writers"
  local buffer = octo_buffers[bufnr]
  local dims = layout.dims(bufnr)

  local groups = M.groups(issue, {
    repo = buffer and buffer.repo or nil,
    width = dims.sidebar > 0 and dims.sidebar or nil,
  })
  local rows, sources, breaks = layout.sidebar(groups)
  local links_by_row = {} ---@type table<integer, octo.LinkedReference[]>
  for i, row in pairs(sources) do
    if row.links ~= nil then
      links_by_row[i] = row.links
    end
  end

  if not update then
    local usable = 0
    for _, line in ipairs(M.body_lines(issue.body)) do
      if vim.fn.strdisplaywidth(line) < dims.gutter then
        usable = usable + 1
      end
    end
    local overflow = dims.stacked and 0 or M.block_rows(#rows - usable, breaks, #rows)
    local empty = {} ---@type string[]
    for _ = 1, overflow + 1 do
      table.insert(empty, "")
    end
    writers.write_block(bufnr, empty, M.BLOCK_LINE + 1)
  end

  layout.beside(bufnr, {
    rows = rows,
    block = M.BLOCK_LINE,
    rule = M.RULE_LINE,
    region = function()
      return M.body_region(bufnr)
    end,
    prepare = function(dims_)
      render_structure(bufnr, dims_)
    end,
    width = function(line, text)
      return line_width(bufnr, line, text)
    end,
    on_paint = function(placed)
      record_links(bufnr, links_by_row, placed)
    end,
  })

  M.write_header(bufnr, issue, utils.get_displayed_state(true, issue.state, issue.stateReason), issue.number)
end

---Lay the sidebar and the body's structure out over a body just written
---@param bufnr integer
function M.decorate_body(bufnr)
  if layout.besides[bufnr] ~= nil then
    layout.repaint(bufnr)
  end
end

return M
