---@diagnostic disable
local eq = assert.are.same
local activity = require "octo.ui.activity"

-- a fixed clock: mid-month and midday, so a zone's offset moves nothing
-- across a day or a month boundary
local NOW = activity.epoch "2026-09-15T12:00:00Z"

---An ISO timestamp this long before the clock
---@param opts { minutes?: integer, hours?: integer, days?: integer }
---@return string
local function before(opts)
  local delta = (opts.minutes or 0) * 60 + (opts.hours or 0) * 3600 + (opts.days or 0) * 86400
  return os.date("!%Y-%m-%dT%H:%M:%SZ", NOW - delta)
end

---@param kind string
---@param at string
---@param label? string
---@param many? string
local function event(kind, at, label, many)
  return { kind = kind, at = at, label = label or kind, many = many }
end

describe("activity:", function()
  describe("describe", function()
    it("names the events it knows", function()
      local closed = activity.describe {
        __typename = "ClosedEvent",
        createdAt = "2026-01-01T00:00:00Z",
        closable = { __typename = "Issue", stateReason = "NOT_PLANNED" },
      }
      eq(
        { kind = "closed", at = "2026-01-01T00:00:00Z", label = "closed as not planned", many = "closed ×%d" },
        closed
      )

      eq(
        "→ In review",
        activity.describe({
          __typename = "ProjectV2ItemStatusChangedEvent",
          createdAt = "2026-01-01T00:00:00Z",
          status = "In review",
        }).label
      )
      eq("board", activity.describe({ __typename = "AddedToProjectV2Event", createdAt = "2026-01-01T00:00:00Z" }).kind)
      eq(
        "typed Feature",
        activity.describe({
          __typename = "IssueTypeAddedEvent",
          createdAt = "2026-01-01T00:00:00Z",
          issueType = { name = "Feature" },
        }).label
      )
      eq(
        "referenced by #7",
        activity.describe({
          __typename = "CrossReferencedEvent",
          createdAt = "2026-01-01T00:00:00Z",
          source = { number = 7 },
        }).label
      )
    end)

    it("groups labels and assignees under one kind each, so churn collapses", function()
      eq(
        activity.describe({ __typename = "LabeledEvent", createdAt = "2026-01-01T00:00:00Z" }).kind,
        activity.describe({ __typename = "UnlabeledEvent", createdAt = "2026-01-01T00:00:00Z" }).kind
      )
      eq(
        activity.describe({ __typename = "AssignedEvent", createdAt = "2026-01-01T00:00:00Z" }).kind,
        activity.describe({ __typename = "UnassignedEvent", createdAt = "2026-01-01T00:00:00Z" }).kind
      )
    end)

    it("skips what it does not know and what has no date", function()
      eq(nil, activity.describe { __typename = "SomethingNewEvent", createdAt = "2026-01-01T00:00:00Z" })
      eq(nil, activity.describe { __typename = "LabeledEvent" })
      eq(nil, activity.describe {})
    end)
  end)

  describe("collect", function()
    it("adds the creation and the merges of the closing pull requests", function()
      local events = activity.collect {
        createdAt = "2026-01-01T00:00:00Z",
        timelineItems = { nodes = { vim.NIL, { __typename = "LabeledEvent", createdAt = "2026-01-02T00:00:00Z" } } },
        closedByPullRequestsReferences = {
          nodes = {
            { number = 5, state = "MERGED", mergedAt = "2026-01-03T00:00:00Z" },
            { number = 6, state = "OPEN", mergedAt = vim.NIL },
          },
        },
      }

      eq(
        { "created", "labels", "merged" },
        vim.tbl_map(function(e)
          return e.kind
        end, events)
      )
      eq("PR #5 merged", events[3].label)
    end)

    it("copes with an issue that has none of it", function()
      eq({}, activity.collect {})
    end)
  end)

  describe("bucket", function()
    it("keys by minutes, hours and days while recent", function()
      eq("now", activity.bucket(NOW - 10, NOW))
      eq("5m", activity.bucket(NOW - 5 * 60, NOW))
      eq("5h", activity.bucket(NOW - 5 * 3600, NOW))
      eq("3d", activity.bucket(NOW - 3 * 86400 - 3600, NOW))
      eq("29d", activity.bucket(NOW - 29 * 86400 - 3600, NOW))
    end)

    it("keys by month once it is not, with the year once that differs", function()
      local june = activity.epoch "2026-06-15T12:00:00Z"
      local last_year = activity.epoch "2025-02-15T12:00:00Z"

      eq(os.date("%b", june), activity.bucket(june, NOW))
      eq(os.date("%b %Y", last_year), activity.bucket(last_year, NOW))
    end)
  end)

  describe("compress", function()
    it("gives nothing for nothing", function()
      local rows, total = activity.compress({}, { now = NOW })

      eq({}, rows)
      eq(0, total)
    end)

    it("reads newest first, whatever order the events came in", function()
      local rows = activity.compress({
        event("created", before { days = 20 }),
        event("closed", before { hours = 2 }),
        event("labels", before { days = 3, hours = 2 }, "labeled"),
      }, { now = NOW })

      eq({ { "2h", "closed" }, { "3d", "labeled" }, { "20d", "created" } }, rows)
    end)

    it("collapses a run of one kind into a count", function()
      local rows, total = activity.compress({
        event("board", before { days = 5, hours = 1 }, "→ Todo", "board churn ×%d"),
        event("board", before { days = 5, hours = 2 }, "→ Doing", "board churn ×%d"),
        event("board", before { days = 5, hours = 3 }, "→ Done", "board churn ×%d"),
        event("merged", before { days = 1, hours = 1 }, "PR #1 merged", "%d PRs merged"),
        event("merged", before { days = 1, hours = 2 }, "PR #2 merged", "%d PRs merged"),
      }, { now = NOW })

      eq({ { "1d", "2 PRs merged" }, { "5d", "board churn ×3" } }, rows)
      eq(5, total)
    end)

    it("does not collapse across a different kind in between", function()
      local rows = activity.compress({
        event("labels", before { days = 1, hours = 1 }, "labeled", "label churn ×%d"),
        event("assignees", before { days = 1, hours = 2 }, "assigned", "assignee churn ×%d"),
        event("labels", before { days = 1, hours = 3 }, "unlabeled", "label churn ×%d"),
      }, { now = NOW })

      eq({ { "1d", "labeled, assigned, unlabeled" } }, rows)
    end)

    it("joins one bucket's entries and wraps them, continuing without a key", function()
      local rows = activity.compress({
        event("a", before { days = 40 }, "board churn ×9"),
        event("b", before { days = 41 }, "assignee churn ×5"),
        event("c", before { days = 42 }, "renamed"),
      }, { now = NOW, width = 34 })

      local month = os.date("%b", NOW - 40 * 86400)
      eq(month, rows[1][1])
      eq("", rows[2][1])
      eq("board churn ×9, assignee churn ×5, renamed", table.concat({ rows[1][2], rows[2][2] }, " "))
      for _, row in ipairs(rows) do
        assert.is_true(vim.fn.strdisplaywidth(row[2]) <= 34 - #month - 2)
      end
    end)

    it("breaks ties the way a timeline reads: the later item first", function()
      local rows = activity.compress({
        event("created", before { days = 2 }, "created"),
        event("type", before { days = 2 }, "typed Feature"),
      }, { now = NOW })

      eq({ { "2d", "typed Feature, created" } }, rows)
    end)

    it("stops at the row cap and still reports every event", function()
      local events = {}
      for i = 1, 12 do
        table.insert(events, event("k" .. i, before { days = i, hours = 1 }, "event " .. i))
      end

      local rows, total = activity.compress(events, { now = NOW, max_rows = 8 })

      eq(8, #rows)
      eq(12, total)
      eq({ "1d", "event 1" }, rows[1])
    end)
  end)
end)
