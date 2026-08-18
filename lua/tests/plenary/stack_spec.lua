---@diagnostic disable
local config = require "octo.config"
local fragments = require "octo.gh.fragments"
local queries = require "octo.gh.queries"

config.setup {}
fragments.setup()
queries.setup()

local eq = assert.are.same

describe("stacked PRs", function()
  describe("pull_request query gating", function()
    after_each(function()
      config.values.github_hostname = ""
      queries.setup()
    end)

    it("includes stackEntry on github.com", function()
      config.values.github_hostname = ""
      queries.setup()
      assert.is_truthy(queries.pull_request:find("stackEntry {", 1, true))
      assert.is_nil(queries.pull_request:find("{stackEntry}", 1, true))
    end)

    it("omits stackEntry on GHES", function()
      config.values.github_hostname = "github.example.com"
      queries.setup()
      assert.is_nil(queries.pull_request:find("stackEntry", 1, true))
    end)
  end)

  describe("build_stack_details", function()
    local writers = require "octo.ui.writers"
    local utils = require "octo.utils"

    local function line_text(line)
      local s = ""
      for _, chunk in ipairs(line) do
        s = s .. chunk[1]
      end
      return s
    end

    local function make_stack_entry()
      return {
        position = 2,
        stack = {
          id = "S_1",
          number = 350,
          size = 5,
          baseRefName = "main",
          entries = {
            nodes = {
              {
                position = 1,
                pullRequest = { number = 330, title = "Bottom PR", state = "MERGED", isDraft = false, url = "" },
              },
              {
                position = 3,
                pullRequest = { number = 343, title = "Top PR", state = "OPEN", isDraft = true, url = "" },
              },
              {
                position = 2,
                pullRequest = {
                  number = 333,
                  title = "Current PR",
                  state = "OPEN",
                  isDraft = false,
                  url = "",
                  reviewDecision = "APPROVED",
                  statusCheckRollup = { state = "SUCCESS" },
                },
              },
            },
          },
        },
      }
    end

    it("returns no lines when the PR is not part of a stack", function()
      eq({}, writers.build_stack_details(nil))
      eq({}, writers.build_stack_details(vim.NIL))
    end)

    it("renders a header with position, size and base branch", function()
      local lines = writers.build_stack_details(make_stack_entry())
      eq("Stack: 2/5 (into main)", line_text(lines[1]))
    end)

    it("renders one line per entry, top of the stack first", function()
      local lines = writers.build_stack_details(make_stack_entry())
      eq(4, #lines)
      assert.is_truthy(line_text(lines[2]):find("#343 Top PR", 1, true))
      assert.is_truthy(line_text(lines[3]):find("#333 Current PR", 1, true))
      assert.is_truthy(line_text(lines[4]):find("#330 Bottom PR", 1, true))
    end)

    it("marks the current PR with an arrow", function()
      local lines = writers.build_stack_details(make_stack_entry())
      assert.is_truthy(vim.startswith(line_text(lines[3]), "  ▶ "))
      assert.is_truthy(vim.startswith(line_text(lines[2]), "    "))
      assert.is_truthy(vim.startswith(line_text(lines[4]), "    "))
    end)

    it("uses the PR state icons", function()
      local lines = writers.build_stack_details(make_stack_entry())
      assert.is_truthy(line_text(lines[2]):find(utils.icons.pull_request.draft[1], 1, true))
      assert.is_truthy(line_text(lines[3]):find(utils.icons.pull_request.open[1], 1, true))
      assert.is_truthy(line_text(lines[4]):find(utils.icons.pull_request.merged[1], 1, true))
    end)

    it("handles inaccessible pull requests", function()
      local stack_entry = make_stack_entry()
      stack_entry.stack.entries.nodes[2].pullRequest = vim.NIL
      local lines = writers.build_stack_details(stack_entry)
      eq(4, #lines)
      assert.is_truthy(line_text(lines[2]):find("not accessible", 1, true))
    end)

    describe("state badges", function()
      it("shows MERGED for merged PRs", function()
        local lines = writers.build_stack_details(make_stack_entry())
        assert.is_truthy(line_text(lines[4]):find("MERGED", 1, true))
      end)

      it("shows DRAFT for draft PRs", function()
        local lines = writers.build_stack_details(make_stack_entry())
        assert.is_truthy(line_text(lines[2]):find("DRAFT", 1, true))
      end)

      it("shows READY for open PRs with approved reviews and green checks", function()
        local lines = writers.build_stack_details(make_stack_entry())
        local text = line_text(lines[3])
        assert.is_truthy(text:find("READY", 1, true))
        assert.is_nil(text:find("NOT READY", 1, true))
      end)

      it("shows READY for open PRs with no required reviews and no checks", function()
        local stack_entry = make_stack_entry()
        stack_entry.stack.entries.nodes[3].pullRequest.reviewDecision = vim.NIL
        stack_entry.stack.entries.nodes[3].pullRequest.statusCheckRollup = vim.NIL
        local lines = writers.build_stack_details(stack_entry)
        local text = line_text(lines[3])
        assert.is_truthy(text:find("READY", 1, true))
        assert.is_nil(text:find("NOT READY", 1, true))
      end)

      it("shows NOT READY when a review is still required", function()
        local stack_entry = make_stack_entry()
        stack_entry.stack.entries.nodes[3].pullRequest.reviewDecision = "REVIEW_REQUIRED"
        local lines = writers.build_stack_details(stack_entry)
        assert.is_truthy(line_text(lines[3]):find("NOT READY", 1, true))
      end)

      it("shows NOT READY when checks are failing", function()
        local stack_entry = make_stack_entry()
        stack_entry.stack.entries.nodes[3].pullRequest.statusCheckRollup = { state = "FAILURE" }
        local lines = writers.build_stack_details(stack_entry)
        assert.is_truthy(line_text(lines[3]):find("NOT READY", 1, true))
      end)

      it("colors the state icon to match the badge", function()
        local stack_entry = make_stack_entry()
        stack_entry.stack.entries.nodes[3].pullRequest.reviewDecision = "REVIEW_REQUIRED"
        local lines = writers.build_stack_details(stack_entry)
        -- line = { marker, icon, "#number ", title, bubble... }: the icon is chunk 2
        eq("OctoGrey", lines[2][2][2]) -- draft
        eq("OctoYellow", lines[3][2][2]) -- open but not ready
        eq("OctoPurple", lines[4][2][2]) -- merged

        stack_entry.stack.entries.nodes[3].pullRequest.reviewDecision = "APPROVED"
        lines = writers.build_stack_details(stack_entry)
        eq("OctoGreen", lines[3][2][2]) -- open and ready
      end)
    end)
  end)

  describe("pull_request query stack fields", function()
    it("fetches per-entry review and check state", function()
      config.values.github_hostname = ""
      queries.setup()
      local sub = queries.pull_request:match "stackEntry %b{}"
      assert.is_truthy(sub)
      assert.is_truthy(sub:find("reviewDecision", 1, true))
      assert.is_truthy(sub:find("statusCheckRollup", 1, true))
    end)
  end)
end)
