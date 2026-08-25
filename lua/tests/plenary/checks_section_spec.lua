---@diagnostic disable
local eq = assert.are.same
local writers = require "octo.ui.writers"

local function line_text(line)
  local text = ""
  for _, chunk in ipairs(line) do
    text = text .. chunk[1]
  end
  return text
end

local function all_text(lines)
  local parts = {}
  for _, line in ipairs(lines) do
    table.insert(parts, line_text(line))
  end
  return table.concat(parts, "\n")
end

local function check_run(name, workflow, status, conclusion, started, completed)
  return {
    __typename = "CheckRun",
    name = name,
    status = status,
    conclusion = conclusion or vim.NIL,
    startedAt = started or vim.NIL,
    completedAt = completed or vim.NIL,
    checkSuite = { workflowRun = { workflow = { name = workflow } } },
  }
end

local function make_rollup()
  return {
    state = "FAILURE",
    contexts = {
      nodes = {
        check_run("docker_build", "CI", "COMPLETED", "SUCCESS", "2026-08-24T10:00:00Z", "2026-08-24T10:03:00Z"),
        check_run("system_tests", "CI", "COMPLETED", "FAILURE", "2026-08-24T10:00:00Z", "2026-08-24T10:04:00Z"),
        check_run("deploy", "Review App", "COMPLETED", "SKIPPED"),
        check_run("migrations", "CI", "IN_PROGRESS", nil, "2026-08-24T10:00:00Z"),
        {
          __typename = "StatusContext",
          context = "license/cla",
          state = "SUCCESS",
          description = "All committers signed",
        },
      },
    },
  }
end

describe("checks section:", function()
  it("renders nothing without a rollup", function()
    eq({}, writers.build_checks_details(nil))
    eq({}, writers.build_checks_details(vim.NIL))
  end)

  it("keeps a single summary line when contexts are unavailable", function()
    local lines = writers.build_checks_details { state = "SUCCESS" }
    eq(1, #lines)
    assert.is_truthy(line_text(lines[1]):find("Checks:", 1, true))
    assert.is_truthy(line_text(lines[1]):find("SUCCESS", 1, true))
  end)

  it("summarizes the checks by outcome", function()
    local lines = writers.build_checks_details(make_rollup())
    local summary = line_text(lines[1])
    assert.is_truthy(summary:find("Checks:", 1, true))
    assert.is_truthy(summary:find("1 failed", 1, true))
    assert.is_truthy(summary:find("1 running", 1, true))
    assert.is_truthy(summary:find("1 skipped", 1, true))
    assert.is_truthy(summary:find("2 passed", 1, true))
  end)

  it("lists one row per check, failures first then running", function()
    local lines = writers.build_checks_details(make_rollup())
    eq(6, #lines) -- summary + 5 contexts
    assert.is_truthy(line_text(lines[2]):find("system_tests", 1, true))
    assert.is_truthy(line_text(lines[3]):find("migrations", 1, true))
  end)

  it("qualifies check runs with their workflow name", function()
    local lines = writers.build_checks_details(make_rollup())
    assert.is_truthy(line_text(lines[2]):find("CI / system_tests", 1, true))
  end)

  it("shows the duration of finished checks only", function()
    local text = all_text(writers.build_checks_details(make_rollup()))
    assert.is_truthy(text:find("4m", 1, true)) -- system_tests took 4 minutes
    assert.is_truthy(text:find("3m", 1, true)) -- docker_build took 3 minutes
    local running_row
    for _, line in ipairs(writers.build_checks_details(make_rollup())) do
      if line_text(line):find("migrations", 1, true) then
        running_row = line_text(line)
      end
    end
    assert.is_nil(running_row:find "%d+[ms]") -- no duration while running
  end)

  it("renders status contexts by their context name", function()
    local text = all_text(writers.build_checks_details(make_rollup()))
    assert.is_truthy(text:find("license/cla", 1, true))
  end)

  it("handles a rollup whose contexts are all successful", function()
    local rollup = {
      state = "SUCCESS",
      contexts = {
        nodes = { check_run("build", "CI", "COMPLETED", "SUCCESS", "2026-08-24T10:00:00Z", "2026-08-24T10:00:30Z") },
      },
    }
    local lines = writers.build_checks_details(rollup)
    eq(2, #lines)
    assert.is_truthy(line_text(lines[1]):find("1 passed", 1, true))
    assert.is_nil(line_text(lines[1]):find("failed", 1, true))
    assert.is_truthy(line_text(lines[2]):find("30s", 1, true))
  end)
end)
