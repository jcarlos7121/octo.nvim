---The timeline, compressed for a sidebar: what happened, newest first, a run
---of one kind of event collapsed into a count, and everything bucketed by how
---long ago. Pure functions -- the clock is a parameter -- so the compression
---can be tested without a buffer.
local config = require "octo.config"
local utils = require "octo.utils"

local M = {}

---@class octo.ActivityEvent
---@field kind string events of one kind in a row collapse into one
---@field at string ISO 8601 timestamp
---@field label string how one such event reads
---@field many? string how a run of them reads, with %d for the count

---The fields of a timeline item the summary reads. Every item has more.
---@class octo.ActivityItem
---@field __typename? string
---@field createdAt? string
---@field stateReason? string
---@field closable? { __typename?: string, stateReason?: string }
---@field source? { number?: integer }
---@field subject? { number?: integer }
---@field issueType? { name?: string }
---@field status? string

local STATE_REASON = {
  COMPLETED = "completed",
  NOT_PLANNED = "not planned",
  DUPLICATE = "duplicate",
  REOPENED = "reopened",
}

---@param value any
---@return string
local function number_ref(value)
  if type(value) == "number" then
    return string.format(" #%d", value)
  end
  return ""
end

---What one timeline item was, or nil for one the summary does not know
---@param item octo.ActivityItem
---@return octo.ActivityEvent?
function M.describe(item)
  local typename = item.__typename
  local at = item.createdAt
  if type(typename) ~= "string" or type(at) ~= "string" then
    return nil
  end

  ---@param kind string
  ---@param label string
  ---@param many? string
  ---@return octo.ActivityEvent
  local function event(kind, label, many)
    return { kind = kind, at = at, label = label, many = many }
  end

  if typename == "IssueComment" then
    return event("comment", "comment", "%d comments")
  elseif typename == "ClosedEvent" then
    local reason = item.closable and item.closable.stateReason or item.stateReason
    local how = type(reason) == "string" and STATE_REASON[reason] or nil
    return event("closed", how and ("closed as " .. how) or "closed", "closed ×%d")
  elseif typename == "ReopenedEvent" then
    return event("reopened", "reopened", "reopened ×%d")
  elseif typename == "LabeledEvent" then
    return event("labels", "labeled", "label churn ×%d")
  elseif typename == "UnlabeledEvent" then
    return event("labels", "unlabeled", "label churn ×%d")
  elseif typename == "AssignedEvent" then
    return event("assignees", "assigned", "assignee churn ×%d")
  elseif typename == "UnassignedEvent" then
    return event("assignees", "unassigned", "assignee churn ×%d")
  elseif typename == "RenamedTitleEvent" then
    return event("renamed", "renamed", "renamed ×%d")
  elseif typename == "MilestonedEvent" then
    return event("milestone", "milestoned", "milestone churn ×%d")
  elseif typename == "DemilestonedEvent" then
    return event("milestone", "demilestoned", "milestone churn ×%d")
  elseif typename == "CrossReferencedEvent" then
    return event("referenced", "referenced by" .. number_ref(item.source and item.source.number), "referenced ×%d")
  elseif typename == "ReferencedEvent" then
    return event("referenced", "referenced in a commit", "referenced ×%d")
  elseif typename == "ConnectedEvent" then
    return event("linked", "linked" .. number_ref(item.subject and item.subject.number), "linked ×%d")
  elseif typename == "ParentIssueAddedEvent" then
    return event("parent", "parent issue added", "parent churn ×%d")
  elseif typename == "ParentIssueRemovedEvent" then
    return event("parent", "parent issue removed", "parent churn ×%d")
  elseif typename == "SubIssueAddedEvent" then
    return event("sub-issues", "sub-issue added", "%d sub-issues added")
  elseif typename == "SubIssueRemovedEvent" then
    return event("sub-issues", "sub-issue removed", "%d sub-issues removed")
  elseif typename == "IssueTypeAddedEvent" then
    local name = item.issueType and item.issueType.name
    return event("type", type(name) == "string" and ("typed " .. name) or "typed", "type churn ×%d")
  elseif typename == "IssueTypeChangedEvent" then
    local name = item.issueType and item.issueType.name
    return event("type", type(name) == "string" and ("retyped " .. name) or "retyped", "type churn ×%d")
  elseif typename == "IssueTypeRemovedEvent" then
    return event("type", "type removed", "type churn ×%d")
  elseif typename == "AddedToProjectV2Event" then
    return event("board", "added to board", "board churn ×%d")
  elseif typename == "RemovedFromProjectV2Event" then
    return event("board", "removed from board", "board churn ×%d")
  elseif typename == "ProjectV2ItemStatusChangedEvent" then
    local status = item.status
    return event(
      "board",
      type(status) == "string" and status ~= "" and ("→ " .. status) or "moved on board",
      "board churn ×%d"
    )
  elseif typename == "PinnedEvent" then
    return event("pinned", "pinned", "pin churn ×%d")
  elseif typename == "UnpinnedEvent" then
    return event("pinned", "unpinned", "pin churn ×%d")
  elseif typename == "LockedEvent" then
    return event("locked", "locked", "lock churn ×%d")
  elseif typename == "UnlockedEvent" then
    return event("locked", "unlocked", "lock churn ×%d")
  elseif typename == "MarkedAsDuplicateEvent" then
    return event("duplicate", "marked duplicate", "duplicate churn ×%d")
  elseif typename == "UnmarkedAsDuplicateEvent" then
    return event("duplicate", "unmarked duplicate", "duplicate churn ×%d")
  elseif typename == "BlockedByAddedEvent" then
    return event("blocking", "blocked by an issue", "blocking churn ×%d")
  elseif typename == "BlockedByRemovedEvent" then
    return event("blocking", "unblocked", "blocking churn ×%d")
  elseif typename == "BlockingAddedEvent" then
    return event("blocking", "blocking an issue", "blocking churn ×%d")
  elseif typename == "BlockingRemovedEvent" then
    return event("blocking", "no longer blocking", "blocking churn ×%d")
  elseif typename == "CommentDeletedEvent" then
    return event("comment deleted", "comment deleted", "%d comments deleted")
  elseif typename == "TransferredEvent" then
    return event("transferred", "transferred", "transferred ×%d")
  end
  return nil
