---@diagnostic disable
local query = require "octo.kanban.query"
local actions = require "octo.kanban.actions"

describe("kanban query", function()
  describe("project_hint", function()
    it("reads the project number from an org project qualifier", function()
      assert.are.equal(5, query.project_hint "project:acme/5")
    end)

    it("reads it from a repository project qualifier", function()
      assert.are.equal(3, query.project_hint "project:acme/widgets/3")
    end)

    it("finds the qualifier among other search terms", function()
      assert.are.equal(5, query.project_hint "assignee:someone project:acme/5 is:open")
    end)

    it("has no opinion when the search names no project", function()
      assert.is_nil(query.project_hint "assignee:someone is:open")
      assert.is_nil(query.project_hint "")
    end)

    it("ignores a project qualifier that does not end in a number", function()
      assert.is_nil(query.project_hint "project:acme/backlog")
    end)
  end)

  describe("project_ref", function()
    it("reads an organisation project", function()
      assert.are.same({ owner = "acme", number = 5 }, query.project_ref "project:acme/5")
    end)

    it("reads a repository project", function()
      assert.are.same({ owner = "acme", repo = "widgets", number = 3 }, query.project_ref "project:acme/widgets/3")
    end)

    it("finds it among other terms", function()
      assert.are.same({ owner = "acme", number = 5 }, query.project_ref "assignee:me project:acme/5 is:open")
    end)

    it("has nothing to say when the search names no project", function()
      assert.is_nil(query.project_ref "assignee:me is:open")
      assert.is_nil(query.project_ref "project:acme/backlog")
    end)
  end)

  describe("combined_query", function()
    -- One request beats two: each `gh` invocation costs ~0.35s of process and auth
    -- overhead before GitHub is even asked anything.
    it("asks for the search and an organisation project together", function()
      local q = query.combined_query { owner = "acme", number = 5 }
      assert.is_truthy(q:find("search(", 1, true))
      assert.is_truthy(q:find("organization(", 1, true))
      assert.is_falsy(q:find("repository(", 1, true))
    end)

    it("asks for a repository project when the ref names a repo", function()
      local q = query.combined_query { owner = "acme", repo = "widgets", number = 3 }
      assert.is_truthy(q:find("search(", 1, true))
      assert.is_truthy(q:find("repository(", 1, true))
      assert.is_falsy(q:find("organization(", 1, true))
    end)

    it("carries the status field and paging variables", function()
      local q = query.combined_query { owner = "acme", number = 5 }
      for _, needle in ipairs { "$q:", "$after:", "$statusField:", "$projectNumber:", "pageInfo" } do
        assert.is_truthy(q:find(needle, 1, true), "missing: " .. needle)
      end
    end)
  end)
end)

describe("kanban actions", function()
  --- index 1 is the unwritable No Status column when `with_no_status` is set.
  local function columns(with_no_status)
    local out = {}
    if with_no_status then
      out[#out + 1] = { name = "No Status", cards = {} }
    end
    for _, spec in ipairs { { "Todo", "opt_todo" }, { "Doing", "opt_doing" }, { "Done", "opt_done" } } do
      out[#out + 1] = { name = spec[1], option_id = spec[2], cards = {} }
    end
    return out
  end

  describe("target_column", function()
    it("moves a card to the next column", function()
      assert.are.equal(2, actions.target_column(columns(false), 1, 1))
    end)

    it("moves a card to the previous column", function()
      assert.are.equal(1, actions.target_column(columns(false), 2, -1))
    end)

    it("stops at the last column", function()
      assert.is_nil(actions.target_column(columns(false), 3, 1))
    end)

    it("stops at the first column", function()
      assert.is_nil(actions.target_column(columns(false), 1, -1))
    end)

    it("refuses to move a card that is not on the board", function()
      -- the No Status column has no option to write, so its cards cannot move
      assert.is_nil(actions.target_column(columns(true), 1, 1))
    end)

    it("refuses to move a card into the No Status column", function()
      -- index 2 is Todo; moving left would land on No Status, which cannot be written
      assert.is_nil(actions.target_column(columns(true), 2, -1))
    end)

    it("moves normally between real columns when No Status is present", function()
      assert.are.equal(3, actions.target_column(columns(true), 2, 1))
    end)
  end)
end)
