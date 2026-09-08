---@diagnostic disable
---Tests for the compressed checks list of the columns layout: one row per
---workflow, built by `writers.build_checks_groups`
local eq = assert.are.same
local writers = require "octo.ui.writers"

local function line_text(line)
  local text = ""
  for _, chunk in ipairs(line) do
    text = text .. chunk[1]
  end
  return text
end

local function rows_text(summary)
  return vim.tbl_map(line_text, summary.rows)
end

local function check_run(name, workflow, status, conclusion, started, completed)
  return {
    __typename = "CheckRun",
    name = name,
    status = status,
    conclusion = conclusion or vim.NIL,
    startedAt = started or vim.NIL,
    completedAt = completed or vim.NIL,
    checkSuite = workflow and { workflowRun = { workflow = { name = workflow } } } or vim.NIL,
  }
end

local function status_context(name, state)
  return { __typename = "StatusContext", context = name, state = state }
end

local function make_rollup()
  return {
    state = "FAILURE",
    contexts = {
      nodes = {
        check_run("docker_build", "CI", "COMPLETED", "SUCCESS", "2026-08-24T10:00:00Z", "2026-08-24T10:03:00Z"),
        check_run("ruby", "CodeQL", "COMPLETED", "SUCCESS", "2026-08-24T10:00:00Z", "2026-08-24T10:02:42Z"),
        check_run("system_tests", "CI", "COMPLETED", "FAILURE", "2026-08-24T10:00:00Z", "2026-08-24T10:04:00Z"),
        check_run("deploy", "Review App", "COMPLETED", "SKIPPED"),
        check_run("js-ts", "CodeQL", "COMPLETED", "SUCCESS", "2026-08-24T10:00:00Z", "2026-08-24T10:01:29Z"),
        check_run("migrations", "CI", "IN_PROGRESS", nil, "2026-08-24T10:00:00Z"),
        check_run("destroy", "Review App", "COMPLETED", "SKIPPED"),
        status_context("license/cla", "SUCCESS"),
      },
    },
  }
end

describe("checks groups:", function()
  it("has nothing to say without a rollup", function()
    local summary = writers.build_checks_groups(nil)
    eq({}, summary.rows)
    eq({}, summary.counts)
    eq(0, summary.total)
    eq(0, writers.build_checks_groups(vim.NIL).total)
  end)

  it("keeps the rollup state alone when there is no per-check data", function()
    local summary = writers.build_checks_groups { state = "SUCCESS" }
    eq(1, #summary.rows)
    assert.is_truthy(line_text(summary.rows[1]):find("SUCCESS", 1, true))
    eq({}, summary.counts)
    eq(0, summary.total)
  end)

  it("lists one row per workflow, the ones needing attention first", function()
    local summary = writers.build_checks_groups(make_rollup())
    local rows = rows_text(summary)
    eq(4, #rows)
    assert.is_truthy(rows[1]:find "^✗ CI")
    assert.is_truthy(rows[2]:find "^✓ CodeQL")
    assert.is_truthy(rows[3]:find "^✓ license/cla")
    assert.is_truthy(rows[4]:find "^⊘ Review App")
    eq(8, summary.total)
  end)

  it("takes the glyph of the worst job in the workflow", function()
    local summary = writers.build_checks_groups(make_rollup())
    -- CI has a failure among a success and a running job
    eq("OctoStateDismissed", summary.rows[1][1][2])
    eq("OctoStateSkipped", summary.rows[4][1][2])
  end)

  it("names the jobs with their durations when they fit", function()
    local rows = rows_text(writers.build_checks_groups(make_rollup()))
    eq("✓ CodeQL ruby 2m42s · js-ts 1m29s", rows[2])
  end)

  it("names jobs without durations plainly", function()
    local rows = rows_text(writers.build_checks_groups(make_rollup()))
    eq("⊘ Review App deploy, destroy", rows[4])
  end)

  it("puts the failing and running jobs first within a workflow", function()
    local rows = rows_text(writers.build_checks_groups(make_rollup()))
    eq("✗ CI system_tests 4m · migrations · docker_build 3m", rows[1])
  end)

  it("digests a workflow whose jobs do not fit the width", function()
    local rows = rows_text(writers.build_checks_groups(make_rollup(), { width = 28 }))
    eq("✓ CodeQL 2 jobs, slowest ruby 2m42s", rows[2])
    -- a failure is what the reader needs to know about, not the slowest job
    eq("✗ CI 3 jobs, system_tests failed", rows[1])
  end)

  it("reads a single-job workflow like a check on its own", function()
    local rollup = {
      state = "PENDING",
      contexts = {
        nodes = {
          check_run("migrations", "CI", "IN_PROGRESS", nil, "2026-08-24T10:00:00Z"),
          check_run("build", "Docs", "COMPLETED", "SUCCESS", "2026-08-24T10:00:00Z", "2026-08-24T10:00:30Z"),
        },
      },
    }
    local rows = rows_text(writers.build_checks_groups(rollup))
    eq("● CI / migrations running", rows[1])
    eq("✓ Docs / build 30s", rows[2])
  end)

  it("groups check runs without a workflow by their own name", function()
    local rollup = {
      state = "SUCCESS",
      contexts = { nodes = { check_run("lint", nil, "COMPLETED", "SUCCESS") } },
    }
    eq({ "✓ lint" }, rows_text(writers.build_checks_groups(rollup)))
  end)

  it("counts the checks per outcome", function()
    local summary = writers.build_checks_groups(make_rollup())
    eq("1 ✗ 4 ✓ 1 ● 2 ⊘", line_text(summary.counts))
  end)

  it("maps every row to the checks it stands for, worst first", function()
    local summary = writers.build_checks_groups(make_rollup())
    eq(
      { "system_tests", "migrations", "docker_build" },
      vim.tbl_map(function(c)
        return c.name
      end, summary.contexts[1])
    )
    eq(1, #summary.contexts[3])
    eq("license/cla", summary.contexts[3][1].context)
  end)

  it("folds the workflows past the cap into a row that answers for all of them", function()
    local summary = writers.build_checks_groups(make_rollup(), { max_rows = 2 })
    local rows = rows_text(summary)
    eq(3, #rows)
    eq("+2 more", rows[3])
    eq(2, summary.hidden)
    eq(3, #summary.contexts[3]) -- license/cla, deploy, destroy
  end)

  it("does not apply a cap that would hide a single row", function()
    local summary = writers.build_checks_groups(make_rollup(), { max_rows = 3 })
    eq(4, #summary.rows)
    eq(0, summary.hidden)
  end)
end)