end

---Everything that happened to an issue: its creation, its timeline, and the
---merges of the pull requests that close it, which the timeline does not carry
---@param issue octo.Issue
---@return octo.ActivityEvent[]
function M.collect(issue)
  local events = {} ---@type octo.ActivityEvent[]

  if type(issue.createdAt) == "string" then
    table.insert(events, { kind = "created", at = issue.createdAt, label = "created", many = "created ×%d" })
  end

  local nodes = vim.tbl_get(issue, "timelineItems", "nodes") or {} ---@type octo.ActivityItem[]
  for _, item in ipairs(nodes) do
    if item ~= vim.NIL then
      local event = M.describe(item)
      if event ~= nil then
        table.insert(events, event)
      end
    end
  end

  local prs = vim.tbl_get(issue, "closedByPullRequestsReferences", "nodes") or {} ---@type octo.ClosingPullRequest[]
  for _, pr in ipairs(prs) do
    if pr ~= vim.NIL and type(pr.mergedAt) == "string" then
      table.insert(events, {
        kind = "merged",
        at = pr.mergedAt,
        label = string.format("PR #%d merged", pr.number),
        many = "%d PRs merged",
      })
    end
  end

  return events
end

---The instant an ISO 8601 UTC timestamp names, as epoch seconds.
---`utils.parse_utc_date` reads the fields as local time, so the result is off
---by the zone's offset; this puts it back, the way `utils.format_date` does.
---@param iso string
---@return integer
function M.epoch(iso)
  local zone_offset = os.difftime(os.time(), os.time(os.date "!*t" --[[@as osdateparam]]))
  return utils.parse_utc_date(iso) + zone_offset
end

