---@diagnostic disable
local board = require "octo.kanban.board"

--- A project item as the search query returns it.
local function item(project_id, project_number, status, item_id)
  return {
    id = item_id or "ITEM_1",
    project = { id = project_id, number = project_number, title = "Team Planning" },
    fieldValueByName = status and { name = status } or nil,
  }
end

--- A search result node.
local function node(number, title, opts)
  opts = opts or {}
  return {
    __typename = opts.pr and "PullRequest" or "Issue",
    number = number,
    title = title,
    state = opts.state or "OPEN",
    url = "https://github.com/acme/widgets/issues/" .. number,
    repository = { nameWithOwner = opts.repo or "acme/widgets" },
    labels = { nodes = opts.labels or {} },
    projectItems = { nodes = opts.items or {} },
  }
end

local OPTIONS = {
  { id = "opt_todo", name = "Todo" },
  { id = "opt_doing", name = "Doing" },
  { id = "opt_done", name = "Done" },
}

describe("kanban board", function()
  describe("choose_project", function()
    it("picks the project that most results belong to", function()
      local nodes = {
        node(1, "a", { items = { item("P_MAIN", 5, "Todo") } }),
        node(2, "b", { items = { item("P_MAIN", 5, "Doing") } }),
        node(3, "c", { items = { item("P_OTHER", 9, "Todo") } }),
      }
      local project = board.choose_project(nodes)
      assert.are.equal("P_MAIN", project.id)
      assert.are.equal(5, project.number)
    end)

    it("honours an explicitly requested project number", function()
      local nodes = {
        node(1, "a", { items = { item("P_MAIN", 5, "Todo") } }),
        node(2, "b", { items = { item("P_MAIN", 5, "Todo") } }),
        node(3, "c", { items = { item("P_OTHER", 9, "Todo") } }),
      }
      local project = board.choose_project(nodes, 9)
      assert.are.equal("P_OTHER", project.id)
    end)

    it("returns nil when a requested project is absent from the results", function()
      local nodes = { node(1, "a", { items = { item("P_MAIN", 5, "Todo") } }) }
      assert.is_nil(board.choose_project(nodes, 42))
    end)

    it("returns nil when nothing is on a project at all", function()
      assert.is_nil(board.choose_project { node(1, "a") })
      assert.is_nil(board.choose_project {})
    end)
  end)

  describe("normalize", function()
    it("reads the status of the chosen project", function()
      local cards = board.normalize({ node(7, "Fix the thing", { items = { item("P_MAIN", 5, "Doing") } }) }, "P_MAIN")
      assert.are.equal(1, #cards)
      assert.are.equal(7, cards[1].number)
      assert.are.equal("Fix the thing", cards[1].title)
      assert.are.equal("Doing", cards[1].status)
      assert.are.equal("acme/widgets", cards[1].repo)
    end)

    it("records the project item id so the card can be moved", function()
      local cards = board.normalize({ node(7, "a", { items = { item("P_MAIN", 5, "Todo", "ITEM_7") } }) }, "P_MAIN")
      assert.are.equal("ITEM_7", cards[1].item_id)
    end)

    it("leaves status unset when the result is only on another project", function()
      local cards = board.normalize({ node(7, "a", { items = { item("P_OTHER", 9, "Done") } }) }, "P_MAIN")
      assert.is_nil(cards[1].status)
      assert.is_nil(cards[1].item_id)
    end)

    it("leaves status unset when the item has no status value", function()
      local cards = board.normalize({ node(7, "a", { items = { item("P_MAIN", 5, nil) } }) }, "P_MAIN")
      assert.is_nil(cards[1].status)
      assert.are.equal("ITEM_1", cards[1].item_id)
    end)

    it("keeps labels with the colour GitHub gives them", function()
      -- the hex is what lets a label render as its own coloured badge
      local nodes = {
        node(7, "an issue", { labels = { { name = "bug", color = "d73a4a" }, { name = "p1", color = "0e8a16" } } }),
      }
      local cards = board.normalize(nodes, "P_MAIN")
      assert.are.same({ { name = "bug", color = "d73a4a" }, { name = "p1", color = "0e8a16" } }, cards[1].labels)
    end)

    it("copes with a label that has no colour", function()
      local cards = board.normalize({ node(7, "a", { labels = { { name = "bug" } } }) }, "P_MAIN")
      assert.are.equal("bug", cards[1].labels[1].name)
      assert.is_nil(cards[1].labels[1].color)
    end)

    it("marks pull requests apart from issues", function()
      local cards = board.normalize({ node(7, "an issue"), node(8, "a pr", { pr = true }) }, "P_MAIN")
      assert.is_false(cards[1].is_pr)
      assert.is_true(cards[2].is_pr)
    end)
  end)

  describe("columns", function()
    it("builds one column per option, in the board's own order", function()
      local cards = {
        { number = 1, status = "Done" },
        { number = 2, status = "Todo" },
      }
      local columns = board.columns(cards, OPTIONS)
      assert.are.same({ "Todo", "Doing", "Done" }, vim.tbl_map(function(c)
        return c.name
      end, columns))
    end)

    it("keeps a column that no card landed in", function()
      local columns = board.columns({ { number = 1, status = "Todo" } }, OPTIONS)
      assert.are.equal(3, #columns)
      assert.are.equal(0, #columns[2].cards)
    end)

    it("carries the option id each column writes when a card moves in", function()
      local columns = board.columns({}, OPTIONS)
      assert.are.equal("opt_doing", columns[2].option_id)
    end)

    it("preserves result order within a column", function()
      local cards = {
        { number = 3, status = "Todo" },
        { number = 1, status = "Todo" },
        { number = 2, status = "Todo" },
      }
      local columns = board.columns(cards, OPTIONS)
      assert.are.same({ 3, 1, 2 }, vim.tbl_map(function(c)
        return c.number
      end, columns[1].cards))
    end)

    it("gathers status-less cards into a leading No Status column", function()
      local cards = {
        { number = 1, status = "Todo" },
        { number = 2, status = nil },
      }
      local columns = board.columns(cards, OPTIONS)
      assert.are.equal(4, #columns)
      assert.are.equal("No Status", columns[1].name)
      assert.are.equal(2, columns[1].cards[1].number)
      assert.is_nil(columns[1].option_id)
    end)

    it("omits the No Status column when every card has one", function()
      local columns = board.columns({ { number = 1, status = "Todo" } }, OPTIONS)
      assert.are.equal("Todo", columns[1].name)
    end)

    it("treats a status the board no longer offers as status-less", function()
      -- an option renamed or deleted on the project since the card was filed
      local columns = board.columns({ { number = 1, status = "Retired" } }, OPTIONS)
      assert.are.equal("No Status", columns[1].name)
      assert.are.equal(1, columns[1].cards[1].number)
    end)
  end)
end)