---How long ago, as a short key: minutes, hours and days while it is recent,
---the month once it is not, with the year once that is not this one either
---@param ts integer
---@param now integer
---@return string
function M.bucket(ts, now)
  local age = math.max(now - ts, 0)
  if age < 60 then
    return "now"
  elseif age < 3600 then
    return string.format("%dm", math.floor(age / 60))
  elseif age < 86400 then
    return string.format("%dh", math.floor(age / 3600))
  elseif age < 30 * 86400 then
    return string.format("%dd", math.floor(age / 86400))
  elseif os.date("%Y", ts) == os.date("%Y", now) then
    return os.date("%b", ts) --[[@as string]]
  end
  return os.date("%b %Y", ts) --[[@as string]]
end

---Break a text into lines no wider than `width`, at spaces
---@param text string
---@param width integer
---@return string[]
local function wrap(text, width)
  local lines = {} ---@type string[]
  local current = ""
  for word in text:gmatch "%S+" do
    if current == "" then
      current = word
    elseif vim.fn.strdisplaywidth(current .. " " .. word) <= width then
      current = current .. " " .. word
    else
      table.insert(lines, current)
      current = word
    end
  end
  if current ~= "" then
    table.insert(lines, current)
  end
  return lines
end

---@class octo.ActivityOpts
---@field now? integer epoch seconds the ages are measured from; the clock by default
---@field max_rows? integer how many rows the sidebar spends on this, 8 by default
---@field width? integer width of the sidebar the rows must fit in

---@class octo.ActivityEntry
---@field kind string
---@field ts integer
---@field count integer
---@field label string

---Compress events into sidebar rows: newest first, a run of one kind collapsed
---into a count, entries of the same age bucket joined into one wrapped remark
---with the bucket as its key. Returns the rows and how many events they stand
---for, for the group title.
---@param events octo.ActivityEvent[]
---@param opts? octo.ActivityOpts
---@return octo.LayoutRow[] rows, integer total
function M.compress(events, opts)
  opts = opts or {}
  local now = opts.now or os.time()
  local max_rows = opts.max_rows or 8
  local width = opts.width or config.values.ui.sidebar_width or 34

  if #events == 0 then
    return {}, 0
  end

  -- newest first; a tie reverses the order given, since a timeline comes
  -- oldest first
  local ordered = {} ---@type { event: octo.ActivityEvent, ts: integer, index: integer }[]
  for i, event in ipairs(events) do
    table.insert(ordered, { event = event, ts = M.epoch(event.at), index = i })
  end
  table.sort(ordered, function(a, b)
    if a.ts ~= b.ts then
      return a.ts > b.ts
    end
    return a.index > b.index
  end)

  -- a run of one kind is one entry, dated by its newest event
  local entries = {} ---@type octo.ActivityEntry[]
  for _, item in ipairs(ordered) do
    local last = entries[#entries]
    if last ~= nil and last.kind == item.event.kind then
      last.count = last.count + 1
      last.label = item.event.many and string.format(item.event.many, last.count) or last.label
    else
      table.insert(entries, { kind = item.event.kind, ts = item.ts, count = 1, label = item.event.label })
    end
  end

  -- entries of one age share a key and read as one remark
  local buckets = {} ---@type { key: string, labels: string[] }[]
  for _, entry in ipairs(entries) do
    local key = M.bucket(entry.ts, now)
    local last = buckets[#buckets]
    if last ~= nil and last.key == key then
      table.insert(last.labels, entry.label)
    else
      table.insert(buckets, { key = key, labels = { entry.label } })
    end
  end

  local key_width = 0
  for _, bucket in ipairs(buckets) do
    key_width = math.max(key_width, vim.fn.strdisplaywidth(bucket.key))
  end
  local value_width = math.max(width - key_width - 2, 8)

  local rows = {} ---@type octo.LayoutRow[]
  for _, bucket in ipairs(buckets) do
    for i, line in ipairs(wrap(table.concat(bucket.labels, ", "), value_width)) do
      if #rows >= max_rows then
        return rows, #events
      end
      table.insert(rows, { i == 1 and bucket.key or "", line })
    end
  end

  return rows, #events
end

return M
